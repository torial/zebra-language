# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-120. Next new bug: BUG-121.**

> BUG-029 and BUG-030 were resolved incidentally in the selfhost implementation — see `FixedBugs.md`.

Fixed / closed bugs have been moved to `FixedBugs.md`.

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
Migrated to FixedBugs.md.

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

### BUG-114: `0 - x` / `0.0 - x` instead of `-x` — ✅ SWEPT 2026-05-06
- **Severity:** N/A
- **Status:** Closed — sweep complete; no `0 - x` / `0.0 - x` occurrences remain in any `.zbr` file.
- **Source:** `STYLE_GUIDE.md` §13.3.

---

### BUG-115: Real `private` / `internal` visibility keywords (phase 13 language proposal)
- **Severity:** Low (open language design question, not a defect)
- **Status:** Open — phase 0.13 language proposal
- **Background:** Repo convention has used a leading `_` prefix on fields to signal "private" (e.g., `_radius`, `_items`). Verified 2026-05-04: this prefix has zero compiler-level enforcement — `f._hidden` from outside the class compiles and runs without complaint. The convention is purely social and misleads readers about what the language guarantees.
- **Decision needed:** Should Zebra add real visibility keywords (`private` / `internal` / `public`), or accept that the language has no field privacy and require the style guide to drop the `_` convention?
- **Style guide stance (2026-05-04):** Drop the `_` convention until/unless real keywords land. Compiler-emitted internals (`_allocator`, `_arena`, `_intern`, `_str_pool`, `_error_ctx`) are out of scope.
- **Cost sketch (if implementing):** parser arm for the visibility token; resolver enforces at member-access; codegen unaffected (Zig has no equivalent — emit `pub` / non-`pub` only). Scope of "internal" (module-private) needs design — Zig has it via `pub` boundary; Zebra would need an analogous module model.
- **Discovered:** 2026-05-04 during style guide drafting.
- **Source:** `STYLE_GUIDE.md` §1 Q3.

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
FixedBugs.md.

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

### BUG-100: ✅ FIXED (side-effect of BUG-099, 2026-05-05)
- **Symptom was:** `else => unreachable` panic when `for k, v in <non-var ident>`.
- **Fix:** The BUG-099 three-way Type split rewrote the surrounding TC block; the
  `is_hashmap_two_var` switch now uses `else => null` (line ~1321 current), so
  a method/class/namespace ident simply yields `hm_dt = null` and the loop falls
  through to normal for-in handling — no panic.
- **Verified 2026-05-05:** `for k, v in getMap()` + HashMap two-var smoke pass.

---

### BUG-101: AstBuilder uses `std.debug.panic` instead of diagnostics for parse-tree shape violations
- **Severity:** Low today (only the parser produces trees and it's well-tested) / Critical for VCS-merge-oracle future (operation-patches could synthesize trees)
- **Status:** Open
- **Symptom:** ~20 sites in `src/AstBuilder.zig` use `std.debug.panic` to assert parse-tree shapes (e.g., `:159, 551, 869, 896, 924, 941, 1086, 1589, 1650, 1908, 1928, 2052, 2131, 2169, 2277, 2430` — partial list). Failure mode is hard panic with terse message and no source span.
- **Reproducer:** None today from any well-formed source (they're invariant assertions). But under a future operation-patch VCS where structural edits synthesize trees, every site is a live hazard.
- **Root cause:** AstBuilder predates the Diagnostic infrastructure; these sites were the historical fail-fast paths.
- **Fix sketch:** Long-horizon refactor — fold each panic into the `Diagnostic` system with a "synthesized AST violated invariant X" error class, including the offending parse-tree NT. Short-term: leave alone but document the assumption that only the parser produces trees.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P0-2]).

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

### BUG-103: TC `extractFromDecls`/`extractFromMembers` silently skip unknown declaration variants
- **Severity:** Low (only triggers on adding a new `Ast.Decl` variant; latent reliability hazard)
- **Status:** Closed — fixed 2026-05-06
- **Resolution:** All 4 `else => {}` catch-alls in the metadata-collection passes replaced with fully exhaustive arms listing every `Ast.Decl` variant explicitly. Adding a new `Ast.Decl` variant now causes a Zig compile error at all 4 sites (same guarantee `checkTopDecl` already had). Behavioral change: none — all new arms are `{}`. Bootstrap 5/5, smoke 44/44, full test suite.
  - `extractFromDecls` (4 new arms: `.use`, `.interface`, `.mixin`, `.extend`, `.sig_`, `.var_`, `.init`)
  - `extractFromMembers` (10 new arms: everything except `.method`, `.var_`, `.init`)
  - `collectExtMethodsInDecls` inner switch (extend members: 12 new arms)
  - `collectExtMethodsInDecls` outer switch (top-level decls: 11 new arms)
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-1]).

---

### BUG-104: Unknown `@directive` silently ignored by AstBuilder
- **Severity:** Low (typical case is benign; impacts merge-oracle and forward-compat)
- **Status:** Closed — fixed 2026-05-06
- **Resolution:** `src/AstBuilder.zig` now emits `warning: unknown @-directive '@foo'; ignored` via `std.debug.print` to stderr when an unrecognized `@name` directive is encountered. `selfhost/parser.zbr` emits the same message via `sys.errln`. Compilation continues normally; only the unknown directive is ignored. Bootstrap 5/5, smoke 44/44.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-2]).

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

REMAINING (deferred): cast-validity check (line 1693 — `42 as ClassType`
still typechecks). Separate scope from literal homogeneity; tracked
within this entry but lower priority.

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

### BUG-107: TC halt-on-diagnostics audit — verify codegen never runs on a tree with diags present
- **Severity:** Medium (verification task; if the property doesn't hold today, this becomes High)
- **Status:** Open (verification needed)
- **Symptom:** `src/TypeChecker.zig` has only ONE `return error.X` site (line 3170, `error.ParseFailed`). The TC accumulates diagnostics into `tc.diags` and returns void; the halting story lives in `main.zig` (or wherever the TC is invoked from).
- **Verification needed:**
  1. Confirm `main.zig` checks `diags.items.len > 0` after typecheck and halts before codegen.
  2. Confirm any other call site (selfhost, REPL, IDE, future merge-oracle) does the same.
  3. If any path runs codegen on a diagnosed tree, that's an immediate elevation to High severity.
- **Fix sketch (if gap found):** Centralize the check — TC could expose `hasErrors()` and any consumer that proceeds without consulting it should be considered a bug.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-5]).

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

### BUG-093: ✅ FIXED 2026-05-05 — `s.len` now emits `@as(i64, @intCast(...))` — returns `int`
- **Severity:** Low (was forcing awkward workarounds; comparisons still worked)
- **Status:** Fixed:
  - `src/CodeGen.zig`: `isStringTypeName(n.name) and prop == "len"` path emits `@as(i64, @intCast(s.len))`.
  - `selfhost/codegen.zbr`: same `@as(i64, @intCast(...))` wrapper in the genMember string path.
  - Test: `test/bug093_strlen_test.zbr` (commit `dbd6fda`); added to `selfhost_smoke.sh`.
- **Original symptom:** `s.len` codegenned as `.len` on `[]const u8` (usize), causing `var n: int = s.len` and `s.len - 3` arithmetic to fail with type mismatch.
- **Discovered:** 2026-04-29 while writing `book_extract.zbr`.

---

### BUG-089: `print` of a mixin-method `str` return falls back to `{any}` byte-array formatting
- **Severity:** Low (cosmetic — wrong output format; does not affect type-annotated locals)
- **Status:** Open
- **Symptom:** Calling a mixin method that returns `str` directly inside `print` emits the bytes as a `[]const u8` integer-array fallback instead of as text.
- **Reproducer:**
  ```zebra
  mixin Greeter
      def hi(): str
          return "hi"

  class Foo adds Greeter
      cue init()
          pass

  class Main
      static
          def main
              var f = Foo()
              print f.hi()        # prints `{ 104, 105 }`, not `hi`
  ```
- **Generated Zig:** `std.debug.print("{any}\n", .{f.hi()});` — wrong format specifier; should be `"{s}\n"`.
- **Root cause:** TC inferExpr on a mixin-derived method call does not surface the declared return type, so the print-emission path in CodeGen sees `Type.unknown` and falls back to `{any}`.  Direct access via a typed local (`var s: str = f.hi(); print s`) emits `{s}` correctly — confirming this is a TC propagation gap on the call site, not a codegen format selector bug.
- **Workaround:** Assign to a `: str`-annotated local before printing.
- **Discovered:** 2026-04-28 while spot-verifying QUICKSTART.md examples.

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

### BUG-088: def-level `try/catch` in non-void return function falls off the end
- **Severity:** Medium (correctness — Zig refuses to compile the generated code)
- **Status:** Fixed
- **Symptom:** A method using the `def...catch` form (catch clause attached to the def itself, not a nested try/catch block) with a non-void return type fails to compile. The generated Zig has a `return` inside the success path, an unreachable `break`, then an `if (_try_err_1 != null) return ...;` afterwards — but no return on the path through both blocks where neither error occurred and the success block didn't already return. Zig errors with "function with non-void return type implicitly returns" + "unreachable code" at the orphan `break`.
- **Reproducer:** A `def f(): str` with `var v = try X()` followed by `return "ok"` and a `catch` clause returning `"err"` — see `test/bug088_try_return_test.zbr`.
- **Root cause:** `body_ends_in_break` in `genTryCatch` didn't handle `.return_` as a terminal statement; the orphan `break :_try_blk` was always emitted.
- **Fix:** `genTryCatch` now checks if the last stmt is `.return_`; if so, skips the `break :_try_blk` and emits `unreachable;` after the catch block. Both `src/CodeGen.zig` and `selfhost/codegen.zbr` updated. Also fixed `genBranch` to emit `=> |_| {` for `as _` discard on boxed union variants (was generating invalid `const _ = …`).
- **Discovered:** While writing `contract_result_throws_test.zbr` for the BUG-087 fix.

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

### BUG-027: Method chaining on struct temporaries requires manual intermediate vars
- **Severity:** Low (ergonomic / language design)
- **Status:** Fixed — expression-position call-arg chains now emit a labeled block `(blk_N: { var _mc_N = f(); break :blk_N _mc_N.method(args); })` in both Zig backend (`src/CodeGen.zig`) and selfhost (`selfhost/codegen.zbr`). Bootstrap 5/5. Throws sub-issue also fixed: `exprCallIsThrows` now handles call-expression receivers (looks up TC type, scans class/struct members); labeled block emits `break :blk_N try _mc_N.method(args)` when the chained method `throws`. Selfhost mirrors this via `inferExpr`+`isClassMethodThrows`.
- **Remaining sub-issue (deferred):** Expression-position chain `foo(f().throws_method())` inside a `try { }` block (`try_block_label != null`) — the labeled block emits the `try` prefix on `break`, but there is no catch redirect into the try-block's error variable. This path is rare (requires both a labeled try block and a throws chain in call-arg position) and not hit by current tests. Workaround: extract to a named variable before the call-arg site.
- **Symptom A (method-chain-on-temporary):** `display(makeBuilder(5).withVal(10))` fails: the struct temporary `makeBuilder(5)` becomes `*const Builder`, but `.withVal(10)` requires `*Builder`.
  **Fixed positions:** `var r = f().method()` (var-init), `return f().method()` (return), `x = f().method()` (assign) — hoisted via `hoistCallChain` in selfhost / statement-position fix in Zig backend. `foo(f().method(args))` (call-arg / expression) — now fixed via labeled block in both backends. `foo(f().throws_method())` — now emits `try` in both backends.
- **Symptom B (TC auto-deref annotation gap):** When a local variable is assigned from a `throws`-returning function via `?` propagation (`var x = foo()?`), the TypeChecker doesn't record the inferred type in `expr_types`. Downstream `^T` field accesses on `x` then silently omit the required `.*` deref because TC type is `.unknown`. Workaround: annotate explicitly — `var x as T = foo()?`. Fix tracked separately as BUG-077.
- **Root cause (A):** Zig temporary value semantics — caller's stack slot for a struct returned by value is `const`.
- **Root cause (B):** `inferCall` for `?`-propagated throws calls doesn't write back to `expr_types` for the receiving variable.

---

### BUG-079: Method chaining on struct-returning calls silently mis-compiles or is unnecessarily banned
- **Severity:** Medium (ergonomics + correctness; blocks natural call-chaining style)
- **Status:** Fixed — commits de0ec8e + 8c16fd9; auto-hoist in `genLocalVar`, `genReturn`, `genAssign` via `hoistCallChain`; expression-position (call args, compound expressions) remains open (BUG-027)
- **Target:** Pre-1.0 (ribbon ceremony blocker)
- **Symptom:** `f().method()` where `f()` returns a struct type is either silently mis-compiled or must be avoided by convention. The compiler does not enforce materialization; the hazard is invisible to the user until a runtime fault or a wrong-Zig-type error appears.
- **Example:**
  ```zebra
  # Broken — f() returns a struct temporary; .bar() has no stable address
  var result = makeWidget().label()

  # Required workaround
  var w = makeWidget()
  var result = w.label()
  ```
- **Root cause:** In the Zig codegen, a struct return value is a temporary on the Zig stack. Methods on Zebra classes/structs are emitted as `fn method(self: *T, ...)` — they require a pointer receiver. Calling `.method()` on a temporary is either rejected by the Zig compiler (`cannot take address of temporary`) or produces a dangling pointer if the optimizer moves the value.
- **Fix direction (two options):**
  1. **Compiler error:** In the TypeChecker or Resolver, detect `ExprCall` nodes whose callee is `ExprMember { object: ExprCall }` (chained call on a call result) and emit a hard error: `"method chaining on a struct return value is not allowed — assign to a variable first"`.
  2. **Auto-materialize:** In CodeGen, when emitting a method call whose object is itself a call expression, auto-insert a `const _tmp = <inner_call>; _tmp.method(...)` — transparent to the user but produces valid Zig.
- **Preferred fix:** Option 2 (auto-materialize) — better ergonomics, no user-visible restriction. Option 1 is faster to implement and safer as an interim gate.
- **Note:** This limitation is currently documented as a CLAUDE.md agent convention ("always materialize intermediates") rather than as a language/compiler constraint. That is the wrong layer — the language should either enforce or transparently handle it.

---

### BUG-083: `genGenericClass` skips `implements` conformance checks
- **Severity:** Low (conformance gap, not correctness gap — the class still compiles)
- **Status:** Fixed — `src/CodeGen.zig` and `selfhost/codegen.zbr` both emit `comptime { IFoo.check(@This()); }` in `genGenericClass`; `test/generic_iface_test.zbr` covers this; bootstrap 5/5.
- **Symptom:** A generic class declared `class Stack(T) implements IFoo` does not emit a `comptime { IFoo.check(@This()); }` block inside the generated Zig struct. The missing check means the compiler won't catch at compile time that `Stack(T)` is missing a required method — the error will only surface when a caller tries to use a `Stack(T)` value through the interface (if ever).
- **Root cause:** `genGenericClass` in both `src/CodeGen.zig` and `selfhost/codegen.zbr` handles `invariants` but has no `implements`/`ifaces` block. `genClass` delegates to `genGenericClass` early and never runs its own `implements` block. This was a pre-existing gap before interface vtable codegen was added.
- **Fix:** Added `implements.len > 0 → comptime { IFoo.check(@This()); }` block in `genGenericClass` (both backends), parallel to `genClass` and `genStruct`.

---

### BUG-084: Selfhost `Lexer.zbr` tracks `[`/`]` in `parenDepth`; Zig `Tokenizer.zig` does not
- **Severity:** Low — root divergence fixed; both backends now behave identically
- **Status:** Fixed — removed `[`/`]` and `@[` from `parenDepth` tracking in `selfhost/Lexer.zbr`; aligned with `src/Tokenizer.zig` (only `(`/`)` tracked); 26/26 smoke tests pass; bootstrap 5/5
- **Root cause:** Selfhost `Lexer.zbr` tracked both `[`/`]` and `(`/`)` in `parenDepth`. Zig `Tokenizer.zig` only tracks `(`/`)`. The divergence was accidental — the original selfhost port added `[`/`]` tracking without a design reason, and the `@[` emit path (added for array literals) was patched to compensate rather than root-cause fixed.
- **Fix:** Removed `parenDepth = parenDepth ± 1` from the `[`/`]` handling and the `@[` `scanAt` path in `selfhost/Lexer.zbr`. Both backends now only suppress EOL inside `(`...`)`. Multi-line `@[...]` is consistently unsupported in both backends (same behavior).

---

### BUG-085: `static def` methods — bare static field names incorrectly emit `self.field`
- **Severity:** Low (ergonomic; workaround available)
- **Status:** Fixed — `src/CodeGen.zig` and `selfhost/codegen.zbr` `genIdent`; `test/shared_var_test.zbr` updated to exercise the fix; bootstrap 5/5.
- **Symptom:** Inside a `static def` method, a bare field name (e.g. `count`) was treated by `genIdent`/`isFieldName` as an instance field and emitted as `self.count`. But static methods have no `self` parameter in the generated Zig — so the generated code was `self.count` in a `fn increment() void` with no `self`, causing a Zig compile error.
- **Root cause:** `genIdent` checked `in_method: bool` (set for both instance and static methods) and `isFieldName` returned true for any declared class field. There was no guard for the static case.
- **Fix:** Rather than adding an `in_static_method` flag (which would miss bare `static var` access from instance methods), the fix checks the field's own `static` modifier at the `genIdent` site:
  - **Zig backend:** After `if (sym.kind == .var_)`, added `if (sym.decl.var_.mods.static_) { emit owner.name; return; }`. Safe because `sym.kind == .var_` guarantees `sym.decl` is the `.var_` union variant.
  - **Selfhost:** Added `isStaticField(name: str): bool` helper (iterates `owner_members`, returns `fld.mods.is_static`). `genIdent` now calls `isStaticField` and emits `owner.name` instead of `self_name.name` for static fields.
- **Benefit:** Fixes bare `static var` access from BOTH static methods AND instance methods — strictly more correct than the `in_static_method` flag approach.
- **Files:** `src/CodeGen.zig` (`genIdent`), `selfhost/codegen.zbr` (`genIdent`, new `isStaticField`).

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

### BUG-119: Selfhost `isListField` fails for `List` fields accessed through function parameters
- **Severity:** Medium (codegen silently emits wrong Zig — `.len` instead of `.items.len`)
- **Status:** Open — proper fix deferred; workaround: add accessor method to the class
- **Symptom:** In a free function (not a class method) that receives a class instance as a parameter, accessing `.len` on a `List` field of that instance generates `state.diags.len` instead of `state.diags.items.len`. The generated Zig fails to compile because `std.ArrayList` has no `.len` field.
- **Reproducer:**
  ```zebra
  class IDEState
      var diags: List(IDEDiagnostic) = List(IDEDiagnostic)()

  def renderDiags(gc: Gui, state: IDEState, editor: CodeEditor)
      gc.text("Count: ${state.diags.len}")   # ← wrong: emits .len not .items.len
  ```
- **Root cause:** In `selfhost/codegen.zbr`, the `.len` property handler calls `isListField(fname)` which only inspects `owner_members` (the current class's declared fields). For free functions, `owner_members` is empty. The `isKnownListField(fname)` hardcoded fallback only covers compiler-internal field names (`args`, `params`, `stmts`, etc.) — "diags" is not in that list.
- **Proper fix:** Add a `list_field_names: HashMap(str, bool)` reverse index to `ModuleTypes` in `selfhost/typechecker.zbr`, populated by `addClassMembers` (parallel to the existing `hashmap_field_names` and `strset_field_names`). Add a `fieldIsList(mt, dep_mt, name)` helper (parallel to `fieldIsHashMap`). Call it in the `.len` handler in `codegen.zbr`. ~3 files, ~25 lines.
- **Workaround:** Add a helper method to the class that accesses the List field from within the method body, where `owner_members` is populated:
  ```zebra
  class IDEState
      var diags: List(IDEDiagnostic) = List(IDEDiagnostic)()
      def diagCount(): int
          return .diags.len   # inside the method, isListField("diags") works
  ```
  Then call `state.diagCount()` at the free-function call site.
- **Discovered:** 2026-05-06 while compiling `IDE/ZebraIDE.zbr`.

---

---

### BUG-120: Selfhost codegen `.add()` → `.append()` rewrite fires on class method calls via lowercase variables
- **Severity:** Medium (silent miscompile — method call becomes a list append; Zig rejects with "no field or member function named 'append'")
- **Status:** Fixed 2026-05-07 — see `FixedBugs.md`
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

*Last updated: 2026-05-07 — BUG-120 filed and fixed: selfhost .add() rewrite fires on user class methods via lowercase variables; fix uses InferCtx to detect class instances*
