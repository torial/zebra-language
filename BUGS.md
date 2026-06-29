# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-149. Next new bug: BUG-150.**

---

## BUG-148: method chained on a HashMap `.fetch(k)` result miscompiles ⚠ OPEN (fix reverted)

**Severity:** medium. Found 2026-06-29 building GameEngine's `MessagingBroker`
(`zbra/services_stub.zbr`): `topics.fetch(topic).len` failed to compile.

**Cause:** `.fetch(k)` emits `(map.get(k) orelse undefined)`. The `orelse
undefined` leaves an `@TypeOf(undefined)` peer in the null branch — fine when
assigned to a typed local, but when a member is chained on the result
(`m.fetch(k).at(0)`), Zig can't peer-resolve `*const T` vs `@TypeOf(undefined)`:
`error: incompatible types: '*const …' and '*const @TypeOf(undefined)'`.

**Attempted fix (reverted):** emitting `(map.get(k).?)` cleanly fixes the
chaining error (verified: `m.fetch(k).at(1)` then compiles+runs) and gives a
*defined* panic instead of UB. **But it broke the round-trip** with
`panic: attempt to use null value` — the **compiler's own source calls
`.fetch(k)` on a sometimes-absent key** and was silently relying on the old
`orelse undefined` (UB that happened not to crash). `.?` turns that latent
misuse into a hard panic during self-compile.

**Real fix (prerequisite first):** audit the selfhost/bootstrap sources for
`.fetch(k)` on possibly-absent keys and guard them (`if m.contains(k)` /
`m.get(k)` optional form) **before** switching the `.fetch` emit to `.?`. Sites:
one in `src/CodeGen.zig`, two in `selfhost/CodeGen.zbr` (24- and 12-space
indented). Until then `.fetch(k)` chaining needs a local (`var q = m.fetch(k)`).
Workaround in place in `zbra/services_stub.zbr`.

## BUG-149: `.len` property on a HashMap `.fetch(k)` result (local-inited map) not lowered

## BUG-149: `.len` property on a HashMap `.fetch(k)` result (local-inited map) not lowered

**Severity:** low (workaround: bind to a local — but see the field/local quirk).
Found 2026-06-29 alongside BUG-148.

**Symptom:** `m.fetch(k).len` (or even `var q = m.fetch(k)`; `q.len`) where `m` is
a **local-inited** `HashMap(K, List(T))` emits `.len` literally rather than
`.items.len` → `error: no field named 'len' in struct 'array_list…'`. The
`.len`-property lowering (#219) doesn't infer that `fetch` returns the map's
List value type from a local-inited HashMap. **It works when the HashMap is a
class field** (`this.field.fetch(k)` resolves the value type via the field
decl), so `zbra/services_stub.zbr`'s `pending()` compiles. Method calls
(`.at`/`.add`) are unaffected.

**Fix direction:** teach the `.len`-property path (and `getExprDeclaredType`) to
derive a `.fetch(k)` result's element/value type from a local-inited HashMap, the
same way it already does for class fields — same family as BUG-147 (call-result
type inference). Deferred (touches broadly-consulted inference; round-trip risk).

---

## BUG-144: a forwarded List/HashMap param emitted `*const` and failed to compile ✅ FIXED

**Severity:** medium (a common cursor/accumulator pattern did not compile).
Found 2026-06-28 dogfooding `examples/lisp.zbr` (its parser threads a one-element
`pos` cursor `List(int)` through `parseForm`/`parseList` → `advance(pos)`).

**Symptom:** a `List(T)`/`HashMap` parameter that is **forwarded by bare ident**
to a mutating callee — but not mutated directly in the body — was emitted by
value (`*const std.ArrayList`), so the `&` at the forwarding site failed with
`error: expected type '*T', found '*const T'`.

Minimal repro:
```
def bump(xs: List(int))
    xs.add(99)
def forward(xs: List(int))   # never mutates xs directly — only forwards it
    bump(xs)
```

**Root cause:** `paramNeedsAddrOf` only checked *direct* mutation (a mutating
method called on the param in this body); it ignored forwarding to a callee that
mutates its matching positional param.

**Fix:** split the predicate into a direct-only core (`paramDirectlyNeedsAddrOf`)
plus a transitive wrapper (`paramNeedsAddrOf` / selfhost `paramNeedsAddrOfTx`)
that reuses the existing forwarding-detector `addAddrOfMutationsInStmts` — the
same one the local var/const decision uses. That detector checks callees with the
direct-only predicate, so there is no recursion. Coverage is **one forwarding
hop** (the common cursor case); deeper pure-forwarding chains (A→B→C where only C
mutates) are not yet flagged. Mirrored in `src/CodeGen.zig` + `selfhost/CodeGen.zbr`;
round-trip byte-identical, smoke 178/178, compile-check 143/0. Regression test:
`test/transitive_list_param_test.zbr`.

---

## BUG-145: `for x in <throws-call>?` (for-in directly over a throws call) ✅ FIXED (selfhost)

**Severity:** low. Found 2026-06-28 in `examples/lisp.zbr` (`for a in listToVec(p)?`).

**Symptom:** iterating directly over a `?`-propagated throws-returning `List(T)`
emitted Zig that does field access on the error union before the `try` unwrap:
`error: error union type 'anyerror!array_list.Aligned(...)' does not support
field access` — because in Zig `.items` binds tighter than `try`, so
`try f().items` reads `.items` off the error union.

**Fix:** `genForInList` (and the selfhost str-list / plain-list for-in arms)
parenthesize the iterable when it is a `try`-expr: `(try f()).items`. Mirrored in
`src/CodeGen.zig` + `selfhost/CodeGen.zbr`. The Lisp now uses `for x in f()?`
directly at all four sites. Regression test: `test/forin_throws_test.zbr`.

**Remaining (bootstrap only, BUG-147 family):** the `--zig-backend` bootstrap
still can't reach `genForInList` for `for x in userFn()?` — its
`getExprDeclaredType` has no `.call`/`.try_` arm, so the iterable's type isn't
resolved to `List` and the loop falls through to a native Zig for-loop
("type ... is not indexable and not a range"). The selfhost's type inference
already looks through `try`. Closing the bootstrap side means giving
`getExprDeclaredType` a call-return-type + try-passthrough arm; deferred because
that function is broadly consulted (round-trip-byte-identity risk on the
non-primary compiler).

---

## BUG-146: `str.toFloat()` / `str.toInt()` return 0 on parse failure ✅ FIXED (added tryFloat/tryInt)

**Severity:** medium (silent wrong-data footgun for any tokenizer/validator).
Found 2026-06-28 in `examples/lisp.zbr` — `parseAtom` relied on a failing
`toFloat()` to fall through to "symbol", but every symbol (`+`, `car`, `<=`)
parsed as the number `0`.

**Cause:** `toFloat`/`toInt` are emitted with a `catch 0.0` / `catch 0` fallback
and typed as plain `float`/`int` — a non-numeric string yields `0` indistinguishable
from the literal `"0"`, with no failure channel.

**Fix (non-breaking, additive):** added `str.tryFloat(): float?` and
`str.tryInt(): int?`, emitted as `(std.fmt.parse… catch null)` (an optional
`?f64`/`?i64`) and typed as optional in both type checkers. The existing
0-fallback `toFloat`/`toInt` are unchanged. `examples/lisp.zbr` now classifies
tokens with `tok.tryFloat()` (the `looksNumeric` workaround is removed).
QUICKSTART updated (and the stale "toInt panics on bad input" note corrected to
"0 on bad input"). Mirrored in `src/{CodeGen,TypeChecker}.zig` +
`selfhost/{CodeGen,TypeChecker}.zbr`. Regression test: `test/try_parse_test.zbr`.

---

## BUG-147: bootstrap (`src/`) miscompiles `examples/lisp.zbr` (3 emit divergences) — BUG-143 family

**Severity:** medium (equivalence violation; selfhost is correct, bootstrap lags).
Found 2026-06-28 — `zebra --zig-backend run examples/lisp.zbr` fails to compile
while the default selfhost compiler runs it correctly end-to-end.

**Symptoms (src/ emit only):**
- `incompatible types: '*lisp.Value' and '@EnumLiteral()'` (a `^Value` field /
  union-literal site in `makeLambda`).
- `expected type 'lisp.Value', found '*lisp.Value'` passing a `^Value` to a
  by-value `showValue(v: Value)`.
- `no field or member function named 'toInt' in 'f64'` — `float.toInt()` not
  lowered the way the selfhost lowers it.

**Status:** OPEN. Same "bootstrap lags selfhost" class as BUG-143; the lisp is a
good multi-pattern repro for a future src/→selfhost convergence pass.

---

## BUG-143: bootstrap (`src/`) codegen lags the selfhost — 14 user-program emit divergences

**Severity:** medium (equivalence violation; the bootstrap is no longer the
primary compiler, but is still reachable via `zebra --zig-backend` and is the
authority that regenerates `selfhost/*.zig`). Found 2026-06-27 by a bootstrap-emit
parity sweep run after compile-check reached 141/0 on the selfhost.

**Status:** IN PROGRESS (task #231) — **12 of 14 closed, parity 120→132 / 14→2**.
Round-trip byte-identical after every fix; selfhost steady at 141/0. The bootstrap is
the **non-primary** compiler, so this is equivalence-restoration, not active-feature work.

**Closed (12):** realpath (sys.cwd/Path.absolute → 0.16 API); Dir.walk `.next(_io)`;
the **ArrayList `.items` cluster** (list_index, for_else, module_var_shadow,
list_ref_autobox, bug119) via a positive-only `objIsList(expr)` helper (list_lit |
`List()` ctor | declared/inferred `List(T)`) wired into the `.index` arm + genForIn, plus
`getExprDeclaredType` generalised to `localVar.field` (module-decls field lookup) and a
list-lit-init `.empty` fix; the **HashMap cluster** (remove, set, field_collision,
param_field) via a `HashMap(K,V)()` ctor → `genStdlibInit` intercept, an `objIsHashMap`
helper lowering `m[k]`→`m.get(k).?`, and inferred-HashMap-var type derivation; and
**tc_iface_transitive** (concrete→interface var-init fat-pointer coercion).

Key design point: all list/hashmap detection is **positive-only** (matches only
definitely-List/HashMap exprs), so strings never match and the compiler's own `spec[i]`
string subscripts / `.at()` list access are untouched → the round-trip stays byte-identical.

### Remaining 2 — kitchen-sink tests, each with further stacked layers
- **dir_walk_test** (parity not yet flipped): walker.next + for-over-Dir.walk-list are
  fixed, but the loop var `f` (element of `List(str)`) isn't typed `str`, so
  `f.endsWith(".zbr")` emits a literal `.endsWith` instead of `std.mem.endsWith`. Needs a
  **TypeChecker** change: infer the for-loop element type for a `Dir.walk`-initialised
  list var (the bootstrap relies on TC element inference for str-method dispatch). Likely
  more layers after (`files.count()`).
- **ws_smoke_test** (parity not yet flipped): the spurious closure capture is **fixed**
  (capture free-var analysis now excludes `if as` bindings — collectFreeVarsStmt +
  checkCaptureBoundaryStmt). Next layer: `ws.recv()` inside the closure doesn't dispatch
  as a `WsConn` method (`_WsConn` has no `recv`; needs `_ws_recv(ws)` — the closure body
  loses the param's `WsConn` type for stdlib-method dispatch).

### What it is
`tools/compile_check.sh` type-checks the Zig the **selfhost** emits (141/0/1 green).
Running the same check against the **bootstrap** emit (`--bootstrap`) yields
**120 passed / 14 FAILED / 8 skipped**: 14 positive-smoke tests where the bootstrap
emits Zig that does **not** type-check, while the selfhost emits correct Zig for the
same source. The selfhost is *ahead* of the bootstrap — this session's (and earlier)
stdlib/0.16 codegen fixes were applied to `selfhost/CodeGen.zbr` and never mirrored
to `src/CodeGen.zig`. It stayed invisible because no gate exercised the bootstrap's
**user-program** emit (`bootstrap_check.sh` only exercises the bootstrap emitting the
*compiler*, which happens not to hit these paths in a breaking way; the
compiler sources use e.g. `sys.cwd` only once and not the broken `.items`/HashMap
shapes).

**Proof of direction (sys.cwd):**
- `src/CodeGen.zig:6969,7314` → `std.Io.Dir.cwd().realpathAlloc(_io, …)` — the
  **0.16-removed** API (`error: no field … 'realpathAlloc' in 'Io.Dir'`).
- `selfhost/CodeGen.zbr:11620` → `std.process.currentPathAlloc(_io, _allocator)` — fixed.

### The 14, by root-cause cluster
- **ArrayList `.items` indexing (5):** `for_else_test`, `list_index_test`,
  `module_var_shadow_test`, `list_ref_autobox_test`, `bug119_list_field_param_test`.
  Bootstrap emits `xs[i]` / `xs` where the selfhost emits `xs.items[@as(usize, …)]`
  (`error: array_list … is not indexable` / `missing struct field: items`).
- **HashMap emission (4):** `hashmap_remove_test`, `hashmap_set_test`,
  `hashmap_field_collision_test`, `hashmap_param_field_test`. Bootstrap emits a
  bogus `HashMap(K,V).init()` (undeclared identifier; no allocator) where the
  selfhost emits `std.StringHashMap(V).init(_allocator)` + `_intern`/`catch`.
- **0.16 stdlib API (2):** `stdlib_additions_test`, `stdlib_misc_test` — `realpathAlloc`
  (above); likely other 0.16 renames in the same region.
- **Concrete→interface coercion (1):** `tc_iface_transitive_match_test` — known gap
  (see COMPILE_CHECK_STATUS.md): `var b: IBase = d` for concrete `d` is selfhost-only.
- **Individual (2):** `dir_walk_test` (`member function expected 1 argument(s), found 0`);
  `ws_smoke_test` (`use of undeclared identifier 'm'`).

### Repeatable gate (landed)
`compile_check.sh --bootstrap` was **non-functional** before this (it passed
`--output-dir` to the bootstrap, whose CLI emits to stdout and rejects the flag, so
every emit silently `continue`d → `0 passed, 0 FAILED`). Fixed 2026-06-27: bootstrap
mode now emits each root file to stdout, and skips multi-file dep tests (the bootstrap
stdout path can't materialize separate-module deps — those pass under the selfhost
whose `--output-dir` emits the deps too). The gate now reports the real 120/14/8.

### Fix plan (scoped — for a gated session)
Mirror each cluster's fix from `selfhost/CodeGen.zbr` into `src/CodeGen.zig`, one
cluster at a time, re-running `bootstrap_check.sh` (round-trip must stay byte-identical)
+ `compile_check.sh --bootstrap` after each. Start with the lowest round-trip risk
(realpath: the compiler uses `sys.cwd` once; ArrayList/HashMap shapes need checking
against compiler-internal usage first). Target: `--bootstrap` reaches the same
141/0 as the selfhost, restoring full equivalence. Then wire `--bootstrap` into the
parity gate so this can't silently regress again.

## BUG-142: missing required argument compiles + runs with garbage

**Severity:** high (correctness/safety — silent wrong behavior).
**Status:** PARTIAL ✅ 2026-06-23 — (a) emits a non-fatal **warning**
(`too few arguments to 'X': expected N, found M`); (b) the **undefined-behavior is
gone**: codegen now pads an omitted no-default argument with `std.mem.zeroes(T)`
(a deterministic zero) instead of `undefined`, so a too-few-args call can no
longer read uninitialized memory. What remains for a full close: promoting the
warning to a hard **error** (gated on the translator follow-up below, so valid
Luau-nil-default calls aren't broken). Found 2026-06-22 via the error-experience
audit (`docs/error_experience_audit.md`).

### What shipped (warning)
A `checkArgCount` + `checkArgCountsInExpr` walker in `selfhost/TypeChecker.zbr`
runs in `checkStmts` over every statement's expressions (var-init, return,
assign, expr-stmt, `print`, and if/while/for/guard conditions). It compares the
provided arg count against the callee's declared params (via new
`fnParamList`/`fnParamListAny` accessors over the already-stored `fn_param_lists`),
counting **required = params without a default**. Conservative: only fires when
the callee's full Param list is known (resolved user free fn / method); builtins,
stdlib, closures-in-locals, and unresolved receivers are skipped. Reaches nested
calls like `print(add(1))`. Regression tests: `test/arg_count_test.zbr` (warns),
`test/arg_count_ok_test.zbr` (defaults + correct arity compile clean).
Round-trip byte-identical; smoke green.

### Why warning, not error (the corpus finding)
Making it a hard error regressed the translator corpus by 28 (1482→1454). The
failures were almost all **off-by-exactly-one** (`expected 4, found 3`) on
translated Luau functions (`playAnimation`, `Scale`, `CreateSubClass`, …): **Luau
permits calling with fewer args** (missing become `nil`), so the translator
pervasively emits too-few-arg calls relying on nil-defaulting. In Zebra those
calls are genuinely unsafe (they hit the `undefined`-padding), but flagging 28
pervasive translator outputs as errors is too aggressive. As a warning, the
corpus is unaffected (warnings are non-fatal → 0 arg-count failures, baseline
restored) while the issue is surfaced.

### Follow-up to fully close (promote warning → error) — de-risked 2026-06-23

Investigated in depth (prototyped both sides, then reverted to the clean warning
state). Key findings for whoever finishes it:

- **All ~28 corpus too-few-args cases are SAME-MODULE** (the function is defined
  *and* called with fewer args in the same script). So the translator analysis is
  **per-script**, not cross-module — much more tractable. (Confirmed: a
  current-module-error vs dep-warn split in `checkArgCount` left the count at 28,
  proving none are cross-module.)
- **Lambda param defaults parse fine** (`var f = def(a, b = nil) = …` works), so
  that is not a blocker.

Remaining work, in order:
1. **Compiler — severity split** (ready, gate-clean in prototype): in
   `checkArgCount`, error when the callee is in `ctx.module_types` (same module —
   the signature is right there, almost certainly a real bug), warn when it
   resolves only via `dep_types`. On its own this regresses the corpus by the full
   28 (all same-module), so it must land *with* the translator change below.
2. **Translator** (`GameEngine/tools/luau2zebra_ast.py`): a per-script pre-pass
   (`_collect_call_arity`, walk the luaparser AST — **use a visited-id set**, nodes
   carry cyclic parent refs) records each bare-name callee's min observed arg
   count; `_emit_params(args, optional_from)` then emits the under-supplied trailing
   params with `= nil`. Prototype took the corpus 1454→1458 (fixed ~15 of 28) but
   surfaced two gaps to finish: (a) the **capture-extraction path** in
   `_emit_func_as_assignment` reuses the `params` string as *call arguments* to the
   hoisted `_lambda_N`, where `= nil` is invalid — separate the param **decl**
   string (with defaults) from the param **names** string (for the call); (b) the
   remaining ~13 are **method** calls (luaparser `Invoke`) and other non-bare-name
   forms the walk skips — extend the walk + match method defs (offset by the
   prepended `self`).
3. **Codegen** (already done): a missing no-default arg is padded with
   `std.mem.zeroes` not `undefined`, so the UB is gone regardless.
4. Land 1+2 together, confirm corpus stays ~1482, then gate + smoke; update the
   `arg_count_test` smoke fixture from `smoke_warn` → `smoke_tc_fail` (same-file).
~~Also: arg-count diagnostics currently report `0:0` in `print`/expr-stmt
positions because expression spans are `zspan()` placeholders.~~ ✅ RESOLVED
2026-06-23 — identifier and member expressions now carry real spans (the parser
captured them; the AST builder was discarding them), so the arg-count /
forgot-parens / arg-type diagnostics render precise carets. Only literal
arguments still fall back to the callee position.

### Original report (for context)

**What happens:** calling a function with fewer arguments than it has parameters
is not caught. Codegen pads the missing positional arg with `undefined`:
```
def add(a: int, b: int): int
    return a + b
def main()
    print(add(1).toString())   # → emits `add(1, undefined)` → prints garbage
```
`add(1)` runs and prints an uninitialized value (e.g. `140701535361921`) instead
of reporting "expected 2 arguments, found 1". A Zig compile would normally reject
the arity, but the `undefined` padding makes it type-check and execute.

**Root cause(s):**
1. Codegen pads omitted positional args with `undefined` (the same mechanism that
   should fill **defaults** — see BUG-139). For a param **without** a default,
   `undefined` is never correct.
2. The TypeChecker does not validate argument **count**. `checkCallExpr` checks
   arg *types* but (a) doesn't count args vs params, and (b) only runs on
   `Stmt.var_` init exprs, so a nested call like `print(add(1)…)` is never
   checked.
3. `ModuleTypes` stores `method_params` as a CSV of param **types** only — it does
   **not** record which params have defaults, so "required arg count" can't be
   computed yet.

**Fix approach (pairs with BUG-139):**
- Thread per-param default info into `ModuleTypes` (mirror of the bootstrap's
  BUG-182 Param-list-with-defaults storage), so `required = params without a
  default`.
- Add an arg-count check at the `Expr.call` arm of `inferExpr` (the universal
  expression walker — fires in every position, fixing reach issue 2b) with a
  caret diagnostic: too few args (< required) and too many (> total, modulo
  varargs/builtins).
- Be conservative to avoid corpus false-positives: only fire when the callee's
  full param list is known (resolved free fn / method in module or dep types);
  skip builtins/stdlib and unknown callees. **Verify against the full translator
  corpus** (`tools/corpus_probe.py`) before committing — a false "too few args"
  would break valid programs.

**Workaround today:** none at the language level; pass all arguments explicitly.

---

## Name-based container-dispatch audit (2026-06-22) — COMPLETE

After fixing the field-name-collision class of bug (BUG-138 List `.len`/`.count`,
BUG-140 HashMap index/`.count`/`.remove`/`.set`, BUG-141 List `[i]` read), the
remaining name-based container dispatches were swept for the same vulnerability.
Findings:
- **List index-write** (`list[i] = v`): already correct — emits `list.items[i] = v`.
- **StrSet `.count()` collision** (`fieldIsStrSet` is global name-based, and
  `enum_names`/`union_names` are StrSet in CodeGen but HashMap in TypeChecker):
  **benign** — the count emit is identical (`@as(i64, @intCast(obj.count()))`)
  whether classified as StrSet or HashMap, and both Zig types have `.count()`.
  Not "benign by luck": there is no observable difference, so no fix is warranted
  (a class-scoped `fieldIsStrSet` would be pure churn).
- **StrSet at the HashMap dispatch sites** (`.remove()`/`.set()`/index): already
  protected by BUG-140's class-scoping — `fieldAwareIsHashMap` returns false for
  a StrSet field (it isn't a `HashMap` generic), so StrSet ops don't mis-route.

Conclusion: the class is closed. The only name-based predicate left
(`fieldIsStrSet`) is provably harmless. New same-named container-field collisions
are now structurally safe at every read/count/remove/set/index site.

---

## BUG-141: indexing a List with `[i]` miscompiles (needs `.items[i]`) ✅ FIXED

**Severity:** medium (reachable, cryptic failure; non-idiomatic syntax so likely
rare in practice — `.at(i)` is the documented accessor).
**Status:** ✅ FIXED 2026-06-22 (selfhost-only). Index-read of a List receiver
(local or current-class/module-type field) now emits `obj.items[i]` instead of
`obj[i]`.

**Why selfhost-only:** the index-read dispatch already differs between the two
compilers and the selfhost is the richer (correct) one — the bootstrap's
`.index =>` arm does NO container dispatch (it emits `self.bag[k]` even for a
HashMap field, which is also invalid Zig), while the selfhost already turns a
HashMap `bag[k]` into `.get(k).?`. Adding List handling extends the selfhost's
existing dispatch and matches the dual-version policy (user-facing-only feature ⇒
selfhost-only; the bootstrap is the trusted regenerator and the selfhost source
indexes Lists via `.at()`, so the round-trip is unaffected). Bringing the
bootstrap index path up to full parity is a separate, larger cleanup if ever
needed.

**Fix** (`selfhost/CodeGen.zbr`, the `Expr.index` read arm): added
`fieldAwareIsList` (parallel to `fieldAwareIsHashMap`) and emit `.items` before
the `[` when the receiver is a List and not a HashMap. Regression test
`test/list_index_test.zbr` (local + field List index, runs end-to-end). Strings
/slices unaffected (still plain `[i]`). The index-**write** path (`obj[i] = v`)
and `.at(i)` were already correct.

### Original report (for context)
**Discovered** 2026-06-22 while building the BUG-140 repro.

**What happens:** indexing a `List` receiver with the `[i]` postfix operator
emits raw `obj[i]` instead of `obj.items[i]`. A `std.ArrayList` does not support
direct indexing, so the generated Zig fails to build:
```
error: type 'array_list.Aligned(i64,null)' does not support indexing
```
Reproduction (both a local and a field List trigger it; strings are fine):
```
def main()
    var nums = List(int)()
    nums.add(10)
    print(nums[1].toString())   # emits nums[@intCast(1)] — invalid; needs nums.items[...]
    var s = "hello"
    print(s[1].toString())      # OK — string is []const u8, slice indexing works
```
`nums[1]` is a natural thing to write, and the grammar lists `[i]` as a valid
postfix (QUICKSTART §ops table) even though `.at(i)` is the documented, working
List accessor (QUICKSTART line ~643). So the operator silently miscompiles rather
than working or giving a clean Zebra error.

**Scope:** the index-**read** path. Receivers that are a List *local* or a List
*field* both miscompile; string/slice/array indexing is correct as-is. The
write/assign path (`obj[i] = v`) and `.at(i)` are unaffected.

**Present in BOTH compilers** (so a fix must touch both, for functional
equivalence):
- bootstrap `src/CodeGen.zig` — the `.index =>` arm (~line 12137) emits
  `genExpr(object)` + `[ … ]` with no List special-case. NOTE: the `Type` union
  (`src/TypeChecker.zig:44`) has **no dedicated `.list` variant** — Lists are
  recognised at the `TypeRef` level (`tr.generic.name == "List"`), not as an
  inferred `Type`, so `tc.expr_types.get(e.object)` won't simply return "list".
  Detecting a List receiver here needs the declared TypeRef / resolve symbol of
  the object (field decl type, or the local's declared `List(T)`), not the
  inferred `Type`. There are also two index-emit paths (~8665 with
  `[@as(usize, @intCast(`, ~12137 with `[@intCast(`) — confirm which one(s)
  handle field/local List index reads before editing.
- selfhost `selfhost/CodeGen.zbr` — the `Expr.index` arm (~line 6824). Add a
  `fieldAwareIsList` (parallel to the new `fieldAwareIsHashMap`): local List
  wins, else class-scoped `isListField`, else `isKnownListField`/`fieldIsList`.
  Emit `.items` before the `[` when the receiver is a List.

**Equivalence note / verification plan:** while building the BUG-140 repro I also
noticed a *latent* cast-style divergence at this site — post-BUG-140 selfhost
emits `[@as(usize, @intCast(0))]` while bootstrap emits `[@intCast(0)]` for the
same `bag[0]`. It never manifests in the round-trip because the selfhost source
indexes Lists via `.at()`, not `[i]`. Any fix here should reconcile that too, and
must be verified by: implement both sides → `bootstrap_check.sh --update`
(bootstrap regen) → plain `bootstrap_check.sh` (selfhost regen) → confirm
`selfhost/*.zig` is unchanged between the two (proves bootstrap emit == selfhost
emit on the actual source). Plus a runnable regression fixture (`nums[1]` on a
local + a field List).

**Workaround today:** use `list.at(i)` (bounds-checked, emits `.items[i]`).

---

## BUG-140: selfhost HashMap dispatch was field-name-based, not class-qualified ✅ FIXED

**Severity:** medium (selfhost-codegen gap; the bootstrap was already correct).
**Status:** ✅ FIXED 2026-06-22. The sibling of BUG-138, for HashMaps: the
selfhost's HashMap member dispatch (indexing `obj[k]`, `.count()`, `.remove()`,
`.set()`, and index-assignment) decided "is field `X` a HashMap?" by **field
name across all classes** (`fieldIsHashMap`), so when two classes had a
same-named field of different container-ness, the dispatch mis-fired.

**Reproduction** (a `List(int)` field colliding with a same-named `HashMap`
field of another class, indexed):
```
class MapHolder
    var bag: HashMap(str, int)
class ListHolder
    var bag: List(int)
    def at0(): int
        return bag[0]
```
- **Selfhost** emitted `return self.bag.get(0).?;` — treating the `List` as a
  HashMap because `fieldIsHashMap("bag")` was globally true (from `MapHolder`).
- **Bootstrap** emitted `return self.bag[@intCast(0)];` — correct (class-scoped).

The selfhost emit is invalid Zig (`List` has no `.get`), so it was build-caught,
but it silently blocked any future selfhost code with a same-named List/HashMap
field pair. The selfhost source already has three such collisions one edge away
from biting: `enum_names` (StrSet vs HashMap), `union_names` (StrSet vs HashMap),
`module_fns` (HashMap vs a class type).

**Fix** (`selfhost/CodeGen.zbr`): added a class-scoped `isHashMapField`
(parallel to `isListField`, via `lookupFieldType` over the current class's
members) and a `fieldAwareIsHashMap` helper — a local var shadows any same-named
field (its type wins), then a field of the **current** class is authoritative
(do NOT fall through to the global name-based `fieldIsHashMap`). Replaced all
five `localIsHashMap(X) or fieldIsHashMap(…)` dispatch sites with
`fieldAwareIsHashMap(X)`. Selfhost-only (the bootstrap's symbol-table resolution
was already right). Round-trip byte-identical; smoke green; regression test
`test/hashmap_field_collision_test.zbr`.

---

## BUG-139: selfhost doesn't fill default `cue init` params at omitting call sites

**Severity:** low (easy workaround: pass the arg explicitly).
**Status:** OPEN, discovered 2026-06-22 while threading `source` into the Resolver
for the undefined-name caret.

**What happened:** a `cue init` with a trailing default param —
`cue init(file_name: str, source: str = "")` — does **not** get the default
filled in at call sites that omit it. `Resolver.Resolver(path)` emitted a 1-arg
Zig `init(path)` against a 2-param `init`, failing:

```
expected 2 argument(s), found 1
```

Every Resolver construction now passes the arg explicitly (`Resolver.Resolver(path, "")`
at the error-ignoring site, `…(path, src)` elsewhere), which is why the caret
shipped. The Parser's identical `source: str = ""` default never tripped this
only because every Parser construction already passed all args.

**Scope / open questions:**
- Default-fill clearly works *somewhere* (default params have been used before) —
  characterize precisely when it does/doesn't. Suspect it's **constructor**
  (`Type.Type(...)` cue-init) call sites specifically, vs. ordinary method calls.
- Bootstrap parity unknown: the bootstrap (Zig `src/`) likely fills defaults
  correctly (this surfaced only on the selfhost round-trip path). Confirm whether
  this is a genuine bootstrap-vs-selfhost divergence or a shared gap.

**Where to look:** selfhost call-emission for cue-init / constructor calls — the
arg-count/default-fill logic in `selfhost/CodeGen.zbr` (genCall / ctor path).
Compare against how the bootstrap fills missing trailing defaults.

**Payoff when fixed:** removes a latent foot-gun (silent "expected N args, found
M" on any defaulted cue init) and lets selfhost compiler code rely on init
defaults the way user programs can.

---

## BUG-138: selfhost `.len` dispatch was field-name-based, not class-qualified ✅ FIXED

**Severity:** medium (selfhost-codegen gap; the bootstrap was already correct).
**Status:** ✅ FIXED 2026-06-22. Root cause was narrower than first thought (not
`.split`): the selfhost's `.len`/`.count` member dispatch looked up "is this a
List field?" by **field name across all classes**, so when two classes had a
same-named field of different types (`source: str` on `Parser` vs `source:
List(PNode)` on `PInScope`), `self.source.len` on the str field wrongly emitted
`self.source.items.len` (`.items` on a `[]const u8`).

**Fix** (`selfhost/CodeGen.zbr`, the `.len`/`.count` member path): when the
member object is a field of the **current** class (`isFieldName`), trust the
class-scoped `isListField` answer and do NOT fall through to the name-based
`fieldIsList(.module_types, …)`, which false-positives on a same-named List field
of another class. Selfhost-only (the bootstrap's symbol-table resolution was
already right). Round-trip byte-identical; smoke 161/161; regression test
`test/field_name_collision_test.zbr` (`text=5 list=3`).

**Payoff:** unblocked the **caret/source-line** parser diagnostic — the Parser
now carries the source text and renders a `^` under the offending column
(committed alongside the fix), which previously hit this divergence.

### Original report (for context)
Discovered while adding a caret/source-line to parser diagnostics. The diagnostic
*message* improvement shipped first (d9b4ec3); the caret was reverted until the
codegen fix landed.

**What happened:** I added a field to `selfhost/Parser.zbr` to hold the source
text for caret rendering and used it with `split`:
- First as `var source_lines: List(str)` populated via `for ln in source.split("\n"): .source_lines.add(ln)`.
- Then reformulated as `var source: str` with a `sourceLine(li)` helper doing
  `for ln in .source.split("\n")`.

Both compile + run correctly when **zebra-bootstrap.exe** (the Zig compiler)
emits `Parser.zbr` — `zig build`, smoke 159/159 all pass. But the round-trip
gate fails at **selfhost-B build**: the **selfhost** compiler (selfhost-A)
re-emits `Parser.zbr` into Zig that references `.items` on a `[]const u8`:

```
selfhost/Parser.zig:4516:45: error: no member named 'items' in '[]const u8'
```

i.e. the selfhost codegen treats the `str` field (or the `split` result, or the
field's element/whole type) as a `List`/`ArrayList` at a use site while its Zig
type is a string slice — a type-inference inconsistency that only the **selfhost**
codegen has (the bootstrap gets it right), so it's a genuine bootstrap-vs-selfhost
divergence.

**Why it matters:** it means a `str`/`List(str)` field interacting with `.split`
can't currently be added to any of the `selfhost/*.zbr` compiler files (they
must round-trip). User programs are unaffected (they compile via zebra.exe,
which is fine — the bug is in *re-emitting* such code).

**To investigate / fix:**
- Build selfhost-A, have it `--emit-zig selfhost/Parser.zbr` with the reverted
  caret code re-applied, and inspect the emission around the `.items` site to
  see which expression's inferred type is wrong.
- Likely in `selfhost/CodeGen.zbr` / the InferCtx field-type or `split`-result
  handling — the selfhost infers the field (or the loop var, or `.len`) as a
  List where it's a str (or vice-versa).
- The reverted caret code (small) is the reproduction; re-apply from the
  d9b4ec3 parent's working-tree notes or re-derive (a `var source: str` field +
  `for ln in .source.split("\n")` + `.source.len`).

**Payoff when fixed:** unblocks the caret/source-line diagnostic (and any future
selfhost code that wants a split-derived string field) — a clean self-hosting-
duality fix.

---

## BUG-137: module-level `var`/`const` names can collide with file-scope decls

**Severity:** medium (correctness/usability for hand-written module vars).
**Status:** ✅ FIXED 2026-06-21 (commit pending). Module vars now emit with a
reserved `_zbr_mv_` prefix in both compilers; references are prefixed
identically, and a shadowing local/param keeps its bare name. The
translator-side mitigation discussed below is no longer required.

### Resolution

Both compilers emit a module-level `var`/`const` as `pub var`/`pub const
_zbr_mv_<name>` (constant `module_var_prefix` in `src/CodeGen.zig`; literal in
`selfhost/CodeGen.zbr` `genFieldDecl`). A reference that resolves to a module
var is emitted with the same prefix:

- **Bootstrap** (`src/CodeGen.zig` `genIdent`): keyed on the resolved symbol
  (`sym.decl.var_.is_top_level`) — sound per-reference, since a shadowing local
  resolves to its own symbol and keeps its bare name.
- **Selfhost** (`selfhost/CodeGen.zbr` `genIdent`): name-based via
  `isModuleVarName` (`module_types.fieldType("", name)`) guarded by
  `isLocalOrParamName` (`param_names` + `infer_ctx.hasLocal`). `genLocalVar` now
  binds every local (incl. unknown-typed) into `infer_ctx`; `noteShadowLocal`
  registers the other binding forms — for-in loop vars (`genForIn`), numeric
  loop vars (`genForNum`), `if … as` captures (`genIsCaptureThen`), and
  `branch … on V as r` captures (`genBranchTagged`) — so all shadow a same-named
  module var instead of being mis-prefixed.

Known minor limitation (selfhost only; the bootstrap is sound per-reference): a
binding's local-name entry in `infer_ctx` is not scope-popped, so within ONE
method a module-var reference that appears *after* a block/loop binding the same
name would be treated as the local. Pathological (a method using both a module
var and a same-named local in disjoint scopes); not seen in the corpus.

Verified: `test/module_var_collision_test.zbr` (preamble-name collision +
plain-local shadow) and `test/module_var_shadow_test.zbr` (for-in / for-num /
if-capture shadows, module vars untouched). Round-trip byte-identical; smoke
158/158.

### Original report (for context)

Module-level `var`/`const` (shipped 2026-06-21, commit 08802f6) emit as bare
file-scope `pub var`/`pub const NAME`. Zig **forbids any function-local or
parameter from shadowing a file-scope declaration**, so a module var whose name
matches *any* identifier used as a local/param anywhere in the emitted file
fails to compile with `local … shadows declaration of 'NAME'`. Two collision
sources:

1. **Runtime preamble** — uses many short/common local & param names. Observed:
   a module `var total` collides with a datetime helper's `const total`, the
   `_progress_bar(total: i64, …)` parameter, *and* a `var total` local — three
   hits from one name. `g`, `s`, `c`, `i`, `node`, `out`, `count`, `label`,
   `config`, `enabled`, `player` … are all landmines.
2. **User's own locals** — a user function declaring `var count` when a module
   `var count` exists is also rejected (same Zig shadow rule).

**Why not fixed in-compiler now:** the sound fix is to move user module vars out
of bare file scope — emit them inside a container struct
(`const _M = struct { pub var total: i64 = 0; };`) and rewrite references to
`_M.total`. The **bootstrap** (`src/`) can do this soundly because the resolver
binds each ident to its declaration (`DeclVar.is_top_level`), so `genIdent`
knows per-reference whether a `total` is the module var or a shadowing local.
The **selfhost** codegen has **no general local-name set** (only typed-local
sets: `strset_locals`, `chan_locals`, …), so it cannot disambiguate a module-var
reference from a same-named local without new local-name tracking on the hot
`genIdent` path. That makes the guard a medium, two-compiler change with several
round-trip gate cycles — deferred while the parallel Zig-0.17 work is in flight.

**Interim mitigation (in use):** the GameEngine Luau→Zebra translator
(`tools/luau2zebra_ast.py`) emits module vars with a reserved prefix
(`_mod_<name>`) for both the declaration and every reference it generates, and
never emits a shadowing local — fully sound for generated code, zero compiler
risk.

**Fix when picked up:**
- `src/CodeGen.zig` — emit module vars in a `_M` container struct (or a reserved
  prefix); `genIdent` already has `is_top_level`, so reference rewriting is local.
- `selfhost/CodeGen.zbr` — same container/prefix emit in `genFieldDecl`
  (owner == "" path) and `genIdent`, **plus** a `method_local_names: StrSet`
  threaded through the generator (reset per method, populated by
  `genLocalVar`/params/for-binds/captures) so `genIdent` only prefixes a name
  that is a module var **and not** a shadowing local.
- Add a smoke fixture: a module var named after a known preamble local (e.g.
  `total`) that compiles and runs.

**Discovered:** 2026-06-21, immediately after shipping module-level var/const
(Stage 1). Probe: `var total = 0` at module scope + any function → shadow error.

---

## BUG-136: `zebra file.zbr` run path captures child stdout instead of streaming

**Severity:** low (UX / capability — affects interactive programs, not
correctness of batch programs)
**Status:** OPEN — known limitation, decision pending (fix vs. leave as-is).

When `zebra file.zbr` runs a program, the selfhost driver
(`selfhost/main.zbr`) invokes the child via `sys.run(argv)`, which **captures**
the child's stdout/stderr into strings and prints them *after* the child exits
(`Terminal.write(rr.stdout, "")` / `sys.err(rr.stderr)`). The Zig-side
bootstrap (`src/main.zig`) does the same on its non-fast path (`runChildRemapped`
captures stderr for source-map remapping). Consequences:

- **No streaming** — output appears all at once when the program finishes, not
  as it is produced. A long-running program looks hung until it exits.
- **No interactivity** — a program that reads stdin or expects a live TTY
  (prompts, REPL-like loops, progress bars) won't work, because the child's
  stdio is piped, not inherited.

This is **pre-existing**, not introduced by the debug-run fast path (2026-06-20,
commit f9a05d1): the fast path's exec step (`sys.run([fast_exe])`) merely follows
the same capture convention the LLVM `zig run` path already used, so behavior is
unchanged either way. The fast path's *build* step legitimately needs capture
(to inspect exit code for fallback); only the *exec* step is the candidate to
change.

**Why it's not obviously a bug:** capture is *required* on the Zig backend's
LLVM path so stderr can be run through `remapZigErrors` (rewrites generated-`.zig`
line numbers back to `.zbr` source lines). Streaming would lose that remapping
for compile-time errors — though for the **fast-path exec** step the child is a
user program (its stderr is the program's own output / panic trace, not Zig
compiler errors), so inheriting stdio there is safe and would restore both
streaming and interactivity for the common debug-run case.

**Possible fixes (decide later):**
1. Fast-path exec only: spawn `fast_exe` with inherited stdio (needs a
   `sys.runInherit`-style API in the selfhost runtime; the bootstrap already has
   `runChild` with inherited stdio — `src/main.zig`). Scoped, low-risk; fixes the
   common case without touching the error-remapping path.
2. General: detect "is this a run (not compile-error) context" and inherit stdio
   for the program while still capturing the compiler's own diagnostics
   separately. More invasive.

Repro: a `.zbr` that prints in a loop with a sleep between lines — under
`zebra file.zbr` nothing appears until it exits.

## BUG-135: non-deterministic source-path markers in emitted .zig

**Severity:** low (cosmetic — affects only the `// Source:` / `// zbr:file:line`
comment markers — but it makes regenerated artifacts differ run-to-run, which
is what makes `update-selfhost` show a spurious diff)
**Status:** FIXED. Slash axis: source-fixed 2026-06-17 (`writePathFwd` /
`fwdSlashes`). Case axis: eliminated 2026-06-18 by the PascalCase file rename —
every `.zbr`/`.zig` pair now matches case, so there is no mismatch for MSYS to
mangle. Artifacts refreshed to the bootstrap canonical; regen is idempotent.

Emitted markers echoed the *verbatim* input path. On Windows + Git Bash, MSYS
argument mangling rewrites the `.zbr` path passed to the compiler
**non-deterministically** — sometimes `selfhost/codegen.zbr`, sometimes
`selfhost\codegen.zbr` (slash), and for the `parser`/`resolver` files whose
`.zig` artifact is capitalized but `.zbr` source is lowercase, sometimes
`parser.zbr` vs `Parser.zbr` (case). So two regen runs of the *same* file could
differ in hundreds–thousands of marker lines with no semantic change.

Fix (slash axis, both compilers): `src/CodeGen.zig` `writePathFwd` + `selfhost/
codegen.zbr` `fwdSlashes` normalize the marker path to forward slashes at emit
time, so the slash is deterministic and portable regardless of how the shell
passes the path. The **case** axis (parser/resolver) is *not* addressed — it is
rooted in the intentional `parser.zbr` → `Parser.zig` naming (the `.zig` mirrors
the hand-written `src/Parser.zig`, and is cross-imported by that capital name in
`build.zig` and many emitted files). Eliminating it would require a coordinated
rename, so it is left for the artifact-refresh pass, which is best run on a
case/slash-stable environment (Linux/CI) where neither axis is mangled.

Note: a single `selfhost/X.zig` cannot be regenerated in isolation — emit shape
(root vs dep, e.g. the aggregated `_zbr_error_msg`) differs and mixing shapes
crashes at runtime (see `tools/bootstrap_check.sh` header). The whole set must
be regenerated together (`update-selfhost`).

---

## BUG-134: bootstrap rejects re-exported cross-module type identity

**Severity:** medium (a type defined in module C, surfaced through module B's
method return, and re-imported in module A, fails A's return/assign check with
`type mismatch: expected 'T', got 'T'`; selfhost accepts it, so the compilers
diverge)
**Status:** FIXED 2026-06-17. `src/TypeChecker.zig` `isAssignable` now treats two
`cross_module` types as assignable when their `type_name` matches, regardless of
the `.module` label — cross-module type identity is by name (the type is the same
re-exported Zig declaration at every hop), with Zig as the backstop. This mirrors
the selfhost's `typesCompatible`, which returns `true` for any non-primitive pair.
`Type.eql` is left unchanged (it still requires module+name for cross_module
identity, so generic-arg/identity comparisons elsewhere keep their strictness);
only the assignment/return-check path is loosened.

Surfaced by GameEngine `instance.zbr`: `World.getSize(): Vector3?` (World in the
`ecs` module, `Vector3` re-exported there from `math`) returns a value the
bootstrap labeled `ecs.Vector3`, while `instance.zbr`'s declared return `Vector3`
resolved to `math.Vector3` — same Zig type, different `.module` label, so
`Type.eql` rejected `return s`. This was only *reachable* after BUG-133 stopped
stripping the optional. Regression: `test/crossmod_optret_*` is a 3-module
re-export chain (geom defines Vec3 → lib's `World.getSize(): Vec3?` → test
re-imports Vec3 and returns the unwrapped binding). With both fixes,
`instance.zbr` compiles under the bootstrap and the selfhost.

---

## BUG-132: bootstrap `genIf` panics on `else if <call> as <bind>`

**Severity:** low (codegen crash on a specific else-if shape; workaround =
nested `else { if … as … }`)
**Status:** FIXED 2026-06-17 — `src/CodeGen.zig` `genIf` now routes every clause
(head + each else-if, in both the capture-headed and plain-headed paths) through
a new `genIfCaptureClause` helper that decides the clause form (union-variant
check / optional unwrap / plain) from *its own* condition. Clauses in one chain
may now mix forms freely. This brings the bootstrap up to the **selfhost**, which
already factored this into `genIsCaptureThen` (so this was a bootstrap-only
divergence — no selfhost change needed). Regression: `test/if_unwrap_test.zbr`
extended with three mixed-chain cases (union-head+optional-elseif,
optional-head+union-elseif, plain-head+optional-elseif).

`src/CodeGen.zig` `genIf` (~9640) read `ei.cond.type_check` for an `else if`
condition, assuming the `is X as y` form — but an else-if whose condition is an
**optional-unwrap on a call** (`else if structNameFromType(et) as snm`) has an
active `.call` union field, so it panicked: `access of union field 'type_check'
while field 'call' is active`. The first `if … as …` (non-else) handled this
correctly; only the `else if` path assumed type_check.

---

## BUG-133: bootstrap strips `?T` from cross-module method returns

**Severity:** medium (a cross-module method declared `: T?` is inferred as `T`
by the bootstrap TC, so `if x as n` on its result errors; selfhost handles it,
so the two compilers diverge — this is §27c)
**Status:** FIXED 2026-06-17 (§27c). `src/TypeChecker.zig` now records an
`optional_method_returns` set on `ModuleInterface` (parallel to the existing
`optional_ref_fields`): when a public method's declared return is `T?` for a
user-defined `T`, its `"Type.method"` key is recorded. The three cross-module
method-return consumption sites build the result via a new
`crossModuleMethodReturnType` helper that re-wraps the `cross_module` type in
`.optional` when the key is present. `src/main.zig`'s `cloneInterface` and the
empty/cycle interface mirror the new field. Regression:
`test/crossmod_optret_test.zbr` (+`_lib`) exercises `if w.getSize() as s` across
a module boundary.

Root cause: `simpleTypeFromRef` collapses `nilable(<user-type>)` to `.unknown`
(since user types don't cross the arena boundary), and `instance_method_return_types`
only stored the bare type *name* (`namedTypeStr` unwraps the nilable), so the
optionality was lost. The **selfhost** stores the full `Type_` (via `typeFromRef`,
which maps `nilable → optional`), so it never had the bug — this was bootstrap
catch-up. GameEngine `instance.zbr` (cross-module `World.getSize(): Vector3?`,
`getTransform(): CFrame?`) now compiles under both compilers.

---

## BUG-131: inline capture-lambda to a `sig` param triple-emits the anon struct

**Severity:** medium (blocked the natural inline `signal.connect(def() capture
… )` idiom — the common Roblox `:Connect(function() … end)` shape)
**Status:** FIXED 2026-06-16 — both compilers now emit the closure value ONCE
into `_zbr_val_N` and derive the create's `@TypeOf` + the assignment from that
local, so they share one type.  (The dispatcher still re-derives its type — it's
a nested fn that can't see the local — but it only reinterprets a type-erased
pointer between layout-identical structs, which is sound.)  Round-trip
byte-identical, smoke 152/152.  Verified: inline `signal.connect(def() capture
…)` compiles and runs.  Discovered 2026-06-16 (GameEngine TweenService.Completed).

`emitCallWithClosureThunks` (the Gap-1 closure-via-sig path) emits the closure
value `genExpr(a.value)` **three times** — inside `@TypeOf(...)` for the
`_allocator.create`, in the `_zbr_cls_N.* = …` assignment, and inside the
dispatcher's `@TypeOf(...)`.  For an **inline** capture-lambda each emission is
a distinct anonymous `(struct {…}{…})` literal, and Zig gives each its own
type, so:

```
const _zbr_cls_1 = _allocator.create(@TypeOf((struct {…}))) …;  // *T1
_zbr_cls_1.* = (struct {…});                                    // T2 != T1  ← error
```

→ `error: expected type 'main__struct_60370', found 'main__struct_60375'`.

**Why it's been latent:** the **ident-bound** form
(`var f = def() capture …; sig.connect(f)`) works, because all three emissions
are the same named variable `f` (one type).  Gap-1 / BuildingTest used that
form, so the inline form was never exercised.  (thread_pool's earlier
anon-struct error was the *same* root cause, masked once BUG-128 stopped it
thunking `submit` at all.)

**Repro:** `signal.connect(def() capture { var x = x }; …)` — any inline
capture-lambda passed to a `sig`-typed parameter.

**Fix applied:** bind the closure value to a local `const _zbr_val_N = <closure>`
once, then `create(@TypeOf(_zbr_val_N))` + `_zbr_cls_N.* = _zbr_val_N`.  This is
the minimal change that fixes the create-vs-assignment type clash (the two
checked, same-scope emissions).  The dispatcher keeps its independent
`@TypeOf(<re-emit>)` — it can't see the local — but it only `@ptrCast`s the
type-erased pool pointer and the structs are layout-identical, so the round-trip
is sound.  A fuller fix (a container-scope named type shared by all three) was
considered but not needed for correctness; the stability-minimal change was
chosen.

---

## BUG-130: ~~methodMutatesSelf marks some non-mutating methods `*self`~~ NOT-A-BUG

**Status:** CLOSED — NOT-A-BUG 2026-06-16.  Misfiled.  The compiler does **not**
auto-analyze mutation; `genMethod` gates `self: *const Owner` purely on the
explicit `@pure` modifier (`src/CodeGen.zig` ~5018: `if (n.mods.pure) "*const "
else "*"`).  The observed inconsistency was a **source** gap: GameEngine's
`Vector3.lerp` was marked `@pure` while the identical `Color3.lerp` /
`Vector2.lerp` were not.  Resolved by adding `@pure` to those methods in the
GameEngine `zbra/math.zbr` (engine commit 935f0de); the `lerpProperty`
mutable-local workaround was dropped.  No compiler change.

(Original misfiling retained below for context.)

**Severity:** low — discovered 2026-06-16 (GameEngine property-reflection work).

`Color3.lerp` and `Vector2.lerp` emit `pub fn lerp(self: *Color3, ...)` while
`Vector3.lerp` — with a structurally **identical**, non-mutating body (returns a
fresh struct built from `self`'s fields, no field writes) — correctly emits
`pub fn lerp(self: *const Vector3, ...)`.  The Gap-2 `@pure`/methodMutatesSelf
analysis (commit 1757706) is therefore inconsistent: it proves Vector3.lerp pure
but not the identical Color3/Vector2 versions.

**Symptom:** calling the method on a value bound from a union variant (`if x is
U.col as c` → `c` is `*const`) fails to compile: `expected type '*math.Color3',
found '*const math.Color3'`.

**Repro:** GameEngine `zbra/math.zbr` Color3.lerp vs Vector3.lerp; see
`zbra/instance.zbr::lerpProperty`, which works around it by copying the receiver
to a `var` local.

**Likely cause:** the analyzer's mutation walk over the method body is
order/shape-sensitive (e.g. treats the `Color3(...)` constructor-from-`.r/.g/.b`
differently than `Vector3(...)` from `.x/.y/.z`), or short-circuits on the first
type and doesn't re-run identically per type.  Fix: make the purity walk
structural so identical bodies yield identical `*const` decisions.

---

## BUG-125: selfhost --emit-zig user-script mode emits cross-module union ctors as tag-calls

**Severity:** medium (blocks user scripts from constructing ECS Components directly)
**Status:** FIXED 2026-06-09 — selfhost now honors `--module-path`; deps found
there are parsed for types only (not emitted), so exposed cross-module unions
classify correctly.  Root cause: `compileDep_use` only searched the source's
own directory, so `use ecs` from `game/scripts/` never parsed `zbra/ecs.zbr`
and `dep_types` never learned `Component` is a union.  Fix: `MultiCompiler`
gained a `module_path` field + `scanDepForTypes` (parse + `populateModuleTypes`,
no emit), wired through `--module-path`.  The bootstrap already handled this;
this brought the selfhost to parity.  `tools/wire_script.py` now passes
`--module-path <engine>/zbra`.  Verified: `Component.anchored(true)` →
`Component{ .anchored = true }`.

**Follow-up 2026-06-09:** `scanDepForTypes` also now registers the dep's
class names in `dep_class_names`, so a script that stores a cross-module
class instance in a field or capture (e.g. `var t: Vector3Tween`) emits the
field/param as `*T` (reference type) instead of by-value — without this,
storing the constructor result (`*Vector3Tween`) into a value-typed field is
a `*T`-vs-`T` mismatch.  Consequence: scripts compiled with `--module-path`
now take their class-typed `main(...)` params by pointer (`*Instance`,
`*RunService`), so the host dispatch passes `inst`/`run` directly rather than
`inst.*`/`run.*`.  Pre-`--module-path` scripts (value params) are unaffected.

**Symptom:** In a `.zbr` file under `game/scripts/` compiled via `zebra.exe --emit-zig`, calls of the form `Component.transform(cf)` (where `Component` is a cross-module union imported via `use ecs exposing Component`) emit literally as `Component.transform(cf)` in Zig — which the Zig compiler rejects with:

```
error: type '@typeInfo(ecs.Component).@"union".tag_type.?' not a function
```

The correct emit, observed for the SAME pattern in stdlib `.zbr` files (`zbra/physics.zbr`, `zbra/humanoid.zbr` — both `use ecs exposing World, Component`), is `Component{ .transform = cf }`.

**Repro (in `C:\Projects\GameEngine`):**
```zebra
# game/scripts/repro.zbr
use ecs exposing Component, World

def main(world: World)
    var cf = ...
    world.addComponent(eid, Component.transform(cf))   # → broken Zig in --emit-zig
```

Failure persists across: nested call args, ident-bound vars, staged locals, and helper-wrapped return statements. The discriminator is *where the .zbr lives* (script vs stdlib), not the syntactic shape.

**Workaround:** Hide the union ctor behind a stdlib method. See `zbra/workspace.zbr`'s `spawnBox` / `setEntityPosition` (and `zbra/workspace.zig` hand-impl) for the pattern used by `game/scripts/orbit_follower.zbr`.

**Discovered:** OrbitFollower case study (4th hand-ported script), 2026-06-09.

---

## BUG-126: Gap 1 closure-via-sig thunk uses per-call-site state slot (last-wins)

**Severity:** medium (blocks two scene instances of the same script that share a `connect()` call site)
**Status:** FIXED 2026-06-09 — replaced the single module-level state slot per
call site with a **trampoline pool** of K=64 (state slot, thunk fn) pairs.
Each connection reached at a call site grabs the next free slot via a
monotonic `_zbr_next_N` counter and is handed a distinct `_zbr_thunks_N[slot]`
fn-pointer bound to its own `_zbr_state_N[slot]`.  A bare Zig fn-pointer
carries no context, so K distinct code addresses are fundamentally required;
the pool bounds concurrent connections at one call site.  Overflow (>K live
connections through one source line) panics with a clear message rather than
silently dropping earlier connections (the old last-wins behaviour).  Fixed in
both `src/CodeGen.zig` (flushPendingThunks + emitCallWithClosureThunks) and
`selfhost/codegen.zbr`; round-trip clean.  Verified: the OrbitFollower
two-instance scene now ticks Follower1 AND Follower2 independently (was
Follower2 only).  **Remaining limitation:** `_zbr_next_N` is monotonic, so
connect/disconnect churn leaks slots; and K is a hard ceiling.  A truly
unbounded fix needs the `sig` ABI to carry a context pointer (fat pointer) —
deferred until a use case needs >64 live connections or dynamic disconnect.

**Symptom:** Each call site that connects a closure to a `sig`-typed signal handler synthesizes a single module-level state cell (`_zbr_state_N: ?*anyopaque`). When the same `connect()` call is reached twice in one program execution (e.g. two scene instances of the same script), the second call overwrites the cell. The first closure is orphaned — its `Heartbeat`/`RenderStepped` handler never fires again, even though the connection appears successful.

**Repro (in `C:\Projects\GameEngine`):** `game/scripts/orbit_follower.zbr` loaded twice as `Follower1` and `Follower2` in `demo_scripts.zbr-scene`. Both `[orbit_follower:FollowerN] connected` messages print; only Follower2's tick lines appear thereafter. Confirmed visually: Follower1's spawned cube sits stationary at its initial position; Follower2's cube orbits.

**Fix direction:** Have `signal.connect(handler)` return a connection ID and have the thunk store a *map* of state cells keyed by ID, rather than a single slot per call site. Existing single-subscriber Roblox-style code stays correct; multi-subscriber works.

**Discovered:** OrbitFollower case study, 2026-06-09. Flagged as unverified concern in the TimerTest case study (`docs/TIMER_TEST_CASE_STUDY.md`); empirically falsified by the OrbitFollower two-instance scene.

---

## BUG-127: selfhost emits negative-literal `var` initializer without type annotation

**Severity:** low (annotation workaround is trivial)
**Status:** FIXED 2026-06-09 — `genLocalVar`'s literal-shape annotation branch
now handles `Expr.unary` (neg of int/float literal), emitting `: i64`/`: f64`
like the bare-literal case.  Used `branch un.operand` (not `is`) so the `^Expr`
deref round-trips identically under bootstrap and selfhost.  Verified:
`var a = -6.0` → `var a: f64 = (-6.0);`.

**Symptom:**
```zebra
var x = -6.0   # emits: var x = (-6.0);  → Zig: comptime_float not const/comptime
var y = 0.0    # emits: var y: f64 = 0.0; (correct)
```

Positive literal initializers widen to `f64`; negative literals (unary minus) emit as a bare comptime expression that Zig rejects when the binding is `var` rather than `const`.

**Workaround:** Annotate explicitly: `var x: float = -6.0`.

**Discovered:** OrbitFollower case study, 2026-06-09.

---

## BUG-128: Gap 1 thunk path over-applies to `sys.go` / `ThreadPool.submit`

**Severity:** high (broke two shipped 1.0 concurrency features — `Chan`+`sys.go`, `ThreadPool` — for closure arguments, in *both* compilers)
**Status:** FIXED 2026-06-16 — `genCall`'s Gap-1 gate routed *any* call with a
closure argument into `emitCallWithClosureThunks`, before the `sys.go`
(`_sys_go`) and `ThreadPool.submit` handlers could run.  Those consumers take
the closure *struct* directly via `anytype` dispatch, but the thunk path handed
them a bare fn-pointer and emitted the callee verbatim (`sys.go(...)` →
undeclared `sys`; `pool.submit(thunk)` → anon-struct type-identity mismatch).

**Root cause:** introduced by BUG-126 (commit 48a3aad).  The Gap-1 thunk exists
only to satisfy bare `sig` fn-pointer parameters, but the gate never checked
that — it fired on the mere presence of a closure arg.

**Fix:** a *negative* gate (`callNeedsClosureThunks` /
`isStdlibClosureStructConsumer` in both `src/CodeGen.zig` and
`selfhost/codegen.zbr`): thunk every closure arg EXCEPT those passed to the two
stdlib closure-struct consumers (`sys.go`, `<pool: ThreadPool>.submit`).  In
Zebra *user* code a closure value can only be typed through a `sig` param (no
user-writable `anytype`), so this never un-thunks the cross-module `sig` case
(`Signal.connect`) that Gap 1 exists for — verified with an isolated
cross-module repro (`evt.connect(closure)` → `evt.connect(_zbr_thunks_1[...])`).

**Discovered:** WIP-branch merge gate (`chan_thread_test` + `thread_pool_test`
smoke failures), 2026-06-16.

---

## BUG-129: bare `Atomic.add(...)` statement misses the `_ =` discard (bootstrap TC)

**Severity:** medium (any `Atomic(int).add/sub/swap/load` used as a bare
statement fails to compile under the bootstrap compiler — Zig "value of type
i64 ignored")
**Status:** FIXED 2026-06-16 — pre-existing, independent of BUG-128 (fails even
at top level, not just in closures).  `src/TypeChecker.zig` had no `Atomic`
inference, so `counter.add(1)` typed as `.unknown`, and the CodeGen discard rule
(`t != .void_ and t != .unknown`) skipped the `_ =`.  `atomic_test` only passes
because it captures every non-void return (`var old: int = counter.add(3)`).

**Fix:** `atomicElemType` + an Atomic arm in `inferCall` (`add/sub/swap/load` →
element type `T`, `cas` → bool, `store` → void).  The selfhost already handled
this in codegen via `atomic_locals` (the `inferExpr`-can't-see-Atomic
workaround); its method set was widened to `{add,sub,swap,load,cas}` to match
the bootstrap so both compilers emit the discard identically.

**Discovered:** unmasked by the BUG-128 fix while greening `thread_pool_test`,
2026-06-16.

---

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

### BUG-111: ✅ NOT-A-BUG 2026-05-05 — compound assign already works

Verified in both backends: `.count += 1`, `this.count += 1`, and
`obj.count += 5` all parse, codegen, and run correctly. The original
filing was based on a repo-wide grep finding "zero occurrences" of
`this.X +=`, but that turned out to be stylistic legacy (selfhost
authors used the verbose `this.X = this.X + 1` form before `.field`
shorthand was canonical), not a compiler limitation.

Closing as not-reproduced. No code change needed for BUG-111.

---

### BUG-111 (original entry, retained for context):
- **Severity:** Low (workaround is verbose but correct)
- **Status:** Open — phase 0.13 syntax-cleanup window
- **Symptom:** `this.pos += 1` and (after style-guide adoption) `.pos += 1` either fail to parse or fail to codegen. Verified via repo-wide grep: zero occurrences of `this\.\w+ \+=` exist in any `.zbr` file across selfhost, test, or examples — confirming users have learned to avoid the form. The workaround in current code is `this.pos = this.pos + 1`.
- **Reproducer:**
  ```zebra
  class Lexer
      var pos: int
      cue init()
          pos = 0
      def advance()
          .pos += 1     # expected: codegen `self.pos += 1`
  ```
- **Why it matters now:** the style guide (see `STYLE_GUIDE.md` §13.1) has flagged the verbose form as compiler-driven, *not* canonical. When this fixes, the sweep is one grep across selfhost.
- **Fix sketch:** investigate whether the parser admits compound-assign on a member-access LHS, then whether codegen emits the correct shape. Likely a 1-line parser fix + codegen verification.
- **Discovered:** 2026-05-04 during style guide drafting.
- **Source:** `STYLE_GUIDE.md` §13.1.

---

### BUG-112: ✅ FIXED 2026-05-05 — no-paren shorthand removed

Grammar rule removed from both `src/Parser.zig` and `selfhost/parser.zbr`.
38-site sweep (`def name: T → def name(): T`) across 17 files completed.
Bootstrap 5/5, smoke 43/43. See commits `2f7e767` + `598a533`.
Migrated to FixedBugs.md.

---

### BUG-112 (original entry, retained for context):
- **Severity:** Low (cosmetic; both forms work today)
- **Status:** Fixed 2026-05-05
- **Symptom:** `def name: T` and `def name(): T` are both legal and equivalent. Callers always write `obj.name()` regardless. The no-paren form is a vestige of the removed `prop`/`get`/`set` machinery (per `project_remove_property_keywords.md`) — it survives but no longer carries weight, and visually contradicts the call-site syntax (footgun: reads as a getter that doesn't need parens at the call site, which isn't true).
- **Repo data:** 38 no-paren occurrences across 17 files; 124 explicit-paren occurrences across 25 files. The repo's revealed preference is `def name(): T`.
- **Fix sketch:**
  1. Sweep the 38 no-paren declarations to `def name(): T` form (mechanical).
  2. Remove the no-paren rule from `parser.zbr` and `src/Parser.zig` so it can't drift back in.
  3. Tokenizer / TC unaffected — they already canonicalise both.
- **Discovered:** 2026-05-04 during style guide drafting.
- **Source:** `STYLE_GUIDE.md` §1 Q2.

---

### BUG-113: ✅ NOT-REPRODUCED 2026-05-05 — slice TC works correctly

Verified: `var text = src[0..3]` correctly types `text` as `str` and
`text.toFloat()` dispatches correctly without an explicit `: str`
annotation.  Both forms (annotated + bare) produce identical output.

The original `pratt_calc.zbr:134` author comment described a real
limitation at the time it was written, but the TC has since improved
(possibly via the BUG-099 work that made type inference more
disciplined, or via earlier inferenceupdates).  The annotation in
pratt_calc is now redundant but harmless — left in place.

Closing as not-reproduced.

---

### BUG-113 (original entry, retained for context):
- **Severity:** Medium (forces explicit annotations downstream of any string slice)
- **Status:** Open — TC inference gap
- **Symptom:** `var text = this.src[start..pos]` infers `text` as something that doesn't dispatch `.toFloat()` correctly, requiring users to write `var text: str = this.src[start..pos]`. The author of `pratt_calc.zbr` documented this in a comment at line 132–134:
  > "the compiler's TC currently loses the slice's str type once it passes through a `var`, so we annotate explicitly to guide `.toFloat()` to the right dispatch."
- **Reproducer:**
  ```zebra
  def parse(src: str): float? throws
      var text = src[0..3]      # text is inferred as ?
      return text.toFloat()     # may fail to dispatch correctly
  ```
- **Fix sketch:** check `inferExpr` for the slice arm — `str[int..int]` should infer back to `str`. Likely a missing case in either the bootstrap or selfhost typechecker (or both, given parity work).
- **Discovered:** 2026-05-04 during style guide drafting; the workaround is in `pratt_calc.zbr:134`.
- **Source:** `STYLE_GUIDE.md` §13.2.

---

### BUG-114: `0 - x` / `0.0 - x` instead of `-x` — ✅ SWEPT 2026-05-06
- **Severity:** N/A
- **Status:** Closed — sweep complete; no `0 - x` / `0.0 - x` occurrences remain in any `.zbr` file.
- **Source:** `STYLE_GUIDE.md` §13.3.

---

### BUG-115: ✅ FIXED 2026-05-14 — `private` / `internal` visibility keywords shipped

`private` and `internal` keywords implemented and enforced by both compilers:
- **Zig backend (`src/TypeChecker.zig`):** `checkMemberVisibility` at line 2185 checks `mods.private` / `mods.protected`; error if accessed outside the owning class. `extractModuleInterface` already skips `private`/`internal` members from cross-module export.
- **Selfhost (`selfhost/typechecker.zbr`):** `ModuleTypes.private_member_keys: HashMap(str, bool)` reverse index populated by `addClassMembers`; `inferExpr Expr.member` checks `isPrivateMember` and emits `"'X' is private"`.

Original open question (resolved by implementing):
- **Status (2026-05-04):** Design question — add keywords, or drop the `_` convention?
- **Decision (2026-05-14):** Implement keywords. Both backends enforce `private` (per-class) and `internal` (treated as protected/module-scoped). Sweep: `_` convention retained only for compiler-emitted internals (`_allocator`, `_arena`, etc.).
- **Evidence:** NEXT_STEPS.md `[x] BUG-115` entry marked complete 2026-05-14.
- **Source:** `STYLE_GUIDE.md` §1 Q3.

---

### BUG-109: ✅ FIXED 2026-05-05 — `.reuse_address` flipped to `false`
- **Severity:** Medium (footgun for test apps; not a crash, but a "wait, why are four copies running?" surprise)
- **Status:** Fixed — `selfhost/stdlib_preamble.zig` line 525: `reuse_address = true` → `false`.
- **Original description:**
- **Symptom:** The runtime `_http_serve` (emitted by `src/CodeGen.zig`) calls `std.net.Address.initIp4(.{0,0,0,0}, port).listen(.{ .reuse_address = true })`. The `reuse_address = true` setting allows multiple processes to successfully `listen()` on the same port; the OS load-balances incoming connections across them. Concrete observed consequence: 2026-04-21 → 2026-05-04 the box accumulated 4 stray `server_test.exe` processes all coexisting on 8080, undetected until manual `netstat` inspection.
- **Reproducer:** Run `server_test.exe` (built from `test/server_test.zbr`) twice in succession in separate terminals — both bind successfully and both serve traffic. No error from the second bind.
- **Root cause:** `src/CodeGen.zig` emits `.reuse_address = true` unconditionally in the `_http_serve` preamble (line ~459 in current emitted output). The flag is appropriate for fast-restart-after-crash workflows (avoids TIME_WAIT delay) but inappropriate for "did I accidentally start two of these?" detection.
- **Fix sketches (pick one):**
  1. **Flip to `.reuse_address = false`** — simplest; OS rejects duplicate binds. Cost: TIME_WAIT delay if the same port is rebound within ~60s after a clean shutdown. For test apps this is fine; for production restart loops it's friction.
  2. **Make it configurable:** `Http.serve(port, handler, reuse: false)` with a default that we pick. Cost: tiny API change, ripples through codegen.
  3. **Probe-bind hybrid:** keep `reuse_address = true` but also attempt a `Tcp.connect` probe first and refuse if it succeeds. Cost: small race window between probe and bind; doubles the syscall surface.
- **Workaround in use:** `test/server_test.zbr` now does the probe-then-bind dance manually at the user level (see commit 7fe29ae). Every other `Http.serve` caller would have to do the same until this is fixed centrally.
- **Discovered:** 2026-05-04 cleanup of the 4 stray instances.
- **Source:** Side-finding from `test/server_test.zbr` port-busy fix.

---

### BUG-110: ✅ FIXED 2026-05-05 — bind error prints clean message instead of panic
- **Severity:** Low (only triggers on bind failure; rare in practice)
- **Status:** Fixed — `selfhost/stdlib_preamble.zig`: `catch |e| @panic(...)` replaced with `std.debug.print` + `return`. Http.serve remains non-throws (making it throws would ripple into TC/codegen — deferred).
- **Original description:**
- **Symptom:** The runtime `_http_serve` handles bind failure with `... .listen(.{ .reuse_address = true }) catch |e| @panic(@errorName(e))`. On any bind failure (port busy with `reuse_address = false`, permission denied for low ports, address-not-available), the program dies with a Zig panic and stack trace rather than a clean error. Counterpart of BUG-107 (TC halt-on-diagnostics audit) but at runtime: the failure is communicated by panic rather than by the language's structured error path.
- **Reproducer:** With BUG-109 fixed (`reuse_address = false`), running `server_test.exe` twice produces a panic on the second run instead of a clean error message.
- **Root cause:** `src/CodeGen.zig` emits the `catch |e| @panic(@errorName(e))` pattern in `_http_serve`. The right shape is to make `Http.serve` `throws` so callers can `catch |err| { print "Could not bind: ${err}" }`.
- **Fix sketch:** Change `Http.serve`'s declared signature to `throws` (in the typechecker's stdlib bindings); update the emit so the bind error propagates as `anyerror!void` rather than panicking. Callers that don't care can still `Http.serve(...) catch unreachable`. Pairs naturally with BUG-109 — both are policy decisions about how the runtime communicates bind problems.
- **Discovered:** 2026-05-04, alongside BUG-109.
- **Source:** Side-finding from `test/server_test.zbr` port-busy fix.

---

### BUG-099: ✅ FIXED 2026-05-05 — Type three-way split shipped (Zig + selfhost)

**Zig backend (src/TypeChecker.zig):** `.context_dependent` / `.unknown` /
`.unresolved` split. `.unresolved` carries an `Ast.Span` for blame. Alarm bell
fires at `checkVarDecl` expectation sites.

**Selfhost port (selfhost/typechecker.zbr):** Completed 2026-05-06. Three new
`Type_` variants added:
- `context_dependent` — nil literal inner type, `result` outside return context,
  if-capture defaults; resolved by the outer checker.
- `unresolved` — TC failed to infer: ident miss, member miss, call fallback,
  index/slice fallback, expr catch-all.
- `unknown_` — unchanged: intentional opaque cases (`this` outside class,
  loop-var default, `addClassMembers` no-annotation, `unbind` sentinel).

`isAbstractType()` helper mirrors `src/TypeChecker.zig isAbstract()`.
Alarm bell added to `checkVarDecl` behind `ctx.strict` flag (enabled by
`typecheck-merge` subcommand only; safe for normal compilation).
`codegen.zbr` format-spec updated to fall through for all three abstract types.

Verified: bootstrap 5/5 round-trip, 44/44 selfhost smoke, full test suite clean.

See commits 429ff98d → 4c84c51b (Zig) for the audit trail. Migrating to
FixedBugs.md.

---

### BUG-099 (original entry, retained for context):
- **Severity:** High (foundational; gates merge-oracle reliability and is the upstream cause of many silent-accept bugs below)
- **Status:** Open
- **Symptom:** The TC's `Type.unknown` is overloaded across three semantically distinct cases that propagate identically:
  1. **Context-dependent (legitimate):** type depends on usage context (e.g., `nil` literal, `result` reference inside a function whose return type is being inferred).
  2. **Opaque-by-design (legitimate):** the TC genuinely cannot and should not assign a concrete type (e.g., `zig_lit`, opaque cross-module externs, generic type parameters not yet substituted).
  3. **Unresolved (illegitimate):** the TC failed to derive a type it ought to have known (e.g., member access on an unknown object, list literal element-type punted to codegen, cross-module field lookup miss).
  Cases 1–3 all return `.unknown`. Downstream rules like "RHS of `var x: int = expr` must be `int`-compatible" can't tell case-3 from case-1, so:
  ```zebra
  var x: int = some_undefined_call()   # silently typechecks; RHS infers to .unknown
  ```
- **Reproducer:** `var x: int = NoSuchMethod()` — RHS infers to `.unknown`, no diagnostic emitted.
- **Root cause:** Type union in `src/TypeChecker.zig` collapses three different concepts into one variant.
- **Fix sketch:** Split into three Type variants:
  - `.context_dependent` — propagates without complaint until a concrete-type expectation site supplies a hint
  - `.unknown` — opaque by design; never errors at expectation sites either
  - `.unresolved` — alarm bell; first concrete-type expectation site emits a diagnostic and the value's source span gets the blame
  Audit every site that currently returns `.unknown` and re-classify into the appropriate bucket. Goal state: zero `.unresolved` instances at typecheck completion on a valid program.
- **Why three buckets, not two:** `.unresolved` is the alarm-bell category. Conflating it with `.unknown` (opaque-by-design) means we can't distinguish "the type system is doing its job on opaque externs" from "the TC gave up."  Three buckets makes the second case visible and countable — ideally always zero on accepted programs.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` cross-cutting finding). User-suggested three-bucket taxonomy 2026-05-01.

---

### BUG-100: ✅ FIXED (side-effect of BUG-099, 2026-05-05)
- **Symptom was:** `else => unreachable` panic when `for k, v in <non-var ident>`.
- **Fix:** The BUG-099 three-way Type split rewrote the surrounding TC block; the
  `is_hashmap_two_var` switch now uses `else => null` (line ~1321 current), so
  a method/class/namespace ident simply yields `hm_dt = null` and the loop falls
  through to normal for-in handling — no panic.
- **Verified 2026-05-05:** `for k, v in getMap()` + HashMap two-var smoke pass.

---

### BUG-101: AstBuilder uses `std.debug.panic` instead of diagnostics for parse-tree shape violations
- **Severity:** Low today (only the parser produces trees and it's well-tested) / Critical for VCS-merge-oracle future (operation-patches could synthesize trees)
- **Status:** Open
- **Symptom:** ~20 sites in `src/AstBuilder.zig` use `std.debug.panic` to assert parse-tree shapes (e.g., `:159, 551, 869, 896, 924, 941, 1086, 1589, 1650, 1908, 1928, 2052, 2131, 2169, 2277, 2430` — partial list). Failure mode is hard panic with terse message and no source span.
- **Reproducer:** None today from any well-formed source (they're invariant assertions). But under a future operation-patch VCS where structural edits synthesize trees, every site is a live hazard.
- **Root cause:** AstBuilder predates the Diagnostic infrastructure; these sites were the historical fail-fast paths.
- **Fix sketch:** Long-horizon refactor — fold each panic into the `Diagnostic` system with a "synthesized AST violated invariant X" error class, including the offending parse-tree NT. Short-term: leave alone but document the assumption that only the parser produces trees.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P0-2]).

---

### BUG-102: Selfhost typechecker has 65+ `to!` force-unwraps — audit needed
- **Severity:** Medium (each is a potential panic with no diagnostic; unknown how many are unguarded)
- **Status:** Closed — fixed 2026-05-06
- **Resolution:** Full audit of all `to!` sites in `selfhost/typechecker.zbr`. All 41 sites are now guarded:
  - 20 converted to `if x as v` (idiomatic optional-unwrap) — works for `String?`, `List(Stmt)?`, `Type_?` same-file locals and cross-module fields
  - 21 kept as `if x != nil: ... to!` with `# safe: nil checked above` or `# safe: nil returned above` comment — required for cross-module `TypeRef?` and `^Expr?` fields (bootstrap TC gap: doesn't track these as optional; tracked separately)
  - Zero unguarded `to!` remain
- **TC gap note:** The Zig bootstrap TC (`src/TypeChecker.zig`) does not correctly infer `TypeRef?` and `^Expr?` cross-module field types as optional, causing `if x as v` to fail with "requires an optional type, got 'TypeRef'". This is a pre-existing gap, not introduced by this fix. The safe guarded `to!` pattern is the correct workaround until that gap is closed.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P0-3]).

---

### BUG-103: TC `extractFromDecls`/`extractFromMembers` silently skip unknown declaration variants
- **Severity:** Low (only triggers on adding a new `Ast.Decl` variant; latent reliability hazard)
- **Status:** Closed — fixed 2026-05-06
- **Resolution:** All 4 `else => {}` catch-alls in the metadata-collection passes replaced with fully exhaustive arms listing every `Ast.Decl` variant explicitly. Adding a new `Ast.Decl` variant now causes a Zig compile error at all 4 sites (same guarantee `checkTopDecl` already had). Behavioral change: none — all new arms are `{}`. Bootstrap 5/5, smoke 44/44, full test suite.
  - `extractFromDecls` (4 new arms: `.use`, `.interface`, `.mixin`, `.extend`, `.sig_`, `.var_`, `.init`)
  - `extractFromMembers` (10 new arms: everything except `.method`, `.var_`, `.init`)
  - `collectExtMethodsInDecls` inner switch (extend members: 12 new arms)
  - `collectExtMethodsInDecls` outer switch (top-level decls: 11 new arms)
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-1]).

---

### BUG-104: Unknown `@directive` silently ignored by AstBuilder
- **Severity:** Low (typical case is benign; impacts merge-oracle and forward-compat)
- **Status:** Closed — fixed 2026-05-06
- **Resolution:** `src/AstBuilder.zig` now emits `warning: unknown @-directive '@foo'; ignored` via `std.debug.print` to stderr when an unrecognized `@name` directive is encountered. `selfhost/parser.zbr` emits the same message via `sys.errln`. Compilation continues normally; only the unknown directive is ignored. Bootstrap 5/5, smoke 44/44.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-2]).

---

### BUG-105: ✅ FIXED 2026-05-05 — enum_member/union_variant resolve to parent type

`inferMember` now returns `Type{ .named = parent_sym }` when looking up
an enum member or union variant via member access. `var c: int = Color.red`
correctly errors; `var c: Color = Color.red` typechecks. Test:
`test/bug105_enum_member_test.zbr`. See commit `f254b754`.

---

### BUG-105 (original entry, retained for context):
- **Severity:** Medium (TODO comment in `:2892`; affects type inference for any enum/union expression usage)
- **Status:** Open
- **Symptom:** `src/TypeChecker.zig:2892, 2894` — `Color.red` infers to `.unknown` instead of `.named(Color)`; `Result.ok(...)` similarly. Downstream rules like `var c: Color = Color.red` then can't catch a mismatch because RHS is `.unknown`.
- **Reproducer:**
  ```zebra
  enum Color: red, blue
  var c: int = Color.red    # should error; today silently typechecks
  ```
- **Root cause:** TODO comments in `inferExpr` for these two AST kinds — never wired up.
- **Fix sketch:** Resolve to `.named(parent_enum)` / `.named(parent_union)` from the resolver's symbol info. Becomes much easier after BUG-099 when `.unresolved` is the alarm-bell bucket.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-3]).

---

### BUG-106: ✅ FIXED (partial) 2026-05-05 — literal homogeneity check shipped

`list_lit` / `array_lit` / `dict_lit` now walk elements and require
mutual `isAssignable` for non-abstract element types. Heterogeneous
literals like `[1, "two", 3]` now error precisely at the offending
element's span. Numeric mixes `[1, 2.0, 3]` still pass (untyped-numeric
semantic). Test: `test/bug106_heterogeneous_list_test.zbr`. See commit
`4c84c51b`.

CAST-VALIDITY (2026-05-18): TC check added proactively to both backends —
when source type is numeric/bool/string and target is `.named` (class/struct),
the TC now emits "cannot cast 'int' to class/struct type 'ClassName'" (Zig:
`src/TypeChecker.zig` cast arm; selfhost: `inferExpr Expr.cast` arm).

The check is correct but currently untestable because the `expr to TypeRef`
cast syntax is broken: the selfhost parser only handles `to!`; the bootstrap
AstBuilder panics with "unexpected NT TypeRef" when the grammar produces an
`Expr9 kw_to TypeRef` subtree. The `ExprCast` AST node exists but is never
created in practice. This is documented in `test/bug106_cast_test.zbr`.
Fix will become testable once the cast parser path is wired up.

---

### BUG-106 (original entry, retained for context):
- **Severity:** Medium (silent miscompile potential; merge-oracle blocker)
- **Status:** Open
- **Symptom:** `src/TypeChecker.zig:1705-1707` — `[1, "a"]` (heterogeneous) infers to `.unknown` without complaint. `dict_lit`, `array_lit` similar. Also `.cast` at `:1693` returns the cast target without validating source-type compatibility (`42 as ClassType` typechecks).
- **Reproducer:**
  ```zebra
  var xs: List(int) = [1, "two", 3]   # silently typechecks; RHS is .unknown
  var c: ClassType = 42 as ClassType  # silently typechecks; impossible cast
  ```
- **Fix sketch:** For literals, walk elements and verify common type (or common supertype if subtyping lands). For `.cast`, validate source/target compatibility (numeric→numeric, optional unwrap, named-class downcast).
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-4]).

---

### BUG-107: ✅ VERIFIED 2026-05-18 — codegen never runs on a diagnosed tree

Verified all three entry points halt before codegen when diagnostics are present:

1. **`src/main.zig:396`:** `if (had_error) return 1;` — after collecting `bind.diags`, `resolve.diags`, `tc.diags`. CodeGen is invoked only on the `else` path.
2. **`selfhost/main.zbr:130-132`:** `if tc_ctx.hasErrors()` → `sys.errln(tc_ctx.errorMessages())` → `sys.exit(1)`. Explicit process exit before Step 5 (Zig emit).
3. **`src/Repl.zig:439-443`:** `had_error` checked after `bind.diags`, `resolve.diags`, `tc.diags`; `if (had_error) return null;` before `CodeGen.generate`.

Property holds. No code change needed.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-5]).

---

### BUG-108: ✅ FIXED (partial) 2026-05-05 — `this` outside class diagnostic shipped

`this` outside a class/struct method or `with` block now emits a
defensive diagnostic at the `this` token span: "'this' used outside a
class/struct method or 'with' block". Test:
`test/bug108_this_outside_class_test.zbr`. See commit `01296dbd`.

REMAINING (deferred):
  - inferIdent miss → handled differently via BUG-099 alarm bell
    at expectation sites (commit `60698f6a`).
  - inferMember cross-module miss → softened to `.unknown` to avoid
    false positives on legitimate cross-module patterns (commit
    `4c84c51b`).
  - index/slice on non-indexable, `expr_types.get` fallbacks: have
    legitimate non-error cases (HashMap[k], generic types,
    TC-sequencing internals) where blanket emitError would false-
    positive. Lower priority.

---

### BUG-108 (original entry, retained for context):
- **Severity:** Medium (umbrella for several P2/P3 sites; many become trivial after BUG-099)
- **Status:** Open
- **Symptom:** Multiple sites silently return `.unknown` where a diagnostic should fire if the TC has reached a state it shouldn't have. Each is benign on well-formed code (some other phase caught the error first) but failure-amplifying when the upstream catch is missed.
  - `inferIdent` (`src/TypeChecker.zig:1739-1747`) — resolver miss returns `.unknown` with no defensive `emitError`. If Resolver is buggy, no diagnostic from TC.
  - `inferMember` (`:1749-1768`) — cross-module member-not-found returns `.unknown` silently (`:1767`).
  - `index`/`slice` on non-indexable (`:1678-1690`) — silently returns `.unknown` for `someInt[0]`.
  - `this` outside class context (`:1672-1673`) — silently `.unknown` if `ext_self_type == null and owner_sym == null`.
- **Fix sketch:** Add defensive `emitError` at each site. Most won't fire on well-formed code (other phases caught it); they're insurance. After BUG-099, these all become "if the result is `.unresolved`, emit at this site."
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entries [P2-1, P2-2, P2-3, P3-1]).

---

### BUG-097: ✅ FIXED 2026-05-08 — `*ArrayList` chain call three-case logic
- **Severity:** Medium (any function that takes a List/HashMap as a mutating out-param can't itself call helpers that take that container by value)
- **Status:** Fixed:
  - `src/CodeGen.zig`: added `caller_ptr_params: ?*const std.StringHashMap(void)` field to `Generator`; populated in `genMethod` for non-TCO methods; `argIdentInCpp` helper; three-case logic in both positional and named paths of `genArgs`.
  - `selfhost/codegen.zbr`: `caller_ptr_params: StrSet` field added + initialized; `withMethodCtx` creates fresh StrSet; `genMethod` populates it after `withInferCtx`; `argIdentInCpp` method on `Generator`; three-case logic in `genArgListNamed`, method dispatch named-reorder path, and method dispatch positional path.
  - Test: `test/bug097_ptr_param_chain_test.zbr`; added to `selfhost_smoke.sh`.
  - Bootstrap 5/5.
- **Original description:**
- **Symptom:** With BUG-091's mutation-driven `*ArrayList` conversion, a function signature like `def freeVars(t: Term, out: List(str))` emits `out: *std.ArrayList(...)`. Two follow-on issues then surface in the same body:
  1. **Recursive call:** `freeVars(child, out)` — the call site still emits `&out` (because the formal param is mutating-container), producing `**ArrayList` for an arg expected as `*ArrayList`.
  2. **Helper call:** `hasName(out, name)` where `hasName` takes `out: List(str)` non-mutating (so its sig stays `ArrayList`). The call site emits `hasName(out, name)` with no `.*` deref, producing `*ArrayList` for an arg expected as `ArrayList`.
- **Reproducer:** see `examples/lambda_calc.zbr`'s commit history — the original `freeVars(t: Term, out: List(str))` shape ran into both above; the file was rewritten to return-by-value instead.
- **Root cause:** the `&` insertion in `genArgs`/`genArgListNamed` didn't account for the caller's param already being `*ArrayList`. The decision rule now distinguishes:
  - arg is value, formal is `*Self` → emit `&arg` (original BUG-091 behavior)
  - arg is already `*Self`, formal is `*Self` → emit `arg` (Case 1: no double `&`)
  - arg is already `*Self`, formal is value → emit `arg.*` (Case 2: deref)
- **Workaround (obsolete):** restructure to return-by-value, or thread the container through a class field.
- **Discovered:** 2026-04-30 while writing `examples/lambda_calc.zbr`.

---

### BUG-096: ✅ FIXED 2026-05-07 — `List(SomeClass)()` constructor now pointer-wraps class type args
- **Severity:** Low (only triggers when storing class instances in Lists declared as fields)
- **Status:** Fixed:
  - `selfhost/codegen.zbr genTypeFromExpr`: added `if class_names.contains_(id.name)` check before `zigPrimitive`; emits `"*" + id.name` for class types, matching `genType`'s behaviour.
  - Zig backend (`src/CodeGen.zig genType`) was already correct; this was a selfhost-only gap.
  - Test: `test/bug096_list_class_ctor_test.zbr`; added to `selfhost_smoke.sh`.
- **Original status:** Open
- **Symptom:** `class Holder { var results: List(Result) = ... }` where `Result` is a class. The field type emits as `std.ArrayList(*Result)` (correct — classes are reference-typed), but the constructor expression `List(Result)()` emits `std.ArrayList(Result){}` (without the pointer). Zig rejects the assignment with a type mismatch.
- **Reproducer:**
  ```zebra
  class Result
      var msg: str = ""
      cue init(m: str)
          this.msg = m

  class Holder
      var results: List(Result)
      cue init()
          this.results = List(Result)()      # ✗ field is List(*Result), ctor builds List(Result)
  ```
- **Workaround:** make the element type a `struct` rather than a `class` (the workaround used by `book_run.zbr`'s `Result` type), or assign via `[]` empty-list literal once that path supports class element types.
- **Discovered:** 2026-04-30 while writing `book_run.zbr`.

---

### BUG-094: ✅ FIXED 2026-05-05 — HashMap two-var for-in works in both backends
- **Severity:** Medium (the QUICKSTART-canonical iteration form is unusable; the rest of the book has examples that won't compile)
- **Status:** Fixed:
  - `selfhost/codegen.zbr`: `_ = kname;` discard is now guarded by `nameUsedInStmts`; same guard added for `vname`.
  - `src/CodeGen.zig genForIn`: early dispatch `if (s.vars.len == 2) return genForInHashMap(s)` added before the type-inference path (Zig backend was falling through to native for-loop syntax, causing "extra capture" error).
  - Test: `test/bug094_hashmap_kv_test.zbr` (all 4 k/v used/unused permutations); added to selfhost_smoke.sh.
- **Original description:**
- **Symptom:** Both backends fail on `for k, v in some_hashmap`:
  - **Selfhost (`zebra.exe`):** emits `const name = ...; _ = name;` immediately followed by usage in the loop body — Zig rejects with "pointless discard of local constant ... used here". Even when the discard is suppressed, `print "${name}: ${age}"` falls back to `{any}` for `name` because the formatter doesn't see the `[]const u8` type for the for-binding.
  - **Zig backend (`zebra-bootstrap.exe`):** rejects the syntax outright with "extra capture in for loop" — the multi-binding form was never wired up here.
- **Reproducer:**
  ```zebra
  def main()
      var ages = HashMap(str, int)()
      ages.put("Alice", 30)
      for name, age in ages
          print "${name}: ${age}"
  ```
- **Workaround:** Read values back via `.get(known_key)` for spot lookups; iterate with a parallel `List(str)` of keys when you genuinely need to walk the whole map.
- **Doc claim:** QUICKSTART §10 documents `for k, v in m` as the canonical iteration. Either fix both backends to support it, or amend the doc to point at the working pattern.
- **Discovered:** 2026-04-30 while sweeping the book's Chapter 3 examples for the verbosity rewrite.

---

### BUG-092: ✅ FIXED 2026-05-07 — `var lines: List(str) = s.split(sep)` now auto-collects the iterator
- **Severity:** Medium (typed `split` into a `List` is the obvious idiom; required an obscure workaround)
- **Status:** Fixed:
  - `src/CodeGen.zig genLocalVar`: when the declared type is `List(str)` and the init expr is a `split` call, the emitter now wraps the `SplitIterator` in a `std.ArrayList` collector loop automatically.
  - `selfhost/codegen.zbr genLocalVar`: same collector inserted in the selfhost path.
  - Test: `test/bug092_split_to_list_test.zbr`; added to `selfhost_smoke.sh`.
- **Original symptom:** `var lines: List(str) = s.split("\n")` emitted the raw `SplitIterator` into the `ArrayList` slot, causing a Zig type mismatch at compile time.
- **Discovered:** 2026-05-06 during stdlib `str` smoke pass.

---

### BUG-091: ✅ FIXED 2026-05-07 — `List`/`HashMap` params mutated inside body now emit `*ArrayList` and call sites take `&`
- **Severity:** High (List/HashMap mutation via methods like `.add()` silently had no effect on the caller's copy)
- **Status:** Fixed:
  - `src/CodeGen.zig`: param declared `List(T)` or `HashMap(K,V)` that is mutated inside the body now emits `param: *std.ArrayList(T)` / `*std.AutoHashMap(K,V)`; call sites pass `&arg`.
  - `selfhost/codegen.zbr`: same mutation-analysis pass + `&` insertion in `genArgs`/`genArgListNamed`.
  - Tests: `test/bug091_list_param_test.zbr`, `test/bug091_dispatch_test.zbr`; both added to `selfhost_smoke.sh`.
- **Original symptom:** `def addTo(items: List(str), x: str): void` emitting `items: std.ArrayList(str)` (value), so mutations never escaped back to the caller.
- **Related:** BUG-097 (follow-on: passing an already-`*ArrayList` arg through a chain still has issues).
- **Discovered:** 2026-05-06 during stdlib smoke pass.

---

### BUG-093: ✅ FIXED 2026-05-05 — `s.len` now emits `@as(i64, @intCast(...))` — returns `int`
- **Severity:** Low (was forcing awkward workarounds; comparisons still worked)
- **Status:** Fixed:
  - `src/CodeGen.zig`: `isStringTypeName(n.name) and prop == "len"` path emits `@as(i64, @intCast(s.len))`.
  - `selfhost/codegen.zbr`: same `@as(i64, @intCast(...))` wrapper in the genMember string path.
  - Test: `test/bug093_strlen_test.zbr` (commit `dbd6fda`); added to `selfhost_smoke.sh`.
- **Original symptom:** `s.len` codegenned as `.len` on `[]const u8` (usize), causing `var n: int = s.len` and `s.len - 3` arithmetic to fail with type mismatch.
- **Discovered:** 2026-04-29 while writing `book_extract.zbr`.

---

### BUG-089: ✅ FIXED 2026-05-08 — mixin method return type correctly inferred; methods emitted into class
- **Severity:** Low (cosmetic — wrong output format; does not affect type-annotated locals)
- **Status:** Fixed:
  - `src/TypeChecker.zig inferMember`: after `own_scope.lookupLocal` misses, iterate `sym.decl.class.adds` and look up each mixin's `own_scope` (resolver populates these). Returns `tc.symbolType(member_sym)`.
  - `selfhost/typechecker.zbr populateModuleTypes`: two-pass fix — pass 1 registers mixins as their own `ClassTypes`; pass 2 merges mixin methods into each class that `adds` them via `addClassMembers`.
  - `selfhost/codegen.zbr genClass`: after own members, iterate `n.mixins`, find matching `Decl.mixin_` in `module_decls`, and call `ig.genMethod` for each mixin method.
  - `selfhost/codegen.zbr count dispatch`: before `.items.len` fallback, check via `inferExpr` if receiver is a class with a user-defined `count()` method — if so, pass through as a normal call.
  - `selfhost/parser.zbr`: added `mixin_: ^PClass` to `PNode` union; `parseMixinDecl()`; `adds` clause parsing in `parseClassDecl`; `mixins: List(str)` field to `PClass`.
  - `selfhost/astbuilder.zbr`: added `buildMixin()`, `PNode.mixin_` dispatch arm, and mixin TypeRef population in `buildClass`.
  - `selfhost/main.zbr`: updated `PClass(...)` constructor call to pass `mixins` field.
  - Test: `test/bug089_mixin_method_test.zbr`; added to `selfhost_smoke.sh`. Bootstrap 5/5.
- **Original description:**
- **Symptom:** Calling a mixin method that returns `str` directly inside `print` emits the bytes as a `[]const u8` integer-array fallback instead of as text.
- **Generated Zig:** `std.debug.print("{any}\n", .{f.hi()});` — wrong format specifier; should be `"{s}\n"`.
- **Root cause:** TC `inferMember` didn't search `adds Mixin` scopes for methods — returned `.unknown`. Also, selfhost didn't parse `mixin` declarations or `adds` clauses at all.
- **Discovered:** 2026-04-28 while spot-verifying QUICKSTART.md examples.

---

### BUG-090: ✅ FIXED 2026-05-08 — `for n in Reflect.fieldNames(obj)` element type is now `str`
- **Severity:** Low (cosmetic; iteration itself is correct)
- **Status:** Fixed:
  - `src/TypeChecker.zig inferForInElemType`: added `Reflect.fieldNames` / `Reflect.fieldTypes` arm alongside `Net.resolve` — returns `.string`.
  - `selfhost/typechecker.zbr isStrListCallExpr`: added `fieldNames` / `fieldTypes` to the member-name check.
  - Test: `test/bug090_reflect_fieldnames_test.zbr`; added to `selfhost_smoke.sh`.
  - Bootstrap 5/5.
- **Original description:**
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
- **Status:** Fixed
- **Symptom:** A method using the `def...catch` form (catch clause attached to the def itself, not a nested try/catch block) with a non-void return type fails to compile. The generated Zig has a `return` inside the success path, an unreachable `break`, then an `if (_try_err_1 != null) return ...;` afterwards — but no return on the path through both blocks where neither error occurred and the success block didn't already return. Zig errors with "function with non-void return type implicitly returns" + "unreachable code" at the orphan `break`.
- **Reproducer:** A `def f(): str` with `var v = try X()` followed by `return "ok"` and a `catch` clause returning `"err"` — see `test/bug088_try_return_test.zbr`.
- **Root cause:** `body_ends_in_break` in `genTryCatch` didn't handle `.return_` as a terminal statement; the orphan `break :_try_blk` was always emitted.
- **Fix:** `genTryCatch` now checks if the last stmt is `.return_`; if so, skips the `break :_try_blk` and emits `unreachable;` after the catch block. Both `src/CodeGen.zig` and `selfhost/codegen.zbr` updated. Also fixed `genBranch` to emit `=> |_| {` for `as _` discard on boxed union variants (was generating invalid `const _ = …`).
- **Discovered:** While writing `contract_result_throws_test.zbr` for the BUG-087 fix.

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

### BUG-119: ✅ FIXED 2026-05-18 — `list_field_names` reverse index in ModuleTypes

`List` fields accessed through function parameters now emit `.items.len` correctly.

**Fix:**
- `selfhost/typechecker.zbr ModuleTypes`: added `list_field_names: HashMap(str, bool)` field (parallel to `hashmap_field_names`), `addListField(name)` + `hasListField(name)` methods; initialized in `cue init()`.
- `selfhost/typechecker.zbr`: added `isListTypeRef(tr: TypeRef): bool` helper (mirrors `isHashMapTypeRef`).
- `selfhost/typechecker.zbr addClassMembers`: after the `isHashMapTypeRef` check, added `if isListTypeRef(v.type_ to!)` → `mt.addListField(v.name)`.
- `selfhost/codegen.zbr`: added `fieldIsList(mt, dep_mt, field_name): bool` helper (parallel to `fieldIsHashMap`); `.len` handler now includes `fieldIsList(.module_types, .dep_types, fn2)` in the `is_list_obj` check.

Test: `test/bug119_list_field_param_test.zbr` (smoke_run: "bug119_list_field_param: OK").
Bootstrap verified: `zig build update-selfhost` + smoke 117/117 passing + bootstrap 5/5.
- **Discovered:** 2026-05-06 while compiling `IDE/ZebraIDE.zbr`.

---

---

### BUG-120: Selfhost codegen `.add()` → `.append()` rewrite fires on class method calls via lowercase variables
- **Severity:** Medium (silent miscompile — method call becomes a list append; Zig rejects with "no field or member function named 'append'")
- **Status:** Fixed 2026-05-07 — see `FixedBugs.md`
- **Symptom:** In `selfhost/codegen.zbr`, the `.add()` → `.append()` heuristic only guards on `isUpperCase(receiver_name)` (capital first letter = namespace/class static call, e.g., `Math.add()`). Lowercase instance variables (e.g., `c: Calc`) are not guarded. So `c.add(2, 3)` where `c` is a `Calc` instance incorrectly emits `c.append(_allocator, 2)`, which Zig rejects.
- **Reproducer:**
  ```zebra
  class Calc
      def add(a: int, b: int): int
          return a + b
  def main()
      var c = Calc()
      var r = c.add(2, 3)   # ← selfhost emits: c.append(_allocator, 2) — WRONG
  ```
- **Root cause:** `codegen.zbr` around line 3949: the guard `isUpperCase(receiver_name)` (BUG-061 fix) protects `ClassName.add()` but not `instance.add()`. A correct fix needs to check the receiver's inferred type — if the receiver is not a List (or HashMap), the rewrite must not apply. This requires InferCtx type tracking at the call site.
- **Proper fix:** Consult `InferCtx` at the `.add()`/`.remove()` etc. call site to confirm the receiver infers to `List(T)` before applying the rewrite. If the receiver is a class instance, skip the rewrite entirely.
- **Workaround:** Avoid naming methods `add` (or any other List-method name: `remove`, `contains`, `get`, `pop`, `insert`, etc.) on user-defined classes when compiling via the selfhost backend. The Zig bootstrap backend is unaffected.
- **Discovered:** 2026-05-07 during `@profile` attribute implementation (test initially used `def add`/`def mul`, which triggered the rewrite; renamed to `addValues`/`mulValues` as workaround).

---

---

### BUG-121: TC diagnostics always report col 0 — span resolution needed

- **Severity:** Low (correct file:line, wrong column — usable but imprecise)
- **Status:** Open — deferred; noted in `checkExpr` with a TODO comment
- **Symptom:** All type-mismatch diagnostics emitted by `checkExpr` and `checkVarDecl` report column 0. The format `file:line:0: error: type mismatch: ...` is technically valid but unhelpful for editors and users.
- **Root cause:** Statement spans record the keyword position (e.g., the `return` token or `var` token), not the expression start. Column within the line is stored as 0 in most spans because the parser does not yet thread byte-offset-within-line into `Span.col`.
- **Proper fix:** Thread a true column (byte offset from start of line) into `Span` during tokenization. The tokenizer tracks `col` via `_col` already in `Lexer.zbr`; it needs to be passed through `PExprId` → `Span` in the ASTBuilder rather than defaulting to 0.
- **Where noted:** `selfhost/typechecker.zbr` `checkExpr` — `TODO BUG-121` comment.
- **Filed:** 2026-05-09

---

---

### BUG-122: Selfhost codegen — `opt_ptr_field_bindings` not seeded for local variables with inferred types

- **Severity:** Low (workaround exists; only hits when a local var holds a struct with `^T?` fields and those fields are accessed via `to!`)
- **Status:** Fixed (2026-05-26) — both sub-problems resolved via `infer_ctx` in `genLocalVar`

#### Background

`opt_ptr_field_bindings` is a `StrSet` on `Generator` tracking `"bindingName.fieldName"` pairs for fields typed `^T?` (optional heap-pointer). The `to_non_nil` (`to!`) codegen handler (codegen.zbr ~line 6245) emits `.?.*` instead of `.?` when the key is present, because Zig needs the extra `.*` deref for pointer fields.

The set is seeded in three places:
- **Named parameters** (line ~2613): at method entry, for each `TypeRef.named` param, scans `opt_ref_fields` for `"TypeName.*"` and adds `"paramName.*"`.
- **`capture` bindings** (line ~4195): when a union arm is bound with `if x is T as cap`, seeds for the variant payload's struct fields.
- **`if x as n` / `if x is T as n` bindings** (line ~5122): same seeding for optional-unwrap and type-check bindings.

**Local `var` declarations are not seeded.** So `var x = someFunc()` where `someFunc` returns `DeclTypeAlias?` does NOT get `"x.constraint"` added to `opt_ptr_field_bindings`, and `x to!.constraint to!` emits `.?` without `.*`, producing a Zig type error (`expected 'ast.Expr', found '*ast.Expr'`).

#### Two sub-problems

**Sub-problem 1 — explicit type annotation** (`var x: DeclTypeAlias = ...`)

When `n.type_` on a `StmtVar` is `TypeRef.named as nt`, the fix is identical to the parameter seeding logic already at line 2613. In `genLocalVar`, after emitting the declaration:

```zebra
if n.type_ is TypeRef.named as nt
    var nt_dot = nt.name + "."
    var orf = opt_ref_fields.items()
    var orfi = 0
    while orfi < orf.count()
        var orf_e: str = orf.at(orfi)
        if orf_e.startsWith(nt_dot)
            opt_ptr_field_bindings.add(makeDottedKey(n.name, extractAfterDot(orf_e)))
        orfi += 1
```

Scope cleanup: `opt_ptr_field_bindings` is reset at method entry (line ~1565: `opt_ptr_field_bindings = StrSet()`), so no per-scope removal is needed for local vars — they live for the method duration and cannot bleed across method boundaries.

This sub-problem is **easy (~1h)** and has no known risks.

**Sub-problem 2 — inferred type** (`var x = someFunc()` where return type is `SomeStruct?`)

The codegen does not currently know what a call expression returns. To seed `opt_ptr_field_bindings` for this case, you need to resolve the return type at the call site.

**Recommended approach:** add a `local_var_types: HashMap(str, str)` (var name → struct type name) to `Generator`. Populate it in `genLocalVar` by inspecting the RHS expression:

- `Expr.call` whose callee is a known function: look up the return type in `module_types` / `dep_types`. The key lookup is `module_types.funcReturnType(funcName)` — this method does not exist yet and would need to be added to `ModuleTypes` in `typechecker.zbr`. It mirrors how `inferExpr` for `Expr.call` already looks up `module_types.methodReturn(...)`.
- `Expr.member_call` (method call): look up via `module_types.methodReturn(typeName, methodName)`, strip `?` if the type is optional, then use the base struct name.

Once `local_var_types` is populated, the `to_non_nil` handler (line ~6245) should additionally check: if `tnn_obj` is in `local_var_types`, get the struct name, form `"structName.memberName"`, and check `opt_ref_fields` directly — eliminating the need for the key to be pre-seeded.

```zebra
# In to_non_nil handler, after the opt_ptr_field_bindings check:
if tnn_obj != nil
    var lv_type = local_var_types.get(tnn_obj to!)
    if lv_type != nil
        var orf_key = makeDottedKey(lv_type to!, tnn_m.member)
        if opt_ref_fields.contains_(orf_key)
            w.emit(".*")
```

**Complexity:** `local_var_types` must propagate into `indented()` child generators (branches, loops, etc.) so bindings declared in an outer scope are visible in inner scopes. The simplest approach is to pass a reference to the parent's `local_var_types` into child generators, or to copy it at `indented()` creation. Since the set only grows within a method and resets at method boundaries, copy-on-enter is safe.

`funcReturnType` on `ModuleTypes` is the new surface that needs implementing in `typechecker.zbr`. It needs to handle: plain functions, methods, and the `?`-strip for optional returns. This is roughly 30-50 lines in `typechecker.zbr` and a corresponding update to `selfhost/typechecker.zig` via `update-selfhost`.

Estimated effort: **~half a day** once sub-problem 1 is done as a warm-up.

#### Current workaround

Extract the code that accesses `^T?` fields into a helper method where the struct is a **named parameter** (not a local variable). This forces `opt_ptr_field_bindings` to be seeded at method entry.

Example: `genTypeAliasConstraint(alias_decl: DeclTypeAlias, ...)` — `alias_decl` is a parameter so `"alias_decl.constraint"` is seeded. See selfhost/codegen.zbr ~line 3557.

#### Files to change when fixing

- `selfhost/typechecker.zbr` — add `funcReturnType(name: str): str?` (or similar) to `ModuleTypes`
- `selfhost/codegen.zbr` — add `local_var_types: HashMap(str, str)` to `Generator`; populate in `genLocalVar`; consult in `to_non_nil` handler; propagate into `indented()`
- `selfhost/typechecker.zig`, `selfhost/codegen.zig` — regenerated via `zig build update-selfhost`
- Add a test: a local var holding a struct with `^T?` field, accessed via `to!`, without extracting into a helper

- **Discovered:** 2026-05-18 during type alias `^Expr?` constraint access in selfhost codegen.

---

### BUG-123: Generated `pub fn main(init: std.process.Init)` shadows user-defined `init` function

- **Status:** Fixed (2026-05-21)
- **Symptom:** An MVU program with `def init(): Model` would fail to compile. Inside the generated `main`, the parameter `init: std.process.Init` shadowed the user's top-level `init` function.
- **Fix:** Renamed the parameter from `init` to `_zinit` in `genMain` in `src/CodeGen.zig` (4 sites) and matching locations in `selfhost/codegen.zbr` (4 sites). Both compilers regenerated. Bootstrap 5/5.

---

### BUG-124: Bootstrap codegen — `^T?` constructor arg boxes as `*?T` instead of `?*T` for value-typed T

- **Severity:** Low (only affects bootstrap compiler for value-typed union/struct `^T?` constructor args; selfhost is correct)
- **Status:** Fixed (2026-05-26) — `genBoxedArgExpr` uses `payload` (nilable-stripped) instead of `inner` for `create()` type; same for same-module union-variant boxing path

#### Symptom

When the bootstrap compiler (`zebra-bootstrap.exe`, the Zig-implemented compiler) generates a constructor call where a `^T?` parameter receives a value-typed union or struct (not a class), it wraps it as `*?T` instead of `?*T`.

Example: `Container(v)` where `Container.opt_val: ^Val?` and `Val` is a union type emits something like:

```zig
// Bootstrap (wrong)
const _bp = _allocator.create(?Val) catch @panic("OOM");
_bp.* = v;  // _bp is *?Val but Container wants ?*Val
```

instead of the correct selfhost output:

```zig
// Selfhost (correct)
const _bv = v;
const _bp = _allocator.create(@TypeOf(_bv)) catch @panic("OOM");
_bp.* = _bv;  // _bp is *Val, then break gives ?*Val
```

#### Root cause

`src/CodeGen.zig` boxing logic for `^T?` arguments. When T is a value type (union, struct, primitive), the bootstrap compiler wraps the whole optional type instead of just T, producing `*?T`. The selfhost `_bx0:` labeled-block approach avoids this by creating a pointer to the concrete value first.

#### Files to change when fixing

- `src/CodeGen.zig` — fix boxing for `^T?` arguments when T is value-typed; use `@TypeOf(value)` or strip the `?` before `create()`
- `src/TypeChecker.zig` — may need `isValueType()` helper to distinguish class (heap-allocated) from value-typed (union/struct/primitive)

#### Discovered

2026-05-26 during BUG-122 testing: `val_test.zbr` (`val_lib.Val` union in `Container.opt_val: ^Val?`) compiled incorrectly through bootstrap.

---

*Last updated: 2026-05-26 — BUG-122 fixed (opt_ptr_field_bindings seeded for local vars); BUG-124 fixed (^T? boxing uses payload not inner); multi-error parse recovery added to both src/ and selfhost/ compilers*
