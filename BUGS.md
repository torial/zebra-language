# Zebra Compiler — Bug Tracker

Running triage list. Updated each milestone. Format: severity (blocker/high/medium/low), status (open/fixed/deferred), and milestone target.

---

## Open Bugs

### BUG-001: ~~Shared method calling shared method emits `self.` prefix~~ — FIXED
- **Status:** Fixed (prior session — TCO work fixed bare shared method calls)
- Was: `testHelper()` inside a shared method generated `self.testHelper()`.
- Now: emits `ClassName.methodName()` correctly for shared→shared calls.

---

### BUG-002: `guard` + `try_postfix` runtime error propagation
- **Severity:** Medium
- **Status:** Open
- **Target:** 0.3 or 0.5 (source-mapped errors)
- **Symptom A (`guard_test`):** `checkPositive` raises inside a guard else block; top-level `try Main.main()` panics with `error: ZebraError`.
- **Symptom B (`try_postfix_test`):** `safeDiv(10,0)?` propagates through `main throws`; top-level panics. The test doesn't catch the error — it's testing propagation but exits non-zero.
- **Note:** Both are likely correct behavior for Zebra error semantics. The tests need `try/catch` wrapping to validate error propagation without panicking. Test quality issue + potentially a compiler issue with top-level error display.

---

### BUG-003: ~~HTTP `serve` fails on Windows with "comptime call of extern function"~~ — FIXED
- **Status:** Fixed 2026-04-09
- Was: `_Ctx` struct stored `handler: Handler` where `Handler = @TypeOf(handler)` is a bare function type (comptime-only in Zig). Made the entire struct comptime-only, so `page_allocator.create(_Ctx)` triggered the `NtAllocateVirtualMemory` comptime path.
- Fix: Declare `const _HFn = *const fn(HttpRequest) HttpResponse` and coerce `const _fn: _HFn = handler` before `_Ctx`. Store `handler_fn: _HFn` in `_Ctx` (fn-pointer = runtime type). Call `ctx.handler_fn(_req)` directly. All three HTTP routes verified working on Windows.

---

### BUG-004: `padLeft/padRight/center` — fill char `'*'` passed as string to `u8` param — FIXED this session
- **Status:** Fixed 2026-04-08
- Was: `_pad_left(s, n, "*", alloc)` failed — `"*"` is `*const [1:0]u8`, not `u8`.
- Fix: Changed pad helpers to accept `anytype` fill; added `_pad_fill` normaliser that handles both char literals (comptime_int) and 1-char strings (pointer).

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

---

### BUG-005: `{d:0>N}` format adds `+` prefix to positive `i64` in Zig 0.15 — FIXED
- **Status:** Fixed 2026-04-09
- **Context:** DateTime preamble `_dt_to_iso8601` and `_dt_format` used `i64` fields with `{d:0>N}` format spec. Zig 0.15.2 adds a `+` sign to positive signed integers when using fill-aligned format (e.g. `{d:0>4}` for `i64 = 1970` → `+1970`).
- **Fix:** Cast all date fields to unsigned types (`@as(u32, ...)`, `@as(u8, ...)`) before passing to `bufPrint`/`allocPrint`. Unsigned integers never receive a sign prefix.
- **Broader note:** This is a Zig 0.15 breaking change from 0.14. Any future preamble code that formats `i64` values with fill-aligned specs should cast to unsigned first.
- **Re-verified 2026-04-17** (`C:\tmp\verify_bug005.zbr`): Zig-backend prints `2026-04-17T23:08:27Z` — no `+` prefix anywhere. Selfhost **untested** (`dt.toIso8601()` method dispatch not wired — feature gap, not a regression of BUG-005 itself).

---

### BUG-006: `zig"..."` expression statement emits double semicolon — FIXED (Zig side)
- **Severity:** Low
- **Status:** Fixed (Zig backend) 2026-04-17; selfhost side still emits `;;` (cosmetic)
- **Target:** 0.5 (low priority)
- **Symptom:** `zig"some_stmt;"` inside a method body emitted `some_stmt;;` — the zig literal already ends with `;`, and `genStmt` for `.expr` always appended another `;`.
- **Zig-side fix:** `src/CodeGen.zig::genStmt` `.expr` case (lines ~4290-4300) detects trailing `;` on `zig_lit` content and skips the appended `;`.
- **Selfhost residue:** `selfhost/codegen.zbr::genStmt` `on Stmt.expr` (line 1938) unconditionally emits `;\n`. Double `;;` is syntactically valid Zig (empty stmt), so round-trip is still clean. Port when selfhost is next touched.
- **Re-verified 2026-04-17** (`/c/tmp/verify_bug006.zbr`): Zig-side emit clean — no `;;` in output. **Selfhost divergence surfaced:** the selfhost parser rejects `zig"..."` even in statement position with `unexpected expression token: 'zig"..."'`. This contradicts BUG-037's aside that "stmt form works (BUG-006 fixed it)" — the Zig-side fix is real, but selfhost can't actually parse it at all. Roll into BUG-037 grammar wave (expression-form and stmt-form share a parser path).

---

---

### BUG-007: `String + String` string concatenation not handled — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `+` operator on strings fell through to the numeric `else` branch in `genBinary`, emitting `(a + b)` which Zig rejects for `[]const u8`. TypeChecker also rejected `String + String` as arithmetic.
- **Fix:**
  - TypeChecker `inferBinary`: added `if (e.op == .add and lt == .string) break :blk .string` before the numeric guard.
  - CodeGen `genBinary`: added dedicated `.add` case — if left operand is string, emits `_str_concat(a, b, _allocator)`.
  - Preamble: added `_str_concat(a, b, alloc)` using `std.mem.concat`.
- **Note:** String concat was previously untested; all prior tests used interpolation `"${var}"` or `StringBuilder`. Now `greeting + ", " + name` style works.
- **Re-verified 2026-04-17** (`C:\tmp\verify_bug007.zbr`): both Zig-backend and selfhost emit `_str_concat`, build, and print `hello, world`.

---

---

### BUG-008: Mutation scanner — `.unknown` TC type caused spurious `var` — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** When `tc.resolve.exprs` had no entry for an ident used as a method receiver (common for stdlib builtins like `sys.args()`), `inferIdent` returned `.unknown`, which the scanner conservatively treated as always-mutating — marking variables like `args` as `var` when they should be `const`.
- **Fix:** Removed the `if (obj_type == .unknown) break :blk true` conservative path. Unknown types now fall through to the explicit allow-list. Added `if (obj_type == .string) break :blk false` guard: Zebra strings are always immutable, so no method call should mark a string var as `var`. These two changes together fix `string_methods_test` (`str.reverse()` was in the List-mutation allow-list) and `sys_test` (`args.count()` was treating the unresolved `args` as always-mutating).
- **Re-verified 2026-04-17** (`/c/tmp/verify_bug008.zbr`): Zig-backend holds — emits `const greeting`, `{s}` format, builds + runs under Zig 0.15 ReleaseSafe, prints `olleh`. **Regressed in selfhost** — selfhost emits `var greeting` + `{}` format (see BUG-039 + BUG-040).

---

### BUG-009: Escape analysis — field writes not propagated — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `propagateEscapesOnce` only traced `var y = <expr>` alias chains. If a variable was stored into a returned struct's field (`result.items = list; return result`), `list` was not marked escaped and would get a `defer list.deinit()` while `result.items` still referenced its memory — a UAF.
- **Fix:** Added `.assign => |s|` handling in `propagateEscapesOnce`: if the assignment target is a field access (`obj.field`) and `obj` is already in the escaped set, all idents in the RHS value are added to the escaped set.
- **Re-verified 2026-04-17** (`/c/tmp/verify_bug009.zbr`): locally-built List assigned into returned Holder field; both compilers build and print `10 / 20 / 30`.

---

### BUG-010: Partial class — duplicate method silently appended — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `mergePartialInto` concatenated all members from a partial without checking for name conflicts. If a partial redefined a method already in the root file, both definitions were appended, producing a Zig compile error with a confusing message about the generated file.
- **Fix:** `mergePartialInto` now scans for duplicate method names before merging. Duplicates emit a clear warning (`"duplicate method 'ClassName.method' — already defined in root"`) and the partial definition is skipped. Non-method members (vars, properties) are still appended unconditionally.
- **Re-verified 2026-04-17** (`C:\tmp\bug010/Greeter.zbr` + `Greeter.ext.zbr`): Zig-backend emits the expected warning (`duplicate method 'Greeter.hi' — already defined in root; skipping partial definition`), builds, and prints `root` (root's definition wins). Selfhost deep probe: grep for `partial` in `selfhost/` returns zero hits outside an unrelated comment; no `mergePartials`/`mergePartialInto` equivalent exists. Selfhost emits a single `fn hi() []const u8 { return "root"; }` — the `.ext.zbr` partial is never discovered, never warned about. For this test both compilers yield "root" for unrelated reasons (Zig by explicit dedup; selfhost by partials-not-implemented). A partial adding *non-conflicting* members would be silently dropped by selfhost — tracked as BUG-046, not a regression of BUG-010.

---

### BUG-011: `tcTypeAnnotation` — comprehensive type annotation for `var` locals
- **Status:** Fixed 2026-04-09
- **Context:** Previously `genLocalVar` used an ad-hoc 6-case inline switch (`.int`, `.uint`, `.float`, `.bool`, `.char`, `.string`) to emit type annotations on mutable local variables. Several cases were missing: sized numerics (`int32`, `uint8`), optional wrappers (`?str`), and `str_slice` (`[]str`).
- **Fix:** Replaced the inline switch with `tcTypeAnnotation(t, alloc)` — a dedicated module-level function mapping all `TypeChecker.Type` variants to Zig annotation strings. All results are uniformly heap-allocated and freed with `defer`. Unknown types and named/stdlib types return null (Zig infers correctly for those). The generic-type assumption (generics always have explicit AST annotations so tcTypeAnnotation is never called for them) is documented inline.

---

### BUG-012: `_type_id` uninitialized for classes without explicit `cue init` — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** Classes with no explicit `cue init` were constructed via `ClassName{}` (struct literal), which sets fields to their defaults. The `_type_id: u32 = _tid_ClassName` field default worked in simple cases but was structurally fragile — any path that bypassed struct-literal construction (e.g., inline Zig `= undefined`) left `_type_id` garbage.
- **Fix:** `genClass` now checks whether any member (own or mixin) is `.init`. If not, a synthetic default `pub fn init() ClassName` is emitted that explicitly stamps `self._type_id = _tid_ClassName`. The constructor call site was updated to emit `ClassName.init()` instead of `ClassName{}` for classes with no explicit init, so all construction paths go through init().
- **Re-verified 2026-04-17** (`/c/tmp/verify_bug012.zbr`): class without `cue init`, field assignment `w.label = "hi"`; both compilers build + run, print `hi`.

---

### BUG-013: `collectEnumMembers` — blank-line leaf detection used structural comparison — FIXED
- **Re-verified 2026-04-17** (`C:\tmp\verify_bug013.zbr` — enum with blank lines between variants): Zig-backend prints `g` (variant resolves). Selfhost **fails at resolve stage** with `undefined name: 'Color'` — selfhost's parser/resolver appears to have an analogous blank-line-in-enum issue. Zig-backend fix holds; selfhost has an independent gap (not a regression of BUG-013 Zig side — selfhost has its own enum-blank-line path). File separately if it becomes a self-hosting blocker.
- **Status:** Fixed 2026-04-10
- **Was:** `if (kids[1] != .leaf)` in `collectEnumMembers` was a structural assumption about the tree shape — it relied on the fact that blank-line productions always produce `.leaf` nodes, which is an implementation detail of the Earley grammar output format.
- **Fix:** Replaced with the named helper `isMeaningfulNode(tn: TN) bool` (returns `true` only for `.inner` nodes), co-located with the other tree-node helpers near the bottom of `AstBuilder.zig`. Intent is now explicit: skip everything that isn't a grammar rule reduction.

---

### BUG-014: Regex lazy match is global, not per-quantifier
- **Severity:** Medium
- **Status:** Open — architectural limitation
- **Symptom:** In a pattern mixing lazy and greedy quantifiers (e.g., `<.*?>.*>`), the global `lazy_match` flag makes ALL quantifiers lazy, so `<.*?>.*>` on `<a><b>` returns `<a>` instead of `<a><b>`.
  - Simple lazy patterns `<.*?>` work correctly.
  - Mixed patterns `<.*?>STUFF.*>` misbehave.
- **Root cause:** The current Thompson NFA passes a global `shortest: bool` to `matchAt`. When ANY `*?`/`+?`/`??` is parsed, `flags.lazy_match = true` is set for the whole regex. The `out1`/`out2` ordering in split nodes DOES encode per-quantifier preference, but `shortest=true` causes the match loop to exit at the FIRST match found, which overrides the greedy `.*` that should extend further.
- **Fix (architectural):** Requires either:
  1. A priority-first NFA simulation (track thread priorities; when multiple threads reach match, highest-priority wins based on `out1`/`out2` ordering path) — complex to implement
  2. A backtracking regex engine — simpler but worst-case O(2^n)
- **Workaround:** For patterns needing mixed lazy/greedy, split into multiple regex calls or restructure the pattern.

---

### BUG-015: `scanMutationsInto` missing `.assert` case — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `scanMutationsInto` handled `.var_`, `.expr`, `.print`, etc. but had no `.assert` case. Method calls on user-defined types inside `assert` conditions (e.g., `assert d.show() == "x"`) were never scanned. The mutation scanner's conservative rule ("any method call on a `.named` type marks the receiver as `var`") never fired for assert conditions, so the receiver was emitted `const`. Then Zig rejected passing `*const Diag` to a method taking `*Diag`.
- **Fix:** Added `.assert => |s| try scanMutationsInExpr(s.cond, set, tc_opt)` to `scanMutationsInto`.
- **Found by:** Self-hosting probe (`test/selfhost_probe.zbr`) — `assert d.show() == "..."` triggered it.
- **Re-verified 2026-04-17** (`/c/tmp/verify_bug015.zbr`): `var d = Diag.init()` emitted on both zebra.exe and zebra-selfhost.exe; `assert d.show() == "x"` routes through `scanMutationsInto.assert` and marks `d` mutable.

---

### LANG-001: Top-level `def` not supported — FIXED 2026-04-10
- **Status:** Fixed
- **Was:** `def kindName(k as TokenKind) as str` at top level (outside any class) was a syntax error. `TopDecl` didn't include `MethodDecl`.
- **Fix:**
  - `ZebraGrammar.zig`: Added `TopDecl → MethodDecl` production.
  - `AstBuilder.zig`: Added `MethodDecl` case in `buildTopDecl`, setting `is_top_level = true` on the resulting `DeclMethod`.
  - `Ast.zig`: Added `is_top_level: bool = false` field to `DeclMethod`.
  - `CodeGen.zig`: In the bare-ident-call path (for calls within class methods), `is_top_level` methods skip the `self.` / `ClassName.` prefix and call directly by name.
  - Binder, Resolver, TypeChecker, and `genTopDecl` already handled top-level `method` decls.

---

### LANG-002: `on X return Y` inline form and blank-line sensitivity — FIXED 2026-04-10
- **Status:** Fixed
- **Was (a):** `on X  return Y` (no comma, inline return) failed to parse. `on X, return Y` (comma + return) also failed because `StmtReturn → kw_return Expr eol` requires a trailing `eol`, making `return` incompatible with the inline `on X, Stmt` production when `Stmt` doesn't include its own eol.
- **Was (b):** The inline comma form (`on X, return Y`) silently broke with a blank line after the last on-clause because the blank line emitted a bare `eol` token that landed inside `StmtBranch`'s expected `dedent`.
- **Fix (a):** Added `BranchOnClause → kw_on Expr kw_return Expr eol` production to `ZebraGrammar.zig`. `AstBuilder.buildBranchOnClause` detects this as `kids.len == 5 and kids[2] == kw_return` and wraps the return value in a synthetic `StmtReturn`. Now `on TokenKind.ident return "ident"` is valid syntax.
- **Fix (b):** Added `BranchOnList → BranchOnList eol` production. `collectBranchOnList` skips blank-line nodes (checking `isLeafKind(kids[1], .eol)`).
- **Verified:** `test/selfhost_probe.zbr` uses native top-level `def` + `on X return Y` syntax and passes.

### BUG-016: `inferMember` didn't unwrap optional type before member lookup — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `inferMember` only looked up fields/methods when `obj_type == .named`. For chained optional accesses like `n?.next` (where `n: ?Node`), the TC type of `n` passed to `inferMember` was `.optional(.named(Node))` — not `.named`. The member lookup silently returned `.unknown`. Local vars initialised from such accesses (`var n2 = n?.next`) then had `.unknown` declared type, so the `optional_unwraps` check for `n2?` failed and CodeGen emitted `try n2.field` (error-propagation) instead of `n2.?.field` (optional-unwrap).
- **Fix:** Added `resolved_obj_type = if (obj_type == .optional) obj_type.optional.* else obj_type` before the `.named` member lookup. The `generic_named` branch was not affected (it already has its own path).
- **Found by:** Recursive type test (`test/recursive_type_test.zbr`) — `n2?.value` where `n2` was inferred from a chained optional access.
- **Re-verification 2026-04-17: unverified** — three attempted re-probes tripped on adjacent codegen bug **BUG-041** (`^ClassType?` emits `?**T`) before reaching the inferMember-unwrap path.
- **Re-verification 2026-04-17 (after BUG-041 fix): holding.** `verify_bug016c.zbr` (minimal member-through-optional-return probe) emits `?*Node` return type, compiles under Zig 0.15 ReleaseSafe, runs printing `42`. `n.?.value` (optional-unwrap form) is emitted correctly — not `try n.value` (error-propagation form).

---

### LANG-003: `^T` heap-indirection type for recursive structs — ADDED 2026-04-10
- **Status:** Implemented
- **What:** `var next as ^Node?` declares a heap-allocated pointer to `Node?`, breaking Zig's recursive struct size cycle. `^T` emits `*T` in Zig; `^T?` emits `?*T`. Type-checked as `T` (the pointer is a codegen detail only).
- **Auto-boxing:** Assignments like `a.next = b` where `a.next` is `^Node?` auto-box `b`: emits `{ const _rp = _allocator.create(Node) catch ...; _rp.* = b; a.next = _rp; }`. Value-copy semantics: the snapshot at boxing time is what's stored; later mutations to the original don't propagate to the boxed copy.
- **Test:** `test/recursive_type_test.zbr`

---

### LANG-004: Cross-module TypeRef resolution — ADDED 2026-04-10, EXTENDED 2026-04-10
- **Status:** Implemented (extended from MVP to full TC inference)
- **What:** `var x as Mod.TypeName` in a file that `use Mod` now resolves correctly. `Mod.TypeName(args)` constructor calls return TC type `.cross_module` (not `.unknown`) so method calls on the result are fully typed. String methods on cross-module instances now correctly use `std.mem.eql` instead of raw `==`.
- **How:** `ModuleInterface` tracks exported type names; `Resolver` handles dotted names; `TypeChecker` added `.cross_module { module, type_name }` Type variant returned by `typeFromRef` for cross-module TypeRefs and by `inferCall` for cross-module constructor calls; `inferMember`/`inferCall` look up field/method types in `imported_modules` when `obj_type == .cross_module`. Library modules now export `_initAllocator` and root `main` propagates its allocator to all imported modules.
- **Limitation:** Nested/chained cross-module method return types (e.g. `a.crossMod().method()`) still resolve to `.unknown`. Full cross-module generic type propagation is future work.
- **Test:** `test/crossmod_types_test.zbr` — now includes `assert p.show() == "(3, 4)"` and `assert s.label() == "(0, 0) to (3, 4)"`.

### LANG-005: `^T` auto-boxing for cross-class field assignments — FIXED 2026-04-10
- **Status:** Fixed
- **What:** `^T` (non-optional heap-indirection) field boxing via `ref_box_type_name` now works when the target field belongs to a different class than the one being generated. Previously `resolveFieldTypeRef` only searched `owner_class` which was only set for generic classes.
- **Fix:**
  1. `genClass` now uses `withClass(n)` (new helper) instead of `withOwner(n.name)`, so `owner_class` is set for ALL concrete classes.
  2. `ref_box_type_name` extended: for `localVar.field = x` targets, after searching `owner_class`, falls back to looking up the field via the TC type of the object. For nested `a.b.field = x`, looks up `field` in the declared type of `a.b`.
- **Test:** `test/recursive_type_test.zbr` — `PairHolder` test with non-optional `^Pair` field.

### BUG-017: `len` on unknown-TC-type emits `.items.len` heuristic — imprecise
- **Severity:** Low
- **Status:** Open — known imprecision; deferred until ModuleInterface preserves return types
- **Symptom:** When a local variable's TC type is `.unknown` (most commonly: the result of a cross-module method call whose return type isn't tracked in `ModuleInterface.methods`) and `.len` is accessed on it, CodeGen emits `.items.len` as a last-resort fallback. This is correct for `ArrayList`-backed `List(T)` values but is wrong for any user-defined struct that has a field named `len`.
- **Example that triggered it:** `lexer_test.zbr` — `var toks = Lexer.tokenize(src)` returned a cross-module `List(Token.Token)`; `toks.len` needed `.items.len`. TC type of `toks` was `.unknown` because `ModuleInterface.methods` stores only `TypeChecker.Type` scalars, not generic `List(T)` return shapes.
- **Root cause:** `ModuleInterface` does not preserve enough information to know that `Lexer.tokenize` returns a `List(Token.Token)`. The methods map stores `Type` values which have no "list of T" variant. So cross-module list-returning calls always land with `.unknown` TC type, and the `len` heuristic fires.
- **Proper fix:** Add a `.list { elem_type }` variant to `TypeChecker.Type`, store it in `ModuleInterface.methods` for methods that return `List(T)`, and propagate it through `inferCall` for cross-module calls. Then the heuristic can be removed; `len` on a `.list` type correctly emits `.items.len`, and `len` on any other type emits `.len` (for slices/strings).
- **Risk of current heuristic:** A user struct with a field named `len` whose type can't be inferred cross-module will silently get `.items.len` emitted — producing a Zig compile error (not a silent wrong answer), so the bug is detectable.
- **Found by:** Self-hosting Phase 1 (`selfhost/lexer_test.zbr`).

### BUG-018: Top-level `def` referenced inside class method set `uses_self = true` — FIXED 2026-04-10
- **Re-verified 2026-04-17** (`C:\tmp\verify_bug018.zbr`): Zig-backend prints `hi!` (top-level `shout()` reachable from class method, no spurious `self` required). Selfhost emits but fails at runtime on format `{}` vs `{s}` — downstream BUG-040, not a regression of BUG-018 itself.
- **Status:** Fixed 2026-04-10
- **Was:** `refsInExpr` set `uses_self = true` for ANY `.method` symbol, including top-level `def` functions (LANG-001). When a class method body called a top-level function (e.g., `opName(o)` inside `Calc.describe`), `uses_self` was incorrectly True, so the compiler omitted `_ = self;`. Zig then reported "unused function parameter" for `self`.
- **Fix:** `refsInExpr` now checks `sym.decl.method.is_top_level`; top-level methods do NOT set `uses_self`. Only instance method references (where the call is emitted as `self.method()`) mark self as used.
- **Found by:** Running full test suite after restoring Phase 1 self-hosting changes. `test/branch_inline_return_test.zbr` → `describe` called the top-level `opName`.

---

### BUG-019: `fn_ref` assignment in `genAssign` owns its own `;\n` terminator
- **Severity:** Low
- **Status:** Open
- **Target:** 0.5 (cleanup)
- **Symptom:** The `fn_ref_emitted` block inside `genAssign`'s `else` branch short-circuits with its own `try g.w.writeAll(";\n"); return;` instead of falling through to the shared `try g.w.writeAll(";\n")` at the bottom of the function. This asymmetry means that if any post-processing is ever added after the shared terminator (e.g., debug annotations, error redirects), the fn-ref path silently skips it.
- **Fix:** Restructure so `fn_ref_emitted` sets a flag and falls through to the shared terminator. Alternatively, extract the `;\n` + return pattern into a small helper so all early-exit paths are consistent.
- **Found by:** Post-implementation review of fn-ref reassignment (`pred = isDigit` → `pred = &isDigit`).

---

### BUG-020: `branch/on` call-expr pattern emitted wrong Zig — FIXED 2026-04-10
- **Status:** Fixed 2026-04-10
- **Was:** `on SomeUnion.variant() as x` in a `branch` on-clause is parsed as a call expression (callee = member `SomeUnion.variant`, args = []). `genBranch` only handled the `.member` case for union switch patterns, so a call expression fell through to `genExpr(v)`, which emitted the union constructor form `SomeUnion{ .variant = {} }` — a struct literal, not a valid Zig switch pattern.
- **Fix:** Added `else if (v.* == .call and v.call.callee.* == .member)` branch in `genBranch`'s union pattern path, extracting `v.call.callee.member.member` as the variant name and emitting `.variant_name`.
- **Also fixed:** Non-union `on PlainEnum.member` (no parens, `is_union = false`) was calling `genExpr(v)` for a `.member` node. Added `else if (v.* == .member)` in the non-union path to emit `.member_name` — correct Zig enum switch syntax.
- **Found by:** Self-hosting Phase 2 (`selfhost/ast_test.zbr`) — `on ast.TypeRef.nilable() as inner_ref` and `on ast.BinaryOp.add`.
- **Re-verified 2026-04-17** (`/c/tmp/verify_bug020.zbr`): Both compilers emit correct `.circle => |r| {...}` / `.square => |side| {...}` / `.empty => {...}` switch prongs. **Ticket stale-reproducer note:** the original surface form `on Union.variant() as name` no longer parses — the grammar now accepts only `on Union.variant as name` (no parens). The underlying fix still holds; re-writing future probes must use the current syntax. Union-variant multi-field payloads are likewise declared `variant as Type` (single-field), not `variant(name as Type)`.

---

### BUG-021: Struct `cue init` stamped `_type_tag` (class-only field) — FIXED 2026-04-10
- **Status:** Fixed 2026-04-10
- **Was:** `genInit` always emitted `self._type_tag = _ttag_StructName` as the first line of any `cue init` body. Structs have no `_type_tag` field (only classes do); the emitted assignment caused a Zig compile error (`no field named '_type_tag' in struct 'StructName'`).
- **Fix:** Added `is_struct_owner: bool = false` field to Generator. `genStruct` uses `var sg = g.withOwner(n.name)` (already done) and then sets `sg.is_struct_owner = true`. `genInit` wraps the `_type_tag` stamp in `if (!g.is_struct_owner)`.
- **Found by:** Self-hosting Phase 2 (`selfhost/ast.zbr`) — first struct with an explicit `cue init`.
- **Re-verified 2026-04-17** (`C:\tmp\verify_bug021.zbr`): both Zig-backend and selfhost build, and print `7` (struct with explicit `cue init` — no spurious `_type_tag` stamp).

---

### BUG-022: `boxed_variants` not cloned in `cloneInterface` — FIXED 2026-04-10
- **Status:** Fixed 2026-04-10
- **Was:** `cloneInterface` in `main.zig` cloned `types`, `throws_methods`, and `exposed_unions` from a `ModuleInterface` but not the new `boxed_variants` map (added for `^T` union payload boxing). Re-imported modules received an empty/uninitialized `boxed_variants`, so cross-module `^T` union construction silently skipped the boxing expression and emitted the raw value — producing a Zig type-mismatch error (`expected '*T', found 'T'`).
- **Fix:** Added full key/value clone loop for `boxed_variants` in `cloneInterface`. Also added `boxed_variants = std.StringHashMap([]const u8).init(alloc)` to the empty stub interface used for circular-import detection.
- **Found by:** Self-hosting Phase 2 (`selfhost/ast.zbr`) — cross-module `TypeRef.nilable` construction.
- **Re-verified 2026-04-17** (`/c/tmp/bug022_main.zbr` + `/c/tmp/bug022_lib.zbr`): Zig-backend holds — emits `.init`, struct-init with correct boxing expression, `.empty`/`.data` tags. **Three distinct selfhost regressions uncovered** in cross-module `Mod.Type.*` handling: BUG-042 (missing `.init`), BUG-043 (variant ctor as fn-call), BUG-044 (branch tag collapsed to union type name).

---

### BUG-023: Multi-line `cue init` blocked by indentation validator — FIXED 2026-04-10
- **Status:** Fixed 2026-04-10
- **Was:** The tokenizer's `processIndentation` function checked indentation on EVERY new line, including continuation lines inside open parentheses. A `cue init(a as int, b as int)` spanning two lines would trigger "SpaceIndentNotMultipleOfFour" because the continuation line's alignment indentation wasn't a multiple of 4. All `cue init` signatures had to fit on one line regardless of parameter count.
- **Fix:** Added `paren_depth: u32 = 0` tracking to Tokenizer. Incremented in `scanOperator` on `(` and decremented on `)`. Also incremented in `scanIdentOrKeyword`'s `open_call` path (which consumed `(` without going through `scanOperator`). `processIndentation` returns early when `paren_depth > 0`. EOL tokens suppressed when `paren_depth > 0` to prevent parser syntax errors on continuation lines.
- **Found by:** Self-hosting Phase 2 (`selfhost/ast.zbr`) — forced all `cue init` signatures onto single lines.
- **Re-verified 2026-04-17** (`/c/tmp/verify_bug023.zbr`): 4-arg `cue init` split across 4 lines parses and emits on both compilers.

---

### BUG-024: `throws` auto-propagation missing — FIXED 2026-04-10
- **Status:** Fixed 2026-04-10
- **Was:** Calling a `throws` method from inside a `throws` method required explicit `?` suffix on every call. Without `?`, Zig rejects the call with "error union is ignored". CodeGen had no mechanism to auto-emit `try` for callee methods. This was a self-hosting blocker for the Parser phase (which throws on every input).
- **Fix:** Added `current_method_throws: bool = false` to Generator, set in `genMethod` when the method signature or body requires error return. Two propagation paths:
  1. **Bare-name calls** (`ident` callee resolved via `resolve.exprs`): auto-emits `try ` prefix when `callee_throws && current_method_throws && !in_try_block && !suppress_auto_try`.
  2. **Self-method calls** (`.method()` syntax → callee is `member(this, "name")`): walks `owner_members` for the method by name; same guard conditions.
  3. **Cross-module calls** (`Mod.method()` callee): checks `imported_modules[mod].throws_methods`; same guards.
- **`suppress_auto_try` flag:** The `.try_` codegen path (Zebra `expr?`) already emits `try ` before calling `genExpr`. Without suppression, genCall would add a second `try`, producing `try try self.foo()`. `suppress_auto_try` is set via a `g2 = g; g2.suppress_auto_try = true` local copy before delegating.
- **`owner_members` field:** Added to Generator (set by `withClass` and `genStruct`). Enables `exprCallIsThrows` to detect `this.method()` calls that throw — needed so `genTryCatch` declares the tracking variable as `var` (not `const`) when the try body contains bare self-method calls.
- **Found by:** Self-hosting Phase 2 planning + throws_autoprop_test.zbr.
- **Re-verified 2026-04-17** (`/c/tmp/verify_bug024.zbr`): `Worker.outer` emits `return try self.inner(x);` — throws auto-propagation still wires up on both compilers.

---

### BUG-025: `scanMutationsInExpr` didn't recurse into `.try_` nodes — FIXED 2026-04-11
- **Status:** Fixed 2026-04-11
- **Was:** `scanMutationsInExpr` handled `.call`, `.binary`, `.member`, `.unary`, `.orelse_`, `.catch_`, `.tuple_lit`, `.type_check` — but not `.try_` (the Zebra `expr?` propagation node). When a variable's method was called via `localVar.method()?`, the `?` wraps the call in a `.try_` node. `scanMutationsInExpr` hit the `else => {}` branch and didn't recurse into the inner call expression, so the receiver `localVar` was never added to the `mutated` set. Result: the variable was emitted as `const`, and Zig rejected the mutable method call with "cast discards const qualifier".
- **Fix:** Added `.try_ => |e| try scanMutationsInExpr(e.expr, set, tc_opt)` to `scanMutationsInExpr`.
- **Found by:** `throws_nested_test.zbr` and `selfhost/ast_test.zbr` — using `localVar.method()?` inside a try block.
- **Re-verified 2026-04-17** (`/c/tmp/verify_bug025.zbr`): `var c = Counter.init()` emitted on both compilers where `c.inc()?` mutates.

### DESIGN-001: Throws auto-propagation scope — nested expression calls require `?`
- **Not a bug** — by design
- **Description:** Throws auto-propagation emits `try` for direct self-method calls (`.method()` syntax) and for statement-level calls whose receiver is detected as a `throws` method. It does NOT auto-propagate for:
  - `localVar.method()` — receiver is a local variable (TC type lookup not wired into auto-try)
  - `this.field.method()` — chained member access through a field
  - Calls nested inside compound expressions (as arguments, in binary ops, etc.)
- **Required action:** Use explicit `?` suffix for these cases: `localVar.method()?`, `this.field.method()?`
- **Rationale:** Expression-level `?` keeps error flow visible at the use site. Auto-propagation is most valuable for statement-level self-method calls (the dominant pattern in method bodies), where the `throws`-chain needs to flow upward without per-call boilerplate.
- **Documented by:** `test/throws_nested_test.zbr` — exercises both auto and explicit-? patterns.

---

### BUG-026: `instance_method_return_types` gaps for exposed-type method chains
- **Severity:** Medium
- **Status:** Open
- **Target:** Phase 7b / post-audit
- **Symptom:** When a variable holds an exposed cross-module struct (from `use Mod exposing TypeName`) and you call a method whose return type is itself a user-defined type, the TC fix added in Phase 7a (commit dcdf70fd) looks up the method in `ModuleInterface.instance_method_return_types`. If that map is not fully populated for a given method (e.g., a method returning another struct that isn't tracked), the TC still returns `.unknown` for the chained call result. This means `var b = a.someMethod()` may still produce `const b` in generated Zig if `someMethod` isn't in `instance_method_return_types`.
- **Root cause:** `instance_method_return_types` is populated by `buildModuleInterface` in `main.zig`. It only captures methods whose return type resolves to a `.named` symbol with a non-primitive type. Methods that return generic types, optionals, or cross-module types are not captured. The coverage is sufficient for Phase 7a's test suite but may be incomplete for deeper chains.
- **Reproduce:** Call `g.withOwner("Foo").indented()` where the intermediate `.withOwner` result is an exposed struct — test still fails because the chained intermediate is anonymous and not tracked.
- **Fix direction:** Populate `instance_method_return_types` more comprehensively in `buildModuleInterface`, including for methods that return the same type as the receiver (`-> Self`). Or convert `instance_method_return_types` to a map from method key to full `TypeRef` rather than just a string type name.
- **Found by:** Phase 7a review — "least confident about" from self-assessment.

---

### BUG-027: Method chaining on struct temporaries requires manual intermediate vars
- **Severity:** Low (ergonomic / language design)
- **Status:** Open — language limitation, not a compiler bug per se
- **Target:** Deferred (requires compiler or language change)
- **Symptom:** In Zebra, calling a method on the return value of another method — `g.indented().withOwner(n.name)` — fails if the intermediate result is a struct (value type). The compiler emits the intermediate as a `*const StructType` (temporary pointer), and the next method call which requires `self: *StructType` (mutable) rejects the const pointer. Users must manually break the chain:
  ```zebra
  var g0 = g.indented()
  var g1 = g0.withOwner(n.name)
  ```
- **Root cause:** Zig temporary value semantics: when a function returns a struct by value, the caller's stack slot is `const`. Zebra's generated code doesn't create a mutable local for intermediate results in method chains.
- **Impact:** Discovered repeatedly in `selfhost/codegen.zbr` where Generator context-forking methods are naturally chained. Every chain must be manually flattened.
- **Fix direction (option A):** When codegen detects a `.call` where the callee is itself a `.call` returning a struct type, emit an anonymous mutable local (`var _tmp = ...; _tmp.next()`) instead of chaining directly.
- **Fix direction (option B):** Language change — allow `let` chains in Zebra that make each step explicit but without requiring named vars (`g.indented() |g0| g0.withOwner(x)`).
- **Found by:** Phase 7a — "least proud of" from self-assessment.

---

### BUG-028: Zebra (Zig-backend) emits pointer addresses into identifier names
- **Severity:** Low (cosmetic; causes noisy diffs, not miscompiles)
- **Status:** Fixed 2026-04-17 (commit 8debe0a) — Generator now carries a monotonic `box_counter_ptr`; all 27 `@intFromPtr(node)`-based name sites route through `Generator.nextUid()`. Two back-to-back emits of `selfhost/codegen.zbr` now produce byte-identical output.
- **Target:** N/A
- **Symptom:** Generated `.zig` from the Zig-backed `zebra` compiler contains identifiers like `_box_2376b6287c0` and `_bp_2376b6287c0` where the hex suffix is a live pointer address from the compiler's own heap. Every run produces different names, so `zebra --emit-zig` output is non-deterministic and dirties the working tree on every invocation.
- **Impact:** `tools/bootstrap_check.sh` cannot restore to a zebra-emitted canonical form without leaving the tree diff-dirty on each run. The script instead leaves the tree in selfhost-emitted form, which *is* deterministic. Also inflates apparent diffs when reviewing compiler backend changes.
- **Note:** Selfhost's emit (codegen.zbr) does NOT exhibit this bug — A→B→B' is byte-identical. Only the Zig-side compiler has the issue.
- **Fix direction:** Replace address-based unique name generator with a monotonic counter seeded at 0 per compilation.
- **Found by:** Bootstrap round-trip stabilization, 2026-04-16.

---

### BUG-029: Class field init with non-int-valued HashMap defaults to i64
- **Severity:** Medium (blocks several TypeChecker port idioms until worked around)
- **Status:** Open
- **Target:** Phase 16c or Phase 17 — fix on Zig side, then port to selfhost
- **Symptom:** In a `cue init` body, `this.field = HashMap()` on a field declared `HashMap(str, T)` for non-int `T` emits `std.StringHashMap(i64).init(_allocator)`, producing a type mismatch. `this.field = HashMap(str, T)()` emits `HashMap([]const u8, T).init()` (not valid Zig). Only bare `field = HashMap()` (implicit self) works.
- **Root cause:** `src/CodeGen.zig::genAssign` generic-RHS field-type resolver (lines ~6901–6923) accepts only target `.ident` or `.member` with `.ident{name="self"}`. Zebra's `this.` parses as `.member` with `.object.* == .this` (a distinct AST variant), so the resolver bails out and falls through to the untyped default `std.StringHashMap(i64).init(_allocator)`.
- **Workaround:** Use implicit-self form (`field_types = HashMap()`) in class cue/init bodies for non-int-valued HashMap fields. Example in selfhost/typechecker.zbr.
- **Fix direction:** Add a `.this` object case alongside the `"self"` ident case in the switch at line 6909–6916.
- **Found by:** Phase 16a TypeChecker port, 2026-04-16.

---

### BUG-030: `.contains()` on param-of-class HashMap field emits List.contains
- **Severity:** Medium (blocks natural idiom for InferCtx-style types in TypeChecker port)
- **Status:** Open
- **Target:** Phase 17 — fix on Zig side, then port to selfhost
- **Symptom:** `param.field.contains(key)` where `param` is typed as a class and `field` is declared `HashMap(K, V)` generates `std.mem.indexOfScalar(@TypeOf(param.field.items[0]), param.field.items, key)` (the List/array `in` idiom) instead of calling `param.field.contains(key)`. The same expression on `this.field.contains()` works correctly. Compile-time failure: HashMap has no field `items`.
- **Reproducer:** In selfhost/typechecker.zbr Phase 16b, `ctx.scope.contains(nm)` where `ctx as InferCtx` and `scope as HashMap(str, Type_)`. Identical method body through a `this.` receiver compiled fine in ClassTypes/ModuleTypes.
- **Root cause (suspected):** `src/CodeGen.zig::genCall` dispatch for `.contains` on a member-access target looks only at the direct field or bare-ident type; when the leftmost receiver is a parameter of a user class, the HashMap-vs-List discriminator falls through to the List code path.
- **Workaround:** Add a wrapper method on the containing class (e.g. `def hasLocal(name) as bool; return scope.contains(name)`) and call that. Used in selfhost/typechecker.zbr Phase 16b (`InferCtx.hasLocal`/`localType`).
- **Found by:** Phase 16b TypeChecker port, 2026-04-16.

---

### BUG-031: Selfhost `except` codegen emits `.*` on value-typed subject — FIXED
- **Severity:** Medium (silent divergence between Zig-compiled compiler and selfhost; only surfaces at level-2 bootstrap)
- **Status:** Fixed 2026-04-17
- **Target:** Phase 17 — fix on Zig side (selfhost codegen), then round-trip
- **Fix:** `selfhost/codegen.zbr` gen path for `Expr.except_` now emits `.*` only when the base is `Expr.this_` and we are in a method body (where `this` lowers to `self: *Owner` — `genMethod` always uses pointer receivers for both class and struct owners). Value-typed locals (`local except {...}`) no longer get a spurious deref. Bootstrap round-trip byte-identical; corpus sweep 114/61 unchanged vs baseline (173/173 byte-identical).
- **Re-verified 2026-04-17** (`/c/tmp/verify_bug031.zbr`): Both compilers emit `_except_tmp = p;` (no `.*`) for a value-typed local `p` passed to `except`.
- **Symptom:** `x except { f = v }` where `x` is a local value (not a pointer) compiles fine on the Zig-compiled Zebra compiler but fails on selfhost-emitted Zig with `error: cannot dereference non-pointer type 'T'`. The selfhost codegen unconditionally emits `var _except_tmp = x.*;` for the `except` subject; `.*` is only legal when the subject is a pointer.
- **Reproducer:** Phase 16c plumbing attempt in `selfhost/codegen.zbr::generateModuleWith`:
  ```
  var g = Generator(...)          # g is a value-typed local
  g = g except
      module_types = buildModuleTypes(m)
      dep_types = deps_mt
  ```
  Zig-compiled compiler emitted valid code in bootstrap step 1; selfhost-A's step-3 re-emit produced `g = blk: { var _except_tmp = g.*; ... }` which failed at step 4 build with `selfhost/codegen.zig:2423:35: error: cannot dereference non-pointer type 'codegen.Generator'`.
- **Why the Zig-compiled compiler is correct:** existing uses of `except` in codegen.zbr are all on `this` inside methods where `this` is lowered to `self: *Generator` (pointer), so `self.*` is valid. Value-typed subjects require `_except_tmp = x;` (no deref).
- **Root cause (suspected):** `src/CodeGen.zig`'s `except` lowering assumes the subject is pointer-shaped; selfhost's port of the same logic inherited the assumption but lacks the pointer-vs-value discrimination the Zig backend does upstream.
- **Workaround:** Avoid `except` on value-typed locals — use init params or mutable `var` field assignment. Phase 16c plumbing switched to init params instead.
- **Found by:** Phase 16c plumbing, 2026-04-16.

---

### BUG-032: Selfhost codegen.zbr emits `.remove` unconditionally as `.orderedRemove` (List form)
- **Severity:** Medium (silently corrupts HashMap mutation in every selfhost-emitted program)
- **Status:** Fixed 2026-04-17 (commit ff87add) — `.remove` dispatch now discriminates HashMap vs List receiver via new `hashmap_locals` + `fieldIsHashMap` infrastructure in typechecker.zbr/codegen.zbr. HashMap emits `_ = obj.remove(key)`; List keeps `_ = obj.orderedRemove(@intCast(idx))`.
- **Target:** Phase 17f+ (after Zig-side sprint items).  Pairs with BUG-030.
- **Symptom:** In `selfhost/codegen.zbr::genMemberCall` around line 3745, `if mname == "remove"` unconditionally emits `_ = obj.orderedRemove(@intCast(key))` regardless of whether the receiver is a `List` or `HashMap`.  HashMaps don't have `orderedRemove`; they have `.remove(key)` which returns `bool`.
- **Evidence:** `selfhost/typechecker.zbr::InferCtx.unbind` (lines 388-394) has a workaround comment: "selfhost mis-emits HashMap.remove as orderedRemove. Until that bug is fixed, 'unbind' by rebinding to Type_.unknown_."  The workaround means any future HashMap-holding class in selfhost has to remember to avoid `.remove`.
- **Zig-side:** Already correct — `src/CodeGen.zig::genStdlibMethod` at line 4636 dispatches via TC type (`tr.generic.name == "HashMap"` → `genHashMapMethod` → emits `.remove(key)` at line 6317-6324).
- **Fix direction (selfhost-only):** Introduce `hashmap_locals: StrSet` + `fieldIsHashMap(module_types, dep_types, name)` parallel to the existing `strset_locals` / `fieldIsStrSet` infrastructure.  In `.remove` dispatch, check if the receiver is a HashMap — if so, emit `_ = obj.remove(key)`; otherwise fall through to `.orderedRemove`.  Also consider extending `.contains` dispatch for symmetric coverage (see BUG-030).
- **Risk:** Selfhost-side edit — must go through bootstrap round-trip verification.  Group with BUG-030 and BUG-031 in a single selfhost-edit commit.
- **Found by:** Phase 17.5 stability-sprint triage, 2026-04-17.

---

### BUG-033: Selfhost `.contains()` on class-field HashMap emits `List.contains` form — NOT REPRODUCED
- **Severity:** N/A
- **Status:** Not Reproduced 2026-04-17
- **Investigation:** Built reproducer `/tmp/bug033_verify.zbr` with `class Reg` holding `HashMap(str,int)` field, called via `self.by_name.contains(k)`.  Selfhost emits CORRECTLY:
  ```zig
  pub fn contains_key(self: *Reg, k: []const u8) bool {
      return self.by_name.contains(k);
  }
  ```
  i.e. the HashMap `.contains` path — NOT the List form as originally filed. BUG-032's walker work (field_hashmap_sites) evidently already covers this receiver shape, or it never mis-emitted for this shape to begin with.
- **Replaced by:** BUG-036 (below) — investigating the above reproducer surfaced a *different* HashMap-field bug around `[key]` subscript emit.
- **Found by:** Phase 17.5 stability-sprint triage (deferred from BUG-030), 2026-04-17.  Closed by same-day re-verification.

---

### BUG-034: Selfhost emits cross-module union construction as struct call (hard-coded `isUnionLikeName` allow-list)
- **Severity:** High (blocks running any selfhost-emitted module whose union types aren't in the hard-coded list — `typechecker_test.zbr` currently only runs through `zebra.exe`, not the selfhost binary).
- **Status:** Fixed 2026-04-17 (commit ff87add) — `generateModuleWith` now consults `deps_mt.hasUnion(exposed_name)` before the hard-coded heuristics.  The allow-list stays as a fallback for the single-file emit path where `deps_mt` is empty.
- **Target:** Phase 17f or with BUG-030/031/032/033 selfhost-edit wave.
- **Symptom:** `UnionName.variant(value)` on a **cross-module** union emits `UnionName.init(value)` (or `UnionName{}` struct call) instead of `UnionName{ .variant = value }`.  Example: in `typechecker_test.zbr`, `Type_.named("Bar")` falls through to the "Class/struct constructor" branch at `selfhost/codegen.zbr:3598` because `Type_` isn't recognised as a union.
- **Root cause:** `selfhost/codegen.zbr::isUnionLikeName` (lines 409-417) is a hard-coded allow-list of 8 names (`PNode`, `PParam`, `Decl`, `TypeRef`, `Stmt`, `Expr`, `StringPart`, `LambdaBody`).  `Type_`, `ClassTypes`, `ModuleTypes`, `CrossModuleType`, etc. are absent, so `generateModuleWith` at line 695-701 classifies them as struct/class names.  Then `genCall` at line 3520-3558 misses the union-construction path because `union_names.contains_(oname)` is false.
- **Zig-side:** Not applicable — the Zig backend discriminates via TC types, not name heuristics.
- **Fix direction (selfhost-only):** Replace `isUnionLikeName` + `isEnumLikeName` name heuristics with `deps_mt.hasUnion(exposed_name)` / `deps_mt.hasEnum(exposed_name)` lookups — the infrastructure already exists (used by `isUnionType` at line 1076-1080).  Fallback to the hard-coded list only when `deps_mt` doesn't know the name (single-file emit paths).  Consider adding `hasEnum` to `ModuleTypes` if it's missing.
- **Risk:** Selfhost-side edit — must go through round-trip + bootstrap_check.  Part of the selfhost-edit wave (BUG-030/031/032/033).
- **Found by:** Phase 17.5 stability-sprint investigation, 2026-04-17.  Evidence: Phase 17d memory note that `typechecker_test.zbr` runs only via `zebra.exe`.

---

### BUG-035: Selfhost parser has no atom handler for `doc_string_line` (`"""..."""` multi-line strings)
- **Severity:** High (blocks any `.zbr` using `"""..."""` from compiling under selfhost; affects `test/selfhost_probe6.zbr` + potentially more corpus files)
- **Status:** Open
- **Target:** Phase 17e or 17f (selfhost-edit wave).
- **Symptom:** A `.zbr` containing `"""..."""` multi-line string literals fails under selfhost with the generic `zebra: selfhost pipeline error:` (empty message — the parser raises without detail). The Zig-compiled compiler (`zebra.exe`) accepts the same file without issue.
- **Reproducer (minimal):**
  ```
  class Main
      shared
          def main
              var s = """
  hello
  """
              print s
  ```
  `zebra-selfhost.exe --emit-zig` raises empty-message pipeline error at parsing; `zebra.exe --emit-zig` emits valid Zig.
- **Root cause:** `selfhost/Lexer.zbr::scanDocString` (line 421) correctly emits `TokenKind.doc_string_line` for `"""..."""` content, but `selfhost/parser.zbr` has **no atom case** that builds an expression from it — `grep doc_string parser.zbr` returns no matches. Any expression position containing a `doc_string_line` token falls through and the parser raises without a message.
- **Zig-side reference:** `src/AstBuilder.zig:2044` — `doc_string_line => .{ .string_lit = .{ .span = s, .kind = .plain, .text = text } }`. The selfhost `astbuilder.zbr`/`parser.zbr` need the equivalent atom handler.
- **Fix direction (selfhost-only):** Add a `doc_string_line` case to the atom-building path in `selfhost/parser.zbr` (or wherever string-lit atoms are produced) that wraps the token text in `Expr.string_lit` with `kind = plain`. Same shape as existing `string_lit` handling.
- **Extra:** The generic "selfhost pipeline error: " with empty `e.message` is itself a diagnostics gap — BUG candidate or merge into Phase 20 diagnostics. Leaving a breadcrumb here rather than filing separately.
- **Risk:** Selfhost-side parser edit — bootstrap_check + corpus sweep required. May unlock additional corpus files beyond probe6.
- **Found by:** probe6/probe7 triage (item #2 from Sean's 2026-04-17 nag list).

---

### BUG-036: Selfhost HashMap field `[key]` subscript emits array-index with bogus `@intCast`
- **Severity:** High (any class-field HashMap read/write via `[k]` syntax emits code Zig rejects)
- **Status:** Open
- **Target:** Phase 17f selfhost-edit wave (pair with remaining HashMap walker work).
- **Symptom:** For `this.field[k] = v` (assign) or `this.field[k]` (read) where `this.field` is typed `HashMap(K,V)`, selfhost emits:
  ```zig
  self.by_name[@as(usize, @intCast(k))] = n;           // assign
  return self.by_name[@as(usize, @intCast(k))];         // read
  ```
  Zig rejects with `error: expected integer or vector, found '[]const u8'`.  The codegen treats the HashMap field as a List (array-indexing with `usize` cast) rather than lowering to `.put(k,v)` / `.get(k).?`.
- **Reproducer:** `/tmp/bug033_verify.zbr`:
  ```
  class Reg
      var by_name as HashMap(str, int)
      cue init()
          this.by_name = HashMap()
      def insert_(k as str, n as int)
          this.by_name[k] = n
      def peek(k as str) as int
          return this.by_name[k]
  ```
  `zebra-selfhost.exe --emit-zig` produces broken Zig; `zebra.exe --emit-zig` also emits `self.by_name[k] = n;` (without the cast) — itself also broken but is a separate Zig-backend issue tracked informally.  The *selfhost-specific* bug here is the spurious `@intCast` wrap.
- **Zig-side reference:** Zig backend's subscript lowering for HashMap receivers routes through `genHashMapSubscript` (approx) and emits `.put`/`.get`.  Selfhost lacks this branch — the subscript path always emits `base[@as(usize, @intCast(idx))]` regardless of receiver type.
- **Fix direction (selfhost-only):** In `selfhost/codegen.zbr`, the subscript emit paths (`genExpr` for `Expr.index_` and `genAssign` for indexed LHS) should consult the walker's `fieldIsHashMap` / `hashmap_locals` / `inferExpr` to detect HashMap receivers and emit `.put(k,v)` / `.get(k).?` instead of `base[@as(usize, @intCast(k))]`.  Also suppress the `@intCast` wrap when the index type isn't integer-coercible (defence-in-depth — a string index should never be cast to `usize`).
- **Risk:** Selfhost-side edit — round-trip + bootstrap_check + corpus sweep required.  Subscript path is hot; regress potential is non-trivial.  Group with BUG-032 successor wave.
- **Found by:** BUG-033 re-verification, 2026-04-17.

---

### BUG-037: Selfhost corpus-failure triage (57/160 .zbr files fail under selfhost)
- **Severity:** High (headline self-hosting gap; every failure is a selfhost-emit gap — the Zig-compiled compiler parses and emits valid-looking Zig for all 57, though downstream `zig build` parity across the 57 has not been audited)
- **Status:** Open — meta-ticket for the Phase 17e/17f selfhost-edit wave
- **Target:** Phase 17e (grammar features) and 17f (diagnostics)

**Sweep methodology** (reproducible, 2026-04-17):
- `./zig-out/bin/zebra-selfhost.exe --emit-zig $file` over every `.zbr` in `test/` and `selfhost/*_test.zbr` (160 files total).
- Fail-signal: stdout line matching `/^zebra:|pipeline error|^panic:|^error:|thread \d+ panic/`.
- Cross-oracle: every selfhost-fail file is passed to `./zig-out/bin/zebra.exe --emit-zig` — **all 57 fails succeed under the Zig compiler**.  None of the failures are due to test authoring error or intentional broken-tests.
- Phase gate on failure (from `printf`/`print` tracing in log): **all 47 silent-message fails die during the parser phase** (last log line is `parsing...`, never `parsed OK`).  That's the strongest single signal in the triage.

**Failure buckets** (57 total; feature tags are the construct the file exercises that the Zig compiler parses but selfhost does not):

| Count | Bucket | Representative files | Fix target |
|------:|--------|----------------------|------------|
|    47 | Parser-only gap, silent message | see below | Phase 17e grammar wave + diagnostics gap in Phase 20 |
|     8 | `undefined name: 'TcScopeKind'` | `selfhost/typechecker_test.zbr` self-reference chain | Pair with BUG-034 follow-up / cross-module resolver work |
|     1 | `undefined name: 'Dir'` | `test/directory_test.zbr` | Stdlib gap — add `Dir` to selfhost stdlib variant set (Phase 19) |
|     1 | `undefined name: 'Calendar'` | `test/datetime_test.zbr` | Stdlib gap — selfhost's datetime stdlib doesn't expose `Calendar` |

**47 parser-gap fails — feature-marker subtotals** (many files hit multiple markers; subtotals overlap):

| Construct | Count | Example file | Notes |
|-----------|------:|--------------|-------|
| `with` contextual-self block | 10 | `test/with_test.zbr` | `with p\n    x = 10` — selfhost parser never learned the `with` atom |
| `raise "msg", detail` with payload | 6 | `test/raise_auto.zbr` | Selfhost parser only handles single-operand `raise` |
| `lambda` expression | 4 | `test/pipeline.zbr`, `test/features.zbr`, `test/result_methods_test.zbr` | Phase 17e scope |
| `zig"..."` inline literal (expression form) | 3 | `test/greet.zbr` | Selfhost parser has no expression-level `zig"..."` atom; stmt form works (BUG-006 fixed it) |
| `orelse` keyword | 2 | `test/nilable_test.zbr` | Parser gap — op-precedence table missing `orelse` |
| `guard cond else, body` | 2 | `test/guard_test.zbr` | Statement-form guard missing in selfhost parser |
| `trailing ?` for optional-unwrap try | 2 | `test/guard_test.zbr` | Postfix `?` as try sugar not wired up |
| `(int, int)` tuple type annotation | 2 | `test/tuple_test.zbr` | Tuple types absent from selfhost type parser |
| `p.0` `p.1` tuple-index member access | 1 | `test/tuple_test.zbr` | Goes with tuple-type work |
| `"""..."""` multi-line doc strings | 2 | `test/csv_test.zbr`, `test/selfhost_probe6.zbr` | Tracked in BUG-035 (parser atom case missing for `doc_string_line` token) |
| `except` block as expression | 2 | `test/tc_check.zbr` | Partial support; may be resolver-level not parser |
| `arena` scope block | 1 | `test/arena_scope_test.zbr` | Atom/statement case missing |
| `extend` declaration | 1 | `test/extend_test.zbr` | Phase 17e |

**Additional constructs surfaced via secondary inspection (not caught by regex buckets above):**
- Range syntax `for i in 0 : n` (`test/bench_zebra.zbr`)
- Top-level `union Shape` with payload variants (`test/branch_exhaustive_test.zbr`)
- Computed properties `get area as float\n    return ...` (`test/computed_property_test.zbr`)
- Top-level `enum` (`test/enum_branch_test.zbr`)
- Top-level `interface ... implements` (`test/interface_test.zbr`)
- Constrained generics `class MinHeap(T where T implements Comparable)` (`test/generic_constrained_test.zbr`)
- Top-level `namespace` (`test/namespace_main.zbr`)
- `shared var` field declaration (`test/shared_field.zbr`)
- `while var c = …, cond` with iterator binding (`test/while_var_test.zbr`)
- `c'a'` char-literal token (`test/while_var_test.zbr`)
- `same` type (recursive self-type in interface method) (`test/generic_constrained_test.zbr`)

**Generic diagnostics gap (surfaced in 47/47 silent fails):**
~~Every parser-level failure prints `zebra: selfhost pipeline error: ` with an **empty message** (the parser raises without setting `e.message`).~~ **FIXED by Phase 20a (commits 9e83d49 + 8b59606, 2026-04-17).** Root cause was not unset raise sites — all parser raise sites did set messages — but cross-module `_error_ctx` isolation: each `.zig` file had a private threadlocal `_error_ctx`; the root module's catch only saw main's own (empty) context, never the dep module (Parser/Lexer) that actually raised. Fix: recursive `_zbr_error_msg()` helper that walks every transitive module, applied to both the Zig backend (`src/CodeGen.zig`) and the selfhost codegen (`selfhost/codegen.zbr`). Post-fix corpus re-triage: **SILENT=0** — all 57 failures now report specific messages (e.g. `unexpected expression token: 'zig"Greeter{}"' at line 8`), cleanly mapping to the feature buckets below.

**Action items (derived from triage):**
- **Phase 17e grammar wave:** with, raise-details, lambda, zig"..." expr, orelse, guard stmt, trailing `?`, tuples, arena, extend, range `:`, top-level union/enum/interface/namespace, computed properties, constrained generics `T where`, `shared var`, `while var`, `c'…'`, `same` type.  Closes ~50 of 57 failures.
- **Phase 19 stdlib:** `Dir`, `Calendar` variant set (2 fails).
- **Phase 20 diagnostics:** empty-message parser raises (affects all 47 silent fails).
- **Cross-module resolver:** `TcScopeKind` undefined name cluster (8 fails) — investigate whether this is a BUG-034 follow-on (`deps_mt.hasEnum`) or a separate resolver/union-expose pathway.  Not yet root-caused.

- **Risk:** This inventory is a planning instrument, not a fix.  Addressing individual buckets requires the standard sprint gate (bootstrap_check + tc tests + corpus diff per commit).  Do not bundle buckets in one commit.
- **Found by:** Phase 17.5 stability-sprint task #40 corpus triage, 2026-04-17.  Inventory scripts live in `/tmp/sweep_triage3.sh` and `/tmp/cross_oracle.sh` for re-running.

---

### BUG-038: Selfhost emits `int.toString()` as codepoint-to-UTF8 encode, not integer-to-decimal

- **Severity:** Medium (produces truncated/garbage output for any line-number / integer embedded in error messages emitted by selfhost-B; selfhost-A is unaffected because Zig backend emits `std.fmt.allocPrint` correctly)
- **Status:** Open — discovered during Phase 20a investigation (2026-04-17)
- **Target:** selfhost-edit wave (same as BUG-036)

**Symptom:** In selfhost-emitted `.zig` files, `int.toString()` expands to

```zig
(blk: { var _cpbuf: [4]u8 = undefined;
        const _cplen = std.unicode.utf8Encode(@intCast(self.peek().line), &_cpbuf) catch 1;
        break :blk _allocator.dupe(u8, _cpbuf[0.._cplen]) catch @panic("OOM"); })
```

That is `std.unicode.utf8Encode` — encode-a-codepoint-as-UTF-8, not integer-to-string. For line 1 it returns byte `\x01`; for line ≥ 128 it returns multi-byte non-printable garbage; for line ≥ 0x110000 it `catch 1`s back to the first byte of `undefined`.

**Cross-oracle:** Zig backend emits the correct form:
```zig
std.fmt.allocPrint(_allocator, "{}", .{self.peek().line}) catch unreachable
```
The selfhost codegen path diverges.

**Root cause direction:** `selfhost/codegen.zbr` has a branch for `.toString()` on `int` receivers that wires to a codepoint emitter rather than `std.fmt.allocPrint`. Likely a copy-paste from the `int.toChar()` / `int` → `char` codepoint path during Phase 7b. Two known call sites in `parser.zbr` raise messages use `line.toString()`; the corruption was masked for the 47 silent fails because the WHOLE message was swallowed by BUG-037 — once BUG-037 was fixed by Phase 20a, the int→garbage truncation became visible.

**Impact:** Every selfhost-emitted program that calls `int.toString()` produces wrong output — most visibly parser error line numbers, but also any user program that formats an int.

- **Found by:** Phase 20a verification, 2026-04-17 — observed `" at line "` with truncated/empty tail in selfhost-B output even though selfhost-A shows correct decimal line numbers.

---

### BUG-039: Selfhost mutation scanner marks string-method receiver as `var`
- **Severity:** Medium (every selfhost-emitted program that calls a string method rejects under Zig 0.15 ReleaseSafe)
- **Status:** Open — found 2026-04-17 by task #48 Batch 2 re-verification of BUG-008
- **Target:** selfhost-edit wave
- **Symptom:** `var greeting = "hello"; print greeting.reverse()` — Zig backend emits `const greeting`, selfhost emits `var greeting`. Zig 0.15 rejects: "local variable is never mutated". BUG-008 fixed this on the Zig side (the `.unknown` → conservative-mutate path was removed); selfhost's mutation scanner never received the same fix.
- **Reproducer:** `C:\tmp\verify_bug008.zbr`
- **Cross-oracle:** `zebra.exe` builds + runs → `olleh`; `zebra-selfhost.exe` emits unbuildable Zig.
- **Likely fix site:** `selfhost/codegen.zbr` mutation-scan phase — mirror Zig-side BUG-008 fix (unknown types fall through to allow-list; strings always immutable).

---

### BUG-040: Selfhost `print` emits `{}` instead of `{s}` for strings
- **Severity:** Medium (every selfhost-emitted `print` of a string fails Zig 0.15 type check)
- **Status:** Open — found 2026-04-17 by task #48 Batch 2 re-verification of BUG-008
- **Target:** selfhost-edit wave
- **Symptom:** `print someString` — selfhost emits `std.debug.print("{}\n", .{ someString })`; Zig 0.15 rejects `[]const u8` under `{}` (needs `{s}`). Zig backend emits `{s}` correctly.
- **Reproducer:** `C:\tmp\verify_bug008.zbr`
- **Likely fix site:** `selfhost/codegen.zbr::genPrint` — check expression TC type; use `{s}` for `string`/`str_slice`, `{}` otherwise.

---

### BUG-041: `^ClassType?` emits `?**T` instead of `?*T` (root cause) — FIXED
- **Severity:** High (blocks all uses of optional heap-pointer class fields; downstream causes invalid `.*` field-assignment emit)
- **Status:** **Fixed 2026-04-17**
- **Fix:** `src/CodeGen.zig::genType .ref_to` arm (and selfhost `selfhost/codegen.zbr` mirror): when `^T`'s inner payload is a class (bare or dotted `Mod.Type`, optionally nilable-wrapped), emit `*ClassName` / `?*ClassName` directly and skip the recursive `genType` call. The recursion would re-enter `.named` which auto-adds `*` for class types, stacking a second pointer layer and producing `**T` / `?**T`. For classes, `^T` is a representation no-op — the auto-box already provides the pointer.
- **Verified:** `verify_bug044.zbr` emits `?*Node` (was `?**Node`); `verify_bug016c.zbr` emits `?*Node` return type, builds and runs printing `42`; `verify_ref_struct.zbr` regression canary still emits `*Point` (single `*`, non-class no-op unchanged); `verify_selfref.zbr` self-ref field still emits `?*Node`; `tools/bootstrap_check.sh` PASS.
- **Target:** 0.5
- **Symptom (representation):** `var x as ^Node?` in a local OR a method return emits Zig type `?**Node` (optional-of-pointer-to-pointer) instead of `?*Node` (optional-pointer). Class auto-boxing already adds one `*`; the `^` operator is adding a second `*` on top of the already-boxed class representation for `^ClassType?`, though `^ClassType` alone emits `*T` correctly. Appears to be a type-formatting layering bug specific to `^` + class + `?` combination.
- **Discriminator probe** (`verify_bug044.zbr`, 2026-04-17): Local `var x as ^Node?` emits `var x: ?**Node = undefined;` — same wrong form as return-position. Rules out "return-position-specific" hypothesis; confirms shared root cause.
- **Downstream symptom (field assignment):** On `^Node?` class fields, `b.next = c` emits `b.next.* = _rp` which Zig 0.15 rejects as `.*` on optional pointer requires `.?` first. Likely cascades from the `?**T` representation — the boxing path writes through the outer `*` expecting `?*T` but gets `?**T`.
- **Reproducers:**
  - `C:\tmp\verify_bug044.zbr` — minimal local-var form showing `?**Node`.
  - `C:\tmp\verify_bug016c.zbr` — return-type `^Node?` emits `?**Node` signature.
  - `C:\tmp\verify_bug016.zbr` — field-assignment `.*` downstream symptom.
- **Likely fix site:** `src/CodeGen.zig` type-formatting for `^T?` when `T` is a class. Check `typeRefToZig` / equivalent — suspect a path that double-applies the class pointer wrapper when the type carries both `^` and `?`.
- **Relation to BUG-016:** BUG-041 blocks all three attempted BUG-016 re-probes; re-verification of BUG-016's original member-through-optional path is unverified until BUG-041 is fixed.

---

### BUG-042: Selfhost cross-module struct ctor missing `.init`
- **Severity:** Medium (every cross-module class/struct construction `Mod.Type(args)` emits as unbuildable fn-call)
- **Status:** Open — found 2026-04-17 by task #48 Batch 2 re-verification of BUG-022
- **Target:** selfhost-edit wave
- **Symptom:** `var p = bug022_lib.Payload(42)` emits as `const pay = bug022_lib.Payload(42);`. Expected `bug022_lib.Payload.init(42);` (matching Zig backend).
- **Reproducer:** `C:\tmp\bug022_main.zbr` + `C:\tmp\bug022_lib.zbr`.
- **Likely fix site:** `selfhost/codegen.zbr` call-emit path — detect `Mod.Type(...)` callee as a cross-module struct/class constructor via `deps_mt` and append `.init`. Unqualified `Type(args)` emit already handles this.

---

### BUG-043: Selfhost `Mod.Union.variant(v)` emits fn-call not struct-init
- **Severity:** Medium (every cross-module tagged-union construction emits unbuildable)
- **Status:** Open — found 2026-04-17 by task #48 Batch 2 re-verification of BUG-022
- **Target:** selfhost-edit wave (likely same fix as BUG-042 + BUG-044)
- **Symptom:** `var v = bug022_lib.Value.data(pay)` emits as `const v = bug022_lib.Value.data(pay);` (fn-call form). Expected `bug022_lib.Value{ .data = <boxed pay> };` (struct-init with boxing per LANG-003).
- **Reproducer:** `C:\tmp\bug022_main.zbr` + `C:\tmp\bug022_lib.zbr`.
- **Likely fix site:** `selfhost/codegen.zbr` call-emit path — detect `Mod.UnionName.variant(...)` via `deps_mt.hasUnion` (BUG-034 fix) and route to struct-init with `boxed_variants` boxing. Unqualified `UnionName.variant(...)` path already handles this (post-BUG-034).

---

### BUG-044: Selfhost cross-module branch pattern collapses variant tag to union type name
- **Severity:** Medium (every cross-module `branch v on Mod.Union.variant` emits duplicate wrong-tag switch arms)
- **Status:** Open — found 2026-04-17 by task #48 Batch 2 re-verification of BUG-022
- **Target:** selfhost-edit wave (likely same fix as BUG-042 + BUG-043)
- **Symptom:** `branch v on bug022_lib.Value.empty ... on bug022_lib.Value.data as p ...` emits:
  ```zig
  switch (v) {
      .Value => |_| { ... }   // should be .empty
      .Value => |p| { ... }   // should be .data
  }
  ```
  Both arms collapse to `.Value` (the union type name). Zig rejects duplicate arms.
- **Reproducer:** `C:\tmp\bug022_main.zbr` + `C:\tmp\bug022_lib.zbr`.
- **Likely fix site:** `selfhost/codegen.zbr` branch-pattern emit path — cross-module `Mod.Union.variant` is being read as `Mod.Union` with `variant` dropped. Check the dotted-name splitter used by branch patterns vs the one used by construction sites.
- **Cross-oracle:** Zig backend emits `.empty` / `.data` correctly.

---

### BUG-045: Ctor-arg boxing wraps `^Class?` args in extra `*` (stale after BUG-041 fix) — FIXED
- **Severity:** Medium (blocks any ctor call that passes a `^Class?` value — linked list / tree construction idioms)
- **Status:** Fixed 2026-04-17 (`a5e082b`) — Zig backend only; selfhost was already correct via Phase 17c walker.
- **Target:** 0.5 (follow-up to BUG-041)
- **Fix:** `genBoxedArgExpr` in `src/CodeGen.zig` short-circuits when the payload is a class (local via `class_names` OR cross-module via `imported_modules`) and falls through to plain `genArgExpr`. The selfhost side (`selfhost/codegen.zbr` lines ~3719-3736) already had this behaviour: Phase 17c replaced the `shouldBoxCtorArg` heuristic with an `inferExpr(arg)` + `isUnionType` walker, which correctly identifies class args as non-union so they were never wrapped in `_bx` blocks. The Zig-side fix brings it up to parity.
- **Verified:** `test/ctor_arg_ref_test.zbr` (promoted probe) — `Node(3, nil) / Node(2, c) / Node(1, b)` emit as plain `Node.init(3, null) / Node.init(2, c) / Node.init(1, b)` via both backends.
- **Symptom:** For `cue init(..., nxt as ^Node?)`, a call `Node(3, nil)` or `Node(2, c)` emits:
  ```zig
  Node.init(3, _box_1: { const _bp_1 = _allocator.create(?*Node) catch @panic("OOM"); _bp_1.* = null; break :_box_1 _bp_1; })
  ```
  The labeled-block yields `*?*Node`, but the param type is now `?*Node` (post BUG-041) — one pointer layer too many. Zig rejects with "pointer type child '?*Node' cannot cast into pointer type child 'Node'".
- **Root cause:** `src/CodeGen.zig::genArgs` (line ~8869) unconditionally boxes args whose param type is `.ref_to`. Before BUG-041, `^Class?` was `?**T` and the boxing matched; after the fix, `^Class` and `^Class?` collapse to `*T` / `?*T` (no extra indirection), so the boxing should be skipped when the payload is a class.
- **Reproducer:** `C:\tmp\verify_bug016b.zbr` (constructor-based linked list with `^Node?` param).
- **Likely fix:** in `genArgs` (and selfhost `selfhost/codegen.zbr` mirror), when `ps[i].type_` is `.ref_to` and the inner (directly, or through `.nilable`) is a class type, pass the arg directly via `genArgExpr` instead of routing to `genBoxedArgExpr`.
- **Relation to BUG-041:** Same conceptual root ("`^Class` is representation no-op"), different codegen path (call-site arg materialization vs type emission). Filed separately to keep the BUG-041 commit diagnosable.

---

### BUG-046: Selfhost does not discover or merge partial-class sibling files — OPEN
- **Severity:** Medium (selfhost-only parity gap; members added in `<stem>.*.zbr` partials are silently dropped)
- **Status:** Open — filed 2026-04-17 during BUG-010 deeper probe
- **Target:** 0.5 (ride with the selfhost-edit wave)
- **Symptom:** Given `Foo.zbr` (root) and `Foo.ext.zbr` (partial) in the same directory, selfhost compiles only the root. No warning, no error, no discovery. The partial's declarations never reach the AST.
- **Evidence:** `grep -rn partial selfhost/` returns one hit (an unrelated comment in `typechecker.zbr`). No `mergePartials`, no `mergePartialInto`. The Zig backend in `src/main.zig` lines ~184–427 implements the feature; selfhost's `main.zbr` does not call any equivalent.
- **For BUG-010's duplicate-method scenario, both compilers happen to yield "root" output** — but for different reasons (Zig: discovers + dedups + skips; selfhost: never discovered). A partial adding non-conflicting members would diverge visibly.
- **Reproducer:** `C:\tmp\bug010\Greeter.zbr` + `Greeter.ext.zbr` with the partial's method renamed (so it is additive, not a duplicate) — selfhost output omits it; Zig backend includes it.
- **Likely fix:** port the `mergePartials` + `mergePartialInto` routine from `src/main.zig` into `selfhost/main.zbr`, invoked between parse and resolve. Needs directory listing, path-stem matching, per-partial tokenize/parse/build, and duplicate-method dedup mirroring the Zig side.

---

### BUG-047: Field-read + field-assign on `^Class?` emitted stale boxing after BUG-041 fix — FIXED
- **Severity:** Medium (blocked read access to `^Class?` fields via a local copy — `var mid = a.next` style — and also turned out to block `b.next = c` writes; both symptoms shared the same root cause)
- **Status:** Fixed 2026-04-17
- **Target:** 0.5 (same wave as BUG-045; closes the class-auto-box-rule's codegen paths)
- **Symptom (read):** Given `class Node { var next as ^Node? }`, `var mid = a.next` emitted `const mid = a.next.*;` — a dereference that was correct when `.next` had type `?**Node` (pre BUG-041) and is one too many now that `.next` is `?*Node`. Zig rejected: *"cannot dereference non-pointer type `?*Node`"*.
- **Symptom (write, discovered while validating the read fix):** `b.next = c` emitted the self-ref heap-box pattern `{ const _rp = _allocator.create(Node); _rp.* = c; b.next = _rp; }` — `c` is already `*Node` via class auto-box, so `_rp.* = c` assigned `*Node` to a `Node` slot. Same BUG-041 staleness, different codegen site.
- **Reproducer:** `test/recursive_type_test.zbr` (write path via `b.next = c`), `C:\tmp\verify_bug016b.zbr` (read path via `var mid = a.next`), and `test/ctor_arg_ref_test.zbr` (adjacent BUG-045 arg path). All three now compile and run.
- **Root cause:** three codegen sites each used a `field_tr == .ref_to` guard unconditional on class vs. non-class payload:
  1. `.member` field-read at `src/CodeGen.zig:8441` — emitted `field.*`.
  2. `StmtAssign` self-ref boxing at `src/CodeGen.zig:6788` — emitted `{ _rp.* = rhs; target = _rp; }` for `?*T`-lhs + `T`-rhs pairs, which also fires when `rhs` is a class (already `*Class`).
  3. `StmtAssign` `ref_box_type_name` path at `src/CodeGen.zig:6802` — emitted the same create-and-store pattern for `^T` fields, again unconditional on class.
- **Fix:** three parallel class-payload short-circuits — unwrap `.ref_to` (and optional `.nilable`), check `class_names` (local) or the imported module's `types` map (cross-module); if class, return false/null and fall through to plain assign. Mirror of BUG-041 in genType and BUG-045 in genBoxedArgExpr.
- **Selfhost:** no parallel port needed — `selfhost/codegen.zbr`'s genAssign does not emit the boxing patterns (it just writes `target = value`), and `Expr.member` does not append `.*` for `ref_to`-typed fields. Phase 17c's walker-based approach bypassed the whole family.
- **Related rule:** `concept_zebra-class-auto-box-rule` — closes the triad of type emit (BUG-041), arg materialization (BUG-045), and member read + write (this).

---

*Last updated: 2026-04-18*

---

### BUG-055: Selfhost parsePostfix drops `expr.get(args)` / `expr.post(args)` method calls — FIXED
- **Status:** Fixed 2026-04-18
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `selfhost/parser.zbr::parsePostfix` only checked `.isOpenCall()` after a `.`-dot member path. When the method name is `get` or `post`, the lexer emits `kw_get` / `kw_post` keyword tokens (Token.zbr:108,150; 225-226,309-310) rather than `open_call` (which only fires when an identifier is *immediately* followed by `(` — Lexer.zbr:274-279). Since keywords win over `open_call`, `csv.get(` and `Http.post(` tokenize as `id dot kw_get/kw_post lparen ...`. The selfhost parser then fell through to the `expr.field` branch, called `.eatId()` on a non-id token, and raised `expected identifier, got 'get'/'post'`. Zig backend has dedicated productions `Expr9 → Expr9 dot (kw_get|kw_post) lparen ArgList rparen` (`src/ZebraGrammar.zig:1137-1138`).
- **Fix:** Single new branch in `parsePostfix` after the `isOpenCall` check: when peek text is `"get"` or `"post"` and `peekAt(1).text == "("`, treat it as a method call — consume the keyword, consume `(`, reuse existing `parseCallArgs()` (which expects `(` already consumed), build `expr_member` + `expr_call` same as the isOpenCall branch. Text comparison via `textIs` rather than a new `isKwGet/isKwPost` helper since the keyword token's text is the word itself.
- **Verification:** Corpus 118/152 → 120/152 (+2 emit: http_test, https_test). Both emit end-to-end to valid Zig. csv_test was the 3rd file in the cluster but trips on a separate resolver-level gap (`undefined name: 'Csv'`) after the parser succeeds — unrelated to BUG-055. Bootstrap round-trip A/B byte-identical.

---

### BUG-056: Selfhost parser rejects `r"..."` / `r'...'` raw string literals — FIXED
- **Status:** Fixed 2026-04-18
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `selfhost/parser.zbr::parseAtom` had no case for `TokenKind.string_raw_single` / `string_raw_double`, even though every other stage was wired: `Token.zbr:29-30` declared the variants; `Lexer.zbr:221-229` emitted them via `scanSimpleString`; `ast.zbr:717-726` already had `StringKind.raw` + `ExprStringLit`; `codegen.zbr:3680` already had an `if sl.kind == StringKind.raw` arm. Parser rejected the atom, so every `r"..."` raised `unexpected expression token`. Zig backend: `ZebraGrammar.zig:1202-1203` (`Atom → string_raw_single | string_raw_double`), `AstBuilder.zig:2040-2041` (`→ .string_lit` with `kind = .raw`), escape at emit in `CodeGen.zig:9946-9961`.
- **Fix (parser.zbr + astbuilder.zbr only):**
  1. `parser.zbr`: new `isRawString()` helper mirroring `isZigLit`, new `PNode.expr_raw_str as str` variant, new `parseAtom` arm after `isZigLit` that consumes the token and returns `PNode.expr_raw_str(text)`.
  2. `astbuilder.zbr`: new `stripRawAndEscape(text)` helper (strips the `r` prefix + surrounding quotes, then doubles every backslash via split-on-`\` / rejoin-with-`\\`), plus arm `on PNode.expr_raw_str as text → Expr.string_lit(ExprStringLit(zspan(), StringKind.raw, stripRawAndEscape(text)))`.
- **Why pre-escape in astbuilder (vs. Zig backend which escapes in codegen):** Mirrors the BUG-053 precedent for `stripZigQuotes`. The selfhost codegen's existing `StringKind.raw` arm emits `"` + text + `"` verbatim; if the AST kept raw content (e.g. `\d+`) un-doubled, the emitted Zig would be invalid because `\d` is not a legal Zig escape. Doubling inside the astbuilder keeps codegen trivial and sidesteps selfhost's uint/int slice-arithmetic awkwardness.
- **Why two `for p in …split(…)` loops were renamed:** Selfhost codegen lowers `for p in …` to a Zig `_it_p` iterator variable. The helper has two `split` loops, so both lowered to the same name — `redeclaration of local variable '_it_p'`. Renamed the second loop's variable to `bp` so the lowered iterators don't collide.
- **Verification:** Corpus 120/152 → 121/152 (+1 emit: raw_string_test). `diff` of `Regex.compile(...)` lines between selfhost and Zig-backend emit is empty except for pre-existing `var`/`const` divergence unrelated to this bug. Bootstrap round-trip A/B byte-identical.

### BUG-057: Selfhost parseStmt rejects `arena` scope blocks — FIXED
- **Status:** Fixed 2026-04-18
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `parseStmt` had no case for the `arena` keyword. Everything else was wired — `ast.zbr:611-617` defines `StmtArenaScope`, `Stmt` union has `arena_scope as ^StmtArenaScope` (line 420), and `codegen.zbr` already emits the `std.heap.ArenaAllocator.init(_allocator); defer _arena.deinit(); _allocator = _arena.allocator();` block. Zig backend: `StmtArenaScope → kw_arena eol Block` (`ZebraGrammar.zig:1020`).
- **Fix (parser.zbr + astbuilder.zbr):** New `PArenaScope` holder struct (stmts only), new `PNode.stmt_arena_scope as ^PArenaScope` variant, new `parseArenaScopeStmt` (`expectText arena` / `skipEol` / `parseBlock`), new parseStmt arm. Astbuilder: new `on PNode.stmt_arena_scope` arm that calls `buildStmts` and returns `Stmt.arena_scope(StmtArenaScope(zspan(), stmts))`. Added `StmtArenaScope` to astbuilder's `use ast exposing` list and `PArenaScope` to the `use Parser exposing` list.
- **Verification:** Corpus 121/152 → 122/152 (+1 emit: arena_scope_test). Bootstrap round-trip A/B byte-identical.

### BUG-062: Selfhost parseTopDecl rejects the `namespace` keyword — FIXED
- **Status:** Fixed 2026-04-18
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `parseTopDecl` had no arm for `namespace Foo[.Bar]` + indented block. Everything else was wired — `ast.zbr` defined `Decl.namespace_ as ^DeclNamespace` (line 41) with `DeclNamespace {span, name, decls}` (line 97-100), and `codegen.zbr::genNamespace` (line 1820) emitted `pub const Foo = struct { ... };` wrapping the nested class/method/var/struct/enum decls. Zig backend grammar: `NamespaceDecl → kw_namespace UsePath eol indent TopDeclList dedent` (`ZebraGrammar.zig:311-316`), built at `AstBuilder.zig:144-154`.
- **Fix:**
  1. `selfhost/parser.zbr` — added `namespace_decl as ^PNamespace` to PNode union; `PNamespace {name, decls}` struct; `parseNamespaceDecl` (eat `namespace`, read dotted path via the existing id/dot loop, `skipEol`, indent/dedent recursion via `parseTopDecl`); parseTopDecl arm.
  2. `selfhost/astbuilder.zbr` — added `DeclNamespace` to `use ast exposing`; `on PNode.namespace_decl as ns` arm in buildTopDecl recurses via `.buildTopDecls(ns.decls)?` and returns `Decl.namespace_(DeclNamespace(zspan(), ns.name, nested))`.
  3. `selfhost/codegen.zbr::generateEntryPoint` — previously only scanned `m.decls` for top-level `Decl.class_` with `shared def main`. When `main` lives inside `namespace App / class Runner / shared def main`, the scanner missed it and no top-level `pub fn main()` thunk was emitted. Added a nested `on Decl.namespace_ as ns` arm that walks `ns.decls`, finds the main class, and sets `main_class = ns.name + "." + nc.name`. The two-step string concat (`qn = ns.name; qn = qn + "."; qn = qn + nc.name;`) works around a selfhost codegen quirk where three-way `a + "." + b` can't compose two separate string slices in a single binary expression.
- **Verification:** Corpus 127/152 → 128/152 (+1 emit: `namespace_main`). Emitted `pub const App = struct { pub const Runner = struct { ... } };` + `pub fn main() void { _allocator = _arena.allocator(); defer _arena.deinit(); App.Runner.main(); }`. Compiles and runs cleanly, prints `from namespace`. Bootstrap round-trip A/B byte-identical.

---

### BUG-061: Selfhost `genMemberCall` rewrites `ClassName.add(...)` to List.append — FIXED
- **Status:** Fixed 2026-04-18
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `genMemberCall` in `selfhost/codegen.zbr:3949` matched any `.add` call and rewrote the receiver to `x.append(_allocator, arg0) catch @panic("OOM")` unless the receiver was a known StrSet. A user-defined class method like `Math.add(3, 10)` or `App.add(3, 10)` therefore emitted `App.append(_allocator, 3) catch @panic("OOM")` — wrong method *and* dropped argument. Zig backend is type-aware and correctly emits `App.add(3, 10)`. Surfaced by the pipeline fix in BUG-060b (`test/pipeline.zbr` uses `Math.add` as a pipeline target).
- **Fix (selfhost/codegen.zbr only):** Added an `is_class_ref = isUpperCase(add_nm)` guard alongside the existing `is_strset` check. The `.add → .append` rewrite now only fires when the receiver is neither a StrSet nor a class-style uppercase identifier (`App`, `Math`, `DottedLib`, etc.). This mirrors the existing uppercase guard on the StringBuilder `.build()` rewrite a few lines above.
- **Why the guard instead of positive List detection:** The codegen already has `isListField` + `list_locals` + `isKnownListField` predicates, but their coverage is not total (class-method rewrites, chained expressions, param-of-param Lists). Flipping to a positive check risked silent regressions on List receivers that weren't in any of those sets. A conservative negative guard (skip only uppercase class refs) narrows the bug without shrinking existing coverage.
- **Verification:** Bootstrap round-trip A/B byte-identical (`tools/bootstrap_check.sh`). Corpus snapshot diff: only `test/pipeline.zbr` and `test/expose_dotted_test.zbr` changed stderr_sha (emit flipped from wrong `.append(...)` to correct `.add(...)`); all other 150 files unchanged. `test/pipeline.zbr` still fails downstream on a separate pre-existing issue (user class named `Math` collides with the hardcoded `std.math.*` dispatch at `codegen.zbr:4222` — different bug, not filed yet).

---

### BUG-060b: Selfhost parseExpr drops the `->` pipeline operator — FIXED
- **Status:** Fixed 2026-04-18
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `parseExpr` had no case for the `arrow` token. Zig backend accepts `Expr → Expr arrow PipelineCall` (`ZebraGrammar.zig:1065`) and desugars `lhs -> f(args)` → `f(lhs, args...)` in `AstBuilder.zig:2266-2305` (member-call form `lhs -> obj.f(args)` → `obj.f(lhs, args...)` preserved by extracting the existing callee from the expr_call node).
- **Fix (parser.zbr + astbuilder.zbr only):**
  1. `parser.zbr`: new `PPipeline {lhs, rhs}` struct, `PNode.expr_pipeline as ^PPipeline` variant. New `parsePipeline` wrapper above `parseOr` — left-associative while-loop on `->`, with `parseOr` for both LHS and RHS. `parseExpr` now returns `parsePipeline()`.
  2. `astbuilder.zbr`: `on PNode.expr_pipeline` arm does the desugar: build `lhs_expr`, branch-match on `rhs_node` — if `PNode.expr_call as pc`, build `callee_expr` + args list with `lhs_expr` prepended; else raise. Added `PPipeline` to `use Parser exposing`.
- **Orthogonal pre-existing bug surfaced:** `test/pipeline.zbr` still fails selfhost codegen because selfhost's genMemberCall pattern-matches `.add` as a List.add→append conversion regardless of receiver type (`App.add(3, 10)` emits as `App.append(_allocator, 3) catch @panic("OOM")`, dropping the second arg). Zig backend correctly emits `App.add(3, 10)`. Filed as separate issue; the pipeline fix itself is verified sound.
- **Verification:** Corpus 126/152 → 127/152 (+1: dns_test; pipeline.zbr blocked on orthogonal `.add` bug). A `/tmp/pip_sum.zbr` probe with `.sum(a, b)` method name shows byte-identical emit to Zig backend: `const r = App.sum(3, 10);`. Bootstrap A/B byte-identical.

---

### BUG-060a: Selfhost parseOr drops the `orelse` binary op — FIXED
- **Status:** Fixed 2026-04-18
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `parseOr` accepted only `or`; `orelse` was rejected as a binary operator. `Expr.orelse_ / ExprOrelse` (`ast.zbr:655,945-953`) + codegen arm (`codegen.zbr:3369-3372`) already emit `genExpr(lhs) + " orelse " + genExpr(fallback)`. Zig backend: `Expr → Expr kw_orelse Expr2` (`ZebraGrammar.zig:1074`), builds to `.orelse_` (`AstBuilder.zig:1907-1909`).
- **Fix (parser.zbr + astbuilder.zbr only):**
  1. `parser.zbr`: new `POrelse {expr, fallback}` struct, `PNode.expr_orelse as ^POrelse` variant. Extended `parseOr` loop with `or this.textIs("orelse")`; chose branch by flag.
  2. `astbuilder.zbr`: `on PNode.expr_orelse as po → Expr.orelse_(ExprOrelse(zspan(), ...))`. Added `ExprOrelse`, `POrelse` to `use` lists.
- **Verification:** Corpus 124/152 → 126/152 (+2: nilable_test, generic_stack_test). Output `return val orelse fallback` matches Zig backend. Bootstrap A/B byte-identical.

---

### BUG-059: Selfhost parseStmt rejects `guard ... else` blocks — FIXED
- **Status:** Fixed 2026-04-18
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `parseStmt` had no case for `guard`. The AST (`Stmt.guard_ as ^StmtGuard`, `ast.zbr:418,591-599`) and the codegen (`on Stmt.guard_`, `codegen.zbr:584,2025`) were already wired, but the parser rejected the token. Zig backend accepts both productions: `StmtGuard → kw_guard Expr kw_else eol Block` (block form, `ZebraGrammar.zig:1024`) and `StmtGuardInline → kw_guard Expr kw_else comma Stmt` (inline form, `ZebraGrammar.zig:1025`).
- **Fix (parser.zbr + astbuilder.zbr only, no codegen change):**
  1. `parser.zbr`: new `PGuard {cond, else_stmts}` struct, `PNode.stmt_guard as ^PGuard` variant, `parseGuardStmt` — after `expectText("else")`, peek for `,`: if present, `parseStmt()` into a one-element list (inline form); else `skipEol()` + `parseBlock()` (block form). parseStmt arm.
  2. `astbuilder.zbr`: `on PNode.stmt_guard` arm builds condition + else-stmts and constructs `Stmt.guard_(StmtGuard(zspan(), cond_expr, else_stmts))`. Added `StmtGuard` to `use ast exposing`, `PGuard` to `use Parser exposing`.
- **Verification:** Corpus 123/152 → 124/152 (+1 emit: guard_test). Output block + inline forms match the Zig backend (modulo pre-existing `_zebra_gt` polymorphic-op wrapping — orthogonal). Bootstrap round-trip A/B byte-identical.

---

### BUG-058: Selfhost parseStmt rejects `with target` contextual-self blocks — FIXED
- **Status:** Fixed 2026-04-18
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `parseStmt` had no case for `with`. `Stmt.with_` (`ast.zbr:415`) + `StmtWith` (`ast.zbr:549-557`) + codegen `genWith` (`codegen.zbr:3184`) all existed, but the parser dropped the token. Zig backend: `StmtWith → kw_with Expr eol Block` (`ZebraGrammar.zig:1019`) with a non-trivial astbuilder step — bare-name assignments inside the block desugar to member accesses on the target (`AstBuilder.zig:1416-1438`). Selfhost `genWith` just wraps the body; without the desugar, `x = 10` inside `with p` emits as a local `x`, not `p.x`.
- **Fix (parser.zbr + astbuilder.zbr):**
  1. `parser.zbr`: new `PWith {target, stmts}` struct, `PNode.stmt_with as ^PWith` variant, `parseWithStmt` (expectText `with` / `parseExpr` / `skipEol` / `parseBlock`), parseStmt arm.
  2. `astbuilder.zbr`: `buildStmts` builds raw body; new helper `rewriteWithStmt(s, target_expr) as Stmt` pattern-matches on `Stmt.assign` → `Expr.ident`, rewrites the assign target to `Expr.member(target_expr, ident.name)`. New `on PNode.stmt_with` arm calls the helper on each body stmt. Added `StmtWith` to `use ast exposing`, `PWith` to `use Parser exposing`.
- **Gotchas encountered:**
  - **Nested `branch` inside a parent `branch` arm:** Selfhost Zig-backend parser emits a `syntax error near 'body'` on a triple-nested `branch / on / branch / on` with a following `var` declaration. Extracted the inner pattern match into a helper method `rewriteWithStmt` to keep each `branch` at a single level of nesting.
  - **Inferred list types don't iterate:** `const raw_body = .buildStmts(...)?` was lowered to `ArrayList(Stmt)` but the `for s in raw_body` loop emitted `for (raw_body)` (missing `.items`), causing `type is not indexable`. Adding an explicit annotation `var raw_body as List(Stmt) = .buildStmts(...)?` made selfhost emit `for (raw_body.items)` correctly. **Rule:** when a `List(T)` is introduced via `const`, annotate the type.
  - **Pointer field of a unwrapped branch variant:** `sa.value` where `sa` is the unwrapped `Stmt.assign as ^StmtAssign` lowered to `sa.value.*` (auto-deref Expr value) but was then passed to `StmtAssign.init` which wants `*ast.Expr`, producing `expected type '*ast.Expr', found 'ast.Expr'`. Workaround: copy to a local `var val_copy as Expr = sa.value`, which selfhost then auto-boxes at the call site. (Filed as a latent codegen inconsistency for future cleanup, but the workaround is local and safe.)
- **Verification:** Corpus 122/152 → 123/152 (+1 emit: with_test). Output `p.x = 10; p.y = 20;` inside the `{ // with }` block matches the Zig backend's emit. Bootstrap round-trip A/B byte-identical.

---

### BUG-053: Selfhost parseAtom rejects the `zig"..."` / `zig'...'` backend literal — FIXED
- **Status:** Fixed 2026-04-17
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `selfhost/parser.zbr::parseAtom` had no case for the `zig_single` / `zig_double` tokens the lexer already emits (`selfhost/Lexer.zbr:241-249`). `ast.zbr` already carried `Expr.zig_lit as ExprZigLit` (line 663), `codegen.zbr` already had an `on Expr.zig_lit` arm (line 3447), and `astbuilder.zbr` had the type in scope — but with no producer in the parser, every `var g as Greeter = zig"Greeter{}"` raised `unexpected expression token`. Zig backend accepts these via `ZebraGrammar.zig:1204-1205` (`Atom → zig_single | zig_double`) and builds to `.zig_lit` at `AstBuilder.zig:2042-2043`.
- **Fix:** Four coordinated edits:
  1. `parser.zbr` — added `expr_zig_lit as str` to the `PNode` union (mirrors `expr_str`).
  2. `parser.zbr::isZigLit()` helper — mirrors `isStringSingle/Double` for the `zig_single`/`zig_double` TokenKinds.
  3. `parser.zbr::parseAtom` — added branch after the char-lit case: `if .isZigLit(): const text = this.peek().text; this.advance(); return PNode.expr_zig_lit(text)`.
  4. `astbuilder.zbr::stripZigQuotes(text)` + new `on PNode.expr_zig_lit` arm — strip the `zig"`/`zig'` prefix and trailing quote, store content-only text in `ExprZigLit.text` (the selfhost codegen then emits it verbatim, matching Zig-backend `genZigLit` which does `text[4..len-1]` during emit — selfhost shifts the strip earlier because `uint`-typed `String.len` arithmetic is awkward in `.zbr` source).
- **Verification:** Corpus 116/152 → 118/152 (+2 emit). Both new-passing files (greet, features) emit byte-identical to the Zig backend and then fail `zig build` with the same pre-existing class-auto-box errors that the Zig-backend emit also hits (expected `*Counter`, found `Counter{}`) — so they're at exit-code-parity with the zig backend, not new runtime successes. with_test was the 3rd file in the original cluster but it trips on a separate `with ctx` keyword parser gap before reaching the zig-lit. Bootstrap round-trip A/B byte-identical.

---

### BUG-052: Selfhost parseUnary drops the `try expr` prefix form — FIXED
- **Status:** Fixed 2026-04-17
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `selfhost/parser.zbr::parseUnary` only recognised `-` as a unary prefix. The `try` prefix form of an expression (`result = try App.risky(5)`) — which the Zig backend accepts as the `kw_try Expr8` production in `src/ZebraGrammar.zig:1129` and builds into `Expr.try_` in `src/AstBuilder.zig:1811` — was silently rejected as `unexpected expression token: 'try'`. The suffix form `expr?` worked already (parsePostfix, line 1298), and stmt-level `try` (try-catch block) worked already (parseStmt at line 924), so the gap was isolated to the expression-prefix form. Equivalence rule: the grammar has both the prefix and the suffix form mapping to the same AST node; selfhost had only the suffix.
- **Fix:** One edit to `parseUnary` — after the `-` branch, mirror the pattern: consume `try`, recurse with `parseUnary()`, wrap in `PNode.expr_try(operand)`. Astbuilder already routes `PNode.expr_try` to `Expr.try_(ExprTry(...))` (astbuilder.zbr:432-434), so no downstream changes needed.
- **Verification:** Corpus 112/152 → 116/152 (+4 emit: try_catch_err, try_catch_full, try_outer_vars, raise_auto). Of those, 3 build + run correctly end-to-end (try_catch_err → "caught an error / after try"; try_catch_full → "10 / after try"; try_outer_vars → "60 / 10"). raise_auto emits but fails `zig build` on a separate auto-throws-inference gap (def risky has `raise` in body but no `throws` annotation; Zig backend infers the `anyerror!` return type — selfhost doesn't yet). Bootstrap round-trip A/B byte-identical.

---

### BUG-051: Selfhost genRaise drops the 2-arg `raise msg, details` form — FIXED (primitive + string paths)
- **Status:** Fixed 2026-04-17 (primitive + string details paths; object path emits `@compileError` fail-loud, pending future port)
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `selfhost/parser.zbr::parseRaiseStmt` parsed at most one expression after `raise` and dropped any trailing `, expr` details. The AST (`ast.zbr::StmtRaise`) already carried a `details as ^Expr?` slot, and `selfhost/codegen.zbr::genRaise` ignored it entirely — emitting only the single-message path. Zig backend (`src/CodeGen.zig::genRaise` lines 8132–8221) implements three type-dispatched paths via `tc.expr_types.get(det)`: primitive → `std.fmt.allocPrint`-based `_rdet_N` slot + shim; string → direct slice-header alloc + shim; object → typed alloc + `.toString()` shim. Equivalence rule violated in two places (parser + codegen).
- **Fix:** Four coordinated edits preserving semantics:
  1. `parser.zbr::parseRaiseStmt` — after first `parseExpr()`, if `textIs(",")` consume and append a second expr to `msg_list` (0 / 1 / 2 element shape).
  2. `astbuilder.zbr::stmt_raise` arm — thread `msg_list.at(1)` into `StmtRaise.details` when `len >= 2`.
  3. `codegen.zbr::Writer` — added `_uid` counter + `nextUid()` method on the shared `Writer` class (mirrors `Generator.nextUid()` in `src/CodeGen.zig`; Writer is heap-allocated so it survives `except`-derived Generator copies).
  4. `codegen.zbr::genRaise` — ported primitive + string emission paths from `src/CodeGen.zig`. Gate via `inferExpr(details, infer_ctx)` (pre-seeded at method/init entry with param types via `typeFromRef`). Primitive fmt dispatch: `float_/float_n` → `{d}`, `char_` → `{u}`, others → `{}`. Object path (non-primitive, non-string) emits `@compileError("selfhost BUG-051: ...")` — loud at `zig build` time rather than silent.
- **Verification:** Corpus 110/152 → 112/152 (+2 real: `throws_raise.zbr` emits valid Zig, builds, runs to completion; `raise_details_test.zbr` emits but trips the `@compileError` — object-details path, not yet ported). Selfhost emission of the 2-arg raise block is byte-identical to Zig backend on `throws_raise.zbr`. The other 4 files in the original 5-file triage cluster (`raise_auto`, `try_catch_err`, `try_catch_full`, `try_outer_vars`) remain blocked on an unrelated parser gap — `try` as an expression prefix (`result = try App.risky(5)`) — which the 2-arg raise error had previously masked. Bootstrap round-trip A/B byte-identical.

---

### BUG-050: Selfhost branch-on drops multi-pattern lists and inline-else — FIXED
- **Status:** Fixed 2026-04-17
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `selfhost/parser.zbr::parseBranchStmt` parsed exactly one `eatBranchPattern()` per arm and handled `else` only as an indented block. Two separate grammar forms were dropped: (1) `on P1, P2, ...` multi-pattern arms (Zig backend emits these as `eql(...) or eql(...)` chains — see `string_branch_test.zbr` line 5), and (2) inline `else, stmt` form (see `branch_exhaustive_test.zbr`). Equivalence rule: Zig `BranchOn` already stores `values as List(Expr)` and `BranchElseOpt → kw_else comma Stmt` — selfhost was silently restricting both to singletons.
- **Fix:** Four coordinated edits preserving semantics:
  1. `parser.zbr::PBranchOn` struct — `pattern as str` → `patterns as List(str)`.
  2. `parseBranchStmt` — after first `eatBranchPattern`, loop while `textIs(",")` collecting more patterns.
  3. `parseBranchStmt` else-arm — after `else`, if `textIs(",")` parse a single inline stmt into `else_stmts`; otherwise fall back to the existing block form.
  4. `astbuilder.zbr::buildBranch` — iterate `arm.patterns` instead of single `arm.pattern`; added `var pat as str = pat_tok` inside the loop to give the Zig emitter a declared `str` so `.split(...)` emits `std.mem.splitSequence(u8, pat, ...)` rather than a raw method call (iteration vars come out untyped `[]const u8` and miss the str-shim path — a separate Zig-backend codegen wrinkle, not a blocker).
- **Verification:** Corpus 105/152 → 110/152 (+5: string_branch_test, enum_branch_test, branch_inline_return_test, branch_exhaustive_test, and one additional). Selfhost emission byte-matches Zig backend on the classify function (`eql(u8, cmd, "start") or eql(u8, cmd, "begin")`). Bootstrap round-trip A/B byte-identical.

---

### BUG-049: Selfhost parser drops field initializers — FIXED
- **Status:** Fixed 2026-04-17
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `selfhost/parser.zbr::parseDeclField` parsed `var NAME as TYPE` then went straight to `skipEol`, never consuming optional `= expr`. The next `parseMemberDecl` iteration saw `=` as a member head and raised "unexpected member: '=' at line N". Equivalence rule also violated: Zig backend preserves the initializer; silently discarding it in selfhost would hide divergence behind A/B byte-identity.
- **Fix:** Three coordinated edits preserving semantics:
  1. `PField` struct — added `init_expr as List(PNode)` (mirrors `PVar`).
  2. `parseDeclField` — parse optional `= .parseExpr()` after type annotation into `init_expr`.
  3. `astbuilder.zbr::buildMember` `on PNode.field_` — thread `f.init_expr` into the `DeclVar` init slot (analogous to the stmt_var arm).
- **Verification:** Corpus 102/152 → 105/152 (+3: shared_field, tco_test, zebra_ide). The other 4 files in the triage cluster (struct_destruct_test, with_test, features, named_args_infer_test) expose different next features (struct destructuring, `zig"..."` expr, named-arg `:`) that the field-init error had masked — separate clusters. Bootstrap round-trip A/B byte-identical.

---

### BUG-048: Selfhost resolver does not register enum names — FIXED
- **Status:** Fixed 2026-04-17
- **Backend:** selfhost only (Zig compiler unaffected)
- **Was:** `selfhost/resolver.zbr::bindTopDecl` had arms for `class_`, `struct_`, `union_decl`, `sig_`, `method_`, `use_` but no arm for `PNode.enum_`. Enum names declared at module scope (e.g. `enum TcScopeKind`) were never added to `module_scope`, so any later `expr_id` reference to the enum type (param annotation `kind as TcScopeKind`, return type `as TcScopeKind`, list construction `List(TcScopeKind)()`) hit `resolveExpr`'s `expr_id` arm → `"undefined name: 'TcScopeKind'"`. 8 corpus files (`tc_scope.zbr`, `tc_check.zbr`, `tc_infer.zbr`, `tc_stdlib.zbr`, and their `_test.zbr` siblings) all tripped on this.
- **Fix:** Added `on PNode.enum_ as e` arm to `bindTopDecl` in `selfhost/resolver.zbr`, mirroring the existing `union_decl` arm.
- **Verification:** Corpus snapshot moved from 94/152 pass → 102/152 pass (+8, matching the affected file count exactly, zero regressions). Bootstrap round-trip A/B byte-identical.

---

### BUG-009: `opt?.field` emits `try opt.?.field` inside `if opt != nil` guard — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `opt?.x` inside an `if opt != nil` block generated `try opt.?.x` instead of `opt.?.x`. Root cause was two-layered:
  1. `exprHasTry`/`bodyHasRaise` treated all `.try_` nodes as error propagation, causing `Main.main()` to get `anyerror!void` return type even when `opt` was a plain optional.
  2. `genExpr` for `.try_` used `tc.expr_types.get(inner_ident)` to detect optional unwraps, but inside a nil-guard the ident's TC type is already narrowed to the non-optional inner type — so the optional check always missed.
- **Fix:** TypeChecker now populates `optional_unwraps: AutoHashMap(*const Ast.Expr, void)` in TypeCheckResult. When inferring a `.try_` node, it checks the inner ident's **declared** type (via `symbolType`, which bypasses nil-narrowing) rather than the inferred type. `exprHasTry` and `genExpr` both consult `optional_unwraps` instead of `expr_types`. The nil-narrowed `genIdent` path (which already emits `name.?`) is detected and the extra `.?` suppressed to prevent double-unwrap.
