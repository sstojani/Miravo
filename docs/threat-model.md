# Threat model

## Assets and adversaries

Primary assets are financial records, identity/session data, tracker membership, receipts/OCR-derived content, exports, backups, availability, and audit integrity. Adversaries include an opportunistic internet attacker, credential stuffer, malicious collaborator, thief with a device, malware/server-account attacker, supply-chain compromise, and accidental operator error.

| Threat | Principal controls | Residual risk / required validation |
|---|---|---|
| Stolen unlocked iPhone | iOS Data Protection, passcode guidance, optional Face ID UI lock, Keychain, device revocation | An already unlocked device can expose visible local data; physical-device test required |
| Malicious/revoked signing certificate | No embedded secret or entitlement dependency; checksummed unsigned source artifact; server session revocation | A malicious signer can modify the app; user must trust signer and verify behavior |
| IPA static extraction | Public configuration only; server-wide credentials absent | URLs, routes, and UI strings are public by design |
| Leaked access token | Short lifetime, device-session active check, revocation, audit, TLS | Valid until expiry/revocation; future key rotation runbook |
| Leaked refresh token | One-time rotation, keyed digest storage, reuse detection revokes family/session | First thief use can race legitimate client; surface session history |
| Leaked Shortcut token | Separate high entropy, HMAC prefix+digest, narrow tracker/scopes, client-attempt/per-token/per-user rate limits, default expiry, immediate revoke, idempotency; app holds raw create response in memory only and uses an expiring local-only pasteboard on explicit copy | A screenshot, malicious keyboard, or another local app observing the clipboard can expose it; warn, prefer tracker scope, copy only while configuring, then revoke/replace promptly |
| Public Funnel probing | HTTPS, strict proxy path policy, Django auth/object auth, body/throttle limits, safe errors | Funnel is beta/version-dependent; external exposure test at deployment |
| Credential stuffing | Tight login throttle, generic errors, Argon2, audit; optional proxy controls | Home-host bandwidth/resource exhaustion remains possible |
| Cross-tracker IDOR | Central permission/queryset services, no client-trusted role, exhaustive role/object tests | A missed endpoint is high impact; test matrix is release gate |
| Shortcut replay/duplicate | User-scoped event ID and idempotency key/fingerprint; transactional create; token rotation preserves the user scope | The initial 120-day retention must exceed the expected queue/retry window; a genuinely new event needs a new UUID |
| Malicious receipt upload | Content sniffing, allow-list, size/decompression/page limits, random private key, quarantine/AV hook, never execute | AV cannot prove safety; downloads use safe disposition |
| Compromised server account | SSH keys, no root password login, least privilege, updates, audit, disk encryption, secret separation | Root compromise exposes live data; rotate all secrets and restore trusted build |
| Stolen disk/backup | LUKS recommendation; age-encrypted offsite archives; separate key; restricted paths | Mounted running disk is readable to privileged compromise |
| Accidental public DB/cache/admin/media | No host data ports, internal Docker network, loopback proxy, deny paths, external probe | Docker/firewall/operator changes can regress; re-test every deployment |
| Dependency/container compromise | Lock file, exact images/tags, audit/scan workflows, minimal image/non-root/no-new-privileges | Tags/actions need eventual digest/SHA pin and periodic refresh |
| Data loss/disk failure | Consistent DB+media archive, checksums/manifests, 7/4/6 retention, offsite encryption, isolated restore drill | Backup is incomplete until restore passes |
| Corrupt backup | Checksums plus automated isolated `pg_restore` and integrity tests | Restore validation is Milestone 10 and currently unimplemented |
| Log leakage | No body/header/cookie/OCR/note/financial payload logs; regex redaction; safe audit metadata allow-list | Exceptions and third-party logs require tests/review |

## Security invariants

- Every tracker-scoped object is authorized from server membership at request time.
- No client-provided balance, role, ownership, server version, or conversion result is trusted without validation.
- Financial mutation idempotency and audit commit with the change.
- Receipt/export download never resolves a public raw storage path.
- `DEBUG`, wildcard hosts/origins/CORS, and cleartext public URLs are rejected in production.
- PostgreSQL/Redis credentials, refresh/Shortcut digests, and encryption keys never appear in mobile configuration.

## Privacy

No advertising or third-party analytics SDK ships initially. Users receive clear local/server storage disclosure, data portability, session/Shortcut revocation, receipt-original retention controls, and a confirmed/graceful account-deletion process whose effects on shared/audit data are documented before implementation.
