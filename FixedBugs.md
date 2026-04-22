# Zebra Compiler — Fixed / Closed Bugs

Bugs that have been resolved, implemented, or closed as "not reproduced".
Open bugs live in `BUGS.md`.

---

### BUG-001: Shared method calling shared method emits `self.` prefix — FIXED
- **Status:** Fixed (prior session — TCO work fixed bare shared method calls)
- Was: `testHelper()` inside a shared method generated `self.testHelper()`.
- Now: emits `ClassName.methodName()` correctly for shared→shared calls.

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
