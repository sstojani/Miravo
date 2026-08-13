# Security policy and implementation baseline

Miravo stores sensitive financial and identity data. Report suspected vulnerabilities privately to the repository owner; do not open a public issue containing real data, credentials, logs, or receipt content.

## Baseline controls

- Non-development traffic is HTTPS-only and authenticated except deliberate liveness/public-config routes.
- Passwords use Argon2. Access JWTs are short lived. Refresh credentials rotate, are stored as keyed hashes, and revoke the device session on reuse.
- Tracker invitation credentials are independent, email-bound, expiring, HMAC-hashed, revocable, and shown once.
- Shortcut credentials use their own secret pepper and high-entropy token family. Only a prefix and HMAC-SHA-256 digest are stored; the raw token is shown once, can be tracker-restricted, carries explicit read/create scopes, expires by default, and is immediately revocable. The narrow routes apply client-attempt, per-token, and per-user throttles.
- The iOS credential screen never writes a raw Shortcut token to SwiftData, UserDefaults, Keychain, logs, or descriptions. It holds the create response only in memory; user-initiated copy uses a local-only pasteboard item with a five-minute expiry, and closing the one-time screen clears the app reference.
- The iOS collaboration screen applies the same one-time treatment to tracker invite codes: redacted non-`Codable` memory only, explicit local-only five-minute clipboard copy, and no persistence. Invite/member/merge calls use the normal short-lived app access token, never a Shortcut token.
- iOS secrets belong only in Keychain. The IPA contains public configuration only.
- iOS access/refresh credentials use a non-synchronizing Keychain item with `AfterFirstUnlockThisDeviceOnly` accessibility and no custom access group; a password is never persisted.
- Cached iOS entities are partitioned by normalized server origin and authenticated user UUID. Sign-out hides the scope without destructively deleting possibly unsynchronized records.
- Synchronization cursors are signed and bound to the authenticated user. Operation replay receipts are user-scoped, fingerprint-protected, database-private, and expire after 120 days; their financial response/proposal content is never emitted to logs.
- Shortcut capture receipts are likewise user-scoped and fingerprint-protected for 120 days. A repeated event ID returns the existing transaction, while reuse of one idempotency key with another normalized payload is rejected. Token rotation cannot create a second user-scoped event.
- Tracker changes are filtered through current active membership. Membership revocation events are targeted only to the affected user so a removed device learns to hide data without receiving later tracker mutations.
- Release URL validation and ATS permit HTTPS only. The Debug-only ATS exception is constrained in code to loopback, and redirects are refused for credential-bearing requests.
- The privacy manifest declares linked app-functionality data accurately, declares no tracking domains, and records only the CA92.1 app-owned UserDefaults required reason.
- Authorization is enforced per object on the server. Shared-tracker tests cover every role.
- Split and settlement commands re-resolve every participant through the authorized tracker, derive totals rather than trust a client balance, lock version roots, and prevent a linked settlement movement from being changed outside the settlement lifecycle.
- Native guest merge requires a clean outbox/conflict state, a fresh synchronization, and authoritative versions for both identities before the server performs the audited irreversible rewrite.
- Financial values are integer minor units; exchange rates use decimal arithmetic and immutable historical snapshots.
- Request bodies and sensitive fields are excluded from logs. Safe errors include request IDs.
- Attachments and exports use private random storage keys and authenticated/expiring delivery, never raw public media URLs.
- Production uses `DEBUG=false`, strict hosts/origins, CSRF for browser sessions, rate/body/file/decompression limits, secure proxy headers, and non-root containers where practical.
- PostgreSQL, Redis, admin, metrics, debug, backups, and raw media are excluded from public Funnel exposure.
- Backups must be encrypted offsite and proven restorable in isolation.

## Secrets that must never enter Git or an IPA

Passwords, Django/JWT/refresh/invitation peppers, database/Redis credentials, access/refresh/invite/Shortcut tokens, signing credentials, Tailscale auth keys, server SSH keys, SMTP credentials, backup keys, and administration credentials.

## Supported disclosure information

Include the affected revision, endpoint/component, safe reproduction steps with synthetic data, expected/actual behavior, and impact. Remove Authorization headers, cookies, tokens, user email, notes, merchant names, amounts, and receipt data.

## Initial response targets

- Critical suspected exposure or authorization bypass: acknowledge within 24 hours.
- High severity: acknowledge within 3 days.
- Other security defects: acknowledge within 7 days.

These are project targets, not a commercial SLA.
