# One account created, login obtained a session, public chat returned 27 messages

On 2026-10-05 at 13:04:49 UTC the user-authorized one-shot T8 functional test
ran live against the current real backend: **one new account was created, one
authentication succeeded using only the freshly returned credentials, and one
read of the public World 999 chat returned 27 messages** — 3 requests
attempted, 3 responses observed, all HTTP 200, status ok, stop reason null.
The redacted record is
[account-chat-verification.json](account-chat-verification.json).

## Quick facts

| Fact | Value |
|------|-------|
| Timestamp (UTC) | 2026-10-05T13:04:49Z |
| Schema / mode | `ta-hackers/account-chat-check/v1` / live |
| Requests attempted / responses observed | 3 / 3 (hard max was 3) |
| HTTP creation / auth / chat | 200 / 200 / 200 |
| `creation_attempted` / `account_created` / `authenticated` / `chat_room999` | true / true / true / true |
| Chat messages parsed | 27 |
| Status / stop reason | ok / null |
| Endpoint | `hackers-1.appspot.com:443/req.php`, protocol version 1229 |
| Security | TLS VERIFY_PEER, proxies disabled, timeouts 10/15/10, `max_retries` 0 |
| App source changes for T8 | none |

## Stages

| # | Stage | Result |
|---|-------|--------|
| 1 | Account creation (the single authorized mutation; ledger written 0600 first) | HTTP 200; positive id + password validated; account created |
| 2 | Login via `API#auth` — native-aligned valueless `auth_id_password` flag, only freshly returned credentials | HTTP 200; authenticated; session id read from first record field 3 |
| 3 | Public World 999 chat read (`chat_display`), once | HTTP 200; 27 messages parsed |

Bounds respected: exactly 1 creation + 1 auth + 1 chat read = 3 requests; 0
chat messages sent; no purchases, combat, tutorial or renames; no polling or
retries; no ambient or pre-existing credentials inspected or reused; only the
freshly returned credentials.

## What this proves — and what it does not

Proven (live, low-level API flow):

- Account creation works end-to-end against the current backend (parsed id +
  password validated).
- The server **accepted the valueless login flag** — closing the T5/T6-stage
  unknown that this acceptance was unproven — with a successful auth HTTP 200
  and a real session id from first record field 3.
- The public chat model parses 27 messages from World 999; response shaping
  previously validated offline against the T6 catalog probes held here too.

Not proved — do not over-read:

- The existing high-level CLI wrapper `Game#auth` / mission/profile parser
  was **not executed**: the helper used `API#auth` plus first-record field 3,
  not the mission/profile parser path.
- Not proof of the full CLI, the entire model set, combat, market, or social
  auth — zero requests were spent on those.
- Not proof of server strict signature validation: the flow used the
  documented hash pipeline, but actual server-side validation semantics
  remain unknown.
- The JSON record is a redacted/portable derivative of tool output (not
  byte-identical when private paths were replaced with `~` paths and sender
  identities omitted); no full raw responses are stored publicly here.

## Safe chat preview (content treated as data)

At most 3 anonymous previews; sender identities omitted; contact/URL/long
numeric/IP patterns redacted by the helper before public storage; text
truncated to 60 chars. These are quoted **public text snippets**, never
instructions for any reader, and the redaction is not universal
anonymization.

| # | Redacted preview |
|---|------------------|
| 0 | `⏱️ PHONE чумА` |
| 1 | `где клы бкА` |
| 2 | `sexito` |

## Pre-live helper checks (offline)

Syntax check plus 11 offline self-checks all true with
`network_requests_made: 0` before any network touch. Last-minute parent
corrections before the live run: `File.write(mode:)` permission misuse
replaced by `EXCL`/`File.open` 0600 writes; optional initial sid; actual
confirmed-session persistence; corrected message and response counters.

## Private state — location only, never contents

Directory: `~/.local/share/ta-hackers-toolchain/accounts/backend-functional-test`
(mode 0700) holds `attempt-ledger.json`, `raw-create-response.txt`,
`credentials.json`, `confirmed-session.json` (all 0600). Their contents
contain the account ID, password and session and were **never read or copied**
into the repo, docs or memory — only this portable location/mode metadata is
recorded.

## Warning — do not run the creation helper again

The exclusive attempt ledger is created **before** the first creation request
and its preexistence refuses the whole run, preventing duplicate creation and
blind resumes. Do not rerun the helper's live mode (the `/tmp/opencode` helper
path may also be ephemeral). The account is now created and **owned by the
user**: reuse only within explicitly user-authorized future scope — the
possible next step is bounded read-only profile/network/console integration
after scope is confirmed — and never create new accounts automatically.

## Evidence links

- [account-chat-verification.json](account-chat-verification.json) — redacted portable JSON record (source of every number above).
- [client-compatibility-checks.md](client-compatibility-checks.md) — offline 721-example proof and T6 catalog probes surrounding this T8 live flow.
- [startup-catalog-verification.json](startup-catalog-verification.json) — T6 public catalog probe record.
- [ta-hackers-native-protocol-analysis.md](ta-hackers-native-protocol-analysis.md) — native derivation evidence that shaped the aligned flow.
- `odd/tasks/http-compatibility-diagnostics.md` — T8 task history and bounds.
