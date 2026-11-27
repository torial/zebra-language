<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-816. Next new bug: BUG-817.** (BUG-804 reserved 2026-11-18 for Fable's V-route entry: an expression lambda with no declared return type passed to a `sig` parameter is emitted with no return type. BUG-805 WITHDRAWN as a duplicate of BUG-778: its shape is added there.)

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

### BUG-816: a type from a `use`d module that is not exposed, named bare, passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-26; found writing BUG-778 step 3 -- the compiler's own
  TypeChecker.zbr named `ExprOptChain`, which its `use Ast exposing ...` list does not hold, and the
  front end let it through to zig)
- **Repro:** `zzmod.zbr` declares `struct Pt` and `struct Other`; `use zzmod exposing Pt, mk` (or a
  plain `use zzmod`), then `def show(o: Other): int`. `-c` exits 0 and `zebra diagnostics` answers
  `[]`; a build fails inside zig, "use of undeclared identifier 'Other'", with a line and no column.
  A name declared NOWHERE is refused at the annotation ("unknown type 'Nope': not declared here, in a
  `use`d module, or as a type parameter in scope") -- the check counts any type a used module
  declares, exposed or not.
- **Fix shape:** at the annotation, refuse a bare type name that only a used module declares and
  this file does not take with `exposing`, naming the module and both fixes (add it to the
  `exposing` list, or qualify it if qualified type names are accepted there). Measure `-c` over the
  corpus first: a file that relies on the leniency today does not build, so nothing should move but
  fixtures -- but a GUI or generated-code path may name runtime types bare.
- **Control when fixing:** the repro refused at 3:13 by `-c` and `zebra diagnostics`; the same file
  with `exposing Pt, Other, mk` builds and runs; an undeclared name keeps its message.

---

### BUG-814: a throwing method reached through a type alias or an `extend` is not resolved
- **Status:** OPEN (filed 2026-11-26; found red-checking BUG-778 step 2b)
- **Repro (alias):** `class R` with `def risky(k: int): int throws`; `type RA = R`;
  `def viaAlias(r: RA, k: int): int` / `return r.risky(k)`. `-c` exits 0; zig: `expected
  type 'i64', found 'anyerror!i64'`, line only. With a method-level `catch` added, `-c`
  refuses it as "nothing in the body before this `catch` can fail ... drop the `catch`" --
  false, and following it gives the zig error.
- **Repro (extend):** `extend str` / `def firstLen(): int throws` (raises on empty), then
  `return s.firstLen()` in a plain function: the same zig error; under a method-level `catch`
  the same false refusal. `s.firstLen()?` works.
- **Cause:** neither codegen (genMemberCall's `isClassMethodThrows` on the receiver's class)
  nor the checker (TypeChecker resolveCallFail) resolves the callee: the receiver's type is
  the alias's name, or `str`. The two agree, so the BUG-778 tripwire stays quiet and the
  implicit-try refusal never fires.
- **Fix shape:** resolve an alias to its target and an `extend` method to its extension (the
  checker knows both) in ONE place both sides read -- resolveCallFail is the checker half --
  and route the call; then the alias / extend shapes join `test/bug778_cannot_fail_ok_test.zbr`,
  where they also become the attacker for its "unresolved never reads as cannot-fail" guard
  (today that guard is observable only in `zebra diagnostics`: mutated out, diagnostics
  printed the false "nothing can fail" on the alias repro; in place, nothing).
- **Control when fixing:** both repros refused unmarked by `-c`, `diagnostics` and
  `--target v` at the call with a column; with `?` or a method-level `catch` they build and
  the catch runs.

---

### BUG-813: a throwing method called through `?.` passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-26; found writing BUG-778 step 2b's BUG-764 counter)
- **Repro:** `class R` with `def risky(k: int): int throws`, then in a plain function
  `var v = r?.risky(k)` (`r: R?`). `-c` exits 0; zig: `expected type '?i64', found
  'anyerror!i64'` at the line, no column. Under a method-level `catch` the same call is not
  routed either, so that catch is refused as "nothing in the body before this `catch` can
  fail" (codegen counts label uses; the `?.` arm never takes the catch-break wrapper).
- **Not BUG-729:** that is a throwing call as the BASE of `?.` (`f()?.m()`); here the method
  reached through `?.` is the one that throws.
- **Open question (semantics):** what `x?.m()` means when `m` can fail. Proposal: as with any
  call that can fail, it needs handling -- `x?.m()` unmarked is refused ("throws call needs
  '?'"), the error propagates with `(x?.m())?`... except that form is already BUG-729's
  spelling for a throwing BASE. A simpler rule: refuse `?.` on a throwing method outright and
  ask for `if x != nil` + an ordinary call, which every consumer can check today.
- **Control when fixing:** the repro refused (or routed) by `-c`, `diagnostics` and
  `--target v` alike; a method-level `catch` around it either routes it or the refusal names
  the `?.` call, not "nothing can fail". The BUG-778 checker counts every `?.` call as "might
  fail" (TypeChecker checkCallsInExpr), so it never claims that catch on its own.

---

### BUG-812: a throwing call in a lambda inside a handled context passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-25; found writing BUG-778's accept fixture)
- **Repro:** a lambda built inside a method-level `catch` body, or inside the operand of a
  postfix `catch` / `?`, whose body calls a throwing function unmarked:
  `var r = apply(def(x: int): int = risky(x), 3) catch -1` with `risky(...): int throws`.
  `-c` exits 0 and `zebra diagnostics` answers `[]`; zig refuses: "expected type 'i64', found
  'anyerror!i64'" (the `catch` operand), "mutable '_try_err' not accessible from here" (a
  method-level `catch`, `var f = def(x: int): int = x + .bump()`).
- **Cause:** the lambda is emitted as its own function, but codegen's handled state
  (`try_block_label`, `in_try_expr`) is INHERITED into its body (`withLambdaReturnType` keeps
  both), so the call is neither routed nor refused. BUG-778's checker rule mirrors that
  inheritance on purpose (`call_handled` is not reset in a lambda) so the step changed no answer.
- **Fix shape:** reset `call_handled` on entering a lambda body (checker) and the two flags in
  `withLambdaReturnType` (codegen). The refusal there must not say "add '?'": a `?` in a lambda
  is refused too (BUG-767), so it reads "handle it inside the lambda (`catch` on the call)".
  Measure `-c` before and after over the five corpora: every newly refused file fails inside
  zig today.
- **Control when fixing:** both repros refused at the call by `-c`, `diagnostics` and `--target v`;
  `def(x: int): int = risky(x) catch 0` in the same positions builds and runs.
- **Exposure (Fable, 2026-11-26):** not met in the GameEngine as far as Fable recalls. No search
  was run. But the engine's emitted tree compiles under zig at its pin (37154b3), so the engine
  holds no live instance; a workaround written without a filing is possible and not recalled.
  The V route's output for the shape is untested (Fable will try it in zebra-vdev).

---

### BUG-810: `==` on interface values on the V route (BUG-788's V half)
- **Status:** OPEN (filed 2026-11-25; the Zig route landed as BUG-788; V route, Fable's to fix after
  his holiday, agreed in writing the same day)
- **Rule (Sean's decision, recorded with BUG-788):** `==` on two interface values compares concretely: the same concrete
  type, then that type's own rule (`cue equals`; identity for a class without one; fields for a
  struct); different concrete types are unequal. `contains` / `in` over a `List(Interface)`, an
  interface against a class value, and an optional interface on either side follow the same rule.
- **Control when fixing:** test/bug788_iface_eq_test.zbr built with `--target v` prints the seven
  lines the Zig route prints (`788 dog: TFT` ... `788 opt: TTTFF`).

---

### BUG-807: a user type named `T` breaks the V build
- **Status:** OPEN (filed 2026-11-18; found by Fable on the V route, reproduced by him on the
  compiler before his current change; V route, his to fix)
- **Repro:** `struct T` with a `Tag?` field and a `List(Tag)` field, built with `--target v`. The
  front end refuses nothing; the C that V generates is refused by tcc at
  `typedef struct __v_option_ptrTag { bool ok; ptrTag value; }`.
- **Suspected cause (not yet narrowed):** the user name `T` meets the runtime's generic
  parameter `T` in `zebra_rt.v`. Not yet reduced to a hand-written V file, so it may be V's own.
- **Fix shape:** if it is the name collision, the V emit prefixes or mangles a user type whose
  name a runtime generic parameter uses (as the Zig route's `_zbr_ty_` prefix does); if it is V's,
  refuse the name on the V route by name rather than handing tcc a broken file.
- **Control when fixing:** the same program with the type renamed (`U`) builds and runs; the
  repro then prints the same as the Zig route.

---

### BUG-702: `b.toInt()` on a byte from `s.bytes()` passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-12; found by Fable in Graze's percent-decoder, reproduced on the
  batch's compiler)
- **Repro:** `for b in "AB".bytes()` then `var n: int = b.toInt()`. `-c` exits 0; the build fails
  `error: expected float type, found 'u8'` -- the call is lowered as a float-to-int conversion.
- **Workaround:** `var n: int = b` (a byte widens to int), which Graze uses.
- **Fix shape:** the receiver's numeric kind decides the lowering: an integer receiver of any
  width is `@as(i64, b)`, never `@intFromFloat`.
- **Control when fixing:** the repro prints 65 and 66; `3.7.toInt()` keeps truncating.

---

### BUG-782: `@derive` is not read on the V route
- **Status:** OPEN, parts (a) and (b) RESOLVED (filed 2026-11-17; reported by Fable, who is fixing it
  on the V route; parts are closed one commit each as BUG-782a..d; the entry closes when all four are)
- **(a) RESOLVED 2026-11-17 (Fable, picked as 875253c):** the `hash()` that only `@derive(Hash)`
  writes is refused on V by name, naming the struct and the way out (a `cue hash(): int`); a
  struct with its own cue is written. Pinned by v-check's `hash` row.
- **(b) RESOLVED 2026-11-18 (Fable, with BUG-786):** `a.equals(b)` on a `@derive(Eq)` struct is
  the route's equality helper for the struct, field by field by the Zig runtime's rule (a List
  field by content, a class field by its `cue equals` or identity). Pinned by v-check's
  `eq_rule` row (the eq_derive program, seventeen lines written by hand).
- **Repro:** (a) `@derive(Hash)`'s `hash()` is emitted as a call to a method the struct does not
  have, and V refuses the file (test/bug776's and bug447_ok's fixtures); (b) `a.equals(b)` on a
  `@derive(Eq)` struct, the same (`a == b` works); (c) `@derive(Debug)` prints `P{x: 1, s: "a"}`
  on V and `P(x=1, s=a)` on Zig -- a silent difference; (d) a `HashMap(K, int)` keyed by a
  `@derive(Eq, Hash)` struct with a List field: Zig does not find an equal-content key built with
  a different list (as its `==` says), V does. All four are "nothing refused" on V today.
- **Fix direction (Fable):** (a) refused on V by name -- Wyhash is not ported, so the derived hash
  VALUE stays the Zig route's; (b)-(d) made to agree with the Zig route.
- **Control when fixing:** each part's program agrees on both routes or is refused on V by name.

---

### BUG-780: `g.text(s)` on libui_ng cuts the text at 511 bytes, silently
- **Status:** OPEN (filed 2026-11-17; reported by Fable porting the GameEngine's GUI client, whose
  33,000-character line showed its first 511 characters)
- **Repro:** an MVU `view` calling `g.text(s)` with `s` over 511 bytes, `--gui-backend=libui_ng`:
  the label shows the first 511 bytes and nothing says it was cut.
- **Cause:** `_lui_text` (selfhost/gui_libui_ng_section.zig ~1963) formats into
  `var _tb: [512]u8` through `_lui_z`. Old behaviour (the May 2026 runtime cut at 510); not a
  regression. Check `_lui_text_colored` and every other `[N]u8` + `_lui_z` site for the same cut,
  and whether a cut can land inside a UTF-8 sequence.
- **Fix shape:** allocate the zero-terminated copy at the text's length (or keep the buffer and
  fall back to an allocation past it); if a cap is kept on purpose, it is documented and the cut
  is marked (an ellipsis) rather than silent.
- **Control when fixing:** a 33,000-byte label shown whole (or visibly marked as cut); a short
  label unchanged. Only a human run proves rendering; a section test can prove the copy.

---

### BUG-779: a `Gui` method call with an argument missing passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-17; reported by Fable porting game/devtools.zbr; reproduced here
  on the stub backend at d283723)
- **Repro:** an MVU `view` with `g.beginHBox("x")` / `g.text("hi")` / `g.endHBox()` (QUICKSTART
  §30 documents `g.beginHBox("row", stretch: false)`). `-c` exits 0; the build fails inside zig,
  "member function expected 2 argument(s), found 1", against `pub fn beginHBox(self: GuiContext,
  id: []const u8, stretch: bool)` -- on the stub backend and on libui_ng.
- **Cause:** the checker knows Gui's method NAMES (`guiMethodKnown`, BUG-369; `'Gui' has no method
  'panel'`) but not their arity or argument types.
- **Fix shape:** derive each verb's parameter list from GuiContext's `pub fn` signatures (the
  table `gui_surface_drift.py` already reads and holds identical across the three regions) and
  check the count -- and the primitive argument types -- at the call, naming the documented
  form. Deriving it keeps the checker from being a fourth hand-kept copy of the surface.
- **Control when fixing:** the repro refused at its line naming `beginHBox(id, stretch)`; every
  GUI example and fixture unchanged (sweep `-c` over examples/, test/ and zebra-ide first).

---

### BUG-778: a refusal made in CodeGen reaches neither `--target v` nor `zebra diagnostics`
- **Status:** OPEN (filed 2026-11-17; found by Fable writing BUG-777, which runs the checker on the
  V route: eight files `-c` refuses are still written by `--target v`)
- **Repro:** the eight -- `bug467`, `bug728`, `bug729_nested` (a throws call needs `?`),
  `bug729_optchain`, `bug730`, `bug764`, `bug767`, `infer_guess_hatch`. Each is refused by
  `zebra -c` and `zebra file.zbr`; `--target v` writes the `.v` (after BUG-777 too), and
  `zebra diagnostics` -- the strict view the LSP shares -- answers `[]`, so the editor shows no
  error on a file that will not build.
- **A ninth (2026-11-18, Fable, filed as BUG-805 and folded in here):** `run(def(x) = x + 3)` with
  `def run(g: Fn): int` -- an untyped lambda parameter as an operand of `+`. `-c` refuses it ("cannot
  infer the type of `x`, an operand of `+`", rc 1) and `--target v` writes `fn (x) {...}` under
  "nothing refused". It is the `infer_guess_hatch` rule, at a lambda.
- **Cause:** those rules are checked in CodeGen.zbr at emit time (`-c` runs the Zig emit to see
  them), not in the checker, so a consumer that runs only the front end never sees them. BUG-764
  and BUG-767 (2026-11-17) were added there, which grew the set.
- **Fix shape:** move each rule into the checker (a rule there reaches all three consumers); do not
  copy CodeGen's rules into the V route. Measure each with `-c` before and after over test/,
  examples/, selfhost/, zebra-ide and the GameEngine.
- **Control when fixing:** each of the eight refused by `--target v` and listed by
  `zebra diagnostics` at the same line and column as `-c`; a clean file unchanged on all three.
- **The whole inventory, measured (2026-11-25):** `tools/refusal_parity_check.sh` (gate
  `refusal-parity`, QUICK) runs every must-reject fixture through all three consumers. Its
  run with the pre-change compiler found **23** gaps among 288 fixtures, not 8. After
  BUG-767's rule moved, **21** remain among the same 288 (the two lambda-`?` fixtures are refused by all three),
  baselined in `tools/refusal_parity_baseline.txt` (which only shrinks). Red-checked with
  the pre-change compiler as the attacker: both lambda-`?` fixtures NEW, a planted line for
  a fixture all three refuse reported CLOSED, rc 1:
  - **the throw rules** (implicit try, BUG-467/480/545/628/728/729, BUG-546/764's cannot-fail,
    BUG-730): all rest on CodeGen's "does this call throw" -- move that ONE predicate into the
    checker, not each rule;
  - **the inference-guess rules** (`infer_guess_*`, BUG-017's `len` names, BUG-758);
  - **module resolution, diagnostics only** (BUG-428, BUG-450, `subdir_stem_clash`): `-c`
    refuses an unresolved or case-wrong `use` and `--target v` does too, but `zebra
    diagnostics` (sideDepTypes) says nothing.
- **Done so far:** BUG-767's lambda `?` -- refused in the checker's shadowing walk, which now
  also visits a module var's initializer and a field default (the tripwire found both
  unwalked). CodeGen keeps its detection as a TRIPWIRE: reaching it prints "internal: the
  checker missed ... (BUG-778)", never a silent pass. Fixture
  `test/bug778_lambda_question_decl_test.zbr`.
- **Done, step 2a (2026-11-25): the unmarked throwing call** (BUG-467/480/545/628/728/729's
  nested half, `implicit_try_rejected`). The checker's call walk (`checkCallsInExpr`) asks
  `callMayFail`, which resolves the callee in codegen's order -- owner method, then (unless a
  local shadows it) this module's def, then an `exposing` import; `mod.f()`; `xs.pop()` on a
  List; a method of the receiver's inferred class or `Cls.m()` -- and answers through ONE
  predicate, `ClassTypes.methodFails` (declared `throws`, or `raise` / `?` in the body), with
  `bodyHasRaise` / `exprHasTry` moved from CgHelpers to AstWalk so both sides read one
  definition. "Handled" (`call_handled`) is set where codegen's `in_try_expr` /
  `try_block_label` are: the operand of `?`, the operand of a postfix `catch`, a method-level
  `catch` body, and the base of a `?.` (BUG-729's own refusal still answers there). A lambda
  INHERITS it, as codegen does -- that inheritance is BUG-812. The nine codegen sites are a
  tripwire now (main.zbr: "internal: the checker missed a throws call ... (BUG-778)").
  - **Measured:** `-c` over 3298 files (test/examples/selfhost, zebra-ide, the GameEngine),
    HEAD vs the change: only the seven fixtures' lines differ, each gaining a column (`9:` ->
    `9:5:`); 1910 accepted in both; 0 tripwire hits. Refusal parity 21 -> **14**: all seven
    close on BOTH consumers, BUG-728 included (diagnostics resolves the `exposing` import).
  - **Found on the way:** a `throws` method on THIS module's interface was never registered
    (`throws_methods` was filled from classes and structs; another module's interface was read
    from dep_types and worked). An unmarked call passed `-c` and failed inside zig, and the same
    call under a method-level `catch` was refused as "nothing can fail". Both fixed (codegen
    registers interface methods declared `throws`; the checker reads the interface's table).
  - BUG-628's fixture no longer prints its `26:21` cannot-fail line under `-c`: the checker's
    errors stop the build before codegen. The cannot-fail rule is step 2b (BUG-546/764).
  - Fixtures: `test/bug778_throws_resolution_ok_test.zbr` (the calls that must NOT be refused:
    a local named like the function, an interface without `throws`, `catch` / method-level
    `catch` routing, a `throws` interface method under a `catch`; red-checked with the
    local-shadow guard mutated out -> refused at 43:12), `test/bug778_iface_unmarked_test.zbr`.
- **Done, step 2b (2026-11-26): the cannot-fail family** (BUG-546's `catch` / `?` on a call
  that cannot fail; BUG-764's method-level `catch` over a body that cannot fail).
  `callMayFail` became ONE resolver, `resolveCallFail` -> `CallFail{known, fails, name}`, read
  by all three rules, so they cannot disagree about which function a call reaches. A
  "cannot fail" claim needs `name` (a resolved class/struct method, this module's def but not
  a `test_*`, an `exposing` or `mod.f()` def, `File.*`); owner dispatch, interfaces and
  anything unresolved make no claim. BUG-764: `checkCallsInExpr` counts every call short of
  "certainly cannot fail" (and every `x?.m(...)`, the one call that is not an `Expr.call`); a
  catch whose body leaves the count unchanged and has no `raise` / `?` is refused. Codegen's
  BUG-546 site is a tripwire; its BUG-764 site still refuses what the checker leaves to it.
  - **Measured:** `-c` over 3300 files, 90773c2 vs the change: 1915 accepted in both; ONE row
    differs -- bug628's fixture regains its `26:21` cannot-fail line (lost in step 2a); 0
    tripwire hits. Refusal parity 14 -> **12** (bug546, bug764 close on both consumers).
    A `catch` on a MIXIN method that cannot fail is now refused in Zebra's words (codegen
    scanned only the class's own members; it reached zig) -- no corpus file had one.
  - **Red-check, and its limit:** with the "unresolved counts as might-fail" guard mutated
    out, `-c` changed for nothing -- today every callee the checker cannot resolve is one
    codegen does not route either (BUG-813 `?.`, BUG-814 alias / `extend`), so both refuse
    the catch. The difference shows in `zebra diagnostics`: mutated, it printed the false
    "nothing can fail" on BUG-814's alias repro; in place, nothing. BUG-814's fix makes it an
    `-c` attacker.
  - Fixtures: `test/bug778_cannot_fail_ok_test.zbr` (bodies that must NOT be refused: owner
    dispatch, only a `raise`, List.pop, a generic class's method, a `throws` interface method,
    a body mixing safe and failing calls), `test/fail_fixtures/bug778_cannot_fail_fail.zbr`
    (mixin method, static method, a catch over a body of safe CALLS).
- **Done, step 3 (2026-11-26): throwing calls in value positions** (BUG-729's `f()?.m()` on a
  throwing `f`; BUG-730's throwing function passed as a value). `checkOptChainThrows` reads
  the same `resolveCallFail` as step 2; `checkFnValueThrows` refuses a throwing function in
  every function-typed slot codegen's `genSigValue` covered -- argument, var init,
  assignment, a list-literal element in a `List(Sig)` var, `List(Sig).add`, a method
  argument. A slot is function-typed when it is a `def(...)` type or a `sig`, optional or
  not; a name that resolves to a local or an owner-class method is a value, not the function.
  Both codegen sites are tripwires.
  - **Measured:** `-c` over 3302 files (this repo, zebra-ide, GameEngine), bed0466 vs the
    change: 1916 accepted in both, **0 rows differ**, 0 tripwire hits. Refusal parity 12 ->
    **10** (bug729, bug730 close). The new fixture's five refusals are at the same
    coordinates under HEAD's `-c`; HEAD's `zebra diagnostics` showed none of them.
  - **Red-check:** with both call sites mutated to `pass`, diagnostics on the fixture is `[]`
    and `-c` reaches codegen, where the tripwires print "internal: the checker missed".
  - **Found on the way:** BUG-816 (an unexposed type from a `use`d module, named bare, fails
    inside zig) -- the first draft named `ExprOptChain` in TypeChecker without it.
  - Fixtures: `test/bug778_throw_values_test.zbr` (method `?.`, cross-module `?.`, a list
    element, `List.add`, an assignment), `test/bug778_throw_values_ok_test.zbr` (safe
    functions in every slot, a parameter named like a throwing function, `?.` with `orelse`,
    `(f(...)?).m()`).

---

### BUG-775: an `extend str` method that does not use its receiver fails inside zig
- **Status:** OPEN (filed 2026-11-17; found writing BUG-773's `extend str` control)
- **Repro:** `extend str` / `def foo(): int` / `return 42`, then `print("a".foo())`. `-c` exits 0;
  zig: "unused function parameter" at `fn _ext_str_foo(self: []const u8) i64`.
- **Fix shape:** the extension's emitted function discards `self` (`_ = self;`) when the body
  does not reference the receiver, as a method that does not use `this` already does.
- **Control when fixing:** the repro prints 42; an extension that uses `.len()` is unchanged.
  Check `extend int` / `extend List(T)` for the same shape.

---

### BUG-774: `HashMap(float, V)` passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-17; found choosing BUG-773's receivers)
- **Repro:** `var m = HashMap(float, int)()` / `m[1.5] = 2`. `-c` exits 0; zig: "unable to hash
  type f64" in std/hash/auto_hash.zig. An empty map with no put compiles.
- **Fix shape:** refuse a float key type (and a Set(float) element) at the constructor and at an
  annotation, naming why -- the BUG-447 reasoning for `@derive(Hash)` on a float field (`0.0 ==
  -0.0` with different bits, `NaN != NaN`) -- and the fix (key on an int or str form).
- **Control when fixing:** the repro refused at its line; `HashMap(int, int)` unchanged.

---

### BUG-772: an unknown method after `?.` on a builtin receiver passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-17; found writing BUG-765's fixture, which first called
  `?.toUpper()`; reproduced on the pre-batch compiler and on the BUG-765 fix)
- **Repro:** `def name(n: int): str?` and `var u = name(1)?.bogus()`. `-c` exits 0; zig: "no field
  or member function named 'bogus' in 'str'". The same name on a plain `str` receiver is refused
  at `-c` ("'str' has no method 'bogus' (see QUICKSTART §14 ...)").
- **Fix shape:** the checker runs the receiver's method-name check (the `*MethodKnown`
  predicates, BUG-369) on the unwrapped type of an opt-chain call.
- **Control when fixing:** the repro refused at its line with the plain receiver's message;
  `name(1)?.upper()` unchanged.

---

### BUG-769: a `float32` receiver's methods are untyped by the checker; `-c` passes, zig refuses
- **Status:** OPEN (filed 2026-11-17; found by Fable while fixing BUG-768 on the V route.
  Zig route; mine.)
- **Repro:** `var n = sys.args().count()` / `var one: float32 = n.toFloat32()` /
  `var w = one.toFloat() * 2` / `print(w)`. `-c` exits 0; zig: "a.zbr:4: error: expected type
  'i64', found 'f64'". `print((one.toFloat() * 2).toFloat32())` fails the same way ("expected
  integer type, found 'f64'"). `${one.toFloat()}` alone in a hole works.
- **Where:** TypeChecker's member typing has an arm for `Type_.float_` (~5041) and none for
  `float_n`, so a sized float's `toFloat()` comes back unknown and the `* 2` is typed as int.
- **Fix shape:** the `float_` arm's methods for `float_n` too (or a shared predicate), with the
  receiver's own width where the method keeps it.
- **Control when fixing:** the repro prints 2.0 (or the arg count times 2); the same program
  with `var one: float` unchanged.

---

### BUG-770: a constant float expression folds at comptime_float precision, unlike the same sum at run time
- **Status:** OPEN (filed 2026-11-17; found by Fable comparing the routes. Zig route; mine.)
- **Repro:** `var a = 0.1` / `print(0.1 + 0.2)` / `print(a + 0.2)` / `print(0.1 + 0.2 == a + 0.2)`
  prints `0.3`, `0.30000000000000004`, `false`. Zig folds a literal-only expression as an
  arbitrary-precision `comptime_float` and rounds once at the end; the run-time sum rounds each
  operand to f64 first. The V route prints `0.30000000000000004` twice and `true` (C folds in
  double), so v_check cannot compare this shape until the routes agree.
- **Why it matters:** `float` is documented as f64, and a program's answer should not depend on
  whether an operand happened to be a literal. An `==` that is false between two spellings of
  one sum is the worst form of it.
- **Fix shape (to measure first):** type float literals as `f64` at an arithmetic operator
  (`@as(f64, 0.1) + 0.2`), so folding happens in f64. Needs an emit sweep and an output_sweep
  diff before landing: any baselined program printing a literal-only float expression moves.
- **Control when fixing:** the repro prints the same value twice and `true`; an int constant
  expression and a `const` float used as a comptime value unchanged.

---

### BUG-771: `var g: float32 = 16777217` passes `-c` and is refused by zig
- **Status:** OPEN (filed 2026-11-17; found by Fable. Zig route; mine. Minor.)
- **Repro:** `var g: float32 = 16777217`. `-c` exits 0; zig: "type 'f32' cannot represent
  integer value '16777217'", at the .zbr line. The words are good; the refusal is the back
  end's, so `-c` and the LSP do not see it.
- **Fix shape:** the front end refuses an int literal assigned to `float32` (or `float16`) that
  the float type cannot represent exactly, naming the nearest values; same check in a call
  argument and a return.
- **Control when fixing:** the repro refused at its line; `16777216` and `0.1` into a
  `float32` unchanged.

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
