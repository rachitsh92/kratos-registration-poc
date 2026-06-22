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
./test_flow.sh testuser@poc.local
```

The script will:
1. Initialize a registration flow
2. Submit the email → Kratos sends OTP via MailSlurper
3. Prompt you to open MailSlurper (http://localhost:4436) and enter the code
4. Complete registration and print the created identity + session token

## Manual curl Flow

### 1. Init flow
```bash
curl -s http://localhost:4433/self-service/registration/api | jq .id
```

### 2. Submit email
```bash
curl -s -X POST \
  "http://localhost:4433/self-service/registration?flow=<FLOW_ID>" \
  -H 'Content-Type: application/json' \
  -d '{"method":"code","traits":{"email":"you@example.com"}}'
```

### 3. Submit OTP
```bash
curl -s -X POST \
  "http://localhost:4433/self-service/registration?flow=<FLOW_ID>" \
  -H 'Content-Type: application/json' \
  -d '{"method":"code","code":"<OTP>","traits":{"email":"you@example.com"}}'
```

## Stop & Clean

```bash
docker compose down -v   # -v removes the SQLite volume (resets all identities)
```

## Prod Checklist (before using at IDFC)
- [ ] Replace SQLite DSN with CockroachDB DSN
- [ ] Replace `secrets.*` values with K8s secrets / Vault references
- [ ] Set `courier.smtp.connection_uri` to SES/CCG SMTP relay
- [ ] Set `log.leak_sensitive_values: false`
- [ ] Set correct `serve.public.base_url` and `cors.allowed_origins`
- [ ] Set `session.cookie.domain` to your actual domain
