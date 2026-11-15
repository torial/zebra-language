<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-743. Next new bug: BUG-744.**

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

### BUG-721: `HttpResponse.text` (and its other fields) have no type in the checker
- **Status:** OPEN (filed 2026-11-13; found building the Pocket Lab manager's model calls)
- **Repro:** `def g(resp: HttpResponse)` with `var u = resp.text` then `print(u.len)`: `-c`
  refuses "cannot infer the type of `u`, so `.len` cannot be resolved". The same through
  `if r as resp` and through `resp.text.replace(..)`. A field read off a runtime object type
  is untyped, so every use past a method call needs an annotation (`var u: str = resp.text`).
- **Fix shape:** type `HttpResponse`'s fields (`status: int`, `text: str`, `headers`) where its
  methods are typed (BUG-680's runtime-object tables), and check the other runtime objects'
  fields the same way.
- **Control when fixing:** the repro passes `-c` and prints the length; an unknown field on an
  `HttpResponse` is refused by name.

---

### BUG-722: `Json.array().append(v)` with a JsonValue passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-13; found building the Pocket Lab manager's model calls)
- **Repro:** `var m = Json.object()`, `m.put("role", "user")`, `var arr = Json.array()`,
  `arr.append(m)`. `-c` exits 0; the build fails `error: expected type 'str', found
  'json.dynamic.Value'`. `put(k, obj)` is the same shape. So JSON objects cannot be nested
  through the builder, and the front end does not say so.
- **Workaround:** stringify each scalar-only object and join the request body as text
  (`plm.zbr`'s `jq()`).
- **Fix shape (a decision):** either `append`/`put` take a JsonValue (nesting, which is what a
  request body needs), or a JsonValue argument is refused at `-c` naming the scalar forms.
  The first is the useful one.
- **Control when fixing:** the repro stringifies to `[{"role":"user"}]`, or is refused at `-c`
  by name; scalar `append`/`put` unchanged.

---

### BUG-724: a zig the compiler cannot start is reported as "spawn failed", naming nothing
- **Status:** OPEN (filed 2026-11-13; found running the Pocket Lab manager's tools)
- **Repro (Git Bash):** `source tools/zig_toolchain.sh` (exports `ZEBRA_ZIG=/c/Users/.../zig.exe`,
  a POSIX-style path), then `MSYS_NO_PATHCONV=1 zebra prog.zbr`. Git Bash normally rewrites that
  path to Windows form for a native program; `MSYS_NO_PATHCONV=1` turns the rewrite off for the
  environment too, so the compiler tries to start a zig at a path Windows cannot find. All it
  prints is `spawn failed` -- not which program, not the path, not that the path came from
  `ZEBRA_ZIG`. It took six runs to isolate, two of them misread (one success came from a shell
  that had not sourced the toolchain, so `ZEBRA_ZIG` was unset).
- **Where:** `_sys_run` turns `error.FileNotFound` into the bare text "spawn failed"; main's zig
  resolution (`getenv("ZEBRA_ZIG")`) takes the variable without checking that it exists.
- **Fix shape:** check `ZEBRA_ZIG` when it is resolved and refuse naming it ("ZEBRA_ZIG names
  /c/... which does not exist"; on Windows add that a /c/... path is Git Bash's spelling); and
  make the spawn failure name argv[0].
- **Control when fixing:** `ZEBRA_ZIG=/nonexistent/zig.exe zebra hello.zbr` says ZEBRA_ZIG and the
  path; a valid `ZEBRA_ZIG` unchanged.

---

### BUG-725: a runtime `int` formatted with a width prints a `+` sign
- **Status:** OPEN (filed 2026-11-13; found building the Pocket Lab manager's dialogue report)
- **Repro:** `var n = sys.args().count()` (1), then
  `print("[${n:>3}] [${n:3}] [${n:<3}] [${7:>3}] [${n:03}] [${-n:>3}]")` prints
  `[ +1] [ +1] [+1 ] [  7] [001] [ -1]`. A width on a RUNTIME signed int adds a `+` the program
  never asked for; the literal `7` and the zero-padded form are right. Python prints
  `[  1] [  1] [1  ] [  7] [001] [ -1]` for the same specs, and QUICKSTART's format-spec section
  describes Python's meaning.
- **Likely cause:** the hole emits Zig's `{d:>3}` over an `i64`; Zig's integer formatting shows the
  sign of a signed value when a width is given. A `comptime_int` (the literal) takes another path.
- **Fix shape:** format a signed int with a width the way `_zbr_zpad` already does for the `0`
  flag -- through a runtime helper that writes the sign only when negative (or when the spec has
  `+`) -- and pin every alignment.
- **Control when fixing:** the repro prints `[  1] [  1] [1  ] [  7] [001] [ -1]`; `${n:+>3}` and
  `${n:+}` still show the sign where the spec asks for it.

---

### BUG-728: an imported function's `throws` is invisible to the front end
- **Status:** OPEN (filed 2026-11-14; found by the GameEngine session moving procgen's generated
  clients to `throws`; repros `C:\tmp\conc\optprobe\xmod`, reproduced on d9067e4)
- **Repro:** `riskmod.zbr` declares `def risky(n: int): List(int) throws`; a caller does
  `use riskmod exposing risky`. `-c` passes all five shapes. (1) An unmarked call is not refused
  for want of `?`; zig refuses it instead: `var xs = risky(n)` then `xs.count()` -> "type
  'anyerror!List(int)' does not support field access", and a bare `risky(n)` statement -> "error
  union is discarded". (2) Under a method-level `catch |e|` the unmarked call is not routed to the
  catch: zig reports "unused block label" at the def's line. The marked form, `risky(n)?`, under
  the same catch works ("ok 1" / "caught: refused -2"), and so does the same program in one module.
- **Why it matters:** QUICKSTART §12 says the `?` rule holds across modules. The user gets a zig
  diagnostic about code they never wrote, and the catch they wrote does nothing until they add `?`.
- **Fix shape:** carry `throws` on the imported signature the checker sees (the table that already
  carries the return type), so the unmarked-call refusal and the method-catch routing both fire.
- **Control when fixing:** both unmarked repros are refused at `-c`, naming `risky` and `?`; the
  marked form is unchanged; a same-module throws call is unchanged.
- **Downstream when fixed:** graze's `check_gate.py` (GameEngine session, graze ec70545) builds five
  ways of ignoring a refusal and expects each refused; today that rests on zig's errors, so those
  five expectations change to this refusal's wording when it lands -- tell that session.

---

### BUG-729: an unmarked throwing call nested in an expression, under a method-level `catch`, passes `-c` and emits Zig that does not parse
- **Status:** OPEN (filed 2026-11-14; found by the GameEngine session in zebra-sprocket's check_crud
  driver; reproduced on d9067e4)
- **Repro:** one module, `def risky(n: int): List(int) throws`, and a def ending in `catch |e|`
  that uses the call without `?` as a `for` operand (`for x in risky(n)`) -> zig "expected ','
  after for operand"; or inside an interpolation (`"count ${risky(n).count()}"`) -> zig "expected
  ',' after argument". `-c` passes both.
- **Why it matters:** DESIGN-001 says a throwing call nested in an expression needs an explicit
  `?`, and with it both positions work (`for x in risky(n)?` and `"${(risky(n)?).count()}"` print
  the right values and route a raise to the catch). So the front end owes a refusal here and
  emits text that is not Zig instead.
- **A trap in the fix's wording:** `risky(n)?.count()` is read as optional chaining (`?.`) and
  fails inside zig ("expected optional type, found 'List(int)'"); only `(risky(n)?).count()` or a
  temp works. A refusal that suggests "add `?`" must say where, or it sends the user into a
  second zig error.
- **Fix shape:** refuse an unmarked throws call in a non-statement position at `-c`, naming the
  call and the parenthesised form; separately, decide whether `f()?.m()` on a throws call should
  parse as propagate-then-call.
- **Control when fixing:** both unmarked positions are refused at their lines; the marked forms
  still print "walked 2 / caught: refused -2 / count 1 / caught: refused -2"; a call bound to a
  var is unchanged.

---

### BUG-730: a throwing function passed where a non-throwing `def` type is expected is refused only by zig, inside zebra_rt.zig
- **Status:** OPEN (filed 2026-11-14; found by the GameEngine session; repro
  `C:\tmp\conc\optprobe\t_value.zbr`, reproduced on d9067e4)
- **Repro:** `def propagates(n: int): str` calls `risky(n)?` (so it throws), and is passed to
  `def dispatch(h: def(int): str, n: int)`. `-c` passes; zig: "expected type '[]const u8', found
  'anyerror![]const u8'" at `zebra_rt.zig:3794`, with no .zbr line at all.
- **Fix shape:** the checker compares the argument's throwing-ness against the `def` type and
  refuses at the call site, naming the function and the parameter.
- **Control when fixing:** refused at `-c` at the call's line; a non-throwing handler passed the
  same way is unchanged.

---

### BUG-731: an optional list used as a list is refused only by zig, and the `else` of `if x == nil` does not narrow
- **Status:** OPEN (filed 2026-11-14; found by the GameEngine session; repros
  `C:\tmp\conc\optprobe\p_for.zbr`, `p_pass.zbr`, `n_narrow.zbr`, reproduced on d9067e4)
- **Repro:** `def gone(d: SqliteDb): List(ItemRow)?`. (1) `for it in gone(d)` passes `-c`; zig:
  "type '?List(ItemRow)' does not support field access". (2) `page(gone(d))` where
  `page(xs: List(ItemRow))` passes `-c`; zig: "expected type 'T', found '?T'". (3)
  `if ys == nil` / `print("ys is nil")` / `else` / `print("ys count ${ys.count()}")` is refused
  at `-c` (n_narrow.zbr:26:27, "'ys' may be nil here"), although the `else` branch can only run
  when `ys` is not nil; the early-return form of the same test narrows.
- **Why it matters:** (1) and (2) are the nil-safety rule failing open into zig's words; (3)
  refuses code the language says is safe.
- **Fix shape:** the checker refuses an optional where a non-optional list is required (`for`
  operand, argument), naming `!` and `if ... as`; narrowing applies to the `else` of `== nil` as
  it does to the `then` of `!= nil`.
- **Control when fixing:** (1) and (2) refused at `-c` at their lines; (3) prints "ys is nil";
  the early-return narrowing is unchanged.

---

### BUG-732: `use risky exposing risky` (a module and a function it exposes sharing a name) fails inside zig
- **Status:** OPEN (filed 2026-11-14; found by the GameEngine session; reproduced on d9067e4)
- **Repro:** `risky.zbr` is `def risky(n: int): int` / `return n * 2`; `main.zbr` is
  `use risky exposing risky` / `def main()` / `print(risky(21))`. `-c` passes; zig: "use of
  undeclared identifier '_zbr_fn_risky'" at main.zbr:4.
- **Fix shape:** resolve the exposed name to the module's function, not to the module; if that is
  ambiguous by design, refuse at `-c` naming both.
- **Control when fixing:** the repro prints 42; `use riskmod exposing risky` is unchanged.

---

### BUG-738: `s.hash()` passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-15; found writing the BUG-701 option A sweep; reproduced on e4045ec)
- **Repro:** `print("a".hash())` -> zig: "no field or member function named 'hash' in 'str'".
- **Cause:** `hash` is in TypeChecker's str method list (since BUG-369) with no CodeGen arm. It is
  in SURFACE.md's str list and in no QUICKSTART table.
- **Fix shape (decision pending):** remove it from the list (it never worked; a `str: -hash`
  surface line), or give it an arm (`Hash.fnv64` already exists).
- **Control when fixing:** either `-c` refuses `"a".hash()` naming the method, or it prints a value.

---

### BUG-739: `x == nil` on a non-optional class or runtime struct passes `-c`; `Uri.parse` is documented as optional and is not
- **Status:** OPEN (filed 2026-11-15; found writing the BUG-701 option A sweep; reproduced on e4045ec)
- **Repro:** `print(mk() != nil)` where `def mk(): P` returns a class -> zig: "comparison of '*P'
  with null"; `print(Uri.parse(s) != nil)` -> "comparison of 'zebra_rt.UriResult' with null". The
  same test on an `int` is refused at `-c` ("'int' is never nil").
- **Second half:** QUICKSTART's table says `Uri.parse(s)` returns `UriResult?`. It returns a
  `UriResult` whose fields are all empty (port 0) when the text does not parse -- a made-up value,
  and the reason a reader writes the `!= nil` above.
- **Fix shape:** the "is never nil" refusal for every non-optional type; `Uri.parse` returns
  `UriResult?` as documented (a surface change) or the table says what it does.
- **Control when fixing:** both comparisons refused at `-c` at their lines; an optional class
  still compares.

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
