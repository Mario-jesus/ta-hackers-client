# Chat send diagnostics status

Verified result: offline chat send/reporting fixes are validated, but live publication is not proven fixed. The latest six-wave server diagnostic ended with transport timeouts before the URI-canonicalization send could run; do not treat HTTP 200 or an empty send response as proof of publication.

Safe public server evidence is summarized in `docs/chat-send-server-diagnostic.json`. Historical evidence below is preserved as context; the current D5/D8 result is the authority for the latest live status.

## Current server diagnostic summary

| Area | Observed evidence |
|------|-------------------|
| Overall result | 20 attempted RPCs this turn: 17 HTTP 200 responses and 3 timed-out reads. Two diagnostic sends were attempted; neither was confirmed as published. |
| Wave 1 | Auth succeeded with HTTP 200, then profile read timed out before chat. No send occurred. |
| Wave 2 | Five RPCs all returned HTTP 200. `Test diagnostico` send was attempted, but the decoded send body was empty (`0` bytes), own echo was false, publication stayed unconfirmed, and CLI count `0` is not proof of actual zero messages. |
| Wave 3 | Read-only independent parsing saw auth/profile/chat HTTP 200 responses and safely parsed 33 chat messages from the returned window. No owned `Test` or `Test diagnostico` was found there. Earlier helper `0` chat count / `1` shape count was erroneous and is superseded by the safe parsed count/provenance. |
| Wave 4 | After the nil native flag fix, five RPCs returned HTTP 200 for isolated `Test protocolo`; the send body was empty and no own publication was confirmed. Pre-read/persistent cursor handling did not provably fix publication. |
| Wave 5 | After the chat URI `%20`/raw-colon fix, the run stopped at 3 of max 5 RPCs because initial `chat_display` timed out after auth/profile HTTP 200. `Test codificacion` was not sent. |
| Wave 6 | Retry stopped at 2 RPCs because profile timed out after auth HTTP 200. `Test codificacion` was not sent. Further waves stopped to avoid blind resends and preserve exclusive ledgers. |

Important boundaries: no rename, new account, purchases, automatic request retries, or `Test codificacion` send occurred. Public artifacts omit private paths, account ids, session ids, credentials, raw response bodies, raw URLs, and actual chat texts other than the user-approved test strings.

## Native/code evidence summary

- Native 1.229 method map evidence identifies `NetRequest_chatDisplay 0x19c8e0c` and `NetRequest_chatSend 0x19c8fb4`; parameter order matches the Ruby/player-id sender path inspected, and raw concatenation is canonicalized by `.NET Uri` before checksum.
- `.NET 8.0.20` synthetic probing showed the native-style URI uses space as `%20` and leaves timestamp colons raw, unlike Ruby form encoding (`+` and `%3A`) for the tested toolchain. The implemented code fix is chat-only and preserves literal plus `%2B`, ampersand `%26`, non-chat behavior, and hash fixtures.
- This is not a full native character-equivalence claim and does not expose credentials or raw concatenated URLs.
- Latest offline verification reported full suite `828/0`, focused API/client `66/0`, helper `24` green, direct attempt-6 mock success through the real entry point with fake transport, read-only attempt-6 refusal, and syntax/diff clean. Native review remains pending with no approval.

## What remains unknown

- Global publication/root cause is not proven fixed.
- Live send validation is blocked by timeouts, not by a completed healthy post-fix send.
- Native caller/server eligibility details, timestamps, and other missing premises remain unknown.
- The next diagnostic should happen only after healthy transport is available and should not blindly resend older or new test messages.

D1 fixes the offline reporting defects that let a chat send look successful when the response body was not trustworthy or when the sent message was never echoed back by the requested reads.

## What changed

| Area | Behavior |
|------|----------|
| Chat response validation | `chat read` and `chat say` validate the raw chat body before `Serializer::Chat` parses it. Valid empty chat still returns `[]`. Recognized `Exception` envelopes raise safe mapped request errors. Malformed nonempty records fail with `Chat response malformed` instead of being swallowed as successful empty chat. |
| Send confirmation | A successful write RPC means only “attempted”. Publication is confirmed only when a not-previously-observed owned message echo matches the own account id, room and exact outgoing text. Echo identity is the conservative tuple `[sender id, datetime, room, exact text]` because the currently implemented seven-field chat parser does not expose a stable message id; the official native chat schema has not been independently reconstructed. One observed echo confirms at most one pending send globally, including repeated sends/responses/reads. |
| Batch final status | Batch mode still runs subsequent user-requested commands such as `chat read` after `chat say`. After all requested commands finish, the final result is false/nonzero if any outgoing send remains unconfirmed. |
| Public JSON | `chat_publication_status` is `confirmed`, `unconfirmed`, or `null`. No account id, session, credential, URL or raw arbitrary server body is printed. |

## D6 native flag evidence

Offline APK string evidence for official 1.229 shows chat builders using valueless query-style flags for chat routes: decoded literal 2682 contains `?chat_display&room=` and literal 2683 contains `?chat_send&room=`. Absolute offsets 162133 and 162152 identify the literals in the decoded evidence. This supports using bare `chat_display` and `chat_send` flags (no `=`) while preserving this client’s existing room, last-message, message, player id, app-version, session-id, hashing and encoding pipeline.

Literal decoding alone did not prove native callsites or parameter order. Subsequent D7 disassembly did verify the chatDisplay/chatSend builders and their parameter order (see the current summary). D6 was tested live in isolated attempt 4 under explicit user authorization: all five RPCs returned HTTP 200, but publication remained unconfirmed. The bare-flag correction was not sufficient to demonstrate a fix.

## D8 native URI alignment and attempt 5

Offline .NET 8 runtime evidence for the native chat builder shows the official URI canonicalization is not the same as Ruby form encoding for chat routes. With `last_message` value `2026-10-05 20:47:09.177`, the observed .NET `Uri.AbsoluteUri` form emits `2026-10-05%2020:47:09.177`; Ruby form encoding emits `2026-10-05+20%3A47%3A09.177`. For `chat_send` and `chat_display` only, this client now form-encodes safely first and then applies the observed safe subset before checksum/signing and sending: literal form spaces (`+`) become `%20`, and escaped colons (`%3A`) become `:`. Other escaped values remain escaped, including literal plus as `%2B`, ampersand as `%26`, percent as `%25`, and Unicode UTF-8 percent encoding.

This is a bounded offline compatibility correction, not raw query concatenation and not a claim of full .NET/Ruby character equivalence. It also does not prove server-side cause for any previous live publication failure.

Diagnostic attempt 5 used one fixed send-mode path with message `Test codificacion`. It keeps the same guarded five-RPC sequence as send attempts 1/2/4, refuses read-only mode, writes an isolated exclusive ledger/capture set, and privately captures both chat read responses in addition to the send response. Public output includes only safe parsed counts, chronology phase (`before_send`/`after_send`), and safe own-message match booleans; it does not publish account id, session id, credentials, raw response bodies, or full URLs. Historical parent command for the explicitly authorized attempt 5 (do not replay its existing ledger):

```bash
source ~/.local/share/ta-hackers-toolchain/env-ruby33.sh && ~/.local/bin/mise exec ruby@3.3.12 -- ruby "$GEM_HOME/bin/bundle" _2.6.9_ exec ruby scripts/cli_chat_diagnostic_check.rb --live --attempt=5
```

The parent executed attempt 5 before final evidence documentation: the initial chat read timed out before any send. Isolated attempt 6 then timed out on the profile read, also before any send. No `Test codificacion` request was sent. These transport failures blocked live validation of the URI correction; preserve both ledgers and do not blindly repeat them.

## What this does not prove

- It does not prove why the prior live `Test` did not appear in the official client.
- Native chat builder parameters and their order are verified for the inspected methods; complete UI/bootstrap dependencies and server acceptance/eligibility rules remain unproven.
- It does not add implicit profile, pre-read, retry or publication-probing requests.
- If two actual server echoes for identical text share the same sender id, datetime and room, they are conservatively ambiguous and count as one observed echo; distinct datetimes can confirm distinct identical sends.
- It does not authorize any new live send/read/authentication.

## Offline verification

Focused D1 command:

```bash
source ~/.local/share/ta-hackers-toolchain/env-ruby33.sh && ~/.local/bin/mise exec ruby@3.3.12 -- ruby "$GEM_HOME/bin/bundle" _2.6.9_ exec rspec spec/chat_response_spec.rb spec/cli_chat_spec.rb spec/cli_batch_spec.rb
```

Historical D1 correction evidence: focused RED produced 67 examples with 4 failures for nonnumeric chat id/room validation and duplicated echo reuse; focused GREEN produced 67 examples, 0 failures. D1 independent verification was 67 focused / 823 full-suite examples, zero failures, and 17 syntax checks. Latest post-D8 verification supersedes the full-suite count: 828 full-suite / 66 API+client focused examples, zero failures, and 24 diagnostic self-tests plus the independent attempt-6 real-entrypoint offline probe. Native assessment was unassessable because intended untracked scope is undeclared; the separate verifier ran. Native preflight remains blocked on intended-untracked selection; no transaction or approval exists.

## Next diagnostic

Six authorized isolated waves are now recorded above. Further waves were paused after repeated read timeouts; stabilize transport before any new publication test. Investigate account/server eligibility or bootstrap requirements without claiming a requirement not evidenced by source or responses. The actual native chat builders have been reconstructed under `/tmp/opencode/chat-native-diagnostic/`; previous scratch was missing, not the current reconstruction. Any future attempt must use a fresh exclusive ledger, a fixed request budget, TLS peer verification and no automatic retries; this document is not permission to replay an uncertain mutation.
