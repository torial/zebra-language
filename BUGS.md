<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-777. Next new bug: BUG-778.**

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

### BUG-777: `zebra --target v` does not run the type checker
- **Status:** OPEN (filed 2026-11-17; reported by Fable on 227b5b5. Fable is writing the fix in
  his worktree)
- **Repro:** `def f(n: int): int` / `return n + 1` / `def main()` / `var x: int = "a"` /
  `print(f("b"))`. `-c` reports both type mismatches; `--target v` writes the `.v`, reports
  "nothing refused: the whole file is in the subset" and exits 0. `xs.isEmpty()` on a List is
  refused at `-c` and emitted and RUN on V (it printed `true`).
- **Cause:** vTarget / vCollect / vLoadModule in `selfhost/main.zbr` resolve (an undefined name
  IS refused) and never call checkModule, so no front-end refusal reaches a V-only build --
  BUG-764's, BUG-767's and BUG-772's among them. No v_check row is affected: every compared
  program also builds on the Zig route, which checks.
- **Fix shape:** vTarget checks each collected module the way MultiCompiler's step 4 does (dep
  types, the reserved / public runtime names), on the ORIGINAL sources before the collision
  rename, printing errors and exiting 1 before anything is written.
- **Control when fixing:** the repro refused on `--target v` with `-c`'s messages and nothing
  written; a clean program still emits.

---

### BUG-775: an `extend str` method that does not use its receiver fails inside zig
- **Status:** OPEN (filed 2026-11-17; found writing BUG-773's `extend str` control)
- **Repro:** `extend str` / `def foo(): int` / `return 42`, then `print("a".foo())`. `-c` exits 0;
  zig: "unused function parameter" at `fn _ext_str_foo(self: []const u8) i64`.
- **Fix shape:** the extension's emitted function discards `self` (`_ = self;`) when the body
  does not reference the receiver, as a method that does not use `this` already does.
- **Control when fixing:** the repro prints 42; an extension that uses `.len()` is unchanged.
  Check `extend int` / `extend List(T)` for the same shape.

---

### BUG-774: `HashMap(float, V)` passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-17; found choosing BUG-773's receivers)
- **Repro:** `var m = HashMap(float, int)()` / `m[1.5] = 2`. `-c` exits 0; zig: "unable to hash
  type f64" in std/hash/auto_hash.zig. An empty map with no put compiles.
- **Fix shape:** refuse a float key type (and a Set(float) element) at the constructor and at an
  annotation, naming why -- the BUG-447 reasoning for `@derive(Hash)` on a float field (`0.0 ==
  -0.0` with different bits, `NaN != NaN`) -- and the fix (key on an int or str form).
- **Control when fixing:** the repro refused at its line; `HashMap(int, int)` unchanged.

---

### BUG-772: an unknown method after `?.` on a builtin receiver passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-17; found writing BUG-765's fixture, which first called
  `?.toUpper()`; reproduced on the pre-batch compiler and on the BUG-765 fix)
- **Repro:** `def name(n: int): str?` and `var u = name(1)?.bogus()`. `-c` exits 0; zig: "no field
  or member function named 'bogus' in 'str'". The same name on a plain `str` receiver is refused
  at `-c` ("'str' has no method 'bogus' (see QUICKSTART §14 ...)").
- **Fix shape:** the checker runs the receiver's method-name check (the `*MethodKnown`
  predicates, BUG-369) on the unwrapped type of an opt-chain call.
- **Control when fixing:** the repro refused at its line with the plain receiver's message;
  `name(1)?.upper()` unchanged.

---

### BUG-769: a `float32` receiver's methods are untyped by the checker; `-c` passes, zig refuses
- **Status:** OPEN (filed 2026-11-17; found by Fable while fixing BUG-768 on the V route.
  Zig route; mine.)
- **Repro:** `var n = sys.args().count()` / `var one: float32 = n.toFloat32()` /
  `var w = one.toFloat() * 2` / `print(w)`. `-c` exits 0; zig: "a.zbr:4: error: expected type
  'i64', found 'f64'". `print((one.toFloat() * 2).toFloat32())` fails the same way ("expected
  integer type, found 'f64'"). `${one.toFloat()}` alone in a hole works.
- **Where:** TypeChecker's member typing has an arm for `Type_.float_` (~5041) and none for
  `float_n`, so a sized float's `toFloat()` comes back unknown and the `* 2` is typed as int.
- **Fix shape:** the `float_` arm's methods for `float_n` too (or a shared predicate), with the
  receiver's own width where the method keeps it.
- **Control when fixing:** the repro prints 2.0 (or the arg count times 2); the same program
  with `var one: float` unchanged.

---

### BUG-770: a constant float expression folds at comptime_float precision, unlike the same sum at run time
- **Status:** OPEN (filed 2026-11-17; found by Fable comparing the routes. Zig route; mine.)
- **Repro:** `var a = 0.1` / `print(0.1 + 0.2)` / `print(a + 0.2)` / `print(0.1 + 0.2 == a + 0.2)`
  prints `0.3`, `0.30000000000000004`, `false`. Zig folds a literal-only expression as an
  arbitrary-precision `comptime_float` and rounds once at the end; the run-time sum rounds each
  operand to f64 first. The V route prints `0.30000000000000004` twice and `true` (C folds in
  double), so v_check cannot compare this shape until the routes agree.
- **Why it matters:** `float` is documented as f64, and a program's answer should not depend on
  whether an operand happened to be a literal. An `==` that is false between two spellings of
  one sum is the worst form of it.
- **Fix shape (to measure first):** type float literals as `f64` at an arithmetic operator
  (`@as(f64, 0.1) + 0.2`), so folding happens in f64. Needs an emit sweep and an output_sweep
  diff before landing: any baselined program printing a literal-only float expression moves.
- **Control when fixing:** the repro prints the same value twice and `true`; an int constant
  expression and a `const` float used as a comptime value unchanged.

---

### BUG-771: `var g: float32 = 16777217` passes `-c` and is refused by zig
- **Status:** OPEN (filed 2026-11-17; found by Fable. Zig route; mine. Minor.)
- **Repro:** `var g: float32 = 16777217`. `-c` exits 0; zig: "type 'f32' cannot represent
  integer value '16777217'", at the .zbr line. The words are good; the refusal is the back
  end's, so `-c` and the LSP do not see it.
- **Fix shape:** the front end refuses an int literal assigned to `float32` (or `float16`) that
  the float type cannot represent exactly, naming the nearest values; same check in a call
  argument and a return.
- **Control when fixing:** the repro refused at its line; `16777216` and `0.1` into a
  `float32` unchanged.

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
