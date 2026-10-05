# Client compatibility checks — offline alignment and bounded external observations

## Summary

Implemented and verified in two layers: **offline**, the client's protocol
version **1229** default and the valueless `auth_id_password` login flag
(no `=`) match the confirmed native 1.227/1.229 derivation, with credential
form encoding intentionally retained (`URI.encode_www_form`) — proven by
**721 examples, 0 failures**, independently re-verified; credential reserved
characters remain form-encoded and the synthetic injection cases passed
(this is not a universal injection-proof claim)). **External**, a separately
authorized fresh round of 4 anonymous catalog probes (2026-10-05) completed
**all selected sanity checks** — per-command counts, levels and gzip
transport are recorded in
[startup-catalog-verification.json](startup-catalog-verification.json).
**T8 live (2026-10-05)** — after explicit user authorization, a one-shot
own-account functional test ran live against the current backend: **one
account created, login authenticated with a real session, and the public
World 999 chat read returned 27 messages** — 3 requests attempted, 3
observed, all HTTP 200 (creation/auth/chat). The server **accepted the
valueless `auth_id_password` flag**, closing the previous "server acceptance
of the login flag remains unproven" unknown. Full report:
[account-chat-checks.md](account-chat-checks.md), source-of-truth record
[account-chat-verification.json](account-chat-verification.json). Native
server-side validation semantics remain unknown.

## What changed (T5, offline)

| Area | Decision |
|------|----------|
| Protocol version | `API::VERSION` (`lib/hackers/api.rb`) and `configs/default.conf` → `1229`, from the confirmed native `VersionCheck.get_appVersionInt` derivation (`Application.version` dots removed, `TrimStart('0')`, `Int32.Parse`). |
| Login flag | `API#auth` sends `auth_id_password` as a valueless flag (`nil` value; `URI.encode_www_form` emits the bare key, no `=`), matching the native `NetRequest_playerLogin` shape. |
| Credential escaping | Intentionally retained: values keep `URI.encode_www_form`; reserved characters remain form-encoded (space→`+`, `+`→`%2B`, percent escapes) and the synthetic injection cases passed. **Not** byte-identical to native reserved-char output; the native raw concatenation was deliberately **not** copied. |
| Everything else | Salt, host/path, hash parameters, and all other commands are untouched. |

## Verification (offline, isolated Ruby 3.3.12 / Bundler 2.6.9)

Exact reproducible commands (full toolchain prefix in every line):

```bash
source ~/.local/share/ta-hackers-toolchain/env-ruby33.sh
~/.local/bin/mise exec ruby@3.3.12 -- ruby "$GEM_HOME/bin/bundle" _2.6.9_ exec rspec spec/api_spec.rb
~/.local/bin/mise exec ruby@3.3.12 -- ruby "$GEM_HOME/bin/bundle" _2.6.9_ exec rspec --format progress
~/.local/bin/mise exec ruby@3.3.12 -- ruby -c lib/hackers/api.rb
~/.local/bin/mise exec ruby@3.3.12 -- ruby -c spec/api_spec.rb
~/.local/bin/mise exec ruby@3.3.12 -- ruby -rjson -e 'p JSON.parse(File.read("configs/default.conf"))["version"]'
git diff --check
```

Observed results:

| Stage | Result |
|-------|--------|
| Historical baseline (pre-T5, T1/T2 stage) | `695 examples, 0 failures` |
| RED (new spec first, pre-change code) | `26 examples, 11 failures` — version defaults (×3), valueless flag, auth wire, frozen cmd_id, 4 catalog fixtures + connectivity |
| GREEN (after the 3-line implementation) | `26 examples, 0 failures` |
| Full suite after T5 (writer run) | `721 examples, 0 failures` (695 + 26 new) |
| **Independent verification (separate actor, T7)** | full suite `721 examples, 0 failures`; `ruby -c` OK for `lib/hackers/api.rb` and `spec/api_spec.rb`; JSON config version `1229`; `git diff --check` clean; `Gemfile.lock` unchanged; an independent MD5 recomputation reproduced **all 7 frozen cmd_id fixtures**; **no source issues found** |

Stub-scope qualifier (writer and independent runs): the recorder replaces
**only** `Client#request_raw`; `request_cmd`, URI generation, parameter
ordering and the hash pipeline execute real, unmocked code. No request leaves
the process.

Test coverage in `spec/api_spec.rb` (26 examples, fully offline):

- Default `API::VERSION`/`configs/default.conf` = 1229; version override (1227)
  and arbitrary custom version flow through without hardcoding.
- Auth request: exact parameter order (`auth_id_password`, `id_player`,
  `password`, `app_version`, `cmd_id`), valueless flag (no `=`), dummy
  credentials only.
- Credential escaping: space→`+`, `+`→`%2B`, `&`/`=`/`#`/unicode percent-
  escaped; no query-parameter injection from credential content.
- Session ordering: `session_id` is inserted before `cmd_id` (representative
  read-only sessioned command); auth (unsessioned) carries no `session_id`.
- Signature: recorded `cmd_id` matches both a frozen independently computed
  fixture and an in-spec reference calculation of the documented in-repo hash
  (salt at offset 10, MD5, Base64 bytes 2..7, `=→. +→- /→_`).
- Public catalog command shapes (see below) with no HTTP calls.

## T6 bounded catalog probes — fresh authorized round (COMPLETE)

The user explicitly selected the bounded fresh round; the parent prepared
and corrected an **outside-app** helper and executed it live. The result is
direct actual terminal JSON (not opaque actor reporting): exit 0,
`total_requests: 4`, all four commands HTTP 200 gzip at the approved
`hackers-1.appspot.com/req.php` endpoint, **all selected sanity checks
passed** (`sanity_ok: true`). Source of truth, copied verbatim into
[startup-catalog-verification.json](startup-catalog-verification.json)
(timestamp `2026-10-05T06:39:36Z`, runtime Ruby 3.3.12, top-level `ok:
true`; no payload hashes — the JSON is the record).

| Command | HTTP | Encoding | Raw→decoded bytes | Sections | Raw records | Model records | Selected checks |
|---------|------|----------|-------------------|----------|-------------|---------------|-----------------|
| `language_translations` (en) | 200 | gzip | 23039→57955 | 1 | 703 | 703 | records≥1; non-empty string keys; ≥1 non-empty string value |
| `app_settings` | 200 | gzip | 347→484 | 1 | 19 | 17 | keys≥12; datetime present; languages≥1 (**16 languages**) |
| `node_types` | 200 | gzip | 7542→23411 | 3 | 570 | 18 | nodes==**18**; names non-empty; levels≥1 per node (324 level records) |
| `program_types` | 200 | gzip | 8363→26265 | 2 | 484 | 22 | programs==**22**; names non-empty; levels≥1 per program (462 level records) |

What this proves and what it does not:

- The selected structural checks completed and passed: translation **703
  keys** (all keys non-empty + at least one non-empty string value — **not**
  703 fully validated translated strings); settings **17 keys / 16 languages
  / datetime present** (no full semantic validation of every setting); node
  **18 fixed types** and **22 programs** with non-empty names and ≥1 level
  each. This is **not** full field-schema, cost or ability correctness.
- No cookie, auth, or session was used; only public catalogs — public
  catalog working does **not** prove authentication, full game
  functionality, client-side or server strict-signature validation.
- Round budget: fresh 4 requests done; **no extra requests planned**.
- Helper correction (before the round, offline only): the parent caught a
  known valid-`text/html` rejection, the translations key/pair emission
  difference, and the TLS getter (`use_ssl?` vs `use_ssl=`), then added
  `sanity_for` functions and a TLS-configuration (zero-connections)
  self-test; final syntax OK and 12 offline checks passed with
  `total_requests: 0`. A pre-live configuration failure emitted
  `NoMethodError` with `total_requests: 0` — **no HTTP budget was spent**.
  No app source edits were made during helper correction; the 721-example
  offline proof is unchanged.

Helper reproduction (only if the path still exists —
`/tmp/opencode/ta-hackers-catalog-check.rb` **may be ephemeral** and is
**not** a committed evergreen helper; running the live mode again is
**not** an automatic permission and needs explicit renewed authorization):

```bash
ruby -c /tmp/opencode/ta-hackers-catalog-check.rb   # syntax check
# self-test: the helper's offline self-test mode (no network; total_requests 0)
# live mode: the helper's --live mode flag, as recorded in the JSON "mode" field
```

### Historical first round (kept separate, unchanged)

The initial 4-request round's shape/count checkers all failed with
`NameError: uninitialized constant Serializer` (unqualified reference; the
repo class is `Hackers::Serializer`), so its counts/schema-sanity were never
captured and compatible-model parsing was not verified then. Its byte
observations (translations 23039→57955, app_settings 346→484, node_types
7542→23411, program_types 8355→26265) came from retained inline probe
records plus the persisted pre-handoff Engram record #1027 —
metadata-supported, not independent full-packet proof. The actor's initial
final handoff was incoherent and is withdrawn; no payload digests are
recorded (a mangled program hash in the audit), and the old hash-audit token
is **not** claimed valid. That round remains historical partial evidence.

## Verification task status

| Task | State |
|------|-------|
| T5 offline alignment | Done (checked) — implementation + tests above |
| T6 catalog probes | **Complete** — user-authorized fresh round (2026-10-05): 4/4 requests, all selected sanity checks passed; first partial round preserved separately above |
| T7 report + independent verification | Documentation/independent portion done (this document); recovery mirror prepared |
| T8 own-account functional test | **Complete (2026-10-05, user-authorized)** — one account created, session obtained, public chat read 27 messages; 3/3 HTTP 200; details in [account-chat-checks.md](account-chat-checks.md) |
| Native review (T2 scope) | **Pending** — consent not granted, no transaction; pending ≠ approval |

Native review status detail: native review mode is on; a preflight step
blocked the intended untracked structured selection, and the previous schema
is not available from status/help output, so no review payload can be
invented. The current candidate has changed since, so a **fresh status check
is required later**. No review consent has been granted, no review
transaction has been started, and no automatic kill-switch resolution is
applied.

## Evidence links

- [startup-catalog-verification.json](startup-catalog-verification.json) — verbatim direct-terminal JSON of the fresh authorized T6 round (source of truth; no payload hashes).
- [account-chat-checks.md](account-chat-checks.md) — T8 live report (2026-10-05): one account created, session obtained, public chat read 27 messages; redacted JSON record at [account-chat-verification.json](account-chat-verification.json).
- [ta-hackers-native-protocol-analysis.md](ta-hackers-native-protocol-analysis.md) — bounded static IL2CPP derivation evidence (165-line verbatim copy, sha256 `ce77ef26c0857841c926de3769af5f58369067a6d2cbe9c2e1cce1bc571a74ec`, byte-identical).
- [ta-hackers-protocol-analysis.md](ta-hackers-protocol-analysis.md) — earlier dated follow-up, including the 2 bounded anonymous `check_connectivity` probes (1227 and 1229, both HTTP 200 gzip).

Explicit limits — do not over-read:

- **No authentication was tested.** No real credentials, no session
  establishment, no receipts. The valueless-flag alignment is byte-level
  request-construction evidence only; native server-side validation semantics
  remain unknown.
- The `+` vs `%20` space-encoding difference between this client and the
  native client remains a documented client-vs-native difference, not proof
  of server-side failure or acceptance.
- The in-repo hash fixtures prove internal consistency of this repository's
  formula; they are not a native cross-proof.
- The fresh T6 round proves the selected structural checks (record counts,
  key/name presence, level presence, datetime, languages) for the four
  public catalogs — **not** full field-schema, cost or ability correctness,
  and **not** authentication, full-game functionality, or server
  strict-signature validation.
- **Historical T5/T6 limits (kept for context; superseded in part by T8 where
  noted):** before T8, no session existed and server acceptance of the login
  flag was unproven; the `+` vs `%20` space-encoding difference between this
  client and the native client was a documented client-vs-native difference,
  not proof of server-side failure or acceptance. **T8 (2026-10-05) showed
  server acceptance of the current user-facing login flow with HTTP 200, a
  real session, and a 27-message chat read.** What T8 does **not** prove: it
  used the low-level `API#auth` directly (the high-level CLI wrapper
  `Game#auth` / mission/profile parser was not executed), and it is not
  server strict-signature validation, full-CLI, entire-model-set, combat,
  market, or social-auth proof. The in-repo hash fixtures still prove only
  internal consistency of this repository's formula, not a native cross-proof.
- Reserved characters remain form-encoded and the synthetic injection cases
  passed; this is not a universal injection-proof claim.

## Next step

The previous T6 human decision is **resolved**: the user explicitly selected
the bounded fresh round and it was executed successfully on 2026-10-05 (see
above); the retry menu previously recorded here is removed.

Likely next step — **not now and not by this writer**: the T8 account now
exists and is owned by the user; a possible follow-up is bounded **read-only
profile/network/console integration** reusing that created test account,
only after the user explicitly confirms the scope. Reuse only — never
duplicate creation (the exclusive attempt ledger refuses reruns).

Native review (T2 scope) remains **pending**: consent not granted, no
transaction started, pending ≠ approval. No native lifecycle command was run
for this update.

## Rollback scope

Revert exactly three edits: `VERSION = 1229` → `1227` in
`lib/hackers/api.rb`, `"version": 1229` → `1227` in `configs/default.conf`,
and `'auth_id_password' => nil` → `''` in `API#auth`; then delete
`spec/api_spec.rb` and this document. No other files are involved; T1's
client transport changes are separate and unaffected.
