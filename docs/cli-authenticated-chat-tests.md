# Authenticated CLI chat: guarded read or bounded immediate batch

The scoped helper runs the real `bin/sandbox` with minimal authentication and
no polling. Default/help/import paths are offline. **`--live` without
`--send-count` remains T1's read-only, three-RPC check.** Explicit
`--send-count 1..5` selects only that prefix of the five authorized messages.
The parent executed one bounded T3 attempt: publication remains unknown and
the goal is partial. No further server call is authorized; see the observed
live outcome below.

This immediate batch does **not** repair the interactive terminal. T1 and T0a
are closed; T0b is paused with its six-case/two-failure candidate preserved in
stash `94f3dcf1356e5c767e7a7c2357cd8d8413e7a3d2`. T2 closed at `be7e033`
with independent verification and final native acknowledgement; T3 remains
unchecked. See `odd/tasks/cli-authenticated-chat-tests.md`.

## Review path

1. Review the helper's pre-transport request validation and per-SEND reservation.
2. Follow its response gate: baseline → SEND → required READ → confirmed → next SEND.
3. Review the subprocess spec: actual entrypoint, signing, serializers and
   command dispatch execute against synthetic Net::HTTP responses only.

Rollback remains the helper, its spec, this guide and feature-tracker changes.
No production CLI, Dataset, API, auth, serializer or transport source changed.
The human-selected `feature-branch-chain` strategy retains the cohesive safety
unit despite the advisory 400-line budget; coverage is not compressed to fit it.

## Invocation shape and isolation

These are **generic parent-only templates**, not permission to run against an
account. Do not substitute a default/new account, copy a real config into the
repository, or model-read the chosen config. The config path is passed through;
only the actual CLI loads it. Use an absolute, new attempt path inside an
existing owned, non-symlink **0700 private parent**. Never reuse an old attempt,
even if it failed before transport.

Source the toolchain **first**, then apply process-only project overrides and
validate them before Bundler. No installation or bundle-config write is needed:

```sh
source ~/.local/share/ta-hackers-toolchain/env-ruby33.sh &&
export BUNDLE_APP_CONFIG="$PWD/.bundle" BUNDLE_PATH="$PWD/.bundle/native-readline" &&
test "$BUNDLE_APP_CONFIG" = /home/Mario/Projects/personal/ta-hackers/.bundle &&
test "$BUNDLE_PATH" = /home/Mario/Projects/personal/ta-hackers/.bundle/native-readline &&
test "$GEM_HOME" = /home/Mario/.local/share/ta-hackers-toolchain/ruby33-gems &&
~/.local/bin/mise exec ruby@3.3.12 -- ruby "$GEM_HOME/bin/bundle" _2.6.9_ exec ruby \
  scripts/cli_authenticated_chat_check.rb --live \
  --config /absolute/path/to/authorized-existing-config.json \
  --attempt-dir /absolute/private-parent/new-attempt --send-count 5
```

Omit only the final `--send-count 5` pair for the read-only check. Counts 1–5
must be single literal digits in that final position; zero, larger counts,
leading zeroes, arbitrary text/room/commands and other options are refused
before config loading or HTTP. A smaller prefix does not authorize a later
retry or another attempt. Import, no arguments and `--help` are offline.

## Guard contracts

| Boundary | Contract |
| --- | --- |
| Identity/config | Positive account ID learned privately from permitted auth request metadata; profile ID and exact accepted nickname `[ff0000]βℓąȼЌhąţhąȼЌ` checked before baseline. Only `Sandbox::Config#load` reads the config. |
| Auth/session | Existing minimal-auth predicate: parsed first record is an array with nonempty SID at index 3. No first-field-zero, six-field minimum or SID-format constraint. Every subsequent request uses the same private SID. |
| Transport | HTTPS `hackers-1.appspot.com:443/req.php`, TLS peer verification, proxies disabled, timeouts 10/15/10 seconds, retries zero, version 1229. |
| Before sockets | HTTP start is deferred until request validation. GET only, no payload, exact key sets, native bare auth/chat flags and profile equals flag, unchanged production signing; reject extra/duplicate keys, forbidden operations, host/room/identity/session/cursor/text deviations. |
| Default live sequence | Auth → profile → one World 999 baseline read; exactly three RPCs, no sending. Local `GAME.chat.open(999)` retains the cursor without a polling thread. |
| Explicit batch | Auth → profile → baseline → `(chat_send → chat_display)` up to five times; ceiling `3 + 2 * count`, at most 13 RPCs. Real CLI commands are `chat say 999 Test codificacion N` and `chat read 999`. |
| Fixed text | Only `Test codificacion 1` through `Test codificacion 5`, in order, with validated request room 999 and the authenticated player ID. |
| Durability | New exclusive directory 0700; initial reservation/captures 0600. Batch syncs attempt-directory creation in its parent. Before each SEND, exclusively create `send-N.json` 0600, check complete write length, flush/fsync file contents, then fsync containing-directory metadata. Failure prevents original transport. Never delete/replace/reset spent reservations. |
| Response gate | HTTP status, encoding and chat schema validated before the CLI can advance. Chat validation mirrors Dataset's exception-envelope and strict seven-field/numeric-ID/country checks, then uses public `Serializer::Chat`. No Dataset-private reflection or protocol extension. |
| Cursor/observations | Baseline and all SEND/READ rows enter observed identities. Public serializer order advances the guard cursor just like Dataset, including SEND rows. Every next request must carry that cursor. |
| Confirmation | Only the required READ may confirm: scalar own ID + exact current text + validated request room + a fresh identity. Conservative identity is own ID/datetime/request room/text; display name, level, rank and country changes do not make a reused echo fresh. Country is not the room field. |
| Stop policy | First timeout, HTTP error, malformed response, reservation failure or absent/stale/wrong echo stops the batch with no retry, extra READ, polling or next SEND. HTTP 200 and SEND response bodies are not publication proof. |

### SEND may consume the echo

Both Dataset reads and writes advance the cursor. If SEND returns an owned
current-message echo, it becomes preobserved and may advance the cursor. The
single subsequent READ is still required. If that READ is empty or cannot
provide a fresh echo, stop with `echo-unconfirmed`, confirmed count unchanged.
Do **not** rewind/reset the cursor, add a READ, repeat the SEND or continue.

### Existing CLI aggregate limitation

Production batch bookkeeping currently conflates parsed country with room.
The helper instead derives room provenance from the validated request. A valid
owned READ echo with country other than 999 can therefore increment the guard's
actual `confirmed_count` while the existing CLI exits 1. The helper honestly
returns `cli-failed`/nonzero exit and retains that count; it does not force
success or mask the compatibility failure. Fixing that aggregate is outside
this slice. Safe publication evidence and overall CLI compatibility are
separate claims, and neither establishes interactive-terminal correctness.

## Private evidence and public outcomes

Raw CLI output stays in exclusive 0600 `stdout`/`stderr` files in the private
attempt. `reservation.json`, `send-N.json` and `summary.json` are also private.
Never expose/read real-account captures or ledgers through model output.
The public JSON contains only static classifications/error classes, RPC count,
integer statuses, name-verification boolean, message count and normalized CLI
exit. Batch mode also exposes:

- `reserved_count`: completed durable SEND reservations, not proof of delivery.
- `possibly_dispatched_count`: conservative count marked before original
  transport starts; a timeout/error may leave actual delivery unknown.
- `confirmed_count`: only fresh owned echoes from required READs.

A failed reservation may leave a spent file even if `reserved_count` did not
increment. Do not retry it or reuse its attempt. Final summary is reporting,
never a substitute for the per-wire gate. Public output never includes account
ID, SID, credentials, raw profile/chat, exception messages, nickname or text.

## Observed offline verification

Every current Ruby check used the source-first, post-export, validated prefix
above, ending in `bundle _2.6.9_ exec` followed by the command below. Synthetic
subprocesses use disposable configs, not the authorized account or a server.

| Command after prefix | Observed T2 result |
| --- | --- |
| `rspec spec/cli_authenticated_chat_check_spec.rb` | Initial RED 42/2: missing batch functionality. Durability RED 90/1: incomplete reservation write allowed all 13 RPCs. Payload RED 95/1: GET body accepted. Final GREEN 98 examples/0 failures, preserving all 40 T1 cases. |
| `rspec spec/cli_authenticated_chat_check_spec.rb spec/cli_chat_spec.rb spec/cli_batch_spec.rb spec/game_minimal_auth_spec.rb spec/cli_connect_spec.rb` | 188 examples/0 failures. |
| `rspec spec/cli_authenticated_chat_check_spec.rb spec/cli_chat_spec.rb spec/cli_batch_spec.rb spec/game_minimal_auth_spec.rb spec/api_spec.rb` | 215 examples/0 failures (original API-focused contract). |
| `rspec` | 994 examples/0 failures. Stashed terminal candidate is not active; no GUI-pass claim. |
| `ruby scripts/cli_chat_diagnostic_check.rb --self-test` | 24 checks passed; self-test only. |
| `ruby scripts/cli_current_prefix_check.rb --self-test` | 10 checks passed; self-test only. |
| `ruby -c scripts/cli_authenticated_chat_check.rb` | Syntax OK. |
| `ruby -c spec/cli_authenticated_chat_check_spec.rb` | Syntax OK. |

No pending examples were reported. Existing Base64 future-Ruby warning only;
no dependency mutation. The 13-RPC success proves exact message order, same
private identity/session, cursor evolution, CLI-only config loading, zero
polling and file/directory fsync before each synthetic SEND. Negative cases
cover first/middle timeout/HTTP/schema errors, missing/wrong-owner/wrong-text
READs, baseline/future identity reuse, SEND-consumed echo, incomplete writes,
file/open/fsync and per-send directory-sync failures, and exclusive reuse
refusal. T1 transport/option/privacy checks and both legal SID variants remain.
These are structural/fake-transport proofs, not packet monitoring or live
account/publication verification.

Historical T1 evidence remains separate: initial RED 2/2, correction SID RED
2/2, corrected GREEN 40/0, relevant 149/0, full 928/0, helpers 24+10 and syntax
passing. T0a subsequently established the reviewed 936-example baseline.
Parent owns commit, assessment and native lifecycle. These offline results
belong to the unchanged source unit, not new tests of this passive report.

## Observed bounded live attempt

**Partial: required fresh owned READ echo unconfirmed; publication unknown.**
After T2 closed at `be7e033ba1b46be334c2863a1504add79a8460af`, the parent
launched the real CLI helper once with `--live --send-count 5`. The sanitized
allowlisted summary, not private captures, supplies this evidence:

| Evidence | Observed result |
| --- | --- |
| Classification / error class | `echo-unconfirmed` / null |
| RPC count / HTTP statuses | 5 / `[200, 200, 200, 200, 200]` |
| Existing-account name/profile check | `name_verified=true` |
| Durable reserved / possibly dispatched / owned confirmed | 1 / 1 / 0 |
| CLI exit / process exit | 1 / 1 |
| Single launch / retry permitted / shared config unchanged | true / false / true |

Sequence: auth → profile → baseline → SEND `Test codificacion 1` → required
READ 1. The durable pre-wire reservation is spent. No sends 2–5, next RPC,
extra READ, retry or new attempt followed the unconfirmed echo. HTTP 200 and
possible dispatch prove neither publication nor loss; incoming content and
interactive listening are not established. The last CLI `message_count=0`
reflects baseline bookkeeping, not evidence that READ 1 was empty.

The synthetic country/room aggregate limitation and SEND-consumed-echo case
above do not establish this attempt's cause. Private captures/ledger bytes
remain private, preserved and never reusable/resettable. Unused ceiling
capacity is not permission for remaining queries. Any additional server call
requires fresh explicit bounded human authorization and a separate diagnostic
scope; T3 stays unchecked until its underlying goal is proven.
