#!/bin/bash
set -e

REGION="us-west-2"
PHONE_NUMBER_ID="1213332605203066"
WABA_ID="1756201745793198"
ACCESS_TOKEN="EAAfsLZAnDzj4BRqZAag5FkZAy98KKEZC8HD8IA0PGrwcG1kCys0gGCFXXFin0lUtzvPJQU1Lka5oYzuM2wLroZCleK9c5LSp5ZAp3gGNvj5Y0du9ZAd1zQyDqAKQMp6UDkvmRbQZB8ccuT9DFNbYbkelAZACZAa9CfQTY1mfJvuGqZBjXl7Rxh9Lle6cBaONdijEZCsUHzAFqHz5Dg3EKzNlkMPUNwPJPL92JTUCbSFKoWqU4pG08LdfiCxMeQZDZD"
VERIFY_TOKEN="proofsheet-verify-2024"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=========================================="
echo "ProofSheet Setup Starting"
echo "Account: $ACCOUNT_ID"
echo "Region: $REGION"
echo "=========================================="

# 1. Secrets Manager
echo "[1/7] Creating secret..."
aws secretsmanager create-secret \
  --name proofsheet/whatsapp \
  --secret-string "{\"access_token\":\"${ACCESS_TOKEN}\",\"phone_number_id\":\"${PHONE_NUMBER_ID}\",\"verify_token\":\"${VERIFY_TOKEN}\"}" \
  --region $REGION 2>/dev/null || \
aws secretsmanager update-secret \
  --secret-id proofsheet/whatsapp \
  --secret-string "{\"access_token\":\"${ACCESS_TOKEN}\",\"phone_number_id\":\"${PHONE_NUMBER_ID}\",\"verify_token\":\"${VERIFY_TOKEN}\"}" \
  --region $REGION
echo "  Done"

# 2. DynamoDB
echo "[2/7] Creating DynamoDB table..."
aws dynamodb create-table \
  --table-name proofsheet_conversations \
  --attribute-definitions \
    AttributeName=phone_number,AttributeType=S \
    AttributeName=timestamp,AttributeType=S \
  --key-schema \
    AttributeName=phone_number,KeyType=HASH \
    AttributeName=timestamp,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --region $REGION 2>/dev/null && echo "  Table created" || echo "  Table already exists"

# 3. S3
echo "[3/7] Creating S3 bucket..."
aws s3 mb s3://proofsheet-docs-${ACCOUNT_ID} --region $REGION 2>/dev/null && echo "  Bucket created" || echo "  Bucket already exists"

# 4. IAM Role
echo "[4/7] Creating IAM role..."
aws iam create-role \
  --role-name proofsheet-lambda-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' 2>/dev/null || true

aws iam attach-role-policy \
  --role-name proofsheet-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true

aws iam put-role-policy \
  --role-name proofsheet-lambda-role \
  --policy-name proofsheet-permissions \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"bedrock:InvokeModel\"],\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\"],\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"dynamodb:GetItem\",\"dynamodb:PutItem\",\"dynamodb:UpdateItem\",\"dynamodb:Query\"],\"Resource\":\"arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/proofsheet_*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::proofsheet-docs-${ACCOUNT_ID}/*\"}
    ]
  }"
echo "  IAM role ready"

# 5. Lambda Function
echo "[5/7] Creating Lambda function..."
cat > /tmp/lambda_function.py << 'LAMBDA'
import json
import boto3
import urllib3
from datetime import datetime, timezone

REGION = 'us-west-2'
bedrock = boto3.client('bedrock-runtime', region_name=REGION)
dynamodb = boto3.resource('dynamodb', region_name=REGION)
secrets_client = boto3.client('secretsmanager', region_name=REGION)
CONVERSATION_TABLE = dynamodb.Table('proofsheet_conversations')
http = urllib3.PoolManager()

_secrets_cache = None

def get_secrets():
    global _secrets_cache
    if _secrets_cache is None:
        resp = secrets_client.get_secret_value(SecretId='proofsheet/whatsapp')
        _secrets_cache = json.loads(resp['SecretString'])
    return _secrets_cache


def lambda_handler(event, context):
    print(f"Event: {json.dumps(event)}")
    method = event.get('requestContext', {}).get('http', {}).get('method', 'POST')

    if method == 'GET':
        return handle_verification(event)

    try:
        body = json.loads(event.get('body', '{}'))
    except json.JSONDecodeError:
        return {'statusCode': 200}

    if body.get('object') != 'whatsapp_business_account':
        return {'statusCode': 200}

    for entry in body.get('entry', []):
        for change in entry.get('changes', []):
            value = change.get('value', {})
            if 'messages' not in value:
                continue
            for message in value['messages']:
                process_message(message)

    return {'statusCode': 200}


def handle_verification(event):
    params = event.get('queryStringParameters', {}) or {}
    mode = params.get('hub.mode', '')
    token = params.get('hub.verify_token', '')
    challenge = params.get('hub.challenge', '')

    print(f"Verify: mode={mode} token={token} challenge={challenge}")

    secrets = get_secrets()

    if mode == 'subscribe' and token == secrets['verify_token']:
        print("Verification SUCCESS")
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'text/plain'},
            'body': challenge
        }
    print(f"Verification FAILED expected={secrets['verify_token']} got={token}")
    return {'statusCode': 403, 'body': 'Forbidden'}


def process_message(message):
    sender = message['from']
    msg_type = message['type']
    timestamp = datetime.now(timezone.utc).isoformat()

    print(f"Message from {sender} type={msg_type}")

    if msg_type == 'text':
        user_text = message['text']['body']
    elif msg_type == 'interactive':
        interactive = message.get('interactive', {})
        if 'button_reply' in interactive:
            user_text = interactive['button_reply']['title']
        elif 'list_reply' in interactive:
            user_text = interactive['list_reply']['title']
        else:
            user_text = '[interactive]'
    else:
        send_reply(sender, "Right now I only support text messages. Voice and image support coming soon!")
        return

    print(f"User text: {user_text}")

    history = get_conversation_history(sender)
    assistant_response = call_bedrock(user_text, history)

    print(f"Response: {assistant_response[:200]}")

    send_reply(sender, assistant_response)
    save_message(sender, timestamp, 'user', user_text)
    save_message(sender, timestamp + '_r', 'assistant', assistant_response)


SYSTEM_PROMPT = """You are ProofSheet, a document assistant on WhatsApp for users in Bangladesh. You help create professional documents (invoices, letters, leave applications, certificates) from conversational input.

RULES:
- Reply in whatever language the user writes in (Bangla, English, or mixed)
- Be conversational and efficient - ask max 2-3 questions
- When you have enough info, confirm what you will generate
- Be friendly but respect the user's time
- Use emoji sparingly

CAPABILITIES: invoices, receipts, business letters, leave applications, experience certificates, formal applications, agreements.

If someone just says hi, introduce yourself briefly and ask how you can help."""


def call_bedrock(user_text, history):
    messages = []
    for msg in history[-10:]:
        messages.append({"role": msg['role'], "content": msg['content']})
    messages.append({"role": "user", "content": user_text})

    try:
        response = bedrock.invoke_model(
            modelId='anthropic.claude-sonnet-4-20250514',
            body=json.dumps({
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 1024,
                "system": SYSTEM_PROMPT,
                "messages": messages
            })
        )
        result = json.loads(response['body'].read())
        return result['content'][0]['text']
    except Exception as e:
        print(f"Bedrock error: {e}")
        return "Sorry, something went wrong. Please try again."


def get_conversation_history(phone_number):
    try:
        from boto3.dynamodb.conditions import Key
        response = CONVERSATION_TABLE.query(
            KeyConditionExpression=Key('phone_number').eq(phone_number),
            ScanIndexForward=False,
            Limit=20
        )
        items = response.get('Items', [])
        items.reverse()
        return [{'role': item['role'], 'content': item['content']} for item in items]
    except Exception as e:
        print(f"DynamoDB read error: {e}")
        return []


def save_message(phone_number, timestamp, role, content):
    try:
        CONVERSATION_TABLE.put_item(Item={
            'phone_number': phone_number,
            'timestamp': timestamp,
            'role': role,
            'content': content[:5000]
        })
    except Exception as e:
        print(f"DynamoDB write error: {e}")


def send_reply(to, text):
    secrets = get_secrets()
    url = f"https://graph.facebook.com/v21.0/{secrets['phone_number_id']}/messages"

    if len(text) > 4000:
        chunks = [text[i:i+4000] for i in range(0, len(text), 4000)]
        for chunk in chunks:
            _send_text(url, secrets['access_token'], to, chunk)
    else:
        _send_text(url, secrets['access_token'], to, text)


def _send_text(url, token, to, text):
    payload = {
        "messaging_product": "whatsapp",
        "recipient_type": "individual",
        "to": to,
        "type": "text",
        "text": {"preview_url": False, "body": text}
    }
    resp = http.request(
        'POST', url,
        body=json.dumps(payload),
        headers={
            'Content-Type': 'application/json',
            'Authorization': f'Bearer {token}'
        }
    )
    print(f"WhatsApp API: {resp.status} {resp.data.decode()}")
LAMBDA

cd /tmp && zip -j lambda_function.zip lambda_function.py

echo "  Waiting 10s for IAM propagation..."
sleep 10

ROLE_ARN=$(aws iam get-role --role-name proofsheet-lambda-role --query Role.Arn --output text)

aws lambda create-function \
  --function-name proofsheet-webhook \
  --runtime python3.12 \
  --handler lambda_function.lambda_handler \
  --role $ROLE_ARN \
  --zip-file fileb:///tmp/lambda_function.zip \
  --timeout 30 \
  --memory-size 512 \
  --architectures arm64 \
  --region $REGION 2>/dev/null && echo "  Lambda created" || \
(aws lambda update-function-code \
  --function-name proofsheet-webhook \
  --zip-file fileb:///tmp/lambda_function.zip \
  --region $REGION > /dev/null && echo "  Lambda updated")

# 6. API Gateway
echo "[6/7] Creating API Gateway..."
API_ID=$(aws apigatewayv2 create-api \
  --name proofsheet-webhook \
  --protocol-type HTTP \
  --region $REGION \
  --query ApiId --output text)

LAMBDA_ARN=$(aws lambda get-function \
  --function-name proofsheet-webhook \
  --region $REGION \
  --query Configuration.FunctionArn --output text)

INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type AWS_PROXY \
  --integration-uri $LAMBDA_ARN \
  --payload-format-version 2.0 \
  --region $REGION \
  --query IntegrationId --output text)

aws apigatewayv2 create-route \
  --api-id $API_ID \
  --route-key "GET /webhook" \
  --target "integrations/$INTEGRATION_ID" \
  --region $REGION > /dev/null

aws apigatewayv2 create-route \
  --api-id $API_ID \
  --route-key "POST /webhook" \
  --target "integrations/$INTEGRATION_ID" \
  --region $REGION > /dev/null

aws apigatewayv2 create-stage \
  --api-id $API_ID \
  --stage-name '$default' \
  --auto-deploy \
  --region $REGION > /dev/null

echo "  API Gateway created"

# 7. Permission
echo "[7/7] Setting permissions..."
aws lambda add-permission \
  --function-name proofsheet-webhook \
  --statement-id apigateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" \
  --region $REGION 2>/dev/null || true

echo "  Done"

echo ""
echo "=========================================="
echo "SETUP COMPLETE"
echo "=========================================="
echo ""
echo "WEBHOOK URL (paste into Meta dashboard):"
echo "https://${API_ID}.execute-api.${REGION}.amazonaws.com/webhook"
echo ""
echo "VERIFY TOKEN (paste into Meta dashboard):"
echo "${VERIFY_TOKEN}"
echo ""
echo "=========================================="
echo "NEXT STEPS:"
echo "1. Go to Meta Developer Dashboard"
echo "2. WhatsApp > Configuration > Webhook"
echo "3. Callback URL = the webhook URL above"
echo "4. Verify Token = ${VERIFY_TOKEN}"
echo "5. Click Verify and Save"
echo "6. Subscribe to messages webhook field"
echo "7. Reply hi to the test number on WhatsApp"
echo "=========================================="
echo ""
echo "To check logs:"
echo "aws logs tail /aws/lambda/proofsheet-webhook --since 5m --region $REGION"