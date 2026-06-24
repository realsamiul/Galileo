#!/bin/bash
set -euo pipefail

export AWS_DEFAULT_REGION=us-west-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "=== Deploying RoosCloset | $ACCOUNT_ID | $AWS_DEFAULT_REGION ==="

# Ensure boto3 is available (no-op on CloudShell, safety net elsewhere)
pip3 install boto3 --quiet --disable-pip-version-check 2>/dev/null || true

cd ~/rooscloset/cdk

echo "Bootstrapping CDK..."
npx cdk bootstrap aws://$ACCOUNT_ID/$AWS_DEFAULT_REGION \
  --require-approval never 2>&1 | tail -5

echo "Deploying all stacks (5-10 minutes)..."
npx cdk deploy --all \
  --require-approval never \
  --outputs-file /tmp/cdk-outputs.json 2>&1 | tail -30

echo ""
echo "=== Stack Outputs ==="
python3 -m json.tool /tmp/cdk-outputs.json

DATA_LAKE=$(python3 -c "
import json
d = json.load(open('/tmp/cdk-outputs.json'))
print(d['RoosCloset-Shared']['DataLakeBucket'])
")
API_URL=$(python3 -c "
import json
d = json.load(open('/tmp/cdk-outputs.json'))
print(d['RoosCloset-Shared']['ApiEndpoint'])
")
PIPELINE_ARN=$(python3 -c "
import json
d = json.load(open('/tmp/cdk-outputs.json'))
print(d['RoosCloset-ATLAS']['PipelineArn'])
")

echo ""
echo "Data Lake : $DATA_LAKE"
echo "API URL   : $API_URL"
echo "Pipeline  : $PIPELINE_ARN"

# ── Test 1: MIRROR score ──────────────────────────────────────────────
echo ""
echo "=== Test 1: MIRROR Score ==="
curl -s -X POST "${API_URL}mirror/score" \
  -H "Content-Type: application/json" \
  -d '{
    "tenant_id": "demo-brand",
    "order_id": "ORD-TEST-001",
    "customer": {
      "lifetime_orders": 0,
      "lifetime_return_rate": 0,
      "is_first_order": true
    },
    "items": [{
      "sku_id": "SKU-DRESS-001",
      "category": "dress",
      "size_chart_present": false
    }]
  }' | python3 -m json.tool

# ── Test 2: Upload PNG to trigger ATLAS pipeline ──────────────────────
echo ""
echo "=== Test 2: ATLAS Pipeline Trigger ==="
python3 << PYEOF
import boto3
import struct
import zlib

def make_png():
    """Build a valid 1x1 white pixel PNG — no Pillow required."""
    def chunk(name, data):
        crc = zlib.crc32(name + data) & 0xFFFFFFFF
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', crc)

    # PNG signature — single line, proper escape sequences
    sig = b'\x89PNG\r\n\x1a\n'
    ihdr_data = struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)
    ihdr = chunk(b'IHDR', ihdr_data)
    # 1x1 white RGB pixel, filter byte 0x00 prepended
    raw_row = b'\x00\xff\xff\xff'
    idat = chunk(b'IDAT', zlib.compress(raw_row))
    iend = chunk(b'IEND', b'')
    return sig + ihdr + idat + iend

s3 = boto3.client('s3')
bucket = '${DATA_LAKE}'
key = 'raw/demo-brand/images/TEST-SKU-001.png'
png_data = make_png()
s3.put_object(Bucket=bucket, Key=key, Body=png_data, ContentType='image/png')
print(f'Uploaded {len(png_data)} byte PNG to s3://{bucket}/{key}')
PYEOF

echo "Waiting 15s for SQS -> Lambda -> Step Functions..."
sleep 15

echo ""
echo "=== Step Functions Executions ==="
aws stepfunctions list-executions \
  --state-machine-arn "$PIPELINE_ARN" \
  --max-results 5 \
  --query 'executions[].{name:name,status:status,start:startDate}' \
  --output table 2>/dev/null || echo "No executions yet"

# ── Test 3: DynamoDB ──────────────────────────────────────────────────
echo ""
echo "=== DynamoDB: Return Events ==="
aws dynamodb scan \
  --table-name rooscloset-return-events \
  --max-items 3 \
  --query 'Items[].{tenant:tenant_id.S,order:order_id.S,risk:risk_score.N,level:risk_level.S}' \
  --output table 2>/dev/null || echo "Table propagating..."

# ── Test 4: Interventions ─────────────────────────────────────────────
echo ""
echo "=== Test 4: Get Interventions ==="
curl -s "${API_URL}mirror/interventions/SKU-DRESS-001" | python3 -m json.tool

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  DEPLOYMENT COMPLETE"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  S3 Data Lake : $DATA_LAKE"
echo "  API Gateway  : $API_URL"
echo ""
echo "  Endpoints:"
echo "    POST ${API_URL}atlas/ingest"
echo "    GET  ${API_URL}atlas/products/{sku_id}"
echo "    POST ${API_URL}atlas/search"
echo "    POST ${API_URL}mirror/score"
echo "    GET  ${API_URL}mirror/interventions/{sku_id}"
echo ""
echo "  Next: Bedrock console -> Model access -> Enable Haiku 4.5"
echo "  Est. idle cost: ~\$35-50/month"
echo "════════════════════════════════════════════════════════"