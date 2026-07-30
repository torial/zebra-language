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
