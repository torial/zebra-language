<!-- doc-status: live -->
# Zebra — how we decide

**This file answers "how do we decide?", and nothing else.** Measurements live in
[FINDINGS.md](FINDINGS.md); work lives in the `NEXT_STEPS_*` files. It was extracted
from NEXT_STEPS.md on 2026-08-29, where the system concept and the decision
framework had been filed under the brainstorm that produced them.

**Scope split with the wiki:** cross-project concepts that apply beyond Zebra live
in `wiki/pages/concepts/` -- `concept_ungit-principle`, `concept_armor-at-the-seams`,
`concept_founders-primary-sources`. This file holds the **Zebra-specific** decisions.
Do not duplicate the wiki here; the repo copy is the one that would go stale.

**Required reading before the §15 API freeze** (they are the inputs to *"are we
happy with this surface forever?"*): `wiki/pages/concepts/concept_zebra-language-warts.md`
and `wiki/pages/concepts/concept_zebra-learner-readiness.md`.

## Honest risks carried forward from the 1.0 roadmap

Recorded here rather than in a queue because they are judgement calls about the
freeze, not work items:

- **"Done" is a judgment call, not a checklist outcome.** The features are there;
  whether the quality bar (error UX, doc accuracy, edge-case robustness) clears
  *"recommend this to a stranger"* is the subjective gate.
- **Single-maintainer stability promises are heavy.** Freezing the API commits us to
  not fixing design warts later without a major bump. Worth a deliberate *"are we
  happy with this surface forever?"* review before §15.
- **Real-world validation is both the proof and the risk.** If a runtime pass reveals
  deep language gaps, those are real 1.0 blockers -- better found before a stability
  promise than after.

## STANDING ITEM — THE FOUNDERS THREAD IS OPEN, NOT DONE (Sean, 2026-08-26)

**Sean's convention: this is not a section to be completed and closed. Work other tickets,
then come back every few days and see whether the intervening work has spurred new
insight.** The evidence that this is the right shape is that the best items here did not
come from a planning session -- they came from bouncing an idea back and forth until it
turned into something neither of us started with:

- Sean's `algorithms.sorting.<bigO>.<name>` became **complexity as reflection data**, which
  then became **a static cost diagnostic** -- Knuth's mandate delivered before the program
  runs.
- "does a `List` local get freed?" became a **measured 20x allocation lever**.
- "track auto-scoping in the transform list" became the argument that the transform
  interface is a **prerequisite** for auto-scoping rather than a companion to it.

**Nothing enforces the cadence.** This is a habit, in the same sense that "`--daily` is the
last thing run when overnight work stops" is a habit -- stated so it can be kept, not
automated. When picking it up again, the useful prompt is not "what is left on the list" but
**"what has the last few days' work taught us that changes an item here?"**

### THE TRIGGER RULE, derived 2026-08-26 — when may a transform fire automatically?

Sean proposed detecting statically that a program never threads, and applying
`--single-threaded` inherently. That is safe, and the reason it is safe generalises into the
rule the transform interface needs for its `trigger` field:

> **A transform may fire AUTOMATICALLY when its precondition is INDEPENDENTLY ENFORCED.
> Otherwise it must be opt-in.**

| transform | precondition | independently enforced? | trigger |
|---|---|---|---|
| infer `--single-threaded` | no thread spawn reachable | **yes** — the flag already makes a spawn a COMPILE ERROR, so a wrong analysis fails the build rather than miscompiling | automatic |
| automatic arena scoping | no allocation outlives the call | **no** — a wrong escape analysis frees live memory, in release, silently | opt-in, until escape analysis has its own verifier |

Two transforms of the same shape with opposite safety profiles, separated by a criterion
rather than by taste. It also gives a research direction for anything we *want* automatic:
find the independent enforcement first, and the transform becomes safe by construction.

### TRANSFORM PROVENANCE — intrinsic vs third-party (Sean, 2026-08-26)

When a miscompile is reported, the first question is **which transform produced this**, and
whether it was ours determines who owns the defect. So:

- `metadata` carries an **origin** (intrinsic / plugin name + version).
- A diagnostic arising from transformed code should be able to **name the transform that
  touched it**.
- Plugins are **added and removed explicitly**, not picked up by directory scanning. A
  plugin present-but-undeclared is invisible at exactly the moment it matters -- the same
  argument `corpus_ls.sh` makes about untracked files, and `registration_check` about
  unasserted ones.

## POST-0.9, PRE-1.0 — BRAINSTORM: WHAT THE FOUNDERS ACTUALLY RECOMMENDED (Sean, 2026-08-26)

Sean's: mine the foundational SE literature for things worth *employing*, not quoting. The
companion to the Knuth item above, and the reason it is worth doing is not reverence — it is
that **several of these were arrived at here independently**, which is decent evidence the
ideas are load-bearing rather than decorative. Where that has happened it is noted, because
"we already do this" is the most useful entry in a list like this.

### Already here, arrived at independently

| idea | who | where it lives in Zebra |
|---|---|---|
| Design by Contract | Meyer (Eiffel) | `require`/`ensure`/`invariant`, gated by `contract_mode_check` |
| Null tracking as a language property | Hoare's "billion-dollar mistake" | nil tracking, `if x != nil` narrowing |
| Guarded commands must be exhaustive | Dijkstra | `branch` exhaustiveness — default-on since the §28 review |
| CSP | Hoare | `Chan(T)` + `sys.go` |
| Pipelines / do one thing well | McIlroy | the `->` pipeline operator |
| Removing features is progress | Wirth (Oberon) | `lint_reserved_words` — seven keywords freed so far |
| Programming as theory building | Naur | this repo's habit of recording WHY, not just what |

That last row is the one worth sitting with. Naur's claim is that a program IS the theory in
the builders' heads, and that documentation cannot fully carry it — which is precisely why
this repo's comments record *the failure that motivated the code* rather than restating the
code. It was not adopted from Naur; it was rediscovered by getting burned.

### Candidates worth arguing about

*Dijkstra*
1. **`branch` with no matching guard should be a defined outcome, not a fall-through.** In
   guarded commands, "no guard true" is an ERROR — a named one. Worth checking what Zebra
   does today (see BUG-288 / the exhaustiveness diagnostics, which cannot currently say
   WHERE).
2. **Weakest-precondition reasoning as the semantics under `require`/`ensure`.** Zebra
   inherited contracts from Eiffel's ergonomics; wp is the theory that makes them composable.
   Would inform what `ensure` may legally refer to.
3. "The competent programmer is fully aware of the limited size of his own skull" — the
   argument for the move-checking-inward programme already in this file.

*Meyer, beyond contracts*
4. **Command-Query Separation as a lint**: a method either changes state or returns a value,
   never both. Mechanically checkable, and Zebra already knows which methods mutate (it uses
   that for `const` vs `var` emission).
5. **Uniform Access**: a field and a zero-argument method should be indistinguishable at the
   call site. Affects whether `x.size` and `x.size()` should both work.

*Parnas*
6. **Information hiding as the module criterion** — decompose by "what is likely to change",
   not by execution order. A lens for the `selfhost/` module split.
7. **"A rational design process and how to fake it"**: documentation written as though the
   design were derived cleanly, even though it never is. This repo does the opposite
   (records the mess) and that is a deliberate disagreement worth stating rather than
   drifting into.

*Knuth, beyond the profiling quote*
8. Literate programming — the inverse of `doc_example_check`, which already asserts the
   docs' code is real. The remaining half is code that carries its prose.

*Brooks*
9. **Essential vs accidental complexity as a feature-acceptance test** for 1.0: does this
   feature remove essential complexity from users, or only accidental complexity we created?
10. **The second-system effect** as an explicit hazard for 1.0 scope.

*Lamport*
11. A written specification of the concurrency model (threads, `Chan`, `Atomic`, the two-tier
    allocator). Zebra has the primitives and no stated memory model.

### THE SYSTEM CONCEPT — **ACCEPTED (Sean, 2026-08-29)**

**No longer a draft.** Accepted after three iterations, together with the decision
framework below (four gates, seven ranked axes) and the accepted-tensions table. The
audience clause was rewritten by Sean; the ordering of axes 2 and 3 was his call,
against Claude's proposal.

**It had already adjudicated real features before it was accepted**, which is the
evidence that it does work rather than merely reads well: restoring the small-team
bound made visibility modifiers suspect, and within minutes that produced BUG-315
(`protected` removed) and BUG-316 (`internal` removed). Neither was on any queue.

Use it the way it is written: **gates first — a failure is a rejection, not a low
score — then the axes, in order.** The material below is the record of how it was
arrived at, including the arguments that lost.

#### The draft as first proposed, and how it changed

Wirth's test for a feature is not "is it useful" but "is it compatible with the original
system concept", and his claim is that the incompatibility usually *passes unrecognized*
rather than being argued and lost. That test needs something to test against, and Zebra has
never written one down. **This is a DRAFT proposed by Claude, not a decision** -- the
identity of the language is Sean's call. It is offered because a concept nobody has written
cannot adjudicate anything, and the 0.9 docket is exactly where it would be used.

The test of a good concept is not that it sounds nice but that **it settles arguments**. The
candidate below is checked against real open questions at the end.

---

> **Zebra is a high-level language that does not make you choose between saying what you
> mean and knowing what it costs.**
>
> Three commitments follow, in priority order:
>
> **1. Safety is not optional at run time.** Where the compiler can prove a check
> unnecessary it removes it. Where it cannot, the check stays, and there is no switch to
> turn it off. (Hoare 1981: his users, offered exactly that switch, refused it.)
>
> **2. The compiler says what it did.** Any transformation applied to a program is
> describable in Zebra itself, and queryable. A transformation that cannot describe itself
> does not ship. (Hoare via Knuth 1974.)
>
> **3. Cost is legible before the program runs.** The language does not hide asymptotics or
> allocation behind convenient syntax, and the compiler reports what parts of a program cost
> the most without being asked. (Knuth 1974; Lampson 1983 on abstractions whose cost only a
> "lively awareness" avoids.)
>
> The performance claim that makes (1) affordable: **within 30-50% of hand-written Zig**,
> measured, not asserted. As of 2026-08-26 the measured gap on numeric array code is ~18%.

---

**Does it adjudicate? Checked against questions actually open today:**

| question | the concept's answer |
|---|---|
| build an unchecked `.atUnchecked()` accessor? | **No** -- violates (1). This is the answer Hoare's users gave. |
| automatic arena scoping? | **Only after the transform interface** -- (2) forbids invisible transformation, and this one frees live memory when wrong. |
| infer `--single-threaded` automatically? | **Yes** -- (2) is satisfied because the precondition is independently enforced (a spawn becomes a compile error). |
| complexity in the import path vs reflection data? | **Reflection** -- (3) wants cost legible, and (2) wants it queryable rather than encoded in a name that then cannot change. |
| retire the imgui backend? | **Yes** -- carries no commitment; three backends for one job is the "bells and whistles" Wirth names. |
| keep `.at()` bounds-checked by default at ~17%? | **Yes** -- (1) is first in priority order precisely so this is not re-argued each time it is measured. |

Six questions, six answers, and none of them "it depends". That is the property worth
keeping if the wording changes.

#### ITERATION 2 -- SEAN'S REJECTS AND TENSIONS (2026-08-29). IN PROGRESS, NOT DECIDED.

Working notes from a live brainstorm. **Nothing here is settled**; it is recorded so the
round is not re-derived. Sean's contributions are marked; the rest is Claude's reaction.

**THE ORGANISING IDEA THAT CAME OUT OF IT.** Safety is non-negotiable AND the programmer must
never fight the compiler for it (Sean: give up compiler speed for runtime resource use, "but
not wanting something like the rust borrow checker, which kills thinking flow"). Those two
together admit only one shape: safety is checked at RUN time, and the speed is won back BY
THE COMPILER.

> **The compiler pays, never the programmer.**

That unifies commitment (1), the anti-borrow-checker stance, BUG-313 and the Cocke transform
-- which it recasts as strategically required rather than locally faster. It rejects lifetime
annotations, mandatory effect systems, `unsafe` blocks, and termination obligations.

**SEAN'S REJECTS**, scored for rejection power:

- *No resource-intensive solution where a lighter one exists; waste is failing to evaluate
  data structures and algorithms for the Pareto frontier.* (Sean's rewrite of "no heavy
  waste", and much stronger -- his examples, Quicksort-not-Bubblesort and hoisting the bounds
  check out of the loop, span library choice AND compiler transform.) **Guard needed: the sin
  is the UNEXAMINED choice, not the suboptimal one**, or it licenses exactly the premature
  optimisation Knuth argues against. Open: Pareto in WHICH dimensions (time, space,
  predictability, code complexity). **Consequence: this promotes the `algorithms`/TAoCP
  namespace from dogfood to obligation** -- if "a lighter one was available" is a defect, the
  language owes people the lighter one in reach.
- *No verbosity for clarity's sake.* Sean's analogy: C.S. Lewis says in a paragraph what
  others take pages to say; "worth the upfront language design time to figure out how to make
  the semantics rich and concise." **Note that is a COST VOLUNTEERED (design latency), which
  is the property demanded of every other line here.** Encapsulation for terse-and-regular:
  **"concision through precision, never through cleverness"** (memorable), *high semantic
  density, low spelling variance* (technical). The enemy is DIALECTS, not verbosity; the test
  is whether a construct lets one idea be written two ways.
- *Founders over fads*, reformulated twice. Claude's version -- prefer ideas that survived
  contact with a working system built by their advocate -- avoids the appeal to authority
  (Sean: "ultimately the fads are an appeal to a MARKETING authority"). Sean's addition is the
  sharper half: *be skeptical of claims that cite no measured results and no engineering
  trade-offs.* **That is the same test this document applies to ITSELF** -- a concept must
  name what it gives up; a methodology that names no cost fails identically. State it once:
  **a claim that names no cost is marketing, whether it comes from us or at us.** (Sean's
  example: Clean Code promises maintainability loudly and never prices the added abstraction
  layers or the lost machine sympathy.)
- *Simple things simple, hard things possible* -- **AXED by agreement.** Nearly universal
  aspiration, low rejection power, and Perl is the cautionary tale of achieving it.

**TENSIONS ACCEPTED** (Sean's proposal that the concept carry these explicitly -- a concept
that lists its tensions cannot be quietly violated by resolving one in secret):

| # | tension | stance |
|---|---|---|
| T1 | expressive density vs. small surface | **the grammar freeze resolves it** (below) |
| T2 | safety always vs. no wasted resources | the compiler pays, never the programmer; ~17% named aloud |
| T3 | compile time vs. runtime resource use | trade compile time freely, NEVER flow of thought |
| T4 | founders-over-fads vs. AI-first being brand new | receipts not age -- this repo is the working system |
| T5 | shipping speed vs. design latency | pay upfront for density (Sean's Lewis point) |
| T6 | AI regularity vs. human expressive freedom | **unresolved, and probably real** |

#### ITERATION 3 -- ACCEPTED (2026-08-29)

Three things stopped being proposals in this round.

**1. THE DECISION FRAMEWORK: FOUR GATES, THEN SEVEN RANKED AXES (settled 2026-08-29).**

The waste rule ("no resource-intensive solution where a lighter one exists") could not
adjudicate without saying Pareto in WHICH dimensions. A first version named four resource
axes -- predictability, footprint, throughput, implementation complexity -- and was then
applied to the whole of NEXT_STEPS. **ELEVEN OF EIGHTEEN ITEMS SCORED ON NONE OF THEM**,
which is what forced the structure below rather than a longer list of the same kind.

**SAFETY IS NOT AN AXIS. IT IS A GATE, AND THAT DISTINCTION IS THE WHOLE POINT.** An axis is
by definition tradeable -- that is what ranking means. Commitment (1) says there is no off
switch. So if safety sits anywhere on a ranked list, someone can eventually argue "binary
size outranks it in this case", and the concept has authorised precisely what it exists to
forbid. Same for describability and for flow of thought.

> **TIER 1 -- GATES. Pass/fail. A failure is a REJECTION, not a low score.**
>
> - **G1** Safety holds at run time; there is no switch to turn it off. *(Hoare 1981)*
> - **G2** The compiler can describe what it did, in Zebra. A transform that cannot
>   describe itself does not ship. *(Hoare via Knuth 1974)*
> - **G3** The compiler pays, never the programmer. No analysis the programmer must fight.
>   *(Sean's flow-of-thought line; this is what excludes a borrow checker)*
> - **G4** Inside the audience bound: a whole-system builder, alone or in a small team.
>
> **TIER 2 -- AXES. Ranked. A lower axis never outranks a higher one.**
>
> 1. **Predictability of cost** -- can you know what this costs before running it?
> 2. **Legibility** -- does the system surface what it already knows? *(commitment 3, UNGIT)*
> 3. **Surface area** -- how much language must be learned and maintained? *(Wirth; also
>    what AI-assistability depends on)*
> 4. **Runtime working set**
> 5. **Throughput**
> 6. **Binary size**
> 7. **Our implementation cost**

**THE ORDERING PRINCIPLE IS STATED, or the list is just taste: rank by IRREVERSIBILITY,
then by WHO PAYS.** Surface area is near-permanent (Hoare: "a feature which is included
before it is fully understood can never be removed later"); binary size is a compile flag
away; implementation cost is ours alone, so it is last. The principle also PREDICTS Sean's
call that working set beats binary size rather than merely recording it -- a working set is
the user's problem at run time, a binary is ours at build time.

**Axes 2 and 3 were Sean's call**, made against Claude's proposal: legibility above surface
area. Claude argued surface area to #2 on irreversibility, citing Zig's feature churn as
the failure mode; Sean ranked legibility higher. The consequence, recorded because it is
what the ordering now DECIDES: a new API that makes cost knowable clears more easily than
it would have, so the `algorithms` namespace and complexity-as-reflection-data both argue
their usefulness rather than having to argue their size first.

**What the axes reject, unchanged from the first version:** GC pauses, "usually fast"
heuristics with bad worst cases, amortised-spiky structures where a steady one exists. **The
demonstration that naming them does real work is that it refines Sean's own example**: with
predictability first, plain Quicksort is OFF the frontier (O(n^2) worst case) and introsort
is on it. The instinct picked the direction; the axes picked the algorithm.

**2. STANDING PRACTICE: EVALUATE AGAINST THE FRAMEWORK (Sean).** NEXT_STEPS items and bug
entries are judged gates-first, then axes, the way the introsort example judges a sort. This
is the concept doing work rather than sitting in a file.

**AND IT DOUBLES AS PR TRIAGE (Sean's observation).** The gates are a pre-review checklist:
a submission that fails one can be triaged WITHOUT reading the implementation, because the
objection is not about code quality. The axes then say what the change is buying and what it
is spending, in an order the reviewer did not invent for the occasion. That is the honest
version of "we'll know it when we see it", and it is worth having before there is a first
PR rather than after.

**3. A COMPATIBILITY TRANSFORM IS A MECHANICAL REWRITER, NEVER A PERMANENT ACCEPTOR
(accepted by Sean).** The grammar-freeze escape valve -- reinstall removed syntax as a
Transform plugin -- had a hazard: **permanent compatibility plugins are permanent
dialects**, which is exactly the "one idea written two ways" the concision rule rejects
(T6 in miniature). So the plugin reads 1.x syntax and **emits 2.x source** rather than
accepting 1.x forever. Old code keeps working, the living language keeps one spelling, and
the plugin has a natural end -- once you have run it, you are done.

Deprecation by migration, not by dialect. **This is also an escape from Hoare's trap** ("a
feature which is included before it is fully understood can never be removed later"): it
removes a feature from the living language without breaking anyone. Closer than it sounds
-- `AstPrinter` already exists, so a Zebra-to-Zebra printer is an extension rather than a
new subsystem.

**FIRST THING THE DRAFT ADJUDICATED THAT IT WAS NOT WRITTEN TO ADJUDICATE: BUG-315.**
Restoring the small-team bound (Sean: "my interests are NOT into a system that can be used
by 10+ developers on a project") restores the rejection of visibility modifiers whose job
is policing team boundaries -- and within minutes that found `protected`, a reserved word
implemented as a synonym for `private` and documented with semantics requiring inheritance
the grammar cannot express. Removed the same day. That is the strongest evidence so far
that a written concept earns its keep.

**GRAMMAR FREEZE (Sean) -- the best structural idea of the round.** Freeze the grammar at or
near 1.0; extension happens through the stdlib and Transforms rather than new syntax.
Precedent: Oberon and C both froze and outlived more expressive contemporaries. Two
consequences worth naming now: (1) **the transform interface becomes load-bearing
infrastructure**, not a tidy-up, and deserves the design weight the grammar has today;
(2) **the instrument already exists** -- `grammar_export.py --check` derives grammar.txt from
the Earley rule table and refuses below 400 rules, so a freeze is a pin on that table rather
than a new gate. **Open question to settle AT freeze time, not at first crisis: the amendment
procedure** for when the grammar turns out to be wrong afterwards. Every frozen language
faces this, and the cautionary tales are the ones that improvised it.

**TOOLS AS A USER-FACING SURFACE (Sean).** Document the tooling, and triage which
compiler-development tools should ship to Zebra's own users. First-pass candidates: `doctor`
(is this tree trustworthy), per-Knuth cost reporting, a transform `--explain`, and the
reconciliation discipline behind `evidence_digest`. Filter: **does it tell the user something
the compiler already knows** -- i.e. UNGIT, so the triage has a criterion rather than taste.

**AUDIENCE, SEAN'S REDRAFT** (supersedes Claude's; the "only ever sees one corner" exclusion
is WITHDRAWN -- a specialist working in one area is a fine case, and that clause was inferred
from the dogfooding record rather than intended):

> Zebra is for someone who wants to build whole systems with as few hoops as possible --
> alone, nearly so, or with a large team -- and who wants the compiler to carry the
> engineering knowledge they shouldn't have to re-derive. It is not for those who want a
> dynamic language or an Object Oriented language or a compiler nanny.
>
> It is built to be read, written and reasoned about by an AI collaborator as a first-class
> user -- which means regularity beats cleverness, and a diagnostic is a feature, not an
> apology.

**BOTH OBJECTIONS RESOLVED IN ITERATION 3.**

*Team size:* Sean restored the bound -- "my interests are NOT into a system that can be used
by 10+ developers on a project". Naming the number is what gives it teeth, and it restores
the rejections that had gone missing (no heavyweight package ecosystem, no visibility
modifiers whose job is policing team boundaries). Proposed wording: **"alone or in a small
team -- not ten or more developers on one codebase."**

*Inheritance:* **Claude was wrong, and Sean's instinct was right.** The claim that "Zebra has
classes, interfaces and inheritance" does not survive the grammar: `ClassHeader ->
ImplementsClauseOpt AddsClauseOpt`, with no class-from-class inheritance anywhere. What is
absent is IMPLEMENTATION inheritance. Since "not an Object Oriented language" would still
mislead a reader of a language that has classes, the phrasing to use is **"a deep class
hierarchy"** in the exclusion list, with the accurate technical line nearby: *Zebra has
classes but no class hierarchy -- conformance from interfaces (`implements`), reuse from
mixins (`adds`) and `extend`; nothing is inherited implicitly.*

On AI-assistability looking like zeitgeist, Sean's answer is decisive for this project: he
may be the language's only user, and he works with AI. The criterion is therefore not a bet
on a trend but a description of the actual development model -- which is also why it is
testable HERE and almost nowhere else.

**RESOLVED — the audience clause was Sean's rewrite (see ITERATION 3). Kept below because the reasoning is the reusable part.** Originally recorded as: left open rather
than filled, because it is an identity question. Three things are worth having settled first:

*The test that separates a concept from a slogan is REJECTION POWER* -- a concept earns its
keep only where it says no to something genuinely attractive, since Wirth's whole mechanism
is that features get adopted BECAUSE users want them. Equivalently: it must name what you are
willing to LOSE. Every concept that worked gave something up (Oberon features, C safety,
Python speed). One that gives up nothing is not one.

*By that test "high level like Python, without sacrificing performance or quality" is a
slogan* -- it forbids nothing, because every proposal that will ever arrive claims to be more
expressive and no slower. High-level-ness IS concept material, but only inverted from a
benefit claimed into a cost accepted: "when expressiveness and speed conflict, Zebra takes the
expressive form and makes the cost visible, rather than offering a faster unsafe form
alongside it." That version rejects `.atUnchecked()`, `unsafe` blocks, and checks-off-in-
release. Same subject, opposite direction, and it settles arguments.

*The same test convicts this draft's own headline.* "does not make you choose between saying
what you mean and knowing what it costs" is the identical all-upside shape. The three
numbered commitments carry the adjudication; the headline is a wrapper. Commitment (1) is the
one behaving properly, because it names the price out loud -- no off switch, ~17% accepted.

*If an audience IS named, it should be a bound, not a market* -- "not for ___" is the half
that rejects. What the dogfooding record actually shows (selfhost, game engine, web
framework, LSP, IDE, ML runtime, n-gram analysis) is ONE PERSON BUILDING A WHOLE SYSTEM END
TO END, which is Oberon's audience -- a coincidence worth noticing given Wirth is where the
test came from. It rejects usefully: no heavyweight package ecosystem (a solo builder
vendors), no fine-grained visibility modifiers (those police boundaries between TEAMS), no GC
(whole-system reasoning needs predictable cost).

**AND THE TWO PULL APART, which is the point of writing it down.** Python's audience is
largely people who will never see the whole system -- that is what its high-level framing is
FOR. Adopting Python's positioning would quietly import Python's audience, after which a
hundred small feature decisions start going the other way. Precisely the incompatibility
Wirth says passes unrecognized rather than being argued and lost.

**What it deliberately does NOT claim:** that Zebra is fast, small, simple, or general.
Those are consequences or trade-offs, not the concept, and a concept that claims everything
adjudicates nothing.

### PRIMARY SOURCES, NIGHT OF 2026-08-26 — and they settle BUG-313 part 2

Two more papers read in full rather than quoted from memory. Both turned out to be about
work done the same day, which is either a good sign about the choice of papers or a bad one
about the novelty of our mistakes.

#### Hoare, *The Emperor's Old Clothes* (Turing lecture, CACM 24(2), 1981)

**On bounds checking, and it is about us:**

> "…every occurrence of every subscript of every subscripted variable was on every occasion
> checked at run time against both the upper and the lower declared bounds of the array.
> Many years later we asked our customers whether they wished us to provide an option to
> switch off these checks in the interests of efficiency on production runs. **Unanimously,
> they urged us not to** — they already knew how frequently subscript errors occur on
> production runs where failure to detect them could be disastrous. **I note with fear and
> horror that even in 1980, language designers and users have not learned this lesson. In
> any respectable branch of engineering, failure to observe such elementary precautions
> would have long been against the law.**"

Zebra shipped precisely the option his customers refused: checks present in debug, absent in
`--release`. BUG-313, described in 1981.

**THIS SETTLES PART 2 OF BUG-313's DESIGN: do not build the unchecked accessor.**

There is an apparent conflict between the two founders, and resolving it is the useful part.
Knuth (1974, citing Wirth and Hoare) says range checking "should be used far more often than
it currently is, **but not everywhere**". Hoare's users, offered exactly that escape hatch,
refused it. The two are reconcilable and the reconciliation is the design:

| | whose job |
|---|---|
| **Elide where the bound is PROVABLE** | the compiler's -- Knuth's "not everywhere", and the elision item |
| **Offer a user-facing off switch** | nobody's -- Hoare's users refused it, and the temptation is the point |

A check the compiler proves unnecessary costs nothing and gives up nothing. A switch the
programmer flips gives up safety at exactly the moment they are most confident and least
correct. **We now know the price of that safety: ~17%, and it is the entire gap to
hand-written Zig.** That is the number to defend, not to escape.

**On approaching a release, which is where Zebra is:**

> "When any new language design project is nearing completion, there is always a mad rush to
> get new features added before standardization. The rush is mad indeed, because it leads
> into a trap from which there is no escape. **A feature which is omitted can always be added
> later, when its design and its implications are well understood. A feature which is
> included before it is fully understood can never be removed later.**"

Read against this file's own 0.9 docket, that is a warning with our name on it. It also
gives the `reserved-words` gate a pedigree: seven keywords have been REMOVED, and Hoare's
point is that removal is the operation you will not get to perform later.

The lecture closes on a parable whose master tailor advises **removing layers** rather than
adding embroidery, and is dismissed as out of touch for it. That is the size-budget item, in
1981, as a bedtime story.

#### Naur, *Programming as Theory Building* (1985) — the one this project is a live test of

> "A person who has or possesses a theory in this sense **knows how to do certain things and
> in addition can support the actual doing with explanations, justifications, and answers to
> queries**."
>
> "**The death of a program happens when the programmer team possessing its theory is
> dissolved.**"
>
> "…program revival, that is reestablishing the theory of a program merely from the
> documentation, is **strictly impossible**."
>
> "Documentation cannot — and so need not — say everything. Its purpose is to help the next
> programmer **build an accurate theory** about the system."

**This project dissolves its team every session.** Sean is continuous; the other half of the
pair is not. By Naur's definition Zebra dies and is revived constantly, and the entire
CLAUDE.md apparatus -- the receipts, the "found 2026-08-01 with…" notes, the bug ledgers
that record what a defect COST rather than only what it was -- is a standing bet against his
"strictly impossible".

**Today produced evidence on both sides of that bet, and both halves matter.**

*For the bet:* the receipts transmit. A session arriving cold used `corpus_ls.sh`'s recorded
receipt to understand why an untracked file must not count, used BUG-302's write-up to
recognise the same defect one layer up in `EMITFAIL`, and used the round-trip's documented
blind spot to know what a green board did not prove. None of that is derivable from the code.

*Against it:* **hazards that are written down were repeated anyway.** The heredoc-eats-
backslashes rule is in memory and was violated five times in one day. The
`$?`-after-a-pipeline trap is described in CLAUDE.md and cost a misread daily three times.
The documentation transmitted the FACT and not the THEORY -- which is Naur's point precisely,
and the reason the eventual fix was not a better note but a TOOL (`zzsafe`, H10) that makes
the mistake structurally harder.

**The refinement worth keeping.** Naur's target is documentation that records *what the
system does*; this repo mostly records *what went wrong and why the code is shaped around
it*, which is much closer to his "explanations, justifications, and answers to queries" --
i.e. theory-shaped content rather than description. That is probably why revival works here
better than he predicts. But the failure mode above shows the ceiling: **a recorded rule
transmits knowledge, not judgement.** Where judgement is what fails, the answer is a
construct that removes the choice, not a better sentence -- which is the same conclusion
Dijkstra, Wirth and Hoare reach about language design, arriving here from documentation.

**A criterion falls out of it, for what belongs in a comment:** not "what does this do" but
"what would let the next person ANSWER A QUERY about it" -- why it is this way, what breaks
if changed, what was tried. That is the test the good comments in this repo already pass and
the weak ones do not.

#### Wirth, *A Plea for Lean Software* (IEEE Computer, 1995)

**On why software grows**, he cites two laws and then names the mechanism:

> "Software expands to fill the available memory." (Parkinson)
> "Software is getting slower more rapidly than hardware becomes faster." (Reiser)

> "A primary cause of complexity is that software vendors **uncritically adopt almost any
> feature that users want**. Any incompatibility with the original system concept is either
> ignored or passes unrecognized…"

> "Increasingly, people seem to **misinterpret complexity as sophistication**, which is
> baffling — the incomprehensible should cause suspicion."

> "To reduce software complexity by concentrating only on the essentials is a proposal
> **swiftly dismissed as ridiculous** in view of customers' love for bells and whistles. When
> 'everything goes' is the modus operandi, **methodologies and disciplines are the first
> casualties**."

**THE PHRASE THAT IS ACTIONABLE IS "the original system concept".** Wirth's test for a
feature is not "is it useful" but "is it compatible with the concept the system was built
on" -- and his claim is that the incompatibility usually "passes unrecognized" rather than
being argued and lost. **Zebra has no written system concept.** Without one, that test cannot
be applied, and every feature request is evaluated on its own merits, which is exactly the
ratchet he describes. Writing one -- a paragraph, not a manifesto -- would make the 0.9
docket answerable rather than a matter of taste. It also pairs with Hoare's warning about
the mad rush before standardization: the concept is what a rushed feature is measured
against.

**On the size budget, a precedent with a number.** Oberon -- a complete operating system
*and* compiler, with storage management, a file system, a window display manager, a network
with servers, and a document editor -- was "designed and implemented by two people within
three years". That is the existence proof behind the size-budget item; the budget is not
asceticism, it is a claim that the whole thing stays comprehensible.

**And a rationale for Zebra's own typing discipline**, in his pull-quote:

> "ABSTRACTION WORKS ONLY WITH LANGUAGES THAT POSTULATE STRICT TYPING OF VARIABLES AND
> FUNCTIONS. IN THIS RESPECT, C FAILS."

Zebra postulates strict typing, nil tracking and contracts, and emits into a language that
also has them. On Wirth's argument that is not incidental -- it is the precondition for the
abstraction boundaries the rest of these items depend on.

#### Parnas, *On the Criteria To Be Used in Decomposing Systems into Modules* (CACM, 1972)

**His criterion is not "split by phase", it is the opposite of that**, and he names our
decomposition as the anti-pattern:

> "In the first decomposition the criterion used was **to make each major step in the
> processing a module**. One might say that to get the first decomposition one **makes a
> flowchart**. This is the most common approach to decomposition or modularization. It is an
> outgrowth of all programmer training… The flowchart was a useful abstraction for systems
> with on the order of 5,000-10,000 instructions, but as we move beyond that it does not
> appear to be sufficient."

The criterion he proposes instead is that "each module hides some design decision from the
rest of the system", and his first specific rule is:

> "A data structure, its internal linkings, accessing procedures and modifying procedures
> are part of a **single module**. They are **not shared by many modules** as is
> conventionally done."

**ZEBRA'S SELFHOST IS THE FIRST DECOMPOSITION.** Lexer -> Parser -> AstBuilder -> Resolver ->
TypeChecker -> CodeGen is a flowchart, and `Ast` is a data structure shared by everything.
Measured: **899 pattern-match sites on Ast variants across five modules** (CodeGen 334,
CgHelpers 280, TypeChecker 192, Checker 68, AstWalk 25).

**And it predicts our defect classes, which is what makes this more than a taxonomy:**

| what we have | Parnas's account of it |
|---|---|
| `lint_expr_walkers` exists at all | a GATE armoring a seam that information hiding would have removed |
| BUG-267, BUG-260 -- walker drift | an Ast variant added; some traversers updated, others not, because no module owns it |
| BUG-293 / BUG-294 -- seeding failures | a registry populated in one pipeline stage and consumed in another |
| BUG-306 -- `inferExpr` cannot see module-scope decls | the same structure, from the other side |

**NOT A PROPOSAL TO RESTRUCTURE THE COMPILER.** The pipeline decomposition has real virtues
here -- it matches how compilation is taught, it makes the round-trip gate expressible, and
899 call sites is not a refactor anyone should start on a whim. Recorded because it explains
a recurring class rather than treating each instance as a surprise, and because it gives a
criterion for boundaries we have NOT yet drawn.

**IT ALSO VALIDATES THE TRANSFORM-INTERFACE-AS-PLUGIN-BOUNDARY, on Parnas's own terms.**
Sean proposed the transform interface as the extension point. Parnas's test is whether a
boundary corresponds to **a design decision likely to change**:

- a `transform` (match / rewrite / metadata / trigger) IS such a decision -- which
  transformations exist, and when they fire, is exactly what varies between versions and
  between third parties;
- a "plugin per compiler phase" would be the flowchart decomposition again, and would freeze
  the seam where our defects already cluster.

So the earlier recommendation -- adopt the size budget, defer the plugin architecture, and
if modularity is needed put the boundary at the transform -- turns out to be Parnas's
criterion rather than a hunch. Good; a hunch that survives contact with the source is worth
more than one that does not.

#### Lampson, *Hints for Computer System Design* (1983)

**The single most on-point sentence found tonight:**

> "The interface must not promise **more than the implementer knows how to deliver**."

That is BUG-313 exactly -- QUICKSTART promised `.at()` was "bounds-checked", the
implementation delivered it only in debug -- and it is stated as a general design rule
forty-three years ago. Worth adopting verbatim as a review question: *does this interface
promise anything the implementation does not deliver in every configuration we ship?*

**On cost visibility, which is the Knuth mandate from the other direction.** On an
over-general design he writes that "it is hard for the programmer to tell what will be fast
and what will be slow", and of an O(n^2) field lookup reached through a convenient
abstraction: "**only a lively awareness of its cost will avoid this disaster**". Knuth argues
the compiler should supply that awareness; Lampson observes what happens when nothing does.
Both land on the complexity-as-reflection-data item.

**Other hints that map onto things here, listed so they are not rediscovered:**

| Lampson | already in Zebra as |
|---|---|
| "Plan to throw one away" | the bootstrap, retired 2026-09-16 |
| "Exterminate features" (Thacker) | `lint_reserved_words` |
| "End-to-end" -- application-level checking is what is logically necessary, other checks are for performance | the gate ladder: only `output_sweep`/`smoke_run` RUN anything, and the compile-only gates are the "for performance" ones |
| "Keep basic interfaces stable" / "keep a place to stand" | the 0.9 versioning question |
| "Separate normal and worst case" -- normal must be fast, worst must make progress | not addressed; a lens for the allocator work |

**The end-to-end row is worth pausing on.** Lampson's claim is that intermediate checks are
*not logically necessary* -- they are performance optimisations, because only the end-to-end
check proves anything. Our ladder has independently arrived at the same shape and says so in
its own words: the compile-only gates cannot see a program that compiles and prints the wrong
answer (BUG-226), and `output_sweep` exists because of it. What Lampson adds is the
justification for keeping the cheap intermediate gates anyway: they are not there to prove
correctness, they are there to find failures sooner.

### THE DIJKSTRA READING, which changes what BUG-313's fix should be

The dogfood code contains **171 `while` loops**, 35 of them the exact `while i < n` /
`i += 1` shape, every one hand-managing an index.

Zebra already has the safe form. Verified: `for i in 0..xs.len` compiles and runs with a
**runtime** bound, and nests with runtime bounds at both levels. The language is not
missing the construct; the construct is not being reached for. `QUICKSTART` demonstrates
`for i in 0..10` only with a **literal**, which is plausibly why.

That is Dijkstra's argument in one observation: **a structured construct eliminates an
error class that discipline can only mitigate.** Every hand-rolled index loop is an
opportunity for the off-by-one that BUG-313 turns from a trap into a silent fabricated
value. Bounds-checking `.at()` makes that failure *loud*; a range-`for` makes it
*impossible*.

So BUG-313's fix is two-sided, and the second half is cheaper than the first:
- **check the index** (the filed fix), and
- **make the safe loop the obvious one** -- document `for i in 0..list.len` with a runtime
  bound, next to the indexing section, where someone writing a numeric loop is already
  looking. UNGIT: the safer path should be the one you find first.

### THE RANGE-CHECK RESOLUTION — the paper already answered BUG-313 (p.271)

Reading past the famous quote found the answer to the question BUG-313 poses. Discussing
bounds checks, Knuth writes:

> "Wirth [94] and Hoare [39] have pointed out that **a well-designed `for` statement can
> permit even a rather simple-minded compiler to avoid most range checks within loops.**
>
> I believe that range checking **should be used far more often than it currently is, but
> not everywhere.**"

**This dissolves the tradeoff BUG-313 was filed with.** That entry frames it as a choice --
check every `.at()` and pay a compare-and-branch, or stay fast and unsafe. It is not a
choice; it is three parts:

| | Knuth's phrasing |
|---|---|
| `.at()` checked by default | "far more often than it currently is" |
| an explicitly-unchecked accessor for hot paths | "but not everywhere" |
| **`for i in 0..xs.len` ELIDES the check** | a well-designed `for` lets the compiler prove the bound |

The third line is the prize and it is the one nobody proposed: **the safe form becomes the
fast form.** A hand-managed index cannot be proved in range, so it must be checked; a range
`for` can be. The dogfood code's 171 hand-rolled `while` loops would therefore pay for
checks that the range-`for` would not need. So "make the safe loop obvious" is not merely
ergonomics -- it is what makes checking affordable enough to leave on.

Attribution correction: this was recorded here first as "the Dijkstra reading". It is
**Wirth and Hoare's**, cited by Knuth.

### RUN SPEED AS A DESIGN CONSTRAINT, with a number (Sean, 2026-08-26)

Sean's target: **within 30-50% of hand-written Zig**, alongside compile speed (cf. V and
FRED using TCC, where fast iteration is a headline feature). Current dogfood evidence: ~8x
faster than Python, not close to Zig.

The value of the number is that it is unambiguous -- "minimal performance cost" is not
falsifiable and 30-50% is. It also needs a benchmark corpus that is NOT the compiler, which
is what the `algorithms` namespace would provide.

First suspects from today's measurement, in order: (1) allocation retention, above -- and
it is testable immediately by re-running a dogfood benchmark inside an `allocate` scope;
(2) `.at()` bounds behaviour once BUG-313 is fixed, where the range-`for` elision matters;
(3) whether hand-rolled index loops defeat optimisations a range-`for` would enable.

### The honest filter

Most "founder wisdom" lists are decorative. The test for anything above earning a place:
**does it become a gate, a lint, a diagnostic, or a removed feature?** Items 1, 4, 5 and 9
can. Items 3 and 7 are stances, not mechanisms — worth stating once and not re-litigating.
---

**Where things live** — this file is one of five; see [NEXT_STEPS.md](../NEXT_STEPS.md)
for the map.

| file | answers |
|---|---|
| [docs/PRINCIPLES.md](PRINCIPLES.md) | how do we decide? |
| [docs/archive/FINDINGS.md](FINDINGS.md) | what do we already know? |
| [docs/NEXT_STEPS_to_0.9.md](../NEXT_STEPS_to_0.9.md) | what is next, before public release? |
| [docs/NEXT_STEPS_to_1.0.md](../NEXT_STEPS_to_1.0.md) | what is next, before the freeze? |
| [docs/NEXT_STEPS_post_1.0.md](../NEXT_STEPS_post_1.0.md) | deliberately deferred past 1.0 |
