# Security policy and implementation baseline

Project Ledger stores sensitive financial and identity data. Report suspected vulnerabilities privately to the repository owner; do not open a public issue containing real data, credentials, logs, or receipt content.

## Baseline controls

- Non-development traffic is HTTPS-only and authenticated except deliberate liveness/public-config routes.
- Passwords use Argon2. Access JWTs are short lived. Refresh credentials rotate, are stored as keyed hashes, and revoke the device session on reuse.
- Shortcut credentials will be independent, scoped, hashed, revocable, rate-limited, optionally expiring, and shown once.
- iOS secrets belong only in Keychain. The IPA contains public configuration only.
- Authorization is enforced per object on the server. Shared-tracker tests cover every role.
- Financial values are integer minor units; exchange rates use decimal arithmetic and immutable historical snapshots.
- Request bodies and sensitive fields are excluded from logs. Safe errors include request IDs.
- Attachments and exports use private random storage keys and authenticated/expiring delivery, never raw public media URLs.
- Production uses `DEBUG=false`, strict hosts/origins, CSRF for browser sessions, rate/body/file/decompression limits, secure proxy headers, and non-root containers where practical.
- PostgreSQL, Redis, admin, metrics, debug, backups, and raw media are excluded from public Funnel exposure.
- Backups must be encrypted offsite and proven restorable in isolation.

## Secrets that must never enter Git or an IPA

Passwords, Django/JWT/refresh peppers, database/Redis credentials, access/refresh/Shortcut tokens, signing credentials, Tailscale auth keys, server SSH keys, SMTP credentials, backup keys, and administration credentials.

## Supported disclosure information

Include the affected revision, endpoint/component, safe reproduction steps with synthetic data, expected/actual behavior, and impact. Remove Authorization headers, cookies, tokens, user email, notes, merchant names, amounts, and receipt data.

## Initial response targets

- Critical suspected exposure or authorization bypass: acknowledge within 24 hours.
- High severity: acknowledge within 3 days.
- Other security defects: acknowledge within 7 days.

These are project targets, not a commercial SLA.

