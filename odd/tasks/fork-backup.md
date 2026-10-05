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
- [ ] F2 Commit the approved existing work in coherent units on the current feature branch.
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
F1 verified. F2 in progress: the first transport work-unit commit is `4967f59f555db349599630641886f6299a0dc82f`, parent `aae76abe486f53bcf8367ce9b94463ee1f08493a`. It contains 12 approved paths (including the eligible HTTP task document), 2664 additions and 19 deletions. Focused transport/API/Game tests passed again (80 examples, 0 failures); cached whitespace check passed; index is clean. The only new content correction was removal of one extra EOF newline byte from `spec/client_http_spec.rb`; all other selected contents were preserved. Local exclusions preserve and hide nested/private artifacts. The CLI/chat unit remains uncommitted.

Native review was attempted for this exact committed range. An initial workspace/committed selection mismatch was corrected with range-specific inspect. The subsequent host consent expired (`consent-binding-expired`); `lineage_created=false`, no native authority mutation and no approval. ASSESS reported risk unassessable and explicitly unavailable review, requiring writer self-verification plus an independent verifier. The independent commit/tree/focused-test verification is running before the second unit. No remote edit, repository creation, or push occurred.

Read-only GitHub checks confirmed the active login `Mario-jesus`. The exact new target returned HTTP 404 (absent or not visible, not absolute absence proof). `gh repo create --private` and the per-command Git credential helper are supported. Creation must still occur exactly once and stop on an existing/uncertain target. The original `fork-backup.md` locator is retained for continuity; the former fork destination is no longer authorized.

## Next step
Observe the independent verifier's result for the first transport commit, then delegate the second CLI/chat commit with its exact approved paths and offline checks. No native approval is claimed. After both units and applicable verification, create and verify the independent private repository and publish via the existing HTTPS credential helper.
