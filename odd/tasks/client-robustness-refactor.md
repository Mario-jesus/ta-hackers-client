# Selective client robustness refactor

## Objective
Integrate useful fixes from the received developer copy while preserving the verified client protections. Improve the parsing and initialization paths shared by scripts; do not assume a reported working external environment proves every script or backend operation works here.

## Baseline and authorization
- User explicitly requested starting the refactor after the GitHub backup.
- Baseline: `a6cfdf3b17cc67821cd45f62733600194f1f5a43`, backed up in the independent private `Mario-jesus/ta-hackers-client` repository.
- Isolated branch: `refactor/client-robustness`; preserve the published backup branch.
- Existing local change in `odd/tasks/fork-backup.md` is the post-push completion record; preserve it and do not include it in this feature's commits.
- Preserve original history/license and all unrelated files. No automatic push, PR, merge, or global dependency/auth configuration changes.
- Only offline deterministic tests and fake transport/script state are authorized in this phase. No live game calls, account creation, tutorial, purchases, combat, or script execution against the backend.
- Never read `configs/mine.conf`, private account credentials/ledgers/raw captures, or private keys.

## Scope and non-goals
Keep TLS peer verification, bounded timeouts, retries disabled, native-aligned request flags/query encoding, minimal authentication, terminal sanitization, and owned-message publication confirmation intact.

The received nested `ta-hackers/` directory is ignored for Git/review privacy but remains available for explicit read-only comparison; it must not be added to this repository. `autohack` repair is excluded. Scripts requiring catalogs/profile/world state must not be represented as ready after session-only minimal authentication.

## Tasks and acceptance checks
- [x] R1 Make serializer normalization non-mutating and explicitly nil-safe; handle incoming UTF-8 without altering outgoing message text. Add observed RED/GREEN regression tests, frozen/reused inputs, delimiter round trips, Unicode, inbound invalid bytes, outbound preservation, and unchanged strict chat validation.
- [ ] G1 Add a tracked `.gitignore` with deterministic isolated-Git tests: exclude private configs/credentials/keys/logs, APKs/raw dumps, local indexes, and the received nested repository; keep public default config, country data, source, tests, docs and task files eligible. Do not read secrets or untrack/delete existing files.
- [ ] R2 Harden missing optional catalog fields with targeted fixtures, starting with app settings and the actual missions-list catalog. Reject malformed required data rather than silently marking it loaded. Adopt only proven useful guards.
- [ ] R3 Align full-connect initialization and verify script prerequisites; evaluate required explicit Ruby dependencies without wholesale lockfile/Reline changes. Preserve minimal mode and do not enable gameplay or autohack.
- [ ] R4 Run independent offline compatibility checks, record supported/unverified script paths and remaining backend uncertainties, and prepare the next bounded diagnostic step without executing it.

## Routing
R1/G1/R2/R3 use one bounded `gentle-ai-worker` at a time because source, tests and public documentation form multi-file changes. Read-only script/initialization mapping is delegated to an explorer; executed independent checks go to `gentle-ai-verify` when required by native ASSESS. The parent owns task transitions and mirrors. No parallel writers.

## Delivery and review
Use small coherent work units with tests and relevant documentation. The R1 executor correctly reported the earlier safety boundary against staging/committing this new refactor; prior backup publication must not be silently treated as fresh commit authority. The user has now explicitly authorized local verified unit commits on `refactor/client-robustness`, with no push or PR. Record commit identities only after actual commits are observed. The parent owns staging/commit sequencing and should commit/review R1 before G1. Do not push, open a PR, or run remote/native lifecycle actions without separate authorization. Review each work-unit commit against its parent, never the accumulated branch. Native review follows only the user-owned switch and provider-issued authority; failed/unavailable review is reported and its assessment plan governs independent verification. About 400 authored lines per unit is advisory, not a reason to omit tests or compress code.

## Evidence and uncertainties
- The baseline serializer used in-place `gsub!`; received implementation duplicates inputs and normalizes nil to an empty string. Received incoming parsers duplicate, force UTF-8, and scrub; outgoing generation must not silently scrub.
- The script dispatcher injects `GAME`, shell and logger but does not load datasets. Minimal auth intentionally skips catalogs; full connect is needed for catalog/profile-dependent scripts.
- The received directory was hidden from the explorer's ignored-file inventory, not absent: a direct read of `ta-hackers/lib/hackers/serializer.rb` confirmed the implementation is present.
- The reported external success of all scripts except autohack is not independently demonstrated. Static autohack breakages reported by the scout are follow-ups, not an implementation target.
- Backup checks: 828 RSpec examples plus 24 and 10 helper self-tests passing. No evidence yet that these refactor changes fix global chat publication.

## Progress
R1 implementation and writer checks observed: RED 10 examples/7 failures before changes; focused GREEN 52 examples/0 failures; full suite 838 examples/0 failures; helpers 24/24 and 10/10; serializer syntax OK. The user subsequently explicitly approved local verified-unit commits (no push/PR). The worker's fixed role forbids staging/committing even with permission, so the parent performed only the mechanical Git handoff after the worker repeated focused GREEN (52/0). Local commit: `04ae4bda1b6b5f99b02d7d2ea327d325df5731ef`, parent `a6cfdf3b17cc67821cd45f62733600194f1f5a43`, exactly `lib/hackers/serializer.rb`, `spec/serializer_spec.rb`, and `docs/client-robustness-refactor.md`; 134 insertions / 11 deletions. Cached whitespace check passed; index empty afterward. G1/feature task files and unrelated backup metadata were excluded.

R1 native review closed successfully after the user requested continuation: fresh bound STATUS retained the same three-path frozen candidate, one-run forecast was acknowledged, and `review-reliability` executed successfully. Native capture approved lineage `review-6b6b79228768e99e`; fresh STATUS supplied its exact acknowledgement, which completed with `native-approved-acknowledgement-completed`, authority `burned`, target `sha256:5ba60cad61916edb6b0001cd942fb19961b28dfac8e94fd7d93fdd272d0aee12`. No STATUS was issued after the burn. The earlier missing-model refusal is resolved for this run; the parent did not edit model settings or change RDD.

Independent verification also passed: all three R1 working blobs matched commit `04ae4bda1b6b5f99b02d7d2ea327d325df5731ef` before/after checks; focused suite 52/0; full suite 840/0 (includes two G1 examples); helpers 24/24 and 10/10; whitespace checks passed. The earlier unavailable ASSESS result used its high-risk independent-verifier fallback and was not mistaken for approval. R1 now has both functional verification and a successfully acknowledged native approval.

G1 implementation and writer checks observed: RED 2 examples/1 failure before the tracked policy (`configs/private.conf` was not ignored in the isolated fixture); focused GREEN `spec/gitignore_spec.rb spec/serializer_spec.rb spec/chat_response_spec.rb` 20 examples/0 failures; full suite 840 examples/0 failures; helpers 24/24 and 10/10. Inventory confirmed only `configs/default.conf`, `data/countries.conf`, and `dumps/.gitignore` are tracked in those areas. No `configs/mine.conf` content was read. Existing local `.git/info/exclude` rules are insufficient for new clones; the new working-tree `.gitignore` carries the tested policy and still awaits its own local commit, with review notes in `docs/repository-ignore-policy.md`. G1 is now the active local commit/review unit, following completed R1. Its commit includes only `.gitignore`, `spec/gitignore_spec.rb`, `docs/repository-ignore-policy.md`, and this feature task document. Do not include unrelated backup metadata or alter the serializer. Record the actual G1 commit identity after creation; leave its checkbox unchecked until checks/review closure are observed.

## Next step
Commit G1 locally, then inspect/review only its range against R1 commit `04ae4bda1b6b5f99b02d7d2ea327d325df5731ef`. Record checks and exact acknowledgement outcome, then reconcile tasks before mapping R2 required versus optional catalog fields. No push, PR, live backend action, or automatic routing/switch change.
