#!/bin/bash
# Lab 8.2: Running Containers on a Managed Service

source ./common.sh

set -euo pipefail

REGION="${AWS_REGION:-$AWS_DEFAULT_REGION}"
CODE_URL="https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACCDEV-2-91558/07-lab-deploy/code.zip"
LABIDE_SCRIPT="./lab8_2_labide_setup.generated.sh"
HELPER_OBJECT="$(basename "$LABIDE_SCRIPT")"
HELPER_BUCKET=""

RDS_CLUSTER_ID="supplierdb"
RDS_INSTANCE_ID="supplierdb-instance-1"
RDS_SUBNET_GROUP="supplierdb-subnet-group"
RDS_ENGINE_VERSION=""
RDS_MASTER_USERNAME="admin"
RDS_MASTER_PASSWORD="coffee_beans_for_all"
RDS_APP_USERNAME="nodeapp"
RDS_APP_PASSWORD="coffee"

ECR_REPO_NAME="cafe/node-web-app"
EB_APPLICATION_NAME="MyNodeApp"
EB_ENVIRONMENT_NAME="MyEnv"
API_NAME="ProductsApi"

LABIDE_ID=""
LABIDE_PUBLIC_IP=""
LABIDE_VPC_ID=""
IDE_SUBNET_ID=""
IDE_AZ=""
LABIDE_SG=""
EXTRA_SUBNET_ID=""
EXTRA_SUBNET_AZ=""
PUBLIC_ROUTE_TABLE_ID=""
DB_ENDPOINT=""
DB_SECURITY_GROUP_ID=""
MY_IP=""
EB_URL=""
WEBSITE_URL=""
REPOSITORY_URI=""

require_value() {
  local value="$1"
  local label="$2"

  if [ -z "$value" ] || [ "$value" = "None" ]; then
    echo "ERROR: Could not determine $label." >&2
    exit 1
  fi
}

find_labide_info() {
  aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=*LabIDE*,*Lab IDE*,*lab-ide*,*IDE*" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,VpcId,SubnetId,Placement.AvailabilityZone,SecurityGroups[0].GroupId]' \
    --output text | head -n 1
}

find_other_az() {
  aws ec2 describe-availability-zones \
    --region "$REGION" \
    --filters "Name=state,Values=available" \
    --query 'AvailabilityZones[].ZoneName' \
    --output text | tr '\t' '\n' | grep -Fxv "$IDE_AZ" | head -n 1
}

ensure_extra_subnet() {
  local existing_subnet_id
  local existing_az

  existing_subnet_id=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$LABIDE_VPC_ID" "Name=tag:Name,Values=extraSubnetForRds" \
    --query 'Subnets[0].SubnetId' \
    --output text 2>/dev/null || true)

  if [ -n "$existing_subnet_id" ] && [ "$existing_subnet_id" != "None" ]; then
    existing_az=$(aws ec2 describe-subnets \
      --region "$REGION" \
      --subnet-ids "$existing_subnet_id" \
      --query 'Subnets[0].AvailabilityZone' \
      --output text)
    EXTRA_SUBNET_ID="$existing_subnet_id"
    EXTRA_SUBNET_AZ="$existing_az"
    echo "    extraSubnetForRds already exists: $EXTRA_SUBNET_ID ($EXTRA_SUBNET_AZ)"
  else
    EXTRA_SUBNET_AZ=$(find_other_az)
    require_value "$EXTRA_SUBNET_AZ" "an Availability Zone different from $IDE_AZ"

    EXTRA_SUBNET_ID=$(aws ec2 create-subnet \
      --region "$REGION" \
      --vpc-id "$LABIDE_VPC_ID" \
      --availability-zone "$EXTRA_SUBNET_AZ" \
      --cidr-block "10.0.2.0/24" \
      --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=extraSubnetForRds}]' \
      --query 'Subnet.SubnetId' \
      --output text)

    echo "    Created extraSubnetForRds: $EXTRA_SUBNET_ID ($EXTRA_SUBNET_AZ)"
  fi

  aws ec2 modify-subnet-attribute \
    --region "$REGION" \
    --subnet-id "$EXTRA_SUBNET_ID" \
    --map-public-ip-on-launch > /dev/null
}

find_public_route_table() {
  aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$LABIDE_VPC_ID" \
    --query "RouteTables[?length(Routes[?DestinationCidrBlock=='0.0.0.0/0' && GatewayId!=null]) > \`0\`].RouteTableId | [0]" \
    --output text
}

ensure_public_route_table_association() {
  local current_route_table_id
  local current_association_id

  PUBLIC_ROUTE_TABLE_ID=$(find_public_route_table)
  require_value "$PUBLIC_ROUTE_TABLE_ID" "a public route table in $LABIDE_VPC_ID"

  current_route_table_id=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=association.subnet-id,Values=$EXTRA_SUBNET_ID" \
    --query 'RouteTables[0].RouteTableId' \
    --output text 2>/dev/null || true)

  if [ "$current_route_table_id" = "$PUBLIC_ROUTE_TABLE_ID" ]; then
    echo "    extraSubnetForRds already uses public route table $PUBLIC_ROUTE_TABLE_ID."
    return
  fi

  current_association_id=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=association.subnet-id,Values=$EXTRA_SUBNET_ID" \
    --query 'RouteTables[0].Associations[0].RouteTableAssociationId' \
    --output text 2>/dev/null || true)

  if [ -n "$current_association_id" ] && [ "$current_association_id" != "None" ]; then
    aws ec2 replace-route-table-association \
      --region "$REGION" \
      --association-id "$current_association_id" \
      --route-table-id "$PUBLIC_ROUTE_TABLE_ID" > /dev/null
  else
    aws ec2 associate-route-table \
      --region "$REGION" \
      --subnet-id "$EXTRA_SUBNET_ID" \
      --route-table-id "$PUBLIC_ROUTE_TABLE_ID" > /dev/null
  fi

  echo "    extraSubnetForRds now uses public route table $PUBLIC_ROUTE_TABLE_ID."
}

ensure_rds_subnet_group() {
  if aws rds describe-db-subnet-groups \
    --region "$REGION" \
    --db-subnet-group-name "$RDS_SUBNET_GROUP" > /dev/null 2>&1; then
    aws rds modify-db-subnet-group \
      --region "$REGION" \
      --db-subnet-group-name "$RDS_SUBNET_GROUP" \
      --subnet-ids "$IDE_SUBNET_ID" "$EXTRA_SUBNET_ID" > /dev/null
    echo "    Updated DB subnet group $RDS_SUBNET_GROUP."
  else
    aws rds create-db-subnet-group \
      --region "$REGION" \
      --db-subnet-group-name "$RDS_SUBNET_GROUP" \
      --db-subnet-group-description "Lab 8.2 subnet group" \
      --subnet-ids "$IDE_SUBNET_ID" "$EXTRA_SUBNET_ID" > /dev/null
    echo "    Created DB subnet group $RDS_SUBNET_GROUP."
  fi
}

select_rds_engine_version() {
  local preferred="8.0.mysql_aurora.3.07.0"
  local versions
  local fallback

  versions=$(aws rds describe-db-engine-versions \
    --region "$REGION" \
    --engine aurora-mysql \
    --query 'DBEngineVersions[].EngineVersion' \
    --output text 2>/dev/null | tr '\t' '\n' | sort -Vu || true)

  if printf '%s\n' "$versions" | grep -Fxq "$preferred"; then
    printf '%s\n' "$preferred"
    return 0
  fi

  fallback=$(printf '%s\n' "$versions" | grep '^8\.0\.mysql_aurora\.3\.' | tail -n 1)
  if [ -n "$fallback" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  fallback=$(printf '%s\n' "$versions" | tail -n 1)
  if [ -n "$fallback" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  printf '%s\n' ""
}

ensure_rds_cluster_and_instance() {
  local create_args

  if aws rds describe-db-clusters \
    --region "$REGION" \
    --db-cluster-identifier "$RDS_CLUSTER_ID" > /dev/null 2>&1; then
    echo "    Aurora cluster $RDS_CLUSTER_ID already exists."
  else
    create_args=(
      rds create-db-cluster
      --region "$REGION" \
      --db-cluster-identifier "$RDS_CLUSTER_ID" \
      --engine aurora-mysql \
      --master-username "$RDS_MASTER_USERNAME" \
      --master-user-password "$RDS_MASTER_PASSWORD" \
      --database-name suppliers \
      --db-subnet-group-name "$RDS_SUBNET_GROUP" \
      --vpc-security-group-ids "$LABIDE_SG" \
      --serverless-v2-scaling-configuration MinCapacity=2,MaxCapacity=16 \
      --enable-http-endpoint
    )

    if [ -n "$RDS_ENGINE_VERSION" ]; then
      create_args+=(--engine-version "$RDS_ENGINE_VERSION")
    fi

    aws "${create_args[@]}" > /dev/null
    echo "    Created Aurora cluster $RDS_CLUSTER_ID."
  fi

  if aws rds describe-db-instances \
    --region "$REGION" \
    --db-instance-identifier "$RDS_INSTANCE_ID" > /dev/null 2>&1; then
    echo "    Aurora instance $RDS_INSTANCE_ID already exists."
  else
    aws rds create-db-instance \
      --region "$REGION" \
      --db-instance-identifier "$RDS_INSTANCE_ID" \
      --db-cluster-identifier "$RDS_CLUSTER_ID" \
      --engine aurora-mysql \
      --db-instance-class db.serverless > /dev/null
    echo "    Created Aurora instance $RDS_INSTANCE_ID."
  fi

  echo "    Waiting for Aurora instance to become available..."
  aws rds wait db-instance-available \
    --region "$REGION" \
    --db-instance-identifier "$RDS_INSTANCE_ID"

  DB_ENDPOINT=$(aws rds describe-db-clusters \
    --region "$REGION" \
    --db-cluster-identifier "$RDS_CLUSTER_ID" \
    --query 'DBClusters[0].Endpoint' \
    --output text)
  DB_SECURITY_GROUP_ID=$(aws rds describe-db-clusters \
    --region "$REGION" \
    --db-cluster-identifier "$RDS_CLUSTER_ID" \
    --query 'DBClusters[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
    --output text)

  require_value "$DB_ENDPOINT" "database endpoint"
  require_value "$DB_SECURITY_GROUP_ID" "database security group ID"
}

ensure_port_8000_for_my_ip() {
  local existing

  existing=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --group-ids "$LABIDE_SG" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`8000\` && ToPort==\`8000\`].IpRanges[?CidrIp=='$MY_IP/32'].CidrIp" \
    --output text 2>/dev/null || true)

  if echo "$existing" | tr '\t' '\n' | grep -Fxq "$MY_IP/32"; then
    echo "    Port 8000 already open for $MY_IP/32 on $LABIDE_SG."
    return
  fi

  aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$LABIDE_SG" \
    --protocol tcp \
    --port 8000 \
    --cidr "$MY_IP/32" > /dev/null 2>&1 || true

  echo "    Port 8000 open for $MY_IP/32 on $LABIDE_SG."
}

ensure_mysql_self_reference() {
  local existing

  existing=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --group-ids "$LABIDE_SG" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`3306\` && ToPort==\`3306\`].UserIdGroupPairs[?GroupId=='$LABIDE_SG'].GroupId" \
    --output text 2>/dev/null || true)

  if echo "$existing" | tr '\t' '\n' | grep -Fxq "$LABIDE_SG"; then
    echo "    Port 3306 already self-referenced on $LABIDE_SG."
    return
  fi

  aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$LABIDE_SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=$LABIDE_SG}]" > /dev/null 2>&1 || true

  echo "    Port 3306 self-reference ensured on $LABIDE_SG."
}

create_staging_bucket() {
  local bucket_name="lab8-2-setup-${ACCOUNT_ID}-${REGION}"

  if aws s3api head-bucket --bucket "$bucket_name" > /dev/null 2>&1; then
    printf '%s\n' "$bucket_name"
    return 0
  fi

  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "$bucket_name" \
      --region "$REGION" > /dev/null
  else
    aws s3api create-bucket \
      --bucket "$bucket_name" \
      --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" > /dev/null
  fi

  printf '%s\n' "$bucket_name"
}

upload_helper_script() {
  aws s3 cp "$LABIDE_SCRIPT" "s3://${HELPER_BUCKET}/${HELPER_OBJECT}" \
    --cache-control "max-age=0" > /dev/null
}

write_local_values_file() {
  cat > ./lab8_2_values.txt <<EOF
IDE VPC ID: $LABIDE_VPC_ID
IDE Availability Zone: $IDE_AZ
IDE subnet ID: $IDE_SUBNET_ID
extraSubnetForRds subnet ID: $EXTRA_SUBNET_ID
IDE security group ID: $LABIDE_SG
Database endpoint: $DB_ENDPOINT
Repository URI: ${REPOSITORY_URI:-}
Elastic Beanstalk URL: ${EB_URL:-}
WebsiteURL: ${WEBSITE_URL:-}
EOF
}

generate_labide_script() {
  cat > "$LABIDE_SCRIPT" <<EOF
#!/bin/bash
# Generated by lab8_2.sh for AWS Academy Lab 8.2

set -euo pipefail

REGION="${REGION}"
CODE_URL="${CODE_URL}"
PUBLIC_IP="${MY_IP}"
DB_ENDPOINT="${DB_ENDPOINT}"
LABIDE_PUBLIC_IP="${LABIDE_PUBLIC_IP}"
IDE_VPC_ID="${LABIDE_VPC_ID}"
IDE_AZ="${IDE_AZ}"
IDE_SUBNET_ID="${IDE_SUBNET_ID}"
EXTRA_SUBNET_ID="${EXTRA_SUBNET_ID}"
LABIDE_SG="${LABIDE_SG}"
RDS_CLUSTER_ID="${RDS_CLUSTER_ID}"
RDS_MASTER_USERNAME="${RDS_MASTER_USERNAME}"
RDS_MASTER_PASSWORD="${RDS_MASTER_PASSWORD}"
RDS_APP_USERNAME="${RDS_APP_USERNAME}"
RDS_APP_PASSWORD="${RDS_APP_PASSWORD}"
ECR_REPO_NAME="${ECR_REPO_NAME}"
EB_APPLICATION_NAME="${EB_APPLICATION_NAME}"
EB_ENVIRONMENT_NAME="${EB_ENVIRONMENT_NAME}"
HELPER_BUCKET="${HELPER_BUCKET}"
BASE="\$HOME/environment"
VALUES_FILE="\$BASE/lab8_2_values.txt"

wait_for_http() {
  local url="\$1"
  local retries="\${2:-90}"
  local count=0

  until curl -fsS "\$url" > /dev/null 2>&1; do
    count=\$((count + 1))
    if [ "\$count" -ge "\$retries" ]; then
      echo "ERROR: Timed out waiting for \$url" >&2
      exit 1
    fi
    sleep 2
  done
}

wait_for_mysql() {
  local retries="\${1:-90}"
  local count=0

  until mysql -h "\$DB_ENDPOINT" -P 3306 -u "\$RDS_MASTER_USERNAME" -p"\$RDS_MASTER_PASSWORD" -e "SELECT 1" > /dev/null 2>&1; do
    count=\$((count + 1))
    if [ "\$count" -ge "\$retries" ]; then
      echo "ERROR: Timed out waiting for MySQL at \$DB_ENDPOINT" >&2
      exit 1
    fi
    sleep 10
  done
}

wait_for_eb_ready() {
  local retries="\${1:-90}"
  local count=0
  local status
  local health
  local cname

  while true; do
    status=\$(aws elasticbeanstalk describe-environments \
      --region "\$REGION" \
      --application-name "\$EB_APPLICATION_NAME" \
      --environment-names "\$EB_ENVIRONMENT_NAME" \
      --query 'Environments[0].Status' \
      --output text 2>/dev/null || true)
    health=\$(aws elasticbeanstalk describe-environments \
      --region "\$REGION" \
      --application-name "\$EB_APPLICATION_NAME" \
      --environment-names "\$EB_ENVIRONMENT_NAME" \
      --query 'Environments[0].Health' \
      --output text 2>/dev/null || true)
    cname=\$(aws elasticbeanstalk describe-environments \
      --region "\$REGION" \
      --application-name "\$EB_APPLICATION_NAME" \
      --environment-names "\$EB_ENVIRONMENT_NAME" \
      --query 'Environments[0].CNAME' \
      --output text 2>/dev/null || true)

    if [ "\$status" = "Ready" ] && [ -n "\$cname" ] && [ "\$cname" != "None" ]; then
      echo "    Elastic Beanstalk status: \$status / \$health" >&2
      printf '%s\n' "\$cname"
      return 0
    fi

    count=\$((count + 1))
    if [ "\$count" -ge "\$retries" ]; then
      echo "ERROR: Timed out waiting for Elastic Beanstalk environment \$EB_ENVIRONMENT_NAME" >&2
      exit 1
    fi

    echo "    Waiting for Elastic Beanstalk: status=\${status:-unknown}, health=\${health:-unknown}" >&2
    sleep 20
  done
}

write_values_file() {
  local repository_uri="\$1"
  local eb_url="\$2"
  local website_url="\$3"

  cat > "\$VALUES_FILE" <<VALUES
IDE VPC ID: \$IDE_VPC_ID
IDE Availability Zone: \$IDE_AZ
IDE subnet ID: \$IDE_SUBNET_ID
extraSubnetForRds subnet ID: \$EXTRA_SUBNET_ID
IDE security group ID: \$LABIDE_SG
Database endpoint: \$DB_ENDPOINT
Repository URI: \$repository_uri
Elastic Beanstalk URL: \$eb_url
WebsiteURL: \$website_url
VALUES
}

echo ""
echo "==> [Task 1] Downloading lab files..."
mkdir -p "\$BASE"
cd "\$BASE"
if [ ! -f code.zip ]; then
  wget -q "\$CODE_URL" -O code.zip
fi
unzip -o code.zip > /dev/null 2>&1 || true

echo "==> [Task 1] Running setup.sh..."
chmod +x ./resources/setup.sh
read -rp "Public IPv4 for setup.sh [\$PUBLIC_IP]: " IP_FOR_SETUP
IP_FOR_SETUP="\${IP_FOR_SETUP:-\$PUBLIC_IP}"
printf '%s\n' "\$IP_FOR_SETUP" | ./resources/setup.sh

echo "==> [Task 1] Verifying AWS CLI and boto3..."
aws --version
pip3 show boto3 > /dev/null

S3_BUCKET=\$(aws s3api list-buckets \
  --query "Buckets[?contains(Name, '-s3bucket')].Name | [0]" \
  --output text 2>/dev/null || true)
WEBSITE_URL=""
if [ -n "\$S3_BUCKET" ] && [ "\$S3_BUCKET" != "None" ]; then
  WEBSITE_URL="http://\${S3_BUCKET}.s3-website-\${REGION}.amazonaws.com"
fi

echo ""
echo "==> [Task 4] Reviewing the ECR image..."
aws ecr describe-repositories --region "\$REGION"
aws ecr describe-images --region "\$REGION" --repository-name "\$ECR_REPO_NAME"
REPOSITORY_URI=\$(aws ecr describe-repositories \
  --region "\$REGION" \
  --repository-names "\$ECR_REPO_NAME" \
  --query 'repositories[0].repositoryUri' \
  --output text)

echo ""
echo "==> [Task 5] Starting the container against Aurora..."
docker stop node-web-app-1 > /dev/null 2>&1 || true
docker rm node-web-app-1 > /dev/null 2>&1 || true
docker run -d --name node-web-app-1 -p 8000:3000 -e APP_DB_HOST="\$DB_ENDPOINT" "\$ECR_REPO_NAME" > /dev/null
wait_for_http "http://localhost:8000" 60
curl -fsS http://localhost:8000 > /dev/null
echo "    Container is responding on http://localhost:8000"
echo "    Browser URL: http://\$LABIDE_PUBLIC_IP:8000"

echo ""
echo "==> [Task 6] Preparing the exact grader-sensitive commands..."
wait_for_mysql 60
cat > "\$BASE/lab8_2_task6_query_editor.sql" <<'TASK6SQL'
DROP USER IF EXISTS 'nodeapp'@'%';
DROP DATABASE IF EXISTS COFFEE;

CREATE USER 'nodeapp'@'%' IDENTIFIED WITH mysql_native_password BY 'coffee';
CREATE DATABASE COFFEE;

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, RELOAD, PROCESS, REFERENCES, INDEX, ALTER, SHOW DATABASES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, REPLICATION SLAVE, REPLICATION CLIENT, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, CREATE USER, EVENT, TRIGGER ON *.* TO 'nodeapp'@'%' WITH GRANT OPTION;

USE COFFEE;

CREATE TABLE suppliers(
    id INT NOT NULL AUTO_INCREMENT,
    name VARCHAR(255) NOT NULL,
    address VARCHAR(255) NOT NULL,
    city VARCHAR(255) NOT NULL,
    state VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL,
    phone VARCHAR(100) NOT NULL,
    PRIMARY KEY (id)
);

SELECT * FROM suppliers;
TASK6SQL

cat > "\$BASE/lab8_2_task7_mysql_commands.txt" <<TASK7CMDS
cd ~/environment/resources
mysql -h \$DB_ENDPOINT -P 3306 -u admin -p
# Password: coffee_beans_for_all
use COFFEE;
source coffee_db_dump.sql
select count(*) from suppliers;
select count(*) from beans;
exit
TASK7CMDS

echo "    Task 6 must be done in AWS RDS Query Editor for reliable grading."
echo ""
echo "    In the AWS console:"
echo "    1. Open RDS -> Query Editor."
echo "    2. Connect with:"
echo "       Cluster/schema: supplierdb / suppliers"
echo "       Username: admin"
echo "       Password: coffee_beans_for_all"
echo "    3. Paste and run the SQL saved at:"
echo "       \$BASE/lab8_2_task6_query_editor.sql"
echo ""
echo "    Exact SQL to paste:"
echo "------------------------------------------------------------"
cat "\$BASE/lab8_2_task6_query_editor.sql"
echo "------------------------------------------------------------"
echo ""
echo "    Then open this page in the browser:"
echo "       http://\$LABIDE_PUBLIC_IP:8000/suppliers"
echo "    Add one supplier through the website UI."
read -rp "Press ENTER after Task 6 is done in Query Editor and one supplier was added..."

echo ""
echo "==> [Task 6] Verifying the supplier row..."
mysql -h "\$DB_ENDPOINT" -P 3306 -u "\$RDS_MASTER_USERNAME" -p"\$RDS_MASTER_PASSWORD" -e "USE COFFEE; SELECT * FROM suppliers;"

echo ""
echo "==> [Task 7] Manual seed step required for reliable grading..."
echo "    Open a SECOND LabIDE terminal and run these exact commands:"
echo "------------------------------------------------------------"
cat "\$BASE/lab8_2_task7_mysql_commands.txt"
echo "------------------------------------------------------------"
echo ""
echo "    Do not type <db-endpoint>; the real endpoint is already in the command above."
read -rp "Press ENTER after you ran the Task 7 commands in the second LabIDE terminal..."
mysql -h "\$DB_ENDPOINT" -P 3306 -u "\$RDS_MASTER_USERNAME" -p"\$RDS_MASTER_PASSWORD" -e "USE COFFEE; SELECT COUNT(*) AS suppliers_count FROM suppliers; SELECT COUNT(*) AS beans_count FROM beans;"
echo "    Supplier and beans data verified."

echo ""
echo "==> [Task 9] Creating the Elastic Beanstalk application..."
cd "\$BASE"
mkdir -p bean
cd bean

cat > options.txt <<OPTIONS
[
    {
        "Namespace": "aws:autoscaling:launchconfiguration",
        "OptionName": "IamInstanceProfile",
        "Value": "aws-elasticbeanstalk-ec2-role"
    },
    {
        "Namespace": "aws:autoscaling:launchconfiguration",
        "OptionName": "SecurityGroups",
        "Value": "\$LABIDE_SG"
    },
    {
        "Namespace": "aws:ec2:vpc",
        "OptionName": "VPCId",
        "Value": "\$IDE_VPC_ID"
    },
    {
        "Namespace": "aws:ec2:vpc",
        "OptionName": "Subnets",
        "Value": "\$IDE_SUBNET_ID,\$EXTRA_SUBNET_ID"
    },
    {
        "Namespace": "aws:elasticbeanstalk:application:environment",
        "OptionName": "APP_DB_HOST",
        "Value": "\$DB_ENDPOINT"
    }
]
OPTIONS

if ! aws elasticbeanstalk describe-applications \
  --region "\$REGION" \
  --application-names "\$EB_APPLICATION_NAME" \
  --query 'Applications[0].ApplicationName' \
  --output text 2>/dev/null | grep -Fxq "\$EB_APPLICATION_NAME"; then
  aws elasticbeanstalk create-application \
    --region "\$REGION" \
    --application-name "\$EB_APPLICATION_NAME" > /dev/null
fi

SOLUTION_STACK=\$(aws elasticbeanstalk list-available-solution-stacks \
  --region "\$REGION" \
  --query "SolutionStacks[?contains(@, 'Amazon Linux 2') && contains(@, 'running Docker')]" \
  --output text | tr '\t' '\n' | tail -n 1)

if [ -z "\$SOLUTION_STACK" ]; then
  echo "ERROR: Could not find an Amazon Linux 2 Docker solution stack." >&2
  exit 1
fi

if ! aws elasticbeanstalk describe-environments \
  --region "\$REGION" \
  --application-name "\$EB_APPLICATION_NAME" \
  --environment-names "\$EB_ENVIRONMENT_NAME" \
  --query "Environments[?Status!='Terminated'][0].EnvironmentName" \
  --output text 2>/dev/null | grep -Fxq "\$EB_ENVIRONMENT_NAME"; then
  aws elasticbeanstalk create-environment \
    --region "\$REGION" \
    --application-name "\$EB_APPLICATION_NAME" \
    --environment-name "\$EB_ENVIRONMENT_NAME" \
    --solution-stack-name "\$SOLUTION_STACK" \
    --option-settings file://options.txt > /dev/null
fi

EB_CNAME=\$(wait_for_eb_ready 90)
echo "    Sample environment URL: http://\$EB_CNAME"

cat > Dockerrun.aws.json <<DOCKERRUN
{
  "AWSEBDockerrunVersion": "1",
  "Image": {
    "Name": "\$REPOSITORY_URI",
    "Update": "true"
  },
  "Ports": [
    {
      "ContainerPort": 3000
    }
  ]
}
DOCKERRUN

VERSION_LABEL="\${EB_APPLICATION_NAME}-version-\$(date +%Y%m%d%H%M%S)a"
ZIP_NAME="\${VERSION_LABEL}.zip"
rm -f "\$ZIP_NAME"
if command -v zip > /dev/null 2>&1; then
  zip -q -j "\$ZIP_NAME" Dockerrun.aws.json
else
  python3 - <<PY
import zipfile
with zipfile.ZipFile("\${ZIP_NAME}", "w", compression=zipfile.ZIP_DEFLATED) as zf:
    zf.write("Dockerrun.aws.json", arcname="Dockerrun.aws.json")
PY
fi
aws s3 cp "\$ZIP_NAME" "s3://\$HELPER_BUCKET/\$ZIP_NAME" > /dev/null

aws elasticbeanstalk create-application-version \
  --region "\$REGION" \
  --application-name "\$EB_APPLICATION_NAME" \
  --version-label "\$VERSION_LABEL" \
  --source-bundle S3Bucket="\$HELPER_BUCKET",S3Key="\$ZIP_NAME" \
  --process > /dev/null

aws elasticbeanstalk update-environment \
  --region "\$REGION" \
  --environment-name "\$EB_ENVIRONMENT_NAME" \
  --version-label "\$VERSION_LABEL" > /dev/null

EB_CNAME=\$(wait_for_eb_ready 90)
docker stop node-web-app-1 > /dev/null 2>&1 || true
docker rm node-web-app-1 > /dev/null 2>&1 || true

write_values_file "\$REPOSITORY_URI" "http://\$EB_CNAME" "\$WEBSITE_URL"

echo ""
echo "==> [Task 9] Verifying the deployed application..."
wait_for_http "http://\$EB_CNAME/beans.json" 60
echo "    Elastic Beanstalk URL: http://\$EB_CNAME"
echo "    Values file: \$VALUES_FILE"

echo ""
echo "=== Lab 8.2 LabIDE setup COMPLETE ==="
echo "    LabIDE app URL:        http://\$LABIDE_PUBLIC_IP:8000"
echo "    Elastic Beanstalk URL: http://\$EB_CNAME"
if [ -n "\$WEBSITE_URL" ]; then
  echo "    Cafe Website URL:      \$WEBSITE_URL"
fi
echo "    Next: return to your original terminal and press ENTER."
EOF

  chmod +x "$LABIDE_SCRIPT"
}

find_repository_uri() {
  aws ecr describe-repositories \
    --region "$REGION" \
    --repository-names "$ECR_REPO_NAME" \
    --query 'repositories[0].repositoryUri' \
    --output text 2>/dev/null || true
}

find_eb_url() {
  aws elasticbeanstalk describe-environments \
    --region "$REGION" \
    --application-name "$EB_APPLICATION_NAME" \
    --environment-names "$EB_ENVIRONMENT_NAME" \
    --query 'Environments[0].CNAME' \
    --output text 2>/dev/null || true
}

find_website_url() {
  local bucket_name

  bucket_name=$(aws s3api list-buckets \
    --query "Buckets[?contains(Name, '-s3bucket')].Name | [0]" \
    --output text 2>/dev/null || true)

  if [ -n "$bucket_name" ] && [ "$bucket_name" != "None" ]; then
    printf 'http://%s.s3-website-%s.amazonaws.com\n' "$bucket_name" "$REGION"
  fi
}

check_eb_role() {
  if aws iam get-role --role-name aws-elasticbeanstalk-ec2-role > /dev/null 2>&1; then
    echo "    Elastic Beanstalk role found: aws-elasticbeanstalk-ec2-role"
  else
    echo "    WARNING: aws-elasticbeanstalk-ec2-role was not found. Task 9 may fail until the lab creates it."
  fi
}

echo ""
echo "==> [Task 1] Discovering the LabIDE instance..."
read -r LABIDE_ID LABIDE_PUBLIC_IP LABIDE_VPC_ID IDE_SUBNET_ID IDE_AZ LABIDE_SG <<< "$(find_labide_info)"
require_value "$LABIDE_ID" "LabIDE instance ID"
require_value "$LABIDE_PUBLIC_IP" "LabIDE public IP"
require_value "$LABIDE_VPC_ID" "LabIDE VPC ID"
require_value "$IDE_SUBNET_ID" "LabIDE subnet ID"
require_value "$IDE_AZ" "LabIDE Availability Zone"
require_value "$LABIDE_SG" "LabIDE security group ID"
echo "    LabIDE: $LABIDE_ID ($LABIDE_PUBLIC_IP)"
echo "    VPC:    $LABIDE_VPC_ID"
echo "    Subnet: $IDE_SUBNET_ID ($IDE_AZ)"
echo "    SG:     $LABIDE_SG"

echo ""
echo "==> [Task 2] Ensuring the second subnet exists..."
ensure_extra_subnet
ensure_public_route_table_association

echo ""
echo "==> [Task 3] Ensuring Aurora Serverless is ready..."
RDS_ENGINE_VERSION=$(select_rds_engine_version)
if [ -n "$RDS_ENGINE_VERSION" ]; then
  echo "    Aurora engine version selected: $RDS_ENGINE_VERSION"
else
  echo "    Aurora engine version selected: default AWS version"
fi
ensure_rds_subnet_group
ensure_rds_cluster_and_instance
echo "    Database endpoint: $DB_ENDPOINT"
echo "    Database SG:       $DB_SECURITY_GROUP_ID"

echo ""
echo "==> [Task 5] Ensuring required security group rules..."
MY_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '\r\n')
require_value "$MY_IP" "your public IP"
echo "    Your public IP: $MY_IP"
ensure_port_8000_for_my_ip
ensure_mysql_self_reference

echo ""
echo "==> [Task 8] Checking the Elastic Beanstalk role..."
check_eb_role

echo ""
echo "==> Preparing the LabIDE helper..."
HELPER_BUCKET=$(create_staging_bucket)
generate_labide_script
upload_helper_script
echo "    Helper bucket: s3://$HELPER_BUCKET"
echo "    Helper script: s3://$HELPER_BUCKET/$HELPER_OBJECT"

echo ""
echo "========================================================="
echo "Lab 8.2 Run Order"
echo "========================================================="
echo "1. Open Details -> LabIDEURL in your browser."
echo "2. Log in with Details -> LabIDEPassword."
echo "3. Open a terminal inside LabIDE / code-server."
echo "4. Run these exact commands in LabIDE:"
echo ""
echo 'ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)'
echo 'REGION=$(aws configure get region 2>/dev/null || echo us-east-1)'
echo "aws s3 cp \"s3://$HELPER_BUCKET/$HELPER_OBJECT\" /tmp/lab8_2.sh && bash /tmp/lab8_2.sh"
echo ""
echo "Do NOT run the helper in CloudShell."
echo "Do NOT run it in the AWS Academy embedded terminal."
echo ""
echo "The helper will stop twice for manual grader-sensitive steps:"
echo "  Task 6: AWS console -> RDS Query Editor"
echo "  Task 7: second LabIDE terminal for mysql/source commands"
echo ""
echo "During Task 6 it will tell you to open:"
echo "http://$LABIDE_PUBLIC_IP:8000/suppliers"
echo "Add one supplier there after the Query Editor SQL, then return to LabIDE and press ENTER."
echo ""
echo "Wait for this exact line in LabIDE before coming back:"
echo "=== Lab 8.2 LabIDE setup COMPLETE ==="
echo "========================================================="
echo ""
read -rp "Press ENTER after the LabIDE helper reports COMPLETE..."

REPOSITORY_URI=$(find_repository_uri)
EB_URL=$(find_eb_url)
WEBSITE_URL=$(find_website_url)

if [ -n "$EB_URL" ] && [ "$EB_URL" != "None" ]; then
  EB_URL="http://$EB_URL"
else
  EB_URL=""
fi

write_local_values_file

echo ""
echo "==> Collected values"
echo "    File:                ./lab8_2_values.txt"
echo "    Database endpoint:   $DB_ENDPOINT"
echo "    Repository URI:      ${REPOSITORY_URI:-not found}"
echo "    Elastic Beanstalk:   ${EB_URL:-not found}"
echo "    WebsiteURL:          ${WEBSITE_URL:-not found}"

echo ""
echo "==> Remaining manual checks"
echo "    Task 8 review only: IAM policy aws-elasticbeanstalk-ec2-instance-policy and role aws-elasticbeanstalk-ec2-role"
if [ -n "$EB_URL" ]; then
  echo "    Task 9 browser checks:"
  echo "      ${EB_URL}/suppliers"
  echo "      ${EB_URL}/beans"
  echo "      ${EB_URL}/beans.json"
fi

echo ""
echo "========================================================="
echo "*** ACTION REQUIRED BEFORE SUBMITTING — TASK 10 GRADE ***"
echo "========================================================="
echo ""
echo "  You MUST configure the API Gateway proxy NOW or you"
echo "  will lose points on Task 10."
echo ""
echo "  Steps:"
echo "  1. Open AWS Console -> API Gateway -> $API_NAME"
echo "  2. Select the top-level '/' resource."
echo "  3. Choose Create resource:"
echo "       Resource Name: bean_products"
echo "       Enable CORS: YES (check the box)"
echo "  4. Select /bean_products, choose Create method:"
echo "       Method type: GET"
echo "       Integration type: HTTP"
echo "       HTTP proxy integration: ON"
echo "       HTTP method: GET"
if [ -n "$EB_URL" ]; then
  echo "       Endpoint URL: ${EB_URL}/beans.json"
else
  echo "       Endpoint URL: http://<Elastic-Beanstalk-URL>/beans.json"
fi
echo "  5. Choose Create method."
echo "  6. Select the top-level '/' resource -> Deploy API:"
echo "       Stage: prod -> Deploy"
if [ -n "$WEBSITE_URL" ]; then
  echo "  7. Open $WEBSITE_URL -> Buy Coffee"
  echo "     Verify that coffee bean inventory loads (not 'coming soon')."
else
  echo "  7. Open the cafe WebsiteURL -> Buy Coffee"
  echo "     Verify that coffee bean inventory loads (not 'coming soon')."
fi
echo ""
echo "  Do NOT submit the lab until Buy Coffee shows inventory."
echo "========================================================="
echo ""
read -rp "Press ENTER only after Task 10 is done and Buy Coffee shows inventory..."

echo ""
echo "==> Lab 8.2 driver is ready."
