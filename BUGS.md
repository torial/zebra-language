# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-078. Next new bug: BUG-079.**

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

### BUG-006: `zig"..."` expression statement emits double semicolon — FIXED (Zig side), selfhost still open
- **Severity:** Low
- **Status:** Fixed (Zig backend) 2026-04-17; selfhost side still emits `;;` (cosmetic)
- **Target:** 0.5 (low priority)
- **Symptom:** `zig"some_stmt;"` inside a method body emitted `some_stmt;;` — the zig literal already ends with `;`, and `genStmt` for `.expr` always appended another `;`.
- **Zig-side fix:** `src/CodeGen.zig::genStmt` `.expr` case detects trailing `;` on `zig_lit` content and skips the appended `;`.
- **Selfhost residue:** `selfhost/codegen.zbr::genStmt` `on Stmt.expr` unconditionally emits `;\n`. Double `;;` is syntactically valid Zig (empty stmt), so round-trip is still clean. Port when selfhost is next touched.

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
- **Status:** Open
- **Target:** Phase 17e or 17f (selfhost-edit wave).
- **Root cause:** `selfhost/parser.zbr` has no atom case that builds an expression from `doc_string_line` token — `grep doc_string parser.zbr` returns no matches.
- **Fix direction:** Add a `doc_string_line` case to the atom-building path in `selfhost/parser.zbr` that wraps the token text in `Expr.string_lit` with `kind = plain`.

---

### BUG-037: Selfhost corpus-failure triage — RESOLVED 2026-04-19
- **Severity:** High (headline self-hosting gap)
- **Status:** Closed — corpus reached 100% (149/149) via BUG-048 through BUG-073 grammar wave. All 47 parser-gap failures driven to zero.
- **Remaining open work (not tracked here):** BUG-035 (`"""…"""` doc strings).

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
- **Status:** Workaround in place; principled fix deferred
- **Description:** When a struct field has type `String` (the Zebra class) rather than `str` (primitive), cross-module member access yields `Type.cross_module`, not `Type.string`. The `+` operator for a `cross_module` typed value therefore emits raw Zig `+` instead of `_str_concat`, causing a Zig compile error (`invalid operands to binary expression: 'pointer' and 'pointer'`).
- **Discovered in:** `genMethod` seeding loop for `opt_ptr_field_bindings` (BUG-073 fix). `nt2.name` is `String` (cross-module), so `nt2.name + "."` would emit invalid Zig.
- **Workaround:** Call `makeDottedKey(nt2.name, "")` instead of `nt2.name + "."`. `makeDottedKey` takes `str`-typed parameters, so inside it `a + "."` correctly routes through `_str_concat`.
- **Principled fix:** The TC's `inferBinary` should recognise `String + str` (and `str + String` and `String + String`) as string concat, returning `Type.string` and emitting `_str_concat`.

---

### BUG-077: TC doesn't record inferred type for `?`-propagated throws-call assignments
- **Severity:** Medium (selfhost-code quality; type errors inside capture/post-throws code go uncaught until Zig compile time)
- **Status:** Open
- **Target:** TC hardening wave
- **Symptom:** `var x = foo()?` where `foo` returns `T throws` — TC type of `x` is `.unknown`. Downstream `x.field` where `field: ^T` silently omits the `.*` auto-deref. Also affects `if x is Union.variant as r`: the binding `r` has type `.unknown` (see BUG-076).
- **Root cause:** `inferCall` in the TypeChecker doesn't write the resolved return type into `expr_types` for the receiving local after `?` propagation. TC for explicit type annotations (`var x as T = foo()?`) works because the annotation is used directly.
- **Fix direction:** In `visitVarDecl` / `inferExpr` for `?`-postfix, look up the callee's declared return type from the resolve result and store it in `expr_types[init_expr]`. Mirror in selfhost TC inference path.

---

### BUG-078: `^ClassName` in union variant double-boxes (`**T`)
- **Severity:** Medium (silent codegen bug; payload pointer is one level too deep)
- **Status:** Open — needs compiler error
- **Target:** Resolver or TypeChecker pass
- **Symptom:** `union Wrap { item as ^Payload }` where `Payload` is a class: class constructors already return `*Payload`, so boxed-variant codegen emits `_allocator.create(*Payload)` → `**Payload`. Struct payloads are unaffected.
- **Root cause:** The `^T` ref-boxing convention was designed for struct/union/primitive payloads. Classes are already reference types; `^ClassName` adds a redundant indirection level.
- **Fix direction:** In the Resolver or TypeChecker, when a union variant's payload type is `.ref_to` and the inner type resolves to a class name, emit a hard error: `'^ClassName' double-boxes — ClassName is already a reference type; use 'item as ClassName' directly`. Add a note to QUICKSTART.md under union variants.

---

### BUG-076: `if x is Union.variant |r|` capture binding not registered in TypeChecker `narrowed_types`
- **Severity:** Medium (TC silent on type errors inside capture body; catches nothing until Zig compile time)
- **Status:** Fixed
- **Fixed in:** BUG-076 commit — `isCaptureLookup` 3-way payload lookup in TypeChecker.zig; selfhost walker narrowing in typechecker.zbr; `genIsCaptureThen` ptr_field_bindings registration in codegen.zbr; bootstrap 5/5
- **Symptom:** Inside `if x is Shape.circle |r| { ... }`, the binding `r` has TC type `.unknown`. Any misuse of `r` (wrong method, wrong field) produces no Zebra-level error — the error only surfaces as a Zig compile error after codegen.
- **Root cause:** `src/TypeChecker.zig::visitIf` and `visitElseIf` do not call `pushNarrowedBinding` (or equivalent) for `is_capture` bindings. The Zig-side code correctly emits `const r = x.circle;` — Zig infers the type — but the TC never records `r → payload_type` in `narrowed_types`.
- **Fix:** Added `isCaptureLookup` helper (3-way: same-module union, cross-module alias, direct cross_module) to TypeChecker.zig; updated `.if_` arm to push/pop the capture binding. Selfhost: `typechecker.zbr` walker now populates `cap_t` via `variantPayload`; `codegen.zbr::genIsCaptureThen` now seeds `ptr_field_bindings`/`opt_ptr_field_bindings` for the bound struct's `^T` fields.

---

### DESIGN-001: Throws auto-propagation scope — nested expression calls require `?`
- **Not a bug** — by design
- **Description:** Throws auto-propagation emits `try` for direct self-method calls and statement-level calls whose receiver is a `throws` method. It does NOT auto-propagate for:
  - `localVar.method()` — receiver is a local variable
  - `this.field.method()` — chained member access through a field
  - Calls nested inside compound expressions
- **Required action:** Use explicit `?` suffix for these cases: `localVar.method()?`, `this.field.method()?`

---

*Last updated: 2026-04-20*
