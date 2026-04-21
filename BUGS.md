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

### BUG-006: `zig"..."` expression statement emits double semicolon — FIXED both sides
- **Severity:** Low
- **Status:** Fixed — Zig backend 2026-04-17; selfhost fixed 2026-04-20 (Phase 20)
- **Symptom:** `zig"some_stmt;"` inside a method body emitted `some_stmt;;` — the zig literal already ends with `;`, and `genStmt` for `.expr` always appended another `;`.
- **Zig-side fix:** `src/CodeGen.zig::genStmt` `.expr` case detects trailing `;` on `zig_lit` content and skips the appended `;`.
- **Selfhost fix:** `selfhost/codegen.zbr::genStmt` `on Stmt.expr` now checks `if e is Expr.zig_lit`: emits content, adds `;` only if content doesn't already end with `;`, then `\n`.

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

### BUG-035: Selfhost parser has no atom handler for `doc_string_line` (`"""..."""` multi-line strings)
- **Severity:** High (blocks any `.zbr` using `"""..."""` from compiling under selfhost)
- **Status:** Fixed — `selfhost/parser.zbr:1885` handles `isDocString()` → `PNode.expr_str(text)`. Confirmed in selfhost_probe6 (test 1 passes). Closed Phase 20 (2026-04-20).
- **Original root cause:** `selfhost/parser.zbr` had no atom case for `doc_string_line` tokens.

---

### BUG-037: Selfhost corpus-failure triage — RESOLVED 2026-04-19
- **Severity:** High (headline self-hosting gap)
- **Status:** Closed — corpus reached 100% (149/149) via BUG-048 through BUG-073 grammar wave. All 47 parser-gap failures driven to zero.
- **Remaining open work (not tracked here):** BUG-035 — now also fixed (see above).

---

---

### BUG-046: Selfhost does not discover or merge partial-class sibling files — FIXED 2026-04-19
- **Severity:** Medium (selfhost-only parity gap; members added in `<stem>.*.zbr` partials are silently dropped)
- **Status:** Fixed — committed 2026-04-19
- **Root cause:** `selfhost/main.zbr` had no sibling-file discovery or partial merge logic.
- **Fix:** Added `mergePartials_pmodule` in `selfhost/main.zbr` — scans the directory for `<stem>.*.zbr` siblings, parses each, and merges matching class members into the root module before codegen. Key implementation detail: `File.read` generates `defer _allocator.free(src)`, which in Zig 0.15 can rewind the arena if the buffer is the last allocation. Fix uses `"" + psrc_raw` (Zebra string concat → `_str_concat`) to make a permanent arena copy before parsing.
- **Gate:** bootstrap 5/5 + `zig build test` green.

---

### BUG-075: `String + str` concat not routed through `_str_concat` in selfhost TypeChecker
- **Severity:** TC inference gap (selfhost only)
- **Status:** Fixed — Phase 20 (2026-04-20)
- **Description:** When a struct field has type `String` (the Zebra class) rather than `str` (primitive), cross-module member access yields `Type.cross_module`, not `Type.string`. The `+` operator for a `cross_module` typed value therefore emitted raw Zig `+` instead of `_str_concat`, causing a Zig compile error (`invalid operands to binary expression: 'pointer' and 'pointer'`).
- **Fix:** Extended `isString(t: Type_)` in `selfhost/typechecker.zbr` to return `true` for `Type_.cross_module` where `cm.type_name == "String"`. The codegen's `isStringBoth` → `isStringWalker` → `inferExpr` → `isString` chain then correctly routes `String + str` through `_str_concat`. Workaround (`makeDottedKey(nt2.name, "")`) removed; replaced with `nt2.name + "."`.
- **Discovered in:** `genMethod` seeding loop for `opt_ptr_field_bindings` (BUG-073 fix). `nt2.name` is `String` (cross-module).

---

### BUG-077: TC doesn't record inferred type for `?`-propagated throws-call assignments
- **Severity:** Medium (selfhost-code quality; type errors inside capture/post-throws code go uncaught until Zig compile time)
- **Status:** Not reproducing as originally described — likely resolved indirectly by BUG-076 (capture binding narrowed_types fix) and Phase 20 typeFromRef exposed-type fix (2026-04-20).
- **Original symptom:** `var x = foo()?` where `foo` returns `T throws` — TC type of `x` might be `.unknown`. Downstream `x.field` where `field: ^T` might omit the `.*` auto-deref.
- **Verified (2026-04-21):** Both `src/TypeChecker.zig` and `selfhost/typechecker.zbr` correctly handle the `.try_` case — `inferExpr` on a `try` node returns `inferExpr(e.expr)`, and `checkVarDecl`/`walkStmt(.var_)` stores the result. The `?`-propagated type is correctly recorded. No fix needed; mark as resolved-by-inference.

---

### BUG-078: `^ClassName` in union variant double-boxes (`**T`) — FIXED
- **Severity:** Medium (silent codegen bug; payload pointer is one level too deep)
- **Status:** Fixed — `src/Resolver.zig::walkUnion` emits a hard error; test `test/bug078_double_box_test.zbr` is the intentional-error fixture
- **Symptom:** `union Wrap { item: ^Payload }` where `Payload` is a class: class constructors already return `*Payload`, so boxed-variant codegen would emit `_allocator.create(*Payload)` → `**Payload`. Struct payloads are unaffected.
- **Root cause:** The `^T` ref-boxing convention was designed for struct/union/primitive payloads. Classes are already reference types; `^ClassName` adds a redundant indirection level.
- **Fix:** In `walkUnion`, after resolving each variant's payload TypeRef, check if the payload is `.ref_to` wrapping a `.named` that resolves to a `.class` symbol. If so, emit: `'^ClassName' double-boxes — 'ClassName' is already a reference type; use 'item: ClassName' directly`. Note added to QUICKSTART.md under union variants.

---

### BUG-076: `if x is Union.variant |r|` capture binding not registered in TypeChecker `narrowed_types`
- **Severity:** Medium (TC silent on type errors inside capture body; catches nothing until Zig compile time)
- **Status:** Fixed
- **Fixed in:** BUG-076 commit — `isCaptureLookup` 3-way payload lookup in TypeChecker.zig; selfhost walker narrowing in typechecker.zbr; `genIsCaptureThen` ptr_field_bindings registration in codegen.zbr; bootstrap 5/5
- **Symptom:** Inside `if x is Shape.circle |r| { ... }`, the binding `r` has TC type `.unknown`. Any misuse of `r` (wrong method, wrong field) produces no Zebra-level error — the error only surfaces as a Zig compile error after codegen.
- **Root cause:** `src/TypeChecker.zig::visitIf` and `visitElseIf` do not call `pushNarrowedBinding` (or equivalent) for `is_capture` bindings. The Zig-side code correctly emits `const r = x.circle;` — Zig infers the type — but the TC never records `r → payload_type` in `narrowed_types`.
- **Fix:** Added `isCaptureLookup` helper (3-way: same-module union, cross-module alias, direct cross_module) to TypeChecker.zig; updated `.if_` arm to push/pop the capture binding. Selfhost: `typechecker.zbr` walker now populates `cap_t` via `variantPayload`; `codegen.zbr::genIsCaptureThen` now seeds `ptr_field_bindings`/`opt_ptr_field_bindings` for the bound struct's `^T` fields.

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

### BUG-080: `^T?` field assignment (closed — not reproducing)
- **Severity:** Medium (originally suspected codegen correctness issue)
- **Status:** Closed — not reproducing as of 2026-04-21. Verified with minimal repro: `n.next = n2` where `next: ^Node?` generates correct `n.next = n2;` in Zig. The BUG-047 class short-circuit in `genAssign` and `field_needs_deref` both correctly suppress the `.*` for class-typed optional ref fields.

---

*Last updated: 2026-04-21 — BUG-078 fixed (walkUnion double-box error); BUG-077 and BUG-080 not reproducing (closed)*
