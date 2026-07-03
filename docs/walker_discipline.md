# Walker discipline — structural lessons from the 2026-07-02 fuzz campaign

Ten bugs were fixed in one day (BUG-159..168, two-faced BUG-166), all found
or confirmed by the differential fuzzer. They cluster into four structural
causes. This note names them so the next fix targets the class, not the
instance.

## 1. The two walker families have OPPOSITE safety rules

The compilers are full of AST walkers ("does this body use name X?", "does
this method touch self?"). They fall into two families, and confusing them
is the single largest bug source of the campaign (5 of the 10):

**Conservative family** — `mightUseName*` (both compilers). Callers suppress
an *optimization* (a `_ = x;` discard) when the walker says "maybe used."
`else => true` is SAFE here: over-approximating just means a missed discard,
and the failure is loud (Zig unused-const error, caught by any gate). The
F2/BUG-161 fixes were about making this family *more precise* (modelling
`this`, `string_interp`, `orelse`) — precision is an improvement, never a
requirement.

**Exact family** — `stmtMentionsThis` / anything deciding `_ = self;` or a
discard the other direction. Here BOTH error directions are Zig compile
errors: emit the discard when the name IS used → "pointless discard"; skip
it when the name is NOT used → "unused parameter/constant." An `else` arm —
whichever value it returns — is a landmine that detonates when a statement
form is added (BUG-166 face 1: `else` missed if-else branches; face 2: the
same walker had no `for_num` arm, and it blew up *hours* after range loops
were added to the generator).

**Rules:**
- New Stmt/Expr AST variants MUST be added to every exact-family walker in
  the same commit. Grep list (selfhost): `stmtMentionsThis`,
  `exprMentionsThis`, `nameUsedInStmt` when feeding discard decisions.
- Bootstrap: prefer exhaustive `switch` (no `else`) in exact-family walkers
  so a new AST variant is a compile error until every walker decides.
- Selfhost: the same protection is exactly what §28c (exhaustiveness
  default-on) buys — this campaign is its empirical justification.

**RETIREMENT DONE 2026-07-03 (the discard-decision walker).** `mightUseName`/
`mightUseNameInExpr`/`mightUseNameStmt` (the unused-capture/local discard
decision — the walker behind F2/BUG-161, F6/BUG-166, F11/BUG-169) were the
worst offenders: conservative `else => true`, so any unmodeled form skipped a
needed discard. Fixed structurally, not by another arm: the **bootstrap** now
uses **exhaustive switches with NO `else`** for both walkers — the Zig compiler
refuses to build if a future Expr/Stmt tag is unhandled, so the class *cannot*
silently return. The **selfhost** mirrors it (mightUseNameStmt is fully
exhaustive → no `else`; mightUseNameInExpr keeps an `else` only for the two
genuinely ident-free forms zig_lit/result_), and **round-trip** enforces
behavioural parity with the bootstrap. This is the template for retiring any
member of the exact family: make the bootstrap switch exhaustive; let the
compiler be the completeness gate. (`stmtMentionsThis` is the next candidate;
it still has an `else`.)

## 2. Inference gaps degrade to guessed emit, not errors (§28a)

BUG-159 (untyped comptime local), BUG-168 (cross-module primitive returns
invisible → raw `+` on slices), and the F7 first-hypothesis near-miss are
one class: **type information exists but does not reach the decision site,
and the emitter guesses instead of failing.** The §28a rule (no typed
dispatch site may guess; unresolvable inference is a Zebra-level
diagnostic) remains the deep fix; until it lands, treat any `else`/fallback
arm in a type-dispatched emitter as a bug report waiting to happen.

BUG-168's validation is the model: after fixing the TC, regenerating the
selfhost changed exactly one emitted line — an annotation became *more*
precise. Inference fixes should make emission strictly better, never
different-and-worse; the round-trip gate proves it per fix.

## 3. Emitters must re-establish what the parser threw away

BUG-163 (orelse/catch/if-expr/try re-associated without parens) and BUG-162
(primitive-name spellings) share a shape: the parser normalizes source
(drops redundant parens, keeps names as plain strings), so the emitter is
responsible for re-establishing validity in the target language. Any
Zig construct that binds looser than every operator must self-parenthesize;
any identifier position must escape-or-collide. When adding an emission
form, ask: *what did the parser normalize away that Zig needs back?*

## 4. Ungenerated syntax is unverified syntax

F8 (two parsers, two ternary syntaxes, zero corpus usage) and F9 (three
range spellings, docs describing a fourth that never existed) prove that a
feature with no generator surface and no corpus usage WILL drift — silently,
because nothing can fail. Standing rule adopted 2026-07-02:

> **New syntax lands with a fuzz generator surface (a `caps` flag in
> `fuzz/gen.py`) and a smoke-registered fixture, in the same commit.**

The fuzzer's grammar is the de-facto verified-language spec; QUICKSTART
describes intent, the generator proves agreement.

---

Cross-references: `fuzz/FINDINGS.md` (per-finding detail), `BUGS.md`
BUG-159..168, `NEXT_STEPS.md` §28 (a: inference-or-error; c: exhaustiveness
default-on — both are the systemic versions of these lessons).
