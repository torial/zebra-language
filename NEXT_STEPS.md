# Zebra — Next Steps

Authoritative priority queue for the project. Update this file rather than regenerating the list from scratch each session.

**Last updated:** 2026-05-05 (Phase 13 sweeps #1+#2 complete; BUG-111/112/113 closed; §19 selfhost TC diags Phase 1 shipped; BUG-099 split shipped; §19.5b typecheck-merge subcommand shipped — oracle-prep cluster COMPLETE)

> **Milestone cumulative semantics:** each milestone listed below is
> *additive*.  A feature labeled for 0.14 lands at 0.14 and is then
> part of the **1.0 stability commitment** — 1.0 includes everything
> delivered from 0.1 through 0.14.  Same rule for 2.0 (kernel track =
> 1.0 + the 2.0 additions).  When evaluating "what blocks 1.0," the
> answer is everything labeled for any 0.x milestone that isn't yet
> shipped + stable, not just the items in §15.  See
> `wiki/pages/projects/project_zebra.md` milestone table for the
> authoritative version-by-version breakdown.

---

## Immediate (Near-Term Compiler Work)

### 1. Open compiler bugs

**BUG-026** — `instance_method_return_types` gaps for exposed-type method chains  
Not manifesting in practice — `scanMutationsInExpr` conservatively marks cross-module calls as mutated.  
Defer unless a concrete failing case is found.

**BUG-014** — Regex lazy match is global, not per-quantifier  
`<.*?>STUFF.*>` misbehaves; `lazy_match` is a whole-regex flag.
Architectural fix: priority-first NFA simulation or backtracking engine.
File: `src/CodeGen.zig` NFA preamble. Effort: L

**BUG-099 cluster (TC reliability keystone)** — see §19.5a below.

**BUG-109 / BUG-110** — `Http.serve` `.reuse_address` policy + bind-error
panic instead of throws. See `BUGS.md`.

**Phase 13 cluster (style-guide–driven sweep targets, BUG-111..115)** —
all queued for the 0.13 syntax-cleanup window. See §12 below for the
syntax-cleanup roster.

---

## Medium Term (Milestone Features)

### 6. REPL (Milestone 0.6)
Two-phase approach: warm-up pre-compiled preamble once → per-input incremental compile.
"Accumulate and rerun" state model (all previous cells stay in scope).
See design notes in `selfhost/` journal and `SELFHOST_JOURNAL.md`.

### 7. Regex per-quantifier lazy/greedy (Milestone 0.7)
Unblocked by BUG-014 fix. Mixed lazy/greedy patterns (`<.*?>STUFF.*>`) require the NFA
to track per-node shortest/longest flags, not a global flag.

### 9. Greek NT n-gram port — **deferred until 0.11 (SIMD)** lands
An earlier port exists from a much earlier Zebra version and is no longer idiomatic.
The update is held until SIMD types arrive so the rewrite uses `f32x8` / dot-product
primitives from the start rather than being ported twice.

The TF-IDF / cosine-similarity follow-on (and any LynseDB-shaped embedding fuzzy match)
are the real beneficiaries of SIMD here. See the "Fuzzy Match and Text Analytics
Use Cases" table in `concept_zebra-simd-design.md`.

Original scope: file I/O, `HashMap` with Unicode keys, sort, sliding n-gram window —
all available now, but the rewrite would land twice if done before 0.11.

### 10. Plugin system — DynLib demo (after `interface` codegen)
Round-trip: a toy "Hello" plugin DLL loaded by a host program via `std.DynLib`.
Depends on `interface` codegen (step 4 above) and a thin `DynLib` stdlib wrapper.
See: `wiki/pages/concepts/concept_zebra-plugin-system.md`

### 11. Contracts: `ensure` / `old` / `--turbo` / `result` — ✅ COMPLETE
All four phases shipped 2026-04-24 to 2026-04-27. Bootstrap 5/5; 40/40 smoke.
Both backends parity. Design doc `wiki/pages/concepts/concept_zebra-0.12-contracts.md`
refreshed 2026-05-04 to reflect as-shipped state. Closed BUG-087 as a side effect.

### 19. Error recovery — current state and remaining gaps ✅ PHASE 1 COMPLETE
**Bootstrap backend largely done** (verified 2026-04-26 via multi-error fixture):
Bind, Resolve, and TypeCheck collect-and-continue via `Diagnostic` lists;
main.zig prints all of them before halting. 5-error fixture reports all 5.
Tokenizer positioned diagnostics + CRLF hint, AstBuilder TODO panics — both
shipped 2026-04-27.

**Selfhost TC diagnostics shipped 2026-05-05:**
- `Diagnostic{file,line,col,message}` struct + `InferCtx.errors` list + `addErr/hasErrors/errorMessages`
- `checkVarDecl/checkStmts/checkDecl/checkModule` walk; catches primitive type mismatches
- `selfhost/main.zbr` step 4.5: TC check runs before codegen; exits on first error set
- `test/selfhost_compat/run_compat.sh` 2/2 PASS; bootstrap 5/5
- Scope: concrete primitive mismatches only (int/bool/char/float/str). Named/enum types
  deferred — enum not tracked in ModuleTypes; would false-positive without full registry.

**Remaining gaps:**
- Named type checking (enum, struct, class) — needs enum tracking in ModuleTypes first
- Unresolved type in type position — same prerequisite
- Multi-error fixture parity: selfhost still only catches resolver + TC primitive errors;
  bootstrap catches 5 error classes; delta closes further as BUG-099 progresses

### 19.5. TC reliability + extracted VCS-helper features (oracle-prep cluster)

Cluster of high-priority items that emerged from the 2026-05-01 typecheck-as-merge-oracle
audit (`C:/tmp/zebra-tc-audit.md`).  Most of these would meaningfully improve daily Zebra
workflow *without* waiting for a full Zebra-VCS rewrite (which is now reframed as a
post-1.0 capstone — see item 13).

**a. BUG-099 — Split overloaded `.unknown`** ✅ COMPLETE (2026-05-05)
Three-way split shipped in `src/TypeChecker.zig`: `.context_dependent` / `.unknown` / `.unresolved`.
Goal state achieved: zero false `.unresolved` emissions on accepted programs (bootstrap 5/5,
smoke 43/43, full test suite). Side effects: BUG-105, BUG-106, BUG-108 (partial) fixed.
Selfhost port of the split is a future item — selfhost TC currently uses `unknown_` only.

**b. `zebra typecheck-merge` subcommand** ✅ COMPLETE (2026-05-05)
`zebra typecheck-merge <file.zbr>` — extracts both sides of a conflict-marked file
(preserving line numbers via blank-line substitution), runs parse+resolve+ASTBuilder+TC
on each side, reports which side has type errors.  Handles standard and diff3 conflict
styles.  Installed as a git `pre-merge-commit` hook via `tools/install_merge_hook.sh`.
Exit code 0 (informational); test fixture: `test/tc_merge_fixture.zbr`; bootstrap 5/5.

**c. Per-commit zip snapshot git hook** ✅ COMPLETE
Shipped: `.git/hooks/post-commit` saves `zsnapshots/<commit-id>.zip` on every commit.
Evidence: `[zsnapshot] saved <hash>.zip` lines visible in all recent commits.

**d. Bootstrap-check feedback latency**
`tools/bootstrap_check.sh` is the integration safety net but slow under CPU throttle
(observed 5–10 min wall on 2026-04-30 PDF rebuild day).  Profile + optimize where cheap
(parallel build steps, cache invalidation tightening).  Concrete sub-items deferred
until profiling identifies hotspots.  **Effort:** unknown; gated on profiling pass.

**e. selfhost TC diagnostics** ✅ COMPLETE (shipped 2026-05-05, see §19 above)
Sequencing now: BUG-099 → §19.5b typecheck-merge subcommand.

**Cluster framing:** items a, b, e all chain toward "the typecheck-as-merge-oracle is a
real, daily-useful tool" without committing to building a VCS.  Item c is independent
stash-hazard relief.  Item d is orthogonal toolchain quality.

---

### 19a. Boundary-restart parser recovery (deferred)
The Earley parser stops on the first syntax error.  Full multi-error Earley recovery is
genuinely hard and most syntax errors cascade from one root cause, so it's low value.
But indent-based languages have natural sync points: every `dedent` back to column 0 is
a clean restart boundary.  After a parse error, scan forward to the next top-decl-starter
(`class` / `struct` / `def` / `use` / `static` / blank-then-`@`) at column 0, restart the
parse from there, accumulate errors across restarts.  Catches "missing paren in method A
+ bad expression in method B" without trying to recover within a broken decl.  
**Effort:** Session-sized (restart-aware token cursor, ParseResult holds
`errors: []ParseError`, decision logic for safe restart points).  1.0-era.

### 12. Syntax and ergonomics cleanup (Milestone 0.13)
Phase 13 work cluster. Style guide draft (`STYLE_GUIDE.md`)
identifies the canonical forms; sweep targets and compiler-driven workarounds
flow into this milestone.

**Compiler fixes (BUGS.md tracking):**
- **BUG-111** ✅ closed as not-a-bug (2026-05-05) — compound assign already works; zero uses of non-working form found repo-wide
- **BUG-112** ✅ complete (2026-05-05) — grammar rule removed; 38 sites swept to `def name(): T` form across 17 files
- **BUG-113** ✅ closed as not-reproduced (2026-05-05) — slice TC works correctly in current compiler
- **BUG-115** — Real `private` / `internal` visibility keywords (language proposal; `_` prefix has zero compiler enforcement today)

**Style guide sweeps (mechanical, no compiler change):**
- `this.field` → `.field` ✅ 1,141 sites swept across 9 selfhost files (2026-05-05)
- `0 - x` / `0.0 - x` → `-x` (BUG-114 filed for tracking only — `-x` already works)
- `class Main` + `static def main` → top-level `def main()` (selfhost/main.zbr first)
- `_underscore` private prefix → drop (pending BUG-115 decision)

**Other cleanup carried over:**
- `^T` auto-boxing edge case fixes (W11 in `concept_zebra-language-warts.md`)
- Book documentation for `sig`, raw strings, `"""`

See: `wiki/pages/concepts/concept_zebra-0.12-syntax-cleanup.md`,
`STYLE_GUIDE.md` §13.

### 20. SIMD types — Milestone 0.11 headliner
`f32x8`, `i16x16`, `f32x4` etc. naming convention (`{element_type}x{lanes}`). Auto-fallback to scalar loop when the target lacks the vector width.  
**Impl coordinates:** `src/Builtins.zig` (SIMD builtins), `src/TypeChecker.zig` (simd type inference), `src/CodeGen.zig` (`genSimdCall`); selfhost parity in `selfhost/codegen.zbr`.  
**Motivation:** LynseDB brute-force vector search; llama.cpp–style dot-product hotpaths.  
See `wiki/pages/concepts/concept_zebra-simd-design.md` for the complete design.

### 21. Milestone 0.11 supporting cluster
Items that land in the same window as SIMD or that unlock the 0.12/0.13 work:
- **gzip compress** — blocked on Zig 0.16 (`std.compress.flate.Compress` is `@panic("TODO")` in Zig 0.15.2); unblock once Zig upgrades
- **`once` method modifier** — body executes at most once; result cached on the instance
- **Chained comparisons** — `0 < x < 100` desugars to `0 < x and x < 100`
- **`unless` / `until`** — negated conditional + loop forms
- **JSON auto-inference** — `Json.parse(T, str)` infers target struct without a separate `as T` annotation
- **`LowLevel` Gui sub-API** — direct ImGui vertex / draw-command access for custom rendering
- **Profiler** — sampling profiler; output compatible with flamegraph or Zig's tracy integration
See `wiki/pages/projects/project_zebra.md` (milestone table 0.11).

---

## Longer Term (1.0 and Beyond)

### 13. VCS in Zebra — post-1.0 capstone (reframed 2026-05-01)
A version-control tool written in Zebra, architected as Pijul-shaped patch algebra +
AST overlay for `.zbr` + typecheck-as-merge-oracle.  See
`wiki/pages/concepts/concept_zebra-vcs-architecture.md` for the full design.

**Reframing:** previously listed as "agent-tools phase, before IDE."  After the
honest-ROI assessment on 2026-05-01, the *full* VCS rewrite is reframed as a post-1.0
capstone (research/teaching artifact + flagship demo) rather than a near-term productivity
investment.  The two pieces that *would* help daily — `zebra typecheck-merge` and the
per-commit zip-snapshot hook — were extracted to item 19.5 (b, c).

**Open question on the reframing:** if a future workflow change introduces sustained
multi-week branches with real merges (e.g., a collaborator joins, or a long-running
experimental fork stabilizes), the calculus shifts back toward Pijul-style merge correctness.
Revisit if that materializes.

### 14. IDE — self-hosted (post contracts)
Self-hosted Zebra + ImGui editor with:
- Syntax highlighting via `ImGuiColorTextEdit` (pthom fork)
- Inline diagnostics (source-mapped errors already done)
- REPL pane
- Plugin loading via the DynLib plugin system

See: `wiki/pages/concepts/concept_zebra-imgui-backend.md`, `concept_zebra-pthom-editor.md`

### 23. 0.14 — Memory model + concurrency primitives (NEW milestone — split from 1.0 on 2026-05-04)

Foundational memory + concurrency primitives.  Cluster motivation: the
three items below all touch the runtime memory model (or the `<-` token);
they should land **together** so the API surface is settled before 1.0
stability locks it.

**a. `<-` arena copy-out operator** ★ design doc complete
Receive-only operator for crossing the `arena {…}` block boundary:
`outer_var <- inner_value` deep-copies the value into the outer arena,
copying only what's actually allocated in the exiting sub-arena
(provenance-aware).  Implementation split: comptime per-type traversal
generation + runtime `_arena_owns()` provenance check.  Six open
implementation questions surfaced; static elision for primitive types
gives a "free when unneeded" property.  Replaces the current `"" + src`
magic-concat idiom with first-class, grep-friendly syntax.
See [[concept_zebra-arena-copyout]] for the full design + raw
brainstorm conversation.  **Effort:** prototype = 1 session for parser
+ str types; full deep-copy generator with cycles + interfaces = 3-5
sessions.

**b. `Chan(T)` channels** — shares `<-` token with (a)
`ch <- val` (send), `var v <- ch` (receive).  Backed by `std.Thread` +
mutex/condvar queue.  `Chan(T)(capacity: n)` construction.  Must land
*after* (a) so the parser support for `<-` is reused — disambiguation
between channel-receive and arena-copy is type-driven (RHS `Chan(T)` →
channel; else → arena copy).  **Effort:** unknown; channel runtime is
real work but the language-side parser piece is small.

**c. Allocator context** — Odin-style named implicit allocator
Currently the compiler threads `_allocator` everywhere; user code
inherits it implicitly.  Allocator context would let user code say
"this block uses allocator X" without manual threading.  Required for
compiler-scale programs that want pool / region allocators alongside
the default arena.  **Effort:** medium; touches every alloc-emitting
codegen site + the runtime `_initAllocator` mechanism.

**Sequencing:** (a) → (b) → (c).  (a) lands the parser + token; (b)
re-uses parser; (c) is independent and can happen before or after.

### 15. 1.0 — Language stability + CHANGELOG (cumulative commitment)

**Cumulative semantics:** 1.0 isn't "the few items below" — it's the
**full API surface delivered through all prior 0.x milestones, locked
down with a stability promise**.  The items below are *new at 1.0*; the
broader commitment is everything that landed from 0.1 onward.

**Stability commitment — 1.0 must have all of:**
- ✅ Generics (delivered 0.8)
- ✅ Contracts (`require`/`ensure`/`invariant`/`old`/`result`/`--turbo`, delivered 0.12)
- ✅ All stdlib modules through 0.4–0.13: Math, Json, DateTime, CSV, Hash, Random, Arg, Terminal, Log, Uri, Compress, Mime, Timer, Regex, Http, Tcp, Udp, Net, File, sys, Gui, Reflect, Json.parseStrict, Progress
- 0.14 deliverables (must be present and stable at 1.0):
  - `<-` arena copy-out operator (see item 23)
  - `Chan(T)` channels (item 23)
  - Allocator context (item 23)
- 0.13 deliverables: syntax cleanup (BUG-111..115 closed; sweeps complete)
- 0.11 deliverables: SIMD types, real ImGui backend, REPL, regex per-quantifier lazy/greedy
- Source-mapped errors (delivered 0.5), self-hosting (Phase 22 cutover, delivered 2026-04-21)

**NEW at 1.0 (the small list below):**
- Type aliases with constraints (`type Name = str where len > 0`)
- WebSocket (`Ws.connect/send/recv/close`)
- **IANA timezone support (`zdt`)** — `DateTime.inZone("America/New_York")`; see `concept_zebra-datetime-design.md`
- **`Test` stdlib module** — `zebra test` subcommand; test discovery by naming convention (`def test_*`); structured pass/fail output; see `STDLIB_ROADMAP.md` item 11
- **General for-loop destructuring** — `for a, b in list_of_pairs` tuple unpacking; currently only HashMap iteration has this as compiler magic
- CHANGELOG covering the full 0.1 → 1.0 surface

**Implication for "what blocks 1.0":** anything in the cumulative
commitment list that isn't yet shipped or yet stable.  Right now: 0.11
items (SIMD, REPL, ImGui completion), 0.13 items (BUG-111..115 +
sweeps), 0.14 items (the whole new milestone), plus the small
NEW-at-1.0 list.

### 22. 2.0 — Kernel track (Zebra for OS-writing)
2.0 deliverable: bring Zebra to kernel-class capability — bare-metal code with no
runtime underneath.  Motivated by the expressiveness multiplier observation
(selfhost is ~2.7x smaller than the Zig backend), suggesting a Linux-1.0-equivalent
kernel could fit in ~60K LOC of Zebra — "one human can hold it in their head" scale,
in the spirit of MenuetOS / KolibriOS / TempleOS / Ladybird.

Settled design directions (2026-05-02):

**`.zbr` / `.zeb` file split.** Two file extensions sharing one parser/AST.  `.zeb`
files unlock the systems vocabulary (inline asm, custom calling conventions, section
attributes, naked functions, volatile structs, panic-handler override, per-CPU storage,
`@no_fp`, `comptime` blocks).  `.zbr` files build on `.zeb` primitives through normal
imports.  Stronger than Rust-style `unsafe { … }` blocks because the privilege boundary
is enforced by *syntax* (the `.zbr` parser doesn't accept the systems vocabulary at all),
not by reviewer attention.  Implementation is roughly 50 lines in the typechecker —
`.zeb` grammar is a superset of `.zbr` grammar; the difference is a per-construct
allow-flag at semantic analysis.

**`@freestanding` mode.** Disables implicit allocator, removes syscall-touching stdlib,
unlocks bare-metal features.  Companion `core` stdlib (parallel to Rust's `core`) provides
no-allocator equivalents: `FixedList(T, N)`, `OpenAddressMap(K, V, N)`, `[]const u8`.
Contracts, generics, interface vtables, `^T`, throws, nil tracking — all survive
unchanged.

**Heavy Zig leverage.** Inline asm (Zig already supports it — confirmed 2026-05-02),
custom calling conventions, `comptime`, `@embedFile`, packed/aligned structs,
address-space-typed pointers, freestanding mode — all already shipping in Zig 0.15+.
Zebra-side work is mostly Zebra-native naming + the type-system pieces Zig doesn't have.

**Phasing:**
- *1.x prerequisites already on roadmap:* `Chan(T)` (item 15), SIMD (item 20),
  allocator context (item 15).
- *2.0 minimum freestanding:* `@freestanding` + `.zeb` recognition + `core` stdlib
  subset + `@callconv("naked"|"interrupt")` + `asm "…"` + `@section` + `extern "linker"`
  + `@embed_file` + `volatile` + `Cpu.*` intrinsics.  Unlocks bootloader + serial-out kernel.
- *2.0 real-OS layer:* general `comptime` + `@per_cpu` + `@panic_handler` + `@no_fp` +
  cross-target `asm` + bootable-image build target.

**Risks / open questions:** see wiki page.  Notable: the `.zeb` could devolve into
"everything I write" (mitigation: project lints + code review culture); `comptime` blocks
are a real language feature with their own type-checking rules (lower to Zig comptime
initially, implement in selfhost when it earns it).

See: `wiki/pages/concepts/concept_zebra-os-additions.md` for the full design.
Sister page: `concept_zebra-systems-additions.md` (browser-class additions; subset of this).

### 16. Intertextual support (post-1.0)
LXX/MT divergence tool; provenance typing; multilingual manuscript analysis.
RESERVED — wait for Zebra 1.0. See: `wiki/pages/projects/project_intertextual.md`

---

## Completed (Reference)

| Item | Completed |
|------|-----------|
| `.gitattributes` CRLF fix (`*.zbr text eol=lf`) | 2026-04-23 |
| String interning (`_intern` / `_str_pool`) — Phase 25 | 2026-04-23 |
| Optional-unwrap `as` binding (`if x as n`) — Phase 24 | 2026-04-22 |
| Named/default param parity (selfhost) — Phase 23 | 2026-04-22 |
| Selfhost cutover (`zebra.exe` = selfhost binary) — Phase 22 | 2026-04-21 |
| Source-mapped errors (`// zbr:file:line` markers) — Phase 19 | 2026-04-20 |
| Self-hosting bootstrap round-trip (5/5) | 2026-04-18 |
| `pro`/`get`/`set`/`body`/`post` keyword removal | 2026-04-19 |
| Batteries-included stdlib (Hash/Random/Arg/Terminal/Log/Uri/Compress/Mime/Timer) | 2026-04-10 |
| User-defined generics (`class Stack(T)`) — Milestone 0.8 | 2026-04-10 |
| ImGui backend (stub + GLFW) | 2026-04-06 |
| String interning at List/HashMap/field sinks | 2026-04-23 |
| `fn_ref` selfhost parity (BUG-019): `isTopLevelMethod` + `&` prefix in genLocalVar/genAssign | 2026-04-23 |
| `HashMap.count()`/`.remove()` without type annotation: infer from init expr (BUG-081) | 2026-04-23 |
| BUG-002: guard/try_postfix tests fixed with try/catch wrapping | 2026-04-23 |
| `for-else` complete — Path 1 (list native) + Path 2 (while-based labeled block) | 2026-04-23 |
| Per-block `scanMutations` in `genStmts` — eliminates cross-arm const/var pollution | 2026-04-23 |
| BUG-027: expression-position chain fix — labeled block in both backends | 2026-04-23 |
| BUG-027 throws sub-issue: `exprCallIsThrows` handles call receivers; `try` emitted in labeled block + statement-position hoist; selfhost parity via `inferExpr`+`isClassMethodThrows`; bootstrap 5/5 | 2026-04-23 |
| BUG-082: selfhost `inferExpr` cross-module constructor gap — `SomeMod.Class(args)` → `Type_.named` | 2026-04-24 |
| `interface` codegen: fat-pointer vtable struct (`ptr`/`vtable`/`check()`); `implements` sites → `.check(@This())`; selfhost parity; bootstrap 5/5 | 2026-04-24 |
| BUG-083: `genGenericClass` now emits `comptime { IFoo.check(@This()); }` for `implements`; selfhost parity; bootstrap 5/5 | 2026-04-24 |
| Float token merge: `float_lit`/`float_lit_exp`/`fractional_lit` → single `float_lit`; `isFloatLit()` simplified; bootstrap 5/5 | 2026-04-24 |
| `@[...]` array literal in expressions + `in @[...]` membership test via `_zebra_in` + `inline for`; selfhost parity; bootstrap 5/5 | 2026-04-24 |
| BUG-084: selfhost `Lexer.zbr` `[`/`]` removed from `parenDepth`; aligned with Zig Tokenizer (`(`/`)` only); 26/26 smoke, bootstrap 5/5 | 2026-04-24 |
| `_f32`/`_f64`/`f32`/`f64` float suffix codegen: `genFloatLit` in both backends; `@as(fNN, val)` emission; selfhost uses `replace()`; 27/27 smoke, bootstrap 5/5 | 2026-04-24 |
| `ensure`+`old` codegen: defer-based post-condition checks; `old expr` → `const _old_N = snapshot;` + substitution; `kw_old`→`UnaryOp.old_` added to selfhost AST/parser/astbuilder; 29/29 smoke, bootstrap 5/5 | 2026-04-24 |
| BUG-085: static-field bare-name emit — `genIdent` now checks field's own `static` mod; emits `TypeName.field` not `self.field`; `isStaticField` added to selfhost; both backends; bootstrap 5/5 | 2026-04-24 |
| DESIGN-002: `collectAndEmitOldSnapshots` 8 missing Expr arms — `array_lit`/`list_lit`/`tuple_lit`/`dict_lit`/`string_interp`/`type_check`/`slice`/`except_` added; regression test `contract_old_compound_test.zbr`; 31/31 smoke, bootstrap 5/5 | 2026-04-24 |
| `--turbo` flag: `strip_contracts: bool` on Generator; all require/ensure/invariant emit sites guarded; `_ = self;` suppression updated; generate* chain threads `strip_contracts`; `smoke_turbo` verifier; `turbo_test.zbr`; both backends; bootstrap 5/5 | 2026-04-24 |
| BUG-027: method chaining in expression position — labeled-block fix in both backends; throws sub-issue: `exprCallIsThrows` handles call receivers | 2026-04-23 |
| BUG-083 / BUG-084: `genGenericClass` `implements` check + selfhost `parenDepth` only tracking `(`/`)` | 2026-04-24 |
| `for-else` complete (Path 1 native + Path 2 labeled-block) | 2026-04-23 |
| `interface` codegen: fat-pointer vtable struct (`ptr`/`vtable`/`check()`); both backends; bootstrap 5/5 | 2026-04-24 |
| `Json.parseStrict` + `@reflectable` (scope-1 primitives); per-class `_json_parse_strict_<T>`; both backends; 43/43 smoke | 2026-04-27 |
| `Progress` stdlib (`Progress.bar`/`tick`/`done`); std.Progress backed; both backends; 34/34 smoke | 2026-04-24 |
| `branch` struct field patterns (Option A): `on Point(x: 0, y: 0)` syntax; both backends; 35/35 smoke | 2026-04-25 |
| `result` capture in `ensure`: `kw_result` + `Expr.result_` + `_ensure_armed` flag; closes BUG-087; 40/40 smoke | 2026-04-27 |
| Selfhost cutover (zebra.exe = selfhost binary) — Phase 22 | 2026-04-21 |
| `str` Comparable verified excluded already at `TypeChecker.zig:2982` (no fiat-by-default; `bool` and `string` excluded explicitly) | (verified 2026-04-?) |
| Style guide draft committed at `STYLE_GUIDE.md` (foundational §1 decisions resolved 2026-05-04) | 2026-05-04 |
| Phase 13 BUGS-111..115 filed for the syntax-cleanup window | 2026-05-04 |
| Phase 13 sweep #1: `this.field → .field` — 1,141 sites across 9 selfhost files | 2026-05-05 |
| Phase 13 sweep #2: `def name: T → def name(): T` — 38 sites across 17 files; grammar rule removed (BUG-112) | 2026-05-05 |
| BUG-111 closed as not-a-bug — compound assign already works | 2026-05-05 |
| BUG-113 closed as not-reproduced — slice TC works correctly | 2026-05-05 |
| BUG-099 `.unknown` three-way split (`.context_dependent`/`.unknown`/`.unresolved`); zero false `.unresolved` on accepted programs; bootstrap 5/5, smoke 43/43 | 2026-05-05 |
| §19 selfhost TC diagnostics Phase 1: `Diagnostic` struct + `InferCtx.errors` + primitive mismatch detection; `selfhost_compat` 2/2 PASS; bootstrap 5/5 | 2026-05-05 |
| §19.5b `zebra typecheck-merge` subcommand: conflict-side extraction + TC check; line-number preservation; diff3 support; git hook installer; bootstrap 5/5 | 2026-05-05 |

---

*Full milestone plan: `wiki/pages/projects/project_zebra.md`*  
*Open bug details: `BUGS.md`*  
*Self-hosting history: `SELFHOST_JOURNAL.md`*
