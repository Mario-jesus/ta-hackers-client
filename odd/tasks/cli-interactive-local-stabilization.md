# Local interactive CLI stabilization — offline functional verification

Topic mirror: `odd/cli-interactive-local-stabilization/tasks` (Engram, project `ta-hackers`).
Repo: `ta-hackers` · branch `fix/cli-chat-working` · baseline HEAD `ed482d7`.
Status: T1/T2/T3 implemented AND checked (focused runs + acceptance pair + independent
verifier, all functional runtime checks green); commit closure PENDING parent.
Native RAR: UNKNOWN — provider-configured assessment PENDING parent; this document is NOT
a RAR receipt, and an independent worker's word "receipt" creates NO native approval.
Full suite + CI deferred (user); live backend NOT run.

## Objective and scope

Verify offline and locally that the two focused CLI spec files pass with the real GNU
Readline 8.3 callback artifact: real entrypoint flows, full backpressure parity, no skips
or weakened checks. Out of scope: Actions/CI run, full suite, live backend, unacked product edits.

## Artifact and runner (exact, env-var, no absolute user paths)

- Artifact: `.bundle/native-readline-callback/cli_readline_callback.so` — GNU Readline 8.3
  (`CliReadlineCallback.version == '8.3'` green), built from the isolated Ruby 3.3.12
  toolchain; build evidence repo-relative in `.bundle/native-readline-callback/mkmf.log`.
- Exact runner:

```bash
cd "$(git rev-parse --show-toplevel)"
source "${TA_HACKERS_TOOLCHAIN_DIR:-$HOME/.local/share/ta-hackers-toolchain}/env-ruby33.sh"
timeout -k 3 104 "$MISE" exec ruby@3.3.12 -- \
  ruby "$GEM_HOME/bin/bundle" _2.6.9_ exec rspec \
  spec/cli_interactive_shell_spec.rb spec/cli_readline_callback_spec.rb \
  --no-color -f documentation --order defined
```

- Vocabulary correction: the tests do NOT normalize any source. Source-mutating
  normalization: NONE applicable. Order before functional runs: non-mutating `ruby -c`
  syntax + `git diff --check` on the allowed paths only, THEN the functional runs.

## Stable constraints

- Edit surfaces (allowed, and actually used): `spec/cli_interactive_shell_spec.rb`;
  `spec/support/callback_screen.rb` (T2 needed NO edit — CallbackScreen UNMODIFIED); this
  tracker file. Product code (`lib/`) untouched; product fixes require STOP + parent report.
- Offline only: no network, backend, accounts, config reads, Git writes; no new PTY
  captures outside the approved ignored `.bundle/`; tests write only their own artifacts.
- No skips, no narrowed/silenced assertions, no fabricated PASS; bounded runs, kill on
  hang, no rerun loops; unrelated dirty files and existing ODD trackers preserved.

## Tasks (one coherent work unit in flight; commit PENDING parent)

Planned commit message: `fix(test): restore interactive CLI acceptance proofs`.
Forecast: ~148 source lines changed (`git diff --numstat`: +99/−49 in
`spec/cli_interactive_shell_spec.rb`) + this doc (≈90 lines) — well under the 400 budget.

### T1 — shared PTY manifest helper + real entrypoint checks ✔ checked
- Root (once): `record_pty_manifest` and `wait_child_bounded` were sibling-scoped inside
  the "real PTY proof" group while the `bin/sandbox entrypoint selection` group calls both
  (`spec/cli_interactive_shell_spec.rb:598` and `:612`) — NoMethodError crashed both
  entrypoint examples before any real flow.
- Fix: single definitions hoisted to the top-level `RSpec.describe` (no globals, no
  renaming, `terminate_child_bounded` stays with its only caller).
- Evidence: focused 3/0 — real entrypoint TTY run exits 0 on EOF (probe adapter+native
  true, zero backend calls); artifact-unavailable works fail-closed with the typed
  `UnavailableError` message; batch/nonTTY stays green.

### T2 — streaming open-row text semantics ✔ checked
- Root (once): expectations asserted the RAW trailing space against `lines`, whose contract
  is the normalized row (`spec/support/callback_screen.rb:138` rstrip).
- Fix (parent-corrected): normalize the expectations (`'/ '` → `'/'`) and prove the space
  is a consumed cell via the existing cursor API (`[row, column] == [0, 2]`, glyph
  deferred). CallbackScreen UNMODIFIED — byte-split and empty-read strict fatal paths
  unchanged; cell buffer and display accessor are both legitimately retained.
- Evidence: focused 8/0.

### T3 — backpressure parity marker observation + accepted SDK echo correction ✔ checked
- Root (once): the transient `frame-start` row could never survive 16 KiB master drains
  into the 12-row bounded screen (row drop), so the mid-frame marker await was
  unsatisfiable at that chunk size.
- Fix: deterministic `MARKER_PHASE_CHUNK = 128` read bound on BOTH drains
  (`drain_stdout`, `await_screen`) until `@frame_marker_latched`; latch after capture; bulk
  reads resume only then. Causality kept verbatim: key queued mid-frame before any
  full-frame drain; drained-bytes inequality, payload formula, deferred-key checks,
  wrapped rows, exact cursor, owner-only frames, submission and the causal no-read window
  ALL preserved.
- First run 1/1 STOP exposed the one legacy expectation that the SDK can never satisfy:
  the dispatch echo is the first token DOWNCASED — verbatim, read directly (external gem,
  not CodeGraph-indexed): `.bundle/native-readline/ruby/3.3.0/gems/sandbox-ruby-0.1/lib/`
  `sandbox/shell.rb:185` `tokens.first&.downcase!` (inside `split_tokens`), consumed at
  `.../lib/sandbox/context.rb:102` and `:125`. The submitted line is a single token, so
  echo == its full downcase. Parent acked; single expectation corrected; the RAW mixed-case
  read-record assertion (`submitted_record[1] == submitted_text`) and all 73-char
  row/cursor/window asserts unchanged.
- Evidence: post-ack acceptance pair 70/0.

## Acceptance (observed)

- RED 70/5 → focused T1 3/0, T2 8/0, T3 1/1 → parent-typed ack → exact pair **70/0 (~6 s),
  zero skips** — all invariants CONFIRMED in runtime by the independent verifier.
- Coverage proved by running assertions: editing, EOF (incl. real entrypoint TTY EOF),
  SIGINT cancel, winsize resize, chat-queue routing, completion, backpressure framing.
- Commit: PENDING parent — coherent test-harness work unit on the existing feature branch
  under authorized ODD; no push (user not requested this round).
