# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-080. Next new bug: BUG-081.**

Fixed / closed bugs have been moved to `FixedBugs.md`.

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

### BUG-019: `fn_ref` assignment in `genAssign` owns its own `;\n` terminator
- **Severity:** Low
- **Status:** Open
- **Target:** 0.5 (cleanup)
- **Symptom:** The `fn_ref_emitted` block inside `genAssign`'s `else` branch short-circuits with its own `try g.w.writeAll(";\n"); return;` instead of falling through to the shared terminator. Asymmetry means any post-processing added after the shared terminator would be silently skipped by the fn-ref path.

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
- **Status:** Partial fix — statement-position hoisting implemented; expression-position and deep chains remain open
- **Symptom A (method-chain-on-temporary):** `g.indented().withOwner(n.name)` fails if the intermediate result is a struct (value type). Users must break the chain:
  ```zebra
  var g0 = g.indented()
  var g1 = g0.withOwner(n.name)
  ```
  **Fix:** Statement-position codegen now auto-hoists `f().method(args)` → `var _mc_N = f(); _mc_N.method(args)`. Expression-position (`return f().method()`, assignment RHS) and deep chains (`f().g().h()`) remain unhandled — `f().g()` still produces a `*const` intermediate for `h()`.
- **Symptom B (TC auto-deref annotation gap):** When a local variable is assigned from a `throws`-returning function via `?` propagation (`var x = foo()?`), the TypeChecker doesn't record the inferred type in `expr_types`. Downstream `^T` field accesses on `x` then silently omit the required `.*` deref because TC type is `.unknown`. Workaround: annotate explicitly — `var x as T = foo()?`. Fix tracked separately as BUG-077.
- **Root cause (A):** Zig temporary value semantics — caller's stack slot for a struct returned by value is `const`.
- **Root cause (B):** `inferCall` for `?`-propagated throws calls doesn't write back to `expr_types` for the receiving variable.

---

### BUG-029: Class field init with non-int-valued HashMap defaults to i64
- **Severity:** Medium (blocks several TypeChecker port idioms until worked around)
- **Status:** Open
- **Target:** Phase 16c or Phase 17 — fix on Zig side, then port to selfhost
- **Symptom:** `this.field = HashMap()` on a field declared `HashMap(str, T)` for non-int `T` emits `std.StringHashMap(i64).init(_allocator)`.
- **Root cause:** `src/CodeGen.zig::genAssign` generic-RHS field-type resolver accepts only target `.ident` or `.member` with `.ident{name="self"}`. Zebra's `this.` parses as `.member` with `.object.* == .this`, so the resolver bails out.
- **Workaround:** Use implicit-self form (`field_types = HashMap()`) in class cue/init bodies.

---

### BUG-030: `.contains()` on param-of-class HashMap field emits List.contains
- **Severity:** Medium
- **Status:** Open
- **Target:** Phase 17 — fix on Zig side, then port to selfhost
- **Symptom:** `param.field.contains(key)` where `param` is typed as a class and `field` is `HashMap(K, V)` generates the List/array `in` idiom instead of `HashMap.contains(key)`.
- **Workaround:** Add a wrapper method on the containing class (e.g. `def hasLocal(name) as bool; return scope.contains(name)`).

---

### BUG-079: Method chaining on struct-returning calls silently mis-compiles or is unnecessarily banned
- **Severity:** Medium (ergonomics + correctness; blocks natural call-chaining style)
- **Status:** Open — workaround required
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

### DESIGN-001: Throws auto-propagation scope — nested expression calls require `?`
- **Not a bug** — by design
- **Description:** Throws auto-propagation emits `try` for direct self-method calls and statement-level calls whose receiver is a `throws` method. It does NOT auto-propagate for:
  - `localVar.method()` — receiver is a local variable
  - `this.field.method()` — chained member access through a field
  - Calls nested inside compound expressions
- **Required action:** Use explicit `?` suffix for these cases: `localVar.method()?`, `this.field.method()?`

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

*Last updated: 2026-04-22 — INFRA-001 added; BUG-006/035/037/046/075/076/077/078/080 moved to FixedBugs.md*
