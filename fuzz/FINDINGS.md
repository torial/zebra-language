# Fuzzer findings

Bugs surfaced by the differential fuzzer (`fuzz/`). Each is a program both
compilers accept but that reveals a codegen/robustness gap. "Shared" findings
(present in *both* compilers — verdict `both-zig-fail`) are robustness gaps, not
equivalence bugs; genuine equivalence bugs show as `run-divergence` /
`zig-diverge-A|B`.

---

## F1 — user identifiers that shadow a Zig primitive type emit invalid Zig  (shared, ✅ FIXED — BUG-162)

**FIXED 2026-07-02, both compilers.** Identifier-position emissions (local
decls, params — including shim/vtable/thunk/lambda glue — expression
references, unused-discards) now route through `emitName`/`zigSafeName`,
which escapes a primitive-shadowing name to `@"name"`. Key property that
made a partial-coverage fix safe: `@"name"` and `name` are the SAME Zig
identifier (escaped spelling, not a rename), so escaping some occurrences
of a legal name never breaks consistency; prefix-concatenated forms
(`_p_*`, `_zbr_mv_*`, `_ttag_*`) keep the bare name — the prefix already
avoids the collision. Known residual (out of scope, rare): `for`/`if-as`
binding names, destructuring names, struct/class field names that shadow a
primitive still emit bare. Regression: `test/fuzz_f1_primitive_names_test.zbr`;
the generator now deliberately names ~10% of locals from a primitive pool
(`PRIM_SHADOW`) to keep the escape differentially tested — 11/40 seeds
carried shadow decls, all `ok`. Smoke 192/192; round-trip byte-identical.

**Original finding:**

**Minimal repro:**
```zebra
def main()
    var i8 = 5
    print("x=${i8}")
```
**Result (both compilers):** `error: name shadows primitive 'i8'` — Zebra emits
the user name `i8` verbatim, which collides with Zig's `i8` integer type.

**Scope:** any identifier that is a Zig primitive/builtin type name —
`i1`..`i65535`, `u1`..`u65535`, `f16/f32/f64/f80/f128`, `bool`, `void`, `type`,
`anyopaque`, `comptime_int`, `comptime_float`, `c_int`/`c_uint`/… . Zebra already
escapes Zig *keywords* in some paths (`_safe_name`-style), but not primitive type
names.

**Fix direction:** in the identifier-emit path (genIdent / genLocalVar / genTopVar
+ param names), escape a name that matches a Zig primitive to `@"name"` (or a
reserved-prefix rename), in both compilers. Add a regression fixture
(`var i8 = …; var f32 = …`).

**Found:** 2026-07-01, first real fuzz run (seeds 0, 5, …). Caught because the
generator originally named loop counters `i{n}`; that's masked in the generator
now, but the compiler gap is real for user code.

**Generator masking (2026-07-02):** all generator prefixes that collide with a
Zig primitive are now avoided — loop counters `i`→`k`, optional-binding names
`u`→`ob` (`u{n}` shadowed `uN`). This was the *sole* remaining source of
`both-zig-fail` noise; masking it lets genuine equivalence divergences surface
cleanly instead of being buried under F1 hits. The **compiler-side** fix (escape
primitive-named identifiers to `@"name"` in both emitters) remains open and needs
a gated session — see fix direction above.

---

## F3 — selfhost omits the numeric type annotation on a mutated comptime-init local  ★ EQUIVALENCE BUG (fixing)

**The fuzzer's first real self-hosting divergence** (verdict `zig-diverge-B`:
the selfhost emit is rejected by `zig`, the bootstrap emit is not).

**Minimal repro:**
```zebra
def main()
    var v = (8 * 2)
    v = v + 1
    print("v=${v}")
```
**Divergence:**
- bootstrap: `var v: i64 = (8 * 2);`  ✅
- selfhost : `var v = (8 * 2);`       ❌ → Zig: `variable of type 'comptime_int' must be const or comptime`

`v` is mutated → emitted as a Zig `var`; its init is a comptime-int *binary op*.
The bootstrap annotates untyped `var`s from the **TC-inferred type**
(`tcTypeAnnotation`); the selfhost's `genLocalVar` only special-cased literal
*syntax* (`int_lit`/`float_lit`/neg-lit), so a binary-op comptime init got no
annotation. (A plain `var v = 5` did not diverge — both annotate the literal.)

**Fix:** `selfhost/CodeGen.zbr genLocalVar` now falls back to the inferred init
type (`lv_infer_t`) for a non-literal numeric init → emits `: i64`/`: f64`,
matching the bootstrap. Regression: `test/fuzz_f3_comptime_local_test.zbr`.
Assigned **BUG-159**.

## F4 — selfhost interpolation used `{}` for non-strings  ★ EQUIVALENCE BUG (fixed, BUG-160)

The fuzzer's **second** self-hosting divergence (verdict `zig-diverge-B`, seen as
a `zig` build timeout on the selfhost emit). Interpolating a non-string with no
explicit spec (`print("${x}")`): bootstrap emits the type-appropriate spec
(`{d}` float, `{any}` List/struct), selfhost hardcoded `{}`. For a List that
`{}` sends Zig's comptime formatter into a blow-up → build timeout; for a float
it's `{}` vs `{d}` (divergent/invalid). Fixed by routing the selfhost's implicit
case through `printFmtSpec` (mirror of the bootstrap's `printFmt`). Regression:
`test/fuzz_f4_interp_fmt_test.zbr`. (Surfaced via the old generator's list
interpolation, before print was restricted to prims — but the bug is real for any
user program interpolating a non-primitive.)

## F5 — generator reassigned an `if x as y` optional-binding capture  (generator bug, fixed)

**Not a compiler bug.** Verdict `both-zig-fail` (`error: cannot assign to constant`)
on a program the generator should never have produced:
```zebra
var v5: int? = 396
if v5 as ob6
    ob6 = 8        # reassigning the narrowing capture
```
An `if x as y` binding is an immutable capture (like Zig's `if (opt) |y|`, which
is `const`); both compilers correctly reject reassigning it. The generator had
added the bound name to its `assignable` pool, so `assign` sometimes targeted it.

**Fix (generator):** mark the `if…as` binding read-only for the duration of its
block via `self._params` — the exact pattern already used for `for` loop captures
(`_params.add(bound)` / `discard` around `gen_block`). Verified seed 9 → `ok`.
This confirms the *language* behavior is correct (immutable narrowing captures);
the finding was pure generator over-generation.

---

## F6 — unused `if x as y` / for-in captures emit payloads Zig rejects  (shared, ✅ FIXED — BUG-164)

**Seeds 3 and 27** (`both-zig-fail`, `error: unused capture`). Probing showed
the gap was total, not shape-specific: NO unused-binding suppression existed
for the `if x as y` statement form (the `_ = b;` suppression seen in the
codebase belongs to `branch` codegen), and the for-in story was a patchwork —
hashmap/tuple/range arms handled it (tuple with two latent flaws: an
under-approximating `nameUsedInStmts` that could produce *pointless*
discards, and ignored where-clause uses), while list/chars/split/bytes/
sqlite arms leaked.

**Fix (both compilers):** `genIfCaptureClause`/`genIsCaptureThen` (all three
arms: union-variant const binding, `is T as`, plain `as`) and a shared
`discardUnusedLoopVars` helper wired into every capture-style for-in arm
emit `_ = v;` when neither the body nor the where-clause provably reads the
binding. `mightUseName` is conservative (true when unsure) — a modelled use
always suppresses the discard, so no pointless-discard risk; the F2 modeling
work (this session) is what makes it precise enough to be useful. Counter
arms (range) skip it — the while-header itself uses the variable.
The generator's for-in `var _ = e` usage mask is REMOVED so unused captures
stay differentially tested. Regression:
`test/fuzz_f6_unused_capture_test.zbr`. Assigned **BUG-164**.

## F10 — selfhost `_ = self;` blind to else-branch self-uses  (✅ FIXED — BUG-166)

**Seed 51**, first 60-seed batch after BUG-164 (verdict `zig-diverge-B`,
`pointless discard of function parameter: _ = self;`). A method whose ONLY
self-use (`.f0 = 61.1`) sat in an `else` branch: the selfhost's
`stmtMentionsThis` `Stmt.if_` arm scanned then-branch + cond but skipped
`else_ifs`/`else_stmts` entirely, so the `_ = self;` suppression fired while
the else branch used self. Bootstrap (`collectRefs`) was correct — a genuine
selfhost-only equivalence bug. Fixed by scanning all branches; sibling
walkers (`nameUsedInStmt`, `methodMutatesSelf`) audited clean. Regression:
the Gauge shape in `test/fuzz_f6_unused_capture_test.zbr` + seed 51.
Also hardened en route: the BUG-164 discards now skip `as _` (explicit
discard binding) — caught by crypto_test before commit (`_ = _;`).

## F9 — range for-in: docs claim `to`, bootstrap has `..`, selfhost has neither  (divergence + doc rot, OPEN)

Found while probing F6. Three-way inconsistency around numeric range loops:
- QUICKSTART §13 documents `for i in 0 to 10` (+ `step`) as the canonical
  form — **both compilers reject it** (no `to` range operator exists).
- The bootstrap parses `for i in 0..3` (genForInToRange) — QUICKSTART uses
  this form in §33/§35 examples.
- The **selfhost parser rejects `..` in for-in** ("expected indent, got
  '..'") — its `..` handling is slice-context only.
- `for i in 0.to(100)` (method form) exists in both (isToRangeIter).
Reconcile: implement `..` range parsing in the selfhost parser (equivalence
rule), fix QUICKSTART §13 to the real forms, decide whether `to`/`step`
should exist at all. Until then the fuzzer must not generate range loops.

## F7 — low-precedence expressions re-emitted without parens  (shared, ✅ FIXED — BUG-163)

**Seed 7**: `var c27 = C5((1 - (v26 orelse 8)))` — valid Zebra — emitted as
`C5.init((1 - v26 orelse 8))`. Zig's `orelse` binds looser than arithmetic,
so that re-parses as `(1 - v26) orelse 8` → `invalid operands to binary
expression: 'comptime_int' and 'optional'`.

**Root cause (both compilers):** the parser drops redundant source parens
(no paren AST node), and the emitters printed `orelse` / `catch` /
`if`-expression / `try` — ALL of which bind looser than every operator in
Zig — without self-parenthesizing. Any nesting of one inside a binary or
tighter context re-associated or failed to parse.

**Initial hypothesis falsified:** this was NOT the concat-of-call-result
inference class (that trap is real but separate — no fuzz seed currently
hits it; the workaround pattern is recorded in BUG-162's entry).

**Fix (both compilers):** the `orelse_`, `catch_` (both plain and
try-block-label forms), `if_expr`, and `try_` emission arms now always wrap
their output in parens. Redundant parens are harmless; missing ones are a
miscompile. Regression: `test/fuzz_f7_precedence_test.zbr` (orelse in
arithmetic — the seed-7 shape; two orelse operands in one binary; `?` in
arithmetic). Assigned **BUG-163**.

## F8 — the two parsers accept DIFFERENT ternary syntaxes  (divergence, OPEN)

Found while writing the F7 fixture. The bootstrap parses the if-expression
(ternary) as call-form `if(cond, then, else)` (AstBuilder 8-child CST arm);
the selfhost parses colon-form `if cond: then else: else_val`
(Parser.zbr `parseAtom` `textIs("if")` arm). Each rejects the other's form.
**Zero corpus usage of either** — the feature is undocumented (no QUICKSTART
section) and untested, so the divergence was invisible until now. Also
latent: literal ternary arms in runtime arithmetic emit bare `comptime_int`
arms that Zig rejects ("value with comptime-only type depends on runtime
control flow") — arms need `@as(i64, …)` wrapping once the syntax is
reconciled. Recommend: pick ONE form (the colon form matches the 0.15
inline-if statement syntax), implement in both parsers, document in
QUICKSTART §13, add typed-arm emission. Until then the fuzzer must not
generate ternaries.

## F2 — unused local emitted as `const` → Zig "unused local constant"  (shared, ✅ FIXED — BUG-161)

**Diagnosed 2026-07-02 by scope-shape probing** (12 hand-built shapes through the
oracle, then 10 refinement shapes). The "scope-specific" hypothesis dissolved
into one root cause with **three faces**, all in the unused-local auto-discard
in `genStmts` (both compilers, shared):

1. **Any annotated decl** (`var zz: int = 5`) — the discard skip for
   explicitly-typed locals existed because a *constrained-alias* type
   (`type Small = int where …`) emits an inline contract check that reads the
   local invisibly to `mightUseName`. But the skip covered **every** annotation,
   so any annotated unused local in any scope was left undischarged.
2. **A later `.field` (implicit-self) statement** — `Expr.this` wasn't modelled
   in `mightUseNameInExpr`, falling into the conservative `else => true`. Any
   method/`cue init` body with a `.field` read or write after the decl reported
   "might be used" for *every* name — no discard for any local in the body.
   (This is why it looked like "method scope" in early probes.)
3. **A later string interpolation or `orelse`** — same root: `string_interp`
   and `orelse_` weren't modelled, so `print("a=${a}")` after `var zz = 5`
   suppressed zz's discard.

**Minimal repros:** `var zz: int = 5` + any later stmt (face 1);
`var zz = 5` then `return .f0` in a method (face 2);
`var zz = 5` then `print("a=${a}")` (face 3).

**Fix (both compilers):** `genStmts` skip narrowed from "any annotated decl" to
`varDeclEmitsConstraintCheck` (named/parametric alias with a `where` constraint,
contracts not stripped — exactly when the hidden read exists);
`mightUseNameInExpr` gained exact arms for `this` (never a user name),
`string_interp` (recurse expr parts), and `orelse_` (recurse both sides).
Regression: `test/fuzz_f2_unused_local_test.zbr` (all three faces + a
constrained-alias local that must still *skip* the discard).
Gates: smoke 192/192, round-trip byte-identical. Assigned **BUG-161**.
