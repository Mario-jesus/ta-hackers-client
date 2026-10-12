# Session authentication is not script readiness

Minimal connect makes exactly one authentication request and extracts a nonempty
session ID. It does not load catalogs or decode tutorial, profile or missions.
A session alone is therefore insufficient for catalog-dependent scripts.

## Full connect boundary

Normal connect retains this sequence:

1. Load language translations, app settings, node types, program types, missions
   list, skin types, hints list, experience list and builders list.
2. Authenticate and decode tutorial, rank, experience and mission data. Reject a
   nil or empty SID before those mutations.
3. Load goal types, shield types and rank list.

This matches the received source ordering; it is not proof that the live protocol
requires that order. A RequestError stops later steps and keeps the failing step's
log attribution. Structural ParserError failures propagate. Neither route adds
retries, clears a previous session on failure, or introduces a universal readiness
state. Full connect does not itself load every player network or world dataset.

## Autohack usage (offline-verified script contract only)

```
run autohack                                     # no arguments: default count 1
run autohack --coffers 40 --timing fast --count 3
run autohack 3                                   # legacy positional count, deprecated: warns
```

Counts: no arguments means one attack; `--count N` is the explicit form
(positive integer); the legacy bare positional count still runs and logs
`Legacy positional argument is an attack count, not a player/network ID; prefer
--count N`. There is no ID detection and no magnitude cap (kept for
compatibility by user decision), so a huge digit run is taken as an attack
count. A positional count together with `--count`, duplicate `--count`
options, more than one positional token or a non-positive/non-numeric value
prints usage and makes zero game calls. No manual target/ID flags exist:
targets are selected automatically from the offered world list, target id 127
is skipped and each id is attempted at most once per run.

Defaults: coffers 5 (integer floor percentage of the attacked target's
validated coffers, computed per currency with no compounding), timing
conservative 420..950 (`fast` = 15..25; a custom `MIN..MAX` needs a positive
minimum). Before any battle call the script logs one plan line: automatic
target selection, requested attacks, coffers, timing; no IDs accepted.

Failure summaries: the final summary line distinguishes completed, stopped and
cancelled runs, reports completed request sequences and attempted attacks as
local counts only, labels the failing stage (`attack`/`update`/`finish`/
`leave`) with an HTTP status plus an allowlisted error type (or the literal
`unknown`), and states `leave request completed; server closure unverified`
when the last leave request actually returned (an accepted raw response is
still not proof of server-side closure), `entry closure not confirmed` when a
confirmed entry's leave did not complete, or `no confirmed entry` when none
was confirmed. It never claims successful attacks or a server-side closure:
the generic harness `Done` line only means the job ended, not a win or proof;
server outcomes stay unverified even after a validated finish response.

Background use: wait for the script's own final summary line; an immediate
exit or process cancel may stop the job before finalization so cleanup stays
unknown, and no shutdown guarantee is claimed. Known fight finish/leave HTTP
500 failures are unaddressed locally: real backend acceptance is pending
(offline UX only, no engine proposal), and the legacy replay scripts remain
out of scope.

## Representative prerequisites (static inspection only)

| Public source | State assumed beyond a session | Additional work in the script |
| --- | --- | --- |
| `scripts/fingoals.rb` | Goal types catalog for amounts and credits | Loads world goals, then calls goal updates repeatedly |
| `scripts/missions.rb` | Missions list catalog for mission names; player ID argument | Loads that player's mission log for display |
| `scripts/colres.rb` | Node types catalog for production limits, speeds and currencies | Loads player network/profile, then collects eligible production nodes repeatedly |
| `scripts/autohack.rb` | Own player country; app settings `node types`/`program types` values (runtime-validated; the exact key strings remain unverified); loaded world targets | Bounded attack run over listed targets: one zero-loot update, one final fight at the configured coffers percentage, then a network leave; blank protocol versions are refused; a typed final failure summary reports completed request sequences only, never successful attacks |

`lib/cli/context/script.rb` dispatches scripts with GAME, shell, logger and
arguments; `lib/cli/sandbox.rb` stores these references. Neither initializes the
required catalogs. The scripts' `connected?` checks do not establish that all
catalog, profile or world prerequisites are available. Full connect supplies the
listed catalogs, not a guarantee that subsequent script reads or mutations work.

## Verification and limits

Offline specs invoke only the registered connect command with fake game/dataset,
logger and shell state. They cover exact ordering, minimal isolation, bootstrap,
auth and post-auth short-circuits, and structural failure propagation. Full-auth
specs retain valid decoding and reject nil/empty SIDs before state setters.
No representative script was executed against a live backend, and no gameplay
mutation or backend publication was validated. `autohack` now carries the
offline contract tests of this repair (restored `attack_net` parse plus strict
script stages), yet its live backend behavior, the exact AppSettings key
strings and loot application remain unverified; it is not declared
battle-ready and no victory is claimed.

Base64 already has explicit requires in `lib/hackers/client.rb` and
`lib/cli/context/query.rb`; no demonstrated missing require warrants dependency
changes. No direct Readline use was identified in the bounded mapping. Gemfile,
lockfile, Reline and global dependencies are unchanged. The observed Ruby 3.3
warning about base64 leaving Ruby 3.4's default gems remains a future compatibility
limit, not a resolved dependency issue.
