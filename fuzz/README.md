# Zebra compiler fuzzer — differential + validity testing

A grammar-directed, **type-aware** fuzzer that stress-tests the self-hosting
equivalence guarantee: the Zig-implemented compiler (`zebra-bootstrap.exe`) and
the Zebra-implemented compiler (`zebra.exe`) must emit **byte-identical** Zig for
every program.

## Why

Equivalence is currently verified by the byte-identical round-trip (only on the
compiler's *own* source) and a fixed test corpus. This fuzzer generates thousands
of *arbitrary* well-formed programs and checks both compilers agree — turning
"tested on the examples we wrote" into "checked on random inputs, here are the
minimized cases where they diverge."

## Pieces

- `gen.py` — type-aware generator. `gen(seed)` yields a well-formed (resolves +
  type-checks) Zebra program. Only ever emits an expression of the required type
  from in-scope vars + size-bounded literals, so programs exercise real codegen
  paths rather than error paths. The subset grows over time (`DEFAULT_CAPS`);
  start conservative → clean baseline → widen to hunt divergences.
- `harness.py` — the oracle. For one program: emit via both compilers, then
  classify: `ok` / `emit-divergence` (**the key finding**) / `crash-A` / `crash-B`
  / `zig-fail` / `both-reject`. `emit-divergence` = a self-hosting equivalence bug.
- `shrink.py` — line-granularity delta debugging; minimizes a failing program
  while preserving its verdict signature.
- `run.py` — driver: `python fuzz/run.py --n 500` runs seeds, buckets verdicts,
  saves shrunk reproducers to `fuzz/findings/`.

## Usage

```bash
python fuzz/run.py --n 500 --shrink       # fuzz 500 seeds, shrink findings
python fuzz/run.py --seed 12345           # reproduce/inspect one seed (shows A vs B)
python fuzz/run.py --n 500 --no-zig       # skip the zig-compile validity check (faster)
python fuzz/gen.py 42                      # just print program for seed 42
```

Run from the repo root; needs `zig-out/bin/{zebra-bootstrap,zebra}.exe` built
(`zig build`) and `zig` on PATH (or `ZIG=/path/to/zig`).

## Verdict buckets

| verdict | meaning |
|---|---|
| `ok` | both emit identical Zig; `zig` accepts it |
| `emit-divergence` | both emit, but the Zig **differs** — a real equivalence bug |
| `crash-A` / `crash-B` | one compiler errored/panicked where the other didn't |
| `zig-fail` | identical emit that `zig` rejects (usually a generator-quality issue) |
| `both-reject` | both refuse the program (generator produced invalid Zebra) |

Divergences and crashes are the findings; `zig-fail`/`both-reject` are tuning
signals for the generator.
