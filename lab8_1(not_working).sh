#!/bin/bash
# Lab 8.1: Migrating a Web Application to Docker Containers

source ./common.sh
set -e

REGION="us-east-1"
CODE_URL="https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACCDEV-2-91558/06-lab-containers/code.zip"
LABIDE_SCRIPT="/tmp/lab8_labide_setup.sh"

cleanup() {
  rm -f "$LABIDE_SCRIPT"
}
trap cleanup EXIT

# -------------------------------------------------------
# Task 1: Discover EC2 instances
# -------------------------------------------------------

echo ""
echo "==> [Task 1] Discovering EC2 instances..."

LABIDE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*LabIDE*,*Lab IDE*,*lab-ide*,*IDE*" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text --region $REGION)
[ "$LABIDE_ID" = "None" ] && LABIDE_ID=""

if [ -z "$LABIDE_ID" ]; then
  echo "ERROR: Cannot find LabIDE instance." >&2; exit 1
fi

LABIDE_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$LABIDE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text --region $REGION)
echo "    LabIDE: $LABIDE_ID ($LABIDE_PUBLIC_IP)"

MYSQL_INFO=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*Mysql*,*mysql*,*MySQL*" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].[InstanceId,PublicIpAddress]" \
  --output text --region $REGION)
MYSQL_INSTANCE_ID=$(echo "$MYSQL_INFO" | awk '{print $1}')
MYSQL_PUBLIC_IP=$(echo "$MYSQL_INFO"  | awk '{print $2}')
echo "    MysqlServerNode: $MYSQL_INSTANCE_ID ($MYSQL_PUBLIC_IP)"

if [ -z "$MYSQL_PUBLIC_IP" ] || [ "$MYSQL_PUBLIC_IP" = "None" ]; then
  echo "ERROR: Cannot find MysqlServerNode." >&2; exit 1
fi

# -------------------------------------------------------
# Task 1: Open security groups and fix NACLs
# -------------------------------------------------------

echo ""
echo "==> [Task 1] Configuring security groups..."

MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "    Your IP: $MY_IP"

LABIDE_SG=$(aws ec2 describe-instances \
  --instance-ids "$LABIDE_ID" \
  --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
  --output text --region $REGION)

# Port 3000 on LabIDE SG (browser access to the app) — check for current IP specifically
EXISTS=$(aws ec2 describe-security-groups \
  --group-ids "$LABIDE_SG" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`3000\`].IpRanges[?CidrIp=='${MY_IP}/32'].CidrIp" \
  --output text --region $REGION)
if [ -z "$EXISTS" ] || [ "$EXISTS" = "None" ]; then
  aws ec2 authorize-security-group-ingress \
    --group-id "$LABIDE_SG" --protocol tcp --port 3000 \
    --cidr "${MY_IP}/32" --region $REGION 2>/dev/null \
    && echo "    Port 3000 opened for ${MY_IP} on LabIDE SG $LABIDE_SG." \
    || echo "    Port 3000 rule already exists."
else
  echo "    Port 3000 already open for ${MY_IP}."
fi

# Port 3306 on all MySQL SGs (for mysqldump from LabIDE)
MYSQL_SGS=$(aws ec2 describe-instances \
  --instance-ids "$MYSQL_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].SecurityGroups[*].GroupId" \
  --output text --region $REGION)
for SG_ID in $MYSQL_SGS; do
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" --protocol tcp --port 3306 \
    --cidr "0.0.0.0/0" --region $REGION 2>/dev/null \
    && echo "    Port 3306 opened on MySQL SG $SG_ID." \
    || echo "    Port 3306 already open on MySQL SG $SG_ID."
done

echo ""
echo "==> [Task 1] Fixing NACLs..."
fix_nacl() {
  local INSTANCE_ID="$1" LABEL="$2"
  local SUBNET NACL
  SUBNET=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].SubnetId" \
    --output text --region $REGION)
  NACL=$(aws ec2 describe-network-acls \
    --filters "Name=association.subnet-id,Values=$SUBNET" \
    --query "NetworkAcls[0].NetworkAclId" \
    --output text --region $REGION)
  echo "    $LABEL -> NACL $NACL"
  # Delete rule 1 first (ignore errors) then recreate as allow-all.
  # This ensures we don't silently keep an existing DENY rule at that number.
  aws ec2 delete-network-acl-entry --network-acl-id "$NACL" \
    --rule-number 1 --ingress --region $REGION 2>/dev/null || true
  aws ec2 delete-network-acl-entry --network-acl-id "$NACL" \
    --rule-number 1 --egress --region $REGION 2>/dev/null || true
  aws ec2 create-network-acl-entry --network-acl-id "$NACL" \
    --rule-number 1 --protocol -1 --rule-action allow --ingress \
    --cidr-block "0.0.0.0/0" --region $REGION 2>/dev/null \
    && echo "    $LABEL NACL: allow-all ingress added (rule 1)." \
    || echo "    $LABEL NACL: ingress rule already exists."
  aws ec2 create-network-acl-entry --network-acl-id "$NACL" \
    --rule-number 1 --protocol -1 --rule-action allow --egress \
    --cidr-block "0.0.0.0/0" --region $REGION 2>/dev/null \
    && echo "    $LABEL NACL: allow-all egress added (rule 1)." \
    || echo "    $LABEL NACL: egress rule already exists."
}
fix_nacl "$LABIDE_ID"         "LabIDE"
fix_nacl "$MYSQL_INSTANCE_ID" "MySQL"

# -------------------------------------------------------
# Task 1: Find or create S3 bucket to stage the setup script
# -------------------------------------------------------

echo ""
echo "==> [Task 1] Finding S3 bucket..."
BUCKET_NAME=$(aws s3 ls 2>/dev/null | awk '{print $3}' | grep -E 's3bucket|samplebucket' | head -1)

if [ -z "$BUCKET_NAME" ]; then
  BUCKET_NAME="lab8-setup-${ACCOUNT_ID}"
  if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region $REGION > /dev/null
    echo "    Created temporary bucket: $BUCKET_NAME"
  else
    echo "    Bucket already exists."
  fi
fi
echo "    Bucket: $BUCKET_NAME"

# -------------------------------------------------------
# Task 6 prep: Create ECR repository
# -------------------------------------------------------

echo ""
echo "==> [Task 6] Creating ECR repository..."
ECR_URI=$(aws ecr describe-repositories \
  --repository-names node-app --region $REGION \
  --query "repositories[0].repositoryUri" --output text 2>/dev/null || true)
[ "$ECR_URI" = "None" ] && ECR_URI=""

if [ -z "$ECR_URI" ]; then
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
# Generate LabIDE setup script
# All instance IPs and ECR info are baked in at generation time
# -------------------------------------------------------

echo ""
echo "==> Generating LabIDE setup script..."

cat > "$LABIDE_SCRIPT" << OUTEREOF
#!/bin/bash
# Lab 8.1 - LabIDE setup script (generated by lab8_1.sh)
set -e

ECR_URI="${ECR_URI}"
REGISTRY_ID="${REGISTRY_ID}"
MYSQL_PUBLIC_IP="${MYSQL_PUBLIC_IP}"
BASE=\$HOME/environment

# -------------------------------------------------------
# Task 1: Download and extract lab files, run setup
# -------------------------------------------------------

echo ""
echo "===> [T1] Downloading lab code..."
mkdir -p "\$BASE" && cd "\$BASE"
if [ ! -f code.zip ]; then
  wget -q "${CODE_URL}" -O code.zip
fi
unzip -o code.zip > /dev/null 2>&1 || true

echo "===> [T1] Running setup.sh..."
chmod +x resources/setup.sh && resources/setup.sh 2>&1 | tail -5

# -------------------------------------------------------
# Task 3: Build node_app Docker image and run container
# -------------------------------------------------------

echo ""
echo "===> [T3] Setting up node_app directory..."
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

# -------------------------------------------------------
# Task 4: Dump MySQL, build mysql_server image, run container
# -------------------------------------------------------

echo ""
echo "===> [T4] Running mysqldump from LabIDE -> MysqlServerNode..."
mkdir -p "\$BASE/containers/mysql"
mysqldump -P 3306 -h "\$MYSQL_PUBLIC_IP" -u nodeapp -pcoffee \
  --databases COFFEE > "\$BASE/containers/mysql/my_sql.sql"
echo "    Dump: \$(wc -l < \$BASE/containers/mysql/my_sql.sql) lines"

echo "===> [T4] Writing mysql Dockerfile..."
cat > "\$BASE/containers/mysql/Dockerfile" << 'DOCKERFILE'
FROM mysql:8.0.23
COPY ./my_sql.sql /
EXPOSE 3306
DOCKERFILE

echo "===> [T4] Freeing disk space (preserving node_app image)..."
docker rmi -f \$(docker images --filter "reference=node*" --filter "dangling=true" -q) 2>/dev/null || true
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
  [ "\$ELAPSED" -ge "\$MAX" ] && echo "ERROR: MySQL timed out." && exit 1
done
echo "    MySQL ready."

sed -i '1d' "\$BASE/containers/mysql/my_sql.sql"
docker exec -i mysql_1 mysql -u root -prootpw < "\$BASE/containers/mysql/my_sql.sql"
docker exec -i mysql_1 mysql -u root -prootpw -e \
  "CREATE USER IF NOT EXISTS 'nodeapp' IDENTIFIED WITH mysql_native_password BY 'coffee';
   GRANT ALL PRIVILEGES ON *.* TO 'nodeapp'@'%'; FLUSH PRIVILEGES;"
echo "    Data imported, nodeapp user created."

# -------------------------------------------------------
# Task 5: Reconnect node_app_1 to mysql_1 container
# -------------------------------------------------------

echo ""
echo "===> [T5] Starting node_app_1 connected to mysql_1..."
MYSQL_IP=\$(docker inspect mysql_1 --format '{{.NetworkSettings.IPAddress}}')
echo "    mysql_1 IP: \$MYSQL_IP"

docker stop node_app_1 2>/dev/null || true
docker rm   node_app_1 2>/dev/null || true
docker run -d --name node_app_1 -p 3000:3000 -e APP_DB_HOST="\$MYSQL_IP" node_app
echo "    node_app_1 started."

# -------------------------------------------------------
# Task 6: Push node_app image to ECR
# -------------------------------------------------------

echo ""
echo "===> [T6] Pushing node_app to ECR..."
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \${REGISTRY_ID}.dkr.ecr.us-east-1.amazonaws.com
docker tag  node_app:latest \${ECR_URI}:latest
docker push \${ECR_URI}:latest
echo "    Image pushed to ECR."

echo ""
echo "===> Running containers:"
docker ps

echo ""
echo "=== Lab 8.1 LabIDE setup COMPLETE ==="
echo "    App URL: http://\$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):3000"
OUTEREOF

chmod +x "$LABIDE_SCRIPT"

# -------------------------------------------------------
# Upload to S3 and print instructions
# -------------------------------------------------------

echo ""
echo "==> Uploading setup script to S3..."
aws s3 cp "$LABIDE_SCRIPT" "s3://${BUCKET_NAME}/lab8_labide_setup.sh" \
  --cache-control "max-age=0" > /dev/null

PRESIGNED_URL=$(aws s3 presign "s3://${BUCKET_NAME}/lab8_labide_setup.sh" \
  --expires-in 3600 --region $REGION)
echo "    Uploaded."

echo ""
echo "========================================================="
echo "  MANUAL STEP — paste this into the VS Code IDE terminal"
echo "========================================================="
echo ""
echo "  1. Open the LabIDE:  (Lab console -> Details -> LabIDEURL)"
echo "  2. Open a terminal:  Terminal -> New Terminal"
echo "  3. Paste and run:"
echo ""
echo "     curl -s \"$PRESIGNED_URL\" | bash"
echo ""
echo "  Takes ~5-10 min. Wait for '=== Lab 8.1 LabIDE setup COMPLETE ==='"
echo "========================================================="
echo ""
read -rp "Press ENTER when VS Code terminal shows COMPLETE..."

# -------------------------------------------------------
# Verify ECR image was pushed
# -------------------------------------------------------

echo ""
echo "==> Verifying ECR image..."
IMAGE_TAGS=$(aws ecr list-images --repository-name node-app --region $REGION \
  --query "imageIds[*].imageTag" --output text 2>/dev/null || true)
[ "$IMAGE_TAGS" = "None" ] && IMAGE_TAGS=""

if [ -n "$IMAGE_TAGS" ]; then
  echo "    ECR image found: $IMAGE_TAGS"
else
  echo "    WARNING: No image in ECR. Check the VS Code terminal output for errors."
fi

# -------------------------------------------------------
# Done
# -------------------------------------------------------

echo ""
echo "==> All tasks complete!"
echo ""
echo "    App URL:        http://${LABIDE_PUBLIC_IP}:3000"
echo "    ECR Repository: $ECR_URI"
echo ""
echo "    Containers running on LabIDE: node_app_1 + mysql_1"
echo "    Submit the lab to get your grade."
