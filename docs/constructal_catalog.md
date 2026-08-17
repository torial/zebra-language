<!-- doc-status: historical -->
# A catalogue of heat-tree morphologies

**Dated exploration, 2026-08-16.** Findings from `examples/constructal.zbr`. Accurate as
of its entries; this is a record, not a live claim about the compiler.

The program grows a high-conductivity structure inside a uniformly heat-generating slab
that can shed heat through **one** cell on its edge. It is never told what a tree is: it
upgrades the cell with the steepest temperature gradient, which is exactly steepest descent
on mean temperature (`dJ/dk = -|grad T|^2`, and conduction is self-adjoint so the adjoint
field is the forward field). Trees are what that does.

## What varies the morphology, and what does not

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

### It does NOT vary much with the growth exponent, and that is the interesting part

Switching from deterministic steepest descent to stochastic selection with
`P ∝ |grad T|^eta` — the parameter that in dielectric-breakdown models takes you from
compact Eden clusters through DLA to needles — barely moves anything here:

| selection | frontier score spread | box dimension |
|---|---|---|
| `eta = 0` (uniform) | 1.0x | 1.475 |
| `eta = 1` | 4.0x mean, 7.2x worst | 1.505 |
| `eta = 4` | 68.5x mean, **216x worst** | 1.423 |
| deterministic | — | 1.386 |

**The first hypothesis was that the scores had too little spread for the exponent to bite.
That was measured and is false** — at `eta = 4` the weights span 216x and the morphology
still does not move. What `eta` does do is interpolate correctly between uniform-frontier
growth and deterministic steepest descent; the two endpoints simply land in nearly the same
place.

The proposed mechanism is **screening**. In DBM the field is source-free, so tips shield
fjords and the selection rule has enormous leverage. Here heat is generated in *every*
cell, so fresh heat appears immediately adjacent to every frontier cell and no part of the
frontier can be starved. The volumetric source term suppresses the screening that `eta`
acts on.

**That is a prediction, not a conclusion, and it has not been tested.** The experiment that
would test it: concentrate the generation far from the sink (or remove it and drive the
problem from a hot boundary instead), restoring long-range transport and therefore
screening. If the mechanism is right, the `eta` axis should open up. If it does not, the
explanation above is wrong.

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
so differences of ~0.1 between specimens are real and differences of ~0.05 are not. That
is precisely why the `eta` result above is reported as a null rather than a trend.

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
zebra run examples/constructal.zbr [N] [kRatio] [budgetFrac] [mode] [eta] [seed]
zebra run examples/constructal.zbr 49 4 0.12 opt              # the engineered spreader
zebra run examples/constructal.zbr 49 4 0.12 grow 1.0 12345   # stochastic growth
zebra run examples/constructal.zbr 49 4 0.12 selftest         # validate the classifier
```

Every specimen is seeded and reproducible.
