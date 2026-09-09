<!-- doc-status: live -->
# CLAUDE.md

Guidance for Claude Code (claude.ai/code) in this repository.

## What this is

**Zebra** is a programming language whose compiler is written in Zig, with an
in-progress self-hosted port in Zebra itself. The name is a portmanteau of Zig
and Cobra; language design draws on Python, Cobra, and Eiffel (contracts, nil
tracking) with a Zig runtime and error model.

History note: this repo was split out from the archived `torial/cobra-language`
repo on 2026-04-16. See `docs/archive/HERITAGE.md` for the background and where the older
history lives.

## Repository layout

- `src/` — the Zig-implemented Zebra compiler (Tokenizer, Parser, Resolver,
  TypeChecker, CodeGen, Builtins, etc.). This is the trusted/production compiler.
- `selfhost/` — the in-progress self-hosted compiler written in Zebra (`*.zbr`).
  Each phase mirrors a file in `src/` (e.g. `Parser.zbr` ↔ `src/Parser.zig`).
  Compiler module files are **PascalCase** to match the Zig `src/` naming
  (`Ast`, `AstWalk`, `AstBuilder`, `CgHelpers`, `Checker`, `CodeGen`, `Parser`, `Resolver`,
  `TypeChecker`, `Token`, `Lexer`; `main` stays lowercase per Zig convention).
  Paired `*.zig` files are generated artifacts (`Parser.zbr` → `Parser.zig`).
- `test/` — integration test suite (`.zbr` fixtures + runners).
- `tools/` — ancillary tools (build/runner scripts, etc.).
- `examples/` — sample Zebra programs.
- `build.zig` / `build.zig.zon` — Zig build driver.
- `zbuild` / `zbuild.bat` — convenience wrappers around `zig build`.
- `QUICKSTART.md` — **agent-facing Zebra language reference**. Read this before
  writing or reading `.zbr` code.
- `SELFHOST_JOURNAL.md` — phase-by-phase notes on porting the compiler to Zebra.
- `BUGS.md` — active compiler bug tracker.
- `NEXT_STEPS.md` — **a ROUTER over five files**, not a queue (split 2026-08-29; it
  was 3,845 lines, which is why nobody read it before planning). Read the one that
  matches the KIND of thing you are doing:
  - `docs/PRINCIPLES.md` — **how we decide**: the system concept, four gates, seven
    ranked axes, accepted tensions. **Read this before proposing or judging work.**
  - `docs/FINDINGS.md` — **what we already know**: measurements, recorded so nobody
    re-derives them. Check here before measuring anything.
  - `NEXT_STEPS_to_0.9.md` / `_to_1.0.md` / `_post_1.0.md` — the queues.
- `STDLIB_ROADMAP.md` — standard library plan.
- `grammar.txt` — language grammar reference.

## Build and test

From the repo root:

```bash
zig build                                    # build the Zebra compiler
zig build run -- path/to/file.zbr            # compile and run a Zebra source file
zig build test                               # run the test suite
./zbuild                                     # convenience wrapper (Unix)
zbuild.bat                                   # convenience wrapper (Windows)
```

Module resolution: `use module_name` is looked up relative to the input file,
then in `selfhost/`, `test/`, and stdlib paths.

## Rebuild + gate runners (start here)

Three wrappers encode the sequences below so you don't reassemble them by hand:

```bash
bash tools/doctor.sh           # is this tree in a state where results can be TRUSTED?
bash tools/doctor.sh --fix     # ...and clear what is safely clearable
bash tools/rebuild.sh          # make a selfhost/*.zbr edit REAL (regen + build)
bash tools/rebuild.sh --no-regen   # build only (no .zbr changed)
bash tools/rebuild.sh --module CodeGen   # THE INNER LOOP: regen ONE module + build, ~10s
bash tools/gates.sh --static   # STATIC (~15s): needs NO BUILD — for a docs/tools/ledger edit
bash tools/gates.sh --fast     # FAST (~2 min): everything except smoke + round-trip
bash tools/gates.sh            # QUICK (~14 min): + smoke + round-trip. After any .zbr edit
bash tools/gates.sh --full     # FULL (~40 min): + the heavy corpus witnesses
bash tools/gates.sh --daily    # DAILY: + gramgen, gui-scaffold(+panel), node-addon. Once a day
bash tools/gates.sh --list     # what each tier runs and what it cannot see
```

`rebuild.sh` exists because the regen sequence has four footguns that have each
cost real time: `zig build update-selfhost` **silently skips** regeneration after a
`.zbr`-only edit (BUG-210); a stale `/tmp/bs-zig` from a killed run causes unrelated
failures; an orphaned `zebra.exe`/`zig.exe` holds a file lock so the build dies
with `AccessDenied`; and a **preamble edit is invisible to the regen until the
bootstrap is rebuilt** (below). It also verifies the built compiler can actually run a
hello-world before reporting success.

**A `stdlib_preamble.zig` edit needs the full sequence *and* the right order.** Two
distinct traps, one at each end:
- The preamble is inlined at emit time, so the compiler only picks up a preamble
  change after **regeneration** (this is what made BUG-219's first fix look like it
  hadn't worked).
- `build.zig:37-59` **embeds** the preamble files into `zebra-bootstrap.exe` at *build*
  time, and the regen runs that binary — so regenerating before rebuilding the
  bootstrap emits the **old** runtime, and every gate downstream measures it. Observed
  2026-07-28: a preamble edit followed by `rebuild.sh` reported OK and changed zero
  generated files. The order is `zig build` → regen → `zig build`; `rebuild.sh` now
  does the leading build itself when one of the bootstrap's INPUTS is newer than the binary.

**"Inputs" meant only the two preambles until 2026-08-26, and the gap cost a failed regen
that blamed the wrong thing.** The preambles are *embedded* at build time; everything in
`src/` is *compiled into* the binary. Identical staleness, and only the first was covered.
Adding `File.tryDelete` to `src/TypeChecker.zig` and using it from `selfhost/main.zbr`
regenerated against an older bootstrap and failed with `expected 'bool', got 'void'` —
**a type error naming the very feature being added**, which reads as "your new code is
wrong" rather than "your compiler is stale". Same reassuring-but-wrong direction as
BUG-302's `CFAIL`. The list is now
`stdlib_preamble.zig napi_preamble.zig src/*.zig build.zig`.

`bash tools/rebuild_guard_check.sh` (~1 s, no build, NOT a gate) falsifies that condition
against controlled timestamps — because **the real rebuild could not**: the loop breaks on
its first match, and after the fix the preamble happened to be newest, so the run fired
citing the preamble and the `src/` arm was never exercised. "The rebuild worked" was not
evidence that it would. Six legs, two of which carry the weight: a **control** (with
nothing newer it must NOT fire — otherwise an always-fires guard passes every other leg),
and the promise that **a `.zbr`-only edit still pays nothing**, which is exactly what
widening the list could have broken. Its copy of the condition is its weakness, so leg 0
compares that copy textually against the shipped tool and REFUSES (exit 2) rather than
passing against logic `rebuild.sh` does not have.

**`--module NAME` is the inner loop, and it is ~10 s against several minutes.** The full
regen re-emits every selfhost module and rebuilds the intermediate compilers first; when
you have edited one `.zbr` and want to see whether the change took, that is almost all
waste. It is sound because the regeneration is done by the **bootstrap**, whose output for
the other modules your edit cannot have changed — verified by regenerating an untouched
module and getting a byte-identical file. (Extracted from `mutation_check.py`'s `regen()`,
which had already run this path thousands of times; two details carried over deliberately —
redirect to a **file**, never a pipe, and check the emit header is actually present rather
than trusting `rc=0`.)

What it does **not** do is prove the regenerated set is self-consistent — only the full
`rebuild.sh` runs the round-trip. So `--module` is for the edit/see/edit loop, and the full
sequence before gating or committing. It **refuses** if a `selfhost/*.zbr` is modified and
not named in `--module` (`--force` overrides): regenerating a subset leaves the tree
half-updated, and every gate downstream then measures a compiler that is partly old.

**Orphan-killing is scoped to this tree (`tools/kill_orphans.sh`), and that matters more
than it sounds.** `rebuild.sh` and `doctor.sh --fix` used to run `taskkill //F //IM
zebra.exe` — machine-wide. On 2026-08-01 that killed a mutation run's bootstrap in the
sibling worktree, mid-mutant, from a `rebuild.sh` in the main checkout. The victim of such
a kill does not see "someone killed me"; it sees a regeneration that failed for no visible
reason, and a harness scores that as a *result*. This repo regularly has two agents working
in it at once, plus isolated worktrees whose entire purpose is not to be affected from
outside. The lock being cleared (`AccessDenied` on `zig-out/bin`) is only ever held by a
process running from *this* tree, so path-scoping loses nothing — and the tool now prints
what it is leaving alone, because silence is what made the old behaviour look like an
unrelated failure.

`doctor.sh` checks the failure modes this environment actually produces, every one of
which has bitten us: **stale generated `.zig`** (you would be testing the OLD compiler —
`zig build update-selfhost` silently skips regeneration, BUG-210, and this made a real
BUG-219 fix appear not to work), orphaned compiler processes holding a lock on
`zig-out/bin` (→ `AccessDenied`), stale `/tmp/bs-*` scratch from a killed run causing
unrelated failures, a compiler that cannot run a hello-world, and low RAM before a
RAM-bound gate. It exits **1** only for states that make results *lie*; everything else
is a warning. **`gates.sh` runs it as a preflight and refuses to report on an
untrustworthy tree** — a green gate that measured the wrong compiler is worse than no
gate at all.

**IF YOU SCRIPT A WAIT AROUND `gates.sh`, IT HAS TWO TERMINAL LINES, NOT ONE.** A green run
ends `gates: N/M PASS (tier)`; a red one ends `gates: N FAILED — name name`. They share no
substring beyond `gates:`, so a waiter that greps only the PASS form waits forever on
exactly the runs you most want to hear about — and a sleeping waiter is indistinguishable
from a gate still working.

Receipt, 2026-08-22: a wait-loop matching `gates: N/M PASS` sat polling for **11.5 hours**
after the `--daily` it was watching had finished in 1h54m, because that run ended
`gates: 3 FAILED`. It burned no CPU, which is why nothing looked wrong; it was reported as
a daily "going long". The same defect was found and fixed in a SECOND loop an hour after
this one was launched, and the fix was never carried back to the instance still running —
so the lesson had been written down while the bug was live. Match `gates:` and classify
after, or wait on the process rather than its output.

**AND THE FIRST HALF OF THAT ADVICE IS WRONG — measured 2026-09-04, by following it.** A run
also PRINTS A HEADER, `gates: quick (JOBS=2)`, before it does any work. So a loop waiting on
the substring `gates:` matches within the first second and reports a tier that has not
started as though it had finished — the same false completion the 11.5-hour receipt above
describes, reached by the remedy written to prevent it, and arriving INSTANTLY rather than
never, which is the more convincing of the two failures.

Three lines share the prefix; only two are terminal:

| line | when |
|---|---|
| `gates: quick (JOBS=2)` | at START — not a result |
| `gates: N/M PASS (tier)` | terminal, green |
| `gates: N FAILED — name name` | terminal, red |

`grep -qE 'gates: .*(PASS\|FAILED)'` distinguishes them. **Waiting on the PROCESS remains the
better answer** — it is the half of the original advice that survives, and it needs no
pattern at all.

**A SECOND DEFECT, in the waiter rather than the pattern, found the same hour.** A bounded
`for i in $(seq 1 N); do grep -q … && break; sleep 5; done` that EXHAUSTS its iterations
falls out of the loop and continues, so it prints an empty result and exits 0 — identical
to the output of a run that finished green. A waiter must distinguish TIMED OUT from
MATCHED and say which; a bare `break` on success is only half the branch.

`gates.sh` runs the set in order with one summary line each and exits non-zero on
any failure. It deliberately does **not** fold in the GUI paths, `fuzz/gramgen.py`,
or `node_addon_test.sh`, so that "gates green" keeps a precise meaning — see its
`--list` for the honest limits. On GUIs the line moved on 2026-07-30: **no gate proves
RENDERING, but startup is now covered** by `tools/gui_scaffold_check.sh` (BUG-229). Four
GUI crashes have sat under fully green gates, and all four were at *startup* — which
needs neither a human nor a terminal to detect. Rendering, input, layout, resize and
colours still require Sean running it.

## The tier ladder — and why it is cut on BUILD-DEPENDENCE, not on seconds

`bash tools/tier_selfcheck.sh` (~2 min, NOT a gate) asks whether the ladder can still
fail. `gate_selfcheck.sh` falsifies the individual gates; this falsifies the thing that
decides WHICH gates run, because a selector is a new way to print green — filter wrongly
and the board shows fewer PASSes and no failures, which reads exactly like success. Six
mutations on a COPY of `gates.sh`, each of which must be caught: an impure gate tagged
static, a purity detector that stopped matching, a collapsed per-tier count, a gate that
silently did not run, a pin that started passing — plus an unmutated control, without
which every "detection" could be an unrelated breakage. Run it after touching `gates.sh`.

**Its control caught two real things on its first two runs**, both of them the harness's
fault rather than the ladder's, and both worth knowing: a probe file named `*.sh` turned
`doc-lint` red BY EXISTING (it matched a live script-count oracle), and a mutation that
replaced only one branch of the purity pattern left another branch matching, so the guard
correctly did not fire — a cooperative attacker, which this repo has written down as the
way a guard gets declared tested without being tested.



Five tiers, **cumulative**: each runs everything below it. `--list` prints the live
per-tier counts, computed from the registrations rather than written down.

| tier | gates | cost (measured range) | run it when |
|---|---|---|---|
| `--static` | 14 <!-- doc-gen: 14 = echo $(( $(grep -cE '^[[:space:]]*(run|pin)_static "' tools/gates.sh) )) --> | **108-121 s** (was 14 s) | you edited docs, ledgers, or `tools/` |
| `--fast` | 29 <!-- doc-gen: 29 = echo $(( $(grep -cE '^[[:space:]]*(run|pin)_static "' tools/gates.sh) + $(grep -cE '^[[:space:]]*(run|pin)_fast "' tools/gates.sh) )) --> | **~2.5 min** | mid-change, before you believe anything |
| (default) | 31 <!-- doc-gen: 31 = echo $(( $(grep -cE '^[[:space:]]*(run|pin)_static "' tools/gates.sh) + $(grep -cE '^[[:space:]]*(run|pin)_fast "' tools/gates.sh) + $(grep -cE '^[[:space:]]*(run|pin)_quick "' tools/gates.sh) )) --> | **7–20 min** | after any `.zbr` edit |
| `--full` | 39 <!-- doc-gen: 39 = echo $(( $(grep -cE '^[[:space:]]*(run|pin)_static "' tools/gates.sh) + $(grep -cE '^[[:space:]]*(run|pin)_fast "' tools/gates.sh) + $(grep -cE '^[[:space:]]*(run|pin)_quick "' tools/gates.sh) + $(grep -cE '^[[:space:]]*(run|pin)_full "' tools/gates.sh) )) --> | **36–83 min** | before committing a codegen change |
| `--daily` | 44 <!-- doc-gen: 44 = echo $(( $(grep -cE '^[[:space:]]*(run|pin)_static "' tools/gates.sh) + $(grep -cE '^[[:space:]]*(run|pin)_fast "' tools/gates.sh) + $(grep -cE '^[[:space:]]*(run|pin)_quick "' tools/gates.sh) + $(grep -cE '^[[:space:]]*(run|pin)_full "' tools/gates.sh) + $(grep -cE '^[[:space:]]*(run|pin)_daily "' tools/gates.sh) )) --> | **37–130 min** | once a day |

**The gate counts carry `doc-gen` oracles as of 2026-08-22.** They did not before, and four
of the five went stale the moment one gate was registered (`bug302-control`) — silently,
in the table whose whole job is to say what each tier covers. `--list` already computed
these live "rather than written down"; the table beside it was written down. That is the
D8 hazard in miniature: a number with no instrument, sitting next to prose that sounds
measured.

**THE COSTS ARE RANGES BECAUSE THEY MEASURED A 3x SPREAD, and the honest version took
three attempts.** The default tier was documented as "~6 min"; it was then measured at
14 min, then at 19m35s inside a `--daily` run, then at **7m05s** on an idle tree with warm
caches. All three are real. `smoke` alone accounts for nearly all of it — **214 s, 647 s
and 774 s** across those runs — with `round-trip` (141–285 s) second. Together they are
**85–99%** of the default tier in every measurement; the other 21 gates total about two
minutes regardless, and 14 of them finish in under two seconds combined.

**So the two things that vary are the two heaviest gates, and everything cheap is
stable.** That is why `--static` and `--fast` have tight numbers while the tiers above
them have ranges, and it is the ladder's actual argument: the rungs that answer fastest
are also the rungs whose cost you can predict. A single figure labelled "measured" would
have been true of one afternoon and wrong by a factor of three the next morning — the same
over-read this section warns about two paragraphs earlier, which is how it got written
wrong twice before landing here.

**AND THE PARAGRAPH ABOVE WAS ITSELF WRONG BY 8x, MEASURED 2026-08-29.** `--static` is not
14 s. Timed twice on an idle machine: **108 s and 121 s** — a consistent pair, not a fluke.
The claim that the cheap rungs have "tight numbers whose cost you can predict" was the one
part of the ladder's argument nobody had re-measured, because a tier that finishes before
you look away never invites a stopwatch.

**Where the time goes, since the arithmetic is the useful part.** Per-gate seconds sum to
**37 s**; `doctor` takes **28 s**; the remaining **~43 s** is per-gate process overhead, which
matches the run's 45 s of `sys` against only 15.6 s of `user`. So barely a seventh of the
wall clock is computation, and the original 14 s figure is roughly the `user` time — a
plausible reading of a stopwatch that measured the wrong thing.

**The obvious hypothesis was tested and FAILED**, and is recorded rather than replaced with a
tidier one: both compilers were rebuilt that day, which invalidates zig's cache, so `doctor`'s
hello-world compile looked like the culprit. `doctor` runs **28 s cold and 28 s warm**. Cache
is not the cause.

**LOAD WAS RAISED AS THE CONFOUND AND THEN RULED OUT — three runs: 108 s, 121 s, 107 s.**
Sean's caution is correct in general (it is why `smoke` carries a 720-1490 s range two sections
down) and a consistent PAIR would not have settled it, since two runs inside one busy stretch
are both slow. So a third was taken deliberately away from any commit — every commit fires
`zsnapshot`, which writes a ~15 MB zip, and that is real self-inflicted load that plausibly
overlapped the first two. It measured **107 s**, with CPU sampled at 0% BOTH BEFORE AND AFTER
the run rather than only before.

**And the `user`/`sys` split explains why load was never a good candidate here.** 15.6 s user
against 45 s sys and ~108 s wall means the tier is SPAWN- AND I/O-BOUND, not CPU-bound — so CPU
pressure would barely move it, which is also why the three runs agree so closely. A tier that
is 14% computation behaves nothing like `smoke`, and the two should not be reasoned about the
same way.

**One reading that survives, and is worth knowing before "wrong" is said too loudly:** `user`
time is 15.6 s, almost exactly the original 14 s. The old figure may have been a correct
measurement of CPU time rather than a wrong measurement of wall clock — in which case both
numbers are right and answer different questions. What a person waiting on a rung experiences
is wall clock, so that is what the table now carries.

`--full` is not measured directly (no run has used the flag): every figure is a `--daily`
wall clock minus its three daily-only gates, which is sound because the runner is
sequential — 2206 s − 68 s, 3383 s − 77 s, 5056 s − 83 s. Per-gate seconds sum to within
~30 s of wall clock in all three runs, so the overhead outside the gates is preflight and
printing.

**SMOKE'S OWN SPREAD MEASURED DIRECTLY, 2026-08-23 — 720 s to 1490 s ON IDENTICAL
BINARIES.** Four consecutive standalone runs of `selfhost_smoke.sh`, two on each of two
builds differing by one function, on an idle machine: 1369 s, 720 s (build A) and 850 s,
1490 s (build B). Ranges overlap completely; the build with the EXTRA work averaged
FASTER. Earlier the same night the same suite ran 343 s and 359 s.

Two things follow. **A 2x swing is normal here, so a single timing proves nothing** — this
sequence was run to decide whether a code change had caused a regression, and one
measurement in either direction would have "confirmed" whichever answer was expected. Take
pairs. And **the 2700 s `GATE_TIMEOUT` is closer than it looks**: a run at the top of the
observed range plus the tier's other work is within a factor of two of it, and smoke
timing out is indistinguishable from smoke hanging.

What moved between the 350 s pair and the 700-1500 s quartet is NOT established. It is
recorded as an observation rather than given a cause it has not earned — the same
discipline the `output_sweep` note above uses for its unexplained disagreement.

**THE UPPER BOUND MOVED AGAIN ON 2026-08-20 (57 → 85 min), and the cause is NOT the two
gates that explain the QUICK spread.** `smoke` was 604 s and `round-trip` 208 s in that
run — squarely mid-range — while `output_sweep` went 623 s → **1402 s** and `divergence`
675 s → **1169 s**, on a machine with nothing else running. Those two are the RUN-the-
corpus and BOTH-compilers gates, so they are the ones most exposed to whatever the
environment is doing, and no explanation here has been tested. Recorded as an observation:
the heavy tiers are predictable to within a factor of two, and anyone budgeting an hour
for `--daily` should budget ninety minutes.

The untested hypothesis, named so a later run can DISCRIMINATE rather than re-argue it:
`src/CodeGen.zig` was rebuilt twice that night (falsifying BUG-124 needs a mutated
bootstrap), which invalidates zig's cache for everything downstream. That fits
`divergence`, which compiles the corpus with BOTH compilers; it does NOT obviously fit
`output_sweep`, which runs already-built binaries. **A fourth `--daily` landing near
37 min on a warm untouched tree is the observation that would settle it** — cheap, and
nobody has to reason about it in the meantime.

**The cut is on build-dependence, and cost is the wrong axis even though cost is the
motivation.** Timings are taken on a WARM tree: `zig-test`, `ffi-lib` and `diag-columns`
each measure ~1 s only because the binaries happen to be current, and cost a full build on
a cold one. A tier whose advertised cost stops being true exactly when you most want it —
mid-edit, nothing rebuilt — is a tier that lies. Build-dependence is stable, derivable,
and answers the question you actually have: *does this change need a compiler to judge?*

**It was MEASURED, not reasoned.** The 12 static gates were established by hiding
`zig-out/bin/zebra*.exe` and running the candidates: all 12 passed with no compiler
present, and two controls (`str-ownership`, `diag-columns`) REFUSED — so the experiment
can discriminate. Re-run that by hand when adding a static gate. Every run also re-derives
the cheap half (`_static_purity_check`): a tool registered `run_static` must not mention
`zig-out`, `zebra.exe` or `zig build`, and the check refuses if its own control — a known
build-dependent tool that must match — stops firing.

**`--static` is the one tier that does not refuse on a `doctor` failure.** Everything
doctor gates is about the BINARY being stale or unbuildable, and no static gate reads the
binary — which is not an assertion, it is what the purity check has just verified. The
warning is printed loudly; every tier above static still refuses.

**BUT THE PREFLIGHT IS BUILD-DEPENDENT EVEN WHERE THE GATES ARE NOT (found 2026-08-29), and
that is a hole in this tier's advertised property.** `doctor.sh` carries 19 references to
`zig build` / `zig-out` / `zebra.exe` and compiles a hello-world, and it runs as the preflight
for EVERY tier including `--static`. So the tier's VERDICT is build-independent — the purity
check proves that, and doctor cannot fail it — while the tier's COST is not: 28 of its ~110
seconds are spent doing exactly the build-dependent work the tier claims not to need. A rung
advertised as "needs NO BUILD" that spends a quarter of its time on the binary is making a
promise about its gates and being read as a promise about the run.

**Proposed, NOT done:** run doctor's cheap checks and skip the hello-world compile when the
tier is `--static`. Deliberately left as a proposal because it changes the SELECTOR rather
than an instrument, and `tier_selfcheck.sh` exists precisely because a selector is a new way
to print green — its six mutations should pass before and after any such change.

**A KNOWN-RED gate is PINNED, not excluded.** `pin_daily "node-addon" "BUG-297"` runs the
gate, prints `XFAIL`, does not fail the tier — and **fails the tier the day it starts
passing**, because a pin that has come good is a registration nobody updated. That is the
`@boundary-pending` idiom applied to a whole gate, and it exists because exclusion is
precisely what let this bug rot: node-addon was in no tier, its last recorded sweep was
2026-08-04, and it had regressed silently by 08-19.

**THE CONVENTION (Sean, 2026-08-19): `--daily` IS THE LAST THING RUN WHEN OVERNIGHT WORK
STOPS.** Not a scheduled job — a closing move. Whatever was being worked on overnight ends
with a full `--daily`, so the tree is left in a state someone can trust in the morning and
the exhaustive set gets run against the day's actual changes rather than against whatever
happened to be committed when a timer fired. It also puts the run where its cost is free:
nobody is waiting on it.

The corollary is the cheap rungs during the work — `--static` after a doc edit, `--fast`
mid-change, the default after a `.zbr` edit — and the expensive one at the end. The ladder
is built for exactly that shape.

**Nothing enforces it.** `--daily` is a set, not a schedule; the cadence is the habit
above.

## Every document says what it is (read this before reading the docs)

Line 1 of each `.md` carries `<!-- doc-status: ... -->`, one of four values. It exists so
a session arriving cold can tell what to *skip* rather than guessing:

| status | meaning | what to do |
|---|---|---|
| `live` | describes CURRENT state | trust it — and keep it true when you change things |
| `historical` | append-only record or dated snapshot | **skip unless you want the history.** Accurate as of its entries; do NOT "fix" a stale reference — that falsifies the record |
| `design` | a design/decision note | read only when touching that subsystem; may describe intent that is not built. Each carries its own `Status:` line |
| `generated` | produced by a tool | **skip.** Edit the tool, not the file |

**13 of the 55 documents are `historical` or `generated`** <!-- doc-gen: 55 = git ls-files | grep -cE '^[^/]+\.md$|^docs/[^/]+\.md$' --> <!-- doc-gen: 13 = for f in *.md docs/*.md; do head -1 "$f" | grep -qE 'doc-status: (historical|generated)' && echo x; done | wc -l | tr -d ' ' -->,
i.e. skippable with confidence. That is the point: the surface area of this repo's
documentation is what let one wrong claim live in four files at once, and "which of these
is current?" was previously answerable only by reading them.

`doc_lint` D7 enforces the declaration, and its own archival-vs-live split now READS it.
It used to hardcode four filenames — a list that was itself the hazard it guarded against,
since it would have gone silently wrong the first time someone added an append-only
document. A declaration cannot drift out of sync with the file it is written in.

## The corpus is what git TRACKS, not what is on disk

Every heavy gate used to enumerate its corpus with a filesystem glob (`ls test/*.zbr`),
which made its result depend on whatever untracked scratch happened to be in the
directory. Found 2026-08-01: `examples/zz_red_main.zbr`, a scratch probe, untracked, in a <!-- doc-lint-ok: the 2026-08-01 stray, named because a concrete instance is what makes the hazard real; cleared by tidy.sh --clean 2026-08-03, so a dangling name here is the tool having WORKED, not a broken link -->
directory `full_sweep --examples --gate` sweeps — invisible to anyone reading the commit
and not reproducible anywhere else.


The worst instance was not a sweep. `bug_fixture_check.py` decides whether a reported bug
has a regression fixture by looking for `test/bug<N>_*.zbr`, so an **untracked** file could
turn that gate **GREEN** by appearing to supply a fixture that exists for nobody else. The
sweeps could only add noise; that one could hide debt.

`tools/corpus_ls.sh` is now the single enumerator — `full_sweep`, `divergence_check`,
`boundary_check` and `bug_fixture_check` all go through it. It reads `git ls-files`, so
**staged counts**: staging is the point at which a file stops being scratch and becomes
something you are asking others to have. It **refuses** to fall back to a glob outside a
git worktree, because a silent fallback would reintroduce exactly the bug it exists to
remove. `gate_selfcheck` carries the inverse of its usual leg here: it plants an untracked
file and requires it to be **ignored** (having first confirmed a glob *would* have seen
it, so the control cannot pass vacuously).

`bash tools/tidy.sh` reports strays; `--clean` removes **only** known-scratch patterns
(`zz_*`, `_mut_*`, `probe_*`) and merely lists everything else. An untracked `.zbr` in
`test/` might be an abandoned probe or a fixture someone is three minutes from committing,
and the tool cannot tell — so it does not guess. **Name throwaway files `zz_*`** and they
become one command to clear.

## Verification gates (and what each one CANNOT catch)

Three complementary checks. They have **different blind spots** — running one is
not a substitute for another. After any codegen / inference / stdlib change, run
all three (`compile_check.sh` is the one most often forgotten and the one that most
often catches real emit bugs):

```bash
bash tools/selfhost_smoke.sh    # emits + runs fixtures. Blind to: emitted Zig that
                                #   fails to COMPILE (it only --emit-zig's most tests).
bash tools/bootstrap_check.sh   # selfhost round-trip (A/B byte-identical). Blind to:
                                #   (1) wrong-but-still-valid Zig (A & B share the bend
                                #   → identical wrong output, clean diff); (2) any program
                                #   it never compiles (the test corpus, ad-hoc probes).
bash tools/positive_set.sh         # THE POSITIVE-SET ENUMERATOR (not a gate) — the
                                #   tests selfhost_smoke declares must SUCCEED, derived
                                #   from its own registrations (smoke / smoke_run /
                                #   smoke_turbo / …; the *_fail helpers are negatives and
                                #   are excluded). One derivation, TWO consumers, for the
                                #   same reason corpus_ls.sh exists.
                                #   IT ALSO OWNS THE SKIP LIST (c_interop_test,
                                #   zig_interop_test, forgot_parens_test) — tests that
                                #   need external C/source the standalone emit never
                                #   materializes. HARNESS LIMITS, NOT BUGS. That list
                                #   used to live inside compile_check.sh, and when
                                #   full_sweep gained the same assertion it did not
                                #   inherit them: c_interop_test, correctly CFAIL in a
                                #   standalone sweep, would have been reported as a
                                #   MUST-PASS FAILURE. A gate that libels a working file
                                #   is one people learn to disbelieve.
                                #   REFUSES rather than printing an empty set (<100
                                #   entries = collapsed derivation). That guard fired on
                                #   its author within minutes of being written, when a
                                #   dropped newline collapsed 276 files into one string.
JOBS=3 bash tools/compile_check.sh   # THE INDEPENDENT WITNESS: emits every positive
                                #   test/*.zbr with the selfhost and runs `zig build-exe`
                                #   on the output. Catches emit bugs the other two miss
                                #   because `zig` fails DIFFERENTLY than the selfhost does.
                                #   Currently a MANUAL tool (not gated) — so its coverage
                                #   is only real on days it's run. `--only <substr>` for a
                                #   tight loop; `--bootstrap` to check the bootstrap's emit.
bash tools/libui_section_check.sh  # THE GUI-BACKEND WITNESS WITHOUT WINDOWS (2026-09-07):
                                #   emits an example with --gui-backend=libui_ng and runs
                                #   `zig build-obj -fno-emit-bin` against the REAL
                                #   zig-libui-ng bindings (extern fns need no library until
                                #   link). Catches wrong binding signatures in
                                #   selfhost/gui_libui_ng_section.zig — which NO other gate
                                #   compiles (tui builds skip it; ast-check sees only
                                #   syntax). Blind to: runtime (a wrong message id is not a
                                #   compile error). Needs LIBUI_BINDINGS=<zig-libui-ng/src>.
bash tools/win_sema_check.sh    # THE WINDOWS COMPILE WITNESS WITHOUT WINDOWS (2026-09-07):
                                #   emits programs and runs `zig build-exe -target
                                #   x86_64-windows-gnu -fno-emit-bin` — full Sema of every
                                #   `os.tag == .windows` branch of the runtime, from Linux.
                                #   First run caught the blind PeekNamedPipe path (BOOL enum
                                #   compared with 0). libui_section_check now targets
                                #   windows too. Blind to: runtime behaviour.
bash tools/styler_test.sh       # tokenizer unit test (`zig test` on the pure STYLER block
                                #   extracted verbatim from the libui section). RED-checked:
                                #   flipping a spec flag fails the matching tests.
JOBS=4 bash tools/divergence_check.sh --gate  # THE REGRESSION WITNESS (re-pointed 2026-09-01,
                                #   bootstrap sunset criterion 4). It used to compare the
                                #   selfhost against the BOOTSTRAP -- an IMPLEMENTATION-vs-
                                #   implementation question that only made sense while two
                                #   implementations existed. The bootstrap is now FROZEN, so
                                #   "can the frozen thing do something the advancing thing
                                #   cannot?" trends permanently to zero: an assertion going
                                #   vacuous BY DESIGN, which is worse than no gate because
                                #   the green keeps being reported.
                                #   IT NOW COMPARES AGAINST THE N-1 ANCHOR -- the compiler
                                #   built from the newest `n1-anchor-*` tag
                                #   (tools/n1_reference.sh, cached by COMMIT SHA so a moved
                                #   tag cannot serve a stale binary). The question is
                                #   VERSION-vs-version and stays useful forever: does this
                                #   compiler still handle everything the anchor handled?
                                #   THE TOKENS WERE RENAMED BECAUSE THE EPISTEMICS INVERTED.
                                #   `SELFHOST GAP` meant "the selfhost LAGS a reference
                                #   implementation"; it is now `REGRESSION` and means "this
                                #   compiler LOST something it used to do". `BOOTSTRAP GAP`
                                #   became `ADVANCE`. Every pre-2026-09-01 sweep note in this
                                #   file uses the OLD meaning -- do not compare the numbers.
                                #   BOTH COMPILERS ARE NOW INVOKED IDENTICALLY. The old code
                                #   had a `boot` branch emitting to STDOUT, because the
                                #   bootstrap produced a SELF-CONTAINED inline file. The
                                #   selfhost emits the MODULE shape, so a stdout redirect
                                #   writes an incomplete program: pointing the reference at an
                                #   N-1 selfhost through that branch scored EVERY file as an
                                #   advance (4/4 on the first smoke, boot=CFAIL throughout)
                                #   for a HARNESS reason. Unifying on --output-dir also
                                #   removed a year-old confound -- it had been comparing an
                                #   inline-shape emit against a module-shape one.
                                #   PRINTS THE ANCHOR ON EVERY RUN, pass or fail, and says
                                #   loudly when the anchor IS HEAD (a degenerate comparison
                                #   that can only report zero).
                                #   VERIFIED RED WITH A REAL ADVERSARY, not a mutation:
                                #   reference := the current selfhost, subject := the
                                #   BOOTSTRAP -> 7 REGRESSIONS, exit 1. Normal run: 0, exit 0.
                                #   Test hooks N1_REF_OVERRIDE / DIV_SELF_OVERRIDE exist for
                                #   exactly that and are used by no tier.
                                #   (was:) THE DRIFT WITNESS: emits the corpus with
                                #   BOTH compilers and compiles each. --gate exits non-zero
                                #   if any SELFHOST GAP (bootstrap compiles it, selfhost
                                #   doesn't) — i.e. the selfhost silently regressed vs the
                                #   reference. Catches selfhost↔bootstrap drift the others
                                #   miss (they all emit with ONE compiler). Baselined 0
                                #   selfhost gaps 2026-07-22. Bootstrap gaps (selfhost LEADS)
                                #   + agree-fails (negative tests) are informational, not gated.
                                #   Heavy → per-session/pre-release, like compile_check.
python fuzz/gramgen.py --gate   # THE PARSER-ROBUSTNESS GATE: derives 960 deterministic
                                #   grammar-valid programs (fixed seeds) and fails on any
                                #   HANG or CRASH (accept/reject divergences are expected,
                                #   don't fail it). Would have caught BUG-199 (an 18-byte
                                #   parser infinite loop) automatically. Complements the
                                #   above (which only ever see human-written programs).
                                #   Optional per-session; ~a few min. Needs both .exe built.
python tools/lint_interp_escape.py # THE INTERP-ESCAPE GATE (static, instant, no build):
                                #   flags a Zebra string that is BOTH interpolated (`${`) and
                                #   contains `\"`. The bootstrap — still the REGEN AUTHORITY for
                                #   selfhost/*.zig — double-escapes that combination, so the
                                #   corruption lands in the shipping compiler. It silently broke
                                #   all 3 genCopyOut `<<-`/`<-` diagnostics (they emitted a Zig
                                #   PARSE error instead of their message) until 2026-07-27.
                                #   BUG-216. 0 = clean. Retire when the bootstrap is fixed/gone.
python tools/hazard_lint.py        # THE TOOLING GATE (static, instant, no build) — the
                                #   only gate pointed at `tools/` rather than at Zebra code.
                                #   Five bugs were found in tools/mutation_check.py between
                                #   2026-07-31 and 08-01 and NOT ONE crashed, warned, or
                                #   exited non-zero: each produced a confident wrong NUMBER,
                                #   and two were published before being caught (241 fake
                                #   "regen detections" from a CRLF restore; a "0 survivors"
                                #   headline from a fingerprint that was a constant).
                                #   Hazards with receipts, each citing its incident: H1 a
                                #   .zbr text-write without newline="\n"; H2 bare `bash`
                                #   (resolves to WSL here) or a wsl-prefixed command; H3 a
                                #   constant sentinel on a path feeding a comparison —
                                #   always biases toward "nothing changed"; H4 a
                                #   compiler-SPECIFIC emit header (two compilers, two
                                #   headers); H5 `git checkout -- .`; H10 `$?` after a
                                #   PIPELINE (that is the LAST command's status -- a
                                #   `--daily 2>&1 | tee log | tail -60` reported exit 0
                                #   while the tier had FAILED, three times in one day);
                                #   H11 `comm`/`join` without a pinned LC_ALL=C (sorted
                                #   is a property of a file AND a collation -- a
                                #   default-locale sort compared against an LC_ALL=C one
                                #   fabricated a list of seven innocent failures).
                                #   Suppress with
                                #   `# hazard-ok:<code> <reason>` — a reason is REQUIRED,
                                #   because an unexplained suppression is how a gate goes
                                #   quiet. It runs its own positive controls before every
                                #   scan and REFUSES to report clean if any stopped firing.
                                #   `--rev 7156d3e` is the non-circular proof: it re-derives
                                #   3 of the 5 real bugs on the commit that shipped them.
                                #   0 = clean. QUICK tier.
python tools/doc_lint.py           # THE DOC-DRIFT GATE (static, instant, no build) — checks
                                #   the CHECKABLE claims only. D1 a `tools/x.sh` named in a
                                #   .md is TRACKED; D2 a repo path linked from a .md is
                                #   TRACKED;
                                #   TRACKED, NOT MERELY PRESENT — changed 2026-08-09, and
                                #   both directions had bitten. It enumerated documents with
                                #   a filesystem glob, so another agent's untracked working
                                #   note in the root turned this SHARED gate red for
                                #   everyone (a D7 "no doc-status" plus a D6 count drift) on
                                #   a file nobody else had. And it resolved a referenced
                                #   path with `.exists()`, which on this case-insensitive
                                #   filesystem answered YES for `selfhost/codegen.zbr` when
                                #   the file is `CodeGen.zbr` — so D2 was BLIND TO EVERY
                                #   CASE-WRONG PATH, and switching to `git ls-files`
                                #   (case-sensitive) immediately surfaced 10 stale
                                #   references to the pre-rename lowercase module names
                                #   across four live/design docs. The false-green was the
                                #   worse half: a red gets fixed. Same line corpus_ls.sh
                                #   draws, and the same refusal — no silent fallback to
                                #   globbing outside a git worktree.
                                #   D3 every gate registered in gates.sh is DESCRIBED here
                                #   in CLAUDE.md (an undocumented gate is how a tier's
                                #   meaning drifts — it found 3 on the day it was written);
                                #   D4 a cited BUG-NNN exists in one of the two ledgers.
                                #   D8 (2026-08-18) a line carrying a doc-gen ORACLE
                                #   must not also carry an UN-oracled multi-digit
                                #   number. D6 checks the numbers that HAVE an oracle;
                                #   what it cannot see is a line where one number is
                                #   instrumented and its neighbour is not — the checked
                                #   half keeps passing, which READS as "this line is
                                #   verified", while the other rots beside it. Caught on
                                #   this file's own walker row (`7 of 54`, oracle on the
                                #   7; the 7 was corrected the moment it moved, the 54
                                #   had been wrong for some time). First run found 3,
                                #   one worse than stale: a row reading "161 blocks in
                                #   25 live docs" whose oracle counted DOCUMENTS, so the
                                #   visible claim had no instrument while appearing to
                                #   have one — and both figures were wrong (156, 28).
                                #   NARROW ON PURPOSE: demanding an oracle for every
                                #   integer everywhere is unusable noise, but numbers
                                #   sharing a line were measured at the same moment and
                                #   rot together. 3 hits, 0 false positives, 51 docs.
                                #   Fix either way — add an oracle, or reword so the
                                #   number is not asserted.
                                #   Append-only records (BUGS.md, BUGS_FIXED.md, the journal,
                                #   CHANGELOG, dated audits) are REPORTED but not gated: an
                                #   entry naming a tool deleted three months later is accurate
                                #   history, and "fixing" it would falsify the record.
                                #   Suppress a deliberate dangling reference (a PROPOSED tool,
                                #   a promotion history) with `<!-- doc-lint-ok: reason -->`;
                                #   the reason is required. It prints its own uncovered set
                                #   every run — behaviour claims, coverage counts, and
                                #   anything inferred from a gate's SILENCE are NOT checked,
                                #   and a clean run must not be read as "the docs are
                                #   accurate". 0 = clean. QUICK tier.
bash tools/release_mode_check.sh   # THE ONLY GATE THAT BUILDS WITH `--release` (FULL tier).
                                #   Every other gate in every tier is DEBUG. That is exactly
                                #   how BUG-228 survived 19 green gates for four days:
                                #   `--release` switched the backend to LLVM (a visible
                                #   20 MB -> 2 MB change) while the branch that emits the
                                #   executable passed no optimize flag at all, so Zig
                                #   defaulted to Debug. Everyone shipping with the flag
                                #   shipped Debug believing otherwise — the flag's whole
                                #   purpose. No gate could see it because none used it.
                                #   Asserts (1) a --release build RUNS and prints the right
                                #   answer — optimisation must not change behaviour, the
                                #   half that matters most — and (2) the release binary is
                                #   materially smaller than the same program built without.
                                #   THE SIZE CHECK IS SELF-CALIBRATING: it compares two
                                #   binaries built in the same run rather than a recorded
                                #   number, because a hardcoded size rots on the next Zig
                                #   release and then passes or fails for no reason. What it
                                #   really asks is "did the -O flag reach zig", and the
                                #   regression it exists to catch makes the two builds
                                #   IDENTICAL in size. Verified red against that exact case
                                #   (812 KB vs 812 KB -> FAIL). 25% margin, not an exact
                                #   figure. Observed: 812 KB vs 19,072 KB.
                                #   A SKIPPED size check is a FAILURE, not a pass — the
                                #   first version could not find the binaries and printed
                                #   "all checks pass" with its only real assertion never
                                #   having run.
                                #   Runs a full LLVM build → FULL tier, not QUICK.
bash tools/contract_mode_check.sh  # THE CONTRACT-STRIPPING CONTRACT (FULL tier, ~55s):
                                #   the ONLY gate that passes `--turbo`, and the only one
                                #   asserting what the two shipping flags DO. Matrix:
                                #     (none)            contracts fire   assert fires
                                #     --release         contracts FIRE   assert fires
                                #     --turbo           stripped         assert FIRES
                                #     --release --turbo stripped         assert FIRES
                                #   `--turbo` and `--release` are INDEPENDENT and compose;
                                #   a shipping build is `--release --turbo`. `assert`
                                #   deliberately survives `--turbo`: a contract is a proof
                                #   obligation on the caller, an assert is a check the
                                #   author wrote to RUN.
                                #   THE ASYMMETRIC LEGS ARE THE POINT. It would be easy to
                                #   assert "contracts off in release" and pass — that was the
                                #   documented and WRONG belief (BUG-257: docs claimed
                                #   "--turbo strips them, so release builds are unaffected",
                                #   which does not follow). What is gated is that --release
                                #   ALONE still fires them, and that --turbo does NOT touch
                                #   assert. Both are what a plausible "optimisation" breaks.
                                #   Precedent for the regression: BUG-228 shipped Debug from
                                #   `--release` for four days under 19 green gates, because
                                #   NO gate passed the flag. A flag no gate passes is
                                #   unverified by construction — docs/testing_strategy.md
                                #   had already named --turbo "a genuinely under-tested path".
                                #   Classifies on a SENTINEL the program prints past the
                                #   check, never on exit code alone — a build failure also
                                #   exits non-zero, and scoring that as "the contract fired"
                                #   would make a broken compiler look like a working guard.
                                #   THE RUNTIME LEGS ALONE FAIL OPEN on --release, though:
                                #   non-zero + no sentinel scores `fired`, so a binary that
                                #   crashed for an unrelated reason would pass while
                                #   contracts were being stripped. That is why the mechanism
                                #   legs cover ALL FOUR combos at EMIT level rather than
                                #   just plain-vs-turbo — the claim carrying the most weight
                                #   (a plain --release build KEEPS its contracts) must not
                                #   rest on a panic.
                                #   COVERS BOTH COMPILERS. `--gui-backend=*` delegates to
                                #   zebra-bootstrap, so a GUI app built --release --turbo
                                #   takes a path the selfhost legs never touch. The
                                #   bootstrap DOES honour --turbo (verified); it takes
                                #   --emit-zig, not --output-dir, so those legs cost no
                                #   build. Asserting this for one of two compilers under the
                                #   title "the contract-stripping contract" would be the
                                #   same over-read that let BUG-228 sit under green gates.
                                #   Verified red against four realistic regressions
                                #   (--release stripping contracts, at runtime AND at emit;
                                #   --turbo stripping assert; the bootstrap ignoring
                                #   --turbo): each mutant failed exactly one leg.
                                #   A vacuous run is a FAILURE — it refuses to report unless
                                #   all 13 checks ran.
python tools/grammar_export.py --check  # THE GRAMMAR-DRIFT GATE (static, instant).
                                #   `grammar.txt` is now GENERATED from the Earley parser's
                                #   own rule table (src/ZebraGrammar.zig, 461 comptime rule <!-- doc-gen: 461 = grep -c 'lhs = ' src/ZebraGrammar.zig -->
                                #   literals). It used to be hand-maintained BNF alongside
                                #   the table — two copies of one thing, one compiled and
                                #   one prose.
                                #   THE DRIFT WAS NOT COSMETIC. `fuzz/gramgen.py` derives
                                #   its 960 programs FROM grammar.txt, so the
                                #   parser-robustness gate was generating **9 constructs the
                                #   parser does not have** (ProDecl, PropDecl, StmtUsing,
                                #   AllAnyExpr, MemberBlockOpt…) and **never reaching 40 it
                                #   does** — LambdaExpr, CaptureBlock, ExceptField*,
                                #   GenericConstruct, DeclUnion. Lambdas and capture blocks
                                #   had never been fuzzed. That also gives its standing
                                #   caveat ("accept/reject divergences are expected") a much
                                #   less innocent explanation than overgeneration.
                                #   Regenerate with `--write`; the RULE TABLE is the
                                #   authority, never the document.
                                #   CANNOT say the grammar is CORRECT, only that the
                                #   document matches the table. Precedence encoded via
                                #   nonterminal layering, and anything the parser does
                                #   outside the Earley table (the tokenizer's indent/dedent
                                #   synthesis especially), are invisible to it.
                                #   Refuses to report if it extracts <400 rules or cannot
                                #   find the start rule — a regex that has stopped matching
                                #   would otherwise blame the DOCUMENT for the extractor's
                                #   failure. 0 = clean. QUICK tier.
python tools/doc_example_check.py  # THE DOC-EXAMPLE GATE — the only gate pointed at what a
                                #   READER is told, rather than at what the compiler does.
                                #   224 fenced `zebra` blocks existed and NOTHING verified
                                #   one of them until 2026-08-03. That is not abstract debt:
                                #   QUICKSTART — the file whose header calls it the
                                #   authoritative reference — documented thread spawning as
                                #   `sys.go(lambda …)` in five blocks, and `lambda` is NOT A
                                #   ZEBRA KEYWORD. None had ever compiled. It was found by
                                #   trying to follow the doc and failing twice (BUG-245).
                                #   Scoped by `doc-status`: only `live` docs are checked —
                                #   BUGS.md is 24 blocks of deliberately-broken repros, and
                                #   "fixing" those would falsify the record.
                                #   SIGNAL vs ARTIFACT is what makes it usable. Checking
                                #   every block naively yields ~100 failures, ~90% noise
                                #   (fragments referring to prose: "undefined name: 'data'").
                                #   A gate at that ratio gets suppressed wholesale. So an
                                #   "undefined name" is an ARTIFACT and NOT gated, while
                                #   "the parser could not READ this construct" is SIGNAL and
                                #   IS. Elision (`...`), counterexamples (`# error:`) and
                                #   `<!-- doc-example-ok: reason -->` are skipped.
                                #   FRONT END ONLY (`zebra -c`) — a doc fragment has no
                                #   modules around it, so a full compile would drown syntax
                                #   errors in missing-dependency noise.
                                #   Baselined at 11 <!-- doc-gen: 11 = grep -vc '^#' tools/doc_example_baseline.txt -->
                                #   (was 27), so it fails only on NEW breakage. That
                                #   baseline is REAL DEBT a reader hits, in three families:
                                #   `print` WITHOUT PARENS (pre-`()`-mandatory Cobra syntax),
                                #   the REMOVED `to!` operator, and assorted stale forms.
                                #   Shrink it; do not grow it. Runs its own good/bad controls
                                #   every invocation and exits 2 if either stops
                                #   discriminating. 0 = clean. QUICK tier.
python tools/lint_fallthrough.py   # THE FALL-THROUGH GATE (static, instant, no build):
                                #   flags a value-returning fn whose TAIL `branch` has a
                                #   value-producing arm that can fall through without
                                #   returning. Codegen TCO-wraps such fns in `while(true)`,
                                #   so a fall-through arm HANGS (not a compile error). Caught
                                #   nothing new when written (the hazard was isolated to the
                                #   §28f set-literal arms, since fixed) but re-flags that exact
                                #   bug if reintroduced. Run after adding any `branch` arm to a
                                #   recursive walker (exprHasTry/inferExpr/…). 0 = clean.
bash tools/runtime_module_check.sh # THE ONLY GATE THAT RUNS EMITTED OUTPUT: small programs
                                #   exercising the DEFAULT emit shape — hello-world (asserting
                                #   the emitted file is <100 lines, i.e. the runtime really was
                                #   externalised into zebra_rt.zig and did not silently go back
                                #   to being spliced), the BUG-221 three-module repro (which
                                #   SEGFAULTED before this change), `zebra run` / `zebra -c`
                                #   (a DIFFERENT branch of zbrToZig — temp dir, not
                                #   --output-dir), and that `--no-runtime-module` and
                                #   `--single-file` still produce the INLINE runtime.
                                #   2026-09-08: GUI backends use the SAME shape now — the
                                #   section is pub-marked into zebra_rt.zig and scaffolded
                                #   beside main.zig (BUG-355/357: one runtime, one section
                                #   per project). Only `--target node-addon` still inlines.
                                #   compile_check never runs anything, so it cannot see any of
                                #   this; and every other gate is happy whichever shape is the
                                #   default, so this is the only one that would notice a silent
                                #   revert. It deliberately passes NO flag where it can.
                                #   Cheap → QUICK tier. Pair with:
JOBS=3 bash tools/compile_check.sh --no-runtime-module  # gate label: `compile_check-inline`
                                #   the SAME corpus with the INLINE
                                #   runtime. Runtime-module emission is the DEFAULT as of
                                #   2026-07-28, so the INLINE shape is the one that would
                                #   otherwise go unwatched — and it stays live via the opt-out
                                #   and as the fallback for --single-file / node-addon / every
                                #   --gui-backend. 217/0/1, identical to the default. FULL tier.
bash tools/stream_check.sh      # THE STREAM-SEPARATION GATE, registered as `stream-sep`
                                #   (BUG-318, FAST tier, ~10s) --
                                #   the only gate that can tell STDOUT from STDERR, and the
                                #   reason it exists is that nothing could.
                                #   RECEIPT: until 2026-08-29 Zebra's `print` lowered to
                                #   `std.debug.print`, which writes to STDERR. Every
                                #   program's output vanished under `> file` or `| grep`,
                                #   with exit code 0 -- for a release meaning "ready for
                                #   others", the first thing a stranger does after print.
                                #   NO EXISTING GATE COULD SEE IT, structurally rather than
                                #   by oversight: `output_sweep.sh:183` -- the ONLY gate that
                                #   reads what programs PRINT -- captures with `2>&1`, so it
                                #   merges the two streams it would need to distinguish; the
                                #   smoke harness greps combined output; every other gate
                                #   asks whether things COMPILE, not where they print.
                                #   IT ALSO RETIRED A FALSE BELIEF. This file and the session
                                #   memories recorded "Windows stdout-to-PIPE writes nothing
                                #   (redirect/file fine)" as a platform quirk, and tooling was
                                #   shaped around it. It was this bug: a FILE redirect got
                                #   nothing either, and the runs that appeared to work were
                                #   capturing 2>&1. `prog | grep` works now.
                                #   SIX LEGS, BOTH DIRECTIONS, because either alone is
                                #   satisfiable by sending everything to one stream: print IS
                                #   on stdout, errln IS on stderr, print is NOT on stderr,
                                #   errln is NOT on stdout -- plus the two usages the bug
                                #   actually broke (`prog | grep`, `prog > file`), tested as a
                                #   user meets them rather than inferred.
                                #   REFUSES if the program produced nothing on EITHER stream:
                                #   two empty strings satisfy every absence test, so the
                                #   positive control runs first. An absence is evidence only
                                #   after a presence has been demonstrated.
                                #   VERIFIED WITH THE REAL ATTACKER, not a mutation: reverting
                                #   the emitted calls to `std.debug.print` gives stdout 0
                                #   bytes / stderr 57 and fails leg 1.
                                #   The markers on the two streams are DIFFERENT strings, so a
                                #   harness that captured one stream twice fails rather than
                                #   passes. 0 failures = clean.
bash tools/selfhost_divergence_check.sh  # THE COMPILER-SOURCES AGREEMENT GATE,
                                #   registered as `selfhost-div` (DAILY tier, ~3 min).
                                #   Points BOTH compilers at the modules the compiler is
                                #   BUILT FROM and requires them to agree.
                                #   THE GAP IT FILLS: `divergence_check` sweeps test/ and
                                #   examples/. Nothing compared the two compilers on
                                #   selfhost/*.zbr, and BUG-332 lived there.
                                #   WHY THE N-1 ANCHOR CANNOT REPLACE IT: that comparison
                                #   asks "did this compiler LOSE something", i.e.
                                #   regressions. BUG-332 never worked, so an N-1 selfhost
                                #   rejects the same code. Only a genuinely INDEPENDENT
                                #   implementation catches a long-standing wrong answer,
                                #   and the bootstrap is the only one this tree has. That
                                #   is the whole remaining argument for keeping it.
                                #   IT BUYS BLAME, NOT DETECTION -- stated narrowly because
                                #   the first draft overclaimed. When the selfhost wrongly
                                #   refuses a module, REGENERATION FAILS, so rebuild.sh
                                #   already stops. What is missing is that the error names
                                #   the SOURCE FILE, reading as "your code is wrong" when
                                #   the truth is "your compiler is wrong". BUG-332 cost
                                #   hours to that misattribution.
                                #   IT CANNOT BE MUTATION-VERIFIED against its own founding
                                #   bug: reverting that fix stops the compiler regenerating,
                                #   so no mutant binary exists to test -- the attempt gave a
                                #   broken tree and a FALSE PASS against the last good
                                #   binary. Proven red instead with SELFDIV_SELF_OVERRIDE
                                #   pointed at a stub refusing one module (11/12, names it).
                                #   ASYMMETRIC ON PURPOSE: selfhost refuses + bootstrap
                                #   accepts = FAIL; the reverse is INFORMATIONAL, because
                                #   the bootstrap is frozen and gating that would turn every
                                #   new language feature into a failure.
                                #   IT PRINTS ITS OWN COVERAGE EVERY RUN (12/12 on
                                #   2026-09-05). The bootstrap is frozen, so the share of
                                #   the compiler it can still read only falls. When it falls
                                #   far enough the bootstrap has stopped being a reference
                                #   and can be deleted -- a decision with a number attached
                                #   rather than one taken when somebody tires of it.
                                #   SCOPED to bootstrap_check.sh's FILES list, not a glob:
                                #   selfhost/ also holds ten aux/phase-test files, and one
                                #   (pipeline_test.zbr) has call sites stale behind an API
                                #   change, so the SELFHOST correctly refuses it while the
                                #   bootstrap accepts -- the REVERSE of the target bug.
                                #   Gating that would mean a red board for being right.
                                #   REFUSES if the bootstrap is absent: it IS the comparison,
                                #   and a vacuous run must not look like agreement.
bash tools/debug_map_check.sh   # THE DEBUG SOURCE-MAP GATE, registered as `debug-map`
                                #   (FAST tier, ~10s). `zebra debug` is a DAP relay: it
                                #   sits between an IDE and lldb-dap and rewrites every
                                #   source coordinate crossing it, because the debugger
                                #   knows only the GENERATED .zig while the user is looking
                                #   at their .zbr. The translation is driven by the
                                #   `// zbr:<file>:<line>` comments codegen stamps into the
                                #   emitted Zig.
                                #   WHY CONNECTIVITY IS NOT THE PROPERTY: a relay that
                                #   forwards bytes UNCHANGED still attaches, still
                                #   initializes, still reports a live session. The only
                                #   symptom of a broken map is breakpoints landing on the
                                #   wrong lines -- so "we connected and got `initialized`"
                                #   passes just as well against the transform deleted.
                                #   NEEDS NO lldb-dap AND NO DEBUG SESSION.
                                #   `zebra debug --dump-map <file.zbr|file.zig>` reports the
                                #   map computed by the SHIPPING lookups, so the property is
                                #   checkable directly. That flag is a diagnostic in its own
                                #   right -- it answers "why did my breakpoint land THERE?"
                                #   -- which is why it is a surface and not a test hook.
                                #   THE ROUND-TRIP LEG ALONE WOULD HAVE SHIPPED A BROKEN
                                #   MAP, and that is the receipt this gate exists for. On
                                #   its first run the round trip was GREEN across every
                                #   marker while `print` statements had NO marker at all
                                #   (BUG-329) -- two lookups broken in compensating ways
                                #   agree with each other perfectly. Leg 2's oracle comes
                                #   from OUTSIDE the map: the fixture's prints name the line
                                #   they sit on, so the expected numbers are derived from
                                #   the source text rather than from anything the compiler
                                #   said. It named all six missing lines on the first run.
                                #   LEGS 3-5 FEED HANDWRITTEN .zig to the parser, with no
                                #   compiler in the loop: a Windows drive path must split at
                                #   the LAST colon (`C:/proj/a.zbr:42`), a malformed marker
                                #   must be SKIPPED rather than defaulted to a line number
                                #   (a fabricated coordinate sends a debugger somewhere
                                #   confidently wrong), and a file with no markers must
                                #   report zero -- which proves the count is a measurement
                                #   and not a constant.
                                #   REFUSES (exit 2) rather than reporting a pass if the
                                #   dump is empty, if the fixture yields under 6 markers, or
                                #   if the source oracle finds under 5 labelled lines: every
                                #   absence assertion is vacuous without a denominator.
                                #   LEGS 6-10 COVER THE TRANSFORM (added 2026-09-04), via
                                #   `zebra debug --dump-transform`, which feeds ONE DAP
                                #   message through the shipping transform and prints what
                                #   would be forwarded -- no lldb-dap, no debug session.
                                #   THE PASS-THROUGH LEGS ARE THE LOAD-BEARING ONES: a relay
                                #   is judged on what it does NOT change. It must forward
                                #   messages it does not model (asserted BYTE-IDENTICAL) and
                                #   fields it does not understand inside the ones it does
                                #   (`condition`, `sourceModified`). A transform that remapped
                                #   coordinates correctly and dropped an unknown field would
                                #   pass every coordinate check and still break a client that
                                #   used that field.
                                #   LEG 10 CAUGHT A REAL BUG INHERITED FROM THE ZIG ORIGINAL:
                                #   both tested endsWith(".zig") for a stack frame, which also
                                #   matches the Zig STANDARD LIBRARY -- a frame in std/mem.zig
                                #   was rewritten to an unrelated .zbr line, sending the editor
                                #   somewhere confidently wrong. The port matches the emitted
                                #   file by NAME instead.
                                #   CANNOT SEE: whether a marker points at the RIGHT zig
                                #   line, or anything about the lldb-dap conversation -- the
                                #   session half (spawn, TCP, threads) is NOT yet ported.
python tools/lsp_server_smoke.py   # THE LSP PROTOCOL GATE, registered as `lsp-smoke`
                                #   (FAST tier, ~2s). Drives `zebra lsp` through a real
                                #   JSON-RPC conversation over stdio -- Content-Length
                                #   framed, same as a live editor -- and checks 14
                                #   responses: diagnostics after a debounced didChange,
                                #   documentSymbol, hover, go-to-definition, completion,
                                #   member completion, signature help, formatting,
                                #   MethodNotFound for an unknown request, shutdown.
                                #   IT EXISTED SINCE THE LSP EPIC AND WAS IN NO TIER
                                #   (registered 2026-09-02). It passes 14/14 today, which
                                #   is luck rather than design: an ungated test is real
                                #   only on days somebody remembers it, and this repo has
                                #   the receipt for how that ends -- node-addon sat
                                #   unregistered and regressed silently for two weeks
                                #   (BUG-297).
                                #   IT IS ALSO THE TEMPLATE for driving any stdio protocol
                                #   here: frame() and read_message() are exactly what a DAP
                                #   smoke test needs, since DAP uses the same
                                #   Content-Length framing. That matters for porting
                                #   `zebra debug` off the bootstrap -- the port is testable
                                #   without an editor, which is the opposite of what this
                                #   docket previously assumed.
                                #   CANNOT SEE: whether an editor renders any of it, or
                                #   anything about the LSP paths the conversation does not
                                #   exercise. 14 assertions.
python tools/lsp_workspace_smoke.py  # THE `use`-GRAPH GATE, registered as `lsp-workspace`
                                #   (FAST tier, ~3s). Three files in a temp dir, ONE open:
                                #   references / definition / rename must reach the module
                                #   the document `use`s and the sibling that uses IT, from
                                #   disk, and must NOT touch a sibling with the same name
                                #   that is not in the graph. Before 2026-09-08 the server
                                #   searched open documents only: a rename at a call site
                                #   left the definition alone and the program stopped
                                #   compiling; Definition into an unopened module was null.
                                #   Found by zebra-ide's rename_workspace_test.
bash tools/cli_check.sh         # THE CLI-SURFACE GATE, registered as `cli-surface`
                                #   (FAST tier, ~16s) -- the only gate that exercises the
                                #   compiler AS A COMMAND rather than as a translator.
                                #   EVERY OTHER GATE asks what the compiler does with a
                                #   PROGRAM: does it emit, does the emit compile, does the
                                #   program print the right thing. Nothing asked what it
                                #   does when a PERSON types something at it.
                                #   RECEIPT, and the gap is structural rather than an
                                #   oversight: argument handling is not part of compiling
                                #   the compiler, so the entire self-hosting self-check
                                #   region never touches it. Four bugs were found there in
                                #   two days -- BUG-321 (`--help | less` prints nothing),
                                #   BUG-322 (`zebra repl` and `zebra build` CRASHED for
                                #   every user outside this repo), BUG-323 (unknown flags
                                #   silently ignored, so a typo'd `--turbo` hands you the
                                #   opposite build) and BUG-327, which had a hard COMPILE
                                #   ERROR sitting inside `zebra build` through 37 green
                                #   gates. See concept_self-verification-blind-spot.
                                #   IT RUNS FROM A SCRATCH DIR OUTSIDE THE REPO, AND THAT
                                #   IS THE WHOLE POINT. BUG-322 was four delegations
                                #   resolving `zig-out/bin/zebra-bootstrap.exe` RELATIVE TO
                                #   THE CWD, so they worked perfectly from the repo root
                                #   and crashed everywhere else. A CLI suite run from the
                                #   repo root would have PASSED on the day that bug
                                #   shipped. It refuses if its scratch dir is inside $REPO.
                                #   EVERY LEG HAS A TIMEOUT, because BUG-327's second layer
                                #   turns `zebra build` into an infinite loop and a gate
                                #   that HANGS is strictly worse than one that fails.
                                #   POSITIVE CONTROL FIRST: `-c` on a good file must exit 0
                                #   AND produce output, or every absence assertion below it
                                #   passes vacuously -- it REFUSES (exit 2) rather than
                                #   reporting green.
                                #   KNOWN-BROKEN BEHAVIOUR IS PINNED, NOT SKIPPED: three
                                #   pins assert today's WRONG answer (BUG-321 x2, BUG-323),
                                #   print their ticket every run, and FAIL THE GATE THE DAY
                                #   THE BUG IS FIXED -- the signal to promote the pin to a
                                #   real assertion. Excluding them is how node-addon rotted
                                #   for two weeks.
                                #   VERIFIED RED WITH THE REAL ATTACKER, not a mutation:
                                #   hiding zebra-bootstrap.exe makes the `zebra repl` leg
                                #   fail. The `zebra build` leg correctly stays GREEN there,
                                #   because BUG-322's fix makes it exit 127 WITH A MESSAGE
                                #   rather than panicking -- the two legs assert different
                                #   properties and each measures what it claims.
                                #   CANNOT SEE: whether usage TEXT is accurate, whether a
                                #   flag does what it says, or any interactive behaviour
                                #   past `repl` starting. 27 assertions, 0 pins. Every pin it
                                #   started with was PROMOTED the day its bug was fixed --
                                #   BUG-321, BUG-323, BUG-327 -- which is what a pin is for.
                                #   THE REPL LEGS ASSERT EVALUATION, not startup: `starts`
                                #   was the right property when repl was a DELEGATION and the
                                #   risk was BUG-322's relative path. Since the port
                                #   (2026-09-02) the risk is the port, so the gate drives a
                                #   session and checks 21*2=42 crosses a cell boundary, that a
                                #   decl cell is accepted AND then callable, and that `:clear`
                                #   really resets -- proven by the FAILURE of the next cell,
                                #   since checking that it printed "session cleared" would
                                #   pass against a no-op. BUG-321's two
                                #   were PROMOTED to real assertions the day it was fixed,
                                #   which is what a pin is for.
                                #   THE BUILD-EXECUTION LEG is the one worth
                                #   knowing about: `b.run()` appears in the corpus
                                #   ONLY inside comments saying it is deliberately
                                #   NOT called, so the Build API's DECLARATION half
                                #   is covered three times over and its EXECUTION
                                #   half was covered ZERO times. This gate scaffolds
                                #   a build that actually runs and pins BUG-327 --
                                #   measured on BOTH compilers, failing at the SAME
                                #   line, so it is not a delegation problem.
bash tools/boundary_check.sh    # THE INTENT WITNESS (A3, QUICK tier, 104-339s -- NOT ~30s,
                                #   measured 2026-09-04 across four runs; the stale figure is
                                #   what made a probe pick a 300s timeout and misread a slow
                                #   run as a HANG): the only
                                #   gate whose expectations were WRITTEN FROM THE LANGUAGE
                                #   REFERENCE rather than recorded from the compiler. Every
                                #   other behaviour check here is a GOLDEN baseline, which
                                #   catches regressions and can NEVER find something that
                                #   was wrong on day one. Probes in test/boundary/, triage
                                #   in docs/boundary_triage.md.
                                #   FIRST RUN (2026-07-30) found BUG-230 (an annotated
                                #   non-empty list literal does not compile — invisible to
                                #   divergence BY CONSTRUCTION, since both compilers do the
                                #   identical wrong thing, and absent from the corpus so
                                #   compile_check never emits it), BUG-232 (arity checking
                                #   SKIPPED inside `${...}`) and BUG-231.
                                #   THE PROPERTY THAT MAKES IT WORK is that expectations are
                                #   authored BEFORE the first run — protected structurally by
                                #   the commit boundary (probes+intent unrun in 603a580,
                                #   findings after). If an .expected is ever written by
                                #   pasting observed output, this is output_sweep with extra
                                #   steps: delete it rather than keep it.
                                #   Probes marked `@boundary-pending BUG-NNN` pin KNOWN-BROKEN
                                #   behaviour on purpose — they pass today, print their ticket
                                #   every run, and FAIL when the bug is fixed. That failure is
                                #   the signal to rewrite the probe, NOT to re-baseline.
RE-BASELINE ORDER (learned 2026-07-31): output_sweep derives its CANDIDATE set from
the FULL_SWEEP baseline. When a corpus file changes compile status, re-baseline
**full_sweep FIRST, then output_sweep** — the other order leaves an output_sweep entry
whose file is no longer a candidate, and the gate correctly reports it as "stopped being
measured", which is a coverage loss rather than a behaviour change.

python tools/lint_stale_bugs.py    # THE STALE-OPEN-BUG SCANNER — REPORT ONLY, not a
                                #   gate, and deliberately so. It ranks OPEN entries by
                                #   evidence from OUTSIDE the ledger — commits whose
                                #   subject claims to have landed the number, and tracked
                                #   regression fixtures — because the thing it hunts is
                                #   invisible to `bug-numbers`.
                                #   WHY IT HAD TO LOOK OUTSIDE. `lint_bug_numbers`'
                                #   resolved-entry leg is HEADING-ONLY on purpose: bodies
                                #   routinely say FIXED about OTHER bugs, which scored 30
                                #   of 53 and is a noise ratio that gets a gate ignored. So
                                #   an entry whose heading never gains a marker is
                                #   structurally invisible there — and that is exactly how
                                #   BUG-283, BUG-270 and BUG-271 each sat closed-but-open,
                                #   the last one for NINE DAYS at the top of the ledger.
                                #   Two of the three were found by someone picking the bug
                                #   up to work on it and discovering it already done.
                                #   NOT A GATE, because it produces real false positives
                                #   and must: BUG-106 ranks top on an old "BUG-106 fixed"
                                #   commit, but today's entry is a NEW conflict filed under
                                #   the same number and is legitimately open. A tool that
                                #   would close that is worse than none. It ranks
                                #   suspicion, names its evidence, and closes nothing.
                                #   CARRIES A BOUNDARY CONTROL, because its first version
                                #   got this wrong in the repo's signature failure mode:
                                #   `git log --grep BUG-14` is a SUBSTRING match and
                                #   collected 24 "fixes" belonging to BUG-140..149 — a
                                #   confident wrong NUMBER, not an error. It now refuses to
                                #   run unless `BUG-14` rejects `BUG-142`, and unless a
                                #   known-landed number (BUG-288) still shows its commits.
                                #   VERIFY BY RUNNING THE CASE before closing anything: a
                                #   fixture existing is not a fix, which is the whole
                                #   reason `registration_check` exists.
python tools/lint_bug_numbers.py   # THE BUG-NUMBER COLLISION GATE (static, instant, QUICK).
                                #   Two agents work in this tree and both allocate a
                                #   number the same way — read BUGS.md, take the next.
                                #   Between one reading and committing, the other can file
                                #   twice. It happened TWICE on 2026-08-06: BUG-260 (two
                                #   bugs, untangled only by `git log -S` archaeology) and
                                #   BUG-269 (caught because a grep happened to print two
                                #   identical headings side by side).
                                #   NO EXISTING GATE COULD SEE IT. `doc_lint` D4 checks a
                                #   cited BUG-NNN RESOLVES — and a duplicate resolves TWICE,
                                #   so a collision leaves D4 *more* satisfied. The failure
                                #   is invisible exactly because the thing that would notice
                                #   is looking for presence.
                                #   SUB-LETTERED NUMBERS ARE NOT COLLISIONS: `BUG-009 (a)` /
                                #   `BUG-060a` are parts of one bug and key to distinct
                                #   slots. Baselined (3 known: 106, and a 49-line block
                                #   containing 249+250 duplicated VERBATIM in BUGS.md — an
                                #   editing accident left in place because BUGS.md is
                                #   doc-status: historical and not mine to edit).
                                #   SECOND LEG, NOT BASELINED: "Last bug number generated"
                                #   must be >= the highest heading. That line is what the
                                #   next person reads, so when it lags it is not a stale
                                #   fact — it is the NEXT collision already scheduled.
                                #   THIRD LEG: a RESOLVED entry must not linger in the
                                #   OPEN ledger. BUGS.md answers "what is left to work
                                #   on", so a finished entry still sitting there makes
                                #   that answer wrong — silently: a reader counts 53 open
                                #   bugs when 50 are open. Found 2026-08-07 with exactly
                                #   that (BUG-255/256/257, all three carrying FIXED plus a
                                #   date in their own headings). HEADING-ONLY on purpose:
                                #   bodies routinely say FIXED about OTHER bugs and every
                                #   good entry has a "Control when fixing" section, which
                                #   scored 30 of 53 — a noise ratio that gets a gate
                                #   ignored. A part-done bug is legitimate and says so with
                                #   `<!-- bug-open-ok: reason -->` (BUG-267 has one: usage
                                #   half fixed, mutation half open).
                                #   Refuses to report if <150 headings parse or if a planted
                                #   duplicate is not detected. Reconfigures stdout to UTF-8:
                                #   printing a heading containing an em-dash or a tick
                                #   raised UnicodeEncodeError on this cp1252 console and
                                #   took the whole gate down with a traceback — a gate that
                                #   CRASHES reports nothing, and the cause looks like the
                                #   ledger rather than the terminal. 0 NEW = clean.
python tools/lint_keyword_coverage.py # THE KEYWORD-COVERAGE GATE (static, instant,
                                #   STATIC tier) -- the MIRROR of `registration_check`. That
                                #   gate asks whether every tracked TEST is asserted by
                                #   something; this asks whether every KEYWORD is EXERCISED by
                                #   something. Nothing asked that until 2026-08-29.
                                #   RECEIPT, and it is why the gate exists: on the day the
                                #   question was first asked, the two MODIFIERS with zero
                                #   corpus uses were `protected` and `internal`, and BOTH were
                                #   defective -- BUG-315 (a synonym for `private`, documented
                                #   with semantics needing inheritance the grammar cannot
                                #   express; removed) and BUG-316 (means different things in
                                #   each compiler, and the selfhost's diagnostic reports "is
                                #   private" about a field declared `internal`). Two for two.
                                #   NO EXISTING GATE COULD SEE IT, and the gap sits between
                                #   three that each stop just short. `divergence_check`
                                #   compiles the corpus with both compilers, so a keyword
                                #   ABSENT from the corpus is invisible to it by construction
                                #   -- there is nothing to compile. `lint_reserved_words` asks
                                #   whether a keyword is REACHABLE in either compiler, which
                                #   both of these were. `registration_check` looks at files,
                                #   not features.
                                #   THE ORACLE IS A TYPABLE WORD, NOT AN ENUM VARIANT NAME,
                                #   and that distinction is the whole reason `zbr_vocab.py`
                                #   exists. `construct_histogram` derived its vocabulary from
                                #   selfhost/Token.zbr's `kw_*` enum -- but `kw_arena` is the
                                #   selfhost's name for a token whose WORD the bootstrap maps
                                #   as `allocate`, and QUICKSTART says the `arena` keyword is
                                #   REMOVED. So an enum-derived vocabulary contains a word no
                                #   program can type and MISSES the one every arena-scoped
                                #   program uses -- wrong in both directions at once.
                                #   THREE SOURCES EXIST AND THEY DISAGREE, so all three are
                                #   read and reconciled rather than one being trusted:
                                #   src/Token.zig's table (80 words), selfhost/Token.zbr's
                                #   `if word == "..."` chain (79), and a hand-maintained
                                #   pipe-delimited statement-keyword STRING in
                                #   selfhost/Parser.zbr. `allocate` is in the first and third
                                #   but not the second. The disagreement is PRINTED every run
                                #   and the gate REFUSES above a ceiling of 6.
                                #   BASELINED AT 6 -- `abstract`, `continue`, `defer`,
                                #   `errdefer`, `implies`, `vari`. `continue` is the one to
                                #   sit with: a basic loop keyword with ZERO code uses across
                                #   547 files, while its sibling `break` has 18 across 5.
                                #   Shrink this list; never grow it.
                                #   CONTROLS, because a scanner that stops seeing code reports
                                #   EVERY keyword as uncovered: a 7-case both-directions
                                #   selftest on synthetic input runs before any real scan
                                #   (a keyword in code counts; in a comment, in a string,
                                #   inside `${...}`, as a substring, or absent does not), and
                                #   it refuses on <300 files, <5000 code lines, or `def`
                                #   appearing under 100 times. The comment/string legs are the
                                #   dangerous ones -- each would INFLATE coverage and hide a
                                #   real gap, which is the quiet direction.
                                #   VERIFIED AGAINST A NAIVE GREP, which disagreed: raw grep
                                #   finds `defer` in 5 files and `continue` in 1. Every one of
                                #   those hits is in a COMMENT. The scanner was right and the
                                #   cross-check was the wrong instrument -- worth knowing
                                #   before anyone "corrects" this gate with a grep.
                                #   CANNOT SEE whether a keyword's SEMANTICS are asserted. A
                                #   file that merely parses `internal` satisfies this gate
                                #   while proving nothing -- BUG-316 needed a probe with a
                                #   control, and no coverage tool would have written it. This
                                #   aims attention. 0 NEW = clean.
python tools/lint_reserved_words.py # THE RESERVED-WORD GATE (static, instant, QUICK tier):
                                #   a keyword must either be USED or be JUSTIFIED. A word in
                                #   the keyword table costs every user of the language the
                                #   right to name a variable, parameter, field or column with
                                #   it — a cost that is invisible until someone hits it, and
                                #   then looks like a compiler bug rather than a decision
                                #   nobody revisited.
                                #   RECEIPT: `aspect` was reserved for aspect-oriented
                                #   programming that was NEVER BUILT — the bootstrap parsed it
                                #   and then panicked "not yet implemented", and the selfhost
                                #   had no parse path at all (`AspectDecl` never appears under
                                #   selfhost/ in the whole git history). So it blocked a real
                                #   DB column name, forced a keyword-rename shield in another
                                #   project, and created a permanent bootstrap-accepts /
                                #   selfhost-rejects divergence for `gramgen` to trip over.
                                #   Freed under NEXT_STEPS U4, 2026-08-09.
                                #   TWO CLASSES, different fixes. R1 UNREACHABLE: no rule in
                                #   EITHER compiler mentions the token, so reserving it is
                                #   pure cost. R2 PARSED-THEN-REFUSED: a rule accepts it and
                                #   AstBuilder answers "not yet implemented" — the feature
                                #   does not exist, the reservation does.
                                #   BOTH COMPILERS, and the first draft got this wrong: it
                                #   scanned only the bootstrap's Earley table, but the
                                #   selfhost parses by hand and consumes TokenKind directly,
                                #   so a word invisible to the table can be live there. That
                                #   is rule 1c — an instrument's assumptions are quantified
                                #   over the subjects it had when written.
                                #   HOW IT NEARLY LIED: the first version asked "does this
                                #   token name appear downstream?" and classified `raise` and
                                #   `throws` as unused. Downstream code acts on the PNode, not
                                #   the token, so absence there means nothing. R2 now asks the
                                #   COMPILER's own answer instead of the author's inference.
                                #   Runs a 5-check selftest on synthetic input before every
                                #   scan and REFUSES if the classifier stops discriminating;
                                #   verified red by removing one baseline entry.
                                #   Baselined at 1 — `implies`, kept on LANGUAGE grounds
                                #   (Sean's call: it is intended as a contract operator,
                                #   `a implies b`). SEVEN words have now left this list:
                                #   weaves, expect, lock, from and trace under U4a
                                #   2026-08-09, then `error` and `try` on 2026-08-13.
                                #   The list shrinking is the gate working, and the last
                                #   two are the shape to remember — they were blocked on
                                #   the EMIT, not the parse, so what freed them was
                                #   BUG-280 plus the isZigKeyword oracle, and neither is
                                #   visible to this gate. A word can be R1 here and still
                                #   be unsafe to free. Shrink it; do not grow it.
                                #   0 NEW = clean.
bash tools/keyword_ident_check.sh  # THE ESCAPED-IDENTIFIER GATE (BUG-280, QUICK tier) —
                                #   the MIRROR IMAGE of reserved-words. That gate asks
                                #   whether a word Zebra reserves earns its keep; this
                                #   one asks what happens to a word Zebra does NOT
                                #   reserve but ZIG does: align, volatile, opaque,
                                #   packed, noalias, anyframe. A user may legally name a
                                #   field with one TODAY, so codegen must escape it as
                                #   @"name" on the way out.
                                #   `emitName` always did. The FIELD paths never called
                                #   it, so `var align: int` in a class emitted
                                #   `align: i64 = 0,` and the generated Zig did not
                                #   parse — while the same word as a LOCAL worked all
                                #   along, which is why it went unnoticed.
                                #   THE SITE MAP IS DERIVED, and that is the whole
                                #   point. Reading the source found FOUR sites. Emitting
                                #   a probe that uses a keyword field in every position
                                #   and grepping the output found NINE; a tenth surfaced
                                #   during the fix. So the probe is now the permanent
                                #   instrument rather than a one-off.
                                #   THE STATIC ALTERNATIVE WAS TRIED AND IT DOES NOT
                                #   WORK — measured 2026-08-15, recorded so nobody
                                #   re-proposes it. The obvious cheap lint is "an
                                #   expression passed through `emitName` somewhere must
                                #   not reach output BARE elsewhere", oracle derived from
                                #   the escaping call sites themselves. Run against the
                                #   commit BEFORE BUG-281 E it finds NOTHING: `mname` was
                                #   passed through emitName ZERO times then, so it was
                                #   never in the guarded set. The lint can only enforce
                                #   consistency with a decision ALREADY made; the bugs
                                #   that actually occur are the decision never made — a
                                #   name escaped NOWHERE that should be escaped
                                #   everywhere. It is also noisy in the other direction:
                                #   on today's tree it flags 10 sites, 0 real, because
                                #   `.` + mname for an Atomic/ThreadPool pass-through and
                                #   `um_cname + "." + mname` as a LOOKUP KEY are both
                                #   correctly bare. Structural, not tunable. The probe
                                #   works precisely because it reads the OUTPUT and so
                                #   needs no advance knowledge of which variable carries
                                #   the name.
                                #   HOW IT DECIDES: strips string-literal CONTENTS, then
                                #   flags any keyword left as a whole word. That single
                                #   rule makes `@"align"` pass AND the reflection string
                                #   `&.{"align"}` pass — the latter is DATA, must stay
                                #   bare, and escaping it would silently corrupt field
                                #   lookup. It needs no allow-list, deliberately: an
                                #   allow-list here would be the same hand-maintained
                                #   oracle that caused the bug.
                                #   AS OF 2026-08-13 IT ALSO COVERS THE METHOD NAME
                                #   (BUG-281 E) — declaration, static declaration, a bare
                                #   sibling call inside a method, and BOTH member-call
                                #   dispatches. Reading found 1 of those 5; the gate named
                                #   the other 4, including the one that matters most: the
                                #   EARLY user-method dispatch, which fires whenever
                                #   inference knows the receiver's class (the common
                                #   case), so fixing the default path alone left every
                                #   resolved call bare.
                                #   AND THE TYPE NAME
                                #   (BUG-281 B), and it covers it DIFFERENTLY: that
                                #   family was fixed by PREFIXING, not escaping, so a
                                #   Zebra type emits as `_zbr_ty_opaque` and the bare
                                #   word never reaches the output at all. `_zbr_ty_opaque`
                                #   is not a whole-word match for `opaque`, so the check
                                #   stays live rather than vacuous — verified by watching
                                #   it go RED on the new shapes before the fix (9 hits
                                #   across both words) and green after.
                                #   SELFHOST ONLY, and that is now structural: the
                                #   fixture no longer builds under the bootstrap, so
                                #   passing it `zebra-bootstrap.exe` is a permanent FAIL
                                #   rather than a check. gates.sh has never had a
                                #   bootstrap leg here; do not add one.
                                #   TWO BLIND SPOTS, both live. (1) THE FIXTURE IS THE
                                #   COVERAGE — on 2026-08-11 it reported the bootstrap
                                #   CLEAN while three further emit families were broken
                                #   in it (BUG-281). Extend the fixture with every fix.
                                #   Receipt that this is not a formality: B's landing
                                #   needed NINE emit sites the fixture (and the derived
                                #   probe) never reached, and every one came from a
                                #   different witness — the ROUND-TRIP (cross-module) and
                                #   selfhost_smoke. A keyword gate over a single-module
                                #   fixture cannot see either.
                                #   (2) It cannot see OVER-escaping, the dangerous
                                #   direction, since stripping strings is exactly what
                                #   lets the reflection strings pass. Diff a pre/post
                                #   emit for that: every changed line must be a keyword
                                #   acquiring @"…" and nothing else. Done for B against
                                #   tools/fixtures/bug281_typename_sites_probe.zbr:
                                #   32 changed lines, every one an identifier gaining the
                                #   prefix; the reflection field-type strings, the _ttag_
                                #   and _reflect_ symbols and the @derive toString format
                                #   literal all correctly UNCHANGED.
                                #   Carries a positive control (the names must appear in
                                #   the emit at all) and a negative one, and REFUSES
                                #   rather than reporting clean when either fails. A
                                #   clean escape with a failed BUILD is reported as a
                                #   separate defect, not as a pass. 0 = clean.
python tools/lint_zig_keywords.py  # THE KEYWORD-ORACLE GATE (BUG-280 defect 2, QUICK
                                #   tier) — the oracle BEHIND keyword-ident. `isZigKeyword`
                                #   decides which words get escaped, it exists TWICE
                                #   (src/CodeGen.zig, selfhost/CgHelpers.zbr), and both
                                #   copies were hand-written lists. A hand-maintained
                                #   oracle guarding against a bug caused by a
                                #   hand-maintained oracle.
                                #   THE RECEIPT IS NOT THE OBVIOUS DIRECTION. The lists
                                #   were missing 12 of Zig 0.16's 46 keywords — and every
                                #   one of the 12 is ALSO a Zebra keyword, so no user
                                #   could reach any of them and nothing was broken. What
                                #   proves the class is the other direction: both copies
                                #   still carry `async`, `await` and `usingnamespace`,
                                #   which Zig NO LONGER HAS. The list already drifted
                                #   across a version bump, silently.
                                #   MISSING fails; EXTRA is reported and NOT gated —
                                #   escaping a non-keyword is identity in Zig, so a stale
                                #   entry is inert, and deleting one would break a build
                                #   against an older Zig. Report, do not churn.
                                #   ORACLE = zig's own std/zig/tokenizer.zig keyword
                                #   table, located via `zig env`. Same philosophy as
                                #   grammar_export --check: the compiled table is the
                                #   authority, never a second copy. THE ONLY GATE THAT
                                #   READS THE ZIG INSTALLATION rather than the repo, so it
                                #   prints the version it judged against — the answer is
                                #   only true for one toolchain.
                                #   Refuses (exit 2) if it extracts <40 keywords, if
                                #   `zig env` cannot be parsed (it is ZON, not JSON), or
                                #   if either isZigKeyword cannot be found — a regex that
                                #   has stopped matching must blame ITSELF, not the
                                #   compiler. Runs both-direction controls on synthetic
                                #   input first (a planted gap must fire, a complete list
                                #   must not) and verified red by deleting one real entry.
                                #   NOT checked: isZigPrimitiveName, zigSafeName's other
                                #   half — already PATTERN-based for the open-ended part
                                #   (`i37`, `u3`, any iN/uN; verified by emitting a class
                                #   with an `i37` field and getting @"i37"), so it does not
                                #   have this failure mode. 0 = clean.
python tools/lint_diag_columns.py  # THE DIAGNOSTIC-POSITION GATE (QUICK tier, ~2s).
                                #   A front-end diagnostic that cannot say WHERE is
                                #   delivered half-finished — and `file:8:0` is NOT
                                #   "position unknown", it is a plausible-looking
                                #   coordinate that is simply wrong. It defeats caret
                                #   rendering (which reads line/col to quote the source)
                                #   and sends an editor to the wrong place. UNGIT
                                #   "nothing fabricated", in the one place the
                                #   move-checking-inward programme keeps landing.
                                #   RECEIPT: THREE bugs of exactly this shape were fixed
                                #   in two days — BUG-284 (zig literals had no span at
                                #   all), BUG-249 (this/nil/result were payload-less),
                                #   BUG-121 (checkExpr used the STATEMENT keyword's
                                #   position). Every one was found by a PERSON reading
                                #   output. A golden-output gate does not assert
                                #   positions and a compile gate cannot see them, so
                                #   nothing here could have caught any of them.
                                #   CANDIDATE SET IS DERIVED from the smoke suite's own
                                #   `smoke_tc_fail`/`smoke_run_fail` registrations —
                                #   where the suite already declares "this must be
                                #   refused". A hand-listed set would rot and silently
                                #   shrink coverage.
                                #   THE BASELINE IS ZERO as of 2026-08-16 (51 candidates,
                                #   47 producing diagnostics). It was 18; BUG-288's three
                                #   batches cleared every one. THAT CHANGES THE GATE'S
                                #   KIND: it was a ratchet failing only on growth, and it
                                #   is now an ABSOLUTE ASSERTION — every must-fail fixture
                                #   in the smoke suite can say where. A new entry is not
                                #   debt to record, it is a regression to fix.
                                #   WHICH MAKES THE REFUSAL GUARDS LOAD-BEARING. With a
                                #   non-empty baseline a collapsed scan still showed a
                                #   suspicious drop; with an empty one it prints
                                #   "0 known, 0 NEW" and passes — indistinguishable from
                                #   success. Read the candidate and produced counts before
                                #   believing a clean run.
                                #   PRINTS ITS DENOMINATOR ON EVERY PATH, pass or fail:
                                #   a gate that hides how much it examined when it fails
                                #   leaves you unable to tell "18 of 49" from "18 of 18",
                                #   and the second means the scan collapsed.
                                #   Refuses if <30 candidates extract (the registration
                                #   regex stopped matching) or if NOT ONE must-fail
                                #   fixture produced a parseable diagnostic — that is a
                                #   harness failure, not a clean result. Runs a
                                #   4-check both-directions selftest first, and was
                                #   verified red by removing one baseline entry.
                                #   CANNOT SEE whether a non-zero column is the RIGHT
                                #   column: it asserts a position was computed, not that
                                #   it points at the token. 0 NEW = clean.
bash tools/zig_test_check.sh       # THE ZIG-SIDE TEST GATE (BUG-279, QUICK tier, ~11s):
                                #   the unit (120) and integration (11) test binaries,
                                #   which were in NO tier and NOT in the uncovered table
                                #   either -- the one state that table exists to make
                                #   impossible. THREE unrelated failures sat on
                                #   committed code because of it.
                                #   DELIBERATELY NOT `zig build test`, which is a
                                #   SUPERSET: it also runs selfhost_smoke (~14 min) and
                                #   compile_check (~6 min), BOTH already gated, so the
                                #   command costs ~20 minutes of duplication to buy ~4
                                #   SECONDS of new coverage. This runs the uncovered
                                #   part alone, via a `test-zig` step added to build.zig.
                                #   WHAT THE BROKEN COMPILE WAS HIDING is the reason to
                                #   care: once the binary ran, two unit tests failed,
                                #   both asserting syntax the language had REMOVED (bare
                                #   `print "..."`, the `to!` operator). Each would have
                                #   failed the day its feature was dropped. They are now
                                #   INVERTED -- asserting the rejection -- per the
                                #   precedent U4a set when `aspect` was freed.
                                #   CONTROLS ON VACUITY: a step that ran nothing also
                                #   exits 0 silently, so it classifies on the count zig
                                #   reports and REFUSES (exit 2) if none is present or
                                #   fewer than 100 ran. Verified by gutting the step's
                                #   dependencies and watching it refuse.
                                #   NOT INCLUDED: escape_hatches_check, currently red on
                                #   a page_allocator review owned elsewhere (leg 3); one
                                #   line adds it when that clears.
python tools/lint_expr_walkers.py  # THE WALKER-DRIFT GATE (static, instant, QUICK tier).
                                #   A function that searches the Expr tree for a name is
                                #   correct only if it descends into every variant that
                                #   CONTAINS expressions. Miss one and it silently answers
                                #   "not used" for an entire construct — and because these
                                #   walkers drive `_ = x;` discards, the symptom lands in
                                #   the emitted Zig as a "pointless discard" against code
                                #   the user wrote correctly.
                                #   THIS CLASS WAS DECLARED RETIRED ONCE, BY HAND.
                                #   `mightUseNameInExpr` carries the note "BUG-169
                                #   retirement: model every remaining ident-bearing expr …
                                #   Retires the walker-drift class (F2/F6/F11)". It came
                                #   back twice anyway: BUG-267 (`zig_lit`) and BUG-260
                                #   (`list_lit`/`array_lit`) — and note what those share.
                                #   The variant was not FORGOTTEN, it was MISCLASSIFIED:
                                #   someone wrote down that it holds no expressions.
                                #   Modelling everything by hand does not prevent that; a
                                #   machine comparison against the AST does.
                                #   THE ORACLE IS Ast.zbr ITSELF — each variant's payload
                                #   struct and field types are declared, so "does this hold
                                #   expressions" is DERIVED, through one level of
                                #   indirection (`List(DictPair)` -> `DictPair.key: Expr`).
                                #   35 variants, 27 ident-bearing, 8 leaf.
                                #   OPT-IN (`# expr-walker: exhaustive`), because 53
                                #   functions branch over Expr and most legitimately care
                                #   about two or three forms — `getVariantKey` wants
                                #   `member` and nothing else. Blanket checking would be
                                #   ~90% noise, and a gate at that ratio gets suppressed
                                #   wholesale (the doc_example_check lesson). The count of
                                #   NON-opted-in walkers prints every run so the gap stays
                                #   visible. Waive a variant with `# expr-walker-ok: <v>
                                #   <reason>`; a reason is required.
                                #   TWO VARIANTS ARE HARDCODED because nothing can derive
                                #   them: `zig_lit` (identifiers live in a STRING — exactly
                                #   how BUG-267 hid from structural reasoning) and `ident`
                                #   (structurally a leaf, yet a usage walker that skips it
                                #   is broken by definition).
                                #   THE SEARCH SET IS DERIVED (a glob over selfhost/*.zbr,
                                #   minus Ast.zbr, which is the ORACLE). It was a HARDCODED
                                #   LIST OF SIX FILES until 2026-08-17, and it failed the
                                #   exact way this gate exists to prevent: a walker moved
                                #   to a NEW module (AstWalk.zbr) and silently left
                                #   coverage -- opted-in went 7 -> 6 while the marker count
                                #   in the tree stayed 7. Nothing went red; the gate just
                                #   checked less. Globbing is safe BECAUSE it is opt-in:
                                #   only marked walkers are checked, so widening the search
                                #   cannot add noise, only stop losing walkers.
                                #   CANNOT SEE: whether a handled variant is handled
                                #   CORRECTLY, and names inside a zig"…" string. Refuses to
                                #   report if <25 variants extract, if its list_lit/int_lit
                                #   controls flip, or if NO walker opted in — a gate with
                                #   nothing to check must not print clean. 0 = clean.
bash tools/ffi_lib_check.sh        # THE PREBUILT-LIBRARY GATE (BUG-266, QUICK tier):
                                #   `use foo` resolving to a prebuilt `foo.lib`/`.a` must
                                #   LINK and the foreign call must return the right value.
                                #   This is the shape a REAL third-party dependency takes —
                                #   a binary you did not build and cannot compile from
                                #   source. BUG-261 covered the `.c` SOURCE case; this is
                                #   the other half, and until 2026-08-06 there was NO route
                                #   to it at all: `BuildTarget.linkLib` takes another Zebra
                                #   build target rather than a path, and the CLI has no
                                #   passthrough, so every foreign call had to be linked by
                                #   hand with `zig build-exe`.
                                #   NO COMPILE-ONLY GATE CAN WITNESS THIS. compile_check and
                                #   full_sweep build with `-fno-emit-bin`, so they never
                                #   link, and an `extern fn` resolving to NO SYMBOL AT ALL
                                #   passes them cleanly. Only a gate that runs the binary
                                #   can tell the difference.
                                #   BUILDS ITS OWN LIBRARY at check time instead of
                                #   committing a binary to the corpus — which also means the
                                #   artifact under test cannot be a stale one passing for
                                #   the wrong reason. The expected value appears NOWHERE in
                                #   the Zebra source, so the program cannot print it without
                                #   really calling in.
                                #   CARRIES A NEGATIVE CONTROL: leg 2 removes the library
                                #   and REQUIRES the value to stop appearing, so leg 1
                                #   cannot pass for an unrelated reason. Classifies on
                                #   PRINTED OUTPUT, never exit code (BUG-259). Refuses to
                                #   report a pass if the library cannot be built.
bash tools/check_mode_check.sh     # THE CHECK-MODE CONTRACT GATE: `-c` is front-end-only
                                #   and deliberately incomplete, so what needs gating is the
                                #   CONTRACT, not the coverage — valid code passes both modes,
                                #   a front-end error fails both, and the asymmetry `--help`
                                #   promises ACTUALLY EXISTS (it requires witnesses that pass
                                #   `-c` and fail `--check-full`). It also guards the SPEED,
                                #   so `-c` silently starting to invoke zig again fails here.
                                #   Carries a built-in failure when no asymmetry witness
                                #   survives, which is why gate_selfcheck lists it as
                                #   self-falsifying. QUICK tier.
python tools/bug_fixture_check.py --gate  # THE REGRESSION-FIXTURE GATE (A1): SQLite's "a
                                #   regression test for every reported bug", as a lint rather
                                #   than a habit. Fails only on NEW debt — the existing
                                #   backlog is baselined — and counts a fixture as real only
                                #   if something actually RUNS it, since an orphaned .zbr
                                #   nobody executes is the shape this class of debt takes.
                                #   Also globs test/boundary/*.zbr. Static; instant. QUICK.
python tools/registration_check.py # THE UNASSERTED-FILE GATE (BUG-243, static, instant):
                                #   every tracked test/*.zbr must have its status asserted by
                                #   SOMETHING — a smoke* registration, presence in the
                                #   full_sweep pass baseline, or an entry in
                                #   tools/registration_exempt.txt WITH A REASON.
                                #   Why: full_sweep gates against a BASELINE, so a file that
                                #   has NEVER passed cannot make it red however broken it is;
                                #   and with no registration nothing asserts it should fail
                                #   either. A permanently-broken file is then indistinguishable
                                #   from an intentionally-negative one. Fifteen were found in
                                #   exactly that state on 2026-08-02 — including the regression
                                #   fixtures for BUG-106 and BUG-108, which had NEVER RUN, so
                                #   those fixes were unverified. Baselined like bug-fixture:
                                #   fails only on NEW debt (24 known). Shrink it, never grow it.
                                #   QUICK tier.
python tools/lint_decl_exhaustive.py  # THE Ast.Decl EXHAUSTIVENESS GATE (static,
                                #   instant, no build) -- BUG-103's PIN, and the reason
                                #   that ticket sat open for months after being FIXED.
                                #   The 2026-05-06 fix replaced four `else => {}`
                                #   catch-alls in the metadata passes with exhaustive
                                #   arms, so adding an Ast.Decl variant becomes a Zig
                                #   COMPILE ERROR rather than a silent skip. But the
                                #   defect only fires when someone ADDS a variant, so it
                                #   cannot be written as a Zebra program: no test/*.zbr
                                #   fixture can exist, and the evidence was an annotation
                                #   plus a reading of the source, never a run.
                                #   WHAT IT GUARDS is the property, not the fix: the
                                #   compile-error guarantee holds only while the switches
                                #   stay exhaustive, and ONE `else => {}` restores the
                                #   original silent-skip while Zig stops complaining. That
                                #   reintroduction is invisible to every other gate -- the
                                #   code compiles, every test passes, and a future variant
                                #   is quietly dropped.
                                #   ORACLE = src/Ast.zig's own `Decl` union, never a
                                #   hand-written list; a second copy is precisely the thing
                                #   this bug is about. NESTED switches are not the subject:
                                #   extractFromDecls legitimately carries `else =>` arms on
                                #   inner TypeRef switches, so arms are matched at the
                                #   Decl switch's own BRACE DEPTH, not by proximity.
                                #   Verified RED both ways: reintroducing a catch-all, and
                                #   deleting one variant's arm. Refuses (exit 2) if <8
                                #   variants extract or a site cannot be found -- a regex
                                #   that stopped matching must blame itself. 0 = clean.
                                #   CANNOT SEE whether an arm does the right thing.
python tools/lint_oom_unreachable.py  # THE RELEASE-ONLY-UB GATE (A4): `unreachable` is
                                #   undefined behaviour in ReleaseFast, which is what
                                #   `zebra --release` ships. Every gate here runs Debug,
                                #   where it TRAPS cleanly — so this hazard is invisible to
                                #   all of them and live only in what users distribute.
                                #   A static lint is the only witness that can see it at all.
                                #   0 = clean. QUICK tier.
bash tools/output_sweep.sh --gate  # THE BEHAVIOUR WITNESS — the only heavy gate that
                                #   RUNS the corpus and reads what it PRINTED. Everything
                                #   else in the FULL tier asks "does the emitted Zig
                                #   compile?", so valid Zig producing WRONG OUTPUT is
                                #   invisible to all of them at any corpus size (BUG-226:
                                #   a for-header `tokenize` emitted {any} and printed
                                #   `{ 97 }` for `a` — perfectly good Zig).
                                #   358 of the 374 compile-clean files, golden-baselined.
                                #   A CRASH IS NOT A FLAKE, and conflating the two cost
                                #   real coverage silently (2026-08-17, BUG-290). A panic
                                #   header carries a THREAD ID — `thread 7440 panic: …` —
                                #   so a program that crashes DETERMINISTICALLY produced
                                #   different output on all three samples and was
                                #   auto-excluded as nondeterministic. The only gate that
                                #   RUNS programs was therefore discarding, automatically,
                                #   a class of the failures it exists to catch.
                                #   test/stdlib_misc_test.zbr sat in that hole from at
                                #   least 07-31, failing at runtime the whole time, and
                                #   its panic text CHANGED while excluded ("reached
                                #   unreachable code" -> "assert failed at :33") with no
                                #   gate reporting anything. It is what hid BUG-290.
                                #   The fix is one normalisation (`thread <TID> panic`),
                                #   NOT a blanket "include crashers": the TID is a
                                #   volatile FIELD like a duration, and the existing rule
                                #   is to normalise those rather than exclude the file.
                                #   Safe because no legitimate output has the shape —
                                #   `grep -cE "thread [0-9]" output_baseline.txt` is 0.
                                #   BOTH DIRECTIONS WERE MEASURED in the same re-baseline:
                                #   stdlib_misc_test and bug259_runtime_exit_code_test
                                #   moved INTO the baseline (deterministic crashes, now
                                #   pinned and visible), while
                                #   arena_concurrency_hazard_test STAYED excluded — its
                                #   panicking-thread COUNT varies run to run (1, 1, 4),
                                #   which is real nondeterminism. 18 -> 16 exclusions,
                                #   356 -> 358 baselined, 0 transients, nothing else moved.
                                #   REFUSES `--only` WITH `--update-baseline`. The update
                                #   path REPLACES the baseline from what the run measured
                                #   (`cp manifest.txt $BASELINE`), so restricting the run
                                #   would have left a ONE-FILE baseline — green forever
                                #   while measuring one program. Nothing downstream could
                                #   see it: the 25%-empty control counts EMPTY records,
                                #   not MISSING ones, so a short baseline of perfectly
                                #   good entries sails past. Refusing beats merging,
                                #   because merging is how a stale record survives a
                                #   re-baseline forever.
                                #   NONDETERMINISM IS DERIVED, never hand-listed:
                                #   --update-baseline takes THREE samples and, if they
                                #   disagree, a three-sample CONFIRMATION ROUND — only a
                                #   REPRODUCED difference is excluded, with its reason
                                #   recorded. A hand-written skip list rots and silently
                                #   shrinks coverage; what the confirmation round fixes is
                                #   that a DERIVED list could silently shrink too, which
                                #   is the same failure in better clothes.
                                #   THE ASYMMETRY IS THE ARGUMENT. A wrongly-EXCLUDED file
                                #   leaves behaviour coverage permanently and reports
                                #   nothing; a wrongly-INCLUDED flaky file fails the gate
                                #   loudly and names itself. Prefer the recoverable error.
                                #   RECEIPT (2026-08-15): a re-baseline dropped `log_test`
                                #   and `refinement_type_test` as nondeterministic. Both
                                #   are deterministic — 10x and 8x byte-identical on the
                                #   built executables, 5x through this harness's own
                                #   --show path. The disagreement appears only inside a
                                #   full 354-file sweep and IS STILL UNEXPLAINED; the
                                #   obvious pipe-capture theory was tested and FAILED
                                #   (12/12 identical through both `$(...)` and a file
                                #   redirect). Recorded as an open question rather than
                                #   given a tidy cause it has not earned.
                                #   TRANSIENTS ARE PRINTED EVERY RUN, including zero, and
                                #   named when non-zero: a rate that starts climbing is
                                #   the early warning that something in the environment
                                #   changed, and it is only legible against a number that
                                #   was always there.
                                #   Both paths are control-tested: a genuinely
                                #   nondeterministic file (log_json_test, which prints a
                                #   clock) must still be excluded, and a forced single
                                #   disagreement must be KEPT and counted.
                                #   LIMIT: golden baseline = catches REGRESSIONS, not
                                #   existing wrongness — same limit full_sweep_baseline
                                #   has. It refuses to write a baseline that is >25%
                                #   empty, so a broken capture cannot become a gate that
                                #   is green forever while measuring silence.
                                #   Sequential by design (parallel fixtures interfere).
                                #   --update-baseline to re-record, --only for a tight
                                #   loop, --show to see what is being captured.
JOBS=2 bash tools/full_sweep.sh --examples --gate  # gate label: `examples_sweep`
                                #   A5 — THE SAME SWEEP OVER examples/.
                                #   Until 2026-07-30 NO gate touched examples/ at all: every
                                #   heavy gate globs test/*.zbr. That was not theoretical —
                                #   examples/widget_smoke.zbr SHIPPED BROKEN on BUG-230, and
                                #   `zebra -c` exits 0 on it (check mode is front-end-only),
                                #   so the obvious spot-check could not see it either. BOTH
                                #   had to be true for it to go unnoticed.
                                #   First run: 18 examples, 14 baselined, and it found BUG-233
                                #   on the spot. Small (~90s) → FULL tier. Non-passing entries
                                #   are NAMED in its output, not just counted, because on this
                                #   corpus each one is a question worth answering.
                                #   `DEPMISS` ≠ broken: a search-path dep that --output-dir
                                #   never emitted (lsystem RUNS fine). A gate that libels a
                                #   working file is one people learn to disbelieve.
JOBS=2 bash tools/full_sweep.sh --gate   # THE FULL-CORPUS WITNESS — and since
                                #   2026-08-19 it carries TWO legs, because it absorbed
                                #   compile_check's property rather than duplicating its
                                #   work. MEASURED: compile_check's positive set (276) is
                                #   a strict SUBSET of this corpus (499) with ZERO unique
                                #   entries, and both ran the same
                                #   `zig build-exe -fno-emit-bin -lc` over the same
                                #   selfhost emit — so the FULL tier emitted and compiled
                                #   276 files TWICE, ~8 minutes per run.
                                #   THE TWO LEGS DIFFER IN KIND, which is why this was
                                #   not a plain deletion. RELATIVE: 0 regressions vs the
                                #   baseline — a file OUTSIDE the baseline cannot make it
                                #   red however broken. ABSOLUTE: every test the smoke
                                #   suite registers as positive must pass, baseline or
                                #   not. Dropping compile_check without the second leg
                                #   would have traded an absolute guarantee for a
                                #   relative one, silently.
                                #   Prints both numbers every run.
                                #   compile_check remains the manual `--only` tool, and
                                #   compile_check-inline STAYS in the tier: the INLINE
                                #   runtime shape is watched by nothing else.
                                #   (was:) emits + zig-
                                #   typechecks EVERY test/*.zbr (403), not just the ~210
                                #   compile_check covers. --gate fails on REGRESSION vs
                                #   tools/full_sweep_baseline.txt (the set that currently
                                #   emit+compile clean, 331). Known negatives/library/
                                #   triage-backlog files need no skip-list — the baseline
                                #   IS the allow-list; re-baseline (--update-baseline) when
                                #   the pass set intentionally grows. Heavy (~25 min, JOBS=2
                                #   — RAM-bound); per-session/pre-release like compile_check.
```

## A failing `zig build-exe` is not automatically a verdict on OUR code

`tools/zig_build_lib.sh` holds ONE definition of "zig failed for a reason that is not about
our emitted output", used by `full_sweep`, `divergence_check` and `compile_check`. It is a
library, not a gate: source it, call `zbr_zig_build "$main" "$berr" 90`, read `ZBR_RC`, and
**report `ZBR_RETRIES` every run including zero**.

It exists because BUG-302 cost seven occurrences across five gates before anyone saw the
error, which turned out to be zig failing to read **its own standard library**:

```
.../.zvm/0.16.0/lib/std/debug.zig:1:1: error: unable to load 'debug.zig': Unexpected
```

`Unexpected` is zig's catch-all for an unmapped OS error; on Windows it shows up under
concurrent builds sharing the stdlib. The failing path is inside the ZIG INSTALLATION, so
our program was never compiled — yet all three gates classified it as `CFAIL`/`FAIL`
("emitted bad Zig"), and in `divergence` that became a **SELFHOST GAP**, the loudest claim
it can make.

**THE REASON IT TOOK SEVEN OCCURRENCES IS THAT EVERY GATE DELETED THE EVIDENCE.**
`full_sweep.check_one` ends `rm -rf "$wdir"`, taking `build.err` with it for every file;
`divergence_check` sent stderr to `/dev/null` outright. The bug was undiagnosable by
construction — no amount of re-running could have produced that message. It was found by
preserving one file, not by another hypothesis. **A gate that classifies a failure must
keep the failure's own account of itself.**

**AND SOMETHING MUST READ IT — keeping it is only half (2026-08-26).** After `EMITFAIL`
started preserving the compiler's stderr, the board still said `EMITFAIL x55` and nothing
consulted the 55 files. A reader had to know the directory existed, know which of the 55
mattered, and open them by hand; UNGIT "nothing withheld" is about the surface the user is
ALREADY LOOKING AT. `bash tools/evidence_digest.sh` (report only, fails nothing) reconciles
the kept evidence against what the smoke suite DECLARES, and `full_sweep --gate` runs it and
folds the two actionable figures onto its own terminal line, because `gates.sh` surfaces a
gate's LAST LINE and anything printed above it is swallowed on a PASS.

Its first run turned a bare 55 into three actions: two exhaustiveness negatives that were
correctly rejected and registered by nothing, and `tc_merge_fixture`, which holds git
conflict markers and cannot compile standalone by construction. `registration_check` went
**18 → 15** unasserted.

**IT RECONCILES BOTH DIRECTIONS, and that is the whole design.** Counting undeclared
refusals alone reaches 0 the day the debt is cleared and then prints `N declared, 0
undeclared` forever — identical output whether it works or whether the lookup silently
stopped matching. A tool that goes vacuous BY SUCCEEDING is the worst version, because
nobody is suspicious on the day a number improves. So it also asserts that every declared
must-reject fixture DID refuse: **a negative test that has started passing** is otherwise
invisible — its registration quietly stops asserting anything the day its bug is fixed.
That direction keeps a non-trivial denominator (51) forever, which is what makes the other
direction's zero mean something. Both were watched going red.

Two traps it was built around, both found by measuring rather than reasoning. **The three
evidence suffixes are not one population**: `.emit.err` is OUR compiler refusing the SOURCE,
`.cfail.err`/`.fail.err` are ZIG refusing our OUTPUT. The first draft globbed all three and
named 33 files as undeclared debt, ~30 of them working files already tracked by
`full_sweep`'s baseline — and a gate that libels a working file is one people learn to
disbelieve. And `divergence`'s evidence is **not reconciled at all**: it emits with both
compilers into one directory and the filenames do not record which one failed, so its count
is reported unreconciled rather than silently folded in or silently dropped.

`tools/must_reject_set.sh` is the derivation behind it — the mirror of `positive_set.sh`,
and now the single source for `divergence_check` too. That gate carried its own inline copy
which was LOSSY (`test/[A-Za-z0-9_]+\.zbr` requires a flat path, so every registration under
`test/fail_fixtures/` was invisible: 48 where the suite registers 54). Harmless only because
`corpus_ls.sh test` does not recurse — an unstruck gap, armored because a shared derivation
costs nothing extra to get right. It REFUSES below a floor rather than returning a short
list, since a collapsed set makes every rejection look unexpected downstream.

Measured 2026-08-22: in one instrumented run, 20 `CFAIL`s were 19 genuine errors in our
output plus exactly ONE infra error — and that one file was precisely the "REGRESSION"
against the baseline. Prior rate was 2 of 3 `full_sweep` runs producing a false red.

- Retries **only** this failure, three tries. `FileNotFound` is deliberately excluded: that
  means a dep of ours was never emitted, it is deterministic, and `DEPMISS` covers it.
- A persistent one is `INFRA` (`CINFRA` in divergence, where it is excluded from gap
  accounting the way `NOMAIN` already is) — never `CFAIL`.
- **The retry count prints every run, zero included.** A rising rate is the early warning
  that the environment changed; a number that only appears when it is bad is a number
  nobody has a baseline for. Same discipline as `output_sweep`'s transients.

`bug302-control` (FAST tier, `tools/bug302_infra_retry_check.sh`) falsifies it with the REAL attacker rather than a mutation:
a stub `zig` emitting the verbatim error, failing once then succeeding. Four legs, and
**leg 2 is the load-bearing one** — a genuine compile error must NOT be retried, or the
retry masks breakage and triples runtime. It sources the SHIPPED predicate, so it cannot
pass against logic the gates do not have.

Why this matters: a green round-trip means the compiler is *self-consistent*, NOT that
what it emits is *correct*. The independent witness (`zig`, which has no idea what Zebra
intended) is the only gate that checks correctness of arbitrary emitted programs. A real
latent miscompile hid behind green round-trip + smoke once (see the §28a selfhost notes);
`compile_check.sh` is how you avoid rediscovering that class the hard way.

**But note the ceiling on that sentence, because it is easy to over-read (BUG-226,
2026-07-29).** `compile_check`, `full_sweep` and `divergence` all ask *"does the emitted
Zig compile?"* — none of them **runs** it. Only `selfhost_smoke.sh` (for its registered
fixtures) and `runtime_module_check.sh` execute anything. So a bug whose symptom is
**correct-compiling code that produces the wrong output** is invisible to the three
heaviest gates by construction, no matter how much corpus you throw at them.

BUG-226 is the receipt: `for t in s.tokenize(",")` typed its loop element wrongly and
emitted `{any}` instead of `{s}`, so it printed `{ 97 }` where `a` was meant. Perfectly
valid Zig. It would have survived every tier indefinitely. What catches this class is a
**run-and-compare fixture** — a `smoke_run` with expected output — which is why a
rendering or semantics fix should always land with one, and why "compile_check is the
independent witness" means *witness to compilability*, not to correctness of behaviour.

**`tools/output_sweep.sh` (added 2026-07-30) closes most of that gap** — see its entry
below. Behaviour coverage went from 126 files to 327, and to **358** once a crash stopped
being mistaken for a flake (2026-08-17). It does not remove the need for a
`smoke_run` on a new fix: the sweep is a *golden* baseline, so it can only tell you
behaviour CHANGED, never that it was right to begin with.

**`tools/boundary_check.sh` (added 2026-07-30) is the answer to that last clause**, and it
is the only gate here that can be. Its expectations were written from QUICKSTART *before*
the compiler was run, so it asserts what the language is supposed to do rather than what it
happens to do — which is why it found BUG-230 on its first run, a three-line program that
does not compile and that no corpus-based gate could ever have surfaced (both compilers
share the bend, and the `test/*.zbr` corpus the heavy gates sweep does not use the form —
the one file that does is `examples/widget_smoke.zbr`, which is **shipping broken**,
because no gate sweeps `examples/` at all). Treat "recorded" and "intended" as
genuinely different properties: everything else in this file measures the first.

### Which property does each gate actually assert?

Worth keeping straight, because "how many gates are green" answers a different question
than "what do we know":

| property | asserted by | corpus coverage |
|---|---|---|
| front end doesn't error | `smoke` (bare helper — emit only, does **not** compile) | 101 |
| emitted Zig compiles | `compile_check`, `full_sweep`, `divergence` | 335 |
| compiler is self-consistent | `bootstrap_check` (round-trip) | selfhost only |
| **program prints the right thing** | `smoke_run`/`smoke_test`, **`output_sweep`** | **358** |
| **…and it is the RIGHT thing, per the reference** | **`boundary_check`** (intent-authored, not recorded) | 32 probes / 308 assertions | <!-- doc-gen: 32 = bash tools/corpus_ls.sh test/boundary | wc -l | tr -d ' ' --> <!-- doc-gen: 308 = cat test/boundary/*.expected | grep -c . -->
| **a foreign symbol actually LINKS and returns** | **`ffi_lib_check`** (builds its own library + negative control) | 1 prebuilt lib |
| **an Expr walker descends into every variant that holds exprs** | **`lint_expr_walkers`** (oracle = `Ast.zbr`) | 10 opted in; the gate prints the ratio | <!-- doc-gen: 10 = grep -rho 'expr-walker: exhaustive' selfhost/*.zbr | wc -l | tr -d ' ' -->
| parser survives hostile input | `fuzz/gramgen.py` | 960 derived programs |
| static hazard classes | `lint_interp_escape`, `lint_fallthrough` | all `.zbr` |
| generated docs match the compiler | `str_ownership_extract --check` | 28 operations |
| **a bug number resolves to exactly one bug** | `lint_bug_numbers` (+ allocator line) | 199 slots, 2 ledgers |
| **the gates can still fail** | `gate_selfcheck.sh` | 7 gates |
| **the TIER SELECTOR can still fail** | `tier_selfcheck.sh` | 6 mutations, incl. a control |
| **our own tools are not lying** | `hazard_lint` (+ its controls) | 95 scripts | <!-- doc-gen: 95 = ls tools/*.sh tools/*.py fuzz/*.py *.py 2>/dev/null | wc -l | tr -d ' ' -->
| docs' checkable claims still resolve | `doc_lint` | 55 tracked documents <!-- doc-gen: 55 = git ls-files | grep -cE '^[^/]+\.md$|^docs/[^/]+\.md$' --> |
| **a reserved word is used, or justified** | `reserved-words` (both compilers) | 81 keywords, 1 baselined |
| **a diagnostic can say WHERE** | `diag-columns` (derived candidates, baselined) | 49 must-fail fixtures, 18 baselined |
| **a word ZIG reserves and Zebra does not survives codegen** | `keyword-ident` (derived site map, no allow-list) | 6 keywords × the positions one fixture reaches |
| **…and the list of such words is not STALE** | `zig-keywords` (oracle = zig's own tokenizer table) | 46 keywords × both compilers |
| **the docs' EXAMPLES actually parse** | `doc_example_check` | `live` docs only; the gate prints its own block and doc counts | <!-- doc-gen: 55 = git ls-files | grep -cE '^[^/]+\.md$|^docs/[^/]+\.md$' -->

The last row is the one that keeps the rest honest; see its header for why.

## What the gates do NOT cover — and when it was last checked

`gates.sh` deliberately excludes three things from `--full` so that "gates green" keeps a
precise meaning. That precision is only worth anything if the excluded set is actually run
sometimes, so record the date here when you do.

**AS OF 2026-08-19 THOSE THREE ARE THE `--daily` TIER** — `gramgen`, `gui-scaffold`,
`node-addon`. They are still out of `--full`; what changed is that they have a name and a
cadence instead of a paragraph asking someone to remember. The paragraph did not work:
their last recorded sweep was 2026-08-04, and wiring the tier immediately found that
**node-addon had regressed in between (BUG-297)** — `--target node-addon` on a class
STATIC-block export emits a reference to the owning class that is never declared. It is
PINNED rather than excluded, so it is visible on every daily run and the pin fails the
tier the day the bug is fixed.

Two smaller findings from the same wiring, neither of them a compiler regression:
`gramgen` is clean (960 programs, 0 hangs, 0 crashes), and `gui-scaffold` **printed
"startup path clean" while its leg 2 had not run at all — BUG-298**. Leg 2 skips when it
finds no `app.exe`, which is also exactly what a FAILED build looks like; here a corrupted
scratch cache in the temp scaffold root was making the build fail, while leg 1 went on
asserting against a `main.zig` left on disk by an earlier run. The tui path itself is
fine: clearing that directory made the build produce an app, which then refused a non-tty
console (rc=3), the documented healthy outcome. Since `gui-scaffold` is the repo's ONLY
automated GUI coverage, half of it silently not running takes that number back to zero —
read its leg 2 line rather than its exit code until BUG-298 is fixed.

**FULL tier 2026-09-05 (second run, BUG-320's compound half): 36/37 in-tier + divergence
standalone.** smoke **400/400**, round-trip byte-identical, `output_sweep` 404 files behaviour
identical, `full_sweep` 0 regressions vs 422, `examples_sweep` 0 vs 19, `boundary` 32/0,
`compile_check-inline` 306/0, `release-mode` and `contract-mode` 13/13, `divergence` 0
regressions vs the N-1 anchor. **ASSEMBLED, not observed in one invocation** -- recorded that
way deliberately, per the precedent below: nothing proves the tree was identical throughout.

**`divergence` was KILLED AT ITS 5400s CEILING, and that was the ENVIRONMENT, not the gate.**
The whole run was roughly 3x slower than the run four hours earlier on the same tree: smoke
1253s against 380s, `output_sweep` 2705s against 885s, `compile_check-inline` 1528s against
449s. Re-run standalone immediately afterwards, `divergence` passed. This is the documented
2-3x spread arriving all at once rather than a new problem, and it is the concrete case the
ceiling warning above describes -- the gate says "SLOW or hung, this cannot tell which", which
is the honest report and the reason a standalone re-run is the answer rather than a bigger
number.

**A number that has to move: the ceiling is now within one bad night of the heaviest gates.**
`output_sweep` took 2705s in this run against a 5400s ceiling. Nothing is proposed here,
because raising a ceiling to accommodate a slow night is how a hang stops being detectable --
but the margin is a factor of two, not the comfortable order of magnitude it reads as.

**FULL tier 2026-09-05: 37/37 PASS in ONE invocation at JOBS=2**, closing the string-indexing
batch (BUG-319, BUG-330, BUG-225). smoke **399/399**, round-trip byte-identical,
`compile_check-inline` **305/0**, `output_sweep` **404 files behaviour identical**,
`full_sweep` 0 regressions vs **422**, `examples_sweep` 0 vs 19, `divergence` 0 regressions
vs the N-1 anchor, `release-mode` and `contract-mode` 13/13.

**BOTH HEAVY BASELINES WERE RE-RECORDED IN THIS RUN'S RUN-UP, in the documented order
(full_sweep first).** `full_sweep` **390 -> 422** and `output_sweep` **356 -> 404**. The
first number discharges a debt this file has been flagging against itself: those 32
accumulated passes could not make the gate red however badly they broke, and now they can.
The re-baseline was taken only AFTER `full_sweep --gate` reported 0 regressions, because
`--update-baseline` re-records whatever it measures -- gating first is the whole difference
between locking in a pass set and silently locking in a regression.

**Exclusions moved 16 -> 18 and that is NOT a coverage loss, which took reading the diff to
establish rather than the count.** The three nondeterministic entries are the SAME files
re-recorded with fresh sample text; the two genuinely new entries are `query_string_test`
and `tcp_echo_roundtrip_test`, both excluded by CAPABILITY (they contact a remote host), a
documented separate category from nondeterminism. A rising exclusion count is exactly the
shape of the silent loss this file warns about, so it is worth checking WHICH files moved
every time, not just how many.

**The only red across two FULL-tier attempts was `doc-lint`, both times on a count THIS
CHANGE invalidated** -- the tracked-corpus figure after adding fixtures, then the
`full_sweep` baseline figure after re-recording it. Both had `doc-gen` oracles and both went
red within the hour. That is the D6 mechanism working exactly as designed, and it is worth
noting that the numbers which rot silently are the ones WITHOUT an oracle, not these.

**DAILY tier 2026-08-30: 37/37 PASS — NO XFAIL, in ONE invocation, 2h10m at JOBS=2.**
Run as the closing move on the day BUG-315, BUG-316, BUG-318 and BUG-320's plain half were
fixed, the imgui backend was retired, and NEXT_STEPS was split. smoke **391/391**,
round-trip byte-identical, `compile_check-inline` **300/0/0**, `output_sweep` /
`full_sweep` / `examples_sweep` 0 regressions, `divergence` **0 selfhost gaps**, `gramgen`
960/0/0, `gui-scaffold` clean, `node-addon` PASS, `stream-sep` 7/7.

**`examples_sweep` green is the line that matters most here.** It is the gate that would
have caught BUG-320 -- a shipped example stopped compiling for ~24 hours because after
landing BUG-313 only static/fast/quick were run. This tier is the convention that catches
that class, demonstrated rather than described.

**THE TIER IS 37 GATES, up from 35, and both additions exist because something got through
that nothing could see:** `keyword-coverage` (a language feature no test exercises --
`protected` and `internal` were the two, and BOTH were defective) and `stream-sep`
(`print` went to stderr, invisible because `output_sweep` captures `2>&1` and therefore
merges the two streams it would have needed to distinguish).

**AND THE UPPER BOUND MOVED AGAIN, 110 min -> 2h10m.** The table above now reads 37-130.
No cause is offered. This run followed several full rebuilds of both compilers, which
invalidates zig's cache downstream -- the same untested hypothesis already recorded for the
08-20 and 08-26 runs, still untested. Recorded as an observation, not a diagnosis.

**DAILY tier 2026-08-26: 35/35 PASS — NO XFAIL, in ONE invocation, 110 min at JOBS=2.**
The first fully green daily with nothing pinned: `node-addon` passes for real now that
BUG-297 is fixed, so the tier's arithmetic is 35 = 35 rather than 34 + 1. smoke **384/384**,
round-trip byte-identical, `compile_check-inline` **295/0/0**, `output_sweep` 374 behaviour
identical, `full_sweep` and `examples_sweep` 0 regressions, `divergence` **0 selfhost
gaps**, `gramgen` 960/0/0, `gui-scaffold` clean.

**AND THE UPPER BOUND MOVED AGAIN, 85 → 110 min.** The table above now reads 37–110. No
cause is offered: this run followed several rebuilds of both compilers, which invalidates
zig's cache downstream — the same untested hypothesis already recorded for the 08-20 run,
and still untested. Recorded as an observation.

It closed a day that fixed BUG-297, 298, 300, 301, 264, 246, 212, 103 and then 307, 309,
310, 308 — and the last four all came out of ONE red gate. `output_sweep` reported a
`File.delete error` panic appended to `try_outer_vars`; chasing it found a selfhost parity
gap that crashed on an absent file (307), and reading the neighbourhood found two
fabricating catches in the shipped runtime (309, 310) plus a retry loop that could never
retry (308).

**THE DAY'S TRANSFERABLE LESSON IS ABOUT EXIT CODES, and it cost a real result.** The first
daily was run as `gates.sh --daily 2>&1 | tee log | tail -60`; the harness reported exit 0
and the tier had FAILED. **The pipeline's status is `tail`'s.** Worse, the obvious
`grep -E "^gates:"` recovery ALSO reads as success — the PASS terminal line is uncoloured
and the FAIL line is ANSI-colour-prefixed, so anchoring at `^gates:` matches only the green
form. Two independent ways to read a red daily as green, stacked. Capture the code with no
pipe (`gates.sh ... > log; rc=$?`) and match `gates:` unanchored.

**DAILY tier 2026-08-22: 33/34 PASS + 1 XFAIL in ONE invocation, 74 min at JOBS=2** —
the first full tier since BUG-302 was fixed, i.e. the first one whose red would have meant
something. smoke **376/376**, round-trip byte-identical, `output_sweep` 374 behaviour
identical, `full_sweep` 0 regressions vs 390 + positive set 288/288, `examples_sweep` 0 vs
19, `divergence` **0 selfhost gaps**, `gramgen` 960/0/0. `node-addon` XFAILed against
BUG-297.

It closed a day that landed bitwise `& | ^ ~ << >>` in both compilers and BUG-302.

**AND THE BUG-302 FIX PROVED ITSELF DURING THIS VERY RUN — which was found by accident,
because the tier board could not show it.** `gates.sh` surfaces one line per gate, so the
per-gate retry counts never reached the summary. The evidence was a `retries.txt`
timestamped inside the tier window naming `hashmap_dispatch_collision_test` and
`shared_var_test`: **the zig-stdlib read failure fired twice and was absorbed, with the
gate passing.** Under the previous behaviour that is up to two phantom regressions and a
red daily — exactly what happened to the 2026-08-22 00:39 run, whose three red gates were
all false.

That accident also exposed the counter itself being wrong: `compile_check` and
`divergence` do `mkdir -p "$OUT"` with no `rm -rf` (only `full_sweep` clears), so
`retries.txt` accumulated across runs and a one-file run reported 2 retries it had not
made. Per-run now, and the counts ride ON `compile-check`'s summary line rather than after
it. **A number that only grows is not a counter, and nothing about it looks wrong.**

**DAILY tier 2026-08-20: 32/33 PASS + 1 XFAIL in ONE invocation, 84m42s at JOBS=2** —
run as the CLOSING MOVE of a night's bug work, which is the convention Sean set that day
(see the tier-ladder section). Every gate green on the committed tree: smoke **366/366**
(up from 359 — seven new regression registrations), round-trip byte-identical,
`compile_check-inline` **281/0/0**, `output_sweep` 374 behaviour-identical, `full_sweep`
0 vs 390 + positive set, `examples_sweep` 0 vs 17, `divergence` **0 selfhost gaps**,
`gramgen` 960/0/0, `gui-scaffold` clean. `node-addon` XFAILed against BUG-297.

That run closed a night in which six ledger entries moved from OPEN to CLOSED (BUG-027,
079, 083, 084, 085, 124) — each with a fixture that was watched going RED against a
compiler with its own fix mutated out — plus BUG-299 filed and BUG-233 investigated. The
tier is what says the tree is still sound afterwards, and it is the reason those closures
can be believed rather than merely asserted.

**`--daily` CONFIRMED CLEAN, 2026-08-19 — 32/33 PASS + 1 XFAIL in ONE invocation,
36m56s at JOBS=2**, on the committed tree with the `examples_sweep` fix. Every gate green:
smoke, round-trip, `compile_check-inline` **276/0/0**, `output_sweep` 374 identical,
`full_sweep` 0 vs 390 + positive set 276/276, `examples_sweep` 0 vs 17, `divergence`
**0 selfhost gaps**, `gramgen` 960/0/0. `node-addon` XFAILed against BUG-297, as
registered — the pin's accounting reconciles in a real tier (32 + 1 = 33 expected).

**FIRST `--daily` TIER, the run before it — 33 gates in ONE invocation, 56m43s at JOBS=2:
30 PASS, 1 XFAIL, 2 FAIL.** smoke **359/359**, round-trip byte-identical, `output_sweep` 374
files behaviour identical, `full_sweep` 0 regressions vs 390 **plus positive set 276/276**,
`divergence` **0 selfhost gaps**, `boundary` 29/0, `contract-mode` 13/13, `release-mode`
clean, `gramgen` 960 programs / 0 hangs / 0 crashes. `node-addon` XFAILed against BUG-297,
as registered.

**THE TIER'S FIRST RUN FOUND A REGRESSION TWELVE HOURS OLD, IN A GATE, THAT NO TIER HAD
RUN SINCE IT CHANGED.** `examples_sweep` could not pass at all: `f5640dd` gave `full_sweep`
its new absolute positive-set leg and did not guard it for `--examples`, so the gate
compared the 276-file **test/** positive set against the **examples/** pass list and
reported every one as a MUST-PASS failure. That commit's verification list covered
`full_sweep` and not its `--examples` sibling — the two are the same script, which is why
the leg was worth sharing and exactly why a leg has to name its corpus. Fixed and
re-verified both ways: examples 0 regressions vs 17 (RELATIVE leg only, and it now SAYS
so), test/ still printing `positive set 276/276 pass`.

**The other failure did not reproduce and is recorded rather than explained.**
`compile_check-inline` reported `iter_collision_test` as "emitted, but zig refused" at
275/1. Standalone: 1/1. Full re-run of the same gate on the same tree: **276/0/0**, and
**276/0/0** again in the clean tier run above. That is the second single-file
non-reproducing failure in this gate in two days under tier load (the first was
2026-08-19's `275 passed / 1 skipped`), and the honest statement is that the rate is worth
watching — not that "it was load", which is a story that fits every observation and
predicts nothing. A third occurrence stops being a transient and becomes the finding.

**TWO MORE FULL TIERS, 30/30 EACH IN ONE INVOCATION, overnight 2026-08-18** — BUG-294
(`8d26aad`) then BUG-293 (`e7b9679`). smoke 348 -> 349, `compile_check` **270/0/2** in
both runtime shapes, `output_sweep` 358 behaviour-identical, `full_sweep` 0 vs 374,
`divergence` **0 selfhost gaps**, `boundary` 29/0 throughout.

**The transferable half is that both bugs were SEEDING failures, not logic failures.**
Each had a correct decision procedure fed by a registry that was populated wrongly:

- BUG-294 — `for_loop_deref` was seeded by a HARDCODED special case (`if iter_member ==
  "entries"`, adding `key` and `value`), correct for the single call site it was written
  for; and the current module's `^T` fields were registered as a side effect of EMITTING
  the struct, so the answer depended on generation order. Both replaced by derivations.
  Note the second is the SAME hazard **BUG-286** fixed for namespace names — its comment
  already states the rule, and it recurred anyway in a neighbouring registry.
- BUG-293 — `fn_param_lists` crossed the module boundary (§27b) and the BODY did not, so
  `paramNeedsAddrOf` answered "no addr-of" for want of evidence.

**And a gate had silently stopped checking, caught only by arithmetic.**
`lint_expr_walkers` carried a HARDCODED list of six files; moving a walker to a new
module took opted-in from 7 to 6 while the marker count in the tree stayed 7. Nothing
went red. Its search set is now derived by glob. **When a count moves for a reason you
can explain, reconcile it against an independent oracle anyway** — the explanation and
the loss looked identical.

**FULL tier 2026-08-17: 30/30 PASS, IN ONE INVOCATION** (`JOBS=2 bash tools/gates.sh
--full`, start to finish, on the committed tree). smoke **344/344**, round-trip
byte-identical, `compile_check` **266/0/2** in BOTH runtime shapes, `output_sweep` 358
behaviour-identical, `full_sweep` 0 vs 374, `examples_sweep` 0 vs 17, `divergence`
**0 selfhost gaps**, `boundary` 29 pass / 0 fail, `contract-mode` 13/13,
`release-mode` clean. The tier is now **30** gates (was 29).

Landed with it: BUG-292's `collectOldNodes` extraction, plus **BUG-293** and
**BUG-294**, both found BY the extraction rather than by a sweep.

**Two things from that run worth keeping.** First, `divergence` went **red** on the
first FULL attempt and the fix was not to quiet it: BUG-294's probe is a selfhost gap
*by construction*, and registering it `smoke_tc_fail` would have silenced the gate
through its derived `MUST_REJECT` list — a list whose meaning is *"the selfhost is
SUPPOSED to reject this"*, which is the opposite of the truth. It moved to
`test/boundary/` as an `@boundary-pending` tripwire instead. **A derived exemption is
still a lie if you enter the wrong declaration to reach it.**

Second, **BUG-294 was found by the round-trip and could not have been found by
anything else here.** smoke was 343/343 with the defect live in the compiler's own
source, because the binary smoke runs is built from the BOOTSTRAP's emit, which is
correct. Only `bootstrap_check` builds selfhost-B from selfhost-A's OWN emit. The
claim above that a green round-trip does not prove correctness has a mirror image
that is just as load-bearing: **a green smoke suite says nothing about what the
selfhost emits for the selfhost.**

**BUG-288 BATCHES 1 AND 2 LANDED 2026-08-16** — literals, then compound expressions,
carry real source positions. `diag-columns` **18 → 14**, and the candidate set grew
**49 → 51**. QUICK **22/22 in one invocation** (smoke **337/337**, round-trip
byte-identical), `output_sweep` 356 files behaviour identical, `compile_check`
**260/0/2**.

**The method note is worth more than the numbers here.** Batch 2 touched 25 emit paths
and **not one of the 14 baseline entries is expression-anchored** — so it would have
landed with the gate reading the same number, indistinguishable from having done nothing.
Two fixtures were therefore written and registered BEFORE the fix, their broken
coordinates recorded (10:0, 11:0), and the gate was watched going **RED** on them first.
That is the `boundary_check` discipline — intent before observation — applied to a
gate that already existed. **When a change's witness cannot see it, extend the witness
first and watch it fail; a batch verified only by gates that were already green is
verified by nothing.**

Batch 3 (21 statement kinds carrying a line but **no column**) holds **all 14** remaining
entries; see BUG-288 for the per-entry breakdown. It is the remainder of the value, not
the leftovers.

**BOTH HEAVY BASELINES RE-LOCKED 2026-08-16, and this closes a gap this file had been
flagging against itself.** `full_sweep` **337 → 374** (+37 insertions, **zero deletions** —
purely additive, so nothing dropped out of the pass set and it cannot be hiding a
regression behind a re-record). `output_sweep` **322 → 356**. Both captured at JOBS=1 on an
idle machine after `doctor` reported the tree trustworthy, in the documented order
(full_sweep FIRST — output_sweep derives its candidates from it).

The 32-accumulated-passes note above is now DISCHARGED: those files could not turn the
gate red however badly they broke, and they can now. QUICK was **22/22 in one invocation**
(smoke 335/335, round-trip byte-identical, `diag-columns` 18 known / 0 NEW) and
`output_sweep --gate` re-run afterwards is **356 files behaviour identical**.

**A method note that cost a re-measurement.** The first `output_sweep --gate` was taken on
a `zebra.exe` built from a source tree carrying a deliberately-injected dead `const` — the
residue of a break-the-gate-on-purpose test whose FIRST attempt was vacuous (Zig does not
analyse unused top-level declarations, so the build passed and rebuilt the binary; the same
lazy-analysis trap that made the BUG-269 probe lie). `doctor` caught the binary↔source
mismatch. The dead const cannot affect codegen, but that is reasoning rather than
measurement, so the gate was re-run after a clean rebuild — same result. **When you break
something on purpose, check that the break actually took, and check what the failed attempt
REBUILT.**

**BUG-269 landed 2026-08-15** — `str` in an `extern` signature is REFUSED at the
declaration instead of emitting `[]const u8` and letting `zig` reject it as an illegal
C-ABI return type. Same family, same place and same shape as BUG-270's `int` check.
FULL tier **29/29 in one invocation**: smoke **335/335**, `compile_check` **260/0/2** in
both runtime shapes, `output_sweep` 322 identical, `full_sweep` 0 vs 337, `divergence`
**0 selfhost gaps**.

**Two method notes from it.** First, the probe lied: declaring `extern def f(): str` and
compiling reported that `zig` ACCEPTED it — for the broken form AND the working one —
because `zig` analyses an `extern fn` LAZILY and a declaration that is never CALLED never
reaches the calling-convention check. Adding a call reproduced the ticket verbatim.
Second, the fixture is a PAIR on purpose: the refusal names `^byte` as the fix, and a
second fixture pins that `^byte` really lowers to `*u8` and is accepted where the slice is
not. **A refusal whose suggested fix does not itself work is advice pointing nowhere, and
only a positive fixture catches that.**

**And BUG-270 was found already FIXED, nine days stale in the open ledger** (`e8c68e7`,
two passing fixtures). Second instance in two days after BUG-283, same cause: the
resolved-entry lint is heading-only, so an entry whose heading never gains a FIXED marker
is invisible to it. The cost is now concrete rather than theoretical — I picked BUG-270
to work on and discovered the compiler already refused the case.

**BUG-249 landed 2026-08-14** — `this`, `nil` and `result` carry real source positions, so
a diagnostic anchored on one no longer reports `0:0`. The selfhost now reports
`bug108_this_outside_class_test.zbr:6:13`, byte-identical to what the BOOTSTRAP reports
for that file, and the `smoke_tc_fail` expectation was tightened from the message alone to
the full coordinate. Verified at JOBS=1 because RAM was down to 3.5 GB: smoke **333/333**,
`compile_check` **259/0/2** in both runtime shapes, `output_sweep` 322 identical,
`full_sweep` 0 vs 337, `examples_sweep` 0 vs 14.

**`divergence` CONFIRMED CLEAN 2026-08-14, after a detour worth recording.** Final result:
**0 selfhost gaps**, 490/490 files scored, bootstrap gaps steady at **48** — unchanged from
before BUG-249, which is what a front-end-only change that adds no corpus file should do.

Getting there took four failed attempts and one wrong diagnosis. It hit the tier's 2700 s
ceiling at JOBS=1, and I then read `ps -W | grep -c zebra-language` returning 0 as "the
background runs are dying" — **that probe returns 0 whether or not a worker is running**,
verified afterwards with a positive control. One "dead" run had in fact been alive for
three hours and died only because I EDITED `divergence_check.sh` WHILE IT WAS EXECUTING
(bash re-reads a script as it runs). The 0-byte logs that made runs look dead have a duller
cause: divergence buffers its whole report to the end, so a healthy long run and a corpse
look identical from outside.

The eventual clean run was a single uninterrupted background pass. **Background runs were
never the problem.** Two lessons, both already rules here and both applied too late: prove
an instrument can SEE before reading its zero as an answer, and never edit a running
script.

`divergence_check.sh` gained `--results` / `--max` / `--classify` out of that detour, which
make the heaviest gate resumable — worth having on the 2026-08-11 receipt alone (two
harness kills, every heavy witness lost), independent of the wrong reason I first gave.

**BUG-282 / BUG-284 / BUG-285 / BUG-286 / BUG-287 landed 2026-08-14** — five bugs, four
commits. FULL tier at JOBS=2 for the last of them: every gate PASS except `output_sweep`,
which is the story below; re-run afterwards with its fix, **322 files behaviour
identical**. `compile_check` **259/0/2** in both runtime shapes, `full_sweep` 0 vs 337,
`divergence` **0 selfhost gaps**.

`divergence` bootstrap gaps **46 → 48**, both accounted for by name rather than waved
through: `bug286_namespace_ctor_test` (a keyword-named namespace, fixed selfhost-only) and
`bug287_sibling_method_shadow_test` (the bootstrap still resolves a bare sibling call to
the same-named class — the same `genCall` ordering, not fixed there). `bug284`'s fixture
is a negative test that fails in BOTH, so it lands as agree-fail rather than a gap.

**BUG-284 / BUG-285 / BUG-287 landed 2026-08-14.** FULL tier at `JOBS=3`: **28/29**, the
one failure being `output_sweep`.

It reported `bug120_sys_readline_test` as having "produced NO record — they stopped being
measured", which the gate correctly calls *worse than failing*.

**FIRST DIAGNOSIS WAS WRONG, AND THE CORRECTION IS THE USEFUL PART.** It looked like
load: the program ran correctly on its own, `--show --only` produced the right record,
`--gate --only` failed again *while divergence was still running*, and idle passed. That
is a clean-looking contention story and this file briefly said "do not run at JOBS=3".
**Then it failed again at JOBS=2**, on a tier where an earlier JOBS=2 run had passed —
so the pattern was intermittent, not tiered, and the tidy explanation was wrong.

**THE REAL CAUSE: the sweep inherited the RUNNER's stdin.** A fixture that READS stdin
therefore behaved differently depending on what the harness handed it — closed gives an
instant EOF, an open handle blocks until the timeout. `run_one` now redirects
`</dev/null`, so a stdin-reading program is deterministic. Note the retry could never
have helped: **retrying a blocking read blocks twice**, and the retry exists for slow
programs, which is a different failure. The fix had to be at the input, not the
observation.

The general lesson, and it is one this repo has written down in other words: a first
explanation that fits every observation so far is still a hypothesis. This one predicted
"JOBS=2 is safe" and that prediction failed on the next run. **A diagnosis that has not
made a prediction has not been tested.**

**U4a's TAIL CLOSED 2026-08-13 — `error` and `try` are ordinary identifiers.** FULL tier
**29/29 in one invocation** again: smoke, round-trip byte-identical, `compile_check`
**257/0/2** in both runtime shapes (the +1 is the new fixture), `output_sweep` 322
identical, `full_sweep` 0 vs 337, `divergence` 0 selfhost gaps. `reserved-words` is now
**81 keywords, 1 baselined** — down from 83/3; only `implies` remains, kept on language
grounds.

**Neither word can be added to `keyword_ident_check`'s word list, and that is a property
of the gate rather than an oversight.** Its rule is "a keyword appearing BARE outside a
string literal is an unescaped identifier", which is sound for `align`/`opaque`/`packed`
because codegen never emits those itself. `error` and `try` are words the compiler emits
legitimately as ZIG keywords — `return error.ZebraError;`, `try f()` — and one generated
compiler module carries **56 bare `try` and 17 bare `error`**. Adding them would fire on
nearly every program that can raise. They are covered instead by
`test/bug280_freed_words_test.zbr`, a `smoke_run` fixture that names things with both
words in eleven positions and asserts the printed values. **The general rule: a word
codegen itself emits cannot be checked by absence.**

**FULL tier 2026-08-13: 29/29 PASS — and for the first time, IN ONE INVOCATION.** The
two previous sweeps were assembled from separate runs, which this file records as weaker
evidence because nothing proves the tree was the same throughout. This one was
`JOBS=2 bash tools/gates.sh --full`, start to finish, on the tree that was committed.

| gate | result |
|---|---|
| QUICK (21) | all PASS — smoke **329/329**, round-trip byte-identical, `zig-keywords` 46/46 |
| `compile_check` | 256 passed, 0 FAILED, 2 skipped |
| `compile_check-inline` | 256 / 0 — identical to the default shape |
| `output_sweep` | 322 files, behaviour identical |
| `full_sweep` | 0 regressions vs 337; `examples_sweep` 0 vs 14 |
| `divergence` | **0 selfhost gaps**; bootstrap gaps steady at **46** |
| `release-mode` / `contract-mode` | clean / 13/13 |

Bootstrap gaps did NOT move for E, and that is worth reading rather than skipping: the
only file carrying an E shape is `bug280_keyword_idents`, which was *already* a bootstrap
gap from B. A family landing selfhost-only adds a gap the first time and none after.

**BUG-281 E landed 2026-08-13** — a keyword-named METHOD is now escaped in the selfhost,
closing the sixth of seven families. Only G remains and it is bootstrap-only (the
selfhost is immune for free via `_zbr_fn_`), so it retires with the bootstrap.
`keyword-ident` watched red on the new shapes then green; the fixture RUNS and prints the
right values (11 / 42 / 111), which is the half that matters — an escaping bug that
swapped two methods would still compile. The regen control: a full rebuild moved
**only `CodeGen.zig`**, so no non-keyword method name anywhere in the compiler's own
25k lines was touched.

**Both B and E are SELFHOST-ONLY, deliberately.** E's bootstrap half is cheap and was
still declined: the bootstrap is the REGEN AUTHORITY, and
`test/bug280_keyword_idents.zbr` can no longer gate it (the file contains a keyword-named
class since B). An ungated change to the regen authority, for a retiring compiler, in a
family already half-broken there, is a poor trade. See BUG-281 for what it costs.

**BUG-281 B landed 2026-08-13** — a Zebra type now emits as `_zbr_ty_<name>` in the
selfhost. QUICK **20/20 in one invocation** (smoke **329/329**, round-trip byte-identical,
`keyword-ident` 6/6, registration 465), with one caveat recorded below. Heavy witnesses,
all run against the final tree in one scripted sequence: `compile_check` **256/0/2**,
`full_sweep` 0 regressions vs 337, `examples_sweep` 0 vs 14, `output_sweep` **322
identical**, `divergence` **0 selfhost gaps**. `compile_check --no-runtime-module` (the
INLINE runtime shape, which nothing else watches) is **256/0/2 — identical to the
default**, which matters here because the change touched ~40 emit sites.

`divergence` bootstrap gaps **45 → 46**. The +1 is `bug280_keyword_idents` and nothing
else — the fixture gained a keyword-named class and struct, which the bootstrap cannot
emit because B was landed **selfhost-only** (Sean's call; the bootstrap is being retired
and the standing rule only requires it to COMPILE the selfhost source, which it does since
no `.zbr` class was renamed). Selfhost-leads, informational, expected.

**The QUICK caveat, and it is an instrument note rather than a result.** `check-mode`
failed its TIMING leg at `-c 4723ms vs --check-full 7773ms`. Re-run alone on the same
binary minutes later: **59ms vs 2195ms, "fast path intact"**. The gate was measuring
machine contention — the whole gate took 48s in the tier run and 5s alone. Every other
leg of it passed both times. Treat a timing-only failure here as a load reading until it
reproduces on a quiet machine; the deterministic legs are the ones that mean something.

**A coverage fact worth knowing before trusting that `output_sweep` line.** It reported
322 files **identical** even though `test/bug280_keyword_idents.zbr` gained four `print`
statements — which looks wrong and is not. That file is in **neither** heavy baseline
(`full_sweep_baseline.txt`'s 337, `output_baseline.txt`'s 322), so no re-baseline was
needed and none was done. It is one of the ~32 accumulated new passes this file already
flags as unlocked-in. Its real coverage is `smoke_run` (runs it, greps `bug280: OK`) plus
`keyword_ident_check`, which emits it, **builds** it, and fails on either. That is
adequate — but it means the heavy sweeps say nothing about this fixture, and a future
session reading "322 identical" should not infer they do.

**BUG-283 landed 2026-08-12** (`zig"${Type}"`): QUICK **20/20** in one invocation —
smoke **329/329**, round-trip byte-identical, registration 465. Heavy witnesses run
individually: `output_sweep` 322 identical, `compile_check` 256/0, `full_sweep` 0
regressions vs 337, `divergence` **0 selfhost gaps**.

`divergence` bootstrap gaps **44 → 45**, and the +1 is accounted for rather than waved
through: the new `test/bug283_zig_lit_typeref_test.zbr` uses a feature the bootstrap does
not have, verified directly — `zebra-bootstrap --emit-zig` passes `${...}` through
verbatim (4 occurrences). The three MIGRATED literals added none, because
`features`/`greet`/`with_test` were already gaps. Selfhost-leads, informational, expected.

**A method note from this landing: do not edit docs while a gate tier is running.** The
QUICK run above reported `doc-lint` clean, and re-running it against the final tree
reported **1** — the two new corpus files moved the tracked count 463 → 465 and this
file's pinned counter went stale *after* the gate had read it. The gate was not wrong; it
measured a tree that no longer existed. Re-run the cheap static gates against the state
you actually commit.

**Swept 2026-08-12 after BUG-281 closed four families in BOTH compilers** — all
28 green, again assembled rather than observed in one invocation. QUICK 20/20 in a single
run (smoke 327/327, round-trip byte-identical); `output_sweep` 322 identical; `full_sweep`
0 regressions vs 337; `examples_sweep` 0 vs 14; `divergence` **0 selfhost gaps** with
bootstrap gaps steady at 44; `compile_check` 255/0 in both runtime shapes;
`contract-mode` 13/13; `release-mode` clean.

**`compile_check --bootstrap` is 219 passed / 19 FAILED / 20 skipped (2026-08-13), and
that is its NORMAL state — recorded here because it never has been.** The tool is manual,
so its number has no baseline anywhere, and a future session seeing 19 red has nothing to
compare against. The 19 break down as: **16 known bootstrap gaps** (the same files
`divergence` lists as *selfhost leads* — the bootstrap genuinely cannot compile them),
and **3 cross-module tests** (`crossmod_modvar_test`, `bug168_crossmod_prim_return_test`,
`bug235_exposing_test`) that fail with `unable to load '<dep>.zig': FileNotFound` because
`--emit-zig` writes ONE file and never emits the dependency. That third group is
`DEPMISS`, not breakage — the same distinction `examples_sweep` draws, and a gate that
libels a working file is one people learn to disbelieve. **If this number moves, check
which group moved before assuming a regression.**

Movement since it was first recorded (220/17/20 on 2026-08-11), accounted for in full
rather than re-recorded — the arithmetic is the check:

| | | |
|---|---|---|
| `bug283_zig_lit_typeref_test` | new corpus file, bootstrap has no `${...}` | 17 → 18, total 257 → 258 |
| `bug280_keyword_idents` | gained a keyword-named class; BUG-281 B is selfhost-only | 18 → 19, and **220 → 219** — it moved OUT of the pass set |

Both are selfhost-leads and both are in `divergence`'s bootstrap-gap list, which is the
cross-check: 46 there, 16 here, and the difference is `examples/` plus files this tool
skips. A move that does NOT reconcile against that list is the one to worry about.

**FULL tier swept 2026-08-11 — 28/28 PASS, but ASSEMBLED, not observed in one run.**
`gates.sh --full` was killed twice by the harness before reaching the heavy witnesses
(once at gate 23, once during `smoke`) with no contention to explain it — no processes
from this tree, 6 GB free, 0% CPU. So the 21 QUICK-plus-`release-mode` lines come from
the first partial run and the remaining 7 were each run individually. Every gate was
seen green; **no single invocation was**. Recorded that way deliberately: a tier result
stitched from separate runs is weaker evidence than one clean pass, because nothing
proves the tree was in the same state throughout.

| gate | result |
|---|---|
| `output_sweep --gate` | 322 files, behaviour identical to baseline (15 nondeterministic) |
| `compile_check` | 255 passed, 0 FAILED, 2 skipped |
| `compile_check-inline` | 255 passed, 0 FAILED — identical to the default shape |
| `full_sweep --gate` | 0 regressions vs baseline (337) |
| `examples_sweep` | 0 regressions vs baseline (14) |
| `divergence --gate` | **0 selfhost gaps**; 44 bootstrap gaps (informational) |
| `contract-mode` | 13/13 |
| QUICK (separate run, one invocation) | **20/20** — smoke 327/327, round-trip byte-identical |

Two numbers worth recording, neither of which this file previously carried.
`divergence` reports **44 bootstrap gaps** — cases where the selfhost LEADS. Still
informational, still "don't chase", but the last written-down figures are **14** in
`docs/divergence_audit.md` and 23 in a session memory, so it has roughly tripled
unremarked and no document here tracked it. And `full_sweep` reports
**369 PASS against a baseline of 337**, i.e. **32 accumulated new passes** nobody has
locked in. A baseline defines the pass set, so those 32 files cannot make the gate red
however broken they become. Re-baselining is a real coverage win and is **not** done —
`full_sweep --update-baseline` FIRST, then `output_sweep --update-baseline`.

**Previous sweep 2026-08-04, all clean** — run overnight with the machine otherwise idle,
so no gate measured contention as a failure. Sequential, not parallel.

| path | result |
|---|---|
| `bash tools/gates.sh --full` | **21/21 PASS** — smoke 293/293, compile_check 237/0, output_sweep 322 identical, full_sweep 0 regressions vs 337, examples_sweep 0 vs 14, divergence 0 selfhost gaps |
| `python fuzz/gramgen.py --gate` | PASS — 960 derived programs, 0 hangs, 0 crashes |
| `bash tools/node_addon_test.sh` | PASS |
| `bash tools/gui_scaffold_check.sh` | PASS — scaffold globals assigned, app got PAST the BUG-229 crash site and refused a non-tty cleanly (rc=3) |
| `zig build test` | **RED, and was already red — BUG-279.** Added to this table 2026-08-09 because it was in NEITHER a tier nor this list, which is the one state this table exists to make impossible. Three unrelated pre-existing failures: an AstPrinter switch missing `TypeRef.fn_type`, a CodeGen test calling `generate()` with 15 of 16 arguments, and a preamble `page_allocator` count drift (70 vs 72). Its selfhost-smoke leg passes 326/326. |

The tier grew 19 → 21 that night: `doc-example` (QUICK) and `release-mode` (FULL).

**Tier update 2026-08-07 — now 26, and `gates.sh --full` was 26/26** at JOBS=1 (smoke 320/320, output_sweep 322 identical, full_sweep 0 regressions, divergence 0 selfhost gaps). `bug-numbers` joined that day. The output_sweep line carried the weight: BUG-273 rewrote what every `assert` in 456 corpus files emits, and only a behaviour witness over the whole corpus could have caught a regression there. Previously — now 25, and `gates.sh --full` was 25/25 at JOBS=1 (smoke 317/317, compile_check 247/0 in both runtime shapes, output_sweep 322 identical, full_sweep 0 regressions vs 337, divergence 0 selfhost gaps). `expr-walker` joined that afternoon. Earlier the same day it was 24/24 (smoke 314/314,
compile_check 244/0 in both runtime shapes, output_sweep 322 identical, full_sweep 0
regressions vs 337, examples_sweep 0 vs 14, divergence 0 selfhost gaps). `ffi-lib` was
added that day (QUICK); the other two new lines are `contract-mode` and
`compile_check-inline`, which existed before but post-date the 21-gate count above.
**The three excluded items were NOT re-run** — their last sweep is still 2026-08-04, so
the table below stands unchanged.

**Previous sweep 2026-08-02** — 18/18, before those two gates existed.

**What a fully green board here does NOT mean.** `full_sweep` passes against a baseline of
**422** <!-- doc-gen: 422 = wc -l < tools/full_sweep_baseline.txt | tr -d ' ' -->
while the tracked corpus is **536** <!-- doc-gen: 536 = bash tools/corpus_ls.sh test | wc -l | tr -d ' ' -->.
A baseline defines the pass set, so files outside it cannot make the gate red no matter how
broken they are. BUG-241 and BUG-242 were both found sitting in exactly that gap. Green
and unexamined are not in tension; see `docs/INSTRUMENT_PASS_PLAN.md` §2.

The baseline figure now carries its own `doc-gen` oracle, added 2026-08-16 after it sat
stale at 337 through a re-baseline to 374. The corpus number beside it had an oracle and
went red within the hour; this one had none and went quietly wrong — in the paragraph
whose whole subject is numbers that look fine and are not. **A count worth writing down
is a count worth deriving.**

The size of that gap is now **measured rather than estimated**, which it was not when this
paragraph was first written (it said "57 are in no known category" against a corpus of 421).
`registration_check` is the instrument: every tracked `test/*.zbr` must have its status
asserted by *something* — a smoke registration, the full_sweep pass baseline, or an entry in
`tools/registration_exempt.txt` **with a reason**. As of 2026-08-26 that leaves **15**
<!-- doc-gen: 15 = python tools/registration_check.py 2>/dev/null | grep -oE '[0-9]+ unasserted' | grep -oE '^[0-9]+' -->
unasserted, against 37 exempt-with-reason. Down from 57, and from 18 on 2026-08-26 when
reading full_sweep's newly-kept evidence named the last three. Shrink it, never grow it — and note
the number now carries an oracle, so this paragraph cannot quietly go stale the way the last
version did.

**Previous sweep 2026-07-29** — after runtime-module emission became the default, because
that change made GUI and node-addon take a *new* fallback branch that no gate exercises.

The GUI check is the one that mattered: it confirmed the fallback does what it claims
— the emitted `src/main.zig` is the INLINE shape (3,947 lines, **zero** `zebra_rt.zig`
imports) with the tui backend selected. A fallback that had silently emitted the split
shape would have produced a program importing a runtime its own scaffold never places,
and nothing in any gate tier would have caught it.

**Updated 2026-07-30 — the GUI gap is now partial, not total.** BUG-229 (tui apps
segfaulting because the selfhost emit never assigned `_tui_env`) was the **fourth** GUI
crash to sit under fully green gates. All four were at **startup**, and a startup crash is
not a rendering problem — it needs neither a human nor a terminal. So
`tools/gui_scaffold_check.sh` now covers that half:

| | covered by | |
|---|---|---|
| scaffold declares a global `= undefined` and never assigns it | `gui_scaffold_check` leg 1 (static) | **gated** |
| app dies with a memory fault at startup | `gui_scaffold_check` leg 2 (runtime) | best-effort |
| rendering, input, layout, resize, colours | **a human running it** | still uncovered |

**Its leg 2 now fails on a panic AFTER startup, and runs twice (2026-09-09).** BUG-358 —
`g.panel(label, closure)` in an MVU `view()` died on the 65th frame, "closure-via-sig pool
exhausted" — produced rc=1 with a panic banner, which the classifier filed as
INCONCLUSIVE rather than as a crash, so the only automated GUI coverage could not have
gone red on it. A post-startup `thread N panic:` is now a FAILURE (the documented healthy
refusal is matched first and still passes). And the default example, `counter`, has no
closure-taking builder, so a second registration, `gui-scaffold-panel`, runs the same
tool on `examples/panel_smoke.zbr` — headless it renders far more than 64 frames inside
the 15 s window. Red-checked by mutating the BUG-358 exemption back out.

Run it as `bash tools/gui_scaffold_check.sh [examples/foo.zbr]`. It builds a real tui app,
so it is minutes, not seconds — treat it like `compile_check`: per-session and
pre-release, not in the QUICK tier. The tool prints its own uncovered list, so the
remaining gap cannot quietly be forgotten.

Sean confirmed BUG-229's fix by running `--gui-backend=tui examples/counter.zbr` and
clicking through it — which remains the only verification that can close a GUI bug.

## Self-hosting

The self-hosting effort lives in `selfhost/`. Rule of thumb for this port:
**the Zebra compiler in `selfhost/` must be functionally equivalent to the
Zig compiler in `src/`.** When closing a gap, do not drop features in the
selfhost port — that creates a regression in the selfhosted side. See
`SELFHOST_JOURNAL.md` for how each phase was done.

## Language quick reference

`QUICKSTART.md` is the authoritative syntax/semantics cheat-sheet for the
Zebra language itself. Skim sections 1–14 before authoring any `.zbr` code.
Key idioms worth remembering up front:

- `var` is always mutable; the compiler emits `const` vs `var` in Zig based
  on mutation analysis.
- `^T` on a field type is heap-indirection (`*T` in Zig). Auto-boxed on
  assignment; transparent when bound inside a `branch` arm.
- `this except field = value, ...` is the immutable-update idiom for structs.
- `throws` methods return `anyerror!T` in Zig; same-file throws-to-throws calls
  auto-propagate, cross-module/local-variable calls need explicit `expr?`.
- Method chaining on struct temporaries (`f().method()`) is auto-materialized
  by the compiler in var-init, return, and assignment positions. Expression-
  position chains (call args, compound expressions) still need a manual temp.

## Common workflows

**Adding a feature to the compiler:**
1. Add the Zig implementation in the appropriate `src/` file.
2. Extend the test suite in `test/`.
3. Update `selfhost/` to keep parity, or file a gap note in `SELFHOST_JOURNAL.md`.
4. Update `QUICKSTART.md` if user-visible syntax or semantics change.

**Self-hosting (Phase 22 complete):**
- `zig build` now produces `zig-out/bin/zebra.exe` from `selfhost/main.zig` (primary).
- `zig-out/bin/zebra-bootstrap.exe` is the Zig-implemented compiler, used by
  `tools/bootstrap_check.sh` to regenerate `selfhost/*.zig` from `*.zbr` sources.
- Keep intermediate Zig files using `zebra --emit-zig` or `--output-dir DIR`.
- Escape hatch: `zebra --zig-backend file.zbr` delegates to `zebra-bootstrap.exe`.

## Notes

- **State handoff 2026-09-08 (read before touching GUI/debug code):** the IDE work
  (`C:\Projects\zebra-ide`) landed P0–P4 across this repo, zig-libui-ng (unpushed:
  OnNotify e1b68d3, OnKey 8c205fd) and zebra-ide; `zebra debug <file>` is native
  (`dbgRunSession`, selfhost/main.zbr); new sys builtins
  `spawnPipedIn/exitCode/readStdinAvailable/stdinClosed/writeStdout` and `--` program-arg
  passthrough; `zebra lsp` resolves the `use` graph from disk (gate `lsp-workspace`); the
  libui section hides widgets the view stops emitting and has `editor.hotkey/takeKey`.
  The libui pin in `luiBuildZon` still points at 93c7f54b, which LACKS OnNotify/OnKey;
  that code is `@hasDecl`-guarded so the build passes — it is waiting on the pin bump
  (`tools/bump_libui_pin.sh` after a push), not on code. To try the unpushed shim on
  Windows WITHOUT the pin: `set ZEBRA_LIBUI_PATH=C:\Projects\zig-libui-ng` before running
  a GUI program (luiBuildZon then emits `.path` instead of the pinned url). Nothing has yet
  run on Windows with a window open. Full status, owed list, open worklist:
  `C:\Projects\zebra-ide\PLAN.md` (last section); wiki `concept_zebra-lightweight-ide` §7b.
  (This bullet was lost once already — 2026-09-08, a bundle overwrote a device-side edit —
  so it now lives in the copy that gets shipped.)
- Platform: Windows is the primary dev environment; bash paths via Git Bash.
- Binaries and build caches (`*.exe`, `*.pdb`, `.zig-cache/`, `zig-out/`) are
  gitignored — do not commit them.
- The `archive/pre-zebra-split` tag in the old cobra-language repo records
  the state at split time.

## Line endings — CRLF hazard for `.zbr` files

The Zebra tokenizer requires **LF-only** (`\n`) line endings. A `\r` character is
treated as an unexpected character and causes a tokenizer crash with the message
`internal compiler error: error.UnexpectedCharacter` — no source location is
reported, making the failure look unrelated.

**How this bites you on Windows:** Python's `open(..., 'w')` writes CRLF by
default. Any script that reads and rewrites a `.zbr` file must pass
`newline='\n'` explicitly:

```python
# CORRECT — LF only
with open('file.zbr', 'w', encoding='utf-8', newline='\n') as f:
    f.write(content)

# WRONG on Windows — writes CRLF, crashes the tokenizer
with open('file.zbr', 'w', encoding='utf-8') as f:
    f.write(content)
```

Git `core.autocrlf` can mask this on checkout, but the repo `.gitattributes`
normalises `.zbr` to LF. If you suspect CRLF: `file selfhost/foo.zbr` will
report `CRLF line terminators` vs `ASCII text`.
