<!-- doc-status: live -->
# Next steps → 1.0 (the freeze)

**The honest blocker is no longer "build the remaining features" -- it is lock
down, validate, and prove what already exists.** That reframing comes from
`docs/archive/ROADMAP_TO_1.0.md` (drafted 2026-06-23, archived 2026-08-29 once its content
landed here), and it still holds: the features are shipped, so the roadmap question
is *what gates declaring the surface stable*, not *what is left to write*.

A 2026-07-28 audit of the blocker list concluded **"one technical bug plus the
freeze"**. That bug was BUG-221 (module init not transitive -- a live segfault), and
it is **now fixed**. What has changed since is not the structure but the evidence: a
month of dogfooding surfaced a class of silent-wrong-answer defects that a freeze
should not ship over.

Judge items against [docs/PRINCIPLES.md](docs/PRINCIPLES.md); measurements are in
[docs/archive/FINDINGS.md](docs/archive/FINDINGS.md).

## WHAT THE ROAD IS MISSING — a 2026-09-14 read of this queue (Fable 5.1; Sean to red-pen)

Sean's prompt was V's `v up`. Reading the queue against "what does a stranger need from a
1.0" rather than "what is left to build" turns up seven things that are not on it, and one
ordering change among things that are. None is a language feature; every one is about the
PROMISE, which §15 says is the open act.

1. **The freeze needs a SURFACE it can be checked against, and none is written down.**
   §15 says "lock the API surface with a stability promise" and lists milestones, not a
   surface. The repo already knows how to do this right: `str_ownership.md` is DERIVED from
   the emit and gated so a flip cannot ship silently. Do the same for the whole stable
   surface -- keywords (from `Token.zig`'s table), stdlib types and their methods (from the
   checker's dispatch tables), CLI flags (from the usage text), `--target`/`--gui-backend`
   values -- one generated `docs/SURFACE.md` plus a `surface-freeze` gate that fails on
   any diff not accompanied by a CHANGELOG line. After 1.0 that gate is the stability
   promise, mechanically; before 1.0 it is the inventory that says what the promise covers.
   **Built 2026-09-14** (`tools/surface_inventory.py`, `docs/SURFACE.md`, gate `surface-freeze`).
   The derivation also found that `Math` is OPEN (unlisted members pass through to
   `std.math`), which the promise has to say explicitly.
2. **`zebra up`** (Sean, 2026-09-14, after V). The installer already lays out
   `~/.zebra/current` + PATH; `up` is: resolve the latest release for this platform from the
   GitHub releases API, download the archive beside `current`, verify against
   `SHA256SUMS.txt`, unpack, swap `current` atomically, print old -> new. Worth doing IN
   ZEBRA (Http + File + gzip/zip + tar are all stdlib) -- it is the first dogfood program a
   stranger runs, and the release layout was designed for it without saying so. Companion
   flags that come free: `zebra up --check` (is there a newer one), `--to 1.0.2` (pin),
   `--list`. Not needed for 0.9; needed the day two releases exist.
   **BUILT 2026-09-14** (`runUp` in selfhost/main.zbr, ~150 lines of Zebra): `zebra up`,
   `--check`, `--to VER`. Finds the release through `latest/download/SHA256SUMS.txt`
   (no API, no rate limit), verifies with `Hash.sha256`, unpacks with the platform `tar`
   (bsdtar reads zip on Windows), keeps `previous/` once. POSIX swap tested end to end
   against the real rc2 archive (91 MB, 18 s); the Windows swap (a detached helper that
   waits for zebra.exe to exit) is written and UNTESTED -- needs a run on torial against
   an install.ps1 layout. `--list` not done.
3. **A version pin FOR PROJECTS, or the promise is unenforceable from the user's side.**
   `zebra build` / `zebra.toml` (whichever the build system settles on) should be able to
   say `zebra = "^1.0"` and have the compiler refuse with a clear line when it does not
   satisfy it. Costs a day; without it a project cannot state what it was tested against.
4. **A deprecation POLICY, which makes the warning tier a PREREQUISITE of the freeze rather
   than a nice-to-have beside it.** DRAFTED 2026-09-14: `docs/design/stability_policy.md` (status
   DRAFT, Sean's red pen) -- the promise, the frozen set, the not-frozen set, the
   warn/rewrite/remove schedule, versions, non-goals. PRINCIPLES.md already says "deprecation by migration,
   not by dialect", but the only mechanism the compiler has is error-or-silence. A 1.0
   surface that can never warn can only ever break. Two sentences in the policy: what
   "stable" excludes (`zig"..."` literal contents; the exact text of diagnostics; emitted
   Zig shape; anything marked experimental), and the N-release warning period before a
   removal.
5. **The version numbers do not agree, and a stranger will notice before we do.**
   DONE 2026-09-14: CHANGELOG.md now explains the two scales up front and carries a
   `## Release 0.9.0` section; milestone headings kept (append-only history). The
   release just cut is `0.9.0-rc2`; `CHANGELOG.md` runs `[0.9] -- 2026-04` through
   `[0.15] -- 2026-05 (in progress)`, because those were feature MILESTONES, not releases.
   Reconcile before 1.0: either renumber the CHANGELOG headings as milestones (`[M15]`) with
   a note, or fold them into release sections. The §15 "final CHANGELOG pass" should
   include this or it will be the first issue filed against the release.
6. DONE 2026-09-15 (Sean: "the smoke being green is very good"): `experimental: false`,
   install doc updated. Was: **macOS is still `experimental: true` in release.yml and the install doc says "until a
   smoke has run green there" -- the release workflow RUNS that smoke on macos-latest.**
   If rc2's macOS leg was green, the note is stale and the flag can flip; if it was not,
   1.0 should say two platforms, not three-with-an-asterisk. Either way it is a decision
   the queue does not currently hold.
7. **The bootstrap sunset needs a 1.0 decision, not a trend line.** DECIDED 2026-09-15
   and DONE 2026-09-16 (Steps 0-4; `src/` is deleted, one compiler, no dependencies,
   and the dead keyword machinery is gone):
   (a), plan in `docs/design/bootstrap_sunset.md` -- which also corrects this entry: the
   selfhost has been its own regen authority since 2026-08-30 (`rebuild.sh` regenerates
   with `zebra.exe`); what the bootstrap still is, is `selfhost-div`'s witness and three
   delegated flags. Was: The selfhost is the
   shipping compiler; the FROZEN bootstrap is still the regen authority and
   `selfhost-div`'s only independent witness. A 1.0 that ships two compilers with the
   primary one unable to regenerate itself is a fact the release notes have to explain.
   Decide which of: (a) selfhost becomes regen authority before 1.0 (criterion 2 in the
   0.9 queue), (b) the bootstrap ships as a documented "reference compiler, frozen at
   0.9", or (c) it is deleted. The number that drives it is printed every daily run.
8. **Say what 1.0 does NOT include**, so absence reads as a decision: no package manager
   (`use` resolves paths; third-party code is `BuildTarget.linkLib` or a checkout), no
   editor extensions beyond the LSP and zebra-ide (a TextMate/tree-sitter grammar is a
   two-hour adoption item worth doing anyway), no Zig-version portability (a release is
   pinned to the Zig it bundles, which is the right answer and should be stated).

DECISIONS 2026-09-15 (Sean, on the 2026-09-14 read above and the surface measurement):
- **`String` alias removed** ("Your str case wins! Let's nuke String"). DONE 2026-09-15:
  the parser refuses `String` wherever a type is read (`eatTypeName`, so annotations,
  generics args and `extend` targets all hit one line) naming `str`; every alias
  site in selfhost/*.zbr is gone (the BUG-425 canonicalisation flips to "str" as the
  only key; `_ext_str_*` is the emitted name); 18 corpus files and `selfhost/Ast.zbr`
  (89 annotations) rewritten mechanically; fixture
  `test/fail_fixtures/string_alias_rejected_test.zbr`; QUICKSTART §3 row dropped.
  The bootstrap (`src/`) keeps accepting the alias only because it is retiring (next).
- **Item 7 → (a)**: the selfhost becomes regen authority and the bootstrap is retired
  ("Let's move to no bootstrap. Worth the effort imo"). Plan: `docs/design/bootstrap_sunset.md`.
  DONE through Step 3, 2026-09-16 (`src/` deleted). It freed one more word on the way
  out: `has`, which only the bootstrap's grammar ever accepted (68 keywords).
- **Item 3 → `b.requires("^1.0")`** on the Build object in `build.zbr`, compared to
  `_zbr_version`, refused by name with `zebra up` as the suggested fix.
- **Open receiver tables** (the ~16 stdlib runtime object types whose instance methods
  the generic dispatch passes through unguarded): close them via the BUG-369 recipe
  ("resolving in general also gives us better -c coverage"), and teach
  `surface_inventory.py` to derive them, so `docs/SURFACE.md` §2's "not yet in the
  derived set" paragraph shrinks to arities.

- **Generic interfaces** (2026-09-16, from freeing `same`; Sean: "let's prioritize for
  1.0"). LANDED the same day: `interface Comparable(T)` as a comptime type function,
  `implements Comparable(Score)`, instantiations as annotations, one vtable per
  instantiation with the parameters substituted, arity refused in the front end
  (test/generic_interface_test.zbr, fail_fixtures/generic_interface_arity_test.zbr).
  SECOND PASS 2026-09-16 (overnight): the checker types a generic-interface value as
  the interface (a wrong method name through `Comparable(Score)` is refused; return
  types flow; a method returning the interface's own type parameter is untyped at the
  call), and -- found on the way -- PLAIN interface values had never refused an unknown
  member either (`sh.bogus()` on a `Shape` reached zig): both refuse now
  (fail_fixtures/interface_unknown_method_test, generic_interface_unknown_method_test;
  test/generic_interface_typed_test). The `where T implements X` constraint is
  ENFORCED at instantiation and at an annotation, with T substituted
  (fail_fixtures/generic_constraint_unmet_test, generic_constraint_primitive_test).
  THIRD PASS the same night: a generic class implementing plain and generic
  interfaces (test/generic_class_iface_test). Found on the way, and worse than the
  edge itself: a generic instance coerced to ANY interface from an identifier hit
  "undeclared identifier '_vtable_Box_Show'" (only the inline ctor worked), and a
  generic class type as a parameter or annotation was emitted as the VALUE type, so
  `def show(b: Box(int))` refused its own instances ("expected type 'T', found '*T'").
  Both fixed: the coercion reads the vtable off the value (`@TypeOf(v.*)._vtable_I`)
  and `Box(int)` is a pointer like every class. STILL LEFT (CLOSED 2026-09-24): an interface extending a
  generic one -- built (`interface Ranked(T) implements Comparable(T)`, plain and generic
  sub-interfaces, classes and generic classes through the chain); two instantiations of
  one generic interface by one class -- REFUSED by name (one method of a name cannot
  satisfy two); the `items = List(T)()` paper cut was the field-initialiser shape of a
  generic class with no `cue init`, whose synthesized init returned a value and never
  compiled -- fixed. test/generic_iface_super_test, generic_class_default_init_test,
  fail_fixtures/generic_iface_twice_test.

ORDERING CHANGE among existing items: the **warning tier** (below) moves from "several
items need it" to "the freeze needs it" (item 4). The **trip test** stays where its own
entry puts it -- the highest-yield thing to run BEFORE declaring a surface stable, since a
frozen interaction bug is frozen for the whole 1.x line.

Not proposed: anything that adds to the language. The queue's own opening paragraph is
right, and V's `up` is a tooling promise, not a language one.

## MOVED FROM THE 0.9 QUEUE, 2026-09-10 — B1 mutation testing / B2 coverage spike

`tools/mutation_check.py` exists and has one valid run (5 mutants: 2 detected, 3
survivors, ~370 s/mutant). A full 60-mutant run is ~6 h of laptop time and answers a 1.0
question — "is the stability promise backed by gates that can fail?" — not a 0.9 one.
The entry text, postmortems and survivor list stay in `docs/NEXT_STEPS_to_0.9.md` (B1)
and `docs/testing_strategy.md` §B1; this is the pointer.

## POST-0.9, PRE-1.0 — ADOPT ZIGZAG'S FALLIBLE `init`/`update`/`view` (Sean, 2026-08-25)

We are pinned to `git+https://github.com/meszmate/zigzag#v0.1.5`, which **is the latest
release** (2026-05-06) — there is nothing to bump to. The resolved hash reads
`zigzag-0.1.2-…`; that is upstream's `.zon` version lagging its own tag, not a stale pin.
Main is ~20+ commits ahead through 2026-08-14.

**THE CHANGE TO ADOPT: PR #132, "let init, update and view return error unions".**

**It is OPT-IN and backward compatible** — both signatures compile simultaneously,
detected per-function at comptime, existing code unchanged. An earlier note in this file
called it a "BREAKING MVU signature change" and advised waiting; that was read off the
commit TITLE, and the PR says otherwise. Corrected rather than left, because this queue is
what the next session works from.

**WHY IT IS WORTH ADOPTING, in this repo's own terms.** The stated motivation is 245
instances of `catch ""` / `catch "?"` / `catch "Error"` in their examples — allocation
failures becoming rendering artifacts *indistinguishable from legitimate output*. That is
UNGIT "nothing fabricated" exactly, and the same defect class as `gui_scaffold_check`
printing "startup path clean" about a scaffold that did not exist (BUG-298).

Note the direction of the purity argument, because it is easy to get backwards: a fallible
`update` does NOT erode MVU's replayability. The alternative is not a pure `update`, it is
one that **silently produces a wrong model**. A propagated error is honest and replays as
"it failed here"; a swallowed OOM destroys replay fidelity far more thoroughly. `update`
still does no I/O and holds no hidden state either way.

**WHAT IT TOUCHES HERE:** the tui section (`selfhost/gui_tui_section.zig`, selected by
`CodeGen.guiSelectPreamble`) declares `init`/`update`/`view`, plus the `build.zig.zon`
fingerprint whose regeneration procedure is documented beside `luiBuildZon()` in
`selfhost/main.zbr`. (The bootstrap's inline `.tui` arm and its `main.zig:1281` note
are gone with `src/`, 2026-09-16.)

**ALSO WORTH TRACKING, not adopting:** their recent Windows resize-detection and Kitty
graphics fixes. This repo is Windows-primary, so that work is directly relevant — and it
is the platform long tail we would inherit if we ever forked, which is the main argument
against doing so. If insulation is wanted without a fork, VENDOR A PINNED COPY the way
`sqlite` is vendored; the shape already exists under
`examples/counter_gui/zig-pkg/zigzag-0.1.2-…`.

**THE THING TO WATCH is not this change but whether the opt-in discipline HOLDS.** A
framework that adds capability without forcing migrations can be followed at our own pace;
the day that stops being true is the day the vendor-and-pin question becomes urgent.


## THE ORACLE ARGUMENT FOR AN `algorithms` NAMESPACE (Sean, 2026-08-26)

Sean's proposal: a stdlib `algorithms` namespace implementing the major classes from *The
Art of Computer Programming*, as a dogfooding exercise that stresses the language outside
compiler work.

The obvious virtues are real -- TAOCP is array- and numeric-heavy, which is precisely the
coverage gap `construct_histogram` measured; and it exercises the language somewhere other
than its own implementation. **But the strongest argument is a different one.**

**IT GIVES US AN ORACLE WE DO NOT CONTROL.** Every test in this repository asserts what
*we* decided is correct. That is why `boundary_check` is singular: its expectations were
written from the language reference BEFORE the compiler was run, so it can find something
that was wrong on day one. Everything else is a golden baseline and can only find drift.

TAOCP algorithms have externally-defined correct behaviour, published invariants, and
worked examples. A wrong answer is *definitively* wrong rather than wrong-by-our-own-
declaration. That is `boundary_check`'s property, available at scale, from a source with no
stake in our compiler. **Volume 2's random-number generators are the sharpest case: they
come with exact expected outputs, and there is no arguing with them.**

Secondary: TAOCP algorithms are specified with loop invariants, which is Meyer's
`require`/`ensure` territory and would be the first serious exercise of Zebra's contracts
outside the compiler.

## COMPLEXITY AS REFLECTION DATA, AND THE STATIC COST DIAGNOSTIC

Sean's first shape was `algorithms.sorting.<bigO>.<name>` -- put the cost in the import
path so it is visible where the programmer already is. **The instinct is right and is
exactly Knuth's mandate moved EARLIER than he moved it**; the mechanism has problems:

- complexity is not one number (quicksort: n log n average, n^2 worst -- which goes in the
  path?), and space complexity is a second axis;
- it makes a *property* into an *identity*, so improving an implementation changes its
  import path and breaks callers.

So keep the instinct and change the mechanism -- identity in the path, cost in the
reflection data, which is the substrate already proposed above for the Hoare criterion:

```
algorithms.sorting.quick          # identity
Reflect.complexity(quick)         # { best, average, worst, space }
```

**AND THEN IT COMPOSES INTO SOMETHING NEITHER OF US STARTED WITH.** If complexity is
queryable metadata and the compiler already has the call graph, then *a quadratic sort
called inside a linear loop is a compile-time diagnostic*. That is "tell the programmer
what parts of their program are costing the most" delivered **statically** -- before the
program runs, with no profiler, no instrumentation, and no measurement infrastructure to
keep honest. It is also deterministic, which means unlike anything timing-based it could
actually be GATED (this repo's timings swing 2x on identical binaries).

The `algorithms` namespace is what would make it real: the first body of code carrying
honest complexity annotations to reason over.

## THE TRANSFORM INTERFACE (Sean's design, 2026-08-26)

Sean proposed wrapping each compiler transformation in an interface: the code shape to
match, the code to generate, the metadata for reflection, and the transform command.
**Agreed, with names:** `match` / `rewrite` / `metadata` / `trigger`.

The reason to insist on it is not tidiness. **A transform that cannot describe itself cannot
be listed, cannot be disabled, and cannot be tested.** Today's five known transformations
(TCO-wrapping, `^T` auto-boxing, const-vs-var from mutation analysis, temp materialization,
`throws` auto-propagation) are ad-hoc code in CodeGen, which is exactly why nobody can
enumerate them and why the TCO fall-through hazard needed a lint rather than a diagnostic.

**Opt-in reporting is right** (automated workflows must not have to parse new output), with
one refinement: the *list of applicable transforms* should stay queryable even when the
*report* is off. "What could have happened here?" is then answerable at zero cost.

## A WARNING TIER, which several of these items need (Sean, 2026-08-26)

**BUILT 2026-09-24.** Warnings print as `file:line:col: warning:`, reach `zebra
diagnostics`/the LSP, never fail a build alone; `--warnings-as-errors` fails on any. The
first warning that fires on ordinary code is `@deprecated("msg")` on a def / method /
static (in-module and across `use`); the older `--warn-non-exhaustive` and the
function-used-as-a-value warning ride the same tier. A cost diagnostic or a transform
notice is now one `ctx.addWarn` away. (Was:) Zebra has no warnings today: everything is an error or silence. The complexity budget wants
to be a warning class with `--warnings-as-errors` for those who want the tighter contract.
So do cost diagnostics, transformation notices, and any future advisory. **Building the tier
once unblocks all of them**; adding each as a bespoke flag does not.

## DECIDED 2026-09-16 — `cue` IS THE PROTOCOL KEYWORD; `cue deinit` IS THE OPEN ONE

Sean: "the intention is for it to be the equivalent of the dunder methods for python" --
then, on the analysis: "I'm actually ok if you do all the ones but `deinit` now".

**The rule.** A `cue` is a method the *compiler* calls, at a place the language defines;
a `def` is a method *your code* calls. The set is closed and lives in one place
(`selfhost/Parser.zbr` `CUE_NAMES`, derived into `docs/SURFACE.md` "Cues" by
`surface_inventory.py`), so adding one is a surface change with a diff. Landed 2026-09-16:
`init`, `toString`, `equals`, `hash`, `compare`, `iter`, `next` -- QUICKSTART §5 "Cues",
`test/cue_protocol_test.zbr`, four refusal fixtures. The ranking that put these first: each
already had a compiler call site (print/`${}`, `==`, HashMap keys, `<`/sort, for-in) that was
either name-dispatched by convention (`toString`) or missing (a class as a HashMap key hashed
its POINTER; `<` on a user type was a Zig error). Cues made the convention checkable.

**Open: `cue deinit`.** Every other cue is called at a syntactic site. `deinit` is called at
end of *scope* or end of *arena*, and the language has no written memory model yet (the
section below). What has to be hashed through with Sean, scenario by scenario, before it
lands: (1) a class instance is a pointer -- when the last local goes out of scope, does
`deinit` fire, and what about the instance still held in a List? (2) inside `allocate`
(arena scope), does the arena's drop call `deinit` on each object it holds, in what order,
and does a `deinit` that touches another arena-held object see it alive? (3) a struct by
value copied into a List: one `deinit` or two? (4) `errdefer`-shaped cleanup on a throw
mid-constructor. (5) interaction with `--turbo`/`--release` (never stripped -- it is not a
contract). The candidate semantics that survives (1)-(3) is "arena-scoped only: `deinit`
runs when the arena that owns the object is dropped, in reverse allocation order, and
never for the default allocator" -- which makes it useless outside `allocate`, so it is not
decided. Do not land a `deinit` that fires at the end of a block for a pointer type;
that is the C++ destructor on a reference type and it double-frees the moment the object
escapes.

**Not cues, on purpose:** `len` / `contains` (`x.len` is a field on the builtins, and a user
type declaring `def len(): int` is an ordinary method -- no operator dispatches on it),
`at` / index (no `[]` operator on user types yet; when there is, it goes in this list),
arithmetic operators (rejected: `+` on a user type reads as overloading, and the language
has taken the Zig position on that).

## ITERATORS / GENERATORS — a real gap, with a real receipt

`yield` was removed and nothing replaced it. Sean's case: parsing a large string with
`.split()`, forced to materialise a full `List(str)` to walk it once; writing a custom
lazy splitter in .NET cut RAM pressure **and** increased speed.

That is the Perlis test failing -- materialising a list you will walk once and discard is
attention to the irrelevant. Liskov's CLU had iterators for exactly this. Reopen with the
dogfood evidence rather than in the abstract.

**2026-09-16: both halves exist -- CLOSED.** `cue iter` / `cue next` (above) make any type a
`for x in obj` iterable, lazily; and `def f(...): Iter(T)` with `yield` writes that class
for you (CodeGen.genGeneratorFn: the body lowered to basic blocks, `next()` a
`while (true) switch (state)`, locals as fields). The .NET lazy splitter is now
`def split(s: str, sep: str): Iter(str)` with a `yield` in a loop. What is NOT in v1, each
refused by name rather than miscompiled: a generator METHOD (needs the receiver captured),
a yield under `branch`/`try`/`with`/`using`/`allocate` or `if x as y`, a yielding `for`
over anything but a List / range / cue iterable, and `Iter(T)` as an annotation (the call
is bound and inferred). Any of those is a bounded extension of the same lowering.

## THE WRITTEN MEMORY MODEL — what it would actually contain

Not formality: today these answers exist only as folklore plus one hazard test, so nobody
can reason about a concurrent Zebra program without reading the runtime. Roughly two pages
answering:

- what does `sys.go` guarantee about writes made **before** the spawn?
- is `Atomic` sequentially consistent, or acquire/release?
- what edge does a `Chan` send/receive establish?
- may an `allocate Arena()` scope cross a thread boundary? (**Today: no** -- 77% crash,
  captured by `arena_concurrency_hazard_test`, and the rule "allocate-scopes are
  single-threaded-only" lives in a NEXT_STEPS bullet rather than in the language docs.)
- what does sharing a `List` across threads guarantee? (Today: nothing, unstated.)

## PARNAS TABLES — a worked example, not a description

Parnas's argument: for a function whose behaviour splits into cases, prose and nested `if`s
both hide whether the cases are **complete** and **disjoint**. A table makes both
mechanically checkable.

Zebra's `File.delete` after BUG-307/308 is a live example:

| condition | result |
|---|---|
| file exists, delete succeeds | returns; file is gone |
| file absent (`FileNotFound`) | returns; treated as success |
| any other error (lock, `IsDir`, `AccessDenied`) | **panics**, naming path and error |

Reading it as a table immediately exposes what prose did not: the third row is why a retry
loop around `delete` was unreachable (BUG-308), and the second row is why `deleteScratch`'s
one tolerated error was the one that could not occur on its path. **Both defects are visible
in the table and were invisible in the code for months.**

The tooling claim is that such a table can be checked: rows exhaustive over the error set,
rows mutually exclusive, and every row exercised by a fixture. `contract_mode_check` already
does this informally -- its four-way `--release` x `--turbo` matrix IS a Parnas table, and
the entry says the asymmetric cells are the point. Worth naming the pattern and reusing it.

## KNUTH'S TRIP TEST — the highest-yield tool on this list — LANDED 2026-09-14

`test/boundary/trip.zbr` + `trip.expected` (intent-authored, exact-compared by
`boundary_check`, QUICK tier). First run: three compiler defects (BUG-424 `Math.abs(int)`
unsigned, BUG-425 `extend str` never resolved, BUG-426 typed-param expression lambda not
passable as a `sig`) plus two things for this queue to decide rather than fix:

- **`defer` / `errdefer` FREED 2026-09-15** (Sean: "bleedthrough from zig and we can
  kill" -- the decision was already in tools/keyword_coverage_baseline.txt). Both token
  tables; the StmtDefer machinery went with the bootstrap (sunset Step 4, 2026-09-16).
  `test/defer_freed_words_test.zbr`, whose first run found BUG-427. `continue` works and
  was merely uncovered.
- An unused `as n` binding in a branch arm is refused (Zig's unused-capture error
  surfacing as a Zebra error) **with no column** -- `diag-columns` cannot see it because
  it is not a front-end diagnostic. Fine as a rule; the position is the defect.
  FIXED 2026-09-16: the checker refuses it at the `on` keyword, with a column
  (fail_fixtures/branch_unused_binding_test; a guarded arm and `as _` are exempt,
  test/branch_binding_forms_test). Branch arms carry a real span now (they had 0:0).
  Fixing it exposed two emit bugs in the if-chain branch form (the one taken when the
  subject's union type is not known, e.g. a `for` variable): a USED binding got a
  `_ = x;` discard ("pointless discard"), and `as _` emitted `const _`. Both fixed; the
  name-use walkers moved from CgHelpers to AstWalk so the checker can share them.

Grow it: every future bug class should get a line in the trip as well as a fixture.


TeX has `trip` and METAFONT has `trap`: single, deliberately fiendish programs exercising
every feature IN COMBINATION, with byte-pinned output. Knuth credits them for TeX's
convergence to near-zero defects.

**This is the direct answer to what `construct_histogram` measured.** Our 522 tests each
exercise one thing, and ZERO combine float + `.at()` + `while`. Isolated tests are
structurally incapable of finding interaction defects. `trip.zbr` would be the corpus's
opposite by design: generics inside contracts inside `branch` arms inside TCO'd recursion,
output pinned byte-for-byte.

It also fixes a defect that adding more files cannot: every test we write is shaped by what
we already believe matters.

## AUTOMATIC ARENA SCOPING — and why it makes the transform interface a PREREQUISITE

Sean's proposal: place an `allocate Arena()` scope automatically where a function's
allocations provably do not outlive the call. Sean also noted, correctly, that it would
have to be tracked in the transform list -- and that instinct is load-bearing rather than
tidy-minded.

**This transformation is DANGEROUS if the escape analysis is wrong.** A value the compiler
wrongly proves does not escape is freed while still referenced: use-after-free, in release,
silently. Compare BUG-313, where the failure at least announces itself as a wrong number;
this one hands out reclaimed memory.

So being listable, queryable and disableable is a **safety requirement**, not documentation.
This transformation cannot ship as invisible compiler magic, which makes the transform
interface a **prerequisite** for it rather than a companion to it. Sequence: interface
first, auto-scoping second.

Related lever, measured 2026-08-26 and available today with no compiler work: in a
multi-threaded build EVERY allocation takes a mutex (`_TsAlloc` wraps the shared arena);
`--single-threaded` makes `builtin.single_threaded` comptime-true and the wrapper is
compiled out. For allocation-heavy single-threaded programs that is serialization removed
from the hottest path. (Mechanism confirmed in the emit; the speedup is NOT yet measured.)

## THE TRANSFORM INTERFACE AS THE PLUGIN MECHANISM (Sean, 2026-08-26)

Sean's: let the transform interface BE the extension point, so people other than the core
maintainers can extend the language within its constraints.

**This is better than a general plugin API for a precise reason: it is a CONSTRAINED
extension point.** Anything a plugin can do it does through `match` / `rewrite` /
`metadata` / `trigger` -- so every third-party transform is automatically listable,
disableable and self-describing, because the interface does not permit otherwise.
Extensibility without surrendering the Hoare property. It also sidesteps the objection
recorded above against plugin boundaries inside a compiler: this is not a new seam through
the compiler's internals, it is one narrow, already-necessary interface.

**Design for this early: a wrong user transform is a MISCOMPILE, and it will be blamed on
Zebra.** So the interface likely needs a fifth part beside the four: a **preserved
property** the rewrite declares and that can be checked against real inputs. That is Meyer
applied to a transformation rather than a function -- and Zebra is unusually well placed
for it, since `bootstrap_check`'s round-trip is already a preserved-property test at
whole-compiler scale.

## PARNAS TABLES — ADOPTED (Sean, 2026-08-26)

Adopted on the strength of the `File.delete` worked example above, where a three-row table
makes BUG-307 and BUG-308 visible on inspection after both sat invisible in the code for
months.

Where to apply first: any function with an **error taxonomy** -- most of the `File`,
`Dir` and process surface. The check the table enables is mechanical: rows exhaustive over
the error set, rows mutually exclusive, every row exercised by a fixture.

`contract_mode_check`'s four-way `--release` x `--turbo` matrix is already a Parnas table
built without the name; its own notes say the asymmetric cells are the point, which is
exactly the completeness property a table makes visible.

## Dogfood programs (IO + net + threads — surface stdlib/runtime gaps; each self-verifies)

BUG-153 (module-global shared state) is fixed, so shared-state servers are
unblocked. The two-tier allocator wiring (§28j) is the remaining concurrency
foundation and needs a supervised session.

- [x] **§28j — thread-safe program allocator DONE (2026-07-24, `b5d1726`).** Shipped the
  ThreadSafeAllocator-wrapper approach (NOT per-thread arenas — that over-scoped it): a
  mutex around the shared arena (`_TsAlloc`/`_prog_alloc` in the preamble + bootstrap),
  `--single-threaded` flag → `-fsingle-threaded` (compiles the wrapper out; thread-spawn
  becomes a compile error). Validated by `thread_alloc_stress_test`. **Residual (post-1.0):**
  `allocate Arena()` scopes swap the global `_allocator` and race with workers (77% crash,
  captured by `arena_concurrency_hazard_test`) → rule: allocate-scopes are single-threaded-
  only. See `docs/design/concurrency_allocation_design.md`. Below = the ORIGINAL (superseded) plan.
- [ ] **§28j step b — two-tier allocator wiring** (per-thread arenas + a shared
  `Smp()` handle). Race is confirmed-in-code but latent-at-runtime; the fix is
  subtle with concurrency-lifetime failure modes the gates can't catch → supervised
  session, decide the shared-handle API first. → *Open detail §28j.*
- [ ] Concurrent web fetcher / link checker (worker threads pull URLs from a `Chan`,
  HTTP GET, aggregate).
- [ ] Parallel log-processing pipeline (`Dir`/`File` walk → workers → merged histogram).
- [ ] Multithreaded Mandelbrot / ray tracer → PPM (compute fan-out + binary IO).
- [ ] Pub/sub or LAN chat broker (TCP + client threads + `Chan` broadcast).
- [ ] MapReduce word-count over the Greek NT / a large corpus (threads + IO + Unicode).
- [ ] Tiny HTTP JSON API persisted to SQLite + a concurrent client smoke test.
- [ ] **§9 — Greek NT n-gram port** (SIMD landed, the deferred-wait is over): file
  I/O, Unicode `HashMap` keys, sort, sliding n-gram window, TF-IDF / cosine via
  `f32x8`. → *Open detail §9.*

## §15 — 1.0: language stability + CHANGELOG (cumulative commitment)

1.0 is the **full API surface delivered through all prior 0.x milestones, locked
with a stability promise.** Everything in the checklist below is delivered; the
open act is the *freeze* + a final CHANGELOG pass.

**Stability commitment — 1.0 must have all of (all ✅ delivered):**
- ✅ Generics (0.8); Contracts (`require`/`ensure`/`invariant`/`old`/`result`/`--turbo`, 0.12)
- ✅ All stdlib through 0.4–0.15 (Math, Json, DateTime, CSV, Hash, Random, Arg,
  Terminal, Log, Uri, Compress, Mime, Timer, Regex, Http, Tcp, Udp, Net, File, sys,
  Gui, Reflect, Path, Profile, SIMD, SQLite, WebSocket, ThreadPool, Atomic, …)
- ✅ Self-hosting + bootstrap round-trip (Phase 22); source-mapped errors (0.5)
- ✅ 0.11 (REPL, JSON auto-inference, gzip, debugger/DAP, build system); 0.13
  (BUG-115, `^T` fixes); 0.14 (full `<-` deep-copy, `Chan(T)`, allocator context);
  0.15 (syntax cleanup, stdlib completeness, libui-ng); `--target node-addon`
- ~~regex per-quantifier~~ → post-1.0 (§7)

**Open:** the stability freeze itself + a final CHANGELOG reconciliation pass over
the 0.1 → 1.0 surface (CHANGELOG.md exists as of 2026-05-26; re-verify it covers
everything since).

## §28a — inference-or-error rule (step 4 open) [ADOPTED — Sean 2026-07-03]

No typed-dispatch site may guess: if inference is empty, emit a diagnostic, not a
guessed emit. Steps 1–3 done (instrumentation → closed every corpus inference gap →
`check_inference_guess.sh` gate, corpus at 0). **Step 4 open:** the language-level
flip — a residual guess becomes a "cannot infer type of X; annotate" compile error.
Systemic fix for the F7/BUG-162/BUG-168 class. Raises the priority of §24e.

**Spike findings (2026-07-15) — scope decided [Sean: "flip the selfhost if it guesses"]:**
The guess INSTRUMENTATION + gate were **bootstrap-only** at the time (three sites in
the bootstrap's `CodeGen.zig`: list_dispatch, len_count, add; `noteInferenceGuess`
+ `warn_inference_guess`; `--warn-inference-guess` is native since, and
`check_inference_guess.sh` runs `zebra.exe`). But the **selfhost guesses too** — `genBinary` add
(`selfhost/CodeGen.zbr:8818`) does `if isStringBoth(l/r) → _str_concat; else → numeric +`,
so an un-inferable operand silently defaults to numeric `+` (the same F7/BUG-168
fallback). `isPrimType` (just below `isStringBoth`) is the "proven-prim" check the gate
needs. The other two selfhost sites (len/count, List-method routing) share the shape.
On the corpus the guess is always *correct* (smoke 236/236, round-trip byte-identical)
but **ungated** — so the flip = add the `isPrimType` gate and turn "neither string nor
proven-prim" into an error.

**This is the §28a campaign re-run on the selfhost (not a one-shot). Measure-first,
per §28a's own discipline.**

**Phase 1 (measure) — DONE 2026-07-15.** Instrumented the 3 selfhost guess sites
(`selfhost/CodeGen.zbr`: `add` ~8874, `len_count` ~8315, `list_dispatch` ~10950),
recording unconditionally via the §28b `_implicit_try_sites` mechanism; reported under
`--warn-inference-guess` (behavior-neutral, no exit). Tool: `tools/measure_selfhost_guess.sh`.

**Result: 80 unique sites** in `selfhost/*.zbr` (add 6, len_count 30, list_dispatch 44;
60 in `CodeGen.zbr`) — **NOT 0**, so not "flip freely". BUT triage found **~zero genuine
ambiguity** — every sampled site emits CORRECT code. Two causes:
1. *Non-guesses the instrumentation over-flags* — user-class field/method on an un-inferred
   receiver: `StrSet.len` (a real `var len: int` field), `args.contains()` (`args = Arg.parse()`,
   a user `Arg` method). ~15 of 44 list_dispatch are `args.contains` alone.
2. *Benign under-inference* — e.g. `(l.len - t.len) + kw.len` is int arithmetic flagged only
   because `inferExpr` doesn't type `.len` → int; `x = c.items(); x.at(i)` routes right by name
   because the `.items()` return type isn't propagated.

**Why ≠ bootstrap (which reached 0 standalone):** the bootstrap consults a global per-expr
type map (`tc.expr_types.get(e)`); the selfhost `InferCtx` has only `scope: HashMap(str,Type_)`
+ on-demand `inferExpr`, which returns `unknown_` for `.len`, call-returns, user-class fields.
No per-expr map exists → precision = strengthening inference, not a lookup.

**Decision (Sean 2026-07-15): land Phase 1 record-only, then step 2, then flip.** NOT the
scope-down (bootstrap gate already provides the user-facing guarantee at 0) and NOT a rush to
flip (would convert ~80 benign under-inferences into false errors).

**Step 2 (in progress) — close the inference root causes**, re-measuring toward 0.
Measurable selfhost/* count (excl. main.zbr/pipeline_test, BUG-181): started **add 6 /
len_count 30 / list_dispatch 27**.

Done (2026-07-15/16):
- ✅ **`inferExpr(.len / .count())` → int** (commit 5c78c17) — `add` bucket 6 → 0. Also
  covers `inferExpr(arith of prims)` since the existing binary handler already propagated
  numeric; the only gap was `.len` not being numeric.
- ✅ **`len_count` guard → `typeIsUnknown`** (commit 9204a0b) — 30 → 18. Dropped proven-receiver
  false positives (StrSet-param `.len` field reads were never ambiguous). Emit-neutral.
- ✅ **StrSet method returns on param/field receivers** (commit 04231dc) — **a real latent
  selfhost MISCOMPILE**, not a benign guess. `StrSet` has a dedicated `Type_.str_set` variant,
  so a param/field typed `StrSet` infers to `str_set` (a `StrSet()` ctor infers to
  `named("StrSet")` and worked); the call handler had no `str_set` arm, so `strset.items()`
  was unresolved and the result local emitted `.len` (string-shaped) — WRONG on an ArrayList
  (`no field named 'len'`). Hidden because the committed `.zig` is bootstrap-generated and the
  round-trip shares the same (wrong) inference on both sides. Added a `str_set` arm
  (`items()`→List(str), `contains_()`→bool). A probe that miscompiled now compiles+runs.
  Cleared the whole CodeGen cluster: len_count 18 → 9, list_dispatch 27 → 18.
  **Precision caveat (2026-07-16, not overclaiming severity):** `StrSet` is *compiler-internal*
  (not user-facing), so this miscompile's blast radius is narrow — it can only appear in
  selfhost code, and the compiler-source usages that would trigger it are mostly guarded by
  `localIsList`-style tracking (which is why the round-trip's A/B builds passed with the bug
  present — the pattern wasn't hit in a breaking form in the compiled path). It is a REAL
  latent miscompile (the probe proves it) and the fix is correct, but it is not a user-facing
  crisis. **The generalizable thread was hunted (2026-07-16) and the class is now BOUNDED:** of
  the 4 dedicated-`Type_` variants with no `inferExpr` call-handler arm (`str_slice`,
  `allocator_ctx`, `sqlite_row_list`, `gui_context`), only **`sqlite_row_list` was a real
  user-facing bug** → **BUG-182** (`db.query(...).at(i)` result untyped → `.asInt`/`.asStr`
  miscompile), fixed in the selfhost. `gui_context` is safe (its value-returners are primitives,
  no struct-dispatch hazard), `str_slice` is a handled sentinel, `allocator_ctx` is internal.
  The hazard requires a *struct-returning* method whose result loses its type; primitive-returners
  don't trip it. Found via the independent witness (`compile_check`), not the corpus.

**This overturns the Phase-1 "~0 genuine ambiguity / emit always correct" read:** for the
selfhost's OWN emit the guesses were producing wrong code; only bootstrap regen masked it.
§28a is fixing real latent miscompiles on the road to selfhost-as-regen-authority, not just
tidying benign guesses.

**⚠️ SCOPE CORRECTION (2026-07-16 full-corpus measure).** The per-file iteration above measured
only NON-`main` selfhost source. The authoritative full-corpus measure (420 files, per-file
timeout) was **143 unique sites: add 40 / len_count 30 / list_dispatch 73** → now **140 (add 37 /
len_count 30 / list_dispatch 73)** after the typed-lambda fix. So "add bucket → 0" holds ONLY for
the non-`main` compiler files; corpus-wide much remains. Distribution: lexer_test 33,
test/csv_test 24, `main.zbr` 19, test/list_functional 10, Parser 9, AstBuilder 5, +~30 other test/
files, examples/life 4. Root-cause patterns still open:
- ✅ **Typed lambda params** (commit c9c85f9) — `genLambdaEx` now seeds a fresh InferCtx with
  the lambda's DECLARED param types (mirroring genMethod), used for BOTH the `@TypeOf(body)`
  return-type inference and the body. `def(x: int) = x + x` / `def(acc: int, x: int) = acc + x`
  no longer guess. Round-trip byte-identical, smoke 236/236. **Corpus delta: 143 → 140 (add 40 →
  37) — only 3 sites, because the corpus lambda-`add` guesses are dominated by UNTYPED functional-
  trio lambdas (below).** Value is the seeding INFRASTRUCTURE the untyped work builds on, not the
  raw count.
- **Untyped functional-trio lambda params** (the remaining `add` driver): `def(acc, x) = acc + x`,
  `def(x) = x * 2` — params carry no declared type, so they bind unknown and still guess. Their
  types must be DERIVED from the higher-order fn's signature: for `nums.reduce(0, def(acc,x)=…)`
  with `nums: List(E)`, `acc` = init's type, `x` = `E`; for `map`/`filter`, `x` = `E`. Needs
  call-site→lambda param-type plumbing (the reduce/map/filter codegen passes derived types into
  `genLambdaEx`), method-specific — moderate risk, a supervised session. Affects list_functional /
  csv / many tests.
- **Cross-module STATIC returns** (`toks = Lexer.tokenize()` on a module name → unknown) —
  lexer_test cluster (~23). Module-static method-return resolution across deps; helps user
  `Module.staticFn()` too.
- **`main.zbr`'s own 19 sites** (2 add: 755/1113; 17 list_dispatch: the `args.contains` /
  `Arg.parse()` cluster — `Arg.parse()` return type not propagated). Never measured pre-fix
  (main.zbr didn't finish compiling; see BUG-181, now ~6s).
- 2 known-hard singletons (flow-sensitive `var a2=a` reassignment; cur_line noise).

NON-main compiler source IS essentially cleared (0/9/18 on those files) and a real miscompile
was fixed — but the flip (step 3) is NOT close corpus-wide; the lambda-param feature is the
largest remaining lever. Re-assess scope with Sean.

**BUG-181 RESOLVED (2026-07-22):** `main.zbr` now self-compiles cleanly (emit rc=0, emitted Zig
builds; proven end-to-end — the self-made 2.3MB compiler compiles a program that runs). 8 emit
divergences fixed, gated by `tools/selfcompile_check.sh`. The §28a-step-4 CONSTRAINT below (main.zbr
can't be in the both-compilers-reject probe) is now LIFTED. See BUGS.md BUG-181.

**Step 3 (the flip) — only once the selfhost standalone count is ~0.** Error + `--allow-inference-guess`
hatch + promote the measure to an enforcing gate. Follow the §28b template (commit 0a591ce):
module-global sites list, driver-level reject in `main.zbr` (NOT `@compileError` — malforms
expression-position sites), `cur_line` on the shared Writer for the location. **The round-trip
won't catch selfhost-vs-bootstrap divergence** — the flip acts as a differential probe (§28b
caught `Parser.zbr:3164`). CONSTRAINT: `main.zbr` can't be part of the both-compilers-reject
validation — the selfhost can't compile it (BUG-181).

Also consider (Sean, if bootstrap kept longer): flip the bootstrap's 3 sites too
(mirror §28b's `rejectImplicitTry`) for user-code parity — low-risk, marginal value
(bootstrap phasing out; divergence is bootstrap-conservative = safe direction).

## §28b — unify error propagation on always-explicit `?` ✅ DONE (step 5 flipped 2026-07-15)

All five steps complete. Steps 1–4 (2026-07-02): instrumentation → swept `?` into
441 auto-try sites → inventory 0 → `check_explicit_try.sh` gate. **Step 5 (the flip,
2026-07-15):** an omitted `?` on a throws call is now a **compile error in both
compilers**, via a **driver-level diagnostic** (NOT `@compileError` — 4 of 5 sites
are expression-position and would malform the emit). A valid `try` is still emitted;
the driver collects the sites and rejects with `file:line: throws call needs '?'`
after codegen. `--allow-implicit-try` is the one-release migration hatch. Bootstrap:
a `pub var implicit_try_sites` global + `rejectImplicitTry` in `main.zig`. Selfhost:
a file-scope `_implicit_try_sites` (mirroring `boss_director`'s registry) + `cur_line`
on the shared Writer + the check in `main.zbr`. Gates: smoke 236/236, round-trip
byte-identical, corpus 0. QUICKSTART §12 + CHANGELOG updated. Regression:
`test/fail_fixtures/implicit_try_rejected_test.zbr` (smoke_tc_fail).

**Surfaced + fixed:** the flip caught `selfhost/Parser.zbr:3164` (`return
p.parseModule()`) — a genuine implicit-try the bootstrap's instrumentation never
flagged because the bootstrap emits an **error-union passthrough** (`return X`, no
`try`) there while the selfhost auto-`try`s it. Adding `?` converged both emitters
(→ `return try …`) and completed the sweep.

**Residual divergence (acceptable, documented):** the selfhost flip rejects
return-position throws calls on a local (`return x.method()` without `?`); the
bootstrap uses passthrough there, so it does *not* reject them. Selfhost-stricter is
the acceptable direction (bootstrap phasing out); a user hitting the selfhost
rejection just adds `?` (the intended fix). Close by extending the bootstrap's
return-path detection if the bootstrap is kept longer.

## §28e — spec `str` ownership per stdlib call

`str` is sometimes borrowed (`s[a..b]`), sometimes freshly allocated (`concat`,
`File.read`) — invisible under the program arena, load-bearing inside `allocate`
scopes and threads. Pre-1.0 task = a per-call borrows-vs-owns table in the
spec/QUICKSTART, so the 1.5 `str_view` design has defined ground.

**Landed 2026-07-29.** `docs/design/str_ownership.md` (generated, gated) + QUICKSTART rules.
The table is DERIVED from emit, not read off codegen, because ~28 near-identical
classification judgements is precisely the work that drifts — and the derivation found
two things a reading would have flattened: the owned-container-of-borrowed-elements
split for `split`/`lines`/`tokenize`, and that `charAt` is a byte VALUE that belongs in
neither class. Regenerate with `--write` after any string codegen change; `--check` is
gated so a flip cannot ship silently.

**Ground this hands to the 1.5 `str_view` design:** a view type needs to express *two*
lifetimes, not one — the container's and the elements'. A `str_view` that only models
"points into something else" still cannot type `split`'s result correctly.

## §28f — generic `Set(T)` [DONE — 2026-07-24], from scratch

**Shipped selfhost-only.** `Type_.set_` variant emitting `AutoHashMap(T, void)` /
`StringHashMap(void)`; `add`/`contains`/`remove`/`len`/`count`/`items`→`List(T)`/`clear`,
`for x in set`, `x in set`; local/param(by-ptr)/field/return/nested. Decisions taken:
str specialized, `items()`→`List(T)`, StrSet stays internal. `add()` interns str keys;
`items()` and `for-in` reuse `_zebra_map_keys`; `in` reuses `_zebra_in` (`@hasDecl
"contains"`). Limits (=HashMap keys): T auto-hashable; no `==`/`print(set)`. The
bootstrap does NOT implement Set (sunsetting) — it shows as an informational
divergence bootstrap-gap; round-trip holds because the compiler's own source never
uses Set. Historical scoping notes below.


The "mirror the existing StrSet API" premise is **invalid**: `StrSet` is a
selfhost-internal Zig type, not user-facing. So `Set(T)` is a HashMap-sized new
builtin: special-case the void value (`AutoHashMap(T, void)` / `StringHashMap(void)`
for str), set methods (add→put(x,{}), contains, remove, count, items→List), for-in,
TC, both compilers. **Decisions to confirm:** str-key specialization; does `items()`
return `List(T)`; expose a `Set(str)` alias or leave StrSet retired. Own gated pass.
Related: the functional trio (`map/filter/reduce/sort/sortBy`), `HashMap.keys/values/
entries` all shipped (see Completed-recent). Broader follow-up: a fuzz surface for
lambda-taking list methods (none fuzzed today — would come as one lambda-generation
capability).

## §28j — `_allocator` under threads → two-tier model (step b open) [DIRECTION SET — Sean 2026-07-03]

> **Design research (2026-07-23): `docs/design/concurrency_allocation_design.md`.** Comparing
> Zig (`ThreadSafeAllocator`, `SmpAllocator` — a GC-free per-thread-cache with
> thread-exit reclamation, both in std) and Go (per-P `mcache` tiers + GC-owned
> lifetime) reframes §28j and **shrinks it**: lead with SHARE-NOTHING (per-thread arenas
> + copy-on-`Chan`/`<<-`, which Zebra already does) so the cross-thread use-after-free
> class is avoided by construction; provide a thread-safe FALLBACK tier for genuine
> shared state by *adopting* a std allocator (`ThreadSafeAllocator` → `SmpAllocator`),
> not inventing one. Residual real work: per-thread arena wiring + audit that
> cross-thread paths copy + a threaded-lifetime gate + a thin opt-in shared annotation.
> Still supervised. See the note for the full comparison + recommendation.


Arena allocators aren't thread-safe; workers sharing the program arena is a latent
race. **Measurement done (step a, 2026-07-04):** race CONFIRMED in code (`_allocator`
is one global non-thread-safe arena; ThreadPool/`sys.go` workers don't swap it) but
did NOT manifest at runtime (200 tasks × 4000 allocs × 16 threads, ~15 runs, zero
corruption — narrow window; UB and latent, not frequently-firing). **Step b open —
WIRING, supervised session (design + risk):** making `_allocator` `threadlocal` fixes
the temporary race but then worker-allocated data a later thread reads → use-after-
free, and that's invisible to single-threaded gates. Correct model = both tiers wired
+ a clean Zebra handle for "allocate in the shared pool" (`Smp()`) — an API design
call (keyword? `shared` block? `sys.sharedAlloc()`?). Add a threaded *lifetime* test
to the gate set, not just the alloc-race probe. Unblocks correct shared-state servers
(the BUG-153/154 territory). **Not for unsupervised work.**

**Prior art — xsync.zig** (assessed 2026-07-21; MIT, single-file, Zig 0.16+master):
cross-`std.Io` **cancellation-safe** sync primitives (Mutex/Condition/Event/Semaphore/
RwLock/`Queue(T)` w/ timeout+close). Strong fit for Zebra's concurrency layer:
reimplement `Chan(T)` on `xsync.Queue`, close **BUG-154** (Tcp.serve no-lock) with
`xsync.Mutex`. **VENDOR** it (not a live dep — binary-size/control) and **read its 3
stdlib-Condition bug reports** (Zebra may share those latent bugs). Value scales with
one decision: **near-essential IF Zebra adds an evented `std.Io` runtime** (green
threads, no OS-thread-per-connection — servers are thread-per-conn today, won't reach
C10k); nice-to-have if threaded-only. Full assessment: memory `project_xsync_concurrency`.
github.com/lalinsky/xsync.zig

## §19.5d — bootstrap-check feedback latency

`tools/bootstrap_check.sh` is the integration safety net but slow under CPU throttle
(5–10 min observed). Profile + optimize where cheap (parallel build steps, cache-
invalidation tightening). Gated on a profiling pass.

## §9 — Greek NT n-gram port

SIMD types shipped 2026-05-08 — the deferral reason is gone. Scope: file I/O,
`HashMap` with Unicode keys, sort, sliding n-gram window, TF-IDF / cosine similarity
via `f32x8` dot-product. `--cpu=native`/`--cpu=x86_64+avx2` passthrough shipped
(QUICKSTART §32, SIGILL hazard noted). See `concept_zebra-simd-design.md`. (Runtime
CPU dispatch — oma-style — is post-1.0.)

## Fuzzer (`fuzz/`) — remaining coverage

Found + fixed 12 real equivalence bugs (F1–F12 → BUG-159…167, 161/162, 173).
Post-fix sweeps clean (seeds 0–99 run-oracle 100/100). **Open:** grow `DEFAULT_CAPS`
into high-bug-history combinations — remaining caps need class-relationship
generation: (4) `^T` boxing, (5) interfaces + `is`, (6) generics / backed-enums /
chained-cmp. Grow grammar surfaces (generics, error/throws, branch/enum). Caution:
`stmtMentionsThis` must stay EXACT. Generic *functions* are intentionally selfhost-
only — do NOT fuzz them as an equivalence surface. Sized numerics (`List(int32)`)
fail at the parser (BUG-172 follow-on). See `fuzz/README.md` + `FINDINGS.md`.

## Open Bugs (not tied to an open milestone slot)

- **Selfhost `_initIo` propagation gap** — CLOSED, and had been since BUG-221's fix:
  the entry thunk walks `_entry_deps` (the TRANSITIVE list) for `_initModuleVars` on the
  runtime-module path and for `_initAllocator`/`_initIo` on the inline path, and
  `runtime_module_check`'s BUG-221 leg runs a depth-2 dep that touches a file. Re-checked
  2026-09-24 (1.0 pre-flight): a three-module chain whose leaf does `File.read` runs on
  the default, `--no-runtime-module` and `--single-file` shapes. (Was:) selfhost-emitted
  dep modules get a simple `_initIo` (local `_io` only); would silently use undefined
  `_io` if a transitive dep gains file I/O.
- **BUG-180** — bootstrap ctor-default fill (see Compiler hardening). Bootstrap-only.
- **BUG-026** — `instance_method_return_types` gaps for exposed-type method chains.
  Not manifesting (`scanMutationsInExpr` conservatively marks cross-module calls
  mutated). Defer unless a concrete failing case appears.
- **BUG-014** — regex lazy match is global, not per-quantifier (`<.*?>STUFF.*>`
  misbehaves). Architectural (priority-first NFA / backtracking). **Deferred
  post-1.0 (§7);** workaround = split/restructure the pattern.
- **SQLite feature defines not passed to the vendored `sqlite3.c`** — the
  compiler adds `sqlite3.c` to the zig build (`selfhost/main.zbr` ~2703) with no
  `-DSQLITE_ENABLE_*` defines, so every feature the amalgamation fences behind
  `#ifdef` (FTS5, RTREE, JSON1 config, etc.) silently compiles out. Surfaced via
  the Graze docs-browser: FTS5 search returned "no such module: fts5" in-app but
  17 hits in `testfixture` — the tell that the *flag*, not the query, was
  missing. **Interim fix (zebra-sprocket `cfc91e1`):** `apply_sprocket_patch.py`
  prepends `#define SQLITE_ENABLE_FTS5 1` to the vendored file, seam-side.
  **Upstream fix:** the compiler should pass the feature-define set (at minimum
  FTS5) when it adds `sqlite3.c` — ideally a small `sqlite_features` knob rather
  than a hardcoded list, so a program can ask for RTREE/JSON without another
  seam patch. Interim workaround is a silent-failure trap if the define is ever
  dropped; make it a build flag, not a prepend. Filed for Opus.

---

# Post-1.0

- **§7 — Regex per-quantifier lazy/greedy** (BUG-014). Per-node shortest/longest
  flags; architectural. Workaround: split the pattern.
- **§6 — REPL resident compiler.** Measured: `zig run` cold 4s / warm 119ms; every
  REPL entry is a cold compile (session file changes each entry); `-fincremental`
  doesn't help on Zig 0.16 Windows (linker state not saved). Options: Zig 0.17+
  incremental linker, or a native Zebra interpreter (~2–3 wk). Deferred.
- **§24e — single method-descriptor table.** One spec driving both TC inference and
  codegen dispatch (replaces the 4-place pattern). Priority raised by §28a.
- **SIMD runtime CPU dispatch** — oma-style startup detection (SSE2→AVX2→AVX-512 /
  NEON→SVE2) without separate builds. Design spike.
- **§13 — VCS in Zebra** (capstone). Pijul-shaped patch algebra + typecheck-as-merge.
  Daily-useful pieces already shipped (§19.5). Research/teaching artifact.
  `concept_zebra-vcs-architecture.md`.
- **§14 — IDE (self-hosted), MVU redesign.** ZigZag TUI canonical backend shipped
  (`--gui-backend=tui`, 2026-05-21). Remaining: libui-ng adapter (~200–300 lines
  widget-cache reconciliation + two Zig 0.16 `build.zig` fixes). `concept_zebra-gui-redesign.md`.
- **§17 — 1.5: WASM target + web frontend SDK.** `--target wasm32-freestanding`/`-wasi`,
  `export def`→`export fn`, JS shim, module blacklist, AlpineJS. Shares `@freestanding`
  + blacklist infra with §22. ~2–3 wk. Key decisions: `throws` at boundary; class/struct
  passing; `print()` buffering. `concept_zebra-wasm-frontend.md`.
- **§17b — 1.5: Http server ergonomics** (swerver-inspired): (a) arena-per-request
  handler model; (b) **`str_view` borrowed slice** — the biggest structural gap
  between Zebra's owned `str` and high-perf servers (needs a lifetime-annotation
  design spike); (c) `BoundedPool(T, N)` with LIFO free-stack + double-release bitmap.
  `concept_zebra-http-design.md`.
- **§26 — 1.5: Zig `@builtin` access** (three tiers): T1 native promotions
  (`sizeof`/`alignof`/`typeof`/`bitcast`); T2 semantic namespaces (`Atomic.*`/`Ptr.*`/
  `Int.*`/`Simd.*`); T3 transparent `@name(args)` pass-through for ~60 more. ~1 wk.
  Removes a primary impediment to writing engine/systems code in Zebra.
- **§22 — 2.0: Kernel track.** `.zbr`/`.zeb` split; `@freestanding` mode; `core`
  stdlib; naked/interrupt callconv, inline asm, `@section`, `@embed_file`, `volatile`,
  `Cpu.*`. Plus the 2.0 WASM additions (multi-file, source maps, wasm-opt,
  serialization). `concept_zebra-os-additions.md`. Reference: BamOS.
- **§16 — Intertextual support.** LXX/MT divergence tool; provenance typing.
  RESERVED for post-1.0. `project_intertextual.md`.

---

# Completed — recent (full detail)

## EPIC: Language Server (LSP) — Phases 1 → 4h ✅ (2026-07-09 → 07-10)

Written **in Zebra** (flagship dogfood + reuses the front-end directly). An LSP is
the biggest daily-ergonomics lever for any language. Open follow-ups are in the
Tooling section above.

- **Phase 1 ✅** — diagnostics *seam*: `zebra diagnostics <file> [--out <json>]` runs
  parse→resolve→typecheck → JSON `{line,col,severity,message}`. Reuses `tcCheckSide`;
  line/col are the trailing numeric fields (robust to the Windows drive-colon).
  `tools/lsp_diagnostics_smoke.sh` + `test/lsp/*.zbr`. NOTE: `print` lands on stderr
  on the Windows fast-backend (so does `--emit-zig`) → `--out <file>` is the clean
  consumer interface.
- **Phase 2 ✅** — `zebra lsp`: a stdio Language Server (JSON-RPC, Content-Length) IN
  `main.zbr`, front-end in-process. `initialize`/`shutdown`/`exit`, `didOpen`/`didChange`/
  `didClose` → `publishDiagnostics`. Transport: `Terminal.write` (real stdout, pipe-
  capable — NOT `print`); stdin via `sys.readLine` + new `sys.readBytes(n)`. Dynamic
  JSON via `Json.parse`. `tools/lsp_server_smoke.py`.
- **Phase 3 ✅** — VS Code extension `editors/vscode/`: thin `vscode-languageclient`
  (9.0.1) over stdio + TextMate grammar + language config. Verified headless (server
  5/5); not yet click-tested inside VS Code.
- **Phase 4a ✅** — formatting (`fmtNormalize`, full-document TextEdit) + documentSymbol
  (module decls → LSP symbols, members nested). Buffers stored in a `docs` map. 8/8.
- **Phase 4b ✅** — hover (markdown code-fence signature via `typeRefStr`) + go-to-
  definition (per-buffer decl index; `lspWordAt`). Constraint found: selfhost
  AstBuilder used `zspan()` = all-zero, so definition fell back to a text search
  (later retired by 4d). Worked around a `List(char)`-ctor round-trip divergence
  (BUG-172). 10/10.
- **Phase 4c ✅** — completion (keywords + declared symbols with kinds/detail). 11/11.
- **Phase 4d ✅** — real source spans on declarations. Parser records the name-token
  position on every decl PNode; AstBuilder threads it via `nameSpan()`. documentSymbol
  ranges now real + name-precise; definition uses the AST span (text search only a
  mid-edit fallback). Internal only — emitted Zig unchanged (round-trip byte-identical).
  Commit f0d9111. Retires the 4b `zspan()` limitation.
- **Phase 4e ✅** — member completion after `.`: `self.`/`this.`/leading-dot → enclosing
  type; type name → members/enum variants; annotated/constructed local → its type's
  members. `.` as trigger. Text-based receiver resolution; unresolved → empty, not
  noisy globals. Commit 78ada96. 12/12.
- **Phase 4f ✅** — formatter v2: inter-token space collapse with byte-for-byte string/
  comment preservation (string/comment-aware line scanner; every mis-read errs toward
  staying *inside* a string). Gated by `tools/fmt_safety.py` (11 fixtures + idempotence
  on 413 files + emit-equivalence: 123 files reformatted, all emit byte-identical Zig).
  Open: canonical re-indent (Tooling section).
- **Phase 4g ✅** — signatureHelp (`(`/`,`; innermost enclosing call, depth-aware comma
  split so `HashMap(str,int)` stays one param; `activeParameter`). Robustness: unknown
  **requests** → `MethodNotFound` (-32601). Functions/methods, single-line. 14/14.
- **Phase 4h ✅** — diagnostics debounce: a `sys.go` reader forwards stdin to a
  `Chan(str)`; main loop `recvTimeout(0.2)` flushes on a ~200ms lull. `didChange` marks
  dirty; a burst coalesces to ONE analysis. Detached reader (so `exit` doesn't hang on
  the stdin-blocked thread); EOF via `Atomic(bool)` + `Chan.close()`. Built on
  `Chan.recvTimeout`. Round-trip byte-identical.
- **Channel timed/non-blocking receive ✅** — `ch.tryRecv(): T?` + `ch.recvTimeout(secs): T?`
  (poll-based, ~2ms granularity; upgradeable to futex timed-wait). Verified under BOTH
  compilers, round-trip byte-identical. *Not done:* a true multi-channel Go-style
  `select` (own project; Zig gives nothing to borrow) — the single-channel-merge +
  `recvTimeout` idiom covers most needs.

## §28 — pre-1.0 design-review campaign (Fable/Opus/Sonnet, 2026-07-02 → 07-04) — mostly ✅

Open tails (§28a step 4, §28e, §28f, §28j step b) are in Open-detail (§28b flipped
2026-07-15 — see the §28b section above, now DONE)
above. Completed pieces:

- **§28c ✅ (07-04)** — exhaustiveness default-on (`--no-warn-non-exhaustive` to opt
  out; legacy `--warn-non-exhaustive` a no-op). Warnings stderr-only → round-trip
  unaffected. Feared "108 legacy `else` arms" a non-issue (selfhost's own sources: 0
  warnings). Error-by-default deferred to 2.0.
- **§28d ✅ (07-02)** — copy-out is `<<-`; `<-` is channel-only. `left_arrow_deep`
  token both compilers; one StmtCopyOut with a `deep` flag; `genCopyOut` enforces the
  pairing via `@compileError` into the emitted Zig (identical behavior both compilers).
  QUICKSTART §28/§35 swept.
- **§28f partial ✅** — functional trio + map utilities: `List.map/filter/reduce`
  (07-03), `HashMap.keys()/values()` (07-04, replaced a broken selfhost emit that
  called ArrayHashMap-only methods), `sort` optional comparator (07-04),
  `HashMap.entries()` → sortable `List((K,V))` (07-06). Higher-order lambda params now
  typed from the receiver's element type (fixes any/all/find/sortBy too). (`Set(T)`
  still open — §28f above.)
- **§28g ✅ (07-03/04)** — grammar cleanups: `to!` alias retired (`x!` won;
  `to_bang_removed_test` must-fail); `yield` removed completely (Zig has no coroutine
  to lower to; old codegen only emitted a `// yield` comment — clean deletion, 0
  migration); optional-FIELD `as`-unwrap confirmed working both compilers.
- **§28h ✅ (07-04)** — `ObjectPool(T)` stdlib: `pool.take()` → `^T?`, `give()`
  (contract-guarded double-release/foreign-object), `inUse()`. Modelled on `Chan(T)`.
  `ObjectPool(int)` intentionally fails (pooling primitives is pointless).
- **§28i ✅ (07-04)** — `sys.memStats()` → `MemStats{ arenaBytes }`
  (`_arena.queryCapacity()`, the high-water mark). Struct shape (not a bare int) so
  fields can be added later.
- **NOT recommended for change** (design-affirmed): `var`-only mutability (BUG-161 was
  an implementation bug, not a design flaw); contracts as identity feature; no
  inheritance; `cue init` (keep, document the Cobra etymology).
- **Synthesis → `docs/walker_discipline.md`:** the ten fixed bugs cluster into four
  structural causes. Standing rule: **new syntax lands with a fuzz generator surface +
  smoke fixture in the same commit.**

## Node.js addon target (`--target node-addon`) ✅ (2026-06-29 → 06-30)

`@node_export def add(a,b): int` + `zebra --target node-addon math.zbr` → `math.node` +
`math.js` shim + `math.d.ts`. Verified end-to-end in Node (int/float/bool/str). Both
compilers build a working `.node`; round-trip + smoke green. Selfhost emit parity,
per-call child arena for string marshaling (Phase 7), cross-platform symbol resolution
(Windows `node.lib` verified; Linux/macOS correct-by-construction), test harness
`test/node_addon/` via `tools/node_addon_test.sh` (Node + node-gyp; not in `zig build
test`). QUICKSTART §45. Follow-ups (cross-platform `.node`, richer matrix) in Tooling.

## Backlog dogfood + hygiene — recent ✅

- **TCP KV store + ThreadPool ✅ (2026-06-30)** — found 7 gaps; fixed BUG-150
  (`sys.sleep`→`std.Io.sleep`, Zig 0.16), 151 (`var _=` discard), 152 (`ThreadPool.submit`
  comptime-fn); filed 153 (module-global Atomic/HashMap — since FIXED), 154 (`Tcp.serve`
  per-conn concurrency, no lock — open, see §28j territory), 155/156 (since resolved).
- **Generated-Zig hygiene ✅ (2026-06-29)** — selfhost routes emit to a temp dir when
  no `--output-dir`; the 300 generated `test/*.zig` are gitignored (8 hand-written
  `.zig` `!`-excepted); `selfhost/*.zig` + `examples/*.zig` stay tracked. `git status`
  clean after regen.
- **Mosaic POC dogfood ✅ (2026-07-14)** — a differential Greek-NT port re-verified
  8 findings against HEAD; live ones filed BUG-175 (fixed: cwd-preamble panic),
  176/177/178 (all fixed), 179 (resolved-as-documented, drop-parity). Numeric
  conversions (`toString`/`toFloat`/`toInt`) confirmed correct & documented.

---

# Completed — archive (one-liners)

Detail in git / `BUGS.md` / `docs/SELFHOST_JOURNAL.md` / `CHANGELOG.md` / wiki.

| Item | Done |
|------|------|
| §27 cross-module type resolution (27a free-fn return, 27b default-fill, 27c optional-return) | 2026-06-17 |
| §24 compiler ergonomics: exhaustive-match warning, cross-module `^T?` bindings, `?.` optional chaining, `genMemberCall` user-method early-exit, type-first dispatch | 2026-05-16/17 |
| §25 block comments `/# #/` (nested) | 2026-06-03 |
| §23 memory model: `allocate` Slices 1–6, `<-` copy-out deep-copy, `Chan(T)`, `sys.go` | 2026-05-12/18 |
| §19 / §19a error recovery: boundary-restart multi-error parse (both compilers), enum TC via `hasEnumAny`, `typecheck-merge`, source-mapped errors | 2026-05-27 |
| §12 syntax cleanup 0.13: BUG-115 visibility keywords, `this.field→.field` (1,141 sites), `def name:T→def name():T` (38 sites), `^T` auto-boxing | 2026-05-05/14 |
| §21 0.11: REPL, JSON auto-inference, gzip, debugger/DAP, `--module-path`, build system, `--cpu` passthrough, debug-run fast path (`-fno-llvm -fno-lld`) | 2026-05-12/06-20 |
| selfhost artifact refresh — committed = bootstrap-canonical, idempotent (BUG-135 path markers; PascalCase rename) | 2026-06-18 |
| 1.0 gap checklist — all `[x]` (REPL, ImGui LowLevel, tuples, generics, Zig 0.16, `<-`, `Chan`, refinement types, WebSocket, IANA tz, `using`, for-destructuring, CHANGELOG, node-addon, libui-ng widgets/dialogs/consolidation, visibility keywords) | 2026-05/06 |
| 0.15 stdlib completeness: Http.serve, ThreadPool, Path.*, gzip, Tcp.serve, Atomic, Log json/file, Crypto AES/SHA, SQLite, UDP | 2026-05-25 |
| Named `cue init` construction (`Point(y:5)`, reorder + default-fill; cross-module selfhost fill deferred) | 2026-05-19 |
| `x!` force-unwrap; `with` bare-method desugar; remove `try` prefix; inline `if x: y`; `Scope` interface; `is not` precedence | 2026-05-23/24 |
| Nested namespaces; DynLib producer (`@export`); plugin vtable demo | 2026-05-16/26 |
| Contracts (`require`/`ensure`/`invariant`/`old`/`result`/`--turbo`) — 0.12 | 2026-04-24/27 |
| Chained comparisons `a<b<c`; `unless`/`until`; `for-else`; `branch` struct-field patterns; `@[...]` array literals | 2026-04-23/26 |
| SIMD types (`f32x8`/etc.); guarded for-in + `List.find`; `@profile`; `Profile` module | 2026-05-06/08 |
| `Json.parseStrict` + `@reflectable`; `interface` fat-pointer vtable codegen | 2026-04-24/27 |
| String interning; optional-unwrap `as`; named/default param parity (selfhost); Phase 22 selfhost cutover | 2026-04-21/23 |
| User-defined generics (`class Stack(T)`) — 0.8; batteries-included stdlib | 2026-04-10 |
| `@once` + `sys.readLine`; TC Phase 5 generic→interface conformance; `typecheck-merge` + git hook; BUG-099 `.unknown` split; per-commit zip snapshot; style guide | 2026-05-04/10 |
| Self-hosting bootstrap round-trip (5/5); `pro`/`get`/`set`/`body`/`post` keyword removal; source-mapped errors (Phase 19); ImGui backend (stub + GLFW) | 2026-04-06/21 |

---

*Full milestone plan: `wiki/pages/projects/project_zebra.md`*
*Open bug details: `BUGS.md`*
*Self-hosting history: `docs/SELFHOST_JOURNAL.md`*

**Last reorganized:** 2026-07-15 (open work curated at top; completed clumped at
bottom — LSP epic + §28 campaign + node-addon kept in full, older work archived to
one-liners). Prior detail preserved in git history.
---

**Where things live** — this file is one of five; see [NEXT_STEPS.md](NEXT_STEPS.md)
for the map.

| file | answers |
|---|---|
| [docs/PRINCIPLES.md](docs/PRINCIPLES.md) | how do we decide? |
| [docs/archive/FINDINGS.md](docs/archive/FINDINGS.md) | what do we already know? |
| [docs/NEXT_STEPS_to_0.9.md](docs/NEXT_STEPS_to_0.9.md) | what is next, before public release? |
| [docs/NEXT_STEPS_to_1.0.md](docs/NEXT_STEPS_to_1.0.md) | what is next, before the freeze? |
| [docs/NEXT_STEPS_post_1.0.md](docs/NEXT_STEPS_post_1.0.md) | deliberately deferred past 1.0 |

## DECIDED 2026-09-12 — nested containers get REFERENCE semantics (BUG-314's other half)

**BUILT 2026-09-24.** Inner containers are boxed at the type (pointer elements) and at the
store (`_zbr_boxed`); `.at()`/`.get()`/`.fetch()`, for-in elements and `as` bindings alias
the parent; the refusal is removed, the probe asserts the new meaning, and
test/nested_container_ref_test.zbr is the contract. The residue worth knowing: a local
STORED into a parent is copied at that moment (the local stays a value), so
`grid.add(local); local.add(x)` does not reach `grid` -- an outlier against Python for that
one shape, stated in QUICKSTART; making every container a reference type is the larger
change and was not taken.

**DECIDED 2026-09-25 (Sean): the residue is to be RESOLVED, not documented.** `grid.add(row);
row.add(x)` must reach `grid` -- top-level containers as references from birth, the Python
answer. Plan not yet written (Sean deferred it to a fresh session). What the plan has to
answer, from the 09-24 build: (1) where the box is made -- at the ctor (`List(int)()` yields a
box; every local of container type is a pointer) rather than at the store; (2) what
`_zbr_boxed`/`_zbr_unboxed` become once nothing is ever a value (most of both go away, but the
by-value struct field and the FFI boundary keep an unbox); (3) copies must become explicit
(`.clone()`) and the mutation scan that decides `var` vs `const` changes meaning for pointer
locals; (4) BUG-438 (field-chain mutation on a struct local) is in the same code and should
fall with it; (5) the round-trip and output_sweep are the witnesses, since the compiler's own
source uses every shape. Sized as the largest single codegen change left before 1.0.

Sean's call: inner containers (`List(List(T))`, `HashMap(K, List(V))`, and the rest) are
**heap-boxed**, so `parent.at(i)` hands back a reference and a mutation through it is seen
by the parent -- the Python/C#/Go answer. Today's behaviour is the strictly-safe refusal
landed with BUG-314 (`dad59ab`): a mutator on a local bound from `.at()`/`.fetch()` of a
nested container is REFUSED with the idioms that work. That refusal stays until this lands,
so no program can observe the wrong answer in between.

Scope when picked up: the runtime shape of nested containers (a boxed element type in the
emitted Zig), `.at()`/`.fetch()` returning the box, the copy-out rules in
`docs/design/str_ownership.md` for the new case, the BUG-314 refusal REMOVED and its
boundary probe (`bug314_at_copy_probe`, currently `@boundary rejects`) rewritten to assert
the reference semantics, and a `smoke_run` fixture that mutates through `.at()` and reads
the parent. Not for 0.9: it changes what existing programs mean.
