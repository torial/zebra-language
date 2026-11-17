<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-768. Next new bug: BUG-769.**

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

### BUG-741: `HttpResponse(status, text)` passes `-c`, then `.withHeader` on it fails inside zig
- **Status:** OPEN (filed 2026-11-15; found writing the BUG-701 option A sweep; reproduced on e4045ec)
- **Repro:** `var r = HttpResponse(200, "body")` / `return r.withHeader("X", "1")` -> zig: "no
  field or member function named 'withHeader' in 'zebra_rt.HttpResponse'". With
  `HttpResponse.new(200, "body")` the same code works.
- **Fix shape:** route `withHeader` on any HttpResponse-typed receiver, or refuse the bare
  constructor at `-c` naming `HttpResponse.new`.
- **Control when fixing:** the repro sends the header, or `-c` refuses it at its line.

---

### BUG-742: `r.withHeader(...)` as a statement silently does nothing
- **Status:** OPEN (filed 2026-11-15; found writing the BUG-701 option A sweep; reproduced on e4045ec)
- **Repro:** `var r = HttpResponse.new(200, "body")` / `r.withHeader("X", "1")` / `return r` --
  builds and runs, and the response has no `X` header. `withHeader` returns a NEW response
  (QUICKSTART), and the statement drops it with no word.
- **Fix shape:** refuse at `-c` a `withHeader` whose result is discarded, naming the
  `return r.withHeader(..)` / `r = r.withHeader(..)` forms.
- **Control when fixing:** the repro is refused at its line; both suggested forms compile.

---

### BUG-744: a class or container as a generic function's type argument emits a name zig cannot find
- **Status:** OPEN (filed 2026-11-15; found writing BUG-709's ok fixture; reproduced on 718330a)
- **Repro:** `class Box` with a field, `def same(T)(x: T): T` returning `x`, then
  `print(same(Box)(b).s)`. `-c` passes; the build fails `use of undeclared identifier 'Box'` at
  the call's `.zbr` line. The emit is `_zbr_fn_same(Box, b)`: since BUG-281 B a Zebra type is
  `_zbr_ty_Box` in the generated Zig, and the type-argument position was not given the prefix.
  A struct (`same(Pt)(Pt())`) fails the same way, and so does a container type argument:
  `same(List(int))(xs)` emits a bare `List` ("undeclared identifier 'List'"). `same(int)(5)` works.
- **Cost:** a generic function can be instantiated only with scalar built-in types; with a class,
  struct or container the program cannot be built, and the message is about generated code.
- **Fix shape:** the emit of a generic call's type arguments goes through the same type-name
  spelling as every other type position (the `_zbr_ty_` prefix for a user type, a qualified one
  for a `use`d module's).
- **Control when fixing:** `same(Box)(b).s` and `same(Pt)(Pt()).x` build and print; `same(int)(5)`
  unchanged; `same(List(int))(xs)` builds and prints `[1, 2]`.

---

### BUG-753: a class field `HashMap(str, C) = {}` passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-15; found by Fable on the V route's side of the engine work)
- **Repro:** `class Reg` with `var by: HashMap(str, Node) = {}` (`Node` a class), `Reg()`, then
  `r.by.set("a", Node())`. `-c` exits 0; the build fails `expected type
  '*hash_map.HashMap([]const u8,*_zbr_ty_Node,...)', found '*hash_map.HashMap([]const
  u8,[]const u8,hash_map.AutoContext([]const u8),80)'` -- the `{}` default is emitted as
  `_ZbrAutoMap([]const u8, []const u8)` whatever the field's declared type.
- **Workaround:** `= HashMap(str, Node)()`.
- **Fix shape:** the empty-literal default takes its type from the field's declaration (the V
  route refuses `= {}` and `= []` there by name; matching the Zig route is the other option).
- **Control when fixing:** the repro prints `1`; `= HashMap(str, Node)()` unchanged; an empty
  `= []` default on a `List(Node)` field checked the same way.

---

### BUG-759: an int LITERAL under `:x` (`${255:x}`) passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-16; found by Fable taking the Zig route's reference output
  for the V format-spec work)
- **Repro:** `print("[${255:x}]")`. `-c` exits 0; the build fails `cannot @bitCast from
  'comptime_int'`, reported at the line of the enclosing `def`, not the `print`. A runtime int
  (`var n = 255`, `${n:x}`) prints `ff`.
- **Also seen once (not reproduced):** in a larger file whose only bad line was this hole, Fable
  saw `zebra file.zbr` exit 1 with no error line and leave a `.fast.exe` whose entry point was
  the image base. Two runs of the same file here printed the error each time; recorded so a
  second sighting can be matched to it.
- **Control when fixing:** the repro prints `[ff]`; a runtime int unchanged; `${255:08x}`
  and `${-1:x}` checked the same way.

---

### BUG-762: `for x in .items(n)` on a user method named `items` types `x` as `str`
- **Status:** OPEN (filed 2026-11-16; found writing BUG-729's probe)
- **Repro:** a class with `def items(n: int): List(int)` and, in another method,
  `for x in .items(n)` / `s = s + x` -> `-c` refuses "cannot concatenate 'int' and 'str'" at the
  `+`. The same code with the method named `vals` prints 3. A false refusal: the loop
  variable is typed by the NAME `items` (a map's `entries`-style iteration), not by the
  method's declared return.
- **Control when fixing:** the repro prints 3; `for k, v in m.items()` on a Map unchanged.

---

### BUG-763: a local named like the method-level `catch` binding, read in the catch, fails inside zig
- **Status:** OPEN (filed 2026-11-16; found writing BUG-729's probe; reproduced on the pre-fix
  compiler)
- **Repro:** `def g(n: int): int` with `var t = f(n)` (f throws), `var e = List(int)()`, and
  `catch |e|` whose body does `print("caught ${e}")` -> zig "use of undeclared identifier 'e'"
  at the print. With the catch body not reading `e`, or the local renamed, it builds.
- **Control when fixing:** the repro prints `caught ...` for a raising `f` and the sum
  otherwise; the catch reads the ERROR, not the local (or the shadowing is refused by name).

---

### BUG-764: a method-level `catch` on a body that cannot fail passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-16; found writing BUG-729's probe; reproduced on the pre-fix
  compiler)
- **Repro:** `def g(): int` / `var e = 5` / `return e` / `catch |e|` / `return -1` -> zig "unused
  block label" at the `def`. BUG-546 refuses a postfix `catch` / `?` on a call that cannot fail;
  this is the method-level form of the same thing.
- **Control when fixing:** refused in Zebra's words at the `catch` ("nothing in the body can
  fail -- drop the `catch`"), or accepted and built; a body with one throwing call unchanged.
- **Second witness (2026-11-17, the GameEngine session):** `C:/tmp/graze_probe/p2_idle_catch.zbr`
  -- the catch over a body whose only call is a non-throwing function of a `use`d module; zig
  "p2_idle_catch.zbr:4: error: unused block label". A row in graze's table since 11-14.

---

### BUG-765: `?.count()` on an optional `List` fails inside zig
- **Status:** OPEN (filed 2026-11-16; found writing BUG-729's probe; reproduced on the pre-fix
  compiler)
- **Repro:** `def maybe(n: int): List(int)?` and `var m = maybe(n)?.count()` -> zig "no field
  or member function named 'count' in 'List(int)'". The opt-chain arm emits the method name
  raw on the unwrapped value, so a builtin receiver method (whose emit is not `.count()`)
  never goes through its own dispatch.
- **Control when fixing:** the repro yields 1 for `maybe(1)` and nil for `maybe(-1)`; a user
  class method through `?.` unchanged.

---

### BUG-767: a `?`-marked throwing call inside a lambda passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-17; found by the GameEngine session writing graze's gate;
  repro `C:/tmp/graze_probe/p3_lambda.zbr` with `riskclient.zbr`, reproduced on d46646c)
- **Repro:** `var hs: List(def(int): str) = []`, then `hs.add(def(n: int): str` /
  `var xs = risky(n)?` / `return "lambda ${xs.count()}")` with `risky` throwing. `-c` exits 0;
  zig: "p3_lambda.zbr:7: error: expected type 'str', found 'anyerror'". The UNMARKED form is
  refused at `-c` ("throws call needs '?'"), so only the marked one slips: a `?` inside a
  lambda propagates out of a body whose `def(...)` type cannot raise.
- **Fix shape:** the BUG-730 rule applied to a lambda body -- a `?` that would propagate out of
  a lambda is refused at the `?`, naming that a function type cannot raise and the fixes
  (handle it in the lambda, or `orelse`/`catch` the call).
- **Control when fixing:** the repro refused at 7; a lambda that calls a non-throwing function,
  and one that handles the error itself, unchanged.

---

### BUG-768: the V route does not map `float32`
- **Status:** OPEN (filed 2026-11-17 by Fable, the V route's owner, fixing BUG-761; 767 is the
  Zig side's, the throwing lambda). **V route only; Fable's to fix** (CodeGenV.zbr /
  zebra_rt.v).
- **What:** CodeGenV's `vNamed` maps `float` to `f64` and passes `float32` through as written,
  which is no V type, and its arithmetic knows one float type: `test/bug445_mixed_numeric_test.zbr`
  emits with nothing refused and then fails in V ("cannot use `float literal` as `float32`",
  "mismatched types `float32` and `i64`", "float modulo not allowed", and an `f64` handed to
  the i64 helper `zmul`). The width is lost in the type name rather than refused, as the sized
  ints' was before BUG-761.
- **Fix shape:** `float32` is V's `f32`; the checker's float half of `numericJoin` restated
  beside BUG-761's `vIntJoin` (float32 with an int stays float32, float32 with float is
  float); `%` on floats through `math.fmod`; a float operand never reaches the i64 helpers.
  `float16` / `float128` refused by name (V has neither).
- **Control when fixing:** bug445's fixture prints the same on both routes under `v-check`;
  a `float32` sum that differs from the `float` sum of the same operands (0.1 + 0.2) prints
  the float32 digits on both.

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
