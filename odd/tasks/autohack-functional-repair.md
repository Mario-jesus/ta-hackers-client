# Autohack functional repair — preparation (docs-only gate)

- **Local implementation closed:** `4cec8b5af6b8706c71de56fc59eb6f1e7c31f7f8` (`feat(autohack): restore bounded configurable script`), exactly the six authorized files. Final parent offline check before commit: **1130 examples, 0 failures (34.6 s)**; the private-config case was excluded and no mutating hooks ran.
- The defaults and configuration interface are implemented and checked locally. Real-server acceptance of combat, flags, resource claims and replay remains unverified. No live attacks, native approval or push occurred; earlier pending-commit and preparation descriptions are historical snapshots superseded by this record.

## Current delivery decision

- The user explicitly selected one local delivery with a size exception (`exception-ok`) for the exact six-file repair: 1239 authored changed lines at the decision. This includes code, tests and documentation; no cosmetic compression or test omissions are permitted.
- Final-byte independent offline verification: **1130 examples, 0 failures (33.47 s)**, with exactly the private default-configuration example excluded. The existing public API version setter is preserved; confirmed-entry cleanup runs at most once, and ambiguous entry stops without another attack.
- Native review and real-server combat/loot validation remain unavailable or unperformed; no approval, victory or empty-coffers guarantee is implied. Parent verification and local commit are pending. The size exception does not authorize a push.

Preparation by delegated agent; NO source write, test execution, Git mutation, network or remote in this unit. Outcome after parent read-back: restore the dead attack-net parser via the existing API surface, then make `scripts/autohack.rb` loadable, configurable and bounded — all from proven local contracts only. No battle engine, no victory/empty-coffers claims, no fabricated replay playback.

## Identity, authorization, resolved behavior

- On branch `fix/cli-chat-working` @ `be6112d`. Source untouched; dirty files `configs/default.conf`, `odd/tasks/client-robustness-refactor.md`, `odd/tasks/fork-backup.md` exclude from any future commit and are never read.
- User-resolved defaults (no new policy asks): loot **5%** default, `--coffers 0..100` integer (100 allowed); timing **conservative 420..950** default, `--timing fast` = 15..25 or custom `MIN..MAX` with `MIN > 0`; success stays draft-constant `7` = `Hackers::Network::SUCCESS_CORE|SUCCESS_RESOURCES|SUCCESS_CONTROL` (bits 1|2|4 = existing defined intent, not a new user flag choice); upstream `9802b81` precedent (zero loot, `success: 23`, sleeps 4..9/35..95/5..12/420..950) is citation only. Delivery strategy for this NEW feature: `ask-on-risk`; local repair and tests ONLY (no backend/account real autohack, no push, no native lifecycle — native unsupported, stopped, no review/retry/mode/PASS).
- No secret/error-raw-profile leakage: progress logs print exception **class only** (`e.class`), never `e.message`/`description` bodies.

## Evidence map (verified READ-ONLY this session, path:line)

| Fact | Reference |
| --- | --- |
| Historical parser: `{nodes (0), net (1,0,1), profile (2,0), readme (4,0,0)}` | `9eb0951` `lib/hackers/serializer.rb:1128–1146`; deleted @ `3767236` |
| Origin `cmdNetGetForAttack` returns `{profile, net}` | a1232cc `lib/hackers.rb:554–569` |
| Modern own-profile slot (2,0) | `lib/hackers/dataset/network.rb:69–70` |
| Dead call | `lib/hackers/api.rb:521–522`; `parseNetGetForAttack` absent (`serializer.rb`) |
| Profile fields integers | `serializer.rb:203–229` (`money=(2,0,2).to_i`, `bitcoins=(2,0,3).to_i`) |
| Fight writes (non-idempotent) | `api.rb:541–557` update; `561–583` finish (+summary/version/keepLock/replayString); `512–523` attack_net; `527–537` leave_net; `429–438` new_targets `player_get_new_targets` — **no purchase/currency params** |
| RequestError automatic | `client.rb:98/103/285`; `MAX_RETRIES=0` |
| RESTRICTION: strict arg contract | `lib/cli/sandbox.rb:97–118` (Script basics); `lib/cli/context/script.rb:21–87` args = raw tokens; `finish` runs BEFORE `thread.kill` (`script.rb:149–155`) |
| Prereq guards exist | `Dataset#loaded?` `dataset.rb:13`; `AppSettings.get` `app_settings.rb:36`; node/program lists are `Dataset` subclasses (`game.rb:48–49`); world needs profile country (`world.rb:31`) |
| Draft defects | `scripts/autohack.rb:58–64` missing commas → SyntaxError; `:25` undefined `k`; `:39` `Game::SUCCESS_FAIL` absent; `:47` private config; `:29/:32/:53/:70` `Game#cmd*` absent; `:20` world-before-player; `:72–75` broad retry; `:83–89` unbounded ReadTimeout retry |

## Critical non-retry rules (non-idempotent server mutation)

- NO auto-retry on attack_net/fight update/finish/leave: server may commit before a timeout; ambiguous outcome is FAILED for that target, CLOSED — never re-attempted same target in the run.
- `targets.new` refresh: single attempt, no retry; cleanup error → log class-only and stop the run (endpoint inspected client-side as parameter-free, but server-side charge/mutation semantics unproven → absent approval choose stop, not retry).
- Cleanup "leave" fires **at most once, only after battle entry was confirmed** (no fake receipt). The `finish` hook requests cancellation; owner-side cleanup must cover normal completion and `Thread.kill` without concurrent or duplicate leave requests. Never hold a mutex during IO; preserve client timeouts. An ambiguous attack outcome stops the run, not a repeat attack.

## Tasks

- [x] **T1 — API attack-net parser repair.** Route: delegated, non-trivial. Files `lib/hackers/api.rb` + `spec/api_spec.rb`. Observed proof: pre-fix RED run recorded 5 attack rows failing (`NameError: uninitialized constant Hackers::API::Serializer` for every row — the dead `Serializer.new` call on a module; standalone `require 'hackers/api'` never loads the serializer, so the draft-era expectation of NoMethodError did not occur); post-fix GREEN 5/5 via `rspec spec/api_spec.rb -e 'attack_net'`. Restored shape: `{nodes 0, net 1, profile (ParserError-validated (2,0)), readme 4}` returned from `Serializer.parseData` + `Serializer::Profile#parse(2,0)`; raw sections documented as unmodeled. Version accessor: read-only split was SUPERSEDED in the correction unit (baseline already had public `attr_accessor :version`; setter/getter restored unchanged; write-failure row replaced by actual request-params/setter compat row, 2/2 `-e 'instance version'`).
- [x] **T2 — Configurable autohack rewrite.** Route: delegated, non-trivial. Files `scripts/autohack.rb` + new `spec/autohack_spec.rb`. Observed proof: pre-rewrite RED = all 24 spec rows failed loading `scripts/autohack.rb` with the draft `SyntaxError` (missing commas, now line 59 boundary); post-rewrite GREEN 24/24 (`rspec spec/autohack_spec.rb`). Implemented on stdlib `OptionParser` over raw tokens: `--coffers 0..100` integer (default 5), `--timing conservative|fast|MIN..MAX` (default conservative 420..950; custom needs positive minimum), positional positive count; invalid args print usage and make zero game calls (asserted). replayVersion = per-instance `api.version` (`2222,7,25` with a synthetic 2222 instance while `API::VERSION` stays 1229; the earlier "read-only" wording on the accessor is superseded in the correction unit - the public accessor from HEAD is restored and remains the source) + the two AppSettings keys, which are runtime-validated and never fabricated as server truth in specs. Per-action sleeps upstream-fixed; between-target interval from the timing option. Zero sleeps in tests (controlled queues; the kill-case parks inside the stub).
- [x] **T3 — Safety bounds + offline regression.** Route: delegated. Observed proof rows: target id 127 skipped; each id attempted at most once via the attempted-id set (repeats after refresh never re-attack); exactly one bounded refresh, then an actionable stop. Correction-unit supersession of the consecutive-cap text: attack-stage transport errors or unparseable responses are UNCERTAIN entry outcomes - the run stops immediately with class-only logs, an actionable manual-inspection line, no further target attempt and no blind leave, so `RecoverableTargetFailure`, the consecutive counter, the three-failure cap and their test were removed as dead/wrong instead of retaining fictional retry behavior. The immediately fatal update/finish/leave mutations never retry; the known entry is recorded right after the validated attack response (earlier post-update placement stranded entry cleanup - the pinned no-leave test was a taught bug and is now replaced: update failure leaves the known entry exactly once, zero finishing calls, no next target); finish failure and cancellation (finish hook or Thread.kill) leave a confirmed entry at most once via main's ensure; a failed leave clears the open-target flag BEFORE further IO, so no duplicate leave fires. Logs stay class-only: synthetic `'malformed-profile-body'`, `'raw-update-body-marker'`, `'raw-attack-body-marker'` body markers asserted absent. Acceptance observed (correction unit): `ruby -c` OK on the four Ruby files; `git diff --check` clean; `--dry-run` partition 1131 total / 1130 with `-E '^(?!.*ships version 1229 in the default configuration).*$'` / exactly 1 positive match (the private-config example; the only phrase occurrence in the negative dry-run output is rspec's own `Run options:` echo) / phrase grep 0 among examples; single full offline run `--example-matches '^(?!.*ships version 1229 in the default configuration).*$' --order defined --format progress` → 1130 examples, 0 failures in 33.9s (120s cap honored), logs under `/tmp/opencode/autohack-correction-*.log`.

## Allowed source surfaces (future unit — narrow)

`scripts/autohack.rb`; `lib/hackers/api.rb` (attack-net method only); `spec/api_spec.rb` (new group); `spec/autohack_spec.rb` (new); `docs/script-prerequisites.md` (autohack row + appsettings/catalog prereqs only); this tracker (plus FULL Engram mirror keyed `odd/autohack-functional-repair/tasks`, project ta-hackers). Any other lib/shared refactor requires a concrete boundary finding returned to the parent first.

Correction-unit supersession (typed, not silent): the earlier "read-only accessor" refinement was based on a FALSE premise. `git show be6112d:lib/hackers/api.rb` lines 18–20 already exposed `attr_accessor :version` PUBLICLY; the write-row RED recorded legitimately by the writer was baseline behavior, not a defect. The original public setter/getter are RESTORED unchanged, the pinned write-failure example was replaced (not kept as a contract), scripts must still not mutate a live instance's version, and the instance-version request/replayVersion tracking is retained (`app_version`/`2222,7,25` rows) plus a new public-setter compat row. The consecutive-recoverable-failure cap (≤3) text is likewise SUPERSEDED: attack-stage transport or parser uncertainty now STOPS the run with no next target and no blind leave, making `RecoverableTargetFailure` and the consecutive counter unreachable dead mechanisms - both were removed together with their now-wrong test; user-facing count semantics (positive positional count) are unchanged.

## Acceptance and suite plan (privacy case)

- Known privacy example: `spec/api_spec.rb:101` (`it 'ships version 1229 in the default configuration'`) reads `configs/default.conf` at runtime; the working-tree file is dirty operator state — must never execute again. Known trap: `-e` with raw regex escapes fails; use `--example-matches`.
- Planned full acceptance: last-unit file-list run + `spec/api_spec.rb` + `spec/autohack_spec.rb`, prefixed `-E` (`--example-matches`, verified short form in rspec-core 3.11.0 `option_parser.rb:239`) with the negative-lookahead regex `'\A(?!.*ships version 1229 in the default configuration)'` (exact full_description `Hackers::API protocol version ships version 1229 in the default configuration`; `-e` is a literal-STRING matcher that breaks on regex escapes — it is NOT used for exclusion). Writer FIRST confirms via `--dry-run --format documentation` that exactly 1 example is excluded and counts match, before any real run. Baseline claim: last unit observed 1097 examples/0 failures excluding that one; T5 targeted 135/0 closed.
- Runner default, test-first (no strict mode inferred). Offline/fake-data only; no game-server contact; loopback-free (recorder stubs only). Backend fixtures are protocol simulation, not gameplay guarantees.

## Checks and environment

```bash
source ~/.local/share/ta-hackers-toolchain/env-ruby33.sh
~/.local/bin/mise exec ruby@3.3.12 -- ruby "$GEM_HOME/bin/bundle" _2.6.9_ exec rspec <files> ...
```

## Delivery forecast and limits

Forecast approximately 400–600 changed authored lines across the 6 listed files (tests not omitted, no cosmetic compression); delivery strategy `ask-on-risk` — if any work UNIT exceeds ~400 lines the parent asks the user before commit. Work-unit commits (parent executes Git; conventional messages; tests+source+doc together): T1 `fix(api): restore attack net parse contract after serializer refactor`; T2 `feat(autohack): restore script with bounded configurable attack policy`; T3 `feat(autohack): enforce operational bounds and cancellation cleanup` (exact text under work-unit review at execution). Unproven remains: server loot/flag/success semantics, `new_targets` server-side effects, AppSettings key strings, live finish-battle response body. Historical source solves proof ≠ backend truth; no receipt for anything native.
