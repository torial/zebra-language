# Zebra Stdlib Gap Audit — Zig 0.15.2 vs Current Zebra

**Audited:** 2026-05-06 (atomics reasoning corrected 2026-05-06: Chan(T) confirmed in 0.14 roadmap)  
**Sprints 1–5 implemented:** 2026-05-06 — All Tier 1 and Tier 2 items (except DateTime.timestamp) now shipped. Bootstrap 5/5, 62/62 smoke tests pass.  
**Method:** Read `src/CodeGen.zig` (all `gen*Call`/`gen*Method` functions), `src/Builtins.zig`, `STDLIB_ROADMAP.md`, and key Zig stdlib sources (`std/math.zig`, `std/mem.zig`, `std/ascii.zig`, `std/base64.zig`, `std/unicode.zig`, `std/hash/*.zig`).

**What Zebra currently has:**
- **Math:** sin/cos/tan/asin/acos/atan/atan2, sqrt/exp/pow/cbrt, log/log2/log10, floor/ceil/round/trunc, abs/min/max/clamp, isNaN/isInf
- **String methods:** contains/startsWith/endsWith/indexOf/lastIndexOf(?)/substring/replace/split/join/lines/bytes/chars, trim/trimLeft/trimRight, upper/lower, toHex/fromHex, toInt/toFloat/format, isAlpha/isNumeric/isValidUtf8/codePointCount, reverse/repeat/concat, padLeft/padRight/center, isEmpty/count
- **File:** read/write/append/delete/rename/copy/exists/readLines/modtime
- **sys:** args/exit/err/errln/getenv/run/sleep
- **Hash:** sha256/sha512/md5/blake3/hmac256
- **Random:** randInt/randFloat/randBool/bytes/seed/choice/shuffle
- **DateTime:** now/fromEpoch/of + addDays/addHours/addMinutes/addSeconds/addMonths/addYears/before/after/equals/daysBetween/secondsBetween/toEpoch/toIso8601/format/inCalendar
- **Other modules:** Base64 (missing), Unicode (missing), Dir/Path, Uri, Http/Tcp/Udp, Compress (partial), Mime, Timer, Progress, Profile, Log, Terminal, Arg, Json, Csv, Regex, Gui, Reflect, Sh, Random

---

## Tier 1 — Almost Free (1–3 codegen lines, zero or near-zero preamble)

These are either direct `std.math.*` calls following the existing one-arg/two-arg pattern, `@builtin` calls, or constant emissions. No preamble function needed — just add a case in `genMathCall` (or the relevant gen function).

### 1.1 Math constants
**Missing:** `Math.PI`, `Math.E`, `Math.TAU`, `Math.PHI`, `Math.SQRT2`, `Math.LN2`, `Math.LN10`  
**Zig:** `std.math.pi`, `.e`, `.tau`, `.phi`, `.sqrt2`, `.ln2`, `.ln10`  
**Codegen:** emit the literal value (e.g. `3.14159265358979323846...`) or `std.math.pi` — these are `comptime_float` constants, simplest to just emit the float literal  
**Preamble lines:** 0  
**Why:** Every scripting language has `Math.PI`. Currently Zebra users have to write `3.14159...` by hand.  
**Implementation:** Handle in `genExpr` for `.member` on `Math` ident (similar to how constants already work in the Zig-side member dispatch).

### 1.2 Math: hyperbolic trig
**Missing:** `Math.sinh(x)`, `Math.cosh(x)`, `Math.tanh(x)`, `Math.asinh(x)`, `Math.acosh(x)`, `Math.atanh(x)`  
**Zig:** `std.math.sinh`, `.cosh`, `.tanh`, `.asinh`, `.acosh`, `.atanh`  
**Codegen:** 6 lines added to `genMathCall`, same pattern as `sin`/`cos`/`tan`  
**Preamble lines:** 0  
**Why:** Signal processing, ML activation functions, statistics. Anyone doing numerical work hits these.

### 1.3 Math: cbrt (cube root)
**Missing:** `Math.cbrt(x)`  
**Zig:** `std.math.cbrt(@as(f64, x))`  
**Codegen:** 1 line in `genMathCall`, same pattern as `sqrt`  
**Preamble lines:** 0  
**Why:** Common in geometry and physics; currently forces `Math.pow(x, 1.0/3.0)` which has precision issues.

### 1.4 Math: hypot
**Missing:** `Math.hypot(a, b)`  
**Zig:** `std.math.hypot(@as(f64, a), @as(f64, b))`  
**Codegen:** 1 case (2-arg) in `genMathCall`  
**Preamble lines:** 0  
**Why:** Euclidean distance computation; avoids overflow from `sqrt(a*a + b*b)`.

### 1.5 Math: log1p, expm1
**Missing:** `Math.log1p(x)`, `Math.expm1(x)`  
**Zig:** `std.math.log1p`, `std.math.expm1`  
**Codegen:** 2 lines in `genMathCall`  
**Preamble lines:** 0  
**Why:** Numerically stable variants for small `x`. Essential for financial/statistical math where `x ≈ 0`.

### 1.6 Math: lerp
**Missing:** `Math.lerp(a, b, t)`  
**Zig:** `std.math.lerp(@as(f64, a), @as(f64, b), @as(f64, t))`  
**Codegen:** 1 case (3-arg) in `genMathCall`  
**Preamble lines:** 0  
**Why:** Linear interpolation; ubiquitous in animation, graphics, color mixing, game dev. `a + (b-a)*t` has float precision edge cases that `lerp` handles correctly.

### 1.7 Math: gcd, lcm
**Missing:** `Math.gcd(a, b)`, `Math.lcm(a, b)`  
**Zig:** `std.math.gcd(@intCast(a), @intCast(b))`, `std.math.lcm`  
**Codegen:** 2 cases in `genMathCall`; need i64→usize cast and back  
**Preamble lines:** 0 (but 3-line wrapper to handle Zebra's i64 type)  
**Why:** Number theory, fraction simplification, scheduling problems.

### 1.8 Math: toRadians, toDegrees
**Missing:** `Math.toRadians(deg)`, `Math.toDegrees(rad)`  
**Zig:** `std.math.degreesToRadians`, `std.math.radiansToDegrees`  
**Codegen:** 2 cases  
**Preamble lines:** 0  
**Why:** Every trig user needs angle unit conversion. Currently requires `x * Math.PI / 180.0` inline.

### 1.9 Math: isPowerOfTwo, wrap
**Missing:** `Math.isPowerOfTwo(n)`, `Math.wrap(x, r)`  
**Zig:** `std.math.isPowerOfTwo`, `std.math.wrap`  
**Codegen:** 2 cases  
**Preamble lines:** 0  
**Why:** `isPowerOfTwo` is used in buffer/alignment code; `wrap` gives always-positive modulo (Python's `%` behavior).

### 1.10 Math: bit ops (popcount, clz, ctz)
**Missing:** `Math.popcount(n)`, `Math.clz(n)`, `Math.ctz(n)`  
**Zig:** `@popCount`, `@clz`, `@ctz` builtins  
**Codegen:** 3 cases; emit `@as(i64, @intCast(@popCount(@as(u64, @bitCast(n)))))`  
**Preamble lines:** 0  
**Why:** Bit manipulation, network programming, hash functions, competitive programming.

### 1.11 String: lastIndexOf
**Missing:** `str.lastIndexOf(sub) -> int` (returns -1 if absent)  
**Zig:** `std.mem.lastIndexOf(u8, haystack, needle)`  
**Codegen:** 3 lines (inline if-expr with cast, same shape as `indexOf`)  
**Preamble lines:** 0  
**Why:** Finding file extensions, parsing from right, very frequent. Currently requires a workaround.

### 1.12 String: eqlIgnoreCase
**Missing:** `str.eqlIgnoreCase(other) -> bool`  
**Zig:** `std.ascii.eqlIgnoreCase(a, b)`  
**Codegen:** 1 line  
**Preamble lines:** 0  
**Why:** Case-insensitive comparison without allocating `lower()` copies.

### 1.13 String: isAlphanumeric, isPrintable
**Missing:** `str.isAlphanumeric()`, `str.isPrintable()`  
**Zig:** `std.ascii.isAlphanumeric`, `std.ascii.isPrint` (loop, same pattern as `isAlpha`)  
**Codegen:** 2 cases, copy-paste of `isAlpha` block  
**Preamble lines:** 0  
**Why:** Input validation; `isAlphanumeric` is the obvious companion to the existing `isAlpha`/`isNumeric`.

### 1.14 File: size
**Missing:** `File.size(path) -> int` (bytes, -1 if missing)  
**Zig:** `std.fs.cwd().statFile(path) catch return -1; .size`  
**Codegen:** 3-line block expression  
**Preamble lines:** 0  
**Why:** Common: "is this file > 0 bytes?", "read only if under limit". Currently forces a full read to check.

### 1.15 File: isFile, isDir
**Missing:** `File.isFile(path) -> bool`, `File.isDir(path) -> bool`  
**Zig:** `std.fs.cwd().statFile(path)` → `.kind == .file` / `.directory`  
**Codegen:** 2 cases (3 lines each)  
**Preamble lines:** 0  
**Why:** Basic filesystem type checks; `Dir.exists` doesn't distinguish file from directory.

### 1.16 sys: cwd
**Missing:** `sys.cwd() -> str`  
**Zig:** `std.fs.cwd().realpathAlloc(_allocator, ".") catch ""`  
**Codegen:** 1 line  
**Preamble lines:** 0  
**Why:** Scripting tools almost always need to know or display CWD.

### 1.17 DateTime: timestamp (unix seconds)
**Missing:** `dt.timestamp() -> int` (epoch in seconds, not ms)  
**Zig:** `@divFloor(dt.epoch_ms, 1000)` — instance method  
**Codegen:** 1 line inline expression  
**Preamble lines:** 0  
**Why:** Unix timestamps in seconds are the universal interop format (HTTP headers, file mtime, most APIs). `toEpoch()` returns ms, which surprises users.

---

## Tier 2 — Cheap (5–20 preamble lines + codegen routing)

These need a small helper function in `stdlib_preamble.zig` but no new algorithm.

### 2.1 Base64 module (new module)
**Missing:** `Base64.encode(data: str) -> str`, `Base64.decode(data: str) -> str?`, `Base64.encodeUrl(data: str) -> str`, `Base64.decodeUrl(data: str) -> str?`  
**Zig:** `std.base64.standard.Encoder`, `std.base64.standard.Decoder`, `std.base64.url_safe_no_pad`  
**Preamble lines:** ~30 (4 wrapper functions, each 6–8 lines: compute output len, allocate, encode/decode, return slice)  
**Why:** Essential for web/API work. Every HTTP API uses Base64 for auth headers, image data, binary payloads. Currently Zebra has no encoding module at all. This is the single highest-value addition.

```zig
fn _base64_encode(s: []const u8) []const u8 {
    const enc = std.base64.standard.Encoder;
    const out = _allocator.alloc(u8, enc.calcSize(s.len)) catch @panic("OOM");
    return enc.encode(out, s);
}
fn _base64_decode(s: []const u8) ?[]const u8 {
    const dec = std.base64.standard.Decoder;
    const out_len = dec.calcSizeForSlice(s) catch return null;
    const out = _allocator.alloc(u8, out_len) catch @panic("OOM");
    dec.decode(out, s) catch return null;
    return out;
}
// + url_safe variants using std.base64.url_safe_no_pad
```

**Codegen dispatch:** `if id.name == "Base64"` → `genBase64Call`; 4 methods, each 2 lines.

### 2.2 Hash: non-crypto fast hashes
**Missing:** `Hash.crc32(data) -> int`, `Hash.fnv64(data) -> int`, `Hash.xxHash64(data) -> int`  
**Zig:** `std.hash.crc.Crc32.hash`, `std.hash.Fnv1a_64.hash`, `std.hash.XxHash64.hash`  
**Preamble lines:** ~12 (3 wrapper functions, each 3–4 lines to cast and return i64)  
**Why:** CRC32 for file checksums and zlib/PNG; FNV/xxHash for non-cryptographic hash tables, deduplication, cache keys. The current `Hash` module only has cryptographic hashes (SHA, BLAKE3) which are slow for these use cases.

```zig
fn _hash_crc32(s: []const u8) i64 {
    return @as(i64, @intCast(std.hash.crc.Crc32.hash(s)));
}
fn _hash_fnv64(s: []const u8) i64 {
    return @as(i64, @bitCast(std.hash.Fnv1a_64.hash(s)));
}
fn _hash_xxhash64(s: []const u8) i64 {
    return @as(i64, @bitCast(std.hash.XxHash64.hash(0, s)));
}
```

### 2.3 String: case-insensitive search
**Missing:** `str.startsWithIgnoreCase(prefix)`, `str.endsWithIgnoreCase(suffix)`, `str.containsIgnoreCase(sub)`, `str.indexOfIgnoreCase(sub) -> int`  
**Zig:** `std.ascii.startsWithIgnoreCase`, `std.ascii.endsWithIgnoreCase`, `std.ascii.indexOfIgnoreCase`  
**Preamble lines:** 0 (direct dispatch, same inline pattern as `startsWith`)  
**Why:** HTTP header matching, config key lookup, user input handling. Extremely common. Currently requires `s.lower().startsWith(prefix.lower())` which allocates two strings.

### 2.4 String: indexOfFrom (find with start offset)
**Missing:** `str.indexOfFrom(sub, start: int) -> int`  
**Zig:** `std.mem.indexOfPos(u8, haystack, @intCast(start), needle)`  
**Codegen:** Inline 3-line if-expr block, same shape as `indexOf`  
**Preamble lines:** 0  
**Why:** Needed for parsing loops where you scan forward through a string (e.g., find next delimiter after position).

### 2.5 String: toIntBase
**Missing:** `str.toIntBase(base: int) -> int` (parse hex/octal/binary strings)  
**Zig:** `std.fmt.parseInt(i64, s, @intCast(base)) catch 0`  
**Codegen:** 3-line inline expression  
**Preamble lines:** 0  
**Why:** Parse `"0xFF"`, `"0b1010"`, `"0o777"` — currently impossible in Zebra without `zig_lit`. Critical for low-level tool writing.

### 2.6 String: tokenize
**Missing:** `str.tokenize(delim) -> iterator` (splits on delimiter, skipping consecutive/leading/trailing)  
**Zig:** `std.mem.tokenizeSequence(u8, s, delim)`  
**Codegen:** 1 line (identical shape to `split`)  
**Preamble lines:** 0  
**Why:** `split(" ")` on `"  hello   world  "` gives empty strings; `tokenize(" ")` skips them. Both are needed for robust whitespace parsing.

### 2.7 String: encodeBase64, decodeBase64
**Missing:** `str.encodeBase64() -> str`, `str.decodeBase64() -> str?`  
**Preamble:** Reuses `_base64_encode` / `_base64_decode` from 2.1 above  
**Why:** Ergonomic instance-method form. Both forms (`Base64.encode(s)` and `s.encodeBase64()`) should exist.

### 2.8 Random: Gaussian distribution
**Missing:** `Random.gaussian(mean: float, stddev: float) -> float`  
**Zig:** Box-Muller transform using `_rng().float(f64)` — no Zig stdlib function, needs ~8 lines  
**Preamble lines:** ~10  
**Why:** Monte Carlo simulation, noise generation, ML data augmentation.

```zig
fn _random_gaussian(mean: f64, stddev: f64) f64 {
    const u1 = _rng().float(f64);
    const u2 = _rng().float(f64);
    const z = @sqrt(-2.0 * @log(u1)) * @cos(2.0 * std.math.pi * u2);
    return mean + stddev * z;
}
```

### 2.9 Random: weighted choice
**Missing:** `Random.weighted(items: List(str), weights: List(float)) -> str`  
**Preamble lines:** ~15 (normalize weights, cumulative sum, binary search)  
**Why:** Sampling with probabilities — A/B testing, generative AI sampling, load-weighted routing.

### 2.10 Path: absolute
**Missing:** `Path.absolute(p: str) -> str` (resolve to absolute path)  
**Zig:** `std.fs.cwd().realpathAlloc(_allocator, p) catch p`  
**Preamble lines:** ~5 (wrapper that falls back to returning input on error)  
**Why:** Scripts that log or compare paths need absolute form; relative paths from nested calls are ambiguous.

### 2.11 File: writeLines
**Missing:** `File.writeLines(path: str, lines: List(str))`  
**Zig:** Write each line + `\n` via join then writeFile  
**Preamble lines:** ~8  
**Why:** Symmetric with `readLines`. Very natural: read lines, transform, write lines.

### 2.12 sys: setenv
**Missing:** `sys.setenv(key: str, val: str)`  
**Zig:** `std.posix.setenv` (POSIX) / `std.os.windows.SetEnvironmentVariableW` (Windows)  
**Preamble lines:** ~10 (platform branch)  
**Why:** Subprocess configuration — set env before `sys.run()`; test isolation; Docker/CI tooling.

### 2.13 Hash: hmac512
**Missing:** `Hash.hmac512(key: str, data: str) -> str`  
**Zig:** `std.crypto.auth.hmac.sha2.HmacSha512`; same pattern as existing `_hash_hmac256`  
**Preamble lines:** ~8 (copy-paste of hmac256 with Sha512)  
**Why:** JWT and AWS Signature V4 require HMAC-SHA256 (have it) and HMAC-SHA512. Completing the pair is trivial.

---

## Tier 3 — Medium (new struct/state needed, 30–80 preamble lines)

Worth doing but not "almost free".

### 3.1 Unicode module (new module)
**API:** `Unicode.isLetter(codepoint: int)`, `Unicode.isDigit(codepoint: int)`, `Unicode.isPunct(codepoint: int)`, `Unicode.encode(codepoint: int) -> str`, `Unicode.decode(s: str) -> int`  
**Zig:** `std.unicode.utf8Encode/Decode`; Unicode property lookups need either a lookup table (~50 lines of range checks) or a linking to ICU.  
**Effort:** `encode`/`decode` are free (std.unicode wrappers); property lookups for full Unicode require a lookup table.  
**Why:** Zebra's `char` type is `u21` (full Unicode codepoint) but currently there's no way to classify codepoints beyond ASCII. The `str.isAlpha()` method uses `std.ascii.isAlphabetic` which fails on é, ñ, etc.  
**Approach:** Implement `encode`/`decode` now (cheap). Property lookups: use a simplified plane-0 range table (covers 99% of use cases, ~60 lines).

### 3.2 Encoding module (new module, or extend Hash)
**API:** `Encode.urlEncode(s) -> str`, `Encode.urlDecode(s) -> str?`, `Encode.htmlEscape(s) -> str`, `Encode.htmlUnescape(s) -> str`  
**Zig:** `std.Uri.percentEncode/decode` available; HTML escaping needs a hand-written table (~20 lines)  
**Effort:** ~60 preamble lines  
**Why:** Web scripting is a primary Zebra use case (Http module already exists). URL encoding and HTML escaping are used in every web app. Currently impossible without `zig_lit`.

### 3.3 Compression: zstd/lzma decompress
**API:** `Compress.lzma(data: str) -> str?`, `Compress.zstd(data: str) -> str?`  
**Zig:** `std.compress.lzma.decompress`, `std.compress.zstd.decompress` — both available in Zig 0.15  
**Effort:** ~30 preamble lines each (reader/writer setup); no encode side (zstd compress not in Zig stdlib)  
**Why:** Reading `.tar.lzma` or `.zst` files is needed for package manager tooling. Decompression only is still useful.

### 3.4 Buffered I/O handles
**API:** `File.openRead(path) -> FileReader`, `FileReader.readLine() -> str?`, `FileReader.close()`  
**Zig:** `std.fs.cwd().openFile` → `BufferedReader` → line iterator  
**Effort:** ~50 preamble lines (new struct `_FileReader` with arena-backed buffer, `readUntilDelimiterAlloc`-based line reading)  
**Why:** `File.readLines(path)` loads the whole file into memory. For large files (server logs, genomic data) line-by-line reading is required. This is a different usage pattern than the current bulk-read API.

### 3.5 DateTime: parse (ISO 8601)
**API:** `DateTime.parse(s: str) -> DateTime?`  
**Zig:** No stdlib ISO 8601 parser; needs ~80 lines of hand-written parsing  
**Effort:** Medium-high  
**Why:** Reading JSON APIs, log files, database timestamps. `toIso8601` already exists on output side; the lack of a parse counterpart is a glaring asymmetry.

---

## Not Worth It / Out of Scope

| Item | Reason |
|------|--------|
| `std.atomic` | Zebra's 0.14 concurrency model is CSP-style (`Chan(T)` channels backed by `std.Thread`). Atomics are a shared-memory primitive that works against that model — the right answer to "coordinate two threads" in Zebra is a channel, not `Atomic.store`. Atomics belong in the `@low_level` systems track (0.15+, kernel/bare-metal), not in general stdlib. |
| `std.crypto` (AES, ChaCha, Argon2) | Security-critical APIs need careful design review; wrong abstraction leaks timing info |
| `std.unicode` UTF-16/WTF-8 | Platform-specific (Windows paths); conflicts with Zebra's UTF-8-everywhere design |
| `std.math.big` (BigInt) | Requires a full allocation strategy; Zebra's arena model makes big integer arithmetic awkward |
| `std.complex` | Niche; would need new `Complex` type in TC |
| `std.io.Writer/Reader` protocol | Zebra doesn't expose generic interfaces; would need major TC additions |
| `std.Build` | Build system internals — not a stdlib use case |
| `std.meta` / `@typeInfo` | Zebra already has `Reflect`; exposing raw comptime introspection would conflict |
| Compression (flate/gzip compress) | Blocked on Zig 0.16 (`std.compress.flate.Compress` is `@panic("TODO")` in 0.15.2) |
| Checked integer arithmetic (`std.math.add`, `.mul`) | Zebra's error model would require `try Math.add(a,b)` — not ergonomic at the Zebra level |
| `std.sort` directly | `list.sort()` already works; exposing sort with custom comparators needs lambda design work |

---

## Recommended Implementation Order

### Sprint 1 — Math completions (1 day, maximum leverage per line of code)
All Tier 1 Math items (1.1–1.10): constants, hyperbolic trig, cbrt, hypot, log1p, expm1, lerp, gcd, lcm, toRadians/toDegrees, isPowerOfTwo, wrap, bit ops. Each is 1–3 lines in `genMathCall`. Total: ~30 codegen lines, 0 preamble lines.

### Sprint 2 — String completions (0.5 day)
Tier 1 String items (1.11–1.13) + Tier 2 items 2.3–2.6: lastIndexOf, eqlIgnoreCase, isAlphanumeric, isPrintable, case-insensitive search methods, indexOfFrom, toIntBase, tokenize. Total: ~20 codegen lines, 0 preamble lines.

### Sprint 3 — Base64 module (0.5 day)
Tier 2 item 2.1 + string methods 2.7. New `Base64` module with 4 functions. ~30 preamble lines + codegen routing + Builtins.zig entry. Highest practical value-to-effort ratio after math completions.

### Sprint 4 — File/sys additions (0.5 day)
Tier 1 items 1.14–1.17 + Tier 2 items 2.10–2.12: File.size, File.isFile, File.isDir, sys.cwd, Path.absolute, File.writeLines, sys.setenv, DateTime.timestamp. Each is 1–10 lines.

### Sprint 5 — Hash additions (0.5 day)
Tier 2 items 2.2 + 2.13: CRC32, FNV64, xxHash64, HMAC-SHA512. ~20 preamble lines.

### Sprint 6 — Unicode encode/decode + Encoding module (1 day)
Tier 3 item 3.1 (encode/decode only, no property lookups yet) + Tier 3 item 3.2 (URL encode/decode, HTML escape). ~80 preamble lines total.

---

## Summary Table

| Status | Item | New module? | Preamble lines | Codegen lines | Value |
|--------|------|-------------|----------------|---------------|-------|
| ✅ Done | Math constants (PI, E, TAU…) | No | 0 | 7 | Every numeric program |
| ✅ Done | Math hyperbolic trig (6 fns) | No | 0 | 6 | Numerical/scientific |
| ✅ Done | Math lerp | No | 0 | 1 | Graphics/animation |
| ✅ Done | Math toRadians/toDegrees | No | 0 | 2 | All trig users |
| ✅ Done | Base64 encode/decode | Yes (`Base64`) | 30 | 8 | Web/API |
| ✅ Done | str.lastIndexOf | No | 0 | 3 | Parsing |
| ✅ Done | Math cbrt, hypot | No | 0 | 2 | Geometry |
| ✅ Done | Math log1p, expm1 | No | 0 | 2 | Numerical |
| ✅ Done | Math gcd, lcm | No | ~3 | 2 | Number theory |
| ✅ Done | Math isPowerOfTwo, wrap | No | 0 | 2 | Systems |
| ✅ Done | Math popcount, clz, ctz | No | 0 | 3 | Bit manipulation |
| ✅ Done | str case-insensitive ops (4) | No | 0 | 4 | HTTP/config |
| ✅ Done | str.indexOfFrom | No | 0 | 3 | Parsing |
| ✅ Done | str.toIntBase | No | 0 | 1 | Low-level tools |
| ✅ Done | str.tokenize | No | 0 | 1 | Text parsing |
| ✅ Done | str.isAlphanumeric, isPrintable | No | 0 | 2 | Validation |
| ✅ Done | str.eqlIgnoreCase | No | 0 | 1 | String compare |
| ✅ Done | Hash.crc32 / fnv64 / xxHash64 | No | 12 | 3 | Checksums/perf |
| ✅ Done | Hash.hmac512 | No | 8 | 1 | Auth/JWT |
| ✅ Done | File.size / isFile / isDir | No | 0 | 6 | Filesystem |
| ✅ Done | File.writeLines | No | 8 | 1 | Symmetry |
| ✅ Done | sys.cwd | No | 0 | 1 | Scripting |
| ✅ Done | sys.setenv | No | 10 | 1 | Subprocess |
| ✅ Done | Path.absolute | No | 5 | 1 | Scripting |
| ✅ Done | Random.gaussian | No | 10 | 1 | Simulation |
| ✅ Done | Random.weighted | No | 15 | 1 | Sampling |
| 🟠 Next | DateTime.timestamp() | No | 0 | 1 | Interop |
| 🟡 Low | Unicode encode/decode | Yes (`Unicode`) | 15 | 4 | Unicode i18n |
| 🟡 Low | URL encode/decode, HTML escape | Yes (`Encode`) | 60 | 6 | Web scripting |
| 🟡 Low | Compress lzma/zstd | No | 30 | 2 | Archives |
| ⬜ Later | File.openRead / line reader | No | 50 | 4 | Large files |
| ⬜ Later | DateTime.parse | No | 80 | 1 | Full DT round-trip |
| ⬜ Later | Unicode property lookups | No | 60 | 4 | Full i18n |
