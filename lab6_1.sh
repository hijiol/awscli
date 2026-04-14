#!/bin/bash
# Lab 6.1: Developing REST APIs with Amazon API Gateway
# Automates all CLI/SDK tasks from the lab instructions

source ./common.sh

set -e

REGION="us-east-1"

# -------------------------------------------------------
# Task 1: Setup
# -------------------------------------------------------

echo "==> Verifying AWS CLI..."
aws --version

echo ""
echo "==> Installing boto3..."
pip3 install boto3 -q

if [ ! -f code.zip ]; then
  echo ""
  echo "==> Downloading lab files..."
  curl -o code.zip "https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACCDEV-2-91558/04-lab-api/code.zip"
  echo "==> Extracting..."
  unzip -o code.zip
else
  echo "==> code.zip already present, skipping download."
  unzip -o code.zip -d . > /dev/null 2>&1 || true
fi

echo ""
echo "==> Detecting public IP..."
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "    Your IP: $MY_IP"

echo ""
echo "==> Detecting S3 bucket..."
BUCKET_NAME=$(aws s3 ls 2>/dev/null | awk '{print $3}' | grep 's3bucket\|samplebucket' | head -1)
if [ -z "$BUCKET_NAME" ]; then
  echo "    Could not auto-detect bucket."
  read -rp "    Enter your S3 bucket name (name only, no date prefix): " INPUT
  BUCKET_NAME=$(echo "$INPUT" | awk '{print $NF}')
fi
echo "    Bucket: $BUCKET_NAME"

echo ""
echo "==> Uploading website files to S3..."
aws s3 cp resources/website s3://$BUCKET_NAME/ --recursive --cache-control "max-age=0"

# -------------------------------------------------------
# Task 2: Create first API endpoint (GET /products)
# -------------------------------------------------------

echo ""
echo "==> [Task 2] Checking if ProductsApi already exists..."
API_ID=$(aws apigateway get-rest-apis --region $REGION \
  --query "items[?name=='ProductsApi'].id" --output text)

if [ -z "$API_ID" ]; then
  echo "==> Patching create_products_api.py..."
  sed -i "s|<FMI>|apigateway|g" python_3/create_products_api.py

  echo "==> Running create_products_api.py..."
  (cd python_3 && python3 create_products_api.py)

  API_ID=$(aws apigateway get-rest-apis --region $REGION \
    --query "items[?name=='ProductsApi'].id" --output text)
  echo "    API created: $API_ID"
else
  echo "    ProductsApi already exists: $API_ID, skipping creation."
fi

# -------------------------------------------------------
# Task 3: Create second API endpoint (GET /products/on_offer)
# -------------------------------------------------------

echo ""
echo "==> [Task 3] Getting /products resource ID..."
PRODUCTS_RESOURCE_ID=$(aws apigateway get-resources \
  --rest-api-id $API_ID --region $REGION \
  --query "items[?path=='/products'].id" --output text)
echo "    /products resource ID: $PRODUCTS_RESOURCE_ID"

ON_OFFER_EXISTS=$(aws apigateway get-resources \
  --rest-api-id $API_ID --region $REGION \
  --query "items[?path=='/products/on_offer'].id" --output text)

if [ -z "$ON_OFFER_EXISTS" ]; then
  echo "==> Patching create_on_offer_api.py..."
  sed -i "s|<FMI_1>|$API_ID|g"              python_3/create_on_offer_api.py
  sed -i "s|<FMI_2>|$PRODUCTS_RESOURCE_ID|g" python_3/create_on_offer_api.py

  echo "==> Running create_on_offer_api.py..."
  (cd python_3 && python3 create_on_offer_api.py)
  echo "    /products/on_offer created."
else
  echo "    /products/on_offer already exists, skipping."
fi

# -------------------------------------------------------
# Task 4: Create third API endpoint (POST /create_report)
# -------------------------------------------------------

echo ""
echo "==> [Task 4] Checking if /create_report exists..."
CREATE_REPORT_EXISTS=$(aws apigateway get-resources \
  --rest-api-id $API_ID --region $REGION \
  --query "items[?path=='/create_report'].id" --output text)

if [ -z "$CREATE_REPORT_EXISTS" ]; then
  echo "==> Patching create_report_api.py..."
  sed -i "s|<FMI_1>|$API_ID|g" python_3/create_report_api.py

  echo "==> Running create_report_api.py..."
  (cd python_3 && python3 create_report_api.py)
  echo "    /create_report created."
else
  echo "    /create_report already exists, skipping."
fi

# -------------------------------------------------------
# Task 5: Deploy the API
# -------------------------------------------------------

echo ""
echo "==> [Task 5] Deploying API to 'prod' stage..."
aws apigateway create-deployment \
  --rest-api-id $API_ID \
  --stage-name prod \
  --region $REGION > /dev/null

INVOKE_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod"
echo "    Invoke URL: $INVOKE_URL"

# -------------------------------------------------------
# Task 6: Update website config and upload to S3
# -------------------------------------------------------

echo ""
echo "==> [Task 6] Updating config.js with Invoke URL..."
sed -i "s|API_GW_BASE_URL_STR: null|API_GW_BASE_URL_STR: \"$INVOKE_URL\"|" \
  resources/website/config.js

echo "==> Uploading config.js to S3..."
aws s3 cp resources/website/config.js s3://$BUCKET_NAME/config.js \
  --content-type "application/javascript" \
  --cache-control "max-age=0"

# -------------------------------------------------------
# Done
# -------------------------------------------------------

echo ""
echo "==> All tasks completed successfully!"
echo ""
echo "    API ID:      $API_ID"
echo "    Invoke URL:  $INVOKE_URL"
echo "    Website URL: https://${BUCKET_NAME}.s3.amazonaws.com/index.html"
echo ""
echo "    - 'on offer' tab should show 1 mock product"
echo "    - 'view all' tab should show 3 mock products"

# -------------------------------------------------------
# Cleanup
# -------------------------------------------------------

echo ""
echo "==> Cleaning up local files..."
rm -f code.zip
rm -rf resources python_3 __pycache__
echo "    Done."
