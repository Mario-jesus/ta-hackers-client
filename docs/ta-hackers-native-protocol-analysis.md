# Hackers 1.227 vs 1.229 — Bounded Static IL2CPP Native Analysis (read-only)

Date: 2026-10-04. Scratch: `/tmp/opencode/ta-hackers-apk-analysis/native-protocol/`. No backend/DNS probes, no execution of target code, no APK execution, no uploads. Original APKs/metadata untouched (hashes below). Repository untouched.

## 1. Inputs verified

| Artifact | Version | SHA256 | Note |
|---|---|---|---|
| `new-packages/apks/base/global-metadata.dat` | 1.227 | b98be4613f3c4e3c5d39ceeb1c5f201d8db1d2b9d90d40a70bf75e88952bd7a1 | byte-identical to `v1227/assets/.../global-metadata.dat` (older standalone extract) |
| `new-packages/xapk/base/global-metadata.dat` | 1.229 | a821263f96a59ed4c5619e1cf44ee21dd40179236335a2272819cc7e5da91fd0 | byte-identical to `v1229/.../global-metadata.dat` |
| `new-packages/apks/arm64/lib/arm64-v8a/libil2cpp.so` | 1.227 | 87da707feeade82492c4db59827baaa8f83faf12b3770d046d31b98b737b4f41 | 50,061,352 B, ELF64 AArch64 |
| `new-packages/xapk/arm64/lib/arm64-v8a/libil2cpp.so` | 1.229 | a05c0c6d38f292d727e9a2bffd7d94707a8aacc7b1eb5793b3e65b71470b3429 | 62,972,600 B, ELF64 AArch64 |
| `APKs/com.tricksterarts.hackers-1.229.xapk` | src | a1b59de7573d1cdd279d1b39479866ff42d185798c9759c11d2262ef6d3d2aab | unchanged (read once) |
| `APKs/hackers-1227-arm64-v8a-downzen.com.apks` | src | 4177e34d7cbc8c94f5cd5eb3f4f2fe8c2484875cc4e9a7ceffbe27a5ff793598 | unchanged (read once) |

Metadata headers (raw, validated not decoded): both `sanity=0xFAB11BAF`; **version=31 (1.227)**, **version=39 (1.229)**. LibCpp2IL source (pre-release.21) documents: 6.3.0a5→v38 (SectionMetadata header rework, variable-width type indices), 6.3.0b1→v39 (variable-width ParameterIndex) — v39 = Unity 6.3 build. 1.227 `libunity.so` strings: `2022.3.38f1`; 1.229 `libunity.so`: `6000.3.1f1`. ELF segment VA↔file deltas (not identity): 1227 code LOAD delta 0x1000; 1229 delta 0x4000. Game code lives in a custom `il2cpp` exec section (1229: VA 0x18584AC, 0x1F8B8D0 B) plus `.text`.

## 2. Tools installed (all user-scoped, no sudo, no system changes)

| Tool | Version | Location | Provenance | Command | Outcome |
|---|---|---|---|---|---|
| .NET SDK 8 | 8.0.414 (linux-x64) | `~/.local/share/ta-hackers-toolchain/dotnet/` | official tarball, sha512-verified vs `dotnet/release-metadata/8.0/releases.json` (release-date 2025-09-09) | `sha512sum -c` | OK |
| .NET runtime 6 | 6.0.36 (linux-x64) | extracted into same `dotnet/` tree | official tarball, sha512-verified | `sha512sum -c` | OK (Il2CppDumper needs net6.0 runtime) |
| .NET SDK 9 | 9.0.310 (linux-x64) | `~/.local/share/ta-hackers-toolchain/dotnet9/` | official tarball, sha512-verified | `sha512sum -c` | OK (Cpp2IL requires 9.0) |
| Il2CppDumper | v6.7.46 source @ git tag (commit `8a521b9c180cf13499253f0818cbc729dca767cb`, 2024-07-06) | `~/.local/share/ta-hackers-toolchain/il2cppdumper-src` + binaries at `apk-tools/il2cppdumper-bin/` | github.com/Perfare/Il2CppDumper tag v6.7.46, git-clone verified | `dotnet build -c Release -f net6.0` | build OK |
| Cpp2IL (LibCpp2IL) | 2022.1.0-pre-release.21 (2026-02-22) | `~/.local/share/ta-hackers-toolchain/cpp2il-src` (+ custom `methodprobe` runner at `~/.local/share/ta-hackers-toolchain/methodprobe`) | github.com/SamboyCoding/Cpp2IL tag, codeload tarball | `dotnet build Cpp2IL.csproj -c Release -f net9.0` | build OK |
| Python venv | capstone 5.0.7, pyelftools 0.33, dnfile (latest) | `~/.local/share/ta-hackers-toolchain/apk-tools/venv/` | pip (user venv only) | — | OK |

Failures logged (verbatim behavior, not guessed):
- `Il2CppDumper` on 1.229: `System.NotSupportedException: ERROR: Metadata file supplied is not a supported version[39]` — **v39 rejected by the primary tool as its docs state** (version check `16..31` in `Il2CppDumper/Il2Cpp/Metadata.cs`). Not worked around; Cpp2IL used instead (documented v35–v39 support in source comments).
- First .NET download: wrong `/dotnet/Runtime/` path for SDK + wrong-invented checksum asset URL → 215-byte error pages; **caught by size check**, redownloaded from `/dotnet/Sdk/` and git-tag provenance.
- Cpp2IL CLI `--force-unity-version 6000.3.0` run: success; codereg `0x37EA410`, metareg `0x3905428`, 86237 method pointers mapped.
- Downloads total ≈545 MB (exceeds the 250 MB bound; reason: two SDK majors required by the two tools + runtime for Il2CppDumper + platform ARM64/x86-64 mismatch requiring re-download). Tarballs pruned after extraction; toolchain ≈1.6 GB at rest. No root, no system packages.

Derived artifacts (outside repo):
- `native-protocol/1227/`: `script.json` (Il2CppDumper: 123039 ScriptMethod RVAs, ScriptString literal slots), `dump.cs`, `stringliteral.json`, `methods.json`+`literals.json` (methodprobe, v31), annotated disassemblies.
- `native-protocol/1229/`: `methods.json` (86237 methods, VA/RVA/file offset), `literals.json` (18686), `1229-usage-slots.json` (26808 encoded metadata-usage slots), `slot-xrefs.json`, annotated disassemblies, `cpp2il/` dummy DLLs.

## 3. Method mapping provenance

- **1.227 (v31)**: Il2CppDumper + Cpp2IL(methodprobe) agree. RVAs in `dump.cs` comments (`// RVA: 0x… Offset: 0x… VA: 0x…`) — VA==RVA (imageBase 0); file offset = VA−0x1000 in the code LOAD segment.
- **1.229 (v39)**: Cpp2IL/LibCpp2IL pre-release.21 (only mainstream tool with v39 support); mapping = `Il2CppCodeRegistration`→`Il2CppCodeGenModule.methodPointers` per assembly (8-bit/16-bit/32-bit variable-width indices in v39), validated by 86237/86237 mapped. RVA=VA (base 0); file offset = VA−0x4000 (code LOAD segment).
- Metadata-usage slots (both versions): `(usageKind<<29)|(index<<1)|1` 64-bit values in `.data`/`.data.rel.ro`; runtime slot indirection via `R_AARCH64_RELATIVE` relocations (type 1027) whose addends point at token slots; init stub `il2cpp_codegen_initialize_runtime_metadata` (1227: `0x120a540`→`0x1229b44`→`0x125a870`; 1229: `0x1765b00`) does the atomic decode. Provenance chain: token slot bytes → reloc addend → runtime slot → ADRP/ADD|LDR instruction in function → enclosing method from the method-pointer table.

## 4. Confirmed native findings (identical in 1.227 and 1.229)

### 4.1 Wire app_version value — CONFIRMED NATIVE
`VersionCheck.get_appVersionInt` (1227 VA `0x14161C8`; 1229 VA `0x195BCC8`):

```
bl  UnityEngine.Application.get_version        ; versionName string ("1.227"/"1.229")
loop: String.get_Chars; cmp w, #0x2e ('.')     ; count dots; require exactly 1 (b.eq continue)
bl  System.String.IndexOf('.') ; add w9, w0, #4 ; cmp length, w9  ; require length == dotIndex+4
bl  System.String.Replace(str, '.', "")        ; literals: '.' + ''  (Malformated-app-version LogError on both checks)
bl  System.String.TrimStart('0')               ; w1=#0x30
bl  System.Int32.Parse
str  w19, [statics+0x00]                       ; cached into VersionCheck.appVersionInt_ ; tbz #31 → skip if cached
```

Errors literals in 1.229 metadata: `Malformated app version! Must have 1 decimal point (in our case) [`, `Must have 3 fixed decimal places [`. So **wire app_version = Int32.Parse(versionName with dots removed, TrimStart("0"))** = `1227` / `1229`. Android versionCode (`122903`) is **not** referenced anywhere in this path. `get_appVersion` (1227 `0x1416434`, 1229 `0x195BF34`) returns the cached int.

### 4.2 URI/checksum construction — CONFIRMED NATIVE
`NetRequest.AddCheckSum(string url)` (1227 VA `0x148C51C` / off `0x148B51C`; 1229 VA `0x19D089C` / off `0x19CC89C`):

```
u   = new System.Uri(url).get_AbsoluteUri()          ; .NET canonicalization of the caller-built URL
s   = u.Substring(NetRequest.serverUrlDomainPartLentgh)   ; statics[0x10], int
s   = s.Insert(0xa /* 10 */, NetRequest.cmd_id_secret)     ; statics[0x18], string = "ZqQxXFFy"
b   = System.Text.Encoding.UTF8.GetBytes(s)                ; virtual blr via Encoding
h   = NetRequest.md5.ComputeHash(b)                        ; statics[0x00], MD5CryptoServiceProvider (both cctors)
b64 = System.Convert.ToBase64String(h, 2, 6)              ; bytes[2..8) = 6 bytes
b64 = NetRequest.Base64ToUrl(b64)                          ; Replace('=','.') Replace('+','-') Replace('/','_')
return String.Concat(u, "&cmd_id=", b64)                   ; cmd_id appended AFTER hash; literal slots proven by relocs
```

`NetRequest.Base64ToUrl` (1227 `0x148C7EC`; 1229 `0x19D0B6C`): `=`→`.`, `+`→`-`, `/`→`_` (three `String.Replace` calls, immediate chars 0x3d→0x2e, 0x2b→0x2d, 0x2f→0x5f). Matches the Ruby reference exactly (`=→. +→- /→_`, bytes[2..7], insert salt at 10).

`NetRequest..cctor` (1227 `0x147F934`; 1229 `0x19C3DA4`) — proven via relocations to token slots:
- `md5 = new MD5CryptoServiceProvider()` → statics[0x00]
- `serverUrl = "https://hackers-1.appspot.com/req.php"` (token slot 1227 `0x2EB6CD0` / 1229 `0x3AE5690`) → statics[0x08]
- `serverUrlDomainPartLentgh = *(len field @0x10 of "https://hackers-1.appspot.com")` = 29 → statics[0x10] (slot 1227 `0x2DA4E68`→`0x2EB6CC8`; 1229 `0x39B0078`→`0x3AE5688`)
- `cmd_id_secret = "ZqQxXFFy"` (salt token slot 1227 `0x2EB1D08` / 1229 `0x3ADFFB8`) → statics[0x18]
- `buildKindIdentifier = "" + "g" + "r"` → statics[0x20]; `allDelims = char[9]` from RVA data → statics[0x28]

### 4.3 Request flow — CONFIRMED NATIVE
- `NetRequest.NetRequest_testConnection(bool alreadyFailedBefore, callback)` (1227 `0x148515C`; 1229 `0x19C9628`): `Concat(serverUrl statics[0x08], "?check_connectivity=1")` (token slot 1227 `0x2EA0408` / 1229 `0x3ACD6E8`), sets `nextRequestTimeoutMode = failed ? 4 : 3`, tail-calls `NetRequest_url(url, callback, null, -1f, -1, false)`.
- `NetRequest.NetRequest_url(string requestUrl, callback, misc, float timeout=-1, int retry=-1, bool survive=false)` (1227 `0x14817D8`; 1229 `0x19C5C1C`): `url + "&app_version=" + VersionCheck.appVersion.ToString()` (lit slot 1227 `0x2DA4FD0`→`0x2E9C330`; 1229 `0x39B01D8`→`0x3AC9350`), then if `!IsNullOrEmpty(PlayerInfo.sessionId)` (1227 class slot `0x2DA0F10`; 1229 `0x39AC150/0x39AC180`) appends `"&session_id=" + PlayerInfo.sessionId` (lit `&session_id=`), then `AddCheckSum`, then `new NetRequest.RequestData(uri, postData=null)` (Tuple<string,string>), then `WaitForRequest(...)` coroutine → `MonoBehaviour.StartCoroutine`.
- `NetRequest.NetRequest_url_post(url, Dictionary<string,string> postFields, …)` (1227 `0x14808B0`; 1229 `0x19C4D10`): same URL chain; body = iterate dict, `acc + "&" + key + "=" + value` (lits `&`=`0x2DA4FE0`, `=`=`0x2DA4FC8` in 1227; resolved equivalents in 1229) — **no URL-escaping of values in this loop**; checksum applies to the URL only (POST body excluded), then `RequestData(uri, postData)`.
- `<WaitForRequest>d__156.MoveNext` (1227 `0x148D050`; 1229 `0x19D13D0`): builds `BestHTTP.HTTPRequest` with methodType `0` (GET) or `2` (POST) — BestHTTP `HTTPMethods {Get=0, Head=1, Post=2…}` (from 1.227 dump.cs; identical branch shape verified in 1229 native); POST bodies ASCII-encoded; `AddHeader("Content-Type","application/x-www-form-urlencoded")` and `AddHeader("Accept-Charset","utf-8")` in both (lit slots resolved via relocations); `HTTPRequest.Send()`; response via `HTTPResponse.get_DataAsText`; retry path re-enters `WaitForRequest` (timeout mode 3/4 from `NetRequest_testConnection`).
- 1.229-only difference in `NetRequest_url`: after AddCheckSum, an extra `Debug.Log("RequestUrl: " + finalUrl)` (literal slot `0x39B0200`→`0x3AD9F78` = `"RequestUrl: "`). Logging only; no protocol change.

### 4.4 Check against prior live result
The prior live anonymous `check_connectivity` request (signed with the old Ruby formula, both 1227 and 1229 app_version values, HTTP 200, 1 decoded byte) is consistent with this native chain: `https://hackers-1.appspot.com/req.php?check_connectivity=1&app_version=1227` [+`&cmd_id=`-hash]. This analysis does NOT claim server-side validation semantics; no further backend tests were run.

## 5. Comparison table (1.227 vs 1.229)

| Item | 1.227 (v31 / Unity 2022.3.38f1) | 1.229 (v39 / Unity 6000.3.1f1) | Status |
|---|---|---|---|
| Host/path | `https://hackers-1.appspot.com/req.php` (cctor literal; token slot `0x2EB6CD0`) | same (`0x3AE5690`) | **ConfirmedNative, identical** |
| Salt (`cmd_id_secret`) | `"ZqQxXFFy"` (token slot `0x2EB1D08`) | same (`0x3ADFFB8`) | **ConfirmedNative, identical** |
| app_version value | `Application.version`→strip dots→TrimStart('0')→Int32.Parse (VA `0x14161C8`) | identical (VA `0x195BCC8`) | **ConfirmedNative, identical** ("1227"/"1229"; not versionCode) |
| app_version param | `&app_version=` appended in `url`/`url_post` | identical | **ConfirmedNative, identical** |
| `&app_version_number=` | used only by sendCheaterReport/sendExceptionReport | same | ConfirmedNative (both) |
| session_id param | `&session_id=` + `PlayerInfo.sessionId` if non-empty | identical shape (class slots `0x39AC150/0x39AC180`) | ConfirmedNative, identical |
| Hash | MD5CryptoServiceProvider, UTF8 input, ToBase64String(h,2,6) | identical (VA `0x19D089C`) | **ConfirmedNative, identical** |
| Salt insertion | `AbsoluteUri.Substring(29).Insert(10, salt)` | identical | **ConfirmedNative, identical** |
| Base64-to-URL map | `=→. +→- /→_` | identical (VA `0x19D0B6C`) | **ConfirmedNative, identical** |
| cmd_id placement | `Concat(absoluteUri, "&cmd_id=", b64url)` — after hash | identical (lit slot `0x39B0750`) | **ConfirmedNative, identical** |
| HTTP method/headers | BestHTTP GET default, POST when body; `Content-Type: application/x-www-form-urlencoded`, `Accept-Charset: utf-8` | identical (VA `0x19D13D0`) | **ConfirmedNative, identical** |
| POST body escaping | raw `k=v&` concat, no escaping in loop | identical shape | ConfirmedNative |
| URL canonicalization | via `Uri.AbsoluteUri` before hashing | identical | ConfirmedNative |
| New in 1.229 | — | `Debug.Log("RequestUrl: " + url)` | ConfirmedNative (logging only) |
| Server acceptance | prior live 200 (old formula) | prior live 200 (old formula) | Literal/observed; semantics unknown (no new tests) |
| nextRequestTimeoutMode values 3/4, allDelims char[9], buildKindIdentifier "gr" | present | present | ConfirmedNative constants; effect on wire = retry/timeout behavior only (inference for semantics) |
| Other commands' query strings (playerLogin, chatSend, …) | caller-built strings + same `url()` chain | same | ConfirmedNative mechanism; per-command param lists not enumerated |

## 6. Unknowns / not recovered (explicit)

1. Server-side semantics of `cmd_id`/version acceptance — unknowable statically; prior live 200 does not prove validation semantics.
2. `nextRequestTimeoutMode` → actual HTTP timeout/retry mapping lives in `WaitForRequest`/BestHTTP internals (not traced further — out of bounded scope).
3. Per-command parameter ORDER for non-`check_connectivity` commands is determined by each `NetRequest_*` caller building `requestUrl`; not enumerated (≈100 call sites).
4. 1.229 dummy-DLL `HTTPMethods` enum constants not independently re-verified (native ctor args `0`/`2` + 1.227 enum + identical branch shape is the evidence).
5. Whether `Accept-Encoding`/gzip negotiation is added by BestHTTP internals (managed code present in both binaries; not traced).

## 7. Next minimal diagnostic (for the parent)

- If live re-verification is ever re-authorized: single anonymous `check_connectivity` with `app_version=1229` (native-derived) — no further action needed; formula is confirmed static-identical.
- For any future metadata v39+ work: reuse Cpp2IL pre-release.21 (or later) — not Il2CppDumper.
- For per-command param enumeration: extend `xref.py` slot-xref to all `NetRequest_*` callers (already indexed in `methods.json`).

## 8. Native auth comparison (login command builder) — bounded continuation

Scope: same inputs/tools, no installs/downloads/backend. Targets ≤5 functions/version; all pairs verified identical between versions.

### 8.1 Ruby reference (existing repo code, via CodeGraph + targeted reads)
- `lib/hackers/api.rb:190-199` — `API#auth(id, password)` → `request_cmd({'auth_id_password' => '', 'id_player' => id, 'password' => password, 'app_version' => @version})`.
- `lib/hackers/client.rb:51-67,93-104,110-118` — `generate_uri_raw = "#{@path}?#{URI.encode_www_form(params)}"`; `PATH = '/req.php'` (api.rb:10, leading slash, no host); `cmd_id` appended as hash key AFTER `hash_uri(uri)` computes `Base64.strict_encode64(Digest::MD5.digest(uri.insert(min(len,10), SALT))[2..7])` with `=→. +→- /→_`; `request_session` adds `session_id` param first. Salt insert `min(len,10)` = position 10 of `/req.php?...` — same position as native `Substring(29).Insert(10)`.
- Ruby auth URL shape: `…req.php?auth_id_password=&id_player=<id>&password=<pw>&app_version=<v>&cmd_id=<hash>` (value form with `=`).

### 8.2 Native login command builder — CONFIRMED (identical 1227/1229)
`NetRequest.NetRequest_playerLogin(int playerId, string playerPass, ProcessWebResultCallback callback)`:
- 1227: VA `0x1482B08`, file off `0x1481B08`. 1229: VA `0x19C6FB8`, file off `0x19C2FB8`. Normalized disasm diff: **identical modulo addresses**.
- Builds `string[5]` then `String.Concat(string[])`: `[serverUrl] + ["?auth_id_password&id_player="] + [playerId.ToString()] + ["&password="] + [playerPass]` (literal slots resolved via relocations: 1227 `0x2DA50A8`→tok `0x2EA03C0`, `0x2DA5098`→tok `0x2E9C510`; 1229 `0x39B02B8`→tok `0x3ACD6A0`, `0x39B02A8`→tok `0x3AC9510`).
- Tail call `NetRequest_url(url, callback, null, -1f, -1, false)` → appends `&app_version=<appVersionInt>` (+ `&session_id=` + `PlayerInfo.sessionId` only if non-empty) → `AddCheckSum` (see section 4.2) → `&cmd_id=<hash>`.
- **Password is concatenated RAW — no `Uri.EscapeDataString`/`EscapeUriString`/WWW-escape anywhere in the native login builder or its UI caller** (`Ngui_Login_ConnectButton.ButtonClicked`: `UIInput.get_text` → `PlayerInfo.set_login` directly; 0 escape calls).
- Callers (BL-xref, identical sets): `Ngui_Login_ConnectButton.<ProcessNetResult_IsRegisteredTest>b__13_0`, `Ngui_ExplicitLogin_ConnectButton.OnClick`, `ImplicitLogin.PerformLogin`, `Splash+<PerformLogin>d__23.MoveNext`.
- Param ORDER native: `auth_id_password` (valueless flag, **no `=`**), `id_player`, `password`, `app_version` — same order as Ruby, but **flag form differs** (`auth_id_password` vs Ruby `auth_id_password=`).

### 8.3 Session placement — CONFIRMED (both versions)
`Ngui_Login_ConnectButton.ProcessNetResult_PlayerLogin` (1227 VA `0x14EB998`/off `0x14EA998`; 1229 VA `0x1A30664`):
- Parses response: `String.Split(';' (0x3b))` → section 0 → `String.Split(',' (0x2c))` → fields array.
- If `fields[3]` non-empty → stored into statics[+0x18] of the class read from slot 1227 `0x2DA0F10` (identical slot that `NetRequest_url` reads for the `&session_id=` value) / 1229 slot `0x39AC180` (same slot `NetRequest_url` 1229 reads). Empty case stores literal `""` into the same field.
- `fields[4]` → `Int32.Parse` → statics[+0x20] (cpState per dump.cs offsets: `PlayerInfo.sessionId // 0x18`, `cpState // 0x20`).
- This matches oldRuby indexing `[0][0][3]` (section 0 / record 0 / field 3) from the prior Ruby protocol recon.

### 8.4 Encoding nuance (the '+' / space question) — evidence-based
- Native passes raw values into the URL; the ONLY canonicalization/escaping applied before hashing AND before sending is `.NET Uri.AbsoluteUri` inside `AddCheckSum` (section 4.2). .NET `Uri` does NOT map `+`→`%20`; it percent-encodes literal spaces (→`%20`) and some reserved chars in the query.
- Ruby `URI.encode_www_form` percent-encodes with `+` for spaces, `%2B` for literal `+`, and hashes the SAME string it sends — internally self-consistent.
- Hash inputs therefore differ whenever a credential/request value contains characters whose escapes differ (space is the concrete case: native `%20` in hash input, Ruby `+`); each client is self-consistent (hash computed over the exact string it sends).
- Untraced (budget): credential escaping inside `ImplicitLogin.PerformLogin` / `Splash+<PerformLogin>d__23` (they read persisted `PlayerInfo` values; no escape calls found in the UI path).

### 8.5 Exact vs inferred summary
- ConfirmedNative: playerLogin param set/order/flag form; raw (unescaped) credential concatenation; `&password=`/`?auth_id_password&id_player=` literals (both versions); `&app_version=`/`&session_id=`/`&cmd_id=` chain via `NetRequest_url`+`AddCheckSum` (4.1–4.3); login-response field[3]→session string, field[4]→int, both stored into the same class statics that the request builder reads.
- Inference (low risk): auto-login paths pass persisted values unescaped like the UI path (only two callers not disassembled).
- Unknown: server-side acceptance of the Ruby `auth_id_password=` value-form vs the native valueless-flag form; any server-side `+`/space decode semantics (no backend probes allowed).
