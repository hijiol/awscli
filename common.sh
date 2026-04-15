#!/bin/bash
# common.sh - Shared setup for all lab scripts

# --- Load .env ---
if [ ! -f .env ]; then
  echo "ERROR: .env file not found. Create one with your AWS credentials."
  exit 1
fi
# Strip Windows carriage returns (\r) so the file works whether edited on
# Windows or Mac/Linux. Without this, values get a \r appended and AWS CLI
# rejects the credentials even though they look correct.
_ENV_CLEAN=$(mktemp)
tr -d '\r' < .env > "$_ENV_CLEAN"
set -a
source "$_ENV_CLEAN"
set +a
rm -f "$_ENV_CLEAN"
# -----------------

# --- Credential check ---
echo "==> Checking AWS credentials..."

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_SESSION_TOKEN" ]; then
  echo "ERROR: One or more credentials are missing from .env."
  echo "       Make sure AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_SESSION_TOKEN are all filled in."
  exit 1
fi

IDENTITY=$(aws sts get-caller-identity --output text 2>&1)
if [ $? -ne 0 ]; then
  echo "ERROR: AWS credentials are expired or invalid."
  echo "       Update your .env file with fresh credentials from the lab and re-run."
  exit 1
fi
ACCOUNT_ID=$(echo "$IDENTITY" | awk '{print $1}')
echo "    Credentials OK."
echo "    Account ID: $ACCOUNT_ID"
echo "    If this account ID doesn't match your lab, update your .env and re-run."
# ------------------------
