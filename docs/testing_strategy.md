# Testing strategy — adopting what works from SQLite

*Written 2026-07-30, at Sean's request, after the behaviour-gate work. Premise he set:
**a system with no surprises beats a system with more features**, and 0.9 can slip as far
as needed to buy real quality information.*

The point of this document is to be honest about **which of SQLite's practices would
actually tell us something about Zebra**, which are artefacts of SQLite being a durable
embedded database rather than a compiler, and what each costs. Copying the whole list
would produce bulk, not information.

---

## 1. What SQLite actually does

From their own published strategy (`sqlite.org/testing.html`), the load-bearing parts:

| practice | what it buys |
|---|---|
| **100% branch + MC/DC coverage** | proof that every decision has been exercised *both ways* |
| ~590× more test code than library code | a consequence of the above, not a goal |
| **Three independent harnesses** (TCL, TH3, SQL Logic Test) | an error in one harness does not hide a bug |
| **Anomaly injection** — OOM, I/O errors, crash/power-loss | exercises the failure paths, where untested code concentrates |
| **Fuzzing** — dbsqlfuzz (mutates *valid* inputs), SQL fuzz, AFL/OSS-Fuzz | inputs no human would author |
| **Differential testing** (SLT compares against other engines) | an oracle that is not itself |
| Sanitizers — Valgrind, ASAN/MSAN/UBSAN | latent UB that tests alone never surface |
| A regression test for **every** reported bug | bugs stay fixed |
| Release checklists | the boring failures |

The one idea underneath all of it: **assert intent, from more than one direction, and
measure what you have not exercised.**

---

## 2. Translating to a compiler — what maps and what does not

Zebra is not a durable store, so some of the list is inapplicable, and saying so is part
of the plan.

**Maps directly:**
- Coverage — "which branches of `CodeGen.zbr` did the corpus never take?" is exactly as
  meaningful for us as for them.
- Fault injection — *for emitted programs and the runtime*, not for the compiler binary.
- Differential testing — we already have the shape (`divergence_check.sh`, selfhost vs
  bootstrap). We are under-using the other axes we already own.
- Boundary values, per-bug regression tests, sanitizers, checklists — all map cleanly.

**Does not map:**
- **Crash / power-loss simulation.** SQLite must survive being killed mid-write because
  it owns durable state. A compiler that dies re-runs. Skip. (Narrow exception: any
  incremental build state — worth one look, not a programme.)
- **Cross-engine comparison.** There is no second Zebra implementation to compare
  against, other than the bootstrap — and we already do that.
- **The 590× ratio as a target.** It is an *output* of MC/DC plus anomaly testing.
  Chasing the ratio directly produces test bulk with no coverage guarantee.

**The structural gap that no tool on this list closes by itself:** SQLite's tests were
written from *intent* — they assert what the code should do. Most of what we added this
week is a **golden baseline**: it records what the code *does*. Golden baselines catch
regressions and are cheap; they can never find behaviour that was wrong from day one.
Closing that needs hand-written expected-output tests for semantics we actually care
about (Tier A3), and it is the reason A3 is in the plan despite being unglamorous.

---

## 3. The plan, ranked by information-per-hour

### Tier A — do before 0.9. Cheap, and each answers a question we cannot currently answer.

**A1 · Bug-fixture gate.** Every `BUG-NNN` marked FIXED in `BUGS.md` must have a
`test/bugNNN_*` fixture, checked mechanically. SQLite's "a test for every bug" as a
lint rather than a habit.
*Cost: ~1 hour. Yield: immediate — tells us today how many past fixes were never pinned,
and makes the answer permanent.* This is the highest ratio on the list.

**A2 · Behaviour differential across emit modes.** We own several axes that must produce
**identical behaviour** and currently only compare *compilability*: runtime-module vs
`--no-runtime-module`, fast backend (`-fno-llvm`) vs LLVM, `--turbo` vs normal,
`zebra run` vs a built exe. `output_sweep.sh` makes this nearly free — same corpus,
different flags, diff the outputs.
*Cost: ~half a day. Yield: high — catches the entire "works in one mode only" class, and
`--turbo` (which strips contracts) is a genuinely under-tested path.*

**A3 · Boundary-value suite, hand-written from intent.** 0/1/N arguments, empty string,
min/max int, float extremes, empty collections, deep nesting, very long identifiers,
non-ASCII everywhere, nil at every position. Written as *expected* output, not recorded.
*Cost: ~1–2 days of authoring. Yield: high, and demonstrated — BUG-224 (0-arg and 2+-arg
`format`) and BUG-223 (`charAt` with no argument) are both boundary bugs we hit by
accident. We have never looked systematically.*

**FIRST PASS DONE 2026-07-30 — the yield estimate held.** `tools/boundary_check.sh`,
probes in `test/boundary/`, triage in `docs/boundary_triage.md`. Four dimensions (empty
string, empty collections, nil at every position, argument arity), ~140 assertions, and
**three real bugs on the first run**: BUG-230 (an annotated non-empty list literal does
not compile), BUG-232 (arity checking skipped inside `${...}`), BUG-231 (named arguments
unparseable inside `${...}`), plus a documentation defect (the `is…` predicates are
ASCII-only, not Unicode as documented).

Three lessons worth keeping, because they generalise past A3:

1. **BUG-230 is the receipt for why this tier had to exist.** Both compilers do the
   identical wrong thing, so `divergence_check` cannot see it *by construction*; and the
   `test/*.zbr` corpus the heavy gates sweep does not use the form. No amount of corpus
   growth or mode differentiation would have found it — only an expectation written from
   the reference could.

   **And it immediately surfaced something larger than itself:** the one file in the repo
   that *does* use the form is `examples/widget_smoke.zbr`, which **does not compile** and
   is shipping that way, because **no gate sweeps `examples/`**. For a release whose whole
   claim is ready-for-others, the directory a newcomer opens first having zero coverage is
   a bigger finding than the bug that exposed it. Filed as an open item below.

2. **The intent-first property needs a structural guard, not a promise.** It is trivially
   easy to author an `.expected` from observed output with a rationalisation attached, at
   which point the suite is `output_sweep` with extra steps. The guard used here is the
   commit boundary: probes and intended output committed **unrun**, findings committed
   after. Any future extension should do the same.

3. **Known-broken rows are pinned, not deleted.** A `@boundary-pending BUG-NNN` directive
   makes a probe assert what the compiler does *today* while printing the ticket on every
   run — so the gate is green and honest, the debt stays visible, and the assertion breaks
   when the bug is fixed. Deleting the bug-finding probes would have bought a green gate
   by removing the coverage that earned it.

**Open tail:** deep nesting, very long identifiers, and non-ASCII in string *operations*
are unwritten. min/max int and float extremes are deliberately deferred until BUG-228
settles what `--release` means, since their answers are build-mode dependent.

**A4 · OOM policy audit — `catch unreachable` in emitted code.** The runtime and codegen
use `catch unreachable` / `catch @panic("OOM")` on allocation. In ReleaseFast,
`unreachable` is **undefined behaviour**, so an out-of-memory condition in a *user's*
Zebra program is currently UB rather than a clean failure. That is precisely a
"surprise", and it is in shipped output, not in our tooling.
*Cost: audit ~2 hours; the policy decision and fix depend on what we find. Yield: high —
this is user-facing correctness, not test infrastructure.*

### Tier B — the real information. Higher cost, and B1 is the one I would most want.

**B1 · Mutation testing of the compiler.** Programmatically perturb `CodeGen.zbr` /
`TypeChecker.zbr` (invert a condition, drop an emit, change a constant), rebuild, run the
gates, record whether **anything** noticed. Over a few hundred mutants this yields a
number that means something concrete: *"our gates catch N% of changes to the compiler."*
It is `gate_selfcheck.sh` aimed one level deeper — and it is the honest substitute for a
coverage percentage when coverage tooling is awkward.
*Cost: ~2 days to build, then overnight runs (each mutant needs a rebuild). Yield: the
highest of anything here, because it is the only item that measures what we are NOT
testing rather than adding more of what we are.*

**BUILT 2026-08-01 — `tools/mutation_check.py`. Three things the plan got wrong.**

1. **The cost estimate was off by an order of magnitude.** "Each mutant needs a rebuild"
   assumed the full `rebuild.sh` cycle. Mutating ONE module and regenerating only that
   module is **22 s**, and `zig build` on one changed module is **3 s**. A no-effect
   mutant now costs ~45 s end to end, so a few hundred is an evening, not a weekend.

2. **A raw survived/detected split is misleading, and would have produced a false
   headline.** The first 5-mutant sample reported *0 detected, 5 survived* — i.e.
   "gates catch 0% of compiler mutations". That was wrong: all five mutations left the
   emitted code **byte-identical**, because CodeGen has 3,559 mutable sites and much of
   it (GUI backends, node-addon, rarely-used stdlib methods) is unreachable from
   anything the corpus compiles. The tool now fingerprints the emit and reports a third
   verdict, **NO-EFFECT**, so the percentage is computed only over mutations that
   actually changed generated code. Without that split the number is dominated by dead
   code and means nothing.

3. **Isolation is mandatory, not tidy.** A run leaves the compiler broken for seconds at
   a time, hundreds of times over; a session sharing the checkout would be handed a
   compiler that is not what it thinks it is — exactly the hazard behind BUG-238. Runs
   happen in a git worktree, which must be a **sibling** of the repo because `build.zig`
   has a path dependency on `../earley`.

**Pilot results (13 mutants, two samples).** CodeGen 5/5 no-effect. TypeChecker 8: two
detected, six no-effect, **zero survivors** — and both detections came from the **A3
boundary suite**, which is a satisfying loop: the intent-written probes catch compiler
mutations that no golden baseline would.

**What is NOT yet established, and the sample is far too small to claim otherwise:** the
headline "gates catch N%" needs a few hundred mutants, not thirteen. What the pilot DOES
establish is that the harness reports both verdicts on real mutations, that its baseline
check refuses to run on a red tree, and that its cost per mutant is affordable. Two of
its own bugs were caught by that baseline check — a worktree that could not build, and a
detector silently broken by WSL path translation, either of which would have produced a
confident, meaningless score.

**⚠ RETRACTED 2026-08-01 — THE 300-MUTANT RUN BELOW IS INVALID. Read this first.**

The run reported *"241 of 300 detected by regen — the bootstrap refused to compile the
mutant"*, and I drew a confident conclusion from it: that self-hosting is a powerful
unremarked safety net, four in five perturbations being fatal to the compiler's own
regeneration. **That conclusion was wrong, and the data behind it was manufactured by a
bug in the harness.**

The harness restored the mutated source after each mutant with

    src.write_text(original, encoding="utf-8")      # no newline="\n"

On Windows Python rewrites that file with **CRLF**, and the Zebra tokenizer rejects a
lone `\r` — `error: unexpected '\r' (CRLF line endings — convert to LF)`. So mutant 1
restored, corrupted `CodeGen.zbr`, and **every later regen failed for that reason
alone**. The harness scored each as "the bootstrap refused this mutant". Running those
same mutants by hand, the bootstrap emits them without complaint.

The apply site had `newline="\n"`. The restore site did not. CLAUDE.md documents this
trap in a section of its own, which did not prevent it.

**The tell I had and ignored:** regen "detections" completed in ~20 s while every other
outcome took 45–270 s. A detection that is *faster than the work it claims to have done*
deserves a look. It is the same shape as the two earlier harness bugs the baseline check
caught (a worktree that could not build; a detector broken by WSL path translation) —
all three produce confident results from an instrument that is not measuring.

**What survives the retraction:**

* the cost measurements (22 s regen, 3 s build) — unaffected, independently verified;
* the NO-EFFECT classification and why it is necessary — unaffected;
* that 15 mutations were caught by the A3 boundary suite — those required regen to
  SUCCEED, so they are real detections;
* **nothing about self-hosting.** That claim is withdrawn entirely, not weakened.

The corrected run is below the retracted block.

---

**RETRACTED — 300-MUTANT RUN, 2026-08-01 (1.7 h, median 16 s/mutant). Kept for the
record because the failure is more instructive than the result would have been.**

```
mutants: 300   detected: 256   survived: 0   no-effect: 44

  detected by regen           241  (80%)   the BOOTSTRAP refused to compile the mutant
  no-effect (identical emit)   44  (15%)   changed nothing we compile
  detected by boundary         15  ( 5%)   OUR GATES
  detected by hello / smoke     0  ( 0%)   never reached
```

**"Gates caught 100% of live mutations" is true and misleading.** Only **15 of 300**
mutations ever reached a gate. The other 241 never got that far because a mutated
compiler *cannot compile itself* — the regeneration step rejects it. So this run mostly
measured the **self-hosting property**, not the test suite.

**Three things worth keeping from that:**

1. ~~**Self-hosting is doing enormous, largely unremarked defensive work.**~~
   **WITHDRAWN.** The 241 "regen refusals" were a CRLF bug in the harness, not the
   bootstrap rejecting anything. Nothing in this run says anything about self-hosting
   as a safety net, in either direction. Establishing that would need a run where the
   source is not being corrupted between mutants — which is what the corrected harness
   now does.

2. **The gate measurement rests on n=15, not n=300.** 15/15 caught is encouraging and
   is *not* the "our gates catch N%" number the plan wanted. The confidence interval on
   fifteen samples is wide enough that the honest statement is "no survivors yet".

3. **All 15 were caught by the A3 boundary suite** — written two days earlier — while
   `hello-world` and `smoke` (263 fixtures) caught **zero**. Not because smoke is weak:
   boundary simply runs earlier in the cascade and got there first. But it does mean the
   intent-written probes are, so far, the only thing demonstrably catching compiler
   mutations that survive self-compilation.

**What B1 v2 needs, and it is a design change not more samples:** mutations that survive
regeneration. Random operator flips are mostly *too destructive* — they break the
compiler before it can produce a differently-behaving compiler. Targeting is the fix:
mutate only within functions the canaries demonstrably execute, or prefer edits on
rarely-taken branches (error paths, fallbacks, edge cases) which are exactly where a
compiler bug hides and exactly what survives self-compilation. That is the run that
would produce a real coverage number.

**Reproduce:** `python tools/mutation_check.py --limit 300 --seed 1`

**B2 · Real coverage measurement — spike first, commit second.** Determine whether we can
get branch coverage of the compiler on Windows (Zig's fuzz instrumentation, kcov under
WSL, or — the interesting option — teaching Zebra itself to emit coverage counters, which
would serve users too).
*Cost: 1 day spike to find out if it is feasible at all. Do not commit to the full item
before the spike reports.* If feasible it supersedes much of B1's role; if not, B1 stands
in for it.

### Tier C — ongoing, after 0.9

- **C1 · Mutation fuzzing of valid programs.** dbsqlfuzz's actual trick is mutating
  *valid* inputs, not generating from a grammar. `fuzz/gramgen.py` generates; nothing
  mutates. Different bug population.
- **C2 · Contract density inside the compiler.** Zebra has `require`/`ensure`/`invariant`
  and `--turbo` to strip them — SQLite's `assert()` discipline, except ours is a language
  feature. The compiler uses them sparsely. Dogfooding here tests the feature *and* the
  compiler.

  **PILOT RUN 2026-07-30 — feasibility proven, zero bugs found, and the null result is
  the useful part.** Measured dogfooding gap first: **~733 defs across `selfhost/*.zbr`,
  7 `require`, 0 `ensure`, 1 `invariant`.** `Parser.zbr` (97 defs) and `TypeChecker.zbr`
  (129 defs) had none at all. Added a class `invariant` plus `require`/`ensure` to the
  Parser cursor (`peek`, `peekAt`, `advance`), then rebuilt and ran the corpus.

  * **Feasibility: proven.** The compiler rebuilt itself with contracts live on its own
    parser; contracts survive regeneration through the bootstrap; QUICK tier 9/9 with
    smoke 262/262 and a byte-identical round-trip.
  * **Bugs found: zero.** No contract fired anywhere in the corpus.
  * **Cost: real but bounded.** Smoke went ~178s → ~210s (~15–20%, and run-to-run
    variance is wide enough that this is an observation, not a benchmark). `--turbo`
    strips them, so release builds are unaffected — but our gates run with them ON.

  **The lesson is a correction to the pilot's own design.** I deliberately chose clauses
  I was *certain* already held, to avoid manufacturing false failures. That choice
  guaranteed the null result: **a contract you are certain holds is documentation; a
  contract you are only fairly sure holds is a test.** The productive zone is the
  uncomfortable middle — properties you *believe* hold but have never checked.

  So the next aim is not "more contracts", it is contracts pointed somewhere invariants
  are genuinely unverified: `TypeChecker` (129 defs, zero contracts, and the phase whose
  wrong beliefs produced BUG-215/218/222/223), and CodeGen's index arithmetic. The Parser
  cursor was the *safest* target and therefore the least informative one.
- **C3 · Sanitizer runs** of the corpus (ReleaseSafe + UBSan) as a periodic sweep.
- **C4 · Release checklist**, written once, followed every release.

---

## 4. What we are deliberately not doing, and why

| skipped | reason |
|---|---|
| Crash / power-loss simulation | no durability contract; a compiler that dies re-runs |
| A second independent harness (TH3-style) | needs a second team; the bootstrap↔selfhost pair is our version and it exists |
| Cross-implementation differential | no third-party Zebra implementation to compare against |
| Targeting a test:code ratio | an output of coverage work, not an input; chasing it yields bulk |
| Leak detection as a priority | the arena model does not free by design — leaks are the architecture, not a bug |

---

## 5. Recommended sequence

1. **A1** (an hour, and it will produce a number today)
2. **A4 audit** (it is the only item that is about *shipped* behaviour rather than tests)
3. **A2** (cheap, reuses the behaviour baseline)
4. **B2 spike** — decide B1-vs-B2 on evidence rather than assumption
5. **A3** (the largest authoring effort; worth doing while B-tier is being built)
6. **B1** or **B2 proper**, per the spike

A1 through A4 are what I would want done before calling anything 0.9. B is what turns
"the gates are green" into "we know what fraction of breakage the gates would catch,"
which is the difference between confidence and evidence.

## 6. What this cannot buy

Even with all of it: no gate here clicks a GUI, and six green gates once sat on top of
three real GUI crashes. Rendering and interaction are still only ever proven by a human
running the thing. That limitation is not addressed by anything in this plan and should
not be papered over by how thorough the rest of it looks.
