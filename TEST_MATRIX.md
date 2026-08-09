# Acceptance and test matrix

Status values: `planned`, `implemented`, `passing-local`, `passing-docker`, `passing-macos`, `manual-passed`, `blocked-external`.

| Area | Acceptance behavior | Automated coverage | Manual/E2E coverage | Status |
|---|---|---|---|---|
| Health | Liveness avoids dependencies; readiness checks DB/cache | `backend/tests/test_health.py` | Compose curl smoke test | passing-local |
| Login | Email/password creates a device session; no raw password/token logged | `backend/tests/test_auth.py` | Owner login from iPhone | passing-local |
| Refresh | One-time rotation; reuse revokes session/family | `backend/tests/test_auth.py` | Retry with captured synthetic token | passing-local |
| Sessions | List own devices; revoke another or current session | `backend/tests/test_auth.py` | Settings device-session UI | passing-local |
| Bootstrap | First owner only; env values cleared; no hardcoded secret | `backend/tests/test_bootstrap_owner.py` | Ubuntu bootstrap runbook | passing-local |
| Errors/logging | Stable code/message/details/request ID; redaction | `backend/tests/test_errors_and_logging.py` | Inspect support bundle | passing-local |
| Permissions | Owner/admin/editor/viewer object boundaries | Milestone 2 API parametrized tests | Two-user device flow | planned |
| Money | ISO code/exponent and integer minor-unit validation | Milestone 2 money property tests | Locale UI checks | planned |
| Accounts | Derived balances, transfer links, cross-currency snapshots | Milestone 2 domain tests | Compare ledger totals | planned |
| Transactions | Refund/void/allocation/audit/tombstone semantics | Milestone 2 domain/API tests | Offline quick-add scenario | planned |
| Sync | Atomic outbox, duplicate-safe push, paged pull/cursor/tombstones/bootstrap | Milestone 4 server+iOS tests | Airplane-mode/reinstall scenarios | planned |
| Conflict | Preserve both proposals and independent progress | Milestone 4 concurrent client tests | Two-client review screen | planned |
| Shortcut | Scopes, hash, expiry, revoke, throttle, replay, fingerprint conflict | Milestone 6 API tests | Online/queue repeated flush | planned |
| Budgets | Posted expense only, periods/rollover/history/offline | Milestone 7 backend+iOS tests | Month boundary UI | planned |
| Recurrence | Month-end/leap/DST/pause/skip/edit/catch-up idempotency | Milestone 7 scheduler tests | Simulated downtime | planned |
| Installments | Schedule/revision/extra/skip/payoff/overpay confirmation | Milestone 7 domain tests | Early payoff flow | planned |
| Splits | Exact totals, rounding, deterministic simplification, settlement exclusion | Milestone 8 property/API tests | Multi-user split/settle | planned |
| Receipts | Local restart survival, checksum retry, private authorization, OCR review | Milestone 9 API+iOS tests | Camera/OCR correction | planned |
| Currency | Manual/provider rate provenance; no invented/historical rewrite | Milestone 2/9 tests | Partially unconverted report | planned |
| Analytics | Offline/server totals consistent; transfers/voids excluded | Milestone 9 golden data tests | 50k record check | planned |
| Exports | UTF-8 CSV, PDF/full portability, authorized expiry/audit | Milestone 9 report tests | UI total comparison | planned |
| Localization | Every implemented user string exists in English and Albanian | Milestone 3 resource parity test | Native-speaker review | planned |
| Accessibility | Dynamic Type, VoiceOver labels, contrast/reduced motion, touch targets | Milestone 5 tests/audit | Physical-device audit | planned |
| Backup | DB/media/config manifest, checksum, encryption, retention, isolated restore | Milestone 10 restore CI/script | Disaster-recovery drill | planned |
| Exposure | Public API only; no DB/Redis/admin/metrics/debug/raw media | Proxy policy tests | External port/path probe | planned |
| iOS CI | Regenerate project, simulator build/test, no secrets | `.github/workflows/ios-ci.yml` | Review xcresult | planned |
| Unsigned IPA | Device app, Payload structure, metadata, architectures, SHA-256/manifest | `.github/workflows/unsigned-ipa.yml` | Signer + device checklist | planned |

## Required end-to-end scenarios

All twelve scenarios from `PROMPT.md` remain required: airplane-mode mutation, repeated Shortcut, app-closed Shortcut, offline queue replay, two-client conflict, role/split/settlement, scheduler downtime, private OCR receipt, matching CSV/PDF, reinstall/bootstrap, isolated backup restore, and unsigned-IPA/device smoke testing.
