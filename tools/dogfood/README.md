# Dogfood sweep

A hand-directed complement to the fuzzer (`fuzz/`). Where the fuzzer generates
*random* well-formed programs, this sweep curates *realistic* programs that exercise
stdlib/idiom **combinations** a real user reaches for — the kind that surfaced the
Mosaic POC findings (`C:\Projects\mosaic\docs\ZEBRA_FINDINGS.md`).

## Why it exists

The round-trip gate (`tools/bootstrap_check.sh`) proves the compiler reproduces its own
output (a *fixed point*); the corpus gates sweep programs we wrote as tests. Neither
sees a realistic combination nobody wrote a fixture for. Every probe here is emitted
and compile-checked, then classified.

**Until 2026-09-16 this was DIFFERENTIAL**: each probe went through both the bootstrap
and the selfhost and the verdicts named the one that disagreed (BUG-173/177/179 came
from that). The bootstrap is retired (`docs/design/bootstrap_sunset.md`); the findings
snapshot below is kept in its original vocabulary.

## Run

```bash
bash tools/dogfood/run.sh      # needs zig-out/bin/zebra[.exe] + zig
```

Verdicts:

| verdict | meaning | action |
|---|---|---|
| `clean` | emits + compiles | the pattern works |
| `GAP` | emitted, `zig` refused it | a language/codegen gap — file it, add a fixture |
| `EMIT-FAIL` | the compiler refused the probe | usually a probe syntax error; else a gap in the front end |

## Adding probes

Drop a small `.zbr` in `probes/` with a header comment stating the pattern and its
expected verdict. Keep each probe minimal and focused on one idiom combination.

## Findings snapshot (2026-07-14)

- **clean (9):** `csv_split_annotated`, `word_freq`, `list_hof`, `class_method`,
  `range_loop`, `optional_bind`, `nested_hashmap`, `str_join_idx`,
  `multi_type_interp` — a broad spread of real-world patterns (annotated
  split-to-List, HashMap frequency count, expression-lambda filter/any, classes with
  cue-init + methods, numeric ranges, `if x as v` binding, nested-generic HashMap
  value, join+index, mixed-type interpolation) all work identically on both
  compilers.
- **SHARED-GAP:** `split_inferred` (BUG-176), `nested_index` (BUG-177 nested case —
  `x[i][j]` misses `.items`; `.at(i).at(j)` works), `int_mul_float` (no implicit
  int→float promotion — by design; use `.toFloat()`).
- **DIVERGE boot-fails (selfhost-ahead, BUG-179):** `tuple_destructure`
  (`var (a,b) = call()`), `len_tofloat` (`.len.toFloat()`). The selfhost accepts
  these; the bootstrap rejects them. Harmless for users (the selfhost is primary),
  but a latent `--update` trap if ever used in **compiler source** (regen goes
  through the bootstrap). Currently unused there, so `--update` is green.

See `BUGS.md` for the tracked entries.
