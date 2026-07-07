# Zebra feature-validation audit — 2026-07-05

*Does each feature **documented in QUICKSTART.md** actually **work** in the
current compiler?* This is a validation audit — complementary to
`LANGUAGE_DESIGN_AUDIT.md` (design critique) and `API_FREEZE_AUDIT.md` (stdlib
regret). It directly serves `ROADMAP_TO_1.0.md`'s "prove what exists" and feeds
`BOOK_PLAN.md`'s 🔴-stale tracking.

**Method:** every documented form was probed with a minimal LF-only `.zbr` →
`zebra-bootstrap.exe --emit-zig` → `zig run`. Three agents swept §1–13, §14–25,
§28+§31; the highest-impact findings were re-verified by hand (marked ✅VERIFIED).
Failures were cross-checked on both compilers where noted. Probes distinguished
agent syntax errors from real gaps.

**Headline:** the language is broadly solid — the large majority of documented
features PASS. But **several of QUICKSTART's own examples do not compile
verbatim**, which is the most user-visible problem (a newcomer copy-pasting hits
an error immediately). Findings split cleanly into four causes: doc errors,
codegen bugs, Zig-0.16 toolchain drift, and bootstrap-lags-selfhost.

---

## A. QUICKSTART examples that are broken *verbatim* (highest priority)

These make the docs actively misleading — fix the doc and/or the compiler.

| # | §  | Example | Cause | Fix |
|---|----|---------|-------|-----|
| A1 | §10 | `var has = items.any(...)`, `var has = m.contains(...)` | ✅VERIFIED **`has` is a reserved word** — the doc's own variable name won't parse | doc: rename the var; OR unreserve `has` outside `guard` |
| A2 | §13 | `var x = if c: a else: b` (colon-form expression-`if`, ~15 lines of §13) | ✅VERIFIED **not implemented** — parser wants `(` after `if`; only the ternary call-form `if(c,a,b)` works as an expression | doc: mark colon-form as statement-only + point to `if(c,a,b)`; OR implement it |
| A3 | §9 | exhaustive union `branch` with `on <all variants>` **and** `else / pass` | codegen emits an `else` prong on an already-exhaustive Zig switch → "unreachable else prong" | codegen: omit the emitted `else` when all variants are covered; OR doc: drop `else` from the exhaustive example |
| A4 | §19 | expression lambda `(x: int) -> x*2` | **doc wrong** — the real form is `def(x: int) = expr`; the arrow form is a syntax error | doc: fix line 1316 |
| A5 | §22 | `struct Node`/`struct TreeNode` with `^T` fields | struct `^T` field mutation emits broken deref-assign + "never mutated"; works only with `class` (corpus uses `class`) | doc: use `class` in the `^T` examples |
| A6 | §22 | union `add(left: ^Expr, right: ^Expr)` (multi-field named payload) | contradicts §9's single-`name: T` payload syntax; doesn't parse | doc: use a §9-valid single-`^T` payload |
| A7 | §25 | Tier-1 `Reflect.className`/`fieldNames` on `var u = User()` | `u` used only in comptime-resolved reflect calls → Zig "unused local constant" | doc: reference `u` elsewhere; OR codegen: suppress the discard |
| A8 | §31 | `re.test(s)` | ✅VERIFIED **`test` is a reserved keyword** → `re.test()` unparseable | rename the method (e.g. `re.matches`) or unreserve `test` in method position |

---

## B. Genuine codegen / language gaps (feature broken on both compilers)

| # | §  | Feature | Symptom |
|---|----|---------|---------|
| B1 | §10/§13 | **indexed for-in** `for i, v in items` (List) | ✅VERIFIED emits `.iterator()` on an ArrayList → "no member function named 'iterator'". Common idiom; `for v in items` + manual counter is the workaround |
| B2 | §10 | **`map`/`filter`/`reduce` on a list-LITERAL var** `var xs = [1,2,3]; xs.map(def(x)=x*2)` | ✅VERIFIED lambda param types as `void` → "arithmetic requires numeric". `listElemTypeOfReceiver` handles `List(T)()` + annotations but NOT `[...]`-init. (Works fine on `List(int)()`-init.) **Small fix — extend the helper.** |
| B3 | §23 | **`zig"…"` referencing parameters** | codegen emits `_ = ptr;` param-discards *before* the inline Zig that uses them → "pointless discard of function parameter" |
| B4 | §19.1 | **mutating `capture` closure** (`count += 1`) — the headline use case | closure var emitted `const` but `.call` takes `*@This()` → const-qualifier error. Read-only captures work |
| B5 | §16 | **interface `is Iface` runtime check** (`if obj is Printable`) | emits undeclared `_ttag_Printable` / "undefined name". Compile-time `implements` works |
| B6 | §5 | **`@once` on a class WITH instance fields** | hidden `_once_*` field emitted *after* methods → Zig "declarations not allowed between container fields". Works only field-less |
| B7 | §5 | **`static var` before an instance field** | emits `pub var` between struct fields → same container error. Order-sensitive (instance fields first works) |
| B8 | §15 | **cross-module non-mutating struct method on a `const` binding** | emits `self: *Vec2` (mutable) → "cast discards const qualifier". Single-file structs correctly emit `*const` |
| B9 | §21 | **`is Union.Variant as n` on an OPTIONAL union** | emits `maybe == .dog` on `?Animal` → error. Non-optional variant checks + optional class checks work |
| B10 | §8 | **backed enum** `enum Status(int)` | ✅VERIFIED (via agent) parse error; plain enums work |
| B11 | §13 | **`while` bind-and-guard** `while x = f() != nil` | parse error; neither `while x = …` nor `while var x = …` parse |
| B12 | §6 | **inline / comma `except`** `this except a = 5, b = 6` | only the block form parses; prose implies inline/comma is valid |

---

## C. Zig-0.16 toolchain drift (emitted runtime uses removed/changed std APIs)

This is the known class: smoke/round-trip/fuzz don't compile-check the emitted
*user* Zig, so these stayed latent. They fail at `zig run`, not emit.

| # | Call | Zig-0.16 breakage |
|---|------|-------------------|
| C1 | `sys.args()` | `std.process.argsAlloc` removed |
| C2 | `File.append(path, data)` | no `seekFromEnd` on `Io.File` |
| C3 | `File.rename(src, dst)` | arity change (expects 4 args, emit passes 3) |
| C4 | `File.modtime(path)` | works but returns `?int`, while §31 documents `int` (−1 if missing) — a **signature mismatch** |

---

## D. Bootstrap (`src/`) lags the self-hosted `zebra.exe`

Reverses the usual "bootstrap is authority" assumption — these work on
`zebra.exe` but fail on `zebra-bootstrap.exe`:

| # | Feature | Note |
|---|---------|------|
| D1 | mixin `adds Mixin` | bootstrap emits mixin method between struct fields; `zebra.exe` is correct |
| D2 | generic functions `def f(T)(x:T):T` | bootstrap syntax-errors; `zebra.exe`/`zebra-selfhost` work. (§17 only documents generic *classes*, which pass everywhere.) |

---

## E. Undocumented-but-working / missing surfaces

- `sys.cwd()` works but is absent from the §31 `sys` table.
- `Math.gcd` works but is absent from the §31 `Math` table.
- No `String.*` static namespace exists (`String.fromInt` → undeclared) — not
  documented either, so "absent" not "broken", but worth a decision pre-freeze.
- `allocate Debug()` (documented for leak detection) reports *every* heap
  allocation as leaked, because the arena model never frees individual values —
  the documented use case is effectively unusable.
- `${n:08x}` on a `comptime_int` literal fails (`@bitCast from comptime_int`);
  works on a runtime int. Minor, but the doc example uses a literal.

---

## Recommended triage

**Cheap doc fixes (make QUICKSTART compile verbatim), zero code risk:** A1, A4,
A5, A6, A7 — rename `has`, fix the arrow-lambda line, use `class`/§9-union in the
`^T` examples, adjust the Reflect example. Plus C4/§31 (`File.modtime` returns
`?int`), the `sys.cwd`/`Math.gcd` table omissions.

**Small, safe compiler fixes:** B2 (extend `listElemTypeOfReceiver` to
list-literal init — direct follow-on to the §28f trio), A3/B-adjacent
(exhaustive-`branch` `else` suppression).

**Bigger / needs judgment (Sean):** A2/expr-`if` (implement vs document-away),
B1 indexed for-in, B3 `zig"…"` params, B4 mutating capture, B5 interface `is`,
B6/B7 field-ordering, B10 backed enums, B11 while-bind — each a real feature
users will reach for. And the C-class Zig-0.16 drift (a compile-check-the-emitted
-Zig gate would have caught all four — worth adding).

**Cross-compiler:** D1/D2 are places `src/` regressed behind the selfhost —
worth reconciling before 1.0 since `src/` is nominally the trusted reference.

---

## Resolution — applied 2026-07-05

### Fixed (mechanical: doc / bad-practice / toolchain-drift)

**Doc corrections** (each re-verified to compile):
- A1 `has` → renamed the example variables (`found`/`present`); noted `has` is a keyword.
- A2 expression-`if` → §13 rewritten to use the ternary `if(cond, a, b)`; the
  colon-form is marked statement-only.
- A4 arrow-lambda → `def(x: int) = expr`.
- A6 union `^T` → single-payload unary `neg: ^Expr` example (multi-field payload
  never parsed; unions are single-payload).
- A7 Reflect Tier-1 → the example now references the instance (was an unused local).
- A8 `re.test` → removed (unimplemented AND `test` is a keyword); doc points to
  `re.find(s) != ""` for match-anywhere.
- §31: `File.modtime` corrected to `int?`; `Math.gcd`/`lcm` and `sys.cwd` added
  (worked but were undocumented).

**Toolchain-drift compiler fixes (Zig 0.16, emitted runtime):**
- C1 `sys.args()` → `_args.toSlice(_allocator)` (argsAlloc removed). Both compilers.
- C2 `File.append` → new `_file_append` preamble helper (read+concat+write, since
  `File.seekFromEnd` is gone). Both compilers. Also fixed a *pre-existing* selfhost
  dispatch bug: the StringBuilder `.append` handler had no receiver guard and was
  intercepting `File.append` → emitting `File.appendSlice`; guarded it.
- C3 `File.rename` → Zig 0.16 sig `rename(old, cwd(), new, io)` (bootstrap; the
  selfhost has no `File.rename` handler at all — see below).

**Code fix:** B2 — `map`/`filter`/`reduce` on a list-literal-initialized var.

### Left for tactical resolution (real feature / design / codegen work)

**Codegen / parser gaps:**
- A3 ✅ FIXED (2026-07-06) — exhaustive union `branch` + `else`: both compilers
  now omit the emitted `else` prong when all variants are covered
  (`branchCoversAllVariants` via the union variant registry).
  Fixture `test/branch_exhaustive_else_test.zbr`.
- A5 struct-`^T` field mutation emits broken deref-assign — now tracked as
  **BUG-170** (selfhost-only; bootstrap boxes correctly).
- B1 ✅ FIXED (2026-07-06) — indexed `for i, v in list` now emits indexed
  iteration (`for (list.items, 0..) |v, _zbr_i|`; i = index int, v = element) on
  both compilers.  Fixture `test/for_indexed_test.zbr`.
- B3 `zig"…"` referencing params → param-discards emitted before the inline Zig.
- B4 mutating `capture` closure → closure self emitted `const`.
- B5 interface `is Iface` runtime check → undeclared `_ttag_Iface`.
- B6 `@once` on a class with instance fields; B7 `static var` before an instance
  field → hidden/static decl emitted between struct fields (Zig container error).
- B8 cross-module non-mutating struct method on a `const` binding → `self: *T`.
- B9 ✅ FIXED (2026-07-06) — `is Union.Variant as n` on an OPTIONAL union now
  unwraps first (`x != null and x.? == .v`, payload via `.?`) and the TC narrows
  the binding through the optional (str payloads print correctly).  Both
  compilers.  Fixture `test/optional_union_is_test.zbr`.
- B10 backed enum `enum Status(int)` (parser — not implemented).
- B11 `while` bind-and-guard `while x = f() != nil` (parser — not implemented).
- B12 inline / comma `except` (only the block form parses; prose implies comma).
- ✅ RESOLVED (2026-07-05) — `^ClassName` is now a real compile error in both
  compilers ("a class is already a reference; drop the '^'"), making the §22 doc
  claim true.  See BUG-078.

**Bootstrap-vs-selfhost divergences (D-class — `src/` is nominally authority):**
- D1 ✅ FIXED (2026-07-05) — mixin `adds` method-return typing on the call path
  (bootstrap now matches `zebra.exe`).
- D2 generic functions `def f(T)(x:T):T` — works on `zebra.exe`, fails on
  bootstrap.  **Deferred** (large feature port to the phasing-out compiler); see
  NEXT_STEPS "Bootstrap lacks generic *functions*".
- **File.read + print** — bootstrap prints the string (`abc`), selfhost prints the
  byte array (`{ 97, 98, 99 }`). A *silent output divergence* — the selfhost types
  `File.read`'s result differently. Pre-existing; surfaced when the File.append fix
  let such programs compile. Worth prioritizing (silent, not a crash).
- `File.rename` — bootstrap only; the selfhost has no handler.

**Design / other:**
- `allocate Debug()` reports every heap allocation as leaked (the arena never frees
  individual values) — the documented leak-detection use case is unusable as-is.
- No `String.*` static namespace exists — decide before the API freeze.
- `${n:08x}` on a `comptime_int` literal fails (`@bitCast from comptime_int`).
