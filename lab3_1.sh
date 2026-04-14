#!/bin/bash
# Lab 3.1: Working with Amazon S3
# Automates all CLI/SDK tasks from the lab instructions

source ./common.sh

set -e  # Exit on error

# --- Config ---
read -rp "Enter your lowercase initials: " INITIALS
DATE=$(date +%Y-%m-%d)
BUCKET_NAME="${INITIALS}-${DATE}-s3site"
REGION="us-east-1"
echo "    Bucket name will be: $BUCKET_NAME"
# --------------

echo "==> Verifying AWS CLI installation..."
aws --version

# -------------------------------------------------------
# Task 1: Install boto3 and download lab files
# -------------------------------------------------------

echo ""
echo "==> Installing boto3..."
pip3 install boto3 -q

if [ ! -f code.zip ]; then
  echo ""
  echo "==> Downloading lab code.zip..."
  curl -o code.zip "https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACCDEV-2-91558/02-lab-s3/code.zip"
  echo "==> Extracting code.zip..."
  unzip -o code.zip
else
  echo "==> code.zip already present, skipping download."
fi

# -------------------------------------------------------
# Task 2: Create S3 bucket
# -------------------------------------------------------

echo ""
echo "==> Checking if S3 bucket exists..."
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "    Bucket '$BUCKET_NAME' already exists, skipping creation."
else
  echo "==> Creating S3 bucket: $BUCKET_NAME..."
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
fi

echo ""
echo "==> Disabling block public access on bucket..."
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# -------------------------------------------------------
# Task 3: Create and apply bucket policy
# -------------------------------------------------------

echo ""
echo "==> Detecting your public IP address..."
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "    Your IP: $MY_IP"

echo ""
echo "==> Creating website_security_policy.json..."
cat > website_security_policy.json << EOF
{
    "Version": "2008-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}/*",
                "arn:aws:s3:::${BUCKET_NAME}"
            ],
            "Condition": {
                "IpAddress": {
                    "aws:SourceIp": [
                        "${MY_IP}/32"
                    ]
                }
            }
        },
        {
            "Sid": "DenyOneObjectIfRequestNotSigned",
            "Effect": "Deny",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::${BUCKET_NAME}/report.html",
            "Condition": {
                "StringNotEquals": {
                    "s3:authtype": "REST-QUERY-STRING"
                }
            }
        }
    ]
}
EOF

echo "==> Applying bucket policy..."
aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy file://website_security_policy.json

echo "    DONE"

# -------------------------------------------------------
# Task 4: Upload website files to S3
# -------------------------------------------------------

echo ""
echo "==> Uploading website files to S3..."
aws s3 cp resources/website s3://$BUCKET_NAME/ --recursive --cache-control "max-age=0"

# -------------------------------------------------------
# Done
# -------------------------------------------------------

echo ""
echo "==> All tasks completed successfully!"
echo ""
echo "    Bucket:      $BUCKET_NAME"
echo "    Allowed IP:  $MY_IP"
echo "    Website URL: https://${BUCKET_NAME}.s3.amazonaws.com/index.html"
echo ""
echo "    Open the URL above in your browser to test the website."
echo "    To test denial, run:"
echo "    curl https://${BUCKET_NAME}.s3.amazonaws.com/index.html"

# -------------------------------------------------------
# Cleanup: remove locally created files
# -------------------------------------------------------
echo ""
echo "==> Cleaning up local files..."
rm -f code.zip website_security_policy.json
rm -rf resources python_3 __pycache__
echo "    Done."
