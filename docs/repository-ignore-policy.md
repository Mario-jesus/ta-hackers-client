# Repository ignore policy

The tracked `.gitignore` protects high-risk local artifacts in every clone while keeping public fixtures and project files eligible for review.

## What is ignored

- Private configs and credential-shaped files, including hidden credential variants.
- Local `.env` files, private keys, account state, private notes, and logs.
- Received nested repository copies, APK/AAB artifacts, raw dumps, and local indexes.
- Ruby cache/build outputs that should not be committed.

## What remains trackable

- `configs/default.conf` and existing public data such as `data/countries.conf`.
- Future public data/catalog files under `data/` unless they match an explicit private pattern.
- Source, bins, scripts, specs, docs, ODD task files, and `Gemfile.lock`.
- `.env.example` when it is deliberately maintained as a public template.

## Important Git behavior

Ignore rules only affect untracked paths. They do not remove, untrack, or rewrite files that are already tracked, and they do not replace local-only exclusions in `.git/info/exclude`.
