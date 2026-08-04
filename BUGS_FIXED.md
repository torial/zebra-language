<!-- doc-status: historical -->
# Zebra Compiler — Fixed / Closed Bugs

Bugs that have been resolved, implemented, or closed as "not reproduced".
Open bugs live in `BUGS.md`.

---

### BUG-239: empty list literal `[]` in expression position — ✅ FIXED 2026-08-01

**Symptom.** Any `[]` used as a call argument, struct-field initialiser, or return
value failed to compile with a Zig-level error that named the *callee's* definition
line rather than the literal:

```
def take(xs: List(str)): int
    return xs.len          # <- error reported HERE
def main()
    print(take([]).toString())
```
```
error: local variable is never mutated
```

**Cause.** The selfhost lowers a list literal to a labeled block —
`(blk_ll_N: { var _ll_N: std.ArrayList(T) = .empty; _ll_N.append(...); break :blk_ll_N _ll_N; })`
— with the keyword hardcoded to `var`. With zero elements no `.append` is emitted,
so the binding is never mutated and Zig hard-errors. The misleading line number is
why this survived: it reads as a fault in the function being called.

**Fix.** `selfhost/CodeGen.zbr`, `Expr.list_lit` — choose the keyword from
`ll.elems.len`, emitting `const` for an empty literal. This matches the house idiom
already documented in the bootstrap (`src/CodeGen.zig:1645`: "a sort-only list must
stay `const`, else Zig rejects it as never mutated"). The same guard was applied to
`Expr.dict_lit`, which a bare `{}` actually reaches.

**Scope notes for whoever touches this next:**

- `var x: List(T) = []` was **never** affected — annotated locals are handled in
  `genLocalVar`, which never reaches the literal lowering. Only expression position
  was broken, which is why the corpus did not catch it.
- A bare `{}` parses as a **dict** literal, not a set. The set-literal branch has no
  zero-element guard because no source syntax can reach it; a comment there records
  what to do if an empty-set syntax is ever added.
- The **bootstrap does not have this bug** — `src/CodeGen.zig:14341` emits a bare
  `std.ArrayList([]const u8).empty` for the empty case with no block at all. Checked
  because BUG-238 turned on exactly this bootstrap/selfhost distinction.

**Regression:** `test/bug239_empty_list_literal_test.zbr`, registered `smoke_run` in
`tools/selfhost_smoke.sh`. Found by dogfooding — writing a village demo for
`examples/tears_of_the_tuon.zbr` and passing `log: []`.

---

### BUG-238: import-parser rejects `except` inside enum-dotted `branch` arms — NOT A COMPILER BUG; reporter error, 2026-08-01

**RESOLVED 2026-08-01. TWO reporter errors, not one compiler bug.**

**Cause 2, found after the rebuild and the more important of the pair:** every
failing invocation in the original report passed **`--gui-backend=stub`**, and that
flag routes the build through the **bootstrap** compiler, whose older parser rejects
return-position `except` — the known BUG-204 family, already documented in
`examples/tears_of_the_tuon.md`. Drop the flag and the same file compiles clean on the
selfhost. Opus's observation that the error text appeared *only in `src/`* was pointing
straight at this and I did not follow it. Policy going forward (Sean, 2026-08-01): use
the selfhost, which is far more current than the bootstrap.

**Cause 1, real but secondary: Opus's explanation 2, the stale tree.** Running `tools/doctor.sh` in my tree — which I did not do before
filing — reports exactly what he suspected:

```
WRONG stale generated Zig — you would be testing the OLD compiler:
        CodeGen.zbr is newer than its .zig
WRONG bootstrap predates a preamble it embeds — a regen now emits the OLD runtime
```

So every measurement in the dossier below was taken against a compiler built from a
half-updated tree, including the delta-debugged "minimal repro", which reduced 1,400
lines to 6 and produced a confident and worthless result. The reduction was sound; the
oracle it was reducing against was not.

The dossier is kept rather than deleted because the failure is instructive: the
original report *states* that the compiler had been rebuilt from a tree with unresolved
merge conflicts, and proceeds anyway. The lesson is not "check the tree" in the
abstract — it is that `tools/doctor.sh` existed, took four seconds, and would have
stopped the whole hunt before it started. Run it before believing any compiler result.

The two secondary observations in the dossier still stand on their own and are worth
keeping: the emit-cache keyed by module basename can serve stale artifacts, and
`spawn failed` outside the repo root deserves a real error message.

**Original report follows, uncorrected.**


**DOES NOT REPRODUCE as of 2026-07-31 ~20:30, and the fixture is the response.**

The ticket's own minimal repro prints **8**. Built fresh from the text above and
deliberately NOT from the game files — the parallel session has
`examples/tears_of_the_tuon.zbr` and `tears_combat_test.zbr` modified in the working
tree, so anything derived from them would confound their edits with a compiler change.
The minimal case is independent of that.

`zebra run examples/tears_combat_test.zbr` now yields **zero** `except` errors. It fails
later, at `tears_combat_test.zbr:205`, on a GAME assertion:
`assert cm.phase == 15 and cm.story == 0, "the token seeks its reader"` — in-flight work
by whoever is editing those files, not a compiler fault, and not mine to touch.

**WHAT FIXED IT IS NOT ESTABLISHED, and I am not claiming it.** Two explanations fit and
neither is proven:

1. One of the seven compiler changes that landed the same day (BUG-230, 234, 236, 223,
   232, 142, 231). Nothing in that list obviously touches cross-module parsing, which
   makes this the weaker candidate.
2. **A transient tree state, which I would own.** The report cites a `zebra.exe` of
   07-31 14:47, and that window contains two of my regenerations that FAILED and
   restored `selfhost/*.zig` from a pre-run snapshot. A compiler built from a
   partially-updated tree can produce exactly this shape of confusing cross-module
   parse error, and `doctor.sh` exists precisely because that state makes results lie.
   Note the symptom fits it: the error text `syntax error near` appears **only in
   `src/`** — the bootstrap — so the failing parse was the bootstrap's, which is
   consistent with a mismatched selfhost/bootstrap pair mid-rebuild.

Explanation 2 is the one I would bet on, and it is a caution worth keeping: while a
rebuild cycle is in flight, this tree can hand another session a compiler that is not
what either of us thinks it is.

**GUARDED rather than closed.** `test/bug238_import_except_test.zbr` +
`test/bug238_except_lib.zbr`, registered `smoke_run` (not `smoke` — the failure was a
parse error in the DEP, which only a real import exercises). Smoke 262 → 263. Left OPEN
rather than marked FIXED, because a regression that stops reproducing without a known
cause has not been fixed; it has stopped being visible, and those are different.

**Symptom.** A module that parses and runs clean STANDALONE fails when loaded
via `use`: every `except` from the first enum-dotted arm onward reports
`syntax error near 'except'`. This re-broke the committed-green tears game
(last green at 1fa2b21): `zebra run examples/tears_combat_test.zbr` now emits
19 such errors from `tears_of_the_tuon.zbr`, first at the update() dispatcher.

**Minimal repro** (two files in examples/):

```
# lib_b238.zbr
struct P
    var a: int

enum Msg
    go
    stay

def update(m: P, msg: Msg): P
    branch msg
        on Msg.go    return m except a = 8
        on Msg.stay  return m except a = 9
    return m
```
```
# main_b238.zbr
use lib_b238 exposing P, Msg, update

def main()
    print(update(P(a: 1), Msg.go).a.toString())
```
`zebra run main_b238.zbr` → `lib_b238.zbr:11:31: syntax error near 'except'`.

**Controls (all verified 2026-07-31, zebra.exe of 07-31 14:47):**
- Same lib code with `def main()` appended, run STANDALONE → prints 8. PASS.
- Same shape with INTEGER arms (`branch k / on 0 ...`) under import → parses
  fine (fails later only if emit-cache is cold-deleted mid-run; unrelated).
- Multi-field vs single-field except: irrelevant — both fail on enum arms.
- Return-position except, forward-declared struct types, list-field except,
  top-level multi-field except: all PASS under import. The trigger is
  exactly: `on Enum.value    return expr except ...` in an imported module.

**Suspicion.** The import path retains (or falls back to) an arm-grammar
older than the main parser's — the dotted-value `on` arm seems to consume
the trailing return-expression with a reduced expression grammar that lacks
postfix `except` (BUG-204's old shape, resurrected inside `use`-loading).
Likely a second parse entry-point for imported modules that didn't get the
B12-era except productions, or a divergent copy of the arm parser in the
selfhost import loader touched by the recent TypeChecker/CodeGen merge.

**Two secondary observations from the same hunt (not filed separately):**
1. **Emit-cache staleness masks errors**: artifacts in `%TMP%` keyed by
   module basename (`<name>.zig`, `<name>.zig.fast.exe`) can serve stale
   results after the source changes — during diagnosis the same compile
   alternated pass/fail depending on leftover artifacts (cousin of
   BUG-235's stale-corpus lesson). A content-hash in the cache key would
   end the class.
2. **`spawn failed` when run outside the repo root**: zebra.exe appears to
   locate its zig/helper relative to CWD; from any other directory every
   compile dies with the bare message `spawn failed`. Worth an explicit
   error ("cannot find zig at <path>") and an exe-relative lookup.

**Assigned: Opus — with Fable's compliments; the tears game is the live
victim and its working tree (scribe-mission changes, uncommitted) is
waiting on this to go green.**

---

### BUG-236: signed `/` and `%` use MISMATCHED conventions; the division identity fails ✅ FIXED 2026-07-31

**FIXED 2026-07-31** (Sean took the recommendation). `%` now emits `@rem` instead of
`@mod`, in both compilers. One builtin: `/` is untouched, so no existing division
changes behaviour, and the pair now matches the language we compile to.

Verified: `(0-7) % 2` is `-1`, `7 % (0-2)` is `1`, and **`(a/b)*b + (a%b) == a` is
TRUE**. The gcd/lcm helpers keep `@mod` deliberately — they run Euclid's algorithm over
already-positive values, where the two agree. Guarded by
`test/boundary/bv_signed_division.zbr`, rewritten from pending to intent.

**Severity:** high (silent wrong arithmetic on negative operands, no diagnostic).
**Found:** 2026-07-31 by the A3 integer dimension. Confirmed at the emit level.

```zebra
(0 - 7) / 2      #  -3   (truncates toward zero)
(0 - 7) % 2      #   1   (floors -- sign of the DIVISOR)
7 % (0 - 2)      #  -1

var a = 0 - 7
var b = 2
(a / b) * b + (a % b) == a     # -> FALSE.  (-3)*2 + 1 = -5, not -7
```

**The division identity `(a/b)*b + (a%b) == a` does not hold.** That identity is not a
nicety; it is the definition of integer division and remainder, and essentially every
algorithm that mixes `/` and `%` on possibly-negative values silently assumes it.

**Root cause, straight from the emitted Zig** — codegen picks one convention for each
operator and they are not the same one:

```
6  @divTrunc     # `/`  -> truncate toward zero   (sign of the DIVIDEND)
5  @mod          # `%`  -> floor                  (sign of the DIVISOR)
```

Only two pairings are coherent, and Zebra is using neither:

| `/` | `%` | `-7/2` | `-7%2` | identity |
|---|---|---|---|---|
| `@divTrunc` | `@rem` | -3 | -1 | holds (C, Zig, Java, Go) |
| `@divFloor` | `@mod` | -4 | 1 | holds (Python) |
| **`@divTrunc`** | **`@mod`** | **-3** | **1** | **BROKEN — current** |

**Recommended fix: change `%` to emit `@rem`.** It is a one-builtin change, it keeps
`/` as it is (so no existing division changes behaviour), and it matches the language
Zebra compiles to. Switching `/` to `@divFloor` instead would also be coherent but
changes far more code and diverges from Zig for no stated reason.

Positive operands are unaffected — `7/2` and `7%2` agree under every convention — which
is why the whole corpus is silent on it. `output_sweep` could not have caught this
either: no corpus program takes a modulo of a negative, so there is nothing recorded to
regress from. Same shape as BUG-234, found by the same method for the same reason.

**QUICKSTART says nothing about either convention**, which is its own defect: the docs
mention `%` only as "use `%` for modulo". Whichever way this is resolved, the rounding
behaviour of both operators on negatives should be written down.

Pinned by `test/boundary/bv_signed_division.zbr`, a `@boundary-pending` probe recording
today's broken output — including `identity=false`, which is the row that should never
have been false and is the one to watch.

---

### BUG-235: the Luau-translated corpus went 1482 -> 849 compiling ✅ RESOLVED 2026-07-31 — STALE CORPUS

**RESOLVED — the corpus on disk was five weeks stale. Nothing was broken.**

Regenerated with the CURRENT translator (`--all --write-zbr`):

```
before (2026-06-16 corpus, measured today):   849 / 1780   47.7%
after  (regenerated today):                  1446 / 1581   91%
recorded in June for reference:              1482 / 1780   83%
```

The compile RATE is now well above June's, though the absolute count is slightly lower:
dedup removed 199 duplicate scripts, so the corpus is 1581 unique files, not 1780.

*(A 250-script sample of that run reported 100% and I briefly believed it. The sample
was the head of a sorted list and the easy scripts sort early — sampling a sorted corpus
by prefix is not sampling. The full-corpus number is the one above.)*

135 files still fail, dominated by 477 `resolver:undefined_ident` — Roblox APIs the shim
does not cover yet. Ongoing translator work, not a regression.

**Against 47.7% for the files that were sitting in `ported_scripts/`.** The regression was
never in the compiler and never in the translator — it was that `ported_scripts/` was
generated **2026-06-16** and the translator learned to emit `exposing` on **2026-06-20**,
with the robloxglobals shim injection following on **2026-06-30**. The corpus predates
its own fix by five weeks.

So the chain is: Zebra correctly tightened `use` to match its documented behaviour;
the June corpus depended on the old leniency; the translator was fixed four days later;
nobody regenerated. Every link is individually reasonable, which is exactly how a
633-file regression sits unnoticed for five weeks.

Corpus regenerated 2026-07-31 (`--all --write-zbr`). Sean's standing note: *"The corpus
is not intended to be locked in yet (as we are iterating toward a solution)."*

**THE LESSON IS THE ONE THAT SURVIVES, and it is not about `use`.** A generated artefact
was checked in, its generator improved four days later, and nothing connected the two.
There was no gate on the corpus and no staleness check on the generator — so a directory
of 1,780 files silently stopped representing what the toolchain produces.

That is the same shape as A5 (`examples/` ungated, shipping a broken file) and as the
`str_ownership.md` gate (a DERIVED doc that goes stale when codegen changes — and which
caught exactly that, twice, this week). The pattern worth generalising: **every generated
artefact under version control needs either a regeneration gate or a staleness check.**
`ported_scripts/` had neither; `str_ownership.md` has one and it works.

**Severity:** high if it is a compiler regression, none if it is deliberate — which is
exactly why it needs answering rather than filing away.
**Found:** 2026-07-31, incidentally, while trying to measure BUG-142's blast radius.
**Needs Sean**, because the resolution depends on project intent, not on code reading.

**The measurement, made with GameEngine's OWN harness so it is comparable to the
number on record** (`python tools/measure_corpus_compile.py 2000`):

| when | compiling | source |
|---|---|---|
| 2026-06-23 | **1482** / 1780 | recorded in BUG-142 above |
| **2026-07-31** | **849** / 1780 (47.7%) | measured today |

**~633 files that used to compile no longer do.**

**What has been ruled out, so this is not a guess about where to look:**

* **Corpus drift** — no. `git diff` of `ported_scripts/` between the June commit and
  HEAD is **empty**; the last regeneration was 2026-06-16, a week BEFORE the 1482
  reading. Same bytes in, different result out.
* **Corpus size** — no. 1780 files in June, 1780 now.
* **A different harness** — no. Same script, same `--emit-zig`, same cwd. Three
  independent instruments (that harness, a `-c` sweep, an `--emit-zig` sweep) all
  agree on **849** today.
* **Module resolution** — no, and this is the one worth recording because it was the
  obvious suspect. The dominant failure is `undefined name: 'RunService'` and friends,
  which looks exactly like a missing search path. It is not: copying **all 69**
  `zbra/*.zbr` modules next to the script reproduces the identical error. The scripts
  reference Roblox service globals **without importing the `robloxglobals` shim** —
  the translator commit that injects it (`401e0b3`) postdates the corpus regeneration.

**IDENTIFIED 2026-07-31 (Sean's question about the `RunSvc` shim led straight to it).**
The cause is **`use` no longer bringing a module's names into scope without `exposing`**.

```zebra
use run_service                      # what the translator emits
RunService.Heartbeat.Connect(cb)     # -> error: undefined name: 'RunService'

use run_service exposing RunService  # add ONE clause
RunService.Heartbeat.Connect(cb)     # -> compiles clean
```

Verified on a real failing corpus file: `0145_Script_Dancing_Shelly.zbr` goes from
`undefined name: 'RunService'` to **rc=0** with nothing changed but that clause.
Qualifying instead (`run_service.RunService()`) works too.

**The numbers line up.** **983** corpus files use a bare `use` with no `exposing`,
against **931** failures today. In June, 1780-1482 = 298 failed — so roughly 685 of
those bare-`use` files compiled *then* and do not *now*. Bare `use` used to expose
names and no longer does.

**RESOLVED IN ZEBRA'S FAVOUR — the compiler is behaving as DOCUMENTED.** QUICKSTART
§ module system spells out both forms, and has all along:

> `use math_utils exposing square, Vec2` → `square(5)` directly
> **"Without exposing — qualified access:"** `use math_utils` → `math_utils.square(5)`

So a bare `use` never *promised* to bind names, the June behaviour was leniency rather
than contract, and tightening it was correct. **The translator is the thing to fix**, and
this is not a Zebra bug so much as a Zebra bug-fix that nothing warned the corpus about.

Remaining decision is only about sequencing and blast radius:

* **(a) The translator is wrong.** `zbra/signal.zbr` — hand-written, not generated —
  already uses `use signal exposing SignalF, Signal`, so `exposing` is evidently the
  intended idiom and the translator was relying on leniency. Fix: emit `exposing`
  (or qualify). One place in `luau2zebra_ast.py`; likely recovers most of the 633.
* **(b) The change still shipped silently.** Even though the new behaviour is the
  documented one, a tightening that invalidates ~685 files in a sibling repo deserved a
  CHANGELOG line and a heads-up. That is the process gap worth keeping, separate from
  the code: **we hardened a semantic and had no way to see who was relying on the old
  one**, because that corpus is ungated. A5's shape (baselined, regress-only) applied to
  `ported_scripts` would have said so the same week.

Either way the corpus is the victim, and **nothing gates it**, which is why five weeks
passed. QUICKSTART should state the rule explicitly whichever way it is resolved — it
currently documents `use module_name` only in terms of module *resolution*, never
scoping.

**On the `RunSvc` shim in `robloxglobals.zbr` specifically** (Sean asked whether it
would help): the *shape* is right — a signal-with-connect — but it is not the useful
one, and renaming it would not have fixed this. `zbra/run_service.zbr` already defines
`class RunService` with PascalCase `Heartbeat`/`Stepped`/`RenderStepped`, matching the
corpus exactly, and the scripts already import it. `RunSvc` duplicates that with
lowercase fields and `connect`, so it matches the corpus *less* well than what is
already there. The missing piece was never the class shape; it was the import clause.

~~**Leading hypothesis, NOT established:** the Resolver became stricter about undefined~~
names sometime after 2026-06-23, turning a previously-tolerated condition into a hard
error. If so it is probably *correct* hardening — but with a 633-file blast radius that
nobody measured, because nothing gates this corpus.

**Confirming it means bisecting the Zebra compiler across ~5 weeks against this corpus.**
That is a real job and it was not started tonight; the point of this entry is that the
number on record is stale and must not be used as a baseline until it is explained.

**Immediate consequence — BUG-142 is blocked on this.** The 1482 figure is the baseline
the too-many/too-few promotion was to be judged against, and it no longer describes
reality. See BUG-142 for what was and was not measurable in the meantime.

**The structural point, which is the third instance of it in two days:** this is another
corpus that **no gate watches**. `examples/` was the first (A5, and it was already
shipping a broken file); this is the same shape at 100x the size and in a different repo.
The A5 pattern applies directly — a baselined, regress-only gate — and would have caught
this the week it happened instead of five weeks later.

---

### BUG-234: `str.reverse()` byte-reverses, turning valid UTF-8 into invalid ✅ FIXED 2026-07-31

**FIXED 2026-07-31** (Sean took the recommendation — option (a), codepoint-aware).
New preamble helper `_str_reverse` walks the string codepoint by codepoint and copies
each one's bytes intact into descending slots, so byte order WITHIN a codepoint is
preserved while codepoint order reverses. Invalid UTF-8 input falls back to a byte
reverse instead of panicking: `reverse()` has no way to report an error, and
garbage-in-garbage-out beats aborting a user's program over a string we were only asked
to turn around. Both compilers call the same helper — one helper, not the old inline
blob duplicated at two emit sites each.

Verified: `"世界".reverse()` is now `"界世"`, valid, 2 codepoints; `"aé中b"` reverses to
`"b中éa"`; ASCII unchanged. Guarded by `test/boundary/bv_reverse_nonascii.zbr`, which
was rewritten from its pending form to assert the intent it was authored with.

**Severity:** high (a stdlib call silently converts valid text into non-text).
**Found:** 2026-07-31 by the A3 non-ASCII dimension, from a row written specifically
because a byte reverse and a codepoint reverse differ exactly here.

```zebra
var c = "世界"                 # valid UTF-8, 2 codepoints, 6 bytes
var rev = c.reverse()          # expected "界世"
rev.isValidUtf8()              # -> false
rev.codePointCount()           # -> 0      (from input that had 2)
rev.len                        # -> 6      (bytes preserved, order shredded)
```

Not a CJK-only or 3-byte-only edge — `"é".reverse()` is invalid too, so it is
**every multi-byte codepoint**. ASCII is unaffected (`"abc".reverse()` is `"cba"`,
valid), which is exactly why nothing noticed: the corpus reverses ASCII.

**Why no gate saw it.** `output_sweep` compares what programs PRINT against a golden
baseline, and no corpus program reverses non-ASCII — so there was nothing to record
and nothing to regress from. This is the golden-baseline limitation in its purest
form: it can only ever tell you behaviour CHANGED, never that it was wrong on day
one. Only an expectation written from the reference could find it, which is the
argument A3 exists to make.

**TWO LEGITIMATE RESOLUTIONS, and they are different decisions — Sean's call:**

* **(a) Make `reverse()` codepoint-aware**, so it cannot produce invalid UTF-8.
* **(b) Declare it a BYTE operation and say so**, as was done for the ASCII-only
  `is…` predicates (also found this week, also a doc-vs-implementation gap).

What is **not** defensible is the current state: documented as "Reverse the string",
implemented as a byte operation, and silently manufacturing invalid UTF-8. Note that
(b) still leaves a stdlib call that turns valid text into invalid text with no
warning, which sits badly in a language whose headline feature is contracts. My
recommendation is (a), with (b) acceptable if reverse() is meant to be a
byte-layer primitive — in which case it should arguably be named for that.

**IS THE CODEPOINT LAYER LOAD-BEARING? Measured 2026-07-31, because Sean asked the
right question — whether anything needs codepoints, or whether the code merely takes
what the API hands it. It is the second, and that decides how risky a fix is.**

| layer | uses across `*.zbr` (boundary probes excluded) |
|---|---|
| codepoint: `.chars()` | 27 — and several are *codegen implementing* it, not consuming it |
| codepoint: `.codePointCount()` | 15 |
| byte: `c'x'` literals | **559** |
| byte: `.len` in `selfhost/` alone | **1056** |

And every consumer that was read is doing **ASCII** work:

* `main.zbr:682` — `diagAllDigits`: compares against `'0'`..`'9'`
* `main.zbr:950` — counts `'\n'` to size an LSP edit range
* `AstBuilder.zbr:1125` — matches `c'('` / `c')'` to track paren depth

None of those need decoding; each would behave identically over bytes, and decoding
UTF-8 to count newlines is strictly slower for no gain. **The compiler reaches for
`.chars()` because it is the API for "walk the characters", not because the task is
Unicode.**

**Two consequences, and they point the same way:**

1. **Fixing `reverse()` is nearly risk-free for us.** Nothing in the compiler reverses
   non-ASCII — nothing in the compiler reverses much of anything — so a codepoint-aware
   `reverse()` cannot regress the codebase that would have to live with it. The usual
   argument against touching string semantics (a 559-site rewrite, per §28e's reasoning
   about `char`) **does not apply here**: that argument is about the `char` TYPE, which
   this does not touch.
2. **The beneficiaries are downstream, not us.** The people a correct `reverse()`
   protects are those processing real text — names with accents, the Greek NT stylometry
   work, game dialogue. Zebra's own corpus is the *least* representative sample of that,
   which is exactly why an intent-written probe found this and 335 corpus files did not.

So the recommendation above (make `reverse()` codepoint-aware) is not merely the tidier
option; it is the one whose cost falls almost entirely on a code path nobody uses, and
whose benefit falls on the users 0.9 is meant to be ready for.

Pinned by `test/boundary/bv_reverse_nonascii.zbr`, a `@boundary-pending` probe that
records today's broken output and will FAIL when this is fixed — the signal to
rewrite it to assert `cjkRevValid=true` / `cjkRevCps=2` / `cjkRev=[界世]`.

**It also caught a bug in the boundary harness itself:** a probe whose output is
invalid UTF-8 made `grep` treat the stream as binary, print `Binary file ... matches`
and DROP the row — which read as "that line was never printed" rather than "the
harness ate it". Fixed with `grep -a`. A suite whose whole job is odd inputs must not
be blinded by an odd input.

---

### BUG-232: argument-count checking is SKIPPED inside containers ✅ FIXED 2026-07-31

**PARTIAL FIX 2026-07-31 — and the bug turned out to be much larger than reported.**

It was filed as "arity checking is skipped inside `${...}`". Enumerating `Expr`'s **34
variants** against `checkCallsInExpr`'s arms showed it handled **eight**. Interpolation
was the visible symptom of a walker that was missing nearly every container: list, set,
array and tuple literals, dict literals, `orelse`, `catch`, slices, optional chains,
chained comparisons, `except` updates, `is` checks, and `old()` were ALL unchecked.
Verified before fixing rather than assumed — `add(1)` warned as a statement and was
silent in a list literal, an orelse and a tuple.

**Fixed for all of those** (15 new arms). Confirmed: list literal, tuple literal,
`orelse`, dict literal and slice all now warn where they were silent.

**FULLY FIXED, including `${...}`.** The interpolation arm resisted six spellings until
the cause turned out to be an **import list**: `StringPart` was missing from this
module's `use Ast exposing ...`. See BUG-237 — without it, codegen never registers the
union's boxed variants, so the `^Expr` payload emits as a raw pointer. Adding
`StringPart` to the exposing list produced the deref immediately.

*(Original note, kept because the hunt is the useful part:)* it was not fixed for
`${...}`, the case originally reported and the one `StringPart.expr_` carries a `^Expr`, and a `^T` bound from a union
payload does not auto-deref when passed — six spellings tried, all emitting a pointer
Zig rejects. Filed as **BUG-237**; that blocks the last arm. The pending probe stays.

**Severity:** high (silent wrong behaviour, in the language's most common idiom).
**Found:** 2026-07-30 by the A3 boundary suite (`test/boundary/`), from the
argument-arity dimension. **Both compilers behave identically.**

```zebra
def add(a: int, b: int): int
    return a + b

var r = add(1)              # warning: too few arguments to 'add': expected 2, found 1
print("${add(1)}")          # NO diagnostic at all — prints 1
```

The same asymmetry holds for too MANY arguments: extras are warned about in a
statement and silently discarded inside an interpolation. The missing argument is
padded with a deterministic zero (BUG-142's partial fix), so the program runs and
prints a plausible wrong answer rather than failing.

**Why this one matters more than its siblings:** `print("${f(...)}")` is the most
common shape in Zebra, so this is the context where a user is *most* likely to make
an arity mistake and *least* likely to be told about it.

**Scope check, so this is not over-claimed** — not everything is skipped in an
interpolation. Unknown-method resolution still fires normally, and type mismatches
are still caught, but *degrade* from a Zebra diagnostic with a caret to a raw Zig
error pointing at the wrong line. Arity is the only check found to be absent
outright.

Pinned by `test/boundary/bv_arity_interp_unchecked.zbr` (a `@boundary-pending`
probe: it asserts today's wrong output and will FAIL when this is fixed, which is
the signal to rewrite it as an assertion of the intended warning). Control:
`bv_arity_too_few.zbr` proves the check exists outside interpolation.

---

### BUG-229: TUI apps SEGFAULT at startup — selfhost emit never assigns `_tui_env` ✅ FIXED 2026-07-30

**Fixed** in `selfhost/CodeGen.zbr` (root-`main` injection block): added the
`if _gui_backend == "tui"` → `_tui_env = _zinit.environ_map;` emit, placed in the
**bootstrap's position** — after the arena defer, before dep propagation — so the two
injection blocks stay diffable. This bug existed *because* they drifted; keeping them
alignable is most of the defence against a fifth instance.

Verified end to end: the scaffolded `main.zig` now assigns `_tui_env` (line ~3934) before
`Terminal.init` dereferences it, and the built app gets **past** the crash site — it now
reaches `enableRawMode` and fails cleanly with `GetConsoleFailed` when run with no
console, which is correct behaviour rather than a segfault.

**Regression guard: `tools/gui_scaffold_check.sh`** — the first check in this repo that
looks at a GUI path at all. Deliberately aimed at the *class*, not the symbol:

* **Leg 1 (static, and the one that gates):** every global the scaffold declares as
  `= undefined` must be assigned somewhere in the same file. Naming only `_tui_env` would
  let the next sibling through silently. Falsified on a doctored scaffold.
* **Leg 2 (runtime, best-effort):** classify by the FAULT, not the exit code and not the
  word "panic". A healthy headless tui app panics with `gui init failed` and exits 3 —
  correct. The BUG-229 signature is a *memory* fault (`memcpy` at `0x0`). The first
  version of this leg called the healthy case a crash and would have reported this very
  fix as still broken.

Still uncovered, and printed in the tool's own output so it cannot be forgotten:
rendering, input, layout, resize, colours. Those need a human. What changed is the line —
from "no gate touches a GUI" to "no gate touches a GUI **beyond startup**", and all four
GUI crashes to date lived at startup.

**RE-CONFIRMED BY SEAN 2026-08-01, and this one covers the whole week.** After eight
compiler changes landed (BUG-230/234/236/223/232/142/231 + the walker completion), Sean
ran BOTH selfhost GUI backends and reported they "looked good and behaved like I'd
expect": `--gui-backend=tui`, and `--gui-backend=libui_ng` on `counter.zbr` and
`widget_smoke.zbr`.

`widget_smoke` is the one that mattered: it is the file BUG-230 was silently breaking
(`var items: List(str) = ["Apple", ...]` feeding a combobox), so this is the fix
verified on a RENDERED CONTROL rather than merely compiling. Three of the week's changes
touch what GUI code leans on — annotated list literals, string-interpolation lexing, and
arity severity — and none of them is provable by any gate at the pixel level.

**CONFIRMED BY SEAN 2026-07-30**: `--gui-backend=tui examples/counter.zbr` runs and
renders correctly. That is the only verification that can close a GUI bug — the gate
proves it starts, a human proves it works.

*Diagnosis by Fable (dossier, root cause, and fix sketch); implementation and guard by
Opus. The dossier was accurate in every particular.*

---

<details><summary>Original report (Fable)</summary>
Found 2026-07-30 by Sean running `--gui-backend=tui examples/tears_of_the_tuon.zbr`
(the fourth GUI crash to sit under green gates, per house prophecy: no gate runs a GUI).

**Symptom:** immediate `Segmentation fault at address 0x0` in `memcpy`, reached from
zigzag `terminal.zig:1801 envVarExists` → `environ_map.get(name)` during
`Terminal.init` → `setup()` → `detectUnicodeWidthCapabilities()` →
`looksLikeKittyTerminal(self.environ_map)`. Reproduces headlessly too (the earlier
"run exe app failure" in scripted runs was THIS, misread as no-console).

**Root cause (diagnosed, high confidence):** the scaffolded app's `main.zig` declares
`var _tui_env: *std.process.Environ.Map = undefined;` (template line — scaffold
main.zig:3038) and passes it to `zz.Terminal.init(_io, _tui_env, …)` (:3046) but
**never assigns it**. The bootstrap's CodeGen has the assignment — `src/CodeGen.zig`
~:6431, inside the root-`main` injection block:

```zig
if (g.gui_backend == .tui) {
    … writeAll("_tui_env = _zinit.environ_map;
");
}
```

— but the **selfhost** mirror of that injection block (`selfhost/CodeGen.zbr` ~:4346,
"Root entry point (Zig 0.16): inject _io/_args/_allocator init", which emits
`_io = _zinit.io;` / `_args = _zinit.minimal.args;` / `_allocator = _prog_alloc();`)
is MISSING the tui-conditional line. Since GUI scaffolding moved to selfhost emission
(NEXT_STEPS "GUI builds via selfhost emission"), every tui app gets the undefined
pointer. A selfhost-lags-bootstrap gap — same family as BUG-204/205/206, opposite era.

**Fix sketch (four lines):** in `selfhost/CodeGen.zbr` inside the `owner == "" and
m.name == "main"` injection block (~:4346), after the `_allocator` emit, add the
equivalent of:

```
if <gui_backend is tui>          # selfhost carries it as `_gui_backend: str` (~:1299)
    ei.writeIndent()
    ei.w.emit("_tui_env = _zinit.environ_map;
")
```

Check how `_gui_backend` reaches CodeGen (module var, set ~:1303) — the condition
should match however the tui section-inclusion already branches. Then the full drill:
`bash tools/rebuild.sh` (this is a selfhost/*.zbr edit → regen matters), re-scaffold a
tui example, and RUN the app (`doctor.sh` first per house law). A `smoke_run`-style
check that the scaffolded app at least *starts* headlessly (init past Terminal.init,
then immediate q) would be the regression guard this class has never had.

**Assigned:** Opus — with Fable's compliments: diagnosis complete, fix located,
one four-line edit + the rebuild drill, and the honor of closing the fourth
GUI crash. (Repro: any `--gui-backend=tui` run of any example.)

</details>

---

### BUG-224: `format()` with 2+ arguments emitted invalid Zig ✅ FIXED 2026-07-29
Found while deriving the §28e ownership table. Both `format` dispatch sites emitted a
**separate** `.{ x }` tuple per argument, but `std.fmt.allocPrint` takes exactly three
arguments — `(allocator, fmt, args_tuple)`:

```zebra
var r = "{} and {}".format(1, 2)
```
```zig
// before — 4 arguments, does not compile
(std.fmt.allocPrint(_zbr_rt._allocator, "{} and {}", .{ 1 }, .{ 2 }) catch unreachable)
```
```
f1.zbr:2: error: expected 3 argument(s), found 4
```

The 1-argument case emitted `.{ 1 }` and worked by coincidence, which is why nothing
caught this: **every existing call in the corpus passes exactly one argument.** A
0-argument call emitted no tuple at all and passed only 2, so it was equally broken at
the other end.

Fixed in `selfhost/CodeGen.zbr` at both dispatch sites (~12420 and ~13697): one tuple,
comma-separated, always emitted — which also fixes the 0-arg case (`.{ }` is a valid
empty tuple). Regression fixture: `test/bug224_format_multiarg_test.zbr`, which
deliberately keeps 2-, 3-, mixed-type and computed-argument calls, since a regression
here is a compile failure rather than a wrong value.

---

### BUG-223: `str.charAt` is typed `str` but emits `u8` ✅ FIXED 2026-07-31

**FIXED** — `charAt` now types as `byte` (`Type_.uint_n(8)`), which is what it has always
emitted. Sean delegated the call ("I'm not sure what to suggest") and took the
recommendation: retype rather than remove, because it leaves users an **honest byte
accessor**, which `s[i]` currently is not.

It was free, and provably so: the old typing made every consumer a compile error, so
`grep -rn '\.charAt('` returned **zero callers** repo-wide and it was absent from
QUICKSTART. Nothing could regress because nothing could compile.

This is the CHEAP half of §28e's byte/codepoint split. **BUG-225** (`s[i]` typed `char`
while holding a byte) is the expensive half — ~104 subscript sites in `selfhost/` and
559 `c'x'` literals comparing against the result — and stays deferred to 1.x.

Guarded by `test/boundary/bv_char_at.zbr`, which asserts the byte values and that
arithmetic on the result works, since being a number is the point of the retype.

Found 2026-07-29 while closing #5a's doc gaps. The TypeChecker and codegen disagree:

* `TypeChecker.stringMethodReturn` (~1340) groups `charAt` with `substring` and returns
  `Type_.string_`.
* codegen (`CodeGen.zbr` ~13560) emits `s[@intCast(i)]`, and indexing a `[]const u8`
  yields **`u8`**.

```zebra
def main()
    var s: str = "abc"
    var c = s.charAt(0)
```
```
c2.zbr:3: error: expected type 'str', found 'u8'
```

Note the missing COLUMN: the diagnostic comes from Zig via the remapper, not from the
front end, which is the BUG-215/BUG-218 shape — the type checker believed something
untrue, so it had no complaint of its own to make. Printing it directly is worse
(`invalid format string 's' for type 'u8'`, pointing into std).

**Also unguarded:** the emit site is `if mname == "charAt" and args.len > 0`, so
`s.charAt()` with no argument falls through to another path entirely — the BUG-222
family. `charAt` is absent from QUICKSTART's method tables, so #5a's arity table does
not cover it and cannot catch that yet.

**Needs a design call before a fix, because it is user-facing API.** The name says
char, the implementation says byte, and Zebra has distinct `char` (u21) and `byte` (u8)
types plus a `bytes()` iterator. Recommendation: make it `byte` — that matches the
implementation and `bytes()`, costs no codegen change, and `s[i..j]`/`chars()` already
cover the other two intents. Whichever is chosen, it then belongs in the QUICKSTART
table so the arity checker picks it up.

**Blast radius measured 2026-07-29 (§28e): ZERO, and the method is not merely mistyped
— it is unusable.** Every way of consuming the result is a compile error today, so no
working program can contain a call:

```
print(s.charAt(0))          -> error: expected type 'str', found 'u8'
s.charAt(0).concat("!")     -> error: no field or member function named 'concat' in 'u8'
```

`grep -rn '\.charAt(' --include='*.zbr'` across the whole repo — `test/`, `selfhost/`,
`examples/`, `IDE/` — returns **no callers**, and it is absent from QUICKSTART. There is
therefore nothing to break: retyping it to `byte` cannot regress a caller, because a
caller cannot currently compile. `byte` already exists as a documented type (`u8`,
QUICKSTART line 242), so this needs no new type either.

Note the asymmetry with BUG-225, which is the *same* byte-vs-codepoint incoherence in
`s[i]`: that one is silently WRONG (it compiles and prints a character not in the
string) and expensive to fix, while this one is loudly broken and free to fix. Fixing
BUG-223 also leaves users an honest byte accessor, which `s[i]` is not.

**The exact change, ready to apply on approval.** `selfhost/TypeChecker.zbr` ~1340 —
`byte` resolves to `Type_.uint_n(8)` (see the same file ~593), so no new type is needed
and codegen is already correct:

```diff
-    if name == "substring" or name == "charAt"
+    if name == "substring"
         return Type_.string_
+    # BUG-223: charAt emits `s[i]`, and indexing a []const u8 yields u8 — a BYTE, not a
+    # str. Grouping it with substring typed it `str`, which made every use of the result
+    # a compile error and left the method with zero callers repo-wide.
+    if name == "charAt"
+        return Type_.uint_n(8)
```

Four things ship with it, or the fix is half-done:
1. Guard the emit site. It is `if mname == "charAt" and args.len > 0`, so a 0-arg
   `s.charAt()` still falls through to an unrelated path — the BUG-222 family.
2. Add it to QUICKSTART's method tables (it is absent today). There is no "Returns
   `byte`" table yet, so one is needed — which is also the honest place to say that
   `bytes()` and `charAt()` are the byte-level pair.
3. Regenerate `tools/stdlib_signatures.tsv` from QUICKSTART, which then gives arity
   checking for free and closes item 1 from the other side.
4. A fixture asserting the result is usable as a byte (arithmetic, comparison to a
   `byte`), since "it compiles at all" is the entire regression risk here.

---

### BUG-222: stdlib calls accept TOO FEW arguments — `s.count()` compiles and panics ✅ FIXED 2026-07-29
Found 2026-07-29 by the #5a signature tooling, which probes each documented method at
reduced arity to learn which trailing arguments default. Seven `str`/`List` rows accept
zero arguments. Three are genuine defaults; **four are silently-dropped arguments**, the
mirror image of BUG-215 (which was about too MANY).

```zebra
def main()
    var s: str = "ab"
    print(s.count().toString())     # compiles clean
```
```
thread 4680 panic: reached unreachable code
```

`s.count("ab")` correctly returns 2. Dropping the argument type-checks, emits, links,
and dies at runtime with no diagnostic — the same "typo becomes a runtime panic three
frames away" shape that made BUG-215 worth fixing.

| call | accepted? | actual behaviour |
|---|---|---|
| `s.padLeft(5)` / `padRight` / `center` | yes | **genuine default** — pads with spaces |
| `s.count()` | yes | **PANIC**, reached unreachable code |
| `s.split()` | yes | returns 1 element (silently wrong) |
| `s.concat()` | yes | identity — harmless but meaningless |
| `List(str).join()` | yes | joins with no separator |

**FIXED 2026-07-29 by #5a (`9d713bc`).** `s.count()` is now
`error: str.count expects 1 argument, got 0` at the user's own line and column.
Verified in both directions by `tools/stdlib_sig_check.py`: the run that originally
reported "7 rows accept FEWER args than required" now reports none, and every row is
also checked at max+1 to prove the check is actually firing rather than the gate
merely agreeing with itself.

**Original analysis:** this is what #5a is for. The verified arity table (`tools/stdlib_arity.tsv`,
min..max per receiver kind) already records that `count` requires 1; once the
TypeChecker consults it, `s.count()` becomes a Zebra diagnostic with a caret instead of
a panic. Tracked there rather than fixed separately — a one-off guard on `count` would
leave the other three, which is exactly how BUG-215 ended up as a single `@compileError`
on `indexOf` while the rest of the surface stayed unguarded.

**Note on method:** the probe that found this originally *encoded* these as legal
minima, because probing measures what the compiler tolerates and what it tolerates is
the bug. Separating real defaults from dropped arguments required RUNNING them. A tool
that learns a specification from a defective implementation will faithfully record the
defect as the specification.

---

### BUG-221: module init is not TRANSITIVE — a 3-module program crashes if the deepest dep does I/O ✅ FIXED 2026-07-28
The entry point initialises **direct dependencies only**. A module that is itself only
reached through another module never receives `_initAllocator`/`_initIo`, so its `_io` and
`_allocator` stay `undefined` and the first use segfaults.

**Reproduced 2026-07-28** — three files, nothing exotic:

```zebra
# leaf.zbr
def readIt(p: str): str
    if File.exists(p)
        return File.read(p)
    return "missing"

# mid.zbr
use leaf exposing readIt
def viaMid(p: str): str
    return readIt(p)

# top.zbr
use mid exposing viaMid
def main()
    print(viaMid("nope.txt"))
```

| depth | result |
|---|---|
| `main` → `leaf` (direct dep does the I/O) | works — prints `missing` |
| `main` → `mid` → `leaf` (transitive) | **`Segmentation fault at address 0xffffffffffffffff`** |

The stack carries `0xaaaaaaaaaaaaaaa9` — Zig's poison pattern for `undefined`, confirming
the pointer was never initialised rather than corrupted.

**Mechanism, confirmed in the emit:** `top.zig` emits
`@import("mid.zig")._initAllocator(_allocator);` for each `use` in the ENTRY module only.
`mid.zig` *defines* `_initAllocator`/`_initIo` but never calls them on `leaf.zig`. So init
reaches depth 1 and stops.

**This was previously tracked as "Selfhost `_initIo` propagation gap — harmless today;
would bite if a transitive dep gains file I/O. Track for 1.0 pre-flight."** It is not
harmless and it does not need a future trigger: any three-module program whose deepest
module touches a file crashes today. Re-filed as a bug with a repro and promoted out of
the "track for later" list.

**Fix direction:** make init transitive. Either (a) emit a propagating `_initIo`/
`_initAllocator` in `generateModuleWith` so each module initialises its own `use` deps
(watch for cycles — needs a visited set), or (b) let the single-file emission
(`docs/single_file_emit_design.md`) dissolve it: one preamble, one `_allocator`/`_io`, no
fan-out at all. That design note already lists **deleting this fan-out** as one of its
wins, so BUG-221 is a third independent argument for it (alongside BUG-220's `@export`
residual and error-location legibility).

**RESOLVED under `--runtime-module` (2026-07-28).** Route (b) was taken, via the runtime
module rather than single-file emission: the runtime holds ONE `_allocator`/`_io` that
every module shares at any depth, so there is nothing to propagate, and the entry point
drives `_initModuleVars()` over the **transitive** dep list instead of direct `use` decls.
The repro above now prints `missing` where it segfaulted. Gated by
`tools/runtime_module_check.sh` (QUICK tier) — the only gate that runs anything emitted
in this mode, and therefore the only one that can see this bug.

Note the fix is smaller than "delete the fan-out": `_allocator`/`_io` genuinely stop
needing propagation, but each module's own `_initModuleVars` still has to be REACHED —
which is precisely the transitivity that was missing.

**CLOSED on the default path 2026-07-28 (`ade34cf`)**: runtime-module emission is now the
default, so this needs no flag. The repro prints `missing`.

**The inline path was fixed separately, 2026-07-29.** Closing this on the default path
left the bug LIVE wherever the inline runtime is still emitted — `--no-runtime-module`,
and as the fallback for `--single-file`, `--target node-addon` and every `--gui-backend`.
Verified rather than assumed: the fixture segfaulted there exactly as before, and the
emitted entry point initialised `mid` but never `leaf`. The cause was the same in both
shapes — the fan-out walked DIRECT `use` decls — so the fix is the same: sweep the
TRANSITIVE dep list the driver already computes. With an inline runtime each module owns
its `_allocator`/`_io`, so both still have to be propagated; only the reach was wrong.

Both shapes are now gated by `tools/runtime_module_check.sh`, which runs the fixture with
and without `--no-runtime-module`. Fixing one path and documenting the other as "latent"
was the wrong call: a multi-module GUI app touching a file from depth 2 would have hit a
segfault that was already understood and already fixed twenty feet away.

---

---

### BUG-220: ANY top-level `def` whose name matches a preamble identifier fails to compile ✅ FIXED 2026-07-28
A user function named `f` emits Zig that will not compile:

```
t.zig:255:35: error: function parameter shadows declaration of 'f'
        pub fn map(self: @This(), f: anytype) _Result(
                                  ^
```

The stdlib preamble's `map` takes a parameter named `f`, and a top-level user `def f` becomes a
file-scope declaration that it shadows. The user never mentions `map`; merely *naming a function
`f`* breaks the build, with an error pointing into preamble code they did not write.

Found while reproducing BUG-219 (the 5,952 bytes of stderr that deadlocks `sys.run` are this
error and its reference trace).

**MEASURED SCOPE 2026-07-28 — far larger than one name.** Zig makes it an error for a function
parameter or local to shadow a file-scope declaration, and user top-level `def`s emit as
file-scope declarations. So a user function collides with *any* preamble parameter or local
anywhere in the 186 KB preamble. Tested by emitting `def NAME(a: int)` + `main` and running
`zig build-exe`:

| Name | Result | | Name | Result |
|---|---|---|---|---|
| `f` | FAIL | | `count` | **FAIL** |
| `g` | FAIL | | `data` | **FAIL** |
| `x` | FAIL | | `body` | **FAIL** |
| `s` | FAIL | | `buf` | **FAIL** |
| `self` | FAIL | | `color` | **FAIL** |
| `item` | FAIL | | `total` | **FAIL** |
| `acc`, `key`, `val` | FAIL | | `parse` | OK |

**15 of 16 tested names fail.** Extracting every non-`_`-prefixed identifier from the preamble
gives **423 names, 293 of them ≤6 characters** — including `count`, `data`, `body`, `buf`,
`ctx`, `conn`, `depth`, `chunk`, `color`, `copy`, `cur`, `child`. These are not exotic; they
are the names a person reaches for first. The error they get points into preamble source they
did not write.

**Class, not instance** — same shape as the CherryCobbler finding where an identifier named
`fn` emitted a Zig keyword: **user identifiers share a file-scope namespace with compiler
internals.** Two candidate fixes:
1. **Prefix every preamble parameter/local** with `_` so collision is impossible by
   construction. Mechanical but touches 423 identifiers.
2. **Emit user declarations inside a namespace/struct instead of at file scope.** This is
   *already designed* — `docs/single_file_emit_design.md` specifies exactly that ("all modules
   → one .zig, namespaced structs"). BUG-220 is an independent argument for that work: it was
   justified on architecture grounds, and it would dissolve this whole bug class as a
   side-effect. Worth adding to that design note's motivation.

**FIXED — by (1), on Sean's call: prefix unconditionally.** Top-level `def`s now emit under
the reserved `_zbr_fn_` prefix, exactly mirroring `_zbr_mv_` for module vars. Prefixing is
unconditional rather than only-on-collision by explicit decision: a conditional form needs a
hand-maintained list of preamble identifiers, and a parallel list that drifts is the bug class
the Build failure came from. Selfhost-only — round-trip compares selfhost-A against selfhost-B
and *both* prefix, so byte-identity holds without touching the bootstrap, which continues to
emit `selfhost/*.zig` unprefixed and only has to compile it.

**Reference sites covered** (each of the last five was found by a gate, not by reading):
| Site | Where |
|---|---|
| declaration | `genMethod`, gated `owner == "" and not in_namespace` |
| direct call + by-value reference | `genIdentRaw`, with BUG-137's shadow guard |
| fn-ref **var binding** (`var p = isDigit`) | writes the name directly, `&`-prefixed |
| fn-ref **reassignment** (`p = isDigit`) | same, separate path — caught by full_sweep |
| cross-module alias | `genUse`, prefixed on **both** sides |
| `zebra test` harness | `generateTestEntryPoint` calls tests by name — 10 smoke failures |
| generic call `identity(int)(42)` | `genCall` writes the callee directly |

Not prefixed, correctly: class methods and `namespace` members (already namespaced inside a
struct — `genNamespace` needed an explicit `in_namespace` flag because it emits through a
Generator copy that still has `owner == ""`).

The naming rule lives in **one** module-level function, `zbrFnSymbol(name, is_export)`; the
Generator method and the test-harness emitter both route through it, so the two copies cannot
drift.

**Residual limitation:** `@export` and `@node_export` functions keep their source names,
because for those the ABI symbol *is* the name. So `@node_export def count(...)` remains
exposed to the original collision. Narrow, and the tradeoff is right, but real. (For
`@node_export` specifically it would be fixable — the JS export name comes from a string, not
the Zig symbol — but the napi wrappers call the underlying function by name and it is not worth
the risk for a niche case.)

Note (2) — namespaced emission — remains the deeper fix and would also cover the export cases;
this does not remove the argument for it, it just stops the bleeding now.

---

---

### BUG-219: `sys.run` DEADLOCKS when a child writes more than a pipe buffer to stderr → `zebra -c` hangs on any program with errors ✅ FIXED 2026-07-28
`_sys_run` (`selfhost/stdlib_preamble.zig:459`) drains the child's pipes **sequentially**:

```zig
if (child.stdout) |f| { ... allocRemaining(...) }   // reads stdout to EOF FIRST
if (child.stderr) |f| { ... allocRemaining(...) }   // only then reads stderr
const term = child.wait(_io) ...
```

If the child fills its **stderr** pipe buffer, it blocks writing. Blocked, it never exits, so
its **stdout** never reaches EOF, so the parent never finishes its first read and never starts
draining stderr. Deadlock — both sides waiting on the other, forever.

**Reproduced 2026-07-28.** A five-line program:

```zebra
def f(a: int)
    print(a.toString())

def main()
    print("hi")
```

`zebra -c` on it runs for **>180 s with 0.25 s of CPU** — blocked, not spinning — and never
returns. The emitted Zig makes `zig build-exe` produce **5,952 bytes** of stderr (see BUG-220
for *why* that program fails to compile), comfortably past a 4 KB pipe buffer.

**Why this one matters more than it looks:** `-c` is *check* mode. It exists to report errors,
and it deadlocks precisely when there are enough errors to report — clean programs pass, broken
ones hang. It is also what `IDE/ZebraIDE.zbr`'s **Check** button runs (`CompilerBridge.check`
→ `zebra -c <file>`), so checking a file with a handful of errors hangs the IDE.

This is the **same family as BUG-208** (`zebra run` blocking on a ~4 KB pipe), which was fixed
for the run path via `exec_inherit` — and whose note explicitly said *"other `sys.run` callers
still limited (follow-ups)."* This is that follow-up, now with a concrete repro.

**Fix direction:** the parent must not serialise the two reads. Options, cheapest first:
**FIXED — by delegating to `std.process.run`.** The Zig standard library already solves this:
its `run()` drains both streams concurrently through `Io.File.MultiReader`. `_sys_run` now calls
it instead of hand-rolling the reads. That preserves the contract (both streams + exit code),
deletes the read-ordering bug rather than reordering it, and puts the tricky part upstream where
it is maintained. (The temp-file redirect I had planned would also have worked, but re-deriving
a solution the stdlib ships is the wrong trade.)

**Verified:** the 4-minute deadlock now completes in **1.09 s** and reports its error; stress-
tested against an emit producing **29,593 bytes** of child stderr — 7× a pipe buffer, previously
a guaranteed hang — 1.2 s, captured correctly. Gates: smoke 257/257, round-trip byte-identical,
compile_check 215/0/1 (load-bearing here, since the preamble is inlined into every emitted
program). Fixes the class, not just `-c`: `sys.run` is also used by `CompilerBridge` and the
build tooling.

---

### BUG-218: `str + int` is diagnosed in an annotated context but LEAKS to Zig in a call argument ✅ FIXED 2026-07-28
Found 2026-07-27 while auditing the book: chapter 1 promises *"When you make a mistake,
Zebra tells you clearly"* and shows a clean Zebra-level diagnostic for `"Hello " + 5`.
The compiler only delivers that when there is a type to check against:

| Written as | Diagnosed by |
|---|---|
| `var s: str = "Hello " + 5` | **Zebra** — `error: expected type 'str', found 'comptime_int'` ✅ |
| `var n: int = 5` … `var s = "Hello " + n` | **Zebra** — `error: expected type 'str', found 'i64'` ✅ |
| `print("Hello " + 5)` | **Zig** — `e.zig:3779:54: error: expected type '[]const u8', found 'comptime_int'` ❌ |

In argument position there is no annotation to drive the check, so the bad concat reaches
codegen and the user gets an error pointing at *generated Zig* (`_str_concat`, a line
number in a 3,800-line emitted file) for a plain type mistake in their own source. This is
the `docs/error_experience_audit.md` class, and it is the single most likely first error a
newcomer hits — string-plus-number in a `print` is the canonical beginner slip.

**Fix direction:** type the operands of `+` when either side is known to be `str` and reject
a non-`str` operand at the Zebra level, independent of whether an expected type is in play.
The TypeChecker already reaches the right answer with a target type; it needs to run the
same check bottom-up. Related to the arity gap noted under BUG-215 — both are "the front
end declines to check something it has enough information to check."

**FIXED 2026-07-28.** `inferExpr`'s `BinaryOp.add` arm now checks bottom-up: when one
operand is `str` and the other is a KNOWN numeric or bool, it raises a Zebra error naming
both fixes. Deliberately narrow — `unknown_` never fires (selfhost inference is weaker than
the bootstrap's; erroring on unknown would convert every inference gap into a false compile
error), and `char_` is excluded, so `"a" + c` is untouched. Gated by
`test/fail_fixtures/str_plus_number_rejected_test.zbr`. Full sweep: 0 regressions across 331.

**Known limitation — no source location when BOTH operands are literals.** `AstBuilder`
constructs binary expressions, string literals and int literals all with `zspan()` (a zero
span; 95 of its node kinds do this), so there is no position to report. The diagnostic
borrows the nearest operand's span from an ident, member or call — which covers the realistic
cases (`"n=" + n`) — but `print("Hello " + 5)`, two literals, still reports `0:0`. Fixing it
properly means populating spans in `AstBuilder` from the parser's tokens.

**Measured 2026-07-28 — and my first claim here was wrong.** I originally wrote that "many
expression-level diagnostics inherit this same weakness." They do not. Probing the corpus'
negative tests: 17 produce a located diagnostic, **0 land at `0:0`**. Probing expression-level
errors directly — undefined name `2:11`, var type mismatch `2:0`, wrong argument type `4:5`,
`str + int` with an ident operand `3:17` — all carry locations. The only reproducible `0:0` is
the two-literal concat (`print("a" + 5)`). So this is a narrow wart, not a systemic one, and
the AstBuilder span work it seemed to justify is **not** worth prioritising. Recording the
correction rather than the tidy version: the generalisation was speculation, and one probe
refuted it.

**Book impact (done):** `01-Getting-Started.md` now shows `print("Hello " + count)` with the
real transcript, captured verbatim from the compiler. It uses a variable rather than a literal
precisely because of the limitation above — with two literals the transcript would have had no
line number, and putting a fabricated one in the book was not an option.

### BUG-217: `CodeEditor.setText` handed Scintilla a non-NUL-terminated buffer → segfault ✅ FIXED + RUN-VERIFIED 2026-07-27
`IDE/ZebraIDE.zbr` aborted (exit 3) on the **Build** button. Sean's stack trace was decisive:

```
Segmentation fault at address 0xffffffffffffffff
  ... in strlen (compiler_rt.lib)
  scintilla/src/Editor.cxx:6190  pdoc->InsertString(0, text, strlen(text));
  ... Editor::WndProc → ScintillaBase::WndProc → ScintillaWin::WndProc
  libui_scintilla/win.cxx:60  SendMessage(s->hwnd, SCI_SETTEXT, len, (LPARAM)text);
  src/sci.zig:9  uiScintillaSetText(self, text.ptr, @intCast(text.len));
  main.zig  _code_editor_set_text → if (_ed.scint) |_s| _s.setText(_ed.text);
```

**Root cause:** `SCI_SETTEXT` **ignores** the length in `wParam` and calls `strlen()` on
the pointer — even though the libui-scintilla binding's Zig signature accepts an explicit
length, which is exactly what makes this trap convincing. `_code_editor_set_text` used
`_allocator.dupe`, which produces **no terminator**, so Scintilla read off the end of the
allocation. The empty case is worse than a stray read: `dupe` of an empty slice returns a
zero-length slice whose `.ptr` is not a readable address at all, so **`setText("")`
segfaults immediately** — and `Msg.build_start` opens with
`m.buildOutputEditor!.setText("")`. Address `0xffffffffffffffff` is that pointer.

**Why it wasn't found earlier:** `examples/editor_min.zbr` (the run-verified single-editor
proof) only ever calls `setText` with a non-empty string literal, where `strlen` usually
finds a zero somewhere in fresh arena memory before faulting. It is a latent
read-past-the-end there too — it just survived.

**Fix (`selfhost/gui_libui_ng_section.zig`):** `_CodeEditor` now keeps `buf` + `len` with
the invariant `buf[len] == 0` and `buf.len >= len + 1`, established in `_code_editor_new`
so no path needs a "never set" special case. Also fixes a second latent defect on the read
path: `SCI_GETTEXTRANGE` writes `n + 1` bytes (it NUL-terminates), but the old code
reallocated only when `n > buf.len`, letting an exactly-full buffer overflow by one byte.
`_code_editor_render` can now call `setText` unconditionally.

**Scope:** libui_ng backend only — the stub/tui `_code_editor_*` store plain slices and
never cross a C boundary. **Not gate-provable** (no headless GUI) — closed instead by
interactive confirmation: Sean clicked Build/Check/List Targets post-fix, "all crashing
behavior w/ those buttons is gone" (2026-07-27).

### BUG-216: `\"` inside an INTERPOLATED string is double-escaped by the bootstrap ✅ VICTIMS FIXED 2026-07-27 (bootstrap root cause left open by choice)
A string that is both interpolated and contains an escaped double quote is compiled
differently by the two compilers:
```zebra
var s = "say \"hi\" n=${n}"
```
- **selfhost** emits `allocPrint(_allocator, "say \"hi\" n={}", …)` — **correct**.
- **bootstrap** emits `allocPrint(_allocator, "say \\\"hi\\\" n={}", …)` — **wrong**.

Root cause (`src/CodeGen.zig` `genStringInterp`, the `if (c == '"') … if (c == '\\')`
escape pass around 16686): the literal parts of an interpolated string carry the **raw
source text**, which is then escaped *again* on the way out, so `\"` → `\\\"`. A plain
non-interpolated string is unescaped correctly by both compilers.

**Why a bootstrap-only bug mattered here.** Normally the rule is "don't chase, the
bootstrap sunsets". But the bootstrap is the **regen authority** for `selfhost/*.zig`, so
this corruption is baked into the *shipping* compiler wherever the pattern appears in the
compiler's own source. It did, in exactly three places: all three `genCopyOut` `<<-`/`<-`
diagnostics emitted `@compileError(\"…` — a Zig **parse** error rather than the message
they were written to give — from the day they were added until 2026-07-27. Nobody noticed
because those diagnostics only appear when you make that specific mistake.

**Fixed:** the three victims now emit the line number as its own piece so every string
stays plain (`w.emit("@compileError(\"line ")` / `w.emit(co.span.line.toString())` / …).
**Gated:** `python tools/lint_interp_escape.py` — static, instant, no build; flags any
`${`-bearing literal containing `\"` in `selfhost/*.zbr` and `IDE/*.zbr`. 0 = clean.
**Left open:** the bootstrap root cause. Fixing it would make the two compilers agree, but
the pattern is now greppable and gated, and the bootstrap is being phased out. Retire the
lint when the bootstrap is fixed or removed.

### BUG-215: two-argument `str.indexOf(sub, from)` silently dropped the offset ✅ FIXED 2026-07-27
`indexOf` takes **one** argument; the offset form is a separately named method,
`indexOfFrom(sub, from)`, returning `int?`. Both compilers accepted `indexOf(sub, from)`
and **silently discarded** the second argument — every search restarted at 0.

**How it presented:** `IDE/ZebraIDE.zbr` used the two-argument form in five places. In
`parseLine` that made `colon1 == colon2 == colon3`, and the very next line does
`ln.substring(colon1 + 1, colon2)` — start > end → Zig slice panic, three frames from the
typo. `parseBuildTargetNames` had the same shape. Those are the **Check** and **List
Targets** toolbar buttons; the IDE aborted (exit 3) on both. Found immediately after
BUG-214 stopped masking it (before that, no button ever dispatched at all).

**Fixed, two parts:**
1. `IDE/ZebraIDE.zbr` — all five sites moved to `indexOfFrom` with `int?` handling.
   Verified against realistic input: `foo.zbr:12:5: error: …` → `12|5|error: bad thing`,
   the Windows `C:/…` drive-letter form parses, non-matching lines return nil, and target
   parsing yields `app`/`lib`.
2. **Codegen guard** (`selfhost/CodeGen.zbr`, both string-method dispatch sites) — an
   `indexOf` call with more than one argument now emits `@compileError("line N:
   str.indexOf takes 1 argument; for an offset search use indexOfFrom(sub, from)
   (returns int?)")` instead of miscompiling. Silently dropping an argument is the worst
   available behavior: it converts a typo into a runtime panic far from its cause.

**Gated:** `smoke_emit_contains test/fail_fixtures/indexof_arity_rejected_test.zbr`.
**Note on the guard's presentation:** Zig reports it as `error: unreachable code` with the
`@compileError` text visible on the offending line, rather than as the compileError itself
(the guard sits in a `const` initializer). The message reaches the user either way; this
matches the pre-existing `genCopyOut` guard pattern.
**Not addressed — the wider class:** arity is unchecked for stdlib methods generally
(`if args.len > 0 genExpr(args[0])` is the pervasive shape, extra arguments ignored).
A real fix is a stdlib signature/arity table in the front end so this becomes a proper
Zebra-level error with a source location. Worth doing before 1.0; `indexOf` is only the
instance that drew blood.

---

### BUG-214: no-payload `union(enum)` variant in value position emitted as tag, not union value → MVU send abort ✅ FIXED + RUN-VERIFIED 2026-07-27
`IDE/ZebraIDE.zbr` now **compiles + links** via `--gui-backend=libui_ng` (all compile gaps
closed: CodeEditor port `b42074a`, BUG-211, BUG-213), and **the window RENDERS and runs**
(Sean-confirmed 2026-07-27: "I did see the IDE"). It **aborts at runtime (exit code 3) on
the first no-payload-variant send** — i.e. clicking any toolbar button (`Open`/`Save`/
`List Targets`/… all send no-payload `Msg` variants) — NOT on startup. The abort is in the
type-erased MVU `send` queue-copy (`_gui_mvu_run` `_sfn`, emitted main.zig:3003), reached
from `view → g.send` (the button-click handler runs inside `view`). **Root cause (well-supported by the emit):** the IDE's `Msg`
is a `union(enum)` with mixed variants — no-payload (`list_targets`, `open_file`, …) and
payload (`filepath_changed: []const u8`, …). A no-payload variant in **value position** is
emitted as bare **`Msg.list_targets`** (the tag), whereas payload variants correctly emit a
full union value `Msg{ .buildfile_changed = bfVal }`. When `Msg.list_targets` is passed to
`g.send(msg: anytype)`, the argument's inferred type is the tag, not the full `Msg` union;
the send queue then reinterprets `&msg` as `*const MsgType` (= full `Msg`) and copies
`@sizeOf(Msg)` bytes from a tag-sized source → size/type mismatch → abort. The crash stack
points exactly at the `g.send(Msg.list_targets)` call site (view:4812). **counter.zbr is
unaffected** — its `Msg` is a *pure enum* (all no-payload), so `Msg.inc` is already a valid
full value and `MsgType` sizes match; the bug needs a `union(enum)` Msg with ≥1 payload
variant AND a no-payload variant sent.

**CONFIRMED at the language level 2026-07-27**, twice over:
1. Zig probe — for `union(enum) { a, b: []const u8, c }`, `@TypeOf(Msg.a)` is
   `@typeInfo(Msg).@"union".tag_type.?` with `@sizeOf == 1`, while `Msg{ .a = {} }` is `Msg`
   with `@sizeOf == 24`. `examples/counter.zbr` survives only because an all-no-payload
   union and its tag are both 1 byte, so the memcpy is accidentally correct.
2. Minimal repro — `test/mvu_mixed_union_test.zbr` (mixed `union Msg { bump, set_label: str }`,
   `view` sends both forms). It aborts under the **plain stub backend** — no GUI, no display
   needed: `thread N panic: incorrect alignment`, from the `@alignCast` in the send queue
   applied to a 1-byte-aligned tag. This makes BUG-214 a runnable regression gate.

**Fix direction — NARROW, not "value/argument position" (the original note was wrong).**
A blanket rewrite of bare `Union.variant` is both unnecessary and actively harmful:
- Every **typed** position (assignment, typed parameter, return, `==` against the union)
  coerces the tag to the union for free, so the bare form is correct there.
- `x == Union{ .v = {} }` is **not legal Zig** (`error: operator == not allowed for type`),
  so a blanket rewrite would introduce a new compile error class.
- `Type_.string_` and friends appear in hundreds of the compiler's own emitted sites, so a
  blanket rewrite would force a matching change in the sunsetting bootstrap to keep
  `bootstrap_check` byte-identical.
The only position with no type to coerce to is the type-**erased** `anytype` parameter of the
MVU `Gui.send`. So: rewrite bare no-payload variants to `Msg{ .variant = {} }` **only** as the
single argument of `send` on a `Gui` receiver, and only for unions declared in the same module
(`novalue_variants`, populated alongside `boxed_variants`). Selfhost-only by construction —
the compiler's own source has no `Gui.send`, so the round-trip stays byte-identical.
**Known limitations — measured, not guessed** (probe: `viewM` as a class method, a send
nested inside `using g.vbox(...)`, a local `var g2: Gui = gg`, and an UNANNOTATED `def
view(g, m)`; emit inspected for each):
- Receiver inference is wide enough for every idiomatic shape — annotated parameter, class
  method, inside a `using` block, and an annotated local all convert. The **only** shape that
  falls back to the bare tag is an **unannotated** receiver parameter (`def view(g, m)`),
  where `inferExpr` cannot reach `Type_.gui_context`. That is a silent miscompile if anyone
  writes it; §28a is moving the language away from unannotated params, and no corpus program
  has that shape. Widening the rewrite to fire on an unknown receiver was considered and
  rejected: it would have to bypass the generic member-call tail, which is where `throws`
  propagation is emitted — trading a documented narrow gap for an undocumented one.
- The rewrite is depth-1: `g.send(if c then Msg.a else Msg.b)` is not covered.

**Landed:** `selfhost/CodeGen.zbr` — `novalue_variants` (populated alongside `boxed_variants`
in both the pre-pass and `genUnion`), `isNoPayloadUnionValue` / `genNoPayloadUnionValue`, and
an `on Type_.gui_context` arm in `genMemberCall` that falls through unchanged for every other
Gui method and every non-matching `send` argument. Verified: all 11 bare sends in
`IDE/ZebraIDE.zbr` convert; repro runs clean; `bootstrap_check` byte-identical; smoke 255/255;
`compile_check` 215/0/1; `divergence_check --gate` 0 selfhost gaps.
**RUN-VERIFIED 2026-07-27:** the gates proved emit shape and no-regression only; the
IDE surviving a real toolbar click was confirmed by Sean clicking through the toolbar.
Buttons dispatch. Doing so immediately unmasked BUG-215 and BUG-217 — two crashes that
were unreachable while nothing dispatched at all; both fixed and confirmed in the same
session.

### BUG-213: selfhost `typeFromName` missing `SysProcess` → `proc.isRunning()` mis-dispatched ✅ FIXED 2026-07-27
Verified post-rebuild: both call forms the IDE uses — `m.proc!.isRunning()` (force-unwrap)
and `if m.proc as p` → `p.isRunning()` (binding) — now emit `_sys_process_is_running(...)`
(probe: 2 call sites converted, 0 residual `.isRunning()`).
The selfhost already dispatches `sys_process` instance methods (`CodeGen.zbr:10981` →
`_sys_process_is_running` / `_sys_process_kill`) and infers `sys.spawn` → `sys_process`.
But `typeFromName` had no `SysProcess` → `sys_process` arm (the bootstrap does, at
`src/TypeChecker.zig:4696`). So a field/var **annotated** `SysProcess?` was not typed as
`sys_process`; a receiver bound from it (`m.debugProc as proc` or `m.debugProc!`) inferred
as unknown, and `proc.isRunning()` fell through to generic method dispatch — emitting a
literal `proc.isRunning()` that Zig rejects (`_SysProcess` has no such member). Blocked the
libui_ng build of `IDE/ZebraIDE.zbr` (its `debugProc`/`buildProc: SysProcess?` fields drive
process polling), *after* the program compiled cleanly through all the CodeEditor code.
**Fix:** one line — `if n == "SysProcess" return Type_.sys_process`, alongside the sibling
builtin-type mappings (Gui, CodeEditor, SqliteDb, …). Same class as the CodeEditor
name→type gap. Note `SysProcess` already resolves (it's not the resolver that was missing
it) — only the type-inference mapping.

### BUG-211: selfhost `nameUsedInStmt` ignored `using` blocks → spurious param discard ✅ FIXED 2026-07-27
`CgHelpers.nameUsedInStmt` (the name-presence scan behind param/local unused-discard
emission) handled 16 statement kinds but had **no `Stmt.in_scope` arm** (the node the
`using` keyword parses to — NOT `Stmt.with_`, which is the `with` contextual-self keyword;
`nameUsedInStmt` was missing both). So a `using EXPR` block fell to `else → false`: any
parameter or local used *only* inside a `using` block was seen as unused, and codegen
emitted a `_ = name;` discard — which Zig then rejects: `error: pointless discard of
function parameter … used here`. This bit **every idiomatic MVU `view`** whose `g`/model
are touched only inside `using g.vbox(...)` (the canonical libui/tui layout form).
`counter.zbr` dodged it (uses `g` at top level); the minimal `examples/editor_min.zbr` and
any params-only-in-`using` program hit it. Found building a minimal CodeEditor program via
`--gui-backend=libui_ng`. **Fix:** add both the `Stmt.in_scope` and `Stmt.with_` arms
(check the header expr + recurse into body `stmts`), mirroring the sibling passes
(`mightUseNameStmt`, `scanMutationsInto`, escape helpers) that already recurse into both.
Verified: `scanMutationsInto` already had both arms and `collectAllIdents` is expr-level,
so `nameUsedInStmt` was the sole gap. Strictly widens the "used" set → can only remove
false discards, never add one (the one exception — a param shadowed by a same-named local
inside the block — is not present in the corpus).

### BUG-210: `zig build update-selfhost` can skip regeneration after a `.zbr`-only edit ✅ FIXED 2026-07-25
`update_run` (`build.zig`) is `b.addSystemCommand({"bash","tools/bootstrap_check.sh",
"--update"})` with a fixed argv, `dependOn(bootstrap_exe)`, and **no declared
`.zbr` inputs**. So Zig's build cache can treat it as up-to-date and **skip the
regeneration** when only `selfhost/*.zbr` changed (bootstrap exe unchanged) —
`zig build update-selfhost` silently no-ops and `selfhost/*.zig` stays stale,
drifting from its `.zbr` source. Observed repeatedly 2026-07-25: edits to
`selfhost/main.zbr` did not reach `main.zig` until forced. **Workaround:**
regenerate directly — `zig-out/bin/zebra-bootstrap.exe --emit-zig selfhost/foo.zbr
> selfhost/foo.zig` — or invalidate the cache. **Fix direction:** mark the step
`has_side_effects = true` (always run) or declare the `.zbr` files as inputs so
the cache key tracks them. Small build.zig change; do it carefully (build system).
`bootstrap_check.sh` itself (the gate) is unaffected — it regenerates into /tmp
fresh each run.
**Fixed (`build.zig`):** `update_run.has_side_effects = true` — the regeneration
step now always runs when `zig build update-selfhost` is invoked. Verified: two
back-to-back invocations both fully regenerate (Step 1/2/3 + PASS each time);
before, the second was a cache no-op.

### BUG-209: `uses_sqlite` false-positive disabled the fast run path + linked sqlite3.c into every compile ✅ FIXED 2026-07-25
The selfhost detected SQLite usage with `zig_src.contains("_sqlite_open")` — but
the preamble **inlines** the `fn _sqlite_open` *definition* into every emitted
program, so the check was true for **every** program. Two costs compounded:
1. The `-fno-llvm -fno-lld` self-hosted-backend **fast run path** (gated on
   `not uses_sqlite`) was never taken → every `zebra run` used the slow LLVM route.
2. The LLVM path linked `vendor/sqlite/sqlite3.c` into **every** compile.
Net: a trivial program took ~14 s to `zebra run` instead of ~1 s. Found while
investigating why the fast path (added `f9a05d1`, verified ~3× then) had gone
dormant. The bootstrap was never affected — it sets `uses_sqlite` structurally in
codegen (`src/CodeGen.zig`), only when a real Sqlite call is emitted.
**Fix (`selfhost/main.zbr`):** detect by **occurrence count**, not presence — the
preamble contributes exactly one `_sqlite_open` (the definition), so a real
`Sqlite.open/query` call adds a second. Bind the split to a `List(str)` first
(`var p: List(str) = zig_src.split("_sqlite_open")`; `p.len > 2`) — a chained
`.split(x).len` emits a Zig split *iterator*, which has no `.len`.
**Verified:** `zebra run` on a plain program dropped ~14 s → ~1 s (fast path now
taken, `.fast.exe` produced); a `Sqlite.open` program still routes to LLVM and
runs; `bootstrap_check` byte-identical; smoke 254/254.

### BUG-208: `zebra run` hangs when the program prints more than ~4 KB ✅ FIXED 2026-07-25
`zebra run <file>` ran the compiled program via `sys.run()`, which **captures**
the child's stdout/stderr through OS pipes. The reader blocks once the pipe
buffer (~4 KB on Windows) fills, so any program that prints more than a few KB
**hangs forever** (CPU 0%, blocked on the write). Found dogfooding
`examples/lsystem.zbr` (ASCII output ~9.5 KB): every run hung at ~4275 bytes
regardless of line length or count — the tell-tale fixed pipe-buffer cutoff.
**Not a codegen bug:** the *standalone* compiled exe prints 64 KB instantly under
both backends, and the bootstrap (`zebra-bootstrap.exe file.zbr > out`) prints
64 KB fine through the identical harness — because it **inherits** stdio for the
program run (`src/main.zig`, `.stdout = .inherit`) instead of capturing it.
**Fix (`selfhost/main.zbr`):** run the compiled program with inherited stdio
(`sys.exec_inherit`), never captured. The LLVM run path was switched from
`zig run` (which captured the program's output via `sys.run`) to
`zig build-exe -femit-bin=<exe>` (capture only the small compile output, where
`remapZigErrors` belongs) followed by `sys.exec_inherit(<exe>)`. Mirrors the
bootstrap. Verified: `zebra run` on a 64 KB-output program now completes
(64005 bytes, exit 0); the L-system renders; small output unaffected.
*(Honest note: the first attempt put `exec_inherit` in the fast `-fno-llvm` path,
which — see the follow-up below — isn't currently taken, so it was correct but
dormant; the operative path was the LLVM branch. Both now inherit.)*
**Follow-ups (separate, lower priority):**
- The fast `-fno-llvm` run path isn't being taken (no `.fast.exe` is produced for
  a plain program), so every `zebra run` currently uses the slower LLVM route.
  Worth a one-line trace to find why the `2213` condition or fast build falls
  through — restoring it is a ~3× dev-loop speedup. Its run step already inherits.
- `sys.run()`'s ~4 KB capture block still affects its *other* callers (node-addon
  build, `Shell.run`, and the compile-error stream itself if a build ever emits
  >4 KB). The program-run case is fixed by not capturing; those capture sites
  retain the latent limit. Fix if they ever handle >4 KB output.

### BUG-204/205/206: bootstrap (LLVM) lags the selfhost on `except` — blocks GUI/TUI apps
All three found 2026-07-25 dogfooding `examples/tears_of_the_tuon.zbr` (a game
port). They share a theme: the **selfhost compiles these fine**, but the
**bootstrap does not** — and GUI backends (`--gui-backend=stub|tui|glfw`) are
hard-wired to *delegate to the bootstrap* (it carries the GUI/zigzag runtime),
so these gaps block any GUI/TUI program even though the primary compiler accepts
it. This is the normally-"don't-chase" bootstrap-lags-selfhost category, but the
GUI-delegation makes it user-visible. Closing them is a scoped parser+codegen
job on `src/` (the selfhost already has the correct behavior to mirror).

**BUG-204 — parser: `except` only parses in var-init position.**
`return p except x = 1` and even `return (p except x = 1)` → `syntax error near
'except'` in the bootstrap; `var q = p except x = 1` is fine. The selfhost
parses `except` as a general (postfix) expression. Repro:
```
struct P { var x: int }
def f(p: P): P
    return p except x = 1     # bootstrap: syntax error; selfhost: OK
```
**Workaround (used in the example):** bind first, then return —
`var q = p except x = 1` / `return q`.
🚫 **WON'T-FIX in the bootstrap (Sean 2026-07-25).** A real fix needs a new
expr-level AST node + Expr9 postfix grammar production + AstBuilder + CodeGen,
with Earley ambiguity to manage — a sizable change to the *sunsetting* bootstrap.
✅ **DISSOLVED for the GUI/tui path (2026-07-26).** `--gui-backend=tui` now builds
through the **selfhost** (no bootstrap delegation), where return-position `except`
already parses — so GUI/tui apps use the natural form. Proven: `examples/tears_of_the_tuon.zbr`
builds via `--gui-backend=tui` with the workaround removed. Still latent for the
bootstrap itself + non-tui GUI backends that still delegate; the bind-then-return
workaround remains valid there. See NEXT_STEPS "GUI builds via selfhost emission".

**BUG-205 — codegen: a var *initialized with* `except` is emitted `const`.**
✅ **FIXED 2026-07-25** (`src/CodeGen.zig` `genVarExcept`). The bootstrap
hardcoded `const` for except-initialized vars; it now picks `const`/`var` from
the mutation set exactly like `genLocalVar` (a reassigned except-init var → `var`,
a never-reassigned one → `const`, preserving const-correctness). The selfhost was
already correct because it lowers `except` to an expression initializer through
the normal local-var path. Was:
```
def g(p: P): P
    var m = p except x = 1    # emitted `const m`
    m = m except x = 2        # error: cannot assign to constant
    return m
```
**Historical workaround (no longer needed):** plain-init then reassign.

**BUG-206 — codegen: `.toInt()` on a float loses float-inference across
reassignments.** In `resolveAttack`, `(attackRoll - defenseRoll).toInt()` (both
operands provably `f64`) emitted a passthrough `.toInt()` (invalid Zig:
`no field or member function named 'toInt' in 'f64'`) after the operands were
conditionally reassigned in intervening blocks. The bootstrap has correct
float→int (`@intFromFloat`) but its float detection at the call site didn't
survive the reassignment history. **Workaround:** bind an explicitly-typed float
first — `var delta: float = attackRoll - defenseRoll` / `var rollDelta =
delta.toInt()`.
⏸ **DEFERRED 2026-07-25 — minimal repro not found (time-boxed).** Reconstructing
`resolveAttack`'s exact shape in isolation (var-instance `rng.nextFloat()`,
nested-if operand reassignment, an early `return` before the `.toInt()`, and the
intervening `var isCrit`/`var base` block) all emit `@intFromFloat` correctly.
The passthrough only manifests inside the full multi-function game module, so a
fix cannot be verified against a minimal case — deferred rather than shipped
blind. The workaround is in place and documented; reopen with a full-module repro.
✅ **DISSOLVED for the GUI/tui path (2026-07-26)** — `--gui-backend=tui` builds
through the selfhost now, whose `.toInt()`-on-float emission is correct; the game
builds via `--gui-backend=tui` with the `var delta: float` workaround removed.
Still latent for the bootstrap itself.

### BUG-200: deeply-nested expressions stack-overflow ✅ FIXED for recursive nesting (2026-07-23); flat-chain residual documented
A deeply-nested expression crashed the compiler with a **stack overflow** instead of a
clean diagnostic — the AST tree-walk (parse → resolve → typecheck; `zebra --check`
alone crashes, so it's the front-end) recurses on expression-tree depth. Measured
selfhost crash thresholds: deep **parens/calls** segfault at ~450 (the worst and most
realistic case — parens re-enter `parseExpr`); flat single-operator **chains**
(`1+1+…`) overflow the downstream walk at ~1000 (built iteratively, don't re-enter
parseExpr).
**FIXED (recursive nesting):** `selfhost/Parser.zbr::parseExpr` now guards recursion
depth (`expr_depth > 200` → clean `error: expression nested too deeply (max nesting
depth 200)`), cleared per-top-level-decl in `tryParseTopDeclInto` to survive error
recovery. 200 is ~4x above any realistic nesting and leaves ~250 stack frames below the
~450 crash. Deep parens/calls/nested-data (the realistic + lowest-threshold crash) now
diagnose cleanly. Regression: `test/bug200_deep_nesting_test.zbr` (250 parens →
smoke_tc_fail). Gates all green.
**Residual (⛔ open, low priority):** extreme single-operator FLAT chains (~1000+ terms,
e.g. `1+1+…+1`) build depth via the iterative binary loops without re-entering parseExpr,
so the guard doesn't catch them — they still crash the tree-walk. A pure fuzzer artifact
(no hand-written code is a 1000-term flat sum; not gramgen-gate-reachable at depths 7/11).
Fix would add per-iteration caps to the ~7 binary-operator loops (parseOr/And/Comparison/
AddSub/MulDiv/pipeline). Deferred — very low value. The Zig bootstrap keeps the whole
crash (sunsetting; not fixed there).

---

### BUG-199: selfhost parser INFINITE LOOP on a leading non-`static` modifier ✅ FIXED (2026-07-23, gramgen fuzzer find)
**18-byte hang.** `readonly struct b` (or any bad top-level decl led by `readonly`/
`abstract` — a non-`static` `ModList` modifier) sent the selfhost parser into an
infinite loop: `zebra.exe` hung >40s (killed) while `zebra-bootstrap.exe` rejects it
in 80ms. **Root:** `Parser.zbr::skipToTopLevelBoundary` returned *without advancing*
when re-entered already sitting on a col-1 recovery-starter — so `parseModule`'s
`while not isEof(): tryParseTopDeclInto()` retry loop re-parsed the same failing token
forever. The bootstrap has no such bug: `parseWithRecovery` resumes at
`findRecoveryBoundary(pos + error_pos + 1)` — the `+1` guarantees forward progress.
**Fix (convergent, selfhost-only, error-recovery path only):** if recovery re-enters
on a col-1 recovery-starter, step past it once before scanning — mirroring the
bootstrap's `+1`. Cannot affect valid parses (only the post-error path changes).
Now rejects in <100ms with a clean `unexpected top-level token: 'readonly'`. Gates:
smoke 236+1, round-trip byte-identical, compile_check, divergence `--gate` (0 selfhost
gaps). Regression: `test/bug199_recovery_hang_test.zbr`. **Found by the new grammar
fuzzer `fuzz/gramgen.py` on its first runs** (a 551-char generated program timed out;
minimized to 18 bytes). Same super-linear-cost family the BUG-181 notes flagged, but
an actual infinite loop, not just slow.

---

## Dogfood findings — Greek NT n-gram program (2026-07-17)

Surfaced by writing a real text-analytics program in Zebra (SBLGNT n-gram +
TF-IDF cosine). Full context: wiki `concept_greek-nt-ngram-stylometry`; repro
programs in that session's scratchpad (`gng/`). Recurring theme across several:
**nested generics + non-`str` element types are under-supported in the selfhost's
container-method dispatch and pointer-mutation analysis.**

### BUG-198: assigning a union value to an OPTIONAL field drops the box type arg ✅ CANNOT REPRODUCE — likely resolved (2026-07-24)
**Could not reproduce** with four faithful shapes (all run correctly): the exact reported
`.field = t` setter pattern (non-optional union param → `Type_?`-style optional union
field), a recursive union (`node: ^Tree`), and an explicit `^Tree?` field. Emits a
correct box, no bare `create()`. Appears resolved by intervening codegen (the divergence
burn-down / BUG-187/188 nil-narrowing era), same as BUG-196's filed face (b). NOT
definitively closed: the original trigger was the specific extend_test
`InferCtx.self_type_override: Type_?` context with the param-as-optional workaround NOT
applied, which wasn't reconstructed here. Added a regression GUARD for the now-working
behavior: `test/bug198_union_optional_field_test.zbr` (smoke_run "bug198: OK"). If it ever
resurfaces, reconstruct the extend self-typing context. Original report retained below.


Direct assignment of a non-optional union value to an optional heap-boxed field —
e.g. `def withSelfType(t: Type_): .self_type_override = t` where the field is
`Type_?` — emits `_allocator.create()` with **no type argument** (`create()` needs
`create(T)`): `{ const _rp = _allocator.create() catch @panic("OOM"); _rp.* = t; self.f = _rp; }`
→ "member function expected 1 argument(s), found 0". The auto-box path for
`union → optional-field` omits `@TypeOf(t)`/the concrete type. Workaround used at the
call site (extend self-typing): declare the setter param as the OPTIONAL type
(`t: Type_?`) so the optional wrap happens at the call boundary (which boxes
correctly), not in the setter body. Real fix: emit `_allocator.create(@TypeOf(t))`
(or the field's element type) in the union→optional-field boxing codegen. Surfaced
during the extend_test divergence fix (2026-07-20).

### BUG-197: SIMD `f32x8` islanded — cannot ingest computed / collection data ✅ FIXED (all 3 tiers, 2026-07-18)
**RESOLVED for real use** — the data bridge is in (commits `ac48cbe`, `015e8c3`):
- **Tier 1 — `.toFloat32()`** (`float`/int/`str` → `f32`): `@floatCast`/`@floatFromInt`/
  `parseFloat(f32)`. Both compilers. Lets computed f64 feed `f32x8` lanes.
- **Tier 2 — `List(float32)`/`List(f32)`**: the selfhost had *diverged* from the
  bootstrap (which already accepted them) — its parser rejected sized-numeric type
  names in value position and its resolver didn't know them. Converged both.
- **Payoff:** the SIMD-vs-scalar all-pairs cosine on the Greek book vectors (the
  comparison the dogfood left blocked) now runs — **~7.8× faster** (f32x8 ~0.39 ms
  vs scalar ~3.03 ms, ReleaseFast), numerically identical (checksum matches), and
  reproduces the exact authorship clustering. Near-perfect 8-lane utilization.
- **Tier 3 (DONE, commit `736a7d6`)** — `f32x8.load(list, offset)` loads N lanes from
  a `List(f32)` at an offset, so hot loops don't hand-write eight `.at()` calls. Plus
  ergonomic follow-ups (`ee69570`, `ce12e9f`): un-annotated `f32x8` reductions,
  `f32.toFloat()` widening, `List(f32)`≡`List(float32)`. **All three tiers complete.**

Original report (for context):
`f32x8` requires `f32` lanes, but there is no bridge from computed data:
- `List(f32)` → resolver "undefined name 'f32'"; `List(float32)` → parser
  "unexpected expression token" (the value-position `List(T)()` ctor-call path
  parses `T` as an expression and rejects sized-numeric names, though the type-
  *annotation* path `var c: float32` accepts them via `isSizedTypeName`).
- No runtime `f64 → f32` conversion: `float32(x)` doesn't parse, no `as` cast,
  `var a: float32 = <runtime f64>` is rejected. Only comptime float literals coerce.
So `f32x8` works only with inline literals (`simd_test.zbr`); it cannot take a
computed vector, a `List`, or loop-varying data — blocking the TF-IDF/cosine and
embedding workloads that motivated SIMD. **Fix is tiered and mostly localized —
see NEXT_STEPS "SIMD data bridge".** Not a redesign.

**Also surfaced — two concrete minimal repros of the OPEN D4 `*T`-vs-`*const T`
cluster:** sorting `List((int,int))` with a lambda comparator, and passing a
`List(List(int))` to a fn parameter, both fail — while the `str`-element versions
(`List((str,int))` sort, `List(List(str))` param) work. The **element-type
dependence is a strong root-cause clue** for the D4 fix. See NEXT_STEPS.

---

## BUG-192: `^T` field assigned a value in `cue init` not auto-boxed (D4 `*T`-vs-`T`) ✅ FIXED same-module (2026-07-17)

A `^T` (heap-indirection) field initialised from a value inside a constructor emitted the value
straight into the `*T` slot — `expected '*Expr', found 'Expr'`. Two causes, both in
`selfhost/CodeGen.zbr`:

1. **Bare-ident field target not recognised.** Inside `cue init`, `left = l` has target
   `Expr.ident("left")` (a bare field name), not `self.left`. `getAssignFieldType` only handled
   *member* targets, so the ref-box path never saw the field type. Extended it to resolve a
   bare-ident target that is a field of the current owner (a local var shadows a field, so a known
   local is excluded).
2. **Union payloads not boxed.** The ref-box path only boxed `struct_names`, but `^T` fields also
   hold **unions** (`^Expr`, `^TcExpr` where `Expr`/`TcExpr` are `union`s). Extended the box
   condition to `.module_types.hasUnion(tn)` as well. (`^Class` is a hard error, so `^T` is always
   a struct or a union — never a class.)

**Regression caught + fixed by the gate:** the union extension boxed `cue init(opt_val: ^Val?)
{ .opt_val = opt_val }` — but `opt_val` is *already* a `?*Val` pointer, so boxing tried to store a
`*Val` into a `Val` slot (broke `val_test`). Auto-box converts a *value* to a heap pointer, so it
must not fire when the RHS is already a ref. Added `rhsIsAlreadyRef` (inferExpr → `^T`/`^T?`) as a
guard on the box path — which also hardens the pre-existing struct case against the same shape.

Result: `selfhost_probe5` compiles end-to-end; `tc_infer_test`'s `^T`-box error is cleared (it now
fails on an unrelated D3 `.len`-on-struct). Gates: round-trip byte-identical, smoke 236/236,
compile_check 198/0/3.

**Follow-up (cross-module unions):** `tc_check_test` assigns a `^tc_infer.TcExpr` field
cross-module; the box condition checks `.module_types.hasUnion` (same-module only) and the create
type name would need the qualified `tc_infer.TcExpr`. The dotted name is already correct for
`create(...)`; only the union *check* needs a `dep_types.hasUnion(bareName)` arm. Deferred — the
box path has proven regression-prone (see above), and `tc_check_test` won't pass regardless (other
errors + its `tc_infer` dep's D3 bug). See [[project_emit_compile_campaign]].

---

## BUG-191: `var`/`const` mutation scan guessed from the method NAME → spurious "never mutated" (D7 cluster) ✅ FIXED (2026-07-17)

The self-hosted mutation scan (`CgHelpers.scanMutations`) decided whether a local must be
emitted `var` by asking whether the *called method's name* was on `isReadOnlyMethod`'s
allow-list. Any method not on the list marked its receiver `var`. That is a name-based
over-approximation with no type information, and it rotted continuously: every read-only
stdlib method that was missing (`isDigit`/`isUpper`/`toLower` on `char`, `isObject`/`isArray`/
`isNull` on a JSON value, `before`/`after`/`equals` on `DateTime` — BUG-190) produced a
`var` on a value that is never mutated, which Zig 0.16 rejects with
`local variable is never mutated`. This was the D7 cluster in `docs/emit_compile_triage.md`
(`unicode_test`, `json_test`, `typechecker_test`, `file_io_test`, `gui_test`).

**The fix (type-driven, the real one — not another name added to the list):** thread the
`InferCtx` through `scanMutations`/`scanMutationsInto`/`scanMutationsInExpr` (mirroring the
`tc_opt` the Zig reference `src/CodeGen.zig` already threads) and, for a method-call receiver,
consult the receiver's **inferred type**. When the type is a value category that is passed by
value — primitives, `char`, `str`, `str_slice`, `json_value` — only an explicit in-place
mutator (`add`/`set`/`put*`/`append*`/`writeRow`/`clear`/`reverse`) forces `var`; every query,
predicate, or new-value builder leaves the receiver `const`, regardless of its name. Structs,
containers, cross-module and unknown receivers stay on the conservative name-based path, so the
change cannot introduce a spurious `var` (or, worse, a `const` on something actually mutated).
`isReadOnlyMethod` survives only as the no-type-info fallback (unit tests, pre-seed emission
paths); it no longer drives the primary decision and can shrink over time.

Result: `unicode_test` now compiles end-to-end (0 errors, was all `never mutated`); the
`never mutated` errors are eliminated for value-type receivers across `json_test`,
`typechecker_test`, and `file_io_test` (their remaining failures are other clusters).
Gates: round-trip byte-identical, smoke 236/236, compile_check 198/0/3 (no regression).

**Round 2 (2026-07-17, same commit series):** a corpus-wide `never mutated` scan found the
initial value-type bucket was both too coarse and too narrow:
- **`str` is fully immutable, not "small-mutating-list".** `greeting.reverse()` returns a *new*
  string, but `reverse` is on `isMutatingMethod`'s list (for List's in-place reverse), so a
  string receiver was wrongly marked `var` (`string_methods_test`). Split the value bucket into
  `isImmutableValueType` (primitives/char/str/str_slice → **never** `var`, mirroring the Zig
  reference's `obj_type == .string → false` special-case) and `isByValueHandleType`
  (json + network/db handles → small-mutating-list).
- **Stdlib handle types were missing.** `tcp_conn`/`ws_conn`/`udp_socket`/`sqlite_*`/`regex` are
  by-value handles whose methods emit `_xxx(handle, …)`; added them to `isByValueHandleType`.
- **Optional receivers weren't unwrapped.** `var conn = Tcp.connect(…)` infers as
  `optional(tcp_conn)`; the decision must peel `optional`/`ref_to` first (`unwrapForMutation`),
  the same unwrap `genMemberCall` does (BUG-188). `tcp_advanced_test` now compiles end-to-end.

After round 2, the `never mutated` class is gone corpus-wide for every value/handle receiver.

**Known residual (documented, not a struct-getter after all):** the only remaining `never mutated`
is `gui_test`, and it is NOT a struct receiver — `frame` is a **closure** (`var frame = def(g)…`)
passed by value to `Gui.run`; its `var` comes from closure lowering (the closure mutates a
captured var), not from `scanMutations` (`frame` is never a method-call receiver). A separate
closure-codegen fix, tracked in NEXT_STEPS; `gui_test` also fails on an unrelated
`GuiContext has no member 'run'`. No named-struct-getter `never mutated` case exists in the
corpus, so the per-method struct-mutation map is not currently needed. See
[[project_emit_compile_campaign]].

---

## BUG-190: DateTime completion round 2 — comparisons over-marked `var`, `toIso8601`/`format` shadowed, chains ✅ FIXED (2026-07-17)

Follow-on to BUG-189; together these make `datetime_test` fully compile AND run correctly.
Four distinct issues:

1. **Const/var (D7):** `var a = DateTime.of(…); a.before(b)` marked `a` as `var` → Zig
   "local variable is never mutated" (the comparison emits `a.epoch_ms < b.epoch_ms`, a read).
   `before`/`after`/`equals` were missing from `isReadOnlyMethod` (`selfhost/CgHelpers.zbr`) —
   added. (The mutation scan conservatively marks every method-call receiver `var` unless the
   method is on the read-only allow-list.)
2. **`toIso8601` not dispatched** (missed in BUG-189) → raw `.toIso8601()`. Added
   `_dt_to_iso8601(dt)` + registered it as string-returning in `isStringExpr` (so `print` uses
   `{s}`, not `{any}` — it was printing the ISO string as a byte array).
3. **`dt.format(fmt)` shadowed** by the string `.format` heuristic (emitted
   `std.fmt.allocPrint(_allocator, dt, …)` → "unable to resolve comptime value"). Added a
   DateTime-gated `format` → `_dt_format(dt, fmt)` handler that runs before the string heuristic.
4. **DateTime method chains** (`DateTime.of(…).addDays(10)`) mis-materialized to raw
   `_mc.addDays(…)` — the same BUG-079/185 misfire. Extended the BUG-185 guard to skip
   materialization for DateTime receivers too (`not isDateTimeExpr(chain.recv)`).

Verified: datetime_test compiles and runs with correct output (dates, ISO strings, formats,
comparisons). Gates: round-trip byte-identical, smoke 236/236, compile_check 198/0.

---

## BUG-189: DateTime instance methods not dispatched — `dt.toEpoch()/addDays()/before()/…` emit raw ✅ FIXED (2026-07-17)

**User-facing.** A batch of `DateTime` instance methods emitted a raw `.method()` call on the
`_DateTime` struct (which has only `epoch_ms`), so they failed to compile:
`toEpoch`, `addDays`/`addHours`/`addMinutes`/`addSeconds`/`addMonths`/`addYears`, `before`/`after`/
`equals`, `daysBetween`/`secondsBetween`, `inCalendar`. All are documented (QUICKSTART) and handled
by the bootstrap; the selfhost's `genMemberCall` simply lacked the dispatch — even though **all the
preamble helpers already existed** (`_dt_add_*`, `_dt_days_between`, `_dt_seconds_between`,
`_dt_in_calendar`). A pure dispatch gap.

**Fix (`selfhost/CodeGen.zbr`).** Added an `isDateTimeExpr(m.object)`-gated block (bootstrap parity,
src/CodeGen.zig ~8420-8520): arith → `_dt_add_X(obj, n)`; comparison → `obj.epoch_ms </>/== other.epoch_ms`
(other defaults to `_dt_now()`); interval → `_dt_{days,seconds}_between(obj, other)`; `inCalendar` →
`_dt_in_calendar(obj, cal)` (defaults to `Calendar.Gregorian`); `toEpoch` → `obj.epoch_ms` (ms, distinct
from `timestamp` = seconds). Gated on a DateTime receiver so common names (`before`/`equals`) don't
intercept user methods.

**Found via** the emit-compile sweep (D5). Cleared every DateTime-method error in `datetime_test`,
which now surfaces a separate **D7 `never mutated`** bug (const/var analysis — shared with
tcp_advanced). Gates: round-trip byte-identical, smoke 236/236.

---

## BUG-188: method on an optional/narrowed receiver doesn't dispatch — `conn.write()` on `?TcpConn` ✅ FIXED (2026-07-17)

**User-facing.** A method call on an optional-typed receiver (even after nil-narrowing) fell
through to a raw `.method()` instead of the type-specific dispatch:

```
var conn = Tcp.connect(host, port)   # ?TcpConn
if conn != nil
    conn.write(data)                 # → error: no member named 'write' in 'TcpConn'
```

`genMemberCall`'s main receiver-type branch computed `recv_t = inferExpr(m.object)` but did NOT
unwrap `optional`/`^T` before matching. `conn` infers to `optional(tcp_conn)` (Tcp.connect returns
`?TcpConn`), and nil-narrowing is codegen-only — it emits `conn.?` but doesn't change `inferExpr`.
So `on Type_.tcp_conn` never matched and the call emitted a raw `.write()`.

**Fix (`selfhost/CodeGen.zbr`).** Unwrap `optional`/`ref_to` from `recv_t` before the type branch,
so a method on a narrowed/checked optional (or a `^T`) dispatches on the underlying type. Narrowing
/ `!` already emits `conn.?`, so `_tcp_write(conn.?, …)` is value-correct. General fix for the D5
"method on optional receiver" sub-family. Cleared the `write`/`readLine`/`readBytes` dispatch in
`tcp_advanced_test` (which now surfaces a separate D7 `never mutated` bug).

Gates: round-trip byte-identical, smoke 236/236, compile_check 198/0 (broad dispatch change — no
regressions). Found via the emit-compile sweep (D5).

---

## BUG-186: `Http.get(url)` emits undeclared `Http` — HashMap `.get` heuristic shadows the namespace ✅ FIXED (2026-07-16)

**User-facing.** `Http.get(url)` / `Http.post(url, body)` emitted a raw `Http.get(...)` →
`error: use of undeclared identifier 'Http'`. The Http *client* API was implemented
(`genHttpCall` → `_http_get`/`_http_post`, both in the preamble) and dispatched at
`genMemberCall`'s namespace block — but the container **method-name heuristic** `if mname
== "get"` (for `HashMap.get`) runs *earlier* and caught `Http.get`, emitting it raw and
returning before the namespace dispatch. (`Http.post`/`serve` have no colliding heuristic.)

**Fix (`selfhost/CodeGen.zbr`).** Guard the `.get` heuristic with `not isNamespaceReceiver(m)`
so a stdlib-namespace receiver (`Http`, `Sqlite`, `Csv`, … — see `isStdlibNamespace`, 33 names)
falls through to the namespace dispatch. Verified: `Http.get`/`Http.post` now emit
`_http_get`/`_http_post` and compile clean.

**Principle:** a call on a stdlib-namespace ident must dispatch by namespace, not by a
container method-name heuristic. `.get` was the only current collision; the helper makes future
ones easy to guard (or move the namespace block ahead of the heuristics — a cleaner refactor).

**Found by** the full-corpus emit-compile sweep (`docs/emit_compile_triage.md`, D1). `http_test`/
`https_test` now surface a separate **nil-narrowing** bug (see BUG-187). Gates: round-trip
byte-identical, smoke 236/236.

---

## BUG-187: `if x != nil` now AUTO-NARROWS `x` (feature implemented) ✅ FIXED (2026-07-16, Sean chose to implement)

**Resolution: implemented auto-narrowing** (option 1). Inside `if x != nil`, a plain local `x`
that is not reassigned in the block is treated as non-optional — every value use emits `x.?`, so
`x.field` / `x.method()` / `x + 1` work directly (matching Kotlin/TS/Swift smart-casts, Eiffel
attachment patterns, and the `nil_narrowed` stub's original intent).

**Implementation (`selfhost/CodeGen.zbr`):** `genIf` narrows the then-block via an
`except`-derived Generator (scope-safe — never leaks out) when the condition is `<ident> != nil`
and the ident isn't reassigned in the block (the reassignment guard also makes it safe: a
narrowed var is never an assignment target). `genIdent` emits `x.?` for a narrowed local; the
`x!` (to_non_nil) emit is guarded so an explicit `x!` on an already-narrowed `x` stays single
(`x.?`, not `x.?.?`). QUICKSTART §11 updated. Cleared `http_test`, `https_test`.

**Deferred (fall back to explicit `x!`, documented):** `and`-chains, `== nil` else-branch,
non-local receivers (`if obj.field != nil`), reassignment invalidation. `tcp_advanced_test`
narrows correctly (`?TcpConn` → `TcpConn`) but then hits a SEPARATE bug — `TcpConn.write` isn't
dispatched on a proven `TcpConn` receiver (the BUG-182/sqlite family); see triage D5.

Gates: round-trip byte-identical, smoke 236/236, compile_check 198/0, runtime verified.

---

## (superseded) BUG-187 original characterization — DESIGN DECISION

**Finding (2026-07-16).** Several tests write `if x != nil` then access `x.field` / `x.method()`
directly:

```
var response = Http.get(url)      # ?HttpResponse
if response != nil
    print(response.status)         # → error: optional type '?HttpResponse' does not support field access
```

This is **not implemented in EITHER compiler** (verified: both emit raw `response.status`). And
**QUICKSTART §11 documents the current idiom as EXPLICIT unwrap:** `if x != nil: print(x!)`, or the
unwrap-binding `if x as n: …`. So by the current documented design, the failing tests are simply
written wrong — `response!.status` compiles clean (verified).

**But** it is likely an *intended-yet-unfinished* feature: `CodeGen.zbr` has a `nil_narrowed:
StrSet?` field ("variables narrowed to non-nil in current scope") that is **declared and
initialized but never populated or consumed** — a scaffold for auto-narrowing that was never
wired. Auto-narrowing (Kotlin/TS/Swift smart-casts; Eiffel Certified-Attachment-Patterns) fits
Zebra's "safe by default" + Eiffel lineage, and several tests assume it.

**Two resolutions — Sean's call (language design):**
1. **Implement auto-narrowing** — finish the stub: in `if x != nil` (and `x == nil` else-branch,
   `and`-chains, etc.) narrow `x` to non-optional within the guarded scope; invalidate on
   reassignment. A real feature in BOTH compilers, with real edge cases (scoping, reassignment,
   nested/`orelse`). Ergonomic + safety win; matches the stub's intent.
2. **Keep explicit `!`** (current documented design) — fix the tests to use `x!` (`response!.status`).
   Small; clears the emit-triage cluster (`http_test`, `https_test`, `tcp_advanced_test`) as
   test-code corrections. Optionally remove the dead `nil_narrowed` stub.

Affects `http_test`, `https_test`, `tcp_advanced_test` (the "nil-narrowing" cluster in
`docs/emit_compile_triage.md`). These are TEST bugs under design (2), or feature-blocked under (1).

---

## BUG-185: chained string methods miscompile — `s.concat(a).concat(b)` emits `_mc.concat(...)` ✅ FIXED (2026-07-16)

**User-facing.** A chained string method (e.g. `clist.at(i).concat(a).concat(b)`) miscompiled:
the BUG-079 auto-hoist (which materializes a method chain's receiver into a `var _mc_N = …`
temp for struct temporaries needing a stable address) misfired on the string chain, emitting:

```
var _mc_1 = (std.mem.concat(...) catch unreachable);          // _mc_1 : []u8
const tri: []const u8 = _mc_1.concat(clist.items[i+2]);        // → error: no field or member function named 'concat' in '[]u8'
```

String methods emit a **by-value special form** (`std.mem.concat(recv, …)`), never
`recv.method()`, so a materialized `_mc_N.concat(…)` is invalid Zig.

**Fix (`selfhost/CodeGen.zbr`).** Skip materialization when the chain's receiver is a string
(`not isStringExpr(chain.recv)`) — `genExpr` handles the nested string chain directly, emitting
`std.mem.concat(std.mem.concat(a, b), c)`. Applied to the var-init and assignment paths; the
return path already guarded on `recv_t is Type_.named` (structs only), so it was safe. Materialization
(BUG-079) is only needed for struct temporaries; string slices pass by value.

**Found by** the full-corpus emit-compile sweep (`docs/emit_compile_triage.md`, cluster D5). Cleared
`fuzzy_match` outright; `fuzzy_selfhost`'s concat error is gone (it now surfaces a separate D3
HashMap `.len` bug). Gates: round-trip byte-identical, smoke 236/236.

---

## BUG-184: preamble `_zebra_list_reduce` parameter `init` shadows a user top-level `init` ✅ FIXED (2026-07-16)

**User-facing.** The runtime preamble helper `_zebra_list_reduce` (emitted into every program
that uses `List.reduce`) had a parameter named `init`. Any program that ALSO emits a top-level
`pub fn init` — e.g. an MVU/GUI model's `init()` returning the Model — hit a Zig error:

```
selfhost/stdlib_preamble.zig-derived line: fn _zebra_list_reduce(comptime T: type, init: anytype, ...)
→ error: function parameter shadows declaration of 'init'
```

Zig forbids a function parameter shadowing a file-scope declaration. `reduce` + a top-level
`init` is a natural combination (the functional trio is common; `init` is the canonical MVU
model constructor), so this bit the GUI examples.

**Fix (`selfhost/stdlib_preamble.zig`).** Renamed the parameter `init` → `init_val` (signature,
return-type `@TypeOf`, and body). Cleared 3 GUI examples outright (`counter`, `hbox_smoke`,
`file_dialog_smoke`); the class is fixed for any `reduce` + top-level-`init` program.

**Found by** the full-corpus emit-compile sweep (`docs/emit_compile_triage.md`, cluster C).
Gates: round-trip byte-identical, smoke 236/236. The other 3 GUI files in cluster C were failing
on this shadow FIRST and now surface distinct next-layer bugs (nested `g` param shadow;
`^T`-box `*T`-vs-`*const T`; a `frame` const-shadow) — reclassified in the triage.

---

## BUG-183: single-quoted string literals with embedded `"` emit unescaped Zig (syntax error) ✅ FIXED in selfhost (2026-07-16); selfhost-only (bootstrap was correct)

**User-facing.** A single-quoted Zebra string containing a literal `"` (natural for JSON,
HTML, etc.) emitted an unescaped `"` into the Zig double-quoted string, producing a **syntax
error** in the generated Zig:

```
var json = '{"name": "Alice"}'
```
→ emitted `const json: []const u8 = "{"name": "Alice"}";`  (the Zig string ends at `"{"` → `error: expected ';' after statement`)

**Root cause.** `StringKind` collapses single- and double-quoted literals to `plain`, and the
selfhost AST drops the quote delimiter — so `genStringLit`'s plain path could not tell them
apart and emitted `sl.text` raw. Double-quoted strings store `"` pre-escaped as `\"` (fine);
single-quoted strings carry a literal `"` (broken). The **bootstrap was correct** — it preserves
the delimiter (`src/CodeGen.zig` ~16418) and escapes single-quoted content; this was a selfhost
divergence.

**Fix (`selfhost/CodeGen.zbr`, `escapePlainStr`).** Escape IDEMPOTENTLY without the delimiter:
split on the already-escaped `\"` (protecting them), escape any bare `"` in each segment, rejoin.
Double-quoted text (all `\"`) passes through unchanged; single-quoted literal `"` gets escaped.
Verified: `'{"name": "Alice"}'` now emits `"{\"name\": \"Alice\"}"`, compiles, and runs correctly;
`"normal with \"escaped\""` is unchanged.

**Found by** the full-corpus emit-compile sweep (`docs/emit_compile_triage.md`, cluster D2).
`json_test` still fails on a *separate* bug (D7 `local variable is never mutated` — const/var
mutation analysis), tracked in the triage.

---

## BUG-182: random access into a query result miscompiles — `db.query(...).at(i)` yields an untyped row ✅ FIXED in selfhost (2026-07-16); bootstrap divergence documented

**User-facing.** `db.query(sql)` returns a materialized, random-accessible row list, but
indexing it with `.at(i)` produced a result whose type was **not** inferred as `sqlite_row`,
so a method on that result miscompiled:

```
var rows = d.query("SELECT id, name FROM t")
var r = rows.at(1)          # skip row 0, read row 1 — a real use case
print(r.asInt("id"))        # ERROR: no field or member function named 'asInt' in '_SqliteRow'
```

`asInt`/`asStr`/`asFloat` are special codegen dispatch (emit `_SqliteRow.int_`/`.str_`),
triggered only when the receiver is *typed* `sqlite_row`. Only `for row in rows` worked,
because that path seeds the row type into `infer_ctx`; random access did not. The StrSet-class
bug (a method whose result loses its type → downstream dispatch breaks), found by sweeping the
dedicated-`Type_`-variant call-handler arms rather than the test corpus.

**Why no gate caught it:** round-trip diffs the selfhost against itself (self-consistency,
blind to this); smoke only `--emit-zig`s (blind to compile-failures); no test exercised `.at()`
on a query result. `compile_check.sh` (the independent witness) is what confirmed it.

**Fix (selfhost, `selfhost/TypeChecker.zbr`):** added a `Type_.sqlite_row_list` arm to the
`inferExpr` call handler — `at` → `sqlite_row`, `count`/`len` → int. Verified: a probe that
miscompiled now compiles + emits `rows.items[i]` → `r.int_(...)`. Regression guard added to
`test/sqlite_test.zbr` (random-access section, so `compile_check` covers it).

**Bootstrap divergence (documented, acceptable):** the bootstrap (`src/TypeChecker.zig`) has no
`sqlite_row_list` type — it types `query` as `.unknown` (line ~4072) and relies entirely on
for-in's separate element inference, so it still miscompiles `rows.at(i).asInt(...)`. Fixing it
means adding a type variant or threading query-provenance into method-return inference — a
larger change to a phasing-out compiler. Selfhost-ahead is the acceptable direction (the primary
`zebra.exe` is fixed; the bootstrap is `--zig-backend` escape-hatch only; regen authority is
untouched — the selfhost compiler source uses no sqlite). Close by adding a `sqlite_row_list`
type to the bootstrap if it is kept longer.

---

## BUG-181: selfhost `zebra.exe` cannot self-compile `selfhost/main.zbr` — RESOLVED 2026-07-22

**RESOLVED.** `zebra.exe` cleanly self-compiles its own driver: `--emit-zig` returns 0 and
the emitted `main.zig` passes `zig build-exe` (semantic analysis) with zero errors. Gated by
`tools/selfcompile_check.sh`. Eight emit divergences fixed across commits `43673d6`,
`fc9d322`, `eee950e`, `e8a0652`, `7cfeb84`.

**Dominant pattern (most of the 8): name-based type detection ignoring the proven type.** The
selfhost guessed List/HashMap/StrSet from an identifier NAME via reverse-index heuristics
(`fieldIsList`/`isKnownListField`/`fieldIsStrSet`) that false-positive when a param/local NAME
shadows such a field elsewhere; the bootstrap uses the TypeChecker type and gates its List
fallback on `obj_tc == .unknown`. Convergent fix: trust inference when it proves a type; fall
to the name heuristics only when the type is genuinely unknown.
- `StrSet.len`→`.items.len`: gated on `typeIsUnknown(receiver)`, restricted to BARE IDENT
  receivers (a member access `obj.field` keeps the heuristic — `fieldIsList("values")` on
  `c.values` is authoritative; a first cut regressed that, fixed in `fc9d322`).
- `StrSet.contains_`→`.contains`: nil-narrowed `StrSet?` via `if x as nn`. ROOT: the `if x as
  n` optional-unwrap never bound the capture's type into infer_ctx; fixed by binding it.
- `.len`/`.count` assignment TARGET emitted the read-form `@as(i64,@intCast(x.len)) = …`;
  genAssign now emits a plain `obj.len = v` field store.
- `int.toString()`/`Value.getObj()` on a method-chain temp emitted the terminal call RAW; new
  `isValueTypeExpr` skips BUG-079 materialization for value/json receivers.
- `str.indexOf` emitted `?i64`; converged to the bootstrap's `i64` with `-1` not-found.
- `stripStringQuotes` (AstBuilder) dropped an interp start-segment's trailing content when it
  had an escaped quote (`"a\"b`→`a\`, `\{` invalid escape); rewrote to strip without splitting.

Each fix gated (`compile_check` 200/0/1 + byte-identical round-trip). Historical detail below.

<details><summary>Original 2026-07-21 progress note (2-of-6 snapshot)</summary>

**Progress (2026-07-21, commit `43673d6`): 2 emit divergences fixed.** Both were
name-based container detection ignoring the receiver's proven type (the general pattern:
the selfhost guesses List/HashMap/StrSet from an identifier NAME via reverse-index
heuristics that false-positive; the bootstrap uses the TypeChecker type and gates its
List fallback on `obj_tc == .unknown`). The convergent fix is to trust inference when it
proves a type and only fall to the name heuristics when the type is genuinely unknown.
- ✅ `StrSet.len` → `.items.len`: `out.len` on a `StrSet` param (name `out` collided with
  a List field elsewhere). Gated the name heuristics on `typeIsUnknown(receiver)`.
- ✅ `StrSet.contains_` → `.contains`: a nil-narrowed `StrSet?` via `if x as nn` dropped
  the `_`. Root cause: the `if x as n` optional-unwrap never bound the capture's type into
  infer_ctx (so `nn` was `unknown`). Fixed by binding the unwrapped capture to the
  optional's inner type — a broad fix (every `if x as n`), verified 200/0 + round-trip.

**Cross-check with single-file (Phase 2):** the combined `selfhost/main.zig` produced by
`zebra.exe --single-file selfhost/main.zbr` has the EXACT SAME emit-bug set as the
multi-file self-build (zero single-file-specific errors), so single-file emission is ready
for the endgame the moment BUG-181 clears — it is not itself a blocker.

**Remaining divergences (from a fresh self-compile, before Zig's early-stop hides more):**
- `int.toString()` on a method-chain temp: `var _mc = self.w.nextUid(); _mc.toString()` —
  the materialization temp's int type isn't tracked, so `.toString()` isn't lowered to the
  int→string helper. (2 sites.) Likely fix: bind the chain-temp's type (the call's return
  type) into infer_ctx at materialization.
- `invalid escape character: '{'` (an emitted string literal — genString/interp escaping).
- `Value.getObj` on `json.dynamic.Value` (stdlib API name mismatch).
- `invalid left-hand side to assignment` (a `.len` **lvalue** — an assignment TARGET
  wrapped in the read-side `@as(i64,@intCast(x.len))` form; see the older note below).

Fix the remaining, re-emit (more errors likely surface behind Zig's early-stop), then add a
gate that self-compiles `main.zbr`. Historical detail below.

### Earlier analysis (2026-07-16) — slowness fixed, original 3-bug snapshot

The self-hosted `zebra.exe` cannot compile its own entry file `selfhost/main.zbr`.
Smaller selfhost modules (`CodeGen.zbr`, `TypeChecker.zbr`, `CgHelpers.zbr`, …)
compile fine.

**History / correction (2026-07-16).** Originally filed as a >300s *timeout*. That
slowness was real (confirmed on the pre-session tree: >120s), NOT contention — an
earlier in-session doubt about contention was itself mistaken. **§28a step-2 inference
fixes (commits 5c78c17 / 9204a0b / 04231dc) incidentally cut it from >120s to ~6s** —
the pre-session compiler's weak inference (unresolved `.len`/`.items()`/dep types)
caused pathological repeated-inference cost; resolving those types made the compile
fast. So the timing symptom is fixed as a side effect.

**Current blocker: pre-existing selfhost EMIT bugs**, previously hidden behind the
slowness (the compile never reached emit). Now `main.zbr` self-compiles in ~6s and
fails Zig compilation with (at least):
1. `TypeChecker.zbr:64` (`TupleType_` ctor `len = elems.items.len`) → emits
   `@as(i64, @intCast(_self.len)) = …` — a `.len` **lvalue** wrongly wrapped in the
   read-side `@intCast`. The len-member codegen (`CodeGen.zbr` ~8309) applies the
   `@as(i64,@intCast(x.len))` read form even when `x.len` is an assignment TARGET.
2. `CodeGen.zig:17173` → `invalid escape character: '{'` (an emitted string literal).
3. `main.zbr:1464` → `local variable is never mutated` (const/var mutation analysis).
None are §28a inference-guesses; all are in the emit path (untouched by §28a). They
are latent selfhost codegen gaps, not regressions.

**Why unnoticed.** No gate self-compiles `main.zbr`. The `.zbr → .zig` regen
(`tools/bootstrap_check.sh`, `zig build update-selfhost`) is performed by the
**bootstrap** (`zebra-bootstrap.exe` — regen authority), which compiles `main.zbr` in
seconds. `tools/selfhost_smoke.sh` runs `zebra.exe --emit-zig` only on small fixtures.

**Impact.** (a) The selfhost cannot yet compile its own driver — a gap on the road to
Zig-only-in-special-cases. (b) §28a validation on `main.zbr` requires clearing these
emit bugs first.

**Next.** Fix the three emit bugs (start with the `.len`-lvalue: the assignment
codegen should emit a plain field store for a `.len` TARGET, not the `@intCast` read
form). Then add a gate that self-compiles `main.zbr` so it stays working.

---

## BUG-180: bootstrap does not fill omitted constructor defaults on emit ⚠️ OPEN (bootstrap-only; selfhost correct)

`zebra-bootstrap.exe --emit-zig` drops omitted defaulted constructor arguments
instead of substituting their defaults, producing an under-argumented Zig call.
The self-hosted `zebra.exe` handles it correctly, so this is a bootstrap-only
emit gap (selfhost-ahead).

**Repro.** A struct with defaulted ctor params:

```
struct Vector3
    cue init(x: float = 0.0, y: float = 0.0, z: float = 0.0)
        ...
```

- `Vector3()`            → bootstrap emits `Vector3.init()`            (0 args)
- `Vector3(x: 0.0, z: 3.0)` → bootstrap emits `Vector3.init(0.0, 3.0)` (2 args)

Both fail Zig 0.16 with `error: expected 3 argument(s), found N`. Selfhost emits
`Vector3.init(0.0, 0.0, 0.0)` / `Vector3.init(0.0, 0.0, 3.0)` — correct.

**Impact.** Surfaced building the GameEngine boss-move layer (`zbra/boss_move.zbr`),
which constructs `Vector3` with omitted defaults. Because the committed engine
`.zig` are regenerated by the bootstrap (regen authority), the round-trip breaks
for any `.zbr` that relies on ctor defaults. Worked around in that repo by
spelling every ctor argument out; the fix belongs in bootstrap's call-emit
(fill omitted params from the callee's declared defaults, as selfhost does).

**Where to look.** Bootstrap call-argument emit (positional/named lowering in
`src/CodeGen.zig` / arg resolution) — the default-substitution step selfhost
already performs and bootstrap skips.

---

## Mosaic POC dogfood (2026-07-14)

A separate Claude session port-tested Zebra on a real differential task (a Greek-NT
intertextual/statistical computation, Python oracle vs Zebra product, byte-identical
output). Its ledger: `C:\Projects\mosaic\docs\ZEBRA_FINDINGS.md` (8 findings, logged
against "0.1.0 Phase 22"). Re-verified against HEAD on 2026-07-14:

- **Already fixed since Phase 22:** escape sequences in interpolation (`\t`);
  indexed `List(str)`/`List(float)` corruption for locals **and** struct fields
  (both emit correct `.items[i]` with `{s}`/`{d}`); the ternary-truncation symptom.
- **Not bugs:** numeric conversions (`toString`/`toFloat`/`toInt` all work and are
  correctly documented — the POC guessed `toStr`, which isn't the API); tolerant-zero
  `toInt` on CRLF (data hygiene); print→stderr (known fast-backend quirk).
- **Live → filed below:** BUG-175 (fixed here), BUG-176, BUG-177, BUG-178.

---

## BUG-175: `zebra.exe` panics `File.read error` when run outside the repo dir ✅ FIXED (2026-07-14)

**Severity:** high — a shipped compiler that only runs inside its own source tree
is a 0.9 ("ready for others") adoption blocker. Surfaced by the Mosaic POC (finding
#1).

**Symptom:** the selfhost `zebra.exe` panics `File.read error` (after "resolved OK")
on ANY program — hello world included — when the cwd is not the repo root. The
**bootstrap** works anywhere.

**Root:** the selfhost reads the stdlib preamble at codegen time via
`File.read("selfhost/stdlib_preamble.zig")` — a **cwd-relative** path
(`main.zbr`). The bootstrap **embeds** the preamble at build time
(`build_options.stdlib_preamble_pre_gui/post_gui`), so it needs no runtime file.
This was both a usability bug and a self-hosting equivalence gap (the bootstrap ran
anywhere; the selfhost did not).

**Fix:** resolve the preamble repo-relative first (keeps every gate — all run from
the repo root — byte-identical), then fall back to a copy installed alongside the
exe. Mirrors the existing sqlite3.c exe-dir pattern (`sys.selfExe()` +
`Path.dirname()`, `main.zbr:2189`). `build.zig` now installs
`selfhost/stdlib_preamble.zig` → `bin/stdlib_preamble.zig` next to `zebra.exe`.
Verified: runs from the repo root, from `scratchpad/`, and from `C:\tmp`; full
round-trip byte-identical; smoke 233/233. Selfhost-only convergence (bootstrap
already embeds).

---

## BUG-176: inferred `split()`/`lines()` now materializes to an indexable `List(str)` ✅ FIXED (2026-07-14)

**Severity:** medium — documented as `List(str)` (QUICKSTART) but not indexable in
the common inferred form. Surfaced by the Mosaic POC (finding #2).

**Symptom (was):** `s.split(sep)` lowers to `std.mem.splitSequence` (a lazy
iterator). `for x in s.split(sep)` worked; `var cols = s.split(sep)` then `cols[0]`
failed to compile (`SplitIterator does not support indexing`). Materialization into
a `List(str)` happened **only** when the target was explicitly annotated
`var cols: List(str) = s.split(sep)` (the BUG-092 path).

**Fix (both compilers):** when a var's init is a `split`/`lines` call with **no
annotation**, materialize the iterator into a `List(str)` — the inferred/indexed
case now behaves like the annotated one. `for x in s.split()` stays lazy (it's an
inline split, not a var initializer, and is intercepted in the for-loop codegen).
- **Selfhost** (`CodeGen.zbr` genLocalVar): a self-contained branch emits the
  `std.ArrayList([]const u8)` materialization and binds the local as `list_(string_)`.
- **Bootstrap** (`src/CodeGen.zig` genLocalVar): synthesizes a `List(str)` `type_` so
  the existing annotated materialization + `objIsList` (→ `.items`) treat it as a
  List. Idempotent, codegen-last-pass.

**Also fixed the POC's #6 on the bootstrap side (prerequisite):** indexing a
`List(str)` in interpolation emitted `{any}` (byte-array output) — and `.lines()`
elements emitted `{u}` (char, a compile error) — because the bootstrap TC didn't type
`str_slice[i]` as string and miscategorised `lines` as returning `.string`. Fixed in
`src/TypeChecker.zig`: `index` typing gained a `.str_slice → .string` arm, and
`split`/`lines` now consistently type as `.str_slice` (moved `lines` out of the
returns-`.string` set). (`#6` was only ever verified fixed on the selfhost before.)

**Verified:** the full split/lines battery (index / `.len` / `.at` / for-in /
annotated) produces **byte-identical output on both compilers**; `tools/dogfood`
`split_inferred` flipped SHARED-GAP → clean with no new divergences; full round-trip
byte-identical; smoke 233/233; fuzzer 0-99 clean. Regression:
`test/bug176_split_list_test.zbr`.

**Not covered (rare, documented):** `s.split(sep)[i]` indexed *directly* without an
intermediate var (a call-result index) — the BUG-177 family; bind to a var first.

---

## BUG-177: bracket-index on a non-name base omits `.items` ✅ FIXED on the selfhost (2026-07-14); bootstrap selfhost-ahead for `x[i][j]`

**Severity:** low — narrow; trivial workaround (bind the call to a var first).
Surfaced while reducing Mosaic finding #6.

**Symptom:** indexing the direct result of a `List`-returning call —
`makeFloats()[1]` — emits `makeFloats()[i]` instead of `makeFloats().items[i]`, so
Zig rejects it (`array_list.Aligned does not support indexing`). Local-var and
struct-field list indexing both correctly emit `.items[i]`. The index-lowering only
inserts `.items` for a base it recognizes as a list local/field (name-keyed via
`fieldAwareIsList(name)`), not for a raw call expression.

**Related manifestation — nested bracket index `x[i][j]` (SHARED, both fail).**
The dogfood sweep (2026-07-14) found that chaining bracket indexes — `grid[0][1]`
where `grid: List(List(int))` — misses `.items` on the *inner* result and is
rejected by **both** compilers (`array_list.Aligned does not support indexing`).
`grid.at(0).at(1)` works on both. Same root as the call-result case: the index-read
`.items` insertion is name-keyed (`fieldAwareIsList(name)`), so any non-name base —
a call result *or* an index result — is missed. The two cases differ only in
bootstrap coverage: it handles the call-result base but not the nested-index base.

**FIXED for `f()[i]` (2026-07-14, selfhost convergence):** the call-result case was a
**selfhost-only divergence** (the bootstrap already emitted
`makeFloats().items[@intCast(1)]`). Fixed in `selfhost/CodeGen.zbr`'s index-read: when
the base is a non-name expression, if it's an `Expr.call` whose inferred type is
`list_`, emit `.items`. Now byte-identical on both compilers (verified via
`tools/dogfood/`). Regression `test/bug177_178_index_tostring_test.zbr`.

**`x[i][j]` (nested index base) — FIXED on the selfhost (2026-07-14); bootstrap is
selfhost-ahead.** The selfhost index-read now emits `.items` for *any* non-name base
whose inferred type is a list (via `inferExpr`), so `x[i][j]` — and arbitrary depth
`x[i][j][k]` — work on the **primary** compiler. The **bootstrap still fails** it: its
TC lacks a real typed-List representation (it limps via `{any}` + `str_slice`
special-cases and has no general `List(T)[i]→T` element typing), so bringing it to
parity would be a major TC refactor of a phasing-out compiler. Per the drop-bootstrap
policy ([[feedback_drop_bootstrap_parity_ok]]) this is left **selfhost-ahead** and
tracked under BUG-179; `.at(i).at(j)` remains the bootstrap-compatible idiom. The
selfhost source uses `.at()`, so the round-trip / `--update` are unaffected.

---

## BUG-178: `str.toString()` emitted `{}` (no specifier) — now identity ✅ FIXED (2026-07-14)

**Severity:** low — an identity call you'd rarely write directly, but a hazard for
generic `@derive`/interface code that calls `.toString()` on a value that happens to
be a `str`. Surfaced verifying the numeric-conversion matrix (Mosaic finding #3).

**Symptom (was):** `var s = "hi"; s.toString()` emitted `std.fmt.allocPrint("{}", .{s})`
— a bare `{}` on a `[]const u8`, which Zig rejects (`cannot format slice without a
specifier`). `toString()` on int/float/bool worked. Failed identically on **both**
compilers (shared bug, no reference to converge to).

**Fix:** `str.toString()` is an **identity** — the receiver is already a string — so
emit the receiver directly (no `allocPrint`). Both compilers: `src/CodeGen.zig` (a
`.string` arm in the toString method codegen) and `selfhost/CodeGen.zbr` (the
str-method dispatch's toString arm). Verified byte-identical (`s.toString()`,
`(5).toString()`, `true.toString()` all agree); regression
`test/bug177_178_index_tostring_test.zbr`.

---

## BUG-179: selfhost-ahead constructs the bootstrap rejects — WON'T-FIX on bootstrap (drop-parity), latent `--update` traps ✅ RESOLVED-AS-DOCUMENTED (2026-07-14)

**Severity:** low — harmless for users (the selfhost is the primary compiler), but a
latent trap for **compiler source**: `--update` regenerates `selfhost/*.zig` via the
**bootstrap**, so any selfhost `.zbr` that uses a selfhost-only construct would fail
to regen. Surfaced by the differential dogfood sweep (`tools/dogfood/`, 2026-07-14).

**Decision (2026-07-14): these are deliberately left selfhost-ahead — the bootstrap
will NOT be brought to parity.** They all trace to the bootstrap TC lacking a real
typed-List representation (it limps via `{any}` + `str_slice` special-cases), so
fixing them is a major TC refactor of a phasing-out compiler. Per the drop-bootstrap
policy ([[feedback_drop_bootstrap_parity_ok]]), that investment isn't warranted; the
selfhost (primary) handles all of them. The hard constraint holds: none appear in
`selfhost/*.zbr`, so the round-trip / `--update` stay green.

**Known selfhost-ahead constructs (bootstrap rejects, selfhost accepts):**
- **`expr.len.toFloat()`** — the bootstrap TC types `List.len` as unknown (not
  `.int`), so `.toFloat()` doesn't dispatch to the numeric lowering and `zig` rejects
  the literal `.toFloat()` call. NB `expr.len.toString()` works on **both** (used in
  selfhost source) — the gap is `toFloat` specifically.
- **`var (a, b) = call()`** — positional destructure of a tuple-returning call; the
  bootstrap TC rejects it (`expected 'tuple'`).
- **`x[i][j]` / deeper nested bracket index** — the selfhost emits `.items` for any
  list-typed non-name base; the bootstrap lacks general `List(T)[i]→T` typing. See
  BUG-177.

**Standing caution for compiler source:** if you add any of these to `selfhost/*.zbr`,
`--update` will break with a bootstrap emit/compile error. Hoist to a plain `int`
local (`var n = x.len; var f = n.toFloat()`), use `.0`/`.1` tuple field access, and
`.at(i).at(j)` for nested indexing.

**Also observed (by design, not a bug):** `int * float` mixed arithmetic is rejected
(no implicit promotion — use `.toFloat()`), but the two compilers fail *differently*
— the bootstrap rejects cleanly at TC, the selfhost emits invalid Zig. Minor
selfhost robustness gap: it should reject mixed-numeric arithmetic at TC like the
bootstrap rather than emit un-compilable output.

---

## BUG-174: `str.indexOf` signature divergence ✅ RESOLVED (verified closed 2026-07-28)

**RESOLVED — verified 2026-07-28.** The three-way inconsistency below is gone; the
design call was effectively made (BUG-181 aligned the selfhost) and the docs were
updated, but the ticket was never closed. It has been sitting in the pre-1.0
blocker list as an open decision that no longer needs deciding.

The convention that actually shipped is **mixed, and consistent everywhere**:

| method | returns | not-found |
|---|---|---|
| `indexOf(sub)` | `int` | `-1` |
| `lastIndexOf(sub)` | `int` | `-1` |
| `indexOfFrom(sub, from)` | `int?` | `nil` |
| `indexOfIgnoreCase(sub)` | `int?` | `nil` |

That split is defensible rather than accidental: the plain forms are used in
arithmetic (`indexOf(x) + 1`), which an optional makes painful — the note at
`CodeGen.zbr` records exactly that as the reason BUG-181 moved the selfhost to the
sentinel. The offset/case-insensitive forms are not used that way and keep `int?`.

Verified by running the same program through BOTH compilers:

    indexOf hit=1  miss=-1  (negative-on-miss branch taken)   — identical
    lastIndexOf 4                                              — identical
    indexOfFrom("b", 2) -> 4 via `f!`                           — identical
    indexOfIgnoreCase("B") -> 1 via `ic!`                       — identical

QUICKSTART:1085 now documents `(str): int` / "`-1` if not found", matching. The
`test/stdlib_str_test.zbr` comment that once contradicted the docs is now correct.

Historical detail below is kept for the record.

**Severity:** medium (equivalence divergence on a documented stdlib method; the
selfhost additionally emits invalid Zig). Surfaced 2026-07-12 hand-testing the
string-method surface before adding it to the fuzzer.

**Three-way inconsistency:**
- **QUICKSTART** (lines 972, 1038-1041) documents `indexOf`/`lastIndexOf`/
  `indexOfFrom`/`indexOfIgnoreCase` as returning **`int?`** ("nil if not found").
- **Selfhost** TC agrees (`TypeChecker.zbr:1275` → `optional(int_)`), BUT its
  codegen is **broken**: `CodeGen.zbr:10345` (and `:11259`) emits
  `blk: { … break :blk if (_idx) |_i| @as(i64, @intCast(_i)) else null; }` — Zig
  fixes the block type to `i64` from the first branch, so `else null` fails with
  `expected type 'i64', found '@TypeOf(null)'`. So even the *documented* usage
  (`var x: int? = s.indexOf(y)`) doesn't compile on the selfhost.
- **Bootstrap** contradicts the docs: types it as **`int`** and emits
  `(if (std.mem.indexOf(...)) |_i| @as(i64, @intCast(_i)) else @as(i64, -1))`
  (−1 sentinel) — self-consistent, compiles, runs.
- A **test comment** (`test/stdlib_str_test.zbr:19`) says "returns -1 when not
  found", contradicting QUICKSTART — so the spec itself is ambiguous.

**Resolution is a DESIGN CALL (deferred to Sean).** Two clean options:
1. **Commit to `int?` per QUICKSTART** (recommended — matches the docs + the
   language's nil-tracking ethos): fix selfhost codegen to emit a valid `?i64`
   (`@as(?i64, @as(i64, @intCast(_i)))` in the found branch, `null` else); change
   bootstrap TC (indexOf/lastIndexOf → optional int) + codegen (`else null`);
   update the stdlib_str_test comment + any `== -1` assertions. Covers the whole
   indexOf family.
2. **Change to `int` (−1)**: update QUICKSTART + selfhost TC/codegen to match the
   bootstrap. Simpler but less idiomatic.

Until resolved, the `indexOf` family is **excluded from the fuzzer's string-method
cap** (it would generate divergent programs). Other string methods (upper/lower/
trim/trimLeft/trimRight/replace/contains/startsWith/len) verified equivalent.

---

## BUG-173: selfhost string-literal-vs-slice coercion — emit divergence ✅ FIXED (2026-07-13)

**Severity:** medium (selfhost emitted invalid Zig where bootstrap was correct — a
real equivalence bug). Surfaced 2026-07-12 by the fuzzer (fuzz finding **F12**).

**Symptom:** on some programs, the **selfhost** emitted Zig that `zig` rejected with
`expected type '*const [N:0]u8', found '[]const u8'` (or the reverse `[1:0]u8`
cannot cast into `[2:0]u8`) — a fixed-size string-literal array type where a slice
was needed. The **bootstrap** emitted code `zig` accepts. Verdict `zig-diverge-B`
(selfhost side). Reproducers: `fuzz/findings/seed{80,83,89}_zig-diverge-B.zbr`.

**Root (confirmed, NOT the suspected union/struct path):** `genLocalVar` in the
selfhost annotated an untyped local from its initializer *only for INT/FLOAT
literal shapes* (`int_lit`/`float_lit`/neg-unary). Its non-literal fallback
covered only `int_`/`float_` from the TC-inferred type. A **string-typed
non-literal init** — a ternary (`var v7 = if(c, "ggbb", " d")`), a concat, or a
`str`-returning call — therefore fell through with **no annotation**, so Zig
inferred `*const [N:0]u8` from the initializer literal. A later assignment of a
different-length string literal (`v7 = "f"`) then failed to unify. The bootstrap
annotates `var v7: []const u8 = …` via `tcTypeAnnotation` (src/CodeGen.zig
`genLocalVar`).

**Fix:** ported the bootstrap's `tcTypeAnnotation` helper into
`selfhost/CodeGen.zbr` (maps a `Type_` → Zig annotation: int/uint/float/bool/
char/**string**/str_slice/void/sized-numerics/optional-recurse; `""` for
named/generic/stdlib where Zig infers correctly) and replaced the `int_`/`float_`-
only fallback in `genLocalVar` with a call to it. This closes the `string_` gap
that was BUG-173 and pre-emptively the sibling gaps (`uint_`/`char_`/`str_slice`/
`optional`). Verified: all three reproducers compile; fuzzer oracle `ok` on seeds
80/83/89; smoke 233/233; full round-trip byte-identical. Regression:
`test/bug173_string_coerce_test.zbr` (ternary / concat / call string inits +
reassignment).

**Why the earlier hypotheses missed it:** F12's ruled-out probes (string `==`
ternary; string var-lit → reassign) both happen to take literal-shape paths or
same-length reassignment, so neither hit the non-literal-init + different-length
combination that is the real trigger.

---

## BUG-172: `char`/`uint` as a generic type argument — resolver gap ✅ FIXED (2026-07-12)

**Severity:** low-medium (bootstrap/selfhost divergence; narrow trigger).
Surfaced 2026-07-10 building the LSP hover/definition (`var chars: List(char) =
List(char)()` in main.zbr).

**Symptom:** `List(char)()` (constructing a `List` of `char`) fails the level-2
selfhost (`selfhost-A`, built from the running compiler's own emit) with
`error: undefined name: 'char'` at the constructor's type argument — while the
running `zebra.exe` compiles and runs the same code fine. So it breaks the
round-trip (selfhost-A can't re-emit a source that uses it), even though the
feature works at runtime. `char` as a param/return type (`def peek(): char`) and
in comparisons works everywhere; only `char` as a **generic type argument in a
constructor** trips it.

**Root (suspected):** the selfhost resolver/codegen doesn't register `char`
(kw_char) as a resolvable type name in the generic-constructor argument position,
so a compiler built from the selfhost's own emit rejects it. Likely a missing
builtin-type case in the generic-arg resolution path (parallels how `int`/`str`
are handled). Needs a minimal repro + a resolver/codegen arm for `char` (and
probably `bool`/`float`) as generic args.

**Fix (2026-07-12):** the real root was narrower and the *opposite* asymmetry from
the note above — the **selfhost** resolver rejected it while the **bootstrap**
accepted it. `selfhost/Resolver.zbr` `isBuiltin()` whitelisted only
`int/str/bool/float` as builtin type names; `char` and `uint` (both keyword
primitives, both already handled by `typeFromName` → `Type_.char_`/`uint_` and by
codegen → `u21`/`u…`) were missing, so in type position (e.g. the generic arg of
`List(char)`) they resolved as "undefined name". Added `char`/`uint` to `isBuiltin`.
Verified: `List(char)`/`List(uint)` now emit `std.ArrayList(u21)`/`…` and run on
BOTH compilers. Regression test: `test/bug172_list_char_test.zbr` (smoke).

**Related gap (lower priority, NOT fixed):** the sized numeric types (`int32`,
`uint64`, `float64`, `byte`, `usize`, …) are *non-keyword* identifiers, so as a
generic arg (`List(int32)`) they fail earlier — at the **parser**
(`unexpected expression token: 'int32'`) — not the resolver. `typeFromName` +
codegen already handle them; a parser arm to accept them in type-arg position
would close it. Discovered while fixing BUG-172.

**Old workaround (no longer needed):** string slicing (`s[a..b]`) + a char-at
helper. `main.zbr` `lspWordAt` still uses this but could now use `List(char)`.

---

## BUG-171: selfhost lexed a bare `'Z'` char literal as a string ✅ FIXED (2026-07-09)

**Severity:** medium (bootstrap/selfhost parity gap; selfhost rejected valid code).
Surfaced 2026-07-08 while building a char-based discriminator for fn-type
inference — unrelated to fn-types.

**Symptom:** a bare single-quoted char literal (`'Z'`, no `c'` prefix) in a
`char`-typed context failed on the selfhost:
```
def getCh(): char
    return 'Z'
```
→ `error: type mismatch: expected char, got str`. The bootstrap accepts it.

**Root:** the selfhost lexer dispatched a bare `'` straight to `scanString`
(always emitting a string token) — it had no char-vs-string disambiguation. The
selfhost's OWN sources only use the `c'…'` prefix form, so this path never bit
self-compilation. The bootstrap's `scanSingleQuote` emits a char literal for
single-char / single-escape content.

**Fix (2026-07-09):** added `scanSingleQuote` to `selfhost/Lexer.zbr` (mirrors
the bootstrap: `'X'` / `'\X'` → char literal, else string) + a codegen arm in
`selfhost/CodeGen.zbr` to emit an already-quoted bare char token as-is (the
`c'…'` path strips the `c`; the bare path was double-wrapping → `''Z''`). Fixture
`test/char_literal_test.zbr`. Gates green (smoke 228, round-trip byte-identical,
inference 0/414, fuzz 25).

---

## BUG-170: selfhost does not box a value struct assigned to a `^T` field ✅ FIXED (2026-07-09)

**Fix (2026-07-09):** `selfhost/CodeGen.zbr` `genAssign` now heap-boxes a value
struct assigned into a `^T`/`^T?` field. It resolves the target field's TypeRef
(`getAssignFieldType`, which handles both `field = x` and `self.field = x`); if it
is `ref_to` with an inner type in `struct_names`, it emits
`{ const _rp = _allocator.create(T) catch @panic("OOM"); _rp.* = value; target = _rp; }`
— identical to the bootstrap. Keying on `struct_names` (not "RHS is a value")
sidesteps the inferExpr-from-codegen problem: since `^Class` is rejected (BUG-078),
`^T` fields are struct or union, and only structs (value types) need the box; union
payloads are already pointers. `test/ref_struct_test.zbr` now registered in smoke
(passes both compilers, round-trip byte-identical, inference 0/414, fuzz 25).

---

### Original report (pre-existing, selfhost-only)

**Severity:** medium (bootstrap/selfhost parity gap; selfhost emits invalid Zig
for a narrow struct pattern). Surfaced 2026-07-05 while making `^ClassName` a
hard error — `test/ref_struct_test.zbr` (a struct `^Point` field test, never
registered in the smoke suite) fails on the selfhost compiler while bootstrap
passes.

**Symptom:** `holder.p = pt` where `p: ^Point` (a `^`-indirected **struct**
field) and `pt` is a value `Point`. Selfhost emits `self.p = pt;` — assigning a
`Point` value to a `*Point` field — which Zig rejects with
`error: expected type '*Point', found 'Point'`.

**Expected (bootstrap emits):**
`{ const _rp = _allocator.create(Point) catch @panic("OOM"); _rp.* = pt; self.p = _rp; }`
— heap-box the value and assign the pointer.

**Root:** `selfhost/CodeGen.zbr` `genAssign` has no boxing path for `^T` fields.
It knows which fields are `^T`/`^T?` (`ref_fields`/`opt_ref_fields` StrSets +
`getAssignFieldType`), but never emits the create-and-copy box when the RHS is a
value. The hard part (why it isn't a trivial fix) is deciding *when* to box:
only when the field is `^T` **and** the RHS is a value (not already a pointer,
e.g. another `^T` field read or a class instance). Making that call precisely
needs `inferExpr` on the RHS from within codegen — the same "least confident"
struct-field-boxing area flagged in `test/recursive_type_test.zbr`.

**Scope note:** This is NOT about classes — after BUG-078's `^ClassName`
rejection, `^` only ever wraps structs/unions, and only structs are value types
needing the box. The only in-repo trigger is `ref_struct_test.zbr`, which is why
it went unnoticed (not in the smoke suite). `test/val_lib.zbr` (union `^Val?`)
is a *field type* only, not an assignment, so it doesn't hit the gap.

**Status:** documented, deferred — not introduced by the `^ClassName` work (the
class boxing it replaced was identity/no-op). Fix = add a `^T`-field boxing arm
to selfhost `genAssign` gated on an `inferExpr`-based value-vs-pointer check,
then register `ref_struct_test` in the smoke suite.

## BUG-169: unused capture/local discard skipped when body holds an unmodeled expr (ternary) ✅ FIXED

**Severity:** medium (shared robustness gap — both compilers emit the same
invalid Zig; `error: unused capture` / `unused local constant`). Found
2026-07-03 by the fuzzer's enum/union/branch batch = fuzz finding **F11**.

**Symptom:** `if x as y` (or for-in / unused local) where the binding is never
read AND the body contains a **ternary** (`if(c,t,e)`) — or any of `try_`,
`catch_`, `to_non_nil`, `is_nil`, `cast`, `type_check`, `opt_chain`, `slice` —
emits the capture without the `_ = y;` discard, which Zig rejects.

**Root (confirmed by reading the walker, no build):** the discard fires only
when `mightUseName(cap, body)` is FALSE; `mightUseNameInExpr` doesn't model
those expr forms, so they hit `else => true`, the discard is skipped, and a
genuinely-unused binding errors. Same family as BUG-161 (that fix added
string_interp/orelse/this to the same walker). Deeper defect: `mightUseName`
is *conservative* ("true when unsure"), but the discard decision needs an
*exact* walker — both error directions are compile errors. `mightUseNameStmt`
has the analogous gap for unmodeled statement forms.

**FIXED 2026-07-03:** added the missing arms to `mightUseNameInExpr`
(if_expr/try_/catch_/to_non_nil/is_nil/cast/type_check/slice/opt_chain/dict_lit;
+except_ on the selfhost) and `mightUseNameStmt` (branch/try_catch/raise/
assert/defer) in both compilers, mirroring the complete `nameUsedInExpr`/
`nameUsedInStmt`; conservative `else => true` kept for the rare remainder
(lambda/with/allocate/copy_out/except-stmt — over-approx there is the safe
direction). Seed 39 → ok; both 80-seed `both-zig-fail` closed; smoke +
round-trip green. Regression `test/fuzz_f11_unused_capture_ternary_test.zbr`
(registered in smoke). **Residual (documented):** an unused binding whose sole
use sits inside a still-unmodeled form would over-conservatively skip its
discard; long-term robust retirement = switch the discard decision to an exact
`collectAllIdents(body)` membership check. Full analysis in `fuzz/FINDINGS.md`
F11; cross-ref `docs/walker_discipline.md` (exact-vs-conservative walker lesson).

---

## BUG-168: cross-module PRIMITIVE-returning free fns untyped at bootstrap call sites ✅ FIXED

**Severity:** medium (bootstrap-lags-selfhost class; `greet(x) + "!"` on a
cross-module `greet(): str` emitted raw Zig `+` on slices — 'pointer' and
'pointer').  Hit twice from inside the compiler's own sources during the
BUG-162 work (worked around with `var z: str = call(...)` hoists), tracked
informally since, minimal repro + fix 2026-07-02.

**Root cause (two layers, both bootstrap-only — the selfhost stores full
`Type_` in dep_types and was always correct):**
1. `extractFromDecls` recorded a free fn's return in `fn_return_types` only
   via `namedTypeStr`, which deliberately skips builtins — so a `: str`
   return was never recorded, and `inferCall` typed the call `.unknown`.
2. `genBinary .add` consulted only the LEFT operand's type (the selfhost's
   helper is literally named `isStringBoth`).

**FIXED (2026-07-02):**
- `primTypeName` records `str/int/float/bool/char` returns in
  `fn_return_types`; the consultation site maps those names back to
  primitive `Type`s instead of wrapping them `.cross_module`.
- `genBinary .add` checks both operands (either side string ⇒ concat;
  `str + non-str` is a TC error upstream, so the OR cannot misfire).
- Validation bonus: regenerating the selfhost with the fixed TC changed
  exactly ONE emitted line — `var lv_used = mightUseName(...)` gained its
  `: bool` annotation, i.e. the compiler's own emission got more precise.

Regression: `test/bug168_crossmod_prim_return_test.zbr` (+`_lib`; call+lit,
lit+call, call+call, int/float arithmetic), registered in smoke.  The
BUG-162 `zigSafeName` hoist workarounds in `selfhost/CodeGen.zbr` are now
unnecessary but harmless — left in place (cosmetic revert, low value).

---

## BUG-167: parsers accepted different ternary syntaxes; literal arms uncompilable ✅ FIXED

**Severity:** medium (front-end equivalence divergence + a feature that was
unusable with literal arms in runtime contexts).
**= fuzz finding F8**, found while writing the F7 fixture (2026-07-02).

The bootstrap parsed the ternary as call-form `if(cond, then, else)`; the
selfhost parsed a colon-form `if c: t else: e`. Each rejected the other's
syntax. Zero corpus usage, no QUICKSTART documentation — invisible until a
fixture tried to use one. Separately, literal arms emitted bare
`comptime_int`/`comptime_float`, which Zig rejects under a runtime
condition.

**FIXED (2026-07-02):** converged on the **call-form** (bootstrap's):
selfhost `parseAtom` now parses `if(c, t, e)`; the colon arm is removed.
(The FINDINGS note initially recommended the colon form; reversed on
implementation grounds — see FINDINGS.md F8.) Both emitters wrap the
ternary in `@as(i64/f64, …)` when the TC types it numeric, fixing the
literal-arms case. Documented in QUICKSTART §13; the fuzz generator now
produces ternaries. Regression: `test/fuzz_f8_ternary_test.zbr`.

---

## BUG-166: selfhost `stmtMentionsThis` blind to else/else-if branches ✅ FIXED

**Severity:** medium (selfhost-only equivalence bug — a method whose ONLY
self-use sits in an `else` branch emitted `_ = self;`, which Zig rejects as
a pointless discard once the else-branch use compiles).
**Found by the differential fuzzer** (seed 51, verdict `zig-diverge-B`) in
the first 60-seed batch after the BUG-164 work — fuzz finding **F10**.

**Root cause:** `selfhost/CodeGen.zbr stmtMentionsThis`'s `Stmt.if_` arm
scanned `then_stmts` + `cond` but skipped `else_ifs` and `else_stmts`
entirely, so `.field = x` in an else branch was invisible to the
`_ = self;` suppression. The bootstrap (`collectRefs`) has no such gap.
Sibling walkers audited clean: `nameUsedInStmt` and `methodMutatesSelf`
if-arms already cover else/else-if.

**FIXED (2026-07-02):** the arm now scans else-if conds/bodies and the else
body. Regression: the else-only-self-use method shape added to
`test/fuzz_f6_unused_capture_test.zbr`; fuzz seed 51 → `ok`.

**Second face (same day, seeds 61/63/69/75/76/83/89/91):** as soon as the
generator gained range loops, the same walker failed one arm over —
`stmtMentionsThis` had NO `Stmt.for_num` arm (its `else` returns false), so
a self-use only inside a range loop emitted a pointless `_ = self;`. Fixed
(for_num arm: start/stop/step + body); Gauge.fill regression shape added.
Design caution: unlike the conservative mightUseName family, this walker
must be EXACT — both error directions are Zig compile errors (pointless
discard vs unused parameter) — so any new Stmt form must be added here.

**Adjacent hardening in the same session:** the BUG-164 if-as discard sites
gained a `cap != "_"` guard — `if x as _` (Zebra's explicit discard
binding) previously made the new code emit `_ = _;`, invalid Zig; caught by
`crypto_test` in the smoke suite before commit.

---

## BUG-164: unused `if-as` / for-in captures emit payloads Zig rejects ✅ FIXED

**Severity:** medium (any legal Zebra program that binds without reading —
`if x as y` for a presence check, a loop over a list just for its count —
failed to compile in both compilers with "unused capture").
**Found by the differential fuzzer** (`fuzz/` finding **F6**, seeds 3/27).

Probing showed no unused-binding suppression existed for `if x as y` at all
(the suppression in the codebase belongs to `branch` codegen), and for-in
arms were a patchwork: hashmap/tuple/range handled it (tuple with two latent
flaws — under-approximating `nameUsedInStmts` risking *pointless* discards,
and ignored where-clause uses), list/chars/split/bytes/sqlite leaked.

**FIXED (2026-07-02), both compilers:** if-as capture arms (union-variant,
`is T as`, plain `as`) and a shared `discardUnusedLoopVars` helper in every
capture-style for-in arm now emit `_ = v;` when neither body nor
where-clause provably reads the binding (`mightUseName` — conservative, so
no pointless-discard risk; precise enough thanks to the BUG-161 modeling).
Tuple arm switched to the same analyzer. Generator's for-in usage mask
removed so this stays differentially tested.
Regression: `test/fuzz_f6_unused_capture_test.zbr`. See FINDINGS.md F6.

---

## BUG-165: range for-in — docs said `to`, bootstrap had usize `..`, selfhost had neither ✅ FIXED (= fuzz F9)

**Status:** FIXED 2026-07-02 (found the same day while probing BUG-164).
Three-way inconsistency: QUICKSTART §13's documented `for i in 0 to 10` (+
`step`) is rejected by BOTH compilers; the bootstrap parses `for i in 0..3`
(and QUICKSTART §33/§35 use that form); the selfhost parser rejects `..` in
for-in entirely ("expected indent, got '..'" — its `..` is slice-context
only). `0.to(n)` method form works in both, and probing revealed the colon
for_num form (`for i in a : b [: step]`) worked in BOTH compilers all along
— the real canonical range.

**FIXED:** `..` is now an alias of the `:` for_num form in both compilers:
the selfhost parses `a..b` into the same for_num node (no step after `..`,
matching the bootstrap); the bootstrap routes binary-dotdot iterables to
the shared i64 counter lowering instead of Zig's native `for (a..b)` —
whose usize counter rejected negative bounds and underflow-panicked on
`i - 1` at zero (a silent semantic split from `:`/`.to()`). Also fixed en
route: bootstrap `genForNum` now brace-scopes its counter like the selfhost
(two same-named colon loops in one scope previously collided). QUICKSTART
§13 corrected to the real forms. Regression: `test/fuzz_f9_range_test.zbr`.
See FINDINGS.md F9.

---

## BUG-163: orelse/catch/if-expr/try re-emitted without parens → precedence miscompile ✅ FIXED

**Severity:** high-medium (silent semantics class: valid Zebra can emit Zig
that re-associates differently; the fuzz hit failed loudly, but shapes like
`(a - b) orelse c` vs `a - (b orelse c)` could compile AND misbehave).
**Found by the differential fuzzer** (`fuzz/` finding **F7**, seed 7,
2026-07-02) — first finding from the post-BUG-162 unmasked batches.

**Symptom:** `C5((1 - (v26 orelse 8)))` emitted `C5.init((1 - v26 orelse 8))`;
Zig parses that as `(1 - v26) orelse 8` → invalid operands (or, worse,
different runtime semantics where both parses type-check).

**Root cause:** the Zebra parser drops redundant source parens (no paren AST
node), so codegen must re-establish precedence — but the `orelse_`, `catch_`,
`if_expr`, and `try_` emission arms printed bare. All four bind looser than
every Zig operator, so ANY nesting inside a binary/call-arg/tighter context
broke. (`1 + try f()` is also invalid Zig — the `try` arm had the same gap.)

**FIXED (2026-07-02), both compilers** (`src/CodeGen.zig` genExpr +
`selfhost/CodeGen.zbr` genExpr): those four arms now always self-parenthesize
(`(x orelse y)`, `(x catch |e| f)`, `(if (c) a else b)`, `(try x)` — including
the try-block-label catch form). Redundant parens are harmless.
Regression: `test/fuzz_f7_precedence_test.zbr`. Smoke + round-trip green;
seed 7 → `ok`.

**Surfaced en route (filed as fuzz F8, OPEN):** the two parsers accept
*different* ternary syntaxes — bootstrap `if(c, t, e)` call-form vs selfhost
`if c: t else: e` colon-form — with zero corpus usage and no QUICKSTART
documentation; plus literal ternary arms emit bare `comptime_int` in runtime
contexts. Reconcile as its own task (see FINDINGS.md F8).

---

## BUG-162: identifiers shadowing Zig primitives emitted bare → invalid Zig ✅ FIXED

**Severity:** medium (shared robustness gap; any user program naming a var or
param `i8`/`u32`/`f64`/`usize`/`c_int`/… failed to compile in both compilers
with Zig's "name shadows primitive").
**Found by the differential fuzzer** (`fuzz/` finding **F1**, 2026-07-01);
compiler-side fix landed 2026-07-02 (was deferred to a gated session).

**FIXED (2026-07-02), both compilers:**
- `isZigPrimitiveName` predicate (iN/uN digit-run int types, f16–f128,
  bool/void/type/anyerror/anyopaque/anyframe/noreturn/comptime_*/isize/usize,
  the `c_*` ABI types, and the primitive values `null`/`undefined`).
- Bootstrap: `Generator.emitName` (writer-level, no allocation) applied at
  identifier-position emissions — genIdent, genLocalVar (all decl paths),
  genStmts unused-discard, genParamList-equivalents (method/init/ext/lambda
  sigs), unused-param discards, TCO shadows (`var X = _p_X` — bare `_p_X`
  side kept), interface shim/vtable/wrapper glue, closure-thunk glue,
  `export fn` shims, constraint-check `const value = X`.
- Selfhost: `zigSafeName` (returning form, for concat-style emission) +
  `emitName` mirror at the same logical sites.
- **Safety property:** `@"name"` is the SAME identifier as `name` in Zig
  (escaped spelling), so partial coverage degrades gracefully — an escaped
  reference to a bare-declared legal name stays consistent. Prefix-
  concatenated names (`_p_`, `_zbr_mv_`, `_ttag_`) must stay bare and do.
- **Residual (rare, deliberate scope bound):** for-in/`if-as` binding names,
  destructuring names, and struct/class *field* names that shadow a
  primitive still emit bare and still fail. Extend `emitName` coverage if a
  real program hits one.
- Selfhost-source trap discovered en route: `zigSafeName(x) + "lit"`
  (cross-module call result in a string concat) emitted raw Zig `+`;
  worked around by hoisting into annotated `var z: str = zigSafeName(x)`
  locals. Same class now tracked as fuzz finding **F7** (open).

Regression: `test/fuzz_f1_primitive_names_test.zbr`; generator now names
~10% of locals from a primitive pool so the escape stays differentially
tested. Smoke 192/192, round-trip byte-identical. See `fuzz/FINDINGS.md` F1.

---

## BUG-161: unused-local auto-discard missed by annotation / `this` / interp / orelse ✅ FIXED

**Severity:** medium (shared robustness gap — programs both compilers accept
emit Zig that `zig` rejects with `error: unused local constant`).
**Found by the differential fuzzer** (`fuzz/` finding **F2**), diagnosed
2026-07-02 by scope-shape probing after the trivial repro failed to reproduce.

**Symptom:** an unused local sometimes emits `const x = <expr>;` with no
`_ = x;` discard. One root cause, three faces, in `genStmts`' auto-discard
(both compilers):
1. the discard skip for explicitly-typed locals — needed only for
   *constrained-alias* types, whose inline contract check reads the local —
   covered **every** annotation (`var zz: int = 5` in any scope);
2. `Expr.this` was unmodelled in `mightUseNameInExpr` (conservative
   `else => true`), so any later `.field` statement in a method/`cue init`
   body suppressed the discard for **every** local in that body;
3. `string_interp` / `orelse_` were likewise unmodelled, so a later
   `print("${other}")` or `(other orelse 0)` suppressed all discards.

**FIXED (2026-07-02), both compilers** (`src/CodeGen.zig` +
`selfhost/CodeGen.zbr`/`CgHelpers.zbr`):
- `genStmts` skip narrowed to a new `varDeclEmitsConstraintCheck` predicate
  (named/`alias_applied` type resolving to a `where`-constrained alias, and
  contracts not stripped) — mirrors the constraint-check emission condition
  exactly, so the discard now fires for plain annotations and, under
  `--turbo`, for constrained-alias locals too (whose check isn't emitted).
- `mightUseNameInExpr` gained exact arms: `this` → false (keyword, never a
  user name), `string_interp` (recurse expr parts), `orelse_` (both sides).

Regression: `test/fuzz_f2_unused_local_test.zbr`. Gates: smoke 192/192,
round-trip byte-identical. See `fuzz/FINDINGS.md` F2.

---

## BUG-160: selfhost string-interpolation used `{}` for non-strings ✅ FIXED

**Severity:** medium (self-hosting equivalence + a real user-facing failure).
**Found by the differential fuzzer** (`fuzz/`), 2026-07-01 — its second divergence
(verdict `zig-diverge-B`, surfaced as a `zig` build timeout on the selfhost emit).

**Symptom:** interpolating a non-string value with no explicit format spec
(`print("${x}")`) diverged. The bootstrap emits the type-appropriate spec via
`printFmt` (`{d}` for float, `{any}` for List/struct/unknown); the selfhost's
`genStringInterp` hardcoded `{}` in the implicit case. Consequences:
- **float** → `{}` vs `{d}`: Zig 0.16 rejects `{}` on a float, or formats it
  differently → divergent output.
- **List/struct** → `{}` vs `{any}`: a `{}` on a `std.ArrayList` sends Zig's
  comptime default-struct formatter into a blow-up → **build timeout** (the
  selfhost emit was uncompilable where the bootstrap's compiled in ~6s).

**FIXED (2026-07-01):** the selfhost `genStringInterp` implicit case now routes
through `printFmtSpec(e)` (the existing mirror of the bootstrap's `printFmt`,
falling back to `{any}`) instead of a hardcoded `{}`. Selfhost-only (the bootstrap
was already correct). Round-trip byte-identical; smoke 192/192. Regression:
`test/fuzz_f4_interp_fmt_test.zbr` (float + List interpolation). See
`fuzz/FINDINGS.md` F4.

---

## BUG-159: selfhost omits numeric annotation on a mutated comptime-init local ✅ FIXED

**Severity:** medium (self-hosting equivalence). **Found by the differential
fuzzer** (`fuzz/`) on its first real run, 2026-07-01 — the first divergence it
caught (verdict `zig-diverge-B`: the selfhost emit is rejected by `zig`, the
bootstrap emit compiles).

**Symptom:** a mutated local whose init is a comptime-numeric *binary op* diverged:
```zebra
def main()
    var v = (8 * 2)   # bootstrap: `var v: i64 = (8 * 2);`   selfhost: `var v = (8 * 2);`
    v = v + 1         # → Zig: variable of type 'comptime_int' must be const or comptime
```
`v` is mutated → a Zig `var`; the init stays `comptime_int` unless annotated. The
bootstrap annotates untyped `var`s from the **TC-inferred type**
(`tcTypeAnnotation`); the selfhost's `genLocalVar` only special-cased literal
*syntax* (`int_lit`/`float_lit`/neg-lit), so a binary-op comptime init got no
annotation. (A plain `var v = 5` did not diverge — both annotate the literal.) The
round-trip gate never caught it: it compares selfhost-vs-selfhost, and the selfhost
is internally consistent.

**FIXED (2026-07-01):** `selfhost/CodeGen.zbr genLocalVar` now hoists the inferred
init type (`lv_infer_t = inferExpr(init)`) and, for a non-literal numeric init,
falls back to `: i64`/`: f64` — matching the bootstrap. Both compilers;
round-trip byte-identical; smoke 191/191. Regression:
`test/fuzz_f3_comptime_local_test.zbr` (int + float). See `fuzz/FINDINGS.md` F3.

---

## BUG-158: a module-global `var` is not accessible cross-module ✅ FIXED

**Severity:** medium. Found 2026-06-30 building the BBAT Roblox-globals shim.
Blocked the natural cross-module singleton pattern (`use robloxglobals exposing
game`) and cross-module data-module access.

**FIXED (2026-07-01):** implemented as designed below, both compilers. A new
`ModuleInterface.module_vars` (selfhost: `ModuleTypes.module_vars`) records the
dep's top-level `var`/`const` names; `genUse` skips the `const g = …` binding for
an exposed module var and records `g → alias` in `exposed_module_vars`; `genIdent`
rewrites each reference to the live `alias._zbr_mv_g`, shadow-safe (a local/param of
the same name keeps its bare name — an exposed cross-module var is unresolved, so
the guard checks the reference doesn't resolve to a local). Verified: scalar +
class-instance singleton work cross-module (`test/crossmod_modvar_test.zbr`, both
compilers, in smoke 190/190); round-trip byte-identical.

**Two limitations found (open):**
- **stdlib-container module vars.** An exposed `HashMap`/`List`/`Atomic` var
  dispatches a *throwing* method (`.put`) with no `catch` wrapper, because the
  consumer doesn't know the exposed var's type → `error: error union is ignored`.
  Class-instance singletons (the shim's use case) and scalars are unaffected;
  `_G` is a class with HashMap *fields*, so BBAT is covered. Fixing needs the
  interface to also carry exposed-var *types*.
- **explicit-receiver field `HashMap.put` misses the auto-`catch`.** Surfaced by
  the fix itself: `g.someField.put(k, v)` (a HashMap `.put` on a `localvar.field`
  receiver) does not get the error-catch the codegen adds for implicit-self
  `.field.put`. Worked around by wrapping in a method (implicit self); the
  underlying codegen gap remains.

---
### Original design (as implemented)

**Severity:** medium. Found 2026-06-30 building the BBAT Roblox-globals shim.
Blocks the natural cross-module singleton pattern (`use robloxglobals exposing
game`) and cross-module data-module access; the shim works around it by declaring
singletons in the *consuming* module and importing only the service *types*.

**Symptom:** `use m exposing g`, where `g` is a module-global `var` in `m`, emits
`const g = m.g;` — but the emitted Zig symbol is `m._zbr_mv_g` (the `module_var_prefix`
that keeps module vars from colliding with locals). Result:
`error: root source file struct 'm' has no member named 'g'`. (A `def`/`class`
exposed from `m` resolves fine — only module `var`s hit this.)

**Why the naive fix is wrong:** emitting `const g = m._zbr_mv_g;` binds the value
at import time (Zig container/global-init = comptime). That works for a
*non-deferred* module var (scalar/`List` — initialized at global scope), but a
*deferred* one (HashMap/Set/Atomic per BUG-153, or a class instance per BUG-157)
is `= undefined` until `_initModuleVars()` runs, so the `const` would capture
`undefined`.

**Fix direction (both compilers):** exposed cross-module module-var references must
resolve to `m._zbr_mv_g` **at each use site** (live), not a one-time `const` binding:
  1. `genUse`: when an exposed name is a module `var` in the dep (consult the dep's
     interface / `imported_modules`), do NOT emit `const g = …`; instead record
     `{g → alias m}` in a new `exposed_module_vars` map.
  2. `genIdent`: when emitting a reference to a name in `exposed_module_vars`, emit
     `m._zbr_mv_g` instead of the bare name.
  3. The dep's var is already `pub var _zbr_mv_g` — no dep-side change needed.
Mirror to `selfhost/CodeGen.zbr`; gate with the full round-trip + smoke. A regression
fixture should cover both a non-deferred (scalar/List) and a deferred (HashMap/class)
exposed module var, same-file and cross-module.

**Payoff:** lets `robloxglobals` expose real singleton `var`s (retire the per-script
injection in `luau2zebra_ast._emit_roblox_globals`), and lets a translated data
module expose its built table directly instead of a `def <mod>Data()` builder.

---

## BUG-150: `sys.sleep` emitted removed `std.Thread.sleep` (Zig 0.16) ✅ FIXED

**Severity:** high (every timing/poll path was uncompilable on Zig 0.16). Found
2026-06-30 dogfooding a multithreaded TCP server (`scratchpad/kv_dogfood.zbr`).

**Cause:** `sys.sleep(ms)` emitted `std.Thread.sleep(ns)`, which Zig 0.16 removed
(`error: root source file struct 'Thread' has no member named 'sleep'`). Sleeping
now goes through the Io interface: `std.Io.sleep(io, duration, clock)`.

**Fix:** new preamble helper `_sysSleep(ms)` → `std.Io.sleep(_io,
std.Io.Duration.fromMilliseconds(ms), .awake) catch {}` (`.awake` is 0.16's
monotonic clock; cancellation is benign for a pacing sleep so it's swallowed).
Both codegens now emit `_sysSleep(@as(i64, @intCast(<ms>)))`. One site in
`src/CodeGen.zig`, one in `selfhost/CodeGen.zbr`, helper in
`selfhost/stdlib_preamble.zig` (shared by both compilers).

## BUG-151: `var _ = expr` discard emitted invalid `const _ = expr` ✅ FIXED

**Severity:** medium. The QUICKSTART discard idiom `var _ = total.add(1)` emitted
`const _ = …;`, which Zig rejects: `error: '_' used as an identifier without @"_"
syntax`. (Zig only accepts the bare discard-assignment `_ = expr;`, never a
`const`/`var` binding literally named `_`.)

**Fix:** `genLocalVar` now special-cases name `==` `_` and emits `_ = <expr>;`
(or `_ = undefined;` when there's no init). One site each in `src/CodeGen.zig`
and `selfhost/CodeGen.zbr`.

## BUG-152: `ThreadPool.submit(def() …)` stored a comptime-only fn type ✅ FIXED

**Severity:** medium (the documented `pool.submit(def() doWork())` form did not
compile). `_ThreadPool.submit` boxed a by-value `fn() void` in a heap `FnBox`,
but a by-value function type is comptime-only: `error: cannot store
comptime-only type 'fn () void' at runtime`.

**Fix:** coerce to the fn-*pointer* type first — `const FnPtr = *const T; const
fp: FnPtr = f;` then box `fp` — exactly the pattern `_ws_serve`/`_http_serve`/
`_tcp_serve` already use (cf. caf477c). `selfhost/stdlib_preamble.zig`, `submit`'s
`.@"fn"` branch. `sys.go` was already fine (Thread.spawn takes a comptime fn).
Validated by `scratchpad/pool_dogfood.zbr` (4 workers run, `pool.wait()` joins).

## BUG-153: module-global var with an allocating initializer is uncompilable ✅ FIXED

**Severity:** high for concurrent/stateful programs (blocks the natural shape of
a shared store, global ECS/world, counters). Found 2026-06-30 dogfooding.

**FIXED (2026-06-30):** deferred init implemented in both compilers. A module-global
`var m: HashMap(K,V) = …` / `var a: Atomic(int) = …` (and `Set`/`Map`) is now emitted
`pub var _zbr_mv_m: T = undefined;` at container scope; the real assignment runs in a
generated `pub fn _initModuleVars()`, called from `_initIo` (so each dep module
self-initialises) and explicitly from the root entry thunk (whose `_initIo` is never
invoked). Requires an explicit type annotation (gives the `: T` and keeps the two
compilers symmetric). Bootstrap emits `_initModuleVars` in the file header; selfhost
emits it as a module footer (in `generateModuleWith`) with the call wired through the
`_initIo` preamble + entry thunks. A selfhost-only follow-on: a module-global `Atomic`
isn't tracked by `inferExpr` (locals/params only), so its `.add` was mis-rewritten to
`List.append` — the rewrite now consults `isModuleGlobalAtomic(name)` (scans
`module_decls`). Verified: `scratchpad/repro153.zbr` (bootstrap) +
`test/module_global_container_test.zbr` (selfhost, smoke 187/187).

**Remaining edge:** an *unannotated* module global (`var m = HashMap(K,V)()`) is not
deferred; module globals in a *non-root* module rely on the dep's `_initIo` path
(covered) but transitive-only deps aren't reached (matches the pre-existing
`_initAllocator`/`_initIo` propagation limitation).

---
### Original report

**Symptom:** a module-level `var m: HashMap(str,str) = HashMap(str,str)()` emits
`pub var _zbr_mv_m: … = std.StringHashMap(…).init(_allocator);` at container
scope → `error: unable to resolve comptime value … initializer of container-level
variable must be comptime-known`. Same for `var a: Atomic(int) = Atomic(int)(0)`
(emits `_atomic_create(…)`, which calls the page allocator at comptime →
`error: comptime call of extern function`). **Plain scalars and `List` globals
DO work** (`= 0`, `= .empty` are comptime-known) — only *allocating* inits fail.

**Symptom:** a module-level `var m: HashMap(str,str) = HashMap(str,str)()` emits
`pub var _zbr_mv_m: … = std.StringHashMap(…).init(_allocator);` at container
scope → `error: unable to resolve comptime value … initializer of container-level
variable must be comptime-known`. Same for `var a: Atomic(int) = Atomic(int)(0)`
(emits `_atomic_create(…)`, which calls the page allocator at comptime →
`error: comptime call of extern function`). **Plain scalars and `List` globals
DO work** (`= 0`, `= .empty` are comptime-known) — only *allocating* inits fail.

**Why it matters:** a `Tcp.serve` handler is a non-capturing fn (BUG-154), so the
only state it can reach is module-global. With allocating globals uncompilable,
you cannot write a correct shared-state TCP server (no global map, no global
atomic/lock). `kv_dogfood` works around it by keeping all shared state in plain-
int + `List` globals and serializing access on a single client.

**Fix direction:** deferred init. Emit `pub var _zbr_mv_X: T = undefined;` at
container scope and run the real `_zbr_mv_X = <init>;` from a generated
`_initModuleVars()` called once at startup — from the root entry thunk (after
`_io`/`_allocator` are live) AND from `_initAllocator` (so dep modules init too;
note the root never receives an `_initAllocator` call, so it needs the entry-thunk
path). Detect "non-comptime init" by collection/Atomic type. Touches both
codegens + entry/`_initAllocator` emission; gate carefully (round-trip risk).

## BUG-154: `Tcp.serve` spawns a thread per connection, but no synchronization is expressible

**Severity:** medium (design/ergonomics). `_tcp_serve` spawns a new
`std.Thread` per accepted connection, so handlers run **concurrently**. A handler
is coerced to `*const fn(TcpConn) void`, so it cannot capture — its only reachable
mutable state is module-global, which (BUG-153) cannot hold an `Atomic`/`Mutex`.
Net effect: **a concurrent TCP server cannot today protect shared state in
Zebra.** Observed as nondeterministic `panic: integer overflow` / `reached
unreachable code` under concurrent clients racing on `List.add`/counters.

**Fix direction:** depends on BUG-153 (global atomics/locks) and/or a capturing-
handler path for `Tcp.serve` (store the handler in a per-connection ctx that also
carries a user state pointer). Until then, document that handlers must be
stateless or access only single-writer state (one client at a time).

## BUG-155: `List` has no element setter / index assignment ✅ FIXED

**Severity:** low. `list.set(i, v)` → `error: no field or member function named
'set'`; in-place element update was impossible.

**FIXED (2026-06-30):** added `List.set(i, x)` to `genListMethod` in both compilers
— emits `list.items[@intCast(i)] = x` (the inverse of `at`), interning a `str`
element / boxing a `^T` element to match `add`'s ownership.  (Chose a `.set(i,x)`
method over new `list[i]=x` syntax — symmetric with the `.at(i)` getter, no parser
change.)  Regression: `test/list_setter_parse_test.zbr`.

## BUG-156: `str.toInt()` doesn't dispatch on a `List.at()` result ✅ FIXED

**Severity:** low (inference gap). `sp.at(0).toInt()` where `sp: List(str)`
emitted `…toInt()` raw → `error: no field or member function named 'toInt' in
'[]const u8'`.

**FIXED (2026-06-30):** two compiler-specific causes.
- Bootstrap (TypeChecker): generic-method inference (`List(T).at(i): T`) only fired
  when the receiver var had an explicit annotation. Added `listCtorTypeRef` so an
  unannotated `var sp = List(str)()` recovers `List(str)` from its init ctor, and
  `sp.at(0)` infers `str` → the `.toInt()` parse helper dispatches.
- Selfhost (CodeGen): the method-chain materializer hoisted `sp.at(0)` into
  `var _mc_N = …`, erasing the element type so `_mc_N.toInt()` mis-dispatched.
  `tryChain` now skips List index accessors (`at`/`first`/`last`) — they lower to
  `list.items[i]` (an lvalue, no temp needed), so the chain dispatches inline and
  sees the `str` element type.
Regression: `test/list_setter_parse_test.zbr`.

## BUG-157: module-global var holding a user class instance is uncompilable ✅ FIXED

**Severity:** high for the Roblox-globals shim + any singleton pattern. Found
2026-06-30 while building the BBAT service-global shim (`game`, `Players`, `_G`,
… as module-global singletons).

**Symptom:** `var g: Foo = Foo()` at module scope emits
`pub var _zbr_mv_g: *Foo = Foo.init();` at container scope; `Foo.init()` allocates
via `_allocator.create`, which Zig can't evaluate at global comptime →
`error: unable to resolve comptime value`. (Same class of failure as BUG-153, which
only deferred *containers* — HashMap/Set/Atomic.) Same-file cases masked it when the
global was unused, because Zig dead-strips the unreferenced decl.

**FIXED (2026-06-30):** extended the BUG-153 deferral to named user class instances.
`deferredModuleVarType`/`isDeferredModuleVar` now also defers a module-global `var`
whose annotated type is `.named` and whose initializer is a constructor/factory
*call* — emitted `= undefined`, assigned in `_initModuleVars()` (source order, so a
global may be constructed from an earlier-declared one). A second fix was required:
`genModule` now pre-registers cross-module *exposed* classes into `class_names`
before the `_initModuleVars` body is emitted, so a deferred init `Foo()` lowers to
`Foo.init()` (not `Foo()` → `type 'type' not a function`). Both compilers; round-trip
byte-identical; selfhost smoke 188/188. Regression:
`test/module_global_class_instance_test.zbr` (same-module + inter-global-dependency
ordering). Deferring is always safe — the assignment runs before any use, and
`const`/comptime-value globals are excluded.

**Remaining edges (separate gaps, not fixed here):**
- A module-global `var` is **not** cross-module accessible: `use m exposing g`
  emits `const g = m.g;` but the symbol is `m._zbr_mv_g` → `has no member named 'g'`.
  The shim works around this by declaring singletons in the *consuming* module and
  importing only the service *types* (types are cross-module fine).
- A module-global `var` may not share a name with an in-scope type
  (`var Players: Players` → resolver `'Players' is already defined`); use a distinct
  type name (`var Players: PlayersSvc`).

---

## BUG-148: method chained on a HashMap `.fetch(k)` result miscompiled ✅ FIXED

**Severity:** medium. Found 2026-06-29 building GameEngine's `MessagingBroker`
(`zbra/services_stub.zbr`): `topics.fetch(topic).len` failed to compile.

**Cause:** `.fetch(k)` emitted `(map.get(k) orelse undefined)`. The `orelse
undefined` leaves an `@TypeOf(undefined)` peer in the null branch — fine when
assigned to a typed local, but when a member is chained on the result
(`m.fetch(k).at(0)`), Zig can't peer-resolve `*const T` vs `@TypeOf(undefined)`:
`error: incompatible types: '*const …' and '*const @TypeOf(undefined)'`.

**Fix:** emit `(map.get(k).?)` — a clean unwrap to the value type (and a *defined*
panic on a missing key, vs the previous UB). One site in `src/CodeGen.zig`, two in
`selfhost/CodeGen.zbr` (24- and 12-space indented — the 12-space one was easy to
miss).

`.?` made `fetch`-on-an-absent-key a hard panic, which on the first attempt broke
the round-trip (`panic: attempt to use null value`) by exposing an **unguarded
`scope.fetch` in the selfhost TypeChecker's `localType`**. Fixed by guarding it
(returns `unknown_` for an untracked name — the TC convention), and defensively
guarded one more cross-map fetch in `Checker.zbr`. So the contract is now explicit:
**`fetch` asserts presence; guard with `.contains(k)` where a key may be absent.**

Regression test `test/hashmap_fetch_chain_test.zbr`; gates: round-trip
byte-identical, smoke 182/182, compile-check 147/0.

**Residual → BUG-149.** Chained *method* calls (`.fetch(k).at(i)`) now work; the
`.len` *property* on a fetch result still needs a local.

## BUG-149: `.len` property on a HashMap `.fetch(k)` result (local-inited map) not lowered

**Severity:** low (workaround: bind to a local — but see the field/local quirk).
Found 2026-06-29 alongside BUG-148.

**Symptom:** `m.fetch(k).len` (or even `var q = m.fetch(k)`; `q.len`) where `m` is
a **local-inited** `HashMap(K, List(T))` emits `.len` literally rather than
`.items.len` → `error: no field named 'len' in struct 'array_list…'`. The
`.len`-property lowering (#219) doesn't infer that `fetch` returns the map's
List value type from a local-inited HashMap. **It works when the HashMap is a
class field** (`this.field.fetch(k)` resolves the value type via the field
decl), so `zbra/services_stub.zbr`'s `pending()` compiles. Method calls
(`.at`/`.add`) are unaffected.

**Fix direction:** teach the `.len`-property path (and `getExprDeclaredType`) to
derive a `.fetch(k)` result's element/value type from a local-inited HashMap, the
same way it already does for class fields — same family as BUG-147 (call-result
type inference). Deferred (touches broadly-consulted inference; round-trip risk).

---

## BUG-144: a forwarded List/HashMap param emitted `*const` and failed to compile ✅ FIXED

**Severity:** medium (a common cursor/accumulator pattern did not compile).
Found 2026-06-28 dogfooding `examples/lisp.zbr` (its parser threads a one-element
`pos` cursor `List(int)` through `parseForm`/`parseList` → `advance(pos)`).

**Symptom:** a `List(T)`/`HashMap` parameter that is **forwarded by bare ident**
to a mutating callee — but not mutated directly in the body — was emitted by
value (`*const std.ArrayList`), so the `&` at the forwarding site failed with
`error: expected type '*T', found '*const T'`.

Minimal repro:
```
def bump(xs: List(int))
    xs.add(99)
def forward(xs: List(int))   # never mutates xs directly — only forwards it
    bump(xs)
```

**Root cause:** `paramNeedsAddrOf` only checked *direct* mutation (a mutating
method called on the param in this body); it ignored forwarding to a callee that
mutates its matching positional param.

**Fix:** split the predicate into a direct-only core (`paramDirectlyNeedsAddrOf`)
plus a transitive wrapper (`paramNeedsAddrOf` / selfhost `paramNeedsAddrOfTx`)
that reuses the existing forwarding-detector `addAddrOfMutationsInStmts` — the
same one the local var/const decision uses. That detector checks callees with the
direct-only predicate, so there is no recursion. Coverage is **one forwarding
hop** (the common cursor case); deeper pure-forwarding chains (A→B→C where only C
mutates) are not yet flagged. Mirrored in `src/CodeGen.zig` + `selfhost/CodeGen.zbr`;
round-trip byte-identical, smoke 178/178, compile-check 143/0. Regression test:
`test/transitive_list_param_test.zbr`.

---

## BUG-145: `for x in <throws-call>?` (for-in directly over a throws call) ✅ FIXED (selfhost)

**Severity:** low. Found 2026-06-28 in `examples/lisp.zbr` (`for a in listToVec(p)?`).

**Symptom:** iterating directly over a `?`-propagated throws-returning `List(T)`
emitted Zig that does field access on the error union before the `try` unwrap:
`error: error union type 'anyerror!array_list.Aligned(...)' does not support
field access` — because in Zig `.items` binds tighter than `try`, so
`try f().items` reads `.items` off the error union.

**Fix:** `genForInList` (and the selfhost str-list / plain-list for-in arms)
parenthesize the iterable when it is a `try`-expr: `(try f()).items`. Mirrored in
`src/CodeGen.zig` + `selfhost/CodeGen.zbr`. The Lisp now uses `for x in f()?`
directly at all four sites. Regression test: `test/forin_throws_test.zbr`.

**Bootstrap residual — ✅ RESOLVED 2026-06-29.** The `--zig-backend` bootstrap
previously couldn't reach `genForInList` for `for x in userFn()?` — its
`getExprDeclaredType` had no `.call`/`.try_` arm, so the iterable's type wasn't
resolved to `List` and the loop fell through to a native Zig for-loop
("type ... is not indexable and not a range"). Fixed by adding a `.try_`
passthrough and a `.call`→declared-return-type arm (ident callees → fn/method
return type) to `src/CodeGen.zig`'s `getExprDeclaredType`. `--zig-backend run`
of a `for a in makeNums()?` repro now compiles + runs. The change is additive
(returns the actual return type where it previously returned null) and produced
**zero** change to the regenerated `selfhost/*.zig` (the compiler's own source
has no such pattern), so it's contained to user-program emit. Gates: bootstrap
emit-check 140/0, round-trip byte-identical, selfhost compile-check 147/0
(unchanged).

---

## BUG-146: `str.toFloat()` / `str.toInt()` return 0 on parse failure ✅ FIXED (added tryFloat/tryInt)

**Severity:** medium (silent wrong-data footgun for any tokenizer/validator).
Found 2026-06-28 in `examples/lisp.zbr` — `parseAtom` relied on a failing
`toFloat()` to fall through to "symbol", but every symbol (`+`, `car`, `<=`)
parsed as the number `0`.

**Cause:** `toFloat`/`toInt` are emitted with a `catch 0.0` / `catch 0` fallback
and typed as plain `float`/`int` — a non-numeric string yields `0` indistinguishable
from the literal `"0"`, with no failure channel.

**Fix (non-breaking, additive):** added `str.tryFloat(): float?` and
`str.tryInt(): int?`, emitted as `(std.fmt.parse… catch null)` (an optional
`?f64`/`?i64`) and typed as optional in both type checkers. The existing
0-fallback `toFloat`/`toInt` are unchanged. `examples/lisp.zbr` now classifies
tokens with `tok.tryFloat()` (the `looksNumeric` workaround is removed).
QUICKSTART updated (and the stale "toInt panics on bad input" note corrected to
"0 on bad input"). Mirrored in `src/{CodeGen,TypeChecker}.zig` +
`selfhost/{CodeGen,TypeChecker}.zbr`. Regression test: `test/try_parse_test.zbr`.

---

## BUG-147: bootstrap (`src/`) miscompiles `examples/lisp.zbr` (3 emit divergences) — BUG-143 family

**Severity:** medium (equivalence violation; selfhost is correct, bootstrap lags).
Found 2026-06-28 — `zebra --zig-backend run examples/lisp.zbr` fails to compile
while the default selfhost compiler runs it correctly end-to-end.

**Symptoms (src/ emit only):**
- `incompatible types: '*lisp.Value' and '@EnumLiteral()'` (a `^Value` field /
  union-literal site in `makeLambda`).
- `expected type 'lisp.Value', found '*lisp.Value'` passing a `^Value` to a
  by-value `showValue(v: Value)`.
- `no field or member function named 'toInt' in 'f64'` — `float.toInt()` not
  lowered the way the selfhost lowers it.

**Status:** OPEN. Same "bootstrap lags selfhost" class as BUG-143; the lisp is a
good multi-pattern repro for a future src/→selfhost convergence pass.

---

## BUG-143: bootstrap (`src/`) codegen lags the selfhost — 14 user-program emit divergences

**Severity:** medium (equivalence violation; the bootstrap is no longer the
primary compiler, but is still reachable via `zebra --zig-backend` and is the
authority that regenerates `selfhost/*.zig`). Found 2026-06-27 by a bootstrap-emit
parity sweep run after compile-check reached 141/0 on the selfhost.

**Status:** IN PROGRESS (task #231) — **12 of 14 closed, parity 120→132 / 14→2**.
Round-trip byte-identical after every fix; selfhost steady at 141/0. The bootstrap is
the **non-primary** compiler, so this is equivalence-restoration, not active-feature work.

**Closed (12):** realpath (sys.cwd/Path.absolute → 0.16 API); Dir.walk `.next(_io)`;
the **ArrayList `.items` cluster** (list_index, for_else, module_var_shadow,
list_ref_autobox, bug119) via a positive-only `objIsList(expr)` helper (list_lit |
`List()` ctor | declared/inferred `List(T)`) wired into the `.index` arm + genForIn, plus
`getExprDeclaredType` generalised to `localVar.field` (module-decls field lookup) and a
list-lit-init `.empty` fix; the **HashMap cluster** (remove, set, field_collision,
param_field) via a `HashMap(K,V)()` ctor → `genStdlibInit` intercept, an `objIsHashMap`
helper lowering `m[k]`→`m.get(k).?`, and inferred-HashMap-var type derivation; and
**tc_iface_transitive** (concrete→interface var-init fat-pointer coercion).

Key design point: all list/hashmap detection is **positive-only** (matches only
definitely-List/HashMap exprs), so strings never match and the compiler's own `spec[i]`
string subscripts / `.at()` list access are untouched → the round-trip stays byte-identical.

### Remaining 2 — kitchen-sink tests, each with further stacked layers
- **dir_walk_test** (parity not yet flipped): walker.next + for-over-Dir.walk-list are
  fixed, but the loop var `f` (element of `List(str)`) isn't typed `str`, so
  `f.endsWith(".zbr")` emits a literal `.endsWith` instead of `std.mem.endsWith`. Needs a
  **TypeChecker** change: infer the for-loop element type for a `Dir.walk`-initialised
  list var (the bootstrap relies on TC element inference for str-method dispatch). Likely
  more layers after (`files.count()`).
- **ws_smoke_test** (parity not yet flipped): the spurious closure capture is **fixed**
  (capture free-var analysis now excludes `if as` bindings — collectFreeVarsStmt +
  checkCaptureBoundaryStmt). Next layer: `ws.recv()` inside the closure doesn't dispatch
  as a `WsConn` method (`_WsConn` has no `recv`; needs `_ws_recv(ws)` — the closure body
  loses the param's `WsConn` type for stdlib-method dispatch).

### What it is
`tools/compile_check.sh` type-checks the Zig the **selfhost** emits (141/0/1 green).
Running the same check against the **bootstrap** emit (`--bootstrap`) yields
**120 passed / 14 FAILED / 8 skipped**: 14 positive-smoke tests where the bootstrap
emits Zig that does **not** type-check, while the selfhost emits correct Zig for the
same source. The selfhost is *ahead* of the bootstrap — this session's (and earlier)
stdlib/0.16 codegen fixes were applied to `selfhost/CodeGen.zbr` and never mirrored
to `src/CodeGen.zig`. It stayed invisible because no gate exercised the bootstrap's
**user-program** emit (`bootstrap_check.sh` only exercises the bootstrap emitting the
*compiler*, which happens not to hit these paths in a breaking way; the
compiler sources use e.g. `sys.cwd` only once and not the broken `.items`/HashMap
shapes).

**Proof of direction (sys.cwd):**
- `src/CodeGen.zig:6969,7314` → `std.Io.Dir.cwd().realpathAlloc(_io, …)` — the
  **0.16-removed** API (`error: no field … 'realpathAlloc' in 'Io.Dir'`).
- `selfhost/CodeGen.zbr:11620` → `std.process.currentPathAlloc(_io, _allocator)` — fixed.

### The 14, by root-cause cluster
- **ArrayList `.items` indexing (5):** `for_else_test`, `list_index_test`,
  `module_var_shadow_test`, `list_ref_autobox_test`, `bug119_list_field_param_test`.
  Bootstrap emits `xs[i]` / `xs` where the selfhost emits `xs.items[@as(usize, …)]`
  (`error: array_list … is not indexable` / `missing struct field: items`).
- **HashMap emission (4):** `hashmap_remove_test`, `hashmap_set_test`,
  `hashmap_field_collision_test`, `hashmap_param_field_test`. Bootstrap emits a
  bogus `HashMap(K,V).init()` (undeclared identifier; no allocator) where the
  selfhost emits `std.StringHashMap(V).init(_allocator)` + `_intern`/`catch`.
- **0.16 stdlib API (2):** `stdlib_additions_test`, `stdlib_misc_test` — `realpathAlloc`
  (above); likely other 0.16 renames in the same region.
- **Concrete→interface coercion (1):** `tc_iface_transitive_match_test` — known gap
  (see COMPILE_CHECK_STATUS.md): `var b: IBase = d` for concrete `d` is selfhost-only.
- **Individual (2):** `dir_walk_test` (`member function expected 1 argument(s), found 0`);
  `ws_smoke_test` (`use of undeclared identifier 'm'`).

### Repeatable gate (landed)
`compile_check.sh --bootstrap` was **non-functional** before this (it passed
`--output-dir` to the bootstrap, whose CLI emits to stdout and rejects the flag, so
every emit silently `continue`d → `0 passed, 0 FAILED`). Fixed 2026-06-27: bootstrap
mode now emits each root file to stdout, and skips multi-file dep tests (the bootstrap
stdout path can't materialize separate-module deps — those pass under the selfhost
whose `--output-dir` emits the deps too). The gate now reports the real 120/14/8.

### Fix plan (scoped — for a gated session)
Mirror each cluster's fix from `selfhost/CodeGen.zbr` into `src/CodeGen.zig`, one
cluster at a time, re-running `bootstrap_check.sh` (round-trip must stay byte-identical)
+ `compile_check.sh --bootstrap` after each. Start with the lowest round-trip risk
(realpath: the compiler uses `sys.cwd` once; ArrayList/HashMap shapes need checking
against compiler-internal usage first). Target: `--bootstrap` reaches the same
141/0 as the selfhost, restoring full equivalence. Then wire `--bootstrap` into the
parity gate so this can't silently regress again.

## BUG-142: missing required argument compiles + runs with garbage ✅ CLOSED 2026-07-31

**CLOSED 2026-07-31 — both directions are now hard ERRORS.** Sean's decision, taken
after the measurement below finally produced a trustworthy number.

**The measurement that unblocked it, and why it took three attempts.** The promotion was
gated on not regressing the Luau corpus, and the recorded baseline (1482) turned out to
be five weeks stale — see BUG-235. Two earlier scans returned "0 too-few", which looked
like good news and was actually a broken instrument: this entry documents ~28 too-few
sites, so **zero was the tell**. After the corpus was regenerated, a third scan with a
built-in control produced:

```
files scanned:   1581      (regenerated corpus, deduped)
files EMITTING:  1446
TOO FEW:         28 lines / 19 distinct files   <-- control PASSES, matches the ~28 on record
TOO MANY:         1 line  /  1 distinct file
```

The control passing is what made the rest believable. An instrument that cannot find a
thing you know is there has not told you the thing is absent.

**The two directions were never one decision, and the numbers prove it.** Luau lets you
omit trailing arguments (they become nil), so the translator emitted too-few calls
pervasively — 19 files. **Nothing in Luau needs EXTRA arguments**, and the whole corpus
held exactly ONE too-many site. Splitting the promotion by direction turned a 19-file
decision into a 1-file one for half the value; that split is what Sean approved.

**Both landed together anyway**, because the corpus is explicitly not frozen (Sean:
*"The corpus is not intended to be locked in yet"*) and because the too-few calls are
genuinely unsafe rather than merely untidy: codegen pads the missing argument with
`std.mem.zeroes`, so the callee reads a silent zero. The old warning left a program that
compiled, ran, and gave a wrong answer — which is the exact failure mode this tracker
exists for.

**Known cost, stated rather than discovered:** 19 of the 1,446 compiling corpus files
(1.3%) now fail. Each has a real bug. The proper fix is the translator emitting `= nil`
defaults for under-supplied trailing params — step 2 below, which already has a
prototype — not the compiler tolerating them. The 19 are listed in the session log.

**Fixtures moved in the same commit**, because a fixture asserting the old severity
fails the instant the promotion lands: `test/arg_count_test.zbr` `smoke_warn` →
`smoke_tc_fail`, and three boundary probes `warns` → `rejects`. Two of those had been
carrying `@boundary-pending BUG-142` since 2026-07-30 and had been authored asserting
this very rejection — they went red, and were rewritten back to the assertion they
started with. Pending count 3 → 1.

**Severity:** high (correctness/safety — silent wrong behavior).
**Status:** PARTIAL ✅ 2026-06-23 — (a) emits a non-fatal **warning**
(`too few arguments to 'X': expected N, found M`); (b) the **undefined-behavior is
gone**: codegen now pads an omitted no-default argument with `std.mem.zeroes(T)`
(a deterministic zero) instead of `undefined`, so a too-few-args call can no
longer read uninitialized memory. What remains for a full close: promoting the
warning to a hard **error** (gated on the translator follow-up below, so valid
Luau-nil-default calls aren't broken). Found 2026-06-22 via the error-experience
audit (`docs/error_experience_audit.md`).

### What shipped (warning)
A `checkArgCount` + `checkArgCountsInExpr` walker in `selfhost/TypeChecker.zbr`
runs in `checkStmts` over every statement's expressions (var-init, return,
assign, expr-stmt, `print`, and if/while/for/guard conditions). It compares the
provided arg count against the callee's declared params (via new
`fnParamList`/`fnParamListAny` accessors over the already-stored `fn_param_lists`),
counting **required = params without a default**. Conservative: only fires when
the callee's full Param list is known (resolved user free fn / method); builtins,
stdlib, closures-in-locals, and unresolved receivers are skipped. Reaches nested
calls like `print(add(1))`. Regression tests: `test/arg_count_test.zbr` (warns),
`test/arg_count_ok_test.zbr` (defaults + correct arity compile clean).
Round-trip byte-identical; smoke green.

### Why warning, not error (the corpus finding)
Making it a hard error regressed the translator corpus by 28 (1482→1454). The
failures were almost all **off-by-exactly-one** (`expected 4, found 3`) on
translated Luau functions (`playAnimation`, `Scale`, `CreateSubClass`, …): **Luau
permits calling with fewer args** (missing become `nil`), so the translator
pervasively emits too-few-arg calls relying on nil-defaulting. In Zebra those
calls are genuinely unsafe (they hit the `undefined`-padding), but flagging 28
pervasive translator outputs as errors is too aggressive. As a warning, the
corpus is unaffected (warnings are non-fatal → 0 arg-count failures, baseline
restored) while the issue is surfaced.

### DECISION (Sean, 2026-07-30): promote to a hard ERROR — both directions

Asked directly during the A3 boundary work, which had pinned the warning behaviour
and flagged the promotion as the one open question it refused to legislate. Sean's
answer: *"I think too few / too many should be an error and not a warning."*

**This unblocks the follow-up below, but does not make it free — the blocker is
cross-repo and still real.** The cost, restated against today's tree:

* The constraint is `GameEngine/tools/luau2zebra_ast.py` and its translated corpus,
  both of which still exist (translator last touched 2026-07-01). Luau permits
  calling with fewer arguments (missing become `nil`), so the translator pervasively
  emits too-few-arg calls. Promotion alone regressed that corpus 1482 → 1454.
* The severity split proposed below (error same-module, warn cross-module) does
  **not** dodge this: BUG-142's own investigation confirmed **all ~28 cases are
  same-module**, so the split still regresses by the full 28.

**MEASUREMENT ATTEMPT 2026-07-30 — INCONCLUSIVE, AND THE WAY IT FAILED IS THE
USEFUL PART. Do not treat its numbers as evidence.**

I scanned all 1,780 files in `GameEngine/ported_scripts` with the warning-era
compiler using `-c` (front-end-only, so arity is visible without invoking Zig —
~1.2 s/file). Raw result:

```
files scanned:            1780
TOO FEW  warning lines:   0
TOO MANY warning lines:   0
files that did NOT check cleanly (arity NOT measurable): 931   <-- 52%
```

**Zero too-few is the tell that the instrument was wrong, not that the corpus is
clean.** This very bug documents ~28 known too-few sites, and the translator fix
that would have removed them never landed — verified: `_collect_call_arity` and
`optional_from` do not exist in `tools/luau2zebra_ast.py`, so the prototype is
still reverted. Finding 0 where 28 are known to exist means the measurement
under-counted; had I only looked at the too-many row I would have read a broken
instrument as a green light.

**Why it under-counted:** 52% of the corpus never reaches the TypeChecker. The
scripts `use workspace / math / players / instance / ...`, which live in
`GameEngine/zbra/`, and module resolution searches the input file's directory then
Zebra's own `selfhost/`, `test/` and stdlib paths — never `zbra/`. So they fail at
resolution with `cannot find module` or `undefined name: 'RunService'`, and a
front end that stops there cannot report an arity diagnostic. `measure_corpus_
compile.py` has a dedicated `missing module import` bucket for exactly this.

**The tempting argument, and why it is not sufficient:** *a file that already fails
cannot be regressed by adding a new error, so the at-risk population is only the
~849 that check cleanly, where too-many is 0.* That is probably right, but it does
not reconcile with this bug's own figure of **1482** compiling files — 849 and 1482
cannot both describe the same success set, so at least one of the two instruments is
measuring something other than what it is being read as. Landing a promotion on an
argument with an unexplained factor-of-two in it would be exactly the mistake this
entry already warns about.

**The measurement that WOULD settle it** is an A/B with the project's own harness,
which is the instrument that produced 1482 in the first place: run
`GameEngine/tools/measure_corpus_compile.py` before the change, rebuild with the
promotion, run it again, diff the buckets. Same tool, same corpus, same cwd — so the
number is comparable to the one on record instead of a new number of my own.

**The compiler change itself is written and lint-clean** (`ctx.addWarn` →
`ctx.addErr` on the too-many arm of `checkArgCount`, selfhost only — the bootstrap
never had this check). It is deliberately NOT landed pending that A/B.

**Recommended landing order, given the decision is now made:**

1. **`too many` first, on its own.** The Luau rationale is entirely about too FEW
   (nil-defaulting). Nothing about the translator requires passing *extra*
   arguments, so this half should be promotable at zero corpus risk — **measure
   before assuming**, but it is the obvious clean split and delivers half the
   decision immediately.
2. **`too few` with the translator change**, per steps 1+2 below. That prototype
   already exists and took the corpus 1454 → 1458; two known gaps remain (the
   capture-extraction path reusing the param string as call arguments, and method
   `Invoke` forms the walk skips).

**Fixture consequences when this lands** (they are tripwires, not regressions):
`test/arg_count_test.zbr` moves `smoke_warn` → `smoke_tc_fail`, and the two A3
probes `test/boundary/bv_arity_too_few.zbr` / `bv_arity_too_many.zbr` flip from
`# @boundary warns` to `# @boundary rejects` and drop their
`@boundary-pending BUG-142` line. They are *designed* to fail at that moment.

### Follow-up to fully close (promote warning → error) — de-risked 2026-06-23

Investigated in depth (prototyped both sides, then reverted to the clean warning
state). Key findings for whoever finishes it:

- **All ~28 corpus too-few-args cases are SAME-MODULE** (the function is defined
  *and* called with fewer args in the same script). So the translator analysis is
  **per-script**, not cross-module — much more tractable. (Confirmed: a
  current-module-error vs dep-warn split in `checkArgCount` left the count at 28,
  proving none are cross-module.)
- **Lambda param defaults parse fine** (`var f = def(a, b = nil) = …` works), so
  that is not a blocker.

Remaining work, in order:
1. **Compiler — severity split** (ready, gate-clean in prototype): in
   `checkArgCount`, error when the callee is in `ctx.module_types` (same module —
   the signature is right there, almost certainly a real bug), warn when it
   resolves only via `dep_types`. On its own this regresses the corpus by the full
   28 (all same-module), so it must land *with* the translator change below.
2. **Translator** (`GameEngine/tools/luau2zebra_ast.py`): a per-script pre-pass
   (`_collect_call_arity`, walk the luaparser AST — **use a visited-id set**, nodes
   carry cyclic parent refs) records each bare-name callee's min observed arg
   count; `_emit_params(args, optional_from)` then emits the under-supplied trailing
   params with `= nil`. Prototype took the corpus 1454→1458 (fixed ~15 of 28) but
   surfaced two gaps to finish: (a) the **capture-extraction path** in
   `_emit_func_as_assignment` reuses the `params` string as *call arguments* to the
   hoisted `_lambda_N`, where `= nil` is invalid — separate the param **decl**
   string (with defaults) from the param **names** string (for the call); (b) the
   remaining ~13 are **method** calls (luaparser `Invoke`) and other non-bare-name
   forms the walk skips — extend the walk + match method defs (offset by the
   prepended `self`).
3. **Codegen** (already done): a missing no-default arg is padded with
   `std.mem.zeroes` not `undefined`, so the UB is gone regardless.
4. Land 1+2 together, confirm corpus stays ~1482, then gate + smoke; update the
   `arg_count_test` smoke fixture from `smoke_warn` → `smoke_tc_fail` (same-file).
~~Also: arg-count diagnostics currently report `0:0` in `print`/expr-stmt
positions because expression spans are `zspan()` placeholders.~~ ✅ RESOLVED
2026-06-23 — identifier and member expressions now carry real spans (the parser
captured them; the AST builder was discarding them), so the arg-count /
forgot-parens / arg-type diagnostics render precise carets. Only literal
arguments still fall back to the callee position.

### Original report (for context)

**What happens:** calling a function with fewer arguments than it has parameters
is not caught. Codegen pads the missing positional arg with `undefined`:
```
def add(a: int, b: int): int
    return a + b
def main()
    print(add(1).toString())   # → emits `add(1, undefined)` → prints garbage
```
`add(1)` runs and prints an uninitialized value (e.g. `140701535361921`) instead
of reporting "expected 2 arguments, found 1". A Zig compile would normally reject
the arity, but the `undefined` padding makes it type-check and execute.

**Root cause(s):**
1. Codegen pads omitted positional args with `undefined` (the same mechanism that
   should fill **defaults** — see BUG-139). For a param **without** a default,
   `undefined` is never correct.
2. The TypeChecker does not validate argument **count**. `checkCallExpr` checks
   arg *types* but (a) doesn't count args vs params, and (b) only runs on
   `Stmt.var_` init exprs, so a nested call like `print(add(1)…)` is never
   checked.
3. `ModuleTypes` stores `method_params` as a CSV of param **types** only — it does
   **not** record which params have defaults, so "required arg count" can't be
   computed yet.

**Fix approach (pairs with BUG-139):**
- Thread per-param default info into `ModuleTypes` (mirror of the bootstrap's
  BUG-182 Param-list-with-defaults storage), so `required = params without a
  default`.
- Add an arg-count check at the `Expr.call` arm of `inferExpr` (the universal
  expression walker — fires in every position, fixing reach issue 2b) with a
  caret diagnostic: too few args (< required) and too many (> total, modulo
  varargs/builtins).
- Be conservative to avoid corpus false-positives: only fire when the callee's
  full param list is known (resolved free fn / method in module or dep types);
  skip builtins/stdlib and unknown callees. **Verify against the full translator
  corpus** (`tools/corpus_probe.py`) before committing — a false "too few args"
  would break valid programs.

**Workaround today:** none at the language level; pass all arguments explicitly.

---

## Name-based container-dispatch audit (2026-06-22) — COMPLETE

After fixing the field-name-collision class of bug (BUG-138 List `.len`/`.count`,
BUG-140 HashMap index/`.count`/`.remove`/`.set`, BUG-141 List `[i]` read), the
remaining name-based container dispatches were swept for the same vulnerability.
Findings:
- **List index-write** (`list[i] = v`): already correct — emits `list.items[i] = v`.
- **StrSet `.count()` collision** (`fieldIsStrSet` is global name-based, and
  `enum_names`/`union_names` are StrSet in CodeGen but HashMap in TypeChecker):
  **benign** — the count emit is identical (`@as(i64, @intCast(obj.count()))`)
  whether classified as StrSet or HashMap, and both Zig types have `.count()`.
  Not "benign by luck": there is no observable difference, so no fix is warranted
  (a class-scoped `fieldIsStrSet` would be pure churn).
- **StrSet at the HashMap dispatch sites** (`.remove()`/`.set()`/index): already
  protected by BUG-140's class-scoping — `fieldAwareIsHashMap` returns false for
  a StrSet field (it isn't a `HashMap` generic), so StrSet ops don't mis-route.

Conclusion: the class is closed. The only name-based predicate left
(`fieldIsStrSet`) is provably harmless. New same-named container-field collisions
are now structurally safe at every read/count/remove/set/index site.

---

## BUG-141: indexing a List with `[i]` miscompiles (needs `.items[i]`) ✅ FIXED

**Severity:** medium (reachable, cryptic failure; non-idiomatic syntax so likely
rare in practice — `.at(i)` is the documented accessor).
**Status:** ✅ FIXED 2026-06-22 (selfhost-only). Index-read of a List receiver
(local or current-class/module-type field) now emits `obj.items[i]` instead of
`obj[i]`.

**Why selfhost-only:** the index-read dispatch already differs between the two
compilers and the selfhost is the richer (correct) one — the bootstrap's
`.index =>` arm does NO container dispatch (it emits `self.bag[k]` even for a
HashMap field, which is also invalid Zig), while the selfhost already turns a
HashMap `bag[k]` into `.get(k).?`. Adding List handling extends the selfhost's
existing dispatch and matches the dual-version policy (user-facing-only feature ⇒
selfhost-only; the bootstrap is the trusted regenerator and the selfhost source
indexes Lists via `.at()`, so the round-trip is unaffected). Bringing the
bootstrap index path up to full parity is a separate, larger cleanup if ever
needed.

**Fix** (`selfhost/CodeGen.zbr`, the `Expr.index` read arm): added
`fieldAwareIsList` (parallel to `fieldAwareIsHashMap`) and emit `.items` before
the `[` when the receiver is a List and not a HashMap. Regression test
`test/list_index_test.zbr` (local + field List index, runs end-to-end). Strings
/slices unaffected (still plain `[i]`). The index-**write** path (`obj[i] = v`)
and `.at(i)` were already correct.

### Original report (for context)
**Discovered** 2026-06-22 while building the BUG-140 repro.

**What happens:** indexing a `List` receiver with the `[i]` postfix operator
emits raw `obj[i]` instead of `obj.items[i]`. A `std.ArrayList` does not support
direct indexing, so the generated Zig fails to build:
```
error: type 'array_list.Aligned(i64,null)' does not support indexing
```
Reproduction (both a local and a field List trigger it; strings are fine):
```
def main()
    var nums = List(int)()
    nums.add(10)
    print(nums[1].toString())   # emits nums[@intCast(1)] — invalid; needs nums.items[...]
    var s = "hello"
    print(s[1].toString())      # OK — string is []const u8, slice indexing works
```
`nums[1]` is a natural thing to write, and the grammar lists `[i]` as a valid
postfix (QUICKSTART §ops table) even though `.at(i)` is the documented, working
List accessor (QUICKSTART line ~643). So the operator silently miscompiles rather
than working or giving a clean Zebra error.

**Scope:** the index-**read** path. Receivers that are a List *local* or a List
*field* both miscompile; string/slice/array indexing is correct as-is. The
write/assign path (`obj[i] = v`) and `.at(i)` are unaffected.

**Present in BOTH compilers** (so a fix must touch both, for functional
equivalence):
- bootstrap `src/CodeGen.zig` — the `.index =>` arm (~line 12137) emits
  `genExpr(object)` + `[ … ]` with no List special-case. NOTE: the `Type` union
  (`src/TypeChecker.zig:44`) has **no dedicated `.list` variant** — Lists are
  recognised at the `TypeRef` level (`tr.generic.name == "List"`), not as an
  inferred `Type`, so `tc.expr_types.get(e.object)` won't simply return "list".
  Detecting a List receiver here needs the declared TypeRef / resolve symbol of
  the object (field decl type, or the local's declared `List(T)`), not the
  inferred `Type`. There are also two index-emit paths (~8665 with
  `[@as(usize, @intCast(`, ~12137 with `[@intCast(`) — confirm which one(s)
  handle field/local List index reads before editing.
- selfhost `selfhost/CodeGen.zbr` — the `Expr.index` arm (~line 6824). Add a
  `fieldAwareIsList` (parallel to the new `fieldAwareIsHashMap`): local List
  wins, else class-scoped `isListField`, else `isKnownListField`/`fieldIsList`.
  Emit `.items` before the `[` when the receiver is a List.

**Equivalence note / verification plan:** while building the BUG-140 repro I also
noticed a *latent* cast-style divergence at this site — post-BUG-140 selfhost
emits `[@as(usize, @intCast(0))]` while bootstrap emits `[@intCast(0)]` for the
same `bag[0]`. It never manifests in the round-trip because the selfhost source
indexes Lists via `.at()`, not `[i]`. Any fix here should reconcile that too, and
must be verified by: implement both sides → `bootstrap_check.sh --update`
(bootstrap regen) → plain `bootstrap_check.sh` (selfhost regen) → confirm
`selfhost/*.zig` is unchanged between the two (proves bootstrap emit == selfhost
emit on the actual source). Plus a runnable regression fixture (`nums[1]` on a
local + a field List).

**Workaround today:** use `list.at(i)` (bounds-checked, emits `.items[i]`).

---

## BUG-140: selfhost HashMap dispatch was field-name-based, not class-qualified ✅ FIXED

**Severity:** medium (selfhost-codegen gap; the bootstrap was already correct).
**Status:** ✅ FIXED 2026-06-22. The sibling of BUG-138, for HashMaps: the
selfhost's HashMap member dispatch (indexing `obj[k]`, `.count()`, `.remove()`,
`.set()`, and index-assignment) decided "is field `X` a HashMap?" by **field
name across all classes** (`fieldIsHashMap`), so when two classes had a
same-named field of different container-ness, the dispatch mis-fired.

**Reproduction** (a `List(int)` field colliding with a same-named `HashMap`
field of another class, indexed):
```
class MapHolder
    var bag: HashMap(str, int)
class ListHolder
    var bag: List(int)
    def at0(): int
        return bag[0]
```
- **Selfhost** emitted `return self.bag.get(0).?;` — treating the `List` as a
  HashMap because `fieldIsHashMap("bag")` was globally true (from `MapHolder`).
- **Bootstrap** emitted `return self.bag[@intCast(0)];` — correct (class-scoped).

The selfhost emit is invalid Zig (`List` has no `.get`), so it was build-caught,
but it silently blocked any future selfhost code with a same-named List/HashMap
field pair. The selfhost source already has three such collisions one edge away
from biting: `enum_names` (StrSet vs HashMap), `union_names` (StrSet vs HashMap),
`module_fns` (HashMap vs a class type).

**Fix** (`selfhost/CodeGen.zbr`): added a class-scoped `isHashMapField`
(parallel to `isListField`, via `lookupFieldType` over the current class's
members) and a `fieldAwareIsHashMap` helper — a local var shadows any same-named
field (its type wins), then a field of the **current** class is authoritative
(do NOT fall through to the global name-based `fieldIsHashMap`). Replaced all
five `localIsHashMap(X) or fieldIsHashMap(…)` dispatch sites with
`fieldAwareIsHashMap(X)`. Selfhost-only (the bootstrap's symbol-table resolution
was already right). Round-trip byte-identical; smoke green; regression test
`test/hashmap_field_collision_test.zbr`.

---

## BUG-139: selfhost doesn't fill default `cue init` params at omitting call sites

**Severity:** low (easy workaround: pass the arg explicitly).
**Status:** OPEN, discovered 2026-06-22 while threading `source` into the Resolver
for the undefined-name caret.

**What happened:** a `cue init` with a trailing default param —
`cue init(file_name: str, source: str = "")` — does **not** get the default
filled in at call sites that omit it. `Resolver.Resolver(path)` emitted a 1-arg
Zig `init(path)` against a 2-param `init`, failing:

```
expected 2 argument(s), found 1
```

Every Resolver construction now passes the arg explicitly (`Resolver.Resolver(path, "")`
at the error-ignoring site, `…(path, src)` elsewhere), which is why the caret
shipped. The Parser's identical `source: str = ""` default never tripped this
only because every Parser construction already passed all args.

**Scope / open questions:**
- Default-fill clearly works *somewhere* (default params have been used before) —
  characterize precisely when it does/doesn't. Suspect it's **constructor**
  (`Type.Type(...)` cue-init) call sites specifically, vs. ordinary method calls.
- Bootstrap parity unknown: the bootstrap (Zig `src/`) likely fills defaults
  correctly (this surfaced only on the selfhost round-trip path). Confirm whether
  this is a genuine bootstrap-vs-selfhost divergence or a shared gap.

**Where to look:** selfhost call-emission for cue-init / constructor calls — the
arg-count/default-fill logic in `selfhost/CodeGen.zbr` (genCall / ctor path).
Compare against how the bootstrap fills missing trailing defaults.

**Payoff when fixed:** removes a latent foot-gun (silent "expected N args, found
M" on any defaulted cue init) and lets selfhost compiler code rely on init
defaults the way user programs can.

---

## BUG-138: selfhost `.len` dispatch was field-name-based, not class-qualified ✅ FIXED

**Severity:** medium (selfhost-codegen gap; the bootstrap was already correct).
**Status:** ✅ FIXED 2026-06-22. Root cause was narrower than first thought (not
`.split`): the selfhost's `.len`/`.count` member dispatch looked up "is this a
List field?" by **field name across all classes**, so when two classes had a
same-named field of different types (`source: str` on `Parser` vs `source:
List(PNode)` on `PInScope`), `self.source.len` on the str field wrongly emitted
`self.source.items.len` (`.items` on a `[]const u8`).

**Fix** (`selfhost/CodeGen.zbr`, the `.len`/`.count` member path): when the
member object is a field of the **current** class (`isFieldName`), trust the
class-scoped `isListField` answer and do NOT fall through to the name-based
`fieldIsList(.module_types, …)`, which false-positives on a same-named List field
of another class. Selfhost-only (the bootstrap's symbol-table resolution was
already right). Round-trip byte-identical; smoke 161/161; regression test
`test/field_name_collision_test.zbr` (`text=5 list=3`).

**Payoff:** unblocked the **caret/source-line** parser diagnostic — the Parser
now carries the source text and renders a `^` under the offending column
(committed alongside the fix), which previously hit this divergence.

### Original report (for context)
Discovered while adding a caret/source-line to parser diagnostics. The diagnostic
*message* improvement shipped first (d9b4ec3); the caret was reverted until the
codegen fix landed.

**What happened:** I added a field to `selfhost/Parser.zbr` to hold the source
text for caret rendering and used it with `split`:
- First as `var source_lines: List(str)` populated via `for ln in source.split("\n"): .source_lines.add(ln)`.
- Then reformulated as `var source: str` with a `sourceLine(li)` helper doing
  `for ln in .source.split("\n")`.

Both compile + run correctly when **zebra-bootstrap.exe** (the Zig compiler)
emits `Parser.zbr` — `zig build`, smoke 159/159 all pass. But the round-trip
gate fails at **selfhost-B build**: the **selfhost** compiler (selfhost-A)
re-emits `Parser.zbr` into Zig that references `.items` on a `[]const u8`:

```
selfhost/Parser.zig:4516:45: error: no member named 'items' in '[]const u8'
```

i.e. the selfhost codegen treats the `str` field (or the `split` result, or the
field's element/whole type) as a `List`/`ArrayList` at a use site while its Zig
type is a string slice — a type-inference inconsistency that only the **selfhost**
codegen has (the bootstrap gets it right), so it's a genuine bootstrap-vs-selfhost
divergence.

**Why it matters:** it means a `str`/`List(str)` field interacting with `.split`
can't currently be added to any of the `selfhost/*.zbr` compiler files (they
must round-trip). User programs are unaffected (they compile via zebra.exe,
which is fine — the bug is in *re-emitting* such code).

**To investigate / fix:**
- Build selfhost-A, have it `--emit-zig selfhost/Parser.zbr` with the reverted
  caret code re-applied, and inspect the emission around the `.items` site to
  see which expression's inferred type is wrong.
- Likely in `selfhost/CodeGen.zbr` / the InferCtx field-type or `split`-result
  handling — the selfhost infers the field (or the loop var, or `.len`) as a
  List where it's a str (or vice-versa).
- The reverted caret code (small) is the reproduction; re-apply from the
  d9b4ec3 parent's working-tree notes or re-derive (a `var source: str` field +
  `for ln in .source.split("\n")` + `.source.len`).

**Payoff when fixed:** unblocks the caret/source-line diagnostic (and any future
selfhost code that wants a split-derived string field) — a clean self-hosting-
duality fix.

---

## BUG-137: module-level `var`/`const` names can collide with file-scope decls

**Severity:** medium (correctness/usability for hand-written module vars).
**Status:** ✅ FIXED 2026-06-21 (commit pending). Module vars now emit with a
reserved `_zbr_mv_` prefix in both compilers; references are prefixed
identically, and a shadowing local/param keeps its bare name. The
translator-side mitigation discussed below is no longer required.

### Resolution

Both compilers emit a module-level `var`/`const` as `pub var`/`pub const
_zbr_mv_<name>` (constant `module_var_prefix` in `src/CodeGen.zig`; literal in
`selfhost/CodeGen.zbr` `genFieldDecl`). A reference that resolves to a module
var is emitted with the same prefix:

- **Bootstrap** (`src/CodeGen.zig` `genIdent`): keyed on the resolved symbol
  (`sym.decl.var_.is_top_level`) — sound per-reference, since a shadowing local
  resolves to its own symbol and keeps its bare name.
- **Selfhost** (`selfhost/CodeGen.zbr` `genIdent`): name-based via
  `isModuleVarName` (`module_types.fieldType("", name)`) guarded by
  `isLocalOrParamName` (`param_names` + `infer_ctx.hasLocal`). `genLocalVar` now
  binds every local (incl. unknown-typed) into `infer_ctx`; `noteShadowLocal`
  registers the other binding forms — for-in loop vars (`genForIn`), numeric
  loop vars (`genForNum`), `if … as` captures (`genIsCaptureThen`), and
  `branch … on V as r` captures (`genBranchTagged`) — so all shadow a same-named
  module var instead of being mis-prefixed.

Known minor limitation (selfhost only; the bootstrap is sound per-reference): a
binding's local-name entry in `infer_ctx` is not scope-popped, so within ONE
method a module-var reference that appears *after* a block/loop binding the same
name would be treated as the local. Pathological (a method using both a module
var and a same-named local in disjoint scopes); not seen in the corpus.

Verified: `test/module_var_collision_test.zbr` (preamble-name collision +
plain-local shadow) and `test/module_var_shadow_test.zbr` (for-in / for-num /
if-capture shadows, module vars untouched). Round-trip byte-identical; smoke
158/158.

### Original report (for context)

Module-level `var`/`const` (shipped 2026-06-21, commit 08802f6) emit as bare
file-scope `pub var`/`pub const NAME`. Zig **forbids any function-local or
parameter from shadowing a file-scope declaration**, so a module var whose name
matches *any* identifier used as a local/param anywhere in the emitted file
fails to compile with `local … shadows declaration of 'NAME'`. Two collision
sources:

1. **Runtime preamble** — uses many short/common local & param names. Observed:
   a module `var total` collides with a datetime helper's `const total`, the
   `_progress_bar(total: i64, …)` parameter, *and* a `var total` local — three
   hits from one name. `g`, `s`, `c`, `i`, `node`, `out`, `count`, `label`,
   `config`, `enabled`, `player` … are all landmines.
2. **User's own locals** — a user function declaring `var count` when a module
   `var count` exists is also rejected (same Zig shadow rule).

**Why not fixed in-compiler now:** the sound fix is to move user module vars out
of bare file scope — emit them inside a container struct
(`const _M = struct { pub var total: i64 = 0; };`) and rewrite references to
`_M.total`. The **bootstrap** (`src/`) can do this soundly because the resolver
binds each ident to its declaration (`DeclVar.is_top_level`), so `genIdent`
knows per-reference whether a `total` is the module var or a shadowing local.
The **selfhost** codegen has **no general local-name set** (only typed-local
sets: `strset_locals`, `chan_locals`, …), so it cannot disambiguate a module-var
reference from a same-named local without new local-name tracking on the hot
`genIdent` path. That makes the guard a medium, two-compiler change with several
round-trip gate cycles — deferred while the parallel Zig-0.17 work is in flight.

**Interim mitigation (in use):** the GameEngine Luau→Zebra translator
(`tools/luau2zebra_ast.py`) emits module vars with a reserved prefix
(`_mod_<name>`) for both the declaration and every reference it generates, and
never emits a shadowing local — fully sound for generated code, zero compiler
risk.

**Fix when picked up:**
- `src/CodeGen.zig` — emit module vars in a `_M` container struct (or a reserved
  prefix); `genIdent` already has `is_top_level`, so reference rewriting is local.
- `selfhost/CodeGen.zbr` — same container/prefix emit in `genFieldDecl`
  (owner == "" path) and `genIdent`, **plus** a `method_local_names: StrSet`
  threaded through the generator (reset per method, populated by
  `genLocalVar`/params/for-binds/captures) so `genIdent` only prefixes a name
  that is a module var **and not** a shadowing local.
- Add a smoke fixture: a module var named after a known preamble local (e.g.
  `total`) that compiles and runs.

**Discovered:** 2026-06-21, immediately after shipping module-level var/const
(Stage 1). Probe: `var total = 0` at module scope + any function → shadow error.

---

## BUG-136: `zebra file.zbr` run path captures child stdout instead of streaming

**Severity:** low (UX / capability — affects interactive programs, not
correctness of batch programs)
**Status:** OPEN — known limitation, decision pending (fix vs. leave as-is).

When `zebra file.zbr` runs a program, the selfhost driver
(`selfhost/main.zbr`) invokes the child via `sys.run(argv)`, which **captures**
the child's stdout/stderr into strings and prints them *after* the child exits
(`Terminal.write(rr.stdout, "")` / `sys.err(rr.stderr)`). The Zig-side
bootstrap (`src/main.zig`) does the same on its non-fast path (`runChildRemapped`
captures stderr for source-map remapping). Consequences:

- **No streaming** — output appears all at once when the program finishes, not
  as it is produced. A long-running program looks hung until it exits.
- **No interactivity** — a program that reads stdin or expects a live TTY
  (prompts, REPL-like loops, progress bars) won't work, because the child's
  stdio is piped, not inherited.

This is **pre-existing**, not introduced by the debug-run fast path (2026-06-20,
commit f9a05d1): the fast path's exec step (`sys.run([fast_exe])`) merely follows
the same capture convention the LLVM `zig run` path already used, so behavior is
unchanged either way. The fast path's *build* step legitimately needs capture
(to inspect exit code for fallback); only the *exec* step is the candidate to
change.

**Why it's not obviously a bug:** capture is *required* on the Zig backend's
LLVM path so stderr can be run through `remapZigErrors` (rewrites generated-`.zig`
line numbers back to `.zbr` source lines). Streaming would lose that remapping
for compile-time errors — though for the **fast-path exec** step the child is a
user program (its stderr is the program's own output / panic trace, not Zig
compiler errors), so inheriting stdio there is safe and would restore both
streaming and interactivity for the common debug-run case.

**Possible fixes (decide later):**
1. Fast-path exec only: spawn `fast_exe` with inherited stdio (needs a
   `sys.runInherit`-style API in the selfhost runtime; the bootstrap already has
   `runChild` with inherited stdio — `src/main.zig`). Scoped, low-risk; fixes the
   common case without touching the error-remapping path.
2. General: detect "is this a run (not compile-error) context" and inherit stdio
   for the program while still capturing the compiler's own diagnostics
   separately. More invasive.

Repro: a `.zbr` that prints in a loop with a sleep between lines — under
`zebra file.zbr` nothing appears until it exits.

## BUG-135: non-deterministic source-path markers in emitted .zig

**Severity:** low (cosmetic — affects only the `// Source:` / `// zbr:file:line`
comment markers — but it makes regenerated artifacts differ run-to-run, which
is what makes `update-selfhost` show a spurious diff)
**Status:** FIXED. Slash axis: source-fixed 2026-06-17 (`writePathFwd` /
`fwdSlashes`). Case axis: eliminated 2026-06-18 by the PascalCase file rename —
every `.zbr`/`.zig` pair now matches case, so there is no mismatch for MSYS to
mangle. Artifacts refreshed to the bootstrap canonical; regen is idempotent.

Emitted markers echoed the *verbatim* input path. On Windows + Git Bash, MSYS
argument mangling rewrites the `.zbr` path passed to the compiler
**non-deterministically** — sometimes `selfhost/codegen.zbr`, sometimes
`selfhost\codegen.zbr` (slash), and for the `parser`/`resolver` files whose
`.zig` artifact is capitalized but `.zbr` source is lowercase, sometimes
`parser.zbr` vs `Parser.zbr` (case). So two regen runs of the *same* file could
differ in hundreds–thousands of marker lines with no semantic change.

Fix (slash axis, both compilers): `src/CodeGen.zig` `writePathFwd` + `selfhost/
codegen.zbr` `fwdSlashes` normalize the marker path to forward slashes at emit
time, so the slash is deterministic and portable regardless of how the shell
passes the path. The **case** axis (parser/resolver) is *not* addressed — it is
rooted in the intentional `parser.zbr` → `Parser.zig` naming (the `.zig` mirrors
the hand-written `src/Parser.zig`, and is cross-imported by that capital name in
`build.zig` and many emitted files). Eliminating it would require a coordinated
rename, so it is left for the artifact-refresh pass, which is best run on a
case/slash-stable environment (Linux/CI) where neither axis is mangled.

Note: a single `selfhost/X.zig` cannot be regenerated in isolation — emit shape
(root vs dep, e.g. the aggregated `_zbr_error_msg`) differs and mixing shapes
crashes at runtime (see `tools/bootstrap_check.sh` header). The whole set must
be regenerated together (`update-selfhost`).

---

## BUG-134: bootstrap rejects re-exported cross-module type identity

**Severity:** medium (a type defined in module C, surfaced through module B's
method return, and re-imported in module A, fails A's return/assign check with
`type mismatch: expected 'T', got 'T'`; selfhost accepts it, so the compilers
diverge)
**Status:** FIXED 2026-06-17. `src/TypeChecker.zig` `isAssignable` now treats two
`cross_module` types as assignable when their `type_name` matches, regardless of
the `.module` label — cross-module type identity is by name (the type is the same
re-exported Zig declaration at every hop), with Zig as the backstop. This mirrors
the selfhost's `typesCompatible`, which returns `true` for any non-primitive pair.
`Type.eql` is left unchanged (it still requires module+name for cross_module
identity, so generic-arg/identity comparisons elsewhere keep their strictness);
only the assignment/return-check path is loosened.

Surfaced by GameEngine `instance.zbr`: `World.getSize(): Vector3?` (World in the
`ecs` module, `Vector3` re-exported there from `math`) returns a value the
bootstrap labeled `ecs.Vector3`, while `instance.zbr`'s declared return `Vector3`
resolved to `math.Vector3` — same Zig type, different `.module` label, so
`Type.eql` rejected `return s`. This was only *reachable* after BUG-133 stopped
stripping the optional. Regression: `test/crossmod_optret_*` is a 3-module
re-export chain (geom defines Vec3 → lib's `World.getSize(): Vec3?` → test
re-imports Vec3 and returns the unwrapped binding). With both fixes,
`instance.zbr` compiles under the bootstrap and the selfhost.

---

## BUG-132: bootstrap `genIf` panics on `else if <call> as <bind>`

**Severity:** low (codegen crash on a specific else-if shape; workaround =
nested `else { if … as … }`)
**Status:** FIXED 2026-06-17 — `src/CodeGen.zig` `genIf` now routes every clause
(head + each else-if, in both the capture-headed and plain-headed paths) through
a new `genIfCaptureClause` helper that decides the clause form (union-variant
check / optional unwrap / plain) from *its own* condition. Clauses in one chain
may now mix forms freely. This brings the bootstrap up to the **selfhost**, which
already factored this into `genIsCaptureThen` (so this was a bootstrap-only
divergence — no selfhost change needed). Regression: `test/if_unwrap_test.zbr`
extended with three mixed-chain cases (union-head+optional-elseif,
optional-head+union-elseif, plain-head+optional-elseif).

`src/CodeGen.zig` `genIf` (~9640) read `ei.cond.type_check` for an `else if`
condition, assuming the `is X as y` form — but an else-if whose condition is an
**optional-unwrap on a call** (`else if structNameFromType(et) as snm`) has an
active `.call` union field, so it panicked: `access of union field 'type_check'
while field 'call' is active`. The first `if … as …` (non-else) handled this
correctly; only the `else if` path assumed type_check.

---

## BUG-133: bootstrap strips `?T` from cross-module method returns

**Severity:** medium (a cross-module method declared `: T?` is inferred as `T`
by the bootstrap TC, so `if x as n` on its result errors; selfhost handles it,
so the two compilers diverge — this is §27c)
**Status:** FIXED 2026-06-17 (§27c). `src/TypeChecker.zig` now records an
`optional_method_returns` set on `ModuleInterface` (parallel to the existing
`optional_ref_fields`): when a public method's declared return is `T?` for a
user-defined `T`, its `"Type.method"` key is recorded. The three cross-module
method-return consumption sites build the result via a new
`crossModuleMethodReturnType` helper that re-wraps the `cross_module` type in
`.optional` when the key is present. `src/main.zig`'s `cloneInterface` and the
empty/cycle interface mirror the new field. Regression:
`test/crossmod_optret_test.zbr` (+`_lib`) exercises `if w.getSize() as s` across
a module boundary.

Root cause: `simpleTypeFromRef` collapses `nilable(<user-type>)` to `.unknown`
(since user types don't cross the arena boundary), and `instance_method_return_types`
only stored the bare type *name* (`namedTypeStr` unwraps the nilable), so the
optionality was lost. The **selfhost** stores the full `Type_` (via `typeFromRef`,
which maps `nilable → optional`), so it never had the bug — this was bootstrap
catch-up. GameEngine `instance.zbr` (cross-module `World.getSize(): Vector3?`,
`getTransform(): CFrame?`) now compiles under both compilers.

---

## BUG-131: inline capture-lambda to a `sig` param triple-emits the anon struct

**Severity:** medium (blocked the natural inline `signal.connect(def() capture
… )` idiom — the common Roblox `:Connect(function() … end)` shape)
**Status:** FIXED 2026-06-16 — both compilers now emit the closure value ONCE
into `_zbr_val_N` and derive the create's `@TypeOf` + the assignment from that
local, so they share one type.  (The dispatcher still re-derives its type — it's
a nested fn that can't see the local — but it only reinterprets a type-erased
pointer between layout-identical structs, which is sound.)  Round-trip
byte-identical, smoke 152/152.  Verified: inline `signal.connect(def() capture
…)` compiles and runs.  Discovered 2026-06-16 (GameEngine TweenService.Completed).

`emitCallWithClosureThunks` (the Gap-1 closure-via-sig path) emits the closure
value `genExpr(a.value)` **three times** — inside `@TypeOf(...)` for the
`_allocator.create`, in the `_zbr_cls_N.* = …` assignment, and inside the
dispatcher's `@TypeOf(...)`.  For an **inline** capture-lambda each emission is
a distinct anonymous `(struct {…}{…})` literal, and Zig gives each its own
type, so:

```
const _zbr_cls_1 = _allocator.create(@TypeOf((struct {…}))) …;  // *T1
_zbr_cls_1.* = (struct {…});                                    // T2 != T1  ← error
```

→ `error: expected type 'main__struct_60370', found 'main__struct_60375'`.

**Why it's been latent:** the **ident-bound** form
(`var f = def() capture …; sig.connect(f)`) works, because all three emissions
are the same named variable `f` (one type).  Gap-1 / BuildingTest used that
form, so the inline form was never exercised.  (thread_pool's earlier
anon-struct error was the *same* root cause, masked once BUG-128 stopped it
thunking `submit` at all.)

**Repro:** `signal.connect(def() capture { var x = x }; …)` — any inline
capture-lambda passed to a `sig`-typed parameter.

**Fix applied:** bind the closure value to a local `const _zbr_val_N = <closure>`
once, then `create(@TypeOf(_zbr_val_N))` + `_zbr_cls_N.* = _zbr_val_N`.  This is
the minimal change that fixes the create-vs-assignment type clash (the two
checked, same-scope emissions).  The dispatcher keeps its independent
`@TypeOf(<re-emit>)` — it can't see the local — but it only `@ptrCast`s the
type-erased pool pointer and the structs are layout-identical, so the round-trip
is sound.  A fuller fix (a container-scope named type shared by all three) was
considered but not needed for correctness; the stability-minimal change was
chosen.

---

## BUG-130: ~~methodMutatesSelf marks some non-mutating methods `*self`~~ NOT-A-BUG

**Status:** CLOSED — NOT-A-BUG 2026-06-16.  Misfiled.  The compiler does **not**
auto-analyze mutation; `genMethod` gates `self: *const Owner` purely on the
explicit `@pure` modifier (`src/CodeGen.zig` ~5018: `if (n.mods.pure) "*const "
else "*"`).  The observed inconsistency was a **source** gap: GameEngine's
`Vector3.lerp` was marked `@pure` while the identical `Color3.lerp` /
`Vector2.lerp` were not.  Resolved by adding `@pure` to those methods in the
GameEngine `zbra/math.zbr` (engine commit 935f0de); the `lerpProperty`
mutable-local workaround was dropped.  No compiler change.

(Original misfiling retained below for context.)

**Severity:** low — discovered 2026-06-16 (GameEngine property-reflection work).

`Color3.lerp` and `Vector2.lerp` emit `pub fn lerp(self: *Color3, ...)` while
`Vector3.lerp` — with a structurally **identical**, non-mutating body (returns a
fresh struct built from `self`'s fields, no field writes) — correctly emits
`pub fn lerp(self: *const Vector3, ...)`.  The Gap-2 `@pure`/methodMutatesSelf
analysis (commit 1757706) is therefore inconsistent: it proves Vector3.lerp pure
but not the identical Color3/Vector2 versions.

**Symptom:** calling the method on a value bound from a union variant (`if x is
U.col as c` → `c` is `*const`) fails to compile: `expected type '*math.Color3',
found '*const math.Color3'`.

**Repro:** GameEngine `zbra/math.zbr` Color3.lerp vs Vector3.lerp; see
`zbra/instance.zbr::lerpProperty`, which works around it by copying the receiver
to a `var` local.

**Likely cause:** the analyzer's mutation walk over the method body is
order/shape-sensitive (e.g. treats the `Color3(...)` constructor-from-`.r/.g/.b`
differently than `Vector3(...)` from `.x/.y/.z`), or short-circuits on the first
type and doesn't re-run identically per type.  Fix: make the purity walk
structural so identical bodies yield identical `*const` decisions.

---

## BUG-125: selfhost --emit-zig user-script mode emits cross-module union ctors as tag-calls

**Severity:** medium (blocks user scripts from constructing ECS Components directly)
**Status:** FIXED 2026-06-09 — selfhost now honors `--module-path`; deps found
there are parsed for types only (not emitted), so exposed cross-module unions
classify correctly.  Root cause: `compileDep_use` only searched the source's
own directory, so `use ecs` from `game/scripts/` never parsed `zbra/ecs.zbr`
and `dep_types` never learned `Component` is a union.  Fix: `MultiCompiler`
gained a `module_path` field + `scanDepForTypes` (parse + `populateModuleTypes`,
no emit), wired through `--module-path`.  The bootstrap already handled this;
this brought the selfhost to parity.  `tools/wire_script.py` now passes
`--module-path <engine>/zbra`.  Verified: `Component.anchored(true)` →
`Component{ .anchored = true }`.

**Follow-up 2026-06-09:** `scanDepForTypes` also now registers the dep's
class names in `dep_class_names`, so a script that stores a cross-module
class instance in a field or capture (e.g. `var t: Vector3Tween`) emits the
field/param as `*T` (reference type) instead of by-value — without this,
storing the constructor result (`*Vector3Tween`) into a value-typed field is
a `*T`-vs-`T` mismatch.  Consequence: scripts compiled with `--module-path`
now take their class-typed `main(...)` params by pointer (`*Instance`,
`*RunService`), so the host dispatch passes `inst`/`run` directly rather than
`inst.*`/`run.*`.  Pre-`--module-path` scripts (value params) are unaffected.

**Symptom:** In a `.zbr` file under `game/scripts/` compiled via `zebra.exe --emit-zig`, calls of the form `Component.transform(cf)` (where `Component` is a cross-module union imported via `use ecs exposing Component`) emit literally as `Component.transform(cf)` in Zig — which the Zig compiler rejects with:

```
error: type '@typeInfo(ecs.Component).@"union".tag_type.?' not a function
```

The correct emit, observed for the SAME pattern in stdlib `.zbr` files (`zbra/physics.zbr`, `zbra/humanoid.zbr` — both `use ecs exposing World, Component`), is `Component{ .transform = cf }`.

**Repro (in `C:\Projects\GameEngine`):**
```zebra
# game/scripts/repro.zbr
use ecs exposing Component, World

def main(world: World)
    var cf = ...
    world.addComponent(eid, Component.transform(cf))   # → broken Zig in --emit-zig
```

Failure persists across: nested call args, ident-bound vars, staged locals, and helper-wrapped return statements. The discriminator is *where the .zbr lives* (script vs stdlib), not the syntactic shape.

**Workaround:** Hide the union ctor behind a stdlib method. See `zbra/workspace.zbr`'s `spawnBox` / `setEntityPosition` (and `zbra/workspace.zig` hand-impl) for the pattern used by `game/scripts/orbit_follower.zbr`.

**Discovered:** OrbitFollower case study (4th hand-ported script), 2026-06-09.

---

## BUG-126: Gap 1 closure-via-sig thunk uses per-call-site state slot (last-wins)

**Severity:** medium (blocks two scene instances of the same script that share a `connect()` call site)
**Status:** FIXED 2026-06-09 — replaced the single module-level state slot per
call site with a **trampoline pool** of K=64 (state slot, thunk fn) pairs.
Each connection reached at a call site grabs the next free slot via a
monotonic `_zbr_next_N` counter and is handed a distinct `_zbr_thunks_N[slot]`
fn-pointer bound to its own `_zbr_state_N[slot]`.  A bare Zig fn-pointer
carries no context, so K distinct code addresses are fundamentally required;
the pool bounds concurrent connections at one call site.  Overflow (>K live
connections through one source line) panics with a clear message rather than
silently dropping earlier connections (the old last-wins behaviour).  Fixed in
both `src/CodeGen.zig` (flushPendingThunks + emitCallWithClosureThunks) and
`selfhost/codegen.zbr`; round-trip clean.  Verified: the OrbitFollower
two-instance scene now ticks Follower1 AND Follower2 independently (was
Follower2 only).  **Remaining limitation:** `_zbr_next_N` is monotonic, so
connect/disconnect churn leaks slots; and K is a hard ceiling.  A truly
unbounded fix needs the `sig` ABI to carry a context pointer (fat pointer) —
deferred until a use case needs >64 live connections or dynamic disconnect.

**Symptom:** Each call site that connects a closure to a `sig`-typed signal handler synthesizes a single module-level state cell (`_zbr_state_N: ?*anyopaque`). When the same `connect()` call is reached twice in one program execution (e.g. two scene instances of the same script), the second call overwrites the cell. The first closure is orphaned — its `Heartbeat`/`RenderStepped` handler never fires again, even though the connection appears successful.

**Repro (in `C:\Projects\GameEngine`):** `game/scripts/orbit_follower.zbr` loaded twice as `Follower1` and `Follower2` in `demo_scripts.zbr-scene`. Both `[orbit_follower:FollowerN] connected` messages print; only Follower2's tick lines appear thereafter. Confirmed visually: Follower1's spawned cube sits stationary at its initial position; Follower2's cube orbits.

**Fix direction:** Have `signal.connect(handler)` return a connection ID and have the thunk store a *map* of state cells keyed by ID, rather than a single slot per call site. Existing single-subscriber Roblox-style code stays correct; multi-subscriber works.

**Discovered:** OrbitFollower case study, 2026-06-09. Flagged as unverified concern in the TimerTest case study (`docs/TIMER_TEST_CASE_STUDY.md`); empirically falsified by the OrbitFollower two-instance scene.

---

## BUG-127: selfhost emits negative-literal `var` initializer without type annotation

**Severity:** low (annotation workaround is trivial)
**Status:** FIXED 2026-06-09 — `genLocalVar`'s literal-shape annotation branch
now handles `Expr.unary` (neg of int/float literal), emitting `: i64`/`: f64`
like the bare-literal case.  Used `branch un.operand` (not `is`) so the `^Expr`
deref round-trips identically under bootstrap and selfhost.  Verified:
`var a = -6.0` → `var a: f64 = (-6.0);`.

**Symptom:**
```zebra
var x = -6.0   # emits: var x = (-6.0);  → Zig: comptime_float not const/comptime
var y = 0.0    # emits: var y: f64 = 0.0; (correct)
```

Positive literal initializers widen to `f64`; negative literals (unary minus) emit as a bare comptime expression that Zig rejects when the binding is `var` rather than `const`.

**Workaround:** Annotate explicitly: `var x: float = -6.0`.

**Discovered:** OrbitFollower case study, 2026-06-09.

---

## BUG-128: Gap 1 thunk path over-applies to `sys.go` / `ThreadPool.submit`

**Severity:** high (broke two shipped 1.0 concurrency features — `Chan`+`sys.go`, `ThreadPool` — for closure arguments, in *both* compilers)
**Status:** FIXED 2026-06-16 — `genCall`'s Gap-1 gate routed *any* call with a
closure argument into `emitCallWithClosureThunks`, before the `sys.go`
(`_sys_go`) and `ThreadPool.submit` handlers could run.  Those consumers take
the closure *struct* directly via `anytype` dispatch, but the thunk path handed
them a bare fn-pointer and emitted the callee verbatim (`sys.go(...)` →
undeclared `sys`; `pool.submit(thunk)` → anon-struct type-identity mismatch).

**Root cause:** introduced by BUG-126 (commit 48a3aad).  The Gap-1 thunk exists
only to satisfy bare `sig` fn-pointer parameters, but the gate never checked
that — it fired on the mere presence of a closure arg.

**Fix:** a *negative* gate (`callNeedsClosureThunks` /
`isStdlibClosureStructConsumer` in both `src/CodeGen.zig` and
`selfhost/codegen.zbr`): thunk every closure arg EXCEPT those passed to the two
stdlib closure-struct consumers (`sys.go`, `<pool: ThreadPool>.submit`).  In
Zebra *user* code a closure value can only be typed through a `sig` param (no
user-writable `anytype`), so this never un-thunks the cross-module `sig` case
(`Signal.connect`) that Gap 1 exists for — verified with an isolated
cross-module repro (`evt.connect(closure)` → `evt.connect(_zbr_thunks_1[...])`).

**Discovered:** WIP-branch merge gate (`chan_thread_test` + `thread_pool_test`
smoke failures), 2026-06-16.

---

## BUG-129: bare `Atomic.add(...)` statement misses the `_ =` discard (bootstrap TC)

**Severity:** medium (any `Atomic(int).add/sub/swap/load` used as a bare
statement fails to compile under the bootstrap compiler — Zig "value of type
i64 ignored")
**Status:** FIXED 2026-06-16 — pre-existing, independent of BUG-128 (fails even
at top level, not just in closures).  `src/TypeChecker.zig` had no `Atomic`
inference, so `counter.add(1)` typed as `.unknown`, and the CodeGen discard rule
(`t != .void_ and t != .unknown`) skipped the `_ =`.  `atomic_test` only passes
because it captures every non-void return (`var old: int = counter.add(3)`).

**Fix:** `atomicElemType` + an Atomic arm in `inferCall` (`add/sub/swap/load` →
element type `T`, `cas` → bool, `store` → void).  The selfhost already handled
this in codegen via `atomic_locals` (the `inferExpr`-can't-see-Atomic
workaround); its method set was widened to `{add,sub,swap,load,cas}` to match
the bootstrap so both compilers emit the discard identically.

**Discovered:** unmasked by the BUG-128 fix while greening `thread_pool_test`,
2026-06-16.

---

> BUG-029 and BUG-030 were resolved incidentally in the selfhost implementation — see `BUGS_FIXED.md`.

Fixed / closed bugs have been moved to `BUGS_FIXED.md`.

---

## BUG-086: struct pattern — cross-module type names not supported

**Severity:** low (pre-1.0 gap)  
**Status:** closed — fixed in commit 343ddac

`on Mod.Point(x: 0)` is now recognized as a struct pattern. Three fix sites:
- `src/AstBuilder.zig` `liftStructPattern`: accepts `.member` callee (Mod.TypeName) alongside plain `.ident`
- `selfhost/parser.zbr`: `isOpenCallAt(offset)` helper + `id "." open_call` detection in `parseBranchStmt`
- `selfhost/astbuilder.zbr` `tryBuildStructPat`: handles `Expr.member` callee

---

## Library Files with No Entry Point (Expected "Failures")

These are not bugs — they're library files that can't run standalone:
- `MathUtils.zbr` — utility class, imported by `crossmod_*`, `use_test`, `transitive_test`
- `StringHelper.zbr` — utility class, imported by `transitive_test`

---

## Intentional Error Tests (Correct Behavior)

These fail WITH A COMPILER ERROR — that IS the test passing:
- `branch_infer_miss_test.zbr` — expects error for non-exhaustive branch
- `branch_missing_test.zbr` — expects error for missing variant
- `capture_error.zbr` — expects error for undeclared capture

---

## Open Bugs

### BUG-196: container-method dispatch broken on `List(List(T))` ✅ RESOLVED (2026-07-23)
Two filed faces: (a) `.len`/`.at` on a `for` binding over `List(List(T))` → "no field
'len' in ArrayList(...)"; (b) `.add` on a `List(List(float))` local → "no member 'add'".
**Root of (a):** `genForIn`'s general List-iteration path registered the loop var in
`for_loop_vars` and special-cased `List(str)`/JSON elements, but never bound the loop
var's TYPE in `infer_ctx` for a general element — so for a nested `List(List(T))` the
inner-List loop var was untyped, and `.len` fell through to the string-shaped `.len`
instead of `.items.len` (and `.at` similarly). **Fix:** in `genForIn`, when the
iterable's element type is itself a container (`Type_.list_`/`Type_.hashmap_`), bind the
loop var to that element type (`ic_for.bind(vname, for_elem_t)`), so container-method
dispatch resolves on the binding. Scoped to container elements so struct/str/primitive
loops are unchanged (they had no working behavior to regress). Face (b) as filed no
longer reproduces (`.add` on the outer `List(List(float))` runs). Verified typed AND
untyped iterables. Regression: `test/bug196_nested_list_test.zbr` (smoke_run "bug196: 43").
Deeper nested-container facets found while probing are filed separately as BUG-201.

### BUG-195: `.entries()`/`.keys()`/`.values()` on a HashMap *parameter* ✅ RESOLVED (2026-07-24)
The `_zebra_map_keys`/`_values`/`_entries` preamble helpers did `@TypeOf(map).KV`; a
HashMap passed as a fn parameter is a `*HashMap`, and `.KV` is not a decl on the pointer
(worked on a local). Fixed in the shared `selfhost/stdlib_preamble.zig` (read by BOTH
compilers at emit time — one fix covers both): added `_MapKV(comptime T)` that derefs a
pointer (`@typeInfo(T) == .pointer`) before reading `.KV`, used in all three helpers. All
three methods now work on a map param. Verified selfhost (entries=30/keys=2/vals=30) and
the bootstrap emit compiles. Regression: `test/bug195_map_param_test.zbr` (smoke_run
"bug195: 62"). Gates all green. No compiler rebuild needed for the fix (preamble is read
at emit time), but regen confirmed clean.

### BUG-194: `Math.log` missing in the selfhost ✅ FIXED (2026-07-18, divergence burn-down)
Was: in the bootstrap (`src/CodeGen.zig:8055`) but not selfhost `genMathCall` —
`Math.log(x)` fell through to `std.math.log` (a 3-arg fn) → "expected 3 argument(s),
found 1". Added the natural-log handler `std.math.log(f64, std.math.e, @as(f64, x))`
(+ `isNaN`→`isNan`, `isInf`, `atan2` while converging `math_test`). Surfaced again by
the selfhost↔bootstrap divergence audit.

### BUG-193: `File.listDir` missing in the selfhost ✅ RESOLVED (2026-07-24)
Was: implemented in the bootstrap but the selfhost emitted `@compileError(...)`. Ported
from the bootstrap (`src/CodeGen.zig:7855`): added `listDir` to the selfhost's
`genFileCall` (a `blk:` expr opening the dir with `.iterate`, duping each entry name into
a `List(str)` — names are slices into the iterator's reused buffer, so the dupe is
required) and its `List(str)` return type to `TypeChecker` File-method inference (beside
`readLines`). Verified: lists a real dir (3 names, sorted, `.len`/iteration dispatch).
Regression: `test/bug193_listdir_test.zbr` (smoke_run "bug193: OK"). Gates all green.
Note: like the bootstrap, `listDir` does NOT path-normalize — pass a native path.

### BUG-119: ✅ FIXED 2026-05-18 — `list_field_names` reverse index in ModuleTypes

`List` fields accessed through function parameters now emit `.items.len` correctly.

**Fix:**
- `selfhost/typechecker.zbr ModuleTypes`: added `list_field_names: HashMap(str, bool)` field (parallel to `hashmap_field_names`), `addListField(name)` + `hasListField(name)` methods; initialized in `cue init()`.
- `selfhost/typechecker.zbr`: added `isListTypeRef(tr: TypeRef): bool` helper (mirrors `isHashMapTypeRef`).
- `selfhost/typechecker.zbr addClassMembers`: after the `isHashMapTypeRef` check, added `if isListTypeRef(v.type_ to!)` → `mt.addListField(v.name)`.
- `selfhost/codegen.zbr`: added `fieldIsList(mt, dep_mt, field_name): bool` helper (parallel to `fieldIsHashMap`); `.len` handler now includes `fieldIsList(.module_types, .dep_types, fn2)` in the `is_list_obj` check.

Test: `test/bug119_list_field_param_test.zbr` (smoke_run: "bug119_list_field_param: OK").
Bootstrap verified: `zig build update-selfhost` + smoke 117/117 passing + bootstrap 5/5.
- **Discovered:** 2026-05-06 while compiling `IDE/ZebraIDE.zbr`.

---

---

### BUG-115: ✅ FIXED 2026-05-14 — `private` / `internal` visibility keywords shipped

`private` and `internal` keywords implemented and enforced by both compilers:
- **Zig backend (`src/TypeChecker.zig`):** `checkMemberVisibility` at line 2185 checks `mods.private` / `mods.protected`; error if accessed outside the owning class. `extractModuleInterface` already skips `private`/`internal` members from cross-module export.
- **Selfhost (`selfhost/typechecker.zbr`):** `ModuleTypes.private_member_keys: HashMap(str, bool)` reverse index populated by `addClassMembers`; `inferExpr Expr.member` checks `isPrivateMember` and emits `"'X' is private"`.

Original open question (resolved by implementing):
- **Status (2026-05-04):** Design question — add keywords, or drop the `_` convention?
- **Decision (2026-05-14):** Implement keywords. Both backends enforce `private` (per-class) and `internal` (treated as protected/module-scoped). Sweep: `_` convention retained only for compiler-emitted internals (`_allocator`, `_arena`, etc.).
- **Evidence:** NEXT_STEPS.md `[x] BUG-115` entry marked complete 2026-05-14.
- **Source:** `STYLE_GUIDE.md` §1 Q3.

---

### BUG-114: `0 - x` / `0.0 - x` instead of `-x` — ✅ SWEPT 2026-05-06
- **Severity:** N/A
- **Status:** Closed — sweep complete; no `0 - x` / `0.0 - x` occurrences remain in any `.zbr` file.
- **Source:** `STYLE_GUIDE.md` §13.3.

---

### BUG-110: ✅ FIXED 2026-05-05 — bind error prints clean message instead of panic
- **Severity:** Low (only triggers on bind failure; rare in practice)
- **Status:** Fixed — `selfhost/stdlib_preamble.zig`: `catch |e| @panic(...)` replaced with `std.debug.print` + `return`. Http.serve remains non-throws (making it throws would ripple into TC/codegen — deferred).
- **Original description:**
- **Symptom:** The runtime `_http_serve` handles bind failure with `... .listen(.{ .reuse_address = true }) catch |e| @panic(@errorName(e))`. On any bind failure (port busy with `reuse_address = false`, permission denied for low ports, address-not-available), the program dies with a Zig panic and stack trace rather than a clean error. Counterpart of BUG-107 (TC halt-on-diagnostics audit) but at runtime: the failure is communicated by panic rather than by the language's structured error path.
- **Reproducer:** With BUG-109 fixed (`reuse_address = false`), running `server_test.exe` twice produces a panic on the second run instead of a clean error message.
- **Root cause:** `src/CodeGen.zig` emits the `catch |e| @panic(@errorName(e))` pattern in `_http_serve`. The right shape is to make `Http.serve` `throws` so callers can `catch |err| { print "Could not bind: ${err}" }`.
- **Fix sketch:** Change `Http.serve`'s declared signature to `throws` (in the typechecker's stdlib bindings); update the emit so the bind error propagates as `anyerror!void` rather than panicking. Callers that don't care can still `Http.serve(...) catch unreachable`. Pairs naturally with BUG-109 — both are policy decisions about how the runtime communicates bind problems.
- **Discovered:** 2026-05-04, alongside BUG-109.
- **Source:** Side-finding from `test/server_test.zbr` port-busy fix.

---

### BUG-109: ✅ FIXED 2026-05-05 — `.reuse_address` flipped to `false`
- **Severity:** Medium (footgun for test apps; not a crash, but a "wait, why are four copies running?" surprise)
- **Status:** Fixed — `selfhost/stdlib_preamble.zig` line 525: `reuse_address = true` → `false`.
- **Original description:**
- **Symptom:** The runtime `_http_serve` (emitted by `src/CodeGen.zig`) calls `std.net.Address.initIp4(.{0,0,0,0}, port).listen(.{ .reuse_address = true })`. The `reuse_address = true` setting allows multiple processes to successfully `listen()` on the same port; the OS load-balances incoming connections across them. Concrete observed consequence: 2026-04-21 → 2026-05-04 the box accumulated 4 stray `server_test.exe` processes all coexisting on 8080, undetected until manual `netstat` inspection.
- **Reproducer:** Run `server_test.exe` (built from `test/server_test.zbr`) twice in succession in separate terminals — both bind successfully and both serve traffic. No error from the second bind.
- **Root cause:** `src/CodeGen.zig` emits `.reuse_address = true` unconditionally in the `_http_serve` preamble (line ~459 in current emitted output). The flag is appropriate for fast-restart-after-crash workflows (avoids TIME_WAIT delay) but inappropriate for "did I accidentally start two of these?" detection.
- **Fix sketches (pick one):**
  1. **Flip to `.reuse_address = false`** — simplest; OS rejects duplicate binds. Cost: TIME_WAIT delay if the same port is rebound within ~60s after a clean shutdown. For test apps this is fine; for production restart loops it's friction.
  2. **Make it configurable:** `Http.serve(port, handler, reuse: false)` with a default that we pick. Cost: tiny API change, ripples through codegen.
  3. **Probe-bind hybrid:** keep `reuse_address = true` but also attempt a `Tcp.connect` probe first and refuse if it succeeds. Cost: small race window between probe and bind; doubles the syscall surface.
- **Workaround in use:** `test/server_test.zbr` now does the probe-then-bind dance manually at the user level (see commit 7fe29ae). Every other `Http.serve` caller would have to do the same until this is fixed centrally.
- **Discovered:** 2026-05-04 cleanup of the 4 stray instances.
- **Source:** Side-finding from `test/server_test.zbr` port-busy fix.

---

### BUG-107: ✅ VERIFIED 2026-05-18 — codegen never runs on a diagnosed tree

Verified all three entry points halt before codegen when diagnostics are present:

1. **`src/main.zig:396`:** `if (had_error) return 1;` — after collecting `bind.diags`, `resolve.diags`, `tc.diags`. CodeGen is invoked only on the `else` path.
2. **`selfhost/main.zbr:130-132`:** `if tc_ctx.hasErrors()` → `sys.errln(tc_ctx.errorMessages())` → `sys.exit(1)`. Explicit process exit before Step 5 (Zig emit).
3. **`src/Repl.zig:439-443`:** `had_error` checked after `bind.diags`, `resolve.diags`, `tc.diags`; `if (had_error) return null;` before `CodeGen.generate`.

Property holds. No code change needed.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-5]).

---

### BUG-100: ✅ FIXED (side-effect of BUG-099, 2026-05-05)
- **Symptom was:** `else => unreachable` panic when `for k, v in <non-var ident>`.
- **Fix:** The BUG-099 three-way Type split rewrote the surrounding TC block; the
  `is_hashmap_two_var` switch now uses `else => null` (line ~1321 current), so
  a method/class/namespace ident simply yields `hm_dt = null` and the loop falls
  through to normal for-in handling — no panic.
- **Verified 2026-05-05:** `for k, v in getMap()` + HashMap two-var smoke pass.

---

### BUG-097: ✅ FIXED 2026-05-08 — `*ArrayList` chain call three-case logic
- **Severity:** Medium (any function that takes a List/HashMap as a mutating out-param can't itself call helpers that take that container by value)
- **Status:** Fixed:
  - `src/CodeGen.zig`: added `caller_ptr_params: ?*const std.StringHashMap(void)` field to `Generator`; populated in `genMethod` for non-TCO methods; `argIdentInCpp` helper; three-case logic in both positional and named paths of `genArgs`.
  - `selfhost/codegen.zbr`: `caller_ptr_params: StrSet` field added + initialized; `withMethodCtx` creates fresh StrSet; `genMethod` populates it after `withInferCtx`; `argIdentInCpp` method on `Generator`; three-case logic in `genArgListNamed`, method dispatch named-reorder path, and method dispatch positional path.
  - Test: `test/bug097_ptr_param_chain_test.zbr`; added to `selfhost_smoke.sh`.
  - Bootstrap 5/5.
- **Original description:**
- **Symptom:** With BUG-091's mutation-driven `*ArrayList` conversion, a function signature like `def freeVars(t: Term, out: List(str))` emits `out: *std.ArrayList(...)`. Two follow-on issues then surface in the same body:
  1. **Recursive call:** `freeVars(child, out)` — the call site still emits `&out` (because the formal param is mutating-container), producing `**ArrayList` for an arg expected as `*ArrayList`.
  2. **Helper call:** `hasName(out, name)` where `hasName` takes `out: List(str)` non-mutating (so its sig stays `ArrayList`). The call site emits `hasName(out, name)` with no `.*` deref, producing `*ArrayList` for an arg expected as `ArrayList`.
- **Reproducer:** see `examples/lambda_calc.zbr`'s commit history — the original `freeVars(t: Term, out: List(str))` shape ran into both above; the file was rewritten to return-by-value instead.
- **Root cause:** the `&` insertion in `genArgs`/`genArgListNamed` didn't account for the caller's param already being `*ArrayList`. The decision rule now distinguishes:
  - arg is value, formal is `*Self` → emit `&arg` (original BUG-091 behavior)
  - arg is already `*Self`, formal is `*Self` → emit `arg` (Case 1: no double `&`)
  - arg is already `*Self`, formal is value → emit `arg.*` (Case 2: deref)
- **Workaround (obsolete):** restructure to return-by-value, or thread the container through a class field.
- **Discovered:** 2026-04-30 while writing `examples/lambda_calc.zbr`.

---

### BUG-096: ✅ FIXED 2026-05-07 — `List(SomeClass)()` constructor now pointer-wraps class type args
- **Severity:** Low (only triggers when storing class instances in Lists declared as fields)
- **Status:** Fixed:
  - `selfhost/codegen.zbr genTypeFromExpr`: added `if class_names.contains_(id.name)` check before `zigPrimitive`; emits `"*" + id.name` for class types, matching `genType`'s behaviour.
  - Zig backend (`src/CodeGen.zig genType`) was already correct; this was a selfhost-only gap.
  - Test: `test/bug096_list_class_ctor_test.zbr`; added to `selfhost_smoke.sh`.
- **Original status:** Open
- **Symptom:** `class Holder { var results: List(Result) = ... }` where `Result` is a class. The field type emits as `std.ArrayList(*Result)` (correct — classes are reference-typed), but the constructor expression `List(Result)()` emits `std.ArrayList(Result){}` (without the pointer). Zig rejects the assignment with a type mismatch.
- **Reproducer:**
  ```zebra
  class Result
      var msg: str = ""
      cue init(m: str)
          this.msg = m

  class Holder
      var results: List(Result)
      cue init()
          this.results = List(Result)()      # ✗ field is List(*Result), ctor builds List(Result)
  ```
- **Workaround:** make the element type a `struct` rather than a `class` (the workaround used by `book_run.zbr`'s `Result` type), or assign via `[]` empty-list literal once that path supports class element types.
- **Discovered:** 2026-04-30 while writing `book_run.zbr`.

---

### BUG-094: ✅ FIXED 2026-05-05 — HashMap two-var for-in works in both backends
- **Severity:** Medium (the QUICKSTART-canonical iteration form is unusable; the rest of the book has examples that won't compile)
- **Status:** Fixed:
  - `selfhost/codegen.zbr`: `_ = kname;` discard is now guarded by `nameUsedInStmts`; same guard added for `vname`.
  - `src/CodeGen.zig genForIn`: early dispatch `if (s.vars.len == 2) return genForInHashMap(s)` added before the type-inference path (Zig backend was falling through to native for-loop syntax, causing "extra capture" error).
  - Test: `test/bug094_hashmap_kv_test.zbr` (all 4 k/v used/unused permutations); added to selfhost_smoke.sh.
- **Original description:**
- **Symptom:** Both backends fail on `for k, v in some_hashmap`:
  - **Selfhost (`zebra.exe`):** emits `const name = ...; _ = name;` immediately followed by usage in the loop body — Zig rejects with "pointless discard of local constant ... used here". Even when the discard is suppressed, `print "${name}: ${age}"` falls back to `{any}` for `name` because the formatter doesn't see the `[]const u8` type for the for-binding.
  - **Zig backend (`zebra-bootstrap.exe`):** rejects the syntax outright with "extra capture in for loop" — the multi-binding form was never wired up here.
- **Reproducer:**
  ```zebra
  def main()
      var ages = HashMap(str, int)()
      ages.put("Alice", 30)
      for name, age in ages
          print "${name}: ${age}"
  ```
- **Workaround:** Read values back via `.get(known_key)` for spot lookups; iterate with a parallel `List(str)` of keys when you genuinely need to walk the whole map.
- **Doc claim:** QUICKSTART §10 documents `for k, v in m` as the canonical iteration. Either fix both backends to support it, or amend the doc to point at the working pattern.
- **Discovered:** 2026-04-30 while sweeping the book's Chapter 3 examples for the verbosity rewrite.

---

### BUG-093: ✅ FIXED 2026-05-05 — `s.len` now emits `@as(i64, @intCast(...))` — returns `int`
- **Severity:** Low (was forcing awkward workarounds; comparisons still worked)
- **Status:** Fixed:
  - `src/CodeGen.zig`: `isStringTypeName(n.name) and prop == "len"` path emits `@as(i64, @intCast(s.len))`.
  - `selfhost/codegen.zbr`: same `@as(i64, @intCast(...))` wrapper in the genMember string path.
  - Test: `test/bug093_strlen_test.zbr` (commit `dbd6fda`); added to `selfhost_smoke.sh`.
- **Original symptom:** `s.len` codegenned as `.len` on `[]const u8` (usize), causing `var n: int = s.len` and `s.len - 3` arithmetic to fail with type mismatch.
- **Discovered:** 2026-04-29 while writing `book_extract.zbr`.

---

### BUG-090: ✅ FIXED 2026-05-08 — `for n in Reflect.fieldNames(obj)` element type is now `str`
- **Severity:** Low (cosmetic; iteration itself is correct)
- **Status:** Fixed:
  - `src/TypeChecker.zig inferForInElemType`: added `Reflect.fieldNames` / `Reflect.fieldTypes` arm alongside `Net.resolve` — returns `.string`.
  - `selfhost/typechecker.zbr isStrListCallExpr`: added `fieldNames` / `fieldTypes` to the member-name check.
  - Test: `test/bug090_reflect_fieldnames_test.zbr`; added to `selfhost_smoke.sh`.
  - Bootstrap 5/5.
- **Original description:**
- **Symptom:** Iterating a `Reflect.fieldNames(obj)` result (or any other `[]str`-returning stdlib call) loses the element type, so `print n` inside the loop emits the byte-array fallback instead of the string.
- **Reproducer:**
  ```zebra
  class User
      var name: str = ""
      var age: int = 0

  class Main
      static
          def main
              var u = User()
              u.name = "Alice"
              for n in Reflect.fieldNames(u)
                  print n               # prints `{ 110, 97, 109, 101 }` then `{ 97, 103, 101 }`
              print u.name              # prints `Alice` correctly — direct field access is fine
  ```
- **Generated Zig:** `for (_reflect_User_fields[0..]) |n| { std.debug.print("{any}\n", .{n}); }` — `n` is `[]const u8` but the print emits `{any}`.
- **Root cause:** for-loop variable element-type propagation gap.  TC infers the iter source as `[]str` / `str_slice` but doesn't record `n`'s element type into the per-statement `expr_types` map that the print-emission path consults.  Same bug class as BUG-089 (TC propagation gap surfaces as wrong print format), different code path.
- **Workaround:** Assign through a `: str`-annotated temp inside the loop before printing.
- **Related:** BUG-017 (legacy `len`-on-unknown-type fallback).
- **Discovered:** 2026-04-28 while spot-verifying QUICKSTART.md §25 reflection example.

---

### BUG-089: ✅ FIXED 2026-05-08 — mixin method return type correctly inferred; methods emitted into class
- **Severity:** Low (cosmetic — wrong output format; does not affect type-annotated locals)
- **Status:** Fixed:
  - `src/TypeChecker.zig inferMember`: after `own_scope.lookupLocal` misses, iterate `sym.decl.class.adds` and look up each mixin's `own_scope` (resolver populates these). Returns `tc.symbolType(member_sym)`.
  - `selfhost/typechecker.zbr populateModuleTypes`: two-pass fix — pass 1 registers mixins as their own `ClassTypes`; pass 2 merges mixin methods into each class that `adds` them via `addClassMembers`.
  - `selfhost/codegen.zbr genClass`: after own members, iterate `n.mixins`, find matching `Decl.mixin_` in `module_decls`, and call `ig.genMethod` for each mixin method.
  - `selfhost/codegen.zbr count dispatch`: before `.items.len` fallback, check via `inferExpr` if receiver is a class with a user-defined `count()` method — if so, pass through as a normal call.
  - `selfhost/parser.zbr`: added `mixin_: ^PClass` to `PNode` union; `parseMixinDecl()`; `adds` clause parsing in `parseClassDecl`; `mixins: List(str)` field to `PClass`.
  - `selfhost/astbuilder.zbr`: added `buildMixin()`, `PNode.mixin_` dispatch arm, and mixin TypeRef population in `buildClass`.
  - `selfhost/main.zbr`: updated `PClass(...)` constructor call to pass `mixins` field.
  - Test: `test/bug089_mixin_method_test.zbr`; added to `selfhost_smoke.sh`. Bootstrap 5/5.
- **Original description:**
- **Symptom:** Calling a mixin method that returns `str` directly inside `print` emits the bytes as a `[]const u8` integer-array fallback instead of as text.
- **Generated Zig:** `std.debug.print("{any}\n", .{f.hi()});` — wrong format specifier; should be `"{s}\n"`.
- **Root cause:** TC `inferMember` didn't search `adds Mixin` scopes for methods — returned `.unknown`. Also, selfhost didn't parse `mixin` declarations or `adds` clauses at all.
- **Discovered:** 2026-04-28 while spot-verifying QUICKSTART.md examples.

---

### BUG-228: `--release` produced an UNOPTIMIZED binary — FIXED 2026-08-03
- **Status:** Fixed. Gated by `tools/release_mode_check.sh` (FULL tier).
- **Was:** `zebra --release` switched the backend to LLVM — a real, visible change (20 MB
  to 2 MB) — but the branch that actually emits an executable passed **no optimize flag**,
  so Zig defaulted to **Debug**. `release` was consumed in three places; the other two (the
  node-addon build, and a `mode_c` branch carrying `-fno-emit-bin`) were fine. The ordinary
  exe path was not among them. **Anyone shipping with the flag shipped Debug believing
  otherwise** — the flag's entire purpose.
- **Fix:** `-OReleaseFast` on that branch. **ReleaseFast, not ReleaseSafe**, per Sean's
  2026-07-30 direction: make ReleaseFast good enough that ReleaseSafe does not buy much,
  and settle it by A/B testing with users rather than by argument. That is the
  Design-by-Contract position — contracts are checked in development and stripped for
  release *because* they established the property, so a release build should not re-check
  at runtime what the contracts already proved.
- **ORDERING WAS LOAD-BEARING and the ticket said so.** The flag also enables
  `unreachable`-is-UB, which A4 removed on 2026-07-30. Adding it earlier would have turned
  an unoptimised-but-safe build directly into an optimised one with UB on OOM.
  `tools/lint_oom_unreachable.py` was confirmed clean (0 hazards) **before** the line was
  written.
- **Verified by SIZE, not timing** (a shared machine makes timings worthless): the same
  emitted `.zig` built three ways — `zebra --release` **813 KB**, reference Debug
  **1872 KB**, reference `-OReleaseFast` **800 KB**. `--release` lands on the ReleaseFast
  figure.
- **Gated, because nothing else in any tier uses the flag.** `release_mode_check.sh`
  asserts the release build RUNS and prints the right answer, and that its binary is
  materially smaller than the same program built without. The size check is
  **self-calibrating** — two binaries built in the same run, not a recorded number, since a
  hardcoded size rots on the next Zig release. Verified RED against the exact regression it
  guards (compare release against itself → `812 KB vs 812 KB → FAIL`).
- **A skipped size check counts as a FAILURE.** The first version of the gate could not
  locate either binary and printed "all checks pass" with its only real assertion never
  having run — caught before it shipped.

---

### BUG-247: a non-ASCII byte was reported as a character that is not in the source — FIXED 2026-08-03
- **Status:** Fixed. Pinned by `test/bug247_nonascii_diag_test.zbr` (`smoke_run_fail`).
- **Found by Sean**, 2026-08-03, reasoning from BUG-225: *"`Lexer.zbr:116` is `def peek():
  char` returning `src[pos]` — if we had unicode source files, we'd run into a risk here."*
  The hypothesis was right; the shape was not what either of us expected.
- **What was NOT wrong** (established first, by experiment):

  | case | result |
  |---|---|
  | non-ASCII in a **string literal** | ✅ `"café naïve"` round-trips, 12 bytes |
  | non-ASCII in a **comment** | ✅ works |
  | non-ASCII **char literal** `c'é'` | ✅ works, prints `é` |
  | non-ASCII **identifier** | ❌ rejected — correct, Zebra identifiers are ASCII |

  **There is no silent corruption of Unicode source.** The lexer copies bytes through
  strings and comments transparently, and every classification is an ASCII range
  comparison, so a high byte simply matches nothing and is rejected.
- **Was:** the rejection MESSAGE. `lexErr` renders `src[pos]` — a raw byte typed `char`
  (BUG-225's pathology) — with `.toString()`, widening lead byte `0xC3` to U+00C3. A user
  who typed `café` was told:

      2:12: unexpected character 'Ã'

  The column was right and **the character was fiction** — there is no `Ã` in the file.
  A reader then hunts for a character they never typed.
- **The bootstrap already had this right** (`unexpected character (byte 0xC3)`), despite
  the selfhost's comment claiming it "Mirrors src/Tokenizer.zig's diag handling". A
  selfhost-lags-bootstrap divergence in diagnostic quality.
- **Fix:** bytes above 0x7F get a message that is honest AND actionable —
  `unexpected non-ASCII byte — identifiers and operators must be ASCII (non-ASCII text is
  fine inside a string literal or a comment)`. No char→int conversion was introduced:
  none exists anywhere in the selfhost (every classification is a range comparison), and
  adding one for a diagnostic would be the wrong trade. Compared against `0x7F` rather
  than `0x80` because **`c''` is not a writable char literal** — a UTF-8 continuation
  byte is not a valid Unicode scalar.
- **Relationship to BUG-225:** this is that bug surfacing in the compiler's own UX. Fixing
  it does not fix BUG-225, which remains a language design decision (§5c of the quality
  audit) — but it removes the one place where the incoherence actively misleads a user.

---

### BUG-227: `str.tokenize(seps)` split on the SEQUENCE, not on any character — FIXED 2026-08-03
- **Status:** Fixed. Pinned by `test/bug227_tokenize_any_test.zbr`.
- **Was:** codegen emitted `std.mem.tokenizeSequence`, so `"a,b;c".tokenize(",;")` returned
  **one** token — the entire string — with no error at any stage. QUICKSTART documents
  "split on ANY character in `seps`".
- **Fix:** `tokenizeAny` at both selfhost dispatch sites. The implementation was changed to
  match the documentation rather than the reverse, because the documented behaviour is what
  makes `tokenize` distinct from `split` — `split` already covers the whole-sequence case
  and **deliberately keeps `splitSequence`** (verified unchanged: `"a<>b<>c".split("<>")`
  → 3, `"a,b;c".split(",;")` → 1).
- **Blast radius zero, as the ticket predicted:** no `.zbr` in the repo calls `str.tokenize`
  (the only `.tokenize(` hits are `Lexer.tokenize(src)`, an unrelated user method).
- **Bootstrap deliberately left on the old emit** — no selfhost source calls `str.tokenize`,
  so the selfhost-leads policy applies (same call as `Shell` earlier today).
- **The fixture uses MULTI-CHARACTER separators throughout**, which is the only input that
  distinguishes the two implementations: with a single-char `seps` they agree, so a test
  using `","` would have passed under the bug. Confirmed to FAIL against the unfixed
  compiler before being registered.

---

### BUG-245: QUICKSTART's `sys.go` examples never compiled, and `Shell.run` was unmigrated — FIXED 2026-08-03
- **Status:** Fixed. Smoke 288/288. Pinned by `test/bug245_shell_process_run_test.zbr`.

**Found 2026-08-03** while writing the §1b fixtures — by trying to follow the doc.

`QUICKSTART.md` is the **authoritative agent-facing reference**, and its entire
concurrency section wrote thread spawning as `sys.go(lambda …)`. Five code blocks, plus a
prose claim that "the lambda can capture variables from the enclosing scope". **None of it
compiled.**

| form, verbatim from the doc | result |
|---|---|
| `sys.go(lambda  var _ = total.add(1) )` | `'var' is a statement keyword and can't be used as an expression here` |
| `sys.go(lambda` + block | parse error **at `lambda`** |
| `sys.go(lambda t.add(1))` | parse error at `lambda` |
| implicit capture of an outer var | `'t' not accessible from inner function` |

`lambda` is **not a Zebra keyword at all**. Every occurrence of the word in the corpus is
in a *comment* describing lambdas conceptually; the syntax is `def(params)`, and captures
need an explicit `capture` block. `test/chan_thread_test.zbr` has always had it right.

**Why no gate could see it.** `doc_lint` checks that referenced *paths* and *tools* exist,
and prints its own uncovered list — the first entry of which is "prose claims about
BEHAVIOUR … needs an experiment". A code block that does not compile is exactly that. The
only instrument that finds this is someone running the examples.

**Fixed**: the concurrency sections now show `def()` + `capture`, each form verified by
running it. The shared-counter example was removed rather than translated, because it hits
**BUG-246**.

**Also fixed, same investigation — a real code defect** (`Shell.run`, gated by
`test/shell_test.zbr`): the selfhost emitted `std.process.Child.run(.{...})`, which does
not exist in Zig 0.16 — the allocator and `Io` are positional
(`std.process.run(_allocator, _io, .{...})`) and `max_output_bytes` is gone. Additionally
`Shell.run` had no TypeChecker arm, so its result typed as unresolved and no `str` method
would dispatch on it. **Third instance of the same pattern as BUG-241/242**: a namespace
with no run coverage was never exercised, so its Zig 0.16 migration never happened and
nothing could find out. The bootstrap still emits the stale form; not fixed there, per the
selfhost-may-lead policy — `Shell` is not used by any selfhost source.

---

### BUG-242: the entire `Csv` namespace was dead in the selfhost — FIXED 2026-08-03
- **Status:** Fixed. `csv_test` passes end to end; registered with `smoke_run`.
- **The ticket understated it.** It read "`Csv.` reading appears to work; it is the writer
  half that has no implementation". Reading did **not** work. `csv_test` failed at line
  **6** — `rowCount` — before it ever reached the writer at line 95. Nothing in the
  namespace worked; the two symptoms had different causes and had to be peeled in order:

  | # | fault | where |
  |---|---|---|
  | 1 | `CsvWriter()` emitted **verbatim** into Zig — no constructor | `CodeGen` bare-stdlib-ctor branch |
  | 2 | `_csv_writer_init` returned `.{ .buf = .{} }` — missing `capacity` | preamble, Zig 0.16 migration |
  | 3 | `Csv.parse` result had **no type**, so no method dispatched | `TypeChecker` namespace arm |
  | 4 | `build()` printed a **byte array** (`{ 97, 44, 98 }`) not a string | `TypeChecker` return type |
  | 5 | table local emitted `var`, never mutated → Zig error | `CgHelpers.isByValueHandleType` |
  | 6 | `_csv_parse` reassigned `.{}` to unmanaged ArrayLists (5 sites) | preamble, Zig 0.16 migration |
  | 7 | `HttpResponse.withHeader` missing entirely (csv_test uses it) | `TypeChecker` + `CodeGen` |

- **Fault 4 is the one worth remembering.** It produced *valid Zig that compiled cleanly*
  and printed the wrong thing — the BUG-226 class. `compile_check`, `full_sweep` and
  `divergence` would all have passed it at any corpus size. Only running the program shows
  it, which is why this landed with a `smoke_run` rather than a registration alone.
- **Faults 2 and 6 are the same missed migration**, and they explain the ticket's wrong
  reading: the Csv parser's *declarations* were updated to `.empty` but its in-loop
  *reassignments* were left as `.{}`. Nothing could reach the code to discover it, so a
  half-finished migration sat there looking complete. A scan of the rest of the preamble
  found no other instance.
- **The two halves have DIFFERENT histories** — established from `git log -S`, not inferred:

  | half | status | evidence |
  |---|---|---|
  | reader | **regression**, 2026-05-19 | `aef05d1 wip: partial Zig 0.16 upgrade (incomplete — 6 errors remain)` |
  | writer | **never worked in the selfhost** | `git log -S "_csv_writer_init" -- selfhost/CodeGen.zbr` returns NOTHING; the bootstrap has had it since `0e71d45` |

  Before `aef05d1`, `.{}` was correct and used *consistently* — declarations and
  reassignments alike. The migration converted the declarations and missed the
  assignments, and the reason is mechanical rather than careless: **`var x: T = .{}`
  carries its type and `x = .{}` does not**, so a migration keyed on the type annotation
  cannot see the assignment. Worth remembering the next time a Zig upgrade is done by
  pattern.

  The commit *announced* itself as unfinished. What was missing was not honesty but any
  instrument that would later ask whether the remaining errors ever got closed —
  `csv_test` would have answered on day one, and nothing ran it. Same root as BUG-243,
  reached from the other direction: the work was unfinished **in the open**.
- **The writer half is a class, not a one-off — and the class is now enumerated**, by
  `tools/unreachable_runtime.sh`. A runtime helper present in the preamble and emitted by
  `src/CodeGen.zig`, but emitted by *no* selfhost source, is unreachable from
  selfhost-compiled programs — which is also why its migration never happened. Validated
  non-circularly: run against the commit before this fix it lists exactly
  `_csv_writer_init` / `_csv_write_row` / `_csv_build`; run after, zero.

  **Result: 73 helpers, 72 of them `_stub_*`/`_gui_*`** — expected, not a finding, since
  `--gui-backend=*` delegates to the bootstrap by design. **Exactly one real entry
  remains: `_build_auto_run`**, which the bootstrap appends to the end of top-level `main`
  in build-script mode (`src/CodeGen.zig:4775`, `:6549`) and no selfhost source emits.
  Narrow, but the same shape — recorded here rather than fixed, since it needs its own
  look at whether the selfhost has a `build_mode` at all.
- **Design note — no new `Type_` variant.** The bootstrap has `.csv_table` / `.csv_row` /
  `.csv_writer`. The selfhost has none, and `Type_` is referenced 950+ times, so adding
  variants means auditing every exhaustive `branch`. Instead these dispatch on
  `Type_.named("CsvTable")` / `named("CsvWriter")`, which the type system already produces
  for unknown names. **CsvRow needed nothing at all**: `_csv_header`/`_csv_row` return
  `std.ArrayList([]const u8)`, which is exactly how `List(str)` is represented, so rows are
  typed `List(str)` and inherit `.at()`/`.len` from the existing list arm.
- **Test:** `smoke_run test/csv_test.zbr "csv_test: all assertions passed"` — a behaviour
  check, not a compile check: it writes a comma-bearing field, re-parses the output and
  compares, so RFC 4180 quoting is exercised round-trip.

---

### BUG-241: `Progress.` has not compiled since Zig 0.16, and nothing noticed — FIXED 2026-08-03
- **Status:** Fixed. Smoke 282/282 (adds `progress_test_run`).
- **Was:** `selfhost/stdlib_preamble.zig` called `std.Progress.start(.{})`, but Zig 0.16's
  signature is `pub fn start(io: Io, options: Options) Node` — verified against
  `lib/std/Progress.zig:588`, not inferred. Every program touching `Progress.` failed to
  build with `member function expected 1 argument(s), found 0`.
- **Fix:** `std.Progress.start(_io, .{})`. `_io` is already a preamble global used
  throughout (`std.Io.Timestamp.now(_io, .awake)`), so this is a one-argument change with
  no plumbing. `Node.start(name, estimated_total_items)` was unchanged, so
  `_progress_root.start(label, _total_u)` needed no edit.
- **Why nothing caught it:** `test/progress_test.zbr` carried **no** smoke registration of
  any kind, so no gate ever touched it. The heavy sweeps gate against a **baseline**, and a
  file that has never passed is not in the pass set — so it could not go red however broken
  it was. This is the BUG-243 class; `tools/registration_check.py` now makes it a gate
  failure rather than a silence.
- **Test:** `smoke_run test/progress_test.zbr "done"` — asserts the deterministic **print**,
  not bar rendering: `std.Progress` detects a non-tty and renders nothing under the gate
  runner, so an expectation written against bar output would never match.
- **Verification:** the fix was confirmed in the **emitted artifact** (`zebra_rt.zig:3621`
  contains `std.Progress.start(_io, .{})`), not from `rebuild.sh` reporting OK — the
  preamble is embedded into the bootstrap at *build* time, so a regen that runs before the
  rebuild emits the old runtime and every gate downstream measures it.

---

### BUG-120: selfhost — `.add()` → `.append()` rewrite fires on user class method calls via lowercase vars — FIXED 2026-05-07
- **Status:** Fixed. Bootstrap 5/5, smoke 64/64.
- **Was:** `selfhost/codegen.zbr` `.add()` heuristic only guarded on `isUpperCase(receiver_name)` (BUG-061). Lowercase instance variables (`c: Calc`) passed the guard, so `c.add(2, 3)` was incorrectly emitted as `c.append(_allocator, 2)`.
- **Fix:** Consult `InferCtx` at the call site before rewriting. If `inferExpr(m.object, infer_ctx)` returns `Type_.named(nc)` with `nc.len > 0`, the receiver is a class instance — skip the rewrite. The InferCtx pre-walk in `genMethod` already seeds all local variable types (params + inferred vars), so this works for annotated params, unannotated vars initialised with class ctors/method returns, and chained calls.
- **Test:** `test/profile_attr_test.zbr` — calls `c.add(2, 3)` where `c: Calc`; workaround method rename (`addValues`) reverted back to `add`.

---

### BUG-118: selfhost — struct construction emits `Struct.init()` with no init method — FIXED 2026-05-05; synthetic init 2026-05-06
- **Status:** Fixed. Bootstrap 5/5, smoke 52/52.
- **Was:** `Point(x: 1, y: 2)` emitted `Point.init(1, 2)`. Plain structs have no `pub fn init`; only classes (and structs with `cue init`) do.
- **Fix (2026-05-05):** `genCall` in `selfhost/codegen.zbr` now tracks two separate StrSets: `struct_names` (all structs) and `struct_with_init` (structs with `cue init`, including all cross-module exposed structs). Plain structs (in `struct_names` but not `struct_with_init`) emit `Struct{ .field = val }` literal syntax. Added `declMembersHaveInit` helper to avoid unused-binding Zig error.
- **Enhancement (2026-05-06):** Both backends now emit a synthetic `pub fn init(fields...) StructName { return .{ ... }; }` in `genStruct` for every plain struct (no explicit `cue init`). This normalises all struct definitions — `StructName.init(...)` is now always callable. The call site continues to use struct literal syntax (order-independent) for construction; the synthetic init is available for Zig interop and future uniform-construction refactors.
- **Test:** `test/bug118_struct_ctor_test.zbr` — constructs `Point(x: 3, y: 4)` and `RGB(r: 255, g: 128, b: 0)`.

---

### BUG-117: `List.join(sep)` — inverted args in selfhost + TC return type gap in bootstrap — FIXED 2026-05-05 (selfhost) + 2026-05-12 (bootstrap)
- **Status:** Fixed in both compilers. Bootstrap 5/5, smoke 92/92.
- **Was (selfhost):** `items.join(sep)` emitted `std.mem.join(_allocator, items, sep.items)` — separator and slices swapped, `.items` on separator.
- **Fix (selfhost, 2026-05-05):** `genMemberCall` `join` arm now emits separator first: `std.mem.join(_allocator, sep, items.items)`.
- **Was (bootstrap):** `inferInstanceMethodReturn` didn't handle `join`, so `var x = list.join(sep)` inferred `x` as `.unknown`. Consequently, calling `.split()` on the join result used literal pass-through, emitting `x.split(...)` which doesn't exist on `[]const u8`.
- **Fix (bootstrap, 2026-05-12):** Added `if (std.mem.eql(u8, method, "join")) return .string;` in `TypeChecker.inferInstanceMethodReturn` so join result is typed `.string`, enabling downstream `.split()` dispatch.
- **Test:** `test/bug117_list_join_test.zbr` — joins `["alpha", "beta", "gamma"]` with `", "`, then splits newline-joined result.

---

### BUG-116: `char.isAlpha()` / `char.isDigit()` / `char.isWhitespace()` + `StringBuilder.appendChar` not dispatched — FIXED 2026-05-05 (selfhost) + 2026-05-12 (bootstrap)
- **Status:** Fixed in both compilers. Bootstrap 5/5, smoke 92/92.
- **Was (selfhost):** Char methods fell through to pass-through path, emitting invalid `u21.isAlpha()` Zig.
- **Fix (selfhost, 2026-05-05):** Added char dispatch block before the string methods section in `genMemberCall`. Detects `Type_.char_` receiver via `inferExpr` and emits `std.ascii.isAlphabetic(@as(u8, @truncate(c)))` etc. Covers: `isAlpha`, `isDigit`, `isWhitespace`, `isUpper`, `isLower`, `toUpper`, `toLower`. Mirrors `genCharMethod` in `src/CodeGen.zig`.
- **Was (bootstrap):** `StringBuilder()` constructor call returned `.unknown` from `TypeChecker.inferCall` (no special case). So `var sb = StringBuilder()` had inferred type `.unknown`, and `sb.appendChar(...)` fell through to a literal method call — generating `sb.appendChar(...)` which doesn't exist on `std.ArrayList(u8)`. Additionally, the TC-inferred fallback switch in `genExprCall` was missing `.string_builder`.
- **Fix (bootstrap, 2026-05-12):** Added `StringBuilder()` special case in `TypeChecker.inferCall` (mirrors `CsvWriter`, `CodeEditor`). Added `.string_builder` arm to TC-inferred fallback switch in `src/CodeGen.zig` (line ~10971).
- **Test:** `test/bug116_char_methods_test.zbr` — counts alpha/digit/space chars, tests isUpper/isLower, verifies toUpper via StringBuilder.

---

### §19: Selfhost TC diagnostics — SHIPPED 2026-05-05
- **Status:** Shipped in `selfhost/typechecker.zbr` + `selfhost/main.zbr`. Compat test 2/2 PASS, bootstrap 5/5.
- **Was:** `selfhost/typechecker.zbr` had inference-only infrastructure (no `errors` list, no `addErr`, no print path). Type mismatches in the selfhost pipeline were only caught after codegen by the downstream Zig compiler, producing `path:LINE:` (no col) format errors.
- **Fix:** Added `Diagnostic{file,line,col,message}` struct, `InferCtx.errors: List(Diagnostic)` + `addErr/hasErrors/errorMessages`, `isPrimitive/typesCompatible` predicates, and `checkVarDecl/checkStmts/checkDecl/checkModule` walk. Wired into `main.zbr` step 4.5 (after ASTBuilder, before codegen). Selfhost now emits `path:LINE:COL: error: type mismatch: expected int, found str` at TC time.
- **Scope:** Concrete primitive mismatches only (int/bool/char/float/str). Named/enum types deferred — enum not tracked in ModuleTypes; would false-positive without full registry.
- **Test:** `test/selfhost_compat/run_compat.sh` updated to PASS when selfhost catches an error with col but bootstrap backend doesn't (known gap: bootstrap error comes from Zig compiler post-codegen).

---

### BUG-102: Selfhost typechecker `to!` force-unwrap audit — FIXED 2026-05-06
- **Status:** Fixed. All 41 `to!` sites in `selfhost/typechecker.zbr` are now guarded. Bootstrap 5/5, smoke 44/44.
- **Was:** `selfhost/typechecker.zbr` had ~41 `to!` force-unwrap operations in various states of guardedness. Several appeared unguarded. A nil at any unguarded `to!` is a hard panic with no diagnostic.
- **Fix:** Full audit of all 41 sites:
  - 20 converted to `if x as v` (idiomatic) — applies to `String?`, `List(Stmt)?`, `Type_?` same-file locals and cross-module fields where the bootstrap TC tracks optionality correctly
  - 21 kept as `if x != nil: ... to!` with `# safe:` annotation — required for cross-module `TypeRef?` and `^Expr?` fields, which the bootstrap TC does not track as optional (pre-existing gap)
- **Note:** The TC gap where `TypeRef?`/`^Expr?` cross-module fields aren't inferred as optional is a separate issue from BUG-102. The guarded `to!` pattern is the correct workaround for those 21 sites.

---

### BUG-099: Type `.unknown` three-way split — FIXED 2026-05-05 (Zig) + 2026-05-06 (selfhost)
- **Status:** Fixed in `src/TypeChecker.zig` (2026-05-05) and `selfhost/typechecker.zbr` (2026-05-06). Bootstrap 5/5, smoke 44/44, full test suite.
- **Was:** `Type.unknown` / `Type_.unknown_` overloaded three semantically distinct cases: context-dependent (nil, result), opaque-by-design (zig_lit, generics), and unresolved (TC gave up). Downstream checks couldn't distinguish them, so `var x: int = undefined_call()` silently typechecked.
- **Fix (Zig):** Three-way split into `.context_dependent`, `.unknown`, `.unresolved: Ast.Span`. Alarm bell fires at `checkVarDecl`. See commits `429ff98` → `fe61ebe`.
- **Fix (selfhost):** `Type_` union gains `context_dependent` and `unresolved`. Twelve `inferExpr`/`walkStmt` sites reclassified: nil inner + result outside return + if-capture defaults → `context_dependent`; ident/member/call/index/slice/expr fallbacks → `unresolved`; intentional opaque cases unchanged (`unknown_`). `isAbstractType()` helper mirrors `isAbstract()`. Alarm bell added to `checkVarDecl` behind `InferCtx.strict` (enabled by `typecheck-merge` only; off for normal compilation to avoid false alarms on TC gaps not yet closed). `codegen.zbr` format-spec falls through for all three abstract variants.
- **Closed as side effects:** BUG-105 (enum_member/union_variant → parent type), BUG-106 (literal element-type homogeneity), BUG-108 (partial — `this` outside class defensive emitError).

---

### BUG-105: `Color.red` infers to `.unknown` instead of `.named(Color)` — FIXED 2026-05-05
- **Status:** Fixed in `src/TypeChecker.zig:inferMember`. Test: `test/bug105_enum_member_test.zbr`, `test/bug105_union_variant_test.zbr`. See commit `f254b75`.
- **Was:** `inferMember` returned `.unknown` for enum-member and union-variant access (`Color.red`, `Result.ok(...)`). Downstream `var c: int = Color.red` silently typechecked.
- **Fix:** `inferMember` now returns `Type{ .named = parent_sym }` when the member resolves to an enum member or union variant. `var c: Color = Color.red` typechecks; `var c: int = Color.red` correctly errors.

---

### BUG-106: Heterogeneous list literals `[1, "two"]` silently typecheck — FIXED (partial) 2026-05-05
- **Status:** Literal homogeneity check shipped. Cast-validity check deferred. Test: `test/bug106_heterogeneous_list_test.zbr`. See commit `fe61ebe`.
- **Was:** `list_lit`, `array_lit`, `dict_lit` inferred to `.unknown` without checking element type consistency. `[1, "two", 3]` was silently accepted.
- **Fix:** Element-type walk now requires mutual `isAssignable` for non-abstract element types. Heterogeneous literals error at the offending element's span. Numeric mixes `[1, 2.0, 3]` still pass (untyped-numeric semantic). Cast-validity check (line 1693 — `42 as ClassType` still typechecks) deferred — separate scope, lower priority.

---

### BUG-108: Silent `.unknown` at `this` outside class — FIXED (partial) 2026-05-05
- **Status:** `this`-outside-class diagnostic shipped. Other sites deferred. Test: `test/bug108_this_outside_class_test.zbr`. See commit `01296db`.
- **Was:** `this` used outside a class/struct method or `with` block silently returned `.unknown` with no diagnostic.
- **Fix:** `this` outside valid context now emits "'this' used outside a class/struct method or 'with' block" at the `this` token span.
- **Remaining (deferred):** `inferMember` cross-module miss softened to `.unknown` (false-positive risk on legitimate patterns); index/slice on non-indexable; `expr_types.get` fallbacks with legitimate non-error cases.

---

### BUG-111: Compound assign `.field += 1` — NOT-A-BUG 2026-05-05
- **Status:** Closed as not-reproduced. Verified 2026-05-05 in both backends.
- **Was (reported):** `this.count += 1` / `.count += 1` suspected to fail; zero occurrences in repo suggesting users avoided the form.
- **Verified:** `.count += 1`, `this.count += 1`, `obj.count += 5` all parse, codegen, and run correctly. The zero-occurrence data was stylistic legacy (authors wrote `this.X = this.X + 1` before `.field` shorthand was canonical), not a compiler limitation.

---

### BUG-112: `def name: T` no-paren shorthand removed from grammar — FIXED 2026-05-05
- **Status:** Fixed 2026-05-05. Grammar rule removed from both backends. 38-site sweep done. Bootstrap 5/5. See commits `2f7e767` (grammar removal) + `598a533` (38-site sweep).
- **Was:** `def name: T` and `def name(): T` were both legal. The no-paren form was a vestige of the removed `prop`/`get`/`set` machinery — visually contradicted call-site syntax (callers always write `obj.name()`).
- **Fix:** No-paren rule removed from `src/Parser.zig` and `selfhost/parser.zbr`. All 38 occurrences across 17 files swept to `def name(): T`. Style guide §1 Q2 updated to reflect canonical form.

---

### BUG-113: Slice TC loses `str` type through `var` binding — NOT-REPRODUCED 2026-05-05
- **Status:** Closed as not-reproduced. Verified 2026-05-05.
- **Was (reported):** `var text = src[0..3]` suspected to infer something other than `str`, requiring explicit `: str` annotation for `.toFloat()` to dispatch. Author comment in `pratt_calc.zbr:132–134` documented this workaround.
- **Verified:** Both the annotated and unannotated forms produce identical output. The TC improvement (likely via BUG-099 work) resolved the underlying inference gap. The `pratt_calc.zbr` annotation is now redundant but harmless — left in place.

---

### BUG-087: `ensure` defer fires on the error path of throws functions — FIXED
- **Status:** Fixed 2026-04-27 in both backends. `_ensure_armed` flag set only on the success path; defer check gated on the flag. Tests: `contract_result_throws_test.zbr`, `contract_ensure_falloff_test.zbr`.
- **Was:** A throws function with an `ensure` clause that raised mid-body caused the ensure check to fire on the error path. Result: program panicked with "ensure failed in '<fn>'" and the user's `try/catch` never saw the original exception. Zig `defer` runs on both success and error returns, but `genEnsureBlock` emitted a plain `defer { if (!(expr)) panic; }` with no success-vs-error discrimination.
- **Fix:** `var _ensure_armed = false;` local at function entry. Set `true` on the success path (right before normal `return _result;` in functions with `result`-capable ensure, or right before any normal return otherwise). Defer check wrapped in `if (_ensure_armed and !(expr)) panic;`.
- **Discovered:** while implementing `result` capture (NEXT_STEPS item #11). Closed as a side effect of the `result`-keyword work — same flag mechanism delivers both features.

---

### BUG-019: `fn_ref` assignment missing `&` prefix in selfhost codegen — FIXED
- **Status:** Fixed 2026-04-23 in `selfhost/codegen.zbr`. `isTopLevelMethod` + `&` prefix paths in `genLocalVar`/`genAssign`. Test: `test/fn_ref_test.zbr`.
- **Was:** `selfhost/codegen.zbr` lacked the fn-ref detection that `src/CodeGen.zig` has. Mutable local vars initialised from a bare top-level function name (e.g. `var pred = isAlpha`) emitted Zig `var pred = isAlpha;` which Zig rejects: *"variable of type 'fn(u21) bool' must be const or comptime"*. The Zig backend had this via `tc_init_type == .fn_ref`; the selfhost lacked parity.
- **Fix:** added `isTopLevelMethod()` scanner over the current module's `module_decls`. Mutable fn-ref locals emit `var pred: @TypeOf(&isAlpha) = &isAlpha;`; reassignment emits `pred = &isDigit;`.
- **Known limitation (deferred):** `isTopLevelMethod()` only scans the current module. Cross-module fn-ref (`var cb = OtherModule.func`) still emits without `&` in selfhost. Not yet seen in practice; refile if it lands.

---

### BUG-002: `guard` + `try_postfix` runtime error propagation — CLOSED (test quality)
- **Status:** Closed 2026-04-23. Tests fixed by adding explicit `try/catch` wrapping. Per memory log + NEXT_STEPS reference table.
- **Was:** Two tests (`guard_test`, `try_postfix_test`) panicked at top level rather than catching propagated errors. Symptom A: `checkPositive` raised inside a guard `else` block; top-level `try Main.main()` panicked with `error: ZebraError`. Symptom B: `safeDiv(10,0)?` propagated through `main throws`; test exited non-zero.
- **Resolution:** Behaviour was correct per Zebra's error semantics — propagation up to `main` does panic if uncaught. The tests were testing propagation without explicit `try/catch` boundaries; adding the wrapping made them validate the propagation path without panicking. No compiler change needed.

---

### BUG-098: `name in some_list` always routed to `std.mem.indexOf(u8, …)` — FIXED
- **Status:** Fixed in `selfhost/codegen.zbr`. Bootstrap 5/5, smoke 43/43.
- **Was:** The `in` operator only specialised for `@[…]` tuple literals on the right; List(T) / HashMap(K,V) variables fell through to the substring path, which emitted `std.mem.indexOf(u8, container, needle)` — Zig rejected because `indexOf` takes a `[]const T` slice, not an `ArrayList`.
- **Fix:** `BinaryOp.in_` now routes to the existing `_zebra_in` runtime helper (which handles ArrayList + HashMap + tuple via comptime dispatch) when the right operand is:
  - `Expr.array_lit` (the existing case)
  - `Expr.list_lit` (newly recognised — `[a, b, c]` literals)
  - `Expr.ident` whose name is in `list_locals` / `hashmap_locals`
  - or any expression whose TC type is a `.named` symbol named `"List"` / `"HashMap"` (covers field accesses)
- **Companion fix:** `genLocalVar` now adds `n.name` to `list_locals` (and `list_str_locals` when the first element is str-typed) for `var x = [a, b, …]` declarations — without that, downstream `.count()`, `.at()`, and `in` dispatches missed list-locals that came from a `[…]` literal rather than a `List(T)()` ctor.
- **Regression test:** `["alice", "bob"]` etc. round-trip through `examples/lambda_calc.zbr` (which uses `name in list` pervasively after this fix).
- **Discovered:** 2026-04-30 while writing `examples/lambda_calc.zbr`.

---

### BUG-095: class field defaults aren't auto-applied — `cue init` left fields as Zig `undefined` — FIXED
- **Status:** Fixed in `selfhost/codegen.zbr` `genInit`. Bootstrap 5/5, smoke 43/43.
- **Was:** When a `cue init` body didn't explicitly assign a class field that had a declared default (`var hits: int = 0`), the un-assigned field was emitted as Zig `undefined` — producing the poison value `0xAAAA…AAAA` which silently overflowed in subsequent arithmetic. The synthetic-default-init path (used when a class has no user-written `cue init`) already pre-filled defaults; the explicit-init path didn't.
- **Fix:** `genInit` now walks `owner_members` for `Decl.var_` entries with a non-nil `init_expr` and emits `_self.field = <default>;` *before* running the user's `cue init` body. The user's body may overwrite those defaults — that's fine and matches the bare-class semantics. Same pre-fill is also added for body-less `cue init` declarations.
- **Reproducer:** `class Counter { var hits: int = 0; var misses: int = 0; cue init(): pass }` — `c.hits + c.misses` now prints `0` instead of `-6148914691236517206`.
- **Discovered:** 2026-04-30 while writing `zebra-tools/book_run.zbr`'s pass/fail counters.

---

### BUG-091: `List(T)` / `HashMap(K,V)` parameter receiver is `*const` — `.add()` rejected by Zig — FIXED
- **Status:** Fixed in **both** `src/CodeGen.zig` (Zig backend) and `selfhost/codegen.zbr` + `selfhost/cg_helpers.zbr` (selfhost). Per-equivalence rule. Bootstrap 5/5; smoke 43/43.
- **Was:** Passing a `List(T)` as a function parameter and calling `.add()` on it emitted `*const ArrayList(...)` (Zig parameters are always const), and `append` (which takes `*Self`) was rejected with "cast discards const qualifier".
- **Fix:** Mutation-driven param-pointering. New helper `paramNeedsAddrOf` returns true when the param's type is `List(T)` / `HashMap(K,V)` AND the body's `scanMutations` set contains the param name. `genMethod` emits the param as `*std.ArrayList(...)` in that case; the call-site emit (`genArgs` in src; `genArgListNamed` + the class-method member-call path in selfhost) emits `&` for the corresponding arg. `addAddrOfMutationsInStmts` (a parallel pass alongside `scanMutations` in `genStmts`) marks the caller's local as `var` so `&items` is `*ArrayList`, not `*const ArrayList`.
- **Why mutation-driven (not blanket):** Existing selfhost code (441 `: List(...)` param sites) is reads-only; flipping the calling convention everywhere would have a large blast radius. The mutation predicate isolates the change to sites that actually need it.
- **Selfhost port:** added `paramNeedsAddrOf` + `isContainerTypeRef` to `cg_helpers.zbr`; added `lookupFnBody`, `addAddrOfMutationsInStmts/Expr`, `*` prefix in `genParamList`, `&` prefix in `genArgListNamed` and `genMemberCall` member-method path; small TypeRef.named "StrSet" → `strset_locals` registration so a typed `var ms: StrSet = scanMutations(...)` round-trips. Both the call-site `&` emit and the addr-of mutation-marking pass cover three dispatch shapes: static (`Class.method`), self (`this.method`), and instance (`var.method` resolved via `inferExpr` against the per-method `InferCtx`).
- **Regression tests:** `test/bug091_list_param_test.zbr` (static `Main.fillX(items)`) and `test/bug091_dispatch_test.zbr` (`this.helper(items)` and `f.helper(items)` instance shapes with assertions). Both pass through `zebra-bootstrap.exe` (Zig backend) and `zebra.exe` (selfhost).
- **Discovered:** 2026-04-29 while writing `book_lint.zbr` (Phase 3 dogfooding tools).

---

### BUG-092: `var lines: List(str) = s.split("\n")` didn't auto-collect SplitIterator — FIXED
- **Status:** Fixed in **both** `src/CodeGen.zig` `genLocalVar` and `selfhost/codegen.zbr` `genLocalVar`. Bootstrap 5/5.
- **Was:** Assigning `content.split("\n")` to a `List(str)`-annotated local annotated the slot as `std.ArrayList([]const u8)` but the RHS emitted `std.mem.splitSequence(...)` — a Zig type mismatch.
- **Fix:**
  - **Zig backend** (`src/CodeGen.zig`): New branch in `genLocalVar` emits the iterator + while-loop drainer alongside the const/var declaration.
  - **Selfhost** (`selfhost/codegen.zbr`): same pattern but emitted as a single labeled-block initializer (`blk_N: { var _ll_N = …; while (…) |…| _ll_N.append(…); break :blk_N _ll_N; }`) so the form works regardless of the outer const/var decision. Also added "lines" to `isReadOnlyMethod` in `cg_helpers.zbr` so a downstream `s.lines()` call doesn't spuriously mark `s` as mutated.
- **Coverage:** Both `split(sep)` and `lines()` are handled via the same path (both return iterators in Zig). Untyped `var x = s.split(...)` for-loop iteration is unchanged (still drives the iterator directly).
- **Regression test:** `test/bug092_split_to_list_test.zbr`, passes through both backends.
- **Discovered:** 2026-04-29 while writing `book_lint.zbr`.

---

### BUG-082: Selfhost `inferExpr` returns `unknown_` for cross-module constructor calls — FIXED
- **Status:** Fixed — `selfhost/typechecker.zbr` `inferExpr` Expr.call/Expr.member branch; `test/bug082_test.zbr` + `test/bug082_lib.zbr`. Bootstrap 5/5.
- **Was:** `var b = SomeMod.SomeClass(args)` gave `b` type `unknown_` in selfhost TC; downstream method-return format strings emitted `{any}` instead of `{s}`, printing raw bytes.
- **Fix:** In `inferExpr`, when receiver resolves to `unknown_` and the member name is a known dep class, return `Type_.named(mem.member)`.

---

### BUG-029: Class field init with non-int-valued HashMap defaults to i64 — FIXED
- **Status:** Fixed in selfhost — resolved incidentally during selfhost implementation
- **Was:** `this.field = HashMap()` on a field declared `HashMap(str, T)` for non-int `T` emitted `std.StringHashMap(i64).init(_allocator)` in the Zig-backend compiler. Root cause: Zig-backend `genAssign` resolved field types only for `.ident` targets or `.member` with `.ident{name="self"}`, bailing out for `this.` which parses as `.member { object: .this }`.
- **Fix:** Selfhost `getAssignFieldType` uses `getMemberFieldName` which handles `Expr.member` generically (returns `m.member` for any member expression). Combined with `genCallWithTypeHint`, emits the correct Zig type.
- **Regression test:** `test/hashmap_this_field_test.zbr`

---

### BUG-030: `.contains()` on param-of-class HashMap field emits List.contains — FIXED
- **Status:** Fixed in selfhost — resolved incidentally during selfhost implementation
- **Was:** `param.field.contains(key)` where `param` is a local of a class type and `field` is `HashMap(K,V)` generated incorrect contains dispatch in the Zig-backend compiler.
- **Fix:** Selfhost `genCall` dispatches `.contains()` on all non-string receivers via `.contains(key)` — correct for Zig HashMap. The `getMemberFieldName`-based path handles chained member access.
- **Regression test:** `test/hashmap_param_field_test.zbr`

---

### BUG-001: Static method calling static method emits `self.` prefix — FIXED
- **Status:** Fixed (prior session — TCO work fixed bare static method calls)
- Was: `testHelper()` inside a static method generated `self.testHelper()`.
- Now: emits `ClassName.methodName()` correctly for static→static calls.

---

### BUG-003: HTTP `serve` fails on Windows with "comptime call of extern function" — FIXED
- **Status:** Fixed 2026-04-09
- Was: `_Ctx` struct stored `handler: Handler` where `Handler = @TypeOf(handler)` is a bare function type (comptime-only in Zig). Made the entire struct comptime-only, so `page_allocator.create(_Ctx)` triggered the `NtAllocateVirtualMemory` comptime path.
- Fix: Declare `const _HFn = *const fn(HttpRequest) HttpResponse` and coerce `const _fn: _HFn = handler` before `_Ctx`. Store `handler_fn: _HFn` in `_Ctx` (fn-pointer = runtime type). Call `ctx.handler_fn(_req)` directly. All three HTTP routes verified working on Windows.

---

### BUG-004: `padLeft/padRight/center` — fill char `'*'` passed as string to `u8` param — FIXED
- **Status:** Fixed 2026-04-08
- Was: `_pad_left(s, n, "*", alloc)` failed — `"*"` is `*const [1:0]u8`, not `u8`.
- Fix: Changed pad helpers to accept `anytype` fill; added `_pad_fill` normaliser that handles both char literals (comptime_int) and 1-char strings (pointer).

---

### BUG-005: `{d:0>N}` format adds `+` prefix to positive `i64` in Zig 0.15 — FIXED
- **Status:** Fixed 2026-04-09
- **Context:** DateTime preamble `_dt_to_iso8601` and `_dt_format` used `i64` fields with `{d:0>N}` format spec. Zig 0.15.2 adds a `+` sign to positive signed integers when using fill-aligned format (e.g. `{d:0>4}` for `i64 = 1970` → `+1970`).
- **Fix:** Cast all date fields to unsigned types (`@as(u32, ...)`, `@as(u8, ...)`) before passing to `bufPrint`/`allocPrint`. Unsigned integers never receive a sign prefix.
- **Broader note:** This is a Zig 0.15 breaking change from 0.14. Any future preamble code that formats `i64` values with fill-aligned specs should cast to unsigned first.

---

### BUG-007: `String + String` string concatenation not handled — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `+` operator on strings fell through to the numeric `else` branch in `genBinary`, emitting `(a + b)` which Zig rejects for `[]const u8`. TypeChecker also rejected `String + String` as arithmetic.
- **Fix:**
  - TypeChecker `inferBinary`: added `if (e.op == .add and lt == .string) break :blk .string` before the numeric guard.
  - CodeGen `genBinary`: added dedicated `.add` case — if left operand is string, emits `_str_concat(a, b, _allocator)`.
  - Preamble: added `_str_concat(a, b, alloc)` using `std.mem.concat`.

---

### BUG-008: Mutation scanner — `.unknown` TC type caused spurious `var` — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** When `tc.resolve.exprs` had no entry for an ident used as a method receiver, `inferIdent` returned `.unknown`, which the scanner conservatively treated as always-mutating.
- **Fix:** Removed the `if (obj_type == .unknown) break :blk true` conservative path. Added `if (obj_type == .string) break :blk false` guard. These fixes together fix `string_methods_test` and `sys_test`.

---

### BUG-009 (a): Escape analysis — field writes not propagated — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `propagateEscapesOnce` only traced `var y = <expr>` alias chains. Storing into a returned struct's field (`result.items = list`) didn't escape `list`.
- **Fix:** Added `.assign` handling in `propagateEscapesOnce`: if target is `obj.field` and `obj` is escaped, all idents in RHS are added to the escaped set.

---

### BUG-009 (b): `opt?.field` emits `try opt.?.field` inside `if opt != nil` guard — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `opt?.x` inside an `if opt != nil` block generated `try opt.?.x` instead of `opt.?.x`.
- **Fix:** TypeChecker now populates `optional_unwraps`. `exprHasTry` and `genExpr` both consult `optional_unwraps` instead of `expr_types`.

---

### BUG-010: Partial class — duplicate method silently appended — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `mergePartialInto` concatenated all members from a partial without checking for name conflicts.
- **Fix:** `mergePartialInto` now scans for duplicate method names before merging. Duplicates emit a clear warning and the partial definition is skipped.

---

### BUG-011: `tcTypeAnnotation` — comprehensive type annotation for `var` locals
- **Status:** Fixed 2026-04-09
- **Fix:** Replaced ad-hoc 6-case inline switch with `tcTypeAnnotation(t, alloc)` — a dedicated module-level function mapping all `TypeChecker.Type` variants to Zig annotation strings.

---

### BUG-012: `_type_id` uninitialized for classes without explicit `cue init` — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** Classes with no explicit `cue init` were constructed via `ClassName{}` (struct literal), leaving `_type_id` uninitialized.
- **Fix:** `genClass` now emits a synthetic default `pub fn init() ClassName` that explicitly stamps `self._type_id = _tid_ClassName`. Constructor call site updated to emit `ClassName.init()`.

---

### BUG-013: `collectEnumMembers` — blank-line leaf detection used structural comparison — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `if (kids[1] != .leaf)` relied on an implementation detail of blank-line productions.
- **Fix:** Replaced with the named helper `isMeaningfulNode(tn: TN) bool`.

---

### BUG-015: `scanMutationsInto` missing `.assert` case — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** Method calls inside `assert` conditions were never scanned, causing the receiver to be emitted `const`.
- **Fix:** Added `.assert => |s| try scanMutationsInExpr(s.cond, set, tc_opt)` to `scanMutationsInto`.

---

### BUG-016: `inferMember` didn't unwrap optional type before member lookup — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `inferMember` only looked up fields/methods when `obj_type == .named`. For `n?.next` (where `n: ?Node`), TC type was `.optional(.named(Node))` — lookup silently returned `.unknown`.
- **Fix:** Added `resolved_obj_type = if (obj_type == .optional) obj_type.optional.* else obj_type` before the `.named` member lookup.

---

### BUG-018: Top-level `def` referenced inside class method set `uses_self = true` — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `refsInExpr` set `uses_self = true` for ANY `.method` symbol, including top-level `def` functions.
- **Fix:** `refsInExpr` now checks `sym.decl.method.is_top_level`; top-level methods do NOT set `uses_self`.

---

### BUG-020: `branch/on` call-expr pattern emitted wrong Zig — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `on SomeUnion.variant() as x` in a `branch` on-clause fell through to `genExpr(v)` which emitted the union constructor form, not a valid Zig switch pattern.
- **Fix:** Added `else if (v.* == .call and v.call.callee.* == .member)` branch in `genBranch`'s union pattern path.

---

### BUG-021: Struct `cue init` stamped `_type_tag` (class-only field) — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `genInit` always emitted `self._type_tag = _ttag_StructName` for any `cue init` body.
- **Fix:** Added `is_struct_owner: bool = false` to Generator. `genInit` wraps the stamp in `if (!g.is_struct_owner)`.

---

### BUG-022: `boxed_variants` not cloned in `cloneInterface` — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `cloneInterface` didn't clone the `boxed_variants` map. Re-imported modules received empty `boxed_variants`, silently skipping boxing expressions.
- **Fix:** Added full key/value clone loop for `boxed_variants` in `cloneInterface`.

---

### BUG-023: Multi-line `cue init` blocked by indentation validator — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `processIndentation` checked indentation on EVERY line including continuation lines inside open parentheses.
- **Fix:** Added `paren_depth: u32 = 0` tracking to Tokenizer. `processIndentation` returns early when `paren_depth > 0`.

---

### BUG-024: `throws` auto-propagation missing — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** Calling a `throws` method from inside a `throws` method required explicit `?` suffix on every call.
- **Fix:** Added `current_method_throws: bool = false` to Generator. Auto-emits `try ` prefix for three call paths (bare-name, self-method, cross-module). Added `suppress_auto_try` flag to prevent double `try try`.

---

### BUG-025: `scanMutationsInExpr` didn't recurse into `.try_` nodes — FIXED
- **Status:** Fixed 2026-04-11
- **Was:** `localVar.method()?` — the `?` wraps the call in a `.try_` node which wasn't recursed into, so `localVar` was never added to the mutated set.
- **Fix:** Added `.try_ => |e| try scanMutationsInExpr(e.expr, set, tc_opt)` to `scanMutationsInExpr`.

---

### BUG-028: Zebra (Zig-backend) emits pointer addresses into identifier names — FIXED
- **Status:** Fixed 2026-04-17 (commit 8debe0a)
- **Was:** Generated `.zig` contained identifiers like `_box_2376b6287c0` — live pointer addresses. Every run produced different names, so output was non-deterministic.
- **Fix:** Generator carries a monotonic `box_counter_ptr`; all 27 `@intFromPtr(node)`-based name sites route through `Generator.nextUid()`.

---

### BUG-031: Selfhost `except` codegen emits `.*` on value-typed subject — FIXED
- **Status:** Fixed 2026-04-17
- **Was:** `x except { f = v }` where `x` is a local value (not a pointer) emitted `var _except_tmp = x.*;` — `.*` is only legal on a pointer.
- **Fix:** `selfhost/codegen.zbr` gen path for `Expr.except_` now emits `.*` only when the base is `Expr.this_` in a method body.

---

### BUG-032: Selfhost codegen.zbr emits `.remove` unconditionally as `.orderedRemove` (List form) — FIXED
- **Status:** Fixed 2026-04-17 (commit ff87add)
- **Fix:** `.remove` dispatch now discriminates HashMap vs List receiver via new `hashmap_locals` + `fieldIsHashMap` infrastructure. HashMap emits `_ = obj.remove(key)`; List keeps `_ = obj.orderedRemove(@intCast(idx))`.

---

### BUG-033: Selfhost `.contains()` on class-field HashMap emits `List.contains` form — NOT REPRODUCED
- **Status:** Not Reproduced 2026-04-17
- **Investigation:** Built reproducer with `class Reg` holding `HashMap(str,int)` field, called via `self.by_name.contains(k)`. Selfhost emits correctly (HashMap `.contains` path). BUG-032's walker work evidently already covers this receiver shape.

---

### BUG-034: Selfhost emits cross-module union construction as struct call — FIXED
- **Status:** Fixed 2026-04-17 (commit ff87add)
- **Fix:** `generateModuleWith` now consults `deps_mt.hasUnion(exposed_name)` before the hard-coded heuristics. The allow-list stays as a fallback for the single-file emit path.

---

### BUG-036: Selfhost HashMap field `[key]` subscript emits array-index with bogus `@intCast` — FIXED
- **Status:** Fixed 2026-04-18 (commit 242394a)
- **Fix:** `genExpr` for `Expr.index` and new `genHashMapAssign` method detect HashMap receivers via `hashmap_locals`/`fieldIsHashMap`: reads emit `.get(k).?`, writes emit `.put(k, v) catch @panic("OOM")`. `scanMutationsInto` updated to mark index-assign base as mutated. `genHashMapAssign` extracted as a method to avoid a nested-branch `.*`-deref bug in the Zig backend. Bootstrap A/B byte-identical.

---

### BUG-038: Selfhost emits `int.toString()` as codepoint-to-UTF8 encode, not integer-to-decimal — FIXED
- **Status:** Fixed 2026-04-18 (commit 443886d)
- **Fix:** `genMemberCall` in `codegen.zbr` now calls `inferExpr(m.object, infer_ctx)` before choosing the toString emit path. `Type_.char_` receivers → utf8Encode; all others → `std.fmt.allocPrint`. Enabled by typechecker fix: `walkStmt` for_in pre-pass detects `for c in s.chars()` via `isCharsCallExpr()` and binds the loop var as `Type_.char_`, preserving that binding after the body walk.

---

### BUG-039: Selfhost mutation scanner marks string-method receiver as `var` — FIXED
- **Status:** Fixed 2026-04-18 (commit 443886d)
- **Fix:** Added missing string methods to `isReadOnlyMethod()` in `cg_helpers.zbr`: `reverse`, `padLeft`, `padRight`, `center`, `toHex`, `fromHex`, `repeat`, `replace`, `isAlpha`, `isNumeric`, `isValidUtf8`.

---

### BUG-041: `^ClassType?` emits `?**T` instead of `?*T` (root cause) — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** `src/CodeGen.zig::genType .ref_to` arm: when `^T`'s inner payload is a class, emit `*ClassName` / `?*ClassName` directly and skip the recursive `genType` call. Class auto-boxing already provides the pointer; `^` is a representation no-op for classes.

---

### BUG-045: Ctor-arg boxing wraps `^Class?` args in extra `*` — FIXED
- **Status:** Fixed 2026-04-17 (`a5e082b`) — Zig backend only; selfhost was already correct via Phase 17c walker.
- **Fix:** `genBoxedArgExpr` in `src/CodeGen.zig` short-circuits when the payload is a class and falls through to plain `genArgExpr`.

---

### BUG-047: Field-read + field-assign on `^Class?` emitted stale boxing after BUG-041 fix — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** Three parallel class-payload short-circuits in `src/CodeGen.zig` — `.member` field-read, `StmtAssign` self-ref boxing, `StmtAssign` `ref_box_type_name` path — each now checks class vs non-class payload before applying boxing.

---

### BUG-048: Selfhost resolver does not register enum names — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** Added `on PNode.enum_ as e` arm to `bindTopDecl` in `selfhost/resolver.zbr`, mirroring the existing `union_decl` arm.

---

### BUG-049: Selfhost parser drops field initializers — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** `PField` struct gained `init_expr as List(PNode)`; `parseDeclField` parses optional `= .parseExpr()`; `astbuilder.zbr::buildMember` threads `f.init_expr` into the `DeclVar` init slot.

---

### BUG-050: Selfhost branch-on drops multi-pattern lists and inline-else — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** `PBranchOn.patterns` (was `pattern`); `parseBranchStmt` loops collecting comma-separated patterns; else arm handles inline `else, stmt` form; `buildBranch` iterates all patterns.

---

### BUG-051: Selfhost genRaise drops the 2-arg `raise msg, details` form — FIXED (primitive + string paths)
- **Status:** Fixed 2026-04-17 (object path emits `@compileError` fail-loud, pending future port)
- **Fix:** `parseRaiseStmt` collects optional `, expr` details; `genRaise` ported primitive + string emission paths from `src/CodeGen.zig`. Added `nextUid()` to `Writer` class.

---

### BUG-052: Selfhost parseUnary drops the `try expr` prefix form — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** `parseUnary` gained a `try` branch — consume `try`, recurse with `parseUnary()`, wrap in `PNode.expr_try(operand)`.

---

### BUG-053: Selfhost parseAtom rejects the `zig"..."` / `zig'...'` backend literal — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** Added `expr_zig_lit as str` PNode variant; `isZigLit()` helper; `parseAtom` arm; `astbuilder.zbr::stripZigQuotes` + `on PNode.expr_zig_lit` arm.

---

### BUG-055: Selfhost parsePostfix drops `expr.get(args)` / `expr.post(args)` method calls — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New branch in `parsePostfix` after the `isOpenCall` check: when peek text is `"get"` or `"post"` and `peekAt(1).text == "("`, treat it as a method call — consume the keyword, consume `(`, reuse `parseCallArgs()`.

---

### BUG-056: Selfhost parser rejects `r"..."` / `r'...'` raw string literals — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** Added `isRawString()` helper, new `PNode.expr_raw_str as str` variant, new `parseAtom` arm. `astbuilder.zbr` new `stripRawAndEscape(text)` helper + arm.

---

### BUG-057: Selfhost parseStmt rejects `arena` scope blocks — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PArenaScope` holder struct, `PNode.stmt_arena_scope as ^PArenaScope` variant, `parseArenaScopeStmt`, astbuilder arm.

---

### BUG-058: Selfhost parseStmt rejects `with target` contextual-self blocks — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PWith {target, stmts}` struct, `PNode.stmt_with`, `parseWithStmt`, astbuilder arm with `rewriteWithStmt` desugaring bare assigns to member accesses on target.

---

### BUG-059: Selfhost parseStmt rejects `guard ... else` blocks — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PGuard {cond, else_stmts}`, `PNode.stmt_guard`, `parseGuardStmt` (supports both block and inline `, stmt` forms), astbuilder arm.

---

### BUG-060a: Selfhost parseOr drops the `orelse` binary op — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `POrelse {expr, fallback}`, `PNode.expr_orelse`, extended `parseOr` loop with `orelse` check, astbuilder arm.

---

### BUG-060b: Selfhost parseExpr drops the `->` pipeline operator — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PPipeline {lhs, rhs}`, `PNode.expr_pipeline`, `parsePipeline` wrapper (left-associative while-loop on `->`), astbuilder arm desugars `lhs -> f(args)` → `f(lhs, args...)`.

---

### BUG-061: Selfhost `genMemberCall` rewrites `ClassName.add(...)` to List.append — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** Added `is_class_ref = isUpperCase(add_nm)` guard alongside existing `is_strset` check. `.add → .append` rewrite skips uppercase class-style identifiers.

---

### BUG-062: Selfhost parseTopDecl rejects the `namespace` keyword — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PNamespace {name, decls}`, `parseNamespaceDecl`, astbuilder arm, `generateEntryPoint` extended to find `main` inside namespaced classes.

---

### BUG-063: Selfhost parseWhileStmt rejects `while var id = init, cond` bind-and-guard — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** Parse-side desugar — `while true { var id = Init; if not Cond: break; ...body }`. Zero AST/codegen changes.

---

### BUG-064: Selfhost parseTopDecl rejects the `interface` keyword — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PNode.interface_ as ^PClass`, `parseInterfaceDecl`, astbuilder arm, `bv.add("PNode.interface_")` in `addCrossModuleBoxedVariants`.

---

### BUG-065: Selfhost parseTopDecl rejects the `extend Type` keyword — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PExtend {target_name, members}`, `parseExtendDecl`, astbuilder arm, `bv.add("PNode.extend_")`, `genExtMethod` updated for `"String"` alias.

---

### BUG-066: Selfhost eatTypeName rejects sized numeric type names (int32/uint8/float32/byte/uint) — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** Added `isSizedTypeName()` helper; extended `eatTypeName`; added `"byte" → "u8"` to `zigTypeForName`.

---

### BUG-067: Selfhost parseMemberDecl rejects the `get name as T` computed-property form — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PProperty {name, type_name, getter_stmts}`, `parsePropertyDecl`, `buildProperty`, `bv.add("PNode.property_")`.

---

### BUG-068: Selfhost parser rejects generic-arg `?` suffix and `name:` labeled call args — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** (a) Generic-args loop in `eatTypeName` now peeks for `?` after each arg and folds it in. (b) `parseCallArgs` consumes `name:` label before the expression.

---

### BUG-069: Selfhost parser missing `expr is TypeName` type-check — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** `parseComparison` gained `else if this.textIs("is")` arm; `astbuilder.zbr` intercepts `pb.op == "is"` and emits `Expr.type_check`; `bv.add("Expr.type_check")`.

---

### BUG-070: Selfhost parser missing `var {x, y} = expr` struct/tuple destructuring — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PDestruct {names, init_expr, is_struct}`, `parseDestructStmt`, `ast.zbr` gained `is_struct as bool` on `StmtDestruct`, astbuilder arm, `bv.add("PNode.stmt_destruct")`, `genDestruct` uses `nextUid()` + branches on `is_struct`, `resolveStmt` arm added.

---

### BUG-071: Selfhost TypeChecker misses string-method return types; str.count(substr) unimplemented — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `stringMethodReturn(name)` function in `typechecker.zbr`; `inferExpr` for `ExprMember` switched to recursive `inferExpr(mem.object)` + `Type_.string_` dispatch arm; `codegen.zbr` gained `str.count(substr)` emit path; `blk_box` typed via `std.meta.Child(@FieldType(...))`.

---

### BUG-072: Tokenizer suppresses EOL/INDENT/DEDENT inside parens — statement-body lambdas fail — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** 5-field state machine in `src/Tokenizer.zig` and `selfhost/Lexer.zbr` (`in_lambda_params`, `lambda_param_depth`, `after_lambda_params`, `lambda_body_active`, `lambda_indent_level`). `parseLambdaExpr` extended to handle both expression-body (`= expr`) and statement-body (eol + indent block) forms.

---

### LANG-001: Top-level `def` not supported — FIXED 2026-04-10
- **Status:** Fixed
- `TopDecl → MethodDecl` production added; `AstBuilder.zig` handles `MethodDecl` case setting `is_top_level = true`; `CodeGen.zig` skips `self.`/`ClassName.` prefix for top-level methods.

---

### LANG-002: `on X return Y` inline form and blank-line sensitivity — FIXED 2026-04-10
- **Status:** Fixed
- Added `BranchOnClause → kw_on Expr kw_return Expr eol` production; `BranchOnList → BranchOnList eol` production to handle blank lines.

---

### LANG-003: `^T` heap-indirection type for recursive structs — ADDED 2026-04-10
- **Status:** Implemented
- `var next as ^Node?` declares heap-allocated pointer. `^T` emits `*T` in Zig; `^T?` emits `?*T`. Auto-boxed on assignment.

---

### LANG-004: Cross-module TypeRef resolution — ADDED 2026-04-10
- **Status:** Implemented (extended from MVP to full TC inference)
- `ModuleInterface` tracks exported type names; `Resolver` handles dotted names; TypeChecker added `.cross_module` Type variant.

---

### LANG-005: `^T` auto-boxing for cross-class field assignments — FIXED 2026-04-10
- **Status:** Fixed
- `genClass` now uses `withClass(n)` for ALL concrete classes. `ref_box_type_name` extended for `localVar.field = x` targets.

---

### BUG-040: Selfhost `print` emits `{}` instead of `{s}` for strings — FIXED 2026-04-19
- **Status:** Fixed in selfhost `genPrint` and `genStringInterp`
- `genPrint` now calls `isStringBoth(expr, "print")` to emit `{s}` for string expressions. `genStringInterp` similarly uses `isStringBoth(e, "interp_fmt")` for interpolated parts. Also fixed: `genStringInterp` now emits `catch @panic("OOM")` instead of `try` (correct for Zebra non-throws context).

---

### BUG-042: Selfhost cross-module struct ctor missing `.init` — FIXED 2026-04-19
- **Status:** Fixed in `selfhost/codegen.zbr::genCall`
- Added `dep_types.hasClass(cm_mem)` check alongside `isCrossModuleCtorCall`. Now detects `Mod.ClassName(args)` as a cross-module struct constructor for any class in the dependency module types, emitting `Mod.ClassName.init(args)`.

---

### BUG-043: Selfhost `Mod.Union.variant(v)` emits fn-call not struct-init — FIXED 2026-04-19
- **Status:** Fixed in `selfhost/codegen.zbr::genCall` via `getXmUnionParts` helper
- Added `getXmUnionParts(callee)` top-level helper that detects 3-part `Mod.Union.variant` callee shapes. `genCall` calls it and emits `Mod.Union{ .variant = value }` with boxed-payload support.
- **Implementation note:** A nested `branch outer_m.object on Expr.member` was attempted but the Zig backend doesn't auto-deref `^Expr` fields in nested branch subjects (TC annotation not consulted for switch subject in method context). Workaround: standalone helper function where TC correctly annotates direct branch bindings.

---

### BUG-044: Selfhost cross-module branch pattern collapses variant tag to union type name — FIXED 2026-04-19
- **Status:** Fixed in `selfhost/astbuilder.zbr::buildBranch`
- `buildBranch` now handles 3-part dotted patterns (e.g. `test_lib.Value.num`) by building a nested member chain: `Expr.member(Expr.member(Expr.ident("test_lib"), "Value"), "num")`. Previously, only 2-part patterns were handled, causing `Mod.Union.variant` to collapse to `.Union`.

---

### BUG-074: `Result.ok` / `Result.err` constructor syntax — REMOVED 2026-04-19
- **Status:** Removed from language and compiler
- `Result(T, E)` as a language-level generic type is removed. Both the Zig compiler (`src/CodeGen.zig`, `src/TypeChecker.zig`) and the selfhost port (`selfhost/codegen.zbr`, `selfhost/resolver.zbr`) had their Result-specific handling excised. The `_Result` preamble helper, `genResultMethod`, and `genResultCall` are all deleted. Test files `result_test.zbr` and `result_methods_test.zbr` (which exercised the constructor syntax) are deleted. Bootstrap: 5/5 steps pass, byte-identical round-trip.

---

### BUG-006: `zig"..."` expression statement emits double semicolon — FIXED both sides
- **Status:** Fixed — Zig backend 2026-04-17; selfhost fixed 2026-04-20 (Phase 20)
- `zig"some_stmt;"` inside a method body emitted `some_stmt;;` — the zig literal already ends with `;`, and `genStmt` for `.expr` always appended another `;`.
- Zig-side fix: `src/CodeGen.zig::genStmt` `.expr` case detects trailing `;` on `zig_lit` content and skips the appended `;`.
- Selfhost fix: `selfhost/codegen.zbr::genStmt` `on Stmt.expr` now checks `if e is Expr.zig_lit`: emits content, adds `;` only if content doesn't already end with `;`.

---

### BUG-035: Selfhost parser has no atom handler for `doc_string_line` (`"""..."""` multi-line strings) — FIXED
- **Status:** Fixed Phase 20 (2026-04-20)
- `selfhost/parser.zbr:1885` handles `isDocString()` → `PNode.expr_str(text)`.

---

### BUG-037: Selfhost corpus-failure triage — RESOLVED 2026-04-19
- **Status:** Closed — corpus reached 100% (149/149) via BUG-048 through BUG-073 grammar wave.

---

### BUG-046: Selfhost partial-class sibling file merge — FIXED 2026-04-19
- **Status:** Fixed — committed 2026-04-19
- Added `mergePartials_pmodule` in `selfhost/main.zbr`. Key detail: `"" + psrc_raw` copies the read buffer into permanent arena storage before parsing (Zig 0.15 `File.read` defer can rewind arena).

---

### BUG-075: `String + str` concat not routed through `_str_concat` in selfhost TypeChecker — FIXED
- **Status:** Fixed Phase 20 (2026-04-20)
- Extended `isString(t)` in `selfhost/typechecker.zbr` to accept `Type_.cross_module` where `cm.type_name == "String"`.

---

### BUG-076: `if x is Union.variant |r|` capture binding not in TypeChecker `narrowed_types` — FIXED
- **Status:** Fixed — `isCaptureLookup` 3-way payload lookup in TypeChecker.zig; selfhost walker narrowing in typechecker.zbr; `genIsCaptureThen` ptr_field_bindings seeding in codegen.zbr; bootstrap 5/5.

---

### BUG-077: TC doesn't record inferred type for `?`-propagated throws-call assignments — RESOLVED
- **Status:** Not reproducing — resolved indirectly by BUG-076 + Phase 20 typeFromRef fix (2026-04-21). Verified both `src/TypeChecker.zig` and `selfhost/typechecker.zbr` correctly propagate through `.try_` nodes.

---

### BUG-078: `^ClassName` in union variant double-boxes (`**T`) — FIXED
- **Status:** Fixed — `src/Resolver.zig::walkUnion` emits a hard error when payload is a class type. Test: `test/bug078_double_box_test.zbr` (intentional-error fixture).

---

### BUG-080: `^T?` field assignment — CLOSED NOT REPRODUCING
- **Status:** Closed 2026-04-21. Verified: `n.next = n2` where `next: ^Node?` generates correct `n.next = n2;` — BUG-047 class short-circuit in `genAssign` and `field_needs_deref` both correctly suppress the `.*` for class-typed optional ref fields.
