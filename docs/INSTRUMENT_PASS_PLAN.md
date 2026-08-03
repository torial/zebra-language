<!-- doc-status: live -->
# Passing all the instruments — the plan

*Written 2026-08-01. The concrete work to get from "the gates are green" to "the gates
have stopped finding things", which are different claims. Pairs with
[`testing_strategy.md`](testing_strategy.md) (why), [`TOOLING_COMMISSION.md`](TOOLING_COMMISSION.md)
(what the instruments are) and [`1.0_FREEZE_CHECKLIST.md`](1.0_FREEZE_CHECKLIST.md) (the
release gate).*

---

## 0. The bar, and the two ways to fake it

**"Passing all the instruments" is achievable by weakening them, and that must not be how
this is done.** Every golden-baseline gate here — `full_sweep`, `output_sweep`,
`examples_sweep`, `bug_fixture_check` — goes green if you re-baseline. So state the real
target:

> **Green is not the goal. The goal is that a NEWLY BUILT instrument finds nothing new.**

Two moves are forbidden for the duration of this work, and both are things a reasonable
person does without noticing:

1. **Re-baselining to clear a red.** A baseline is re-recorded when the pass set
   *intentionally grows*, never to make a failure go away. If a gate goes red, the diff
   gets read.
2. **Weakening an expected string.** If a `smoke_run` assertion is inconvenient, the fix
   is the code or a better assertion — not a shorter substring. `test/terminal_test.zbr`
   asserts `"hello world"` specifically because that substring is what catches a
   write/writeln swap; a "simplification" to `"OK"` would silently retire a real check.

**Why this framing:** seven instruments built since 2026-06-25 each found real defects
within hours of first running (`compile_check`, `output_sweep`, examples sweep,
`boundary_check`, `gui_scaffold_check`, mutation testing, `stdlib_run_coverage`). That is
the signature of unmeasured surface. The freeze question is answered when that stops
being true — not when the board is green.

---

## 1. Close what is already found

Everything here is specific and verifiable today. No investigation needed to start.

### 1a. Ten mutation survivors *(~1 day)*

Full inventory with `worktree → main` line numbers in
[`testing_strategy.md`](testing_strategy.md) §B1. Two are closed and `--site`-verified;
these ten are open.

- **(c) three semantic boundaries — a fixture each.** `12608→12626` (a call whose arity
  exactly matches a defaulted parameter list), `733` (`TypeRef.generic` renders
  `Name(, T, U)`), `7524` (value position of a string-keyed HashMap parameter).
- **(b) two bare-constructor branches — INVESTIGATE, do not test.** `11166→11184` and
  `6075`. Twelve corpus files use bare `HashMap()` and none broke when the branch was
  disabled, so something downstream already handles the shape. Find what, then delete the
  branch or document why both exist. **A test here would pin duplicated behaviour.**
- **(d) two AstBuilder-only predicates — check whether they are dead** before writing
  anything. `330`, `341`.
- **(a) three remaining stdlib emitters** — covered by §1b below.

**Each closes with a receipt, not an assumption:** `python tools/mutation_check.py --site
selfhost/CodeGen.zbr:<line>` must flip the verdict from `SURVIVED` to `DETECTED`. Line
numbers drift; on a miss the tool now prints the neighbourhood so you can re-aim.

### 1b. Four stdlib namespaces *(~half a day, two are blocked)*

`tools/stdlib_run_coverage.py` is the meter — currently **26/30**.

- **`Csv`** — blocked on **BUG-242** (`csv_test.zbr` references an undeclared `CsvWriter`).
  Fix, then registration is one line.
- **`Progress`** — blocked on **BUG-241** (`std.Progress.start` gained an `Io` parameter in
  Zig 0.16; the preamble still calls it with one argument). Fix, then one line.
- **`Ws`** — needs a **client+server fixture with a bounded wait**. `ws_smoke_test.zbr` is
  a server and does not terminate (verified: SIGTERM at 45 s), so it cannot be registered
  as-is.
- **`Shell`** — needs a **purpose-built test**. Its only user is `test/zebra_ide.zbr`, an
  IDE harness. Must not depend on which utilities the host happens to have.

---

## 2. The unexplained set — the highest-value item on this list

**CORRECTION 2026-08-02: it is 25, not 57.** The original figure came from `comm`-ing the
corpus against the pass baseline and subtracting only registered negatives — a crude
method that counted library files and documented cases as mysteries. `full_sweep` already
buckets every file, so the honest cut is its own classification cross-referenced against
what each file is registered with:

| bucket | meaning | count | status |
|---|---|---|---|
| `EMITFAIL` | the compiler refused to emit | **27** | ✅ registered negative tests — asserted |
| `NOMAIN` | no `main()`; a library/fixture | **27** | ✅ legitimately not runnable |
| `DEPMISS` | search-path dep `--output-dir` skipped | **2** | ✅ documented as not-broken |
| **`CFAIL`** | **emitted Zig does not compile** | **21** | 🔴 3 registered, **18 unregistered** |
| **`EMITFAIL`** | **refuses to emit, nobody asserts it** | **4** | ⚠ unexplained |

**25 files, of which 18 CFAIL carry no registration at all** — and two of those were
already filed as BUG-241/242 the day before, which is what makes the rest worth checking.

Reproduce (results come from `full_sweep`'s own run, so no re-derivation):

```bash
bash tools/full_sweep.sh          # leaves $TMPDIR/zebra_full_sweep/results.txt
grep -v '^PASS ' $TMPDIR/zebra_full_sweep/results.txt
```

**`CFAIL` does not mean broken.** The sweep uses a multi-module `--output-dir` shape, and
a program can run perfectly via `zebra file.zbr` while failing that path — `DEPMISS` is
the documented case of exactly this. So each file resolves to one of:

| finding | action |
|---|---|
| RUNS via `zebra file.zbr` | the sweep's shape is the problem, not the file — register it (`smoke_run`) |
| genuinely BROKEN | file a bug; it has never worked and nobody knew |
| library / fixture | mis-bucketed; exempt it explicitly |

**Why this is the priority.** BUG-241 and BUG-242 were both in exactly this state —
uncompilable for months, invisible because a baseline-driven sweep cannot distinguish
*"never worked"* from *"intentionally negative"*. Sixteen more unregistered `CFAIL` files
sit in that blind spot, and the first two anyone looked at were both broken.

**Triage each into one of three buckets**, and record the bucket so the set cannot re-form:

| bucket | action |
|---|---|
| genuinely negative | register it (`smoke_tc_fail` / `smoke_warn`) so its failure is *asserted* |
| broken | file a bug, fix or quarantine explicitly |
| should pass | fix, then re-baseline `full_sweep` (an intentional growth — allowed) |

**Then close the class**: nothing should be able to sit in `test/` unregistered and
unexplained again. `bug_fixture_check.py` already enforces this shape for *bug* fixtures
("counts a fixture as real only if something actually RUNS it"); the same idea needs to
cover ordinary feature tests. That check is the durable outcome of this item — the triage
is one-time, the gate is not.

*Sizing: under a day now that the number is 25 rather than 57, and most of the work is
running each file and reading one line of output.*

---

## 3. Run the instruments that have not run — ✅ DONE 2026-08-02, ALL GREEN

Ran sequentially overnight. **FULL tier 18/18**, `gramgen` 0 hangs / 0 crashes,
`node_addon_test` PASS, `gui_scaffold_check` PASS (startup only). Recorded in CLAUDE.md
with the date, which is the only thing that makes the "deliberately excluded" note honest.

**The plan does not change — and the reason is the interesting part.** A fully green
FULL tier is *entirely compatible* with §2's 57 unexplained files, because `full_sweep`
gates against a **baseline of 337** while the corpus is **421**. Files outside a baseline
cannot make a gate red however broken they are. So the green board raises no doubt about
§2; it is simply silent on it. Proceed to §2 as ordered.

<details><summary>original §3 checklist</summary>

Cheap, and it is the part most likely to be skipped.

- **FULL tier** — `bash tools/gates.sh --full` (~50 min, RAM-bound). Only QUICK has run
  during the tooling work. FULL adds `compile_check`, `compile_check-inline`,
  `output_sweep`, `full_sweep`, `examples_sweep`, `divergence`.
- **`bash tools/gate_selfcheck.sh`** end-to-end — proves each gate can still fail. It
  gained three legs recently and the whole run has not been checked since.
- **The deliberately-excluded set, last swept 2026-07-29** (recorded in CLAUDE.md, and the
  record is only worth anything if the date gets updated):
  - `python fuzz/gramgen.py --gate` — 960 derived programs, hangs and crashes
  - `bash tools/node_addon_test.sh`
  - `bash tools/gui_scaffold_check.sh` — startup only; **rendering still needs a human**
- **`bash tools/tidy.sh`** — clears scratch; confirms no untracked file is influencing a
  gate (it no longer can, but the report is worth reading).

</details>

---

## 4. Make the measurements honest

Upgrading the instruments, so that §5's exit criteria mean something. This is the part
that decides whether the freeze rests on evidence or on absence of evidence.

- **Per-BRANCH stdlib coverage.** Today's 26/30 is per-*namespace* and is explicitly an
  upper bound — `genSqliteCall` has many branches and one `Sqlite.` mention. Extend
  `stdlib_run_coverage.py` to count `mname == "..."` branches per emitter and report how
  many are reached by any run-fixture. **Expect this number to be much worse than 26/30,
  and treat that as the tool working.**
- **A larger, targeted mutation run.** B1 v2, already queued in `NEXT_STEPS.md`: sample
  until *N live* mutants rather than N total, and bias site selection toward code the
  corpus executes. The figure to watch is the **survivor RATE per live mutant** (today:
  12 of 21), not the count. Cost is ~370 s/live mutant; 100 live is roughly an overnight
  run.
- **Extend A3 into untested language areas.** `boundary_check` found three day-one bugs on
  its first run from twelve probes; it is now 21. Its uncovered list is in
  [`boundary_triage.md`](boundary_triage.md). Intent-authored probes are the only
  instrument here that can find something that was *always* wrong.

---

## 5. Exit criteria — what would justify the freeze

Falsifiable, so the decision is not a matter of confidence:

1. **§2 is empty** — every corpus file is passing, registered-negative, or has a ticket.
   No file in an unknown state.
2. **A targeted mutation run shows a materially lower survivor rate** than today's 12/21,
   with every survivor triaged. Not zero — zero would be suspicious at this sample size.
3. **Per-branch stdlib coverage is measured and its gaps are decisions**, not discoveries.
4. **A round of new A3 probes finds nothing.** This is the strongest single signal
   available, because it is the only instrument that tests *intent* rather than recorded
   behaviour: if writing fresh probes from QUICKSTART stops producing bugs, the language
   surface has settled.
5. **FULL tier and the excluded set both green, with the sweep date recorded.**

**Criterion 4 is the one to weight.** The others confirm that known surface is watched;
only 4 speaks to surface nobody has thought about yet.

---

## Suggested order

| # | item | why first |
|---|---|---|
| 1 | §3 — run FULL + the excluded set | cheap, and may change everything below |
| 2 | §2 — triage the 57 | highest expected yield; two known-broken already found |
| 3 | §1b — BUG-241, BUG-242, then `Ws`/`Shell` | unblocks the coverage meter |
| 4 | §1a — the ten survivors | concrete, each verifiable |
| 5 | §4 — per-branch coverage, targeted mutation, A3 | makes §5 answerable |

§3 goes first for a reason: if FULL is red, the plan changes, and it would be
embarrassing to spend two days on §2 and then discover it. **Run the cheap wide check
before the expensive deep one.**
