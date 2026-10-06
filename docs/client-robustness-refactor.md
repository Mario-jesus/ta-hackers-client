# Client robustness refactor notes

R1 narrows serializer hardening to input preservation and optional text safety. It does not claim broader script or backend readiness.

## What changed

- `Serializer.normalizeData` now returns a translated copy instead of editing the caller's string.
- `nil` optional text normalizes to `''`, so existing callers can safely call methods such as `.split` on optional normalized values.
- Incoming parser entry points duplicate received data, force it to UTF-8, and scrub malformed bytes before splitting.

## Deliberate limits

- Outgoing message generation is not scrubbed. Invalid outgoing UTF-8 still raises instead of being silently changed.
- Valid outgoing Unicode and delimiter translation remain byte-exact for the serializer delimiters.
- Strict chat response validation, signing, request flags, cursor handling, client configuration, and catalog/domain validators are outside R1 and unchanged.

## Offline verification focus

R1 tests cover frozen and reused strings, nil optional text, delimiter round trips, valid Unicode, malformed incoming bytes, unchanged source strings, outbound preservation, and existing chat/API regressions.
