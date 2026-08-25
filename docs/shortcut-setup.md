# Apple Wallet Transaction Shortcut setup

Status: the server credential, lookup, single-capture, and batch-capture endpoints are implemented and pass local automated tests. The native token/default-management source is implemented and passes Linux privacy/localization/syntax contracts, but has not yet compiled or run under Xcode. These construction steps are a reproducible contract, not a claim that an importable `.shortcut` file or current-device behavior has been signed or verified.

On 2026-08-09, Apple’s current [Transaction trigger guide](https://support.apple.com/guide/shortcuts/transaction-trigger-apd65c67538a/ios) still documents Wallet transaction automation, and [Get Contents of URL](https://support.apple.com/guide/shortcuts/request-your-first-api-apd58d46713f/ios) still documents JSON POST bodies. Apple may vary exposed fields, labels, card-selection choices, and immediate-run behavior by iOS version, region, and payment configuration; inspect the actual Transaction input on the target iPhone.

## Before creating the automation

1. Confirm ordinary manual app entry and foreground sync work.
2. In Miravo Settings → Apple Wallet Shortcut, create a token. The screen requests only `categories:read`, `accounts:read`, and `transactions:create`, and recommends locking it to one tracker.
3. Copy the raw token once into the Shortcut. Miravo does not persist it; the explicit copy is local to the iPhone clipboard and expires after five minutes. Do not screenshot/share it. The server stores only its digest.
4. Select a default tracker/account to reduce prompts.
5. Replace `https://replace-me.ts.net` below with the exact HTTPS API host shown by the app.

A developer can also exercise the same authenticated management contract with `POST /api/v1/shortcut/credentials` and this JSON body:

```json
{
  "name": "Wallet automation",
  "tracker_id": "UUID or null",
  "scopes": ["categories:read", "accounts:read", "transactions:create"]
}
```

That request uses an ordinary access JWT. Its 201 response is the only response containing `raw_token`. `GET /api/v1/shortcut/credentials` never returns it, and `DELETE /api/v1/shortcut/credentials/{id}` revokes it immediately. Do not place the access JWT or refresh token in a Shortcut.

## Online automation

1. Shortcuts → Automation → New Personal Automation → Transaction.
2. Select the intended card(s) and the available immediate-run option. Do not infer that every iOS/region offers identical prompting behavior.
3. Inspect Shortcut Input and extract amount, currency, merchant, transaction date, and optional card label. Do not extract or transmit a payment credential.
4. Use `Get Contents of URL` with:
   - URL: `https://replace-me.ts.net/api/v1/shortcut/context`
   - Method: `GET`
   - Header: `Authorization: Bearer <shortcut-token>`
5. Select a tracker from `trackers`, unless the one tracker-scoped token already determines it. The response supplies tracker defaults, base currency, and base-currency exponent.
6. Fetch the active choices as needed:
   - `GET https://replace-me.ts.net/api/v1/shortcut/categories?tracker_id=<UUID>`
   - `GET https://replace-me.ts.net/api/v1/shortcut/accounts?tracker_id=<UUID>`
   - use the same bearer header; a tracker-scoped token may omit the query parameter.
7. Choose a category and account, or use the returned `is_default`/context default IDs. `category_id` may be null when the record is deliberately marked `needs_review=true`; `account_id` is required.
8. Generate one UUID and retain it in a variable. Do not regenerate it during retry handling.
9. Convert the localized decimal amount to integer minor units using the selected account/result currency exponent. Never concatenate localized digits and guess precision. For exponent `e`, multiply the decimal value by `10^e` and accept it only when the result is an exact positive integer.
10. Build a Dictionary using this mapping:

| API field | Shortcut value |
|---|---|
| `event_id` | The retained UUID |
| `source` | Literal `apple_wallet_shortcut` |
| `tracker_id`, `account_id`, `category_id` | Selected/default IDs; category may be null |
| `amount_minor`, `currency` | Exact minor-unit integer and ISO currency from the trigger/account |
| `merchant`, `occurred_at`, `card_label` | Exposed transaction values, with an ISO 8601 date |
| `note` | Optional text or null; never a payment credential |
| `needs_review` | True when category/conversion needs app review |
| `client_payload_version` | Integer `1` |

11. Add a second `Get Contents of URL`:
   - URL: `https://replace-me.ts.net/api/v1/shortcut/transactions`
   - Method: `POST`
   - Headers: `Authorization: Bearer <shortcut-token>`, `Idempotency-Key: <UUID>`, `Content-Type: application/json`
   - Body: the Dictionary above; use the same UUID for `event_id` and `Idempotency-Key`.
12. Treat `status=created` and `status=duplicate` as success. Preserve the same UUID/payload for an uncertain transport result. Show a safe actionable failure for validation, authorization, rate-limit, or server errors.

If transaction, account, and tracker-base currencies do not match, this minimal automation is insufficient. It must ask the user for explicit account/base minor-unit amounts and the full rate snapshot described in `docs/api.md`, or queue the entry for manual app review. The server never invents a rate.

Miravo can show its own local “Shortcut expense added” notification only after the app synchronizes and sees the new `source=shortcut` expense. This does not replace immediate Shortcut feedback: if the app is not running and no background refresh occurs, the Shortcut should still show its own success/failure result.

## Safe synthetic test

Before enabling the personal trigger, copy `docs/examples/shortcut-transaction.json`, replace the tracker/account IDs and UUID, and send it with a normal test Shortcut using merchant `PROJECT LEDGER TEST` and `needs_review=true`. Send the identical request twice and confirm the first result is `created`, the second is `duplicate`, and only one transaction exists. Void the test through the app afterward. Never test using a real card credential.

## Offline queue variant

Build the same versioned payload and UUID before networking. If the POST fails or its result is unknown, append only the payload—not the token—to one JSON object per line in a user-visible Shortcuts folder such as `Shortcuts/Miravo/pending.jsonl`.

A separate “Flush Expense Queue” Shortcut should:

1. Read at most 50 queued lines and decode each JSON object.
2. Wrap them as `{"transactions": [/* decoded objects */]}` like `docs/examples/shortcut-batch.json`.
3. POST to `/api/v1/shortcut/transactions/batch` with the bearer and JSON content-type headers. The batch route does not need a top-level `Idempotency-Key`; each unchanged `event_id` is its key.
4. Remove only items whose matching result is `created` or `duplicate`.
5. Preserve `rejected` items and every unsent line, with the original event IDs and payloads. Surface the returned safe code for manual correction.

Re-running the flush is safe while those event IDs remain unchanged. The server initially retains user-scoped idempotency receipts for 120 days, so token rotation does not make an acknowledged queued event new.

File append/replace behavior must be manually verified on the installed iOS release. If Shortcuts cannot atomically rewrite the queue, preserve the input file and write a new acknowledged-ID file instead; document that manual cleanup is required.

## Troubleshooting

| Result | Action |
|---|---|
| Unauthorized/revoked | Create a new scoped token in the app and replace the Shortcut header; never broaden to a normal refresh token |
| Unreachable/server unavailable | Confirm HTTPS host, Funnel status, server readiness; queue payload with same UUID |
| Duplicate/existing | Success: the original idempotent record is returned |
| Idempotency conflict | The same UUID was reused with different data; preserve both payloads and generate a new UUID only for the genuinely distinct event |
| Invalid amount/currency | Re-check locale decimal parsing and currency exponent; do not round with binary floating point |
| Missing category | Allow `needs_review=true`/null category if server policy permits, or refresh context and choose one |
| Conversion required | Supply the complete explicit snapshot or preserve the item for app review; never guess a rate |
| Rate limited | Keep the original payload/UUID and retry later; do not create replacement events |

This automation is a capture aid, not bank reconciliation. Wallet transaction triggers do not grant the app ongoing Wallet history access.
