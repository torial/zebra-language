<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-714. Next new bug: BUG-715.**

> **Numbering correction 2026-08-05.** Two different bugs were both filed as
> BUG-260 by sessions working in parallel. The query-param one below was filed
> first (`5717d80`) and keeps the number; the C-dependency one was filed later
> (`fcd9c7c`) and is **renumbered BUG-261**. Commit `fcd9c7c`'s message still
> says "BUG-260" — that is the record of what was written at the time and is
> left alone; look for BUG-261 in the ledgers.
>
> No gate could see this: `doc_lint` D4 only checks that a cited BUG-NNN exists
> *somewhere*, so a duplicate satisfies it twice over.

> ### FILING PRACTICE — read this before adding an entry
>
> **1. Leave the workaround in the CALLING code, with the bug number beside it.**
> A bug report says what broke. A workaround comment says what the author did
> *instead* — and that is the measurable cost of the defect, in a form nothing else
> captures. Receipt (2026-08-26): three entries in `C:/Projects/tinylm`'s Zebra sources
> — BUG-311, BUG-312 and one unfiled quirk — recorded that the author could not return a
> tuple of containers, could not share a generic `matvec` helper, and could not put
> functions in a class. Reading those three comments established in minutes that the
> code's whole shape was dictated by our defects rather than chosen, which no amount of
> reading the ledger would have shown. Prefer `# BUG-NNN: <what I had to do instead>`
> next to the distorted code.
>
> **2. A workaround also dates the defect's cost.** When the bug is fixed, the comment
> is the test: remove the workaround and see whether the natural form now works. Without
> it nobody knows which code was bent, so nobody straightens it and the tax is paid
> forever.
>
> **3. Reproduce before filing, and say so if you could not.** The same session tried to
> file that third quirk and *could not reproduce it* — top-level `def` and `static def`
> both mutated a list parameter correctly, nested `List(List(float))` included. It was
> NOT filed. An unreproducible entry costs a future reader more than a missing one, and
> "I could not reproduce this, here is exactly what I tried" is a legitimate thing to
> write in the ledger.
>
> **4. Measure both build modes for anything touching memory or arithmetic.** Every gate
> here builds Debug. BUG-313 is invisible in Debug and silently fabricates a value in
> `--release`; BUG-228 shipped Debug binaries from `--release` for four days under 19
> green gates. If an entry claims a safety property, it must say which mode it was
> measured in.

---

### BUG-701: a panic in an `Http.serve` handler ends the whole server process
- **Status:** OPEN (filed 2026-11-12; Fable, measured through the sprocket toolchain of 2026-11-08)
- **Observed:** `GET /task/\xff\xfe HTTP/1.1` (a path holding bytes that are not UTF-8) killed
  a Graze server: the next connection was refused. The handler walked the path as text
  (`split` / `chars()` / compare). **The operation is `chars()`** (Fable, 2026-11-12: with the
  guard removed, raw `\xff\xfe` went through `split`, `trim` and `==` and died in `for c in
  s.chars()`), filed on its own as BUG-703 -- a `str` operation that panics on bytes a peer
  controls is a crash any client can trigger.
- **The general shape, true by construction:** the accept loop calls the handler in-process,
  and a Zig panic is a process exit, so ANY handler defect is a denial of service. Graze's
  charter (§4.3) wants per-request recovery that answers 500 and keeps serving; Zig has no
  `recover`, so that needs a design (a worker process, or handlers that cannot panic on input),
  not a patch. **Decided 2026-11-12 (Sean):** option A (remove the panics input can reach,
  BUG-703 first), then option B (an opt-in supervising restart), and both are required;
  `docs/design/http_serve_recovery.md`. This entry closes when B lands.
- **Workaround today:** check `isValidUtf8()` on path, query and body first and answer 400
  (Graze does; witnessed red and green in `graze/tasks/check_tasks.py`).
- **Control when fixing:** a raw `Tcp` client sends the non-UTF-8 path; the server must answer
  it (400 or 500) AND answer the next request.

---

### BUG-702: `b.toInt()` on a byte from `s.bytes()` passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-12; found by Fable in Graze's percent-decoder, reproduced on the
  batch's compiler)
- **Repro:** `for b in "AB".bytes()` then `var n: int = b.toInt()`. `-c` exits 0; the build fails
  `error: expected float type, found 'u8'` -- the call is lowered as a float-to-int conversion.
- **Workaround:** `var n: int = b` (a byte widens to int), which Graze uses.
- **Fix shape:** the receiver's numeric kind decides the lowering: an integer receiver of any
  width is `@as(i64, b)`, never `@intFromFloat`.
- **Control when fixing:** the repro prints 65 and 66; `3.7.toInt()` keeps truncating.

---

### BUG-703: `s.chars()` panics on a string that is not valid UTF-8
- **Status:** OPEN (filed 2026-11-12; reproduced)
- **Repro:** `var s = "a" + "${255:c}" + "b"`; `s.isValidUtf8()` is false, and `for c in s.chars()`
  panics: `attempt to unwrap error: Utf8InvalidStartByte`. In an `Http.serve` handler that is
  BUG-701 -- any client sending such bytes ends the server.
- **Fix shape (a decision, not a patch):** yield U+FFFD for each invalid sequence (what most
  languages' lossy decoders do), or refuse at the call by returning nothing for the bad run.
  Either way, never panic on input bytes; `isValidUtf8()` stays the way to tell. Fable's leaning
  (2026-11-12, to be agreed in writing before building, since the V route needs the same answer):
  REFUSE in anything whose result feeds a comparison or a store, because two U+FFFDs compare
  equal (the reassuring-answer failure), and keep a separately named lossy conversion for display.
- **Release builds are worse (measured 2026-11-13):** the same repro under `--release` SEGFAULTS
  (`Segmentation fault at address 0x11`) instead of panicking. The loop is
  `std.unicode.Utf8View.initUnchecked(s).iterator().nextCodepoint()`, whose decode is
  `catch unreachable` inside std -- compiled ReleaseFast, outside the user functions'
  `@setRuntimeSafety(true)` (BUG-667/668), so it is undefined behaviour there. The fix must not
  use std's unchecked iterator.
- **Neighbours:** BUG-714 (`codePointCount()` returns 0 on the same input); BUG-712 (the V route
  yields bytes, so its answer differs even on valid text). Read, not run: a `char`'s `toString()`
  on a value `utf8Encode` rejects takes `catch 1` and returns one byte of an UNINITIALISED buffer
  (CodeGen.zbr, `_cpbuf`).
- **Proposal:** `docs/design/str_invalid_utf8.md` (2026-11-13), for agreement with Fable.
- **Control when fixing:** the repro iterates three items (or the chosen spelling's count) and
  exits 0, in Debug AND `--release`; a valid string's `chars()` is unchanged.

---

### BUG-704: `conn.readAll()` panics when the peer resets the connection
- **Status:** OPEN (filed 2026-11-12; found by the BUG-699 red-check)
- **Where:** `_tcp_read_all` ends `streamRemaining(..) catch |e| @panic(@errorName(e))`. A peer that
  resets instead of closing -- which any server does when it closes with unread input -- turns
  into `panic: ReadFailed` in the CLIENT: a remote peer can crash a program by misbehaving.
  Seen 8 of 8 runs against `Http.serve` with its lingering close removed.
- **Fix shape:** return what arrived. `read()` already treats an error as end of stream; whether
  `readAll` should also distinguish "reset" from "closed" is the decision to make (QUICKSTART
  says `""` at EOF for `read`, nothing for `readAll`).
- **Control when fixing:** a `Tcp.serve` handler that writes a reply and closes with unread input;
  the client's `readAll()` returns the reply (or what arrived) and the program exits 0.

---

### BUG-705: an unbraced `ë` in a string passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-12; found writing the Crypto batch's fixtures, reproduced on 8ac485e)
- **Repro:** `print("cafë")` (the Python/JSON spelling). `zebra -c` exits 0; the build fails in
  the emitted Zig with `error: expected '{', found '0'` -- the escape is passed through verbatim.
- **Why it is a leak, not a typo:** the lexer already refuses an unknown escape at its column --
  `"a\wb"` gives `unknown escape \w in a string -- the escapes are ... \u{N}` -- but it accepts
  `\u` without checking that `{` follows.
- **Fix shape:** refuse `\u` not followed by `{` at the escape's column, naming the braced form
  (`\u{00eb}`); the same check for an unterminated `\u{`.
- **Control when fixing:** the repro is refused by `-c` with a column; `print("caf\u{00eb}")` still
  prints `cafë`. Write the fixture from Python or an editor: bash `printf` rewrites `\u` itself.

---

### BUG-708: `private` is not enforced from another module, and never on methods
- **Status:** OPEN (filed 2026-11-13; Fable from Graze, reproduced on 0aaf714)
- **Repro:** `vault.zbr` declares `class Vault` with `private var secret: str`, `private var log:
  StringBuilder` and `private def hidden(): str`. `other.zbr` does `use vault exposing Vault`, then
  `v.secret = "w"`, `v.log.append("x")`, `print(v.hidden())`. `zebra -c other.zbr` exits 0 and the
  program runs, printing the written value through both methods.
- **Two defects, measured separately:**
  1. **Fields, across modules.** In ONE file the field shapes are refused at their column
     (`'secret' is private`, `'log' is private`, for a read, a write and a container mutation).
     From another module none is. The check in `TypeChecker.zbr` (`'...' is private`, near the
     BUG-680 runtime-object arms) asks only `ctx.module_types.isPrivateMember`; a dep's class
     records its private keys in `dep_types`, which is never consulted (reading, not yet
     measured: `populateModuleTypes` runs `addClassMembers` for deps, which records the key).
  2. **Methods, everywhere.** `v.hidden()` is accepted even with the class and the call in the
     same file. `addClassMembers` records a private method's key, but no call path reads it.
- **Cost:** QUICKSTART §18 says `private` "restricts the member to the owning class". A type whose
  point is an invariant -- Graze's `SafeHtml` keeps its text in a private `StringBuilder` so only
  its methods can write it -- has no guarantee from the compiler. Graze covers it with a source
  check of its own.
- **Fix shape:** an `isPrivateMemberAny` beside `fieldTypeAny` (own module, dep table, bare-name
  fallback), used by the field check; the same test on the member-call path for methods, with
  the owning-class exemption. A refusal names the member and the class (`'hidden' is private to
  Vault`). Before landing, measure: `-c` refusal counts over this repo, zebra-ide and the
  GameEngine before and after, since a private method called from outside may exist today.
- **Control when fixing:** each of the four repro lines refused at its column across modules, and
  the method call refused in one file; the class's own methods still read and call every
  private member; a public member of the same class still reachable from `other.zbr`.

---

### BUG-709: `zebra -c` accepts a `str` or `int` where a class is expected
- **Status:** OPEN (filed 2026-11-13; Fable from Graze, reproduced on 0aaf714)
- **Repro:** `class SafeHtml` and `def html(body: SafeHtml)`; then `html("<p>")`, `return name`
  from `def f(name: str): SafeHtml`, and `var h: SafeHtml = name`. `-c` exits 0 on all three.
  `--check-full` and a build refuse at the `.zbr` line (`expected type '*SafeHtml', found
  '*const [3:0]u8'`), so a build never ships it. `html(5)` and `html(Other())` with another
  class pass `-c` too; `-c --strict` sees none of them.
- **Cost:** `-c` is the fast check the IDE and the LSP run on every edit; a wrong argument type
  shows up only at build, as a Zig type name. `--help` says `-c` can pass code a build refuses,
  but plain argument types are the first thing a reader expects it to cover.
- **Fix shape:** in the call-argument loop, the typed-`var` check and `return`, refuse a value
  whose type is KNOWN (a literal, a `str`/`int`/`float`/`bool` local, another class) where the
  slot is a user class, naming both types. An unknown type is not refused (the BUG-632 rule).
  Measure `-c` counts over the three corpora first.
- **Control when fixing:** the five shapes refused at their columns; a `SafeHtml` value, a
  `SafeHtml?` slot given `nil`, and an interface slot given an implementing class still pass.

---

### BUG-711: `DateTime.inZone` answers in UTC for a zone it does not know, without saying so
- **Status:** OPEN (filed 2026-11-13; found building the Pocket Lab manager's `watch`)
- **Repro:** `DateTime.of(2026, 1, 15, 12, 0, 0).inZone("America/Phonix")` (a typo) and
  `.inZone("America/Boise")` (a real IANA zone the runtime's table lacks) both format as `12:00`,
  the UTC time; `"America/Phoenix"` correctly gives `05:00`. QUICKSTART says "Unknown zone names
  fall back to UTC (no crash)". A program that labels the time with the zone it asked for prints
  a wrong time with a right-looking label, and a one-letter typo is indistinguishable from UTC.
- **Correction (2026-11-13, same day):** this entry first gave `America/Phoenix` as the repro and
  said the table lists 10 zones. Both were wrong: QUICKSTART's 10 rows are "representative
  (~75 total)", the runtime's table has Phoenix, and Phoenix formats correctly. Measured with
  the probe above before correcting.
- **Second half:** nothing reads the machine's own zone, so a program cannot print local time
  without the user naming an IANA zone; `DateTime.now()` is documented as "current wall-clock
  time", which reads as local.
- **Fix shape (a decision):** refuse a literal zone outside the table at `-c` and panic or return
  nil at run time for a computed one -- a default that reads as an answer is the UNGIT
  "fabricated" case; and add a local-zone read (`DateTime.local()`, or `inZone("local")`) from
  the OS. Say "UTC" in the `DateTime.now()` row.
- **Control when fixing:** `inZone("America/Phonix")` no longer answers UTC silently;
  `inZone("America/Phoenix")` (05:00 at 12:00 UTC) and `inZone("America/Denver")` unchanged.

---

### BUG-712: on the V route `s.chars()` yields BYTES, not codepoints
- **Status:** OPEN (filed 2026-11-13; found preparing the BUG-703 proposal)
- **Repro:** `for c in "aéb".chars()` counting and printing each `c`. The Zig route iterates 3
  times (`a`, `é`, `b`); the V route (`--target v`, V b399a50) iterates 4 times and prints
  `97 195 169 98`. Valid input, different answers.
- **Cause:** `CodeGenV.zbr` lowers `chars` to `zlist_of[u8](obj.bytes())` with the comment "Zebra's
  char is a byte", and `docs/design/v_backend_poc.md` repeats it. QUICKSTART ("Bytes, codepoints,
  and graphemes") says a `char` is a decoded codepoint (`u21`), and the Zig route does that.
- **Why no gate saw it:** `v-check` compares the V and Zig runs of the `v_poc` examples and the
  selfhost dumps; none of them iterates `chars()` over non-ASCII text.
- **Fix shape:** decode on the V route too (V's `s.runes()`, or the runtime's own decoder so
  invalid bytes get the same answer as BUG-703's on Zig). Settle BUG-703's spelling first: the V
  route must give the same answer for invalid bytes, not only valid ones.
- **Control when fixing:** the repro iterates 3 times on both routes with the same output; an
  ASCII string unchanged.

---

### BUG-713: on the V route `"${n:c}"` with an `int` writes a codepoint, not one byte
- **Status:** OPEN (filed 2026-11-13; found with BUG-712)
- **Repro:** QUICKSTART's own percent-decoder example, `sb.append("${206:c}")`,
  `sb.append("${184:c}")`, `print(sb.build())`. Zig prints `θ` (2 bytes); V prints `Î¸` (4 bytes).
  A runtime `int` the same: `"${k:c}"` with `k = 206` is 1 byte on Zig, 2 on V.
- **Why it matters:** QUICKSTART documents `:c` on an `int` as EXACTLY ONE BYTE, so a decoder can
  assemble UTF-8 a byte at a time; on V every percent-decoded non-ASCII character is corrupted,
  silently. Graze's `percent_decode` is this shape.
- **Fix shape:** on an `int` argument, `:c` writes the low byte; on a `char`, the UTF-8 encoding.
  The argument's type decides, as on the Zig route.
- **Control when fixing:** the example prints `θ` with `len` 2 on both routes; `"${c:c}"` for a
  `char` `é` stays 2 bytes.

---

### BUG-714: `s.codePointCount()` returns 0 for a string that is not valid UTF-8
- **Status:** OPEN (filed 2026-11-13; part of BUG-701 option A's list)
- **Repro:** `("a" + "${255:c}" + "b").codePointCount()` is `0`; the string has 3 bytes and is not
  empty. The emit is `std.unicode.utf8CountCodepoints(s) catch 0` (CodeGen.zbr, two sites).
- **Why it matters:** 0 is the count of the empty string, so it reads as an answer ("nothing
  here") rather than as "could not count" -- a length check on input passes whatever it holds.
- **Fix shape:** count by the same rule BUG-703 settles for `chars()`, so that `codePointCount()`
  always equals the number of items `chars()` yields; never a constant on failure.
- **Control when fixing:** the repro's count equals the `chars()` iteration count of the same
  string; `"aéb".codePointCount()` stays 3.

---

### DESIGN-001: Throws auto-propagation scope — nested expression calls require `?`
- **Not a bug** — by design
- **Description:** Throws auto-propagation emits `try` for direct self-method calls and statement-level calls whose receiver is a `throws` method. It does NOT auto-propagate for:
  - `localVar.method()` — receiver is a local variable
  - `this.field.method()` — chained member access through a field
  - Calls nested inside compound expressions
- **Required action:** Use explicit `?` suffix for these cases: `localVar.method()?`, `this.field.method()?`

---

### DESIGN-002: `collectAndEmitOldSnapshots` (selfhost) missing `Expr` arms
- **Status:** Fixed — `selfhost/codegen.zbr` `collectAndEmitOldSnapshots`; `test/contract_old_compound_test.zbr` covers the `array_lit` case; 31/31 smoke, bootstrap 5/5.
- **Was:** `selfhost/codegen.zbr` `collectAndEmitOldSnapshots` fell through to `else: pass` for 8 compound Expr variants. An `old expr` nested inside any of these produced an undeclared-identifier Zig compile error: the `defer` block referenced `_old_N` but no snapshot was ever emitted.
- **Confirmed failing test:** `ensure val in @[old val, n]` — `old val` inside `array_lit` — produced `error: use of undeclared identifier '_old_0'` before the fix.
- **Fixed arms added:**
  - `array_lit` — iterate `elems`, recurse each
  - `list_lit` — iterate `elems`, recurse each
  - `tuple_lit` — iterate `elems`, recurse each
  - `dict_lit` — iterate `entries`, recurse `entry.key` and `entry.value`
  - `string_interp` — iterate `parts`; recurse only `StringPart.expr_` arms
  - `type_check` — recurse into `tc.expr`
  - `slice` — recurse `sl.object`; recurse `sl.start to!` and `sl.stop_ to!` if non-nil
  - `except_` — recurse `ex.base`; recurse each `f.value` in `ex.fields`
  - `lambda` — left as no-op (correct: `old` inside a lambda body is semantically unsound)
  - Leaf nodes — left as `else: pass` (correct: can't contain `old_`)
- **Note on slice optional fields:** `ExprSlice.start: ^Expr?` uses `!= nil` + `to!` (not `if x as s`) — consistent with the existing `genExpr` slice handling in the selfhost.
- **Files:** `selfhost/codegen.zbr` (`collectAndEmitOldSnapshots`), `test/contract_old_compound_test.zbr` (new), `tools/selfhost_smoke.sh` (new smoke entry).


---

### INFRA-001: --update non-idempotence on first run after certain bootstrap states
- **Not a bug** — cosmetic only; both output forms compile and round-trip correctly
- **Symptom:** The first `bash tools/bootstrap_check.sh --update` (or `zig build update-selfhost`)
  after a full bootstrap or manual `/tmp/bs-zig` copy can produce `selfhost/*.zig` files with
  the header `// Generated by the Zebra compiler.` (bootstrap style) rather than the expected
  `// Generated by zebra-selfhost.` (selfhost style). Subsequent `--update` runs are stable and
  idempotent on the selfhost-style output.
- **What to do:** If you see bootstrap-style headers after `--update`, just run `--update` once
  more. The second run will produce the correct selfhost-style headers and stay there.
- **Root cause (partial):** `codegen.zbr` line 808 (`generateFullWithDeps`) and line 831
  (`generateDepWith`) both emit `"// Generated by zebra-selfhost.\n"`, so selfhost-A should
  always produce selfhost-style output. The first-run anomaly may be a stale `zebra-selfhost.exe`
  binary that predates step 2's rebuild, or Zig build-cache reuse in step 2 that skips the
  recompile when source timestamps haven't changed. Not fully traced.
- **Where this is also documented:** Comment in `tools/bootstrap_check.sh` update-mode header.
