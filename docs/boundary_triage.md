# Boundary-value suite — method, findings, and what is deliberately not covered

*Tier A3 of `docs/testing_strategy.md`. Probes live in `test/boundary/`, runner is
`tools/boundary_check.sh`.*

---

## 1. Why this is not another golden baseline

`tools/output_sweep.sh` records what 327 corpus programs currently print and fails when
that changes. It is the right tool for regressions and it is structurally incapable of
finding behaviour that was **wrong on day one** — the recorded value is the assertion, so
a wrong value is recorded exactly as confidently as a right one. `testing_strategy.md`
names that as the gap A3 exists to close.

The only thing that closes it is authoring the expectation **from the language reference,
before observing the compiler**. That is a property of the *process*, not of the files, so
it is protected structurally rather than by good intentions:

* The probes and their intended output were committed in **one commit, having never been
  run**. The first run's results were committed **after**. The ordering is visible in
  `git log` and cannot be reconstructed after the fact.
* When a probe disagrees with the compiler, the question is *"which of the two is
  wrong?"* — and the answer is recorded in §3 below either way, including the cases where
  the expectation was wrong.

If a future change ever authors a `.expected` by pasting observed output, this suite has
become `output_sweep` with extra steps and should be deleted rather than kept.

**One honest seam:** how values *render* (a bool prints `true`, an int prints unadorned)
was established with a throwaway program before authoring, and is not part of what the
suite tests. The suite asserts what an operation **yields at a boundary**, not how the
printer formats it. Mixing those would have made every row depend on guessing a print
format, which is not the property under test.

## 2. Outcome kinds

A boundary case has three honest outcomes and a stdout diff models only one. Each probe
declares its kind in a `# @boundary` header:

| kind | assertion |
|---|---|
| `runs` | exits 0, and stdout **equals** the hand-written `.expected` |
| `rejects <text>` | the compiler **refuses** it, naming `<text>` |
| `panics <text>` | it builds, then **fails at runtime** with `<text>` |

`rejects` and `panics` abort the process, so each such probe is its **own file**. A trap
in case 3 of 20 would silently hide cases 4–20 inside a green suite — the same
coverage-loss shape `gate_selfcheck.sh` exists to catch elsewhere.

## 3. Findings from the first run

*Filled in by the run that follows the authoring commit. Every divergence between
intended and actual output is listed here with a verdict, including the ones where the
intent turned out to be wrong.*

<!-- FIRST-RUN RESULTS GO HERE -->

## 4. Not covered, and why — no silent caps

The suite covers four dimensions completely rather than nine partially. What is **not**
covered is listed here and printed by the runner on every invocation, so the gap cannot
quietly be mistaken for coverage.

| dimension | why not |
|---|---|
| **min/max int, overflow, division by zero** | Behaviour is **build-mode dependent** and the modes are currently in flux: the default is Debug on the self-hosted backend (where overflow traps), while **BUG-228** records that `--release` does not actually pass an optimize flag, and Sean's direction is to make ReleaseFast good enough and A/B it. Authoring expectations now would pin one mode's answers as the language's, and they would flip when BUG-228 lands. Do this dimension *after* BUG-228. |
| **float extremes** (inf, nan, -0.0, denormals) | Same reason, plus float **formatting** is a second unpinned variable. |
| **non-ASCII indexing** (`s[i]`) | **BUG-225** — typed `char`, holds a raw byte, silently wrong for non-ASCII. §28e decided this is **documented for 0.9 and retyped in 1.x**. A probe asserting codepoint semantics would fail forever by design; a probe asserting today's byte behaviour would enshrine a known bug. |
| **`charAt`** | **BUG-223** is an open decision awaiting Sean. Encoding either answer would be this suite legislating a user-facing API change. |
| **deep nesting, very long identifiers** | Genuinely open work, not blocked on anything — the next extension of this suite. |
| **non-ASCII in string *operations*** (not indexing) | Partially reachable today (`codePointCount`, `chars()`) and worth adding; excluded from the first pass only for scope. |

The four dimensions covered — empty string, empty collections, nil at every position, and
argument arity — were chosen because **BUG-223 and BUG-224 both came from exactly there**,
found by accident. That is the region with the strongest prior.
