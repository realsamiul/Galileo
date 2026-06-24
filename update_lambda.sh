#!/bin/bash
set -e

REGION="us-west-2"

# ==========================================
# 1. UPDATE SECRETS MANAGER
# ==========================================

echo "[1/2] Updating secrets with Page Access Token..."

AWS_PAGER="" aws secretsmanager update-secret \
  --secret-id proofsheet/whatsapp \
  --secret-string '{
    "access_token":"EAAfsLZAnDzj4BRqZAag5FkZAy98KKEZC8HD8IA0PGrwcG1kCys0gGCFXXFin0lUtzvPJQU1Lka5oYzuM2wLroZCleK9c5LSp5ZAp3gGNvj5Y0du9ZAd1zQyDqAKQMp6UDkvmRbQZB8ccuT9DFNbYbkelAZACZAa9CfQTY1mfJvuGqZBjXl7Rxh9Lle6cBaONdijEZCsUHzAFqHz5Dg3EKzNlkMPUNwPJPL92JTUCbSFKoWqU4pG08LdfiCxMeQZDZD",
    "phone_number_id":"1213332605203066",
    "verify_token":"proofsheet-verify-2024",
    "page_access_token":"EAAfsLZAnDzj4BRoNUIHofv7M6y7QjE9lvrVXiMmZBnh6ZBDBShvcbZCporbfSD61mC3vTNIjkpyDDaNZAPDQbGOjsYmnnZBe26RSll7VPuD09ZAQOZAtg8xf47sj2hfSFYyoUS4QK2Qc6bkFtRUMu2onYJKITDH9bWr4aiqzZCAhHRK3kkfsi6sIbeo5RNZCuX7tPjzln9tp5foAZDZD"
  }' \
  --region $REGION

echo "  Secrets updated"

# ==========================================
# 2. UPDATE LAMBDA CODE
# ==========================================

echo "[2/2] Updating Lambda function code..."

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


# ==========================================
# MAIN HANDLER
# ==========================================

def lambda_handler(event, context):
    print(f"Event: {json.dumps(event)}")
    method = event.get('requestContext', {}).get('http', {}).get('method', 'POST')

    if method == 'GET':
        return handle_verification(event)

    try:
        body = json.loads(event.get('body', '{}'))
    except json.JSONDecodeError:
        return {'statusCode': 200}

    obj = body.get('object', '')

    if obj == 'whatsapp_business_account':
        handle_whatsapp(body)
    elif obj == 'page':
        handle_messenger(body)
    else:
        print(f"Unknown object type: {obj}")

    return {'statusCode': 200}


def handle_verification(event):
    params = event.get('queryStringParameters', {}) or {}
    mode = params.get('hub.mode', '')
    token = params.get('hub.verify_token', '')
    challenge = params.get('hub.challenge', '')

    print(f"Verify: mode={mode} token={token}")
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


# ==========================================
# CHANNEL: WHATSAPP
# ==========================================

def handle_whatsapp(body):
    for entry in body.get('entry', []):
        for change in entry.get('changes', []):
            value = change.get('value', {})
            if 'messages' not in value:
                continue
            for message in value['messages']:
                sender = message['from']
                msg_type = message['type']

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
                    send_whatsapp_reply(sender, "Right now I support text only. Voice & image coming soon!")
                    return

                process_and_respond(sender, user_text, 'whatsapp')


# ==========================================
# CHANNEL: MESSENGER
# ==========================================

def handle_messenger(body):
    for entry in body.get('entry', []):
        for messaging_event in entry.get('messaging', []):
            if messaging_event.get('message', {}).get('is_echo'):
                continue

            sender_id = messaging_event['sender']['id']

            if 'message' in messaging_event:
                message = messaging_event['message']

                if 'text' in message:
                    user_text = message['text']
                elif 'attachments' in message:
                    send_messenger_reply(sender_id, "Right now I support text only. Voice & image coming soon!")
                    return
                else:
                    return

                process_and_respond(sender_id, user_text, 'messenger')

            elif 'postback' in messaging_event:
                payload = messaging_event['postback'].get('payload', '')
                title = messaging_event['postback'].get('title', payload)
                process_and_respond(sender_id, title, 'messenger')


# ==========================================
# CORE LOGIC
# ==========================================

def process_and_respond(sender_id, user_text, channel):
    timestamp = datetime.now(timezone.utc).isoformat()

    print(f"[{channel}] From: {sender_id} Text: {user_text}")

    history = get_conversation_history(sender_id)
    assistant_response = call_bedrock(user_text, history)

    print(f"[{channel}] Response: {assistant_response[:200]}")

    if channel == 'whatsapp':
        send_whatsapp_reply(sender_id, assistant_response)
    elif channel == 'messenger':
        send_messenger_reply(sender_id, assistant_response)

    save_message(sender_id, timestamp, 'user', user_text)
    save_message(sender_id, timestamp + '_r', 'assistant', assistant_response)


# ==========================================
# BEDROCK
# ==========================================

SYSTEM_PROMPT = """You are ProofSheet, a professional document assistant on messaging platforms, serving users in Bangladesh.

You help create professional documents from conversational input.

RULES:
- Reply in whatever language the user writes in (Bangla, English, or mixed Banglish)
- Be conversational and efficient - ask max 2-3 questions before you have enough info
- Group your questions (don't ask one field at a time)
- Make smart assumptions (today's date, standard formats, BDT currency)
- Be friendly but respect the user's time
- Use emoji sparingly

CAPABILITIES: invoices, receipts, business letters, leave applications, experience certificates, formal applications, agreements.

If someone just says hi, introduce yourself in 2-3 lines and ask what document they need."""


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
        return "Sorry, something went wrong on my end. Please try again in a moment."


# ==========================================
# CONVERSATION MEMORY
# ==========================================

def get_conversation_history(sender_id):
    try:
        from boto3.dynamodb.conditions import Key
        response = CONVERSATION_TABLE.query(
            KeyConditionExpression=Key('phone_number').eq(sender_id),
            ScanIndexForward=False,
            Limit=20
        )
        items = response.get('Items', [])
        items.reverse()
        return [{'role': item['role'], 'content': item['content']} for item in items]
    except Exception as e:
        print(f"DynamoDB read error: {e}")
        return []


def save_message(sender_id, timestamp, role, content):
    try:
        CONVERSATION_TABLE.put_item(Item={
            'phone_number': sender_id,
            'timestamp': timestamp,
            'role': role,
            'content': content[:5000]
        })
    except Exception as e:
        print(f"DynamoDB write error: {e}")


# ==========================================
# WHATSAPP SEND
# ==========================================

def send_whatsapp_reply(to, text):
    secrets = get_secrets()
    url = f"https://graph.facebook.com/v21.0/{secrets['phone_number_id']}/messages"

    if len(text) > 4000:
        chunks = [text[i:i+4000] for i in range(0, len(text), 4000)]
        for chunk in chunks:
            _send_whatsapp_text(url, secrets['access_token'], to, chunk)
    else:
        _send_whatsapp_text(url, secrets['access_token'], to, text)


def _send_whatsapp_text(url, token, to, text):
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
    print(f"WhatsApp send: {resp.status} {resp.data.decode()[:200]}")


# ==========================================
# MESSENGER SEND
# ==========================================

def send_messenger_reply(recipient_id, text):
    secrets = get_secrets()
    token = secrets.get('page_access_token', '')

    if not token:
        print("ERROR: No page_access_token in secrets")
        return

    url = f"https://graph.facebook.com/v21.0/me/messages?access_token={token}"

    if len(text) > 2000:
        chunks = [text[i:i+2000] for i in range(0, len(text), 2000)]
        for chunk in chunks:
            _send_messenger_text(url, recipient_id, chunk)
    else:
        _send_messenger_text(url, recipient_id, text)


def _send_messenger_text(url, recipient_id, text):
    payload = {
        "recipient": {"id": recipient_id},
        "message": {"text": text},
        "messaging_type": "RESPONSE"
    }
    resp = http.request(
        'POST', url,
        body=json.dumps(payload),
        headers={'Content-Type': 'application/json'}
    )
    print(f"Messenger send: {resp.status} {resp.data.decode()[:200]}")
LAMBDA

cd /tmp && zip -j lambda_function.zip lambda_function.py

AWS_PAGER="" aws lambda update-function-code \
  --function-name proofsheet-webhook \
  --zip-file fileb:///tmp/lambda_function.zip \
  --region $REGION

echo ""
echo "=========================================="
echo "LAMBDA UPDATED - Now supports both WhatsApp and Messenger"
echo "=========================================="
echo ""
echo "NEXT: Add Messenger product to your Meta App"
echo "1. developers.facebook.com/apps -> your app -> Add Products -> Messenger"
echo "2. Generate Page Access Token for your Facebook Page"
echo "3. Update Secrets Manager with the page_access_token"
echo "4. Configure webhook: same URL, same verify token"
echo "5. Subscribe to 'messages' field"
echo "6. Message your Facebook Page -- it should reply"
echo "=========================================="