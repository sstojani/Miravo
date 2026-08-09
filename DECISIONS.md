# Decision log

## D-001 — Provisional identity and configuration

- **Decision:** Use “Project Ledger” as the provisional app name, `com.example.projectledger` as the provisional bundle identifier, `ALL` as default currency, `Europe/Tirane` as default time zone, and an empty/invalid public URL placeholder.
- **Why:** These match the supplied defaults and keep implementation unblocked.
- **Consequence:** All values live in centralized environment/XcodeGen configuration and remain explicitly non-final.

## D-002 — Django 5.2 LTS on Python 3.13

- **Decision:** Use Django 5.2 LTS and target Python 3.13; permit Python 3.12–3.14 for developer tooling.
- **Why:** On 2026-08-09, Django 5.2.17 was the current LTS with extended support through April 2028, while Django 6.0 had a shorter support horizon. Python 3.13 remains in bug-fix support and is conservative for the worker/package ecosystem.
- **Consequence:** Upgrade patches promptly; reconsider Python 3.14 only after the dependency/test matrix is green.

## D-003 — JWT access plus opaque rotating refresh credentials

- **Decision:** Access tokens are short-lived signed JWTs. Refresh credentials are high-entropy opaque values stored only as HMAC-SHA-256 digests and rotated exactly once per successful refresh.
- **Why:** Native clients do not benefit from self-contained refresh JWTs. Opaque credentials make immediate revocation, strict reuse detection, and one-time raw-token display straightforward.
- **Consequence:** Refresh requires a database transaction. Reusing an already consumed credential revokes its whole device session and forces login.

## D-004 — API-visible request IDs, no payload logging

- **Decision:** Generate or validate a bounded request ID, return it on every response, and log only safe request metadata in structured JSON.
- **Why:** This supports diagnosis without placing financial contents or credentials in logs.
- **Consequence:** Debugging payload problems relies on explicit safe validation details, not copied bodies.

## D-005 — Caddy loopback edge with explicit public-path denial

- **Decision:** The proxy binds host loopback only and denies admin, metrics, debug, raw media, schema UI, and static management paths before proxying the API.
- **Why:** Funnel exposes the selected local service publicly; it is not an authorization boundary.
- **Consequence:** Administration needs a separate tailnet-only/SSH path. Installed Tailscale CLI help must be checked at deployment.

## D-006 — SwiftData remains the intended iOS store

- **Decision:** Retain SwiftData for local persistence, with domain/repository boundaries that can isolate a future SQLite/Core Data substitution.
- **Why:** No blocker is currently known, and iOS 18 is the minimum target.
- **Consequence:** The sync outbox and cursor must be validated for atomicity on a macOS runner before Milestone 3 acceptance.

## D-007 — No extension or entitlement dependency

- **Decision:** Wallet capture posts directly from an optional personal Shortcut to the HTTPS API; the app uses ordinary URLSession sync.
- **Why:** Third-party re-signing may alter entitlements, and Apple does not provide continuous Wallet-history access to an ordinary app.
- **Consequence:** Background tasks/WebSockets improve freshness only. Manual entry and foreground sync remain complete without them.

## D-008 — Git repository in a workspace subdirectory

- **Decision:** Use `ProjectLedger/` as the monorepo root.
- **Why:** The execution environment placed a read-only non-repository `.git` directory at the workspace root.
- **Consequence:** All user-facing repository links point to the subdirectory; this has no effect after cloning/pushing the actual repo.

## D-009 — Reproducible hosted Apple toolchain

- **Decision:** Pin iOS CI to GitHub's `macos-15` runner contract, select Xcode 16.4 explicitly, and install XcodeGen 2.46.0 through a pinned Mint package reference.
- **Why:** The Linux workspace cannot compile native iOS code, while the selected hosted image/tool versions support the iOS 18 deployment target and are reviewable in workflow source.
- **Consequence:** CI prints actual versions and project regeneration must be clean. The pins must be reviewed when GitHub retires an image or Apple toolchain.

## D-010 — Audit findings update the lock, not just the report

- **Decision:** Treat a dependency advisory as a lock-file failure even when it affects development tooling; raise the compatible minimum, refresh `uv.lock`, and rerun all checks.
- **Why:** The first local audit identified an advisory in the resolved pytest version. Resolving to pytest 9.1.1 removed the finding without weakening tests.
- **Consequence:** `pip-audit` now reports no known vulnerability locally; hosted dependency and container scans remain required before Milestone 10 acceptance.

## D-011 — Relational financial revisions and category-version snapshots

- **Decision:** Capture immutable transaction, movement, allocation, and category revision rows before financially meaningful edits; each current allocation records the category version used when posted.
- **Why:** Audit event names alone cannot reproduce old money semantics, while generic JSON would hide critical financial relationships. Category renames and merges must not rewrite what an older record meant.
- **Consequence:** Edits and merges cost extra rows and transactions, but prior amounts/accounts/categories remain queryable and protected by foreign keys. Large merges may move to an audited background job later without changing the data model.

## D-012 — Server-derived movements behind command serializers

- **Decision:** Clients submit transaction commands; they never submit arbitrary signed account movements. The server creates movements transactionally after validating tracker roles, currencies, conversions, allocations, and references.
- **Why:** Accepting client-authored balances or unrestricted signed movements would make authorization and ledger invariants fragile.
- **Consequence:** API write shapes differ from read representations. Full replacements require `base_version`; conflicting versions return HTTP 409 and preserve the current record.
