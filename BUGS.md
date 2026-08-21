<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-302. Next new bug: BUG-303.**

> **Numbering correction 2026-08-05.** Two different bugs were both filed as
> BUG-260 by sessions working in parallel. The query-param one below was filed
> first (`5717d80`) and keeps the number; the C-dependency one was filed later
> (`fcd9c7c`) and is **renumbered BUG-261**. Commit `fcd9c7c`'s message still
> says "BUG-260" — that is the record of what was written at the time and is
> left alone; look for BUG-261 in the ledgers.
>
> No gate could see this: `doc_lint` D4 only checks that a cited BUG-NNN exists
> *somewhere*, so a duplicate satisfies it twice over.

---

### BUG-302: the heavy PARALLEL gates fail one file per run at a low rate, and it never reproduces — THIRD occurrence, so it is now a finding — OPEN (2026-08-20)

CLAUDE.md has said since 2026-08-19 that a third occurrence "stops being a transient and
becomes the finding". This is the third.

| # | when | gate | file | verdict in-tier | verdict alone |
|---|---|---|---|---|---|
| 1 | 2026-08-19, `--daily` | `compile_check-inline` | `iter_collision_test` | 275 passed / 1 skipped | 1/1, then 276/0/0 on a full re-run |
| 2 | 2026-08-20, first `--daily` | `compile_check-inline` | `iter_collision_test` | 275/1 | 276/0/0 |
| 3 | 2026-08-20, `--full` | `divergence` | `contract_old_test` | `self=CFAIL`, 1 selfhost gap | 0 gaps via the harness's OWN `--only` path; emit+`build-exe` by hand also clean |

**THE SHAPE IS CONSISTENT AND THE FILES ARE NOT.** One file, one gate, inside a heavy
sweep at `JOBS=2`; passes immediately afterwards by every route including the gate's own.
Two different gates and two different fixtures, so it is not a property of either.

**WHY IT MATTERS MORE THAN ONE RED LINE.** These are the two gates whose whole job is to
be believed about the corpus. A gate that fails one file per run at a low rate teaches
people to re-run it, and re-running until green is precisely how a real regression gets
waved through. It also cost real time here: occurrence 3 was investigated as a suspected
regression from a same-day compiler change before it was shown to be nothing.

**RULED OUT:** a shared workdir. `divergence_check.sh` gives each worker its own
`$OUT/ws-<name>` / `$OUT/wb-<name>`, so two workers cannot collide on the emit directory.

**THE UNTESTED HYPOTHESIS, named so a later run can discriminate rather than re-argue.**
Both affected gates invoke `zig build-exe` from parallel workers, and every worker shares
ONE global Zig cache (`%LocalAppData%\zig`). The QUICK gates that never do this have never
shown the symptom. Contention on that cache — a lock timeout, or a partially-written entry
being read — would produce exactly this: a single arbitrary file failing, with no defect in
the file and nothing reproducible afterwards.

**The discriminating experiment, cheap and not yet run:** re-run one of these gates with a
per-worker `ZIG_GLOBAL_CACHE_DIR`. If the rate goes to zero, the cause is cache contention
and the fix is to give each worker its own; if it does not, the hypothesis is dead and the
next suspect is the emit step rather than the build step. Running at `JOBS=1` is the
cruder version of the same test.

**Do NOT "fix" this by adding a retry.** A gate that retries until green is the thing this
ledger exists to prevent. If the cause turns out to be cache contention, isolate the
caches; the failure should stay loud.

---

### BUG-301: `${expr:c}` works for a literal and fails for a RUNTIME int — no way to build a byte from a computed value — OPEN (found 2026-08-20)

```zebra
var b = "${206:c}"              # fine -- emits one byte, 0xCE
var n = hi * 16 + lo
var c = "${n:c}"                # error: expected type 'u8', found 'i64'
```

The `:c` spec on an `int` emits Zig's `{c}` (`printAsciiChar`, which takes a **u8**), and
codegen passes the Zebra `int` (`i64`) through unnarrowed. A literal coerces at comptime;
a runtime value does not, and the user sees a raw Zig type error against generated code.

**WHY IT MATTERS BEYOND THE ERROR MESSAGE.** `${n:c}` is the ONLY way to put an arbitrary
byte into a string, and byte assembly is what UTF-8-correct decoding needs — `%CE%B8` is
two bytes that together form one codepoint, so a percent-decoder must build bytes, not
codepoints. With this broken, a decoder can only handle values it can name as literals: in
practice a table over printable ASCII, leaving every `%XX` ≥ 128 undecodable. That is
exactly where the Graze decoder stopped (correspondence Entry 24), and it is why that
entry reads as "no int→char in reach" — the capability is there and unreachable from a
computed value.

**Where:** `bitCastType` (`selfhost/CodeGen.zbr`, and the bootstrap's twin) narrows the
argument for `x`/`X`/`o`/`b` and has no case for `c`. The existing cast emits
`@as(T, @bitCast(x))`, which is **invalid** i64→u8 — Zig requires equal bit widths — so
this needs a different cast kind, not just another entry in that table.

**AND THAT CARRIES A SEMANTIC DECISION, which is why this is filed rather than fixed:**
what should a runtime value outside 0..255 do?

| option | behaviour | precedent |
|---|---|---|
| `@truncate` | always defined, silently wraps | Go `byte(n)`, Rust `as u8` |
| `@intCast` | panics in Debug/ReleaseSafe — **UB in ReleaseFast**, which is what `zebra --release` ships | — |
| front-end refusal | rejects a statically-known bad literal; still needs one of the above at runtime | Python `bytes([n])` raises |

`@intCast` alone is the one to avoid: it puts undefined behaviour in the shipping
configuration, which is the hazard `tools/lint_oom_unreachable.py` exists to keep out.
Recommendation is `@truncate` plus a front-end refusal for a known-out-of-range literal —
but the semantics are Sean's call.

**Control when fixing:** a decoder that builds `θ` from `%CE%B8` with hex digits parsed at
runtime must round-trip, and `${300:c}` must do whatever the decision says rather than
whatever Zig happens to do. Note `:c` on a `char` value is a DIFFERENT path (it emits
Zig's `{u}`, the codepoint form) and must keep working — see QUICKSTART's note.

---

### BUG-300: BUG-244 HAS REGRESSED — every `zebra <file>.zbr` run leaks a ~20 MB executable into TMPDIR again — OPEN (found 2026-08-20)

`tools/runtime_module_check.sh` is RED on the committed tree:

```
FAIL  a successful run left 1 scratch file(s) in C:\Users\Sean\AppData\Local\Temp
```

**This is the exact bug `60fa160` closed on 2026-08-15** ("BUG-244: stop leaking a ~20 MB
executable into TMPDIR on every run"). The gate that pins it is in the QUICK tier and is
now failing, which is the system working — but the fix itself has stopped taking effect.

**What survives a clean run:** `hw.zig.fast.exe` (19,988,480 bytes) and `hw.zig.run.pdb`.
**What does not:** `hw.zig`. Both deletes sit in the SAME conditional
(`if rc == 0 and not keep_temp and output_dir == ""` — `selfhost/main.zbr`, the BUG-244
block), so the block RAN and `File.delete(zig_path)` succeeded while
`File.delete(fast_exe)` silently did not. `File.delete` cannot report failure, which is
why this is invisible without the gate.

**Measured, so the next person does not repeat it:**

| probe | result |
|---|---|
| 5 consecutive runs | leaked 5/5 — **deterministic, not a race** |
| the same 5 runs against a compiler built from **HEAD** with all local changes reverted | leaked 3/3 — **not caused by any uncommitted work** |
| `rm` from the shell immediately after the run | **succeeds** — the handle IS released by then |
| the same gate in the two `--daily` runs earlier the SAME DAY | **PASSED** |

**The last two rows are the whole puzzle and neither is explained.** The file is not
locked a moment later, so the compiler's `File.delete` is running while Windows still
holds the just-executed image — the classic delete-a-running-exe shape. But that would be
a race, and it reproduces 5/5; and the identical committed code passed twice within hours.
Something in the environment moved, and nothing here establishes what.

**Fix direction (untested):** deleting an executable immediately after `sys.exec_inherit`
returns is not reliable on Windows. A short retry with backoff, or deferring the unlink,
would make the existing BUG-244 logic robust instead of timing-dependent — and would hold
whether or not the environmental trigger is ever identified.

**Control when fixing:** `bash tools/runtime_module_check.sh` must pass, and the fix must
be watched going RED with the retry removed. Note the `.pdb` alongside: it is named for
the LLVM path (`.run.pdb`) although only the fast path ran, which nothing here explains
either and may be a thread to pull.

---

### BUG-299: a value-typed STRUCT is not auto-boxed into a `^Struct?` field, though a UNION is — OPEN (found 2026-08-20)

Assigning a struct VALUE to a `^T?` (nilable heap-indirection) field fails on BOTH
compilers, while the identical shape with a UNION payload works. Found while writing
BUG-124's regression pin, which needed a value-typed payload and started with both.

```zebra
struct Pair
    var a: int
    var b: int
    cue init(x: int, y: int)
        a = x
        b = y

struct PairBox
    var opt_pair: ^Pair?
    cue init(opt_pair: ^Pair?)
        .opt_pair = opt_pair

def makePairBox(x: int, y: int): PairBox
    var p = Pair(x, y)
    return PairBox(p)          # <- the struct value is never boxed
```

| compiler | line | message |
|---|---|---|
| selfhost | 15 (`return PairBox(p)`) | `error: expected type '?*T', found 'T'` |
| bootstrap | 11 (`.opt_pair = opt_pair`) | `error: expected type 'Pair', found '?*Pair'` |

**THE CONTROL IS WHAT MAKES THIS A BUG RATHER THAN AN UNSUPPORTED FORM.** The same
construction with a union payload — `union Val` in a `^Val?` field, constructed from a
value — compiles and runs on both compilers today; that is
`test/bug124_boxed_nilable_ctor_test.zbr`, which passes. So `^T?` auto-boxing exists and
works; it is the STRUCT payload that misses it.

The two compilers fail at DIFFERENT sites, which is worth noting before assuming one root
cause: the selfhost rejects the constructor ARGUMENT (the value never becomes a pointer),
while the bootstrap accepts the argument and rejects the FIELD ASSIGNMENT inside `init`
(it has a `?*Pair` where the field wants a `Pair`). They may be one gap seen from two
sides or two gaps; nothing here has established which.

The bootstrap additionally reports `local variable is never mutated` at the `cue init`
line for this probe. Recorded because it appeared, not because it is known to be part of
this defect.

- **Severity:** Medium — `^T?` is the documented idiom for an optional heap field, and a
  struct is the type most likely to want one. The workaround is a union or a class.
- **Control when fixing:** the probe above must compile and print, on BOTH compilers, and
  `test/bug124_boxed_nilable_ctor_test.zbr` (the union control) must keep passing. Add the
  struct half back to that fixture, where it was deliberately removed with a note.

---

### BUG-298: `gui_scaffold_check` reports "startup path clean" when the scaffold build produced NO app — leg 2 skips instead of failing — OPEN (found 2026-08-19)

Leg 2 of `tools/gui_scaffold_check.sh` runs the built app and classifies the startup
fault. When it cannot find an `app.exe` it prints

```
  --    leg 2: skipped (no built app.exe — leg 1 still gates the regression)
```

and the gate still exits 0 with `gui scaffold check: startup path clean`. **But "no
app.exe" has two very different causes and the gate cannot tell them apart:** the harness
genuinely not building one, and the build having FAILED. In the second case the gate
reports clean about a scaffold that does not exist.

**Observed, not hypothesised.** On 2026-08-19 the check reported `startup path clean`
while `zebra --gui-backend=tui examples/counter.zbr` was exiting 1 on

```
error: unable to read results of configure phase from
'…\Temp\counter_gui_tui\.zig-cache\tmp\16ce6e37c914cf04': FileNotFound
```

— a corrupted scratch cache in the temp scaffold root. Moving that directory aside made
the build work and produce `app.exe`, after which the app ran and refused a non-tty
console (rc=3), which is the documented healthy outcome. So the underlying tui path was
fine; what was broken was the gate's ability to say that it had not checked it.

**Leg 1 kept working throughout, and that is what made it look green** — it reads the
scaffolded `main.zig`, which a previous run had left on disk. A gate asserting against a
stale artifact from an earlier date is the shape this repo keeps re-finding.

**Why this matters more than one skipped leg.** `gui_scaffold_check` is the ONLY automated
GUI coverage in the repo — four GUI crashes have sat under fully green gates and all four
were at startup. Half of it silently not running returns that number to "no gate touches a
GUI".

**Suggested fix.** Distinguish the two causes: if the build exited non-zero for a reason
OTHER than the app's own non-tty refusal, that is a FAILURE, not a skip. The refusal is
already identified by leg 2's own classifier, so the information exists — it is just
consulted after the point where the skip has already been taken. A gate that cannot run
its runtime leg should say `INCONCLUSIVE` and exit non-zero, not `clean`.

**Control when fixing.** Corrupt or remove the scaffold's `.zig-cache` and confirm the
gate goes RED rather than printing `startup path clean`; then restore and confirm it goes
green with leg 2 actually running (rc=3, non-tty refusal). It is registered in the
`--daily` tier, so both states are observable there.

---

### BUG-297: `--target node-addon` emits an undeclared reference to the owning class for a STATIC-block export — OPEN (found 2026-08-19)

`zebra --target node-addon` on a `@node_export` inside a class `static` block emits a
reference to the class that is never declared, and the build fails on the compiler's own
diagnostic:

```
test/node_addon/math.zbr:31: error: use of undeclared identifier 'Calc'
```

**Isolated to the node-addon target, and to the class path specifically.** Three probes:

| probe | result |
|---|---|
| `zebra -c test/node_addon/math.zbr` | clean — the front end is fine |
| `zebra --target node-addon test/node_addon/math.zbr` | **fails as above** |
| the sibling fixture `strings.zbr` (no class) | passes |

The failing shape is the last block of `test/node_addon/math.zbr`, which exists to
exercise the `Owner.method` call path:

```zebra
class Calc
    static
        @node_export
        def square(n: int): int
            return n * n
```

**HOW IT WAS FOUND, which is the part worth keeping.** It was not found by a gate — it was
found by *wiring a gate*. `tools/node_addon_test.sh` was in NO tier: it sat under
CLAUDE.md's "run these deliberately" list, where its last recorded sweep is **2026-08-04,
PASS**. Nothing has run it since, so the regression's window is those two weeks and
nothing narrows it further. This is the same shape as BUG-279 (`zig build test` red, in
neither a tier nor the uncovered table) two days earlier, and the second instance is what
motivated the `--daily` tier rather than another reminder.

**It is PINNED, not excluded.** `gates.sh` registers it as
`pin_daily "node-addon" "BUG-297"`: it RUNS on every `--daily`, prints `XFAIL` with this
ticket, and does not fail the tier — but it **fails the tier the day it starts passing**,
so the pin cannot outlive the bug. Excluding it is what let it rot in the first place.

**Control when fixing.** `bash tools/node_addon_test.sh` must report every fixture ok
(`math` is the one to watch; `strings` and the negative `bad` already pass), and the
`pin_daily` registration must then become `run_daily` — the tier will say so loudly if it
is forgotten. Worth adding a class-static fixture to the node-addon set at the same time:
`math.zbr` is currently the only file covering that path, which is why one regression took
the whole gate red.

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

### BUG-103: TC `extractFromDecls`/`extractFromMembers` silently skip unknown declaration variants

> **Triaged 2026-08-17 — KEPT OPEN pending a pin, not because it is believed broken.**
> The body below says *Closed — fixed 2026-05-06*, and `lint_stale_bugs` flagged it. The
> defect only triggers on adding a NEW `Ast.Decl` variant, so it cannot be expressed as a
> Zebra program at all — no fixture can exist in the current harness, and the evidence is
> the annotation plus the source, never a run. **Close it only alongside something that
> can fail**: the natural pin is a check that every `Ast.Decl` variant is handled, in the
> shape of `lint_expr_walkers` (whose oracle is `Ast.zbr` itself).
- **Severity:** Low (only triggers on adding a new `Ast.Decl` variant; latent reliability hazard)
- **Status:** Closed — fixed 2026-05-06
- **Resolution:** All 4 `else => {}` catch-alls in the metadata-collection passes replaced with fully exhaustive arms listing every `Ast.Decl` variant explicitly. Adding a new `Ast.Decl` variant now causes a Zig compile error at all 4 sites (same guarantee `checkTopDecl` already had). Behavioral change: none — all new arms are `{}`. Bootstrap 5/5, smoke 44/44, full test suite.
  - `extractFromDecls` (4 new arms: `.use`, `.interface`, `.mixin`, `.extend`, `.sig_`, `.var_`, `.init`)
  - `extractFromMembers` (10 new arms: everything except `.method`, `.var_`, `.init`)
  - `collectExtMethodsInDecls` inner switch (extend members: 12 new arms)
  - `collectExtMethodsInDecls` outer switch (top-level decls: 11 new arms)
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-1]).

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

### BUG-281: SEVEN emit families print Zig keywords bare — SIX closed, G open (bootstrap-only)
<!-- bug-open-ok: six of seven families are closed and pinned by test/bug280_keyword_idents.zbr; G is bootstrap-only and the selfhost is immune to it for free -->

**STATE 2026-08-13.** A (`@derive` bodies), C (capture read), D (enum members, union
variants, switch prongs and construction) and F (bare field read in a method) are fixed
in **both** compilers. **B (the type name) and E (a method name) are fixed in the
SELFHOST** — B by prefixing (option 2 below, Sean's call), E by escaping. All six are
pinned by `test/bug280_keyword_idents.zbr`, which is registered with `smoke_run`; each
set of shapes was added there and `keyword_ident_check.sh` was **watched going red on
them before the fix and green after**. Only G (a top-level fn name) remains, it is
**bootstrap-only**, and the selfhost is immune to it for free because `_zbr_fn_` already
prefixes those — so G disappears when the bootstrap is retired and needs no work.

**B AND E ARE SELFHOST-ONLY, AND E's HALF WAS A DECISION RATHER THAN AN OVERSIGHT.**
Fixing E in the bootstrap is genuinely cheap — the same `emitName` routing. It was not
done, for two reasons that only apply together: the bootstrap is the **regen authority**,
so a mistake there corrupts every `selfhost/*.zig`, and `test/bug280_keyword_idents.zbr`
can no longer gate it (the file now contains a keyword-named class, which the bootstrap
cannot emit since B). An ungated change to the regen authority, for a compiler being
retired, in a family that is *already* half-broken there because of B, is a poor trade.
It costs nothing today: the selfhost source has no keyword-named method, so the bootstrap
still compiles it. It costs a **GUI** user with a keyword-named method, since
`--gui-backend=*` delegates to the bootstrap — and such a user is already blocked by B.

**WHY E TOOK ESCAPING AND B TOOK A PREFIX — the rule, not a preference.** A method is
namespaced inside its type, so it cannot collide with anything at file scope; escaping is
sufficient and `@"align"` is the same identifier to Zig as `align`. A type name IS at file
scope, which is what made the prefix worth its cost. The same test tells you which tool a
future family needs.

**THE SITE COUNT WAS 5, AND FOUR OF FIVE CAME FROM THE GATE.** Reading found the public
wrapper's declaration. The gate named the static declaration, a bare sibling call
(`self.align()`, a different path from `obj.m()`), and both member-call dispatches — and
the second dispatch is the one worth remembering: `genMemberCall` has an **early**
user-method path that fires whenever inference knows the receiver's class, which is the
common case, so fixing the *default* path left every resolved call bare and the gate red
in exactly the same place. One `emitName` in `topLevelFnZigName` covers `main` and every
`@export` fn at both ends at once, because declaration and reference both go through it.

**B'S LANDING — WHAT THE DERIVED SITE TABLE DID NOT CONTAIN.** The five-cluster table
below was derived from the probe, and every cluster in it was real. It was also
**incomplete, by exactly the property that produced it**: a probe can only name shapes it
contains. Nine further sites came from two witnesses the probe cannot be:

| witness | what it found |
|---|---|
| **the level-2 round-trip** (`bootstrap_check.sh`, steps 3–4) | `StrSet.init()`, which is HARDCODED in three places because `StrSet` is spelled like a stdlib container yet is an ordinary Zebra class in `CgHelpers.zbr`; and `Parser.Parser.parse()`, where a module ALIAS shares its name with a class it declares, so `class_names` reports the namespace as a type |
| **`selfhost_smoke`** (11 red, then 1) | interface vtable shim bodies; the `@export` singleton factory; the `^T` heap-box `create(T)` in four places; a no-payload union value; and `field_not_found_test`, which caught a **user-facing leak** rather than a compile error |

Nothing in `test/*.zbr` reaches the first two — they need the compiler's own cross-module
code, which only the round-trip compiles. **Run the round-trip early on a change like
this, not last.**

**A METHOD NOTE THAT COST A 17-MINUTE CYCLE, recorded because it will recur.** This was
run by hand:

```bash
bash tools/rebuild.sh --module CodeGen 2>&1 | grep -E "^rebuild|error" | head -3 \
  && bash tools/selfhost_smoke.sh
```

A pipeline's exit status is its LAST command, so `head`'s success gated the `&&`.
`rebuild.sh` had in fact refused — correctly, because `selfhost/main.zbr` was modified and
not named in `--module` — and `smoke` then measured the OLD compiler for a full cycle and
reported a confident 328/1. The refusal it printed was three lines above the `head -3`
cut. `hazard_lint` cannot see this: it scans `tools/`, and no committed script does it
(checked). **Redirect to a file and check `$?` explicitly** when chaining a build into a
gate; `| head` in front of `&&` throws the answer away.

**THE LEAK IS THE FINDING WORTH KEEPING.** `_zbr_ty_` is internal, but `zig` quotes it
back: `no field named 'y' in struct '_zbr_ty_P'`, against a program whose author wrote
`struct P` and has never seen the prefix. That is UNGIT "nothing fabricated" — a spelling
presented as the user's own. `selfhost/main.zbr`'s `humanizeZigTypes` already existed for
exactly this purpose (it maps `[]const u8` back to `str`) and now strips the prefix too.
**`_zbr_fn_` and `_zbr_mv_` leak the same way and still do** — same one-line fix, left
alone because moving those messages is not this change's business.

**Not done, and named so it does not read as covered:** `src/CodeGen.zig`. Selfhost-only
under the standing rule — the bootstrap still COMPILES the selfhost source, because no
`.zbr` class was renamed. The cost is one new bootstrap gap
(`test/bug280_keyword_idents.zbr`), informational in `divergence_check`.

**Found 2026-08-11** finishing BUG-280's selfhost half, by a four-line probe rather than
by reading. BUG-280 fixed the field/constructor/member/literal paths in both compilers
and its gate reports clean. **The bootstrap is broken in all of these too** — so this is
not a selfhost gap, and `divergence_check` will not see it.

**FILED AS THREE FAMILIES; A WIDENED PROBE FOUND SEVEN.** The first version of this entry
listed A, B and C, derived from a probe that exercised `@derive`, a keyword-named class,
and a capture block. Adding a keyword as an enum member, a union variant, a method name,
a top-level function name and a bare field read inside a method — all legal Zebra
identifiers today — turned up four more in a single emit. That is the same ratio as
BUG-280 (reading found 4 of 9; a probe found 9), arriving immediately after the lesson
was written down. **The probe is the map. Widen it before believing a family count.**

| | family | bootstrap | selfhost |
|---|---|---|---|
| A | `@derive` bodies — `self.<field>` in toString/eql/hash | broken | broken |
| B | the type NAME itself — `pub const opaque = struct` | broken | broken |
| C | a capture READ in a lambda body | broken | broken |
| D | enum members and union variants | broken | broken |
| E | method name — declaration AND call site | broken | broken |
| F | bare field read inside a method (no `.` prefix) | broken | broken |
| G | top-level function name | **broken** | **OK** |

**G is the interesting one, and it points at the cheap general fix.** The selfhost emits
`pub fn _zbr_fn_anyframe()` while the bootstrap emits `pub fn anyframe()`. The selfhost is
immune *for free*, because the prefix already makes the name collision-free — exactly the
reasoning that governs `_zbr_mv_` for module vars and `_ttag_`/`_reflect_` for type tags.
Wherever a name is already prefixed, this whole bug class cannot occur.

**Note also what D, E and F share with C:** in each, a name is escaped at one end and bare
at the other, so the emitted Zig is internally inconsistent rather than uniformly wrong.
That is why no single error message describes the bug — Zig stops at the first one.

Repro: `tools/fixtures/bug281_keyword_gaps_repro.zbr` — deliberately OUTSIDE `test/`,
because neither compiler can build it and a corpus file in that state would put
`full_sweep`, `smoke` and `registration_check` in the red for known, filed debt.

```zebra
@derive(Debug, Eq, Hash)
struct Der
    var align: int = 0

class opaque
    var packed: int = 0
```

Emitted by `zebra-bootstrap --emit-zig`, and it does not compile:

```
error: expected pointer dereference, optional unwrap, or field access, found 'align'
```

**A — `@derive` bodies emit `self.<field>` bare.** `genDeriveToString`,
`genDeriveEql` and `genDeriveHash` build their member access with a raw `{s}`:

```zig
return std.fmt.allocPrint(_allocator, "Der(align={}, ...)", .{self.align, ...});
return (self.align == other.align) and ...;
std.hash.autoHashStrat(&hasher, self.align, .Deep);
```

The field is DECLARED `@"align": i64` two lines above. This is the first error Zig
reaches, which is why it masks B and C.

**B — the type NAME itself is never escaped.** `pub const opaque = struct {`,
`pub fn get(self: *const opaque)`, `pub fn init() *opaque`, `opaque.init()`. Note the
asymmetry that makes this easy to misread as fine: `_ttag_opaque` and
`_reflect_opaque_name` are *correct*, because the prefix already makes them
collision-free — the same reasoning that governs `_zbr_mv_` in `genFieldDecl`.
BUG-280 *did* escape `genType`'s class-name emits, which makes the two halves
**disagree**: an annotated local emits `*@"opaque"` while the declaration it names emits
`pub const opaque`. Escaped and bare are the same identifier for a Zig *primitive* (the
case `emitName` was originally written for) but not for a Zig *keyword*, where the bare
spelling does not parse at all. So fixing B means fixing the declaration side to match,
not reverting `genType`.

**C — a capture is declared escaped and read bare.** Within one emitted struct:

```zig
const addIt = struct {
    @"noalias": i64,                       // declaration — escaped
    fn call(self: @This(), v: i64) i64 {
        return (v + self.noalias);         // read — BARE
    }
}{ .@"noalias" = @"noalias", };            // designator — escaped
```

The declaration and designator were in BUG-280's site map; the body reference goes
through `genIdentRaw`'s capture-field path (`selfhost/CodeGen.zbr` ~10475) and was not.
Inconsistent inside a single struct is the sharpest statement of it.

**A, C, D and F are done** — each was a bounded set of emit sites and the same one-line
change BUG-280 made everywhere else: route the emit through `emitName`. D was the widest
and the least obvious: the enum member and union variant *declarations* are only half of
it, and the gate also named the **switch prongs** (`.align => {`) and the **construction
designator** (`Shape{ .volatile = 12 }`). Reading would have found the declarations and
stopped.

**B AND E ARE A DECISION, NOT A CHORE — and there are three options, not two.** The
counting matters: the escape is only ever needed at **emit** sites, because
`class_names` / `struct_names` / `enum_names` / the dotted `Owner.method` maps hold the
*Zebra* name and never change. A crude grep puts B at roughly **45** candidate emit sites
in the selfhost (12 of them the bare `owner` spelling) and E at roughly **21**, plus the
bootstrap's own set. So it is wide-but-mechanical, not a map audit — the word "invasive"
in the first version of this entry was an adjective derived from reading, which is the
habit this bug exists to discourage.

1. **Escape at every emit site.** Supports the names fully. Wide (~66 selfhost sites plus
   the bootstrap), but each edit is trivial and the probe-plus-gate makes completeness
   checkable rather than believed.
2. **Prefix the emitted spelling**, the way `_zbr_mv_` already does for module vars and
   `_zbr_fn_` for top-level functions. This *immunises the whole class permanently* — no
   escaping is ever needed again, at any emit site anyone adds later. That is why family
   G costs the selfhost nothing today. The catch is that type names cross module
   boundaries (`Module.ClassName`), so the prefix must be consistent across modules AND
   across the bootstrap/selfhost pair. Biggest change, biggest payoff.
3. **Refuse at the front end**, with a Zebra diagnostic naming the word and the fix.
   Cheapest by far — one check in the resolver — and *strictly better than today*, where
   the user gets a Zig parse error against generated code carrying no Zebra source
   location. The cost is that the name stays unusable, which is what reserving a word
   means; this is effectively "Zig's keywords are reserved for TYPE and METHOD names,
   but free everywhere else."

**DECIDED 2026-08-12: option 2, the prefix.** Sean's call — an investment against future
work, and he wants the bootstrap retired soon anyway, so paying a bootstrap tax here is
not worth it. **Selfhost-first is therefore acceptable**, under the standing rule: the
bootstrap must still COMPILE the selfhost source, which it does, because no `.zbr` source
changes.

**The argument for 2 over 1 is NOT "no escaping ever needed" — that is weak, since both
cost the same ~45 sites up front. It is the FAILURE MODE afterward:**

| | a newly-added emit site that forgets | |
|---|---|---|
| escaping (1) | breaks only for a keyword-named type — **silent, latent, rare** | this bug, twice |
| prefixing (2) | emits `Route` when nothing declares it — **Zig errors on the first test that uses any class** | loud, immediate, universal |

That converts a rare silent failure into an unmissable one, which is the principle the
rest of this repo is built on. It is also why family G costs the selfhost nothing today.

**THE ONE REAL COST, found by measuring rather than reasoning.** Of 70 `zig"..."` inline
literals, **three** reference a Zebra type by its emitted spelling — `zig"Counter{}"`,
`zig"Greeter{}"`, `zig"Point{}"`. So prefixing raises a language question: **is the
emitted Zig spelling of a Zebra type part of the public contract for `zig"..."` escape
hatches?** Note these are the construct the lints are structurally blind to (BUG-267), so
they cannot be found by any checker — only by grep.

**THE COMPATIBILITY ALIAS WAS TRIED AND IT IS WRONG. Do not reintroduce it.**

The proposal was to emit, alongside the prefixed declaration:

```zig
pub const _zbr_ty_Route = struct { ... };
pub const Route = _zbr_ty_Route;   // <- WRONG. Do not do this.
```

reasoning that generated code would use the prefix while hand-written `zig"Route{}"`
kept working. **It silently defeats the entire change**, and this was measured, not
argued:

| | 26 reference sites still un-migrated | result |
|---|---|---|
| alias emitted | every bare `ZqClass` RESOLVES through it | **whole probe compiles clean** |
| alias removed | nothing declares the bare name | `error: use of undeclared identifier 'ZqClass'`, ×26 |

So with the alias, the loud-failure property that is the *entire justification* for
prefixing over escaping does not exist. It is a silent fallback sitting on the exact path
that decides "is this correct", biased — as the repo's own instrument rules say they
always are — toward *nothing is wrong*. Both directions were run; the failure was seen,
not assumed.

**Accepted cost: the emitted Zig spelling of a Zebra type becomes PRIVATE.** A
hand-written `zig"Foo{}"` naming a type by that spelling stops resolving. Three such
literals exist in the corpus: `zig"Counter{}"`, `zig"Greeter{}"`, `zig"Point{}"`.

**LAND BUG-283 FIRST — the two decouple completely, and the order matters.** An earlier
draft of this entry said to migrate those three literals *in the same commit* as the
prefix. That is wrong, and needlessly so:

| order | what the prefix commit does to users |
|---|---|
| prefix first, then BUG-283 | **breaks every `zig"Type{}"` in existence** with nothing to migrate *to* — the replacement mechanism does not exist yet |
| **BUG-283 first, then prefix** | the substitution form exists, the three literals move to it while the old spelling still works, and the prefix commit then breaks **nothing** |

With BUG-283 in place the prefix becomes a pure internal change with no user-visible
surface at all — which is the whole point of doing it as an investment rather than a
patch. It also means the prefix no longer needs a deprecation story, because by the time
it lands nothing depends on the spelling.

**Sequencing.** B (type names) first, since E (method names) is namespaced inside the
type and becomes easier once B lands. G disappears for free the moment the bootstrap is
retired, and is already a non-issue in the selfhost.

**B LANDED 2026-08-13; the planning below is kept as the record of how it was scoped.**
Read it for the reasoning, not for the state — the site table is accurate and incomplete,
and the section at the top of this entry says by exactly what.

**E LANDED 2026-08-13, and the prediction above held exactly**: a method is namespaced
inside its type, so it needed `emitName` rather than a prefix, and it was five sites of
the same one-line change A/C/D/F took. What the prediction did *not* contain is which
five — see the site-count note at the top of this entry. The estimate in the option list
below said "roughly 21 emit sites" for E; the real number is 5, because that grep counted
every `w.emit(mname)` in the file and ~30 of those are stdlib namespaces (`Math.`,
`File.`, `sys.`, `Json.`…) whose method names are fixed by the runtime and can never be a
user identifier. **A grep-derived site estimate is an upper bound, not a count.**

**THE SITE LIST IS DERIVED AND READY — `tools/fixtures/bug281_typename_sites_probe.zbr`.**
Every type in it is named `Zq…`, a token that appears nowhere else in the compiler or the
runtime, so `grep Zq` over the emit returns exactly the sites and nothing else. 51
occurrences collapse to **~15 distinct emit positions**, and the rule separating them is
the same one BUG-280 settled: **an identifier gets the prefix; a string never does.**

| must be prefixed (identifier) | |
|---|---|
| `pub const ZqClass = struct` | declaration — class, struct, enum, union |
| `pub fn bump(self: *ZqClass)` | method receiver |
| `pub fn init() *ZqClass` / `create(ZqClass)` | class init return + allocator arg |
| `pub fn init(a: i64) ZqDerived` | struct synth-init return type |
| `toString(self: *const ZqDerived)`, `eql(…, other: *const ZqDerived)` | derive receivers |
| `_zbr_fn_takesZq(c: *ZqClass, p: ZqPlain)` | parameter types (via `genType`) |
| `pub fn _zbr_fn_makesZq() ZqPlain` | return type |
| `return ZqPlain{ .b = 2 }` / `ZqUnion{ .num = 6 }` | struct + union construction |
| `inner: ZqPlain`, `maybe: ?*ZqClass` | field types |
| `ZqClass.init()`, `ZqClass.shared`, `ZqEnum.two` | qualified access |
| `std.ArrayList(ZqPlain)` | container type argument |

| must NOT be prefixed | why |
|---|---|
| `_ttag_ZqClass`, `_reflect_ZqClass_name` | **already prefixed** — and they are the existing proof this approach works |
| `_zbr_hash("ZqClass")`, `"ZqClass"`, `"ZqDerived(a={})"` | strings — data, not identifiers |
| `&.{"ZqPlain", "?ZqClass"}` | reflection FIELD TYPES — the Zebra type name AS DATA. Prefixing this would silently corrupt reflection, and no gate would see it |

That last row is the over-application hazard, in the same shape as BUG-280's reflection
strings: verify by diffing a pre/post emit of this probe, where every changed line must
be an identifier gaining the prefix and nothing else.

**THIS CHANGE IS ATOMIC. It cannot be landed in pieces, and that is not a preference.**
Prefixing the declarations while the references stay bare produces a compiler that emits
nothing compilable for any program containing a class. The one mechanism that would allow
a staged landing is the compatibility alias — and that is the design proven wrong above.
So it is 26 sites or none, in a single commit, with a full gated landing behind it.
Attempted twice and reverted twice on that basis; the revert is clean and takes one
`git checkout` plus `rebuild.sh --module CgHelpers --module CodeGen`.

**THE 26 SITES ARE FIVE CLUSTERS, which is what makes it a session's work rather than an
archaeology project.** Derived by running the probe with declarations already prefixed
and reading what still came out bare:

| # | cluster | emitted shape | where |
|---|---|---|---|
| 1 | method + derive receivers | `self: *ZqClass`, `self: *const ZqDerived` | `genMethod`, `genInit`, `genDeriveToString`/`Eql`/`Hash` |
| 2 | class synthesised init | `pub fn init() *ZqClass`, `_allocator.create(ZqClass)` | `genClass` |
| 3 | struct synthesised init return | `pub fn init(a: i64) ZqDerived` | `genStruct` |
| 4 | type positions | `*ZqClass`, `ZqPlain`, `?*ZqClass`, `std.ArrayList(ZqPlain)` | `genType` — **these are exactly the 6 sites BUG-280 routed through `emitName`; they become `emitTypeName`** |
| 5 | construction + qualified access | `ZqPlain{ .b = 2 }`, `ZqClass.init()`, `ZqClass.shared`, `ZqEnum.two`, `ZqUnion{ .num = 6 }` | `genCall`, `genIdentRaw`'s shared-field branch, the enum/union construction arms |

Cluster 4 is the reassuring one: BUG-280 already found and routed those six, so they are
known-complete and the edit is mechanical. Cluster 1 is mostly `w.emit(owner)`, of which
there are 12 occurrences — check each, since not all are type positions.

**OUTCOME: 12 of those 12 `owner` sites, 8 of them type positions and 4 not.** The four
left bare are the ones that put the name in a STRING — `_profile_start("Owner.method")`,
`_zbr_hash("Owner")`, the invariant-failure panic text, and the `@derive` `toString`
format literal. That split is the same rule BUG-280 settled and the same rule the
over-application control checks; "check each" was the right instruction and a sweep would
have corrupted all four.

**And BUG-283 already bought the user-facing half:** `emitTypeRefName` in
`selfhost/CodeGen.zbr` is the single place `${Name}` resolves to a spelling. Change that
one function from `emitName` to `emitTypeName` and every `${...}` in every user program
follows. That indirection exists for exactly this.

**What this does NOT fix, measured 2026-08-12 in answer to a direct question:** the
trailing-`_` convention in the selfhost sources. Of 94 such identifiers, **48** dodge a
**ZEBRA** keyword (`var_`, `class_`, `if_`, `int_`, `bool_`, `except_`…), 44 are
stylistic, and only **2** (`fn_`, `void_`) dodge a Zig name. A Zebra-keyword collision
happens in the TOKENIZER, before anything is emitted, so no emit-side scheme can touch
it. The lever for those 48 is freeing Zebra keywords — the `lint_reserved_words` / U4
line of work. Two problems that look like one.

**Do not fix these by hand-hunting `w.emit(<x>.name)` call sites.** There are hundreds,
most of them correct. The reliable procedure is the one that produced this table: extend
the probe with a new declaration form, emit, grep, and fix only what the grep names.

**Why no gate saw it.** `keyword_ident_check.sh` passed the bootstrap the whole time.
Its own header declares the limit — "the fixture is the coverage" — and this is the
receipt: three broken families, one gate, green. It is also invisible to
`divergence_check --gate` by construction, since both compilers are wrong identically,
and to `compile_check`/`full_sweep`, because no corpus file names a field or a class
after a Zig keyword.

**Control when fixing:** extend `test/bug280_keyword_idents.zbr` with the probe's three
shapes **before** touching codegen, and watch `keyword_ident_check.sh` go red first. The
fixture deliberately does *not* carry them today — a corpus file neither compiler can
build would put `full_sweep` and `smoke` in the red for known, filed debt.

### BUG-279: `zig build test` is red on committed code, in no gate tier — ⚠ LEGS 1+2 FIXED 2026-08-18; leg 3 is someone else's review

> **LEGS 1 AND 2 FIXED 2026-08-18, verified per-step rather than by silence:**
>
> ```
> Build Summary: 8/10 steps succeeded (1 failed); 131/131 tests passed
> +- run test unit          120 pass (120 total)
> +- run test integration    11 pass  (11 total)
> +- run bash success  6m    compile_check: 276 passed, 0 FAILED
> +- run bash failure        escape_hatches_check      <- leg 3, below
> +- run bash success 14m    selfhost smoke: 359/359
> ```
>
> Leg 1: `AstPrinter.printTypeRef` gained the `.fn_type` case (printed like `.tuple`;
> `ret == null` is void). Leg 2: the codegen test helper now passes the 16th argument,
> `emit_node_addon = false`. **The ticket's line number for leg 2 was STALE** — 17750 is
> `findMainClass` today — so the call was found by searching, not by trusting the
> coordinate.
>
> **THE CONTROL IN THIS TICKET EARNED ITS KEEP, and it is the reason the real find
> surfaced.** It demanded the run PHASE be reached, "not merely the compile error
> disappearing". Once the binary ran, **two unit tests failed — both asserting syntax the
> language had REMOVED**:
>
> | stale test | asserted |
> |---|---|
> | `parse: print statement with interpolated string` | `print "hi ${name}!"` — the pre-`()`-mandatory Cobra form |
> | `parse: to! non-nil assertion` | `x = foo() to!` — the operator §28 removed |
>
> Each would have failed the day its feature was dropped, if anyone could have run it.
> **That is the true cost of legs 1 and 2**: not two compile errors, but two false claims
> about the language sheltering behind them — one of them a construct the grammar is
> supposed to REJECT.
>
> Both were **inverted, not deleted**, following the precedent U4a set when `aspect` was
> freed ("the six Parser acceptance tests … replaced by their inverse"). A deleted test
> asserts nothing; an inverted one pins the removal. A positive `print(...)` control was
> added so the inversion cannot pass because printing broke generally. 119 -> 120 tests.
>
> **LEG 3 IS UNTOUCHED AND DELIBERATELY SO.** It still fires (70 vs 72). Every
> `page_allocator` use in the preamble carries a lifetime comment (arena-rewind survival,
> cross-thread channels/pools), but WHICH TWO ARE NEW needs the author who added them —
> the ticket assigns this as a review, not an edit, and that has not changed.
>
> **THE STRUCTURAL QUESTION NOW HAS A MEASUREMENT.** `zig build test` is a SUPERSET:
> unit + integration + `selfhost_smoke.sh` + `escape_hatches_check.sh` + `compile_check`.
> Smoke and compile_check are already in the tiers, so putting the command in a tier
> wholesale would run ~20 minutes of work TWICE. The three legs covered by nothing else
> are **unit, integration and escape-hatches**, and they are cheap — 120+11 tests in ~4s
> combined, per the summary above.
>
> **AND THE bug-fixture GATE INDEPENDENTLY CONFIRMED THAT ARGUMENT.** Marking legs 1+2
> fixed turned it red: *"1 newly FIXED bug with no test that runs"*. It is RIGHT. The
> pins for those legs are the two inverted Parser tests — and they only execute under
> `zig build test`, which no tier runs. So "a test that actually RUNS" is genuinely
> false, which is the exact category that gate was built to catch, and the same reason
> this bug existed at all.
>
> **CLEARED 2026-08-19, by the very fix it argued for.** It was baselined for a few
> hours with the clearing condition written down — *"remove it the moment the
> unit/integration legs are gated, because at that point the pins really do run"* — and
> that is exactly what happened: `tools/zig_test_check.sh` carries a `# pins: BUG-279`
> claim, the `# pins:` mechanism only counts when the script is REGISTERED IN gates.sh,
> and it now is. Debt 127 -> 126, the diff a single line, checked both times so a
> re-baseline could not absorb unrelated drift.
>
> Worth keeping as a pattern: the gate did not merely complain, it **named the condition
> under which it would stop complaining**, and satisfying that condition was the same act
> as fixing the underlying structural gap. A baseline entry with a written clearing
> condition is a to-do with an owner; one without is just debt.
>
> **Recommended (Sean's call, not taken unilaterally):** add unit + integration +
> escape-hatches to the QUICK tier as one gate, and list `zig build test` itself in
> CLAUDE.md's uncovered table with a date. That covers exactly the uncovered set at a
> fraction of the cost and makes this drift impossible, which is the ticket's stated
> goal. <!-- bug-open-ok: leg 3 is a review someone else owns; the tier decision is Sean's -->

**Found 2026-08-09** by running it after a front-end change, on the assumption it was
part of the contract. It is not: `gates.sh` does not run it in either tier, and
CLAUDE.md's *"What the gates do NOT cover"* section — which exists precisely so the
unrun set stays visible — does not list it either. So it is neither run nor accounted
for as unrun, which is the one state that section is designed to make impossible.

It is also the first command in CLAUDE.md's **Build and test** block, three lines under
`zig build`. A newcomer types it before anything else.

**Three independent failures, none related to the others, all on committed code:**

1. **`src/AstPrinter.zig:283` — `switch must handle all possibilities`**, missing
   `TypeRef.fn_type`. The inline `def(P): R` function-type was added to
   `Ast.TypeRef` (the closure-factory work) and the printer never grew a case.
   Compile error, so `test/main.zig`'s whole integration binary does not build.

2. **`src/CodeGen.zig:17750` — `expected 16 argument(s), found 15`.** A test calls
   `generate(...)` with the signature it had before a parameter was added. The unit
   test binary does not build either.

3. **`escape_hatches_check`: `stdlib_preamble.zig` count drift, expected 70, actual
   **72**.** Two `page_allocator` uses were added without bumping `EXPECTED_PREAMBLE`
   in `tools/escape_hatches_check.sh`. That tool prints the correct procedure in its
   own failure message — verify each new use has a comment justifying why it must
   outlive the program arena, then bump the counter — so this one is **a review, not
   an edit**, and belongs to whoever added the uses. <!-- bug-open-ok: leg 3 is a review someone else owns; legs 1 and 2 are ordinary fixes -->

**Why the green board did not see any of it.** Legs 1 and 2 are in code that only the
Zig test binaries compile; `zig build` alone never analyses them, and every gate builds
the compiler rather than the tests. Leg 3's checker is only invoked from `zig build
test`. So `gates.sh --full` can be 27/27 — it was, on the commit before this entry —
while the command in the README is broken three ways.

**The structural fix is not "fix these three".** It is to decide whether `zig build
test` is part of the contract. If it is, it belongs in a tier and the drift stops being
possible. If it is not, it belongs in the *uncovered* table with a date, like
`gramgen`, `node_addon_test` and the GUI paths — which is the whole point of that
table. Leaving it in neither is how all three of these landed.

**Control when fixing:** legs 1 and 2 must be verified by `zig build test` reaching the
*run* phase, not merely by the compile error disappearing — a test binary that builds
and then fails is a different state from one that never built, and the second is what
has been hiding here.

### BUG-267: `zig"…"` literals do not participate in MUTATION analysis (usage half ✅ FIXED 2026-08-06)
<!-- bug-open-ok: PARTIAL — the usage half is fixed and the heading says so, but the MUTATION half is still open, so this belongs in the open ledger. Move it when the write half lands. -->

**Found 2026-08-05** probing a real third-party DLL. Same root class as BUG-260 (a
parameter used only inside a query bind list), and worse-placed: `zig"…"` is the only way
to touch a C pointer, so the escape hatch reserved for FFI is exactly the construct the
analysis cannot see into.

    var p = Py_GetVersion()                       # read ONLY inside the escape
    zig"const _c: [*:0]const u8 = @ptrFromInt(p); out = std.mem.span(_c);"

    error: pointless discard of local constant   ->  _ = p;   emitted alongside the use
    error: cannot assign to constant             ->  `out` emitted const; escape assigns it

Both walks stop at the literal: a variable **read** only inside it is treated as unused,
and one **assigned** only inside it is treated as never mutated. Working around it needs
two unrelated dummy statements (a fake comparison to use `p`, a dead branch to make `out`
a var) — see `docs/extern_ffi_design.md` §9 for the full repro.

**Control when fixing:** a var read only inside a `zig"…"` must NOT get a discard, and one
assigned only inside it must be emitted `var`; a genuinely unused var must still get its
discard, and a genuinely non-mutated one must still be `const`. Both directions.

**READ HALF FIXED 2026-08-06.** `mightUseNameInExpr` now carries the `zig_lit` case its
sibling walker has had since B3, so a local read only inside an escape is no longer
discarded. Pinned by `test/bug267_ziglit_local_use_test.zbr`, which asserts BOTH
directions — the escape case compiles, AND a genuinely unused local still gets its
`_ =`, so a fix that simply stopped discarding anything fails there rather than passing.
**What remains open is the WRITE half only** (see the last section below).

**Re-scoped 2026-08-06 — the earlier scoping below was WRONG about the read half, and
wrong in the expensive direction: it argued for new language syntax to solve a problem
this codebase had already solved one walker over.**

**The read half is an INCONSISTENCY, not a missing capability.** `zigLitMentionsWord()`
already exists in `selfhost/CgHelpers.zbr`, and its own comment states why: *"A param
referenced from a `zig"…"` literal is used, so it must not be discarded."* There are two
usage walkers, and only one of them learned that lesson:

| walker | `zig_lit` case | used by |
|---|---|---|
| `nameUsedInExpr` | scans the text | parameter discards |
| `mightUseNameInExpr` | falls into "no user idents" -> false | **local** discards |

Measured, same construct both ways:

    param used only in zig"…"  ->  no discard    (correct, long-standing)
    local used only in zig"…"  ->  `_ = q;`      -> pointless discard of local constant

So the fix is to give `mightUseNameInExpr` the same `zig_lit` case the sibling walker
already has. No new syntax; it makes locals behave like parameters, which is what a reader
would assume already happens.

**The scan does not skip Zig strings or comments**, so a name appearing only inside one
counts as a use, the discard is suppressed, and Zig reports `unused local variable`. That
is a real limit and it is stated here rather than hidden — but it is **already accepted for
parameters**, has not bitten, and its failure direction is a compile error rather than a
silent miscompile.

**Two designs considered and NOT pursued, recorded so they are not re-derived:**

- **`zig"…" reads a, b`** (an explicit read list). Exact rather than heuristic, and it was
  the recommendation until `zigLitMentionsWord` turned up. Rejected because it adds
  language surface to answer a question the compiler already answers elsewhere, and would
  leave TWO mechanisms for "what does this escape touch" — the more likely long-term
  hazard than the false-positive it prevents. Revisit only if the string/comment
  false-positive is actually hit.
- **A `zig` BLOCK form with `reads` / `writes` clauses** (mirroring `capture`). The more
  complete design, and the only one that addresses the write half for multi-statement
  escapes. Not pursued because **the need was never demonstrated**: every real case so far
  is a value flowing OUT of C, which expression form already handles. Revisit when someone
  hits a genuine multi-statement escape that must mutate an existing local.

**The write half is separate and remains open.** No mutation walker scans `zig"…"` at all,
so a local assigned only inside a statement-form escape is still emitted `const` and Zig
rejects the assignment. Expression form (`var out = zig"…"`) avoids it entirely and is the
recommended shape, so this is a documented limit rather than a blocker.

**Related:** BUG-260 is the same walker question in a different construct (a parameter used
only inside a query bind list). It is NOT fixed by this — that construct is a list literal,
not a `zig_lit` — but it is worth checking against whatever fix lands here.


### BUG-264: the selfhost lowers a module-scope `StrSet.add` as `List.append`, so it cannot re-emit its own source

**Found 2026-08-05** by the round-trip gate, while adding a module-scope `StrSet` to
`selfhost/CodeGen.zbr` for BUG-261. Worked around there (`List(str)` instead); the
underlying defect is untouched.

A file-scope `var s: StrSet = StrSet()` followed by `s.add(x)`:

| | emit |
|---|---|
| bootstrap | `pub var _zbr_mv_s: *StrSet = undefined;` … `_zbr_mv_s.add(path);` — **correct** |
| selfhost | types it `StrSet`, then lowers the call as a List: `_zbr_mv_s.append(_zbr_rt._allocator, path)` |

The selfhost's output does not compile:

```
error: method invocation only supports up to one level of implicit pointer dereferencing
note: struct declared here -- pub const StrSet = struct {
```

So the type is resolved correctly and only the **method lowering** is wrong: `.add` on a
module-scope var is treated as `List.add` unconditionally. `_implicit_try_sites` and
`_inference_guess_sites`, the only pre-existing module-scope collections in that file, are
both `List(str)` — so the wrong branch has always been the right answer until now, which
is presumably why this has never fired.

**A selfhost-LEADS-vs-LAGS inversion worth noting:** here the bootstrap is right and the
shipping compiler is wrong, the same direction as BUG-254.

**Only the round-trip gate can see this class.** `zig build` builds `zebra.exe` from the
*bootstrap's* (correct) emit, so the compiler builds, runs, and passes all 313 smoke
fixtures while being unable to emit valid Zig for its own source. Nothing before step 3 of
`bootstrap_check` looks at what the selfhost emits for that file.

**Control when fixing:** a module-scope `StrSet` with `.add`/`.contains_` must round-trip;
a module-scope `List(str)` with `.add` must still emit `.append(allocator, …)`. Both
directions — the easy wrong fix is to stop treating module-var `.add` as List at all.

### BUG-262: the selfhost never materializes a native `.zig` dep, so `use SomeZigModule` fails — OPEN (a fix was written, verified, and REVERTED 2026-08-20 — read this first)

> **THE DIAGNOSIS IS CONFIRMED AND THE FIRST FIX WAS WRONG IN ONE SPECIFIC WAY. Anyone
> picking this up should start from here rather than from the original entry below.**
>
> **Confirmed:** `zebra.exe test/zig_interop_test.zbr` fails
> `unable to load 'ZigMath.zig': FileNotFound` while `zebra-bootstrap.exe` runs it. The
> bootstrap emits BESIDE THE SOURCE, where the dep already sits; the selfhost emits to a
> temp directory and copies nothing there. There is no `.zig` branch in the selfhost's dep
> resolution at all.
>
> **The fix that worked:** collect `.zig` deps during the dep walk, then copy each one
> beside the emitted output in `writeNativeZigDeps`, called immediately after
> `writeRuntimeModule` — the single point every emit route (`--emit-zig`, `--output-dir`,
> run-mode temp dir, `-c`, the fast backend) passes through. Verified: `zig_interop_test`
> ran, and the standalone `--output-dir` emit produced `ZigMath.zig` beside the output and
> `zig build-exe` on it returned 0.
>
> **WHY IT WAS REVERTED — the ordering, and it is not a detail.** The new branch `return`ed
> as soon as it found a `<dep>.zig`, which put it AHEAD of the prebuilt-library scan. That
> broke `ffi_lib_check`:
>
> ```
> error: lld-link: undefined symbol: zebra_lib_answer
> ```
>
> because that gate writes `zzlib.zig` as **the source it builds `zzlib.lib` from**, and
> then compiles a Zebra program that must LINK the library. With the new branch, `use
> zzlib` found the `.zig`, treated it as an importable module, and never linked. The gate
> even carries a leg asserting the emit must NOT `@import("zzlib.zig")` for a prebuilt
> library — the constraint was already written down, in a gate, and the fix walked into it.
>
> **So the rule the next attempt must encode:** a prebuilt library WINS over a `.zig` of
> the same name; only a bare `.zig` with no library beside it is an importable dep. That is
> the OPPOSITE of the `.c` rule ("a `foo.c` beside a stale `foo.lib` keeps compiling the
> source"), and the reason is that a `.zig` may be the SOURCE OF the library rather than a
> module. Put the branch after the library scan.
>
> **A COVERAGE PRIZE IS ATTACHED, which is why this is worth finishing.**
> `zig_interop_test` sits in `tools/positive_set.sh`'s SKIP list described as a HARNESS
> LIMIT — *"needs external source the standalone emit never materializes"*. That
> description is true and its cause is THIS BUG, not the harness. With the fix in place the
> file left the skip list, `registration_check`'s unasserted debt went 19 → 18, and
> `full_sweep`'s absolute leg gained a file. A "harness limit" that turns out to be a
> compiler defect is worth re-reading the other two skips for.
>
> **Fixture shape that worked:** a trivial `test/bug262_*.zig` exporting one function plus
> a `.zbr` that `use`s it — with QUALIFIED calls, not `exposing`. An `exposing` list on a
> native dep aliases the Zebra-MANGLED name (`_zbr_fn_triple`), which a hand-written Zig
> module does not have; that is **BUG-263** and it is still open, so pinning it here makes
> the fixture fail for the wrong reason.

---

### BUG-263: `use foo exposing bar` emits no aliases when `foo` is a native dep

**Found 2026-08-05** while fixing BUG-261, by reading the bootstrap branch being
ported rather than by hitting it.

Both compilers attach the exposed-name aliasing to the **Zebra-dep** branch of
`genUse` only (`src/CodeGen.zig:4899-4930`, `selfhost/CodeGen.zbr` genUse). So on
a dep that resolved to `.c` or `.zig`:

    use CUtils exposing c_add          # c_add is never bound to anything

The `use` itself still works — `CUtils.c_add(...)` resolves — so this is a missing
convenience, not a miscompile. It fails at the Zig stage with an undefined
identifier rather than silently, which is why it has gone unnoticed.

**It is a SHARED hole, and that is the point.** Fixing it in the selfhost alone
would open a selfhost gap in `divergence_check`, which is currently 0 and is the
property the port exists to preserve. Either fix both compilers together or
neither. Filed rather than fixed for that reason.

### BUG-254: the BOOTSTRAP is over-strict on mixed numeric arithmetic — `1 + 2.0` is rejected — OPEN

**Found 2026-08-04** while porting BUG-253's arithmetic diagnostics, and notable because it
runs the OTHER WAY: here the **selfhost is right and the bootstrap is wrong**.

```zebra
var a: int = 1
var b: float = 2.0
var c = a + b        # bootstrap: error: arithmetic operands must have the same type: 'int' vs 'float'
var d = 1 + 2.0      # bootstrap: same error
```
The selfhost accepts both. `src/TypeChecker.zig` requires `Type.eql(lt, rt)` — exact
equality — for `+ - * / // % **`.

**Sean's decision, 2026-08-04:** *"I'd prefer to keep `1 + 2.0` … I think not supporting it
would cause a lot of headaches for something in the python-like space of languages."* So the
permissive behaviour is the intended semantic and the strict rule is the defect.

**It also contradicts the language's own stated principle.** QUICKSTART's untyped-numeric
rule is why `[1, 2.0, 3]` is a legal list literal — `int` and `float` are mutually
assignable. Arithmetic demanding exact equality is inconsistent with that.

**Consequence for BUG-253's triage, and this is the useful part:** "present in the bootstrap,
missing from the selfhost" is **NOT automatically a defect**. This is the first confirmed
case where the missing diagnostic *should* stay missing. `tools/diagnostic_parity.py`
reports candidates rather than gating precisely because this judgement cannot be automated —
and this ticket is the evidence that the caution was warranted rather than decorative.

**Fix:** relax `src/TypeChecker.zig` to mutual assignability (the rule `isAssignable`
already implements, and which the list-literal check uses) instead of `Type.eql`. Low
urgency — the bootstrap is the regen authority, not the shipping compiler, so this affects
`--zig-backend` users and the GUI paths rather than ordinary builds.

### BUG-253: the selfhost TypeChecker has roughly HALF the bootstrap's diagnostics — OPEN (umbrella)

**Found 2026-08-04**, by asking the question BUG-252 raised: *"which other bootstrap
diagnostics never reached the selfhost?"* Three had already been found by accident
(BUG-106, BUG-108/248, BUG-099/252). Three accidents is a class, not a coincidence.

Enumerated by `tools/diagnostic_parity.py`:

    bootstrap src/TypeChecker.zig   37 diagnostics
    selfhost  TypeChecker.zbr       19 diagnostics
    no counterpart found            26 candidates

**VERIFIED BY EXPERIMENT, not by the matcher.** Three candidates were tested directly
against both compilers; the tool is fuzzy by construction and its number means nothing on
its own:

| probe | bootstrap | selfhost `-c` | verdict |
|---|---|---|---|
| `var b = a - 1` where `a: str` | rejects | **accepts** | **gap confirmed** |
| `def f(): int` with a bare `return` | rejects | **accepts** | **gap confirmed** |
| `var b = a & 2` where `a: float` | accepts | rejects | **false positive** — the selfhost LEADS here |

So the hit rate on a 3-sample is 2/3, and the one miss errs in the harmless direction. The
26 are **candidates for triage**, not 26 defects.

**Impact is diagnostic quality, not silent wrongness.** Both confirmed gaps still FAIL to
compile — Zig catches them:

    p3.zbr:2: error: expected type 'i64', found 'void'

That is a message in **Zig's vocabulary, about emitted code the user never wrote**, for a
mistake (`return` with no value from a function declared `: int`) the front end could name
exactly. This is the same programme as `tools/frontend_gap.py`, which measured `-c` missing
**43%** of what `zig` rejects — and this ticket explains a large part of *why*.

**The missing set is substantive**, not cosmetic. Among the candidates: arithmetic operand
type mismatches, bitwise-on-non-integer, `if x as n` requiring an optional, destructuring
arity, `return` without a value, SIMD operand types, `raise` details lacking `toString`.

**Not made a gate, deliberately.** "Absent" is a candidate: a diagnostic may be legitimately
unported because it guards a bootstrap-only feature, or reworded past the matcher. Gating it
would demand a suppression list nobody maintains. It reports; a person decides.

### Triage, 2026-08-04 — 9 probes run against BOTH compilers

The matcher lists messages, not programs, so each candidate needed a minimal repro and a
run against both compilers. `scratchpad/triage_253.py`.

| candidate | verdict | action |
|---|---|---|
| bare `return` from `def f(): int` | real gap | ✅ **PORTED** |
| `"x" - 1` (non-numeric arithmetic operand) | real gap | ✅ **PORTED** |
| compound assignment on a non-numeric | real gap | ✅ **PORTED** |
| `if x as n` on a non-optional | real gap | ✅ **PORTED** |
| destructuring arity mismatch | real gap | ✅ **PORTED** |
| destructuring a non-tuple | real gap | ✅ **PORTED** |
| tuple index out of bounds | real gap | ✅ **PORTED** |
| `unary '-' requires numeric type` | real gap | ✅ **PORTED** (the `Expr.unary` arm was added) |
| `arithmetic operands must have the same type` | *selfhost is RIGHT* | ❌ **DO NOT PORT** — BUG-254 |

**Two candidates were BAD PROBES, not evidence.** `bitwise operator requires integer type`
and `bitwise 'not' …` both came back "rejected by both" — but the error was
`unexpected expression token: '&'`, a **parse** error. `&` and `~` are not Zebra syntax, so
the probes never reached the TypeChecker. Recorded because the same trap bit a guard later
in the session: a "guard" written with `/=` proved nothing, because Zebra has no `/=`
either. **A probe using syntax the language lacks tests nothing and looks like a result.**

**`unary '-'` is blocked for a structural reason, not effort.** `inferExpr` has NO
`Expr.unary` arm at all — unary expressions fall through to unknown. Porting the check means
ADDING inference for that node, which is a behaviour change well beyond restoring a
diagnostic. Identical situation to `array_lit` under BUG-106. Both are one call away once
the arm exists.

**Hit rate so far: 7 real gaps of 9 probed**, one of which must not be ported. That ratio is
why the tool reports candidates and does not gate.

**Suggested order:** the ones a beginner hits first — arithmetic/type-mismatch operands, and
`return` without a value. Each is a small port from a known-good reference implementation,
and each converts a leaked Zig error into a Zebra one.

### Status 2026-08-04 — all 8 portable candidates of the 9 probed are done

The two structural blockers named above (`Expr.unary` and `array_lit` having no `inferExpr`
arm) were resolved by adding the arms, so nothing from the triage remains open. Selfhost
TypeChecker diagnostics: **19 → 25**. The one candidate that must NOT be ported is
BUG-254, where the selfhost is right and the bootstrap is wrong.

**Two things the last four ports pinned down that are worth carrying forward:**

*The tuple index check was not only missing, the access itself was arity-capped.* The
selfhost tested `m.member` against the four string literals `"0".."3"` rather than parsing
it, so `t.4` on a 5-tuple never reached the tuple branch at all — it fell through to the
generic member paths and inferred as something unrelated. The emitted Zig still compiled,
which is why no gate saw it: this is the BUG-226 class, where valid Zig produces the wrong
answer. `test/bug253_tuple_index_high_test.zbr` is therefore a **run-and-compare** fixture,
not a compile check — only the printed value distinguishes the two.

*Every one of these ports is DELIBERATELY NARROWER than the bootstrap it came from.* The
bootstrap guards these diagnostics with `!isAbstract()`; the selfhost versions go through
`isConcretePrimitive`, which fires on `int`/`float`/`str`/`bool` and nothing else. The
reason is BUG-218: `isAbstractType` knows about `unknown_`/`unresolved`/`context_dependent`
but *not* about the places selfhost inference is simply weaker than the bootstrap's (§28a).
An expression that really is optional, or really is a tuple, but that the selfhost typed as
`named` would draw a false compile error on correct code. The cost of being narrow is a
missed diagnostic; the cost of being wide is rejecting a working program. Widen when
inference closes the gap — not before.

**False-positive evidence:** all 482 tracked `test/` + `examples/` files and every
`selfhost/*.zbr` were compiled with the new checks; 4 flags, all of them the deliberately
planted controls. A sweep that reports zero without a control that must fire is not
evidence, and an earlier run of exactly this sweep silently checked **0 files** because
`corpus_ls.sh` was called without its DIR argument — the controls are what caught it.

**Known shortfall, not chased:** the two destructuring diagnostics report column 0, because
`AstBuilder` constructs `StmtDestruct` with `Span(pd.line, 0, pd.line, 0)`. The line is
correct. Same span-plumbing class as BUG-249.

### Triage round 2, 2026-08-05 — the remaining candidates

With the first nine done, `diagnostic_parity.py` reports **37 bootstrap / 29 selfhost, 10
candidates** (down from 26). Two of the ten were already settled: `arithmetic operands must
have the same type` is BUG-254 (**do not port** — the selfhost is right) and `cannot
determine type for value assigned to` is BUG-252 (present, disabled, blocked on §28a).

The rest, each probed against BOTH compilers:

| candidate | bootstrap | selfhost | verdict |
|---|---|---|---|
| `'List(...)' requires explicit initialization` | rejects | accepted | ✅ **PORTED** |
| `struct destructuring requires a class or struct` | rejects | accepted | ✅ **PORTED** |
| `raise details must implement 'toString as str'` | rejects | accepted | real gap — **open** |
| `type alias constraint must be 'bool'` | rejects | accepted | real gap — **open**, see caveat |
| `type argument does not implement …` | not probed | — | open |
| `SIMD operands must have the same type` | **untestable this way** | — | see below |

**The uninitialized-collection check needed a locality distinction the selfhost did not
have.** The bootstrap guards it with an `is_local` flag, because a *class field* declared
`var items: List(int)` is correct Zebra — it gets its value in `cue init()`. The selfhost's
`checkVarDecl` serves both statement-scope `Stmt.var_` and declaration-scope `Decl.var_`, so
putting the check inside it would have rejected every class field in the language. It lives
at the `checkStmts` call site instead, which *is* the local one — the distinction is
structural rather than a flag someone has to keep true. `bug253_uninit_collection_field_test`
pins the exemption as a run-and-compare fixture so a later tightening cannot quietly break it.

**SIMD cannot be triaged by differential probe, and the reason is worth recording.** The
bootstrap rejects `f32x8` as *"not defined"* — including in `test/simd_test.zbr`, the
corpus's own SIMD test, which the selfhost compiles and runs. SIMD is a selfhost-LEADS
feature, so **the bootstrap is not a usable reference for it**, and a candidate that exists
only in the bootstrap says nothing about what the selfhost should do. Whether the selfhost
wants an operand-type check here is an *intent* question — `boundary_check`'s department,
not this one's. (Noticed in passing: `QUICKSTART.md` documents `f32x4`, which the bootstrap
also calls undefined. Unresolved; the selfhost's support is what matters and it is
untested at that width.)

**Caveat on the type-alias row.** The bootstrap rejects `type Even = int where value % 2`,
but with `expected type 'bool', found 'i64'` — *not* the candidate string. So a gap is
confirmed (the selfhost accepts a non-bool refinement predicate) while the specific
diagnostic that fired is a different one. Recorded honestly rather than counted as a match:
the probe proves the behaviour gap, not the provenance.

### BUG-252: BUG-099's check is present but disabled by default — OPEN (blocked on §28a)

> **Heading corrected 2026-08-05.** It read *"BUG-099's check is missing from the selfhost,
> same class as BUG-106/248"*. That was wrong on both counts — the check exists, and it is
> not that class. The original text is kept below because the reasoning that produced the
> wrong conclusion is the useful part; the correction is at the end of the entry.

**Found 2026-08-04** by auditing the `check_mode_check` witness set against a new criterion
(Sean): a witness must show a genuine LIMIT of front-end checking, not a check the selfhost
happens to lack. Two of the three failed that test.

    test/bug099_unresolved_test.zbr
      bootstrap  -> error: use of undeclared identifier 'Math'
      selfhost   -> `-c` exits 0

**Third instance of the pattern** (BUG-248 = BUG-108, BUG-106, now BUG-099): a check shipped
in the bootstrap in May 2026 and never ported to the compiler that ships. All three were
found the same way — by asking what the *reference implementation* does with a file the
selfhost accepts.

**It is currently load-bearing as a witness**, which is why it is filed rather than fixed on
the spot: retiring it drops the set to two. `witness_zig_backend_literal` was added first so
the set never falls below that. Port the check, then remove this file from `WITNESSES` in
`tools/check_mode_check.sh` and from the note in `selfhost/main.zbr`.

**Worth a sweep, not just a fix.** Three confirmed instances suggests the right question is
not "port this one" but *"which other bootstrap diagnostics never reached the selfhost?"* —
enumerable by diffing the two compilers' error strings.

### Correction 2026-08-05 — the check is NOT missing. It is present and switched off.

**The title above is wrong and the classification with it.** `selfhost/TypeChecker.zbr`
has this check. It lives in `checkVarDecl`, it is guarded by `ctx.strict`, and `strict` is
set by exactly one caller: `selfhost/main.zbr:651`, the **LSP diagnostics** seam. Normal
compilation constructs `InferCtx` with `.strict = false`, so `zebra -c` never runs it.

    if ctx.strict and inferred is Type_.unresolved
        ctx.addErr(…, "unresolved type for init expr of '" + dv.name + "' (TC gap)")

This is why `diagnostic_parity.py` counted it absent: the tool matches error *strings*, and
the selfhost's wording (`unresolved type for init expr of 'x' (TC gap)`) shares no phrase
with the bootstrap's (`cannot determine type for value assigned to 'x: int'`). A fuzzy
string matcher cannot distinguish "never ported" from "ported, reworded, and disabled" —
worth remembering before reading its remaining candidates as a defect count.

**So this is not a port. It is a decision about a default, and the measurement says no.**

Flipping `.strict = true`, regenerating, and compiling all 487 tracked `test/` +
`examples/` + `selfhost/*.zbr` files:

| | files newly rejected |
|---|---|
| `test/` | 9 |
| `examples/` | 6 |
| **`selfhost/`** | **13** |
| **total** | **28** |

The selfhost 13 include `CodeGen.zbr`, `Resolver.zbr`, `TypeChecker.zbr`, `AstBuilder.zbr`
and `main.zbr` — **the compiler could not compile itself.** The examples include
`lisp.zbr`, `pratt_calc.zbr` and `kv_store.zbr`, which are working programs.

Not one of those 28 is a bug in the program. Each is a place where selfhost inference
returns `unresolved` for something it ought to have derived — §28a, the same gap that makes
every diagnostic ported this week deliberately narrower than its bootstrap original. The
flag is off for a reason, and the comment above it (*"alarm bell for TC gaps"*) is accurate:
it is an instrument for finding inference gaps, not a user-facing check.

**Reframed, therefore:** BUG-252 is not "port BUG-099's check". It is **"close enough of
§28a that the alarm bell can be armed by default"**, and the 28-file list is a ready-made
worklist for that, ordered by how much it would embarrass us (`selfhost/` first — a
compiler that cannot compile itself under its own strictest setting is the honest measure
of the gap). Until then the LSP-only default is correct, not an oversight.

**Consequence for the witness set:** `test/bug099_unresolved_test.zbr` stays a valid
`check_mode_check` witness, and for a *better* reason than it was filed under. It does not
demonstrate a check the selfhost happens to lack; it demonstrates a genuine limit — the
front end declines to assert a type it could not derive. That is the criterion Sean asked
for. Nothing needs retiring.

*Measured with a positive control: with strict on, the bug099 fixture MUST be rejected, and
was; with the flip reverted it MUST be accepted again, and was. The tree was restored to
byte-identical `.zbr` and generated `.zig` before this note was written.*

### BUG-251: a request/response `Tcp` server DEADLOCKS — `conn.read()` appears to block until EOF — OPEN

**Found 2026-08-04** while giving `Tcp` its first real run fixture. The fixture had to be
**withdrawn rather than registered**, because a hanging fixture in the QUICK tier is worse
than an uncovered namespace: it teaches people to re-run gates until they pass.

**Repro** (server reads first, then replies — the ordinary request/response shape):

```zebra
def echoHandler(conn: TcpConn)
    var data = conn.read()          # <- blocks
    conn.write("ECHO:" + data)
    conn.close()

def main()
    sys.go(def()
        Tcp.serve(19921, echoHandler)
    )
    var c = Tcp.connect("127.0.0.1", 19921)
    if c as conn
        conn.write("ping")
        var reply = conn.read()     # <- and so does this
        conn.close()
```
Hangs. Killed at 200 s.

**Isolated — both halves work SEPARATELY**, which is what makes the diagnosis specific:

| probe | result |
|---|---|
| client connects, no read | ✅ `connected=true`, exits 0 |
| server WRITES first, client reads | ✅ `got=SERVER-HELLO`, exits 0 |
| **server READS first, then replies** | ❌ **hangs** |

**Reading:** `TcpConn.read()` appears to read **to EOF** rather than returning the first
available chunk. A server that reads before replying therefore waits for the client to
close, while the client waits for the reply — a deadlock, not a slow path. If that is the
intended semantic then `Tcp` cannot express request/response at all without a framing or
half-close mechanism, and **that is a design gap rather than an implementation bug**.

**Why this went unnoticed:** `test/tcp_serve_test.zbr` is the only Tcp fixture and its
`main` merely prints a string — the `Tcp.serve` call sits in a `startServer()` that nothing
calls (quality audit §1). `stdlib_run_coverage` counts Tcp as covered on that basis. It has
never opened a socket.

**Needed:** a decision on `read()`'s contract (chunk vs to-EOF), then either a documented
framing idiom or a `readSome`/`readLine`. Until then Tcp has no honest run coverage.

---

### BUG-106 (front-end check) — CONFLICT: the fixture serves two incompatible roles — NEEDS A DECISION

**Not a new defect. A collision, surfaced 2026-08-04**, and recorded because acting on it
without a decision would silently break a gate.

The selfhost does **not** implement BUG-106's heterogeneous-literal check. Verified:

| compiler | `var xs = [1, "two", 3]` |
|---|---|
| bootstrap | ✅ `error: list literal has heterogeneous element types: 'String' is not compatible with 'int'` |
| **selfhost** (`zebra.exe`, what ships) | ❌ `-c` exits **0**; fails later inside emitted Zig |

By the selfhost-equivalence rule that gap should simply be closed — as BUG-248 was, the
same night, for BUG-108. **It cannot be, without a decision**, because
`test/bug106_heterogeneous_list_test.zbr` is simultaneously:

1. **the regression fixture for BUG-106** — it must be REJECTED by the front end; and
2. **one of three asymmetry witnesses** named in `selfhost/main.zbr` and required by
   `tools/check_mode_check.sh` — it must PASS `-c` and fail `--check-full`, proving the
   documented `-c` limitation is real.

Those are contradictory. Porting the check satisfies (1) and destroys (2) for this file.

**It is survivable but not free:** `check_mode_check` fails only when *no* witness
survives, and there are three, so fixing this leaves two. What it costs is a **witness**,
and the comment in `selfhost/main.zbr` naming all three would go stale with it.

**The options:**
- **a.** Port the check; retire this file as a witness; pick a replacement witness first so
  the set never drops below two; update the `main.zbr` comment.
- **b.** Port the check and split the file: a new negative fixture for the check, and leave
  a *different* construct here as the witness.
- **c.** Leave the gap, and record explicitly that the selfhost does not implement it — the
  worst option, because the two compilers then disagree on what is a valid program.

**Recommend (b)** — a witness should not be load-bearing for a bug fixture, and the
coupling is what made this invisible. Sean's call.


### BUG-246: an UNANNOTATED `Atomic(T)(v)` local mis-resolves `.add()` to `.append()` — OPEN (the `capture` block is a red herring)

> **RE-DIAGNOSED 2026-08-20. The heading changed because the original one names the wrong
> cause, and following it costs the next person the same hour it cost me.**
>
> **The capture block has nothing to do with it.** Measured, three shapes:
>
> | shape | result |
> |---|---|
> | `var t = Atomic(int)(0)` then `t.add(5)` — no lambda at all | **FAILS**, `no field or member function named 'append'` |
> | `var t: Atomic(int) = Atomic(int)(0)` then `t.add(5)` | passes |
> | the ticket's capture block, with the OUTER declaration annotated | passes |
>
> So the defect is that an **unannotated generic stdlib constructor is not typed**: with no
> type for `t`, the member call falls through to the stdlib heuristics and `.add` matches
> List's `.append`. The original repro simply had an unannotated outer `var`.
>
> **Same class as BUG-250** (a builtin constructor call the TypeChecker does not type),
> which is worth knowing because that one was fixed by typing the call.
>
> **THE CLASS WAS SWEPT 2026-08-20 AND IT IS BOUNDED — three untyped, one reachable.**
> Codegen emits bare constructors for seven generic stdlib types; the TypeChecker types
> four. The gap is `Atomic`, `ThreadPool`, `ObjectPool` — and only `Atomic` actually
> breaks:
>
> | untyped constructor | reachable defect? |
> |---|---|
> | `Atomic(int)(0)` | **YES** — `.add` falls through to List's heuristic and emits `.append` |
> | `ThreadPool(2)` | no — `submit`/`wait` collide with nothing (probed: runs) |
> | `ObjectPool(T)(n)` | no — `take`/`give`/`inUse` collide with nothing (probed: runs) |
>
> **So the trigger is not "untyped" alone — it is untyped AND a method name that COLLIDES
> with a stdlib heuristic.** `.add` is the collider because List has one. That predicts the
> next occurrence: any new stdlib type with an `add`-shaped method inherits this the day it
> is added, whether or not anyone touches Atomic. Typing the three constructors removes the
> class rather than the instance.
>
> **WHERE THE NEXT ATTEMPT SHOULD NOT START.** `TypeChecker.zbr`'s
> `typeFromExpr`/`typeFromRef` arms handle `List`, `HashMap`, `Chan` and `Set` and return
> `Type_.unknown_` for `Atomic` — in BOTH arms. Adding an `Atomic` case there looks like
> the fix and is not sufficient on its own: the ANNOTATED form already works while its
> `typeFromRef` arm also returns `unknown_`, so the annotated path is getting its dispatch
> from somewhere else. Find that mechanism first; the fix is to make the unannotated path
> reach the same place.
>
> A capture-binding change (binding a capture's declared type into the lambda's
> InferCtx, which `genLambdaEx` does for params and not for captures) was written, built
> and then REVERTED: it is defensible on its own terms but it did not fix this ticket, and
> shipping an inference change with no case that proves it load-bearing is how a
> regression arrives with nothing to blame. Recorded here as a real gap someone may still
> want to close, with a fixture, deliberately.


**Found 2026-08-03**, writing the §1b `Ws` fixture.

```zebra
var t = Atomic(int)(0)
sys.go(def()
    capture
        var t: Atomic(int) = t
    var _ = t.add(1)
)
```
```
error: no field or member function named 'append' in 'zebra_rt._Atomic(i64)'
```

This is the **BUG-120 family** — the `.add()` → `.append()` List rewrite firing on a
receiver that is not a List. BUG-120 fixed the case of a lowercase class instance by
consulting `InferCtx` at the call site; a variable re-declared inside a `capture` block
evidently does not get the same treatment, so the heuristic wins again.

**Narrow, and the boundary is known:** `store` and `load` on a captured `Atomic` work
(verified). Only `add` is affected, because only `add` collides with the List method name.

**Impact is larger than it looks** — this is the documented idiom for a shared counter
across threads, and it cannot be written. `Chan(T)` is the workaround (sum on the
receiving side), which is what `test/chan_thread_test.zbr` does.

**QUICKSTART's shared-counter example was removed rather than repaired** when the
surrounding `lambda` errors were fixed (BUG-245's note); restore it when this is fixed.


---

### BUG-243: fifteen corpus files have never compiled, and no gate could say so

**Found 2026-08-02**, working §2 of `docs/INSTRUMENT_PASS_PLAN.md`. An umbrella ticket:
these are not one defect, they are fifteen — but they were found by one method, they share
one cause of invisibility, and the inventory is more useful in one place than scattered.

**How they hid.** `full_sweep` gates against a **baseline** (337 of 421 files). A file
that has *never* passed is not in the baseline, so it cannot make the gate red however
broken it is. And none of these carries a `smoke*` registration, so nothing asserts they
should fail either. **A permanently-broken file is indistinguishable from an intentionally
negative one**, and both look like a green board.

Every one was verified by running `zebra <file>` directly — not inferred from the sweep.

| file | error | class |
|---|---|---|
| `expose_dotted_test` | emitted Zig: `expected ';' after declaration` | **codegen emits invalid Zig** |
| `typechecker_test` | emitted Zig: `unused function parameter` | **codegen** |
| `tc_check_test` | emitted Zig: `expected type '*tc_infer.TcExpr'` | **codegen** |
| `tc_infer_test` | emitted Zig: `struct 'tc_types.TcTypes' has no member` | **codegen** |
| `zebra_ide` | emitted Zig: `use of undeclared identifier 'Lis…'` | **codegen** |
| `progress_test` | `zebra_rt.zig:3617: expected 2 argument(s), found 1` | **BUG-241** (filed) |
| `gui_test` | `local variable is never mutated` | the BUG-230 const/var family |
| `csv_test` | `use of undeclared identifier 'CsvWriter'` | **BUG-242** (filed) |
| `bug106_heterogeneous_list_test` | `expected type 'i64'` | **regression fixture that does not run** |
| `bug108_this_outside_class_test` | `use of undeclared identifier` | **regression fixture that does not run** |
| `crossmod_expose_test` | `type 'array_list.Aligned(…)'` | cross-module expose |
| `generic_pair_test` | `expected type 'T', found '*T'` | generics |
| `json_parse_typed_test` | `no field or member function named …` | stdlib/typing |
| `raise_details_test` | `error union is ignored` | error model |
| `tc_types_test` | `struct 'tc_types.TcTypes' has no member` | (tc_* family) |

**The two rows that matter most are the regression fixtures.** `bug106_*` and `bug108_*`
exist to prove BUG-106 and BUG-108 stay fixed. Neither has ever run. **Those two fixes are
unverified**, and have been for as long as the fixtures have existed.

**Second-most: five files fail inside EMITTED Zig**, not at the Zebra source. Those are
codegen defects — the compiler producing invalid or ill-typed Zig — which is the class
`compile_check` exists to catch, and it does not sweep these because they are not in its
smoke-derived worklist.

**The `tc_*` / `typechecker_test` / `zebra_ide` group** looks like an earlier
self-hosting/IDE experiment. They may be legitimately stale rather than defects — decide
per file, and if stale, **delete or quarantine explicitly** rather than leaving them to
look like coverage.

**Disposition:** triage each into runs-but-sweep-shape (register), broken (fix), or stale
(delete/quarantine). Then close the class — see `tools/registration_check.py`, which makes
an unregistered, unexplained `test/*.zbr` a gate failure instead of a silence.


### BUG-240: `var s: Set(T) = {}` — annotated EMPTY set literal does not compile — OPEN

**Symptom.** An empty set literal with a type annotation fails; the same
annotation with a non-empty literal is fine, and the `HashMap` equivalent is fine.

```
def main()
    var s: Set(str) = {}          # <- FAILS
    print(s.len.toString())
```
```
error: expected type 'hash_map.HashMap(str,void,hash_map.StringContext,80)',
         found 'hash_map.HashMap(str,str,hash_map.AutoContext(str),80)'
```

Controls, both of which **pass** — this is narrow, not a general set failure:

| Form | Result |
|---|---|
| `var s: Set(str) = {"a"}` | ✅ works |
| `var d: HashMap(str, int) = {}` | ✅ works |
| `var s: Set(str) = {}` | ❌ the error above |

**Cause.** A bare `{}` is ambiguous (empty set vs empty dict) and the parser
resolves it to **`dict_lit`** unconditionally — only the annotation can say
which was meant. `genLocalVar` already knows this and special-cases it, but
**only for `HashMap`**:

```
selfhost/CodeGen.zbr:5830
    if gtll.name == "HashMap"
        # §28f: `var m: HashMap(K,V) = {}` — only the annotation can type an
        # EMPTY dict literal, so handle it here ...
        if ie is Expr.dict_lit as dl_init
            if dl_init.entries.len == 0
```

There is no sibling branch for `Set`, so an annotated empty set falls through
to the generic `dict_lit` lowering and emits
`std.AutoHashMap([]const u8, []const u8)` against a declared
`std.StringHashMap(void)`. Generated line:

```zig
const s: std.StringHashMap(void) = (blk_dl_1: { const _dl_1 = std.AutoHashMap([]const u8, []const u8).init(...); ... });
```

**Suggested fix.** Add the `Set` sibling next to the `HashMap` branch at
`CodeGen.zbr:5830`, emitting the annotated type's `.init(_allocator)` directly —
the same shape, and like that branch it needs no `const`/`var` mutation guard
because no `.put` is emitted.

**Relationship to BUG-239.** Found while verifying a claim made in the BUG-239
commit message (that no source syntax reaches a zero-element `set_lit`). That
claim **holds** — this path proves it, since even the annotated set form lowers
through `dict_lit`, never `set_lit`. BUG-239's `const` guard already applies
here, so the *never-mutated* half is fixed; what remains is purely the type
selection. The comment left in the `set_lit` branch stays accurate.

**Not fixed here deliberately:** found during a session working elsewhere in the
tree while a concurrent mutation-testing run was in progress; logged rather than
patched to avoid colliding with it.

---

### BUG-237: a union used WITHOUT being `exposing`-imported silently mis-emits `^T` payloads ⚠ OPEN

> **Triaged 2026-08-17 — still OPEN; `lint_stale_bugs` scores this a false positive.**
> The commit it counts as "claiming a fix" is the **BUG-232 unblock** noted at the bottom
> of this entry — adding `StringPart` to an exposing list, which is the WORKAROUND this
> ticket exists to remove, not a fix for it. Same false-positive class as BUG-106, and
> that tool ranks suspicion rather than closing anything, exactly so this stays a
> judgement call. Recorded so the next triage pass does not re-derive it.

**ROOT CAUSE FOUND 2026-07-31** — it is not about union payloads in general. It is that
**referencing a union that is not in the module's `use X exposing ...` list silently
skips its boxed-variant registration.**

```zebra
use Ast exposing Expr              # StringPart NOT exposed
if part is StringPart.expr_ as e   # still RESOLVES and compiles the front end
    someFn(e)                      # emits `someFn(e)` -- a raw *Expr. Zig rejects it.

use Ast exposing StringPart, Expr  # exposed
if part is StringPart.expr_ as e   # emits `const e_ptr = ...; const e = e_ptr.*;`
    someFn(e)                      # correct
```

`selfhost/CodeGen.zbr:6917` gates the deref on
`boxed_variants.contains_(union + "." + variant)`, and `boxed_variants` is populated
from same-module unions plus `populateBoxedVariants(..., deps_mt)` on each `use` — which
evidently follows the **exposed** names. So an unexposed union is still *referenceable*
(the front end resolves `StringPart.expr_` fine) but codegen has no record that its
payload is boxed.

**That combination — resolves, compiles the front end, emits wrong Zig — is the defect.**
Either the reference should be rejected ("StringPart is not exposed in this module"), or
the registration should follow reachability rather than the exposing list. The current
behaviour fails in the worst available way: a Zig type error naming `Ast.Expr` vs
`*Ast.Expr`, in generated code, for a mistake that is really a missing import clause.

**Cost of the ambiguity, measured:** six spellings tried before the import list was
suspected — bare binding, renamed binding, annotated local, pointer-typed parameter,
direct payload access, and a call in condition position. Every one emitted the pointer,
because none of them was the actual variable. `CgHelpers.zbr` "mysteriously" worked for
exactly one reason: it exposes `StringPart` and `TypeChecker` did not.

**Severity:** medium (silent mis-emit; the diagnostic points at generated types, and the
real fix is a missing name in an import list).
**Found:** 2026-07-31 while fixing BUG-232, which it blocked until the cause was found.

```zebra
union StringPart
    literal: String
    expr_: ^Expr

# inside a walker taking `Expr`:
if part is StringPart.expr_ as e
    someFn(e)          # emits `someFn(e)` where e is *Expr
                       # -> error: expected type 'Ast.Expr', found '*Ast.Expr'
```

A `^T` **struct field** derefs correctly — `cm.object` two lines away emits
`cm.object.*`, and `sx.start` (a `^Expr?`) emits `sx.start.?.*`. The gap is specific to
a `^T` reached through a **union payload binding**.

**Six spellings were tried, all emitting the bare pointer:**

1. bare binding as an argument — `someFn(e)`
2. renamed binding (matching a working precedent's names exactly) — `someFn(se)`
3. annotated local — `var pex: Expr = pe` emitted `const pex: Expr = pe;`, no deref
4. pointer-typed parameter — a `def f(be: ^Expr)` wrapper, which passed it on unchanged
5. direct payload access without a binding — `someFn(part.expr_)`
6. call in CONDITION position — `if boolReturningWrapper(e)`

**What makes it genuinely odd:** `selfhost/CgHelpers.zbr:268-269` does *the same thing*
and emits the deref (`const e_ptr = part.expr_; const e = e_ptr.*;`) — verified against a
FRESH emit from today's bootstrap, so it is not a stale artefact. The two source sites
are structurally identical down to the loop shape. Reduced probes of the same shape (bare
argument, void statement call, interpolated call, over a `union Part { expr_: ^Node }`)
all compile fine, so the trigger is not the construct alone and was not isolated.

Whatever the discriminator is, it is worth finding: it means the same source line emits
different code in two places, which is the kind of thing that makes a codegen bug look
like a user error.

**BUG-232 is no longer blocked** — adding `StringPart` to the exposing list fixed it, and
`bv_arity_interp_unchecked.zbr` now asserts the warning instead of pinning the silence.
This entry remains open on its own merits: the next person to reference an unexposed
union will lose the same hours, and a compiler that silently emits wrong code for a
missing import clause is a poor trade for the convenience of not writing the name.

---

### BUG-233: a lambda parameter that shadows an enclosing one emits invalid Zig ⚠ OPEN

**Severity:** medium (valid Zebra rejected; the error is a raw Zig one).
**Found:** 2026-07-30 by the **A5 examples sweep on its very first run** — the gate
that had never existed. `examples/panel_smoke.zbr` has been shipping broken.

```zebra
def view(g: Gui, model: Model)
    g.panel("Controls", def(g: Gui)      # lambda param deliberately named `g`
        if g.button("+1")
            ...
```

Emits a nested container whose `call` reuses the enclosing parameter name:

```zig
pub fn _zbr_fn_view(g: Gui, model: Model) void {
    g.panel("Controls", struct { pub fn call(g: Gui) void {   // <-- Zig: shadowing
```

```
panel_smoke.zig:45:46: error: function parameter 'g' shadows function parameter from outer scope
```

Shadowing an outer name in a nested lambda is ordinary in Zebra (and in Python,
which Zebra draws from). **Zig forbids it**, so codegen has to rename — it does not.
Re-using the receiver's name inside a UI callback is about as natural as Zebra
lambda code gets, which is why an example does it.

**Same family as BUG-220** (user names colliding with emitted names), and the fix is
probably the same shape: give the lambda parameter a reserved prefix, or rename only
on detected collision. BUG-220 chose `_zbr_fn_` for top-level defs for exactly this
class of reason.

---

**INVESTIGATED 2026-08-20 — not fixed; here is what the next attempt should start from.**

**A minimal NON-GUI repro, which this entry did not have.** The only recorded case was
`examples/panel_smoke.zbr`, which needs the GUI path to reproduce. It is seven lines:

```zebra
def runWith(n: int, f: def(int): int): int
    return f(n)

def outer(x: int): int
    return runWith(x, def(x: int): int      # lambda param shadows the enclosing one
        return x * 2
    )

def main()
    assert outer(21) == 42
```

```
error: function parameter 'x' shadows function parameter from outer scope
```

**BOTH COMPILERS, verified.** The selfhost and the bootstrap produce the identical error
on that file. That matters for scoping the fix rather than being a detail: the reported
case is a GUI example, `--gui-backend=*` delegates to **zebra-bootstrap**, so a
selfhost-only fix would leave `examples/panel_smoke.zbr` exactly as broken as it is now.
This is one of the cases where the standing "ship selfhost-only when parity is a tax"
allowance does not apply — parity IS the fix here.

**"Give it a reserved prefix" is the WRONG half of the ticket's suggestion.** Renaming
every lambda parameter changes the emitted Zig for every lambda in the corpus, which
churns both heavy golden baselines (`output_sweep`, and the round-trip's byte-identity)
for a defect that occurs only on collision. Rename ONLY on detected collision and no
existing program's emit moves at all.

**Detection is already available.** `isLocalOrParamName(name)` on the ENCLOSING generator
answers exactly the question — it consults `param_names` plus `infer_ctx.hasLocal` — and
in `genLambdaEx` the enclosing generator is still `self` at the point the parameter list
is emitted (`lg` is derived a few lines later).

**The actual work is the SUBSTITUTION, not the detection.** The parameter is emitted once
via `zigSafeName(p.name)`, but every reference in the body resolves through
`genIdentRaw`, which has no notion of a renamed local. So the fix needs a per-lambda
rename MAP threaded onto the lambda's generator — the `capture_fields` pattern
(`asMethod().withCaptureFields(cf).withInferCtx(lam_ctx)`) is the shape to copy — plus an
early arm in `genIdentRaw` ahead of the capture-field arm.

**The obvious shortcut does not work, and it is worth writing down so nobody re-derives
it:** emit the parameter renamed and immediately re-bind it (`const x = _zbr_lp_x;`) so
the body can keep using the bare name. Zig forbids a *local* shadowing an outer-scope
parameter too, so the re-binding is the same error one line lower.

**Nested lambdas need the renamed name to be UNIQUE, not merely prefixed** — two nested
lambdas both taking `g` would otherwise collide with each other under one fixed prefix.
The lambda's uid is already in hand for the struct label.

**Why it was not landed in the session that found all this:** it is a codegen change in
two compilers, one of them the regen authority, whose reported symptom is only fully
verifiable by a human running a GUI app. That is a poor thing to land unattended
overnight. The repro above turns it into a bounded, gate-verifiable task for whoever
picks it up: the fixture can be an ordinary `smoke_run`, no GUI required.

**Why nothing caught it:** it is not in `test/*.zbr`, and every heavy gate globs
that. `examples/` had no gate until A5 (`tools/full_sweep.sh --examples`), which is
now in the FULL tier. Not baselined — it is one of the two named non-passing entries
the sweep prints on every run.

---

### BUG-225: `s[i]` is typed `char` but yields a byte — ⬜ OPEN (1.x retype; 0.9 SEMANTICS DECIDED 2026-08-03)

> **DECIDED 2026-08-03 (Sean):** `s[i]` **is a byte**, and the documentation now says so
> plainly rather than hedging. This puts Zebra with **Go** (indexes to a byte, never
> pretends otherwise) and **Rust** (forbids `str` indexing outright) — good company, and
> the honest position: a UTF-8 string has no O(1) i-th character, so any language offering
> one is lying or copying.
>
> **This is NO LONGER A 0.9 BLOCKER.** What remains is the *type* (`char` holding a byte),
> which is a 1.x retype — see the blast radius below. QUICKSTART now leads with the rule
> ("index for bytes, iterate for characters") instead of burying it in a known-gap note.
>
> **BUG-247** (fixed) removed the one place the incoherence actively misled a user: the
> lexer reported a non-ASCII byte as a character that was not in the source file.
Found 2026-07-29 by the §28e derivation. `s[i]` is typed `char` (u21) but holds a raw
UTF-8 **byte**, so for any multi-byte codepoint it produces a character that is not in
the string — and it does so silently, with no error at any stage.

```zebra
def main()
    var s: str = "eéx"
    print(s.len.toString())              # 4  — bytes, honest
    print(s.codePointCount().toString()) # 3  — codepoints, honest
    print(s[1].toString())               # Ã  — WRONG. byte 0xC3 widened to U+00C3
    for c in s.chars()
        print(c.toString())              # e é x — correct
```

Emitted: `const a_index: u21 = s[@as(usize, @intCast(0))];` — the byte is widened to
u21, so `.toString()` UTF-8-encodes 0xC3 as the codepoint U+00C3 (`Ã`). Only `chars()`
is honest, because only `chars()` decodes.

**This is the one string incoherence with a real blast radius, and it is a language
design call, not a bug fix.** The selfhost compiler's own lexer is built on it —
`Lexer.zbr:116` is `def peek(): char` returning `src[pos]`, ~60 subscript sites in
that file alone, ~104 across `selfhost/`, and the 559 `c'x'` literals compare against
the result. Retyping `s[i]` to `byte` therefore requires deciding how `byte` and `char`
compare, which is design work.

Options, in ascending cost: (a) **document the limit for 0.9** and retype in 1.x —
Go and Rust both chose codepoint-with-a-documented-byte-layer and neither pretends an
index yields a character; (b) retype `s[i]` to `byte` and define `byte`/`char`
comparison; (c) make `s[i]` on a `str` an error and force `byteAt(i)` or `chars()`,
which is clearest and most disruptive. **Recommended: (a) for 0.9**, since the fix
competes directly with the pre-0.9 churn freeze and the honest documentation is most of
the value. Cross-ref [[§28e]] and BUG-223, which is the same incoherence at zero cost.

---

### BUG-212: selfhost emits `var` (not `const`) for a builtin-pointer local used only as a method receiver ⬜ OPEN
`var e = CodeEditor()` followed by `e.setText(...)` / `e.getText()` (and no reassignment)
emits `var e = _code_editor_new();`, which Zig rejects: `error: local variable is never
mutated`. `e` is a `*_CodeEditor` (a pointer) — calling `_code_editor_*(e, …)` passes the
pointer by value and never reassigns `e`, so it should be `const`. The mutation analysis
appears to treat a method call on the local as mutating its receiver, which is correct for
by-value struct receivers but wrong for these builtin heap-handle value types (code_editor;
likely also other pointer builtins). **Impact:** low — the IDE and normal code assign such
handles straight into a field (`m.editor = CodeEditor.forZebra()`), never a bare local, so
this only bites `var x = CodeEditor()` used purely as a receiver. Workaround: assign into a
field/struct, or add another use. **Fix direction:** in the const/var mutation scan, don't
count a method call as mutating the receiver when the receiver's inferred type is a
pointer-builtin value type (code_editor, …). Verify against the bootstrap's behavior.

### BUG-201: nested-container dispatch on call-result / mutable-loop receivers ⛔ OPEN (found probing BUG-196)
Two distinct facets surfaced when probing BUG-196, each its own mechanism:
- **(b1) `.add`/`.at`/`.len` on a `.at()` CALL-RESULT** — `m.at(0).add(99)` on
  `List(List(int))` → "no member function named 'add' in ArrayList". genMemberCall's
  `recv_t = inferExpr(m.object)` dispatch (CodeGen ~10630) *should* fire the `Type_.list_`
  arm, but `inferExpr(m.at(0))` isn't resolving to `list_` at the codegen call site even
  though the standalone `.at` inferExpr handler (TypeChecker ~1844 returns the element
  type) and the outer `inferExpr(m)` both work. Likely a codegen-`infer_ctx` population
  gap for chained call receivers. A chained-dispatch/inference fix.
- **(b2) mutating a `for`-binding element** — `for r in m: r.add(5)` now *dispatches*
  correctly (post-BUG-196) but hits "expected '*T', found '*const T'": Zig loop bindings
  are `const` (`for (m.items) |r|`), so mutating the element needs the by-pointer form
  `for (m.items) |*r|` + deref. A separate mutation-aware loop-lowering feature (detect a
  mutating method on the loop var → emit `|*r|`). Matrix-in-place-build pattern.

### BUG-101: AstBuilder uses `std.debug.panic` instead of diagnostics for parse-tree shape violations
- **Severity:** Low today (only the parser produces trees and it's well-tested) / Critical for VCS-merge-oracle future (operation-patches could synthesize trees)
- **Status:** Open
- **Symptom:** ~20 sites in `src/AstBuilder.zig` use `std.debug.panic` to assert parse-tree shapes (e.g., `:159, 551, 869, 896, 924, 941, 1086, 1589, 1650, 1908, 1928, 2052, 2131, 2169, 2277, 2430` — partial list). Failure mode is hard panic with terse message and no source span.
- **Reproducer:** None today from any well-formed source (they're invariant assertions). But under a future operation-patch VCS where structural edits synthesize trees, every site is a live hazard.
- **Root cause:** AstBuilder predates the Diagnostic infrastructure; these sites were the historical fail-fast paths.
- **Fix sketch:** Long-horizon refactor — fold each panic into the `Diagnostic` system with a "synthesized AST violated invariant X" error class, including the offending parse-tree NT. Short-term: leave alone but document the assumption that only the parser produces trees.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P0-2]).

---

### BUG-014: Regex lazy match is global, not per-quantifier
- **Severity:** Medium
- **Status:** Open — architectural limitation
- **Symptom:** In a pattern mixing lazy and greedy quantifiers (e.g., `<.*?>.*>`), the global `lazy_match` flag makes ALL quantifiers lazy.
  - Simple lazy patterns `<.*?>` work correctly.
  - Mixed patterns `<.*?>STUFF.*>` misbehave.
- **Root cause:** The current Thompson NFA passes a global `shortest: bool` to `matchAt`. When ANY `*?`/`+?`/`??` is parsed, `flags.lazy_match = true` is set for the whole regex.
- **Fix (architectural):** Requires either a priority-first NFA simulation or a backtracking regex engine.
- **Workaround:** For patterns needing mixed lazy/greedy, split into multiple regex calls or restructure the pattern.

---

### BUG-017: `len` on unknown-TC-type emits `.items.len` heuristic — imprecise
- **Severity:** Low
- **Status:** Open — known imprecision; deferred until ModuleInterface preserves return types
- **Symptom:** When a local variable's TC type is `.unknown` and `.len` is accessed on it, CodeGen emits `.items.len` as a last-resort fallback. Correct for `ArrayList`-backed `List(T)` values but wrong for user-defined structs with a field named `len`.
- **Proper fix:** Add a `.list { elem_type }` variant to `TypeChecker.Type`, store it in `ModuleInterface.methods` for list-returning methods, propagate through `inferCall` for cross-module calls.

---

### BUG-026: `instance_method_return_types` gaps for exposed-type method chains
- **Severity:** Medium
- **Status:** Open
- **Target:** Phase 7b / post-audit
- **Symptom:** `var b = a.someMethod()` may still produce `const b` in generated Zig if `someMethod` isn't in `instance_method_return_types`.
- **Root cause:** `instance_method_return_types` is populated by `buildModuleInterface`. It only captures methods whose return type resolves to a `.named` symbol with a non-primitive type.
- **Fix direction:** Populate `instance_method_return_types` more comprehensively, including methods returning `Self` or generic types.

---

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

