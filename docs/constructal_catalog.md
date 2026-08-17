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

### It DOES vary with the growth exponent — but only where the tree can screen

**This section previously reported a null, and the null was wrong.** It was measured at a
single conductivity ratio (k = 4), where the exponent genuinely does nothing, and
generalised from that one slice. Sweeping both axes shows a clean phase diagram.

Box dimension, stochastic mode, uniform sources, seed 12345:

| k \ eta | 0 | 1 | 2 | 4 |
|---|---|---|---|---|
| 2 | 1.535 | 1.502 | 1.530 | 1.523 |
| 4 | 1.535 | 1.502 | 1.495 | 1.483 |
| 10 | 1.535 | 1.437 | 1.439 | 1.354 |
| 30 | 1.535 | 1.415 | 1.338 | 1.200 |
| 100 | 1.535 | 1.338 | 1.185 | **1.142** |

`eta` spread by contrast: 0.012, 0.052, 0.181, 0.335, **0.393** — monotonic, and only the
last three exceed the classifier's ~0.1 resolution.

**SCREENING REQUIRES TWO THINGS AT ONCE, and that is the finding.** The aggregate must
perturb the field (high contrast) *and* the selection rule must be sensitive to the
perturbation (high `eta`). Either alone does nothing, which is exactly why the `eta = 0`
column and the `k = 2` row are both flat. At low contrast the tree barely bends the field,
every frontier cell looks alike, and no exponent can amplify a difference that is not
there.

The morphologies at the corner are textbook, and visibly so. At `k = 100, eta = 0` the top
22 rows of the domain are **empty** — a compact blob hugging the sink, an Eden cluster. At
`k = 100, eta = 4` long sparse tendrils reach most of the way up. That is the Eden -> DLA
transition, and it was completely invisible at `k = 4`.

**THE eta = 0 COLUMN IS AN INTERNAL CONTROL, not just a data point.** At `eta = 0` selection
is uniform over the frontier and therefore field-independent, so the morphology must not
depend on conductivity at all. It reads 1.535 at every one of the five ratios, to three
decimals. An implementation that had leaked the field into the `eta = 0` path would show
drift there.

### The source-term hypothesis was wrong, and backwards

The previous version of this document proposed that volumetric generation suppresses
screening — that heat appearing next to every frontier cell prevents starvation, and that
removing the sources would open the `eta` axis. A source-free mode was added to test it
(`src = edge`: no bulk generation, top row held hot, which makes the problem a dielectric
breakdown model).

At the same `k = 100`, the `eta` spread is **0.393 with uniform sources and 0.142
source-free**. Sources make `eta` *more* effective here, not less. The hypothesis was not
merely unsupported; it pointed the wrong way. The controlling variable is conductivity
contrast, and the source mode is a second-order effect on top of it.

Recorded rather than deleted, because the useful part is that the hypothesis was specific
enough to be killed by one sweep.

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
