#!/bin/bash
set -e

# Dev tool (Bonus 3, tech-design.md §15): simulates a real Twilio
# delivery-status callback against a running instance of this app, to
# prove the webhook works end-to-end without needing a real Twilio
# account. Signs up a throwaway user, sends a message (capturing its
# fake/real external_sid), builds a genuinely valid X-Twilio-Signature by
# hand (Twilio's publicly documented algorithm — see
# spec/requests/api/v1/webhooks/twilio_status_spec.rb for the same logic
# in Ruby), posts a simulated "delivered" callback, then re-fetches
# messages so you can confirm status actually flipped from sent to
# delivered.
#
# Prerequisite: TWILIO_AUTH_TOKEN and TWILIO_STATUS_CALLBACK_URL must
# already be set on the target backend's environment (the webhook is
# disabled/503 otherwise, by design — see §15.5). AUTH_TOKEN below MUST
# match whatever TWILIO_AUTH_TOKEN is set to there.
#
# Usage:
#   BASE_URL=https://your-backend.onrender.com \
#   AUTH_TOKEN=whatever-you-set-in-render \
#   ./script/test_webhook.sh

BASE="${BASE_URL:-http://localhost:3000}"
AUTH_TOKEN="${AUTH_TOKEN:?Set AUTH_TOKEN to match TWILIO_AUTH_TOKEN on the target backend}"
CALLBACK_URL="$BASE/api/v1/webhooks/twilio/status"

COOKIE_JAR=$(mktemp)
USERNAME="webhooktest$RANDOM"
PASSWORD="correct-horse-battery"

cleanup() { rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

echo "Target: $BASE"
echo "1) Signing up as $USERNAME..."
curl -s -c "$COOKIE_JAR" -X POST "$BASE/api/v1/auth/signup" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" > /dev/null

echo "2) Sending a message (creates a record with an external_sid)..."
CREATE_RESPONSE=$(curl -s -b "$COOKIE_JAR" -X POST "$BASE/api/v1/messages" \
  -H "Content-Type: application/json" \
  -d '{"to_number":"+15005550006","body":"webhook test"}')
echo "   Response: $CREATE_RESPONSE"

SID=$(echo "$CREATE_RESPONSE" | grep -o '"external_sid":"[^"]*"' | sed 's/.*:"//;s/"$//')
echo "   external_sid: $SID"

if [ -z "$SID" ]; then
  echo "Could not extract external_sid from the create response — aborting." >&2
  exit 1
fi

echo "3) Building a valid Twilio signature for a 'delivered' callback..."
DATA="${CALLBACK_URL}MessageSid${SID}MessageStatusdelivered"
SIGNATURE=$(printf '%s' "$DATA" | openssl dgst -sha1 -hmac "$AUTH_TOKEN" -binary | openssl base64)
echo "   Signature: $SIGNATURE"

echo "4) Sending the simulated Twilio webhook..."
curl -s -i -X POST "$CALLBACK_URL" \
  -H "X-Twilio-Signature: $SIGNATURE" \
  --data-urlencode "MessageSid=$SID" \
  --data-urlencode "MessageStatus=delivered"
echo

echo "5) Re-fetching messages to confirm the status actually changed..."
curl -s -b "$COOKIE_JAR" "$BASE/api/v1/messages"
echo
