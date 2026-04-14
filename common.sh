#!/bin/bash
# common.sh - Shared setup for all lab scripts

# --- Load .env ---
if [ ! -f .env ]; then
  echo "ERROR: .env file not found. Create one with your AWS credentials."
  exit 1
fi
set -a
source .env
set +a
# -----------------

# --- Credential check ---
echo "==> Checking AWS credentials..."
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
