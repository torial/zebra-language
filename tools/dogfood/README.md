# Differential dogfood sweep

A hand-directed complement to the differential fuzzer (`fuzz/`). Where the fuzzer
generates *random* well-formed programs, this sweep curates *realistic* programs
that exercise stdlib/idiom **combinations** a real user reaches for — the kind that
surfaced the Mosaic POC findings (`C:\Projects\mosaic\docs\ZEBRA_FINDINGS.md`).

## Why it exists

The round-trip gate (`tools/bootstrap_check.sh`) proves the selfhost reproduces its
own output (a *fixed point*), but it does **not** compare the selfhost against the
bootstrap. So a codegen change that makes the two compilers *disagree* on a user
program passes the round-trip silently. This sweep is the differential net for that:
every probe is emitted by **both** compilers and compile-checked, then classified.

## Run

```bash
bash tools/dogfood/run.sh      # needs zig-out/bin/{zebra,zebra-bootstrap}.exe + zig
```

Verdicts:

| verdict | meaning | action |
|---|---|---|
| `clean` | both emit + both compile | the pattern works |
| `SHARED-GAP` | both reject | a real language gap (fix both + validate differentially) |
| `DIVERGE self-fails` | bootstrap ok, selfhost rejects | **converge the selfhost** (safe — cf. BUG-173/177) |
| `DIVERGE boot-fails` | selfhost ok, bootstrap rejects | selfhost-ahead (cf. BUG-179) — mind the `--update` trap |
| `BOTH-EMIT-FAIL` | both fail to emit | usually a probe syntax error |

## Adding probes

Drop a small `.zbr` in `probes/` with a header comment stating the pattern and its
expected verdict. Keep each probe minimal and focused on one idiom combination.

## Findings snapshot (2026-07-14)

- **clean:** `csv_split_annotated`, `word_freq`, `list_hof` — common real-world
  patterns (annotated split-to-List, HashMap frequency count, expression-lambda
  filter/any) work identically on both compilers.
- **SHARED-GAP:** `split_inferred` (BUG-176), `nested_index` (BUG-177 nested case —
  `x[i][j]` misses `.items`; `.at(i).at(j)` works), `int_mul_float` (no implicit
  int→float promotion — by design; use `.toFloat()`).
- **DIVERGE boot-fails (selfhost-ahead, BUG-179):** `tuple_destructure`
  (`var (a,b) = call()`), `len_tofloat` (`.len.toFloat()`). The selfhost accepts
  these; the bootstrap rejects them. Harmless for users (the selfhost is primary),
  but a latent `--update` trap if ever used in **compiler source** (regen goes
  through the bootstrap). Currently unused there, so `--update` is green.

See `BUGS.md` for the tracked entries.
