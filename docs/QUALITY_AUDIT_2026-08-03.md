<!-- doc-status: live -->
# Quality audit — where Zebra actually stands for 0.9 / 1.0

*2026-08-03. Written after the instrument pass (`INSTRUMENT_PASS_PLAN.md` §1b, §2, §3) and
a day that closed BUG-241/242/245 and added three gates. Companion to
[`ROADMAP_TO_1.0.md`](ROADMAP_TO_1.0.md), which asks "what gates declaring the surface
stable"; this asks the narrower question **"what would a user hit?"** and corrects two
claims in that document that today's evidence falsifies.*

---

## 0. The bar, taken from Sean's own framing

> *"I'd much rather a system that has no surprises for anyone (or as little as possible)
> rather than more new features."* — 2026-07-30, adopting the hardening programme.

That is a sharper and more testable bar than "feature complete", and it is the one used
throughout this document. **A surprise is any case where a reasonable user does something
reasonable and gets an outcome they could not have predicted.** Ranked by how much trust
each costs:

| rank | class | why it is ranked here |
|---|---|---|
| 1 | **silently wrong answers** | the user does not know to file a bug. They ship it. Trust never recovers |
| 2 | **ships the wrong artifact** | affects everyone downstream, invisible in development |
| 3 | **documented thing does not work** | the user assumes THEY are wrong, and gives up |
| 4 | **basic syntax fails to compile** | embarrassing, but self-announcing: an error message is an honest signal |
| 5 | **internal / environmental** | costs us, not them |

Class 4 is deliberately ranked *below* class 3. A compile error is a bad experience; being
told the wrong thing by the manual is a worse one, because it destroys the user's ability
to self-correct.

---

## 1. What we can now assert, with evidence

Everything here is a measurement taken on 2026-08-03, not a recollection.

| property | instrument | figure |
|---|---|---|
| emitted Zig compiles | `compile_check` (+`-inline`) | **235 / 0 failed** |
| whole corpus emits + typechecks | `full_sweep` | **0 regressions vs 337** |
| programs print what they printed before | `output_sweep` | **322 files, behaviour identical** |
| selfhost has not drifted from the bootstrap | `divergence` | **0 selfhost gaps** |
| compiler is self-consistent | round-trip | **byte-identical** |
| registered fixtures behave | `smoke` | **288 / 288** |
| language does what the REFERENCE says | `boundary_check` | 21 probes / ~140 assertions |
| every corpus file's status is asserted | `registration_check` | 426 tracked, **22 unasserted** |
| every fixed bug has a running test | `bug_fixture_check` | 186 fixed, **76 pinned** |
| stdlib namespaces have a run fixture | `stdlib_run_coverage` | 30/30 reported, **≤28 real** |
| doc examples parse | `doc_example_check` | 147 checked, **93 parse, 11 known-broken** |
| our own tools are not lying | `hazard_lint` | 0, with 8 controls firing |

**FULL tier: 19/19 green.** That is a real result and it is also the least interesting line
here, for the reason §3 gives.

---

## 2. The open defects, classified by what a user would experience

**Twelve bugs are genuinely open.** (`BUGS.md` contains 95 `###` headings, but **54 of them
are entries already marked FIXED or NOT-A-BUG that were never moved to `BUGS_FIXED.md`**.
That is ledger hygiene, not debt — but it makes the open count look eight times worse than
it is, and a stale blocker list invites re-litigating decisions already shipped.)

### Class 1 — SILENTLY WRONG

> **REVISED 2026-08-03, same day, on starting the sweep. This section originally listed
> three bugs and called all three 0.9 blockers. That was wrong in two of the three, and
> the headline built on it (§5, *"blocked on three bugs plus `--release`"*) was wrong with
> it.** Reading each ticket properly before acting is what corrected it — which is an
> argument for triaging from the tickets rather than from a classification made over them.
>
> - **BUG-237 was MISCLASSIFIED.** It emits wrong Zig and **`zig` rejects it**
>   (`expected type 'Ast.Expr', found '*Ast.Expr'`). The program does not compile. The
>   "silently" in that ticket means the *front end* does not warn — not that a user gets a
>   wrong answer. It is **Class 4** with a poor diagnostic, and its better home is the
>   front-end gap in §5b: *"referencing a union that is not `exposing`-imported should be
>   an error"* is exactly a check that belongs in the Resolver.
> - **BUG-225 is genuine Class 1 but is NOT a sweep item.** Its own ticket measured the
>   blast radius: `s[i]` returning `char` is what the selfhost lexer is built on — ~104
>   subscript sites across `selfhost/`, 559 `c'x'` literals compared against the result.
>   Retyping it means deciding how `byte` and `char` compare. **That is a language design
>   decision, not a bug fix**, and it is Sean's call — see §5c.
> - **BUG-227 was the one real, actionable Class 1 item, and it is FIXED** (2026-08-03).

| bug | status |
|---|---|
| **BUG-227** | `tokenize` split on the sequence, not any character | ✅ **FIXED** — `tokenizeAny`, pinned by `bug227_tokenize_any_test` |
| **BUG-225** | `str` indexing is silently wrong for non-ASCII | ⬜ open — **design decision, §5c** |
| ~~BUG-237~~ | reclassified to Class 4 / front-end gap | |

The structural point stands regardless of the count: **no gate we have can find this class
by construction.** `compile_check`, `full_sweep` and `divergence` all ask "does it
compile?", and `output_sweep` is a *golden* baseline, so it locks in whatever the behaviour
already was. BUG-226 is the precedent — valid Zig printing `{ 97 }` for `a`. BUG-227 sat
open for five days in a corpus of 426 files and 19 green gates.

### Class 2 — ships the wrong artifact

| bug | what happens |
|---|---|
| **BUG-228** | `zebra --release` produces an **unoptimized** binary |

Everything a user distributes is built with this flag. Related: every gate we run is Debug,
so `unreachable` (UB in ReleaseFast) is exercised by nobody — `lint_oom_unreachable` is a
static proxy, not a witness.

### Class 3 — documented behaviour that does not work

Not a numbered bug, but measured today and material: **11 code examples in `live` docs do
not parse**, and before today **zero** of 224 had ever been checked. `QUICKSTART`'s entire
concurrency section documented `sys.go(lambda …)` — and `lambda` is not a Zebra keyword.
Five blocks, none of which had ever compiled (BUG-245).

### Class 4 — fails to compile, but says so

BUG-230 (annotated non-empty list literal), BUG-240 (annotated empty set literal), BUG-231
(named args inside `${…}`), BUG-233 (lambda parameter shadowing), BUG-201 (nested-container
dispatch), BUG-246 (`Atomic.add` inside `capture`).

Six bugs, and the pattern is worth naming: **most are ordinary syntax a beginner writes in
their first hour** — annotate a list, annotate a set, interpolate a call. They are honest
failures, but there are enough of them to read as "this language is unfinished".

### Class 5 — ours, not theirs

BUG-244 (a 20 MB executable leaked per run — 120 GB had accumulated), BUG-212 (selfhost
`const`/`var`).

---

## 3. What a green board does NOT cover

Ranked by how much of the risk each hides.

1. **Correct-compiling wrong behaviour.** Structural, not incidental. Only
   `boundary_check` (21 probes) and run-and-compare fixtures can see it, and `output_sweep`
   — the broadest behaviour instrument at 322 files — is a *golden* baseline: it proves
   behaviour has not **changed**, never that it was **right**.
2. **Anything requiring a human.** GUI rendering, input, layout, resize, colours. Four GUI
   crashes have sat under fully green gates; `gui_scaffold_check` now covers *startup*, and
   startup only.
3. **Release-mode behaviour.** Every gate runs Debug.
4. **110 fixed bugs with no running test (59%).** They are fixed today. Nothing asserts
   they stay fixed.
5. **The 22 unasserted corpus files**, including the **15 in BUG-243 that have never
   compiled** — spot-checked again today, still broken. Two are the regression fixtures for
   BUG-106 and BUG-108, so **those two fixes remain unverified**.
6. **`Tcp` and `Http` have no runtime exercise at all.** Their fixtures' `main` only prints
   a string; the `serve` calls sit in a `startServer()` nothing ever calls.

---

## 4. Corrections to `ROADMAP_TO_1.0.md`

Two claims in that document are falsified by today's evidence. Recorded here rather than
edited silently, because the roadmap is a dated assessment and the *change* is the finding.

| roadmap claim | status |
|---|---|
| "Docs reconciled to reality: 🟡 **QUICKSTART current**" | ❌ **false.** Its concurrency section never compiled. Now instrumented; 11 live-doc examples still do not parse |
| "the honest road to 1.0 is **one technical bug** plus the freeze" (2026-07-28 audit) | ⚠ **superseded.** That audit predates BUG-225/227/228/230/237/240/243/245/246. The freeze framing stands; the count does not |

The 2026-07-28 audit was right about its own moment and right in method. It is a good
illustration of why an audit needs a date attached and a re-run, not a re-read.

---

## 5. The recommendation

**Internal 1.0 — supportable now.** The compiler is well defended against regressing what
it does. Three independent heavy witnesses, a 322-file behaviour baseline, an intent-authored
suite, and a self-consistency proof. For a team that knows the sharp edges, this is solid.

**External 0.9 — closer than this document first claimed.** ~~The blocker is the three
silent-wrongness bugs plus `--release`.~~ **Revised the same day:** one of those three was
misclassified, one is a design decision rather than a defect, and the third is now fixed.
The remaining hard blocker is **`--release` (BUG-228)** plus **a decision on BUG-225**.

The reasoning that made silent wrongness the bar is unchanged and still right: a user who
gets a wrong answer with no error does not file a bug — they conclude the language is not
trustworthy, and they are not wrong to. What changed is the count, not the principle.

### A falsifiable definition of ready

Not a feeling — each item is checkable, and two are deliberately about *instruments* rather
than defects, because the recurring lesson of this repo is that the unmeasured is where the
damage lives:

1. ~~**BUG-225, BUG-227, BUG-237 fixed**~~ → **BUG-227 fixed ✅**; BUG-237 reclassified;
   **BUG-225 needs a DECISION, not a fix** (§5c). Each Class 1 fix carries a
   **run-and-compare** fixture, because a compile check cannot witness this class.
2. **BUG-228 fixed**, plus one gate that actually runs a `--release` build.
3. **The BUG-243 fifteen resolved** — fixed, or deleted with a reason. In particular the
   BUG-106/BUG-108 fixtures must actually run, or those fixes stay unverified.
4. **`Tcp` and `Http` given real run fixtures**, on the `ws_echo_test` pattern (bounded
   retry, `smoke_run_bounded`). They are currently counted as covered and are not.
5. **A round of new A3 boundary probes finds nothing.** Weighted most heavily of the five.
   A3 is the only instrument that can find day-one wrongness; if a fresh batch written from
   the reference comes back empty, that is the strongest evidence available that the
   language does what it claims. If it finds three more BUG-230s, we were not close.

**Class 4 (the six compile-time bugs) is explicitly NOT on this list.** They are real and
worth fixing, but they announce themselves, and holding 0.9 for them would trade a
measurable risk for a cosmetic one.

### Sequence

1. The three silent-wrongness bugs — highest trust-cost per unit of work.
2. BUG-228 + a release-mode gate — small, and it is what users actually ship.
3. BUG-243's fifteen — mostly triage; two are unverified fixes.
4. A3 round two — the exit criterion, and the one that could reopen everything.
5. Class 4 sweep, ledger hygiene (move the 54 resolved entries), doc-example baseline.

---

## 5b. The front-end gap — measured, at Sean's suggestion

Prompted by an observation on 2026-08-03: all four BUG-243 files spot-checked exit **0**
under `zebra -c` and then fail to build. `-c` is documented as front-end-only and
deliberately incomplete — but *"incomplete"* is not a size, and every case where `zig`
delivers a diagnosis that Zebra's own front end could have delivered is precisely the work
named by NEXT_STEPS' organizing goal, **"move checking INTO Zebra"**.

Measured across the corpus (`scratchpad/frontend_gap.py`): for every tracked
`test/*.zbr` **not** in the `full_sweep` baseline, does `-c` catch what `zig` rejects?

| of 63 corpus programs that do not compile | |
|---|---|
| `-c` catches it | **31** |
| **`-c` misses it** | **23 (43%)** |
| compiled after all | 9 |

**The first number was 49, and it was wrong.** 26 of those are library modules whose only
failure is `root source file struct 'MathUtils' has no member named 'main'` — they are not
programs, `-c` is right to accept them, and the harness was at fault for running them as
executables. All 26 were confirmed to pass `-c`, so the correction is exact rather than
estimated. Same lesson as every other instrument here: the first number a new probe
produces is a hypothesis.

**Where the 23 sit**, as candidate checks to add rather than as symptoms:

| class | note |
|---|---|
| undeclared identifier / scope | e.g. `self` used outside a class — the Resolver owns scopes and has the information |
| unhandled error union | this is the §28b explicit-`?` rule; the TypeChecker knows what throws |
| type mismatch | heterogeneous list literals, enum/int confusion — inference gaps |
| generics (`expected 'T', found '*T'`) | genuinely harder; not low-hanging |

**A tension to resolve before acting.** Three of the 23 — `bug099_unresolved_test`,
`bug106_heterogeneous_list_test`, `c_interop_test` — are the **deliberate asymmetry
witnesses** `check_mode_check.sh` requires, to prove that the `-c` vs `--check-full` split
`--help` promises actually exists. That gate **fails by design when no witness survives**.
So closing the gap is not simply "add checks until the number is zero": each check moved
into the front end must be accompanied by a decision about whether the asymmetry is still
a promise worth keeping, and the witness set updated deliberately rather than discovered
broken.

**Why this is worth doing beyond tidiness.** A miss is not just a late error — it is an
error delivered *in Zig's vocabulary, about emitted code the user never wrote*. `expected
type 'i64', found '*const [3:0]u8'` is a fine message for someone reading generated Zig and
an unhelpful one for someone who wrote a list literal. Every check moved inward converts a
leaked diagnostic into a Zebra one, which is the same argument that motivated the error-
experience work in 2026-06.

## 5c. BUG-225 — a decision for Sean, not a sweep item

`s[i]` on a `str` yields a raw UTF-8 **byte** typed as `char` (u21). For any multi-byte
codepoint it produces a character that is not in the string, silently:

```zebra
var s: str = "eéx"
print(s[1].toString())     # Ã  — byte 0xC3 widened to U+00C3. WRONG.
for c in s.chars()
    print(c.toString())    # e é x — correct; chars() decodes
```

**Why this is not a sweep item.** The ticket measured the blast radius before recommending
anything: `s[i]` returning `char` is what the **selfhost compiler's own lexer** is built on
— `Lexer.zbr:116` is `def peek(): char` returning `src[pos]`, ~60 subscript sites in that
file, **~104 across `selfhost/`**, and **559 `c'x'` literals** compared against the result.
Retyping `s[i]` means deciding how `byte` and `char` compare. That is language design.

**The options, and what each costs:**

| | option | cost | precedent |
|---|---|---|---|
| **a** | **Document the limit for 0.9**, retype in 1.x | ~zero code; honest docs + a `byteAt()` alias | closest to **Go** — indexing yields a byte, and Go never pretends otherwise |
| **b** | Retype `s[i]` to `byte`, define `byte`/`char` comparison | ~104 sites + a comparison rule, mid-freeze | Go, done properly |
| **c** | Make `s[i]` on a `str` an **error**; force `byteAt(i)` / `chars()` | clearest semantics, most disruptive | **Rust**, which forbids `str` indexing outright |

**The conflict worth being explicit about.** The ticket recommends **(a)** — it competes
directly with the pre-0.9 churn freeze, and honest documentation captures most of the
value. This audit's §2 ranks silent wrongness as the top trust cost, which argues for
**(c)**. Both readings are defensible and they point different ways.

**My read, offered as a recommendation rather than a decision:** the specific defect is not
that indexing yields a byte — Go does that and nobody is surprised. It is that **the type
says `char`**, which is the language asserting something false. So (a) is acceptable *only*
if the documentation is blunt: "`s[i]` yields a byte, typed `char` for historical reasons;
use `chars()` for characters and `byteAt()` when you mean bytes." If we are not willing to
write that sentence, we should do (c) instead — and the fact that we would wince at writing
it is the useful test of whether (a) is really acceptable.

**This is Sean's call.** It changes what 0.9 promises about text handling, which is not a
decision to take inside a sweep.

## 6. The finding that should outlive this document

Three bugs were closed today — BUG-241 (`Progress`), BUG-242 (`Csv`), BUG-245 (`Shell`) —
and they were the **last three stdlib namespaces with no run coverage**. Every one had a
broken Zig 0.16 migration behind it. Three for three.

> **Code that nothing executes does not survive a toolchain upgrade, and nothing tells
> you.**

That predicted correctly three times in a row, which makes it a usable planning tool rather
than a slogan. The question it turns into is answerable and enumerable: *what else does
nothing execute?* Today that question was pointed at stdlib namespaces (now 0 unexercised),
runtime helpers (`unreachable_runtime.sh` — 1 remaining, `_build_auto_run`) and doc examples
(now gated). The surfaces where it has **not** yet been asked are §3's list — and that list,
not the bug count, is the honest measure of how much we do not know.
