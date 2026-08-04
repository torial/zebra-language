<!-- doc-status: historical -->
# BUGS.md entries removed as duplicates — 2026-08-04

Eleven bug numbers existed in **both** `BUGS.md` and `BUGS_FIXED.md`. The open ledger's
copies were removed, because an entry present in both makes the open list lie about what is
open.

Their bodies are kept here rather than discarded, for one reason: where the two copies
differed, the BUGS.md text sometimes carried an *original* pre-fix description ("original
entry, retained for context") that the fixed ledger summarises rather than reproduces. That
is history, and this repo's convention is that history is not edited away.

**Nothing here is open.** Every number below is resolved and documented in `BUGS_FIXED.md`;
that file is authoritative. This is an archive of the removed duplicate text only.

---

### BUG-111: ✅ NOT-A-BUG 2026-05-05 — compound assign already works

Verified in both backends: `.count += 1`, `this.count += 1`, and
`obj.count += 5` all parse, codegen, and run correctly. The original
filing was based on a repo-wide grep finding "zero occurrences" of
`this.X +=`, but that turned out to be stylistic legacy (selfhost
authors used the verbose `this.X = this.X + 1` form before `.field`
shorthand was canonical), not a compiler limitation.

Closing as not-reproduced. No code change needed for BUG-111.

---

### BUG-111 (original entry, retained for context):
- **Severity:** Low (workaround is verbose but correct)
- **Status:** Open — phase 0.13 syntax-cleanup window
- **Symptom:** `this.pos += 1` and (after style-guide adoption) `.pos += 1` either fail to parse or fail to codegen. Verified via repo-wide grep: zero occurrences of `this\.\w+ \+=` exist in any `.zbr` file across selfhost, test, or examples — confirming users have learned to avoid the form. The workaround in current code is `this.pos = this.pos + 1`.
- **Reproducer:**
  ```zebra
  class Lexer
      var pos: int
      cue init()
          pos = 0
      def advance()
          .pos += 1     # expected: codegen `self.pos += 1`
  ```
- **Why it matters now:** the style guide (see `STYLE_GUIDE.md` §13.1) has flagged the verbose form as compiler-driven, *not* canonical. When this fixes, the sweep is one grep across selfhost.
- **Fix sketch:** investigate whether the parser admits compound-assign on a member-access LHS, then whether codegen emits the correct shape. Likely a 1-line parser fix + codegen verification.
- **Discovered:** 2026-05-04 during style guide drafting.
- **Source:** `STYLE_GUIDE.md` §13.1.

---

### BUG-112: ✅ FIXED 2026-05-05 — no-paren shorthand removed

Grammar rule removed from both `src/Parser.zig` and `selfhost/parser.zbr`.
38-site sweep (`def name: T → def name(): T`) across 17 files completed.
Bootstrap 5/5, smoke 43/43. See commits `2f7e767` + `598a533`.
Migrated to BUGS_FIXED.md.

---

### BUG-112 (original entry, retained for context):
- **Severity:** Low (cosmetic; both forms work today)
- **Status:** Fixed 2026-05-05
- **Symptom:** `def name: T` and `def name(): T` are both legal and equivalent. Callers always write `obj.name()` regardless. The no-paren form is a vestige of the removed `prop`/`get`/`set` machinery (per `project_remove_property_keywords.md`) — it survives but no longer carries weight, and visually contradicts the call-site syntax (footgun: reads as a getter that doesn't need parens at the call site, which isn't true).
- **Repo data:** 38 no-paren occurrences across 17 files; 124 explicit-paren occurrences across 25 files. The repo's revealed preference is `def name(): T`.
- **Fix sketch:**
  1. Sweep the 38 no-paren declarations to `def name(): T` form (mechanical).
  2. Remove the no-paren rule from `parser.zbr` and `src/Parser.zig` so it can't drift back in.
  3. Tokenizer / TC unaffected — they already canonicalise both.
- **Discovered:** 2026-05-04 during style guide drafting.
- **Source:** `STYLE_GUIDE.md` §1 Q2.

---

### BUG-113: ✅ NOT-REPRODUCED 2026-05-05 — slice TC works correctly

Verified: `var text = src[0..3]` correctly types `text` as `str` and
`text.toFloat()` dispatches correctly without an explicit `: str`
annotation.  Both forms (annotated + bare) produce identical output.

The original `pratt_calc.zbr:134` author comment described a real
limitation at the time it was written, but the TC has since improved
(possibly via the BUG-099 work that made type inference more
disciplined, or via earlier inferenceupdates).  The annotation in
pratt_calc is now redundant but harmless — left in place.

Closing as not-reproduced.

---

### BUG-113 (original entry, retained for context):
- **Severity:** Medium (forces explicit annotations downstream of any string slice)
- **Status:** Open — TC inference gap
- **Symptom:** `var text = this.src[start..pos]` infers `text` as something that doesn't dispatch `.toFloat()` correctly, requiring users to write `var text: str = this.src[start..pos]`. The author of `pratt_calc.zbr` documented this in a comment at line 132–134:
  > "the compiler's TC currently loses the slice's str type once it passes through a `var`, so we annotate explicitly to guide `.toFloat()` to the right dispatch."
- **Reproducer:**
  ```zebra
  def parse(src: str): float? throws
      var text = src[0..3]      # text is inferred as ?
      return text.toFloat()     # may fail to dispatch correctly
  ```
- **Fix sketch:** check `inferExpr` for the slice arm — `str[int..int]` should infer back to `str`. Likely a missing case in either the bootstrap or selfhost typechecker (or both, given parity work).
- **Discovered:** 2026-05-04 during style guide drafting; the workaround is in `pratt_calc.zbr:134`.
- **Source:** `STYLE_GUIDE.md` §13.2.

---

### BUG-099: ✅ FIXED 2026-05-05 — Type three-way split shipped (Zig + selfhost)

**Zig backend (src/TypeChecker.zig):** `.context_dependent` / `.unknown` /
`.unresolved` split. `.unresolved` carries an `Ast.Span` for blame. Alarm bell
fires at `checkVarDecl` expectation sites.

**Selfhost port (selfhost/typechecker.zbr):** Completed 2026-05-06. Three new
`Type_` variants added:
- `context_dependent` — nil literal inner type, `result` outside return context,
  if-capture defaults; resolved by the outer checker.
- `unresolved` — TC failed to infer: ident miss, member miss, call fallback,
  index/slice fallback, expr catch-all.
- `unknown_` — unchanged: intentional opaque cases (`this` outside class,
  loop-var default, `addClassMembers` no-annotation, `unbind` sentinel).

`isAbstractType()` helper mirrors `src/TypeChecker.zig isAbstract()`.
Alarm bell added to `checkVarDecl` behind `ctx.strict` flag (enabled by
`typecheck-merge` subcommand only; safe for normal compilation).
`codegen.zbr` format-spec updated to fall through for all three abstract types.

Verified: bootstrap 5/5 round-trip, 44/44 selfhost smoke, full test suite clean.

See commits 429ff98d → 4c84c51b (Zig) for the audit trail. Migrating to
BUGS_FIXED.md.

---

### BUG-099 (original entry, retained for context):
- **Severity:** High (foundational; gates merge-oracle reliability and is the upstream cause of many silent-accept bugs below)
- **Status:** Open
- **Symptom:** The TC's `Type.unknown` is overloaded across three semantically distinct cases that propagate identically:
  1. **Context-dependent (legitimate):** type depends on usage context (e.g., `nil` literal, `result` reference inside a function whose return type is being inferred).
  2. **Opaque-by-design (legitimate):** the TC genuinely cannot and should not assign a concrete type (e.g., `zig_lit`, opaque cross-module externs, generic type parameters not yet substituted).
  3. **Unresolved (illegitimate):** the TC failed to derive a type it ought to have known (e.g., member access on an unknown object, list literal element-type punted to codegen, cross-module field lookup miss).
  Cases 1–3 all return `.unknown`. Downstream rules like "RHS of `var x: int = expr` must be `int`-compatible" can't tell case-3 from case-1, so:
  ```zebra
  var x: int = some_undefined_call()   # silently typechecks; RHS infers to .unknown
  ```
- **Reproducer:** `var x: int = NoSuchMethod()` — RHS infers to `.unknown`, no diagnostic emitted.
- **Root cause:** Type union in `src/TypeChecker.zig` collapses three different concepts into one variant.
- **Fix sketch:** Split into three Type variants:
  - `.context_dependent` — propagates without complaint until a concrete-type expectation site supplies a hint
  - `.unknown` — opaque by design; never errors at expectation sites either
  - `.unresolved` — alarm bell; first concrete-type expectation site emits a diagnostic and the value's source span gets the blame
  Audit every site that currently returns `.unknown` and re-classify into the appropriate bucket. Goal state: zero `.unresolved` instances at typecheck completion on a valid program.
- **Why three buckets, not two:** `.unresolved` is the alarm-bell category. Conflating it with `.unknown` (opaque-by-design) means we can't distinguish "the type system is doing its job on opaque externs" from "the TC gave up."  Three buckets makes the second case visible and countable — ideally always zero on accepted programs.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` cross-cutting finding). User-suggested three-bucket taxonomy 2026-05-01.

---

### BUG-102: Selfhost typechecker has 65+ `to!` force-unwraps — audit needed
- **Severity:** Medium (each is a potential panic with no diagnostic; unknown how many are unguarded)
- **Status:** Closed — fixed 2026-05-06
- **Resolution:** Full audit of all `to!` sites in `selfhost/typechecker.zbr`. All 41 sites are now guarded:
  - 20 converted to `if x as v` (idiomatic optional-unwrap) — works for `String?`, `List(Stmt)?`, `Type_?` same-file locals and cross-module fields
  - 21 kept as `if x != nil: ... to!` with `# safe: nil checked above` or `# safe: nil returned above` comment — required for cross-module `TypeRef?` and `^Expr?` fields (bootstrap TC gap: doesn't track these as optional; tracked separately)
  - Zero unguarded `to!` remain
- **TC gap note:** The Zig bootstrap TC (`src/TypeChecker.zig`) does not correctly infer `TypeRef?` and `^Expr?` cross-module field types as optional, causing `if x as v` to fail with "requires an optional type, got 'TypeRef'". This is a pre-existing gap, not introduced by this fix. The safe guarded `to!` pattern is the correct workaround until that gap is closed.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P0-3]).

---

### BUG-105: ✅ FIXED 2026-05-05 — enum_member/union_variant resolve to parent type

`inferMember` now returns `Type{ .named = parent_sym }` when looking up
an enum member or union variant via member access. `var c: int = Color.red`
correctly errors; `var c: Color = Color.red` typechecks. Test:
`test/bug105_enum_member_test.zbr`. See commit `f254b754`.

---

### BUG-105 (original entry, retained for context):
- **Severity:** Medium (TODO comment in `:2892`; affects type inference for any enum/union expression usage)
- **Status:** Open
- **Symptom:** `src/TypeChecker.zig:2892, 2894` — `Color.red` infers to `.unknown` instead of `.named(Color)`; `Result.ok(...)` similarly. Downstream rules like `var c: Color = Color.red` then can't catch a mismatch because RHS is `.unknown`.
- **Reproducer:**
  ```zebra
  enum Color: red, blue
  var c: int = Color.red    # should error; today silently typechecks
  ```
- **Root cause:** TODO comments in `inferExpr` for these two AST kinds — never wired up.
- **Fix sketch:** Resolve to `.named(parent_enum)` / `.named(parent_union)` from the resolver's symbol info. Becomes much easier after BUG-099 when `.unresolved` is the alarm-bell bucket.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-3]).

---

### BUG-106: ✅ FIXED (partial) 2026-05-05 — literal homogeneity check shipped

`list_lit` / `array_lit` / `dict_lit` now walk elements and require
mutual `isAssignable` for non-abstract element types. Heterogeneous
literals like `[1, "two", 3]` now error precisely at the offending
element's span. Numeric mixes `[1, 2.0, 3]` still pass (untyped-numeric
semantic). Test: `test/bug106_heterogeneous_list_test.zbr`. See commit
`4c84c51b`.

CAST-VALIDITY (2026-05-18): TC check added proactively to both backends —
when source type is numeric/bool/string and target is `.named` (class/struct),
the TC now emits "cannot cast 'int' to class/struct type 'ClassName'" (Zig:
`src/TypeChecker.zig` cast arm; selfhost: `inferExpr Expr.cast` arm).

The check is correct but currently untestable because the `expr to TypeRef`
cast syntax is broken: the selfhost parser only handles `to!`; the bootstrap
AstBuilder panics with "unexpected NT TypeRef" when the grammar produces an
`Expr9 kw_to TypeRef` subtree. The `ExprCast` AST node exists but is never
created in practice. This is documented in `test/bug106_cast_test.zbr`.
Fix will become testable once the cast parser path is wired up.

---

### BUG-106 (original entry, retained for context):
- **Severity:** Medium (silent miscompile potential; merge-oracle blocker)
- **Status:** Open
- **Symptom:** `src/TypeChecker.zig:1705-1707` — `[1, "a"]` (heterogeneous) infers to `.unknown` without complaint. `dict_lit`, `array_lit` similar. Also `.cast` at `:1693` returns the cast target without validating source-type compatibility (`42 as ClassType` typechecks).
- **Reproducer:**
  ```zebra
  var xs: List(int) = [1, "two", 3]   # silently typechecks; RHS is .unknown
  var c: ClassType = 42 as ClassType  # silently typechecks; impossible cast
  ```
- **Fix sketch:** For literals, walk elements and verify common type (or common supertype if subtyping lands). For `.cast`, validate source/target compatibility (numeric→numeric, optional unwrap, named-class downcast).
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-4]).

---

### BUG-108: ✅ FIXED (partial) 2026-05-05 — `this` outside class diagnostic shipped

`this` outside a class/struct method or `with` block now emits a
defensive diagnostic at the `this` token span: "'this' used outside a
class/struct method or 'with' block". Test:
`test/bug108_this_outside_class_test.zbr`. See commit `01296dbd`.

REMAINING (deferred):
  - inferIdent miss → handled differently via BUG-099 alarm bell
    at expectation sites (commit `60698f6a`).
  - inferMember cross-module miss → softened to `.unknown` to avoid
    false positives on legitimate cross-module patterns (commit
    `4c84c51b`).
  - index/slice on non-indexable, `expr_types.get` fallbacks: have
    legitimate non-error cases (HashMap[k], generic types,
    TC-sequencing internals) where blanket emitError would false-
    positive. Lower priority.

---

### BUG-108 (original entry, retained for context):
- **Severity:** Medium (umbrella for several P2/P3 sites; many become trivial after BUG-099)
- **Status:** Open
- **Symptom:** Multiple sites silently return `.unknown` where a diagnostic should fire if the TC has reached a state it shouldn't have. Each is benign on well-formed code (some other phase caught the error first) but failure-amplifying when the upstream catch is missed.
  - `inferIdent` (`src/TypeChecker.zig:1739-1747`) — resolver miss returns `.unknown` with no defensive `emitError`. If Resolver is buggy, no diagnostic from TC.
  - `inferMember` (`:1749-1768`) — cross-module member-not-found returns `.unknown` silently (`:1767`).
  - `index`/`slice` on non-indexable (`:1678-1690`) — silently returns `.unknown` for `someInt[0]`.
  - `this` outside class context (`:1672-1673`) — silently `.unknown` if `ext_self_type == null and owner_sym == null`.
- **Fix sketch:** Add defensive `emitError` at each site. Most won't fire on well-formed code (other phases caught it); they're insurance. After BUG-099, these all become "if the result is `.unresolved`, emit at this site."
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entries [P2-1, P2-2, P2-3, P3-1]).

---

### BUG-092: ✅ FIXED 2026-05-07 — `var lines: List(str) = s.split(sep)` now auto-collects the iterator
- **Severity:** Medium (typed `split` into a `List` is the obvious idiom; required an obscure workaround)
- **Status:** Fixed:
  - `src/CodeGen.zig genLocalVar`: when the declared type is `List(str)` and the init expr is a `split` call, the emitter now wraps the `SplitIterator` in a `std.ArrayList` collector loop automatically.
  - `selfhost/codegen.zbr genLocalVar`: same collector inserted in the selfhost path.
  - Test: `test/bug092_split_to_list_test.zbr`; added to `selfhost_smoke.sh`.
- **Original symptom:** `var lines: List(str) = s.split("\n")` emitted the raw `SplitIterator` into the `ArrayList` slot, causing a Zig type mismatch at compile time.
- **Discovered:** 2026-05-06 during stdlib `str` smoke pass.

---

### BUG-091: ✅ FIXED 2026-05-07 — `List`/`HashMap` params mutated inside body now emit `*ArrayList` and call sites take `&`
- **Severity:** High (List/HashMap mutation via methods like `.add()` silently had no effect on the caller's copy)
- **Status:** Fixed:
  - `src/CodeGen.zig`: param declared `List(T)` or `HashMap(K,V)` that is mutated inside the body now emits `param: *std.ArrayList(T)` / `*std.AutoHashMap(K,V)`; call sites pass `&arg`.
  - `selfhost/codegen.zbr`: same mutation-analysis pass + `&` insertion in `genArgs`/`genArgListNamed`.
  - Tests: `test/bug091_list_param_test.zbr`, `test/bug091_dispatch_test.zbr`; both added to `selfhost_smoke.sh`.
- **Original symptom:** `def addTo(items: List(str), x: str): void` emitting `items: std.ArrayList(str)` (value), so mutations never escaped back to the caller.
- **Related:** BUG-097 (follow-on: passing an already-`*ArrayList` arg through a chain still has issues).
- **Discovered:** 2026-05-06 during stdlib smoke pass.

---

### BUG-120: Selfhost codegen `.add()` → `.append()` rewrite fires on class method calls via lowercase variables
- **Severity:** Medium (silent miscompile — method call becomes a list append; Zig rejects with "no field or member function named 'append'")
- **Status:** Fixed 2026-05-07 — see `BUGS_FIXED.md`
- **Symptom:** In `selfhost/codegen.zbr`, the `.add()` → `.append()` heuristic only guards on `isUpperCase(receiver_name)` (capital first letter = namespace/class static call, e.g., `Math.add()`). Lowercase instance variables (e.g., `c: Calc`) are not guarded. So `c.add(2, 3)` where `c` is a `Calc` instance incorrectly emits `c.append(_allocator, 2)`, which Zig rejects.
- **Reproducer:**
  ```zebra
  class Calc
      def add(a: int, b: int): int
          return a + b
  def main()
      var c = Calc()
      var r = c.add(2, 3)   # ← selfhost emits: c.append(_allocator, 2) — WRONG
  ```
- **Root cause:** `codegen.zbr` around line 3949: the guard `isUpperCase(receiver_name)` (BUG-061 fix) protects `ClassName.add()` but not `instance.add()`. A correct fix needs to check the receiver's inferred type — if the receiver is not a List (or HashMap), the rewrite must not apply. This requires InferCtx type tracking at the call site.
- **Proper fix:** Consult `InferCtx` at the `.add()`/`.remove()` etc. call site to confirm the receiver infers to `List(T)` before applying the rewrite. If the receiver is a class instance, skip the rewrite entirely.
- **Workaround:** Avoid naming methods `add` (or any other List-method name: `remove`, `contains`, `get`, `pop`, `insert`, etc.) on user-defined classes when compiling via the selfhost backend. The Zig bootstrap backend is unaffected.
- **Discovered:** 2026-05-07 during `@profile` attribute implementation (test initially used `def add`/`def mul`, which triggered the rewrite; renamed to `addValues`/`mulValues` as workaround).

---

---

