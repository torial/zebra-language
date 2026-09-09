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
- **(b) two bare-constructor branches — ✅ INVESTIGATED 2026-08-03. The hypothesis below
  was WRONG; read this before acting on it.** `11166→11184` and `6075`.

  > The original reading — *"these are **redundant**, not untested … adding tests here
  > would pin duplicated behaviour"* — does not survive contact with the code.
  > `genLocalVar` handles the **annotated** form early: `var m: HashMap(K,V) = HashMap()`
  > goes through `isGenericStdlibCtor` → `genGenericCtorExpr(ie, n.type_)` at
  > `CodeGen.zbr:5764` and **returns before 11184 is ever reached**. So 11184 is not a
  > duplicate path — it is the **complementary** one, firing only for an *unannotated*
  > bare `HashMap()` in expression position, where it deliberately emits
  > `std.StringHashMap(anytype)` so that Zig's error points at the missing annotation.
  >
  > **It is a diagnostic, and that is why the mutation survived**: disabling it makes the
  > call fall through to a different path that *also* fails to compile, and no gate
  > asserts *which* error a bad program produces. The twelve corpus files that "use bare
  > `HashMap()`" all carry annotations, so none of them reach this branch at all.
  >
  > **Do NOT delete it** — that was the original plan's suggestion and it would remove a
  > deliberate error message. The real resolution is either a negative fixture asserting
  > the *diagnostic text*, or accepting an error-message path as legitimately ungated.
  > **No `--site` receipt applies here; the resolution is not a test.** That is a
  > decision, not an omission.

- **(d) two AstBuilder-only predicates — ✅ INVESTIGATED 2026-08-03. `330` is provably
  DEAD**, not "might be".

  > `CodeGen.zbr:323` already returns true for anything ending `_expr`/`_stmt`:
  > ```
  > if nm.endsWith("_expr") or nm.endsWith("_stmt")
  >     return true
  > ```
  > Every name guarded at **328** (`this_expr`/`callee_expr`/`base_expr`), **330**
  > (`left_expr`/`right_expr`/`operand_expr`), **332** (`target_expr`/`value_expr`/
  > `obj_expr`) and **334** (`idx_expr`/`subject_expr`/`iter_expr`) ends in `_expr`, so
  > none of those four blocks is reachable. Mutating 330 to always-false changed nothing
  > because control never arrives there. Line 326 keeps live names (`rval`, `msg`, `cond`)
  > and 336 (`initval`, `type_ref`) is live — neither suffix matches.
  >
  > **Resolution is deletion of 328–335, not a test**, which removes the survivor by
  > removing the site. Deliberately NOT done on 2026-08-03: the tree was at a clean,
  > gated, pushed state and deleting four unreachable `if`s would have re-entered a
  > rebuild + FULL-gate cycle for no behavioural gain. Do it in a session already
  > touching `CodeGen.zbr`, and prove it with the experiment below rather than by reading.
  >
  > **The falsifiable check, if you want one:** emit `selfhost/AstBuilder.zbr` before and
  > after the deletion — byte-identical output proves the lines were dead. The control
  > that makes that meaningful is disabling **323** instead, which MUST change the output;
  > without it, "identical" could just mean the emit command was broken.
  >
  > `341` (`buildExpr`/`buildStmt`) is a different case and is **not** shown dead —
  > mutating it makes the predicate over-fire rather than never-fire.
- **(a) three remaining stdlib emitters** — covered by §1b below.

**Each closes with a receipt, not an assumption:** `python tools/mutation_check.py --site
selfhost/CodeGen.zbr:<line>` must flip the verdict from `SURVIVED` to `DETECTED`. Line
numbers drift; on a miss the tool now prints the neighbourhood so you can re-aim.

### 1b. Four stdlib namespaces *(~half a day, two are blocked)*

`tools/stdlib_run_coverage.py` is the meter — **26/30 → 28/30 as of 2026-08-03**.

> **The meter is an UPPER BOUND and must not be quoted as a coverage figure.** It counts a
> namespace as covered when some fixture *mentions* it, not when anything exercises the
> emitter's branches — the tool prints this disclaimer itself, and the real number is
> worse. It is a checklist of which namespaces have *any* run fixture, nothing more. The
> same caution the mutation percentages carry (§B1: *"not a coverage figure and should not
> be quoted as one"*) applies here verbatim.
>
> For the four closed below, the honest evidence is not the meter but the fixtures: each is
> a registration asserting **printed output**, `csv` round-trips a comma-bearing field
> through RFC 4180 quoting, and `ws` completes a real client↔server echo. Those are
> behaviour claims. "30/30" is not.
>
> **A NAMED INSTANCE, so the caveat is not abstract (found 2026-08-03).** The meter credits
> **`Tcp`** and **`Http`** with run coverage on the strength of fixtures whose stdlib call
> sits in a function **nothing ever calls**:
> ```
> def startServer()
>     Tcp.serve(19876, handleConn)   # the corpus's only Tcp.serve
> def main()
>     print("tcp_serve_test OK")     # startServer() is never called
> ```
> Both are registered with `smoke_run`, both pass, and neither ever binds a socket.
> `http_serve_test.zbr` is the same shape and says so in its own comment ("exercises
> Http.serve codegen path without starting a server"). **The fixtures are honest; the meter
> is not** — it cannot tell a compile smoke from a run fixture. So the real count of
> namespaces with genuine runtime exercise is **at most 28, not 30**.
>
> Scanned with `scratchpad/dead_fixture_fns.py` (a `def` whose name appears nowhere else).
> It initially also flagged `random_instance_test`'s five `test_*` functions — a **false
> positive**: `smoke_test` invokes `zebra test`, which discovers them by name convention.
> Recorded because the correction is the useful part: "uncalled" depends on which runner
> you assume, and the scan assumed one.

- **`Csv`** — ✅ **CLOSED 2026-08-03** (BUG-242). The ticket said only the writer was
  missing; in fact the whole namespace was dead — seven faults, including one that emitted
  *valid Zig printing a byte array*. Registered via `test/csv_test.zbr` plus the
  `bug242_csv_roundtrip_test` fixture.
- **`Progress`** — ✅ **CLOSED 2026-08-03** (BUG-241). `std.Progress.start` gained an `Io`
  parameter in Zig 0.16. Registered via `test/progress_test.zbr` plus
  `bug241_progress_io_test`. The expectation asserts the deterministic **print**, not bar
  rendering — `std.Progress` goes quiet on a non-tty, so a bar-shaped expectation could
  never match under the runner.
- **`Ws`** — ✅ **CLOSED 2026-08-03**. `test/ws_echo_test.zbr` does a real client↔server
  round trip: server on a `sys.go` thread, **bounded connect retry** rather than a
  `sys.sleep` timing assumption, payload echoed and compared. Verified 6/6 consecutive
  before registration, and both assertions shown to fire independently — a wrong payload
  and an unreachable port produce **different** messages, so a port collision cannot read
  as a broken echo. Process exit with the server thread still blocked in `accept` was
  **verified, not assumed**.
- **`Shell`** — ✅ **CLOSED 2026-08-03**. `test/shell_test.zbr` uses `echo`, the only
  command that is a builtin of *both* `cmd` and `sh`, so it assumes nothing about the host.
  It runs `echo alpha && echo beta` and asserts both outputs appear **and that `&&` does
  not** — which discriminates a real shell from an implementation that merely echoes its
  argument back. Comparison is `contains`, never equality, since `cmd` emits CRLF and `sh`
  LF. Closing it required fixing **BUG-245**: the emitter still called
  `std.process.Child.run`, removed in Zig 0.16.

**The prerequisite neither item could be done without.** `smoke_run` has **no timeout**, so
a fixture that fails to terminate hangs the entire tier rather than failing it — and both
of these spawn external work. `smoke_run_bounded` was added first, and **proved able to go
red** against a deliberate `while true` probe before either fixture was written. It reports
a hang as an explicit `TIMEOUT` verdict, distinct from a wrong answer, because otherwise a
hang prints "expected '…' in output" and sends the next session hunting a codegen bug that
does not exist.

**The model that could not be copied.** `tcp_serve_test.zbr` looks like the precedent for a
server fixture and is not one — its `main` only prints (see the meter note above). There
was no working example of a bounded server test in this repo before `ws_echo_test`.

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
