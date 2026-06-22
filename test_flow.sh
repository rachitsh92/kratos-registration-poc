#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Kratos Email+OTP Registration Flow — Test Script
# Usage: ./test_flow.sh [email] [first_name] [last_name] [company]
# ─────────────────────────────────────────────────────────────────

set -e

KRATOS_PUBLIC="http://localhost:4433"
EMAIL="${1:-testuser@poc.local}"
FIRST_NAME="${2:-John}"
LAST_NAME="${3:-Doe}"
COMPANY="${4:-Acme Inc}"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Kratos OTP Registration Flow"
echo "  Email   : $EMAIL"
echo "  Name    : $FIRST_NAME $LAST_NAME"
echo "  Company : $COMPANY"
echo "═══════════════════════════════════════════════════════════"

# ── Step 1: Initialize Registration Flow ─────────────────────────
echo ""
echo "▶ Step 1: Initializing registration flow..."
FLOW_RESPONSE=$(curl -s -X GET \
  "${KRATOS_PUBLIC}/self-service/registration/api" \
  -H 'Accept: application/json')

FLOW_ID=$(echo "$FLOW_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "  ✓ Flow ID: $FLOW_ID"

# ── Step 2: Submit traits → triggers OTP send via courier ─────────
echo ""
echo "▶ Step 2: Submitting details to trigger OTP send..."
curl -s -X POST \
  "${KRATOS_PUBLIC}/self-service/registration?flow=${FLOW_ID}" \
  -H 'Content-Type: application/json' \
  -d "{
    \"method\": \"code\",
    \"traits\": {
      \"email\": \"${EMAIL}\",
      \"name\": {
        \"first\": \"${FIRST_NAME}\",
        \"last\": \"${LAST_NAME}\"
      },
      \"company\": \"${COMPANY}\"
    }
  }" | python3 -c "
import sys, json
r = json.load(sys.stdin)
msgs = r.get('ui', {}).get('messages', [])
for m in msgs:
    print('  >', m.get('text',''))
" 2>/dev/null || echo "  ✓ Details submitted — check MailSlurper at http://localhost:4436"

echo ""
echo "  📬 Open http://localhost:4436 to get your OTP code"
echo ""

# ── Step 3: Prompt user for OTP ──────────────────────────────────
read -p "  Enter the OTP code from MailSlurper: " OTP_CODE

# ── Step 4: Submit OTP → completes registration ──────────────────
echo ""
echo "▶ Step 3: Submitting OTP to complete registration..."
RESULT=$(curl -s -X POST \
  "${KRATOS_PUBLIC}/self-service/registration?flow=${FLOW_ID}" \
  -H 'Content-Type: application/json' \
  -d "{
    \"method\": \"code\",
    \"code\": \"${OTP_CODE}\",
    \"traits\": {
      \"email\": \"${EMAIL}\",
      \"name\": {
        \"first\": \"${FIRST_NAME}\",
        \"last\": \"${LAST_NAME}\"
      },
      \"company\": \"${COMPANY}\"
    }
  }")

SESSION_TOKEN=$(echo "$RESULT" | python3 -c "
import sys, json
r = json.load(sys.stdin)
if 'identity' in r:
    identity = r['identity']
    traits = identity['traits']
    name = traits.get('name', {})
    print('  ✅ Registration successful!', file=sys.stderr)
    print('  Identity ID :', identity['id'], file=sys.stderr)
    print('  Email       :', traits.get('email'), file=sys.stderr)
    print('  Name        :', name.get('first',''), name.get('last',''), file=sys.stderr)
    print('  Company     :', traits.get('company',''), file=sys.stderr)
    print('  Created At  :', identity['created_at'], file=sys.stderr)
    if 'session_token' in r:
        print('  Session Token:', r['session_token'][:40] + '...', file=sys.stderr)
        print(r['session_token'])
elif 'error' in r:
    print('  ❌ Error:', r['error'].get('message', 'unknown'), file=sys.stderr)
else:
    msgs = r.get('ui', {}).get('messages', [])
    for m in msgs:
        print('  ⚠', m.get('text',''), file=sys.stderr)
    print(json.dumps(r, indent=2), file=sys.stderr)
")

# ── Step 5: Whoami ────────────────────────────────────────────────
if [ -n "$SESSION_TOKEN" ]; then
  echo ""
  echo "▶ Step 4: Verifying session (whoami)..."
  curl -s "${KRATOS_PUBLIC}/sessions/whoami" \
    -H "Authorization: Bearer ${SESSION_TOKEN}" | python3 -c "
import sys, json
r = json.load(sys.stdin)
identity = r.get('identity', {})
traits = identity.get('traits', {})
name = traits.get('name', {})
print('  ✓ Session active     :', r.get('active'))
print('  ✓ Session ID         :', r.get('id'))
print('  ✓ Identity ID        :', identity.get('id'))
print('  ✓ Email              :', traits.get('email'))
print('  ✓ Name               :', name.get('first',''), name.get('last',''))
print('  ✓ Company            :', traits.get('company',''))
print('  ✓ Expires At         :', r.get('expires_at'))
"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
