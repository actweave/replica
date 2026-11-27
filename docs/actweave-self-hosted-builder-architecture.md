# ActWeave Replica Hub Self-Hosted Builder & Profile Display Architecture (Loop 2)

This document defines the architecture, security boundaries, and staged delivery plan for Loop 2 of ActWeave's self-maintained Replica Hub (`hub/`): **in-container self-hosted prototype builds using Git worktrees (eliminating GitHub Actions dependency), human-readable display names for external/OIDC reviewers, and production container packaging with CJK font support**.

> **Public repository boundary**: Never commit real deployment domains, NAS/host IPs, API keys, OAuth secrets, or personal email addresses to this repository. Tests and documentation must use placeholder values such as `example.com` and `example.invalid`.

---

## 1. Goals and Non-Goals

### Goals

1. **Zero GitHub Actions dependency for connected GitHub repositories**: When `REPLICA_BUILD_RUNNER=self_hosted` is enabled, Hub syncs connected GitHub repositories locally via short-lived GitHub App Installation Tokens and builds/screenshots commits in isolated `git worktree` checkouts inside the container, producing the exact same validated `replica-build-v1` artifacts as `actions/build`.
2. **Multi-branch isolation & fast rebuilds**: Each pushed branch commit builds in a temporary detached worktree and cleans up immediately after artifact extraction. A persistent npm cache under `storage/` keeps incremental rebuilds fast (~10–30s when dependencies are unchanged) while falling back to online registry fetches (respecting `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`) when dependencies change.
3. **Resource & sandbox safety**:
   - Single-concurrency build queue (`self_hosted_builds`, `threads: 1`) so concurrent branch pushes never exhaust memory on small self-hosted servers.
   - Works under `read_only: true` root filesystem, `cap_drop: ALL`, `no-new-privileges: true`, and non-root container UIDs, writing only to mounted `/rails/storage` and `/rails/tmp`.
   - Installation tokens are passed ephemerally to `git` (never persisted to `.git/config`, logs, or error messages).
4. **Clear CJK screenshots**: Production image includes Chromium and CJK fonts (`fonts-noto-cjk`) so prototype screenshots render Chinese typography cleanly without tofu boxes.
5. **Human-readable reviewer identities**: Allow administrators to assign an optional `display_name` on email allowlist entries, allow signed-in external users to edit their own display name (`users.name`), and automatically sync `name` and HTTPS `picture` from OIDC `id_token` claims (without exposing email addresses in public handles).
6. **Backward compatibility**: Default `REPLICA_BUILD_RUNNER` (unset or `github_actions`) preserves existing upstream GitHub Actions behavior and Local Mode (`REPLICA_LOCAL_MODE=1`) behavior with zero regressions.

### Non-Goals (Loop 2)

- Long-lived editable source worktrees on the production host (Hub serves immutable static artifacts from `storage/artifacts/builds/<id>`, not live dev servers).
- Supporting non-GitHub Git hosts (e.g., Gitea/GitLab) — keep Git sync cleanly encapsulated so future remotes can be added later, but Loop 2 targets connected GitHub App repositories.
- Splitting a separate builder container in `compose.yaml` (keeping a dedicated `self_hosted_builds` queue allows future split with zero code changes if ever needed).

---

## 2. Self-Hosted Build Runner (`REPLICA_BUILD_RUNNER=self_hosted`)

### 2.1 Configuration

- `REPLICA_BUILD_RUNNER`:
  - `"github_actions"` (default when unset): existing upstream behavior.
  - `"self_hosted"`: Hub syncs GitHub App repositories into `storage/repos/<repository_id>` and builds commits locally instead of waiting for GitHub Actions workflow runs/artifacts.
- `REPLICA_SELF_HOSTED_BUILD_ROOT`: defaults to `Rails.root.join("storage/self_hosted_builds")` (ephemeral worktrees and temp output, cleaned up after each build).
- `REPLICA_SELF_HOSTED_REPOS_ROOT`: defaults to `Rails.root.join("storage/repos")` (bare/mirror Git repositories per `repository.id`).
- `REPLICA_NPM_CACHE_DIR`: defaults to `Rails.root.join("storage/npm-cache")`.
- `REPLICA_BUILD_ACTION_ROOT`: defaults to `/opt/replica/actions-build` in production image if present, falling back to `Rails.root.join("../actions/build")` in development/test.

### 2.2 Repository Synchronization (`Repository::SelfHostedSync`)

- Maintains a bare Git mirror at `#{repos_root}/#{repository.id}.git` (no checked-out working tree inside the mirror; all builds use detached worktrees).
- Authenticates `git fetch --prune` against `#{Rails.configuration.x.github_url}/#{repository.name_with_owner}.git` using a short-lived GitHub App installation token:
  - Pass credentials via an ephemeral `GIT_ASKPASS` helper or `http.extraheader` via `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` environment variables — **never** embed tokens in remote URLs, `.git/config`, command-line argv, or exception messages (scrub any token occurrence if an error message is captured).
  - Honor `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` (and lowercase equivalents) when fetching over HTTPS.
- Synchronizes all `refs/heads/*` matching `repository.build_branch?(branch)`:
  - Records changed branch heads via `repository.build_discoveries.record!(branch_name:, commit_sha:, branch_head: true)`.
  - Populates `commit_author_name` from `git show -s --format=%an <sha>` when missing.
  - Enqueues `build.build_self_hosted_package_later!` onto the `self_hosted_builds` queue when `build.state == "queued"`.
  - Marks deleted branches cleanly consistent with existing branch lifecycle rules.

### 2.3 Triggers & Workflow Banner Behavior

When `REPLICA_BUILD_RUNNER=self_hosted` (and not `LocalDevelopment.enabled?`):

- **GitHub `push` Webhook**: Enqueues `Repository::SelfHostedSync` for the pushed repository (instead of waiting for a `workflow_run` event).
- **Scheduled poll (`discover_github_builds`) & manual Refresh button (`POST /repositories/:github_id/poll`)**: Runs repository sync + `SelfHostedSync` to catch any missed pushes immediately.
- **Workflow installation prompt**: Suppresses the `.github/workflows/replica.yml` missing-workflow prompt / banner because GitHub Actions is not required in `self_hosted` mode.
- **Queue concurrency**: Configure Solid Queue (`config/queue.yml`) with a dedicated `self_hosted_builds` dispatcher/worker pool of `threads: 1` (and serialized per-repository lock during `git fetch` / worktree creation) so concurrent pushes queue cleanly without OOM.

### 2.4 Isolated Worktree Package Builder (`Build::SelfHostedPackage`)

Share the core `actions/build` execution pipeline with `Build::LocalPackage` (refactor shared helpers rather than duplicating script invocation):

1. Transition `build` atomically from `queued` -> `running` (`started_at`).
2. Ensure the exact `build.commit_sha` exists in the local bare mirror (`#{repos_root}/#{repository.id}.git`); if missing, perform a bounded fetch first.
3. Create temporary workspace under `REPLICA_SELF_HOSTED_BUILD_ROOT` (`build-<id>-*`), run `git -C <mirror> worktree add --detach <checkout> <commit_sha>`.
4. Run `actions/build` stages inside `<checkout>` with bounded timeout (15 minutes) and sanitized environment:
   - Pass `npm_config_cache=<REPLICA_NPM_CACHE_DIR>`, `npm_config_prefer_offline=true`, `CI=true`, `HOME=<temp_dir>`, plus proxy env vars (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, lowercase equivalents) so `npm ci` uses cache first and fetches newly added packages through proxy if needed.
   - Run `validate-repository`, `npm ci --prefer-offline`, `npm run build`, `validate-build-output`, `capture-screenshots` (with `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` / system Chromium + `--disable-dev-shm-usage` compatible flags or `/tmp` writable dir), and `create-package`.
5. Zip output and pass into `Build::PackageExtraction.new(artifact_store:).extract!(file, prefix: "builds/#{build.id}")`.
6. Always run `git -C <mirror> worktree remove --force <checkout>` and prune temporary directory in `ensure`.
7. Mark build `successful` with `artifact_prefix`, `artifact_bytes`, `finished_at` (or `failed` with scrubbed `failure_summary` and cleaned artifacts on error).

---

## 3. External User Display Names & OIDC Profile Sync

### 3.1 Allowlist `display_name`

- Add optional `display_name` (`string`, max 80 chars, stripped) to `auth_allowlist_entries`.
- Hub Admins can optionally specify or update `display_name` on `/auth_allowlist_entries`.
- When `AuthAllowlistEntry#admit_verified_email!` creates or updates an external `User`:
  - If `user.name.blank?` and `display_name.present?`, populate `user.name = display_name`.
  - Keep `user.login` as the stable non-email handle (`reviewer-<hex>`) so emails are never exposed in handles or URLs.

### 3.2 User Self-Service Display Name

- Allow signed-in external users (`identity_kind == "external"`) to update their own `name` (trimmed, max 80 chars, plain text, no HTML) via a lightweight profile/settings endpoint (e.g., `PATCH /profile` or modal/form accessible from user menu) with CSRF protection and audit logging.
- Existing Hub UI (`user.name.presence || user.login`) automatically displays the friendly name in sidebar, comments, mentions, and admin pages.

### 3.3 OIDC `name` and `picture` Sync

- Update `OidcIdToken` / `OidcAuthenticationsController` to extract optional `name` (string, max 80 chars) and `picture` (validated HTTPS URL, max 500 chars, no credentials) from verified `id_token` claims.
- On OIDC sign-in:
  - Set `user.name` from OIDC `name` only when `user.name.blank?` (so manual user edits are preserved; also fall back to allowlist `display_name` if OIDC omits `name`).
  - Set `user.avatar_url` from validated HTTPS `picture` when present (preserving existing CSP `img-src 'self' https: data:`).

---

## 4. Production Image Packaging & Verification

### 4.1 Dockerfile & Workflow Updates

- Update `hub/Dockerfile` and `.github/workflows/actweave-hub-image.yml` to accept a named build context `build_action=../actions/build` (matching the existing `learning=../packages/learning` pattern):
  - Install runtime packages: `git`, `chromium`, `fonts-noto-cjk` (or lightweight CJK sans subset such as `fonts-noto-cjk` / `fonts-wqy-zenhei` — verify crisp Chinese rendering and reasonable image size), and required Chromium shared libraries.
  - Retain `npm` alongside `node` in the final image (owned by root so app runtime cannot tamper with binaries).
  - Copy `actions/build` into `/opt/replica/actions-build` and install its production dependencies (`npm ci --omit=dev --ignore-scripts`) at build time.
  - Set `ENV REPLICA_BUILD_ACTION_ROOT="/opt/replica/actions-build"` and `ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH="/usr/bin/chromium"`.
  - Ensure Chromium runs cleanly under `read_only: true`, `cap_drop: ALL`, `no-new-privileges: true`, non-root `1026:100`, and small default `/dev/shm` (pass `--disable-dev-shm-usage` in `actions/build` screenshot launcher when running in Linux containers, or verify Chromium works cleanly under Docker default 64MB `/dev/shm`!).

### 4.2 Local-First Production Simulation Before NAS Deployment

Before deploying to NAS, verify locally on Mac with:

1. **Devcontainer live test**: `REPLICA_LOCAL_MODE=0`, `REPLICA_AUTH_MODE=unified`, `REPLICA_BUILD_RUNNER=self_hosted` against a connected GitHub App repository — verify `git fetch` -> worktree build -> artifact extraction -> preview without triggering GitHub Actions.
2. **Read-only production container test**: Run the built production image locally with `--read-only --cap-drop ALL --security-opt no-new-privileges:true --user 1026:100 --tmpfs /tmp` and mounted `storage/` + `tmp/` + `secrets/`, verifying:
   - `/up` returns HTTP 200;
   - Self-hosted build of a real prototype branch succeeds inside the read-only sandbox;
   - Captured desktop/narrow screenshots render Chinese characters cleanly (no tofu boxes).
3. **NAS rollout** (only after explicit operator confirmation): Build immutable digest via `Build ActWeave Hub image` workflow, add `REPLICA_BUILD_RUNNER=self_hosted` to NAS `hub.env`, deploy via restricted `nas-compose` gateway, and verify end-to-end push -> auto-build -> preview without GitHub Actions.

---

## 5. Staged Delivery Plan (Multica Issues)

- **`1.0` Self-Hosted Build Runner Core (`REPLICA_BUILD_RUNNER=self_hosted`)**: Bare mirror Git sync via ephemeral GitHub App token, shared worktree build/package pipeline (`Build::SelfHostedPackage`), persistent npm cache (`--prefer-offline`), single-concurrency `self_hosted_builds` Solid Queue pool, Webhook/poll/refresh integration, and workflow banner suppression.
- **`1.1` External User Display Name & OIDC Profile Sync**: Allowlist `display_name`, external user self-service display name editor (zh-CN + en, Storybook + Vitest), and OIDC `name` + HTTPS `picture` claim sync.
- **`1.2` Builder Production Image + Local Read-Only Sandbox Verification + NAS Rollout**: Update `hub/Dockerfile`, `actions/build` Chromium container flags if needed, `.github/workflows/actweave-hub-image.yml`, execute local dev & read-only production container verification (including CJK screenshot check), then prepare NAS rollout checklist for operator confirmation.
