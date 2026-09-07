# Sync recovery branch handoff - 2026-09-07

Publication state: owner requested immediate push to a separate branch and no more tests. This records the current implementation, not a verified iOS release. Base: `origin/main` at `d41327d`; branch: `codex/stale-sync-recovery`. No clean-room product identity changes were imported. No live server access, deployment, database cleanup, secret change or production migration was performed.

## Findings and reproduction

- Deleted-record resolution: queue two edits, receive a server tombstone, then choose Keep Server. Previous code rebased later edits onto the tombstone. The new deletion path clears only that record's queue, resolves its conflicts and quarantines dependent mutations without deleting their receipt files. Keep Mine is unavailable for tombstones.
- Permanent retry: reject an immutable operation for an invalid base version, then invoke Retry Failed repeatedly. Previous code indiscriminately returned failures to pending. Retry now uses an allowlist, validates basic operation invariants and changes the operation ID only after a definitive rejected receipt. Unknown transport outcomes retain the ID.
- Guest handoff: stop the process after successful login but before guest adoption. An in-memory adoption marker was lost. The handoff is now persisted before scope switching, blocks sync until adoption and cannot silently move the pending guest profile to another account.
- Disposable scaffold: change a starter payload without changing its local projection, then sign in. The old predicate could classify it as disposable. Canonical semantic payload checks now preserve altered data; identical untouched duplicate operations remain disposable. Real guest records retain identity and are resequenced into the authenticated scope as a separate tracker.
- Bootstrap pagination: fetch page one, modify server rows, then fetch the continuation. Previously current-row reads could mix generations. A changed watermark now invalidates that generation, using the client's existing bounded restart. This is not a transactionally frozen historical snapshot.
- Starter cleanup: customize an account balance/category or retain deleted financial history in an otherwise empty starter tracker, then run the cleanup dry-run. Candidate selection now rejects customized/history-bearing scaffolds and rechecks before an explicit confirmed cleanup. No cleanup was run on the user's server.

Historical stale device state cannot be attributed conclusively to reinstall/signing behavior from source alone. The diagnostics screen includes bundle/version/build, hashed scope/device identifiers, counts and safe error codes to support that investigation.

## Implementation and invariants

New native modules: `SyncRecoveryPolicy`, `SyncLocalInventory`, `LedgerSyncRecovery`, `FailedOperationsView`, `SyncDiagnosticsView`. Existing sync actor/controller, outbox model, preferences/session, guest adoption, settings/conflict views and en/sq resources were updated. New tests: `backend/tests/test_sync_recovery.py`, `SyncRecoveryTests.swift`, `GuestRecoveryTests.swift`; native fixture helpers were shared from `LedgerSyncActorTests.swift`.

- Local store remains the UI source; recovery changes save atomically through the model context.
- Per-entity ordering includes blocked/backoff failures; later edits cannot jump the earlier operation.
- Parent creates must complete before child operations/default-reference updates are sent.
- Complete bootstrap is required before confirmed discard. Failed downloads keep local edits. New same-record edits after confirmation cancel the requested discard.
- Repair refuses local outbox work, unresolved conflicts and unfinished uploads; it resets sync metadata, not receipt files.
- Overlapping same-scope actor runs share work; different scopes cannot receive the same run result.
- Diagnostics exclude financial payloads, credentials and raw server/user scope identifiers.
- Backend base-version requirements remain strict; matching-version writes to a deleted record also conflict.

## Verification already performed

- Local Linux (WSL, Python 3.14, locked dependencies, SQLite): full backend pytest with coverage **110 passed**, **82.27%**, above the 75% gate. Includes new recovery tests and existing exports/attachment tests. Existing staticfiles warnings remain.
- Windows: Ruff check passed; Ruff format found one changed-file formatting issue and that file was formatted; mypy passed for 110 source files.
- Windows: iOS source-contract check passed; localization coverage passed for 845 literal UI keys. These checks preceded the last native test-file addition.
- SwiftFormat 0.63.0 was applied to the then-changed Swift files; final lint was not run. Early full lint was affected by Windows line endings, which were normalized without unrelated semantic changes.
- Initial Windows pytest failed eight temporary-directory setups; a writable-folder rerun passed 109 tests and failed the Unix permission assertion. The full Linux run subsequently passed that assertion and all 110 tests. The security test was not weakened.

## Unverified gates and remaining risks

- No native Swift compile, XcodeGen execution, simulator tests, unsigned IPA or owner-signed physical-device test. New tests are authored only; final formatting and integration review were interrupted by the immediate-push request.
- Outbox adds optional/defaulted recovery metadata. Existing-store lightweight migration and file-backed process-restart behavior require macOS/device verification. No backend model changes or database migration were introduced.
- Bootstrap watermark invalidation is conservative and global: frequent unrelated server writes can cause retries. PostgreSQL commit-order/concurrent-write snapshot behavior requires further integration review; SQLite tests are not proof of PostgreSQL isolation.
- Confirmed absence means unavailable to this account, not proof of deletion. Dependent work is retained for review, but automated parent remapping is not implemented.
- Full native starter sequencing, concurrent-trigger/refresh-bootstrap integration tests and the remaining requested acceptance scenarios still need completion/execution. The current branch must not be treated as validated for main merely because backend tests pass.

## Physical-iPhone acceptance after native build validation

Use a dedicated test account and preserve any real unsynced data before testing reinstalls.

1. Record bundle/version/build and scope/device digests in Settings > Sync diagnostics.
2. Start as guest without editing, then sign in to a test account with existing server data. Verify restored trackers, accounts, categories and plans, with no additional starter tracker.
3. Repeat with an empty test account; confirm initial provisioning occurs once and the default account/category references survive restart.
4. As guest create an expense and budget, then sign in. Verify both survive, upload once and remain after a later reinstall/login. Imported guest data may be a separate tracker.
5. On two test devices, edit a record offline and delete it remotely. Synchronize, review the deletion conflict, confirm server deletion and verify later same-record edits stop retrying while unrelated pending work remains.
6. Interrupt the network during a confirmed failed-operation discard. Restart; verify the pending recovery remains and completes only after reconnection. Add a new edit during recovery and verify it is preserved.
7. Verify Repair synchronization refuses unsynced edits/uploads. With a clean queue, confirm repair and verify the server snapshot restores the data without deleting receipt files.
8. Copy diagnostics and inspect that it contains only technical metadata, not notes, merchants, amounts, passwords or tokens.

Recommended commit message: `Fix stale sync recovery and preserve guest data across authentication`.
