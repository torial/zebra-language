# Fuzzer findings

Bugs surfaced by the differential fuzzer (`fuzz/`). Each is a program both
compilers accept but that reveals a codegen/robustness gap. "Shared" findings
(present in *both* compilers — verdict `both-zig-fail`) are robustness gaps, not
equivalence bugs; genuine equivalence bugs show as `run-divergence` /
`zig-diverge-A|B`.

---

## F12 — selfhost string-literal-vs-slice coercion divergence  ✅ FIXED — BUG-173 (2026-07-13)

**FIXED 2026-07-13 (supervised session).** Root was NOT the suspected union/
struct/method-return path below — it was `genLocalVar`: the selfhost annotated an
untyped local from its init only for INT/FLOAT *literal shapes*, and its non-
literal fallback covered only `int_`/`float_`. A **string-typed non-literal init**
(ternary `var v = if(c,"ggbb"," d")`, concat, or `str`-returning call) fell through
unannotated → Zig inferred `*const [N:0]u8` → a later different-length string
assignment failed to unify. Fixed by porting the bootstrap's `tcTypeAnnotation`
into `selfhost/CodeGen.zbr` and using it in the fallback (adds string_ + uint/char/
str_slice/optional). Seeds 80/83/89 → `ok`; smoke 233/233; full round-trip clean.
Regression: `test/bug173_string_coerce_test.zbr`. See BUG-173.

**Diagnosis note:** the "not yet minimally reduced" guess below (union/struct/
method-return) was WRONG — hand-reading the emitted Zig around the error line
(`var v7 = …` vs bootstrap's `var v7: []const u8 = …`) pinpointed it in minutes,
faster than shrinking would have. The two ruled-out probes missed because both
take literal-shape paths or same-length reassignment.

**Original finding (surfaced 2026-07-12):** by growing the generator: added a `chars` cap so `char`
appears as a `List(char)` element (the BUG-172 shape; leaf-only, not in `PRIMS`).
The cap itself is clean — 98/100 seeds `ok`, valid char programs, no `both-reject`
noise. But its RNG shift moved **seeds 80 and 83** onto a program shape the fuzzer
had never generated, both verdict `zig-diverge-B`:

```
selfhost emit rejected by zig: expected type '*const [5:0]u8', found '[]const u8'
```

i.e. the **selfhost** emits Zig where a fixed-size string-literal type
(`*const [N:0]u8`) is expected but a string slice (`[]const u8`) is supplied,
while the **bootstrap** emits code `zig` accepts. `run.py` saved reproducers to
`fuzz/findings/seed80,83_zig-diverge-B.zbr`.

**Not char-related** — `shrink.py` reduced seed 80 to a program with **no** `char`
/ `List(char)` at all (it kept `List(bool)`, string concat, a ternary, a union
with a string-ish payload). So this is a **pre-existing** selfhost string-coercion
bug that the char cap merely *exposed* via RNG variation — exactly the coverage-
map thesis (more random combination → latent bugs surface).

**Not yet minimally reduced.** Two obvious hypotheses were ruled out (both compile
identically on BOTH compilers, so neither is the trigger):
- string literal `==` a ternary-of-strings (`"x" == if(c, "y", f())`) — fine.
- string var from a literal then reassigned to a concat/slice (`var v = "x"; v = a + b`) — fine (both emit `var v: []const u8`).

So the trigger is a more specific combination in seed 80/83 (at the time
hypothesized as a string payload flowing through a union variant / struct field /
method return). *That hypothesis was wrong* — see the FIXED note above: the real
trigger was a string-typed non-literal **var initializer**, resolved by reading
the emitted Zig rather than by bisection.

## F11 — unused capture/local discard skipped when the body holds an unmodeled expr (shared, ✅ FIXED — BUG-169)

**FIXED 2026-07-03:** added the missing arms to `mightUseNameInExpr`
(`if_expr`, `try_`, `catch_`, `to_non_nil`, `is_nil`, `cast`, `type_check`,
`slice`, `opt_chain`, `dict_lit`; `except_` on the selfhost) and
`mightUseNameStmt` (`branch`, `try_catch`, `raise`, `assert`, `defer`) in BOTH
compilers, mirroring the complete `nameUsedInExpr`/`nameUsedInStmt` (conservative
`else => true` kept for the rare remainder — `lambda`/`with`/`allocate`/
`copy_out`/`except`-stmt — where over-approx is the safe direction, no pointless
discard). Seed 39 → `ok`; both `both-zig-fail` from the 80-seed batch closed;
regression `test/fuzz_f11_unused_capture_ternary_test.zbr` (if-as+ternary,
if-as+branch, for-in+ternary, unused-local+ternary). Smoke + round-trip green.
**RETIRED 2026-07-03 (class killed structurally).** Rather than the deferred
`collectAllIdents` route, the fix went further: `mightUseNameInExpr`/
`mightUseNameStmt` in the **bootstrap** are now **exhaustive switches with no
`else`** — the Zig compiler refuses to build if any future Expr/Stmt form is
unhandled, so this class (F2/F6/F11 all shared it) can no longer silently
recur. Selfhost mirrors it; round-trip enforces parity. No residual: every
ident-bearing form is modelled; the only `else` left (selfhost
mightUseNameInExpr) covers zig_lit/result_ which genuinely have no idents.
See `docs/walker_discipline.md` §1 "RETIREMENT".

**Original finding:**

**Found 2026-07-03** by the enum/union/branch batch (80 seeds → 2 `both-zig-fail`;
seed 39 pinned, second in seeds 50–79 predicted same root). Note the *equivalence*
was clean (30/30 zig-validity + 5/5 `--run`); these are shared robustness gaps.

**Minimal shape** (from seed 39, `if x as y` with an unused binding + a ternary
in the body):
```zebra
def main()
    var o: int? = nil
    if o as b            # b is never read in the body
        var x = if(true, 1, 2)   # a ternary — the trigger
        print("x=${x}")
```
Both compilers emit `if (o) |b| { … }` **without** the `_ = b;` discard, so Zig
rejects it: `error: unused capture`. (Same class as an unused local → "unused
local constant".)

**Root cause (airtight, confirmed by reading the walker — no build needed):**
the unused-binding discard fires only when `mightUseName(cap, body)` is FALSE.
`mightUseNameInExpr` models ident/member/index/unary/binary/call/tuple_lit/
chained_cmp/string_interp/orelse_/literals/this — but NOT `if_expr` (ternary),
`try_`, `catch_`, `to_non_nil`, `is_nil`, `cast`, `type_check`, `opt_chain`,
`slice`. Those hit the conservative `else => true`. So a ternary (or any of the
unmodeled forms) *anywhere* in the body makes `mightUseName` claim "maybe uses
`b`", the discard is skipped, and a genuinely-unused `b` errors. Surfaced now
because ternaries only entered the generator yesterday (F8) and the enum/union
work produced bigger bodies. **Same family as F2/BUG-161** — that fix added
string_interp/orelse/this; this is the same walker, further expr forms.

**The deeper defect (the real lesson):** `mightUseName` was designed
*conservative* ("true when unsure") to avoid a *pointless discard* (`_ = x` when
x IS used). But for the discard decision, BOTH error directions are Zig compile
errors — over-approx → unused-capture/const; under-approx → pointless discard —
so the walker must be **exact**, not conservative. The `else => true` is the
root defect and will keep surfacing as the grammar grows (each unmodeled
expr/stmt form in a capture body with an unused binding = a `both-zig-fail`).
Note `mightUseNameStmt` has the SAME over-approx gap for unmodeled *statement*
forms (branch/with/try_catch/…) — a nested `branch` in an unused-capture body
would trigger it too.

**Fix (specified; deferred to a RAM-plentiful session — the code edit is
trivial but needs a compiler rebuild + regen + gates, and the host was at
~3.4GB killing zig jobs when this was found):**
- Immediate: add the missing identifier-containing arms to `mightUseNameInExpr`
  in BOTH compilers (`src/CodeGen.zig` + `selfhost/CgHelpers.zbr`), mirroring the
  already-complete `nameUsedInExpr`: `if_expr` (recurse cond/then/else), `try_`,
  `catch_`, `to_non_nil`, `is_nil`, `cast`, `type_check`, `opt_chain`, `slice`.
- Robust: also close `mightUseNameStmt`'s statement-form gaps, OR switch the
  discard decision to an *exact* ident-set check (`collectAllIdents(body)` —
  already in CgHelpers — `cap in idents`), which is immune to walker-completeness
  drift. Recommend the exact-ident-set approach long-term; it retires the whole
  bug class instead of playing whack-a-form.
- Regression: `test/fuzz_f11_unused_capture_ternary_test.zbr` (the minimal shape
  above + a for-in variant + an unused-local variant).
- Cross-ref `docs/walker_discipline.md`: this is the "exact vs conservative
  walker family" lesson biting exactly as that doc warned.

Repro saved: `fuzz/findings/seed39_both-zig-fail_bug169.zbr`.

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

**Second face (2026-07-02, seeds 61/63/69/75/76/83/89/91):** the widened
generator (range loops) immediately exposed the SAME walker one arm over —
`stmtMentionsThis` had no `Stmt.for_num` arm at all, so a self-use only
inside a range loop was invisible (`_ = self;` + `self.f0 = …` in the
while body → pointless discard). Fixed: for_num arm scans start/stop/step
+ body. Design caution recorded: this walker's `else` returns FALSE, and
BOTH error directions are Zig errors (`_ = self` + use = pointless discard;
no `_ = self` + no use = unused parameter) — it must be kept exactly in
sync with statement forms, unlike the conservative mightUseName family.
The Gauge.fill shape in the F6 fixture is the regression.

## F9 — range for-in: docs claim `to`, bootstrap has `..`, selfhost has neither  (✅ FIXED — BUG-165)

Found while probing F6; resolved 2026-07-02. The full picture turned out to
be FOUR-way once `for i in a : b [: step]` was probed — the colon for_num
form worked in BOTH compilers all along and is the real canonical range:
- QUICKSTART §13's `for i in 0 to 10` (+ `step`): pure doc rot — no compiler
  ever accepted it. §13 now documents the real forms.
- Bootstrap `for i in 0..3`: parsed, but lowered to Zig's NATIVE range for —
  a **usize** counter (negative bounds = compile error; `i - 1` at zero =
  underflow panic), silently different semantics from `:`/`.to()` (i64).
- Selfhost: rejected `..` in for-in entirely.

**Fix:** `..` is now an alias for the `:` for_num form in both compilers —
selfhost parses `a..b` into the same for_num node (step disallowed after
`..`, matching the bootstrap); bootstrap routes binary-dotdot iterables to
the shared i64 counter lowering (`genForInRangeParts`) instead of native
`for (a..b)`. En route: bootstrap `genForNum` gained the brace scoping the
selfhost always had (two same-named `for i in a : b` loops in one scope
previously collided — latent, corpus never did it). Regression:
`test/fuzz_f9_range_test.zbr` (all three spellings + step + negative bounds
+ `i - 1` at zero + repeated same-named loops).

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

## F8 — the two parsers accepted DIFFERENT ternary syntaxes  (✅ FIXED — BUG-167)

Found while writing the F7 fixture; resolved 2026-07-02. The bootstrap
parsed call-form `if(cond, then, else)`; the selfhost parsed colon-form
`if cond: then else: else_val`. Each rejected the other's form; zero corpus
usage of either, undocumented, untested.

**Resolution: converged on the CALL-form** (the bootstrap's). The original
note here recommended the colon form for aesthetic consistency with inline-
if statements — reversed on implementation grounds: converging to the
bootstrap needed a ~15-line contained change in the selfhost's `parseAtom`,
while colon-form would have meant new grammar in the bootstrap's CST parser
(the regen authority) for an unused feature, and `if(` in expression
position is unambiguous. The selfhost colon-form arm is removed.

**Also fixed (both compilers):** literal arms are `comptime_int`/`float` —
with a runtime condition Zig rejected the ternary outright ("value with
comptime-only type depends on runtime control flow"). Both emitters now
wrap in `@as(i64, …)`/`@as(f64, …)` when the TC types the ternary numeric.

Documented in QUICKSTART §13; generator now produces ternaries
(`caps['ternary']`) and range loops (`caps['ranges']`). Regression:
`test/fuzz_f8_ternary_test.zbr`.

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

---

# Grammar-fuzzer findings (`gramgen.py`)

A distinct instrument from the semantic fuzzer above: `gramgen.py` derives
*syntactically*-valid programs straight from `grammar.txt` (coverage-guided) and
feeds them through both compilers' front-ends. Grammar-valid ≠ semantically-valid,
so the signals are **crashes/hangs** and **accept/reject divergences** (two
implementations of one grammar must agree), not emit/run comparison. Prefixed `G`.

## G1 — selfhost parser infinite loop on a leading non-`static` modifier  ✅ FIXED — BUG-199 (2026-07-23)

The headline find, on the fuzzer's first runs. A 551-char generated program timed
out only in the selfhost; minimized to **`readonly struct b`** (18 bytes) — the
selfhost hung forever, the bootstrap rejected it in 80ms. Root: an error-recovery
no-progress loop (`skipToTopLevelBoundary` re-entering on a col-1 recovery-starter
without advancing). Fixed by mirroring the bootstrap's progress guarantee. Full
detail + regression fixture in `BUGS.md` BUG-199.

## G2 — empty-body declarations  ✅ RESOLVED (design decision, 2026-07-23)

**Decision (Sean): empty / marker `struct`s and `class`es are LEGAL.** Verified the
selfhost emits an instantiable marker type (`pub const Marker = struct { init()… }`;
`const m: Marker = Marker{}`) that compiles AND runs. So the selfhost is CORRECT here
and the bootstrap has a parse-time gap (rejects them) — a known low-priority
bootstrap-lag as it sunsets; the selfhost is the reference. Codified in `grammar.txt`
(`MemberBlockOpt`, scoped to struct+class), documented in QUICKSTART, regression
`test/marker_struct_test.zbr` (smoke_run). The fuzzer's remaining "empty struct/class"
PARSE-DIVERGENCE findings are now EXPECTED (bootstrap-lag), not bugs.

**Scoped deliberately to struct+class.** The selfhost's parser *also* accepts empty
`interface`/`mixin`/`extend`/`enum`, but those are NOT blessed: empty `interface`
miscompiles (emits a broken `pub fn check(comptime T)` conformance stub → zig rejects);
empty `mixin`/`extend` are no-ops; a zero-variant `enum` is degenerate. Grammar keeps
mandatory bodies for those. **Two follow-ups surfaced (low priority):**
- selfhost parser is too lenient on empty `interface`/`mixin`/`extend`/`enum` (accepts
  what the grammar now forbids); empty `interface` additionally miscompiles.
- **Member-var `as`-type drift:** `var x as int` as a *class/struct member* is rejected
  by BOTH compilers (`unexpected member: 'as'`) despite `VarMemberDecl → … VarTypeOpt →
  kw_as TypeRef` in the grammar. A grammar↔parser mismatch (both agree, so not a
  divergence) — filed here as a note.

## G3 — size-type name as type-alias RHS: bootstrap resolver gap  ⛔ OPEN (low, bootstrap-lags)

`type b = f64` — the selfhost accepts; the bootstrap's resolver rejects with
`'f64' is not defined` (it resolves `float` but not the `f64`/`i32` size-type names in
a type-alias RHS position). `type MyInt = int` works in both. Selfhost LEADS →
sunsetting-bootstrap class (see NEXT_STEPS 5-family triage); low priority.

## G4 — miscellaneous single-sided rejects  ⛔ OPEN (low)

Assorted resolver/timing divergences the sweep surfaced, all low-signal:
`use <nonexistent>` (bootstrap fails module resolution during emit; selfhost emits an
`@import` of a missing module that would fail later at `zig` — different stage, same
eventual reject); a lone `@result`/unknown `@`-directive at EOF (bootstrap accepts,
selfhost errors "unexpected end of input").

## Grammar hygiene — dead rule

`ValueArgListNE` / `ValueArg` (grammar.txt lines ~452–461) are **defined but
unreferenced** by any production — surfaced as permanently-uncovered by the sampler.
Candidate for removal or wiring-in (they were meant for value-applied aliases in type
position). Cosmetic; noted, not filed.

## Campaign 2026-07-23 (post-BUG-199) — parser robustness confirmed

After BUG-199 was fixed, ran **10,800 grammar-valid programs** (12 seeds × depths
7/10/13). **0 hangs, 0 crashes** — strong evidence no other parser hang/crash is
reachable at these depths. All findings were the known accept/reject DIVERGENCE
classes (G2 empty-body, G3 size-type alias, G4 @-directive/module-resolution); no new
bug classes. Deep-expression super-linear slowdown (depth ≥16, the BUG-181 inference
family) is real but out of this campaign's scope (a perf/algorithm issue, not a clean
bug) — probe separately if that thread is picked up.

**Tooling upgrades this session** (`gramgen.py`): findings dedup by normalized
signature, smallest reproducer kept per signature and written to
`fuzz/findings/gramgen/` (gitignored), and a message-stage heuristic that splits
**PARSE-DIVERGENCE** (one side rejects grammar-valid input at the parse stage — the
purest front-end signal) from resolve/type DIVERGENCE (expected noise for
semantically-garbage generated programs). A true differential FE oracle would need a
`--check`/`--parse` flag with a reliable exit code in BOTH compilers — the selfhost
has `--check` (but it exits 0 on error) and the bootstrap has none; deferred (touches
the sunsetting bootstrap).
