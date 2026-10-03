<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-517. Next new bug: BUG-518.**

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

### BUG-517: comparing a `chars()` element with a one-character string literal passes the front end and fails inside zig -- OPEN (found 2026-10-02)
- **Severity:** Medium (a leak: `-c` exits 0, the build fails in the runtime with `incompatible types: 'u21' and '*const [1:0]u8'` -- a Zig error about code the user never wrote, pointing into zebra_rt.zig)
- **Repro:**
  ```zebra
  def main()
      var n: int = 0
      for ch in "a1b2".chars()
          if ch >= "0" and ch <= "9"
              n = n + 1
      print(n)
  ```
  `zebra -c` accepts it; `zebra x.zbr` fails in zig. `chars()` yields codepoints (u21); the literal is a string.
- **Found by:** writing BUG-513's driver code (`keepFailedScratch` compared directory-name characters with "0".."9"); the first regen died in zig. The driver now uses `str.isNumeric()`.
- **Fix direction:** decide what a codepoint compared with a ONE-character literal means. Either lower the literal to its codepoint (`ch >= "0"` reads naturally, and Python users will write it), or refuse in the front end naming `ch.toString()` / a char literal. Either way the checker must type a `chars()` element and stop the mismatch before codegen. leakgen does not generate `chars()` comparisons -- add the shape to `fuzz/gen.py` with the fix.

---

### BUG-502: every dependency's classes are visible to every module of the program, transitively -- a bare class name a file never imported can resolve -- OPEN (found 2026-09-30)
- **Severity:** Low today (an invisible bare name is refused by the front end unless it ALSO means something else, which is how BUG-489 surfaced), but it is the root of a class of "which meaning wins" bugs.
- **Where:** `main.zbr` accumulates `dep_class_names` across EVERY module the build compiles and hands the whole list to `generateModuleWith` for each module, which registers each as a class. So a module sees classes from modules it never `use`d. BUG-489 fixed the one observable case (a name that is also a stdlib type) by filtering; the list itself is still program-wide.
- **Found by:** BUG-489's root-causing (2026-09-30).
- **Fix direction:** the per-module registration should be the module's own classes, its `exposing` names, and (for dotted `m.C` paths) the classes of the modules it `use`s directly -- not the program-wide union. Check whether the GameEngine bare-names any type it only reaches transitively before tightening: the front end currently accepts some such names, and tightening turns them into refusals.

---

### BUG-501: a container stored in a container is aliased on some paths and copied on others -- writes are silently lost, with no refusal -- OPEN (found 2026-09-30)
- **Severity:** High (silent data loss -- and possibly corruption, see the correction -- in ordinary code: a `HashMap(str, HashMap(str, int))` or `HashMap(str, List(int))` drops writes depending on HOW the inner container was reached, and nothing in Zebra or Zig says so)
- **Found by:** Fable (GameEngine port), measured again on `fd6ed7e` with both container kinds:

  | shape | HashMap inner | List inner |
  |---|---|---|
  | `if outer.get(k) as x` then mutate `x` | ALIASED (write seen) | ALIASED |
  | `outer.set(k, local)` then mutate `local` | COPY (write lost) | COPY (lost) |
  | returned from a `def` (`return m` from `get as`), mutated through a temp | SHALLOW COPY -- see below | COPY (lost) |
  | the same, mutated as a statement `f(outer, k).set(...)` | Zig: `expected type '*T', found '*const T'` | -- |

  Repro: `test/`-shaped program in the filer's notes (two maps, two lists, the four shapes; prints `map: get-as=5 set-then-mutate=0 returned=9` / `list: a=1 ... b=0`).
- **CORRECTION, same day -- the "returned" row is worse than a copy.** The first measurement read
  it as ALIASED (the write was seen); Fable's shape read 0. Both functions emit
  `return _zbr_unboxed(m);`, a by-value copy of a Zig `StringHashMap`, whose struct holds a
  POINTER to its storage. When the inner map already had storage, the copy's write landed in the
  SHARED buffer and the original's lookup happened to find it (while its own count was not
  updated); when the inner map was empty, the copy allocated fresh storage and the write was lost.
  So the outcome depends on the map's allocation state, and a copy that half-shares storage can
  CORRUPT the original (a count that disagrees with the buffer, a grow that frees storage the
  original still points at). Any fix must make these copies either real (deep) or not copies.
  Fable's repro, verbatim (prints 0; with the inner map pre-populated the same code prints the
  write): a `def inner(outer, k)` returning the `get as`-bound map, then `var m1 = inner(outer, "a")`
  / `m1.set("x", 5)` / read back through `outer.get("a")`.
- **A live instance, found by auditing for the shape (Fable, same day):** the GameEngine's
  `PlayerData.getScope` returned an inner map by value from a `HashMap`-of-`HashMap` field, and
  the demo's "bump Wins" wrote through the returned copy -- WORKING, by the shared-storage
  accident above. It would have stopped working the first time that scope started empty. Now a
  class (engine findings ledger F18: "a map inside a container or across a def boundary is
  wrapped in a class", pending the decision).
- **SCOPE CORRECTION, 2026-09-30 (measured on the batch-1 tree) -- this is not about nesting.**
  The root is lower: a Zig container (`std.ArrayList`, `StringHashMap`) is a struct holding a
  POINTER to its buffer plus its own length/capacity, and Zebra copies that struct by value at
  every assignment. The copy shares the buffer but not the length, so it is neither a copy nor
  an alias -- the next append on either side can overwrite the other's elements. Nesting is one
  way to reach it. Three more rows, no container-in-container anywhere:

  | shape | result |
  |---|---|
  | `var b = a` (List with one element), `b.add(20)`, `a.add(30)` | `b[1]` reads **30** -- `a`'s append overwrote `b`'s element |
  | `def all(): List(int)` returning `.items`; caller `got.add(2)`, then `bag.items.add(3)` | `got[1]` reads **3** |
  | a struct with a List field copied (`var r2 = r1`), both then appended to | `r2.xs[1]` reads `r1`'s value |
  | `this except xs = ...` on such a struct | the same half-copy: `r3` (len 3) appends into the buffer `r1` (len 2) still owns |

  The field-return row is the common one: a class that hands out its list is ordinary code.
  Params are unaffected (a container parameter is passed by pointer -- `fill(c)` mutates `c`).
- **Decision (Sean, 2026-09-30): SHARED semantics** -- given for nested containers, before the
  root above was measured. Applied honestly it means containers are REFERENCES everywhere
  (`var b = a` aliases, as in Python/Cobra), i.e. a container value is a pointer to a heap
  container in the emitted Zig. That is a change to what assignment means for every container,
  every struct holding one, and `except` -- multi-day, witnessed by the heavy gates, and larger
  than the nested-only fix that was approved. Held for Sean's confirmation of the wider scope;
  the alternative is an interim refusal wherever a container is copied out of a live location.
- **Where it comes from:** the 2026-09-24 container work boxes an inner container and COPIES it out when it reaches a VALUE slot (`genValueOf`, `_zbr_unboxed`) -- deliberately, so a copy-out is the documented rule in some positions. What is not decided anywhere is the rule itself: whether a container nested in a container is a REFERENCE (what `get as` and, for maps, a returned value already do) or a VALUE (what `set(k, local)` does). The two kinds disagree on the return path, which means the current behaviour is not one rule applied twice.
- **Decision needed (Sean):** reference semantics for nested containers everywhere (the least surprising for Python/Cobra readers, and what the engine assumed), or value semantics everywhere with the aliasing paths made copies -- and in either case a refusal or a warning where a write would be lost. Until then the engine wraps inner maps in a class (`workspace.TagList`, `shop_util.Inventory`), which is a reference.
- **Also:** the statement-form compile error in row 4 is a leak on its own (a call-result receiver that is a boxed container passed as `*const`).

### BUG-449: `HttpRequest` cannot be constructed from Zebra — OPEN (found 2026-09-25)

`var r = HttpRequest()` -> "undefined name: 'HttpRequest'". A clean refusal, but it means a
router written as `def route(req: HttpRequest): HttpResponse` (the book's Project 2) cannot be
unit-tested without starting a server. A limitation, not a leak.

---

### BUG-306: `inferExpr` cannot see MODULE-SCOPE declarations, so every type-based dispatch guard needs a bespoke oracle — OPEN (found 2026-08-23)

**Two bugs from one gap, and the patches sit TEN LINES APART in the same function.**

`inferExpr` is documented in `selfhost/CodeGen.zbr` as seeing "only locals/params". Every
guard that decides a method lowering by asking the receiver's TYPE therefore misses a
module-scope variable, silently, and falls through to whatever the default branch is. In
`genMemberCall` that default is "treat `.add` as a `List` append".

| bug | type | patch |
|---|---|---|
| BUG-153 | a module-global `Atomic` | `isModuleGlobalAtomic` |
| BUG-264 | a module-scope `StrSet` | `isModuleGlobalStrSet` |

Both oracles do the same thing — walk `module_decls` looking for a `Decl.var_` with a
matching name and the right `TypeRef` — and both exist only because the general question
cannot be asked. **A third type will need a third.**

**WHY IT STAYS INVISIBLE.** The wrong branch is the RIGHT ANSWER for the common case:
every module-scope collection in the compiler's own source was a `List(str)` until someone
declared a `StrSet`. So the guard is not merely missing a case, it is confidently correct
until the moment it is confidently wrong, and nothing distinguishes those two states from
inside.

**THE STRUCTURAL FIX** is to let `inferExpr` resolve a module-scope declaration, at which
point the existing `Type_.named` test in each guard starts working and both bespoke
oracles can be deleted. That is a change to inference rather than to a lowering, which is
why BUG-264 was fixed with the cheap precedented patch instead — recorded here so the
third instance does not get a third one-off.

**Not made a gate.** What would catch this class is the ROUND-TRIP, and only because the
compiler's own source happens to use the constructs; there is no general instrument. See
BUG-264 for why no `test/*.zbr` fixture can express it: `StrSet` is not a user-facing type.

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

**REPRODUCTION ATTEMPTED 2026-08-30 — THE STATED MECHANISM DOES NOT REPRODUCE.**
Tested against the compiler's own code, not a synthetic case: `selfhost/AstWalk.zbr:27`
exposes `StringPart` and `:118` uses `if part is StringPart.expr_ as ex`, i.e. the
workaround this entry exists to remove is currently in place. Removed it on a COPY and
emitted with `zebra.exe`:

| | result |
|---|---|
| control (StringPart exposed) | **emits**; only error is `unable to load 'Ast.zig': FileNotFound`, the expected DEPMISS for a library module emitted standalone |
| StringPart removed from `exposing` | **`zz_walk_nox.zbr:118:28: error: undefined name: 'StringPart'`** — front end REFUSES, nothing emitted |

The entry's mechanism requires that the reference *"still RESOLVES and compiles the front
end"* and then emits a raw `*Expr`. It does not: the resolver refuses, with a correct
line and column. Two synthetic constructions (union unreachable, union reachable through
an exposed struct field) refuse the same way.

**So the SILENT half — the G1 property — is closed.** What remains is at most a usability
question (a union must be `exposing`-imported to be named), which is a defensible rule and
not a 0.9 blocker. **Reclassified: not a silent-wrong-answer bug.** Whoever picks this up
should decide whether the refusal IS the intended resolution and close it, rather than
implementing the boxed-variant registration the entry proposes.


---

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

