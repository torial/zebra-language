# Zebra — Next Steps

Authoritative priority queue for the project. Update this file rather than regenerating the list from scratch each session.

**Last updated:** 2026-05-20 (Zig 0.16 fully complete: bootstrap 5/5, 122/122 smoke; _Chan→std.Io.Mutex/Condition, _build_new .empty; bamos + oma tracked; _initIo gap noted)

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
- [x] REPL — `zebra repl` subcommand; accumulate-and-rerun model; sentinel output isolation; :help/:clear/:history/:load/:save; selfhost delegates to bootstrap (2026-05-13)
- [x] Real ImGui backend completion (`LowLevel` sub-API) — `g.lowLevel.addLine/addRect/addRectFilled/addCircle/addCircleFilled/addText` (DrawList), `getWindowPos/Size/getCursorPos/getMousePos` → `(float,float)` tuple, `beginGroup/endGroup/sameLine`; stub + ImGui backends; 94/94 smoke (2026-05-13)
- [x] JSON auto-inference — `Json.parse(T, src)` typed overload routes to `parseStrict` machinery; `@reflectable` required; both backends; bootstrap 5/5 (2026-05-13)
- [x] Tuple/multi-return — `(T1, T2)` type, `(a, b)` literal, `var (x, y) = f()` destructure, `.0`/`.1` index; TC element-type registration; 93/93 smoke; bootstrap 5/5 (2026-05-13)
- [x] gzip compress — `std.compress.flate.Compress.init` + round-trip test; 124/124 smoke, bootstrap 5/5 (2026-05-20)
- [x] Generic functions — `def identity(T)(x: T): T` syntax; `comptime T: type` Zig emission; call-site flattening `identity(int)(42)` → `identity(i64, 42)`; TC inference for format specs; 125/125 smoke, bootstrap 5/5 (2026-05-20)
- [x] Zig 0.16 upgrade (core) — `ArrayList.empty`, `init: std.process.Init`, `_initIo` chain, selfhost `genMethod` fix; bootstrap 5/5 (2026-05-20)
- [x] Zig 0.16 compat — `_Chan` updated to `std.Io.Mutex`/`Condition` + `std.Options.debug_io`; `_build_new` `.targets = .empty`; 122/122 smoke, bootstrap 5/5 (2026-05-20)
- [x] Debugger / DAP — `zebra debug <file.zbr>` + DAP proxy (commit 18bccac)
- [x] Build system in Zebra — `zebra build` + `Build` stdlib module; selfhost TC/codegen parity; --build-file/--list-targets/b.target(); 96/96 smoke, bootstrap 5/5 (2026-05-14)

**0.13 remaining:**
- [x] BUG-115 — visibility keywords enforcement: `private`/`public`/`internal`/`protected` parsed + enforced; TC error outside owning class; cross-module `internal` excluded from interface table; selfhost parity; 99/99 smoke, bootstrap 5/5 (2026-05-14)
- [x] `^T` auto-boxing edge case fixes: `List(^T).add(val)` heaps-boxes struct values in both compilers; `for item in List(^T)` via Zig auto-deref; method-chain fixed (BUG-027/079); 100/100 smoke, bootstrap 5/5 (2026-05-14)
- [ ] Book docs for `sig`, raw strings, `"""`

**0.14 remaining (entire milestone — priority cluster):**
- [x] `<-` copy-out: full deep-copy for `List` / classes inside `allocate` blocks via `_zbr_deep_copy`; HashMap blocked (compile error by design); 114/114 smoke, bootstrap 5/5 (2026-05-17)
- [x] `allocate` Slice 5: `is_scoped` flag wired into copy-out; `allocate_depth` replaces `arena_depth`; scoped Arena/Debug/FixedBuffer dupe correctly; 113/113 smoke, bootstrap 5/5 (2026-05-17)
- [x] `allocate` Slice 6: `arena` keyword removed (soft deprecation — helpful error message); `StmtArenaScope` removed from both compilers; `kw_arena` kept in lexer so parser can surface the error cleanly; 113/113 smoke, bootstrap 5/5 (2026-05-17)
- [x] `Chan(T)` channels (`ch <- val` / `var v <- ch`); `sys.go(lambda)` fire-and-forget threads; TC inference (recv→?T, send/close→void); chan+thread smoke tests; QUICKSTART §35; 116/116 smoke, bootstrap 5/5 (2026-05-18)

**New at 1.0:**
- [x] `Test` stdlib module + `zebra test` subcommand
- [x] Type aliases with constraints (`type Name = BaseType where value > expr`); transparent emit; constraint check injected after var init; --turbo strips checks; both backends; bootstrap 5/5 (2026-05-18)
- [x] Refinement types (parametric aliases): `type Bounded(lo: int, hi: int) = int where value >= lo and value <= hi`; value params bound into constraint; `Bounded(0, 100)` in type position; struct-base aliases; both backends; 119/119 smoke, bootstrap 5/5 (2026-05-18)
- [x] WebSocket (`Ws.connect/send/recv/close` + `Ws.serve` + `wss://` TLS + blocking `recv` + graceful close); both backends; bootstrap 5/5 (2026-05-19)
- [x] IANA timezone support (`DateTime.inZone("America/New_York")`) — built-in table (~75 zones), 4 DST rules (US/EU/AU/NZ), zero binary-size cost if unused, both backends, 130/130 smoke, bootstrap 5/5 (2026-05-23)
- [x] `in EXPR` scope blocks — any object with `begin()`/`end()` works; desugars to `{ const _in_N = EXPR; _in_N.begin(); defer _in_N.end(); body }`; `g.vbox()`/`g.hbox()` factory methods on GuiContext; QUICKSTART §38; both backends, 131/131 smoke, bootstrap 5/5 (2026-05-23)
- [x] General for-loop destructuring (`for a, b in list_of_pairs` — `List((T1, T2))` declared-type locals/params; where clause; arity error; 97/97 smoke, bootstrap 5/5) (2026-05-14)
- [ ] CHANGELOG covering the full 0.1 → 1.0 surface

**0.15 — Language syntax cleanup:**
- [x] `x!` postfix force-unwrap — `x!` ≡ `x to!`; `x!.method()` chains cleanly; `to!` stays as alias; both compilers; 132/132 smoke, bootstrap 5/5 (2026-05-23)
- [x] `with` desugars bare method calls — `with g` makes `text("hello")` → `g.text("hello")`; both compilers; 133/133 smoke, bootstrap 5/5 (2026-05-23)
- [x] Remove `try expr` prefix form — Zig syntax leak; use `expr?` instead; migration note in QUICKSTART; both compilers; 133/133 smoke, bootstrap 5/5 (2026-05-23)
- [x] Inline single-line if/else — `if x: y` and `if x: y else: z`; `:` required; `else if` chaining + next-line `else:` both supported; both compilers; 133/133 smoke, bootstrap 5/5 (2026-05-24)
- [ ] `Scope` interface for `in EXPR` — TC verifies `in EXPR`'s type implements `interface Scope { begin(); end() }`; `_GuiVBox`/`_GuiHBox` updated; structural typing (no `implements` needed); both compilers
- [x] `is not` precedence — documented in QUICKSTART; test added to is_not_precedence_test.zbr; Expr4 > Expr3(not) > Expr(or) ordering confirmed; both compilers (2026-05-23)

**0.15 — Stdlib completeness (pre-1.0 push):**
- [ ] `Http.serve(port, handler)` — Zig has `std.http.Server` since 0.11; expose for web service use cases; both backends
- [ ] `ThreadPool(n)` — `std.Thread.Pool`; `pool.submit(lambda)` + `pool.wait()`; bounded concurrency; both backends
- [ ] `Path.*` — `Path.join/dirname/basename/normalize/extension`; wraps `std.fs.path`; both backends
- [ ] Complete gzip compress — `Compress.gzip(bytes)` is currently a stub (Zig 0.15 limit fixed in 0.16); both backends
- [ ] `Tcp.serve(port, handler)` — complement to `Tcp.connect`; both backends
- [ ] `Atomic(T)` — wraps `std.atomic.Value(T)`; lock-free int/bool counters; both backends
- [ ] `Log` improvements — structured logging (JSON lines, level filtering, file sink); both backends
- [ ] `Crypto` additions — AES-GCM encrypt/decrypt, curve25519 key exchange; wraps `std.crypto`; both backends
- [ ] `SQLite` — C binding via `zig-sqlite` or direct `libsqlite3`; lower priority (requires C dep)

**0.15 — libui-ng consolidation:**
- [ ] Audit `torial/libui-ng` (wp-2025) vs `petabyt/libui-dev` (extra components) + `kojix2/libui-ng` (bug fixes); cherry-pick into `torial/libui-ng`; update `build.zig.zon` hash

---

## Open Bugs

**Selfhost `_initIo` propagation gap** —
Selfhost-emitted dep modules get a simple `_initIo` from the preamble (sets local `_io` only);
bootstrap-emitted dep modules get a propagating version that chains to their own transitive deps.
Currently harmless: `ast.zbr`/`cg_helpers.zbr`/`typechecker.zbr` don't call any `_io`-dependent
operations directly.  If a transitive dep gains file I/O calls in future, it will silently use
undefined `_io`.  Long-term fix: emit a propagating `_initIo` in `generateModuleWith` (mirroring
`src/CodeGen.zig` `genModule` lines 1896–1907).  **Deferred** — harmless now; track for 1.0 pre-flight.

**BUG-026** — `instance_method_return_types` gaps for exposed-type method chains
Not manifesting in practice — `scanMutationsInExpr` conservatively marks cross-module calls as mutated.
Defer unless a concrete failing case is found.

**BUG-014** — Regex lazy match is global, not per-quantifier
`<.*?>STUFF.*>` misbehaves; `lazy_match` is a whole-regex flag.
Architectural fix: priority-first NFA simulation or backtracking engine.
File: `src/CodeGen.zig` NFA preamble. Effort: L. **Deferred post-1.0** — workaround is to split the pattern or restructure; no concrete urgent case.

**Phase 13 cluster (style-guide–driven sweep targets, BUG-115)** —
queued for the 0.13 syntax-cleanup window. See §12 below.

---

## Medium Term (Milestone Features)

### 24. Compiler ergonomics + self-hosting quality (active sprint 2026-05-16)

Five pain points surfaced during Gap-3 / tuple / DynLib work. Prioritised in this order:

**a. Exhaustive union-match warning** *(complete 2026-05-16)*
`--warn-non-exhaustive` flag in both compilers: when a `branch` on a same-module union
has an `else` arm but doesn't name all variants, emits a warning per uncovered variant.
108 existing `else` arms made always-on impractical; flag enables opt-in at development
time when adding new union variants.  Bootstrap (`typeCheckPass3Ex`) + selfhost
(`InferCtx.warn_non_exhaustive` + `checkStmts Stmt.branch_` arm + `warningMessages()`).
Bootstrap 5/5, 104/104 smoke.

**b. Cross-module `^T?` branch bindings not tracked** *(complete 2026-05-16)*
Bootstrap TC: `inferMember` for cross-module types now wraps in `optional` when the field
is in `optional_ref_fields` (i.e., declared as `^T?`).  Previously, `instance_field_types`
returned a bare `cross_module` type stripping the optional wrapper, so `if x as n` on such
fields reported "requires optional type, got 'T'".
Selfhost TC: option B in `walkStmt` `if x as n` now strips `Type_.ref_to` before checking
`Type_.optional`, so same-file `^T?` fields also work.
Test: `test/crossmod_hatopt_test.zbr` — linked list with cross-module `^Chain?` field.
Bootstrap 5/5, 105/105 smoke.

**c. Optional chaining `?.` operator** *(complete 2026-05-16)*
`foo?.bar` and `foo?.method(args)` — nil base propagates nil; non-nil accesses member/calls
method.  New `question_dot` token; grammar productions; `ExprOptChain` AST node; Resolver +
TC + CodeGen in both compilers.  Selfhost resolver, `nameUsedInExpr` in `cg_helpers.zbr`
patched to handle `opt_chain` (missing cases caused spurious `_ = param;` + pointless-discard
Zig error).  Bootstrap 5/5, 106/106 smoke.

**d. `genMemberCall` user-method bypass pattern keeps recurring** *(complete 2026-05-16)*
Added a general user-method early-exit in `genMemberCall` (selfhost/codegen.zbr): before
all heuristic branches, if the receiver is a `Type_.named` user class with a declared
method `mname`, emit `receiver.mname(args)` directly (with `try` prefix when the method
is in `throws_methods` and the call context is throws).  Stdlib primitives (List,
StringBuilder, etc.) are not in `ModuleTypes`, so they fall through to existing heuristics.
Makes the per-method `count`/`at` bypasses redundant (kept for now as documentation).
Bootstrap 5/5, 104/104 smoke.

**e. Stdlib method registration in 4 places** *(architectural; defer)*
Every new stdlib method touches `src/CodeGen.zig`, `selfhost/codegen.zbr`,
`selfhost/typechecker.zbr` (inferExpr allowlist), and sometimes `cg_helpers.zbr`.
Long-term fix: a single method-descriptor table driving both TC inference and codegen
dispatch.  **Defer post-1.0** — the 4-place pattern is painful but mechanical.

**f. Type-first dispatch for str/StringBuilder/List/HashMap** *(complete 2026-05-17)*
Mode 1 arms added in `selfhost/codegen.zbr` `genMemberCall`: `Type_.string_builder`,
`Type_.hashmap_`, `Type_.list_`, `Type_.string_` each have a `branch recv_t` arm that
handles all their known methods and returns; unhandled methods fall through to Mode 2 as
a safe fallback.  Additive strategy — Mode 2 kept for `infer_ctx == nil` paths (field
defaults) and TC gaps.  Bootstrap 5/5, 112/112 smoke.  See commit 6c1c072.

### 6. REPL (Milestone 0.11)
Two-phase approach: warm-up pre-compiled preamble once → per-input incremental compile.
"Accumulate and rerun" state model (all previous cells stay in scope).
`sys.readLine()` is done (2026-05-10); remaining work is the incremental-compile mode.
See design notes in `SELFHOST_JOURNAL.md`.

**REPL latency — resident compiler (`--watch` / compiler server) — pre-1.0:**
Current model spawns a fresh `zig` process per REPL entry; Zig 0.16 incremental compilation
helps mid-session (declaration-level cache hits on append-only generated source), but cold-start
and link cost remain.  Next unlock: keep a resident Zig compiler process alive for the REPL
session using `--watch` or the compiler server API so incremental state stays warm in memory.
This would make per-entry latency feel near-instant for small additions.  **Target: pre-1.0.**

### 7. Regex per-quantifier lazy/greedy (Milestone 0.11)
Unblocked by BUG-014 fix. Mixed lazy/greedy patterns (`<.*?>STUFF.*>`) require the NFA
to track per-node shortest/longest flags, not a global flag.

### 9. Greek NT n-gram port — **SIMD now landed; deferred wait is over**
SIMD types shipped 2026-05-08 — the reason for deferring this port is gone.
Scope: file I/O, `HashMap` with Unicode keys, sort, sliding n-gram window, TF-IDF /
cosine similarity via `f32x8` dot-product.  See `concept_zebra-simd-design.md`
for the fuzzy-match and text-analytics use-case table.

**SIMD 1.0 enhancement — runtime CPU dispatch:**
[oma](https://github.com/ATTron/oma) (One Man Array) is a Zig library for runtime SIMD
dispatch: at startup the binary detects CPU capabilities and selects the best kernel
(SSE2 → AVX2 → AVX-512 on x86-64; NEON → SVE2 on AArch64) without requiring separate
builds.  By 1.0, Zebra's SIMD types should use runtime dispatch so a single
`zebra build` binary runs optimally across CPUs without per-target compilation.
Design spike needed: integrate `oma`-style dispatch or expose `@cpu_feature` primitives
that map to the same pattern.  **Target: 1.0.**

### 10. Plugin system — DynLib demo ✓ (2026-05-16)
Interface vtable construction, shim functions, DynLib stdlib, and demo files are complete.
`examples/hello_plugin.zbr` + `examples/plugin_host.zbr` show the factory-function pattern.
`test/dynlib_iface_test.zbr` covers vtable dispatch without DLL loading (both backends pass).
Full DLL round-trip (build plugin → load from host) requires platform build steps — not in CI.
See: `wiki/pages/concepts/concept_zebra-plugin-system.md`

### 12. Syntax and ergonomics cleanup (Milestone 0.13)

**Open compiler work:**
- **BUG-115** — Real `private` / `internal` visibility keywords (language proposal;
  `_` prefix has zero compiler enforcement today). Decision needed before 1.0.

**Open sweeps (pending BUG-115 decision):**
- `_underscore` private prefix → drop (blocked on BUG-115 outcome)

**Open docs:**
- Book documentation for `sig`, raw strings, `"""`
- `^T` auto-boxing ✅ — done 2026-05-14 (see 0.13 remaining above)

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

- **gzip compress** ✅ — `std.compress.flate.Compress.init` + round-trip test; 124/124 smoke, bootstrap 5/5 (2026-05-20).
- **JSON auto-inference** — `Json.parse(T, str)` without a separate `as T` annotation.
- **Gui stack** — ImGui GLFW backend is superseded by the MVU + ZigZag TUI + libui-ng redesign
  (decided 2026-05-18; see §14 and `wiki/pages/concepts/concept_zebra-gui-redesign.md`).
  `LowLevel` sub-API work is on hold pending ZigZag canonical backend implementation.
- **Debugger / DAP** — `zebra debug <file.zbr>` subcommand implemented (commit 18bccac).
  Full DAP proxy in `src/Debugger.zig`: bidirectional `zbr↔zig` source-map (reads
  `// zbr:file:line` markers), Content-Length framed JSON transport, two-relay-thread
  proxy that remaps `setBreakpoints` and `stackTrace` messages between IDE and lldb-dap.
  Graceful error if lldb-dap not on PATH. Selfhost delegates to `zebra-bootstrap.exe`
  via `sys.exec_inherit`. IDE setup documented in `docs/DEBUGGING.md`.
  **Next:** Debug button in ZebraIDE (IDE/ZebraIDE.zbr — implement DAP client using
  `zebra debug --listen PORT`); install LLDB on Windows to test end-to-end.
- **`--module-path DIR`** — implemented (2026-05-12). Adds DIR to the module search
  path; `use Foo` resolves against source-file directory first, then each `--module-path`
  in order. Multiple flags allowed; also `--module-path=DIR` form. Threads recursively
  through `compileZbrToZig`.
- **Build system in Zebra** — `zebra build` subcommand + `Build` stdlib module (2026-05-13).
  `Build.new()` / `b.exe(name, entry)` / `b.lib(name, entry)` / `b.run()` /
  `target.platform(str)` / `target.option(k,v)` / `target.linkLib(other)` /
  `b.dependency(name, ver)` stub.  Bootstrap compiler only; selfhost TC/codegen parity pending.

---

## Longer Term (pre-1.0)

### 23. 0.14 — Memory model + concurrency primitives ★ Priority cluster

Foundational memory + concurrency primitives.  Cluster motivation: these items shape the
runtime memory model and the `<-` token — they need to land **together** so the API
surface is settled before 1.0 stability locks it.

**a. `allocate` block — Slices 1–4 shipped, Slices 5–6 remaining**
Slices 1–4 complete (2026-05-12): `Allocator` as a primitive Zebra type; `allocate <expr>`
block syntax; `Arena()`, `Debug()`, `Page()`, `Smp()`, `C()`, `FixedBuffer(buf)`,
`ThreadSafe(inner)`, `Pool(T)()`, `StackFallback(N)()` named wrappers; both backends.
`arena` still coexists as legacy sugar for `allocate Arena()`.

Remaining:
- **Slice 5** — copy-out reconciliation: `StmtAllocate.is_scoped` flag wired into `<-`
  codegen; `allocate_depth` replaces `arena_depth`; non-scoped wrappers short-circuit
  to plain assignment.  See `docs/allocate_design.md`.
- **Slice 6** ✅ — `arena` keyword removed; `StmtArenaScope` gone from both compilers; `kw_arena` kept
  in lexer so the parser surfaces a helpful error instead of crashing. (2026-05-17)

**b. `<-` copy-out operator — DONE (2026-05-17)**
`str` → `dupe`; `List(T)` / class / struct → `_zbr_deep_copy` (comptime recursive
traversal via `@typeInfo`; ArrayList detected by method presence; single-item `*T`
recurses into fields; `HashMap` is a compile-time error by design).
Primitives (int/float/bool/char) → plain assignment.  `scanMutations` now descends
into `allocate` blocks so LHS targets are correctly emitted as `var`.
See `selfhost/stdlib_preamble.zig` for `_zbr_deep_copy` and `selfhost/cg_helpers.zbr`
for the `scanMutationsInto` fix.

**c. `Chan(T)` channels** *(complete 2026-05-18)*
`_Chan(T)` runtime (mutex/condvar/ring buffer), `_chan_create`, `genChanMethod` (send/recv/close),
`<-` sugar in `genCopyOut`, `Chan(T)` → `*_Chan(T)` in genType, `Chan(T)(cap)` constructor —
all implemented in both compilers.  `sys.go(lambda)` fire-and-forget thread spawning via
`_sys_go` comptime helper in `stdlib_preamble.zig`.  Selfhost TC inference added (chan_ Type_ variant,
recv→?T, send/close→void).  `chan_smoke_test.zbr` + `chan_thread_test.zbr` both in `selfhost_smoke.sh`.
QUICKSTART §35 documents full API.  116/116 smoke, bootstrap 5/5.

**Sequencing:** (a) Slice 5 → (b) full deep-copy → (c) — all complete.

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
- 0.11 deliverables: REPL, Gui stack (ImGui superseded by ZigZag+libui-ng redesign — see §14), regex per-quantifier, JSON auto-inference, gzip, debugger/DAP, build system
- 0.13 deliverables: BUG-115 resolved, remaining sweeps, `^T` fixes
- 0.14 deliverables: full `<-` deep-copy, `Chan(T)`, allocator context

**New at 1.0:**
- ~~Named `cue init` construction calls~~ **DONE (2026-05-19)**: `Point(y: 5)` with defaults; `Config(debug: true)` reorders and fills remaining defaults. Both compilers. Limitation: selfhost codegen only does named/default fill for same-module types — cross-module (`ast.Modifiers`) still needs positional args in selfhost-compiled code.  All `Modifiers` params now have `= false` defaults for bootstrap use.  bootstrap 5/5, 121/121 smoke.  Cross-module selfhost fill is deferred to a future sprint (requires threading dep module AST through `lookupFnParams`).
- ~~`Test` stdlib module~~ **DONE**: `zebra test` subcommand, `assert_eq/ne/true/false` statements, `def test_*` discovery, structured pass/fail output; both backends
- ~~Type aliases with constraints~~ **DONE**: `type Name = BaseType where value > expr`; transparent emit; constraint check injected after var init; --turbo strips checks; both backends; bootstrap 5/5 (2026-05-18)
- ~~Refinement types (parametric aliases)~~ **DONE**: `type Bounded(lo: int, hi: int) = int where value >= lo and value <= hi`; value params bound into constraint check; 119/119 smoke, bootstrap 5/5 (2026-05-18)
- ~~WebSocket~~ **DONE**: `Ws.connect/send/recv/close` + `Ws.serve` + `wss://` TLS + blocking `recv` + graceful close; both backends; bootstrap 5/5 (2026-05-19)
- IANA timezone support (`zdt`) — `DateTime.inZone("America/New_York")`; see `concept_zebra-datetime-design.md`
- [x] General for-loop destructuring — `for a, b in list_of_pairs` tuple unpacking (2026-05-14)
- CHANGELOG covering the full 0.1 → 1.0 surface

---

## Post-1.0

### 13. VCS in Zebra — post-1.0 capstone
Pijul-shaped patch algebra + AST overlay + typecheck-as-merge-oracle.
The daily-useful pieces (`zebra typecheck-merge` subcommand, per-commit zip snapshot)
were extracted and shipped in §19.5.  The full VCS rewrite is a post-1.0 research /
teaching artifact.  See `wiki/pages/concepts/concept_zebra-vcs-architecture.md`.

### 14. IDE — self-hosted (GUI stack redesigned 2026-05-18)

**Previous direction (superseded):** ImGui GLFW backend + pthom ImGuiColorTextEdit.

**New direction:** MVU/Elm architecture + ZigZag TUI canonical backend + libui-ng GUI adapter.
- **API model:** `init()` / `update(msg)` / `view(model)` — users write MVU; ZigZag TUI is the
  canonical backend that defines the API ceiling.
- **ZigZag TUI** (meszmate/zigzag, v0.1.5, Zig 0.15.2-compatible): pure Zig, zero deps, CodeView
  with syntax highlighting, 34+ components including DiffView/Table/BarChart/FilePicker.
- **libui-ng GUI** (kojix2 fork, active): native OS controls (Win32/GTK3/Cocoa).  Zig binding:
  `desttinghim/zig-libui-ng` — **validate against Zig 0.15.2 before starting** (30 min check).
- **Code editor:** ZigZag CodeView (full); libui-ng `uiMultilineEntry` (degraded); stub no-op.
  `uiArea` is the long-term libui-ng path.
- **Layout:** `.fill` / `.fraction(n)` / `.fixed(n)` semantic values — each backend maps its own density.

**Implementation sequence:**
1. ~~Validate `desttinghim/zig-libui-ng` against Zig 0.15.2~~ — done (broken, ~30 min fix deferred)
2. ~~Design MVU Gui API in QUICKSTART.md + toy programs~~ — done (see §30 in QUICKSTART.md)
3. ~~ZigZag TUI backend (canonical reference)~~ — **done 2026-05-21** (`--gui-backend=tui`; counter example works end-to-end; see `docs/gui_mvu_design.md`)
4. libui-ng adapter (~200-300 lines widget-cache reconciliation + two `build.zig` Zig 0.16 fixes)

See: `wiki/pages/concepts/concept_zebra-gui-redesign.md`

### 17. 1.5 — WASM Compilation Target + Web Frontend SDK

Compile Zebra to WebAssembly — both freestanding (AlpineJS / HTMX browser integration)
and WASI (server-side Wasm runtimes).  Full design doc at
`wiki/pages/concepts/concept_zebra-wasm-frontend.md`.

**Core deliverables:**
- `--target wasm32-freestanding` and `--target wasm32-wasi` compiler flags
- `std.heap.wasm_allocator` as default allocator in WASM targets (replaces GPA; uses
  `@wasmMemoryGrow` — already in Zig 0.13+, zero extra deps)
- `export def` → Zig `export fn` codegen; `-rdynamic` flag threads through to `zig build`
- `__zebra_alloc(len: i32): i32` exported memory helper for JS-side string allocation
- `print()` remapped to imported `__zebra_print(ptr: u32, len: u32)` in WASM mode
- String boundary convention: pointer + length pairs; generated shim uses
  `TextDecoder`/`TextEncoder` for marshalling
- Generated JS shim (`module.js`) wires imports, exposes named exports, manages memory
- Module target blacklist: each build target declares unavailable stdlib modules
  (e.g. `wasm_freestanding` blacklists `File`, `Http`, `Tcp`, `Udp`, `Net`, `Gui`,
  `sys.exec_*`, `sys.getenv`; WASI relaxes the `Http`/`Tcp` portion)
- AlpineJS integration: `zebra build --target wasm32 --alpine` emits an Alpine-ready shim
  so exports are usable directly as `x-data` object properties
- No-`throws` restriction at WASM export boundary (compile-time error, not runtime trap)

**Key design decisions to settle before implementation:**
1. `throws` at WASM boundary: compile-time restriction (recommended) vs return-code
   convention vs trap — affects whether exported functions can call stdlib I/O
2. Class/struct passing across boundary: restrict to primitives + strings at 1.5, or add
   serialization protocol now
3. `print()` buffering: flush on newline vs flush on export-function return

**Effort:** ~2–3 weeks.  Shares `@freestanding` mode + module blacklist infrastructure
with the §22 kernel track — implement those two foundations once, both milestones benefit.

See: `wiki/pages/concepts/concept_zebra-wasm-frontend.md`

### 17b. 1.5 — Http server ergonomics (swerver-inspired)

Three patterns from the [swerver](https://ziggit.dev/t/building-an-http-server-with-no-per-request-allocations-in-zig/15578) zero-allocation Zig HTTP server worth adopting at 1.5.  See design notes at `wiki/pages/concepts/concept_zebra-http-design.md`.

**a. Arena-per-request as the idiomatic `Http` handler model**
The runtime supplies a fresh `Allocator` (backed by a fixed-size arena) to every handler; it resets automatically on handler return.  Zero per-request heap churn for typical GET traffic.  Aligns with Zebra's existing `allocate` block + `Chan(T)` model.  Primary open question: explicit arena parameter vs implicit allocator context (explicit is safer for 1.5; contextual sugar can follow).

**b. `str_view` / borrowed string slice type**
Swerver's zero-copy header parser works because Zig can express `[]const u8` slices that borrow from the read buffer without copying.  Zebra's `str` is always owned — no way to say "this string lives as long as this buffer."  A `str_view` (or `StrSlice`, `&str`) unlocks zero-copy HTTP header parsing, zero-copy CSV/JSON tokenization, and cheap substring operations.  **This is the biggest structural gap between Zebra's string model and what high-performance servers need.**  Requires a design spike on lifetime annotation or scoped-lifetime guarantees before implementation.

**c. `BoundedPool(T, N)` stdlib module**
`Pool(T)()` already exists as an allocator wrapper.  What swerver adds on top: a LIFO free-index stack (O(1) acquire/release) and an acquired bitmap for double-release detection in debug mode (`BoundedPool(T, N, .debug)`).  Useful beyond HTTP: any program managing fixed pools of buffers (audio, video, network I/O) benefits from the correctness guarantee with zero overhead on the success path.

See: `wiki/pages/concepts/concept_zebra-http-design.md`

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

**Reference project:** [BamOS](https://github.com/bagggage/bamos) — Zig-native OS kernel with
multi-ABI support (GNU/Linux + Windows NT) and a pure-Zig build pipeline.  Use as a concrete
test target / compatibility reference when designing `.zeb` freestanding mode and `@freestanding`
ABI conventions.  Bootstrappable with `zig build` alone — no external toolchain needed.

**WASM track (builds on §17 1.5 foundations):**
The `@freestanding` mode and module blacklist built for the kernel track are shared with
WASM targets.  2.0 adds beyond 1.5:
- Multi-file WASM modules (1.5 is single-file only)
- Source maps for WASM output (`--sourcemap` flag; maps WASM binary offsets to `.zbr` lines)
- `wasm-opt` integration as an optional Binaryen post-pass (size + speed)
- Class/struct passing across WASM boundary via serialization protocol (deferred from 1.5)
- HTMX pattern library: `zebra build --target wasm32 --htmx` emits server-validation shim

See: `wiki/pages/concepts/concept_zebra-wasm-frontend.md` §2.0 section

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
