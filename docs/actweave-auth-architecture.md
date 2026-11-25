# ActWeave Replica Hub Authentication & Per-Repository Authorization Architecture (Loop 1)

This document defines the architecture, data model, security boundaries, and staged delivery plan for Loop 1 of ActWeave's self-maintained Replica Hub (`hub/`): **Rails-native Email (Resend OTP) + Generic OIDC (including Google) authentication, per-repository authorization, and unified authentication across production and Local Mode**.

> **Public repository boundary**: Never commit real deployment domains, NAS/host IPs, API keys, OAuth secrets, or personal email addresses to this repository. Tests and documentation must use placeholder values such as `example.com` and `example.invalid`.

---

## 1. Goals and Non-Goals

### Goals

1. **Rails-native unified authentication**: Support email 6-digit one-time verification code login (via Resend HTTPS API) and generic OIDC login (supporting Google and any standards-compliant OIDC provider) directly inside Rails 8, reusing Hub's existing encrypted `Session`, `SessionRevocation`, `SecurityRateLimiting`, and `SecurityAuditEvent` primitives.
2. **Email allowlist admission**: Only allowlisted email addresses may sign in via email OTP or OIDC. Initial allowlist and initial Hub administrators can be bootstrapped through environment variables and maintained in the Hub admin UI.
3. **Per-repository authorization**: Grant each allowlisted user explicit per-repository roles (`read`, `write`, `admin`) without requiring a GitHub account or GitHub repository permission check.
4. **Account unification by verified email**: Signing in with email OTP and later signing in with an OIDC provider returning the same verified email resolves to the same `User` record, preserving comments, notifications, and repository permissions.
5. **Unified auth across Production and Local Mode**: Allow Local Mode (`REPLICA_LOCAL_MODE=1`, serving local filesystem repositories without GitHub Actions) to run the exact same Email/OIDC authentication and per-repository authorization stack as production when unified auth is enabled, while preserving the default zero-config `Open local Hub` fallback so existing upstream tests continue to pass unchanged.

### Non-Goals (Loop 1)

- Deploying an external Node.js / Better Auth sidecar service.
- Replacing or breaking existing GitHub OAuth sign-in when a GitHub App is configured.
- Building a NAS-side prototype builder / Actions replacement (scheduled for Loop 2).
- Opening unauthenticated Local Mode on non-localhost production origins.

---

## 2. Core Data Model

### 2.1 `users` table evolution

Existing schema enforces `index_users_on_one_local_identity` on `WHERE github_id IS NULL` and derives `User#local?` from `github_id.nil?`. To support non-GitHub users safely:

- Add `identity_kind` (`string`, not null, check constraint `IN ('local', 'github', 'external')`):
  - Existing rows with `github_id IS NOT NULL` backfill to `'github'`.
  - Existing rows with `github_id IS NULL` backfill to `'local'`.
  - Email / OIDC users use `'external'`.
- Add `email` (`string`, nullable, normalized lowercase + trimmed, partial unique index `WHERE email IS NOT NULL`).
- Replace `index_users_on_one_local_identity` (`WHERE github_id IS NULL`) with a unique partial index on `WHERE identity_kind = 'local'`.
- Update `User#local?` to `identity_kind == "local"`.
- Keep `User#hub_admin?` valid for both `'github'` and `'external'` users (never `'local'`).

### 2.2 `user_identities`

Links one `User` to one or more external login identities:

- `user_id` (FK -> `users`, not null)
- `provider` (`string`, not null — e.g. `"email"`, `"oidc:<slug>"`, `"github"`)
- `issuer` (`string`, nullable — OIDC `iss` URL for OIDC identities)
- `subject` (`string`, not null — normalized email for `"email"`, OIDC `sub` for OIDC)
- `email` (`string`, nullable, normalized)
- `email_verified` (`boolean`, default `false`, not null)
- `last_signed_in_at` (`datetime`)
- Unique index on `(provider, subject)`.

### 2.3 `auth_allowlist_entries`

Controls who is permitted to authenticate via Email OTP or OIDC:

- `email` (`string`, not null, normalized lowercase + trimmed, unique index)
- `hub_admin` (`boolean`, default `false`, not null)
- `added_by_id` (nullable FK -> `users`)
- `notes` (`string`, nullable)
- Environment bootstrap (idempotent on boot/auth check, never overwriting revocations unless configured):
  - `REPLICA_AUTH_ALLOWLIST_EMAILS`: comma-separated normalized emails seeded as allowlisted entries.
  - `REPLICA_AUTH_BOOTSTRAP_ADMIN_EMAILS`: comma-separated normalized emails seeded as allowlisted `hub_admin: true` entries.

### 2.4 `repository_memberships`

Explicit per-repository access grants:

- `repository_id` (FK -> `repositories`, not null)
- `user_id` (FK -> `users`, not null)
- `role` (`string`, not null, check constraint `IN ('read', 'write', 'admin')`)
- `granted_by_id` (nullable FK -> `users`)
- Unique index on `(repository_id, user_id)`.

### 2.5 `email_login_challenges`

Short-lived one-time verification codes for Resend email login:

- `email` (`string`, not null, normalized)
- `code_digest` (`string`, not null — HMAC-SHA256 / secure digest, never plaintext)
- `expires_at` (`datetime`, not null — 10 minutes TTL)
- `attempts` (`integer`, default `0`, not null — max 5 attempts)
- `consumed_at` (`datetime`, nullable)
- `request_ip` (`string`, nullable)
- Index on `(email, created_at)` and `expires_at`.

---

## 3. Authorization Architecture

### 3.1 `Repository::Authorization`

Normalize effective permission for `(repository, user)` across both production and Local Mode:

1. If `repository.installation_state != "active"`, return `"none"`.
2. If `LocalDevelopment.enabled?` and unified auth is **not** active, retain existing single local developer `"admin"` behavior (backward compatibility for upstream local-mode tests).
3. Check local `RepositoryMembership` for `(repository, user)`:
   - For `'external'` users (Email/OIDC): **authoritative** — return the membership's `role` (`"read"`, `"write"`, or `"admin"`), or `"none"` if no membership exists. Never call GitHub API.
   - For `'github'` users: keep existing GitHub permission lookup; if a `RepositoryMembership` also exists, take the higher permission level (`PERMISSION_LEVELS`).
   - In Local Mode with unified auth active: check `LocalDevelopment.repository_available?` first, then resolve permission from `RepositoryMembership` (and if `user.hub_admin?` has no explicit membership yet, allow admin UI access to grant memberships without bypassing explicit repository grants, or grant `hub_admin` ability to manage repository memberships from Hub Administration).
4. Cache key must use `user.id` and include a membership version/timestamp (never assume `user.github_id` is non-nil). Updating or deleting a `RepositoryMembership` immediately invalidates permission and selector caches.

### 3.2 `HasRepositoryWorkspace`

- `authorized_repositories`:
  - Only batch-query GitHub API for `'github'` users when a GitHub App installation is active.
  - For `'external'` users, resolve readable repositories directly via `RepositoryMembership` joined with `workspace_repositories`.
  - Keep `repository.route_id` working seamlessly for both GitHub-backed (`github_id`) and Local Mode (`id`) repositories.

### 3.3 `Authentication`

- `resume_session` checks:
  - When unified auth is active: accept `'external'` (and `'github'` if GitHub auth is enabled) sessions consistently in both production and Local Mode; reject `'local'` developer sessions.
  - When unified auth is inactive: preserve exact upstream behavior (`browser_session.user.local? == LocalDevelopment.enabled?`).

---

## 4. Email OTP via Resend

### Configuration

- `REPLICA_AUTH_EMAIL_ENABLED` (`"1"` / `"true"` to enable; automatically enabled when `REPLICA_AUTH_MODE=unified` or `RESEND_API_KEY` is configured with allowlist)
- `RESEND_API_KEY`: Resend API key (kept in runtime secrets, never committed)
- `RESEND_FROM_EMAIL`: verified sender address (e.g. `Replica Hub <noreply@example.com>`)
- `RESEND_API_BASE_URL`: defaults to `https://api.resend.com` (honors `HTTPS_PROXY` via `Net::HTTP` default proxy support)

### Delivery & Security Rules

- `POST /auth/email/challenges`:
  - Rate-limited by trusted IP and normalized email (`SecurityRateLimiting`).
  - Checks `AuthAllowlistEntry` for normalized email.
  - Always returns a generic success response ("If this email is allowed, a verification code has been sent") to prevent allowlist enumeration.
  - Generates a cryptographically random 6-digit code (`SecureRandom.random_number(1_000_000)` formatted `%06d`), stores only its HMAC digest, invalidates prior unconsumed challenges for that email.
  - Sends email via `ResendClient` (`POST /emails` with `Authorization: Bearer <RESEND_API_KEY>`). In `development` when `RESEND_API_KEY` is blank, logs the code to Rails logger so local debugging works without external credentials.
- `POST /auth/email/verify`:
  - Rate-limited by IP and email; constant-time digest comparison; atomic consumption with max 5 attempts and 10-minute expiry.
  - Re-checks `AuthAllowlistEntry` before admitting.
  - Finds or creates `User` by normalized email (`identity_kind: "external"`), syncs `hub_admin` if entry marks `hub_admin: true`, records `UserIdentity(provider: "email", subject: email)`, starts a fresh `Session`, and records `SecurityAuditEvent`.

---

## 5. Generic OIDC Authentication

### Configuration

Configured via `REPLICA_OIDC_PROVIDERS_JSON` (JSON array in runtime environment/secrets), where each entry defines:

```json
[
  {
    "slug": "google",
    "display_name": "Google",
    "issuer": "https://accounts.google.com",
    "client_id": "example-client-id",
    "client_secret": "example-client-secret",
    "scopes": "openid email profile"
  }
]
```

### Protocol & Security Requirements

- Routes:
  - `POST /auth/oidc/:provider` — starts Authorization Code + PKCE (`S256`) + `state` + `nonce` stored in encrypted session, redirects to discovered `authorization_endpoint`.
  - `GET /auth/oidc/:provider/callback` — validates `state`, exchanges code with PKCE `code_verifier` at `token_endpoint`, fetches & caches JWKS from `jwks_uri`, verifies `id_token` RS256/ES256 signature, `iss`, `aud`, `exp`, `iat`, `nonce`, and requires `email_verified == true`.
- CSP: `HubContentSecurityPolicy` dynamically adds the origin(s) of configured OIDC `authorization_endpoint` / `issuer` to `form-action` so form-based sign-in redirects succeed in Chromium browsers.
- Account admission & linking:
  - Requires normalized `email` to match `AuthAllowlistEntry`.
  - Looks up existing `UserIdentity(provider: "oidc:#{slug}", subject: sub)` first, then links by normalized `User#email` so Email OTP and OIDC users with the same verified email share one `User` record seamlessly.
  - Records `SecurityAuditEvent` for sign-in success and denials.

---

## 6. Unified Auth Across NAS Production and Local Mode

- `REPLICA_AUTH_MODE`:
  - `"default"` (unset): preserves upstream behavior (GitHub App in production / `REPLICA_LOCAL_MODE=0`; one-click `Open local Hub` in `REPLICA_LOCAL_MODE=1`).
  - `"unified"`: enables Email OTP + configured OIDC providers (+ optional GitHub OAuth if `REPLICA_AUTH_GITHUB_ENABLED=1` and GitHub App is configured) in **both** production and `REPLICA_LOCAL_MODE=1`.
- In Local Mode with `REPLICA_AUTH_MODE=unified`:
  - Repositories are still discovered and built locally from `hub/.local/prototypes/*` (zero GitHub Actions).
  - Sign-in, allowlist checks, Hub admin management, and per-repository `RepositoryMembership` authorization work identically to NAS production.
  - Home page displays the unified sign-in UI (Email OTP + any configured OIDC buttons, plus GitHub button only when enabled).

---

## 7. Staged Delivery Plan (Multica Issues)

- **Stage 1: Identity Foundation, Email OTP & Repository Access Management**
  - `1.0` Decouple `User` identity model + add `user_identities`, `auth_allowlist_entries`, `repository_memberships` + bootstrap env seeding + refactor `Repository::Authorization` & `HasRepositoryWorkspace`.
  - `1.1` Implement Resend 6-digit OTP email sign-in backend, rate limits, audit events, Home login UI (zh-CN + en), and Storybook stories.
  - `1.2` Implement Hub Admin allowlist management UI and per-repository member access management UI (`read` / `write` / `admin`) with immediate cache invalidation.
- **Stage 2: Generic OIDC & Unified NAS/Local Auth Cutover**
  - `2.0` Implement generic OIDC provider registry, Discovery + PKCE + JWKS `id_token` verification, dynamic CSP `form-action`, verified-email account merging, and Google OIDC support.
  - `2.1` Wire `REPLICA_AUTH_MODE=unified` across Local Mode and Production, verify full test suite + RuboCop + Vitest + Storybook, and complete end-to-end verification across local dev and NAS production.
