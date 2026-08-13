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
- Budgets are aggregate roots. Their selected category snapshots and threshold percentages are replaced atomically with the root, so child rows cannot be independently reordered ahead of the owning version.
- Recurring rules accept create/update/archive/restore/delete plus explicit pause/resume/end/skip-next commands. Recurring occurrences are server-produced read-only changes; bootstrap orders rules, then transactions, then occurrences so links resolve atomically on the client.
- Installment plans accept create/update/archive/restore/delete/cancel plus explicit record-payment/payoff/skip-payment/reschedule-payment commands. A plan UUID is the command/version boundary. Deterministic UUIDv5 schedule-row IDs let later offline commands reference rows produced by an earlier queued create/revision. A local payment projects its ordinary ledger transaction and schedule progress atomically but queues only the plan command; schedule rows and payment history remain server-produced changes. A failed/conflicted plan command blocks later commands for that plan without blocking unrelated entities.
- Guest participants accept create/update/archive/restore/delete commands. Registered participants are created from active membership and remain server-authoritative for identity/lifecycle. Settlements accept only create/delete/restore because changing debtor, creditor, currency, amount, or occurrence time means creating a new audited settlement. Split payer/share children are replaced atomically inside the owning expense transaction payload and never sent as independent roots.
- The native client mirrors participant and settlement roots in scoped SwiftData. A transaction update distinguishes “leave split unchanged,” “replace the complete split,” and an explicit JSON `null` that removes it. A settlement with an optional account movement still queues only one settlement root; the linked transaction is an optimistic local projection and cannot be mutated independently.
- Invite creation/revocation/acceptance, member role/removal, and guest-to-registered merge are not offline outbox commands. They are server-authoritative connected actions authenticated with the normal short-lived app access token, followed by an ordinary pull. Raw invitation tokens are one-time in-memory values. Before guest merge, the app requires a clean outbox/conflict state, a successful sync, and synchronized source/target versions so an irreversible server rewrite cannot bypass unsent split or settlement proposals.

Attachments use a separate two-stage protocol. The native queue first stores normalized content and a thumbnail under iOS Data Protection, then persists a compound-scoped attachment UUID, owning transaction, safe relative paths, allow-listed MIME type, positive bounded byte count, lowercase SHA-256 digest, original-retention flag, state, attempt count, next retry, safe error code, and timestamps. It waits until the owning transaction has a server version, reserves that exact metadata through `POST /attachments/`, and streams the protected file with `PUT /attachments/{id}/content/`. Enqueue and reservation are idempotent only for an identical metadata fingerprint. Interrupted uploads return to pending; transient failures back off; permanent validation/quarantine results stop automatic retry; pending/failed uploads can be cancelled without deleting the local receipt, and cancelled or failed items can be explicitly returned to the pending queue.

The server streams each body into a private `0600` staging file, bounds bytes, hashes content, sniffs an allow-listed container signature, verifies the reservation, runs an optional trusted scanner hook, and atomically moves it to a randomized private or quarantine key. No storage key enters an API or sync representation. Attachment metadata/tombstones travel through normal pull/bootstrap after their transaction; binary bytes never enter the change log. An authorized native preview first verifies an existing local file by exact size and SHA-256. A second device uses authenticated `GET /attachments/{id}/content/`, refuses redirects/cross-origin responses, bounds the downloaded temporary file, requires the expected media type, rechecks size/digest, and saves it under Data Protection before displaying it. The sync cursor advances independently of binary transfer failures.

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
4. Require every page to retain the same target cursor; decode all typed records and validate tracker/membership/participant/account/category/tag/transaction/split/settlement/budget/recurrence/installment relationships, including same-tracker participants and exact payer/share totals, budget category scope, recurrence account/category scope, deterministic due instants and occurrence keys, exact installment component totals, plan/schedule/payment links, and payment/transaction identity.
5. Publish the reconciled snapshot and final pull cursor in one SwiftData save, retaining every entity with a queued local mutation. An unresolved pending/failed installment-plan mutation also protects its owned preview schedule rows; a resolved conflict instead publishes the authoritative plan/schedule while keeping the discarded proposal in conflict history.
6. Immediately pull from the fixed cursor so changes committed while pages were downloading are not deferred to a later launch.
7. Rebase/replay retained commands against downloaded versions, producing conflicts where required.

A page or publish failure rolls back its entire local transaction. Completed staging pages remain resumable, while the prior visible store/cursor and unsent outbox stay usable.

## Conflict rules

- Security/membership/role data is server-authoritative.
- Membership snapshots persist as an offline roster. A current-user active role change updates the cached tracker permission immediately; removal marks access revoked. Viewer writes are also rejected inside the local repository, not only hidden in views.
- Delete on a newer version defeats an older edit, but the local proposal is retained for review.
- The server merges only provably non-overlapping field changes.
- Overlapping financial edits return base information when retained, current server representation, proposed local changes, and changed-field metadata.
- UI offers keep server, submit mine as a new update, and meaningful field review. The decision is audited.
- For installment conflicts, keep-server removes only the unsynchronized projected ledger transaction, requires a safe bootstrap of server-authored children, and preserves later commands as explicit dependency conflicts. Keep-mine rebases the same proposal with a new operation ID.
- Pending transaction split children and settlement-owned movement projections remain protected during pull/bootstrap. A rejected/conflicted settlement marks its owned local projection consistently without blocking unrelated roots. Guest merge is intentionally unavailable while any unresolved local proposal exists, so it does not require a separate offline merge-conflict representation.

## Triggers and diagnostics

Attempt on login/bootstrap, launch/foreground, local change, pull-to-refresh, active connectivity return, periodic active timer, best-effort BackgroundTasks, and WebSocket invalidation. Correctness never assumes a precise background or Wi-Fi event.

The iOS foreground socket uses `wss` on the configured HTTPS origin, sends the current access JWT only in the authorization header, refuses redirects, bounds frames to 64 KiB, and reconnects with exponential backoff. The ASGI consumer validates the active device session, joins user-specific/global fan-out groups, sends only a sequence hint, and closes at token expiry. A hint is coalesced into a normal pull; it never mutates local domain state directly. When the token rotates after an HTTP refresh, the client replaces the socket. Redis, WebSocket, background scheduling, and reachability-monitor failure all degrade to the active timer/manual/foreground paths.

`NWPathMonitor` is treated only as a transition hint: the initial path does not duplicate launch sync, and only an observed unsatisfied-to-satisfied transition requests another run. `BGAppRefreshTask` has a bundle-derived permitted identifier, is resubmitted best-effort, honors expiration cancellation, and reports whether iOS accepted the request. iOS decides when or whether to execute it.

The UI always exposes last success, current state, pending/failed/conflict counts, and manual retry. States are pending, syncing, synced, failed, and conflicted.
