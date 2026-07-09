# Central Identity Provider (CIP) — Multi-Tenant Data Model & Flows

**Scope:** This document covers the identity core of the CIP — registration, credential storage, and login — for a multi-tenant setup where each tenant (integrator) defines its own identity trait schema. Token issuance (Hydra/OAuth2) is out of scope; the CIP acts purely as the identity/authentication layer.

**Worked tenants:** `tradex` (email + PAN based) and `quantumcash` (phone based) — used throughout for concrete examples.

---

## 1. Design Principles

1. **One set of tables serves all tenants.** No per-tenant table or database — tenant isolation is enforced by a `tenant_id` column on every row, present in every query.
2. **Fixed fields vs. variable fields are separated.** Universal identity fields (id, state, timestamps) live as real columns. Tenant-specific fields (email vs. phone, PAN vs. wallet ID) live in a `traits JSONB` column, validated against a per-tenant JSON Schema at write time — never enforced structurally by the table.
3. **"The person" and "the ways to prove it's them" are separate concerns.** An identity can have multiple credential types (password, OTP, WebAuthn), and each credential can have multiple lookup identifiers (email, username). Splitting these into their own tables lets either evolve independently.
4. **Uniqueness is tenant-scoped, not global.** The same email or phone number can legitimately belong to different people at different tenants — uniqueness constraints always include `tenant_id`.
5. **Database:** CockroachDB — chosen for ACID guarantees on credential writes, native JSONB for trait flexibility, and multi-region support for data-residency requirements.

---

## 2. Data Model

### 2.1 `tenants`

The root of everything — every other table hangs off this.

| Column | Type | Notes |
|---|---|---|
| `id` | UUID (PK) | |
| `slug` | TEXT, UNIQUE | e.g. `tradex`, `quantumcash` |
| `name` | TEXT | display name |
| `active_schema_id` | UUID (FK → identity_schemas.id) | currently live schema version |
| `created_at`, `updated_at` | TIMESTAMPTZ | |

**Example rows:**

| id | slug | name |
|---|---|---|
| `T1` | `tradex` | TradeX Securities |
| `T2` | `quantumcash` | QuantumCash Wallet |

---

### 2.2 `identity_schemas`

Versioned registry of each tenant's identity "form definition" — the JSON Schema that `traits` must validate against. Equivalent to Kratos's schema server, but stored in-DB.

| Column | Type | Notes |
|---|---|---|
| `id` | UUID (PK) | |
| `tenant_id` | UUID (FK → tenants.id) | |
| `version` | INT | monotonically increasing per tenant |
| `json_schema` | JSONB | the schema document |
| `created_at` | TIMESTAMPTZ | |

**TradeX schema (S1, v1):**
```json
{
  "$id": "tradex-v1",
  "type": "object",
  "properties": {
    "email": { "type": "string", "format": "email" },
    "pan": { "type": "string", "pattern": "^[A-Z]{5}[0-9]{4}[A-Z]$" },
    "demat_account": { "type": "string" },
    "full_name": { "type": "string" },
    "mobile": { "type": "string" }
  },
  "required": ["email", "pan", "full_name"]
}
```

**QuantumCash schema (S2, v1):**
```json
{
  "$id": "quantumcash-v1",
  "type": "object",
  "properties": {
    "phone": { "type": "string", "pattern": "^\\+91[0-9]{10}$" },
    "wallet_id": { "type": "string" },
    "kyc_tier": { "type": "string", "enum": ["basic", "full"] }
  },
  "required": ["phone", "wallet_id"]
}
```

---

### 2.3 `identities`

One row per person, across all tenants.

| Column | Type | Notes |
|---|---|---|
| `id` | UUID (PK) | |
| `tenant_id` | UUID (FK → tenants.id) | never nullable, present in every query |
| `schema_id` | UUID (FK → identity_schemas.id) | schema version this row was validated against |
| `traits` | JSONB | tenant-specific payload |
| `state` | TEXT | `active`, `inactive`, `locked` |
| `created_at`, `updated_at` | TIMESTAMPTZ | |

Indexes: `(tenant_id, state)`; inverted index on `traits` for path lookups.

**Example rows:**

| id | tenant_id | schema_id | traits | state |
|---|---|---|---|---|
| `IDT-AAAA` | `T1` | `S1` | `{email: rachit@example.com, pan: ABCDE1234F, demat_account: 1203840000123456, full_name: Rachit Kumar}` | active |
| `IDT-DDDD` | `T2` | `S2` | `{phone: +919876543210, wallet_id: QC-WAL-99812, kyc_tier: basic}` | active |

---

### 2.4 `identity_credentials`

"The lock" — how a person proves who they are. One identity can have multiple rows here (password, OTP, WebAuthn), each verified differently.

| Column | Type | Notes |
|---|---|---|
| `id` | UUID (PK) | |
| `identity_id` | UUID (FK → identities.id) | |
| `tenant_id` | UUID | denormalized to avoid a join for tenant-scoped queries/RLS |
| `type` | TEXT | `password`, `otp`, `webauthn`, `oidc` |
| `config` | JSONB | credential-type-specific payload — never raw secrets, always hashed |
| `created_at`, `updated_at` | TIMESTAMPTZ | |

**Example — Rachit at TradeX, with two credential types:**

| id | identity_id | tenant_id | type | config |
|---|---|---|---|---|
| `CRED-BBBB` | `IDT-AAAA` | `T1` | password | `{hashed_password: "$argon2id$v=19$...", hash_algo: "argon2id"}` |
| `CRED-HHHH` | `IDT-AAAA` | `T1` | otp | `{phone: "+919876543210", otp_channel: "sms"}` |

Note: password hashing uses Argon2id (current recommended default), not bcrypt.

---

### 2.5 `identity_credential_identifiers`

"The label on the lock" — the lookup key a person types to start a login (email, phone, username), pointing at which credential it belongs to. Exists as its own table because one credential can be reachable by more than one label, and different tenants use entirely different identifier types.

| Column | Type | Notes |
|---|---|---|
| `id` | UUID (PK) | |
| `tenant_id` | UUID | |
| `identity_credential_id` | UUID (FK) | |
| `identifier` | TEXT | e.g. `rachit@example.com`, `+919876543210` |
| Constraint | `UNIQUE (tenant_id, identifier, identity_credential_id)` | scoped per tenant — same identifier can exist at two different tenants for two different people; loosen further if one identifier should map to multiple credential types for the same person |

**Example rows:**

| id | tenant_id | identity_credential_id | identifier |
|---|---|---|---|
| `IDR-CCCC` | `T1` | `CRED-BBBB` | `rachit@example.com` |
| `IDR-IIII` | `T1` | `CRED-HHHH` | `+919876543210` |
| `IDR-FFFF` | `T2` | `CRED-EEEE` | `+919876543210` |

Note the last row: the same phone number `+919876543210` is a valid identifier at both TradeX (as a secondary OTP identifier) and QuantumCash (as the primary identifier) — for two entirely different people. This is only possible because uniqueness is scoped to `tenant_id`.

---

### 2.6 Relationship Chain

```
tenants (1)
   │
   ├──► identity_schemas (1 tenant → many schema versions)
   │
   └──► identities (1 tenant → many people)
              │
              └──► identity_credentials (1 person → many credential types)
                          │
                          └──► identity_credential_identifiers (1 credential → many lookup labels)
```

Data flows **down** on registration (tenant → person → credential → identifier).
Lookups flow **up** on login (identifier → credential → person).

---

## 3. Registration Flow — Full Trace

### 3.1 TradeX registration

**Request:**
```
POST /tenants/tradex/self-service/registration
{
  "traits": {
    "email": "rachit@example.com",
    "pan": "ABCDE1234F",
    "demat_account": "1203840000123456",
    "full_name": "Rachit Kumar"
  },
  "password": "S0meStr0ngP@ss!"
}
```

| Step | Action | Table touched |
|---|---|---|
| 1 | Resolve tenant: `slug='tradex'` → `tenant_id=T1`, `active_schema_id=S1` | `tenants` (read) |
| 2 | Load schema `S1`, validate submitted `traits` against it — required fields present, PAN regex matches | `identity_schemas` (read) |
| 3 | Uniqueness pre-check: `SELECT 1 FROM identity_credential_identifiers WHERE tenant_id='T1' AND identifier='rachit@example.com'` → not found | `identity_credential_identifiers` (read) |
| 4 | **Transaction:** insert identity, credential, identifier atomically | `identities`, `identity_credentials`, `identity_credential_identifiers` (write) |

**Transaction:**
```sql
BEGIN;

INSERT INTO identities (id, tenant_id, schema_id, traits, state, created_at, updated_at)
VALUES ('IDT-AAAA', 'T1', 'S1',
  '{"email":"rachit@example.com","pan":"ABCDE1234F","demat_account":"1203840000123456","full_name":"Rachit Kumar"}',
  'active', now(), now());

INSERT INTO identity_credentials (id, identity_id, tenant_id, type, config, created_at, updated_at)
VALUES ('CRED-BBBB', 'IDT-AAAA', 'T1', 'password',
  '{"hashed_password":"$argon2id$v=19$m=65536,t=3,p=4$...","hash_algo":"argon2id"}',
  now(), now());

INSERT INTO identity_credential_identifiers (id, tenant_id, identity_credential_id, identifier)
VALUES ('IDR-CCCC', 'T1', 'CRED-BBBB', 'rachit@example.com');

COMMIT;
```

Single transaction is deliberate: if the process crashes mid-way, a partial write (e.g. an identity with no credential) would create a ghost account that can never log in.

**Response:**
```json
{ "identity_id": "IDT-AAAA", "state": "active" }
```

### 3.2 QuantumCash registration

**Request:**
```
POST /tenants/quantumcash/self-service/registration
{
  "traits": {
    "phone": "+919876543210",
    "wallet_id": "QC-WAL-99812",
    "kyc_tier": "basic"
  },
  "password": "An0therStr0ngP@ss!"
}
```

Same 4 steps, resolved against `T2` / `S2` instead:

```sql
BEGIN;

INSERT INTO identities (id, tenant_id, schema_id, traits, state, created_at, updated_at)
VALUES ('IDT-DDDD', 'T2', 'S2',
  '{"phone":"+919876543210","wallet_id":"QC-WAL-99812","kyc_tier":"basic"}',
  'active', now(), now());

INSERT INTO identity_credentials (id, identity_id, tenant_id, type, config, created_at, updated_at)
VALUES ('CRED-EEEE', 'IDT-DDDD', 'T2', 'password',
  '{"hashed_password":"$argon2id$v=19$...","hash_algo":"argon2id"}',
  now(), now());

INSERT INTO identity_credential_identifiers (id, tenant_id, identity_credential_id, identifier)
VALUES ('IDR-FFFF', 'T2', 'CRED-EEEE', '+919876543210');

COMMIT;
```

**Result — same tables, two structurally different `traits` payloads coexisting:**

| id | tenant_id | traits |
|---|---|---|
| `IDT-AAAA` | `T1` | `{email, pan, demat_account, full_name}` |
| `IDT-DDDD` | `T2` | `{phone, wallet_id, kyc_tier}` |

### 3.3 Adding a second credential (OTP) to the existing TradeX identity

No new `identities` row — only new `identity_credentials` + `identity_credential_identifiers` rows, linked to the existing `IDT-AAAA`:

```sql
BEGIN;

INSERT INTO identity_credentials (id, identity_id, tenant_id, type, config, created_at, updated_at)
VALUES ('CRED-HHHH', 'IDT-AAAA', 'T1', 'otp',
  '{"phone":"+919876543210","otp_channel":"sms"}', now(), now());

INSERT INTO identity_credential_identifiers (id, tenant_id, identity_credential_id, identifier)
VALUES ('IDR-IIII', 'T1', 'CRED-HHHH', '+919876543210');

COMMIT;
```

`IDT-AAAA` now has two independent login paths — password via email, and OTP via phone — both resolving to the same person.

---

## 4. Login Flow — Full Trace

### 4.1 TradeX — password login

**Request:**
```
POST /tenants/tradex/self-service/login
{ "identifier": "rachit@example.com", "password": "S0meStr0ngP@ss!" }
```

| Step | Action | Table touched |
|---|---|---|
| 1 | Resolve tenant: `tradex` → `T1` | `tenants` |
| 2 | `SELECT identity_credential_id FROM identity_credential_identifiers WHERE tenant_id='T1' AND identifier='rachit@example.com'` → `CRED-BBBB` | `identity_credential_identifiers` |
| 3 | `SELECT config FROM identity_credentials WHERE id='CRED-BBBB' AND tenant_id='T1' AND type='password'` → verify Argon2id hash → match | `identity_credentials` |
| 4 | `SELECT id, state, traits FROM identities WHERE id='IDT-AAAA' AND tenant_id='T1'` → `state='active'` | `identities` |
| 5 | Issue session | `sessions` (new table — see note below) |

`tenant_id` is included in every single query above even though the UUID primary keys are already globally unique — this is deliberate defense-in-depth against a missing filter causing a cross-tenant leak.

### 4.2 TradeX — OTP login (same person, different door)

**Request:**
```
POST /tenants/tradex/self-service/login
{ "identifier": "+919876543210", "method": "otp" }
```

| Step | Action |
|---|---|
| 1 | Resolve tenant → `T1` |
| 2 | Lookup `identifier='+919876543210'` in `identity_credential_identifiers` (scoped to `T1`) → `CRED-HHHH` |
| 3 | `identity_credentials` row `CRED-HHHH`, `type='otp'` → send OTP to `config.phone`, verify code entered |
| 4 | Fetch `identities` via `identity_id` → same `IDT-AAAA` as the password path |
| 5 | Issue session |

Both 4.1 and 4.2 terminate at the same `identity_id` — different credential, same person.

### 4.3 QuantumCash — password login

**Request:**
```
POST /tenants/quantumcash/self-service/login
{ "identifier": "+919876543210", "password": "An0therStr0ngP@ss!" }
```

Resolves through `T2` only — note this is the *same identifier string* as TradeX's OTP identifier in 4.2, but scoped to a different tenant, so it correctly resolves to a completely different person (`IDT-DDDD`, not `IDT-AAAA`).

| Step | Action |
|---|---|
| 1 | Resolve tenant → `T2` |
| 2 | Lookup `identifier='+919876543210'` scoped to `T2` → `CRED-EEEE` |
| 3 | Verify password hash |
| 4 | Fetch `identities` → `IDT-DDDD`, `state='active'` |
| 5 | Issue session |

---

## 5. Open Items Surfaced (Not Yet Designed)

1. **Tenant resolution mechanism** — path prefix used in these examples for concreteness; still to decide between path, subdomain, or API-key-derived resolution, and how this interacts with Hydra's login redirect knowing which tenant to target.
2. **`sessions` table** — referenced in the login flow but not yet designed; needs to plug into existing session-poll/keep-alive mechanisms.
3. **Identifier-to-credential cardinality** — current constraint assumes one identifier maps to one credential; revisit if the same identifier should be usable across multiple credential types for one person (e.g. email as a label for both password and magic-link).
4. **Schema versioning/migration** — what happens to existing identities validated against schema v1 when a tenant ships v2.
5. **DB-level validation** — whether to add a CHECK constraint on `traits` as defense-in-depth alongside application-layer JSON Schema validation.
6. **Password hashing at scale** — Argon2id is CPU-heavy by design; needs non-blocking handling in the service layer.
