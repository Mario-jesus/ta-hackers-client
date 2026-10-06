# Client robustness: offline verification, not live readiness

**Verified offline; local branch unpublished; backend behavior unknown.**
This report records evidence at source commit
`f89f3eec6f5d94836117452678a16bedf80cb87c` on `refactor/client-robustness`.
The later documentation commit is not the source-evidence identity.
No push, PR, merge, live account creation or game action was performed by this refactor.

## Five local work units

Each approval covers its own commit against its parent, not the entire branch.
The original `a6cfdf3b17cc67821cd45f62733600194f1f5a43` transport/CLI
baseline was **not retrospectively reviewed** by these reviews.

| Unit | Local commit | Native approval and exact acknowledgement |
|---|---|---|
| R1 serializer | `04ae4bd` | `review-6b6b79228768e99e`: approved; exact acknowledgement completed, authority burned |
| G1 privacy policy | `9cfc925` | `review-2fe39f83c2b4d7c3`: approved; exact acknowledgement completed, authority burned |
| R2a settings | `771dff1` | `review-c635aa99a07de39d`: approved; exact acknowledgement completed, authority burned |
| R2b missions | `5ff3be0` | `review-1df6e70c900f384c`: approved; exact acknowledgement completed, authority burned |
| R3 initialization | `f89f3ee` | `review-3726e064faf58cc7`: approved; exact acknowledgement completed, authority burned |

R3 used four lenses: risk, resilience, readability and reliability.
The other units used consolidated reliability reviews under medium profiles.
Full commit identities, acknowledgement targets and independent checks are in the
[feature task](../odd/tasks/client-robustness-refactor.md).

## Functional evidence reused, not rerun in R4

Independent R3 verification at the source commit passed **155 focused examples,
888 full-suite examples, zero failures**, helpers **24/24 and 10/10**, four
source/spec syntax checks and committed whitespace checks, with no skipped/pending examples.
R4 reused this evidence because the source was unchanged; it did not rerun the full suite.
Historical component RED was writer-observed and GREEN independently verified;
R4 did not replay those failures. This passive report has no meaningful behavior-level RED.
Compatibility was verified only with **Ruby 3.3.12 / Bundler 2.6.9**.
Explicit Base64 loading already exists; the future Ruby 3.4 default-gem warning
remains unresolved. No dependency changes were made.

## R4 preservation and privacy evidence

The independent R4 invariant check observed the correct source HEAD and branch,
an empty index, and only intentional feature-task/old-backup-document modifications.

| Check | Observed result at source commit |
|---|---|
| Public working blobs | 113 source/spec/docs/config/data/policy/license blobs matched HEAD |
| Protected baseline paths | 68 unchanged, including transport/API/client/chat/batch/default config/countries/helpers/license |
| Source changes since baseline | Exactly serializer, AppSettings, MissionsList, Game and CLI root |
| License and ancestry | `LICENSE` blob `0eeb91622aa55c8620447f18c6d6969c54135aae` equal at baseline/HEAD; baseline ancestor check exit 0 |
| Remote preservation limit | Origin and backup names present; URLs not read or independently byte-checked |
| High-risk tracked path inventory | Zero flags, including newly tracked paths; inherited `dumps/.gitignore` excepted |
| Fake-path ignore probes | Eight private paths ignored (exit 0); six public paths eligible (exit 1) |
| Independent isolated ignore spec | 2 examples / 0 failures, empty template and global masks disabled |
| Modes and whitespace | No mode changes; diff whitespace check passed; no failed/pending invariant check |

The filename inventory covers private prefixes/configs, received nested files,
APKs, keys/env/logs and raw dumps. It is **not a content-secrecy proof**.
The isolated ignore check made no source or repository Git writes.

## Limits and next decision

Synthetic offline packets do not prove protocol/catalog completeness or live readiness.
Representative `fingoals`, `missions` and `colres` prerequisites are static mappings
only; minimal session authentication is not sufficient for full catalog/profile/world dependencies.
`autohack` was excluded, not repaired and not executed.
See [catalog limits](catalog-validation.md), [script prerequisites](script-prerequisites.md),
[serializer scope](client-robustness-refactor.md) and [ignore policy](repository-ignore-policy.md).

Global-chat publication remains unresolved: HTTP 200 is not owned-message echo proof,
and corrected-URI live confirmation is not established. No fresh account or send occurred here.
Fresh-account/live-helper D9/D10 remain paused; the helper is not implemented.
The next proposal is a bounded offline fresh-helper build with independent checks,
then separate human approval before any transport gate, account or one World message.
Publication is a separate human choice: local commits do not authorize push, PR,
merge or publication to the creator remote.
