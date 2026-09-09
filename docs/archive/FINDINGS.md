<!-- doc-status: live -->
# Zebra — what we already know

**Measurements and derived rules, recorded so nobody re-derives them.** This file
answers "what do we already know?" and nothing else: decisions live in
[PRINCIPLES.md](PRINCIPLES.md), work in the `NEXT_STEPS_*` files.

Extracted from NEXT_STEPS.md on 2026-08-29. Every entry here was filed under the
conversation that produced it rather than under what it was -- which is precisely
why they were hard to find, and the reason this file exists.

**A finding is not a task.** If something here implies work, the work belongs in a
`NEXT_STEPS_*` file with a pointer back. Keep the measurement here and the action
there, or the measurement rots when the action ships.

## BUG-313's COST: ~17%, and the FIRST measurement of it was wrong (2026-08-26)

**CORRECTED. The first figure published here was 91% and it was an artifact of one noisy
batch.** The honest number is **~17%**, and the correction is the more useful result,
because the method that produced the wrong number looked rigorous.

Measured IN-PROCESS (`tools/bench/index_bench.zbr`): best-of-25 timed rounds inside the program,
5 independent paired runs, `--release --single-threaded`.

| run | checked | unchecked | overhead |
|---|---|---|---|
| 1 | 241 | 200 | 20.5% |
| 2 | 248 | 217 | 14.3% |
| 3 | 264 | 222 | 18.9% |
| 4 | 238 | 209 | 13.9% |
| 5 | 236 | 204 | 15.7% |

**Checked is slower in 5 of 5 pairs, by 14-21%.** The consistent SIGN across independent
pairs is what makes this trustworthy, more than any single ratio.

**WHY THE FIRST MEASUREMENT LIED.** It timed the whole PROCESS and subtracted a
zero-work baseline. That looked careful -- interleaved, minimum-of-10, baseline subtracted --
and still produced 91%, because on an IDLE machine the MINIMUM over 15 rounds moves
517 / 555 / 560 ms for the same binary. Process-level noise alone is ~8%, and one unlucky
batch put the checked build at 784 ms where later runs put it at 503.

**A minimum is only as good as the number of samples it is drawn from, and process startup
adds noise that no amount of interleaving removes.** Timing inside the process removes
loader, first-touch and scheduler-entry costs from the sample entirely, and makes rounds
cheap enough to take a best-of-25 rather than a best-of-10.

**This is a WORST CASE and should be read as one.** The loop does almost nothing except
index; real code does more work per index and will see less. What it bounds is the ceiling,
and the ceiling is high enough to matter against a 30-50%-of-Zig target.

**Three instrument failures on the way to that number, all caught by arithmetic:**

1. **The first benchmark measured process startup.** 0 iterations cost 165 ms; 100
   iterations cost *less* (149 ms, pure noise); 400 cost 208 ms. Fixed overhead was ~10x the
   signal. An early "64% overhead" reading from that setup was measuring nothing.
2. **Doubling the work did not double the time** (100 iters 254 ms, 200 iters 242 ms), which
   is what exposed (1). Iterations were made mutually dependent so nothing could be elided,
   and a 0-iteration build was added as an explicit baseline.
3. **The first mutant differed in TWO ways.** It removed the check *and* changed the cast
   from `@intCast` to `@bitCast`. Those are not the same: `@intCast` tells LLVM the value
   fits the target range, `@bitCast` tells it nothing. The "unchecked" build came out **3.6x
   SLOWER than checked** -- a backwards result that was the mutant's fault, not the
   compiler's. Rebuilt with `@intCast` retained, i.e. exactly the pre-fix emit.

The third is the reusable one: **a mutant that differs in two ways attributes the whole
delta to one of them**, and here the wrong reading was the flattering one (checking is
free!). Same shape as the cooperative-attacker rule, in a benchmark rather than a test.

**WHAT THE NUMBER DECIDES.** Part 2 of the design (an explicitly-unchecked accessor) is
now clearly needed rather than merely tidy, and part 3 (range-`for` elision) moves from
"the nice half" to the one that carries the argument: a hot loop written as
`for i in 0..xs.len` should pay nothing, and today it pays the same ~17% as a hand-managed
index.

**HYPOTHESIS REFUTED BY LOOKING AT THE ASM (2026-08-26).** The natural story was that the
cost is lost VECTORIZATION rather than the branch. It is not. The two inner loops, isolated
by content after two failed attempts to find them by symbol and by loop-span heuristics:

```
unchecked, 6 instructions        checked, 8 instructions
                                 cmp    rax, rbx          <- the bounds check
                                 je     .LBB5_133         <- branch to panic
vmovsd xmm1, [rcx + 8*rdx]       vmovsd xmm2, [rdi + 8*rbx]
vmulsd xmm1, xmm1, [rsi + 8*rdx] vmulsd xmm2, xmm2, [r9 + 8*rbx]
vaddsd xmm0, xmm0, xmm1          vaddsd xmm1, xmm1, xmm2
inc / cmp / jne                  inc / cmp / jne
```

**Both are SCALAR** -- `vmulsd`/`vaddsd`, not `vmulpd`/`vaddpd`. Neither build vectorizes
this loop, so there was no vectorization to lose. The cost is exactly two instructions, one
`cmp` and one conditional branch, added to a six-instruction body: 33% more instructions
producing ~17% more time -- an unremarkable ratio once the number is right, and one that
no longer needs the basic-block split or dependency chain invoked to explain it. (The
earlier text reached for those to explain 91%, which is a reminder that a wrong measurement
recruits plausible mechanisms to justify itself.)

**AND LLVM ALREADY ELIDES HALF OF IT.** The loop performs TWO indexed reads (`row.at(j)`
and `v.at(j)`) and emits only ONE check -- the optimizer hoisted or merged the other,
unprompted, from a hand-managed `while` index.

**That is the strongest argument yet for the elision, and it changes the ordering.** If
LLVM removes one check with no help at all, giving it a provable bound from a range-`for`
should let it remove the rest -- so the elision plausibly recovers the whole ~17%,
automatically, for code already written in the safe form. The unchecked accessor recovers
the same but only where a user opts in, and it hands back the safety.

**Method note worth more than the result: three instruments failed before one worked.**
Symbol lookup failed (`matvec` was inlined and survives only as a reflection string); a
whole-function instruction count was too diluted to say anything (2346 vs 2319); a
"smallest backward jump" heuristic found the integer-to-string formatting loop in one build
and the real loop in the other, and dutifully reported a comparison between them. What
worked was searching for the loop by its CONTENT -- the accumulator pattern
`vaddsd xmm, xmm, xmm` -- and then READING the two bodies instead of counting them.

## THE GAP TO HAND-WRITTEN ZIG: ~18%, MEASURED FOR THE FIRST TIME (2026-08-26)

Sean's stated target is **within 30-50% of hand-written Zig**. Nobody had ever measured it.
The number is **~18%, comfortably inside the target**, and essentially all of it is the
bounds check added by BUG-313.

Identical algorithm, identical work (12000 matvec calls, n=128), identical timing method
(best-of-25 in-process rounds), `--release --single-threaded` / `-OReleaseFast
-fsingle-threaded`, identical checksum (1040.384). Run INTERLEAVED:

| run | Zebra (checked) | Zig (flat slice) | Zig (ArrayList layout) |
|---|---|---|---|
| 1 | 328 | 277 | 288 |
| 2 | 308 | 267 | 275 |
| 3 | 324 | 254 | 256 |
| 4 | 298 | 264 | 285 |

Zebra is slower in **4 of 4** pairs, by 13-28%.

**TWO INDEPENDENT MEASUREMENTS AGREE, which is what makes this trustworthy.** The bounds
check costs ~17% (measured separately, checked vs unchecked). Zebra-checked is ~18% behind
Zig. So **Zebra-unchecked sits at parity with hand-written Zig** -- the codegen itself is
not the gap, the safety check is.

**THE DATA STRUCTURE IS NOT THE GAP EITHER.** Zig using an ArrayList-of-ArrayLists (exactly
what Zebra emits) measures 256-288; Zig using a flat slice measures 254-277. Indistinguishable.
So the emitted representation is not costing anything either -- which is worth knowing before
anyone proposes changing it.

**METHOD NOTE, and it changed the answer.** Run standalone rather than interleaved, the same
binaries suggested PARITY (Zebra 236-264 against Zig 253-256). That reading was flattering
and wrong: the two sets were taken minutes apart under different machine conditions.
Interleaving put Zebra consistently behind. **A favourable result deserves more scrutiny
than an unfavourable one**, and on this machine a comparison that is not interleaved is not
a comparison.

**CAVEAT, recorded rather than discovered later: these numbers were taken while a `--daily`
tier was running at JOBS=2.** The absolute milliseconds are therefore inflated and should not
be compared against measurements from a quiet machine. The RATIO is protected -- both sides
saw identical contention because the runs were interleaved, which is exactly the property
interleaving buys -- but a future re-measurement on an idle box should expect lower absolutes
and is the one to quote if a single number is ever needed.

Reference implementation kept at `tools/bench/zig_reference.zig`; the Zebra side is
`tools/bench/index_bench.zbr`.

## THE ELISION: NOT BUILT, and the measurement is why (2026-08-26)

Part 3 of BUG-313's design was to make `for i in 0..xs.len` elide its bounds check, on the
Wirth/Hoare argument that a well-designed `for` lets even a simple compiler prove the index.
**It was not built, and the case for building it now does not survive the numbers.**

| | |
|---|---|
| prize | **~17%** ceiling -- the unchecked build IS the perfectly-elided build for that loop |
| loops it would apply to in the dogfood code | **0** (171 `while`, zero range-`for`) |
| loops in the whole `test/` corpus | 4 |
| what enforces its precondition | **nothing** |

**The precondition problem is the deciding one.** The lowering snapshots the bound before
the loop:

```zig
var i: i64 = 0;
const _stop_i: i64 = @as(i64, @intCast(xs.items.len));   // taken ONCE
while (i < _stop_i) : (i += 1) { s += _zbr_at(xs.items, i); }
```

If the body shrinks the list, `i` outruns the real length and the CHECK is what saves you.
So eliding is sound only when the receiver is not mutated in the body and the loop variable
is not reassigned -- and **nothing independently enforces either**. By the trigger rule
derived earlier the same day, that makes it opt-in at best, and a wrong analysis silently
reintroduces the exact memory-unsafety BUG-313 removed.

**The blocker is ADOPTION, not codegen.** A perfect elision today would speed up four loops
in our corpus and none in the real program. The range-`for` has to be the form people
actually reach for before the optimisation has anything to optimise -- which is a docs and
ergonomics problem, already started in `QUICKSTART` and in tinylm's notes.

**Revisit when:** a real program is written in range-`for` form, or the transform interface
exists (so the elision can ship as a described, disableable transform rather than invisible
codegen), whichever comes first. The measurement to re-take then is the same in-process
paired benchmark; the tooling for it is `tools/bench/index_bench.zbr`.

**Worth recording as a positive result:** LLVM already elides one of the two checks in the
hand-written `while` loop, unprompted. Whatever we build should be measured against that
baseline rather than against "no elision at all", because a chunk of the available win is
already being taken automatically.

## THE OTHER HALF OF KNUTH'S SENTENCE: COCKE'S HOIST (2026-08-29) -- MEASURED, BUILD IT

**The section above analysed the WRONG transform, and Sean caught it.** He recalled that
Knuth discusses doing the bounds check BEFORE the loop, so it is not paid at loop prices.
Checked against the paper (p.269, Subscript Checking) -- correct, and it names **two**
mechanisms in one paragraph where I had carried only one:

> "John Cocke observes that time-consuming range checks can be avoided by a smart compiler
> which first compiles the checks into the program **then moves them out of the loop**.
> Wirth and Hoare have pointed out that a well-designed `for` statement can permit even a
> rather simple-minded compiler to avoid most range checks within loops."

The second is the language-design one, and everything above is a fair verdict on it. **The
first is a pure compiler transform: no new syntax, no user annotation, and -- decisively --
no unenforced precondition.** That is why it survives the objection that killed the other.

**WHAT WAS MEASURED (three steps, each falsifying the last one's assumption).**

1. In ISOLATION, LLVM already does Cocke's hoist -- **including for our exact emit shape**:
   `_zbr_at` verbatim from the preamble, `i64` induction variable, the `i < 0` test and the
   `@intCast`. The checked function's inner loop came out **instruction-identical** to the
   unchecked one, both 8x unrolled. So our lowering is NOT what blocks the optimizer, which
   was the obvious first hypothesis and is wrong.
2. In the REAL emitted benchmark it does NOT hoist. The matvec inner loop keeps
   `cmp rcx, r9 / je <panic>` and is not unrolled. What differs is nesting: the inner loop
   sits inside an outer loop that stores to memory, and LLVM gives up.
3. Hand-applying loop versioning to that ONE loop:

| | today's emit | Cocke-versioned |
|---|---|---|
| inner loop | 8 instrs, check inside | **6 instrs, no check** |
| packed-SIMD ops in the binary | **0** | **3** |
| best-of-N, in-process | 177 ms | **160 ms** |
| checksum | 1040.384 | 1040.384 (identical -- the correctness control) |

**~10% off the whole benchmark from one loop, and the larger half is VECTORIZATION, not the
two instructions.** The check was blocking LLVM from vectorizing at all; removing it turned
a scalar loop into a packed one. That is a bigger and more general prize than the arithmetic
suggested, and nothing in the analysis above anticipated it.

**THE TRANSFORM, and why it is exactly semantics-preserving.** Version the loop:

```zig
if (bound <= xs.items.len) {
    while (...) { s += xs.items[@intCast(j)]; ... }   // unchecked
} else {
    while (...) { s += _zbr_at(xs.items, j); ... }    // TODAY'S EMIT, VERBATIM
}
```

The else branch is the current lowering unchanged, so a program that would panic still
panics -- same message, same reported index, same iteration. There is no `unreachable`, no
UB, and no behaviour that depends on the analysis being right: **a wrong analysis costs
speed, never safety.** That is the property the range-`for` elision could not offer, and it
is why this one can fire automatically under the trigger rule (its precondition is
independently enforced -- by the guard, at runtime).

**Preconditions for emitting the guard** (all decidable, all already have walkers):
the index expression is exactly the loop variable; the loop variable is assigned only by its
own increment; the increment is a positive constant; the container expression is
loop-invariant. Note the guard makes the *bound* precondition self-enforcing, so the
analysis only has to be right about the loop variable and the receiver.

**WHAT IS NOT ESTABLISHED, and should not be over-read from the table:**
- ONE benchmark, ONE loop shape, maximally index-dense. Real code does more work per index
  and will see less.
- Code size grows for every versioned loop. Untested: whether to skip versioning for large
  bodies, and what the threshold is.
- Whether the win survives when the two containers are the SAME object (aliasing).
- Whether `--turbo` should raise or lower the threshold. Unmeasured.

**Ordering:** this outranks both remaining BUG-313 parts. It needs no language change, no
adoption of a new loop form (it fires on the 171 hand-rolled `while` loops in tinylm as
readily as on a range-`for`), and it is the only one of the three with a measurement behind
it. Reproduce with `tools/bench/index_bench.zbr`; the hand-versioned emit is the artifact.

## RUN EVERY GATE RED ONCE, AND READ WHAT IT SAYS (2026-08-26)

`gate_selfcheck` and `tier_selfcheck` prove a gate CAN fail. That is not the same as
reading what it says WHEN it fails -- and the failure output is simultaneously the part
most likely to be wrong and the part least likely to be seen.

**Receipt, found within minutes of writing this down.** Falsifying the new BUG-313 legs
against a real attacker (a compiler rebuilt with the check stripped from `_zbr_at`) made
`release_mode_check` print:

```
   FAIL   index past the end was NOT refused in --release
   FAIL   negative index was NOT refused in --release
release-mode: 1 check(s) FAILED
```

Two failures, reported as one. `fail=1` was a FLAG being printed as a COUNT, in all eight
of that gate's failure paths -- so it had reported "1 check(s) FAILED" for its entire
existence regardless of how many checks failed. **No green run could ever have shown this.**
Fixed to a real counter and verified in both directions (2 against the mutant, silent when
clean).

**The shape generalises.** Everything a gate checks about itself -- a sentinel, a panic
text, a count, a refusal message -- lives on the failure path. `contract_mode_check`
classifies on a printed sentinel rather than exit code for exactly this reason (a build
failure also exits non-zero); `output_sweep` prints its transient count even when zero.
A gate whose PASS line is honest and whose FAIL line is not is half-instrumented, and the
half that is broken is the half you consult under pressure.

**The practice:** when adding or touching a gate, break it deliberately once and *read the
output*, not just the exit code. Ask the same question the instrument-discipline rules ask
of a clean result -- "what would make this print the wrong thing?" -- of the red one.

## THE AUDIT THAT CAME OUT OF THIS, and its first receipt (2026-08-26)

Two founders, two questions, in sequence. Run against real dogfood code they found a
shipped memory-safety bug in under an hour, and **neither question alone would have found
it**:

**1. Knuth — what do REAL programs do that our tests do not?**
`tools/construct_histogram.py <dir>` diffs the construct distribution of a real program
against `test/`. On 1116 lines of neural-network Zebra (`C:/Projects/tinylm`):

| construct | real, per 1k lines | corpus | ratio |
|---|---|---|---|
| `float` | 331.5 | 3.6 | **92x** |
| `while` | 152.3 | 4.0 | **38x** |

and the combination is starker than either number: files exercising float + `.at()` +
`while` together are **6 of 6** real files against **0 of 522** corpus files (the one
apparent corpus match is `tc_types.zbr`, where "float" is the enum variant name `float_`).

**2. Hoare — what did the COMPILER DO to that code?**
`.at(j)` lowers to `row.items[@intCast(j)]`: raw slice indexing. Zig checks that in Debug
and ReleaseSafe and **not** in ReleaseFast, which is what `--release` passes. Measured both
ways: a 2-element list read at index 2 panics in debug and, in `--release`, returns `0` and
carries on. **BUG-313.**

**WHY THE PAIR IS THE POINT.** The histogram alone says "`.at()` is popular" -- not a
finding. The transformation audit alone, run against our own corpus, shows the identical
lowering on code that barely indexes anything and looks unremarkable. The defect lives in
the intersection: *a construct we do not test, examined for what the compiler silently does
to it.* Knuth's empiricism aimed by Hoare's criterion.

Neither is a gate and neither should be. They are an **audit** — run against each new real
program, because each one is a fresh sample of the distribution users actually write.

## MEMORY: dead locals are NEVER reclaimed, and `allocate Arena()` is the lever (measured 2026-08-26)

Sean asked, while chasing the NN performance gap, whether a `List` local is freed when its
function returns, and proposed per-type allocators to control fragmentation. Measured:

`_prog_alloc()` returns `_arena.allocator()` -- a single **program-lifetime arena**. The
only `deinit` in an emitted program is `defer _zbr_rt._arena.deinit()` at the end of `main`.
So **nothing is ever freed until the process exits.**

| 200 calls x 20000 floats, all locals dead on return | arena bytes |
|---|---|
| plain calls | **37,170,786** |
| each iteration wrapped in `allocate Arena()` | **1,790,872** |

200 x 20000 x 8 = 32 MB, so essentially 100% of the allocation is retained in the first
case. The scoped form reclaims, 20x.

**THIS REFRAMES THE PER-TYPE-ALLOCATOR IDEA.** Partitioning by type controls fragmentation;
Zebra has no fragmentation, because it never frees. The lever is **scope**, not partition.
And note §28j is about the allocator's THREAD-SAFETY, not reclamation -- the planned
two-tier design is per-thread arenas, which are still arenas.

**Actionable now:** wrap each training iteration in `allocate Arena()`, with `<<-` copy-out
for values that must survive (weights, gradients). The likely dominant cost in a long
training run is not arithmetic but an ever-growing working set destroying cache locality.

**Worth investigating (not yet measured):** whether the compiler could place an
`allocate` scope automatically where escape analysis proves no allocation outlives the
call. That is the Hoare criterion again -- a transformation the compiler is positioned to
make and the user cannot see.

## SMALLER, RECORDED

- **Version string: `0.9_zig0.16`**, not `0.9_0.16` -- the bare form reads as a four-part
  version, and the Zig version is semantically load-bearing here (BUG-280's keyword list
  already drifted across a Zig bump; `--release` semantics depend on it). It belongs in the
  string because it changes behaviour.
- **Total-size budget: adopt the BUDGET, defer the plugin architecture.** A size ceiling is
  free and forces the conversation at every feature. Modularity is one possible *response*
  to exceeding it, not the mandated one -- and plugin boundaries inside a compiler are
  unusually expensive, because this project's defects cluster at seams (BUG-293/294 were
  both seeding failures across a boundary). Let the budget reveal the fault lines before
  pouring concrete into them.
- **Reward checks: declined for now, on Sean's read** -- a $2.56 cheque is a trophy because
  of who signed it, so the mechanism does not transfer without the stature. Revisit if that
  changes.
- **`BUGS_FIXED.md` wants organising before a public release.** It is already TAOCP-style
  errata treated as a first-class artifact rather than an apology; that is worth keeping
  deliberately and structuring by version once versions exist.
- **Read the primary source before quoting it.** Knuth, Royce and Brooks are all
  systematically misquoted, and this session made the mistake twice in one afternoon: the
  wrong Knuth paper cited from memory (caught by the filename `p261-knuth.pdf`), and the
  range-check argument attributed to Dijkstra when it is Wirth and Hoare's. Same discipline
  as "do not trust the instrument", pointed at literature.

## Smaller observations from the same sample, recorded not filed

- **`continue` appears in NEITHER corpus** -- zero uses across 522 test files and 1116 lines
  of real code. `lint_reserved_words` cannot see this: the word is parsed, just never
  exercised. Either a feature nobody needs or a gap nobody has noticed.
- **A `float` prints without its fractional part**: `7.0` renders as `7` (full precision is
  kept -- `1.0/3.0` gives `0.3333333333333333`). Languages disagree here (JS drops it,
  Python keeps it), so this is a design question rather than a defect, but it makes a float
  and an int indistinguishable in output, which matters when eyeballing tensor values.
- **The six dogfood files should become fixtures.** They compile, they are real, and they
  are the only evidence we hold of the distribution users write. Registering them moves the
  numeric path from *present* to *asserted*.

## Language & compiler direction — 2026-07-28 assessment

Sean asked what would make Zebra a daily driver on technical grounds (ecosystem/user-base
explicitly excluded). Items below are that answer, re-ordered by MEASUREMENT after the first
pass got the cause wrong. **#2 and #4 are flagged DISCUSS-FIRST at Sean's request** — he wants
to weigh strategies before implementation.

### The measurements everything below rests on (don't re-derive these)

| What | Time |
|---|---|
| Zebra front end, hello-world (`--emit-zig`) | **0.057 s** |
| `zig build-exe`, trivial 5-line Zig, LLVM | **5.2 s** |
| `zig build-exe`, Zebra 3,790-line emit, LLVM | 6.2 s |
| `zig build-exe`, trivial Zig, `-fno-llvm -fno-lld` | **0.94 s** |
| `zig build-exe`, Zebra 3,790-line emit, `-fno-llvm -fno-lld` | **1.15 s** |

**The conclusions, which are not what I first claimed:**
- The front end is *excellent* — 57 ms. Latency is entirely downstream of it.
- **Zig's own floor dominates**: ~5.2 s LLVM / ~0.94 s self-hosted, for ANY program.
- The entire 186 KB preamble therefore costs **~1 s on LLVM and ~0.2 s on the fast backend** —
  not the bulk of the time. My first analysis attributed the 5.2 s to the preamble without
  measuring the floor; one probe refuted it. **Preamble work is NOT a latency fix.**
- Therefore *tree-shaking the preamble* (conditional population — Sean's alternative) buys
  ~0.2 s. See the verdict under #1.

### THE ORGANIZING GOAL (agreed with Sean, 2026-07-28): move checking INTO Zebra

The measurement that produced this frame:

| `zebra -c` outcome | time |
|---|---|
| clean program | 0.81 s |
| error only `zig` can see | 1.88 s |
| **error the Zebra front end catches itself** | **0.062 s** |

A check the front end can answer costs **62 milliseconds**, because it never invokes
Zig at all. So the question was never "how do we make checking fast" — it is
**"how much checking can Zebra do itself?"** Every check moved into the front end is
simultaneously ~25x faster, reported against the user's own source instead of
generated Zig, and available to the IDE/LSP without a build.

That reframes three items below as **one project wearing three hats**:

- **#3** (nil-narrowing into the TypeChecker) — makes the TC authoritative about what
  is known, which everything else builds on.
- **#5a** (stdlib arity/signature table) — moves a whole class of silent miscompiles
  (BUG-215) into front-end diagnostics.
- **#4** (what `-c` should promise) — becomes a *consequence* rather than a separate
  design question: the more the front end checks, the more a fast check is a real one.

Related, same direction: BUG-218 (`str + int`) was exactly this move — a mistake that
used to surface as a Zig error about `_str_concat` in a 3,790-line generated file now
resolves in 62 ms against the user's own line, with a caret. That is the template.

**Sequencing:** ~~#5a first, then #3~~ — **#3 landed first** (2026-07-28, `81501dc`), which
makes the TC authoritative about what is known and unblocks the rest. **#5a is next** in this
group (self-contained, immediate user-visible payoff, no dependencies); then revisit #4 with
Sean once the front end's coverage is actually worth promising something about.

### F1 — SPIKE: move stdlib method-name checking out of CodeGen so `-c` can see it (2026-08-17)

**Sean's framing:** *"do we have places that are in the CodeGen that we could push into
the CgHelpers to free up more `-c` functionality?"* Yes, and the largest class is one
shape repeated ~35 times.

**THE MEASUREMENT.** `selfhost/CodeGen.zbr` contains **49** `@compileError` emissions.
About **35** are the identical shape:

    @compileError("selfhost: unknown Path.<method>")
    @compileError("selfhost: unknown File.<method>")
    ... sys, Json, Http, HttpResponse, Ws, Regex, DateTime, Hash, Crypto, Random,
        Terminal, Log, Csv, Timer, Progress, Profile, Base64, Uri, Compress, Mime,
        Tcp, Udp, Sqlite, Net, Gui, Shell, Dir, Reflect, Arg, Build, ...

Each is a **pure name lookup** — namespace + method name, both present in the AST. No
emit context, no inference, no allocator. That is exactly `CgHelpers`' stated contract
("pure analysis passes on the Zebra AST: no I/O, no allocator dependencies").

**WHAT IT COSTS TODAY.** `Path.bogus()` produces a Zig `@compileError` against GENERATED
code. So `zebra -c` exits **0** (front-end only — it never compiles the emitted Zig), and
when the user does hit it the message points at generated Zig rather than at their source
line. That is `tools/frontend_gap.py`'s 23-of-54 gap, and the same UNGIT failure as
BUG-259: the system knows and does not say, where the user is already looking.

**THE PRECEDENT ALREADY EXISTS — this is not a new architecture.**
`selfhost/Resolver.zbr:26` already does `use CgHelpers exposing isStdlibNs`, so a
FRONT-END phase consuming shared AST helpers is proven in-tree. The namespace-level
knowledge is already shared; only the per-namespace METHOD tables are not. It also lines
up with the root cause recorded in the divergence notes: *"Resolver.isBuiltin vs
CodeGen.isStdlibNamespace drift — unify."*

**WHY THIS IS A SPIKE AND NOT A GRIND-THROUGH-35.** Three hazards, in severity order:

1. **Getting a table wrong REFUSES VALID CODE**, which is the expensive direction — a
   false accusation against a correct program, not a miss. If an extracted table omits a
   method CodeGen actually handles, the front end rejects a working call.
2. **A hand-copied table above a default is rule 1b** — "a comment or list enumerating
   what a default applies to is a hand-maintained oracle wearing documentation as a
   disguise", the hazard recorded on `isStringExpr` (BUG-277). Copying 35 lists by hand
   would be minting 35 of them.
3. The method names are woven into `if mname == "..."` CONTROL FLOW inside each
   `genXCall`, so extraction means turning control flow into data, 35 times.

**SO THE SPIKE'S REAL QUESTION IS NOT "can we move it" BUT "can the table be DERIVED
rather than copied?"** — the rule `lint_zig_keywords` (oracle = zig's own tokenizer
table) and `grammar_export --check` (oracle = the Earley rule table) are both built on.
If the table can be derived from the emit branches, the remaining 34 are a mechanical
grind with a real gate behind them. **If it cannot be derived, the honest outcome may be
a LINT that cross-checks the two lists rather than a move** — and that is a legitimate
result of the spike, not a failure of it.

**DO ONE NAMESPACE END TO END.** `Path` is the smallest (see `genPathCall`,
`CodeGen.zbr:~17100`). Deliverable: the front end refuses `Path.bogus()` with a Zebra
diagnostic carrying a source position, `zebra -c` catches it, and the table is derived or
the derivation is proven impossible with the reason written down.

**CONTROL BEFORE BELIEVING IT WORKS:** a probe calling every method `genPathCall` really
does handle must still compile. A spike that only tests the REJECT direction has
confirmed nothing about the 2.-hazard above — that is the negative-control rule
(*"probe a failure and you overestimate the damage; probe a success and you
underestimate it"*).

### UNGIT pass — migrate every SILENT surface into a LOUD one (Fable, 2026-08-08)

Same organizing goal, arrived at from a different door: an UNGIT review of
`QUICKSTART.md` (the design principle: *a tool owes its user the whole truth it
holds, and no more; nothing withheld, nothing fabricated, nothing ambient* —
`wiki/pages/concepts/concept_ungit-principle.md`). The finding is that the
quickstart is *unusually honest* — its §1.5 already splits Python gotchas into
**Loud** (compile error) and **SILENT** (different answer, no warning), tags
each with a BUG number, and one section literally opens *"read this one, it
fails silently."* That honesty is the documentation compensating for language
silence. **The program: move each SILENT row across the line into Loud** — which
is precisely "move checking into Zebra," and BUG-218 (`str + int`) is the
template each item below follows: a mistake that surfaced as a Zig error in
generated code becomes a 62 ms diagnostic against the user's own source.

Distinction held deliberately: some SILENT surprises are *correct design* and
must stay documented, not "fixed" — `-7/2 == -3` (C/Zig truncation, self-
consistent) is not a defect and is out of scope. Ungitting makes *silence*
loud; it does not make a language refuse to have opinions.

- [x] **BUG-292 — `old <parameter>` is REFUSED. DONE 2026-08-17 (`31ff0d0`).** The
  first UNGIT migration of this batch to actually land, and the template holds: a
  silent surface (a post-condition that passes under any implementation of `old`,
  including a broken one) became a 62 ms front-end diagnostic against the user's own
  line, with a caret. `zebra -c` catches it.
  **What it cost was placement, not logic.** The traversal is shared with CodeGen, and
  the plan recorded in BUGS.md said to put it in `CgHelpers` — which closes a cycle,
  because `CgHelpers` imports `TypeChecker`. That surfaced **BUG-295** (an import cycle
  builds clean and yields a compiler that stack-overflows, no diagnostic) and a second
  manifestation of **BUG-294**. It lives in the new `selfhost/AstWalk.zbr`.
  **Two receipts worth carrying into the remaining U-items.** (1) Landing a refusal is
  the cheapest moment to find every document that taught the thing you just refused —
  `doc_example_check` failed with 1 NEW and named `STYLE_GUIDE.md`, a file I had not
  looked at, carrying the same example and the same wrong rationale. Run it
  deliberately after the next one. (2) A refusal needs a POSITIVE control that
  discriminates, or you have only proved the compiler can say no.

- [x] **BUG-294 + BUG-293 — FIXED overnight 2026-08-18** (`8d26aad`, `e7b9679`), both
  FULL tier 30/30 in one invocation. Not UNGIT items themselves, but they came out of
  BUG-292's placement hunt and both share its moral: **the defect was in how a decision
  gets SEEDED, not in the decision.**
  - BUG-294 (`^T` deref) had two manifestations and ONE root — the deref is driven by
    name-keyed side tables, and the loop-variable half was a hardcoded special case for
    `DictEntry.key`/`.value` while the current module's fields were registered as a side
    effect of EMITTING the struct. Fixed by deriving both. The removed special case was
    proven subsumed by the round-trip, not merely deleted.
  - BUG-293 (cross-module container out-param) was a mirror: `fn_param_lists` crossed
    the module boundary under §27b and the BODY did not, so the caller could not tell
    whether to pass `&`. It now travels the same route.
  - **Two pending tripwires fired on their own** when the fixes landed, which is the
    convention working: `bv_hat_deref_loopvar` and `bug293_xmod_container_test` both
    passed by asserting broken behaviour, went red on the fix, and were rewritten to
    assert intent.

- [~] **BUG-295 — import cycles: DIAGNOSTICS LANDED, refusal DEFERRED by decision**
  (`2b18579`, `39bad44`, 2026-08-18). A cycle is reported with its full path and the
  rule stated (*first import wins; the second module sees a PARTIAL view*), and a
  shared module that declares module-level state is named at end of compilation. Both
  fire on real code; the selfhost compiling itself is silent.
  **HELD AT WARNING, deliberately — the reasoning is recorded in BUG-295 and should not
  be re-derived.** Short version: a refusal must be actionable, and *"extract a third
  module"* is not advice a user can take about a VENDORED dependency. Measured: a cycle
  reached via `--module-path` is invisible today (type-scanned, never compiled) while
  one vendored by COPYING INTO THE TREE is detected — so refusal would wall exactly the
  population that cannot fix it. Promoting needs three things together: an escape hatch
  modelled on `--allow-implicit-try` (§28b already solved this shape), a different
  message when the cycle is not yours, and a deliberate answer for the `--module-path`
  blind spot. `MultiCompiler.cycle_is_error` flips the switch in one line and both
  directions are verified, so the decision is cheap to revisit and expensive to get
  wrong.
  **Small, decoupled follow-up:** make a vendored (`--module-path`) cycle WARN, so the
  blind spot is closed without touching the refuse/allow question.

- [ ] **U1 — `for-else` silently DROPS the `else` block** on HashMap /
  string-split / chars iterators (BUG-16; QUICKSTART §26, §27#11). This is the
  sharpest item: not a wrong answer but *code the author wrote, deleted with no
  word* — the worst shape a SILENT surface can take. **Interim fix is cheap and
  should not wait on the real feature:** reject `for-else` on the unsupported
  iterator forms with a front-end error — `error: for-else is not yet supported
  on <chars/split/HashMap> iterators` — pointing at the `else` keyword.
  *Acceptance:* a `for … else` over `.chars()` compiles to that diagnostic, not
  to a binary missing the block. Milestone: 0.9 (a dropped block is a
  correctness hazard, not polish).

- [ ] **U2 — map/filter element type not inferred through a binding** (BUG-17;
  QUICKSTART §10, stated 3×: *"annotate the binding … isn't inferred through the
  binding yet"*). The ambient-knowledge tax: the user must know to write
  `var d: List(int) = xs.map(...)` or silently lose the ability to call List
  methods on `d`. Two honest exits, either acceptable: (a) propagate the
  map/filter result's element type through the binding (the real fix), or (b)
  interim — when a List method is called on an un-annotated map/filter binding
  and inference fails, emit a diagnostic that *names the annotation fix* instead
  of a downstream type error. *Acceptance:* `[1,2,3].map(def(x)=x*2)` bound and
  then `.sort()`-ed either works or errors saying "annotate the binding as
  List(int)". Milestone: 0.x.

- [ ] **U3 — `extern` `int`-size ABI mismatch is silent** (BUG-18; QUICKSTART
  §ABI, *"read this one, it fails silently"*). `extern def f(x: int)` against a C
  `int` links cleanly and corrupts the call (Zebra `int` is 64-bit; C's is 32).
  The front end *knows the declared type* — this is a 62 ms check. **Fix:** a
  front-end lint on `extern def` parameters/returns typed `int` (and `uint`):
  `warning: C 'int' is 32-bit; use int32 for a C ABI boundary`. *Acceptance:*
  an `extern def` with an `int` param warns with the int32 suggestion; using
  `int32` is silent. Milestone: 0.x (cheap, high-value at the FFI boundary Graze
  will lean on).

- [x] **U4 — free the reserved word `aspect`; move AOP (if ever) to `@aspect`**
  — **DONE 2026-08-09.** `aspect` is an ordinary identifier: `var aspect = 1`,
  `def f(aspect: str)` and `var aspect: str` in a class all compile and run.
  Removed `kw_aspect` from both tokenizers, the nine `AspectDecl` /
  `AspectBodyItem` grammar rules, the three nonterminals, the two `TopDecl` /
  `MemberDecl` productions, AstBuilder's three arms, and the six Parser
  acceptance tests — which are replaced by their inverse (the word must now
  reach the parser as a plain `id`). `grammar.txt` regenerated from the rule
  table: 474 → 465 rules, 149 → 146 nonterminals.
  **Two things the removal surfaced.** (1) It also closed a *permanent*
  accept/reject divergence: `AspectDecl` never appears anywhere under
  `selfhost/` in the whole git history, so the bootstrap accepted a construct
  the selfhost had no parse path for — and `fuzz/gramgen.py` derives its
  programs from `grammar.txt`, so it was generating exactly that. (2) It
  orphaned `kw_error`, whose *only* grammar uses were inside the `on error(e)`
  advice clauses. Baselined rather than removed — see below.
  The old construct now gives a clean `unexpected top-level token: 'aspect'`
  instead of the `std.debug.panic` it used to.

- [x] **U4a — the rest of the reserved-word audit** — **DONE 2026-08-09.**
  Sean's call: *"implies I think is the only one to keep. weaves could be turned
  into a decorator so no kw needed there."* **Five freed, three still reserved** —
  and the split is not the one either of us expected.

  | word | was | now |
  |---|---|---|
  | `weaves` | R2 — clause parsed, nothing read it; project-level form panicked | **freed**; `@weaves` if AOP is ever built, matching `@aspect` |
  | `expect`, `lock` | R2 — parsed, then `std.debug.panic("not yet implemented")` | **freed** |
  | `from`, `trace` | R1 — no rule in either compiler | **freed** |
  | `error` | R1 — orphaned when `aspect` took the `on error(e)` clauses | **still reserved** — BUG-280 |
  | `try` | R1 — no construct since §28b replaced it with `expr?` | **still reserved** — BUG-280 |
  | **`implies`** | R1 — sits under *Contracts* | **kept**, on language grounds |

  **Why two of the five you asked for did not ship.** Freeing a word at the tokenizer
  is only half the job: the compiler then has to be able to EMIT it. Measured after
  the change, per word and per position — `error` works as a local and a parameter and
  fails as a **field** (`error: i64 = 0,` in the generated Zig); `try` fails
  everywhere. Both are Zig keywords, and `isZigKeyword` is a hand-maintained list
  missing `try` while the field-declaration path never consults it at all (BUG-280).

  Freeing them anyway would have replaced a clear Zebra diagnostic
  (`expected identifier, got 'try'`) with a Zig parse error against generated code
  carrying no Zebra source location. That is a worse surface, so they wait. The
  Parser tests assert they are STILL rejected, so the tokenizer cannot be freed
  without the emit being fixed first.

  **BUG-280 is a live bug regardless**, which is the part worth acting on: Zebra never
  reserved `align`, `packed`, `opaque`, `volatile`, `threadlocal`, `anyframe` — all Zig
  keywords, all legal Zebra identifiers today. `class C / var align: int = 0` does not
  compile, and has not for as long as the field path has skipped `emitName`.

  **BUG-280 is FIXED in both compilers as of 2026-08-11** (18 emit sites each, not the
  same 18 — see the entry in `BUGS_FIXED.md`), gated by `keyword-ident` in the QUICK
  tier.

  **U4a's TAIL IS CLOSED — `error` and `try` are FREED, 2026-08-13.** Sean's call, after
  the scan corrected a premise: `error` was never a competing error mechanism, it was the
  `on error(e)` **advice clause inside an aspect body**, orphaned when `aspect` went; and
  `try` lost its construct when §28b replaced `try expr` with `expr?`. What survives is
  the method-level `catch |e|` clause, which synthesises `Ast.StmtTryCatch` with no `try`
  token — so `buildStmtTryCatch` in the bootstrap is dead code (flagged in place, not
  deleted). Verified in BOTH compilers, structurally (zero occurrences in `grammar.txt`,
  which is GENERATED from the rule table) and empirically (statement prefix, expression
  prefix, `try`/`catch` block and bare identifier all rejected before the change).
  Nothing planned claims either word: typed error sets (#2) is `throws ParseError`, an
  ordinary identifier, with no `error{...}` syntax.

  **What actually unblocked them was the EMIT, and that is the lesson.** They were held
  back not by the parse but by codegen's inability to spell them, which
  `lint_reserved_words` cannot see — it classified both R1 (unreachable) the whole time.
  BUG-280's field paths plus the `isZigKeyword` oracle (`tools/lint_zig_keywords.py`,
  2026-08-13) closed it. **A word can be R1 in that gate and still be unsafe to free.**

  Proof is `test/bug280_freed_words_test.zbr`, registered with `smoke_run`: both words as
  a local, a parameter, a field, a static field, a class name, a struct name, a method
  name, a static method name, an enum member, a union variant and inside `@derive`
  bodies — all compiling and printing the right values. Deliberately NOT added to
  `keyword_ident_check`'s word list: codegen emits `error` and `try` legitimately as ZIG
  keywords (`return error.ZebraError;`, `try f()` — 56 and 17 bare occurrences in a
  single generated module), so that gate's rule would fire on nearly every program.
  Reserved-words baseline 3 → **1**; only `implies` remains, kept on language grounds.

  Three further emit families were still unescaped in BOTH compilers when this was
  written (`@derive` bodies, the type name itself, a capture read in a lambda body):
  **BUG-281**, now six of seven closed.

  Grammar: 465 → **456 rules**, 146 → **143 nonterminals** — exactly the 9 rules and
  3 nonterminals removed here. `grammar.txt` is regenerated from the rule table.

- [ ] **U4b — delete the vestigial `WeavesOpt` nonterminal (small, and a real hazard)**
  U4a freed `weaves` by deleting the rule `WeavesOpt → kw_weaves TypeRefListNE`
  and **keeping the ε production**, so `WeavesOpt` still occupies a slot in the
  RHS of **14 declaration rules** while always matching empty.

  That was deliberate, and the reason is the interesting part: `src/AstBuilder.zig`
  addresses parse-tree children by **hardcoded index** — `kids[11]`, `kids[9]` —
  with the rule's layout written in a **comment** above each function, e.g.

  ```
  // Non-generic: ModList kw_class id ClassHeader IsClauseOpt HasOpt WeavesOpt eol indent MemberDeclList dedent
  //   indices:   0       1         2  3           4           5      6         7    8      9              10
  ```

  Deleting `WeavesOpt` shifts every index after position 6 in all 14 rules, across
  generic and non-generic variants, checked against nothing but that prose. There
  are 503 `kids[N]` sites in the file. A wrong index does not necessarily fail
  loudly — landing on an adjacent optional (`IsClauseOpt` vs `HasOpt`) yields an
  empty list rather than an error.

  So this is **rule 1b at the scale of a whole file**: a comment enumerating a
  layout, load-bearing, unchecked. The cleanup is worth doing, but it wants its own
  session and probably wants the positional access replaced by a
  find-child-by-nonterminal helper first — which would retire the hazard rather
  than move it. Filed rather than rushed.

  <details><summary>original U4 text, kept for the record</summary>

  (bugbook BUG-10; Sean's call, confirmed by investigation 2026-08-08).
  `kw_aspect` is reserved but the feature does not exist: the bootstrap parses
  `AspectDecl` into a dead node (0 references in `CodeGen.zig` /
  `TypeChecker.zig`), and the selfhost does not parse it at all — `aspect Foo`
  today errors `unexpected top-level token: 'aspect'`. So the keyword's only
  live effect is to *block `aspect` as an identifier*, at real cost: it is the
  collision behind procgen's keyword-rename shield, it cannot be a parameter or
  field name, and it is a real DB column name in the wild (Mosaic's
  `claim_confidence.aspect`). **Fix:** remove `aspect` from the keyword token
  list (same hygiene as the `pro`/`get`/`set`/`body`/`post` removal already
  done); if aspect-oriented programming is ever built, `@aspect` decorator
  syntax (matching `@reflectable`/`@once`/`@profile`) is the modern idiom and
  needs no reserved word. *Acceptance:* `var aspect = 1` and `def f(aspect: str)`
  compile; the AOP grammar production, if kept, is unreachable and can be
  deleted or gated behind `@`. Milestone: 0.x (small, removes a whole friction
  class). **Likely companions:** a quick audit for other reserved-but-
  unimplemented words (`weaves`, `cue`, `vari`?) may free several at once.

  </details>

**Same template, already tracked — fold in when their sections are touched:**
BUG-225 (`s[i]` typed `char` while holding a byte — the type lies about the
value), BUG-227 (`tokenize(seps)` splits on the whole sequence, disagreeing with
its own docs). Both are SILENT rows awaiting the same Loud migration.

Cross-reference for all of the above: bugbook BUG-16/17/18 + BUG-10 (Fable's
tracker, `C:\Projects\bugbook`), filed 2026-08-08.

### ~~FREE WIN — `-c` is excluded from the fast backend~~ — **DONE 2026-07-28 (`3fabc50`)**

`selfhost/main.zbr:2414` read `if not mode_c and not release and …`, so check mode — the
compiler's most latency-sensitive command, and the one ZebraIDE's Check button ran (the IDE
was removed with the imgui backend, 2026-08-29) —
was **explicitly excluded** from the `-fno-llvm -fno-lld` path and took the slowest available
route. The exclusion turned out not to be load-bearing: the comment's argument (the self-hosted
linker does not error on unresolved C symbols) is about C deps, which the condition already
tests separately, and the compile-failure fallback to the authoritative LLVM path protects the
rest. A check also needs no binary, so it now passes `-fno-emit-bin` and skips linking
entirely — measured as most of the remaining cost. **3.97 s → 0.81 s**, identical diagnostics.

- [~] **#1 — Stop inlining the preamble; ship it as a runtime module. NOW THE DEFAULT (2026-07-28; `--no-runtime-module` opts out) — read `docs/design/runtime_module_design.md` before touching it.** Emitted programs
  would `@import` a runtime package instead of carrying 3,790 lines of copy-pasted preamble for a
  2-line source. **Re-justified after measurement — this is NOT about speed** (worth ~0.2 s on
  the fast path). It is about three things that are real:
  1. **Error locations.** Errors currently land in generated code (`_str_concat` at line 3779 of
     a file the user never wrote — BUG-215/218). With a ~50-line emitted file there is almost
     nowhere for an error to land except user code.
  2. **Namespace isolation.** Closes BUG-220 *completely*, including the `@export`/`@node_export`
     cases the `_zbr_fn_` prefix cannot cover.
  3. **Artifact comprehensibility** — debugging, DAP, `remapZigErrors`, and anyone reading the
     emitted Zig.

  **Verdict on the tree-shaking alternative** (conditionally populate the preamble by what the
  program uses): *not recommended as a substitute.* It buys ~0.2 s; it requires a call-graph
  reachability analysis over the preamble (whose helpers call each other) that must be
  conservative or it emits undefined identifiers; and — the decisive objection — it makes
  BUG-220-class collisions **input-dependent**: a program compiles until you add a call that
  drags in a preamble chunk containing your function's name. A collision that appears when you
  add an unrelated line is a far worse failure mode than one that is either always present or
  never. Tree-shaking is a reasonable *optimisation* later; it is not the fix for what #1 is for.

  Overlaps `docs/design/single_file_emit_design.md` but is distinct: that combines *modules*; this stops
  copy-pasting the *runtime*.

  **Spike outcome (do not re-derive):** `@import` shares file-scope state across modules at
  any depth (proven 3 levels deep) — so one shared `_allocator`/`_io` **dissolves BUG-221**
  outright, no fan-out. A real hello-world split cleanly: **3,791 lines → a 30-line user file
  + a 3,770-line runtime module (126×)**. Two constraints found before writing any compiler
  code: (a) `usingnamespace` is **removed in Zig 0.16**, so symbols come in by explicit alias;
  (b) a mutable `var` **cannot be aliased** across modules (`const x = _rt.x` → "unable to
  resolve comptime value"), so the **19 mutable preamble vars must be QUALIFIED** at every
  emit site — that is the main implementation cost, and it is also exactly what makes them
  shared. Plus one backward dependency to break: the preamble's `_initIo` calls
  `_initModuleVars()`, which codegen emits into the *user* file.

  **PHASING (decided 2026-07-28): behind a default-off `--runtime-module` flag**, exactly as
  single-file emission was phased. The reason is more than caution: `bootstrap_check.sh` step 3
  has selfhost-A re-emit into `selfhost/` itself, so an unconditional change would make the
  compiler's own committed `.zig` shape depend on which tool last regenerated it (bootstrap =
  monolithic, selfhost-A = split). A flag the round-trip never passes removes that entirely.
  **Invariant: `bootstrap_check.sh` must never pass `--runtime-module`.**

  - [x] **Step 1 — mark the preamble `pub` (2026-07-28, `f115795`).** 429 declarations (396
    top-level + 33 type members) via `tools/pub_mark_preamble.py`, marked structurally — only
    where every enclosing block is a container, since `pub` on a function-body statement is
    illegal. Inert while the preamble is spliced inline, so it landed alone and was proven by
    the full tier: **7/7 — compile_check 217/0/1, round-trip byte-identical, full_sweep 0
    regressions (333), divergence 0 selfhost gaps.** NOT mirrored into `src/CodeGen.zig`: the
    bootstrap keeps inlining, so it never needs the markings. Still unmarked, and required
    before the flag can cover GUI: `gui_tui_section.zig` (89 decls), `gui_libui_ng_section.zig`
    (102).
  - [x] **Steps 2-6 — the codegen change, LANDED 2026-07-28 behind `--runtime-module`.**
    `zebra --runtime-module` writes `zebra_rt.zig` beside the program and `@import`s it:
    hello-world **3,791 lines -> 27**, and **BUG-221 is dissolved** (the three-module repro
    that segfaults on the default path prints its answer). Qualification runs as a
    quote/comment/field-aware post-pass over the assembled emit — `_allocator` alone is
    written at 135 emit sites, mostly inside larger `w.emit(...)` literals, so one pass that
    cannot miss a site beats 250+ hand edits. The alias set is read back out of the emitted
    text, so codegen needed no new tracking. Off the flag, assembly reproduces the historical
    shape exactly.
    - **The `pub` marking runs in BOTH directions — this is the finding worth keeping.**
      Step 1 marked the runtime `pub` so the program could import it; but the runtime also
      calls back INTO the program (`_ThreadPool.submit(f: anytype)` does `@as(*T, ...).call()`
      on a closure struct that *codegen* emitted), and across a module boundary that member
      needs `pub` too. The spike never saw it because it only ever split a hello-world.
      `compile_check --runtime-module` caught it on the three threading tests (214/3/1) —
      the clearest argument for gating the flag with the corpus witness rather than examples.
    - **Refused, not guessed:** `--runtime-module` errors out with `--single-file` (both
      restructure file scope), `--target node-addon`, and any `--gui-backend` (both scaffold
      their own build; the GUI section files are not `pub`-marked yet).
    - **Gates added:** `tools/runtime_module_check.sh` (QUICK tier — the only gate that RUNS
      anything emitted in this mode, hence the only one that can see BUG-221) and
      `compile_check.sh --runtime-module` (FULL tier), which is **217/0/1, identical to the
      default-mode baseline**.
  - [x] **FLIPPED TO DEFAULT 2026-07-28 (`ade34cf`).** `--no-runtime-module` opts out.
    **BUG-221 is fixed on the default path.** The three refusals became FALLBACKS, which is
    the substance of the flip: under a flag, refusing an uncovered combination is honest; as
    the default it would simply break those paths. `--single-file`, `--target node-addon` and
    every `--gui-backend` now silently select the inline runtime. The import binds to
    `_zbr_rt` (not `_rt`) — the mode adds a file-scope name to every emitted program, which
    is exactly the BUG-220 hazard, and `_zbr_` is already the reserved prefix for it.
    Gates 9/9, including a round-trip where **selfhost-B is built from selfhost-A's split
    emit and reproduces it byte-identically** — the compiler bootstraps itself through the
    new runtime.
  - [ ] **Residual work, in priority order:**
    1. **~70ms per emit vs the inline runtime** (hello-world ~120ms vs ~52ms; smoke 213s vs
       187s baseline). `96c09b2` cached the render and the name scan, taking the regression
       from 3.6x to ~1.15x on the suite, but the caches do NOT help a single-module program —
       each is populated and used once. What remains is one render, one 3,767-line scan, and
       one 186 KB read-and-compare per emit. **Needs instrumentation, not another guess**;
       the read-and-compare is the first thing to attack (it exists only to narrow the
       concurrent-write window on the shared temp path, which `--output-dir` avoids).
    2. **Cover the fallback paths**: `pub`-mark `gui_tui_section.zig` (89 decls) and
       `gui_libui_ng_section.zig` (102) for the GUI backends; decide the node-addon story.
       Until then those emit the inline runtime, guarded by `runtime_module_check.sh`.
       **No longer a correctness gap** — BUG-221 was closed on the inline path too
       (2026-07-29), so the fallback shape is merely *older*, not *broken*. It had been
       live there: the fixture segfaulted under `--no-runtime-module` because the fan-out
       walked direct `use` decls; it now sweeps the same transitive list. Both shapes are
       gated.
    3. The design note's claim that this "closes BUG-220 completely including the `@export`
       residual" is **unverified** — `@export` is a class-factory annotation here, so the
       obvious repro does not exercise it. What IS demonstrable: the emitted file's scope
       holds only the *referenced* subset of the runtime's 399 names, a strict subset of the
       inline path's, so collisions can only decrease.

- [x] **#3 — Move nil-narrowing into the TypeChecker. DONE 2026-07-28 (`81501dc`).** Narrowing
  was codegen-only (the BUG-188 note in `genMemberCall`): `inferExpr` still reported `?T` inside
  `if x != nil`, so the type checker and codegen disagreed about what was known. The cost was
  user-visible — the same mistake got a Zebra diagnostic with a caret outside a nil-check and a
  raw Zig error with no column inside one. `InferCtx.scope` is flat, so the then-branch saves and
  restores the original type; four of the six cases in `test/nil_narrow_tc_test.zbr` exist to
  prove the restore works, because a leak would produce FALSE errors on valid code rather than a
  missing one. Detection mirrors CodeGen's `nilCheckedIdent` exactly so the two cannot drift.
  Gates: 7/7 full.

- [ ] **#5a — Stdlib arity/signature checking.** The BUG-215 class: `indexOf(a, b)` silently
  discarded its second argument, turning a typo into a runtime panic three frames away. Today
  only `indexOf` is guarded, via `@compileError`. The real fix is a stdlib signature table in the
  front end so arity errors become proper Zebra diagnostics with a source location.

  **Groundwork done 2026-07-28 — read this before starting, it rules out two approaches.**
  1. **Deriving arities from CodeGen is UNSOUND.** Scanning each `if mname == "X"` block for the
     highest `args.at(N)` it reads gives 292 method names but wrong numbers — it reports
     `addDays 0`, `abs 0`, `ceil 0`, because codegen reads arguments through several idioms
     (`genArgList`, loops, helpers) an AST-free scan cannot see. A wrong table produces FALSE
     errors on valid code, which is worse than no table. Do not revive this.
  2. **QUICKSTART's documented signatures are a good source, and 42 of 45 string methods
     validate against the compiler** (script: build a call at the documented arity, run `-c`).
     But the section is not receiver-uniform — `join` is documented under "String method
     reference" while being a `List` method (`parts.join(", ")`), which my first validator
     mis-reported as a doc bug. **Any signature table or doc-checking gate must carry the
     receiver KIND per row, not assume it from the section heading.**
  3. Real finding from that pass, already fixed: `chars()`/`bytes()` were documented as
     returning `List(char)`/`List(int)` but are **`for`-only iterators** — `for c in s.chars()`
     compiles, `var cs = s.chars()` does not.

  **Recommended shape:** a table keyed by *(receiver kind, method name) -> arity*, consulted by
  the TypeChecker only where the receiver type is KNOWN (unknown receiver -> no check, so an
  inference gap can never manufacture a false error). Pair it with a gate that, for every table
  row, compiles a call at the declared arity — so a wrong entry fails loudly at gate time
  instead of silently breaking users. That gate is the artifact worth having; it also
  doubles as a doc-vs-implementation check for the language reference, which is how the
  `chars`/`bytes` inaccuracy surfaced.

- [ ] **#5b — Spans on all AST nodes.** `AstBuilder` uses `zspan()` for 95 of its node kinds.
  Measured impact is *narrower than first claimed* (17 corpus diagnostics carry locations, 0 land
  at `0:0`; the only reproducible case is a two-literal concat), so this is a cap on how good
  diagnostics can get, not a present emergency. Do it when it blocks something.

- [x] **BUG-142 — arity is a hard ERROR. CLOSED 2026-07-31 (Sean's call).** Too few AND
  too many arguments now reject instead of warning. Unblocked by BUG-235: the promotion
  was gated on a corpus baseline that turned out to be five weeks stale, and two scans
  returned a confident "0 too-few" that was a broken instrument rather than a clean
  corpus. Regenerating the corpus and adding a control produced the real number — 28
  too-few lines / 19 files, and exactly **1** too-many site in 1,581 files, which is why
  splitting the promotion by direction was worth doing even though both landed together.

- [ ] **#2 — Typed error sets. STRATEGY DECIDED 2026-07-29: declared-only, opt-in.**
  `def parse(s: str) throws ParseError` declares an explicit set; a bare `throws` keeps
  meaning "anything". Migration is therefore per-function and nothing breaks on day one.
  **Inferred sets were considered and rejected**: they are more ergonomic, but a new
  failure mode added to a leaf function would silently change the signature of callers
  several modules up, which is exactly the invisible-ripple behaviour a contracts
  language should not have. A function should state what it promises. Original framing: Errors are stringly-typed:
  `raise "division by zero"`, caught as `e.message`, everything `anyerror!T`. A caller cannot
  know which errors a function raises, cannot handle them exhaustively, gets no compiler help
  when a new failure mode is added, and breaks silently when someone rewords a string. This is
  the one place Zebra is **less typed than the Zig it compiles to** (Zig has error sets; we
  flatten them). In a language whose differentiator is Eiffel-style contracts — careful machinery
  for stating what must hold going in and out — leaving "what can go wrong" untyped is the
  design's biggest internal inconsistency. Sketch: `def parse(s: str) throws ParseError` with
  exhaustive `catch`. Design space includes declared vs inferred sets, subtyping/widening, and
  migrating every existing `raise`.

- [ ] **#4 — A check mode that actually checks. STRATEGY DECIDED 2026-07-29: fast default
  + `--check-full`.** `-c` becomes front-end-only (~62 ms where the front end can answer);
  `--check-full` keeps today's full `zig build-exe` pass. The IDE Check button is the
  dominant caller and that is the difference between live feedback and a pause.
  **Non-negotiable part of this decision:** the asymmetry must be NAMED in `--help` —
  a fast `-c` can pass on code that `zebra run` then fails to build, and a check whose
  limits are undocumented is the same class of problem as a gate that cannot fail.
  Best sequenced after #5a, which raises what the front end can answer. Original framing: `zebra -c`
  runs a full `zig build-exe`. A check that stops after typecheck would be **~0.06 s instead of
  5.2 s** — 90x on the compiler's most-run command, and it would make the IDE Check button
  instant. The strategy question is what `-c` should *promise*: front-end-only (fast, misses
  emit/codegen bugs only `zig` catches) versus today's full build (slow, total). Plausible answer
  is both — a fast default plus an opt-in `--check-full` — but that contract is worth agreeing
  before building. The FREE WIN above is independent and can land first regardless.
---

**Where things live** — this file is one of five; see [NEXT_STEPS.md](../NEXT_STEPS.md)
for the map.

| file | answers |
|---|---|
| [docs/PRINCIPLES.md](PRINCIPLES.md) | how do we decide? |
| [docs/archive/FINDINGS.md](FINDINGS.md) | what do we already know? |
| [NEXT_STEPS_to_0.9.md](../NEXT_STEPS_to_0.9.md) | what is next, before public release? |
| [NEXT_STEPS_to_1.0.md](../NEXT_STEPS_to_1.0.md) | what is next, before the freeze? |
| [NEXT_STEPS_post_1.0.md](../NEXT_STEPS_post_1.0.md) | deliberately deferred past 1.0 |
