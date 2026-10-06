# Authenticated CLI chat check: offline-proven read-only slice

T1 introduces a scoped helper that runs the real `bin/sandbox` minimal batch:
`connect` → exact `name --expect` → `chat read 999`. It cannot send. Import,
help and default execution are offline. **LIVE ONLY AUTHORIZED PARENT**, after
all three source slices (T1, T0, T2) have been verified; this document is not a live execution
instruction. No live outcome has been observed.

## Review path

1. Review `scripts/cli_authenticated_chat_check.rb`: exclusive reservation,
   deferred HTTP start, exact request allowlists and safe summary.
2. Review `spec/cli_authenticated_chat_check_spec.rb`: subprocess fake HTTP
   runs the actual CLI entrypoint, serializers, signing and command dispatch.
3. Parent commits/reviews T1 before the separately authorized T0 terminal unit;
   T2 follows T0. The feature tracker is `odd/tasks/cli-authenticated-chat-tests.md`.

## Read-only contract

| Boundary | Implementation |
| --- | --- |
| Opt-in | Exact option shape: live opt-in, explicit absolute chosen config path, explicit absolute new attempt directory. No default account or injected commands/messages/scripts. |
| Config ownership | Only the real CLI `Sandbox::Config#load` reads the chosen config. The guard learns a positive account ID internally from the permitted auth request and binds profile/session checks to it. |
| Auth response | Match existing `Game#auth_minimal`: the parsed first record must be an array with nonempty SID at index 3. No first-field-zero, six-field minimum, tail-field or SID-format assumption. Missing/empty SID and invalid UTF-8 still stop; subsequent requests must bind to that exact private SID. |
| Identity | Exact accepted nickname `[ff0000]βℓąȼЌhąţhąȼЌ`; guard and real CLI both check it before the read. |
| Transport | HTTPS `hackers-1.appspot.com:443/req.php`, peer verification, no proxy, 10/15/10-second timeouts, retries zero. |
| Before sockets | Production client normally starts HTTP before `get`; the helper defers that start until destination and parameter validation, then invokes original transport inside original start. |
| RPC ceiling | Auth, profile, one World 999 display only; strict key sets reject sends, rename, creation, catalogs, extras, duplicates and out-of-order calls. Native bare auth/display flags and profile equals encoding are preserved. Production signing is unchanged. |
| Attempt ownership | Exclusive new directory 0700, files 0600, private owned parent; reject existing names and symlink ancestors/destinations. Reservation is flushed/fsynced before transport. Never truncate, reset or inspect old attempts. |
| Evidence | Raw CLI output stays in private stdout/stderr files. Public summary contains only static classification/error class, RPC count, integer statuses, boolean name verification, integer message count and normalized CLI exit. No URI, name, text, identity, session, password or exception message is published. |
| Stop policy | Wrong name/identity, malformed auth/profile, transport failure/timeout or CLI failure prevents subsequent steps. A malformed read ends the three-RPC attempt without further work. |
| Local baseline | After the accepted profile, local-only `GAME.chat.open(999)` retains the room through the CLI one-shot read. The CLI still validates name before reading. No polling thread and no extra RPC. An empty read retains an empty cursor; it does not invent one. |

Private attempt files are `reservation.json`, `stdout`, `stderr` and
`summary.json`. The reservation is deliberately not a reusable workflow or
send authorization. Existing configurations are neither assumed authorized
nor inspected by the helper before the CLI loads them.

## Observed offline evidence

All Ruby commands used this exact prefix:

```sh
source ~/.local/share/ta-hackers-toolchain/env-ruby33.sh && ~/.local/bin/mise exec ruby@3.3.12 -- ruby "$GEM_HOME/bin/bundle" _2.6.9_ exec
```

| Command after prefix | Observed result |
| --- | --- |
| `rspec spec/cli_authenticated_chat_check_spec.rb` (RED) | 2 examples, 2 intended behavioral failures: scaffold dispatched zero RPCs instead of auth/profile/read and auth/profile. No missing-file/setup failure. |
| `rspec spec/cli_authenticated_chat_check_spec.rb --example 'accepts minimal-auth SID variant'` (correction RED) | 2 examples, 2 intended `auth-malformed` failures before helper correction: six fields with nonzero first field and four fields with nonempty SID. |
| `rspec spec/cli_authenticated_chat_check_spec.rb` (correction GREEN) | 40 examples, 0 failures. |
| `rspec spec/cli_authenticated_chat_check_spec.rb spec/cli_chat_spec.rb spec/cli_batch_spec.rb spec/game_minimal_auth_spec.rb spec/api_spec.rb` | 149 examples, 0 failures. |
| `rspec` | 928 examples, 0 failures. |
| `ruby scripts/cli_chat_diagnostic_check.rb --self-test` | 24 checks passed; never invoked live. |
| `ruby scripts/cli_current_prefix_check.rb --self-test` | 10 checks passed; never invoked live. |
| `ruby -c scripts/cli_authenticated_chat_check.rb` | Syntax OK. |
| `ruby -c spec/cli_authenticated_chat_check_spec.rb` | Syntax OK. |

No pending/skipped examples were reported. The existing Base64 future-Ruby-3.4
warning is not a failed check; no dependency change was made. Synthetic
subprocesses verify actual three-RPC order, both exact-name checks, config
read ownership, pre-transport reservation, private permissions, retained
cursor and zero polling. Alternate cases include wrong name/profile identity,
malformed auth/chat, timeout at each ordinal, forbidden parameters/options,
destination/TLS/proxy/timeouts/retry deviations, bare flags and duplicate paths.
These are structural/fake-transport proofs, not packet monitoring or live
server/account verification. The two auth variants now pass the real CLI
three-RPC path with retained cursor and CLI-only synthetic config loading.
This proves alignment with the existing minimal-auth predicate, not a backend
packet format or the meanings of other auth fields.

Whitespace verification passed: `git diff --check` plus explicit EOF/trailing
whitespace checks of all four untracked surfaces.
The previously disclosed 705-line initial unit remains above the
400-line heuristic: retaining the single reservation/transport boundary with
its adversarial tests avoids an unsafe or nonfunctional partial slice.

## Next slice and rollback

T0 is a separately authorized terminal/poller compatibility unit after T1;
this correction does not implement it or alter its allowed scope. The parent
retained the prior automated config, not `mine`; no config was inspected here.

The human's new bounded authorization supersedes the singleton permission:
**approved send count 5**, same existing account/nickname/configuration and
World 999. No real requests have occurred. Future T2/T3 may attempt only the
exact sequential messages `Test codificacion 1` through `Test codificacion 5`,
with a maximum of **13 RPCs**: auth/profile/baseline plus up to five send/read
pairs. This is not unlimited permission.

T2 must keep this baseline room/cursor, record preobserved echo identities and
make a separate durable pre-wire reservation for each permitted message.
Each fresh owned exact-text/World-999 echo must be confirmed before the next
send; HTTP success or a preexisting message is not confirmation. Stop on the
first timeout, error or unconfirmed result, with no retry or next send. T3
records the actual confirmed count and any early-stop outcome, never invented
success. No fresh account, rename, gameplay, polling, extra reads or reset of
previous paths is authorized. T1 implements none of these send capabilities:
its fake execution and runtime guard remain read-only, exactly three RPCs.
Do not reuse old fixed-path helpers live.

Rollback boundary: remove only the new helper, its spec, this guide and this
feature's tracker changes. Production CLI/API/transport and unrelated task
metadata are unchanged. Parent owns staging, local commits, candidate review
and the eventual bounded live handoff. T1 remains unchecked until that
parent-owned lifecycle is complete.
