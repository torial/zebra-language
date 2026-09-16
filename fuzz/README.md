# Zebra compiler fuzzer — validity testing

A grammar-directed, **type-aware** fuzzer that stress-tests the compiler on programs
nobody wrote: it must not crash or hang, and what it emits must be Zig that `zig`
accepts (and, with `--run`, a program that runs).

**Until 2026-09-16 this was a DIFFERENTIAL fuzzer.** Two compilers existed -- the
Zig-implemented bootstrap (`zebra-bootstrap.exe`, `src/`) and the Zebra-implemented
selfhost (`zebra.exe`) -- and the oracle was that they agree: accept the same programs,
emit Zig that `zig` judges the same way, produce the same stdout. That found BUG-159
and BUG-160, equivalence bugs the byte-identical round-trip gate structurally cannot
catch because they only manifest on user code shapes absent from the compiler's own
sources. The bootstrap was retired (`docs/design/bootstrap_sunset.md`); the second
implementation no longer exists, so the surviving oracle is validity, and the verdict
names below keep their B-side spelling so `gramgen.py`'s classifier reads unchanged.

## The oracle — what is checked

1. **Crash-freedom** — the compiler may not panic or hang (`crash-B` with a panic
   marker or `TIMEOUT` in the detail; a plain refusal is the same verdict and is
   expected for grammar-valid semantic garbage).
2. **Validity** — the Zig it emits must compile (`zig build-obj`; `zig-fail`).
3. **Runs** (opt-in `--run`) — build an executable from the emit and run it
   (`run-hang`).

## Pieces

- **`leakgen.py` (2026-09-09) — the "Zebra accepts, Zig rejects" fuzzer, selfhost only.**
  gen.py's well-formed programs → selfhost emit → `zig build-exe -fno-emit-bin`. A leak is
  a program the front end accepted and zig refused (the user sees a Zig diagnostic about
  code they never wrote — BUG-336..339, 354). DAILY gate (`--gate`, fixed seeds, fails on
  any signature not in `leak_baseline.txt`; every baseline line must name a BUG). Its first
  3,000 programs found BUG-360..366. `harness.py` is the older oracle and predates
  runtime-module emission (it compiles `m.zig` alone, without the `zebra_rt.zig` beside
  it) — prefer leakgen for the emit-validity question; `gramgen.py --gate` still drives
  `harness.py` for the hang/crash question, emit only.

- `gen.py` — type-aware generator. `gen(seed)` yields a well-formed (resolves +
  type-checks) Zebra program, only ever emitting an expression of the required
  type from in-scope vars + size-bounded literals, so programs exercise real
  codegen paths rather than error paths. Grammar surfaces, gated by `DEFAULT_CAPS`
  and grown incrementally: prim locals & arithmetic, comparisons, `if`/`else`,
  bounded `while`, `print`/interpolation, functions (read-only params), optionals
  (`T?`, nil, `if x as y`, `orelse`), lists (`List(T)`, `.add`, for-in), structs
  (fields + `cue init` + field read/write), classes (fields + methods, `*self`
  vs `*const self`, method dispatch), ternary `if(c,t,e)`, numeric ranges
  (`a:b[:s]` / `a..b`), **`throws`** (throws fns with a conditional `raise`,
  explicit-`?` propagation (§28b), method-level `catch` wrappers that make
  throws chains reachable + runnable from `main`), and **enums / unions /
  `branch`** — bare enums (`E.variant`), tagged unions (payload-less +
  prim-payload variants, `U.variant(x)` construction), and `branch` dispatch
  with payload binding (`on U.v as p`), in both exhaustive and `else` forms.
- `harness.py` — the oracle above. `check(zbr, tag, zig_check=True, run=False)`.
- `shrink.py` — line-granularity delta debugging; minimizes a failing program
  while preserving its verdict signature.
- `run.py` — driver: runs a seed range, buckets verdicts, saves reproducers to
  `fuzz/findings/` (gitignored).

## Usage

```bash
python fuzz/run.py --n 200                 # fuzz 200 seeds (emit + zig-validity)
python fuzz/run.py --n 200 --run           # also build-exe + run + compare stdout
python fuzz/run.py --start 500 --n 100     # seeds 500..599
python fuzz/run.py --seed 12345            # reproduce/inspect one seed (A vs B)
python fuzz/run.py --n 200 --no-zig        # emit + crash-check only (fastest)
python fuzz/run.py --n 200 --shrink        # shrink findings to minimal repros
python fuzz/gen.py 42                       # just print the program for seed 42
```

Run from the repo root; needs `zig-out/bin/zebra[.exe]` built
(`zig build`) and `zig` on PATH (or `ZIG=/path/to/zig`). Set `PYTHONUTF8=1`.

## Verdict buckets

| verdict | meaning |
|---|---|
| `ok` | accepted; the emit compiles (and, with `--run`, the program ran) |
| `crash-B` | the compiler refused, panicked or hung (`gramgen` splits these by the detail text: TIMEOUT → HANG, panic marker → CRASH, else a refusal) |
| `zig-fail` | the emit is Zig that `zig` rejects — a robustness gap (leakgen's question, with a baseline) |
| `run-hang` | the built program did not finish |

(`crash-A`, `zig-diverge-A/B`, `run-divergence`, `both-zig-fail`, `both-reject` were the
differential verdicts and can no longer occur.)

## Findings

See `FINDINGS.md` for details. Summary:

- **F3 / BUG-159** (fixed) — selfhost omitted the numeric type annotation on a
  mutated comptime-init local (`var v = (8*2)`), which `zig` rejects. Equivalence
  bug; first real find.
- **F4 / BUG-160** (fixed) — selfhost interpolated non-strings with `{}` instead
  of the type-appropriate spec (`{d}`/`{any}`); a `List` sent Zig's formatter into
  a comptime blow-up. Equivalence bug.
- **F1** (shared, open) — user identifiers that shadow a Zig primitive type name
  (`i8`, `u32`, `f64`, …) emit invalid Zig in **both** compilers. Real robustness
  gap; the compiler-side fix (escape to `@"name"`) is deferred to a gated session.
  Masked in the generator (no primitive-shadowing prefixes) so it stops burying
  genuine divergences.
- **F2** (shared, investigating) — an unused local in some scopes emits `const`
  that Zig rejects as an unused constant; needs a minimal repro.
- **F5** (generator bug, fixed) — the generator reassigned an `if x as y` capture,
  which both compilers correctly reject (immutable narrowing binding). Not a
  compiler bug; fixed by marking the capture read-only.

## Environment note

On this dev host, background runs are capped at ~4 min and zig builds are slow
under memory pressure (often ~1 min/build when free RAM is low), so large batches
get killed mid-run. For incremental data, prefer small per-seed-printing loops
(`python -u`, print each verdict) over one big `run.py --n` invocation; check free
RAM first and throttle when it is low.
