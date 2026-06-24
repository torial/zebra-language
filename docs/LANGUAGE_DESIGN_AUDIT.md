# Zebra language-design audit

*Drafted 2026-06-24, pre-1.0. A critical eye on the language surface itself
(not the stdlib — that's `API_FREEZE_AUDIT.md`). Organized by Sean's three
lenses: (a) inconsistent, (b) redundant, (c) borrowed-but-not-adapted. Each item
has a **verdict**: 🔧 fix before freeze · 🤔 reconsider (subjective, your call) ·
✅ defensible-but-noted. Opinionated by request; many of these are deliberate
choices I'm pressure-testing, not bugs.*

---

## (a) Inconsistencies

### L1. `print` is a statement, not a function 🔧
`print` parses as `kw_print ExprList` (a Python-2 / BASIC print *statement*), so
`print x` and `print x, y` are valid — but the docs and real code also write
`print(x)` and `print("${m}")`, which only work because `(x)` is a parenthesized
expression argument. The result: `print` *looks* like a function call half the
time and a bare statement the other half, and it's the one "call-like" thing in
the language that isn't a call. Everything else uses `f(args)`.
**Verdict:** make `print` a regular function (`print(...)`), matching the rest of
the language and what most examples already show. This is the single most
visible language inconsistency and it freezes permanently. (Python 3 removed the
statement form for exactly this reason.)

### L2. Size access: `.len` (property) vs `.count()` (method) 🔧
`str.len` is a property; `List.count()` and `HashMap.count()` are methods. Two
spellings for "how big is it," differing by collection. (And `str.count(sub)` is
a *different* operation — substring count — overloading the word.)
**Verdict:** pick one spelling for size across all collections+str (recommend
`.len` everywhere — it reads as an intrinsic property, and frees `count(x)` to
mean "count occurrences of x"). Freezes permanently otherwise.

### L3. The `to` keyword is overloaded 5 ways 🤔
`to` means: range bound (`for i in 0 to 10`), cast (`x to T`), force-unwrap
(`x to!`), try-unwrap (`x to?`), and a postfix method (`0.to(5)`). One keyword,
five jobs — heavy context-disambiguation for a reader.
**Verdict:** reconsider at least the range use (see L4) and the `to!`/`to?`
unwrap forms (see L7); the cast `x to T` is the clearest claimant to `to`.

### L4. Ranges use `to`/`step`; slices use `..` 🤔
`for i in 0 to 10 step 2` (BASIC/Pascal) vs `src[a..b]` (Rust/Python). Both
express a span, with different syntax. A learner meets two "range" notations.
**Verdict:** reconsider unifying — e.g. `for i in 0..10` / `0..10 step 2`, or at
minimum document the deliberate loop-vs-slice split. (See also L11.)

### L5. `^T?` vs `T?` ordering ✅
Known "managed friction" (`concept_zebra-language-warts` W11). The `^` (heap) and
`?` (optional) modifiers compose but the order trips newcomers. Deliberate cost
of the Zig backend; flagged, not fixable without giving up `^T`.

---

## (b) Redundancies

### L6. Two force-unwrap forms: `x!` and `x to!` 🔧
`x to!` is an explicit alias for `x!` (warts W7 kept it). Two syntaxes, one
operation — exactly the kind of thing a freeze should not lock in duplicate.
**Verdict:** keep `x!` (terser, reads like Swift/Kotlin), deprecate `x to!`
before freeze (or vice-versa — but pick one).

### L7. `unless` / `until` 🤔
Pure sugar: `unless c` → `if not c`, `until c` → `while not c` (Ruby/Perl import).
They add keyword surface and parser paths for zero expressive power, and `unless`
in particular is a well-known readability foot-gun (the Ruby community itself
discourages `unless ... else`).
**Verdict:** reconsider dropping both — `if not` / `while not` are barely longer
and unambiguous. If kept, it's a deliberate ergonomics bet; just know it's
redundant surface frozen forever.
**DONE (2026-06-24): both removed.** `unless`/`until` were pure parser desugar
(`unless C` → `if not C`, `until C` → `while not C`) with one test usage; the
keywords + grammar + parser support are gone from both compilers. `to?` (the
"to-optional" wrap operator, 0 usages) is being removed in the same pass — it
turned out to mean *wrap-in-optional*, which assignment already does implicitly,
not "try-unwrap" as the name suggested.

### L8. `with` and `using` are both "scoped context" 🤔
Two block constructs that both establish a scope: `using EXPR` (resource
lifecycle, begin/end) and `with obj` (implicit receiver). Distinct purposes, but
a reader meets two context-block keywords. (The bigger issue is naming — see L10.)
**Verdict:** the *functions* are both worth having; the *names* need rethought.

### L9. `cue` marks dunder / special-protocol methods ✅
*(Revised 2026-06-24 after Sean clarified the intent.)* `cue` is not
constructor-specific ceremony — it's the marker for **special-protocol ("dunder")
methods**, inherited from Cobra's design. `cue init(...)` is the constructor as
one instance of a special method; the keyword generalizes to other protocol hooks
(`cue eq`, `cue str`, `cue hash`, …) as they're added. Framed that way it's a
**deliberate, extensible** choice — and arguably *clearer* than Python's
`__dunder__` naming convention, because the specialness is a keyword rather than a
fragile naming trick the reader has to recognize.
**Verdict:** defensible; keep. The earlier "opaque ceremony" read was wrong — the
payoff is an explicit, greppable special-method namespace. (Worth a QUICKSTART note
listing the recognized `cue` hooks so the set is discoverable.)

---

## (c) Borrowed but not adapted to Zebra idiom

### L10. `with` / `using` are *backwards* from mainstream ⚠️🔧
This is the boldest finding. In Python and C#, the resource-lifecycle construct
is spelled `with` (Python) / `using` (C#). Zebra uses **`using`** for resource
lifecycle (begin/end) and **`with`** for Pascal/VB-style *implicit-receiver*.
So a Python/C# developer reading `with g` expects "g is a managed resource for
this block" but gets "g is the implicit receiver" — and Zebra's actual
resource construct is the *other* keyword. The two most-loaded context keywords
were imported from three different languages with their meanings crossed.
Pascal's `with` (implicit receiver) is itself widely considered a mistake
(ambiguous shadowing) — which is why Zebra had to bolt on the "top-level
statements only, not nested" restriction to make it safe.
**Verdict:** strongly reconsider before freeze. Option: `using`/`with` →
resource lifecycle (match Python/C#), and rename the implicit-receiver construct
to something that doesn't collide (it's GUI-builder sugar — a name like `on obj`
or folding it into the builder pattern). Locking the crossed meaning is the
language-design decision I'd least want frozen.

### L11. `to` / `step` ranges are BASIC/Pascal 🤔
`FOR i = 0 TO 10 STEP 2` is 1964 BASIC. Modern languages (Rust, Swift, Kotlin,
Python via `range`) use `..` / `..<` / explicit range objects. It reads dated and
clashes with Zebra's own `..` slices (L4).
**Verdict:** reconsider `..`-based ranges for idiom + internal consistency.

### L12. `print` statement is Python-2 (L1 from the borrowing angle) 🔧
Covered in L1 — worth naming here too: the print *statement* is the one construct
Python explicitly deleted between 2 and 3. Adopting the abandoned form is the
clearest "borrowed without re-examining" case.

### L13. Exception vocabulary is a three-language mix ✅
`throws` (Java), `raise` (Python), `catch |e|` (Zig). The *model* (exceptions
primary, richer than Zig error unions) is a deliberate, documented decision
(warts W4) and it works well. The *vocabulary* is mixed-heritage — Python pairs
`raise` with no declaration; Java pairs `throw` with `throws`. Minor; the pieces
are individually familiar and the blend is coherent enough in practice.
**Verdict:** defensible; noted only for completeness.

### L14. `^T` is Pascal pointer syntax ✅
Deliberate, and reasonably adapted (auto-box rules, transparent branch binding,
`^ClassName` is a compile error). The Pascal `^` will read oddly to C/Rust folks
but the semantics are Zebra's own. Accept (= W11).

---

## Recommendation: the pre-freeze short list

If the freeze is "lock it forever," these four are worth resolving *first*
because they're cheap to change now and permanent to change later:

1. **L1/L12 — make `print` a function.** Removes the single most visible
   inconsistency; aligns with every other call.
2. **L2 — one size spelling** (`.len` everywhere).
3. **L6 — one force-unwrap form** (`x!`; deprecate `x to!`).
4. **L10 — fix the `with`/`using` naming cross** so it matches mainstream
   expectations.

The `🤔` items (L3/L4/L7/L9/L11 — ranges, `unless`/`until`, `cue`) are judgment
calls on idiom vs. familiarity; worth a deliberate decision, but each is
defensible if chosen consciously. The `✅` items (`^T`, exception vocabulary) are
sound deliberate choices.

Net: the language is in good shape — most friction is concentrated in a few
keyword/spelling choices, and only four are genuinely worth fixing before the
"never remove" line. None touch the type system, semantics, or the contract
identity feature, which are solid.
