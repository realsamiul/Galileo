#!/bin/bash
set -e

REGION="us-west-2"
MODEL_ID="arn:aws:bedrock:us-west-2:601548054060:inference-profile/us.anthropic.claude-haiku-4-5-20251001-v1:0"

echo "[1/2] Downloading current Lambda code..."
cd /tmp
aws lambda get-function \
  --function-name proofsheet-webhook \
  --region $REGION \
  --query 'Code.Location' \
  --output text | xargs curl -s -o lambda_function.zip

echo "[2/2] Fixing model ID and redeploying..."
unzip -o lambda_function.zip > /dev/null

# Replace the broken model ID with the inference profile ARN
sed -i "s|anthropic\.claude-sonnet-4-20250514|${MODEL_ID}|g" lambda_function.py

zip -j lambda_function_fixed.zip lambda_function.py > /dev/null

aws lambda update-function-code \
  --function-name proofsheet-webhook \
  --zip-file fileb:///tmp/lambda_function_fixed.zip \
  --region $REGION

echo ""
echo "=========================================="
echo "LAMBDA UPDATED - Using Claude Haiku 4.5"
echo "=========================================="
echo ""
echo "Send another message to your Facebook Page, then check logs:"
echo ""
echo "  aws logs tail /aws/lambda/proofsheet-webhook --since 1m --region $REGION"
echo "=========================================="