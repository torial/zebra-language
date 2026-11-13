<!-- doc-status: design -->
# `chars()` on bytes that are not UTF-8 (BUG-703, with 712 and 714)

Status: PROPOSED 2026-11-13 (Opus). This needs a written agreement with Fable before anything
is built, because the V route must give the same answer. BUG-703 is the first step of BUG-701's
option A (`http_serve_recovery.md`).

## What happens today (measured 2026-11-13)

The string is `"a" + "${255:c}" + "b"`: 3 bytes, `isValidUtf8()` false.

| | Zig route, Debug | Zig route, `--release` | V route |
|---|---|---|---|
| `for c in s.chars()` | yields `a`, then panics `Utf8InvalidStartByte` | yields `a`, then **segfaults** | yields bytes (BUG-712) |
| `s.codePointCount()` | **0** (`catch 0`, BUG-714) | 0 | not mapped (refused) |
| `"aéb"` (valid) `chars()` | 3 items | 3 items | **4 items** (BUG-712) |

The release segfault happens because the loop uses std's `Utf8View.initUnchecked(...).nextCodepoint()`.
Its decode is `catch unreachable` inside std, and std is compiled ReleaseFast, outside the
`@setRuntimeSafety(true)` that user functions carry (BUG-667/668). Any fix has to use its own
decoder, not that iterator.

## Requirements

1. **Never panic or crash on input bytes.** That is BUG-701 option A's whole point: a client
   that sends `\xff` must not be able to end a server.
2. **Never fabricate.** No constant on failure: BUG-714's `0` is the count of the empty string.
3. **Distinct inputs stay distinct (Fable, 2026-11-12).** If a result feeds a comparison or a
   store, two different invalid inputs must not come out equal. Two U+FFFD replacements compare
   equal, and that is the reassuring-answer failure.
4. **Both routes give the same answer**, for invalid input and for valid input.

## The call sites, and what each one does with the result

`for ... in ....chars()` loops in tracked `.zbr` files:

| corpus | loops |
|---|---|
| zebra-language | 38 (27 in `test/`, 11 in `selfhost/`) |
| graze | 6 |
| GameEngine | 3 |
| zebra-ide, mosaic, zebra-sprocket, pocket-lab-manager | 0 |

Outside the tests, the sites fall into three shapes:

- **Rebuild a string and store it.** GameEngine `jsonEscape` (writes a save file), `cleanSaveName`
  (a file name), `unban.zbr` (rewrites player data), Graze `percent_decode`. A lossy decoder
  changes stored bytes here *silently*.
- **Validate.** Graze checks every char against an allowed set (two sites). Any answer works if
  the invalid byte is not in the set.
- **Walk a literal.** Graze's hex and printable tables, and most compiler sites. These never see
  invalid input.
- **Input from outside, in the compiler itself:** `lspFormatEdits(text)` (selfhost/main.zbr)
  walks a document's text with `chars()`. Whether an editor can deliver invalid UTF-8 to
  `zebra lsp` has not been tested.

## Options

### A. U+FFFD for each invalid byte

This is what Go's `for _, r := range s` does, and what Rust's `from_utf8_lossy` and the WHATWG
decoder do. It never panics, and no call site changes. It breaks requirement 3: `"\xff"` and
`"\xfe"` both become `"�"`, and every rebuild-and-store site rewrites the stored bytes.

### B. Refuse: `chars()` raises on invalid input

This is the strictest option and satisfies 1-3. Its cost is that `chars()` becomes `throws`, so
all 47 loops need a `?` or a `catch`, nearly all of them over text that is always valid. A
failure the language makes nearly every author handle trains them to write a blanket `catch`.

### C. Byte escape: an invalid byte becomes its own char (Python's PEP 383, `surrogateescape`)

An invalid byte `b` (0x80-0xFF) is yielded as the char `U+DC00 + b`, which is in U+DC80..U+DCFF.
These are lone low surrogates: no valid UTF-8 decodes to them, so they cannot collide with real
text. Turning a char back into text (`toString()`, `"${c}"`, `"${c:c}"`, `StringBuilder.append`)
writes the **original byte** for a char in that range.

- 1: it never panics; the decoder is total.
- 2: nothing is a constant. `codePointCount()` counts exactly the items `chars()` yields, so
  `"a\xffb"` counts 3.
- 3: distinct bytes give distinct chars, and a rebuilt string is **byte-identical** to its input.
  `jsonEscape` stores what it was given, and a validator rejects the escaped char because it is
  not in any allowed set.
- 4: the V route implements the same decoder (BUG-712 needs a decoder there anyway).
- No call site changes. `isValidUtf8()` stays the way to refuse up front, as Graze already does.

**The decoder, exactly.** Both of C's properties, the byte-identical rebuild and the absence of
collisions, rest on these rules, so both routes must implement them identically:
- Decode by the standard well-formed table (Unicode 3.9, Table 3-7).
- **On any failure, escape only the FIRST byte and resume at the next one.** Never consume a
  maximal invalid subpart. A truncated `E2 82` yields two escape chars, `U+DCE2 U+DC82`.
- **Reject encoded surrogates, overlongs, and values above U+10FFFF, escaping each byte.** That
  covers `ED A0 80`..`ED BF BF`, overlongs such as `C0 80` and `E0 80 80`, and `F4 90 80 80` and
  above. If a route accepted `ED B3 BF` as the real char U+DCFF, `toString()` would write the
  single byte `0xFF`. That breaks the round trip and collides with a literal `\xff`.
- On the V route this means **a hand-written decoder in `zebra_rt.v`**, not V's `runes()`, which is
  not known to reject these. On the Zig route it means a runtime function, not std's iterator,
  because of the release-mode UB above.

**What C does not fix: a site that escapes into a format.** GameEngine's `jsonEscape` under C
writes the original `0xFF` into the save file. The bytes are exact, but the file is not valid
JSON, and a strict reader may refuse it on load. "No call site changes" is true for the bytes, not
for the validity of the output. A site that writes JSON, HTML, or anything else defined over
Unicode still needs `isValidUtf8()` or `toValidUtf8()` at that boundary. C makes that a choice
the author can see; A makes it silently, B makes it fail.

For display, add a named lossy conversion, **`s.toValidUtf8(): str`** (U+FFFD for each invalid
sequence). A program asks for that loss by name; nothing applies it silently.

Cost:
- A decoder in each runtime, about 30 lines each.
- One char-to-bytes helper on the Zig route, used wherever a char becomes text. Reading the code
  finds the `toString` emit, which also fixes the uninitialised-buffer `catch 1` noted in
  BUG-703, and three `{u}` interpolation formats. That count is from reading. The real site map
  comes from emitting, see the fixture list, because Zig's `{u}` quietly writes U+FFFD for a
  surrogate and a missed site breaks the round trip with no error.
- `codePointCount` and `reverse` go through the same decoder.

The price:
- A program that builds U+DC80..U+DCFF on purpose gets a raw byte back from `toString()`.
  Python has the same rule.
- A classifier such as `isLetter` answers false for those chars.

## Recommendation

**C**, with `toValidUtf8()` for display. It is the only option that is both total and exact.
It changes no call site, and it meets Fable's comparison and store objection directly rather
than by making every loop handle an error.

B is the fallback if Fable wants refusal in the type. If so, the decision is whether it is
`chars()` that throws, or a new `tryChars(): List(char)?` beside a total `chars()`.

## What the fix's fixture must show

- `for c in "a\xffb".chars()` yields 3 items, the middle one `U+DCFF`, in Debug **and**
  `--release`, on both routes.
- **The test vectors live in a `v_poc` example**, so that `v-check` diffs the V and Zig runs on
  every `--v`, which closes BUG-712 and BUG-713's blind spot for good. The vectors are all 256
  single bytes, the edge cases from the decoder rules above (truncated sequences, encoded
  surrogates, overlongs, above U+10FFFF), and valid text in 1-, 2-, 3- and 4-byte forms. Each
  prints its item count and its rebuilt bytes in hex.
- **The char-to-text site map is DERIVED by emitting** a probe that turns a char into text in
  every position: `print(c)`, `"${c}"`, `"${c:c}"`, `toString()`, `StringBuilder.append`, `join`
  over a `List(char)`, and a map key. The output is grepped for `{u}` and `utf8Encode`. Reading
  finds fewer sites than emitting (`keyword-ident`'s record is 4 against 9).
- `"\xff"` and `"\xfe"` rebuild to different strings.
- Rebuilding any string char by char gives back exactly its bytes. Check this on valid text and
  on random bytes, as a loop over generated inputs.
- `codePointCount()` equals the iteration count.
- `toValidUtf8()` turns `"a\xffb"` into `"a�b"`.
- A `chars()` walk inside an `Http.serve` handler, fed `\xff\xfe` by a raw `Tcp` client, answers
  and keeps serving (BUG-701's control, A half).
