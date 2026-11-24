# Vault: logins, payment cards, contacts (CHAT-185)

The host keeps one vault per user. It holds three kinds of rows:

- **Logins** (Hermes H32): see `docs/WIRE_CONTRACT.md`, "Login vault".
- **Payment cards**: number, expiry, security code, name, ZIP, label.
- **Contacts**: the user's own contact info (label such as Home or Work,
  name, company, phones, emails, address).

All three are in the same encrypted file as the secrets
(`SecretsVault`, AES-256-GCM, key from the host identity). No value goes
into a log, the runs database or a workspace file.

## What the agent sees

| Kind | The agent sees | The agent never sees |
|------|----------------|----------------------|
| Login | origin, username, label | password, TOTP key |
| Card | brand, last 4 digits, label, default ("Amex •••• 1005, default") | number, expiry, security code |
| Contact | all fields | (nothing hidden) |

Tools:

- `vault_list {kind?: all|logins|payments|contacts}`: counts for All,
  Logins, Payments, Contacts and masked rows.
- `vault_contacts {label?}`: the full contact info.

## Placeholders

The agent writes a placeholder in a browser fill. The host puts in the
value. Placeholders work only in `browser_type.text` and in
`browser_fill_form.fields[].value`. A placeholder in any other place stops
the call.

- Card: `{{card:<id|label|default>:<field>}}`. Fields: `number`, `exp`
  (MM/YY), `exp_month`, `exp_year` (YYYY), `exp_year2` (YY), `cvc`, `name`,
  `zip`. `default` is the default payment method.
- Contact: `{{contact:<label|id>:<field>}}`. Fields: `name`, `first_name`,
  `last_name`, `company`, `phone` (primary), `email` (primary), `street`,
  `line2`, `city`, `region`, `zip`, `country`, `address` (one line).

## Card fill rules

The guard is `VaultGuard` (`agents/runtime/src/chuk_agents_runtime/vault.py`).
It wraps the login guard and is the MCP `call_guard` of each session.

1. The page must be `https` (`http` only for localhost).
2. Each target field is probed in its own frame. The frame must be the page
   itself or a known payment provider (Stripe, Adyen, Braintree, Checkout.com,
   Square, Mollie, PayPal).
3. The field must be a checkout field: an `<input>` with `autocomplete`
   `cc-number`, `cc-exp`, `cc-csc`, ... or a name, id or label for that
   field. A card field of another kind is refused.
4. The user approves each call that uses a card. The action class is
   `payment`. It always asks. The card offers "once" and "deny" only. The
   user can set the class to `deny` for an agent. The user can not set it
   to `allow`. Use one `browser_fill_form` call for the whole checkout:
   then there is one approval.
5. After the fill, the number and the security code are masked in the
   result and in every later browser result of the session. The card number
   is also masked in all tool output and stream frames (the secrets
   scrubber). Screenshots and page scripts on that site are refused for the
   rest of the session.
6. One audit line per fill in `login_vault_audit.jsonl` (`entry_id`
   `card:<id>`, field names, outcome). Never a value.

Contacts need no approval. They are filled on any `https` page.

## Default payment method

The first saved card becomes the default. The app can change it. Text for
the app: "The agent pays with this first. You still approve every purchase."

## Frames (app to host, sealed)

Each frame gets one terminal reply. The reply echoes `request_id`.

| Frame | Reply |
|-------|-------|
| `payment_vault_set {id?, number?, exp_month?, exp_year?, cvc?, name?, zip?, label?, make_default?}` | `payment_vault {entries, default_id, saved}` |
| `payment_vault_delete {id}` | `payment_vault {entries, default_id, deleted}` |
| `payment_vault_default {id or null}` | `payment_vault {entries, default_id}` |
| `payment_vault_list {}` | `payment_vault {entries, default_id}` |
| `contact_vault_set {id?, label, name?, company?, phones?, emails?, address?}` | `contact_vault {entries, saved}` |
| `contact_vault_delete {id}` | `contact_vault {entries, deleted}` |
| `contact_vault_list {}` | `contact_vault {entries}` |

A card entry: `id, brand, last4, label, exp_month, exp_year, name, zip,
has_cvc, is_default, created_at, last_used_at`. Never the number or the
security code. An error is the field `error` with the unchanged list.

`phones` is a list of `{number, primary}`, `emails` a list of
`{address, primary}` (a plain string is also accepted). There is always
exactly one primary row. `address` is `{street, line2, city, region, zip,
country}`.

## Files

- `agents/runtime/src/chuk_agents_runtime/vault.py`: guard, placeholders,
  tools.
- `agents/runtime/src/chuk_agents_runtime/action_policy.py`: class
  `payment`.
- `agents/executor/src/chuk_agents_executor/vault_items.py`: checks and
  views.
- `agents/executor/src/chuk_agents_executor/vault_frames.py`: frames, guard
  factory.
- `agents/executor/src/chuk_agents_executor/secrets.py`: storage.

## Open

- The Flutter app has no Payments and Contacts tabs yet.
