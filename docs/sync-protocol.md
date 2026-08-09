# Offline synchronization protocol

The local database drives every ordinary app view. Remote responses update local state; views do not wait on them.

## Local mutation transaction

1. Validate the command locally using the currency exponent and domain rules.
2. In one SwiftData transaction, mutate the client-generated UUID entity and append an outbox operation.
3. The outbox records operation ID/idempotency key, a per-user monotonic local sequence, entity/type, command, versioned payload, base server version, creation time, and retry state.
4. Commit, update UI, and dismiss without a network spinner.
5. Ask the synchronization actor to run if appropriate.

If step 2 fails, neither entity nor outbox persists. Undo is another auditable local command; delete becomes a tombstone.

## Push

- One synchronization actor sends bounded batches ordered by the durable local sequence. An immediate edit or tombstone can never sort ahead of its create merely because both share a clock tick.
- Operations carry independent IDs and base versions. Server processing is transactional per operation and returns accepted, duplicate, rejected, unauthorized, or conflict.
- Structural envelopes and typed payloads reject unknown fields. A per-user receipt stores the operation fingerprint/result for 120 days; exact replay is safe even after re-login, while a changed fingerprint conflicts.
- At most one operation for a given entity is sent in a batch. Its persisted payload and operation ID never change after an attempt; after acceptance, the next queued edit is rebased to the returned server version and sent in sequence. This preserves the idempotency fingerprint when a response is lost. Server updates/deletes require an explicit positive base version.
- Lost responses are retried with identical IDs. Validation/permission/revocation failures stop automatic retry; transient failures use exponential backoff with jitter.
- Conflicts and permanent failures do not block unrelated operations.
- Binary attachments use a separate checksum/idempotency queue and never ride in the mutation batch.

The current native attachment boundary persists a compound scoped attachment UUID, owning transaction UUID, relative local path, allow-listed MIME type, positive bounded byte count, lowercase SHA-256 digest, state, attempt count, next retry, safe error code, and timestamps. Enqueue is idempotent only for an identical metadata fingerprint; conflicting reuse fails. Interrupted `uploading` rows return to `pending` after restart. This is queue scaffolding, not a claim that binary upload exists—the private upload protocol and server attachment resource arrive with receipts in Milestone 9.

## Pull

- Each device stores a durable opaque cursor signed by the server and bound to that user UUID.
- After push and on invalidation/manual/foreground triggers, pull bounded change pages.
- Apply a page—including tombstones—and its next cursor atomically. Never advance a cursor before page commit.
- Change rows are filtered by current authorization; membership changes are additionally targeted to the affected user so access removal is delivered. WebSockets carry only a “data changed” hint.
- Change rows contain references, not duplicate financial payload archives. Each response renders the latest current version, so repeated sequence rows are harmless versioned upserts.
- Change/tombstone retention begins at 90 days. A cursor older than retention returns a machine-readable bootstrap-required error.

## Full bootstrap

1. Preserve unsent outbox commands and locally referenced files.
2. The server fixes an upper change-log sequence and signs one normal target cursor on the first request. Every UUID-ordered page carries that exact opaque token inside its signed, user-bound bootstrap continuation; it is not re-signed between pages.
3. Persist each page under a local bootstrap generation without changing the visible ledger or normal pull cursor.
4. Require every page to retain the same target cursor; decode all typed records and validate core tracker/account/category/transaction relationships.
5. Publish the reconciled snapshot and final pull cursor in one SwiftData save, retaining every entity with a queued local mutation.
6. Immediately pull from the fixed cursor so changes committed while pages were downloading are not deferred to a later launch.
7. Rebase/replay retained commands against downloaded versions, producing conflicts where required.

A page or publish failure rolls back its entire local transaction. Completed staging pages remain resumable, while the prior visible store/cursor and unsent outbox stay usable.

## Conflict rules

- Security/membership/role data is server-authoritative.
- Delete on a newer version defeats an older edit, but the local proposal is retained for review.
- The server merges only provably non-overlapping field changes.
- Overlapping financial edits return base information when retained, current server representation, proposed local changes, and changed-field metadata.
- UI offers keep server, submit mine as a new update, and meaningful field review. The decision is audited.

## Triggers and diagnostics

Attempt on login/bootstrap, launch/foreground, local change, pull-to-refresh, active connectivity return, periodic active timer, best-effort BackgroundTasks, and WebSocket invalidation. Correctness never assumes a precise background or Wi-Fi event.

The iOS foreground socket uses `wss` on the configured HTTPS origin, sends the current access JWT only in the authorization header, refuses redirects, bounds frames to 64 KiB, and reconnects with exponential backoff. The ASGI consumer validates the active device session, joins user-specific/global fan-out groups, sends only a sequence hint, and closes at token expiry. A hint is coalesced into a normal pull; it never mutates local domain state directly. When the token rotates after an HTTP refresh, the client replaces the socket. Redis, WebSocket, background scheduling, and reachability-monitor failure all degrade to the active timer/manual/foreground paths.

`NWPathMonitor` is treated only as a transition hint: the initial path does not duplicate launch sync, and only an observed unsatisfied-to-satisfied transition requests another run. `BGAppRefreshTask` has a bundle-derived permitted identifier, is resubmitted best-effort, honors expiration cancellation, and reports whether iOS accepted the request. iOS decides when or whether to execute it.

The UI always exposes last success, current state, pending/failed/conflict counts, and manual retry. States are pending, syncing, synced, failed, and conflicted.
