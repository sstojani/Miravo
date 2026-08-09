# Backup and restore

A backup is not accepted until an isolated restore passes integrity tests.

## Backup set

- Consistent PostgreSQL custom-format `pg_dump`.
- Private receipt/media archive.
- Configuration/secret-name inventory without secret values.
- Source revision, schema/application version, timestamps, and checksums.
- Age-encrypted archive before offsite copying; decryption key held separately.

Initial retention is 7 daily, 4 weekly, and 6 monthly recovery points. Backup failure must be visible through timer status/monitoring. The current backup script creates an encrypted atomic recovery artifact; retention rotation and automated isolated validation remain Milestone 10.

## Restore drill

1. Provision a temporary isolated Docker project/network and empty volumes. Never point it at production volumes.
2. Verify outer and inner checksums, decrypt into a restricted temporary directory, and inspect revision/manifest.
3. Restore PostgreSQL with `pg_restore` into a fresh database and restore private media.
4. Start the matching application revision, apply only documented compatible migrations, run Django checks and integrity queries.
5. Verify users/trackers/transactions/movements/attachments counts, financial invariants, media checksums, a synthetic login, readiness, and private-media authorization.
6. Record duration/results, then destroy only the explicitly named temporary environment.

Production recovery requires a reviewed outage plan, fresh evidence-preserving backup if possible, exact target selection, and explicit authorization. Never overwrite the sole production copy to “test” a restore.

