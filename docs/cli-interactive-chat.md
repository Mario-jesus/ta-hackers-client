# Exception-safe interactive chat ownership

The T0a lifecycle change removes a failed or stopped poller from the local room registry and closes only the room it still owns. It does **not** fix interactive terminal redraw: the installed SDK can still raise `NoMethodError` when `Readline` resolves to Reline without `refresh_line`.

## Lifecycle contract

| Event | Local outcome |
|-------|---------------|
| Request error | Stop polling, report the exception class only, and clean up ownership. |
| Unexpected output or logging error | Clean up in `ensure`; the worker reports only its class and retains the original exception for `Thread#value`/`join`. Disable automatic raw thread reports on that worker only. |
| Error reporting itself fails | Cleanup still runs; the reporting exception propagates. |
| Normal nil response or thread kill | Remove the registry entry and close the locally owned room. |
| Explicit close followed by reopen | Detach and close locally before killing the old worker; its delayed cleanup cannot delete or close the new owner's room. |
| Immediate worker completion | A queue start barrier prevents polling until its exact Thread object is registered. |

A mutex serializes registry ownership and the dataset's local `open`/`close` operations. These operations do not issue requests. Polling, output, thread kill and thread join never occur while holding that mutex. Cleanup compares the registered owner with `Thread.current`, not merely the room number. No worker restart or request retry is introduced; the default five-second interval and one-second floor are unchanged.

## Offline evidence

On Ruby 3.3.12, the corrected pre-implementation RED run had 29 examples and six behavioral failures: output-error leakage, reporting-error leakage, private request-error body output, execution before registration, kill leakage, and old cleanup deleting a reopened room. Earlier test-harness failures were corrected before this behavioral RED; they are not implementation evidence. A subsequent privacy RED had 31 examples and one failure proving automatic raw worker reporting was still enabled; the fix disables it per worker and attempts a class-only report after cleanup, retaining the original error even if reporting fails.

GREEN has 31 focused chat examples, 130 regression-focus examples and 936 full-suite examples, all passing with no reported pending examples. The eight new cases include actual fake-shell output failure, successful message rendering before kill, blocked-reader kill and reopen, immediate nil completion, controlled delayed old-reader unwinding after explicit close/reopen, and retained original worker errors despite failing class-only reporting. Existing RequestError and cadence tests remain green. Synthetic queues and bounded waits control ordering; no backend or real account is used. Old diagnostic/prefix self-tests pass 24 and 10 checks; both modified Ruby files pass syntax checks. The existing Base64 future-Ruby warning remains unchanged.

## Terminal redraw remains pending (T0b)

No adapter, entrypoint injection, installed-gem change or global backend method has been added. A fake output exception proves lifecycle cleanup, not working interactive output. PTY verification is not applicable to this isolated lifecycle unit; actual-SDK PTY proof of visible prompt restoration, partially typed input, correct cursor and unchanged submission remains mandatory for T0b. No PTY success is claimed here.

The parent read the received public legacy chat source: it likewise lacks ensured cleanup and registers after thread start. Its different readline/reline dependency lock is not runtime evidence or a reported source fix. The received project was not executed.

## T0b1 standalone callback prototype (local, not injected)

A standalone C module (`ext/cli_readline_callback/`) binds the documented public GNU Readline 8.3 callback APIs without loading `readline-ext` or touching SDK private state. One UI owner uses `CliReadlineCallback.install/read_char/emit_message/remove` (plus `session`, `buffer`, `point`, `version`): C-owned callback data (line/EOF records, cancellation pipe), Ruby objects created only under the GVL, native blocking reads released via `rb_thread_call_without_gvl` with a signal-safe unblock, and ownership/GV/GC/exactly-once-free/EOF/exception-interrupt cleanup enforced in C. Producers must not write the terminal while editing; `emit_message` clears the visible line, prints, and relies on the owner's single `redisplay`.

Build locally with `ruby scripts/build_cli_readline_callback.rb` through the project toolchain launcher; artifacts stay under ignored `.bundle/native-readline-callback/` (extconf finds `rl_callback_handler_install` in `-lreadline`; GNU 8.3 version is asserted at install). `spec/cli_readline_callback_spec.rb` covers the contract, lifecycle and a real-PTY display gate; see `odd/tasks/cli-authenticated-chat-tests.md` for observed counts. The historical 5-examples/4-failures run before any edit is a harness RED, not behavioral test-first proof for the native module: the original native product RED is unavailable because the resumed writer inherited the already-written partial C source and checked it as-is (no native code was deleted or reverted to fabricate one). All four failures were fixture/model defects — the unstable `IO::ConsoleMode#==` restore comparison and the screen model missing ECMA-48 ICH/DCH/ECH — and the native module needed no change for them. An independent verifier reproduced focused 5/0, the 124/0 focused CLI/API set, the 1001/0 full suite and the true midframe barrier (4096 of 180316 output bytes drained with the frame still owned), then found one latent screen-model defect: ECH truncated the untouched tail beyond the erased span; the real PTY stream never emits it, so the gate itself stayed valid. A dedicated pure-model regression was added, observed RED (destroyed tail, collapsed row width), and the model corrected; unknown ANSI remains fatal, and ICH/DCH/ECH clipping, unchanged width/cursor and preserved tails are now pinned. GREEN is 11/0 complete callback spec (5 PTY gate + 6 model) and the full suite reported in the feature tracker; helpers pass 24+10 offline self-tests. Prototype limitation: `emit_message` holds the GVL while its `fputs` output may block on PTY capacity — T0b2 must evaluate edit responsiveness/streaming separately; no native change or integration is authorized at prototype scope.

Not injected into the production shell. Still unproved: colored/wide-Unicode/grapheme prompts, resize, input history, post-unwind edit snapshots, and real SDK/Reline parity (T0b2 must map and prove that separately); PTY display assertions above were, and remain, the gate for any integration claim. No other file, dependency, configuration or server surface was touched.

## Review and rollback

Review the registration barrier, exact-thread ownership check and close/reopen tests first. Parent local commit and review disposition remain pending. Rollback this source unit through `lib/cli/context/chat.rb`, `spec/cli_chat_spec.rb` and this guide, with its evidence in `odd/tasks/cli-authenticated-chat-tests.md`; do not revert T1's authenticated read guard.

URI, TLS, auth, transport, message sanitization, sending and publication behavior are outside this change. T2 still owns five sequential confirmed messages and the 13-RPC ceiling; this unit performs no live requests.
