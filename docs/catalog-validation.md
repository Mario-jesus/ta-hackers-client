# AppSettings validation

AppSettings now publishes a catalog only after the entire supplied settings section parses successfully. Each load first clears the previous raw data, settings, languages and timestamp; failed initial loads or reloads remain unloaded with empty getters and a nil timestamp.

## Packet contract

| Position in section 0 | Required shape |
|---|---|
| Records 0–10 | Nonempty string key at field 1 and string value at field 2 |
| Record 11 | Nonempty string timestamp at field 0, retained verbatim |
| Record 12 (optional) | Language entries `code:ID`: nonempty code, signed or unsigned integer ID |
| Records 13 onward (optional) | Nonempty string key at field 0 and string value at field 1 |

Language and extension records may be omitted. An empty record 12 can reserve the language position before extensions. Supplied malformed optional entries are errors, not default zero IDs. Empty setting values are allowed when represented as an interior field; the existing serializer discards trailing empty fields, so a missing trailing value is rejected. Unused extra columns and sections remain ignored; setting names are not restricted to a whitelist.

Unsigned numeric setting values retain the existing `/^\d+$/` integer coercion; other text is unchanged. Timestamp format and meaning are not validated or converted. Structural failures raise `Hackers::Serializer::ParserError`; API exceptions propagate unchanged. No generic Dataset or Serializer behavior was changed.

## Observed offline checks

- Test-first: 18 AppSettings examples, 15 intended behavior failures before implementation; full-catalog compatibility assertions passed on the old source.
- AppSettings GREEN: 18/0; focused serializer/chat/API/CLI compatibility: 93/0.
- Full suite: 858/0 (840 baseline plus 18 new examples).
- Diagnostic and current-prefix helper self-tests: 24/24 and 10/10; AppSettings Ruby syntax OK.

These synthetic packets establish client parsing/state behavior only, not backend catalog completeness or live script readiness. Initialization ordering remains separate work.

## MissionsList validation

MissionsList invalidates raw data and its mission array before fetching. It builds a local array and publishes only after every row succeeds. Initial failures, invalid reloads, late malformed rows and API failures leave it unloaded with empty enumeration/lookup; API exceptions propagate by identity.

Section 0 must be an array, and each record must be an array with a nonempty string ID matching `/\A[+-]?\d+\z/`. Structural errors raise `Hackers::Serializer::ParserError` with static text and at most a record index, never row contents. A present empty section is valid: the actual packet `@ignored` parses to an empty section 0. Raw nil or empty text has no section and is rejected.

Only the ID is newly constrained. Zero, negative, plus-signed and leading-zero IDs retain `to_i` semantics; duplicates retain first-match lookup and enumeration order. All other numeric coercions, normalized optional text/CSV strings, nullable giver/info/group, Mission members and array storage remain unchanged. ID-only records and trailing omissions retain legacy defaults; this conservative client compatibility is not proof of upstream optionality. No 29-field requirement, numeric ranges, uniqueness rule or mandatory coordinates were added. Successful load still returns the parsed record array, not raw text or a new return shape.

Observed test-first checks: 21 synthetic examples, 15 intended failures before implementation, with six legacy/valid examples passing (including all full-row conversions). Focused MissionsList/AppSettings/Serializer/chat/API/CLI checks: 114/0; full suite: 879/0; helpers: 24/24 and 10/10. Invalid parsed shapes use isolated serializer stubs; present-empty-section evidence uses the real serializer. No backend or received-script execution was used.
