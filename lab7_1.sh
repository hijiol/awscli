#!/bin/bash
# Lab 7.1: Creating Lambda Functions Using the AWS SDK for Python
# Automates all CLI/SDK tasks from the lab instructions

source ./common.sh
set -e

REGION="us-east-1"
TABLE_NAME="FoodProducts"
INDEX_NAME="special_GSI"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

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
  curl -o code.zip "https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACCDEV-2-91558/05-lab-lambda/code.zip"
  echo "==> Extracting..."
  unzip -o code.zip
else
  echo "==> code.zip already present, skipping download."
  unzip -o code.zip > /dev/null 2>&1 || true
fi

echo ""
echo "==> Detecting public IP..."
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "    Your IP: $MY_IP"

echo ""
echo "==> Running setup.sh (best effort)..."
if [ -f resources/setup.sh ]; then
  chmod +x resources/setup.sh
  echo "$MY_IP" | bash resources/setup.sh || echo "    setup.sh done (some errors on Windows are expected)"
fi

echo ""
echo "==> Detecting S3 bucket..."
BUCKET_NAME=$(aws s3 ls 2>/dev/null | awk '{print $3}' | grep 's3bucket\|samplebucket' | head -1)
if [ -z "$BUCKET_NAME" ]; then
  echo "    Could not auto-detect bucket."
  read -rp "    Enter your S3 bucket name: " INPUT
  BUCKET_NAME=$(echo "$INPUT" | awk '{print $NF}')
fi
echo "    Bucket: $BUCKET_NAME"

echo ""
echo "==> Getting API Gateway details..."
API_ID=$(aws apigateway get-rest-apis --region $REGION \
  --query "items[?name=='ProductsApi'].id" --output text)
echo "    API ID: $API_ID"

PRODUCTS_RESOURCE_ID=$(aws apigateway get-resources \
  --rest-api-id $API_ID --region $REGION \
  --query "items[?path=='/products'].id" --output text)

ON_OFFER_RESOURCE_ID=$(aws apigateway get-resources \
  --rest-api-id $API_ID --region $REGION \
  --query "items[?path=='/products/on_offer'].id" --output text)

CREATE_REPORT_RESOURCE_ID=$(aws apigateway get-resources \
  --rest-api-id $API_ID --region $REGION \
  --query "items[?path=='/create_report'].id" --output text)

echo "    /products:         $PRODUCTS_RESOURCE_ID"
echo "    /products/on_offer: $ON_OFFER_RESOURCE_ID"
echo "    /create_report:    $CREATE_REPORT_RESOURCE_ID"

echo ""
echo "==> Getting LambdaAccessToDynamoDB role ARN..."
ROLE_ARN=$(aws iam get-role --role-name LambdaAccessToDynamoDB \
  --query 'Role.Arn' --output text)
echo "    Role ARN: $ROLE_ARN"

# -------------------------------------------------------
# DynamoDB bootstrap (labs are independent - must load data here)
# -------------------------------------------------------

echo ""
echo "==> Checking DynamoDB table..."
ITEM_COUNT=$(aws dynamodb scan --table-name $TABLE_NAME --region $REGION \
  --select COUNT --query Count --output text 2>/dev/null || echo "0")
echo "    Items in $TABLE_NAME: $ITEM_COUNT"

if [ "$ITEM_COUNT" = "0" ]; then
  echo "==> Table empty — downloading lab5 data files..."
  curl -s -o lab5_code.zip "https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACCDEV-2-91558/03-lab-dynamo/code.zip"
  mkdir -p lab5_temp
  unzip -o lab5_code.zip -d lab5_temp > /dev/null 2>&1

  # Create table if missing
  TABLE_EXISTS=$(aws dynamodb list-tables --region $REGION \
    --query "TableNames[?@=='$TABLE_NAME']" --output text)
  if [ -z "$TABLE_EXISTS" ]; then
    echo "==> Creating $TABLE_NAME table..."
    sed -i "s|<FMI_1>|$TABLE_NAME|g" lab5_temp/python_3/create_table.py
    (cd lab5_temp/python_3 && python3 create_table.py)
    aws dynamodb wait table-exists --table-name $TABLE_NAME --region $REGION
    echo "    Table created."
  fi

  # Load production data
  echo "==> Loading production data..."
  sed -i "s|<FMI>|$TABLE_NAME|g" lab5_temp/python_3/batch_put.py
  (cd lab5_temp/python_3 && python3 batch_put.py)

  # Create GSI if missing
  GSI_STATUS=$(aws dynamodb describe-table --table-name $TABLE_NAME --region $REGION \
    --query "Table.GlobalSecondaryIndexes[?IndexName=='$INDEX_NAME'].IndexStatus" \
    --output text 2>/dev/null)
  if [ -z "$GSI_STATUS" ]; then
    echo "==> Creating $INDEX_NAME GSI..."
    sed -i "s|<FMI_1>|HASH|g" lab5_temp/python_3/add_gsi.py
    (cd lab5_temp/python_3 && python3 add_gsi.py)
  fi

  rm -rf lab5_temp lab5_code.zip
fi

echo "==> Waiting for $INDEX_NAME to be ACTIVE..."
while true; do
  GSI_STATUS=$(aws dynamodb describe-table --table-name $TABLE_NAME --region $REGION \
    --query "Table.GlobalSecondaryIndexes[?IndexName=='$INDEX_NAME'].IndexStatus" \
    --output text 2>/dev/null)
  echo "    GSI status: $GSI_STATUS"
  if [ "$GSI_STATUS" = "ACTIVE" ]; then echo "    GSI ready."; break; fi
  if [ -z "$GSI_STATUS" ]; then echo "    WARNING: GSI not found!"; break; fi
  sleep 15
done

# -------------------------------------------------------
# Task 2: Create get_all_products Lambda
# -------------------------------------------------------

echo ""
echo "==> [Task 2] Patching get_all_products_code.py..."
sed -i "s|<FMI_1>|$TABLE_NAME|g" python_3/get_all_products_code.py
sed -i "s|<FMI_2>|$INDEX_NAME|g" python_3/get_all_products_code.py
sed -i "s|^print(lambda_handler|#print(lambda_handler|g" python_3/get_all_products_code.py

echo "==> Patching get_all_products_wrapper.py..."
sed -i "s|<FMI_1>|$ROLE_ARN|g"    python_3/get_all_products_wrapper.py
sed -i "s|<FMI_2>|$BUCKET_NAME|g" python_3/get_all_products_wrapper.py
sed -i "s|<FMI>|$BUCKET_NAME|g"   python_3/get_all_products_wrapper.py

echo "==> Zipping and uploading get_all_products_code.py..."
(cd python_3 && python3 -c "import zipfile; z=zipfile.ZipFile('get_all_products_code.zip','w',zipfile.ZIP_DEFLATED); z.write('get_all_products_code.py','get_all_products_code.py'); z.close()")
aws s3 cp python_3/get_all_products_code.zip s3://$BUCKET_NAME/

echo "==> Checking if get_all_products Lambda already exists..."
LAMBDA_EXISTS=$(aws lambda get-function --function-name get_all_products \
  --region $REGION --query 'Configuration.FunctionName' --output text 2>/dev/null || echo "")

if [ -z "$LAMBDA_EXISTS" ]; then
  echo "==> Creating get_all_products Lambda function..."
  (cd python_3 && python3 get_all_products_wrapper.py)
else
  echo "    Lambda already exists, updating code..."
  aws lambda update-function-code \
    --function-name get_all_products \
    --zip-file fileb://python_3/get_all_products_code.zip \
    --region $REGION > /dev/null
fi

GET_ALL_PRODUCTS_ARN=$(aws lambda get-function \
  --function-name get_all_products \
  --query 'Configuration.FunctionArn' --output text --region $REGION)
echo "    Lambda ARN: $GET_ALL_PRODUCTS_ARN"

echo "==> Granting API Gateway permission to invoke get_all_products..."
aws lambda add-permission \
  --function-name get_all_products \
  --statement-id allow-apigateway \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*" \
  --region $REGION > /dev/null 2>/dev/null || echo "    (Permission already exists)"

# -------------------------------------------------------
# Task 3: Configure REST API for get_all_products
# -------------------------------------------------------

echo ""
echo "==> [Task 3] Updating /products GET integration to Lambda..."
aws apigateway put-integration \
  --rest-api-id $API_ID \
  --resource-id $PRODUCTS_RESOURCE_ID \
  --http-method GET \
  --type AWS \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$GET_ALL_PRODUCTS_ARN/invocations" \
  --region $REGION > /dev/null

echo "==> Enabling CORS on /products..."
aws apigateway put-method-response \
  --rest-api-id $API_ID \
  --resource-id $PRODUCTS_RESOURCE_ID \
  --http-method GET \
  --status-code 200 \
  --response-parameters '{"method.response.header.Access-Control-Allow-Origin": false}' \
  --region $REGION > /dev/null 2>/dev/null || true

aws apigateway put-integration-response \
  --rest-api-id $API_ID \
  --resource-id $PRODUCTS_RESOURCE_ID \
  --http-method GET \
  --status-code 200 \
  --response-parameters '{"method.response.header.Access-Control-Allow-Origin": "'"'"'*'"'"'"}' \
  --region $REGION > /dev/null

echo "==> Updating /products/on_offer GET integration to Lambda + mapping template..."
aws apigateway put-integration \
  --rest-api-id $API_ID \
  --resource-id $ON_OFFER_RESOURCE_ID \
  --http-method GET \
  --type AWS \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$GET_ALL_PRODUCTS_ARN/invocations" \
  --request-templates '{"application/json": "{\"path\": \"$context.resourcePath\"}"}' \
  --passthrough-behavior WHEN_NO_TEMPLATES \
  --region $REGION

aws apigateway create-deployment \
  --rest-api-id $API_ID \
  --stage-name prod \
  --region us-east-1

echo "==> Verifying on_offer mapping template..."
TMPL=$(aws apigateway get-integration \
  --rest-api-id $API_ID \
  --resource-id $ON_OFFER_RESOURCE_ID \
  --http-method GET \
  --region $REGION \
  --query 'requestTemplates' --output text)
echo "    requestTemplates: $TMPL"

echo "==> Enabling CORS on /products/on_offer..."
aws apigateway put-method-response \
  --rest-api-id $API_ID \
  --resource-id $ON_OFFER_RESOURCE_ID \
  --http-method GET \
  --status-code 200 \
  --response-parameters '{"method.response.header.Access-Control-Allow-Origin": false}' \
  --region $REGION > /dev/null 2>/dev/null || true

aws apigateway put-integration-response \
  --rest-api-id $API_ID \
  --resource-id $ON_OFFER_RESOURCE_ID \
  --http-method GET \
  --status-code 200 \
  --response-parameters '{"method.response.header.Access-Control-Allow-Origin": "'"'"'*'"'"'"}' \
  --region $REGION > /dev/null

# -------------------------------------------------------
# Task 4: Create create_report Lambda
# -------------------------------------------------------

echo ""
echo "==> [Task 4] Patching create_report_code.py..."
sed -i "s|^print(lambda_handler|#print(lambda_handler|g" python_3/create_report_code.py

echo "==> Patching create_report_wrapper.py..."
sed -i "s|<FMI_1>|$ROLE_ARN|g"    python_3/create_report_wrapper.py
sed -i "s|<FMI_2>|$BUCKET_NAME|g" python_3/create_report_wrapper.py
sed -i "s|<FMI>|$BUCKET_NAME|g"   python_3/create_report_wrapper.py

echo "==> Zipping and uploading create_report_code.py..."
(cd python_3 && python3 -c "import zipfile; z=zipfile.ZipFile('create_report_code.zip','w',zipfile.ZIP_DEFLATED); z.write('create_report_code.py','create_report_code.py'); z.close()")
aws s3 cp python_3/create_report_code.zip s3://$BUCKET_NAME/

echo "==> Checking if create_report Lambda already exists..."
LAMBDA_EXISTS=$(aws lambda get-function --function-name create_report \
  --region $REGION --query 'Configuration.FunctionName' --output text 2>/dev/null || echo "")

if [ -z "$LAMBDA_EXISTS" ]; then
  echo "==> Creating create_report Lambda function..."
  (cd python_3 && python3 create_report_wrapper.py)
else
  echo "    Lambda already exists, updating code..."
  aws lambda update-function-code \
    --function-name create_report \
    --zip-file fileb://python_3/create_report_code.zip \
    --region $REGION > /dev/null
fi

CREATE_REPORT_ARN=$(aws lambda get-function \
  --function-name create_report \
  --query 'Configuration.FunctionArn' --output text --region $REGION)
echo "    Lambda ARN: $CREATE_REPORT_ARN"

echo "==> Granting API Gateway permission to invoke create_report..."
aws lambda add-permission \
  --function-name create_report \
  --statement-id allow-apigateway \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*" \
  --region $REGION > /dev/null 2>/dev/null || echo "    (Permission already exists)"

# -------------------------------------------------------
# Task 5: Configure REST API for create_report
# -------------------------------------------------------

echo ""
echo "==> [Task 5] Updating /create_report POST integration to Lambda..."
aws apigateway put-integration \
  --rest-api-id $API_ID \
  --resource-id $CREATE_REPORT_RESOURCE_ID \
  --http-method POST \
  --type AWS \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$CREATE_REPORT_ARN/invocations" \
  --region $REGION > /dev/null

aws apigateway put-integration-response \
  --rest-api-id $API_ID \
  --resource-id $CREATE_REPORT_RESOURCE_ID \
  --http-method POST \
  --status-code 200 \
  --region $REGION > /dev/null 2>/dev/null || true

echo ""
echo "==> Deploying API to prod stage..."
aws apigateway create-deployment \
  --rest-api-id $API_ID \
  --stage-name prod \
  --region $REGION > /dev/null

INVOKE_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod"
echo "    Invoke URL: $INVOKE_URL"

echo ""
echo "==> Checking DynamoDB table and special_GSI..."
python3 -c "
import boto3
from boto3.dynamodb.conditions import Attr
ddb = boto3.resource('dynamodb', region_name='us-east-1')
table = ddb.Table('FoodProducts')

total = table.scan(Select='COUNT')['Count']
print(f'  Total items in FoodProducts: {total}')

try:
    gsi = table.scan(IndexName='special_GSI', Select='COUNT')
    print(f'  Items in special_GSI: {gsi[\"Count\"]}')
except Exception as e:
    print(f'  special_GSI error: {e}')

special = table.scan(FilterExpression=Attr('special').exists(), Select='COUNT')['Count']
print(f'  Items with special attribute: {special}')
"

echo ""
echo "==> Testing /products/on_offer endpoint (waiting 3s for deployment to propagate)..."
sleep 3
ON_OFFER_RESP=$(curl -s "$INVOKE_URL/products/on_offer")
echo "    Raw response (first 300 chars): ${ON_OFFER_RESP:0:300}"
ITEM_COUNT=$(echo "$ON_OFFER_RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    arr = d.get('product_item_arr', [])
    print(len(arr))
except Exception as e:
    print('ERROR: ' + str(e))
" 2>/dev/null)
echo "    Items returned: $ITEM_COUNT (expected 6)"

# -------------------------------------------------------
# Update config.js
# -------------------------------------------------------

echo ""
echo "==> Updating config.js with Invoke URL..."
sed -i "s|API_GW_BASE_URL_STR: null|API_GW_BASE_URL_STR: \"$INVOKE_URL\"|" \
  resources/website/config.js
sed -i "s|API_GW_BASE_URL_STR: \"https://[^\"]*\"|API_GW_BASE_URL_STR: \"$INVOKE_URL\"|" \
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
echo "    - 'on offer' tab should show 6 live DynamoDB items"
echo "    - 'view all' tab should show all 26 live DynamoDB items"

# -------------------------------------------------------
# Cleanup
# -------------------------------------------------------

echo ""
echo "==> Showing Lambda handler for debugging..."
echo "--- get_all_products_code.py (full) ---"
cat python_3/get_all_products_code.py 2>/dev/null || echo "    (file not found)"
echo "---------------------------------------"

echo "==> Cleaning up local files..."
rm -f code.zip
rm -rf resources python_3 __pycache__
echo "    Done."
