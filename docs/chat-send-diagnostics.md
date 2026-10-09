# Chat send diagnostics status

Verified result: the original message send regression is **FUNCTIONALLY RESOLVED**. The user-approved ONE complete original send executed exactly once through real, unmodified production source (canonical path unpatched, no monkeypatch) under an independently audited guard, with all five RPCs returning HTTP 200, a genuine structured echo of the own account id and exact message text inside the 212-byte send response, CLI exit 0 and `publication_confirmed` true. Offline parity and the observed-punctuation normalization stay validated (focused runner 91 examples, 0 failures; parent functional spot checks reconfirmed 91/0; an independent verifier completed every technical check). Delivery remains **PENDING**: the source units are uncommitted, native review is not invoked, the full suite stays intentionally not run for the separate SDK PTY reason, and no commit decision has been made. Historical failed attempts remain below as context; never treat HTTP 200 alone as publication proof without the structured echo.

Safe public server evidence is summarized in `docs/chat-send-server-diagnostic.json`. Historical evidence below is preserved as context; the message pre-escaping live attempt record (`original_fixed`), the round-2 bang probes, the round-3 asterisk probes and the round-4 complete original revalidation (`original_final`) are the authority for the latest live status.

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
- Native caller evidence for official 1.229 (`SendMessageButton` → `Uri.EscapeDataString(filteredMessage)` before `Uri.AbsoluteUri`/checksum) shows the chat message is pre-escaped once with the full RFC 3986 data contract. The message field therefore keeps message colons as `%3A`, encodes literal `*` as `%2A`, leaves `~` literal, and percent-encodes non-ASCII as uppercase UTF-8 — while `last_message` and every other non-message chat field keep the verified space/colon canonicalization. Offline `.NET 8` synthetic oracle reference data for six messages (formatted originals, accented letters, `!`/`?`, literal `*`, emoji; synthetic credentials; signatures included) is embedded in `spec/client_http_spec.rb` and matches exactly at the escape stage.
- Round-2 and round-3 controlled same-account backend probes showed percent-bang (`%21`) and percent-asterisk (`%2A`) message wire values rejected with an empty 5-class send response while the identical decoded texts published with literal `!`/`*` in the signed wire bytes. The final wire form therefore applies an explicit two-token backend-compatible normalization: the RFC 3986 escape stage is unchanged and still matches the oracle; only the chat message field exposes literal `!` and `*` before the checksum, with all other punctuation kept escaped (details below). Round-4 executed the complete original message successfully through the unmodified production path (`original_final` below).
- This is not a full native character-equivalence claim and does not expose credentials or raw concatenated URLs.
- Latest offline verification reported full suite `828/0`, focused API/client `66/0`, helper `24` green, direct attempt-6 mock success through the real entry point with fake transport, read-only attempt-6 refusal, and syntax/diff clean. Native review remains pending with no approval.

## What remains unknown

- The send regression through the original message is functionally resolved (round 4); the general server-side parser/validator logic behind percent-punctuation rejection is still not explicated.
- The historical send 500 for the original message (capture `original_fixed`) predates the punctuation normalization and is superseded by the round-4 successful complete revalidation; the historical attempt is retained as evidence, not as current status.
- Percent-bang and percent-asterisk rejections have controlled cause evidence at this endpoint; the server-side parser/validator behavior behind it and the native final wire forms for `!`/`*` (hex case, `Uri.AbsoluteUri` byte behavior) remain unknown.
- Native caller/server eligibility details, timestamps, and other missing premises remain unknown.
- CLI-side original-text preprocessing (existing token joins collapse double spaces to single) is an additional byte-divergence source between CLI-authored and native-authored message sources; recorded as diagnostic context, not a proven root.
- The user-granted ONE complete original room 69 live validation has now executed successfully (round 4); no further sends are needed for this bug, and any new send requires new explicit authorization.

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

Offline .NET 8 runtime evidence for the native chat builder shows the official URI canonicalization is not the same as Ruby form encoding for chat routes. With `last_message` value `2026-10-05 20:47:09.177`, the observed .NET `Uri.AbsoluteUri` form emits `2026-10-05%2020:47:09.177`; Ruby form encoding emits `2026-10-05+20%3A47%3A09.177`. For `chat_send` and `chat_display` only, this client canonicalizes before checksum/signing and sending, field by field. The message field is escaped once with the native `Uri.EscapeDataString` contract (confirmed by native caller evidence): message colons stay `%3A`, literal `*` becomes `%2A`, `~` stays literal, and non-ASCII becomes uppercase UTF-8 percent encoding; the message is never re-form-escaped. Other chat fields keep form encoding plus the observed safe subset: literal form spaces (`+`) become `%20`, and escaped colons (`%3A`) become `:`, which preserves raw timestamp colons in `last_message`. All other escaped values remain escaped, including literal plus as `%2B`, ampersand as `%26`, percent as `%25`, hash as `%23`, and Unicode UTF-8 percent encoding. Non-chat requests keep plain form encoding, including a `message` key outside chat requests.

Earlier chat-only canonicalization globally unescaped every `%3A` and left `*` raw where the native builder emits `%2A`. The divergence was byte-level in the signed wire URI only: both encodings decode back to identical message text, so no decoded message text was corrupted, and no server-side root cause is proven by this evidence. The field-specific escape removes the byte-level divergence without raw query concatenation. Offline verification for this message-field correction observed the mandated focused runner RED with 78 examples / 4 intended failures (message colon shape, native reference match, signed signature) and GREEN with 78 examples / 0 failures after the fix; the parent re-ran the exact focused command after the live attempt and observed 78 examples / 0 failures again. Full-suite disclosure: not run because the SDK PTY gate remains unresolved. Live publication proof stayed parent-owned: exactly one original-message send in the approved room with the approved configuration, recorded under `original_fixed` below. A previously authorized ASCII formatted send containing `A*BC` succeeded live, so this correction does not claim a proven server-side root cause for historical publication failures; it aligns the outgoing URI with the observed native flow.

This is a bounded offline compatibility correction, not raw query concatenation and not a claim of full .NET/Ruby character equivalence. It also does not prove server-side cause for any previous live publication failure.

## Message pre-escaping live attempt (`original_fixed`)

The user-approved single live send executed exactly once through the fixed guarded diagnostic path, with no retries and no further sends. Private capture identifier `original_fixed` is used as a bounded identifier; no capture paths, credentials, raw response bodies or URLs are published.

| Step | Result |
|------|--------|
| Auth | 200, 193 bytes |
| Profile | 200, 104 bytes |
| Chat read before send | 200, 158 bytes, 2 messages |
| `chat_send` | **500, empty, 0 bytes** |
| Chat read after send | 200, 158 bytes, 2 messages |

Observed outcome: CLI exit 1, one send attempt, `publication_confirmed` false; the post-send read shows the same message count, so no owned echo appeared. The bracketing 200 reads show healthy transport at send time, so this 5-class empty-0-byte send response is a server rejection or error whose cause is unknown. Native-flow URI parity is proven offline (focused runner 78/0, parent-confirmed), but the user-reported send 500 is NOT solved; the whole change is PARTIAL/BLOCKED. No retry, no native review, no commit and no push happened or are permitted without new explicit authorization; the next diagnostic is read-only.

## Backend-compatible observed punctuation normalization

Round-2 controlled, user-approved backend evidence (each case exactly once, no retries; network closed after this round) localized one server constraint for the signed wire bytes of the chat message:

| Probe message | Send result |
|---------------|-------------|
| `Prueba áéíóúñ` | 200, fresh own exact echo published |
| `Prueba ! ?` | 500, empty, 0 bytes |
| `Prueba !` | 500, empty, 0 bytes |
| `Prueba ?` | 200, own exact echo |
| `Prueba !` with the final diagnostic exposing literal `!` (temporary wrapper, unmodified hash chain, same parameters and decoded text) | 200, 80 bytes, fresh own exact echo published; all five RPCs 200 |

Round-3 user-approved asterisk evidence (each case once, no retries; two sends and ten RPCs total through the independent guard with full TLS, identity, session, version and room; parent verified the safe-variant receipt; thirteen offline proof checks):

| Probe message | Send result |
|---------------|-------------|
| `A*B` sent by current production with percent-asterisk wire (`A%2AB`) | 500, empty, 0 bytes, no fresh own exact echo |
| `A*B` with the final diagnostic exposing literal `*` only (`%2A`→`*`, unmodified hash formula, all other parameters identical) | 200, 75 bytes, fresh own exact echo published in the send response |
| Follow-up chat read | 0 new messages after the normal cursor, consistent with the published echo |

Binary compatibility evidence for the framework places the `.NET` UriParser quirks (compatibility bool true → quirks 3) and verifies the RFC 3986 escape stage exactly; the final official `Uri.AbsoluteUri` byte behavior for these shapes stays unknown.

Label and change: percent-escaped bang (`%21`) and percent-escaped asterisk (`%2A`) inside the chat message field were the probe-specific wire shapes correlated with the empty 5-class send response, and the literal wire forms published. The client therefore normalizes only the final wire bytes of the chat message field (`%21` → literal `!`, `%2A` → literal `*`) before the checksum, applied identically on both hashing passes, through one explicit two-token mapping with no generic unescape-all. A literal user `%2A`/`%21` string is itself percent-escaped (`%252A`/`%2521`) and stays escaped, so only escape-stage tokens are exposed; `*` is exposed as a URL component literal, never as a separator. This is a BACKEND-COMPATIBLE NORMALIZATION of URI signed bytes: the RFC 3986 `Uri.EscapeDataString` escape stage is preserved and still matches the `.NET` oracle at that stage; message colons stay `%3A`, `~` stays literal, all other punctuation stays escaped (`?` as `%3F`, `&` as `%26`, `#` as `%23`, `%` as `%25`, `+` as `%2B`), `last_message` keeps raw colons and non-chat requests keep plain form encoding. Non-message chat fields keep their pre-existing form behavior, in which Ruby form encoding already leaves a literal `*` raw. The hash algorithm and credential handling are untouched. No new configuration flags were added.

Offline verification round 2 (network closed, offline only): the mandated focused runner observed RED with 85 examples / 5 intended failures (backend bang wire form for oracle messages containing `!`, signed bang variant over an independently derived hash, repeated and accented bangs, signed two-pass identity, mixed punctuation) and GREEN with 85 examples / 0 failures after the correction. The `.NET` reference tests were restructured honestly: the RFC 3986 escape stage still matches all six oracle entries; the three oracle messages without a bang keep the exact native URI and `.NET` signature; the three messages with a bang now assert the backend-compatible variant, whose expected hash is derived in the spec from the final known URI and whose stored `.NET` signature must differ from the final signed bytes (asserted, not assumed). Full suite remains not run (SDK PTY gate unresolved).

Offline verification round 3 (offline only): the mandated focused runner observed RED with 91 examples / 6 intended failures (backend wire for the punctuated oracle entries, signed punctuated variant, the user-probed asterisk `A*B` with independently derived signature, repeated asterisks with bangs, mixed asterisk/bang/accents, injection punctuation) and GREEN with 91 examples / 0 failures after the two-token correction. Two harness-only expectation corrections in the same round pinned the pre-existing non-message/non-chat Ruby form behavior, in which a literal `*` is already raw; they were corrected before evidence capture and are not behavioral REDs. The `.NET` reference tests stay honest: the escape stage matches all six entries; the two plain entries keep the exact native URI and `.NET` signature; the four punctuated entries assert the backend-compatible variant with independently derived hashes and asserted `.NET`-signature differences. Full suite remains not run (SDK PTY gate unresolved).

Honest limits: modern .NET 8 `Uri` canonicalization does not expose literal bangs or asterisks, and the official native final canonicalization for `!`/`*` (hex case, `Uri.AbsoluteUri` byte behavior) remains unknown, so no official-runtime byte-equality claim is made. Round-3 cause evidence came from targeted probes through temporary wrappers; the round-4 complete original validation below proves the production path directly.

## Complete original revalidation (`original_final`)

The user-approved final validation executed the complete original message exactly once through real, unmodified production source — no monkeypatch, canonical path unpatched — under the independently audited guard: the read-only verifier audited the runner and guard and confirmed the real `Net::HTTP` path with no fake transport. Private capture identifier: `original_final` (bounded identifier only; no capture paths, credentials, raw bodies, raw URLs, ids or sessions are published).

| Step | Result |
|------|--------|
| Auth | 200 |
| Profile | 200 |
| Chat display before send | 200 |
| `chat_send` (complete original message) | 200, 212 bytes, structured echo inside the send response matching the own account id and the exact message text |
| Chat display after send | 200, 0 new records after the advanced cursor |

Observed outcome: CLI exit 0, `publication_confirmed` true, `canonical_unpatched` true. The exact original CLI command was used; the CLI-side existing normalization collapsed the double space to a single space before the message left the CLI, and the derived message size is 140 bytes / 136 codepoints. The echoed datetime is summarized only as a privacy-bounded string length (23 characters) — the length is the public fact, never the literal datetime value or any raw capture content.

Independent verification: the independent read-only verifier completed the technical checks — message-only `%21`/`%2A` normalization before the hash, collision and injection guards, honest `.NET` claim boundaries, and validation of the real HTTP exchange and the send-response echo. The parent's functional spot checks re-ran the focused runner with **91 examples, 0 failures**.

Boundaries: this resolves the send regression functionally for the complete original message; it does not claim full native runtime byte equality, does not declare the implementation complete, and does not close delivery. Source units remain uncommitted, native review is not invoked, the full suite remains intentionally not run for the separate SDK PTY reason, and the cached delivery strategy `ask-on-risk` still requires an explicit user decision before any commit (no chain strategy or exception selected, no automatic commit, no toggles).

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
- The round-4 success does not claim native review approval (native assessment was not invoked), a committed delivery, or a full-suite green; the SDK PTY issue remains separate from this send bug.

## Offline verification

Focused D1 command:

```bash
source ~/.local/share/ta-hackers-toolchain/env-ruby33.sh && ~/.local/bin/mise exec ruby@3.3.12 -- ruby "$GEM_HOME/bin/bundle" _2.6.9_ exec rspec spec/chat_response_spec.rb spec/cli_chat_spec.rb spec/cli_batch_spec.rb
```

Historical D1 correction evidence: focused RED produced 67 examples with 4 failures for nonnumeric chat id/room validation and duplicated echo reuse; focused GREEN produced 67 examples, 0 failures. D1 independent verification was 67 focused / 823 full-suite examples, zero failures, and 17 syntax checks. Latest post-D8 verification supersedes the full-suite count: 828 full-suite / 66 API+client focused examples, zero failures, and 24 diagnostic self-tests plus the independent attempt-6 real-entrypoint offline probe. Native assessment was unassessable because intended untracked scope is undeclared; the separate verifier ran. Native preflight remains blocked on intended-untracked selection; no transaction or approval exists.

Round-4 verification: the parent's functional spot checks re-ran the focused runner with 91 examples / 0 failures, and the independent verifier completed the full technical audit of the round-4 live validation (real transport, echo identity, normalization boundaries). No new tests and no source byte changes occurred in the documentation round; the full suite remains intentionally not run for the separate SDK PTY reason.

## Next diagnostic

Six authorized isolated waves, the message pre-escaping attempt (`original_fixed`), the round-2 bang probes, the round-3 asterisk probes and the round-4 complete original revalidation (`original_final`) are recorded above; every mutative step ran exactly once. The send regression is functionally resolved through the unmodified production path; no further sends are needed for this bug, and any new send requires new explicit authorization. The next steps are delivery steps, not diagnostics: the parent/user must select the delivery strategy (cached `ask-on-risk`; no chain strategy or exception selected) before any commit; native assessment remains pending and requires a safe scoped review isolation that never includes `configs/default.conf` or unrelated task trackers; the full suite stays intentionally not run for the separate SDK PTY reason. The actual native chat builders have been reconstructed under `/tmp/opencode/chat-native-diagnostic/`; previous scratch was missing, not the current reconstruction. This document is not permission to replay an uncertain mutation.
