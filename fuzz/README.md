# Zebra compiler fuzzer — differential + validity testing

A grammar-directed, **type-aware** fuzzer that stress-tests the self-hosting
equivalence guarantee: the Zig-implemented compiler (`zebra-bootstrap.exe`) and
the Zebra-implemented compiler (`zebra.exe`) must be **functionally equivalent** —
they should accept the same programs and produce programs that behave the same.

## Why

Equivalence is otherwise verified only by the byte-identical round-trip gate
(which runs on the compilers' *own* source) and a fixed hand-written corpus. This
fuzzer generates arbitrary well-formed programs and checks both compilers agree —
turning "tested on the examples we wrote" into "checked on random inputs, here are
the minimized cases where they diverge." It has already found and fixed two real
self-hosting equivalence bugs (BUG-159, BUG-160) that the round-trip gate
structurally cannot catch, because they only manifest on user code shapes absent
from the compiler's own sources.

## The oracle — what "equivalent" means here

We do **not** compare the two compilers' emitted Zig byte-for-byte. Both emitters
prepend a large runtime preamble, and the two preambles differ cosmetically
(ordering, comments, helper spelling) while being semantically identical — a
byte-diff is all false positives. Instead the oracle is three layers, cheapest
first:

1. **Crash-freedom** — neither compiler may panic / error where the other
   succeeds (`crash-A` / `crash-B`).
2. **Validity** — the Zig each compiler emits must compile (`zig build-obj`).
   If one compiler's emit is rejected by `zig` and the other's is accepted, that
   is a divergence (`zig-diverge-A` / `zig-diverge-B`).
3. **Runtime equivalence** (opt-in `--run`) — build an executable from each emit,
   run both, and compare stdout (`run-divergence`).

## Pieces

- `gen.py` — type-aware generator. `gen(seed)` yields a well-formed (resolves +
  type-checks) Zebra program, only ever emitting an expression of the required
  type from in-scope vars + size-bounded literals, so programs exercise real
  codegen paths rather than error paths. Grammar surfaces, gated by `DEFAULT_CAPS`
  and grown incrementally: prim locals & arithmetic, comparisons, `if`/`else`,
  bounded `while`, `print`/interpolation, functions (read-only params), optionals
  (`T?`, nil, `if x as y`, `orelse`), lists (`List(T)`, `.add`, for-in), structs
  (fields + `cue init` + field read/write), classes (fields + methods, `*self`
  vs `*const self`, method dispatch).
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

Run from the repo root; needs `zig-out/bin/{zebra-bootstrap,zebra}.exe` built
(`zig build`) and `zig` on PATH (or `ZIG=/path/to/zig`). Set `PYTHONUTF8=1`.

## Verdict buckets

| verdict | meaning |
|---|---|
| `ok` | both accept; emits compile (and, with `--run`, produce identical stdout) |
| `zig-diverge-A` / `zig-diverge-B` | one compiler's emit is rejected by `zig`, the other's accepted — **an equivalence bug** (B = selfhost side) |
| `run-divergence` | both emits compile but produce **different stdout** — an equivalence bug |
| `crash-A` / `crash-B` | one compiler errored/panicked where the other didn't |
| `both-zig-fail` | both emit Zig that `zig` rejects — a **shared** robustness gap, not an equivalence bug |
| `both-reject` | both refuse the program (generator produced invalid Zebra) |

Divergences and crashes are the equivalence findings; `both-zig-fail` flags shared
compiler gaps; `both-reject` is a generator-tuning signal.

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
