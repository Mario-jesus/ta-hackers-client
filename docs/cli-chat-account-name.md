# Priority CLI: chat read/send and account name (C1)

Working offline capabilities added to the existing `bin/sandbox`: minimal
one-request connect, threadless one-shot chat read/send, own-name read,
exact-Unicode rename with skip-if-exact, and a deterministic fail-fast batch
mode with a safe JSON summary.

**Live status:** two parent-guarded live stages are now recorded (C3 remains partial). First, the exact 22-character rename request returned only the current 20-character prefix and stopped before chat. Later, the user accepted the current `[ff0000]βℓąȼЌhąţhąȼЌ` prefix and authorized exactly one `Test` send to World 999 without another rename. That second real CLI run attempted the send and exited 0, but the readback did **not** confirm the owned message (`own_message_seen: false`), so live chat verification remains unconfirmed. See *Live verification* below, `docs/cli-chat-live-verification.json` for the historic rename evidence, and `docs/cli-current-prefix-chat-verification.json` for the current-prefix send attempt.

## Quick path

1. Load the runtime (from the repository root):

   ```bash
   source ~/.local/share/ta-hackers-toolchain/env-ruby33.sh
   RT() { ~/.local/bin/mise exec ruby@3.3.12 -- ruby "$GEM_HOME/bin/bundle" _2.6.9_ exec "$@"; }
   ```

2. Interactive minimal session (no catalog prelude, one auth request):

   ```bash
   RT ruby bin/sandbox -m -c <path-to-private-config>
   ```

3. One-shot batch sequence (repeatable `-e`, exit status 0 only when every
   command succeeded):

   ```bash
   RT ruby bin/sandbox -m -c <path-to-private-config> \
     -e 'connect' \
     -e 'name' \
     -e "rename '[ff0000]βℓąȼЌhąţhąȼЌ€я'" \
     -e "name --expect '[ff0000]βℓąȼЌhąţhąȼЌ€я'" \
     -e 'chat say 999 Test' \
     -e 'chat read 999' \
     --json
   ```

4. Batch mode exits before the interactive loop; with `--json`, the printed
   **last line only** is the structured summary. Lines printed before the
   summary are human-readable command output (a handwritten parser is not
   supported and not needed — parse the process exit status first, then only
   the final line).

## Details

| Topic | Decision |
|-------|----------|
| Minimal connect | `bin/sandbox -m` sets minimal mode; `connect` then performs exactly one auth request and extracts only the session id (`Game#auth_minimal`). The full twelve-catalog prelude remains the default without `-m`. |
| One-shot chat | `chat read <room>` reads once; `chat say <room> <text>` sends once. Both open the room locally, issue exactly one RPC, and close it when they opened it — existing poll rooms are never closed. No polling threads are started. |
| Interactive chat | `chat open <room>` keeps its poll thread with a positive bounded interval: server setting when valid, default **5 s** when unset/invalid, floored at **1 s**. A request error stops the thread and cleans up instead of looping forever. **Interactive grammar:** at the root prompt, enter `chat` alone to switch into the chat context, then `say 999 Test` / `read 999` inside it — the root-level space form `chat say 999 Test` only enters the context and drops the arguments. The batch form `-e 'chat say 999 Test'` is routed by the batch runner and works (or use `-e 'chat' -e 'say 999 Test'`). |
| Own name | `name` prints the own display name (no account id). `name --expect <value>` performs one profile read and fails the batch on mismatch. |
| Rename | `rename <name>` keeps the existing one-time wire route (`player_set_name_once` with its current empty-value flag, unchanged, not native-verified). If a prior `name` read verified the exact same value, the rename is skipped — no retries, no fallback routes, no extra pre-rename reads. |
| Exact values | `bin/sandbox` quotes are **shell syntax, not value**. Quoting preserves `[]`, Unicode and spaces exactly; no strip, transliteration or normalization occurs. The authorized test message is exactly `Test`. |
| Batch semantics | Registry pre-validation (unknown command / missing mandatory args), logger-error counting, first-failure-stop for real command errors, and final nonzero exit when attempted outgoing chat sends remain unconfirmed after all requested commands have run. `Shell#exec` returns nil (SDK), so success is never inferred from it. Failed unknown commands, argument and exception details are redacted: unknown untrusted exceptions report the class only, mapped request errors keep their type, static description and safe HTTP status, and malformed quoting reports a static reason — raw lines/args are never echoed. |
| Transport safety | Pool construction sets `max_retries=0` (Net::HTTP's default of 1 silently retried even mutative sends — fixed), and bounded timeouts: open 10 s, read 15 s, write 10 s. Absence of the `ssl` config key now inherits the server default (TLS on) after a pre-correction bug forced plaintext for private JSON configs; explicit booleans and legacy `'on'`/`'off'` strings are honored, invalid values fail, and plaintext to the known game host is refused before credentials leave the process (custom/loopback hosts keep explicit plaintext). Certificate verification stays enabled end-to-end (loopback HTTP tests use explicit `ssl=false` hosts, never VERIFY_NONE). |
| Malformed config | A config that fails to parse prints a static friendly reason and exits 1 — the parser message (which quotes config content) is never echoed. |
| JSON summary | `--json` prints one line: `{"ok":bool,"commands":[{"command","ok"[,"error"]}],"own_name":string-or-null,"own_message_seen":bool,"chat_message_count":n,"chat_publication_status":string-or-null}`. No account ids, sessions, tokens, URLs or config contents. `own_message_seen` and `chat_publication_status: "confirmed"` require every attempted outgoing send to be echoed by a not-previously-observed own account id, room and exact message text tuple. Because the implemented seven-field parser exposes no stable message id (official native chat schema remains unverified), reuse detection keys echoes by `[sender id, datetime, room, exact text]`; identical echoes with the same timestamp are conservatively counted once, while distinct datetimes can confirm distinct identical sends. `"unconfirmed"` means the send was attempted but not proven published. |
| Config paths | `-c` accepts a bare config name (named fallback in `configs/`, `.conf`) or an explicit existing path: relative, absolute, `~`-expanded, `.conf`/`.json`. A missing explicit path fails with a friendly message and exit 1. No implicit account search. Credentials are read only from the config you pass and are never logged. |
| Untrusted chat | Incoming names and text are sanitized for display (ANSI/OSC/control effects and newlines stripped, Unicode and `[ff0000]`-style literals preserved), so messages cannot fake prompts, lines or batch status. Chat read/write bodies are validated before permissive chat parsing: valid empty chat is still empty, recognized exception envelopes become mapped safe errors, and malformed nonempty rows fail instead of becoming a successful empty read. Outgoing text is sent verbatim; messages containing terminal control sequences are rejected, not mutated. |
| Bootstrap | `bin/sandbox` prepends its repository `lib/` to `$LOAD_PATH`, so repo code no longer depends on the caller's CWD or `RUBYLIB`. The `sandbox-ruby` gem still activates under the documented `bundle exec` runtime prefix. |

## Checklist

- [x] D1 correction focused RED → GREEN observed for chat response validation and duplicated echo reuse (67 examples: 4 failures before implementation → 0 after).
- [x] Focused RED → GREEN observed (33 failures before implementation → 0 after).
- [x] C2 correction round: RED observed (10 failing examples: TLS inheritance/legacy/guard, pool retries/timeouts, config-content echo, batch message withholding/malformed quoting) → focused GREEN (87 examples, 0 failures).
- [x] Independent D2 full offline suite after chat validation/confirmation corrections: 823 examples, 0 failures; focused 67 examples, 0 failures and 17 Ruby syntax checks passed. Earlier C1/C2 full suite: 806 examples, 0 failures (historical).
- [x] `ruby -c` passes for every changed entrypoint/lib/spec file.
- [x] `git diff --check` clean; `bin/sandbox --help` exits 0 with no network.
- [x] Application tests use synthetic configs and transport-only stubs. The independent C2 verifier later disclosed two possible outbound authentication attempts with synthetic credentials from probes that omitted their transport stub; those attempts are not used as evidence and were not repeated.

## Live verification (C3 — partial)

### Historic exact-name attempt — stopped by design

One guarded live run executed the original exact-name batch sequence from the real `bin/sandbox` entrypoint (no API-only substitute), inside a read-only HTTP scope guard with peer/TLS verification, an unchanged source hash and private capture (protected 0600 logs). Evidence summary:

| Item | Observed |
|------|----------|
| Result | process exit 1, `ok: false`, stopped on the `--expect` failure before chat send/read |
| RPCs | 1 auth, 2 profile reads, 1 rename (all HTTP 200) |
| Requested name | `[ff0000]βℓąȼЌhąţhąȼЌ€я` (22 characters), exact original on the wire, guard-verified before sending |
| Returned name | `[ff0000]βℓąȼЌhąţhąȼЌ` — 20 characters, 31 bytes, exact prefix of the requested name, color prefix intact; NFC normalization does not explain the difference |
| Chat | `send_attempted: false`, `own_message_seen: false`, `chat_message_count: 0` — no `Test` posted |
| Error class | none (the mismatch is a verified equality failure, not an exception) |
| Ledger | private attempt ledger outside the repository (0600) prevented duplicate rename/send; not reset, not retried |

Note: the exact returned value above is recorded precisely in
`docs/cli-chat-live-verification.json` alongside counts and statuses.

### Current-prefix chat attempt — send attempted, not confirmed

After the user accepted the current returned prefix `[ff0000]βℓąȼЌhąţhąȼЌ`, the parent executed one further guarded real-CLI batch with no rename and no retry: auth, profile/name check for the current prefix, `chat say 999 Test`, and `chat read 999`. Duplicate authorization messages authorized only this one send. A new exclusive private ledger (`cli-current-prefix-test-world999.json`) was used; the old rename ledger was preserved.

| Item | Observed |
|------|----------|
| Classification | `send-attempted-unconfirmed` |
| Real CLI exit | 0 |
| Guard process exit | 1 (guard wrapper result only; the real CLI exit was 0) |
| RPCs | 4 total: ordered auth, profile/name check, send, read |
| HTTP statuses | 200, 200, 200, 200 |
| Accepted current name | `[ff0000]βℓąȼЌhąţhąȼЌ` |
| Rename | not attempted |
| Message | exactly one authorized `Test` to World 999 |
| Readback | `chat_message_count: 29`, `own_message_seen: false` |
| Result | send attempted, but the owned `Test` was not confirmed in the readback |

Safe structured evidence for this second run is in
`docs/cli-current-prefix-chat-verification.json`. The guard script
`scripts/cli_current_prefix_check.rb` was executed by the parent only; helper
scope remains pending native review. The earlier documentation-only live-run
update did not rerun the full suite (historical source evidence: 806 examples).
The subsequent chat response/confirmation corrections were independently
verified with 823 full-suite examples and 67 focused examples, zero failures.

### Current limitations (facts only, no inferred caps)

- The server readback returned 20 characters (31 bytes) for the requested
  22-character name. This is one observed API readback: it is NOT a proven
  general 20-character or 32-byte database limit and says nothing about the
  underlying implementation.
- The full desired 22-character name was not confirmed applied.
- The later current-prefix CLI run attempted the authorized `Test` send, but the owned message was not confirmed in the readback.
- No automatic retry, fallback rename, color stripping or alternate value was applied or is recommended by this tooling.
- There is no proven reason for the missing own-message match or delivery confirmation. The own-match checks parse both sender id and exact message text internally, not just display name.

## Next step

No stale decision is pending: the user already authorized exactly one `Test` under the current prefix, and that authorization has been spent. No further request, retry, read, rename or send is authorized by these docs. A future read-only follow-up would require fresh parent/user authorization.
