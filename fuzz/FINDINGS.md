# Fuzzer findings

Bugs surfaced by the differential fuzzer (`fuzz/`). Each is a program both
compilers accept but that reveals a codegen/robustness gap. "Shared" findings
(present in *both* compilers — verdict `both-zig-fail`) are robustness gaps, not
equivalence bugs; genuine equivalence bugs show as `run-divergence` /
`zig-diverge-A|B`.

---

## F1 — user identifiers that shadow a Zig primitive type emit invalid Zig  (shared, open)

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

## F2 — unused local emitted as `const` → Zig "unused local constant"  (shared, investigating)

A never-used generated `var` in some scopes emits `const x = <expr>;`, which Zig
rejects (`error: unused local constant`). A trivial top-level `var unused = 5`
does *not* reproduce it, so the trigger is scope-specific (likely a var declared
inside an `if`/`while` block and unused there). Zig discards unused locals with
`_ = x;`; Zebra may want the same for locals it can prove are unused. Needs a
minimal repro (shrinker) before filing a direction.
