<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-663. Next new bug: BUG-664.**

> **Numbering correction 2026-08-05.** Two different bugs were both filed as
> BUG-260 by sessions working in parallel. The query-param one below was filed
> first (`5717d80`) and keeps the number; the C-dependency one was filed later
> (`fcd9c7c`) and is **renumbered BUG-261**. Commit `fcd9c7c`'s message still
> says "BUG-260" — that is the record of what was written at the time and is
> left alone; look for BUG-261 in the ledgers.
>
> No gate could see this: `doc_lint` D4 only checks that a cited BUG-NNN exists
> *somewhere*, so a duplicate satisfies it twice over.

> ### FILING PRACTICE — read this before adding an entry
>
> **1. Leave the workaround in the CALLING code, with the bug number beside it.**
> A bug report says what broke. A workaround comment says what the author did
> *instead* — and that is the measurable cost of the defect, in a form nothing else
> captures. Receipt (2026-08-26): three entries in `C:/Projects/tinylm`'s Zebra sources
> — BUG-311, BUG-312 and one unfiled quirk — recorded that the author could not return a
> tuple of containers, could not share a generic `matvec` helper, and could not put
> functions in a class. Reading those three comments established in minutes that the
> code's whole shape was dictated by our defects rather than chosen, which no amount of
> reading the ledger would have shown. Prefer `# BUG-NNN: <what I had to do instead>`
> next to the distorted code.
>
> **2. A workaround also dates the defect's cost.** When the bug is fixed, the comment
> is the test: remove the workaround and see whether the natural form now works. Without
> it nobody knows which code was bent, so nobody straightens it and the tax is paid
> forever.
>
> **3. Reproduce before filing, and say so if you could not.** The same session tried to
> file that third quirk and *could not reproduce it* — top-level `def` and `static def`
> both mutated a list parameter correctly, nested `List(List(float))` included. It was
> NOT filed. An unreproducible entry costs a future reader more than a missing one, and
> "I could not reproduce this, here is exactly what I tried" is a legitimate thing to
> write in the ledger.
>
> **4. Measure both build modes for anything touching memory or arithmetic.** Every gate
> here builds Debug. BUG-313 is invisible in Debug and silently fabricates a value in
> `--release`; BUG-228 shipped Debug binaries from `--release` for four days under 19
> green gates. If an entry claims a safety property, it must say which mode it was
> measured in.

---

### BUG-295: a module import CYCLE builds cleanly and produces a compiler that STACK-OVERFLOWS — ⚠ HALF FIXED (diagnostic landed 2026-08-18; the overflow is still unexplained)

> **THE "NO DIAGNOSTIC" HALF IS CLOSED.** A cycle is now REPORTED, with its full path
> and the rule spelled out, and the corresponding `smoke_warn` fixture pins the message:
>
> ```
> warning: import cycle: t_a -> t_b -> t_c -> t_a
>   a module in a cycle is compiled ONCE and the first import wins, so
>   the second module sees a PARTIAL view of the first. That is well
>   defined for functions and types and UNDEFINED for module-level state:
>   no initialisation order satisfies both directions.
>   fix: move the names they share into a third module that both import.
> ```
>
> **THE MECHANISM IS SEAN'S, AND IT IS A REFINEMENT RATHER THAN A REPLACEMENT.** His
> framing: keep a set of imported modules and ignore later imports — *"first import
> wins"*, made explicit. `compileDep`'s `visited` set ALREADY did exactly that, which
> is why the compiler never hung; the missing piece is that one set conflates two very
> different skips — a module already FINISHED (a diamond dependency, benign, the common
> case) and a module still IN PROGRESS (the cycle). An in-progress stack separates them
> and carries the path for free, because the stack IS the chain. The dedup was not
> touched.
>
> **It WARNS rather than refuses** (Sean's call): a cycle is undefined rather than
> wrong, so the honest move is to say so and decide after watching it fire on real
> code. `MultiCompiler.cycle_is_error` flips it in one line — **both directions were
> verified before shipping**, because an untested switch is exactly the kind of
> affordance that is wrong when someone reaches for it: error mode exits 1 on a cycle
> and does NOT refuse a diamond.
>
> **THE NEGATIVE CONTROL IS THE LOAD-BEARING FIXTURE.** `bug295_diamond_test` imports a
> leaf from two parents, so it is skipped on its second visit by the same code path a
> cycle re-enters. It must compile SILENTLY; a detector that fires on the most ordinary
> shape in a dependency graph gets suppressed wholesale rather than read.
>
> **PART (b) LANDED 2026-08-18 — the DIAMOND note, and the measurement changed it.**
> Sean asked for two things: that a shared leaf be imported once, and an
> end-of-compilation warning naming shared modules with their side-effect risk.
>
> **(a) needed no change, which is the more useful answer.** The leaf is already
> compiled once (`visited`) AND its initialiser runs exactly once before `main` — the
> root emits one `_initModuleVars()` per entry of a DEDUPLICATED transitive list.
> Measured with a leaf whose initialiser prints: one line, not two.
>
> **(b) says something different from what it would have said unmeasured.** The
> plausible warning is *"a shared module may be initialised more than once"*. That is
> FALSE, per the above, and shipping it would have put a confident wrong claim in the
> compiler's own voice and sent a reader hunting a bug that does not exist. What is
> TRUE is the sharing: a probe bumped a leaf's counter twice through one importer and
> read **2** through the other. One instance, shared — the direct consequence of
> "first import wins".
>
> ```
> note: 1 module(s) imported by more than one module AND declaring module-level state:
>   p_leaf — imported by p_left, p_right
>   their state is ONE instance shared by every importer, not a copy per
>   importer: a mutation through one is visible through the others. Each is
>   initialised exactly once, before main.
> ```
>
> **SCOPED TO STATEFUL MODULES, or it would be a wall.** Most modules in a healthy
> graph are shared; `Ast` is imported eight times by the selfhost. A module with no
> top-level `var` has no instance to share, and the set is DERIVED from the AST rather
> than guessed. Real-world check: **the selfhost compiling ITSELF is silent** — and
> silent for the right reason, which was verified rather than assumed, since "correctly
> scoped" and "detection is broken" look identical from outside: `CodeGen` has 14
> top-level vars and exactly one importer per compilation (`codegen_test` and
> `pipeline_test` are separate programs).
>
> **One edge case that had to be right:** import edges are counted at the RESOLUTION
> site, before `compileDep`'s already-visited early return. The imports that get
> SKIPPED are precisely the ones that make a module shared, so counting only first
> visits would have reported no diamonds ever.
>
> ---
>
> ### DECISION 2026-08-18: HOLD AT WARNING. Do not promote to a refusal yet.
>
> Sean's call, after walking the user experience of both modes. The analysis below is
> recorded in full so the question does not have to be re-derived.
>
> **THE VENDORED-DEPENDENCY CASE IS WHY.** A refusal has to be actionable, and
> *"move the names they share into a third module"* is not advice a user can take about
> code they do not own. Measured — the two dependency routes behave oppositely:
>
> | vendoring style | route | cycle detected? |
> |---|---|---|
> | `--module-path lib` | `scanDepForTypes` → **returns before `compileDep`** | **NO** — 0 reports |
> | copied into the tree (adjacent files) | `compileDep` | **yes** |
>
> **THE `--module-path` EXEMPTION IS ACCIDENTAL, NOT DESIGNED**, and that is the part
> most worth remembering. Those deps escape because they are parsed for TYPES ONLY and
> never compiled — not because anyone decided vendored code should be unjudged. It
> reverses silently the day module-path deps are made to compile properly. Both new
> diagnostics are blind there: a vendored stateful shared module gets no diamond note
> either.
>
> **THE DANGEROUS CASE IS VENDORING BY COPYING INTO THE TREE**, which is how people
> vendor in a language with no package manager. Those files are adjacent, so they are
> compiled, so a cycle among them IS detected — and under refusal that is a wall the
> user cannot climb without forking someone else's library and losing the patch on the
> next update.
>
> **PRECONDITIONS FOR PROMOTING TO A REFUSAL** — all three, not any one:
>
> 1. **An escape hatch that prices the workaround.** `--allow-import-cycles`, modelled
>    directly on `--allow-implicit-try`: §28b made implicit error propagation a hard
>    error and shipped exactly that flag ("accepts the old implicit form for one
>    release"). This repo has already solved this shape once; copy it.
> 2. **A DIFFERENT MESSAGE when the user does not own the cycle.** If every module in
>    the cycle sits under `--module-path` or a vendor directory, the actionable advice
>    is *report upstream, or pin around it*, plus the flag — not "extract a module".
> 3. **Close or deliberately document the `--module-path` blind spot.** Preferably make
>    it WARN (so you learn your dependency has a cycle) and never error. Leaving it as a
>    side effect of type-scanning is the kind of unchosen behaviour that becomes a
>    surprise later.
>
> **UX, captured from real runs so it need not be re-run:**
>
> | mode | what the user gets |
> |---|---|
> | **warning** (ships) | both diagnostics print; the program **builds and runs** |
> | **refusal** (`cycle_is_error = true`) | same text with `error:`, stops there, **exit 1** |
> | after taking the advice | extracting the shared name into an import-free third module **clears it** — verified by doing it, still in refusal mode, program ran |
>
> **One asymmetry worth knowing:** in refusal mode the DIAMOND note never prints,
> because the compile aborts at the cycle before reaching end-of-compilation. The two
> diagnostics are not both visible on a failing build.
>
> **And the warning is doing real work right now**, which is the honest argument for
> holding: the `config ↔ logger` transcript used to evaluate this is a program that
> compiles and runs correctly today. Refusing it would break a working build over
> something Zebra cannot yet say what is wrong with. Promote when module-level state in
> a cycle gets a defined answer — or gets forbidden — not before.
>
> **WHAT REMAINS OPEN:** (0) the `--module-path` blind spot — a cycle wholly inside a
> vendored tree is invisible to BOTH new diagnostics, and closing it at WARNING level
> is small, decoupled from the refuse/allow decision, and was offered but not done.
> (1) the stack overflow itself is still unexplained — see the
> refuted hypothesis and three failed reproductions below — and this diagnostic makes
> the cycle VISIBLE without making it SAFE; if the overflow's cause also affects acyclic
> code, the warning hides nothing but fixes nothing either. (2) whether to promote the
> warning to a refusal, which is a language-semantics decision. (3) the adjacent finding
> that a cycle carrying a class type mis-boxes (`expected 'Ctx', found '*Ctx'`).

- **Severity:** Medium — no wrong answers, but the failure mode is a silent crash with
  no message naming the cause, and the construct is accepted all the way through the
  build.
- **Status:** OPEN. Not pinned by a fixture — see "why there is no fixture" below.

**Found 2026-08-17** while placing `collectOldNodes` for BUG-292. The TypeChecker
needed a traversal that lives in `CgHelpers`, and `CgHelpers` already imports
`TypeChecker` (`InferCtx`, `Type_`, `inferExpr`), so the import would close a cycle.

**A two-module cycle works.** Probed first, deliberately:

```zebra
# a.zbr                          # b.zbr
use b exposing helperB           use a exposing helperA
def helperA(n: int): int         def helperB(n: int): int
    return n + 1                     return helperA(n) + 10
def main()
    print("a=${helperB(1)}")
```

prints `a=12`. So cycles are not rejected, and nothing warns.

**At compiler scale the same construct produces a broken binary.** Adding
`use CgHelpers exposing collectOldNodes` to `selfhost/TypeChecker.zbr` regenerates and
builds with no error, and the resulting `zebra.exe` dies on hello-world:

```
Stack overflow (no address available)
```

**ISOLATED, not inferred.** The first attempt carried a new check as well, so the
obvious suspect was my own code. Adding the bare `use` line **with zero call sites**
reproduces it exactly. The import alone is sufficient.

**MECHANISM UNKNOWN, AND THE FIRST HYPOTHESIS IS NOW REFUTED.** This entry originally
guessed module-init: emitted modules call each other's `_initModuleVars()`, and a cycle
there would recurse forever — which would also explain why the toy passed, since
neither toy module had module-level state. **Tested 2026-08-18; it does not hold.**

Three minimal cycles were probed and NONE reproduces the stack overflow:

| probe | shape | result |
|---|---|---|
| functions only | mutual `def` calls | prints `a=12` |
| **+ module-level state on both sides** | the module-init hypothesis, directly | prints `a=12` |
| carrying a TYPE across the cycle | `use ... exposing Ctx, helperA` | a DIFFERENT error: `expected type 'Ctx', found '*Ctx'` (class auto-box across the cycle) |

So whatever produces the overflow needs something the toys lack — scale, or a specific
construct in the TypeChecker/CgHelpers pair. The third probe is its own small finding:
a cycle carrying a class type mis-boxes, which is not this bug but is adjacent.

**Recorded as unknown on purpose.** A tidy cause this has not earned would be worse
than none, and the reproduction attempts are the useful inheritance: do not re-run
these three.

**What IS established:** the compiler's own traversal does not hang — `compileDep`
guards on a `visited` list, so each module is compiled once. The failure is entirely in
the PRODUCT: the built `zebra.exe` was fine to produce and crashed when run.

**Why there is no fixture.** Any fixture would be two `.zbr` files that build a
compiler-scale cycle, and the failure is a stack overflow in a BUILT BINARY rather
than a compile error — nothing in the corpus harness runs that shape. The cheap
version (the toy above) PASSES, so it would pin the wrong thing. The honest pin is a
refusal: see below.

**Suggested fix — refuse, don't repair.** The front end knows the module graph after
`use` resolution, so a cycle is a 62 ms check. `error: import cycle: TypeChecker ->
CgHelpers -> TypeChecker` naming the path is worth far more than making cycles work,
and it is the UNGIT-shaped answer: the system knows, so it should say. If cycles are
later wanted deliberately, the refusal is the place to relax.

**Workaround, and it is what BUG-292 shipped:** put the shared code in a module both
sides can import without closing a loop — `selfhost/AstWalk.zbr`, which imports `Ast`
and nothing else.

**REPRODUCTION ATTEMPTED 2026-08-30 — REPRODUCES, BUT NOT AS FILED, AND NOT SILENTLY.**
Two three-module cycles built and run:

| cycle contents | result |
|---|---|
| functions only | warns `import cycle: zz_a -> zz_b -> zz_c -> zz_a`, **builds and runs correctly** (printed `6`, the right answer) |
| carrying MODULE-LEVEL STATE | warns, then **FAILS to compile**: `zz_c.zig:13:12: error: unable to resolve comptime value` |

That matches the warning's own text — well defined for functions, undefined for
module-level state — so the diagnostic is accurate about its own scope.

**The title's claim is now wrong in the useful direction.** It does not "build cleanly and
produce a compiler that stack-overflows": it warns, and then fails loudly. **Reclassified:
not a silent-wrong-answer bug.** What is left is a LEAKED ZIG DIAGNOSTIC — `unable to
resolve comptime value` is Zig's message about our emitted code, with no Zebra-level
explanation and no source position in the user's `.zbr`. That is a real defect and a much
smaller one.

**Found alongside, and filed separately as BUG-324:** the failed compile still leaves a
runnable `.exe` that segfaults with no output.

**RE-PROBED 2026-10-28 -- BOTH LEAKS ARE GONE; neither reproduces on `a549b29`.** Five
probes, every one warning about the cycle and then building and printing the right answer:

| cycle (zz_a -> zz_b -> zz_c -> zz_a unless noted) | printed | expected |
|---|---|---|
| module-level state on all three sides, read locally | 112 | 2 + 10 + 100 |
| `zz_c` reads `zz_a.count` across the cycle | 114 | 2 + 10 + 100 + 2 |
| `zz_c`'s INITIALISER reads `zz_a.count` | 113 | 2 + 10 + (1 + 100) |
| two-module cycle carrying a class (`exposing Ctx, helperP`) | 11 | 5 * 2 + 1 |
| ... the other module constructs, rebinds and returns the class | 22, 9 | 12 + 10; 9 |

So the 2026-08-30 `unable to resolve comptime value` and the 2026-08-17 `expected 'Ctx',
found '*Ctx'` were fixed in passing by later work; which commit fixed them is not
established (none names them), and the probes here may not match the originals byte for
byte -- those files were not kept. The third row
is the shape the warning calls undefined, and it came out right only because the read ran
in the direction that happened to work. **That sentence originally said "defined in
practice", and it was wrong:** the other direction -- the DEPENDENCY's initialiser reading
the importer's computed var -- printed -6148914691236517205 (2026-10-28, `zz_b.bval =
zz_a.count + 1`). Dependencies initialise first, so a cycle has no eager order that works.

**THE MODULE-STATE HALF FIXED 2026-10-29 -- a cycle is a singleton (Sean's framing).** Each
module stays one instance, initialised once, and every module-level variable is set before
its first read: a computed one (`isDeferredModuleVar`) in a module on a cycle gets an
accessor, `_zbr_mvref_<name>()`, which runs its initialiser on first use, and every
reference -- the module's own, `mod.x`, an exposed `x`, reads and writes alike -- goes
through it as `_zbr_mvref_<name>().*`. The module's own init sweep forces the accessors
rather than re-assigning, so a write made by a partner's initialiser survives. An
initialiser that needs its own value is a genuine cycle: a frame list in the runtime names
the chain (`error: module initialisation cycle: b.y -> a.x -> b.y`, exit 1). With
`--no-runtime-module` each module has its own frame list, so the message names only the
variable and says the chain is unavailable. Cycle members are marked by the cycle report
(`$cyc:` in dep_types), which runs while every member is still in progress, so no member
is generated before it is known to be on a cycle. Modules not on a cycle emit exactly as
before; the compiler's own source has no cycle and only the edited modules' `.zig` moved.
Fixtures: `test/bug295_lazy_init_test.zbr` (every reference spelling, two writes that must
survive; the pre-fix compiler panicked "integer overflow") and
`test/bug295_init_cycle_test.zbr` (`smoke_run_fail`; the pre-fix compiler printed
-6148914691236517204). **Warn-or-refuse is decided: warn** (Sean, 2026-10-29), and the
warning now states the rule instead of calling module state undefined.
Also probed (not a fixture): a three-module cycle a -> b -> c -> a whose initialisers read
across it, plus a module OUTSIDE the cycle (imported by a and b) whose initialiser reads a
cycle member's computed var -- `30 33 64` as expected; HEAD panicked "integer overflow".
A static scan of the `use` graphs of this repo, zebra-ide and the GameEngine (10,662 files)
found no cycle outside the bug295 fixtures, so no existing program's emit moves. FULL tier
48/48 in one invocation.

**What remains open:** (0) the `--module-path` blind spot; (1) the compiler-scale stack
overflow, never reproduced below compiler scale; (3) a class's deferred `static var`
(BUG-649) in a cycle module is still assigned eagerly by its module's sweep, so a cycle
partner's initialiser that reads it reads garbage; (4) `--single-file` cannot build ANY
cycle -- zig: `use of undeclared identifier '_mod_<root>'` -- on HEAD before this change
too.


---

### BUG-289: two deterministic programs disagreed with themselves inside a full output_sweep — cause unknown

**Found 2026-08-15** during an `output_sweep --update-baseline`. `log_test` and
`refinement_type_test` were auto-excluded as nondeterministic and so dropped out
of behaviour coverage. Both are deterministic:

| check | result |
|---|---|
| built executable, 10 consecutive runs (`refinement_type_test`) | byte-identical, 12 bytes, rc=0 |
| built executable, 8 consecutive runs (`log_test`) | byte-identical, 178 bytes |
| through the harness's own `--show --only` path, 5 runs | byte-identical |

The disagreement appears **only** inside a full 354-file sweep. What the
exclusion records actually show is narrower than "truncation", and the
distinction matters because the wrong word sends the next reader chasing the
wrong mechanism: the recorded reason is a single `<` line — `0` for
`refinement_type_test`, `All log tests passed.` for `log_test` — meaning that
line was present in one sample and absent in another. Both happen to be the last
line of the recorded output, which is suggestive, but nothing here establishes
that the tail was cut rather than a sample differing some other way.

**The obvious explanation was tested and FAILED.** This repo has a documented
Windows hazard — stdout to a PIPE can lose writes, which is why `rebuild.sh` and
`mutation_check.py` both redirect to a file — and `output_sweep` captures with
`$(...)`, a pipe. Predicted: pipe capture truncates occasionally, file capture
never does. Observed: **12/12 identical through both.** The theory is recorded
here as eliminated, not as the answer.

Remaining candidates, none tested: interference from an earlier fixture in the
same sweep (a server or thread fixture outliving its `timeout`), console/handle
contention, or something about sustained sequential load.

**Mitigated, not fixed.** `output_sweep --update-baseline` now requires an
exclusion to REPRODUCE: three samples, and if they disagree, a three-sample
confirmation round; only a repeated difference excludes. A file that disagrees
once and is then unanimous is kept and reported as a `transient` in the run
summary. Both paths are control-tested (a clock-printing fixture must still be
excluded; a forced single disagreement must be kept). That converts this from
silent coverage loss into a printed number — but it does not explain the
underlying disagreement, and a rising transient count is the signal to come
back to this ticket.

### DESIGN-001: Throws auto-propagation scope — nested expression calls require `?`
- **Not a bug** — by design
- **Description:** Throws auto-propagation emits `try` for direct self-method calls and statement-level calls whose receiver is a `throws` method. It does NOT auto-propagate for:
  - `localVar.method()` — receiver is a local variable
  - `this.field.method()` — chained member access through a field
  - Calls nested inside compound expressions
- **Required action:** Use explicit `?` suffix for these cases: `localVar.method()?`, `this.field.method()?`

---

### DESIGN-002: `collectAndEmitOldSnapshots` (selfhost) missing `Expr` arms
- **Status:** Fixed — `selfhost/codegen.zbr` `collectAndEmitOldSnapshots`; `test/contract_old_compound_test.zbr` covers the `array_lit` case; 31/31 smoke, bootstrap 5/5.
- **Was:** `selfhost/codegen.zbr` `collectAndEmitOldSnapshots` fell through to `else: pass` for 8 compound Expr variants. An `old expr` nested inside any of these produced an undeclared-identifier Zig compile error: the `defer` block referenced `_old_N` but no snapshot was ever emitted.
- **Confirmed failing test:** `ensure val in @[old val, n]` — `old val` inside `array_lit` — produced `error: use of undeclared identifier '_old_0'` before the fix.
- **Fixed arms added:**
  - `array_lit` — iterate `elems`, recurse each
  - `list_lit` — iterate `elems`, recurse each
  - `tuple_lit` — iterate `elems`, recurse each
  - `dict_lit` — iterate `entries`, recurse `entry.key` and `entry.value`
  - `string_interp` — iterate `parts`; recurse only `StringPart.expr_` arms
  - `type_check` — recurse into `tc.expr`
  - `slice` — recurse `sl.object`; recurse `sl.start to!` and `sl.stop_ to!` if non-nil
  - `except_` — recurse `ex.base`; recurse each `f.value` in `ex.fields`
  - `lambda` — left as no-op (correct: `old` inside a lambda body is semantically unsound)
  - Leaf nodes — left as `else: pass` (correct: can't contain `old_`)
- **Note on slice optional fields:** `ExprSlice.start: ^Expr?` uses `!= nil` + `to!` (not `if x as s`) — consistent with the existing `genExpr` slice handling in the selfhost.
- **Files:** `selfhost/codegen.zbr` (`collectAndEmitOldSnapshots`), `test/contract_old_compound_test.zbr` (new), `tools/selfhost_smoke.sh` (new smoke entry).


---

### INFRA-001: --update non-idempotence on first run after certain bootstrap states
- **Not a bug** — cosmetic only; both output forms compile and round-trip correctly
- **Symptom:** The first `bash tools/bootstrap_check.sh --update` (or `zig build update-selfhost`)
  after a full bootstrap or manual `/tmp/bs-zig` copy can produce `selfhost/*.zig` files with
  the header `// Generated by the Zebra compiler.` (bootstrap style) rather than the expected
  `// Generated by zebra-selfhost.` (selfhost style). Subsequent `--update` runs are stable and
  idempotent on the selfhost-style output.
- **What to do:** If you see bootstrap-style headers after `--update`, just run `--update` once
  more. The second run will produce the correct selfhost-style headers and stay there.
- **Root cause (partial):** `codegen.zbr` line 808 (`generateFullWithDeps`) and line 831
  (`generateDepWith`) both emit `"// Generated by zebra-selfhost.\n"`, so selfhost-A should
  always produce selfhost-style output. The first-run anomaly may be a stale `zebra-selfhost.exe`
  binary that predates step 2's rebuild, or Zig build-cache reuse in step 2 that skips the
  recompile when source timestamps haven't changed. Not fully traced.
- **Where this is also documented:** Comment in `tools/bootstrap_check.sh` update-mode header.

---

