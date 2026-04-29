# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-090. Next new bug: BUG-091.**

> BUG-029 and BUG-030 were resolved incidentally in the selfhost implementation — see `FixedBugs.md`.

Fixed / closed bugs have been moved to `FixedBugs.md`.

---

## BUG-086: struct pattern — cross-module type names not supported

**Severity:** low (pre-1.0 gap)  
**Status:** closed — fixed in commit 343ddac

`on Mod.Point(x: 0)` is now recognized as a struct pattern. Three fix sites:
- `src/AstBuilder.zig` `liftStructPattern`: accepts `.member` callee (Mod.TypeName) alongside plain `.ident`
- `selfhost/parser.zbr`: `isOpenCallAt(offset)` helper + `id "." open_call` detection in `parseBranchStmt`
- `selfhost/astbuilder.zbr` `tryBuildStructPat`: handles `Expr.member` callee

---

## Library Files with No Entry Point (Expected "Failures")

These are not bugs — they're library files that can't run standalone:
- `MathUtils.zbr` — utility class, imported by `crossmod_*`, `use_test`, `transitive_test`
- `StringHelper.zbr` — utility class, imported by `transitive_test`

---

## Intentional Error Tests (Correct Behavior)

These fail WITH A COMPILER ERROR — that IS the test passing:
- `branch_infer_miss_test.zbr` — expects error for non-exhaustive branch
- `branch_missing_test.zbr` — expects error for missing variant
- `capture_error.zbr` — expects error for undeclared capture

---

## Open Bugs

### BUG-089: `print` of a mixin-method `str` return falls back to `{any}` byte-array formatting
- **Severity:** Low (cosmetic — wrong output format; does not affect type-annotated locals)
- **Status:** Open
- **Symptom:** Calling a mixin method that returns `str` directly inside `print` emits the bytes as a `[]const u8` integer-array fallback instead of as text.
- **Reproducer:**
  ```zebra
  mixin Greeter
      def hi(): str
          return "hi"

  class Foo adds Greeter
      cue init()
          pass

  class Main
      static
          def main
              var f = Foo()
              print f.hi()        # prints `{ 104, 105 }`, not `hi`
  ```
- **Generated Zig:** `std.debug.print("{any}\n", .{f.hi()});` — wrong format specifier; should be `"{s}\n"`.
- **Root cause:** TC inferExpr on a mixin-derived method call does not surface the declared return type, so the print-emission path in CodeGen sees `Type.unknown` and falls back to `{any}`.  Direct access via a typed local (`var s: str = f.hi(); print s`) emits `{s}` correctly — confirming this is a TC propagation gap on the call site, not a codegen format selector bug.
- **Workaround:** Assign to a `: str`-annotated local before printing.
- **Discovered:** 2026-04-28 while spot-verifying QUICKSTART.md examples.

---

### BUG-090: `for n in Reflect.fieldNames(obj)` loses element type — `print n` emits `{any}`
- **Severity:** Low (cosmetic; iteration itself is correct)
- **Status:** Open
- **Symptom:** Iterating a `Reflect.fieldNames(obj)` result (or any other `[]str`-returning stdlib call) loses the element type, so `print n` inside the loop emits the byte-array fallback instead of the string.
- **Reproducer:**
  ```zebra
  class User
      var name: str = ""
      var age: int = 0

  class Main
      static
          def main
              var u = User()
              u.name = "Alice"
              for n in Reflect.fieldNames(u)
                  print n               # prints `{ 110, 97, 109, 101 }` then `{ 97, 103, 101 }`
              print u.name              # prints `Alice` correctly — direct field access is fine
  ```
- **Generated Zig:** `for (_reflect_User_fields[0..]) |n| { std.debug.print("{any}\n", .{n}); }` — `n` is `[]const u8` but the print emits `{any}`.
- **Root cause:** for-loop variable element-type propagation gap.  TC infers the iter source as `[]str` / `str_slice` but doesn't record `n`'s element type into the per-statement `expr_types` map that the print-emission path consults.  Same bug class as BUG-089 (TC propagation gap surfaces as wrong print format), different code path.
- **Workaround:** Assign through a `: str`-annotated temp inside the loop before printing.
- **Related:** BUG-017 (legacy `len`-on-unknown-type fallback).
- **Discovered:** 2026-04-28 while spot-verifying QUICKSTART.md §25 reflection example.

---

### BUG-088: def-level `try/catch` in non-void return function falls off the end
- **Severity:** Medium (correctness — Zig refuses to compile the generated code)
- **Status:** Open
- **Symptom:** A method using the `def...catch` form (catch clause attached to the def itself, not a nested try/catch block) with a non-void return type fails to compile. The generated Zig has a `return` inside the success path, an unreachable `break`, then an `if (_try_err_1 != null) return ...;` afterwards — but no return on the path through both blocks where neither error occurred and the success block didn't already return. Zig errors with "function with non-void return type implicitly returns" + "unreachable code" at the orphan `break`.
- **Reproducer:** A `def f(): str` with `var v = try X()` followed by `return "ok"` and a `catch` clause returning `"err"` — see the original `contract_result_throws_test.zbr` shape (now restructured to side-effect form to avoid this).
- **Root cause:** The labeled-block lowering for def-level catch doesn't restructure the success path's return into a `break :blk EXPR` with a typed labeled-block result.
- **Workaround:** Use a void function with side effects (mutate a passed-in object, print) instead of returning from the def-level try/catch block.
- **Discovered:** While writing `contract_result_throws_test.zbr` for the BUG-087 fix.

---

### BUG-087: `ensure` defer fires on the error path of throws functions
- **Severity:** Medium (correctness — silent panic instead of caught exception)
- **Status:** Fixed — `_ensure_armed` flag set only on the success path; defer check gated on the flag.  Both Zig and selfhost backends.  Tests: `contract_result_throws_test.zbr` and `contract_ensure_falloff_test.zbr`.
- **Symptom:** A throws function with an `ensure` clause that raises mid-body causes the ensure check to fire on the error path. Result: the program panics with "ensure failed in '<fn>'" and the user's `try/catch` never sees the original exception.
- **Reproducer:** `C:/tmp/ensure_throws_probe.zbr` — `maybeFail(-5)` raises "negative!" but defer evaluates `x > 100`, fails, panics. The outer `catch` is bypassed.
- **Root cause:** Zig `defer` runs on both success and error returns. The current `genEnsureBlock` emits a plain `defer { if (!(expr)) panic; }` with no success-vs-error discrimination.
- **Fix:** Add a `var _ensure_armed = false;` local at function entry. Set it `true` on the success path (right before normal `return _result;` in functions with `result`-capable ensure, or right before any normal return otherwise). Wrap the defer check in `if (_ensure_armed and !(expr)) panic;`.
- **Links:** Discovered while implementing `result` capture (NEXT_STEPS.md item #11 remaining piece).

---

### BUG-002: `guard` + `try_postfix` runtime error propagation
- **Severity:** Medium
- **Status:** Open
- **Target:** 0.3 or 0.5 (source-mapped errors)
- **Symptom A (`guard_test`):** `checkPositive` raises inside a guard else block; top-level `try Main.main()` panics with `error: ZebraError`.
- **Symptom B (`try_postfix_test`):** `safeDiv(10,0)?` propagates through `main throws`; top-level panics. The test doesn't catch the error — it's testing propagation but exits non-zero.
- **Note:** Both are likely correct behavior for Zebra error semantics. The tests need `try/catch` wrapping to validate error propagation without panicking. Test quality issue + potentially a compiler issue with top-level error display.

---

### BUG-014: Regex lazy match is global, not per-quantifier
- **Severity:** Medium
- **Status:** Open — architectural limitation
- **Symptom:** In a pattern mixing lazy and greedy quantifiers (e.g., `<.*?>.*>`), the global `lazy_match` flag makes ALL quantifiers lazy.
  - Simple lazy patterns `<.*?>` work correctly.
  - Mixed patterns `<.*?>STUFF.*>` misbehave.
- **Root cause:** The current Thompson NFA passes a global `shortest: bool` to `matchAt`. When ANY `*?`/`+?`/`??` is parsed, `flags.lazy_match = true` is set for the whole regex.
- **Fix (architectural):** Requires either a priority-first NFA simulation or a backtracking regex engine.
- **Workaround:** For patterns needing mixed lazy/greedy, split into multiple regex calls or restructure the pattern.

---

### BUG-017: `len` on unknown-TC-type emits `.items.len` heuristic — imprecise
- **Severity:** Low
- **Status:** Open — known imprecision; deferred until ModuleInterface preserves return types
- **Symptom:** When a local variable's TC type is `.unknown` and `.len` is accessed on it, CodeGen emits `.items.len` as a last-resort fallback. Correct for `ArrayList`-backed `List(T)` values but wrong for user-defined structs with a field named `len`.
- **Proper fix:** Add a `.list { elem_type }` variant to `TypeChecker.Type`, store it in `ModuleInterface.methods` for list-returning methods, propagate through `inferCall` for cross-module calls.

---

### BUG-019: `fn_ref` assignment missing `&` prefix in selfhost codegen
- **Severity:** Low
- **Status:** Fixed — selfhost `codegen.zbr` `isTopLevelMethod` + `genLocalVar`/`genAssign` fn-ref paths; see `test/fn_ref_test.zbr`
- **Target:** 0.5 (cleanup)
- **Root cause:** `selfhost/codegen.zbr` lacked the fn-ref detection that `src/CodeGen.zig` has. Mutable local vars initialized from a bare top-level function name (e.g. `var pred = isAlpha`) must emit `var pred: @TypeOf(&isAlpha) = &isAlpha;`, and reassignment (`pred = isDigit`) must emit `pred = &isDigit;`. The Zig backend had this via `tc_init_type == .fn_ref`; the selfhost now uses `isTopLevelMethod()`.
- **Original symptom:** `var pred = isAlpha` compiled by selfhost zebra.exe produced Zig `var pred = isAlpha;` which Zig rejects ("variable of type 'fn(u21) bool' must be const or comptime").
- **Known limitation:** `isTopLevelMethod()` only scans the current module's `module_decls`. Cross-module fn_ref (`var cb = OtherModule.func`) will still emit `cb = OtherModule.func;` without `&` in selfhost. Not yet seen in practice.

---

### BUG-026: `instance_method_return_types` gaps for exposed-type method chains
- **Severity:** Medium
- **Status:** Open
- **Target:** Phase 7b / post-audit
- **Symptom:** `var b = a.someMethod()` may still produce `const b` in generated Zig if `someMethod` isn't in `instance_method_return_types`.
- **Root cause:** `instance_method_return_types` is populated by `buildModuleInterface`. It only captures methods whose return type resolves to a `.named` symbol with a non-primitive type.
- **Fix direction:** Populate `instance_method_return_types` more comprehensively, including methods returning `Self` or generic types.

---

### BUG-027: Method chaining on struct temporaries requires manual intermediate vars
- **Severity:** Low (ergonomic / language design)
- **Status:** Fixed — expression-position call-arg chains now emit a labeled block `(blk_N: { var _mc_N = f(); break :blk_N _mc_N.method(args); })` in both Zig backend (`src/CodeGen.zig`) and selfhost (`selfhost/codegen.zbr`). Bootstrap 5/5. Throws sub-issue also fixed: `exprCallIsThrows` now handles call-expression receivers (looks up TC type, scans class/struct members); labeled block emits `break :blk_N try _mc_N.method(args)` when the chained method `throws`. Selfhost mirrors this via `inferExpr`+`isClassMethodThrows`.
- **Remaining sub-issue (deferred):** Expression-position chain `foo(f().throws_method())` inside a `try { }` block (`try_block_label != null`) — the labeled block emits the `try` prefix on `break`, but there is no catch redirect into the try-block's error variable. This path is rare (requires both a labeled try block and a throws chain in call-arg position) and not hit by current tests. Workaround: extract to a named variable before the call-arg site.
- **Symptom A (method-chain-on-temporary):** `display(makeBuilder(5).withVal(10))` fails: the struct temporary `makeBuilder(5)` becomes `*const Builder`, but `.withVal(10)` requires `*Builder`.
  **Fixed positions:** `var r = f().method()` (var-init), `return f().method()` (return), `x = f().method()` (assign) — hoisted via `hoistCallChain` in selfhost / statement-position fix in Zig backend. `foo(f().method(args))` (call-arg / expression) — now fixed via labeled block in both backends. `foo(f().throws_method())` — now emits `try` in both backends.
- **Symptom B (TC auto-deref annotation gap):** When a local variable is assigned from a `throws`-returning function via `?` propagation (`var x = foo()?`), the TypeChecker doesn't record the inferred type in `expr_types`. Downstream `^T` field accesses on `x` then silently omit the required `.*` deref because TC type is `.unknown`. Workaround: annotate explicitly — `var x as T = foo()?`. Fix tracked separately as BUG-077.
- **Root cause (A):** Zig temporary value semantics — caller's stack slot for a struct returned by value is `const`.
- **Root cause (B):** `inferCall` for `?`-propagated throws calls doesn't write back to `expr_types` for the receiving variable.

---

### BUG-079: Method chaining on struct-returning calls silently mis-compiles or is unnecessarily banned
- **Severity:** Medium (ergonomics + correctness; blocks natural call-chaining style)
- **Status:** Fixed — commits de0ec8e + 8c16fd9; auto-hoist in `genLocalVar`, `genReturn`, `genAssign` via `hoistCallChain`; expression-position (call args, compound expressions) remains open (BUG-027)
- **Target:** Pre-1.0 (ribbon ceremony blocker)
- **Symptom:** `f().method()` where `f()` returns a struct type is either silently mis-compiled or must be avoided by convention. The compiler does not enforce materialization; the hazard is invisible to the user until a runtime fault or a wrong-Zig-type error appears.
- **Example:**
  ```zebra
  # Broken — f() returns a struct temporary; .bar() has no stable address
  var result = makeWidget().label()

  # Required workaround
  var w = makeWidget()
  var result = w.label()
  ```
- **Root cause:** In the Zig codegen, a struct return value is a temporary on the Zig stack. Methods on Zebra classes/structs are emitted as `fn method(self: *T, ...)` — they require a pointer receiver. Calling `.method()` on a temporary is either rejected by the Zig compiler (`cannot take address of temporary`) or produces a dangling pointer if the optimizer moves the value.
- **Fix direction (two options):**
  1. **Compiler error:** In the TypeChecker or Resolver, detect `ExprCall` nodes whose callee is `ExprMember { object: ExprCall }` (chained call on a call result) and emit a hard error: `"method chaining on a struct return value is not allowed — assign to a variable first"`.
  2. **Auto-materialize:** In CodeGen, when emitting a method call whose object is itself a call expression, auto-insert a `const _tmp = <inner_call>; _tmp.method(...)` — transparent to the user but produces valid Zig.
- **Preferred fix:** Option 2 (auto-materialize) — better ergonomics, no user-visible restriction. Option 1 is faster to implement and safer as an interim gate.
- **Note:** This limitation is currently documented as a CLAUDE.md agent convention ("always materialize intermediates") rather than as a language/compiler constraint. That is the wrong layer — the language should either enforce or transparently handle it.

---

### BUG-083: `genGenericClass` skips `implements` conformance checks
- **Severity:** Low (conformance gap, not correctness gap — the class still compiles)
- **Status:** Fixed — `src/CodeGen.zig` and `selfhost/codegen.zbr` both emit `comptime { IFoo.check(@This()); }` in `genGenericClass`; `test/generic_iface_test.zbr` covers this; bootstrap 5/5.
- **Symptom:** A generic class declared `class Stack(T) implements IFoo` does not emit a `comptime { IFoo.check(@This()); }` block inside the generated Zig struct. The missing check means the compiler won't catch at compile time that `Stack(T)` is missing a required method — the error will only surface when a caller tries to use a `Stack(T)` value through the interface (if ever).
- **Root cause:** `genGenericClass` in both `src/CodeGen.zig` and `selfhost/codegen.zbr` handles `invariants` but has no `implements`/`ifaces` block. `genClass` delegates to `genGenericClass` early and never runs its own `implements` block. This was a pre-existing gap before interface vtable codegen was added.
- **Fix:** Added `implements.len > 0 → comptime { IFoo.check(@This()); }` block in `genGenericClass` (both backends), parallel to `genClass` and `genStruct`.

---

### BUG-084: Selfhost `Lexer.zbr` tracks `[`/`]` in `parenDepth`; Zig `Tokenizer.zig` does not
- **Severity:** Low — root divergence fixed; both backends now behave identically
- **Status:** Fixed — removed `[`/`]` and `@[` from `parenDepth` tracking in `selfhost/Lexer.zbr`; aligned with `src/Tokenizer.zig` (only `(`/`)` tracked); 26/26 smoke tests pass; bootstrap 5/5
- **Root cause:** Selfhost `Lexer.zbr` tracked both `[`/`]` and `(`/`)` in `parenDepth`. Zig `Tokenizer.zig` only tracks `(`/`)`. The divergence was accidental — the original selfhost port added `[`/`]` tracking without a design reason, and the `@[` emit path (added for array literals) was patched to compensate rather than root-cause fixed.
- **Fix:** Removed `parenDepth = parenDepth ± 1` from the `[`/`]` handling and the `@[` `scanAt` path in `selfhost/Lexer.zbr`. Both backends now only suppress EOL inside `(`...`)`. Multi-line `@[...]` is consistently unsupported in both backends (same behavior).

---

### BUG-085: `static def` methods — bare static field names incorrectly emit `self.field`
- **Severity:** Low (ergonomic; workaround available)
- **Status:** Fixed — `src/CodeGen.zig` and `selfhost/codegen.zbr` `genIdent`; `test/shared_var_test.zbr` updated to exercise the fix; bootstrap 5/5.
- **Symptom:** Inside a `static def` method, a bare field name (e.g. `count`) was treated by `genIdent`/`isFieldName` as an instance field and emitted as `self.count`. But static methods have no `self` parameter in the generated Zig — so the generated code was `self.count` in a `fn increment() void` with no `self`, causing a Zig compile error.
- **Root cause:** `genIdent` checked `in_method: bool` (set for both instance and static methods) and `isFieldName` returned true for any declared class field. There was no guard for the static case.
- **Fix:** Rather than adding an `in_static_method` flag (which would miss bare `static var` access from instance methods), the fix checks the field's own `static` modifier at the `genIdent` site:
  - **Zig backend:** After `if (sym.kind == .var_)`, added `if (sym.decl.var_.mods.static_) { emit owner.name; return; }`. Safe because `sym.kind == .var_` guarantees `sym.decl` is the `.var_` union variant.
  - **Selfhost:** Added `isStaticField(name: str): bool` helper (iterates `owner_members`, returns `fld.mods.is_static`). `genIdent` now calls `isStaticField` and emits `owner.name` instead of `self_name.name` for static fields.
- **Benefit:** Fixes bare `static var` access from BOTH static methods AND instance methods — strictly more correct than the `in_static_method` flag approach.
- **Files:** `src/CodeGen.zig` (`genIdent`), `selfhost/codegen.zbr` (`genIdent`, new `isStaticField`).

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

---

*Last updated: 2026-04-24 — BUG-085 closed: static-field bare-name emit; DESIGN-002 closed: collectAndEmitOldSnapshots 8 missing arms added + regression test*
