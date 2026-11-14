<!-- doc-status: design -->
# `chars()` on bytes that are not UTF-8 (BUG-703, with 712 and 714)

Status: AGREED 2026-11-13 by Opus and Fable, in writing: option C with the additions under
"Decision". BOTH HALVES ARE BUILT (2026-11-13): the Zig half by Opus (BUG-703 and BUG-714), with
the shared `v_poc` fixture whose Zig run is the expected output; the V half by Fable against that
fixture (BUG-712 and BUG-713; `selfhost/zebra_rt.v`'s `zutf8_next` and its neighbours), and
`v-check` passes on both. What the fixture cannot tell apart on the V route, and what covers it
instead, is under "The V half" at the end. BUG-703 is the first step of BUG-701's option A
(`http_serve_recovery.md`).

## What happens today (measured 2026-11-13)

The string is `"a" + "${255:c}" + "b"`: 3 bytes, `isValidUtf8()` false.

| | Zig route, Debug | Zig route, `--release` | V route |
|---|---|---|---|
| `for c in s.chars()` | yields `a`, then panics `Utf8InvalidStartByte` | yields `a`, then **segfaults** | yields bytes (BUG-712) |
| `s.codePointCount()` | **0** (`catch 0`, BUG-714) | 0 | not mapped (refused) |
| `"aéb"` (valid) `chars()` | 3 items | 3 items | **4 items** (BUG-712) |

The release segfault comes from std's `Utf8View.initUnchecked(...).nextCodepoint()`, which the
loop uses. Its decode is `catch unreachable` inside std. std is compiled ReleaseFast, outside the
`@setRuntimeSafety(true)` that user functions carry (BUG-667/668). So the fix has to use its own
decoder, not that iterator.

## Requirements

1. **Never panic or crash on input bytes.** That is the whole point of BUG-701 option A: a client
   that sends `\xff` must not be able to end a server.
2. **Never fabricate.** No constant on failure: BUG-714's `0` is the count of the empty string.
3. **Distinct inputs stay distinct (Fable, 2026-11-12).** Where a result feeds a comparison or a
   store, two different invalid inputs must not come out equal. Two U+FFFD replacements compare
   equal, which is the reassuring-answer failure.
4. **Both routes give the same answer**, for invalid input and for valid input.

## The call sites, and what each one does with the result

`for ... in ....chars()` loops in tracked `.zbr` files:

| corpus | loops |
|---|---|
| zebra-language | 38 (27 in `test/`, 11 in `selfhost/`) |
| graze | 6 |
| GameEngine | 3 |
| zebra-ide, mosaic, zebra-sprocket, pocket-lab-manager | 0 |

Outside the tests, the sites take four shapes:

- **Rebuild a string and store it.** GameEngine `jsonEscape` (writes a save file), `cleanSaveName`
  (a file name), `unban.zbr` (rewrites player data), Graze `percent_decode`. A lossy decoder
  would change the stored bytes here *silently*.
- **Validate.** Graze checks every char against an allowed set (two sites). Any answer works as
  long as the invalid byte is not in the set.
- **Walk a literal.** Graze's hex and printable tables, and most compiler sites. These never see
  invalid input.
- **Input from outside, in the compiler itself:** `lspFormatEdits(text)` (selfhost/main.zbr)
  walks a document's text with `chars()`. Nobody has tested whether an editor can deliver
  invalid UTF-8 to `zebra lsp`.

## Options

### A. U+FFFD for each invalid byte

Go's `for _, r := range s` does this, and so do Rust's `from_utf8_lossy` and the WHATWG decoder.
It never panics, and no call site changes. It breaks requirement 3: `"\xff"` and `"\xfe"` both
become U+FFFD, and every rebuild-and-store site rewrites the stored bytes.

### B. Refuse: `chars()` raises on invalid input

The strictest option, and it satisfies 1-3. The cost: `chars()` becomes `throws`, so all 47
loops need a `?` or a `catch`, nearly all of them over text that is always valid. When the
language makes nearly every author handle a failure, it trains them to write a blanket `catch`.

### C. Byte escape: an invalid byte becomes its own char (Python's PEP 383, `surrogateescape`)

An invalid byte `b` (0x80-0xFF) is yielded as the char `U+DC00 + b`, in U+DC80..U+DCFF. These are
lone low surrogates: no valid UTF-8 decodes to them, so they cannot collide with real text. When
a char in that range becomes text again (`toString()`, `"${c}"`, `"${c:c}"`,
`StringBuilder.append`), it writes the **original byte**.

- 1: it never panics; the decoder is total.
- 2: nothing is a constant. `codePointCount()` counts exactly the items `chars()` yields, so
  `"a\xffb"` counts 3.
- 3: distinct bytes give distinct chars, and a rebuilt string is **byte-identical** to its input.
  A validator rejects the escape char because it is in no allowed set.
- 4: the V route implements the same decoder (BUG-712 needs a decoder there anyway).
- No call site changes. `isValidUtf8()` remains the way to refuse up front, as Graze already does.

**The decoder, exactly.** C's two properties, byte-identical rebuild and no collisions, rest on
these rules, so both routes must implement them identically:
- Decode by the standard well-formed table (Unicode 3.9, Table 3-7).
- **On any failure, escape only the FIRST byte and resume at the next one.** Never consume a
  maximal invalid subpart. A truncated `E2 82` yields two escape chars, U+DCE2 U+DC82.
- **Reject encoded surrogates, overlongs and values above U+10FFFF, escaping each byte.** That
  covers `ED A0 80`..`ED BF BF`, overlongs such as `C0 80` and `E0 80 80`, and `F4 90 80 80` and
  above. If a route accepted `ED B3 BF` as the real char U+DCFF, `toString()` would write the
  single byte `0xFF`. That breaks the round trip and collides with a literal `\xff`.
- On the V route this means **a hand-written decoder in `zebra_rt.v`**, not V's `runes()`, which
  is not known to reject these. On the Zig route it means a runtime function, not std's
  iterator, because of the release-mode undefined behaviour above.

**What C does not fix: a site that escapes into a format.** Under C, GameEngine's `jsonEscape`
writes the original `0xFF` into the save file. The bytes are exact, but the file is not valid
JSON, and a strict reader may refuse it on load. "No call site changes" holds for the bytes, not
for the validity of the output. A site that writes JSON, HTML or anything else defined over
Unicode still needs `isValidUtf8()` or `toValidUtf8()` at that boundary. C leaves that as a
choice the author can see; A makes it silently, and B makes the site fail.

For display, add a named lossy conversion, **`s.toValidUtf8(): str`** (U+FFFD for each invalid
sequence). A program asks for that loss by name; nothing applies it silently.

Cost:
- A decoder in each runtime, about 30 lines each.
- One char-to-bytes helper on the Zig route, used wherever a char becomes text. Reading the code
  finds the `toString` emit (which also fixes the uninitialised-buffer `catch 1` noted in
  BUG-703) and three `{u}` interpolation formats. That count comes from reading; the real site
  map comes from emitting (see the fixture list). Zig's `{u}` quietly writes U+FFFD for a
  surrogate, so a missed site breaks the round trip with no error.
- `codePointCount` and `reverse` go through the same decoder.

The price:
- A classifier such as `isLetter` answers false for an escape char.

## Decision (2026-11-13)

**C**, with `toValidUtf8()` for display. It is the only option that is both total and exact, and
it changes no call site. Fable, on B: refusal belongs at the boundary, by `isValidUtf8()`, where
Graze already puts it. A `?` on 47 loops over text that is always valid teaches the blanket catch.

The agreement adds Fable's five amendments to C. Two were rescoped after measuring:

1. **Every char a program can hold has a defined text, and the reachable ones are injective.**
   Measured: a program gets a char only from a `c'...'` literal or from `chars()`. There is no
   int-to-char conversion: `var c: char = 65` and a runtime int are refused ("expected char,
   found int"), `n.toChar()` does not exist, and `c + 1` is an int.
   - The lexer **refuses a surrogate char literal outside the escape range** (U+D800..U+DC7F and
     U+DD00..U+DFFF), as it already refuses `"\u{D800}"` in a string. Today `c'\u{D800}'` is
     accepted, and `c'\u{DCFF}'` comes out three different ways: `toString()` writes `aa` (one
     byte of an uninitialised buffer), while `"${c}"` and `"${c:c}"` write U+FFFD.
   - The lexer **allows `c'\u{DC80}'`..`c'\u{DCFF}'`**, so a program can test for an escape char
     by comparison.
   - So every reachable char is either a valid scalar, written as UTF-8, or an escape char,
     written as its original byte. Char-to-text is total and injective over these, and
     **bytes -> chars -> bytes is the identity for every byte string.**
   - The helper still defines the unreachable rest: any other surrogate, and 0x110000..0x1FFFFF.
     It writes them in the generalized 3- or 4-byte form WTF-8 would use, never U+FFFD and never
     a panic. That output is invalid UTF-8, so it re-decodes as escape chars and is stable from
     then on. Over those chars **chars -> bytes is NOT injective**: a built U+DD00 and the three
     escapes DCED DCB4 DC80 write the same bytes. That is unreachable today. **Any future
     int-to-char conversion must refuse those values or document this caveat.** A fixture line
     pins the refusal of `var c: char = 65`, so the day someone adds the conversion, it goes red
     and points them here.
2. **`${n:c}` on an int behaves like `n.toUint8()`.** Measured: today the Zig route truncates
   silently. `${300:c}` writes 0x2C, a runtime -1 writes 0xFF, and 0xDD00 writes 0x00, a NUL. A
   literal outside 0..255 is refused at `-c`. A runtime value outside that range traps with the
   checked conversions' message (BUG-534's family), in the same words on both routes. A char
   under `:c` writes its UTF-8, and an escape char writes its original byte. QUICKSTART's `:c`
   rows say so.
3. **`c.escapedByte(): int?`** returns the original byte (0x80..0xFF) for an escape char and nil
   for a real char. Since `"${c.toInt():c}"` now traps, this keeps the 0xDC00 constant out of
   user code.
4. **Runtime format boundaries and invalid bytes.** Measured on the Zig route, 2026-11-13. This
   step changes none of them; the list is here so that "total" is not read wider than `chars()`.

   | boundary | input `61 FF 62`, or a lone `\uD800` |
   |---|---|
   | `Json.parse` of raw invalid bytes in a string | nil (refused) |
   | `Json.parse` of `"\uD800"` | nil (refused) |
   | `Json.stringify` of a str holding 0xFF | unmeasured (no way found to build one; parse refuses it) |
   | `File.write` then `File.read` | byte-exact |
   | Sqlite `asStr` on `CAST(X'61FF62' AS TEXT)` | byte-exact |
   | `Regex("a.b")` | `.` matches 0xFF as one unit; `find` returns the exact bytes |
   | Http header value, `sys.args` | unmeasured |

   Fable will put the GameEngine's `isValidUtf8()` checks at its network and typed-text
   boundaries, not in its escaper.
5. **QUICKSTART states the rule in one place:** `chars()` never refuses. Validity is a separate
   question, asked with `isValidUtf8()` where text enters. An allow-list validator rejects an
   escape char; a deny-list validator ("no control characters") passes it.

## What the fix's fixture must show

- `for c in "a\xffb".chars()` yields 3 items, the middle one U+DCFF, in Debug **and**
  `--release`, on both routes.
- **The test vectors live in a `v_poc` example**, so `v-check` diffs the V and Zig runs on every
  `--v`. That closes the blind spot behind BUG-712 and BUG-713 for good.
- **Exhaustive where that is cheap** (amendment 5): all 256 one-byte strings and all 65,536
  two-byte strings. Add three- and four-byte strings over the lead bytes with boundary second
  bytes (E0 9F/A0, ED 9F/A0, EF BF, F0 8F/90, F4 8F/90, F5..FF), plus valid text in 1-, 2-, 3-
  and 4-byte forms. Each block prints an item count and a hash of the rebuilt bytes plus the
  item codepoints, so the expected file stays small. A few vectors are printed in the clear
  beside them as a readable control. A hash is only ever compared for equality across routes,
  never read as a value.
- **The char-to-text site map is DERIVED by emitting** a probe that turns a char into text in
  every position: `print(c)`, `"${c}"`, `"${c:c}"`, `toString()`, `StringBuilder.append`,
  `join` over a `List(char)`, and a map key. The output is grepped for `{u}` and `utf8Encode`.
  Reading finds fewer sites than emitting (`keyword-ident`'s record: 4 found by reading, 9 by
  emitting).
- `"\xff"` and `"\xfe"` rebuild to different strings.
- Rebuilding any string char by char gives back exactly its bytes.
- `codePointCount()` equals the iteration count.
- `toValidUtf8()` turns `"a\xffb"` into `a`, U+FFFD, `b`.
- `c.escapedByte()` is 255 for the escape char of 0xFF and nil for `c'a'`.
- **Every `str` method that could decode** (amendment 4): `upper`, `lower`, `trim`, `reverse`,
  `split("")`, `replace`, `contains`/`indexOf`, the padding functions (is a width counted in
  chars or in bytes?) and `codePointCount`. Each runs on the invalid vectors, with bytes printed
  in hex, on both routes.
- The refusals: `var c: char = 65` and a runtime int are refused, and so is `c'\u{D800}'`.
  `c'\u{DCFF}'` is accepted. `${300:c}` is refused at `-c`. A runtime 300 under `:c` traps, and
  the fixture pins the exit code and the stderr text, so the V route matches them word for word.
- A `chars()` walk inside an `Http.serve` handler, fed `\xff\xfe` by a raw `Tcp` client, answers
  and keeps serving (BUG-701's control, A half).

## The V half (Fable, 2026-11-13)

Built against `examples/v_poc_utf8.zbr`; identical to the Zig run at the first run, and the
selfhost dumps and the route's modules with it. What the building turned up that this note
should carry:

- **The V route had no char at all.** `char` was `u8`, so the change is a representation change
  (a `rune`), not a decoder dropped in. The compiler's own lexer keeps bytes in `char`s
  (`def peek(): char` returning `src[pos]`), which the Zig route widens silently; the V emitter
  now says `rune(...)` at a return, a declared local, an argument and an assignment. A byte's
  `toString()` printed the character on the V route for the same reason; it is the number now,
  as on the Zig route.
- **Width and case were diverging on VALID text**, not only invalid: V's `${s:8}` counts visible
  characters and has no `>` or `^`; V's `to_upper()` changes `é` and goes through runes; V's
  `reverse()` is by byte. None of the earlier `v_poc` examples used non-ASCII text with any of
  them. All three go through the runtime now.
- **What the shared fixture cannot see on the V route**, found by planting 22 faults one at a
  time: a by-byte `reverse` (the fixture's reverse vector is all single-byte items, so the two
  orders are the same bytes), which side takes an odd centre's spare byte (its `center(9)` over
  five bytes pads evenly), a width that left-aligns where it should right-align, and the `:c`
  trap. `tools/v_check.sh`'s `fmt_c` row carries a control program for exactly these (valid
  multi-byte text reversed, an odd centre, each alignment, the case of a non-ASCII letter) beside
  the trap fixture. A reverse of valid multi-byte text and an odd centre would be worth adding
  to the shared fixture itself, so the Zig route's own output pins them too.
- **No V mirror exists for** BUG-701's control (an `Http.serve` handler fed `\xff\xfe`): the V
  route has no `Http.serve`, `Ws.serve` or `Tcp.serve`. Nor for `Json` over invalid bytes
  (unmeasured on V), nor for the sized conversions (`toUint8` and its siblings), whose trap
  text `:c` now uses there without the family being mapped.
