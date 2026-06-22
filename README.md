# Kratos Email + OTP Registration POC

Passwordless registration using Ory Kratos native `code` method with MailSlurper for local email catching.

## Prerequisites
- Docker + Docker Compose
- curl + python3 (for test script)

## Start

```bash
docker compose up
```

Wait ~10 seconds for migrations to complete and Kratos to start.

## Verify Services

| Service         | URL                        |
|-----------------|----------------------------|
| Kratos Public   | http://localhost:4433      |
| Kratos Admin    | http://localhost:4434      |
| MailSlurper UI  | http://localhost:4436      |

Health check:
```bash
curl http://localhost:4433/health/ready
```

## Run the Test Flow

```bash
# defaults: John Doe, Acme Inc
./test_flow.sh testuser@poc.local

# custom name and company
./test_flow.sh you@example.com "Jane" "Smith" "Globex Corp"
```

The script will:
1. Initialize a registration flow
2. Submit email, name, and company → Kratos sends OTP via MailSlurper
3. Prompt you to open MailSlurper (http://localhost:4436) and enter the code
4. Complete registration and print the created identity + session token
5. Automatically call `/sessions/whoami` to verify the session

## Manual curl Flow

### 1. Init flow
```bash
FLOW_ID=$(curl -s http://localhost:4433/self-service/registration/api | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
```

### 2. Submit traits (triggers OTP email)
```bash
curl -s -X POST \
  "http://localhost:4433/self-service/registration?flow=${FLOW_ID}" \
  -H 'Content-Type: application/json' \
  -d '{
    "method": "code",
    "traits": {
      "email": "you@example.com",
      "name": { "first": "Jane", "last": "Smith" },
      "company": "Globex Corp"
    }
  }'
```

### 3. Submit OTP (completes registration)
```bash
curl -s -X POST \
  "http://localhost:4433/self-service/registration?flow=${FLOW_ID}" \
  -H 'Content-Type: application/json' \
  -d '{
    "method": "code",
    "code": "<OTP_FROM_MAILSLURPER>",
    "traits": {
      "email": "you@example.com",
      "name": { "first": "Jane", "last": "Smith" },
      "company": "Globex Corp"
    }
  }'
```

The response contains the created identity and a `session_token`:

```json
{
  "session_token": "ory_st_...",
  "identity": {
    "id": "...",
    "traits": {
      "email": "you@example.com",
      "name": { "first": "Jane", "last": "Smith" },
      "company": "Globex Corp"
    }
  }
}
```

## Session / Whoami

After registration (or login), Kratos returns a `session_token`. Use it to verify the session and fetch the authenticated identity.

### Endpoint

```
GET /sessions/whoami
Authorization: Bearer <session_token>
```

### curl

```bash
curl -s http://localhost:4433/sessions/whoami \
  -H "Authorization: Bearer <session_token>" | python3 -m json.tool
```

### Example response

```json
{
  "id": "<session_id>",
  "active": true,
  "expires_at": "2026-06-23T10:25:39Z",
  "authenticated_at": "2026-06-22T10:25:39Z",
  "authenticator_assurance_level": "aal1",
  "authentication_methods": [
    {
      "method": "code",
      "aal": "aal1",
      "completed_at": "2026-06-22T10:25:39Z"
    }
  ],
  "identity": {
    "id": "<identity_id>",
    "traits": {
      "email": "you@example.com",
      "name": { "first": "Jane", "last": "Smith" },
      "company": "Globex Corp"
    },
    "created_at": "2026-06-22T10:25:39Z",
    "updated_at": "2026-06-22T10:25:39Z"
  }
}
```

### Key fields

| Field | Description |
|-------|-------------|
| `active` | `true` if the session is valid and not expired |
| `expires_at` | When the session expires (default: 24h after creation) |
| `authenticated_at` | When the OTP was verified |
| `authenticator_assurance_level` | `aal1` = single factor (OTP). `aal2` = MFA |
| `identity.traits` | The user's email, name, and company |

### Usage in your app

Your backend should call `/sessions/whoami` on every request to validate the token passed by the client. If `active` is `false` or the call returns `401`, the session has expired and the user must re-authenticate.

## Admin: Identities

### List all identities
```bash
curl -s http://localhost:4434/admin/identities | python3 -m json.tool
```

### Look up identity by email
```bash
curl -s "http://localhost:4434/admin/identities?credentials_identifier=you@example.com" | python3 -m json.tool
```

This is an indexed lookup — Kratos queries directly by the credential identifier, not a full table scan. Safe to use in production with millions of identities.

### Extract just the identity ID
```bash
curl -s "http://localhost:4434/admin/identities?credentials_identifier=you@example.com" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else 'not found')"
```

> **Note:** Identity lookup is admin-only (`localhost:4434`). The public API has no email lookup endpoint by design — exposing one would be a data leak. Never expose port 4434 outside your backend.

## Stop & Clean

```bash
docker compose down -v   # -v removes the SQLite volume (resets all identities)
```

## Prod Checklist
- [ ] Replace SQLite DSN with CockroachDB DSN
- [ ] Replace `secrets.*` values with K8s secrets / Vault references
- [ ] Set `courier.smtp.connection_uri` to SES/CCG SMTP relay
- [ ] Set `log.leak_sensitive_values: false`
- [ ] Set correct `serve.public.base_url` and `cors.allowed_origins`
- [ ] Set `session.cookie.domain` to your actual domain
