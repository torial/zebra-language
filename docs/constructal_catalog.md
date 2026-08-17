<!-- doc-status: historical -->
# A catalogue of heat-tree morphologies

**Dated exploration, 2026-08-16.** Findings from `examples/constructal.zbr`. Accurate as
of its entries; this is a record, not a live claim about the compiler.

The program grows a high-conductivity structure inside a uniformly heat-generating slab
that can shed heat through **one** cell on its edge. It is never told what a tree is: it
upgrades the cell with the steepest temperature gradient, which is exactly steepest descent
on mean temperature (`dJ/dk = -|grad T|^2`, and conduction is self-adjoint so the adjoint
field is the forward field). Trees are what that does.

## What varies the morphology

### It varies with conductivity contrast

`49x49`, budget 12%, deterministic mode:

| k ratio | box dimension | tips | `Q ∝ w^a` | T_max improvement |
|---|---|---|---|---|
| 2 | 1.521 | 14 | 1.054 | 1.48x |
| 4 | 1.386 | 10 | 1.045 | 2.03x |
| 10 | 1.335 | 9 | 1.145 | 2.90x |
| 30 | 1.171 | 7 | 1.409 | 4.02x |
| 100 | 1.088 | 6 | 1.157 | 5.78x |

A monotonic sequence from a **bushy, near-space-filling tree** to a **sparse skeleton**.
When the conductor is barely better than the substrate you need it everywhere; when it is
100x better a thin spine suffices. Note the inverse pairing — *lower* fractal dimension
buys *better* cooling.

At `k = 100` every branch is exactly one cell wide and there is no width variation left to
fit, because extending to unserved heat always beats thickening an already-excellent path.
That is a result, and the program says so rather than fitting noise.

### It DOES vary with the growth exponent — measured over 8 seeds per cell

**An earlier version of this document reported a null here. The null was wrong**: it was
measured at one conductivity ratio (k = 4) with **one seed**, and generalised. Everything
below is 8 seeds per cell, 256 runs.

```
pooled seed-to-seed sd = 0.0285   ->   a difference below 0.057 (2 sd) is NOT resolvable
```

That number is the whole methodology. The original "null" was a spread of **0.052** — below
the resolution of the data that produced it. The honest statement was always "no effect
resolvable here", never "no effect".

Box dimension, mean +- sd over 8 seeds:

| src | k \ eta | 0 | 1 | 2 | 4 | eta effect |
|---|---|---|---|---|---|---|
| uniform | 2 | 1.506±.035 | 1.503±.021 | 1.515±.019 | 1.527±.011 | −0.021 *not resolved* |
| uniform | 10 | 1.506±.035 | 1.462±.026 | 1.420±.020 | 1.347±.023 | **+0.160** |
| uniform | 30 | 1.506±.035 | 1.427±.034 | 1.299±.027 | 1.210±.022 | **+0.296** |
| uniform | 100 | 1.506±.035 | 1.341±.026 | 1.210±.030 | 1.126±.017 | **+0.380** |
| edge | 2 | 1.506±.035 | 1.515±.031 | 1.531±.018 | 1.525±.016 | −0.019 *not resolved* |
| edge | 10 | 1.506±.035 | 1.466±.010 | 1.405±.016 | 1.398±.017 | **+0.109** |
| edge | 30 | 1.507±.035 | 1.399±.042 | 1.388±.035 | 1.354±.030 | **+0.152** |
| edge | 100 | 1.506±.035 | 1.358±.044 | 1.364±.036 | 1.323±.059 | **+0.183** |

Three things are established:

1. **The exponent's effect is real and grows monotonically with conductivity contrast**,
   in both source modes, and is unresolvable at `k = 2`.
2. **The `eta = 0` column is an internal control and it passes.** Selection there is
   uniform over the frontier and therefore field-independent, so morphology must not
   depend on conductivity *or* on the source mode — and it reads 1.506 ± 0.035 in all
   eight cells.
3. **Uniform sources give roughly double the exponent's leverage of a source-free field**,
   at every resolved contrast (+0.160/+0.296/+0.380 against +0.109/+0.152/+0.183).

The corner morphologies are textbook and visible by eye. At `k = 100, eta = 0` the top 22
rows are **empty** — a compact blob hugging the sink. At `k = 100, eta = 4` sparse tendrils
reach most of the way up.

### Three mechanisms proposed, three refuted

This is the part worth keeping. Each explanation was specific enough to test, and each
died:

| hypothesis | test | outcome |
|---|---|---|
| the frontier scores lack the dynamic range for `eta` to bite | instrument the best/worst ratio | **false** — at `eta = 4` weights span 216x and morphology still barely moves |
| volumetric sources suppress screening, so removing them opens the `eta` axis | build a source-free mode and compare | **false and backwards** — sources give ~2x MORE leverage, not less |
| uniform sources win because they create more gradient heterogeneity | compare frontier spread across modes | **false** — edge has 3.5x MORE spread (2438x vs 695x at k=100) and half the effect |

So the uniform-vs-source-free asymmetry is **measured and unexplained**. It is stated that
way deliberately. After three plausible stories died to one measurement each, a fourth
story offered without a test would be worth nothing.

The edge-mode non-monotonicity flagged in an earlier draft (`eta` = 1, 2, 4 reading 1.358,
1.364, 1.323) is **not real**: that rise is 0.006, a tenth of the resolution, and it came
from a single seed. Withholding judgement on it was correct.

## The scaling law, and a prediction that failed

Measured: `Q ∝ w^1.05` (r² up to 0.99, stable across k ratio 2..6 and grids 35..61).

The prediction written down beforehand was `Q ∝ w^2`, from minimising `sum(Q R)` at fixed
volume. That was wrong because the objective was wrong. A transport network minimises
**dissipation**, `sum(Q^2 R)` — the objective Murray used:

```
minimise sum(Q_i^2 L_i / (k A_i))   s.t.   sum(A_i L_i) = V
  ->  A ∝ Q                     exponent 1     (conduction, R ∝ 1/A)
  ->  d^3 ∝ Q                   exponent 3     (Poiseuille, R ∝ 1/d^4)
```

So **Murray's cube law and this linear law are the same variational principle**. The entire
gap between exponent 1 and exponent 3 is `1/A` versus `1/d^4`. A blood vessel and a heat
spreader are one optimisation wearing two transport laws.

The k-ratio trend is the control on that story: the derivation assumes branch resistance
matters, and as contrast rises the branches go isothermal, the premise fails, and the fit
degrades exactly where it should (r² 0.99 -> 0.39).

## Instrument notes — read before trusting any number above

**The box-counting classifier is biased ~6% low.** It is validated on shapes of known
dimension every run (`mode = selftest`):

| shape | measured | exact |
|---|---|---|
| filled square | 1.848 | 2.000 |
| horizontal line | 0.949 | 1.000 |
| diagonal line | 0.949 | 1.000 |
| Sierpinski carpet | 1.747 | 1.893 |

On a 49-cell grid the usable box sizes span barely one decade, so this is finite-size bias,
not a coding error. **It discriminates well** — 0.95 / 1.75 / 1.85 are cleanly separated —
so differences of ~0.1 between specimens are real and differences of ~0.05 are not.

That threshold is load-bearing in both directions and it caught a mistake each way. It is
why the `k = 2` row (spread 0.012) is reported as flat rather than as a faint trend — and
it is also why the original single-slice measurement at `k = 4` (spread 0.052) should never
have been written up as a null in the first place: 0.05 is *below* the resolution, so the
honest statement was "no effect resolvable here", not "no effect".

**The branch-width instrument lied first.** Its first version accepted every horizontal run
of conductor as a cross-section — but a horizontal run through a *horizontal* branch is its
**length**, not its width. Those entries pair a large `w` with a small perpendicular flux
and drag the exponent toward 1. It read 1.1, which is close to the correct answer **for
entirely the wrong reason**. Runs are now kept only where heat flows *across* them, both
orientations are pooled, and r² is printed so a meaningless fit cannot pass as a
measurement.

Two further controls run before any result: mirror symmetry of the field (1.3e-5 relative —
an indexing bug breaks this while still printing a plausible field) and energy balance at
the sink (2.4e-4). Symmetry is asserted **on the solver only**; the grown tree is expected
to be asymmetric, because greedy descent on a problem with degenerate optima picks one and
breaks the symmetry, exactly as Bénard cells choose a phase.

## Reproducing

```
zebra run examples/constructal.zbr [N] [kRatio] [budgetFrac] [mode] [eta] [seed] [srcMode]

zebra run examples/constructal.zbr 49 4   0.12 opt                    # engineered spreader
zebra run examples/constructal.zbr 49 100 0.12 grow 0.0 12345 uniform # compact Eden blob
zebra run examples/constructal.zbr 49 100 0.12 grow 4.0 12345 uniform # sparse DLA tendrils
zebra run examples/constructal.zbr 49 100 0.12 grow 2.0 12345 edge    # source-free (DBM)
zebra run examples/constructal.zbr 49 4   0.12 selftest                # validate classifier
```

Every specimen is seeded and reproducible.

The 256-run multi-seed sweep behind the table above is kept as raw rows, so the statistics
can be re-derived or disputed rather than taken on trust:

- `docs/data/constructal_sweep49.tsv` — one row per run: k, eta, src, seed, dimension, tips
- `docs/data/constructal_aggregate.py` — the aggregator, which computes the pooled
  seed-to-seed sd and refuses to call a difference resolved unless it clears 2 sd

A run that produced no number is written as `FAILED` rather than left blank, so a failure
can never be silently averaged in as a zero.
