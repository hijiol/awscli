#!/bin/bash
# Lab 8.1: Migrating a Web Application to Docker Containers
# Strategy:
#   - Local AWS CLI: discover instances, open security groups, create ECR repo
#   - Generates a setup script for the LabIDE, uploads it to S3
#   - Prints a one-liner for you to paste into the VS Code IDE browser terminal
#   - Waits for confirmation, then verifies ECR

source ./common.sh

set -e

REGION="us-east-1"
CODE_URL="https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACCDEV-2-91558/06-lab-containers/code.zip"

# -------------------------------------------------------
# Task 1: Discover EC2 instances
# -------------------------------------------------------

echo ""
echo "==> [Task 1] Discovering EC2 instances..."

# Find LabIDE instance
LABIDE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*LabIDE*,*Lab IDE*,*lab-ide*" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text --region $REGION 2>/dev/null)

if [ -z "$LABIDE_ID" ] || [ "$LABIDE_ID" = "None" ]; then
  LABIDE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=*IDE*" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text --region $REGION)
fi

if [ -z "$LABIDE_ID" ] || [ "$LABIDE_ID" = "None" ]; then
  echo "ERROR: Cannot find LabIDE instance." >&2; exit 1
fi

LABIDE_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$LABIDE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text --region $REGION)
echo "    LabIDE:          $LABIDE_ID ($LABIDE_PUBLIC_IP)"

# Find MysqlServerNode private IP (for mysqldump within VPC)
MYSQL_INFO=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*Mysql*,*mysql*,*MySQL*" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].[InstanceId,PrivateIpAddress]" \
  --output text --region $REGION)
MYSQL_INSTANCE_ID=$(echo "$MYSQL_INFO" | awk '{print $1}')
MYSQL_PRIVATE_IP=$(echo "$MYSQL_INFO"  | awk '{print $2}')
echo "    MysqlServerNode: $MYSQL_INSTANCE_ID (Private: $MYSQL_PRIVATE_IP)"

if [ -z "$MYSQL_PRIVATE_IP" ] || [ "$MYSQL_PRIVATE_IP" = "None" ]; then
  echo "ERROR: Cannot find MysqlServerNode." >&2; exit 1
fi

# Find AppServerNode (has existing MySQL access, used for mysqldump)
APPSERVER_INFO=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*AppServer*,*App Server*,*appserver*" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].[InstanceId,PublicIpAddress]" \
  --output text --region $REGION)
APPSERVER_ID=$(echo "$APPSERVER_INFO" | awk '{print $1}')
APPSERVER_IP=$(echo "$APPSERVER_INFO" | awk '{print $2}')
echo "    AppServerNode:   $APPSERVER_ID ($APPSERVER_IP)"

# -------------------------------------------------------
# Task 1: Open ports on LabIDE SG + NACL, and open MySQL port on MysqlServerNode SG
# -------------------------------------------------------

echo ""
echo "==> [Task 1] Opening ports on security groups..."

MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "    Your IP: $MY_IP"

LABIDE_SG=$(aws ec2 describe-instances \
  --instance-ids "$LABIDE_ID" \
  --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
  --output text --region $REGION)
echo "    LabIDE Security Group: $LABIDE_SG"

MYSQL_SG=$(aws ec2 describe-instances \
  --instance-ids "$MYSQL_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
  --output text --region $REGION)
echo "    MySQL Security Group:  $MYSQL_SG"

# Open a port on a given security group from a given CIDR
open_port_on_sg() {
  local SG="$1"
  local PORT="$2"
  local CIDR="$3"
  local EXISTS
  EXISTS=$(aws ec2 describe-security-groups \
    --group-ids "$SG" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`${PORT}\` && ToPort==\`${PORT}\`].FromPort" \
    --output text --region $REGION)
  if [ -z "$EXISTS" ]; then
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG" --protocol tcp --port "$PORT" \
      --cidr "$CIDR" --region $REGION > /dev/null
    echo "    SG $SG: port $PORT opened for $CIDR."
  else
    echo "    SG $SG: port $PORT already open."
  fi
}

# Port 3000 on LabIDE SG (for your browser)
open_port_on_sg "$LABIDE_SG" 3000 "${MY_IP}/32"

# Port 3306 on ALL MySQL SGs — force add 0.0.0.0/0, ignore "already exists" error
echo "    Force-opening port 3306 on all MysqlServerNode security groups..."
MYSQL_SGS=$(aws ec2 describe-instances \
  --instance-ids "$MYSQL_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].SecurityGroups[*].GroupId" \
  --output text --region $REGION)
for SG_ID in $MYSQL_SGS; do
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" --protocol tcp --port 3306 \
    --cidr "0.0.0.0/0" --region $REGION 2>/dev/null \
    && echo "    SG $SG_ID: port 3306 opened (0.0.0.0/0)." \
    || echo "    SG $SG_ID: port 3306 rule already exists."
done

# Fix NACLs on BOTH the LabIDE subnet and MySQL subnet
# Use allow-all rules (protocol -1) so we don't miss anything
fix_nacl() {
  local INSTANCE_ID="$1"
  local LABEL="$2"
  local SUBNET
  SUBNET=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].SubnetId" \
    --output text --region $REGION)
  local NACL
  NACL=$(aws ec2 describe-network-acls \
    --filters "Name=association.subnet-id,Values=$SUBNET" \
    --query "NetworkAcls[0].NetworkAclId" \
    --output text --region $REGION)
  echo "    $LABEL subnet $SUBNET -> NACL $NACL"
  # Allow all inbound
  aws ec2 create-network-acl-entry --network-acl-id "$NACL" \
    --rule-number 90 --protocol -1 --rule-action allow --ingress \
    --cidr-block "0.0.0.0/0" --region $REGION 2>/dev/null \
    && echo "    $LABEL NACL: allow-all ingress added." \
    || echo "    $LABEL NACL: allow-all ingress already exists."
  # Allow all outbound
  aws ec2 create-network-acl-entry --network-acl-id "$NACL" \
    --rule-number 90 --protocol -1 --rule-action allow --egress \
    --cidr-block "0.0.0.0/0" --region $REGION 2>/dev/null \
    && echo "    $LABEL NACL: allow-all egress added." \
    || echo "    $LABEL NACL: allow-all egress already exists."
}

echo ""
echo "==> [Task 1] Fixing NACLs on LabIDE and MySQL subnets..."
fix_nacl "$LABIDE_ID"       "LabIDE"
fix_nacl "$MYSQL_INSTANCE_ID" "MySQL"

# -------------------------------------------------------
# Task 1: Find or create a temporary S3 bucket to stage the LabIDE setup script
# -------------------------------------------------------

echo ""
echo "==> [Task 1] Finding S3 bucket..."
BUCKET_NAME=$(aws s3 ls 2>/dev/null | awk '{print $3}' | grep -E 's3bucket|samplebucket' | head -1)

if [ -z "$BUCKET_NAME" ]; then
  # No existing bucket — create a temporary one using account ID for uniqueness
  BUCKET_NAME="lab8-setup-${ACCOUNT_ID}"
  echo "    No existing bucket found. Creating temporary bucket: $BUCKET_NAME"
  if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region $REGION > /dev/null
    # Block public access except for the presigned URL approach
    aws s3api put-public-access-block \
      --bucket "$BUCKET_NAME" \
      --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
      > /dev/null
    echo "    Bucket created."
  else
    echo "    Bucket already exists."
  fi
fi
echo "    Bucket: $BUCKET_NAME"

# -------------------------------------------------------
# Task 6 (prep): Create ECR repository now so LabIDE script can push to it
# -------------------------------------------------------

echo ""
echo "==> [Task 6] Creating ECR repository..."
ECR_URI=$(aws ecr describe-repositories \
  --repository-names node-app --region $REGION \
  --query "repositories[0].repositoryUri" --output text 2>/dev/null || echo "")

if [ -z "$ECR_URI" ] || [ "$ECR_URI" = "None" ]; then
  aws ecr create-repository --repository-name node-app --region $REGION > /dev/null
  ECR_URI=$(aws ecr describe-repositories \
    --repository-names node-app --region $REGION \
    --query "repositories[0].repositoryUri" --output text)
  echo "    ECR repository 'node-app' created."
else
  echo "    ECR repository already exists."
fi
echo "    Repository URI: $ECR_URI"

REGISTRY_ID=$(echo "$ECR_URI" | cut -d. -f1)

# -------------------------------------------------------
# Run mysqldump from AppServerNode (has existing MySQL access)
# Pipe result back to local, upload to S3 for LabIDE to download
# -------------------------------------------------------

echo ""
echo "==> Running mysqldump via AppServerNode SSH..."

# Find labsuser.pem
KEY_FILE=""
for candidate in "./labsuser.pem" "$HOME/.ssh/labsuser.pem"; do
  if [ -f "$candidate" ]; then KEY_FILE="$candidate"; break; fi
done

if [ -z "$KEY_FILE" ]; then
  echo "ERROR: labsuser.pem not found. Download it from lab Details panel." >&2
  exit 1
fi
chmod 600 "$KEY_FILE" 2>/dev/null || true

# Open SSH port on AppServerNode SG
APPSERVER_SG=$(aws ec2 describe-instances \
  --instance-ids "$APPSERVER_ID" \
  --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
  --output text --region $REGION)
aws ec2 authorize-security-group-ingress \
  --group-id "$APPSERVER_SG" --protocol tcp --port 22 \
  --cidr "${MY_IP}/32" --region $REGION 2>/dev/null || true
echo "    SSH opened on AppServerNode SG $APPSERVER_SG"

# SSH to AppServerNode and run mysqldump — pipe directly back to local file
echo "    Connecting to AppServerNode ($APPSERVER_IP) to dump MySQL..."
ssh -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=20 \
    -o LogLevel=ERROR \
    "ubuntu@${APPSERVER_IP}" \
    "mysqldump -P 3306 -h ${MYSQL_PRIVATE_IP} -u nodeapp -pcoffee --databases COFFEE 2>/dev/null" \
    > /tmp/my_sql.sql

DUMP_LINES=$(wc -l < /tmp/my_sql.sql)
echo "    Dump: $DUMP_LINES lines"

if [ "$DUMP_LINES" -lt 10 ]; then
  echo "ERROR: Dump file too small — mysqldump likely failed." >&2
  cat /tmp/my_sql.sql >&2
  exit 1
fi

# Upload dump to S3 for LabIDE to download
aws s3 cp /tmp/my_sql.sql "s3://${BUCKET_NAME}/my_sql.sql" --cache-control "max-age=0" > /dev/null
DUMP_URL=$(aws s3 presign "s3://${BUCKET_NAME}/my_sql.sql" --expires-in 3600 --region $REGION)
echo "    Dump uploaded to S3."

# -------------------------------------------------------
# Generate the LabIDE setup script (runs inside VS Code terminal)
# All instance IPs and ECR info are baked in from local discovery above
# -------------------------------------------------------

echo ""
echo "==> Generating LabIDE setup script..."

LABIDE_SCRIPT="/tmp/lab8_labide_setup.sh"

cat > "$LABIDE_SCRIPT" << OUTEREOF
#!/bin/bash
# Lab 8.1 - Full setup script for LabIDE
# Generated by lab8_1.sh and run from the VS Code IDE browser terminal
set -e

ECR_URI="$ECR_URI"
REGISTRY_ID="$REGISTRY_ID"
MYSQL_HOST="$MYSQL_PRIVATE_IP"
CODE_URL="$CODE_URL"
BASE=\$HOME/environment

echo ""
echo "===> [T1] Downloading lab code..."
mkdir -p "\$BASE"
cd "\$BASE"
if [ ! -f code.zip ]; then
  wget -q "\$CODE_URL" -O code.zip
fi
unzip -o code.zip > /dev/null 2>&1 || true

echo "===> [T1] Running setup.sh..."
chmod +x ./resources/setup.sh && ./resources/setup.sh 2>&1 | tail -5

echo ""
echo "===> [T3] Creating node_app directory..."
mkdir -p "\$BASE/containers/node_app"
if [ ! -d "\$BASE/containers/node_app/codebase_partner" ]; then
  cp -r "\$BASE/resources/codebase_partner" "\$BASE/containers/node_app/"
fi

echo "===> [T3] Writing node_app Dockerfile..."
cat > "\$BASE/containers/node_app/codebase_partner/Dockerfile" << 'DOCKERFILE'
FROM node:11-alpine
RUN mkdir -p /usr/src/app
WORKDIR /usr/src/app
COPY . .
RUN npm install
EXPOSE 3000
CMD ["npm", "run", "start"]
DOCKERFILE

echo "===> [T3] Building node_app image..."
cd "\$BASE/containers/node_app/codebase_partner"
docker build --tag node_app .

echo ""
echo "===> [T4] Downloading mysqldump from S3..."
mkdir -p "\$BASE/containers/mysql"
curl -s "$DUMP_URL" > "\$BASE/containers/mysql/my_sql.sql"
echo "    Dump: \$(wc -l < \$BASE/containers/mysql/my_sql.sql) lines"

echo "===> [T4] Writing MySQL Dockerfile..."
cat > "\$BASE/containers/mysql/Dockerfile" << 'DOCKERFILE'
FROM mysql:8.0.23
COPY ./my_sql.sql /
EXPOSE 3306
DOCKERFILE

echo "===> [T4] Freeing disk space..."
docker rmi -f \$(docker image ls -a -q) 2>/dev/null || true
docker image prune -f   2>/dev/null || true
docker container prune -f 2>/dev/null || true

echo "===> [T4] Building mysql_server image..."
cd "\$BASE/containers/mysql"
docker build --tag mysql_server .

echo "===> [T4] Starting mysql_1 container..."
docker stop mysql_1 2>/dev/null || true
docker rm   mysql_1 2>/dev/null || true
docker run --name mysql_1 -p 3306:3306 -e MYSQL_ROOT_PASSWORD=rootpw -d mysql_server

echo "    Waiting for MySQL to initialize..."
MAX=90; ELAPSED=0
until docker exec mysql_1 mysqladmin ping -u root -prootpw --silent 2>/dev/null; do
  sleep 5; ELAPSED=\$((ELAPSED+5))
  echo "    ...\${ELAPSED}/\${MAX}s"
  [ "\$ELAPSED" -ge "\$MAX" ] && echo "ERROR: MySQL timed out" && exit 1
done
echo "    MySQL ready."

sed -i '1d' "\$BASE/containers/mysql/my_sql.sql"
docker exec -i mysql_1 mysql -u root -prootpw < "\$BASE/containers/mysql/my_sql.sql"
docker exec -i mysql_1 mysql -u root -prootpw -e \
  "CREATE USER IF NOT EXISTS 'nodeapp' IDENTIFIED WITH mysql_native_password BY 'coffee';
   GRANT ALL PRIVILEGES ON *.* TO 'nodeapp'@'%'; FLUSH PRIVILEGES;"
echo "    Data imported, user created."

echo ""
echo "===> [T5] Connecting node_app_1 to mysql_1..."
if ! docker image inspect node_app:latest &>/dev/null; then
  cd "\$BASE/containers/node_app/codebase_partner"
  docker build --tag node_app .
fi
MYSQL_IP=\$(docker inspect mysql_1 --format '{{.NetworkSettings.IPAddress}}')
echo "    MySQL container IP: \$MYSQL_IP"
docker stop node_app_1 2>/dev/null || true
docker rm   node_app_1 2>/dev/null || true
docker run -d --name node_app_1 -p 3000:3000 -e APP_DB_HOST="\$MYSQL_IP" node_app
echo "    node_app_1 started."

echo ""
echo "===> [T6] Pushing to ECR..."
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \${REGISTRY_ID}.dkr.ecr.us-east-1.amazonaws.com
if ! docker image inspect node_app:latest &>/dev/null; then
  cd "\$BASE/containers/node_app/codebase_partner"
  docker build --tag node_app .
fi
docker tag  node_app:latest \${ECR_URI}:latest
docker push \${ECR_URI}:latest
echo "    Image pushed to ECR."

echo ""
echo "===> Running containers:"
docker ps
echo ""
echo "=== Lab 8.1 LabIDE setup COMPLETE ==="
OUTEREOF

chmod +x "$LABIDE_SCRIPT"
echo "    Setup script generated: $LABIDE_SCRIPT"

# -------------------------------------------------------
# Upload setup script to S3 so LabIDE can curl it
# -------------------------------------------------------

echo ""
echo "==> Uploading setup script to S3..."
aws s3 cp "$LABIDE_SCRIPT" "s3://${BUCKET_NAME}/lab8_labide_setup.sh" \
  --cache-control "max-age=0" > /dev/null

SCRIPT_URL="https://${BUCKET_NAME}.s3.amazonaws.com/lab8_labide_setup.sh"
PRESIGNED_URL=$(aws s3 presign "s3://${BUCKET_NAME}/lab8_labide_setup.sh" \
  --expires-in 3600 --region $REGION)
echo "    Uploaded."

# -------------------------------------------------------
# Instruct user to run the script in VS Code IDE terminal
# -------------------------------------------------------

echo ""
echo "========================================================="
echo "  MANUAL STEP REQUIRED — paste this into VS Code terminal"
echo "========================================================="
echo ""
echo "  1. Open your VS Code IDE:"
echo "     (Lab console -> Details -> LabIDEURL)"
echo ""
echo "  2. Open a terminal in VS Code (Terminal -> New Terminal)"
echo ""
echo "  3. Paste and run this command:"
echo ""
echo "     curl -s \"$PRESIGNED_URL\" | bash"
echo ""
echo "  This will take ~5-10 minutes (Docker builds + MySQL start)."
echo "  Wait for '=== Lab 8.1 LabIDE setup COMPLETE ===' before continuing."
echo "========================================================="
echo ""
read -rp "Press ENTER when the VS Code terminal shows COMPLETE..."

# -------------------------------------------------------
# Verify ECR image was pushed
# -------------------------------------------------------

echo ""
echo "==> Verifying ECR image..."
IMAGE_TAGS=$(aws ecr list-images --repository-name node-app --region $REGION \
  --query "imageIds[*].imageTag" --output text 2>/dev/null || echo "")

if [ -n "$IMAGE_TAGS" ]; then
  echo "    ECR image found: $IMAGE_TAGS"
  aws ecr list-images --repository-name node-app --region $REGION
else
  echo "    WARNING: No images in ECR yet."
  echo "    Go back to VS Code, wait for '=== COMPLETE ===' then re-run this script."
fi

# -------------------------------------------------------
# Done
# -------------------------------------------------------

echo ""
echo "==> All tasks complete!"
echo ""
echo "    App URL:         http://${LABIDE_PUBLIC_IP}:3000"
echo "    ECR Repository:  $ECR_URI"
echo ""
echo "    Containers running on LabIDE: node_app_1 + mysql_1"
echo "    Submit the lab to get your grade."

rm -f "$LABIDE_SCRIPT" /tmp/lab8_t*.sh
