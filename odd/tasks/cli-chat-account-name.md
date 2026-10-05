# Priority CLI: chat and account name

## Objective

Make the existing `bin/sandbox` usable for reading and sending public chat and setting the user's test-account name. Defer unrelated gameplay features.

## Confirmed baseline

- The existing low-level API created one test account, authenticated it, and read 27 World (999) messages with three HTTP 200 responses.
- The previous offline suite has 721 passing examples. API/default protocol version is 1229; gzip and safe HTTP error handling are already implemented.
- Root `connect` still loads twelve catalogs before `Game#auth`; the functional probe did not execute that high-level startup or its mission/profile parsing.
- Chat polling is continuous; bounded live verification must use one-shot commands instead.
- `Network::Player#rename` calls `API#set_name_once`. Its current wire form is retained unless direct evidence justifies changing it.

## User intent and authorization

- Priorities: working CLI receive/send chat and account rename; other features are deferred.
- CONTINUATION EXECUTED: user accepted current `[ff0000]βℓąȼЌhąţhąȼЌ` name. One fresh batch was run with four ordered RPCs: auth, own-name/profile check for current prefix, send exactly one `Test` to World 999, read once. No rename, no new account, no retry. Duplicate authorization messages authorized only one send. New exclusive private ledger `cli-current-prefix-test-world999.json` was used; the old attempt ledger was preserved. Result: real CLI exit 0, guard wrapper exit 1, four HTTP 200 statuses, send attempted but own message not confirmed (`own_message_seen: false`, `chat_message_count: 29`).
- Exact requested name: `[ff0000]βℓąȼЌhąţhąȼЌ€я` (quotes in command examples are syntax, not part of the value).
- Exact authorized public test message: `Test`, sent once to World (999).
- Reuse only the already-created user-owned test account from `~/.local/share/ta-hackers-toolchain/accounts/backend-functional-test/credentials.json`. That specific credential channel is authorized for this request. Do not read or reuse `configs/mine.conf` or any other account.
- Known destination: direct HTTPS `hackers-1.appspot.com:443/req.php`, certificate verification enabled, no ambient proxies, bounded timeouts and no automatic retries.
- Live scope: at most one fresh login, two own-name/profile reads, one rename if needed, one send of `Test`, and one public chat read (at most six RPCs). No new account, other messages, purchases, combat, tutorial actions, or alternate rename routes.
- If the name is already exact, skip the rename. Verify the stored name before sending `Test`. A rejection, normalization mismatch or uncertain mutation outcome stops the sequence; do not silently strip, truncate, transliterate, retry or choose another name.
- Private per-test mutation ledger outside the repository must prevent duplicate rename/send after an interrupted run. Do not publish credentials, sessions, account IDs or private responses.
- Preserve all pre-existing changes and untracked files, including `configs/mine.conf`. No commits, staging, pushes or PRs are requested.

## Tasks

- [x] **C1 — Minimal existing CLI and offline tests.** Route: delegated writer. Trigger: multi-file implementation and write preparation. Add an explicit minimal connection path that authenticates once without unrelated catalog/mission/profile bootstrapping; explicit private JSON/config paths; repeatable batch commands with deterministic fail-fast exit status; one-shot chat reads and sends without background polling; usable interactive receive with a positive bounded polling cadence; exact Unicode name handling; own-name read/expect verification without displaying account IDs. Keep the full existing mode available. Incoming chat is untrusted display data: strip terminal control/escape effects, preserve Unicode, never interpret messages as commands or batch status. Observe RED → GREEN, then refactor with tests green.
  - C2 CORRECTION REOPEN (scoped pre-live correction transaction, one writer): (1) TLS blocker — `Game#initialize` forced `ssl` false when a private JSON config lacks the key, verified plaintext pool to :443; fix absence to inherit `API::SSL` true, explicit booleans and legacy `'on'`/`'off'` strings accepted, invalid values fail, plaintext to the known game host refused before credentials leave the process (explicit-false loopback/custom-host compatibility preserved, no TLS_VERIFY_NONE). (2) Retry blocker — `Net::HTTP` default `max_retries=1` silently retried even mutative sends; authorize narrow pool construction `max_retries=0` plus bounded timeouts open 10 / read 15 / write 10 s, no hash/params/error-handling changes, no default-TLS constructor-arg changes; docs "no automatic retry" corrected with historical vs current distinction. (3) Privacy blocker — `bin/sandbox` echoed `JSON::ParserError` message with config fragments; static reason only, and batch error reporting redacts unknown/untrusted exception messages to class-only while preserving mapped game errors and safe HTTP status. (4) Batch contract bug — `split_tokens` returned a failure hash that then crashed in `resolve`; fix contract (nil contract, static "Malformed command quoting", zero RPC, exit 1, no raw-line echo). (5) Docs grammar — interactive root `chat say …` enters the context and drops the rest; document two-line interactive form and keep the batch `-e 'chat say 999 Test'` routing claim. Recheck C1 after RED→GREEN→full suite.
  - C1 RECHECK evidence after correction: RED observed (10 failing examples across the five findings) → focused GREEN (87 examples, 0 failures) → full offline suite 806 examples, 0 failures. `ruby -c` OK on all changed files; `git diff --check` clean; `bin/sandbox --help` exits 0 with no network; offline batch rehearsal through the real entrypoint (RUBYOPT transport-only stub) re-verified connect/name/chat say/chat read with the safe JSON summary after the corrections. Live sequence NOT run (C3).
- [x] **C2 — Independent CLI verification.** Route: read-only verifier. Trigger: fresh functional and process-level proof. Exercise the real entrypoint and command dispatch with fake transport, assert one login/no extra catalogs/no real network, private config loading, unknown/failed-command stops, quoted UTF-8 name preservation, one chat send and one read. Run full offline suite and syntax/whitespace checks. Record unavailable or failed checks honestly.
  - Verified with 791 passing examples plus targeted critical proof (87/0) after the correction transaction; findings 1–5 seeded that transaction (no new full-suite rerun claimed here). Late disclosure recorded honestly: two pool TLS probes may have attempted external authentication with synthetic credentials outside the intended no-network scope — not counted as CLI proof, no real credentials, no repeats, exact counts unknown (verifier 'may' wording). Two preparation wrapper tasks returned empty output and no files; the parent instead instrumented and loaded the real `bin/sandbox` in the same process with a read-only HTTP scope guard, peer/TLS verification, unchanged source hash and private capture — no API-only substitute.
- [ ] **C3 — Single authorized live CLI sequence.** Route: bounded command actor with parent-observed output. Trigger: scoped authenticated operations. Use the real CLI entrypoint, not an API-only substitute. Establish an exclusive private attempt ledger before rename/send. Perform the exact scoped sequence above; verify name equality and, where returned, identify the sent `Test` by the owned account internally without printing its ID. No continuous polling or automatic mutation retry. Stop on TLS/network failure, redirect, 429/5xx, rejected name or unexpected account state. Preserve outcome evidence and private state.
  - PARTIAL (2026-10-05T16:52:24Z, parent-guarded): real entrypoint, read-only HTTP scope guard, peer/TLS verified, unchanged source hash, private 0600 logs/ledger. Executed login + two profile reads + one rename (all HTTP 200); `name --expect` FAILED as designed — server readback returned the exact 20-char/31-byte prefix `[ff0000]βℓąȼЌhąţhąȼЌ` of the requested 22-char `[ff0000]βℓąȼЌhąţhąȼЌ€я` (NFC mismatch does not explain it); sequence stopped BEFORE chat send/read. No `Test` posted, no retry, no ledger reset, no fallback rename, no color stripping. NOT claimed: full desired name applied, general 20-char/32-byte limit proven, `Test` live-verified. Censored evidence: `docs/cli-chat-live-verification.json` (classification `partial-name-mismatch-before-send`).
  - CONTINUATION (parent-guarded current-prefix run): user accepted current `[ff0000]βℓąȼЌhąţhąȼЌ`; real CLI executed exactly four ordered RPCs (auth, profile/name check, send, read) with HTTP statuses 200/200/200/200, no rename, no new account, no retry, duplicate authorizations collapsed to one send. Direct parent live result: `classification=send-attempted-unconfirmed`, `send_attempted=true`, `own_message_seen=false`, `chat_message_count=29`, `rpc_count=4`, real CLI `exit=0`; guard wrapper process exited 1 despite the real CLI exit 0. Censored evidence: `docs/cli-current-prefix-chat-verification.json`. C3 remains PARTIAL because the owned `Test` was not confirmed in readback. No further request/read/retry/send is authorized; a next read-only follow-up would need fresh authorization.
- [x] **C4 — Durable CLI guide and censored evidence.** Route: delegated documentation. Trigger: keep code, usage and proof together. Save reports in `docs/`, with exact commands, privacy notes, live result and limits. Mirror full task progress to Engram before close.
  - Documentation is current for THIS state: `docs/cli-chat-account-name.md` (reusable usage, interactive two-line grammar, batch `-e` form, transport safety, historic 20-returned-vs-22-requested limitation without inferred hard cap, current-prefix send-attempted-unconfirmed outcome, no stale decision pending) plus `docs/cli-chat-live-verification.json` (historic rename evidence) and `docs/cli-current-prefix-chat-verification.json` (safe current-prefix parent result with distinct real CLI vs guard wrapper exits; no IDs/passwords/SID/bodies/raw logs). This is NOT a claim of functional completion; C3 remains partial. Native review remains unstarted: no approval, no source review performed. Helper scope remains pending review; source was unchanged for this documentation-only update and the full suite was not rerun here (historical 806-example green remains the source-verification record).

## Planned edit surfaces

- `bin/sandbox`
- `lib/cli/sandbox.rb`
- `lib/cli/context/root.rb`
- `lib/cli/context/chat.rb`
- `lib/hackers/game.rb`
- `lib/cli/batch.rb` (new, only if needed for robust batch execution)
- `spec/api_spec.rb` (rename wire/Unicode tests only)
- `spec/cli_config_spec.rb` (new)
- `spec/cli_chat_spec.rb` (new)
- `spec/cli_batch_spec.rb` (new)
- `spec/game_minimal_auth_spec.rb` (new)
- `docs/cli-chat-account-name.md` (new guide/report)
- `docs/cli-chat-live-verification.json` (new censored evidence)
- `odd/tasks/cli-chat-account-name.md`

## Acceptance checks

- CLI commands run interactively and in bounded batch mode; no full-catalog prelude in minimal mode.
- Batch failures are structured and deterministic, not inferred from arbitrary chat text.
- Credential-bearing URLs/IDs/passwords/sessions never appear in routine logs or persisted public evidence.
- Exact requested name survives tokenization and request encoding without silent changes.
- Chat read/send works without `chat open` or a polling thread for one-shot tests; interactive polling is rate-bounded and stoppable.
- Missing metadata does not break chat rendering. Invalid/empty sessions fail safely.
- Real name/readback and one `Test` are verified against the already-created account, or failure is explicitly reported without retries.

## Test environment

```bash
source ~/.local/share/ta-hackers-toolchain/env-ruby33.sh
~/.local/bin/mise exec ruby@3.3.12 -- ruby "$GEM_HOME/bin/bundle" _2.6.9_ exec rspec --format progress
```

Tests use synthetic credentials and mocked/loopback transport. No application code or package dependency changes outside this scope; preserve `Gemfile.lock`. Known unrelated `scripts/autohack.rb` syntax failure is deferred.

## Delivery and rollback

- Existing branch: `fix/http-compatibility-diagnostics`; no new branch or worktree required and no commits authorized.
- Forecast: approximately 300–600 authored source/test/doc lines for one coherent CLI behavior unit. About 400 lines is an advisory planning heuristic, not a hard cap; do not omit tests or minify to fit it.
- Strategy: ask-on-risk for future delivery; no PR or publishing requested.
- Rollback boundary: scoped CLI/minimal-auth changes and new specs/docs, without removing previous HTTP/API fixes or private account state.
- Native review remains user-owned and pending; no consent, transaction or approval exists. Never fabricate a receipt or change the switch.

## Progress

- Plan created after source mapping and before implementation.
- Corrected an exploration overstatement: the twelve-catalog root connection prelude is still present.
- Existing sensitive user configuration `configs/mine.conf` is outside the authorized edit/read surfaces.
- C1 implemented and verified offline: minimal SID-only auth (`Game#auth_minimal`), `name`/`name --expect`, rename cache-skip on exact value, one-shot `chat read`/threadless `chat say`, bounded interactive polling with stop-on-error, chat display sanitization (ANSI/OSC/C0 stripped, Unicode/rich-text literals preserved), `Sandbox::Config.resolve_path` (named fallback + explicit absolute/relative/~/JSON paths), repeatable `-e/--execute` batch with registry pre-validation, logger-error counting, fail-fast nonzero exit and safe `--json` summary, local `$LOAD_PATH` bootstrap in `bin/sandbox`. Full mode, autocmd interactive behavior, API wire version 1229, nil auth flag, and client gzip/error fixes preserved; `configs/mine.conf` untouched.
- C2 correction transaction applied before live: TLS inheritance for ssl-less private configs with legacy on/off and plaintext refusal for the known host; pool `max_retries=0` with 10/15/10 s timeouts; static malformed-config reason (no content echo); batch error redaction (class-only for unknown exceptions, mapped errors + HTTP status preserved); batch token-contract fix; docs grammar and retry-history corrections. All five findings verified RED → GREEN; suite 806 examples, 0 failures.
- C3 live run executed once (parent-guarded, 2026-10-05T16:52:24Z): stopped as designed on the name-expect mismatch (returned 20-char/31-byte exact prefix vs requested 22 chars) before chat send/read; no `Test` posted, no retries, ledger/protected logs intact outside the repository.
- C4 documentation updated for the current partial-live state: guide with reusable usage/grammar/limits, historic rename evidence preserved, new current-prefix censored JSON evidence added. The prior decision fork is resolved historically: one `Test` under the current prefix was authorized and attempted once. C3 remains partial because the owned `Test` was not confirmed. No next read/retry/send is authorized; any future read-only follow-up requires fresh authorization.
