# Apple Wallet Transaction Shortcut setup

Status: the server Shortcut endpoints and token screen are Milestone 6 work. These construction steps are a reproducible contract, not a claim that an importable `.shortcut` file has been signed or verified.

Apple documents that a Shortcuts Transaction trigger can run based on a selected Wallet card and that `Get Contents of URL` supports JSON POST bodies. Apple may vary exposed field labels by iOS version/region; inspect the actual Transaction input on the target iPhone.

## Before creating the automation

1. Confirm ordinary manual app entry and foreground sync work.
2. In Project Ledger Settings → Shortcut, create a token restricted to `categories:read`, `accounts:read`, and `transactions:create`, optionally locked to one tracker.
3. Copy the raw token once into the Shortcut. Do not screenshot/share it. The server stores only its digest.
4. Select a default tracker/account to reduce prompts.
5. Replace `https://replace-me.ts.net` below with the exact HTTPS API host shown by the app.

## Online automation

1. Shortcuts → Automation → New Personal Automation → Transaction.
2. Select the intended card(s) and the available immediate-run option. Do not infer that every iOS/region offers identical prompting behavior.
3. Inspect Shortcut Input and extract amount, currency, merchant, transaction date, and optional card label. Do not extract or transmit a payment credential.
4. Use `Get Contents of URL` with:
   - URL: `https://replace-me.ts.net/api/v1/shortcut/context`
   - Method: `GET`
   - Header: `Authorization: Bearer <shortcut-token>`
5. Choose from returned categories. Use default tracker/account or prompt when desired.
6. Generate one UUID and retain it in a variable.
7. Convert the localized decimal amount to integer minor units using the returned currency exponent. Never concatenate localized digits and guess precision.
8. Add a second `Get Contents of URL`:
   - URL: `https://replace-me.ts.net/api/v1/shortcut/transactions`
   - Method: `POST`
   - Headers: `Authorization: Bearer <shortcut-token>`, `Idempotency-Key: <UUID>`, `Content-Type: application/json`
   - Body: JSON matching `docs/api.md`; use the same UUID for `event_id`.
9. Check the response status/result. Show a short success message for created/existing; show a safe actionable failure for other results.

## Safe synthetic test

Before enabling the personal trigger, build a normal Shortcut with amount `1.00`, currency `ALL`, merchant `PROJECT LEDGER TEST`, `needs_review=true`, and a fresh UUID. Delete/void the test through the app after confirming one record appears. Never test using a real card credential.

## Offline queue variant

Build the same versioned payload and UUID before networking. If the POST fails, append only the payload—not the token—to a JSON-lines file in a user-visible Shortcuts folder. A separate “Flush Expense Queue” Shortcut reads records, POSTs a bounded array to `/shortcut/transactions/batch` with the same event IDs, and rewrites the file with only unacknowledged records. Re-running the flush is safe by server idempotency.

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

This automation is a capture aid, not bank reconciliation. Wallet transaction triggers do not grant the app ongoing Wallet history access.

