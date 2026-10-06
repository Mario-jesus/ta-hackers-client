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

## Representative prerequisites (static inspection only)

| Public source | State assumed beyond a session | Additional work in the script |
| --- | --- | --- |
| `scripts/fingoals.rb` | Goal types catalog for amounts and credits | Loads world goals, then calls goal updates repeatedly |
| `scripts/missions.rb` | Missions list catalog for mission names; player ID argument | Loads that player's mission log for display |
| `scripts/colres.rb` | Node types catalog for production limits, speeds and currencies | Loads player network/profile, then collects eligible production nodes repeatedly |

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
No representative script was executed, and no gameplay mutation or backend
publication was validated. `autohack` is excluded, not declared ready.

Base64 already has explicit requires in `lib/hackers/client.rb` and
`lib/cli/context/query.rb`; no demonstrated missing require warrants dependency
changes. No direct Readline use was identified in the bounded mapping. Gemfile,
lockfile, Reline and global dependencies are unchanged. The observed Ruby 3.3
warning about base64 leaving Ruby 3.4's default gems remains a future compatibility
limit, not a resolved dependency issue.
