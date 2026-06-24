#!/bin/bash
set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-west-2"
MODEL_ARN="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:inference-profile/us.anthropic.claude-haiku-4-5-20251001-v1:0"

echo "Account  : $ACCOUNT_ID"
echo "Region   : $REGION"
echo "Model ARN: $MODEL_ARN"

echo ""
echo "Patching CDK environment variables..."
cd ~/rooscloset/cdk/lib

# Target only the quoted string in environment blocks, not the IAM ARN lines
sed -i "s|'HAIKU_ARN_PLACEHOLDER'|'${MODEL_ARN}'|g" atlas-stack.ts
sed -i "s|'HAIKU_ARN_PLACEHOLDER'|'${MODEL_ARN}'|g" mirror-stack.ts

echo "Patching Lambda handlers..."
cd ~/rooscloset/atlas/handlers
sed -i "s|'HAIKU_ARN_PLACEHOLDER'|'${MODEL_ARN}'|g" attribute.py

cd ~/rooscloset/mirror/handlers
sed -i "s|'HAIKU_ARN_PLACEHOLDER'|'${MODEL_ARN}'|g" explain.py
sed -i "s|'HAIKU_ARN_PLACEHOLDER'|'${MODEL_ARN}'|g" prescribe.py

echo ""
echo "Verifying patches..."
echo "--- atlas-stack.ts BEDROCK_MODEL_ID line ---"
grep "BEDROCK_MODEL_ID" ~/rooscloset/cdk/lib/atlas-stack.ts

echo "--- mirror-stack.ts BEDROCK_MODEL_ID lines ---"
grep "BEDROCK_MODEL_ID" ~/rooscloset/cdk/lib/mirror-stack.ts

echo "--- IAM policies unchanged (should still say resources: ['*']) ---"
grep -A2 "bedrock:InvokeModel" ~/rooscloset/cdk/lib/atlas-stack.ts | head -6

echo ""
echo "=== Patch complete. Run rc_deploy.sh next. ==="