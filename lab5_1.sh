#!/bin/bash
# Lab 5.1: Working with Amazon DynamoDB
# Automates all CLI/SDK tasks from the lab instructions

source ./common.sh

REGION="us-east-1"
TABLE_NAME="FoodProducts"

# -------------------------------------------------------
# Task 1: Setup
# -------------------------------------------------------

echo "==> Verifying AWS CLI..."
aws --version

echo ""
echo "==> Installing boto3..."
pip3 install boto3 -q

echo ""
echo "==> Downloading lab files..."
curl -o code.zip "https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACCDEV-2-91558/03-lab-dynamo/code.zip"

echo "==> Extracting code.zip..."
unzip -o code.zip

echo ""
echo "==> Verifying boto3 installation..."
pip3 show boto3

# -------------------------------------------------------
# Task 2: Create DynamoDB table
# -------------------------------------------------------

echo ""
echo "==> Patching create_table.py..."
sed -i "s|<FMI_1>|$TABLE_NAME|g" python_3/create_table.py

echo "==> Checking if table already exists..."
TABLE_EXISTS=$(aws dynamodb list-tables --region $REGION \
  --query "length(TableNames[?@=='$TABLE_NAME'])" --output text)

if [ "$TABLE_EXISTS" -gt 0 ]; then
  echo "    Table '$TABLE_NAME' already exists, skipping creation."
else
  echo "==> Creating DynamoDB table: $TABLE_NAME..."
  cd python_3
  python3 create_table.py
  cd ..
fi

echo ""
echo "==> Verifying table..."
aws dynamodb list-tables --region $REGION

# -------------------------------------------------------
# Task 3: Condition expression demo
# -------------------------------------------------------

echo ""
echo "==> [Task 3] Inserting 'best cake' record..."
aws dynamodb put-item \
  --table-name $TABLE_NAME \
  --item '{"product_name": {"S": "best cake"}, "product_id": {"S": "111111111111"}}' \
  --region $REGION

echo "==> Inserting 'best pie' record..."
aws dynamodb put-item \
  --table-name $TABLE_NAME \
  --item '{"product_name": {"S": "best pie"}, "product_id": {"S": "676767676767"}}' \
  --region $REGION

echo "==> Updating 'best pie' product_id to 3333333333..."
aws dynamodb put-item \
  --table-name $TABLE_NAME \
  --item '{"product_name": {"S": "best pie"}, "product_id": {"S": "3333333333"}}' \
  --region $REGION

echo "==> Testing condition expression (expect ConditionalCheckFailedException)..."
set +e
aws dynamodb put-item \
  --table-name $TABLE_NAME \
  --item '{"product_name": {"S": "best pie"}, "product_id": {"S": "2222222222"}}' \
  --condition-expression "attribute_not_exists(product_name)" \
  --region $REGION
set -e
echo "    (Above error is expected behavior)"

# -------------------------------------------------------
# Task 4: conditional_put.py
# -------------------------------------------------------

echo ""
echo "==> [Task 4] Patching conditional_put.py..."
sed -i "s|<FMI_1>|$TABLE_NAME|g"     python_3/conditional_put.py
sed -i "s|<FMI_2>|apple pie|g"        python_3/conditional_put.py
sed -i "s|<FMI_3>|a444|g"             python_3/conditional_put.py
sed -i "s|<FMI_4>|595|g"              python_3/conditional_put.py
sed -i "s|<FMI_5>|It is amazing!|g"   python_3/conditional_put.py
sed -i "s|<FMI_6>|whole pie|g"        python_3/conditional_put.py
sed -i "s|<FMI_7>|apple|g"            python_3/conditional_put.py

echo "==> Running conditional_put.py (insert apple pie)..."
cd python_3
python3 conditional_put.py

echo "==> Running again (should not overwrite - condition guards it)..."
set +e
python3 conditional_put.py
set -e

echo "==> Changing product_name to cherry pie and re-running..."
sed -i "s|apple pie|cherry pie|g" conditional_put.py
python3 conditional_put.py
cd ..

# -------------------------------------------------------
# Task 5: Batch load
# -------------------------------------------------------

echo ""
echo "==> [Task 5] Deleting all existing table items..."
python3 -c "
import boto3
dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
table = dynamodb.Table('FoodProducts')
scan = table.scan()
with table.batch_writer() as batch:
    for item in scan['Items']:
        batch.delete_item(Key={'product_name': item['product_name']})
print('All items deleted.')
"

echo ""
echo "==> Patching test_batch_put.py (with overwrite - shows last-write-wins behavior)..."
sed -i "s|<FMI_1>|$TABLE_NAME|g"   python_3/test_batch_put.py
sed -i "s|<FMI_2>|product_name|g"  python_3/test_batch_put.py

echo "==> Running test_batch_put.py (overwrite enabled - will succeed with duplicates)..."
cd python_3
python3 test_batch_put.py

echo ""
echo "==> Removing overwrite_by_pkeys to fail on duplicates..."
sed -i "s|batch_writer(overwrite_by_pkeys=\['product_name'\])|batch_writer()|g" test_batch_put.py

echo "==> Running test_batch_put.py again (expect ValidationException for duplicates)..."
set +e
python3 test_batch_put.py
set -e
echo "    (Above error is expected - duplicate keys detected)"
cd ..

echo ""
echo "==> Deleting all items again before production load..."
python3 -c "
import boto3
dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
table = dynamodb.Table('FoodProducts')
scan = table.scan()
with table.batch_writer() as batch:
    for item in scan['Items']:
        batch.delete_item(Key={'product_name': item['product_name']})
print('All items deleted.')
"

echo ""
echo "==> Patching batch_put.py..."
sed -i "s|<FMI>|$TABLE_NAME|g" python_3/batch_put.py

echo "==> Running batch_put.py (loading production data)..."
cd python_3
python3 batch_put.py
cd ..

# -------------------------------------------------------
# Task 6: Query the table
# -------------------------------------------------------

echo ""
echo "==> [Task 6] Patching get_all_items.py..."
sed -i "s|<FMI_1>|$TABLE_NAME|g" python_3/get_all_items.py

echo "==> Running get_all_items.py..."
cd python_3
python3 get_all_items.py

echo ""
echo "==> Patching get_one_item.py..."
sed -i "s|<FMI_1>|product_name|g" get_one_item.py

echo "==> Running get_one_item.py..."
python3 get_one_item.py
cd ..

# -------------------------------------------------------
# Task 7: Add Global Secondary Index
# -------------------------------------------------------

echo ""
echo "==> [Task 7] Patching add_gsi.py..."
sed -i "s|<FMI_1>|HASH|g" python_3/add_gsi.py

echo "==> Checking if GSI already exists..."
GSI_STATUS=$(aws dynamodb describe-table \
  --table-name $TABLE_NAME \
  --region $REGION \
  --query "Table.GlobalSecondaryIndexes[?IndexName=='special_GSI'].IndexStatus" \
  --output text)

if [ -n "$GSI_STATUS" ] && [ "$GSI_STATUS" != "None" ]; then
  echo "    GSI already exists (status: $GSI_STATUS), skipping creation."
else
  echo "==> Running add_gsi.py..."
  cd python_3
  python3 add_gsi.py
  cd ..
fi

echo ""
echo "==> Waiting for GSI 'special_GSI' to become ACTIVE (this can take up to 5 minutes)..."
while true; do
  STATUS=$(aws dynamodb describe-table \
    --table-name $TABLE_NAME \
    --region $REGION \
    --query "Table.GlobalSecondaryIndexes[?IndexName=='special_GSI'].IndexStatus" \
    --output text)
  echo "    GSI status: $STATUS"
  if [ "$STATUS" = "ACTIVE" ]; then
    echo "    GSI is ACTIVE."
    break
  fi
  sleep 15
done

echo ""
echo "==> Patching scan_with_filter.py..."
sed -i "s|<FMI_1>|special_GSI|g" python_3/scan_with_filter.py
sed -i "s|<FMI_2>|tags|g"        python_3/scan_with_filter.py

echo "==> Running scan_with_filter.py..."
cd python_3
python3 scan_with_filter.py
cd ..

# -------------------------------------------------------
# Cleanup
# -------------------------------------------------------

echo ""
echo "==> Cleaning up local files..."
rm -f code.zip
rm -rf resources python_3 __pycache__
echo "    Done."

echo ""
echo "==> All tasks completed successfully!"
echo "    Table '$TABLE_NAME' is live in DynamoDB (region: $REGION)"
