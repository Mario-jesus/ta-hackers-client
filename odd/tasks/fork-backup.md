# Save current client progress to an independent private repository

## Objective
Before integrating the received developer code, back up the current client to a NEW, independent repository: `Mario-jesus/ta-hackers-client`, private. The user selected this name and visibility explicitly. Do not create a fork or publish to the abandoned fork target.

## Authorization and constraints
- Commit and publish the existing client work; preserve its original history and LICENSE.
- Current branch: `fix/http-compatibility-diagnostics`; baseline commit: `aae76abe486f53bcf8367ce9b94463ee1f08493a`.
- Preserve `origin` (`animotto/ta-hackers`). Use a separate `backup` remote for the new repository; never push to `origin` or `Mario-jesus/ta-hackers`.
- Use existing GitHub CLI authentication as `Mario-jesus` over HTTPS, scoped to the publishing commands. Do not read private keys/tokens, change global auth settings, upload SSH keys, or rewrite history.
- Exclude `configs/mine.conf`, credentials/account ledgers/logs, APKs, raw dumps/data, `.codegraph/`, `.atl/`, and the nested received `ta-hackers/` repo from new commits.
- No game backend, account creation, live helper execution, received-code integration, force push, PR, or merge.
- Preserve all unrelated local files. Local Git exclusion of private/nested artifacts is allowed; do not delete or move them.

## Tasks
- [x] F1 Verify the exact public backup scope, privacy, offline checks, and usable GitHub authentication.
- [x] F2 Commit the approved existing work in coherent units on the current feature branch.
- [ ] F3 Create the independent private repository, publish the branch, and verify its identity and visibility.

## Routing
F1 used read-only explorers/verifiers. F2/F3 use one bounded executor at a time; no concurrent Git/index writers. The parent owns task reconciliation and native review authority. This is a backup of existing work, not new behavior implementation; no new RED cycle is meaningful. Applicable existing offline checks are required.

## Verified evidence
- Full RSpec: 828 examples, 0 failures.
- Diagnostic helper: 24/24 offline self-tests passed.
- Current-prefix helper: 10/10 offline self-tests passed.
- Relevant Ruby syntax and `git diff --check`: passed.
- Full-text privacy scan across 35 candidate paths: no actual private credential blockers observed; findings classified as protocol keys, synthetic fixtures, placeholders, or redacted/public references. Five public JSON reports parsed.
- `configs/default.conf`: placeholder/unset credential fields; public version change only.
- Git index empty. `spec/client_spec.rb` unchanged; exclude it from commit changes.
- The sole tracked dump-name artifact is inherited, unchanged `dumps/.gitignore`, not a raw capture.
- GitHub CLI is authenticated as `Mario-jesus`. SSH agent has no loaded keys; former fork SSH access failed. That target is now abandoned; use existing CLI auth over HTTPS for the newly selected repository.
- RDD is on (global). Preflight performed no mutation and was blocked by the unignored nested unrelated Git repo `ta-hackers/`. A local `.git/info/exclude` entry can preserve that directory while keeping it outside this repository's candidate. No native approval exists.

## Commit scope
Transport/API/client compatibility with its API/HTTP specs and protocol evidence; then CLI/chat/batch behavior, diagnostic helpers, applicable CLI/chat/auth specs, redacted reports, and task documents. Exact paths must be allowlisted; no blanket `git add .` or directory add.

## Acceptance checks
- Commit trees contain only allowlisted additions; private/nested artifacts remain local.
- Coherent Conventional Commits preserve behavior with its tests/evidence; record their full identities.
- Native review follows only provider-issued authority under the current switch; unavailable/declined review is reported, not called approved.
- Check exact new repository name before creation. An existing repository is not permission to overwrite it; stop if it already exists.
- Create once as private/non-fork. On ambiguous creation or push, reconcile read-only once and never blindly retry.
- Verify `isPrivate=true`, `isFork=false`, exact owner/name, and remote branch SHA equals intended local SHA.
- No commit hooks changed or bypassed; no force push or upstream publication.

## Progress
F1 verified. F2 has two committed work units:
1. `4967f59f555db349599630641886f6299a0dc82f` (`fix(http): harden transport and align native request compatibility`), parent `aae76abe486f53bcf8367ce9b94463ee1f08493a`: 12 approved paths, 2664 additions and 19 deletions. Focused tests passed (80 examples, 0 failures); cached whitespace check passed. The only content correction removed one extra EOF newline byte from `spec/client_http_spec.rb`. Independent verification confirmed all 12 blobs and repeated 80 passing tests; no severe source blocker found. A historical authentication-evidence wording inconsistency in the HTTP report remains a documentation follow-up.
2. `18c189b8677b244660763c76cfc316c10d866efc` (`fix(cli): preserve verified chat diagnostics and publication checks`), parent `4967f59f555db349599630641886f6299a0dc82f`: exactly 22 approved paths, 4134 additions and 18 deletions. Full suite passed (828 examples, 0 failures), helpers passed (24/24 and 10/10), cached whitespace check passed; no source-byte or EOF corrections were needed.

Local exclusions preserve and hide nested/private artifacts. F2 is verified: the independent second-unit check reproduced 828 passing examples and 24/24 plus 10/10 helper self-tests; the 6 source, 4 spec, and 2 helper blobs match the committed tree, exactly 22 allowed paths were confirmed, and the committed whitespace check/index passed. No severe deterministic blocker was observed. No received-code integration occurred. The only remaining local content change is this passive task/evidence document.

Native review outcomes: the first committed unit's host consent expired; no lineage/authority mutation or approval was created. Its required independent verification passed. The second CLI/chat unit was inspected and START was attempted both at its staged target and exact committed range; each stopped with `lens_context_budget_exceeded`, no authority or approval. ASSESS for the second committed range reports high risk (process boundary in `lib/cli/batch.rb`), explicitly unavailable review, writer self-verification plus mandatory independent verifier. The reported candidate is not consumed. Do not retry the unchanged oversized review candidate, truncate immutable evidence, or invent approval. No remote edit, repository creation, or push occurred.

Read-only GitHub checks confirmed the active login `Mario-jesus`. The exact new target returned HTTP 404 (absent or not visible, not absolute absence proof). `gh repo create --private` and the per-command Git credential helper are supported. Creation must still occur exactly once and stop on an existing/uncertain target. The original `fork-backup.md` locator is retained for continuity; the former fork destination is no longer authorized.

## Next step
F3 is in progress: create `Mario-jesus/ta-hackers-client` exactly once as private/non-fork, commit only this public verification evidence, add a separate `backup` HTTPS remote, and push/verify `fix/http-compatibility-diagnostics`. No further product decision is needed; creation/publication is explicitly authorized. The latest reminder was inspected as task-document-only metadata, and native ASSESS reports passive risk, `reviewDue=false`; structural readback is the complete applicable check. No code review approval is inferred from that passive result.
