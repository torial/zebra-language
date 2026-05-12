# Zebra — Next Steps

Authoritative priority queue for the project. Update this file rather than regenerating the list from scratch each session.

**Last updated:** 2026-05-11 (cleanup pass — collapse completed items, add 1.0 gap checklist)

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

## 1.0 Gap Checklist (quick-scan)

Everything here must ship before 1.0 stability locks in.

**0.11 remaining:**
- [ ] REPL
- [ ] Real ImGui backend completion (`LowLevel` sub-API + any remaining rendering gaps)
- [ ] BUG-014 regex per-quantifier lazy/greedy
- [ ] JSON auto-inference (`Json.parse(T, str)` without `as T`)
- [ ] gzip compress — **Zig 0.16 now released; unblocked but migration work TBD**
- [x] Debugger / DAP — `zebra debug <file.zbr>` + DAP proxy (commit 18bccac)
- [ ] Build system in Zebra

**0.13 remaining:**
- [ ] BUG-115 — visibility keywords decision + sweep (or formally drop `_` convention)
- [ ] `^T` auto-boxing edge case fixes
- [ ] Book docs for `sig`, raw strings, `"""`

**0.14 remaining (entire milestone — priority cluster):**
- [ ] `<-` arena copy-out: full deep-copy for `List` / classes (prototype done for str+primitives)
- [ ] `Chan(T)` channels (`ch <- val` / `var v <- ch`)
- [ ] Allocator context (Odin-style named implicit allocator)

**New at 1.0:**
- [x] `Test` stdlib module + `zebra test` subcommand
- [ ] Type aliases with constraints (`type Name = str where len > 0`)
- [ ] WebSocket (`Ws.connect/send/recv/close`)
- [ ] IANA timezone support (`zdt` — `DateTime.inZone("America/New_York")`)
- [ ] General for-loop destructuring (`for a, b in list_of_pairs`)
- [ ] CHANGELOG covering the full 0.1 → 1.0 surface

---

## Open Bugs

**BUG-026** — `instance_method_return_types` gaps for exposed-type method chains
Not manifesting in practice — `scanMutationsInExpr` conservatively marks cross-module calls as mutated.
Defer unless a concrete failing case is found.

**BUG-014** — Regex lazy match is global, not per-quantifier
`<.*?>STUFF.*>` misbehaves; `lazy_match` is a whole-regex flag.
Architectural fix: priority-first NFA simulation or backtracking engine.
File: `src/CodeGen.zig` NFA preamble. Effort: L. Blocks §7 below.

**Phase 13 cluster (style-guide–driven sweep targets, BUG-115)** —
queued for the 0.13 syntax-cleanup window. See §12 below.

---

## Medium Term (Milestone Features)

### 6. REPL (Milestone 0.11)
Two-phase approach: warm-up pre-compiled preamble once → per-input incremental compile.
"Accumulate and rerun" state model (all previous cells stay in scope).
`sys.readLine()` is done (2026-05-10); remaining work is the incremental-compile mode.
See design notes in `SELFHOST_JOURNAL.md`.

### 7. Regex per-quantifier lazy/greedy (Milestone 0.11)
Unblocked by BUG-014 fix. Mixed lazy/greedy patterns (`<.*?>STUFF.*>`) require the NFA
to track per-node shortest/longest flags, not a global flag.

### 9. Greek NT n-gram port — **SIMD now landed; deferred wait is over**
SIMD types shipped 2026-05-08 — the reason for deferring this port is gone.
Scope: file I/O, `HashMap` with Unicode keys, sort, sliding n-gram window, TF-IDF /
cosine similarity via `f32x8` dot-product.  See `concept_zebra-simd-design.md`
for the fuzzy-match and text-analytics use-case table.

### 10. Plugin system — DynLib demo
Round-trip: a toy "Hello" plugin DLL loaded by a host program via `std.DynLib`.
`interface` codegen is done — this is now unblocked.
See: `wiki/pages/concepts/concept_zebra-plugin-system.md`

### 12. Syntax and ergonomics cleanup (Milestone 0.13)

**Open compiler work:**
- **BUG-115** — Real `private` / `internal` visibility keywords (language proposal;
  `_` prefix has zero compiler enforcement today). Decision needed before 1.0.

**Open sweeps (pending BUG-115 decision):**
- `_underscore` private prefix → drop (blocked on BUG-115 outcome)

**Open docs:**
- Book documentation for `sig`, raw strings, `"""`
- `^T` auto-boxing edge case fixes (W11 in `concept_zebra-language-warts.md`)

**Done (reference):**
- BUG-111 ✅ — compound assign already works (closed not-a-bug 2026-05-05)
- BUG-112 ✅ — `def name: T` grammar rule removed; 38 sites swept (2026-05-05)
- BUG-113 ✅ — slice TC works correctly (closed not-reproduced 2026-05-05)
- `this.field → .field` sweep ✅ — 1,141 sites across 9 selfhost files (2026-05-05)
- `class Main + static def main → def main()` sweep ✅ — 103 files (2026-05-06)
- `0 - x → -x` sweep ✅ — already clean (verified 2026-05-06)
- Scripting stdlib gate ✅ — `Dir.walk` + `re.replace` + `sys.readLine` all done

See: `wiki/pages/concepts/concept_zebra-0.12-syntax-cleanup.md`, `STYLE_GUIDE.md` §13.

### 19. Error recovery — remaining gaps

**Done:** Bootstrap collect-and-continue (5 error classes), selfhost TC primitive
mismatch diagnostics, `zebra typecheck-merge` subcommand, source-mapped errors.
See completed table for details.

**Still open:**
- **Enum type checking** — enum variants not tracked in `ModuleTypes`; false-positive
  risk prevents adding them without a full enum registry first.
- **Multi-error fixture parity** — selfhost catches resolver + TC primitive errors;
  bootstrap catches 5 classes; delta closes further once enum tracking lands.

### 19.5. TC reliability cluster — remaining item

**d. Bootstrap-check feedback latency**
`tools/bootstrap_check.sh` is the integration safety net but slow under CPU throttle
(observed 5–10 min wall on 2026-04-30 PDF rebuild day).  Profile + optimize where cheap
(parallel build steps, cache invalidation tightening).  Gated on a profiling pass.

Items a, b, c, e all complete — see completed table.

### 19a. Boundary-restart parser recovery (deferred)
After a parse error, scan forward to the next top-decl-starter (`class` / `struct` /
`def` / `use` / `static` / blank-then-`@`) at column 0, restart the parse from there,
accumulate errors across restarts.  Most syntax errors cascade from one root cause, so
full multi-error Earley recovery is disproportionate — but this catches "missing paren
in method A + bad expression in method B" cheaply.
**Effort:** session-sized. **Target:** 1.0-era.

### 21. Milestone 0.11 — remaining items

- **gzip compress** — `std.compress.flate.Compress` was `@panic("TODO")` in Zig 0.15.2.
  **Zig 0.16 now released** — unblocked, but migration to 0.16 may bring its own
  headaches.  Revisit once the Zig upgrade is done.
- **JSON auto-inference** — `Json.parse(T, str)` without a separate `as T` annotation.
- **`LowLevel` Gui sub-API** — direct ImGui vertex / draw-command access for custom rendering.
- **Debugger / DAP** — `zebra debug <file.zbr>` subcommand implemented (commit 18bccac).
  Full DAP proxy in `src/Debugger.zig`: bidirectional `zbr↔zig` source-map (reads
  `// zbr:file:line` markers), Content-Length framed JSON transport, two-relay-thread
  proxy that remaps `setBreakpoints` and `stackTrace` messages between IDE and lldb-dap.
  Graceful error if lldb-dap not on PATH. Selfhost delegates to `zebra-bootstrap.exe`
  via `sys.exec_inherit`. **Next:** wire into the custom IDE (IDE/ZebraIDE.zbr); install
  LLDB on Windows to test end-to-end.
- **Build system in Zebra** — not started.

---

## Longer Term (pre-1.0)

### 23. 0.14 — Memory model + concurrency primitives ★ Priority cluster

Foundational memory + concurrency primitives.  Cluster motivation: these items shape the
runtime memory model and the `<-` token — they need to land **together** so the API
surface is settled before 1.0 stability locks it.  If `Chan(T)`'s API or allocator
context syntax is wrong, there's no fixing it post-1.0.

**a. `<-` arena copy-out operator — prototype done, full deep-copy pending**
Parser + both backends shipped for `str` + primitives (2026-05-10).
Full deep-copy for `List` / classes with provenance tracking is the remaining work.
Implementation split: comptime per-type traversal generation + runtime `_arena_owns()`
provenance check.  See [[concept_zebra-arena-copyout]] for design doc.

**b. `Chan(T)` channels**
`ch <- val` (send), `var v <- ch` (receive).  Backed by `std.Thread` +
mutex/condvar queue.  `Chan(T)(capacity: n)` construction.  Parser support for
`<-` is already in place — disambiguation between channel-receive and arena-copy
is type-driven (RHS `Chan(T)` → channel; else → arena copy).
**Effort:** unknown; channel runtime is real work; language-side parser piece is small.

**c. Allocator context** — Odin-style named implicit allocator
Lets user code say "this block uses allocator X" without manual threading.  Required
for compiler-scale programs that want pool / region allocators alongside the default
arena.  **Effort:** medium; touches every alloc-emitting codegen site + `_initAllocator`.

**Sequencing:** (a) full deep-copy → (b) → (c).  (c) is independent and can move earlier.

### 15. 1.0 — Language stability + CHANGELOG (cumulative commitment)

**Cumulative semantics:** 1.0 is the **full API surface delivered through all prior 0.x
milestones, locked down with a stability promise**.  The items below are *new at 1.0*;
the broader commitment is everything that landed from 0.1 onward.

**Stability commitment — 1.0 must have all of:**
- ✅ Generics (delivered 0.8)
- ✅ Contracts (`require`/`ensure`/`invariant`/`old`/`result`/`--turbo`, delivered 0.12)
- ✅ All stdlib modules through 0.4–0.13: Math, Json, DateTime, CSV, Hash, Random, Arg,
  Terminal, Log, Uri, Compress, Mime, Timer, Regex, Http, Tcp, Udp, Net, File, sys,
  Gui, Reflect, Json.parseStrict, Progress, Base64, Path, Profile, SIMD
- ✅ Self-hosting + bootstrap round-trip (Phase 22, 2026-04-21)
- ✅ Source-mapped errors (delivered 0.5)
- 0.11 deliverables: REPL, real ImGui backend, regex per-quantifier, JSON auto-inference, gzip, debugger/DAP, build system
- 0.13 deliverables: BUG-115 resolved, remaining sweeps, `^T` fixes
- 0.14 deliverables: full `<-` deep-copy, `Chan(T)`, allocator context

**New at 1.0:**
- ~~`Test` stdlib module~~ **DONE**: `zebra test` subcommand, `assert_eq/ne/true/false` statements, `def test_*` discovery, structured pass/fail output; both backends
- Type aliases with constraints (`type Name = str where len > 0`)
- WebSocket (`Ws.connect/send/recv/close`)
- IANA timezone support (`zdt`) — `DateTime.inZone("America/New_York")`; see `concept_zebra-datetime-design.md`
- General for-loop destructuring — `for a, b in list_of_pairs` tuple unpacking; currently only HashMap iteration has this
- CHANGELOG covering the full 0.1 → 1.0 surface

---

## Post-1.0

### 13. VCS in Zebra — post-1.0 capstone
Pijul-shaped patch algebra + AST overlay + typecheck-as-merge-oracle.
The daily-useful pieces (`zebra typecheck-merge` subcommand, per-commit zip snapshot)
were extracted and shipped in §19.5.  The full VCS rewrite is a post-1.0 research /
teaching artifact.  See `wiki/pages/concepts/concept_zebra-vcs-architecture.md`.

### 14. IDE — self-hosted
Self-hosted Zebra + ImGui editor: syntax highlighting (pthom `ImGuiColorTextEdit`),
inline diagnostics (source-mapping already done), REPL pane, plugin loading.
See: `wiki/pages/concepts/concept_zebra-imgui-backend.md`, `concept_zebra-pthom-editor.md`

### 22. 2.0 — Kernel track (Zebra for OS-writing)
2.0 deliverable: bring Zebra to kernel-class capability — bare-metal code with no
runtime underneath.  Motivated by the expressiveness multiplier observation
(selfhost is ~2.7x smaller than the Zig backend), suggesting a Linux-1.0-equivalent
kernel could fit in ~60K LOC of Zebra.

Settled design directions (2026-05-02):

**`.zbr` / `.zeb` file split.** `.zeb` files unlock the systems vocabulary (inline asm,
custom calling conventions, section attributes, naked functions, volatile structs,
panic-handler override, per-CPU storage, `@no_fp`, `comptime` blocks).  Privilege
boundary enforced by *syntax*, not reviewer attention.  Implementation ~50 lines
in the typechecker.

**`@freestanding` mode.** Disables implicit allocator, removes syscall-touching stdlib,
unlocks bare-metal.  Companion `core` stdlib provides no-allocator equivalents.
Contracts, generics, interface vtables, `^T`, throws, nil tracking all survive.

**Phasing:**
- *2.0 minimum:* `@freestanding` + `.zeb` recognition + `core` stdlib subset +
  `@callconv("naked"|"interrupt")` + `asm "…"` + `@section` + `extern "linker"` +
  `@embed_file` + `volatile` + `Cpu.*` intrinsics.  Unlocks bootloader + serial-out kernel.
- *2.0 real-OS:* general `comptime` + `@per_cpu` + `@panic_handler` + `@no_fp` +
  cross-target `asm` + bootable-image build target.

See: `wiki/pages/concepts/concept_zebra-os-additions.md`
Sister page: `concept_zebra-systems-additions.md` (browser-class additions; subset of this).

### 16. Intertextual support (post-1.0)
LXX/MT divergence tool; provenance typing; multilingual manuscript analysis.
RESERVED — wait for Zebra 1.0. See: `wiki/pages/projects/project_intertextual.md`

---

## Completed (Reference)

| Item | Completed |
|------|-----------|
| `@once` modifier + `sys.readLine()` + `<-` arena prototype (str+primitives) | 2026-05-10 |
| TC Phase 5: generic class→interface + i→i + transitive conformance; both backends | 2026-05-09 |
| `zebra typecheck-merge` subcommand + git hook installer | 2026-05-05 |
| BUG-099 `.unknown` three-way split (`context_dependent`/`unknown_`/`unresolved`); selfhost port | 2026-05-05–06 |
| Selfhost TC diagnostics Phase 1: primitive mismatch detection; `selfhost_compat` 2/2 | 2026-05-05 |
| Stdlib gap sprint (Sprints 1–5): Math/String/Base64/Hash/File/sys/Path/Random extensions | 2026-05-06 |
| Phase 13 sweeps: `this.field→.field` (1,141 sites), `def name:T→def name():T` (38 sites), BUG-112 grammar rule removed | 2026-05-05 |
| BUG-111 closed (not-a-bug), BUG-113 closed (not-reproduced) | 2026-05-05 |
| SIMD types (`f32x8`/`i32x4`/etc.); constructor/splat/load/arith/reductions; both backends | 2026-05-08 |
| Guarded for-in (`for x in list if cond`) + `List.find(pred)`; all 7 dispatch paths | 2026-05-08 |
| `@profile` method attribute (Part B); wraps body with Profile.start/defer end | 2026-05-07 |
| BUG-120: `.add()→.append()` rewrite fires on user class methods via lowercase vars | 2026-05-07 |
| `Profile` module Part A: `start/end/report/dump_folded/reset`; flamegraph output | 2026-05-06 |
| Chained comparisons `a < b < c`; `ExprChainedCmp` AST; labeled-block and-chain | 2026-05-06 |
| `unless`/`until` — parser-level desugar; both backends | 2026-05-06 |
| Style guide draft committed (`STYLE_GUIDE.md`; foundational §1 decisions resolved) | 2026-05-04 |
| Per-commit zip snapshot git hook (`zsnapshots/<hash>.zip`) | 2026-05-05 |
| `Json.parseStrict` + `@reflectable` (scope-1 primitives); both backends | 2026-04-27 |
| `result` capture in `ensure`; closes BUG-087 | 2026-04-27 |
| `--turbo` flag: strips contracts at codegen; both backends | 2026-04-24 |
| `ensure` + `old` codegen: defer-based post-conditions; `old expr` snapshots | 2026-04-24 |
| `Progress` stdlib (`Progress.bar/tick/done`); std.Progress backed; both backends | 2026-04-24 |
| `branch` struct field patterns (`on Point(x: 0, y: 0)`) syntax; both backends | 2026-04-25 |
| `interface` codegen: fat-pointer vtable struct; `implements` → `.check(@This())` | 2026-04-24 |
| `@[...]` array literal + `in @[...]` membership test; selfhost parity | 2026-04-24 |
| Float token merge: `float_lit`/`float_lit_exp`/`fractional_lit` → single `float_lit` | 2026-04-24 |
| `for-else` — Path 1 (list native) + Path 2 (while-based labeled block) | 2026-04-23 |
| BUG-027: expression-position chain fix + throws sub-issue; both backends | 2026-04-23 |
| BUG-082: selfhost cross-module constructor gap — `SomeMod.Class(args)` → `Type_.named` | 2026-04-24 |
| Contracts: `require`/`ensure`/`invariant`/`old`/`result`/`--turbo` — Milestone 0.12 | 2026-04-24–27 |
| String interning (`_intern`/`_str_pool`) — Phase 25 | 2026-04-23 |
| Optional-unwrap `as` binding (`if x as n`) — Phase 24 | 2026-04-22 |
| Named/default param parity (selfhost) — Phase 23 | 2026-04-22 |
| Selfhost cutover (`zebra.exe` = selfhost binary) — Phase 22 | 2026-04-21 |
| Source-mapped errors (`// zbr:file:line` markers) — Phase 19 | 2026-04-20 |
| `pro`/`get`/`set`/`body`/`post` keyword removal | 2026-04-19 |
| Self-hosting bootstrap round-trip (5/5) | 2026-04-18 |
| User-defined generics (`class Stack(T)`) — Milestone 0.8 | 2026-04-10 |
| Batteries-included stdlib (Hash/Random/Arg/Terminal/Log/Uri/Compress/Mime/Timer) | 2026-04-10 |
| ImGui backend (stub + GLFW) | 2026-04-06 |

---

*Full milestone plan: `wiki/pages/projects/project_zebra.md`*
*Open bug details: `BUGS.md`*
*Self-hosting history: `SELFHOST_JOURNAL.md`*
