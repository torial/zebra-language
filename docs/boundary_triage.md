<!-- doc-status: live -->
# Boundary-value suite — method, findings, and what is deliberately not covered

*Tier A3 of `docs/testing_strategy.md`. Probes live in `test/boundary/`, runner is
`tools/boundary_check.sh`.*

---

## 1. Why this is not another golden baseline

`tools/output_sweep.sh` records what 327 corpus programs currently print and fails when
that changes. It is the right tool for regressions and it is structurally incapable of
finding behaviour that was **wrong on day one** — the recorded value is the assertion, so
a wrong value is recorded exactly as confidently as a right one. `testing_strategy.md`
names that as the gap A3 exists to close.

The only thing that closes it is authoring the expectation **from the language reference,
before observing the compiler**. That is a property of the *process*, not of the files, so
it is protected structurally rather than by good intentions:

* The probes and their intended output were committed in **one commit, having never been
  run**. The first run's results were committed **after**. The ordering is visible in
  `git log` and cannot be reconstructed after the fact.
* When a probe disagrees with the compiler, the question is *"which of the two is
  wrong?"* — and the answer is recorded in §3 below either way, including the cases where
  the expectation was wrong.

If a future change ever authors a `.expected` by pasting observed output, this suite has
become `output_sweep` with extra steps and should be deleted rather than kept.

**One honest seam:** how values *render* (a bool prints `true`, an int prints unadorned)
was established with a throwaway program before authoring, and is not part of what the
suite tests. The suite asserts what an operation **yields at a boundary**, not how the
printer formats it. Mixing those would have made every row depend on guessing a print
format, which is not the property under test.

## 2. Outcome kinds

A boundary case has several honest outcomes and a stdout diff models only one. Each probe
declares its kind in a `# @boundary` header:

| kind | assertion |
|---|---|
| `runs` | exits 0, and stdout **equals** the hand-written `.expected` |
| `rejects <text>` | the compiler **refuses** it, naming `<text>` |
| `panics <text>` | it builds, then **fails at runtime** with `<text>` |
| `warns <text>` | it compiles (exit 0) but **emits** `<text>` |

`warns` was added *after* the first run, which is the honest way round: the three-kind
taxonomy was written from reasoning and turned out to be one short. Too-few and too-many
arguments neither run clean nor abort — they warn — and without a kind for that, the two
arity probes would have had to be mis-declared as something they are not. It asserts by
substring rather than by diff, because a warning line carries the absolute source path
and an `.expected` containing one would be machine-specific.

A probe may also carry a second directive:

```
# @boundary-pending BUG-NNN  <one-line reason>
```

meaning **this probe encodes current behaviour that is known to differ from intent**. The
declared assertion is still checked (so the gate is green and honest about today), the
ticket is printed on every run (so the debt cannot go quiet), and when the bug is fixed
the assertion **breaks** — which is the signal to rewrite the probe to assert the intent
it was always meant to. A pending probe is a tripwire on a known gap, not a suppression
of it. See §3.5.

`rejects` and `panics` abort the process, so each such probe is its **own file**. A trap
in case 3 of 20 would silently hide cases 4–20 inside a green suite — the same
coverage-loss shape `gate_selfcheck.sh` exists to catch elsewhere.

## 3. Findings from the first run (2026-07-30)

**9 probes, 6 disagreed with intent.** Of those six: **three were compiler bugs**, **two
were my expectation being wrong**, and **one was a diagnostic-quality problem behind a
wrong expectation. Every row is below, including the ones I got wrong** — a triage that
only records the compiler's mistakes is a scoreboard, not a record.

Scale, for calibration: roughly 140 individual assertions were authored, and about 130 of
them matched the compiler exactly on the first run. The suite's value is concentrated in
the handful that did not.

### 3.1 Compiler bugs found

| # | verdict | summary |
|---|---|---|
| **BUG-230** | real bug, high | `var nums: List(int) = [1, 2, 3]` — an **annotated, non-empty** list literal does not compile. |
| **BUG-231** | real bug, medium | Named arguments do not parse inside `${...}` interpolation. |
| **BUG-232** | real bug, high | Argument-count checking is **skipped entirely** inside `${...}` interpolation. |

**BUG-230** is the one worth studying, because of *how* it hid. A list literal lowers to
`std.ArrayList(T).empty` plus one generated `append` per element; the const-vs-var
mutation analysis does not count those generated appends as mutations, so a binding the
user never mutates is emitted as Zig `const` and its own initialisation then fails. The
symptom appears to be about whichever read-only method follows (`.count()`, `.sort()`,
`.map()`), and is not — adding `nums.add(4)` makes the identical program compile.

It is invisible to **every** heavy gate simultaneously, for two independent reasons:
both compilers do the identical wrong thing (so `divergence_check` cannot see it by
construction), and no corpus file uses the annotated non-empty form (so `compile_check`
and `full_sweep` never emit it). This is the "self-consistency is not correctness" class,
and it is the first instance found *deliberately* rather than by accident.

**BUG-231 and BUG-232 are the same family**: the expression sub-parser used inside
`${...}` is a weaker path than the ordinary expression parser. BUG-232 is the more
serious of the two — `print("${f(...)}")` is the most common shape in the language, so
it is the context where a user is most likely to make an arity mistake and least likely
to be told. The missing argument is padded with a deterministic zero, so the program runs
and prints a plausible wrong answer.

**Scope check, because the first reading was too broad.** After finding arity unchecked
inside interpolation, the tempting conclusion was "the interpolation path skips checking."
That is wrong, and probing it took ten minutes: unknown-method resolution fires normally
inside `${}`, and type mismatches are still *caught* — they merely **degrade** from a
Zebra diagnostic with a caret and the right line to a raw Zig error at the wrong one.
Arity is the only check found absent outright. Recording the narrower claim is the point;
the broader one would have been a correct measurement generalised past its evidence.

### 3.2 Where my expectation was wrong

| row | I expected | actual | verdict |
|---|---|---|---|
| `"".isAlpha()`, `isNumeric()`, `isPrintable()` | `true` (vacuous truth over an empty sequence) | `false` | **expectation wrong.** Codegen contains an explicit `if (s.len == 0) break :blk false` — a deliberate Python-compatible choice (`"".isalpha()` is `False` there too), not an oversight. Expectations corrected. |
| `Point(1, nil)` on a field-only struct | constructs positionally | rejected | **expectation wrong.** QUICKSTART §6 is consistent: positional construction requires a `cue init`; a field-only struct takes named arguments. I omitted the constructor. |

Both are recorded rather than quietly edited, because "the suite disagreed with the
compiler" is only informative if the direction of the error is on the record too.

### 3.3 Diagnostic-quality findings (no ticket filed; recorded for the front-end programme)

These are not wrong behaviour, but they are exactly the *"error lands in generated Zig
instead of the user's source"* problem that `NEXT_STEPS.md`'s "move checking INTO Zebra"
programme exists to fix. Listed here as evidence for it rather than as separate bugs:

1. **Type errors inside `${...}`** degrade from `type mismatch: expected int, got str`
   with a caret at `4:13` to `expected type 'i64', found '*const [4:0]u8'` at line 2.
2. **Positional construction of a field-only struct** reports `type 'Point' does not
   support array initialization syntax` — Zig's vocabulary for a plain Zebra mistake.
3. **`@[1, 2, 3].count()`** reports `no field named 'items' in tuple 'struct { comptime
   comptime_int = 1, ... }'`, leaking the array literal's lowering. (Arrays are not
   Lists, so rejecting it is correct; the message is not.)

### 3.4 A documentation defect found on the way

`isAlpha` / `isNumeric` / `isAlphanumeric` / `isPrintable` are **ASCII-only**
(`std.ascii.isAlphabetic` in codegen), while QUICKSTART describes them as operating on
"Unicode letters" and "codepoints". Verified: `"é".isAlpha()` and `"Ω".isAlpha()` both
return `false`. Same class as the `chars()`/`bytes()` inaccuracy found during §28e's
groundwork — the reference describing an intention rather than the implementation.
QUICKSTART corrected; no compiler change proposed, since ASCII-only is a defensible
choice as long as it is the one being documented.

### 3.5 How the known-broken rows are kept without a red gate

Deleting the three bug-finding probes would have bought a green gate by removing the
coverage that earned it; leaving them red would have produced a gate people learn to
ignore. Instead each carries a `@boundary-pending BUG-NNN` directive: the probe asserts
what the compiler does **today**, the ticket is printed on every run so the debt stays
visible, and when the bug is fixed the assertion **breaks** — which is the signal to
rewrite the probe to assert the intent it was always meant to. A pending probe is a
tripwire on a known gap, not a suppression of it.

## 3A. Second pass — the open tail (2026-07-31)

The three dimensions `NEXT_STEPS` listed as A3's unblocked tail, authored under the same
seam (probes + intent committed unrun in `cf35d85`, results after).

| probe | rows | result |
|---|---|---|
| `bv_deep_nesting` | 10 | **every row matched intent first try** |
| `bv_long_identifiers` | 10 | **every row matched intent first try** |
| `bv_nonascii_ops` | 22 | 2 of my own arithmetic errors; 1 real bug (split out) |

**BUG-234 — `reverse()` byte-reverses, turning valid UTF-8 into invalid.** `"世界".reverse()`
is not `"界世"`; it is not text at all (`isValidUtf8()` false, `codePointCount()` 0, from
input that had 2). Every multi-byte codepoint is affected — `"é"` too — while ASCII is fine,
which is precisely why nothing noticed: the corpus reverses ASCII.

That row existed because a byte reverse and a codepoint reverse differ *exactly* there.
It is the clearest single vindication of the intent-first method so far: `output_sweep`
could never have found it, because no corpus program reverses non-ASCII, so there was
nothing recorded to regress from.

**Where my expectations were wrong again, recorded per the rule:** I asserted
`"Ωmega"` had 6 codepoints and 7 bytes. It has **5 and 6** — I counted the ASCII tail as
five characters instead of four. The `concat` rows inherited the same error. Two rows,
one mistake, entirely mine.

**Where intent was right and worth keeping:** `upper()` leaves non-ASCII unchanged
(`"héllo".upper()` is `"HéLLO"`), which I predicted from the `is…` predicates being
ASCII-only. The model is at least *consistent*, even where it is under-documented.

**A harness bug the probe exposed.** `bv_reverse_nonascii` prints deliberately invalid
UTF-8, which made `grep` treat the stream as binary: it printed `Binary file ... matches`
and DROPPED the row. The row's absence read as "never printed" rather than "the harness
ate it" — the more dangerous of the two readings. Fixed with `grep -a`. A suite whose
whole job is odd inputs must not be blinded by an odd input, and this is the second time
this session that a checker of mine failed on its own subject matter (the first being a
run that measured nothing and reported success).

## 3B. Third pass — integer boundaries (2026-07-31)

The first pass deferred the ENTIRE integer dimension behind BUG-228. That was too broad,
and re-examining it is the reason two more bugs exist on the record. **Only arithmetic
OVERFLOW is build-mode dependent.** Parsing, formatting, the representability of the
extreme literals, and the rounding conventions of `/` and `%` are defined identically in
every mode, so they were probed now.

| probe | rows | result |
|---|---|---|
| `bv_int_boundaries` | 21 | **every row matched intent first try** |
| `bv_min_int_literal` | 5 | **every row matched intent first try** |
| `bv_signed_division` | 10 | **BUG-236** |

`bv_min_int_literal` is split out deliberately: `-9223372036854775808` has no positive
counterpart, so a lexer that reads digits before applying the sign must briefly hold a
value that does not fit. It handles it correctly — but it was the likeliest single row
to fail outright, and a compile failure would have taken 21 other rows with it.

**BUG-236 — `/` and `%` use mismatched conventions.** `/` emits `@divTrunc` (truncate
toward zero) and `%` emits `@mod` (floor). Only two pairings are coherent
(`@divTrunc`+`@rem`, or `@divFloor`+`@mod`) and Zebra uses neither, so
`(a/b)*b + (a%b) == a` — the *definition* of integer division and remainder — is FALSE
for negative operands.

Positive operands agree under every convention, which is exactly why the corpus is
silent: `output_sweep` had nothing recorded to regress from, because no corpus program
takes a modulo of a negative. That is the same shape as BUG-234 (`reverse()` on
non-ASCII) — both found by the same method, both invisible to a golden baseline by
construction, and both cases where a single hand-written row aimed at a known fork in
the semantics paid for the whole dimension.

**A note on what "deferred" should mean.** Deferring the int dimension wholesale cost
two bugs five weeks of invisibility. The lesson is not "defer less" — BUG-228 really
does make overflow unmeasurable — it is that a deferral should name the *specific*
property that is blocked, not the whole dimension that contains it.

## 3C. The tripwires fired — both of them, on real fixes (2026-07-31)

Sean took the recommendations on BUG-234 and BUG-236, and both were fixed the same day
they were found. What is worth recording is not the fixes but **what the suite did when
they landed**:

| probe | authored | went pending | rewritten to intent |
|---|---|---|---|
| `bv_reverse_nonascii` | asserting reverse keeps text valid | found it did not | asserts the intent again |
| `bv_signed_division` | asserting the division identity holds | found it did not | asserts the intent again |

Both probes went **red on their own** when the fix landed, and the red demanded a
rewrite rather than a re-baseline. That is the full lifecycle of a `@boundary-pending`
tripwire, start to finish, twice — and it is the first time the mechanism has been
exercised end-to-end on anything other than a defect planted by `gate_selfcheck.sh`.

The pending count went 6 → 4. The two that closed are the two Sean decided; the four
that remain (BUG-142 ×2, BUG-231, BUG-232) are all still open decisions or unfixed
bugs, which is exactly what pending is for.

**A third fix rode along: BUG-223** (`charAt` typed `str` while emitting `u8`).
Delegated by Sean and taken as recommended — retype to `byte` rather than remove, so
users keep an honest byte accessor. Provably free: the old typing made every consumer a
compile error, so there were zero callers to break. Now guarded by `bv_char_at.zbr`,
which checks that arithmetic on the result works, since being a number is the point.

**What the three fixes have in common, and it is the session's thesis in one line:**
every one was a place where two defensible conventions existed and nobody had written
down which was chosen. Not one was a hard bug in a complicated algorithm. The compiler
is solid where it is complicated and wrong where it is *unspecified* — which is an
argument for writing the spec down, and for a suite whose expectations come from the
spec rather than from the implementation.

## 3D. Round 2 — the non-ASCII byte dimension (2026-08-03): CLEAN

**Result: 2 probes, 15 assertions, 0 findings.** Every hand-authored expectation matched the
compiler on the first run. Suite went 21 -> 23 probes.

**A clean round is a real result here, and it is worth saying why.** Everywhere else in this
repo a green gate mostly means "nothing changed". In THIS suite the expectations were
written from QUICKSTART before the compiler was invoked, so a pass means something stronger:
**the implementation and the documentation independently agree.** Round 1 found three bugs
(BUG-230/231/232) from twelve probes, so the method demonstrably finds things when they are
there. It found nothing here.

That is direct evidence for the decision Sean made the same day — `s[i]` is a byte, matching
Go and Rust. The byte semantics are not merely tolerable; they are implemented
**consistently** across indexing, slicing, `.len`, `.codePointCount()` and `.chars()`.

**Why this dimension, and why now.** Not invented scope — §4 below listed it as uncovered
with a specific blocker, and the blocker expired:

| §4 said | what changed 2026-08-03 |
|---|---|
| non-ASCII indexing: *"a probe asserting today's byte behaviour would enshrine a known bug"* | Sean **decided** byte semantics are intended. Asserting them is now asserting INTENT |
| charAt: *"BUG-223 is an open decision awaiting Sean"* | BUG-223 fixed 2026-07-31, documented `(int): byte` |
| overflow: *"Do this dimension after BUG-228"* | BUG-228 fixed 2026-08-03 |

### 3D.1 The finding that arrived BEFORE any probe ran

**QUICKSTART does not document integer overflow or division-by-zero behaviour at all.** The
only matches in the whole reference are user code raising its own `"division by zero"`.

This suite's premise is that expectations come from the reference. An undefined behaviour
therefore **cannot be probed without inventing the answer** — and a probe encoding an
invented answer is worse than no probe, because it looks like a specification.

So the overflow dimension stays uncovered, but the reason has changed and sharpened: it was
recorded as *"build modes are in flux"*, which is now resolved. The real blocker is that
**there is nothing written down to assert**. Deciding the semantics and documenting them is
the prerequisite, not more probing. That is a docs/design task, not a testing one.

### 3D.2 Two assertions deliberately shaped around what is NOT defined

Recorded because the shape is the reusable part, not the rows:

* **`s[i]` is asserted by COMPARISON, never by rendering.** It is typed `char` (BUG-225), so
  interpolating it prints a *character*, not a number — and how a raw byte renders as text
  is not defined anywhere. Every row is a length or an equality. The load-bearing row is
  `s[1] == c'é'` asserted **false**: `s[1]` is é's lead byte, which is precisely the
  documented divergence, asserted positively rather than lamented.
* **`s[0..2]` is asserted by LENGTH only.** It crosses a codepoint, so it is invalid UTF-8,
  and what invalid UTF-8 does when printed is undefined. The length is defined; the
  rendering is not.

**`charAt` was NOT probed**, despite being unblocked. It returns `byte`, and comparing a
`byte` to a `char` is exactly the question BUG-225 leaves undefined — probing it would
require inventing that answer as well. Added to §4 rather than quietly skipped.

### 3D.3 What a clean round does NOT license

**One dimension, two probes, fifteen assertions.** The quality audit's exit criterion — *"a
round of new A3 probes finds nothing"* — is **not** met by this. It is one dimension of one
round coming back clean. The dimensions with the strongest remaining prior are the ones §4
still lists, and the honest reading is: the region we just probed is sound, and we have said
nothing about the regions we have not.

---

## 4. Not covered, and why — no silent caps

The suite covers four dimensions completely rather than nine partially. What is **not**
covered is listed here and printed by the runner on every invocation, so the gap cannot
quietly be mistaken for coverage.

| dimension | why not |
|---|---|
| **overflow, division by zero** (min/max literals + parsing + `/`,`%` rounding now COVERED, see 3B) | Behaviour is **build-mode dependent** and the modes are currently in flux: the default is Debug on the self-hosted backend (where overflow traps), while **BUG-228** records that `--release` does not actually pass an optimize flag, and Sean's direction is to make ReleaseFast good enough and A/B it. Authoring expectations now would pin one mode's answers as the language's, and they would flip when BUG-228 lands. Do this dimension *after* BUG-228. |
| **float extremes** (inf, nan, -0.0, denormals) | Same reason, plus float **formatting** is a second unpinned variable. |
| **non-ASCII indexing** (`s[i]`) | **BUG-225** — typed `char`, holds a raw byte, silently wrong for non-ASCII. §28e decided this is **documented for 0.9 and retyped in 1.x**. A probe asserting codepoint semantics would fail forever by design; a probe asserting today's byte behaviour would enshrine a known bug. |
| **`charAt`** | **BUG-223** is an open decision awaiting Sean. Encoding either answer would be this suite legislating a user-facing API change. |
| ~~deep nesting, very long identifiers~~ | **DONE 2026-07-31.** Both clean — every row matched intent on the first run. |
| ~~non-ASCII in string *operations*~~ | **DONE 2026-07-31**, and it found **BUG-234**. |

The four dimensions covered — empty string, empty collections, nil at every position, and
argument arity — were chosen because **BUG-223 and BUG-224 both came from exactly there**,
found by accident. That is the region with the strongest prior.
