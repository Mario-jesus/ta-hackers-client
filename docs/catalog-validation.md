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

These synthetic packets establish client parsing/state behavior only, not backend catalog completeness or live script readiness. MissionsList validation and initialization ordering remain separate work.
