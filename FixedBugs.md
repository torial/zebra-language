# Zebra Compiler — Fixed / Closed Bugs

Bugs that have been resolved, implemented, or closed as "not reproduced".
Open bugs live in `BUGS.md`.

---

### BUG-118: selfhost — struct construction emits `Struct.init()` with no init method — FIXED 2026-05-05; synthetic init 2026-05-06
- **Status:** Fixed. Bootstrap 5/5, smoke 52/52.
- **Was:** `Point(x: 1, y: 2)` emitted `Point.init(1, 2)`. Plain structs have no `pub fn init`; only classes (and structs with `cue init`) do.
- **Fix (2026-05-05):** `genCall` in `selfhost/codegen.zbr` now tracks two separate StrSets: `struct_names` (all structs) and `struct_with_init` (structs with `cue init`, including all cross-module exposed structs). Plain structs (in `struct_names` but not `struct_with_init`) emit `Struct{ .field = val }` literal syntax. Added `declMembersHaveInit` helper to avoid unused-binding Zig error.
- **Enhancement (2026-05-06):** Both backends now emit a synthetic `pub fn init(fields...) StructName { return .{ ... }; }` in `genStruct` for every plain struct (no explicit `cue init`). This normalises all struct definitions — `StructName.init(...)` is now always callable. The call site continues to use struct literal syntax (order-independent) for construction; the synthetic init is available for Zig interop and future uniform-construction refactors.
- **Test:** `test/bug118_struct_ctor_test.zbr` — constructs `Point(x: 3, y: 4)` and `RGB(r: 255, g: 128, b: 0)`.

---

### BUG-117: selfhost — `List.join(sep)` codegen emits inverted arguments — FIXED 2026-05-05
- **Status:** Fixed. Bootstrap 5/5, smoke 52/52.
- **Was:** `items.join(sep)` emitted `std.mem.join(_allocator, items, sep.items)` — separator and slices swapped, `.items` on separator.
- **Fix:** `genMemberCall` `join` arm now emits separator first: `std.mem.join(_allocator, sep, items.items)`.
- **Test:** `test/bug117_list_join_test.zbr` — joins `["alpha", "beta", "gamma"]` with `", "`.

---

### BUG-116: selfhost — `char.isAlpha()` / `char.isDigit()` / `char.isWhitespace()` not dispatched — FIXED 2026-05-05
- **Status:** Fixed. Bootstrap 5/5, smoke 52/52.
- **Was:** Char methods fell through to pass-through path, emitting invalid `u21.isAlpha()` Zig.
- **Fix:** Added char dispatch block before the string methods section in `genMemberCall`. Detects `Type_.char_` receiver via `inferExpr` and emits `std.ascii.isAlphabetic(@as(u8, @truncate(c)))` etc. Covers: `isAlpha`, `isDigit`, `isWhitespace`, `isUpper`, `isLower`, `toUpper`, `toLower`. Mirrors `genCharMethod` in `src/CodeGen.zig`.
- **Test:** `test/bug116_char_methods_test.zbr` — counts alpha/digit/space chars, tests isUpper/isLower, verifies toUpper via StringBuilder.

---

### §19: Selfhost TC diagnostics — SHIPPED 2026-05-05
- **Status:** Shipped in `selfhost/typechecker.zbr` + `selfhost/main.zbr`. Compat test 2/2 PASS, bootstrap 5/5.
- **Was:** `selfhost/typechecker.zbr` had inference-only infrastructure (no `errors` list, no `addErr`, no print path). Type mismatches in the selfhost pipeline were only caught after codegen by the downstream Zig compiler, producing `path:LINE:` (no col) format errors.
- **Fix:** Added `Diagnostic{file,line,col,message}` struct, `InferCtx.errors: List(Diagnostic)` + `addErr/hasErrors/errorMessages`, `isPrimitive/typesCompatible` predicates, and `checkVarDecl/checkStmts/checkDecl/checkModule` walk. Wired into `main.zbr` step 4.5 (after ASTBuilder, before codegen). Selfhost now emits `path:LINE:COL: error: type mismatch: expected int, found str` at TC time.
- **Scope:** Concrete primitive mismatches only (int/bool/char/float/str). Named/enum types deferred — enum not tracked in ModuleTypes; would false-positive without full registry.
- **Test:** `test/selfhost_compat/run_compat.sh` updated to PASS when selfhost catches an error with col but bootstrap backend doesn't (known gap: bootstrap error comes from Zig compiler post-codegen).

---

### BUG-102: Selfhost typechecker `to!` force-unwrap audit — FIXED 2026-05-06
- **Status:** Fixed. All 41 `to!` sites in `selfhost/typechecker.zbr` are now guarded. Bootstrap 5/5, smoke 44/44.
- **Was:** `selfhost/typechecker.zbr` had ~41 `to!` force-unwrap operations in various states of guardedness. Several appeared unguarded. A nil at any unguarded `to!` is a hard panic with no diagnostic.
- **Fix:** Full audit of all 41 sites:
  - 20 converted to `if x as v` (idiomatic) — applies to `String?`, `List(Stmt)?`, `Type_?` same-file locals and cross-module fields where the bootstrap TC tracks optionality correctly
  - 21 kept as `if x != nil: ... to!` with `# safe:` annotation — required for cross-module `TypeRef?` and `^Expr?` fields, which the bootstrap TC does not track as optional (pre-existing gap)
- **Note:** The TC gap where `TypeRef?`/`^Expr?` cross-module fields aren't inferred as optional is a separate issue from BUG-102. The guarded `to!` pattern is the correct workaround for those 21 sites.

---

### BUG-099: Type `.unknown` three-way split — FIXED 2026-05-05 (Zig) + 2026-05-06 (selfhost)
- **Status:** Fixed in `src/TypeChecker.zig` (2026-05-05) and `selfhost/typechecker.zbr` (2026-05-06). Bootstrap 5/5, smoke 44/44, full test suite.
- **Was:** `Type.unknown` / `Type_.unknown_` overloaded three semantically distinct cases: context-dependent (nil, result), opaque-by-design (zig_lit, generics), and unresolved (TC gave up). Downstream checks couldn't distinguish them, so `var x: int = undefined_call()` silently typechecked.
- **Fix (Zig):** Three-way split into `.context_dependent`, `.unknown`, `.unresolved: Ast.Span`. Alarm bell fires at `checkVarDecl`. See commits `429ff98` → `fe61ebe`.
- **Fix (selfhost):** `Type_` union gains `context_dependent` and `unresolved`. Twelve `inferExpr`/`walkStmt` sites reclassified: nil inner + result outside return + if-capture defaults → `context_dependent`; ident/member/call/index/slice/expr fallbacks → `unresolved`; intentional opaque cases unchanged (`unknown_`). `isAbstractType()` helper mirrors `isAbstract()`. Alarm bell added to `checkVarDecl` behind `InferCtx.strict` (enabled by `typecheck-merge` only; off for normal compilation to avoid false alarms on TC gaps not yet closed). `codegen.zbr` format-spec falls through for all three abstract variants.
- **Closed as side effects:** BUG-105 (enum_member/union_variant → parent type), BUG-106 (literal element-type homogeneity), BUG-108 (partial — `this` outside class defensive emitError).

---

### BUG-105: `Color.red` infers to `.unknown` instead of `.named(Color)` — FIXED 2026-05-05
- **Status:** Fixed in `src/TypeChecker.zig:inferMember`. Test: `test/bug105_enum_member_test.zbr`, `test/bug105_union_variant_test.zbr`. See commit `f254b75`.
- **Was:** `inferMember` returned `.unknown` for enum-member and union-variant access (`Color.red`, `Result.ok(...)`). Downstream `var c: int = Color.red` silently typechecked.
- **Fix:** `inferMember` now returns `Type{ .named = parent_sym }` when the member resolves to an enum member or union variant. `var c: Color = Color.red` typechecks; `var c: int = Color.red` correctly errors.

---

### BUG-106: Heterogeneous list literals `[1, "two"]` silently typecheck — FIXED (partial) 2026-05-05
- **Status:** Literal homogeneity check shipped. Cast-validity check deferred. Test: `test/bug106_heterogeneous_list_test.zbr`. See commit `fe61ebe`.
- **Was:** `list_lit`, `array_lit`, `dict_lit` inferred to `.unknown` without checking element type consistency. `[1, "two", 3]` was silently accepted.
- **Fix:** Element-type walk now requires mutual `isAssignable` for non-abstract element types. Heterogeneous literals error at the offending element's span. Numeric mixes `[1, 2.0, 3]` still pass (untyped-numeric semantic). Cast-validity check (line 1693 — `42 as ClassType` still typechecks) deferred — separate scope, lower priority.

---

### BUG-108: Silent `.unknown` at `this` outside class — FIXED (partial) 2026-05-05
- **Status:** `this`-outside-class diagnostic shipped. Other sites deferred. Test: `test/bug108_this_outside_class_test.zbr`. See commit `01296db`.
- **Was:** `this` used outside a class/struct method or `with` block silently returned `.unknown` with no diagnostic.
- **Fix:** `this` outside valid context now emits "'this' used outside a class/struct method or 'with' block" at the `this` token span.
- **Remaining (deferred):** `inferMember` cross-module miss softened to `.unknown` (false-positive risk on legitimate patterns); index/slice on non-indexable; `expr_types.get` fallbacks with legitimate non-error cases.

---

### BUG-111: Compound assign `.field += 1` — NOT-A-BUG 2026-05-05
- **Status:** Closed as not-reproduced. Verified 2026-05-05 in both backends.
- **Was (reported):** `this.count += 1` / `.count += 1` suspected to fail; zero occurrences in repo suggesting users avoided the form.
- **Verified:** `.count += 1`, `this.count += 1`, `obj.count += 5` all parse, codegen, and run correctly. The zero-occurrence data was stylistic legacy (authors wrote `this.X = this.X + 1` before `.field` shorthand was canonical), not a compiler limitation.

---

### BUG-112: `def name: T` no-paren shorthand removed from grammar — FIXED 2026-05-05
- **Status:** Fixed 2026-05-05. Grammar rule removed from both backends. 38-site sweep done. Bootstrap 5/5. See commits `2f7e767` (grammar removal) + `598a533` (38-site sweep).
- **Was:** `def name: T` and `def name(): T` were both legal. The no-paren form was a vestige of the removed `prop`/`get`/`set` machinery — visually contradicted call-site syntax (callers always write `obj.name()`).
- **Fix:** No-paren rule removed from `src/Parser.zig` and `selfhost/parser.zbr`. All 38 occurrences across 17 files swept to `def name(): T`. Style guide §1 Q2 updated to reflect canonical form.

---

### BUG-113: Slice TC loses `str` type through `var` binding — NOT-REPRODUCED 2026-05-05
- **Status:** Closed as not-reproduced. Verified 2026-05-05.
- **Was (reported):** `var text = src[0..3]` suspected to infer something other than `str`, requiring explicit `: str` annotation for `.toFloat()` to dispatch. Author comment in `pratt_calc.zbr:132–134` documented this workaround.
- **Verified:** Both the annotated and unannotated forms produce identical output. The TC improvement (likely via BUG-099 work) resolved the underlying inference gap. The `pratt_calc.zbr` annotation is now redundant but harmless — left in place.

---

### BUG-087: `ensure` defer fires on the error path of throws functions — FIXED
- **Status:** Fixed 2026-04-27 in both backends. `_ensure_armed` flag set only on the success path; defer check gated on the flag. Tests: `contract_result_throws_test.zbr`, `contract_ensure_falloff_test.zbr`.
- **Was:** A throws function with an `ensure` clause that raised mid-body caused the ensure check to fire on the error path. Result: program panicked with "ensure failed in '<fn>'" and the user's `try/catch` never saw the original exception. Zig `defer` runs on both success and error returns, but `genEnsureBlock` emitted a plain `defer { if (!(expr)) panic; }` with no success-vs-error discrimination.
- **Fix:** `var _ensure_armed = false;` local at function entry. Set `true` on the success path (right before normal `return _result;` in functions with `result`-capable ensure, or right before any normal return otherwise). Defer check wrapped in `if (_ensure_armed and !(expr)) panic;`.
- **Discovered:** while implementing `result` capture (NEXT_STEPS item #11). Closed as a side effect of the `result`-keyword work — same flag mechanism delivers both features.

---

### BUG-019: `fn_ref` assignment missing `&` prefix in selfhost codegen — FIXED
- **Status:** Fixed 2026-04-23 in `selfhost/codegen.zbr`. `isTopLevelMethod` + `&` prefix paths in `genLocalVar`/`genAssign`. Test: `test/fn_ref_test.zbr`.
- **Was:** `selfhost/codegen.zbr` lacked the fn-ref detection that `src/CodeGen.zig` has. Mutable local vars initialised from a bare top-level function name (e.g. `var pred = isAlpha`) emitted Zig `var pred = isAlpha;` which Zig rejects: *"variable of type 'fn(u21) bool' must be const or comptime"*. The Zig backend had this via `tc_init_type == .fn_ref`; the selfhost lacked parity.
- **Fix:** added `isTopLevelMethod()` scanner over the current module's `module_decls`. Mutable fn-ref locals emit `var pred: @TypeOf(&isAlpha) = &isAlpha;`; reassignment emits `pred = &isDigit;`.
- **Known limitation (deferred):** `isTopLevelMethod()` only scans the current module. Cross-module fn-ref (`var cb = OtherModule.func`) still emits without `&` in selfhost. Not yet seen in practice; refile if it lands.

---

### BUG-002: `guard` + `try_postfix` runtime error propagation — CLOSED (test quality)
- **Status:** Closed 2026-04-23. Tests fixed by adding explicit `try/catch` wrapping. Per memory log + NEXT_STEPS reference table.
- **Was:** Two tests (`guard_test`, `try_postfix_test`) panicked at top level rather than catching propagated errors. Symptom A: `checkPositive` raised inside a guard `else` block; top-level `try Main.main()` panicked with `error: ZebraError`. Symptom B: `safeDiv(10,0)?` propagated through `main throws`; test exited non-zero.
- **Resolution:** Behaviour was correct per Zebra's error semantics — propagation up to `main` does panic if uncaught. The tests were testing propagation without explicit `try/catch` boundaries; adding the wrapping made them validate the propagation path without panicking. No compiler change needed.

---

### BUG-098: `name in some_list` always routed to `std.mem.indexOf(u8, …)` — FIXED
- **Status:** Fixed in `selfhost/codegen.zbr`. Bootstrap 5/5, smoke 43/43.
- **Was:** The `in` operator only specialised for `@[…]` tuple literals on the right; List(T) / HashMap(K,V) variables fell through to the substring path, which emitted `std.mem.indexOf(u8, container, needle)` — Zig rejected because `indexOf` takes a `[]const T` slice, not an `ArrayList`.
- **Fix:** `BinaryOp.in_` now routes to the existing `_zebra_in` runtime helper (which handles ArrayList + HashMap + tuple via comptime dispatch) when the right operand is:
  - `Expr.array_lit` (the existing case)
  - `Expr.list_lit` (newly recognised — `[a, b, c]` literals)
  - `Expr.ident` whose name is in `list_locals` / `hashmap_locals`
  - or any expression whose TC type is a `.named` symbol named `"List"` / `"HashMap"` (covers field accesses)
- **Companion fix:** `genLocalVar` now adds `n.name` to `list_locals` (and `list_str_locals` when the first element is str-typed) for `var x = [a, b, …]` declarations — without that, downstream `.count()`, `.at()`, and `in` dispatches missed list-locals that came from a `[…]` literal rather than a `List(T)()` ctor.
- **Regression test:** `["alice", "bob"]` etc. round-trip through `examples/lambda_calc.zbr` (which uses `name in list` pervasively after this fix).
- **Discovered:** 2026-04-30 while writing `examples/lambda_calc.zbr`.

---

### BUG-095: class field defaults aren't auto-applied — `cue init` left fields as Zig `undefined` — FIXED
- **Status:** Fixed in `selfhost/codegen.zbr` `genInit`. Bootstrap 5/5, smoke 43/43.
- **Was:** When a `cue init` body didn't explicitly assign a class field that had a declared default (`var hits: int = 0`), the un-assigned field was emitted as Zig `undefined` — producing the poison value `0xAAAA…AAAA` which silently overflowed in subsequent arithmetic. The synthetic-default-init path (used when a class has no user-written `cue init`) already pre-filled defaults; the explicit-init path didn't.
- **Fix:** `genInit` now walks `owner_members` for `Decl.var_` entries with a non-nil `init_expr` and emits `_self.field = <default>;` *before* running the user's `cue init` body. The user's body may overwrite those defaults — that's fine and matches the bare-class semantics. Same pre-fill is also added for body-less `cue init` declarations.
- **Reproducer:** `class Counter { var hits: int = 0; var misses: int = 0; cue init(): pass }` — `c.hits + c.misses` now prints `0` instead of `-6148914691236517206`.
- **Discovered:** 2026-04-30 while writing `zebra-tools/book_run.zbr`'s pass/fail counters.

---

### BUG-091: `List(T)` / `HashMap(K,V)` parameter receiver is `*const` — `.add()` rejected by Zig — FIXED
- **Status:** Fixed in **both** `src/CodeGen.zig` (Zig backend) and `selfhost/codegen.zbr` + `selfhost/cg_helpers.zbr` (selfhost). Per-equivalence rule. Bootstrap 5/5; smoke 43/43.
- **Was:** Passing a `List(T)` as a function parameter and calling `.add()` on it emitted `*const ArrayList(...)` (Zig parameters are always const), and `append` (which takes `*Self`) was rejected with "cast discards const qualifier".
- **Fix:** Mutation-driven param-pointering. New helper `paramNeedsAddrOf` returns true when the param's type is `List(T)` / `HashMap(K,V)` AND the body's `scanMutations` set contains the param name. `genMethod` emits the param as `*std.ArrayList(...)` in that case; the call-site emit (`genArgs` in src; `genArgListNamed` + the class-method member-call path in selfhost) emits `&` for the corresponding arg. `addAddrOfMutationsInStmts` (a parallel pass alongside `scanMutations` in `genStmts`) marks the caller's local as `var` so `&items` is `*ArrayList`, not `*const ArrayList`.
- **Why mutation-driven (not blanket):** Existing selfhost code (441 `: List(...)` param sites) is reads-only; flipping the calling convention everywhere would have a large blast radius. The mutation predicate isolates the change to sites that actually need it.
- **Selfhost port:** added `paramNeedsAddrOf` + `isContainerTypeRef` to `cg_helpers.zbr`; added `lookupFnBody`, `addAddrOfMutationsInStmts/Expr`, `*` prefix in `genParamList`, `&` prefix in `genArgListNamed` and `genMemberCall` member-method path; small TypeRef.named "StrSet" → `strset_locals` registration so a typed `var ms: StrSet = scanMutations(...)` round-trips. Both the call-site `&` emit and the addr-of mutation-marking pass cover three dispatch shapes: static (`Class.method`), self (`this.method`), and instance (`var.method` resolved via `inferExpr` against the per-method `InferCtx`).
- **Regression tests:** `test/bug091_list_param_test.zbr` (static `Main.fillX(items)`) and `test/bug091_dispatch_test.zbr` (`this.helper(items)` and `f.helper(items)` instance shapes with assertions). Both pass through `zebra-bootstrap.exe` (Zig backend) and `zebra.exe` (selfhost).
- **Discovered:** 2026-04-29 while writing `book_lint.zbr` (Phase 3 dogfooding tools).

---

### BUG-092: `var lines: List(str) = s.split("\n")` didn't auto-collect SplitIterator — FIXED
- **Status:** Fixed in **both** `src/CodeGen.zig` `genLocalVar` and `selfhost/codegen.zbr` `genLocalVar`. Bootstrap 5/5.
- **Was:** Assigning `content.split("\n")` to a `List(str)`-annotated local annotated the slot as `std.ArrayList([]const u8)` but the RHS emitted `std.mem.splitSequence(...)` — a Zig type mismatch.
- **Fix:**
  - **Zig backend** (`src/CodeGen.zig`): New branch in `genLocalVar` emits the iterator + while-loop drainer alongside the const/var declaration.
  - **Selfhost** (`selfhost/codegen.zbr`): same pattern but emitted as a single labeled-block initializer (`blk_N: { var _ll_N = …; while (…) |…| _ll_N.append(…); break :blk_N _ll_N; }`) so the form works regardless of the outer const/var decision. Also added "lines" to `isReadOnlyMethod` in `cg_helpers.zbr` so a downstream `s.lines()` call doesn't spuriously mark `s` as mutated.
- **Coverage:** Both `split(sep)` and `lines()` are handled via the same path (both return iterators in Zig). Untyped `var x = s.split(...)` for-loop iteration is unchanged (still drives the iterator directly).
- **Regression test:** `test/bug092_split_to_list_test.zbr`, passes through both backends.
- **Discovered:** 2026-04-29 while writing `book_lint.zbr`.

---

### BUG-082: Selfhost `inferExpr` returns `unknown_` for cross-module constructor calls — FIXED
- **Status:** Fixed — `selfhost/typechecker.zbr` `inferExpr` Expr.call/Expr.member branch; `test/bug082_test.zbr` + `test/bug082_lib.zbr`. Bootstrap 5/5.
- **Was:** `var b = SomeMod.SomeClass(args)` gave `b` type `unknown_` in selfhost TC; downstream method-return format strings emitted `{any}` instead of `{s}`, printing raw bytes.
- **Fix:** In `inferExpr`, when receiver resolves to `unknown_` and the member name is a known dep class, return `Type_.named(mem.member)`.

---

### BUG-029: Class field init with non-int-valued HashMap defaults to i64 — FIXED
- **Status:** Fixed in selfhost — resolved incidentally during selfhost implementation
- **Was:** `this.field = HashMap()` on a field declared `HashMap(str, T)` for non-int `T` emitted `std.StringHashMap(i64).init(_allocator)` in the Zig-backend compiler. Root cause: Zig-backend `genAssign` resolved field types only for `.ident` targets or `.member` with `.ident{name="self"}`, bailing out for `this.` which parses as `.member { object: .this }`.
- **Fix:** Selfhost `getAssignFieldType` uses `getMemberFieldName` which handles `Expr.member` generically (returns `m.member` for any member expression). Combined with `genCallWithTypeHint`, emits the correct Zig type.
- **Regression test:** `test/hashmap_this_field_test.zbr`

---

### BUG-030: `.contains()` on param-of-class HashMap field emits List.contains — FIXED
- **Status:** Fixed in selfhost — resolved incidentally during selfhost implementation
- **Was:** `param.field.contains(key)` where `param` is a local of a class type and `field` is `HashMap(K,V)` generated incorrect contains dispatch in the Zig-backend compiler.
- **Fix:** Selfhost `genCall` dispatches `.contains()` on all non-string receivers via `.contains(key)` — correct for Zig HashMap. The `getMemberFieldName`-based path handles chained member access.
- **Regression test:** `test/hashmap_param_field_test.zbr`

---

### BUG-001: Static method calling static method emits `self.` prefix — FIXED
- **Status:** Fixed (prior session — TCO work fixed bare static method calls)
- Was: `testHelper()` inside a static method generated `self.testHelper()`.
- Now: emits `ClassName.methodName()` correctly for static→static calls.

---

### BUG-003: HTTP `serve` fails on Windows with "comptime call of extern function" — FIXED
- **Status:** Fixed 2026-04-09
- Was: `_Ctx` struct stored `handler: Handler` where `Handler = @TypeOf(handler)` is a bare function type (comptime-only in Zig). Made the entire struct comptime-only, so `page_allocator.create(_Ctx)` triggered the `NtAllocateVirtualMemory` comptime path.
- Fix: Declare `const _HFn = *const fn(HttpRequest) HttpResponse` and coerce `const _fn: _HFn = handler` before `_Ctx`. Store `handler_fn: _HFn` in `_Ctx` (fn-pointer = runtime type). Call `ctx.handler_fn(_req)` directly. All three HTTP routes verified working on Windows.

---

### BUG-004: `padLeft/padRight/center` — fill char `'*'` passed as string to `u8` param — FIXED
- **Status:** Fixed 2026-04-08
- Was: `_pad_left(s, n, "*", alloc)` failed — `"*"` is `*const [1:0]u8`, not `u8`.
- Fix: Changed pad helpers to accept `anytype` fill; added `_pad_fill` normaliser that handles both char literals (comptime_int) and 1-char strings (pointer).

---

### BUG-005: `{d:0>N}` format adds `+` prefix to positive `i64` in Zig 0.15 — FIXED
- **Status:** Fixed 2026-04-09
- **Context:** DateTime preamble `_dt_to_iso8601` and `_dt_format` used `i64` fields with `{d:0>N}` format spec. Zig 0.15.2 adds a `+` sign to positive signed integers when using fill-aligned format (e.g. `{d:0>4}` for `i64 = 1970` → `+1970`).
- **Fix:** Cast all date fields to unsigned types (`@as(u32, ...)`, `@as(u8, ...)`) before passing to `bufPrint`/`allocPrint`. Unsigned integers never receive a sign prefix.
- **Broader note:** This is a Zig 0.15 breaking change from 0.14. Any future preamble code that formats `i64` values with fill-aligned specs should cast to unsigned first.

---

### BUG-007: `String + String` string concatenation not handled — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `+` operator on strings fell through to the numeric `else` branch in `genBinary`, emitting `(a + b)` which Zig rejects for `[]const u8`. TypeChecker also rejected `String + String` as arithmetic.
- **Fix:**
  - TypeChecker `inferBinary`: added `if (e.op == .add and lt == .string) break :blk .string` before the numeric guard.
  - CodeGen `genBinary`: added dedicated `.add` case — if left operand is string, emits `_str_concat(a, b, _allocator)`.
  - Preamble: added `_str_concat(a, b, alloc)` using `std.mem.concat`.

---

### BUG-008: Mutation scanner — `.unknown` TC type caused spurious `var` — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** When `tc.resolve.exprs` had no entry for an ident used as a method receiver, `inferIdent` returned `.unknown`, which the scanner conservatively treated as always-mutating.
- **Fix:** Removed the `if (obj_type == .unknown) break :blk true` conservative path. Added `if (obj_type == .string) break :blk false` guard. These fixes together fix `string_methods_test` and `sys_test`.

---

### BUG-009 (a): Escape analysis — field writes not propagated — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `propagateEscapesOnce` only traced `var y = <expr>` alias chains. Storing into a returned struct's field (`result.items = list`) didn't escape `list`.
- **Fix:** Added `.assign` handling in `propagateEscapesOnce`: if target is `obj.field` and `obj` is escaped, all idents in RHS are added to the escaped set.

---

### BUG-009 (b): `opt?.field` emits `try opt.?.field` inside `if opt != nil` guard — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `opt?.x` inside an `if opt != nil` block generated `try opt.?.x` instead of `opt.?.x`.
- **Fix:** TypeChecker now populates `optional_unwraps`. `exprHasTry` and `genExpr` both consult `optional_unwraps` instead of `expr_types`.

---

### BUG-010: Partial class — duplicate method silently appended — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `mergePartialInto` concatenated all members from a partial without checking for name conflicts.
- **Fix:** `mergePartialInto` now scans for duplicate method names before merging. Duplicates emit a clear warning and the partial definition is skipped.

---

### BUG-011: `tcTypeAnnotation` — comprehensive type annotation for `var` locals
- **Status:** Fixed 2026-04-09
- **Fix:** Replaced ad-hoc 6-case inline switch with `tcTypeAnnotation(t, alloc)` — a dedicated module-level function mapping all `TypeChecker.Type` variants to Zig annotation strings.

---

### BUG-012: `_type_id` uninitialized for classes without explicit `cue init` — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** Classes with no explicit `cue init` were constructed via `ClassName{}` (struct literal), leaving `_type_id` uninitialized.
- **Fix:** `genClass` now emits a synthetic default `pub fn init() ClassName` that explicitly stamps `self._type_id = _tid_ClassName`. Constructor call site updated to emit `ClassName.init()`.

---

### BUG-013: `collectEnumMembers` — blank-line leaf detection used structural comparison — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `if (kids[1] != .leaf)` relied on an implementation detail of blank-line productions.
- **Fix:** Replaced with the named helper `isMeaningfulNode(tn: TN) bool`.

---

### BUG-015: `scanMutationsInto` missing `.assert` case — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** Method calls inside `assert` conditions were never scanned, causing the receiver to be emitted `const`.
- **Fix:** Added `.assert => |s| try scanMutationsInExpr(s.cond, set, tc_opt)` to `scanMutationsInto`.

---

### BUG-016: `inferMember` didn't unwrap optional type before member lookup — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `inferMember` only looked up fields/methods when `obj_type == .named`. For `n?.next` (where `n: ?Node`), TC type was `.optional(.named(Node))` — lookup silently returned `.unknown`.
- **Fix:** Added `resolved_obj_type = if (obj_type == .optional) obj_type.optional.* else obj_type` before the `.named` member lookup.

---

### BUG-018: Top-level `def` referenced inside class method set `uses_self = true` — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `refsInExpr` set `uses_self = true` for ANY `.method` symbol, including top-level `def` functions.
- **Fix:** `refsInExpr` now checks `sym.decl.method.is_top_level`; top-level methods do NOT set `uses_self`.

---

### BUG-020: `branch/on` call-expr pattern emitted wrong Zig — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `on SomeUnion.variant() as x` in a `branch` on-clause fell through to `genExpr(v)` which emitted the union constructor form, not a valid Zig switch pattern.
- **Fix:** Added `else if (v.* == .call and v.call.callee.* == .member)` branch in `genBranch`'s union pattern path.

---

### BUG-021: Struct `cue init` stamped `_type_tag` (class-only field) — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `genInit` always emitted `self._type_tag = _ttag_StructName` for any `cue init` body.
- **Fix:** Added `is_struct_owner: bool = false` to Generator. `genInit` wraps the stamp in `if (!g.is_struct_owner)`.

---

### BUG-022: `boxed_variants` not cloned in `cloneInterface` — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `cloneInterface` didn't clone the `boxed_variants` map. Re-imported modules received empty `boxed_variants`, silently skipping boxing expressions.
- **Fix:** Added full key/value clone loop for `boxed_variants` in `cloneInterface`.

---

### BUG-023: Multi-line `cue init` blocked by indentation validator — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `processIndentation` checked indentation on EVERY line including continuation lines inside open parentheses.
- **Fix:** Added `paren_depth: u32 = 0` tracking to Tokenizer. `processIndentation` returns early when `paren_depth > 0`.

---

### BUG-024: `throws` auto-propagation missing — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** Calling a `throws` method from inside a `throws` method required explicit `?` suffix on every call.
- **Fix:** Added `current_method_throws: bool = false` to Generator. Auto-emits `try ` prefix for three call paths (bare-name, self-method, cross-module). Added `suppress_auto_try` flag to prevent double `try try`.

---

### BUG-025: `scanMutationsInExpr` didn't recurse into `.try_` nodes — FIXED
- **Status:** Fixed 2026-04-11
- **Was:** `localVar.method()?` — the `?` wraps the call in a `.try_` node which wasn't recursed into, so `localVar` was never added to the mutated set.
- **Fix:** Added `.try_ => |e| try scanMutationsInExpr(e.expr, set, tc_opt)` to `scanMutationsInExpr`.

---

### BUG-028: Zebra (Zig-backend) emits pointer addresses into identifier names — FIXED
- **Status:** Fixed 2026-04-17 (commit 8debe0a)
- **Was:** Generated `.zig` contained identifiers like `_box_2376b6287c0` — live pointer addresses. Every run produced different names, so output was non-deterministic.
- **Fix:** Generator carries a monotonic `box_counter_ptr`; all 27 `@intFromPtr(node)`-based name sites route through `Generator.nextUid()`.

---

### BUG-031: Selfhost `except` codegen emits `.*` on value-typed subject — FIXED
- **Status:** Fixed 2026-04-17
- **Was:** `x except { f = v }` where `x` is a local value (not a pointer) emitted `var _except_tmp = x.*;` — `.*` is only legal on a pointer.
- **Fix:** `selfhost/codegen.zbr` gen path for `Expr.except_` now emits `.*` only when the base is `Expr.this_` in a method body.

---

### BUG-032: Selfhost codegen.zbr emits `.remove` unconditionally as `.orderedRemove` (List form) — FIXED
- **Status:** Fixed 2026-04-17 (commit ff87add)
- **Fix:** `.remove` dispatch now discriminates HashMap vs List receiver via new `hashmap_locals` + `fieldIsHashMap` infrastructure. HashMap emits `_ = obj.remove(key)`; List keeps `_ = obj.orderedRemove(@intCast(idx))`.

---

### BUG-033: Selfhost `.contains()` on class-field HashMap emits `List.contains` form — NOT REPRODUCED
- **Status:** Not Reproduced 2026-04-17
- **Investigation:** Built reproducer with `class Reg` holding `HashMap(str,int)` field, called via `self.by_name.contains(k)`. Selfhost emits correctly (HashMap `.contains` path). BUG-032's walker work evidently already covers this receiver shape.

---

### BUG-034: Selfhost emits cross-module union construction as struct call — FIXED
- **Status:** Fixed 2026-04-17 (commit ff87add)
- **Fix:** `generateModuleWith` now consults `deps_mt.hasUnion(exposed_name)` before the hard-coded heuristics. The allow-list stays as a fallback for the single-file emit path.

---

### BUG-036: Selfhost HashMap field `[key]` subscript emits array-index with bogus `@intCast` — FIXED
- **Status:** Fixed 2026-04-18 (commit 242394a)
- **Fix:** `genExpr` for `Expr.index` and new `genHashMapAssign` method detect HashMap receivers via `hashmap_locals`/`fieldIsHashMap`: reads emit `.get(k).?`, writes emit `.put(k, v) catch @panic("OOM")`. `scanMutationsInto` updated to mark index-assign base as mutated. `genHashMapAssign` extracted as a method to avoid a nested-branch `.*`-deref bug in the Zig backend. Bootstrap A/B byte-identical.

---

### BUG-038: Selfhost emits `int.toString()` as codepoint-to-UTF8 encode, not integer-to-decimal — FIXED
- **Status:** Fixed 2026-04-18 (commit 443886d)
- **Fix:** `genMemberCall` in `codegen.zbr` now calls `inferExpr(m.object, infer_ctx)` before choosing the toString emit path. `Type_.char_` receivers → utf8Encode; all others → `std.fmt.allocPrint`. Enabled by typechecker fix: `walkStmt` for_in pre-pass detects `for c in s.chars()` via `isCharsCallExpr()` and binds the loop var as `Type_.char_`, preserving that binding after the body walk.

---

### BUG-039: Selfhost mutation scanner marks string-method receiver as `var` — FIXED
- **Status:** Fixed 2026-04-18 (commit 443886d)
- **Fix:** Added missing string methods to `isReadOnlyMethod()` in `cg_helpers.zbr`: `reverse`, `padLeft`, `padRight`, `center`, `toHex`, `fromHex`, `repeat`, `replace`, `isAlpha`, `isNumeric`, `isValidUtf8`.

---

### BUG-041: `^ClassType?` emits `?**T` instead of `?*T` (root cause) — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** `src/CodeGen.zig::genType .ref_to` arm: when `^T`'s inner payload is a class, emit `*ClassName` / `?*ClassName` directly and skip the recursive `genType` call. Class auto-boxing already provides the pointer; `^` is a representation no-op for classes.

---

### BUG-045: Ctor-arg boxing wraps `^Class?` args in extra `*` — FIXED
- **Status:** Fixed 2026-04-17 (`a5e082b`) — Zig backend only; selfhost was already correct via Phase 17c walker.
- **Fix:** `genBoxedArgExpr` in `src/CodeGen.zig` short-circuits when the payload is a class and falls through to plain `genArgExpr`.

---

### BUG-047: Field-read + field-assign on `^Class?` emitted stale boxing after BUG-041 fix — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** Three parallel class-payload short-circuits in `src/CodeGen.zig` — `.member` field-read, `StmtAssign` self-ref boxing, `StmtAssign` `ref_box_type_name` path — each now checks class vs non-class payload before applying boxing.

---

### BUG-048: Selfhost resolver does not register enum names — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** Added `on PNode.enum_ as e` arm to `bindTopDecl` in `selfhost/resolver.zbr`, mirroring the existing `union_decl` arm.

---

### BUG-049: Selfhost parser drops field initializers — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** `PField` struct gained `init_expr as List(PNode)`; `parseDeclField` parses optional `= .parseExpr()`; `astbuilder.zbr::buildMember` threads `f.init_expr` into the `DeclVar` init slot.

---

### BUG-050: Selfhost branch-on drops multi-pattern lists and inline-else — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** `PBranchOn.patterns` (was `pattern`); `parseBranchStmt` loops collecting comma-separated patterns; else arm handles inline `else, stmt` form; `buildBranch` iterates all patterns.

---

### BUG-051: Selfhost genRaise drops the 2-arg `raise msg, details` form — FIXED (primitive + string paths)
- **Status:** Fixed 2026-04-17 (object path emits `@compileError` fail-loud, pending future port)
- **Fix:** `parseRaiseStmt` collects optional `, expr` details; `genRaise` ported primitive + string emission paths from `src/CodeGen.zig`. Added `nextUid()` to `Writer` class.

---

### BUG-052: Selfhost parseUnary drops the `try expr` prefix form — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** `parseUnary` gained a `try` branch — consume `try`, recurse with `parseUnary()`, wrap in `PNode.expr_try(operand)`.

---

### BUG-053: Selfhost parseAtom rejects the `zig"..."` / `zig'...'` backend literal — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** Added `expr_zig_lit as str` PNode variant; `isZigLit()` helper; `parseAtom` arm; `astbuilder.zbr::stripZigQuotes` + `on PNode.expr_zig_lit` arm.

---

### BUG-055: Selfhost parsePostfix drops `expr.get(args)` / `expr.post(args)` method calls — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New branch in `parsePostfix` after the `isOpenCall` check: when peek text is `"get"` or `"post"` and `peekAt(1).text == "("`, treat it as a method call — consume the keyword, consume `(`, reuse `parseCallArgs()`.

---

### BUG-056: Selfhost parser rejects `r"..."` / `r'...'` raw string literals — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** Added `isRawString()` helper, new `PNode.expr_raw_str as str` variant, new `parseAtom` arm. `astbuilder.zbr` new `stripRawAndEscape(text)` helper + arm.

---

### BUG-057: Selfhost parseStmt rejects `arena` scope blocks — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PArenaScope` holder struct, `PNode.stmt_arena_scope as ^PArenaScope` variant, `parseArenaScopeStmt`, astbuilder arm.

---

### BUG-058: Selfhost parseStmt rejects `with target` contextual-self blocks — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PWith {target, stmts}` struct, `PNode.stmt_with`, `parseWithStmt`, astbuilder arm with `rewriteWithStmt` desugaring bare assigns to member accesses on target.

---

### BUG-059: Selfhost parseStmt rejects `guard ... else` blocks — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PGuard {cond, else_stmts}`, `PNode.stmt_guard`, `parseGuardStmt` (supports both block and inline `, stmt` forms), astbuilder arm.

---

### BUG-060a: Selfhost parseOr drops the `orelse` binary op — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `POrelse {expr, fallback}`, `PNode.expr_orelse`, extended `parseOr` loop with `orelse` check, astbuilder arm.

---

### BUG-060b: Selfhost parseExpr drops the `->` pipeline operator — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PPipeline {lhs, rhs}`, `PNode.expr_pipeline`, `parsePipeline` wrapper (left-associative while-loop on `->`), astbuilder arm desugars `lhs -> f(args)` → `f(lhs, args...)`.

---

### BUG-061: Selfhost `genMemberCall` rewrites `ClassName.add(...)` to List.append — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** Added `is_class_ref = isUpperCase(add_nm)` guard alongside existing `is_strset` check. `.add → .append` rewrite skips uppercase class-style identifiers.

---

### BUG-062: Selfhost parseTopDecl rejects the `namespace` keyword — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PNamespace {name, decls}`, `parseNamespaceDecl`, astbuilder arm, `generateEntryPoint` extended to find `main` inside namespaced classes.

---

### BUG-063: Selfhost parseWhileStmt rejects `while var id = init, cond` bind-and-guard — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** Parse-side desugar — `while true { var id = Init; if not Cond: break; ...body }`. Zero AST/codegen changes.

---

### BUG-064: Selfhost parseTopDecl rejects the `interface` keyword — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PNode.interface_ as ^PClass`, `parseInterfaceDecl`, astbuilder arm, `bv.add("PNode.interface_")` in `addCrossModuleBoxedVariants`.

---

### BUG-065: Selfhost parseTopDecl rejects the `extend Type` keyword — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PExtend {target_name, members}`, `parseExtendDecl`, astbuilder arm, `bv.add("PNode.extend_")`, `genExtMethod` updated for `"String"` alias.

---

### BUG-066: Selfhost eatTypeName rejects sized numeric type names (int32/uint8/float32/byte/uint) — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** Added `isSizedTypeName()` helper; extended `eatTypeName`; added `"byte" → "u8"` to `zigTypeForName`.

---

### BUG-067: Selfhost parseMemberDecl rejects the `get name as T` computed-property form — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PProperty {name, type_name, getter_stmts}`, `parsePropertyDecl`, `buildProperty`, `bv.add("PNode.property_")`.

---

### BUG-068: Selfhost parser rejects generic-arg `?` suffix and `name:` labeled call args — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** (a) Generic-args loop in `eatTypeName` now peeks for `?` after each arg and folds it in. (b) `parseCallArgs` consumes `name:` label before the expression.

---

### BUG-069: Selfhost parser missing `expr is TypeName` type-check — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** `parseComparison` gained `else if this.textIs("is")` arm; `astbuilder.zbr` intercepts `pb.op == "is"` and emits `Expr.type_check`; `bv.add("Expr.type_check")`.

---

### BUG-070: Selfhost parser missing `var {x, y} = expr` struct/tuple destructuring — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PDestruct {names, init_expr, is_struct}`, `parseDestructStmt`, `ast.zbr` gained `is_struct as bool` on `StmtDestruct`, astbuilder arm, `bv.add("PNode.stmt_destruct")`, `genDestruct` uses `nextUid()` + branches on `is_struct`, `resolveStmt` arm added.

---

### BUG-071: Selfhost TypeChecker misses string-method return types; str.count(substr) unimplemented — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `stringMethodReturn(name)` function in `typechecker.zbr`; `inferExpr` for `ExprMember` switched to recursive `inferExpr(mem.object)` + `Type_.string_` dispatch arm; `codegen.zbr` gained `str.count(substr)` emit path; `blk_box` typed via `std.meta.Child(@FieldType(...))`.

---

### BUG-072: Tokenizer suppresses EOL/INDENT/DEDENT inside parens — statement-body lambdas fail — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** 5-field state machine in `src/Tokenizer.zig` and `selfhost/Lexer.zbr` (`in_lambda_params`, `lambda_param_depth`, `after_lambda_params`, `lambda_body_active`, `lambda_indent_level`). `parseLambdaExpr` extended to handle both expression-body (`= expr`) and statement-body (eol + indent block) forms.

---

### LANG-001: Top-level `def` not supported — FIXED 2026-04-10
- **Status:** Fixed
- `TopDecl → MethodDecl` production added; `AstBuilder.zig` handles `MethodDecl` case setting `is_top_level = true`; `CodeGen.zig` skips `self.`/`ClassName.` prefix for top-level methods.

---

### LANG-002: `on X return Y` inline form and blank-line sensitivity — FIXED 2026-04-10
- **Status:** Fixed
- Added `BranchOnClause → kw_on Expr kw_return Expr eol` production; `BranchOnList → BranchOnList eol` production to handle blank lines.

---

### LANG-003: `^T` heap-indirection type for recursive structs — ADDED 2026-04-10
- **Status:** Implemented
- `var next as ^Node?` declares heap-allocated pointer. `^T` emits `*T` in Zig; `^T?` emits `?*T`. Auto-boxed on assignment.

---

### LANG-004: Cross-module TypeRef resolution — ADDED 2026-04-10
- **Status:** Implemented (extended from MVP to full TC inference)
- `ModuleInterface` tracks exported type names; `Resolver` handles dotted names; TypeChecker added `.cross_module` Type variant.

---

### LANG-005: `^T` auto-boxing for cross-class field assignments — FIXED 2026-04-10
- **Status:** Fixed
- `genClass` now uses `withClass(n)` for ALL concrete classes. `ref_box_type_name` extended for `localVar.field = x` targets.

---

### BUG-040: Selfhost `print` emits `{}` instead of `{s}` for strings — FIXED 2026-04-19
- **Status:** Fixed in selfhost `genPrint` and `genStringInterp`
- `genPrint` now calls `isStringBoth(expr, "print")` to emit `{s}` for string expressions. `genStringInterp` similarly uses `isStringBoth(e, "interp_fmt")` for interpolated parts. Also fixed: `genStringInterp` now emits `catch @panic("OOM")` instead of `try` (correct for Zebra non-throws context).

---

### BUG-042: Selfhost cross-module struct ctor missing `.init` — FIXED 2026-04-19
- **Status:** Fixed in `selfhost/codegen.zbr::genCall`
- Added `dep_types.hasClass(cm_mem)` check alongside `isCrossModuleCtorCall`. Now detects `Mod.ClassName(args)` as a cross-module struct constructor for any class in the dependency module types, emitting `Mod.ClassName.init(args)`.

---

### BUG-043: Selfhost `Mod.Union.variant(v)` emits fn-call not struct-init — FIXED 2026-04-19
- **Status:** Fixed in `selfhost/codegen.zbr::genCall` via `getXmUnionParts` helper
- Added `getXmUnionParts(callee)` top-level helper that detects 3-part `Mod.Union.variant` callee shapes. `genCall` calls it and emits `Mod.Union{ .variant = value }` with boxed-payload support.
- **Implementation note:** A nested `branch outer_m.object on Expr.member` was attempted but the Zig backend doesn't auto-deref `^Expr` fields in nested branch subjects (TC annotation not consulted for switch subject in method context). Workaround: standalone helper function where TC correctly annotates direct branch bindings.

---

### BUG-044: Selfhost cross-module branch pattern collapses variant tag to union type name — FIXED 2026-04-19
- **Status:** Fixed in `selfhost/astbuilder.zbr::buildBranch`
- `buildBranch` now handles 3-part dotted patterns (e.g. `test_lib.Value.num`) by building a nested member chain: `Expr.member(Expr.member(Expr.ident("test_lib"), "Value"), "num")`. Previously, only 2-part patterns were handled, causing `Mod.Union.variant` to collapse to `.Union`.

---

### BUG-074: `Result.ok` / `Result.err` constructor syntax — REMOVED 2026-04-19
- **Status:** Removed from language and compiler
- `Result(T, E)` as a language-level generic type is removed. Both the Zig compiler (`src/CodeGen.zig`, `src/TypeChecker.zig`) and the selfhost port (`selfhost/codegen.zbr`, `selfhost/resolver.zbr`) had their Result-specific handling excised. The `_Result` preamble helper, `genResultMethod`, and `genResultCall` are all deleted. Test files `result_test.zbr` and `result_methods_test.zbr` (which exercised the constructor syntax) are deleted. Bootstrap: 5/5 steps pass, byte-identical round-trip.

---

### BUG-006: `zig"..."` expression statement emits double semicolon — FIXED both sides
- **Status:** Fixed — Zig backend 2026-04-17; selfhost fixed 2026-04-20 (Phase 20)
- `zig"some_stmt;"` inside a method body emitted `some_stmt;;` — the zig literal already ends with `;`, and `genStmt` for `.expr` always appended another `;`.
- Zig-side fix: `src/CodeGen.zig::genStmt` `.expr` case detects trailing `;` on `zig_lit` content and skips the appended `;`.
- Selfhost fix: `selfhost/codegen.zbr::genStmt` `on Stmt.expr` now checks `if e is Expr.zig_lit`: emits content, adds `;` only if content doesn't already end with `;`.

---

### BUG-035: Selfhost parser has no atom handler for `doc_string_line` (`"""..."""` multi-line strings) — FIXED
- **Status:** Fixed Phase 20 (2026-04-20)
- `selfhost/parser.zbr:1885` handles `isDocString()` → `PNode.expr_str(text)`.

---

### BUG-037: Selfhost corpus-failure triage — RESOLVED 2026-04-19
- **Status:** Closed — corpus reached 100% (149/149) via BUG-048 through BUG-073 grammar wave.

---

### BUG-046: Selfhost partial-class sibling file merge — FIXED 2026-04-19
- **Status:** Fixed — committed 2026-04-19
- Added `mergePartials_pmodule` in `selfhost/main.zbr`. Key detail: `"" + psrc_raw` copies the read buffer into permanent arena storage before parsing (Zig 0.15 `File.read` defer can rewind arena).

---

### BUG-075: `String + str` concat not routed through `_str_concat` in selfhost TypeChecker — FIXED
- **Status:** Fixed Phase 20 (2026-04-20)
- Extended `isString(t)` in `selfhost/typechecker.zbr` to accept `Type_.cross_module` where `cm.type_name == "String"`.

---

### BUG-076: `if x is Union.variant |r|` capture binding not in TypeChecker `narrowed_types` — FIXED
- **Status:** Fixed — `isCaptureLookup` 3-way payload lookup in TypeChecker.zig; selfhost walker narrowing in typechecker.zbr; `genIsCaptureThen` ptr_field_bindings seeding in codegen.zbr; bootstrap 5/5.

---

### BUG-077: TC doesn't record inferred type for `?`-propagated throws-call assignments — RESOLVED
- **Status:** Not reproducing — resolved indirectly by BUG-076 + Phase 20 typeFromRef fix (2026-04-21). Verified both `src/TypeChecker.zig` and `selfhost/typechecker.zbr` correctly propagate through `.try_` nodes.

---

### BUG-078: `^ClassName` in union variant double-boxes (`**T`) — FIXED
- **Status:** Fixed — `src/Resolver.zig::walkUnion` emits a hard error when payload is a class type. Test: `test/bug078_double_box_test.zbr` (intentional-error fixture).

---

### BUG-080: `^T?` field assignment — CLOSED NOT REPRODUCING
- **Status:** Closed 2026-04-21. Verified: `n.next = n2` where `next: ^Node?` generates correct `n.next = n2;` — BUG-047 class short-circuit in `genAssign` and `field_needs_deref` both correctly suppress the `.*` for class-typed optional ref fields.
