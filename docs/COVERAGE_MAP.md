# Language-feature coverage & the risk surface

*Where the QA net has holes. Started 2026-07-12. This is the map of which language
constructs are actually exercised by which verification layer — and, more usefully,
which are **not**, because that is where the next undiscovered bug lives.*

Companions: [`QA_TOOLS.md`](QA_TOOLS.md) (the tools that produce this coverage),
[`FEATURE_AUDIT_2026-07-05.md`](FEATURE_AUDIT_2026-07-05.md) (constructs known to be
*broken* — this doc is about constructs that are *unwatched*), [`../fuzz/README.md`](../fuzz/README.md).

---

## The thesis (and why it matters)

A construct is well-defended when it's tested in **combination** with others, not
just in isolation. The four coverage sources, from weakest to strongest signal:

1. **Used by the compiler itself** — the selfhost sources are a large real program;
   if `Parser.zbr` uses a construct, it's exercised. But only in *the shapes the
   compiler happens to use*.
2. **A hand-written `test/` fixture** — exercises a construct deliberately, but only
   in *the shape the author thought of*.
3. **Round-trip** (`bootstrap_check.sh`) — strong, but only on the compiler's own
   source shapes.
4. **The fuzzer** (`fuzz/run.py`) — the only source that **randomly combines**
   constructs, so it finds interactions nobody wrote a test for. **But it only
   combines the constructs inside its `DEFAULT_CAPS`.**

**The blind spot is combinatorial.** `BUG-172` is the canonical example: `char`
literals *have* tests (`char_literal_test`, `char_tostring_test`, `bug116_char_
methods_test`), and `List(T)` generics are fuzzed — but `List(char)` as a
*constructor argument* is a combination that no test wrote, the fuzzer doesn't
generate (char isn't in its caps), and the compiler itself never uses (it reaches
for string slicing). So it sat undetected until the LSP work tripped over it. Every
red cell below is a potential `BUG-172`.

---

## Legend

- **Fuzzed** — inside the fuzzer's `DEFAULT_CAPS` (randomly generated + combined).
- **Tests** — count of dedicated `test/*.zbr` fixtures (rough grep; combination
  coverage varies).
- **Self-use** — number of `selfhost/*.zbr` compiler files that use it.
- **Risk** — 🟢 low (fuzzed) · 🟡 medium (well-tested/used but only in fixed shapes)
  · 🔴 high (thin/no test, not fuzzed, little compiler use).

---

## The matrix

### Fuzzed — randomly combined (🟢 low risk)
These get the strong treatment: random generation, random combination, differential
+ run oracle across bootstrap and selfhost.

| Cluster | Notes |
|---|---|
| int/float/bool locals + arithmetic | `DEFAULT_CAPS` core |
| comparisons, `if`/`else`, bounded `while` | |
| `print` + basic string interpolation | |
| functions (read-only params) | params are read-only in the generator |
| optionals: `T?`, `nil`, `if x as y`, `orelse` | |
| `List(T)`: construct, `.add`, `.len`, for-in | but **not** `List(char)` (see 🔴) |
| structs (fields, `cue init`, field r/w) | |
| classes (fields, methods, `*self`/`*const self`, dispatch) | |
| enums (`E.variant`, branch) | bare enums only — **not** backed `enum E(int)` |
| unions (payload variants, `branch ... on U.v as p`) | |
| ternary `if(c,a,b)` · ranges `a:b[:s]` / `a..b` · `throws` + `?` + `catch` | past fuzzer finds (F8/F9/§28b) — now covered |

### Tested + compiler-used, but NOT fuzzed (🟡 medium — isolated coverage only)
Solid hand-test + self-use coverage, so the common shapes are safe — but nobody is
randomly combining them with each other or with the fuzzed set. Interaction bugs
(the `BUG-172` shape) can hide here.

| Cluster | Tests | Self-use | Note |
|---|---|---|---|
| HashMap | 22 | 10 | heavy tests (collisions, entries, fetch-chain); bug-prone historically (bug094, dispatch collisions) |
| interfaces + `is Iface` runtime check | 16–19 | 5–10 | `is`-RTTI was a recent gap (audit B5) — under-tested until fixed |
| `^T` heap boxing | 14 | 12 | audit A5/B4, BUG-170 all lived here; still not fuzzed |
| closures / `capture` | 20 | 10 | mutating-capture was audit B4 |
| mixins | 6 | 4 | bootstrap-lag D1 |
| `guard` · `using`-scope-blocks | 7 / 4 | 4 / 6 | |
| Chan / Atomic / ThreadPool | 2 / 4 / 2 | 3 / 2 / 2 | concurrency — hard to fuzz deterministically |
| Reflect · `@once` · `@derive` · generics (fn + class) | 3 / 2 / — / many | 2 / 2 | generics well-tested; `@once` order-sensitive (audit B6) |
| contracts (require/ensure/invariant) · namespaces · cross-module · except · regex · SIMD · DynLib | several each | varies | broad hand-test coverage, zero fuzz |

### Thin or no dedicated test, NOT fuzzed (🔴 high — the risk surface)

| Cluster | Tests | Self-use | Why it's exposed |
|---|---|---|---|
| ~~**`char` in generic position**~~ | ✅ FIXED | — | **BUG-172 — now fixed (2026-07-12).** char/uint as a generic arg (`List(char)`) was rejected by the selfhost resolver (`isBuiltin` gap); added them. Regression test `test/bug172_list_char_test.zbr`. Was the exemplar of this whole doc — investigating the 🔴 cell produced a real fix. |
| sized numerics as a generic arg (`List(int32)`) | 0 | 0 | discovered fixing BUG-172: non-keyword primitives fail at the **parser** in type-arg position. Low priority; noted in BUGS.md |
| chained comparisons `a < b < c` | 1 | 4 | one fixture; a real precedence-sensitive feature (fuzz F7 was precedence) |
| refinement types `type B(lo,hi)=int where` | 1 | 1 | thin; parametric-alias codegen is intricate |
| tuples / destructuring | 1 | 0 | thin; not used by the compiler |
| `with` (contextual self) | 3 | 0 | not used by the compiler |
| type aliases (constraint) | 3 | 0 | transparent-emit; not self-used |
| backed enums `enum Status(int)` | 1 (`backed_enum_test`) | 0 | audit B10 was a parse error; fuzzer generates bare enums only |

> Method note: counts are quick greps, not an exhaustive per-production audit — a
> cluster with "1 test" may still be well-covered inside that fixture, and a
> `selfhost` count of 0 doesn't mean unused by *user* corpus. Treat 🔴 as "look here
> first," not "definitely broken." Refine as constructs get pulled into the fuzzer.
>
> Reclassified 2026-07-12: **`StrSet`** was flagged 🔴 ("zero tests") but turned out
> to be **compiler-internal** — it's not in QUICKSTART, and `StrSet()` construction
> is rejected by **both** compilers' resolvers (a deliberate-looking gate, not a
> divergence). So its lack of a user-facing test is expected; dropped from the risk
> surface. Investigating it still paid off — it confirmed the same `isBuiltin` root
> cause as BUG-172.

### Fuzzer-coverage progress (2026-07-12) — three clusters moved 🟡/🔴 → 🟢

Now randomly combined by `fuzz/gen.py` (`DEFAULT_CAPS`):
- **`char` as a `List(char)` element** — was the 🔴 BUG-172 exemplar; fixed + fuzzed.
- **HashMap(K,V)** — construct / set / `get orelse` / len / entries for-in.
- **string methods** (clean subset) — upper/lower/trim\*/replace/contains/startsWith/len.

What growing them found (the thesis, repeatedly): the char cap exposed **BUG-173**
(a latent selfhost string-coercion divergence), and hand-testing the string surface
exposed **BUG-174** (`str.indexOf` int? vs int/-1 signature divergence). HashMap and
the string subset are equivalence-clean (only shared `both-zig-fail` robustness gaps,
no divergence). Still 🔴/🟡 and not yet fuzzed: **`^T` boxing, interfaces+`is`,
generics/backed-enums/chained-cmp** — higher-complexity generation (class
relationships); the next targets. (Generic *functions* are intentionally
selfhost-only per audit D2 — not an equivalence surface.)

---

## Recommendations (highest-leverage first)

**1. Grow the fuzzer's `DEFAULT_CAPS` — this is the multiplier.** Every construct
moved from 🟡/🔴 into the fuzzer stops being "tested in the shapes we thought of" and
starts being *randomly combined*. Prioritize by bug-history × usage (these have had
bugs precisely *because* they were only isolated-tested):

| Priority | Add to fuzzer | Rationale |
|---|---|---|
| 1 | **`char` literals + as `List`/container element** | directly closes the BUG-172 class; cheapest high-value add |
| 2 | **string methods** (`.chars`, `.split`, `.replace`, slicing) | bug-dense (bug092/093/116/117); the LSP work leaned on these |
| 3 | **HashMap** (construct, set/get, entries, for-in) | historically bug-prone; big surface |
| 4 | **`^T` heap boxing** (fields + optional `^T?`) | audit A5/B4/BUG-170; never randomly combined |
| 5 | **interfaces + `is Iface`** | audit B5 shape; RTTI is new |
| 6 | generics (fn + class) · backed enums · chained comparisons | rounds out the type surface |

Each addition follows the fuzzer's existing pattern (a `DEFAULT_CAPS` flag + a
type-aware generator branch that only emits well-typed uses) — see how `structs`/
`unions`/`throws` were added. Add one, run `--n 200 --run`, triage new buckets.

**2. ✅ `BUG-172` fixed (2026-07-12)** — `char`/`uint` as a generic arg were
rejected by the selfhost resolver (`isBuiltin` gap). This was the exemplar for the
whole thesis: the 🔴 cell held a real, fixable bug. Follow-on gap noted: sized
numerics (`int32`, …) as a generic arg fail at the parser (BUGS.md).

**4. Keep this map + the audit as living docs.** When a construct enters the
fuzzer, move it to 🟢 here. When a 🔴 gets a real test, update the count. Pair with
`FEATURE_AUDIT_2026-07-05.md` (known-broken) — this doc is known-*unwatched*; the
overlap between them (a construct that's both broken *and* unwatched) is the
top-priority fix.

---

## Why keep the bootstrap even after it stops shipping

The differential fuzzer and `parity_check` both depend on having **two independent
compilers** to disagree. Per the direction memo, the Zig bootstrap is being phased
out of *shipping* — but it should be retained as a **test-only differential oracle**.
The day there's only one compiler, `run.py`'s entire "A vs B" premise (and the
byte-identical round-trip's meaning) collapses to "the compiler agrees with itself,"
which catches far less. The bootstrap's long-term job is to be the second opinion.
