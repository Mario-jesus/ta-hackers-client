# Task: Chat poll bounded transient-network read recovery

- **Local unit closed:** `7faa6363d7b3df3f6155fb0178a7d4dd7199cbfe` (`feat(chat): recover bounded transient read polling failures`), exactly the four approved paths. Final parent acceptance before commit: **135 examples, 0 failures (18.71 s)**; no mutating hooks ran. The approved size exception covered 651 insertions and 14 deletions.
- Delivery remains local: no push, no native approval. Live backend validation, Actions and the full suite remain unrun; private configuration and unrelated changes were excluded. Pending-commit descriptions below are preserved pre-closure snapshots and are superseded by this record.

- **Current functional status:** writer acceptance **135/0 (18.65 s)** and independent acceptance **135/0 (18.63 s)**, with no skips. T5 reproduced the empty-prompt failure deterministically and carries the genuine post-banner bytes into the prompt observation; production startup and every real-TTY assertion remain unchanged.
- The earlier PARTIAL closure entries below are historical checkpoints. Final parent verification and the approved four-file local commit remain pending; the size exception does not authorize a push or create native review approval.

## T5 — preserve entrypoint output across observation boundaries

- Route: delegated; preparation for a non-trivial change to `spec/cli_interactive_shell_spec.rb`. No production changes are planned.
- Evidence: consecutive `await_output` calls reset their buffers. A read containing both the banner and prompt satisfies the first call, which discards bytes needed by the second; this explains the observed empty prompt collection, subject to deterministic reproduction.
- Test-first: use a real pipe containing a single banner-plus-prompt burst to reproduce the actual helper failure, then carry genuine unconsumed output into the next observation. Preserve the real TTY, EOF, fail-closed and prompt assertions; no fabricated prompt, timeout increase or sleeps.
- Checks: one targeted RED/GREEN sequence, one combined acceptance and independent verification. The existing four-file local size exception applies; no push or native approval is authorized.

- **Latest closure status: PARTIAL, uncommitted.** Final parent acceptance: **134 examples, 1 failure (28.58 s)**. The marker/deferred-key regression passed, but the real entrypoint TTY example failed with `entrypoint prompt not observed; collected=""` (`spec/cli_interactive_shell_spec.rb:611`, example `:664`). Cause not established; no automatic rerun.
- The shell stopped before staging or committing. No push occurred. Earlier 134/0 runs below remain valid historical observations, not final combined acceptance; the approved size exception does not waive this functional failure.
- **T5 writer-observed arc (executed, test-first, single runs only).** RED — focused `merged in one chunk` row:
  **1 example, 1 failure, 10.02 s**, the ACTUAL helper raising `entrypoint prompt not observed; collected=""`
  (the exact combined-run signature; frames helper → wrapper → row; input: one real `IO.pipe` prewritten
  banner+prompt burst, writer OPEN so exhaustion reads are genuine EAGAIN, never EOFError);
  `/tmp/opencode/entrypoint-boundary-red-1791569561.log`. GREEN patch: `await_output` gained an optional
  `initial:` buffer and the shared `await_entrypoint_startup` wrapper carries the ENTIRE unconsumed `post_match`
  tail of the first banner match; regexes, messages, deadlines and every real-PTY assertion byte-unchanged (no
  sleeps, no skips, no bypass). GREEN group: **4 examples, 0 failures, 0.63844 s**
  (`/tmp/opencode/entrypoint-boundary-green-1791569602.log`); `ruby -c` Syntax OK, scoped `git diff --check` clean.
- T5 combined acceptance (single run, ≤104 s cap): **135 examples, 0 failures, 18.65 s, exit 0** —
  chat + batch + `chat_response` + interactive = prior 134 + the 1 T5 row
  (`/tmp/opencode/entrypoint-combined-t5-1791569641.log`). No `split across reads` row was added: with
  prewritten bytes a real pipe coalesces writes, so a prewritten 'split' input cannot stay split at read level;
  the untouched real-PTY rows exercise both arrival shapes naturally.
- T5 scope delta (this turn): `spec/cli_interactive_shell_spec.rb` ≈ +48/−2 (shared wrapper + deterministic row +
  `initial:` kwarg; scoped numstat vs HEAD incl. the earlier T4 state: +152/−11) plus this doc only; NO production
  byte changes; T4 marker/recovery rows and `lib/cli/context/chat.rb` untouched. `exception-ok` unit forecast
  (accepted 4-file scope): 563 accepted → ≈650 changed lines with this doc growth — disclosed, no compression.
- T5 closure: PARTIAL, uncommitted, parent owns Git (no stage/commit/push by the worker). Remaining: the parent's
  post-commit spot check and a fresh independent verification. Claim scoping: the deterministic merged-chunk input
  reproduces the observation-boundary loss through the real helper; this records deterministic causality of the
  observation surface, NOT a universal 'race impossible' statement.

## T4 — complete the interactive prerequisite without weakening runtime checks

- Route: delegated; source-reading preparation and a non-trivial PTY harness change. Allowed extension: `spec/cli_interactive_shell_spec.rb` only; production recovery code remains unchanged.
- Evidence: the latest 133/1 failure missed `frame-start`; `await_any_record` drains output before consuming ready events, and `drain_stdout` loops until EAGAIN even with 128-byte chunks. This can scroll past the marker before the screen predicate runs.
- Test-first: add a deterministic both-streams-ready burst regression, observe RED, then bound pre-marker draining and prioritize ready event records. Preserve every real-PTY backpressure, deferred-key, raw-input and cursor assertion.
- Checks: one targeted RED/GREEN sequence, one combined acceptance, then independent verification. Historical failures remain recorded; no sleep-based fix or rerun-until-green.
- Delivery decision (user authorization, recorded this session): `exception-ok` — 'Una entrega con excepción'. The
  feature is accepted at **563 changed lines** as ONE exact 4-file coherent local unit, with NO native review and
  NO push; the size exception is documented explicitly in this doc's commit section — accepted by explicit scope,
  never by cosmetic compression or omitted tests. Commit identity remains pending the parent.

### Observed T4 arc (updated after the parent-authorized scoped correction)

- RED (deterministic, captured once, no invented RED): 1 example, 1 failure, 2.01 s —
  `frame-start row not observed` raised by the ACTUAL `await_screen` through the ACTUAL helper chain
  `facade_intent → await_any_record → drain_stdout` on two real IO pipes (record JSON + ~1.3 K frame burst
  prewritten, both fds verified readable by `IO.select`; writers kept open so exhaustion reads are real EAGAIN).
  Log: `/tmp/opencode/pty-observer-red-record-priority-t4.log`.
- First GREEN attempt (global record-first patch): 2 examples, 1 failure, 0.18112 s — the new regression was green;
  the existing 'defers a key' example failed with an UNTRACKED shape `expect([screen.row, screen.column]).to
  eq([10, 5])` got `[10, 6]` (pre-frame cursor). STOPPED per rule; log:
  `/tmp/opencode/pty-observer-green-record-priority-t4.log`.
- Root proven READ-ONLY from source order (no scheduler blame): read records reach fd4 via the ASYNC reporter
  thread (`spec/cli_interactive_shell_spec.rb:1018-1022`) after the owner thread pushes them (:820); the cursor
  redisplay of that key crosses the master AFTER `read_char` returns — so global record-first let `facade_settled`
  return before the point-25 cursor CSI drained; the observed cursor was the stale point-26 redisplay. Frame
  intents differ: owner-DIRECT synchronous syswrite BEFORE the C emit (:836-839) — correct to prioritize.
- Scoped correction (parent-authorized; this doc's sibling spec only, no product changes):
  `await_any_record(events, output, screen, record_first: false)` — default = legacy drain-before-ready-record
  with NO global drain limit (normal `facade_settled` semantics restored); ONLY `facade_intent` passes
  `record_first: true` (record-first priority + at most ONE bounded `MARKER_PHASE_CHUNK` read per readiness
  round pre-latch; bulk after the latch). The exact pre-frame `expect([screen.row, screen.column]).to eq([10, 5])`
  is preceded by a bounded `await_screen` cursor predicate observing the DRAINED real terminal bytes until the
  point-25 cursor shows — no sleeps, no screen modifications, no new flags or global state, no assertion weakened.
  The historical RED above remains the failure evidence; no new RED was invented.
- Focused GREEN (single foreground run): 2 examples, 0 failures, 0.399 s —
  `/tmp/opencode/pty-observer-scoped-green-t4-01.log`.
- Combined 4-path acceptance (single run, ≤104 s cap): **134 examples, 0 failures, 18.66 s, exit 0** —
  `spec/cli_chat_spec.rb` + `spec/cli_batch_spec.rb` + `spec/chat_response_spec.rb` + `spec/cli_interactive_shell_spec.rb`,
  count = prior 133 + 1 new regression (`/tmp/opencode/pty-observer-scoped-combined-t4-01.log`). All backpressure,
  deferred-key, raw-mixed-case, mid/post-frame wrapped-row, exact-cursor and no-read-window invariants preserved
  byte-identical; the intermittent row is closed against the DETERMINISTIC regression plus the scoped pump shape.
- Closure: PARTIAL, uncommitted; delivery RESOLVED — user chose `exception-ok`, accepting the **563 changed lines**
  recorded at the decision (see the commit section). Independent fresh verification is already green pre-commit;
  commit identity still pending the parent (current state: docs-only pre-commit preparation).

- CURRENT LEAD — latest combined results (supersedes the historical rows below): writer **134 examples, 0 failures,
  18.66 s** and fresh independent verifier **134 examples, 0 failures, 18.5 s, no skips/pending** on the same
  4-path rspec bundle, real GNU Readline 8.3, single stable command and order; every assertion intact. Deferred by
  user instruction: full-suite/backend/LIVE runs remain unexecuted (critical source paths reasoned reads-only;
  no auth/resend; permanent errors stop; max 3 additional attempts — per the approved policy below).
- Current closure: PARTIAL, UNCOMMITTED and ready for the parent's local commit under the user's `exception-ok`
  choice (563 changed lines accepted at the decision; NO native review — unsupported and already stopped, no
  retry/PASS/toggle — and NO push; an ordinary branch commit is NOT remote approval and grants no receipt). The
  deterministic root is proven from source ordering (read record crosses fd4 via the async reporter before that
  round's redisplay) — this documents deterministic causality, NOT a universal race-impossible claim.
- Historical intermediate records, kept as-then (legitimate observations of their time, superseded by the scoped
  correction above, never final blockers): parent scoped trio **88/0 (15.26 s)** at the 43-row stage; combined
  **133/1** and focused **2/1** pre-fix interactive failures — unexplained then, root-caused later (record-vs-
  redisplay ordering); the pre-fix **131/2** and isolated **45/1** rows below also stand as history.

- Status: executed (test-first RED→GREEN→regression, then scoped correction rows appended); source UNCOMMITTED — parent owns Git; working-tree only, not approved.
- Branch/HEAD: `fix/cli-chat-working` @ `b28d2f4` (dirty-protection, excluded from commit: `configs/default.conf`,
  `odd/tasks/client-robustness-refactor.md`, `odd/tasks/fork-backup.md` — untouched by this task)
- Baseline proof (pre-change): rspec chat/batch/response trio = 77 examples, 0 failures, 3.09 s.
- Native review: unsupported (prior attempt compiled, `retry_safe=false`, code 1) — no native PASS/receipt/mode change; stop on failure.
- Delivery strategy: `exception-ok` (user-selected 'Una entrega con excepción') — supersedes the historical
  `ask-on-risk` advisory. Parent actual count AT the decision (working tree @ `b28d2f4`): **402 insertions / 10
  deletions** across `lib/cli/context/chat.rb` + `spec/cli_chat_spec.rb` + `spec/cli_interactive_shell_spec.rb`,
  plus **151 new doc lines = 563 changed lines accepted exactly**. Doc-only updates after the decision (stale-fact
  corrections + this decision record + the exact 4-path plan) may grow this doc modestly under the exception
  scope — disclosed, not cosmetic compression. (Historical forecast, superseded: ~200–350 authored lines.)
- All below is user-resolved; implementation MUST NOT re-ask policy questions.

## User-resolved behavior

Retriable = transient NETWORK READ failures only, during the open-room poll loop, preserving the room entry and the
`last_message` cursor. Stop (existing single class-only error + teardown) for authentication/session/permanent errors.
Never resend pending chat messages, never re-authenticate, never reset the cursor or recreate the room.
Session-expiry detection is NOT retryable here: no re-login path is implemented in this task.

## Evidence map (verified this session, path:line)

- Poll loop + failure exit: `lib/cli/context/chat.rb:109-127` (rescue `Hackers::RequestError` → class-only log + `break`;
  ownership `ensure` 129-137; registry/lock contract 5-8; interval floor 13-14, 38-47).
- Transport wrap origin of retryable types: `lib/hackers/client.rb:97-99` (`RequestError(e.class.to_s, e.message)`,
  `http_status` nil); bounded evidence for non-200 at 240-249, 263-269, 284-295; `MAX_RETRIES=0` 30-39.
- Must-STOP shapes: type `'Exception'`/`'HTTP'` (client.rb:244-248) and dataset `'Chat response malformed'`
  (`lib/hackers/dataset/chat.rb:83,92`); EXCEPTIONS map has NO session entry (`exceptions.rb:35-39`) — allowlist safe.
- Read path: `lib/hackers/dataset/chat.rb:35-44` → `api.read_chat` (api.rb:482-492); no-auth/spy surface:
  `Game#auth` (game.rb:95), `Game#auth_minimal` (81), `Chat#write` (dataset 46), `API#write_chat` (496).
  Ruby 3.3.12: `Net::*Timeout` < `Timeout::Error` < `RuntimeError`; `EOFError` < `IOError`; `SocketError` < StandardError.

## Retry policy (approved, exact)

- Allowlist, strict `RequestError#type` equality + guard `e.http_status.nil?`: `Net::OpenTimeout`, `Net::ReadTimeout`,
  `Net::WriteTimeout`, `Errno::ECONNRESET`, `Errno::ECONNREFUSED`, `Errno::EHOSTUNREACH`, `Errno::ENETUNREACH`,
  `Errno::ETIMEDOUT`, `EOFError`, `SocketError`.
- Excluded: `'HTTP'` (5xx — no server-error retries), `'Exception'`/game envelopes (session/auth/permanent),
  `'Chat response malformed'`, `OpenSSL::SSL::SSLError` (TLS ambiguity → stop), `IO::TimeoutError` (unreachable here).
- Bounds: max **3 additional** attempts per episode (constant, no env/flags); wait = existing `chat_poll_interval`
  (floor 1; no exponential); retry only in the `chat_read` polling loop; counter resets to 0 only after a valid
  successful read; close during a retry wait kills the worker normally (sleep outside the mutex; kill path unchanged).
- Progress: one bounded log per retry `Chat read retry (n/3) (#{e.class})`; exhaustion terminal
  `Chat read failed after 3 retries (#{e.class})`; permanent/auth keeps `Chat read (#{e.class})`.
  Class only — never bodies. Batch summary/gates unchanged (no fake success, sends untouched).

## Source handling (allowed files only)

- `lib/cli/context/chat.rb`: modify ONLY the `chat_read` rescue block: classify via the frozen allowlist constant;
  retriable attempt with budget left → bounded progress log, `sleep(chat_poll_interval)`, `next`; else existing break.
  Add frozen constants near 13-14. Preserve `ensure` 129-137, open wrapper 186-199, nil-read break 121, cursor
  behavior 102-110. No dataset/client/batch edits; concrete boundary → STOP and document before extending scope.
- `spec/cli_chat_spec.rb`: Queue-gated, join-bounded rows (no new env, no counter fake, counts/queues/output only).
  Existing 77 rows untouched.

## Task steps (allowed plan; correction rows were appended afterward)

1. RED: add new poller rows → focused run of `spec/cli_chat_spec.rb` → recovery rows fail, existing 77 stay green.
2. GREEN: implement allowlist + bounded retry in `lib/cli/context/chat.rb` → recovery rows green, existing 77 intact.
3. Regression: one 4-path combined run → 0 failures (retry rows + 77 + batch + interactive), far under 120 s.
4. Scoped correction: test/doc only — append regression rows against the ALREADY-implemented behavior (no invented RED),
   `ruby -c` + `git diff --check` on the exact three candidate paths, then one combined acceptance run (≤ 104 s).

## Planned spec rows and coverage statuses (filled by writer)

(i) transient-then-success — R1 (retry line, room open, cursor `''→''→'1000'`, newest-first render noted);
(ii) exhaustion — R2 (exactly 4 read calls, one terminal line, ownership torn down);
(iii) stop guards — 4 rows (Exception / HTTP+500 / malformed / TLS): exactly 1 read call, immediate break;
(iv) counter reset — R3 (raise→empty success→raise re-enters full budget: 6 calls, 4 retry lines);
(v) no side effects — R1 method-level guards + dedicated row: actual retry→success path, transport calls 2+ with
`chat_display`-only keys, never-throws spies on the real `Game#auth`/`Game#auth_minimal`/`Chat#write`/`API#write_chat`;
(vi)+(vii) close-during-retry (kill interrupts, teardown, no crash) and room-switch isolation (sibling row).
Full mapping — one table row: all ten allowlisted types retryable via the pure production helper; `'HTTP' http_status: 500`,
`'Exception'`, `'OpenSSL::SSL::SSLError'`, `'Chat response malformed'` terminal; runtime keeps 4 representative
network exceptions. No broad mocks, no `.as_null_object`.
Determinism: app_settings stub seam (interval 1), `Queue` gates, `join` guards; sleeps are source-owned seconds only.

## Work-unit commit (single coherent local unit) — READY, parent-executed

`git add lib/cli/context/chat.rb spec/cli_chat_spec.rb spec/cli_interactive_shell_spec.rb odd/tasks/chat-poll-recovery.md`
— EXACTLY those four paths ONLY (source + recovery spec + interactive marker regression/patch + this doc); never
stage `configs/default.conf`, `odd/tasks/client-robustness-refactor.md`, `odd/tasks/fork-backup.md`.
Message: `feat(chat): recover bounded transient read polling failures` (conventional commit describing the
outcome; tests+doc+source in one unit). Delivery: `exception-ok` LOCAL commit — NO native review (unsupported,
already stopped; no retry/PASS/toggle), NO push; an ordinary branch commit is not remote approval. Rollback =
revert exactly those four paths. NOT executed by this writer — commit identity still pending the parent.

## Observed evidence (writer execution, this session)

- RED: 41 examples, 4 intended failures (recover-cursor, exhaust-4, reset-empty, close-interrupt); stop-guards +
  sibling-isolation green under old code; legacy 32 green. GREEN after implementation: 41 examples, 0 failures, 11.13 s.
- Latest accepted proof (independent verifier on the actual repo, same command order): combined 4-path = 131 examples,
  0 failures, 17.61 s — the current accepted baseline this doc records.
- Writer's historical combined 131/2 (both `cli_interactive_shell_spec` PTY rows) and isolated 45/1 are honestly
  UNREPRODUCED — cause unknown, not replaced with PASS; the "headless causes PTY failures" attribution is INVALIDATED
  by the independent headless 131/0; an unmodified-source re-run in a throwaway copy was an invalid baseline artifact
  (missing matching native artifact/toolchain root) — recorded only as an invalid experiment, no locator needed.
- Scope correction (this turn, test/doc only): planned row (v) explicit — dedicated no-auth/no-resend row (actual
  retry→success, calls 2+, `chat_display`-only keys, never-throws spies on the four real methods), R1 augmented with
  those method-level guards, one table row enforcing all ten allowlisted types retryable + status-bearing HTTP terminal;
  all pass current production (no invented RED).
- Post-correction acceptance (writer, same command order, single run): 133 examples, 1 failure — 43/43 chat rows green;
  sole failure again the historically unreproduced PTY defers-a-queued-key row; stopped per rule, no isolated reruns,
  no environment attribution claimed.
- Surface delta: `lib/cli/context/chat.rb` +50/-3 unchanged by the correction scope (no source byte changes);
  `spec/cli_chat_spec.rb` total +237 (legacy 32 intact + 9 recovery rows + 2 correction rows); doc within bound.

## Verification & independence

Pre-commit independence (DONE): the fresh independent verifier ran the same 4-path command on a fresh shell — **134
examples, 0 failures, 18.5 s, no skips** — before any commit. Remaining: the parent's post-commit final spot check
(fresh shell, exact counts, the untouched legacy-77 baseline), reporting `N/A` for runtime scenario or the observed
command result.
Offline simulations only; no live network probes; no config/account reads beyond existing spec scaffolding.
