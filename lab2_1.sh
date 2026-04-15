#!/bin/bash
# Lab 2.1: Exploring AWS CloudShell and IDE
# Automates all CLI/SDK tasks from the lab instructions

source ./common.sh

set -e  # Exit on error

cleanup() {
  rm -f list-buckets.py index.html
}
trap cleanup EXIT

echo "==> Verifying AWS CLI installation..."
aws --version

echo ""
echo "==> Listing S3 buckets..."
aws s3 ls

# Detect the sample bucket automatically
BUCKET_NAME=$(aws s3 ls | grep 'samplebucket' | awk '{print $3}')

if [ -z "$BUCKET_NAME" ]; then
  echo "ERROR: Could not find a bucket with 'sample-bucket' in its name."
  echo "Please set BUCKET_NAME manually and re-run."
  exit 1
fi

echo ""
echo "==> Found bucket: $BUCKET_NAME"

# -------------------------------------------------------
# Task 1: Create and upload list-buckets.py
# -------------------------------------------------------

echo ""
echo "==> Creating list-buckets.py..."
cat > list-buckets.py << 'EOF'
import boto3

session = boto3.Session()
s3_client = session.client('s3')
b = s3_client.list_buckets()
for item in b['Buckets']:
    print(item['Name'])
EOF

echo "==> Uploading list-buckets.py to S3..."
aws s3 cp list-buckets.py s3://$BUCKET_NAME/list-buckets.py

# -------------------------------------------------------
# Task 2: Download list-buckets.py from S3 and run it
# -------------------------------------------------------

echo ""
echo "==> Downloading list-buckets.py from S3..."
aws s3 cp s3://$BUCKET_NAME/list-buckets.py .

echo ""
echo "==> Installing boto3 (SDK for Python)..."
pip3 install boto3 -q

echo ""
echo "==> Running list-buckets.py..."
python3 list-buckets.py

# -------------------------------------------------------
# Task 2: Create index.html and upload it to S3
# -------------------------------------------------------

echo ""
echo "==> Creating index.html..."
cat > index.html << 'EOF'
<body> Hello World. </body>
EOF

echo "==> Uploading index.html to S3..."
aws s3 cp index.html s3://$BUCKET_NAME/index.html

echo ""
echo "==> All tasks completed successfully!"
echo "    Bucket: $BUCKET_NAME"
echo "    Files uploaded: list-buckets.py, index.html"

# -------------------------------------------------------
# Cleanup: remove locally created files
# -------------------------------------------------------
echo ""
echo "==> Cleaning up local files..."
rm -f list-buckets.py index.html
echo "    Done."

