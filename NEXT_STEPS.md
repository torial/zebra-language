# Zebra — Next Steps

Authoritative priority queue for the project. **Update this file rather than
regenerating it.** Open work is curated at the top (scan the index first);
completed work is clumped at the bottom (recent items in full, older items as
one-line archive rows). Full history for anything archived lives in git, `BUGS.md`,
`SELFHOST_JOURNAL.md`, `CHANGELOG.md`, and the wiki.

> **Milestone cumulative semantics:** each milestone is *additive*. A feature
> labeled 0.14 lands at 0.14 and is then part of the **1.0 stability commitment**
> (1.0 = everything delivered 0.1 → 0.15, locked). Same rule for 2.0 (kernel
> track = 1.0 + the 2.0 additions). "What blocks 1.0" = everything labeled for any
> 0.x milestone not yet shipped + stable. Public release = **0.9** (ready-for-
> others, not-yet-1.0). Authoritative version-by-version breakdown:
> `wiki/pages/projects/project_zebra.md`.

---

# ▶ Open work — scan me first

Every genuinely-open item, grouped. Each links to its detail section below or to
the tracker. `[ ]` = open, `[~]` = partially done / has an open tail.

## Language & compiler direction — 2026-07-28 assessment

Sean asked what would make Zebra a daily driver on technical grounds (ecosystem/user-base
explicitly excluded). Items below are that answer, re-ordered by MEASUREMENT after the first
pass got the cause wrong. **#2 and #4 are flagged DISCUSS-FIRST at Sean's request** — he wants
to weigh strategies before implementation.

### The measurements everything below rests on (don't re-derive these)

| What | Time |
|---|---|
| Zebra front end, hello-world (`--emit-zig`) | **0.057 s** |
| `zig build-exe`, trivial 5-line Zig, LLVM | **5.2 s** |
| `zig build-exe`, Zebra 3,790-line emit, LLVM | 6.2 s |
| `zig build-exe`, trivial Zig, `-fno-llvm -fno-lld` | **0.94 s** |
| `zig build-exe`, Zebra 3,790-line emit, `-fno-llvm -fno-lld` | **1.15 s** |

**The conclusions, which are not what I first claimed:**
- The front end is *excellent* — 57 ms. Latency is entirely downstream of it.
- **Zig's own floor dominates**: ~5.2 s LLVM / ~0.94 s self-hosted, for ANY program.
- The entire 186 KB preamble therefore costs **~1 s on LLVM and ~0.2 s on the fast backend** —
  not the bulk of the time. My first analysis attributed the 5.2 s to the preamble without
  measuring the floor; one probe refuted it. **Preamble work is NOT a latency fix.**
- Therefore *tree-shaking the preamble* (conditional population — Sean's alternative) buys
  ~0.2 s. See the verdict under #1.

### THE ORGANIZING GOAL (agreed with Sean, 2026-07-28): move checking INTO Zebra

The measurement that produced this frame:

| `zebra -c` outcome | time |
|---|---|
| clean program | 0.81 s |
| error only `zig` can see | 1.88 s |
| **error the Zebra front end catches itself** | **0.062 s** |

A check the front end can answer costs **62 milliseconds**, because it never invokes
Zig at all. So the question was never "how do we make checking fast" — it is
**"how much checking can Zebra do itself?"** Every check moved into the front end is
simultaneously ~25x faster, reported against the user's own source instead of
generated Zig, and available to the IDE/LSP without a build.

That reframes three items below as **one project wearing three hats**:

- **#3** (nil-narrowing into the TypeChecker) — makes the TC authoritative about what
  is known, which everything else builds on.
- **#5a** (stdlib arity/signature table) — moves a whole class of silent miscompiles
  (BUG-215) into front-end diagnostics.
- **#4** (what `-c` should promise) — becomes a *consequence* rather than a separate
  design question: the more the front end checks, the more a fast check is a real one.

Related, same direction: BUG-218 (`str + int`) was exactly this move — a mistake that
used to surface as a Zig error about `_str_concat` in a 3,790-line generated file now
resolves in 62 ms against the user's own line, with a caret. That is the template.

**Sequencing:** #5a first (self-contained, immediate user-visible payoff, no
dependencies), then #3 (deeper, unlocks the rest), then revisit #4 with Sean once the
front end's coverage is actually worth promising something about.

### FREE WIN — `-c` is excluded from the fast backend (do this first)

`selfhost/main.zbr:2414` reads `if not mode_c and not release and …` — check mode is
**explicitly excluded** from the `-fno-llvm -fno-lld` path. So the most latency-sensitive
operation in the compiler, and the one that `IDE/ZebraIDE.zbr`'s Check button runs, deliberately
takes the *slowest* route: **5.2 s where ~1 s was available.**

The exclusion may be deliberate — the comment above it notes the self-hosted linker does not
error on unresolved C symbols, so compile-failure fallback cannot protect C-dep builds. But that
argument is about C deps, which the condition already tests separately. Worth an hour: determine
whether `mode_c` needs excluding at all, and if not, delete two words for a 5x improvement in
the compiler's most-run command.

- [ ] **#1 — Stop inlining the preamble; ship it as a runtime module. SPIKED 2026-07-28 — design proven end-to-end, see `docs/runtime_module_design.md` before starting.** Emitted programs
  would `@import` a runtime package instead of carrying 3,790 lines of copy-pasted preamble for a
  2-line source. **Re-justified after measurement — this is NOT about speed** (worth ~0.2 s on
  the fast path). It is about three things that are real:
  1. **Error locations.** Errors currently land in generated code (`_str_concat` at line 3779 of
     a file the user never wrote — BUG-215/218). With a ~50-line emitted file there is almost
     nowhere for an error to land except user code.
  2. **Namespace isolation.** Closes BUG-220 *completely*, including the `@export`/`@node_export`
     cases the `_zbr_fn_` prefix cannot cover.
  3. **Artifact comprehensibility** — debugging, DAP, `remapZigErrors`, and anyone reading the
     emitted Zig.

  **Verdict on the tree-shaking alternative** (conditionally populate the preamble by what the
  program uses): *not recommended as a substitute.* It buys ~0.2 s; it requires a call-graph
  reachability analysis over the preamble (whose helpers call each other) that must be
  conservative or it emits undefined identifiers; and — the decisive objection — it makes
  BUG-220-class collisions **input-dependent**: a program compiles until you add a call that
  drags in a preamble chunk containing your function's name. A collision that appears when you
  add an unrelated line is a far worse failure mode than one that is either always present or
  never. Tree-shaking is a reasonable *optimisation* later; it is not the fix for what #1 is for.

  Overlaps `docs/single_file_emit_design.md` but is distinct: that combines *modules*; this stops
  copy-pasting the *runtime*.

  **Spike outcome (do not re-derive):** `@import` shares file-scope state across modules at
  any depth (proven 3 levels deep) — so one shared `_allocator`/`_io` **dissolves BUG-221**
  outright, no fan-out. A real hello-world split cleanly: **3,791 lines → a 30-line user file
  + a 3,770-line runtime module (126×)**. Two constraints found before writing any compiler
  code: (a) `usingnamespace` is **removed in Zig 0.16**, so symbols come in by explicit alias;
  (b) a mutable `var` **cannot be aliased** across modules (`const x = _rt.x` → "unable to
  resolve comptime value"), so the **19 mutable preamble vars must be QUALIFIED** at every
  emit site — that is the main implementation cost, and it is also exactly what makes them
  shared. Plus one backward dependency to break: the preamble's `_initIo` calls
  `_initModuleVars()`, which codegen emits into the *user* file.

- [ ] **#3 — Move nil-narrowing into the TypeChecker.** Narrowing is currently codegen-only (see
  the BUG-188 note in `genMemberCall`): `inferExpr` still reports `?TcpConn` inside
  `if conn != nil`, so the type checker and codegen disagree about what is known. It works today
  because emit unwraps, but it caps every future check built on inference. Prerequisite for
  making the TC authoritative.

- [ ] **#5a — Stdlib arity/signature checking.** The BUG-215 class: `indexOf(a, b)` silently
  discarded its second argument, turning a typo into a runtime panic three frames away. Today
  only `indexOf` is guarded, via `@compileError`. The real fix is a stdlib signature table in the
  front end so arity errors become proper Zebra diagnostics with a source location.

  **Groundwork done 2026-07-28 — read this before starting, it rules out two approaches.**
  1. **Deriving arities from CodeGen is UNSOUND.** Scanning each `if mname == "X"` block for the
     highest `args.at(N)` it reads gives 292 method names but wrong numbers — it reports
     `addDays 0`, `abs 0`, `ceil 0`, because codegen reads arguments through several idioms
     (`genArgList`, loops, helpers) an AST-free scan cannot see. A wrong table produces FALSE
     errors on valid code, which is worse than no table. Do not revive this.
  2. **QUICKSTART's documented signatures are a good source, and 42 of 45 string methods
     validate against the compiler** (script: build a call at the documented arity, run `-c`).
     But the section is not receiver-uniform — `join` is documented under "String method
     reference" while being a `List` method (`parts.join(", ")`), which my first validator
     mis-reported as a doc bug. **Any signature table or doc-checking gate must carry the
     receiver KIND per row, not assume it from the section heading.**
  3. Real finding from that pass, already fixed: `chars()`/`bytes()` were documented as
     returning `List(char)`/`List(int)` but are **`for`-only iterators** — `for c in s.chars()`
     compiles, `var cs = s.chars()` does not.

  **Recommended shape:** a table keyed by *(receiver kind, method name) -> arity*, consulted by
  the TypeChecker only where the receiver type is KNOWN (unknown receiver -> no check, so an
  inference gap can never manufacture a false error). Pair it with a gate that, for every table
  row, compiles a call at the declared arity — so a wrong entry fails loudly at gate time
  instead of silently breaking users. That gate is the artifact worth having; it also
  doubles as a doc-vs-implementation check for the language reference, which is how the
  `chars`/`bytes` inaccuracy surfaced.

- [ ] **#5b — Spans on all AST nodes.** `AstBuilder` uses `zspan()` for 95 of its node kinds.
  Measured impact is *narrower than first claimed* (17 corpus diagnostics carry locations, 0 land
  at `0:0`; the only reproducible case is a two-literal concat), so this is a cap on how good
  diagnostics can get, not a present emergency. Do it when it blocks something.

- [ ] **#2 — Typed error sets. DISCUSS STRATEGY WITH SEAN FIRST.** Errors are stringly-typed:
  `raise "division by zero"`, caught as `e.message`, everything `anyerror!T`. A caller cannot
  know which errors a function raises, cannot handle them exhaustively, gets no compiler help
  when a new failure mode is added, and breaks silently when someone rewords a string. This is
  the one place Zebra is **less typed than the Zig it compiles to** (Zig has error sets; we
  flatten them). In a language whose differentiator is Eiffel-style contracts — careful machinery
  for stating what must hold going in and out — leaving "what can go wrong" untyped is the
  design's biggest internal inconsistency. Sketch: `def parse(s: str) throws ParseError` with
  exhaustive `catch`. Design space includes declared vs inferred sets, subtyping/widening, and
  migrating every existing `raise`.

- [ ] **#4 — A check mode that actually checks. DISCUSS STRATEGY WITH SEAN FIRST.** `zebra -c`
  runs a full `zig build-exe`. A check that stops after typecheck would be **~0.06 s instead of
  5.2 s** — 90x on the compiler's most-run command, and it would make the IDE Check button
  instant. The strategy question is what `-c` should *promise*: front-end-only (fast, misses
  emit/codegen bugs only `zig` catches) versus today's full build (slow, total). Plausible answer
  is both — a fast default plus an opt-in `--check-full` — but that contract is worth agreeing
  before building. The FREE WIN above is independent and can land first regardless.

## Pre-1.0 blockers (the road to 0.9 / 1.0)

> **AUDITED 2026-07-28 — the list was longer than the work.** Every item was checked
> against reality. Of 8 entries, 3 were already complete, and of the 5 that read as
> open:
> - **1 is a real blocker, and more serious than it was labelled** — BUG-221 (module
>   init is not transitive) was recorded as "harmless today"; it is a live segfault.
> - **1 is the milestone act itself** (§15) — not work, the promise to freeze.
> - **1 is explicitly NOT a blocker by its own text** — §28a, which records Sean's
>   2026-07-23 framing verbatim: *"NOT a 1.0/1.5 gate … Doesn't block anything."* It
>   was sitting in the blocker list anyway.
> - **1 had a stale premise** — §19.5d claims 5–10 min; measured 163–180 s.
> - **1 is 1.5 groundwork by its own description** — §28e exists to ground the *1.5*
>   `str_view` design. Left in place pending Sean's call rather than moved unilaterally.
> - **1 was already resolved months ago** — BUG-174, closed 2026-07-28.
>
> **So the honest road to 1.0 is one technical bug plus the freeze**, not five open
> items. A stale blocker is not free: it makes the distance look longer than it is and
> invites re-litigating decisions already shipped.


- [ ] **§28a step 4 — inference-or-error language flip (selfhost).** Phase 1 (measure)
  DONE 2026-07-15: instrumented the 3 selfhost guess sites; 80 unique sites but ~0 genuine
  ambiguity — the gap is selfhost *inference strength*, not a flip. **Step 2 open: close the
  ~5–8 inference root causes** (`.len`→int, arith-of-prims→prim, call-return propagation,
  user-class field typing; overlaps §24e), re-measure toward 0, THEN flip. Bootstrap corpus
  stays at 0 (`check_inference_guess.sh`), so the user-facing guarantee already holds. Gated,
  supervised. Also surfaced BUG-181 (selfhost can't self-compile `main.zbr`). → *Open detail §28a.*
  **Framing (Sean 2026-07-23): NOT a 1.0/1.5 gate — an INCREMENTAL thread.** Each inference
  root cause is independent and shippable, so §28a rides as a series of post-1.0 point
  releases (1.0.x), each gated. Doesn't block anything; the bootstrap witness holds the line
  meanwhile. A thread to pull on for a while, not a milestone.
- [x] **SIMD data bridge (BUG-197) — `f32x8` usable on real data. Tiers 1+2 DONE 2026-07-18.**
  Found by the 2026-07-17 Greek-NT dogfood. **Tier 1 `.toFloat32()`** (commit `ac48cbe`) and
  **Tier 2 `List(float32)`/`List(f32)`** (commit `015e8c3`) landed, gated. Payoff delivered: the
  SIMD-vs-scalar all-pairs cosine on the Greek vectors runs at **~7.8×** (f32x8 0.39 ms vs scalar
  3.03 ms, ReleaseFast), identical results, exact clustering. **Tier 2 was a selfhost-lags-bootstrap
  convergence** (the bootstrap already accepted `List(float32)`).
  - [x] **Ergonomic follow-ups DONE 2026-07-18** (commits `ee69570`, `ce12e9f`, all gated):
    un-annotated `var v = f32x8(…)` now dispatches `.sum()`/`.dot()` (SIMD-ctor inference — another
    selfhost→bootstrap convergence); `f32.toFloat()` widens via `@floatCast` instead of
    `@floatFromInt`; short type names `f32`/`i32`/`u8`/… map in `typeFromName` so `List(f32)` is
    inference-consistent with `List(float32)`.
  - [x] **Tier 3 DONE 2026-07-18** (commit `736a7d6`) — `f32x8.load(list, offset)` on Sean's
    approved API: `f32x8.load(WF, o)` → `(WF).items[@as(usize,@intCast(o))..][0..8].*`; 1-arg
    `.load(slice)` (offset 0) unchanged. Benchmark rewritten to it — byte-identical, four one-line
    loads for four eight-arg constructors. **All three SIMD-data-bridge tiers complete; BUG-197
    fully resolved.**
- [ ] **§28e — `str` ownership doc table.** Per-stdlib-call borrows-vs-owns table in
  the spec/QUICKSTART (documentation, not a new type). Grounds the 1.5 `str_view`
  design. → *Open detail §28e.*
- [x] **§28f — generic `Set(T)` DONE (2026-07-24).** Distinct `Type_.set_` variant
  emitting `AutoHashMap(T, void)` / `StringHashMap(void)` (str). API: `add`/`contains`/
  `remove`/`len`/`count`/`items`→`List(T)`/`clear`, `for x in set`, `x in set`. Works as
  local/param(by-ptr)/field/return/nested `List(Set(int))`. **Selfhost-only** (bootstrap
  sunsets; the compiler's own source never uses Set, so round-trip holds). Decisions taken:
  str specialized (content-hash), `items()`→`List(T)`, StrSet stays internal. Limits (=HashMap):
  T must be auto-hashable; no `==`/`print(set)`. **Collection literals also DONE** —
  `{a, b, c}`→`Set(T)` (new `Expr.set_lit`) and `{k: v, ...}`→`HashMap(K,V)`
  (`Expr.dict_lit`, disambiguated by `:`); `{}`→empty dict (annotate or error). (Set
  literals root-caused a nasty TCO fall-through hang — see [[project_tco_fallthrough_hazard]];
  dict literals went smoothly since that plumbing was already safe.) Tests: `set_basic_test`,
  `set_advanced_test`, `set_literal_test`, `dict_literal_test` (all smoke-gated). → detail §28f.
- [x] **BUG-174 — `str.indexOf` signature design call. CLOSED 2026-07-28 — it was
  already resolved, just never closed.** Both compilers and the docs now agree on a
  mixed convention: `indexOf`/`lastIndexOf` return `int` with a `-1` sentinel (so
  arithmetic like `indexOf(x) + 1` stays natural — the reason BUG-181 moved the
  selfhost off `int?`), while `indexOfFrom`/`indexOfIgnoreCase` return `int?`.
  Verified by running the same program through both compilers: identical output on
  all four methods, hit and miss. **Was sitting in the pre-1.0 blocker list as an
  open decision that no longer needed deciding.**
- [ ] **BUG-221 — module init is not TRANSITIVE (was: "`_initIo` propagation gap,
  harmless today").** **Re-verified 2026-07-28 and it is NOT harmless:** a three-module
  program whose deepest module touches a file **segfaults today** — no future trigger
  needed. `main` → `leaf` works; `main` → `mid` → `leaf` crashes at
  `0xffffffffffffffff` with Zig's `0xaaaa…` poison pattern in the trace, because the
  entry point initialises direct deps only. Repro + mechanism in `BUGS.md`. **This is
  the one genuine technical blocker left on this list.**
- [ ] **§15 — 1.0 stability lock + final CHANGELOG pass.** The milestone act itself:
  everything below the line is delivered; 1.0 is the promise to freeze it. → *Open
  detail §15.*
- [ ] **§19.5d — `bootstrap_check.sh` latency. NOT A BLOCKER; premise was stale.**
  The §19.5d note says "5–10 min observed". Measured 2026-07-28 via the new per-gate
  timing in `tools/gates.sh`: **163–180 s** (~3 min), roughly half the recorded figure.
  It is an optimisation, not a correctness gate, and nothing about 1.0 depends on it.
  Moved off the blocker list in spirit — left here only until someone re-files it under
  tooling.

## Compiler hardening (gated; unattended-safe — deterministic, round-trip-checked)

- [x] **BUG-220 — user function names could collide with preamble internals. FIXED 2026-07-28.**
  Zig forbids a parameter shadowing a file-scope declaration, and top-level `def`s emit at file
  scope, so a user function collided with any of the preamble's 423 non-underscore identifiers:
  `count`, `data`, `total`, `buf`, `body`, `color` — 15 of 16 everyday names tested — failed to
  compile, with the error pointing into preamble source the user never wrote. Top-level defs now
  take the reserved `_zbr_fn_` prefix, finishing the half of BUG-137 (`_zbr_mv_` for module vars)
  that was never done. Selfhost-only; gate `test/toplevel_name_collision_test.zbr`. Residual:
  `@export`/`@node_export` keep their names (the ABI symbol IS the name) — closed only by the
  namespaced-emission design (§ docs/single_file_emit_design.md 1a).
- [x] **BUG-219 — `sys.run` deadlock. FIXED 2026-07-28.** Sequential pipe drain (stdout to EOF,
  then stderr) deadlocked whenever a child filled its stderr buffer — which made `zebra -c` hang
  precisely when a program had errors to report, and that is what the IDE's Check button runs.
  Now delegates to `std.process.run` (concurrent drain via `Io.File.MultiReader`). 4 min → 1.09 s,
  verified against 29.5 KB of child stderr. Same family as BUG-208's noted follow-ups.

- [ ] **Selfhost↔bootstrap divergence burn-down** (`tools/divergence_check.sh`,
  `docs/divergence_audit.md`). New harness (2026-07-18) catches drift the other gates
  can't (they all emit with one compiler). First run: 272 agree-pass, **19 → 17 selfhost
  gaps** after the Build fix (`e5f34d8`). Every remaining gap has a known-good bootstrap
  emit to diff against — a `diff bootstrap-emit vs selfhost-emit → converge` workflow.
  - [x] **All selfhost gaps closed (2026-07-22).** 17 emit-compile D-clusters + the final 3
    post-BUG-181 (string_methods/expressiveness_test/throws_autoprop_test). Every fix diffed
    against the known-good bootstrap emit and gated.
  - [x] **Root fix — unify the stdlib-namespace list (DONE 2026-07-23, `0b11d83`).**
    Extracted `CgHelpers.isStdlibNs` as the single source both `Resolver.isBuiltin` and
    `CodeGen.isStdlibNamespace` consult — the Build-bug drift class can no longer recur.
    Behavior-preserving; all 5 gates green.
  - [x] **GATED (2026-07-22).** `bash tools/divergence_check.sh --gate` exits 1 on any selfhost
    gap; baselined 0. Documented in CLAUDE.md verification-gates. Per-session/pre-release (heavy).
  - Note: **14 BOOTSTRAP gaps** = selfhost LEADS; no fix needed (bootstrap sunsets).
    Full 5-family root-cause triage under "Bootstrap-lags-selfhost convergence" below
    (2026-07-22): pointer/value, `.items`-on-non-list, inference, parser/SIMD, sqlite-binding.
- [x] **GUI builds via selfhost emission (TUI) — DONE 2026-07-26.** `--gui-backend=tui`
  now emits the tui backend and scaffolds/builds the `zig build` project via the
  **selfhost itself** (commits `61a3ffa` Phase 1, `bbc7845` Phase 2, `3ef1e8e` example
  cleanup) — no more bootstrap delegation. Dissolves BUG-204 + BUG-206 for the tui path
  (proven: `examples/tears_of_the_tuon.zbr` builds via `--gui-backend=tui` with all
  workarounds removed). Mechanism: `selfhost/gui_tui_section.zig` (tui backend, read at
  runtime) + `CodeGen.guiSelectPreamble` (substitutes it for the stub section) +
  `main.compileGuiTui` (scaffold + `zig build --build-file` w/ inherited stdio). Gated:
  stub emit byte-identical, bootstrap_check byte-identical, smoke 254/254.
  **libui_ng also ported (2026-07-26, commit `af4d0f3`) AND now works end-to-end
  (2026-07-27).** Same generalized path (`compileGuiProject(zig_path, mode_run, backend)`
  + `gui_libui_ng_section.zig` + `luiBuildZig/Zon`). The former blocker — the upstream
  `zig-libui-ng` dep not compiling under Zig 0.16 (`ui.h` `uiRect` undefined) — is
  resolved by pointing the binding at Sean's consolidated forks:
  `torial/zig-libui-ng@main` (wp base + zig-0.16's sci/scintilla, Zig-0.16 fixes:
  `@intFromBool` on c_int setters, `Separator` alias, 5-arg `OnToggled`) which in turn
  pins `torial/libui-ng@main` (carries the vendored `uiRect` struct from petabyt/libui-dev).
  Both forks consolidated to a single `main` (stale branches deleted, defaults set).
  **Proven portable:** `examples/tears_of_the_tuon.zbr` compiles + links `app.exe` via
  `--gui-backend=libui_ng` from a **cold global cache** (both deps fetched fresh from
  GitHub). The *proven* part is compile + link (the emitted `app.exe` is produced); only
  the `run` step fails — the exe won't launch in this non-interactive shell (exit 57 under
  `zig build run`, 127 when invoked directly from git-bash). Not diagnosed to a root cause;
  most plausibly the lack of an interactive Windows display/session, NOT a build problem.
  Needs a manual interactive run to confirm the window actually shows. Also fixed a latent
  `compileGuiProject` bug: it wrote `build.zig`/`build.zig.zon` only when absent, so a
  stale scaffold silently kept an old dependency pin — now rewritten unconditionally.
  **RUNTIME-VERIFIED 2026-07-27:** counter (`+`/`−`/reset work), the game
  (difficulty screen renders), and — after porting the `CodeEditor` builtin to the
  selfhost — a single Scintilla editor (`examples/editor_min.zbr`: renders + displays
  its `setText` content, Sean-confirmed). See `docs/libui_ng_audit.md` for the full
  claims-vs-verified ledger.
  **IDE: BUG-214 FIXED 2026-07-27 — next step is ONE INTERACTIVE RUN (Sean).**
  The IDE compiles + links + **renders** via `--gui-backend=libui_ng` (all compile gaps
  closed: CodeEditor port `b42074a`, BUG-211 `using`-usage `33571e5`, BUG-213 `SysProcess`
  dispatch `1895d79`), and the click-crash is fixed: BUG-214 emitted a no-payload
  `union(enum)` `Msg` variant as a bare **tag** (`Msg.list_targets`, 1 byte) instead of
  `Msg{ .variant = {} }` (the full union), so the type-erased MVU `g.send(anytype)` copy
  size-mismatched. Fixed selfhost-side, narrowly (only the `send`-on-`Gui` argument
  position — a blanket rewrite is illegal Zig for `==` and would force a bootstrap-parity
  diff; see BUGS.md). All 11 bare IDE sends now convert; new runtime gate
  `test/mvu_mixed_union_test.zbr` (reproduces under the **stub** backend, no display
  needed) is in the smoke suite. Gates green: round-trip byte-identical, smoke 255/255,
  compile_check 215/0/1, divergence 0 selfhost gaps.
  **INTERACTIVE RESULT (Sean, 2026-07-27): THE IDE IS NOW CLICK-STABLE.** Final word after
  the second pass: *"All crashing behavior w/ those buttons is gone."* BUG-214 confirmed
  (buttons dispatch), and the two crashes it had been masking — BUG-215 and BUG-217 —
  are fixed and confirmed in the same session. Nothing ever dispatched before BUG-214, so
  neither downstream crash could have been seen until it was fixed:
  - **BUG-215 (FIXED + confirmed)** — `Check` and `List Targets` aborted: the IDE called
    `str.indexOf(sub, from)`, which is not a real signature (`indexOfFrom` is), and both
    compilers silently dropped the offset → `substring(start > end)` panic. Fixed in the
    IDE *and* guarded in codegen so it cannot recur silently.
  - **BUG-217 (FIXED + confirmed)** — `Build` segfaulted: `SCI_SETTEXT`
    **ignores** the length it is given and calls `strlen()` on the pointer
    (`scintilla/src/Editor.cxx:6190`), but `_code_editor_set_text` used
    `_allocator.dupe`, which produces no terminator. `setText("")` — the first thing
    `Msg.build_start` does — passes a zero-length slice whose `.ptr` is not readable at
    all, hence `Segmentation fault at address 0xffffffffffffffff`. `_CodeEditor` now
    maintains `buf[len] == 0` as an invariant; also fixed a latent one-byte overflow on
    the `SCI_GETTEXTRANGE` read path. **Method note:** the stack trace settled this in
    one round after three hypotheses died guessing — including this one, dismissed
    because the *binding* takes an explicit length (it does, then discards it at the C
    boundary). For any future GUI crash, get `… > log 2>&1` + the top 40 lines FIRST.
  **ALL IDE UNKNOWNS NOW CLOSED (2026-07-27).** The four Scintilla editors **do**
  coexist in one window, and editability behaves exactly as authored: typing works in
  `m.editor`, while the three panes given `setReadOnly(true)` in `ideInit`
  (diag/output/buildOutput) correctly reject input — Sean confirmed the one-editable-
  pane behavior and correctly attributed it to read-only mode. `examples/editor_min.zbr`
  was also re-run post-BUG-217, re-earning the marker it held under the buggy code.
  **The IDE is END-TO-END RUN-VERIFIED**: builds, links, renders, dispatches, survives
  every toolbar button, and hosts four coexisting Scintilla controls.
  **What remains is UNBUILT, not broken** — syntax highlighting (`forZebra` falls back
  to plain; no lexer wired), `setErrorMarkers` (no-op stub), the column half of
  `setCursorPosition`, and any Table/Tree widget for a file explorer. Those are the
  next IDE features whenever the IDE comes back up the queue.
  NOTE: use `bash tools/bootstrap_check.sh --update` DIRECTLY to
  regen after `.zbr` edits — `zig build update-selfhost` silently skips (BUG-210).
  **Housekeeping surfaced by BUG-214:** the checked-in `examples/*.zig` artifacts are
  stale — regenerating `examples/counter.zig` produced ~1400 lines of pre-existing
  preamble drift on top of the 3 lines BUG-214 actually changed, so it was left alone
  rather than burying the fix. Regenerate the `examples/` artifacts as a standalone
  cleanup commit (or decide they should be gitignored like `selfhost/*.zig` is not).
  **Remaining (follow-ups, not blocking):** (a) `compileGuiProject` copies only the root
  emitted `.zig` — multi-module GUI apps still need dep `.zig` files copied into the
  scaffold (single-file / no-dep GUI apps like the game work now; residual "GUI
  module-resolution" limit). (b) **only glfw** still delegates to the bootstrap (same recipe
  to port when wanted: extract its arm from `src/CodeGen.zig`, add a section file +
  build template + backend name to `gui_selfhost`). (c) `--gui-backend=stub` explicit still
  delegates (plain `zebra run` already emits stub via the selfhost).
- [ ] ~~**GUI builds via selfhost emission — phase the bootstrap out of the GUI path**~~
  (epic; scoped 2026-07-25, scoped TUI-only). Today
  `--gui-backend=*` delegates the WHOLE build to `zebra-bootstrap.exe`, so bootstrap-lags-
  selfhost gaps BLOCK GUI/TUI apps even though the primary/selfhost compiler accepts the code —
  found porting `examples/tears_of_the_tuon.zbr` (BUG-204 return-position `except`, BUG-206
  `.toInt()`-on-float, GUI module-resolution all bite here). **Payoff: dissolves BUG-204 +
  BUG-206 + GUI module-resolution at once**, phases the bootstrap out of the GUI path (endgame).
  **Decision (Sean 2026-07-25): the right fix; do NOT do bootstrap grammar surgery for BUG-204.
  Scope TUI-only (defer imgui/libui_ng). Mechanical copy into the selfhost — do NOT refactor the
  sunsetting bootstrap (its GUI copy dies with it). Do it as a fresh, gated, phased effort.**
  - **Corrected scope (was mis-estimated as ~160 lines / "focused session"):** ~500 lines
    TUI-only, ~2000 all-backends. The scaffold driver was only half. **The real work + risk:**
    the selfhost gets its GUI backend from the preamble file UNCONDITIONALLY (always **stub** —
    `selfhost/stdlib_preamble.zig`, `_gui_active_backend` between the STDLIB_PREAMBLE_GUI markers;
    the selfhost reads the whole file, the bootstrap keeps the section inline in CodeGen with a
    `switch(gui_backend)`). To emit tui *instead*, stub must become codegen-**selected** — split
    the stub block out of the shared preamble, gate on `gui_backend`. This restructures a path
    every GUI-stub test depends on: it **MUST stay byte-identical for the stub case** or
    `bootstrap_check` breaks + every GUI stub test shifts. That gate-holding restructure is the
    crux, NOT the tui glue (static strings — mechanical copy, watch CRLF/escaping in `.zbr`).
  - **Reference map (bootstrap side, to copy/mirror):** backend `switch(g.gui_backend)` =
    `src/CodeGen.zig:3061-4683` (stub 3062-3234, imgui ~3234-3835, **tui 3841-4114**, libui
    4124-4683; each arm ends `const _gui_active_backend = _gui_<x>_backend`). Scaffold =
    `compileGuiProject` `src/main.zig:1348-1417`; build.zig/.zon templates `1188-1300`
    (tui template `1254-1300`). Selfhost currently: parses `gui_backend` (`selfhost/main.zbr:2094`)
    only to delegate (`~2320`); CodeGen emits `_gui_active_backend.*` CALLS but has NO
    `gui_backend` field/param (never threaded).
  - [x] **Phase 1 DONE 2026-07-25 (commit `61a3ffa`, gated).** Threaded `gui_backend` through
    the pipeline (`main` → `setGuiBackend` → `_gui_backend` var in CodeGen, mirroring
    `setSingleFile`) and routed every preamble-append site through `guiSelectPreamble`, which
    splits on the STDLIB_PREAMBLE_GUI markers so codegen picks the backend. **Refinement vs the
    original plan:** stub stays SOURCED FROM the preamble file (split-then-reassemble = verbatim),
    NOT extracted into codegen strings — so stub is byte-identical by construction (lower risk).
    Verified: counter (GUI stub) + a plain program emit byte-identical to pre-change;
    bootstrap_check byte-identical; smoke 254/254.
  - [~] **Phase 2 — core mechanism VALIDATED 2026-07-25; delivery+scaffold+routing remain.**
    **Validated (the make-or-break unknown):** grafting the bootstrap's tui GUI section into a
    *selfhost* emit (selfhost preGui + bootstrap tui-section + selfhost postGui) COMPILES + links
    with zigzag (`zig build` exit 0). So the selfhost preamble is compatible with the bootstrap's
    tui glue; the ~20-line stub-vs-preamble divergence is confined to the GUI section (replaced
    wholesale for tui) and is irrelevant. **tui section extraction (reproducible):** emit any GUI
    program with the bootstrap twice — `zebra-bootstrap.exe --emit-zig g.zbr` (stub) and
    `--gui-backend=tui --emit-zig g.zbr` (tui); the tui GUI section = the tui emit's text from
    `// ─── GUI: backend isolation` through `const _gui_active_backend: _GuiBackend =
    _gui_tui_backend;` (~508 lines / 26 KB; contains the sole `@import("zigzag")`; no `"""`).
    **`guiSelectPreamble` tui branch (validated shape):** for `_gui_backend=="tui"`, return
    `preamble[0..siEnd] + "\n" + <tui-section> + preamble[aeEnd..]` where `si`=STDLIB_PREAMBLE_GUI_START
    marker, `ae`=`const _gui_active_backend … = _gui_stub_backend;` (ASCII-stable anchors). **NOT
    byte-identical to the bootstrap is fine** — tui isn't in the divergence corpus; it only needs
    to build+run. **Remaining:** (a) deliver the tui section — file `selfhost/gui_tui_section.zig`
    read at runtime (resolve like `preamble_path`, install next to exe in build.zig) is cleaner
    than a 508-line embed [triple-quoted `"""` works but bloats CodeGen]; (b) port the
    scaffold+zig-build driver (`compileGuiProject` `src/main.zig:1348-1417`, uses `.stdout=.inherit`
    already) + the tui build.zig/.zon templates (`src/main.zig:1254-1300`) into `selfhost/main.zbr`;
    (c) route `--gui-backend=tui` through emit-then-scaffold instead of delegating (`selfhost/main.zbr`
    ~2320). **Acceptance: `zebra --gui-backend=tui examples/tears_of_the_tuon.zbr` builds + runs the
    game WITHOUT the BUG-204/206 workarounds (revert those in the example to prove it);
    bootstrap_check + smoke green.**
- [ ] **Grow the fuzzer's `DEFAULT_CAPS`** (`fuzz/gen.py`) — highest-leverage
  correctness lever (risk surface is combinatorial; see `docs/COVERAGE_MAP.md`).
  Remaining caps need class-relationship generation: (4) `^T` boxing,
  (5) interfaces + `is`, (6) generics / backed-enums / chained-cmp. → *Open detail,
  Fuzzer.*
- [ ] Grow fuzzer grammar surfaces (generics, error/throws, branch/enum); run
  `fuzz/run.py --run` batches when free RAM allows (small batches under memory
  pressure).
- [~] **Bootstrap-lags-selfhost convergence** (bootstrap is the regen authority;
  selfhost is ahead — converge only where the round-trip needs it):
  - **RECOMMENDATION (2026-07-22): do NOT chase these as a batch.** Full triage below shows
    the 14 span 5 codegen surfaces (not one bug), most triggered by escape-hatch/niche
    constructs (`zig"…"` raw literals, `f32x8`, generic-fn syntax), and all require porting
    selfhost codegen *back into the sunsetting bootstrap* — against the roadmap's "don't do
    sizable ports into the phasing-out bootstrap." Witness value is real but bounded: for all
    14 the selfhost output is already known-correct (compiles + smoke-passes), so there is no
    silent blind spot today — only a degraded reference for *future* changes in those (stable)
    areas. Fix opportunistically if one blocks the round-trip; otherwise leave until/unless
    the bootstrap's Phase-2 (single-file witness) work reopens it.
  - **Triage map — 14 bootstrap gaps → 5 root-cause families (divergence_check, 2026-07-22):**
    - **(A) pointer/value confusion (~6, dominant):** `greet`/`with_test`/`features`/
      `selfhost_probe5` emit `*T = T{}` (declared `*T`, init value); `pratt_calc`/`lambda_calc`
      the inverse (`T` vs `*T`). Trigger: explicit class-type local + `zig"T{}"` raw-literal
      init. Bootstrap's pointer-vs-value / `^T`-box decision is diffuse (no single guard) —
      this is the `^T`-boxing class the fuzzer notes flag as hard. Sizable.
    - **(B) spurious `.items` on non-list (~3):** `list_iter` (`.items` on `[]i64` slice),
      `hashmap_init_patterns_test` (`.items` on HashMap), `bug177_178_index_tostring_test`
      (nested `g.items[0][1]` — inner needs `.items`). Container-shape tracking lag.
    - **(C) inference/TC lag (~2):** `lisp` (`expected float, got Value`), `sort_test`
      (indexing empty slice).
    - **(D) parser/feature gaps — EMITFAIL (~2, deepest):** `generic_fn_test` (bootstrap
      parser: `syntax error near '('` on generic-fn syntax), `simd_test` (`f32x8` not
      defined — known niche).
    - **(E) stdlib-binding lag (~1):** `sqlite_test` (`asInt` missing on `_SqliteRow`).
  - [ ] **BUG-180 (new 2026-07-14)** — bootstrap drops omitted ctor defaults on emit
    (`Vector3()` → `Vector3.init()`); selfhost fills them. Workaround: spell ctor
    args out. → `BUGS.md`.
  - [ ] `for x in <as-bound List>` → `.items` (low value now — bootstrap phasing out; family B).
  - [ ] `zig"…"` ref-analysis (count idents used inside zig-literals; no spurious `_ = v;`).
  - [ ] Reconcile explicit `: void` parse divergence (bootstrap `.named "void"` vs
    selfhost `.void_`).
  - [ ] BUG-147 (3 bootstrap lisp-emit divergences); BUG-149 (`.len` on a local-map `fetch`).
- [ ] Audit/regenerate stale engine-style `.zig` with the converged bootstrap
  (`pathfinding.zig` was stale; others likely are); add a numeric-conversion
  compiler test; correct QUICKSTART §21.
- [x] Run full `compile_check.sh` corpus (JOBS-paced) + triage regressions. **DONE
  2026-07-16: 198 passed / 0 FAILED / 3 skipped (selfhost, JOBS=3)** — the §28a step-2
  changes introduced no emitted-Zig regressions. `compile_check` is the *independent
  witness* the round-trip lacks (round-trip diffs the selfhost against itself → blind to
  wrong-but-compiling output AND to programs it never compiles; `compile_check` runs
  `zig build-exe` on emitted corpus programs). **Recommend gating it** (per-commit or at
  least per-session) — it is currently a manual tool, so the coverage-blindness it closes
  is only closed on the days someone remembers to run it. Cost: a few min at JOBS=3.
- [ ] **⚠️ 1.0 BLOCKER — emit-compile triage campaign** → **`docs/emit_compile_triage.md`**.
  > **RE-SWEPT + GATED 2026-07-24** (`docs/full_sweep_triage.md`, `tools/full_sweep.sh`).
  > Full 403-file re-sweep: **328 PASS, 0 regressions, 0 NEW bugs** — every remaining
  > CFAIL/EMITFAIL is a negative test, library module, interop-needs-libs, multi-module,
  > or a KNOWN item in this campaign's backlog. Fixed 3 stale tests (removed syntax) en
  > route. The corpus is now gate-able: `full_sweep.sh --gate` fails on regression vs a
  > 328-test baseline (no skip-list needed). The codegen backlog below is unchanged — the
  > sweep confirmed the state rather than finding new work.
  A full-corpus independent-witness sweep (all 399 `test/`+`examples/` `.zbr`, not just the
  ~201 smoke-registered) found **52 standalone-compile FAILs**: ~11 negative/harness, and
  **~30 genuine codegen/type miscompiles on current constructs**, clustered into ~15–20 root
  causes (undeclared-type-not-emitted `Http`/`CsvWriter`; syntax errors in emitted Zig `json`;
  `.len`-on-ArrayList `dns`; `^T`-box `*T`-vs-`T`; BUG-182-class mis-typed-receiver dispatch;
  one GUI `param shadows 'init'` bug covering ~6 files). BUG-182 was the tip. Campaign: verify
  real-vs-stale per cluster, fix by root cause (~15–20 fixes clear ~30 files), gate
  `compile_check` over the triaged-clean corpus so it can't regrow, prune stale tests. Found
  2026-07-16 by casting the witness wider than the curated smoke set.
  - [ ] **Follow-up (D7 residual) — closure local over-marked `var`.** BUG-191 (2026-07-17, two
    rounds) made the `var`/`const` scan type-driven for value + by-value-handle receivers
    (immutable str/primitives → never `var`; json/tcp/ws/udp/sqlite/regex → `const` unless an
    explicit mutator; optional/`^T` unwrapped), killing the `never mutated` class corpus-wide.
    The ONE remaining `never mutated` (in `gui_test`) is NOT a scanMutations case: `frame` is a
    **closure** (`var frame = def(g)…`) passed by value to `Gui.run`, marked `var` by closure
    lowering because the closure body mutates a captured var — yet `frame` itself is copied into a
    heap slot and never mutated locally. Fix lives in the closure/lambda codegen (emit the closure
    temp `const` when it is only passed by value and never locally re-invoked with mutation), not
    in `scanMutations`. Low priority: 1 file, which also fails on an unrelated
    `GuiContext has no member 'run'`. NOTE: a measured corpus scan found **no** named-struct-getter
    `never mutated` case, so the earlier "per-method struct mutation map" idea is unnecessary —
    structs correctly stay on the name-based fallback.
- [ ] **§24e — single method-descriptor table** (stdlib method registration touches
  4 places). Deferred post-1.0, but §28a raised its priority (it converts four
  heuristic dispatch surfaces into one spec). → *Post-1.0 §24e.*
- [ ] **Single-file emission — codegen architecture** [Phase 1 (single-module, both compilers)
  + §7b Phase 2 (multi-module merge, **selfhost**) + Phase 4 (edge-case parity + node-addon
  hardening) LANDED 2026-07-21, behind default-off `--single-file`. **F5 closed**;
  `compile_check.sh --single-file` = 200/0/1 == multi-file baseline; round-trip byte-identical;
  smoke 236/236. **BUG-181 RESOLVED 2026-07-22 → Phase 5 UNBLOCKED** (the combined selfhost/main.zig
  now COMPILES). **Phase 5/6 DE-SCOPED (2026-07-22, `docs/regen_authority_decision.md`):** keep
  the bootstrap as the independent multi-file regen authority (the trusting-trust witness that
  caught BUG-181); do NOT make the selfhost sole authority, do NOT add single-file to the
  bootstrap now. Single-file stays a shipped feature (default-off), gated by
  `tools/selfcompile_check.sh`. Revisit post-1.0 (freeze bootstrap) or if the 9-file burden bites
  (then bootstrap Phase 2 is the correct route). **Feature complete for now.**]

- [x] **Convergence sweep: 3 selfhost gaps — ALL CLOSED (2026-07-22).** The post-BUG-181
  `divergence_check.sh` found 3 selfhost-lags-bootstrap gaps; all fixed + gated (200/0/1 +
  round-trip each): `string_methods` (indexOf→int, `37873e8`); `expressiveness_test`
  (named-args/defaults in user-method calls + string-repeat codegen + inference, `3fe5630`);
  `throws_autoprop_test` (try-block catch-wiring in the user-method early-exit). **Two of the three
  shared ONE root:** genMemberCall's "general user-method early-exit" (~11620) emitted args
  positionally and returned before the default path's named-arg/default AND try-block-catch handling
  — so both named-args/defaults and throws-in-try were silently wrong for user-method calls (a
  high-impact class: any program using default params, named args, or throws-in-try on a user
  method). Confirmed: `divergence_check.sh` now reports **0 selfhost gaps** (292 agree-pass · 46
  agree-fail negatives · 18 no-main libraries; 14 bootstrap-lags-selfhost gaps remain — secondary
  witness-quality item, tracked separately). Original triage below (kept):

  <details><summary>Original 2-gap triage (2026-07-22)</summary>
  - **`expressiveness_test` — named args + default params in METHOD calls.** `g.greet(name: "Alice")`
    (default `greeting`) emits `g.greet("Alice")` (1 arg, no default); reordered
    `g.greet(greeting: "Hi", name: "Carol")` emits source-order `g.greet("Hi", "Carol")`. Root: in
    genMemberCall, `mc_params` is nil because `inferExpr(g)` doesn't resolve an EXPLICITLY-typed local
    (`var g: Greeter = Greeter()`) to `named("Greeter")` (or `lookupFnParams("Greeter.greet")` is
    empty) — so neither the legacy reorder path NOR a `genArgListFull` delegation can fire. FIX =
    make the receiver's class resolve (bind explicitly-typed locals in infer_ctx / register method
    params) THEN delegate the has-named/needs-fill case to `genArgListFull` (the correct algo the
    constructor path already uses; a guarded delegation was drafted + reverted pending the inference
    fix). The bootstrap handles all of this. Connects to §28a inference.
  - **`throws_autoprop_test` — a bare `throws` call in a try-block.** `.outer()` (throws, no `?`) inside
    a method-level `catch` emits bare `self.outer();` → "error union is ignored". `.inner()?` (explicit)
    works, so throws DETECTION is fine; the try-block CATCH-wiring at genMemberCall ~12950
    (`callee_throws2 and try_block_label != nil`) doesn't fire for `.outer()` despite both conditions
    appearing set — a context bug (couldn't pin statically; needs instrumentation). The bootstrap does
    this at the STATEMENT level (src/CodeGen.zig genStmt ~6843: `e is call and try_block_label and
    exprCallIsThrows`) — mirroring that (statement-level catch) is the likely clean convergence, but
    verify it doesn't double-emit with the existing 12950 path.
  </details>
  (Resolution note: fixed instead in the user-method early-exit, which was the real path both
  gaps flowed through — see the closed entry above.)

- [x] **Grammar fuzzer (generative)** [idea Sean 2026-07-22 → BUILT 2026-07-23]. `fuzz/gramgen.py`:
  coverage-guided CFG derivation from `grammar.txt` (production choice weighted 1/(1+times_used) →
  94% production coverage over 200 programs), stateful indent/dedent renderer, plugs into the
  existing `harness.check(zig_check=False)` oracle. Complements `gen.py` (semantic) by attacking the
  front-end accept/reject space directly. **First runs paid off immediately:** found **BUG-199** (an
  18-byte selfhost parser INFINITE LOOP, `readonly struct b` — now FIXED + gated), plus lower-signal
  divergences (G2 empty-body decl leniency, G3 size-type alias resolution, G4 misc) and a dead
  grammar rule (`ValueArg*`). Findings in `fuzz/FINDINGS.md` (G-series). Note on "Earley": generation
  is CFG *derivation* (no parsing algorithm needed); Earley matters only for the inverse.
  - [ ] **Follow-ups (optional):** address G2 (selfhost accepts body-less `struct`/`extend`);
    dead-rule cleanup in `grammar.txt`; add a front-end-only oracle mode (parse/`--check` rather
    than full `--emit-zig`) so resolver/TC divergences aren't swamped by legit "undefined name"
    rejections; consider gating a fixed-seed gramgen batch (assert no crashes/hangs) per session.

- [ ] **`indexOf` nil-safe API (principled `int?`)** [deferred 2026-07-22, Sean's call: revisit
  during hands-on language testing]. `str.indexOf`/`lastIndexOf` currently return `int` with a `-1`
  sentinel (matches the reference bootstrap + `main.zbr` usage; the documented `int?` was never
  implemented — the codegen always emitted `i64`). The nil-safe `int?` (nil-not-found) fits the
  language's Eiffel-style **nil-tracking** pillar and is the preferred long-term shape. Doing it is
  a deliberate cross-compiler change: type `int?` + emit `?i64` in BOTH compilers, and fix
  `main.zbr`'s `indexOf(" ") + 1` (→ `!`/guard). `indexOfFrom`/`indexOfIgnoreCase` already return
  `int?` (do them too for consistency). Not incidental convergence work — its own small task.
  Emit all Zebra modules into **one** `.zig` file, each wrapped in a namespace `struct`, with
  **one** shared runtime preamble at file scope (today: one file *per module*, each inlining the
  full ~3712-line preamble). Wins: dissolves the **F5** name-collision class for free (namespaced
  user decls leave file scope, so preamble internals can't shadow them), emits the preamble once
  (the ~9-module selfhost compiles ~9 copies today), and **deletes** the cross-module
  `_initAllocator`/`_initIo`/`_zbr_error_msg` fan-out (`main.zig` hand-wires it for 8 modules).
  **Justification is architecture + F5-closure + simplification, NOT speed** — the spike measured
  the compile-time win as modest (~12 ms/preamble-copy frontend; Sema win real but unmeasurable in
  noise). Prototype compiled + ran; cross-module `use`, bare outward preamble resolution, and F5
  dissolution all verified. Real project: both emitters kept equivalent, round-trip goes
  single-artifact, phased behind a temporary `--single-file` flag. **Supervised, careful, gated.**
  → *Design + phased plan: `docs/single_file_emit_design.md`.* Supersedes the bespoke F5 fix.

## Dogfood programs (IO + net + threads — surface stdlib/runtime gaps; each self-verifies)

BUG-153 (module-global shared state) is fixed, so shared-state servers are
unblocked. The two-tier allocator wiring (§28j) is the remaining concurrency
foundation and needs a supervised session.

- [x] **§28j — thread-safe program allocator DONE (2026-07-24, `b5d1726`).** Shipped the
  ThreadSafeAllocator-wrapper approach (NOT per-thread arenas — that over-scoped it): a
  mutex around the shared arena (`_TsAlloc`/`_prog_alloc` in the preamble + bootstrap),
  `--single-threaded` flag → `-fsingle-threaded` (compiles the wrapper out; thread-spawn
  becomes a compile error). Validated by `thread_alloc_stress_test`. **Residual (post-1.0):**
  `allocate Arena()` scopes swap the global `_allocator` and race with workers (77% crash,
  captured by `arena_concurrency_hazard_test`) → rule: allocate-scopes are single-threaded-
  only. See `docs/concurrency_allocation_design.md`. Below = the ORIGINAL (superseded) plan.
- [ ] **§28j step b — two-tier allocator wiring** (per-thread arenas + a shared
  `Smp()` handle). Race is confirmed-in-code but latent-at-runtime; the fix is
  subtle with concurrency-lifetime failure modes the gates can't catch → supervised
  session, decide the shared-handle API first. → *Open detail §28j.*
- [ ] Concurrent web fetcher / link checker (worker threads pull URLs from a `Chan`,
  HTTP GET, aggregate).
- [ ] Parallel log-processing pipeline (`Dir`/`File` walk → workers → merged histogram).
- [ ] Multithreaded Mandelbrot / ray tracer → PPM (compute fan-out + binary IO).
- [ ] Pub/sub or LAN chat broker (TCP + client threads + `Chan` broadcast).
- [ ] MapReduce word-count over the Greek NT / a large corpus (threads + IO + Unicode).
- [ ] Tiny HTTP JSON API persisted to SQLite + a concurrent client smoke test.
- [ ] **§9 — Greek NT n-gram port** (SIMD landed, the deferred-wait is over): file
  I/O, Unicode `HashMap` keys, sort, sliding n-gram window, TF-IDF / cosine via
  `f32x8`. → *Open detail §9.*

## Tooling & LSP polish (mostly post-1.0 ergonomics)

- [ ] **LSP follow-ups** (epic is Phases 1–4h done; see Completed-recent): scope-aware
  locals / shadowing / cross-file resolution; per-document-VERSION parse cache
  (blocked only by AST/arena lifetime, not concurrency); member-completion dedup;
  VS Code click-test + `.vsix` package/publish.
- [ ] **Formatter re-indent** to canonical 4-space nesting (needs INDENT/DEDENT +
  continuation handling; natural follow-on now the string-safe scanner exists).
- [ ] **IDE** — advance one stalled ZebraIDE experiment (tree widget / Debug button
  DAP client via `zebra debug --listen PORT`); install LLDB on Windows to test the
  debugger end-to-end.
- [ ] **N-API follow-ups** — cross-platform `.node` (Linux undefined-symbol default;
  macOS `-undefined dynamic_lookup`) + doc; richer `test/node_addon` matrix.

## Environment / repo cleanup (safe, unattended)

- [ ] Prune the stale session task list to the genuinely-open few.
- [ ] **Wiki sync** — N-API, First Horseman, bootstrap convergence, the GameEngine
  boss-move layer → `project_zebra.md`; lint dates.
- [ ] Tidy scratchpad repros into `examples/` or delete.

---

# Open — detail

## §15 — 1.0: language stability + CHANGELOG (cumulative commitment)

1.0 is the **full API surface delivered through all prior 0.x milestones, locked
with a stability promise.** Everything in the checklist below is delivered; the
open act is the *freeze* + a final CHANGELOG pass.

**Stability commitment — 1.0 must have all of (all ✅ delivered):**
- ✅ Generics (0.8); Contracts (`require`/`ensure`/`invariant`/`old`/`result`/`--turbo`, 0.12)
- ✅ All stdlib through 0.4–0.15 (Math, Json, DateTime, CSV, Hash, Random, Arg,
  Terminal, Log, Uri, Compress, Mime, Timer, Regex, Http, Tcp, Udp, Net, File, sys,
  Gui, Reflect, Path, Profile, SIMD, SQLite, WebSocket, ThreadPool, Atomic, …)
- ✅ Self-hosting + bootstrap round-trip (Phase 22); source-mapped errors (0.5)
- ✅ 0.11 (REPL, JSON auto-inference, gzip, debugger/DAP, build system); 0.13
  (BUG-115, `^T` fixes); 0.14 (full `<-` deep-copy, `Chan(T)`, allocator context);
  0.15 (syntax cleanup, stdlib completeness, libui-ng); `--target node-addon`
- ~~regex per-quantifier~~ → post-1.0 (§7)

**Open:** the stability freeze itself + a final CHANGELOG reconciliation pass over
the 0.1 → 1.0 surface (CHANGELOG.md exists as of 2026-05-26; re-verify it covers
everything since).

## §28a — inference-or-error rule (step 4 open) [ADOPTED — Sean 2026-07-03]

No typed-dispatch site may guess: if inference is empty, emit a diagnostic, not a
guessed emit. Steps 1–3 done (instrumentation → closed every corpus inference gap →
`check_inference_guess.sh` gate, corpus at 0). **Step 4 open:** the language-level
flip — a residual guess becomes a "cannot infer type of X; annotate" compile error.
Systemic fix for the F7/BUG-162/BUG-168 class. Raises the priority of §24e.

**Spike findings (2026-07-15) — scope decided [Sean: "flip the selfhost if it guesses"]:**
The guess INSTRUMENTATION + gate are **bootstrap-only** (bootstrap sites:
`src/CodeGen.zig` ~7503 list_dispatch, ~7562 len_count, ~16196 add; `noteInferenceGuess`
+ `warn_inference_guess`). But the **selfhost guesses too** — `genBinary` add
(`selfhost/CodeGen.zbr:8818`) does `if isStringBoth(l/r) → _str_concat; else → numeric +`,
so an un-inferable operand silently defaults to numeric `+` (the same F7/BUG-168
fallback). `isPrimType` (just below `isStringBoth`) is the "proven-prim" check the gate
needs. The other two selfhost sites (len/count, List-method routing) share the shape.
On the corpus the guess is always *correct* (smoke 236/236, round-trip byte-identical)
but **ungated** — so the flip = add the `isPrimType` gate and turn "neither string nor
proven-prim" into an error.

**This is the §28a campaign re-run on the selfhost (not a one-shot). Measure-first,
per §28a's own discipline.**

**Phase 1 (measure) — DONE 2026-07-15.** Instrumented the 3 selfhost guess sites
(`selfhost/CodeGen.zbr`: `add` ~8874, `len_count` ~8315, `list_dispatch` ~10950),
recording unconditionally via the §28b `_implicit_try_sites` mechanism; reported under
`--warn-inference-guess` (behavior-neutral, no exit). Tool: `tools/measure_selfhost_guess.sh`.

**Result: 80 unique sites** in `selfhost/*.zbr` (add 6, len_count 30, list_dispatch 44;
60 in `CodeGen.zbr`) — **NOT 0**, so not "flip freely". BUT triage found **~zero genuine
ambiguity** — every sampled site emits CORRECT code. Two causes:
1. *Non-guesses the instrumentation over-flags* — user-class field/method on an un-inferred
   receiver: `StrSet.len` (a real `var len: int` field), `args.contains()` (`args = Arg.parse()`,
   a user `Arg` method). ~15 of 44 list_dispatch are `args.contains` alone.
2. *Benign under-inference* — e.g. `(l.len - t.len) + kw.len` is int arithmetic flagged only
   because `inferExpr` doesn't type `.len` → int; `x = c.items(); x.at(i)` routes right by name
   because the `.items()` return type isn't propagated.

**Why ≠ bootstrap (which reached 0 standalone):** the bootstrap consults a global per-expr
type map (`tc.expr_types.get(e)`); the selfhost `InferCtx` has only `scope: HashMap(str,Type_)`
+ on-demand `inferExpr`, which returns `unknown_` for `.len`, call-returns, user-class fields.
No per-expr map exists → precision = strengthening inference, not a lookup.

**Decision (Sean 2026-07-15): land Phase 1 record-only, then step 2, then flip.** NOT the
scope-down (bootstrap gate already provides the user-facing guarantee at 0) and NOT a rush to
flip (would convert ~80 benign under-inferences into false errors).

**Step 2 (in progress) — close the inference root causes**, re-measuring toward 0.
Measurable selfhost/* count (excl. main.zbr/pipeline_test, BUG-181): started **add 6 /
len_count 30 / list_dispatch 27**.

Done (2026-07-15/16):
- ✅ **`inferExpr(.len / .count())` → int** (commit 5c78c17) — `add` bucket 6 → 0. Also
  covers `inferExpr(arith of prims)` since the existing binary handler already propagated
  numeric; the only gap was `.len` not being numeric.
- ✅ **`len_count` guard → `typeIsUnknown`** (commit 9204a0b) — 30 → 18. Dropped proven-receiver
  false positives (StrSet-param `.len` field reads were never ambiguous). Emit-neutral.
- ✅ **StrSet method returns on param/field receivers** (commit 04231dc) — **a real latent
  selfhost MISCOMPILE**, not a benign guess. `StrSet` has a dedicated `Type_.str_set` variant,
  so a param/field typed `StrSet` infers to `str_set` (a `StrSet()` ctor infers to
  `named("StrSet")` and worked); the call handler had no `str_set` arm, so `strset.items()`
  was unresolved and the result local emitted `.len` (string-shaped) — WRONG on an ArrayList
  (`no field named 'len'`). Hidden because the committed `.zig` is bootstrap-generated and the
  round-trip shares the same (wrong) inference on both sides. Added a `str_set` arm
  (`items()`→List(str), `contains_()`→bool). A probe that miscompiled now compiles+runs.
  Cleared the whole CodeGen cluster: len_count 18 → 9, list_dispatch 27 → 18.
  **Precision caveat (2026-07-16, not overclaiming severity):** `StrSet` is *compiler-internal*
  (not user-facing), so this miscompile's blast radius is narrow — it can only appear in
  selfhost code, and the compiler-source usages that would trigger it are mostly guarded by
  `localIsList`-style tracking (which is why the round-trip's A/B builds passed with the bug
  present — the pattern wasn't hit in a breaking form in the compiled path). It is a REAL
  latent miscompile (the probe proves it) and the fix is correct, but it is not a user-facing
  crisis. **The generalizable thread was hunted (2026-07-16) and the class is now BOUNDED:** of
  the 4 dedicated-`Type_` variants with no `inferExpr` call-handler arm (`str_slice`,
  `allocator_ctx`, `sqlite_row_list`, `gui_context`), only **`sqlite_row_list` was a real
  user-facing bug** → **BUG-182** (`db.query(...).at(i)` result untyped → `.asInt`/`.asStr`
  miscompile), fixed in the selfhost. `gui_context` is safe (its value-returners are primitives,
  no struct-dispatch hazard), `str_slice` is a handled sentinel, `allocator_ctx` is internal.
  The hazard requires a *struct-returning* method whose result loses its type; primitive-returners
  don't trip it. Found via the independent witness (`compile_check`), not the corpus.

**This overturns the Phase-1 "~0 genuine ambiguity / emit always correct" read:** for the
selfhost's OWN emit the guesses were producing wrong code; only bootstrap regen masked it.
§28a is fixing real latent miscompiles on the road to selfhost-as-regen-authority, not just
tidying benign guesses.

**⚠️ SCOPE CORRECTION (2026-07-16 full-corpus measure).** The per-file iteration above measured
only NON-`main` selfhost source. The authoritative full-corpus measure (420 files, per-file
timeout) was **143 unique sites: add 40 / len_count 30 / list_dispatch 73** → now **140 (add 37 /
len_count 30 / list_dispatch 73)** after the typed-lambda fix. So "add bucket → 0" holds ONLY for
the non-`main` compiler files; corpus-wide much remains. Distribution: lexer_test 33,
test/csv_test 24, `main.zbr` 19, test/list_functional 10, Parser 9, AstBuilder 5, +~30 other test/
files, examples/life 4. Root-cause patterns still open:
- ✅ **Typed lambda params** (commit c9c85f9) — `genLambdaEx` now seeds a fresh InferCtx with
  the lambda's DECLARED param types (mirroring genMethod), used for BOTH the `@TypeOf(body)`
  return-type inference and the body. `def(x: int) = x + x` / `def(acc: int, x: int) = acc + x`
  no longer guess. Round-trip byte-identical, smoke 236/236. **Corpus delta: 143 → 140 (add 40 →
  37) — only 3 sites, because the corpus lambda-`add` guesses are dominated by UNTYPED functional-
  trio lambdas (below).** Value is the seeding INFRASTRUCTURE the untyped work builds on, not the
  raw count.
- **Untyped functional-trio lambda params** (the remaining `add` driver): `def(acc, x) = acc + x`,
  `def(x) = x * 2` — params carry no declared type, so they bind unknown and still guess. Their
  types must be DERIVED from the higher-order fn's signature: for `nums.reduce(0, def(acc,x)=…)`
  with `nums: List(E)`, `acc` = init's type, `x` = `E`; for `map`/`filter`, `x` = `E`. Needs
  call-site→lambda param-type plumbing (the reduce/map/filter codegen passes derived types into
  `genLambdaEx`), method-specific — moderate risk, a supervised session. Affects list_functional /
  csv / many tests.
- **Cross-module STATIC returns** (`toks = Lexer.tokenize()` on a module name → unknown) —
  lexer_test cluster (~23). Module-static method-return resolution across deps; helps user
  `Module.staticFn()` too.
- **`main.zbr`'s own 19 sites** (2 add: 755/1113; 17 list_dispatch: the `args.contains` /
  `Arg.parse()` cluster — `Arg.parse()` return type not propagated). Never measured pre-fix
  (main.zbr didn't finish compiling; see BUG-181, now ~6s).
- 2 known-hard singletons (flow-sensitive `var a2=a` reassignment; cur_line noise).

NON-main compiler source IS essentially cleared (0/9/18 on those files) and a real miscompile
was fixed — but the flip (step 3) is NOT close corpus-wide; the lambda-param feature is the
largest remaining lever. Re-assess scope with Sean.

**BUG-181 RESOLVED (2026-07-22):** `main.zbr` now self-compiles cleanly (emit rc=0, emitted Zig
builds; proven end-to-end — the self-made 2.3MB compiler compiles a program that runs). 8 emit
divergences fixed, gated by `tools/selfcompile_check.sh`. The §28a-step-4 CONSTRAINT below (main.zbr
can't be in the both-compilers-reject probe) is now LIFTED. See BUGS.md BUG-181.

**Step 3 (the flip) — only once the selfhost standalone count is ~0.** Error + `--allow-inference-guess`
hatch + promote the measure to an enforcing gate. Follow the §28b template (commit 0a591ce):
module-global sites list, driver-level reject in `main.zbr` (NOT `@compileError` — malforms
expression-position sites), `cur_line` on the shared Writer for the location. **The round-trip
won't catch selfhost-vs-bootstrap divergence** — the flip acts as a differential probe (§28b
caught `Parser.zbr:3164`). CONSTRAINT: `main.zbr` can't be part of the both-compilers-reject
validation — the selfhost can't compile it (BUG-181).

Also consider (Sean, if bootstrap kept longer): flip the bootstrap's 3 sites too
(mirror §28b's `rejectImplicitTry`) for user-code parity — low-risk, marginal value
(bootstrap phasing out; divergence is bootstrap-conservative = safe direction).

## §28b — unify error propagation on always-explicit `?` ✅ DONE (step 5 flipped 2026-07-15)

All five steps complete. Steps 1–4 (2026-07-02): instrumentation → swept `?` into
441 auto-try sites → inventory 0 → `check_explicit_try.sh` gate. **Step 5 (the flip,
2026-07-15):** an omitted `?` on a throws call is now a **compile error in both
compilers**, via a **driver-level diagnostic** (NOT `@compileError` — 4 of 5 sites
are expression-position and would malform the emit). A valid `try` is still emitted;
the driver collects the sites and rejects with `file:line: throws call needs '?'`
after codegen. `--allow-implicit-try` is the one-release migration hatch. Bootstrap:
a `pub var implicit_try_sites` global + `rejectImplicitTry` in `main.zig`. Selfhost:
a file-scope `_implicit_try_sites` (mirroring `boss_director`'s registry) + `cur_line`
on the shared Writer + the check in `main.zbr`. Gates: smoke 236/236, round-trip
byte-identical, corpus 0. QUICKSTART §12 + CHANGELOG updated. Regression:
`test/fail_fixtures/implicit_try_rejected_test.zbr` (smoke_tc_fail).

**Surfaced + fixed:** the flip caught `selfhost/Parser.zbr:3164` (`return
p.parseModule()`) — a genuine implicit-try the bootstrap's instrumentation never
flagged because the bootstrap emits an **error-union passthrough** (`return X`, no
`try`) there while the selfhost auto-`try`s it. Adding `?` converged both emitters
(→ `return try …`) and completed the sweep.

**Residual divergence (acceptable, documented):** the selfhost flip rejects
return-position throws calls on a local (`return x.method()` without `?`); the
bootstrap uses passthrough there, so it does *not* reject them. Selfhost-stricter is
the acceptable direction (bootstrap phasing out); a user hitting the selfhost
rejection just adds `?` (the intended fix). Close by extending the bootstrap's
return-path detection if the bootstrap is kept longer.

## §28e — spec `str` ownership per stdlib call

`str` is sometimes borrowed (`s[a..b]`), sometimes freshly allocated (`concat`,
`File.read`) — invisible under the program arena, load-bearing inside `allocate`
scopes and threads. Pre-1.0 task = a per-call borrows-vs-owns table in the
spec/QUICKSTART, so the 1.5 `str_view` design has defined ground.

## §28f — generic `Set(T)` [DONE — 2026-07-24], from scratch

**Shipped selfhost-only.** `Type_.set_` variant emitting `AutoHashMap(T, void)` /
`StringHashMap(void)`; `add`/`contains`/`remove`/`len`/`count`/`items`→`List(T)`/`clear`,
`for x in set`, `x in set`; local/param(by-ptr)/field/return/nested. Decisions taken:
str specialized, `items()`→`List(T)`, StrSet stays internal. `add()` interns str keys;
`items()` and `for-in` reuse `_zebra_map_keys`; `in` reuses `_zebra_in` (`@hasDecl
"contains"`). Limits (=HashMap keys): T auto-hashable; no `==`/`print(set)`. The
bootstrap does NOT implement Set (sunsetting) — it shows as an informational
divergence bootstrap-gap; round-trip holds because the compiler's own source never
uses Set. Historical scoping notes below.


The "mirror the existing StrSet API" premise is **invalid**: `StrSet` is a
selfhost-internal Zig type, not user-facing. So `Set(T)` is a HashMap-sized new
builtin: special-case the void value (`AutoHashMap(T, void)` / `StringHashMap(void)`
for str), set methods (add→put(x,{}), contains, remove, count, items→List), for-in,
TC, both compilers. **Decisions to confirm:** str-key specialization; does `items()`
return `List(T)`; expose a `Set(str)` alias or leave StrSet retired. Own gated pass.
Related: the functional trio (`map/filter/reduce/sort/sortBy`), `HashMap.keys/values/
entries` all shipped (see Completed-recent). Broader follow-up: a fuzz surface for
lambda-taking list methods (none fuzzed today — would come as one lambda-generation
capability).

## §28j — `_allocator` under threads → two-tier model (step b open) [DIRECTION SET — Sean 2026-07-03]

> **Design research (2026-07-23): `docs/concurrency_allocation_design.md`.** Comparing
> Zig (`ThreadSafeAllocator`, `SmpAllocator` — a GC-free per-thread-cache with
> thread-exit reclamation, both in std) and Go (per-P `mcache` tiers + GC-owned
> lifetime) reframes §28j and **shrinks it**: lead with SHARE-NOTHING (per-thread arenas
> + copy-on-`Chan`/`<<-`, which Zebra already does) so the cross-thread use-after-free
> class is avoided by construction; provide a thread-safe FALLBACK tier for genuine
> shared state by *adopting* a std allocator (`ThreadSafeAllocator` → `SmpAllocator`),
> not inventing one. Residual real work: per-thread arena wiring + audit that
> cross-thread paths copy + a threaded-lifetime gate + a thin opt-in shared annotation.
> Still supervised. See the note for the full comparison + recommendation.


Arena allocators aren't thread-safe; workers sharing the program arena is a latent
race. **Measurement done (step a, 2026-07-04):** race CONFIRMED in code (`_allocator`
is one global non-thread-safe arena; ThreadPool/`sys.go` workers don't swap it) but
did NOT manifest at runtime (200 tasks × 4000 allocs × 16 threads, ~15 runs, zero
corruption — narrow window; UB and latent, not frequently-firing). **Step b open —
WIRING, supervised session (design + risk):** making `_allocator` `threadlocal` fixes
the temporary race but then worker-allocated data a later thread reads → use-after-
free, and that's invisible to single-threaded gates. Correct model = both tiers wired
+ a clean Zebra handle for "allocate in the shared pool" (`Smp()`) — an API design
call (keyword? `shared` block? `sys.sharedAlloc()`?). Add a threaded *lifetime* test
to the gate set, not just the alloc-race probe. Unblocks correct shared-state servers
(the BUG-153/154 territory). **Not for unsupervised work.**

**Prior art — xsync.zig** (assessed 2026-07-21; MIT, single-file, Zig 0.16+master):
cross-`std.Io` **cancellation-safe** sync primitives (Mutex/Condition/Event/Semaphore/
RwLock/`Queue(T)` w/ timeout+close). Strong fit for Zebra's concurrency layer:
reimplement `Chan(T)` on `xsync.Queue`, close **BUG-154** (Tcp.serve no-lock) with
`xsync.Mutex`. **VENDOR** it (not a live dep — binary-size/control) and **read its 3
stdlib-Condition bug reports** (Zebra may share those latent bugs). Value scales with
one decision: **near-essential IF Zebra adds an evented `std.Io` runtime** (green
threads, no OS-thread-per-connection — servers are thread-per-conn today, won't reach
C10k); nice-to-have if threaded-only. Full assessment: memory `project_xsync_concurrency`.
github.com/lalinsky/xsync.zig

## §19.5d — bootstrap-check feedback latency

`tools/bootstrap_check.sh` is the integration safety net but slow under CPU throttle
(5–10 min observed). Profile + optimize where cheap (parallel build steps, cache-
invalidation tightening). Gated on a profiling pass.

## §9 — Greek NT n-gram port

SIMD types shipped 2026-05-08 — the deferral reason is gone. Scope: file I/O,
`HashMap` with Unicode keys, sort, sliding n-gram window, TF-IDF / cosine similarity
via `f32x8` dot-product. `--cpu=native`/`--cpu=x86_64+avx2` passthrough shipped
(QUICKSTART §32, SIGILL hazard noted). See `concept_zebra-simd-design.md`. (Runtime
CPU dispatch — oma-style — is post-1.0.)

## Fuzzer (`fuzz/`) — remaining coverage

Found + fixed 12 real equivalence bugs (F1–F12 → BUG-159…167, 161/162, 173).
Post-fix sweeps clean (seeds 0–99 run-oracle 100/100). **Open:** grow `DEFAULT_CAPS`
into high-bug-history combinations — remaining caps need class-relationship
generation: (4) `^T` boxing, (5) interfaces + `is`, (6) generics / backed-enums /
chained-cmp. Grow grammar surfaces (generics, error/throws, branch/enum). Caution:
`stmtMentionsThis` must stay EXACT. Generic *functions* are intentionally selfhost-
only — do NOT fuzz them as an equivalence surface. Sized numerics (`List(int32)`)
fail at the parser (BUG-172 follow-on). See `fuzz/README.md` + `FINDINGS.md`.

## Open Bugs (not tied to an open milestone slot)

- **Selfhost `_initIo` propagation gap** — selfhost-emitted dep modules get a simple
  `_initIo` (local `_io` only); bootstrap-emitted ones propagate to transitive deps.
  Harmless now (`Ast`/`CgHelpers`/`TypeChecker` don't call `_io` ops directly); would
  silently use undefined `_io` if a transitive dep gains file I/O. Fix: emit a
  propagating `_initIo` in `generateModuleWith`. **Track for 1.0 pre-flight.**
- **BUG-180** — bootstrap ctor-default fill (see Compiler hardening). Bootstrap-only.
- **BUG-026** — `instance_method_return_types` gaps for exposed-type method chains.
  Not manifesting (`scanMutationsInExpr` conservatively marks cross-module calls
  mutated). Defer unless a concrete failing case appears.
- **BUG-014** — regex lazy match is global, not per-quantifier (`<.*?>STUFF.*>`
  misbehaves). Architectural (priority-first NFA / backtracking). **Deferred
  post-1.0 (§7);** workaround = split/restructure the pattern.

---

# Post-1.0

- **§7 — Regex per-quantifier lazy/greedy** (BUG-014). Per-node shortest/longest
  flags; architectural. Workaround: split the pattern.
- **§6 — REPL resident compiler.** Measured: `zig run` cold 4s / warm 119ms; every
  REPL entry is a cold compile (session file changes each entry); `-fincremental`
  doesn't help on Zig 0.16 Windows (linker state not saved). Options: Zig 0.17+
  incremental linker, or a native Zebra interpreter (~2–3 wk). Deferred.
- **§24e — single method-descriptor table.** One spec driving both TC inference and
  codegen dispatch (replaces the 4-place pattern). Priority raised by §28a.
- **SIMD runtime CPU dispatch** — oma-style startup detection (SSE2→AVX2→AVX-512 /
  NEON→SVE2) without separate builds. Design spike.
- **§13 — VCS in Zebra** (capstone). Pijul-shaped patch algebra + typecheck-as-merge.
  Daily-useful pieces already shipped (§19.5). Research/teaching artifact.
  `concept_zebra-vcs-architecture.md`.
- **§14 — IDE (self-hosted), MVU redesign.** ZigZag TUI canonical backend shipped
  (`--gui-backend=tui`, 2026-05-21). Remaining: libui-ng adapter (~200–300 lines
  widget-cache reconciliation + two Zig 0.16 `build.zig` fixes). `concept_zebra-gui-redesign.md`.
- **§17 — 1.5: WASM target + web frontend SDK.** `--target wasm32-freestanding`/`-wasi`,
  `export def`→`export fn`, JS shim, module blacklist, AlpineJS. Shares `@freestanding`
  + blacklist infra with §22. ~2–3 wk. Key decisions: `throws` at boundary; class/struct
  passing; `print()` buffering. `concept_zebra-wasm-frontend.md`.
- **§17b — 1.5: Http server ergonomics** (swerver-inspired): (a) arena-per-request
  handler model; (b) **`str_view` borrowed slice** — the biggest structural gap
  between Zebra's owned `str` and high-perf servers (needs a lifetime-annotation
  design spike); (c) `BoundedPool(T, N)` with LIFO free-stack + double-release bitmap.
  `concept_zebra-http-design.md`.
- **§26 — 1.5: Zig `@builtin` access** (three tiers): T1 native promotions
  (`sizeof`/`alignof`/`typeof`/`bitcast`); T2 semantic namespaces (`Atomic.*`/`Ptr.*`/
  `Int.*`/`Simd.*`); T3 transparent `@name(args)` pass-through for ~60 more. ~1 wk.
  Removes a primary impediment to writing engine/systems code in Zebra.
- **§22 — 2.0: Kernel track.** `.zbr`/`.zeb` split; `@freestanding` mode; `core`
  stdlib; naked/interrupt callconv, inline asm, `@section`, `@embed_file`, `volatile`,
  `Cpu.*`. Plus the 2.0 WASM additions (multi-file, source maps, wasm-opt,
  serialization). `concept_zebra-os-additions.md`. Reference: BamOS.
- **§16 — Intertextual support.** LXX/MT divergence tool; provenance typing.
  RESERVED for post-1.0. `project_intertextual.md`.

---

# Completed — recent (full detail)

## EPIC: Language Server (LSP) — Phases 1 → 4h ✅ (2026-07-09 → 07-10)

Written **in Zebra** (flagship dogfood + reuses the front-end directly). An LSP is
the biggest daily-ergonomics lever for any language. Open follow-ups are in the
Tooling section above.

- **Phase 1 ✅** — diagnostics *seam*: `zebra diagnostics <file> [--out <json>]` runs
  parse→resolve→typecheck → JSON `{line,col,severity,message}`. Reuses `tcCheckSide`;
  line/col are the trailing numeric fields (robust to the Windows drive-colon).
  `tools/lsp_diagnostics_smoke.sh` + `test/lsp/*.zbr`. NOTE: `print` lands on stderr
  on the Windows fast-backend (so does `--emit-zig`) → `--out <file>` is the clean
  consumer interface.
- **Phase 2 ✅** — `zebra lsp`: a stdio Language Server (JSON-RPC, Content-Length) IN
  `main.zbr`, front-end in-process. `initialize`/`shutdown`/`exit`, `didOpen`/`didChange`/
  `didClose` → `publishDiagnostics`. Transport: `Terminal.write` (real stdout, pipe-
  capable — NOT `print`); stdin via `sys.readLine` + new `sys.readBytes(n)`. Dynamic
  JSON via `Json.parse`. `tools/lsp_server_smoke.py`.
- **Phase 3 ✅** — VS Code extension `editors/vscode/`: thin `vscode-languageclient`
  (9.0.1) over stdio + TextMate grammar + language config. Verified headless (server
  5/5); not yet click-tested inside VS Code.
- **Phase 4a ✅** — formatting (`fmtNormalize`, full-document TextEdit) + documentSymbol
  (module decls → LSP symbols, members nested). Buffers stored in a `docs` map. 8/8.
- **Phase 4b ✅** — hover (markdown code-fence signature via `typeRefStr`) + go-to-
  definition (per-buffer decl index; `lspWordAt`). Constraint found: selfhost
  AstBuilder used `zspan()` = all-zero, so definition fell back to a text search
  (later retired by 4d). Worked around a `List(char)`-ctor round-trip divergence
  (BUG-172). 10/10.
- **Phase 4c ✅** — completion (keywords + declared symbols with kinds/detail). 11/11.
- **Phase 4d ✅** — real source spans on declarations. Parser records the name-token
  position on every decl PNode; AstBuilder threads it via `nameSpan()`. documentSymbol
  ranges now real + name-precise; definition uses the AST span (text search only a
  mid-edit fallback). Internal only — emitted Zig unchanged (round-trip byte-identical).
  Commit f0d9111. Retires the 4b `zspan()` limitation.
- **Phase 4e ✅** — member completion after `.`: `self.`/`this.`/leading-dot → enclosing
  type; type name → members/enum variants; annotated/constructed local → its type's
  members. `.` as trigger. Text-based receiver resolution; unresolved → empty, not
  noisy globals. Commit 78ada96. 12/12.
- **Phase 4f ✅** — formatter v2: inter-token space collapse with byte-for-byte string/
  comment preservation (string/comment-aware line scanner; every mis-read errs toward
  staying *inside* a string). Gated by `tools/fmt_safety.py` (11 fixtures + idempotence
  on 413 files + emit-equivalence: 123 files reformatted, all emit byte-identical Zig).
  Open: canonical re-indent (Tooling section).
- **Phase 4g ✅** — signatureHelp (`(`/`,`; innermost enclosing call, depth-aware comma
  split so `HashMap(str,int)` stays one param; `activeParameter`). Robustness: unknown
  **requests** → `MethodNotFound` (-32601). Functions/methods, single-line. 14/14.
- **Phase 4h ✅** — diagnostics debounce: a `sys.go` reader forwards stdin to a
  `Chan(str)`; main loop `recvTimeout(0.2)` flushes on a ~200ms lull. `didChange` marks
  dirty; a burst coalesces to ONE analysis. Detached reader (so `exit` doesn't hang on
  the stdin-blocked thread); EOF via `Atomic(bool)` + `Chan.close()`. Built on
  `Chan.recvTimeout`. Round-trip byte-identical.
- **Channel timed/non-blocking receive ✅** — `ch.tryRecv(): T?` + `ch.recvTimeout(secs): T?`
  (poll-based, ~2ms granularity; upgradeable to futex timed-wait). Verified under BOTH
  compilers, round-trip byte-identical. *Not done:* a true multi-channel Go-style
  `select` (own project; Zig gives nothing to borrow) — the single-channel-merge +
  `recvTimeout` idiom covers most needs.

## §28 — pre-1.0 design-review campaign (Fable/Opus/Sonnet, 2026-07-02 → 07-04) — mostly ✅

Open tails (§28a step 4, §28e, §28f, §28j step b) are in Open-detail (§28b flipped
2026-07-15 — see the §28b section above, now DONE)
above. Completed pieces:

- **§28c ✅ (07-04)** — exhaustiveness default-on (`--no-warn-non-exhaustive` to opt
  out; legacy `--warn-non-exhaustive` a no-op). Warnings stderr-only → round-trip
  unaffected. Feared "108 legacy `else` arms" a non-issue (selfhost's own sources: 0
  warnings). Error-by-default deferred to 2.0.
- **§28d ✅ (07-02)** — copy-out is `<<-`; `<-` is channel-only. `left_arrow_deep`
  token both compilers; one StmtCopyOut with a `deep` flag; `genCopyOut` enforces the
  pairing via `@compileError` into the emitted Zig (identical behavior both compilers).
  QUICKSTART §28/§35 swept.
- **§28f partial ✅** — functional trio + map utilities: `List.map/filter/reduce`
  (07-03), `HashMap.keys()/values()` (07-04, replaced a broken selfhost emit that
  called ArrayHashMap-only methods), `sort` optional comparator (07-04),
  `HashMap.entries()` → sortable `List((K,V))` (07-06). Higher-order lambda params now
  typed from the receiver's element type (fixes any/all/find/sortBy too). (`Set(T)`
  still open — §28f above.)
- **§28g ✅ (07-03/04)** — grammar cleanups: `to!` alias retired (`x!` won;
  `to_bang_removed_test` must-fail); `yield` removed completely (Zig has no coroutine
  to lower to; old codegen only emitted a `// yield` comment — clean deletion, 0
  migration); optional-FIELD `as`-unwrap confirmed working both compilers.
- **§28h ✅ (07-04)** — `ObjectPool(T)` stdlib: `pool.take()` → `^T?`, `give()`
  (contract-guarded double-release/foreign-object), `inUse()`. Modelled on `Chan(T)`.
  `ObjectPool(int)` intentionally fails (pooling primitives is pointless).
- **§28i ✅ (07-04)** — `sys.memStats()` → `MemStats{ arenaBytes }`
  (`_arena.queryCapacity()`, the high-water mark). Struct shape (not a bare int) so
  fields can be added later.
- **NOT recommended for change** (design-affirmed): `var`-only mutability (BUG-161 was
  an implementation bug, not a design flaw); contracts as identity feature; no
  inheritance; `cue init` (keep, document the Cobra etymology).
- **Synthesis → `docs/walker_discipline.md`:** the ten fixed bugs cluster into four
  structural causes. Standing rule: **new syntax lands with a fuzz generator surface +
  smoke fixture in the same commit.**

## Node.js addon target (`--target node-addon`) ✅ (2026-06-29 → 06-30)

`@node_export def add(a,b): int` + `zebra --target node-addon math.zbr` → `math.node` +
`math.js` shim + `math.d.ts`. Verified end-to-end in Node (int/float/bool/str). Both
compilers build a working `.node`; round-trip + smoke green. Selfhost emit parity,
per-call child arena for string marshaling (Phase 7), cross-platform symbol resolution
(Windows `node.lib` verified; Linux/macOS correct-by-construction), test harness
`test/node_addon/` via `tools/node_addon_test.sh` (Node + node-gyp; not in `zig build
test`). QUICKSTART §45. Follow-ups (cross-platform `.node`, richer matrix) in Tooling.

## Backlog dogfood + hygiene — recent ✅

- **TCP KV store + ThreadPool ✅ (2026-06-30)** — found 7 gaps; fixed BUG-150
  (`sys.sleep`→`std.Io.sleep`, Zig 0.16), 151 (`var _=` discard), 152 (`ThreadPool.submit`
  comptime-fn); filed 153 (module-global Atomic/HashMap — since FIXED), 154 (`Tcp.serve`
  per-conn concurrency, no lock — open, see §28j territory), 155/156 (since resolved).
- **Generated-Zig hygiene ✅ (2026-06-29)** — selfhost routes emit to a temp dir when
  no `--output-dir`; the 300 generated `test/*.zig` are gitignored (8 hand-written
  `.zig` `!`-excepted); `selfhost/*.zig` + `examples/*.zig` stay tracked. `git status`
  clean after regen.
- **Mosaic POC dogfood ✅ (2026-07-14)** — a differential Greek-NT port re-verified
  8 findings against HEAD; live ones filed BUG-175 (fixed: cwd-preamble panic),
  176/177/178 (all fixed), 179 (resolved-as-documented, drop-parity). Numeric
  conversions (`toString`/`toFloat`/`toInt`) confirmed correct & documented.

---

# Completed — archive (one-liners)

Detail in git / `BUGS.md` / `SELFHOST_JOURNAL.md` / `CHANGELOG.md` / wiki.

| Item | Done |
|------|------|
| §27 cross-module type resolution (27a free-fn return, 27b default-fill, 27c optional-return) | 2026-06-17 |
| §24 compiler ergonomics: exhaustive-match warning, cross-module `^T?` bindings, `?.` optional chaining, `genMemberCall` user-method early-exit, type-first dispatch | 2026-05-16/17 |
| §25 block comments `/# #/` (nested) | 2026-06-03 |
| §23 memory model: `allocate` Slices 1–6, `<-` copy-out deep-copy, `Chan(T)`, `sys.go` | 2026-05-12/18 |
| §19 / §19a error recovery: boundary-restart multi-error parse (both compilers), enum TC via `hasEnumAny`, `typecheck-merge`, source-mapped errors | 2026-05-27 |
| §12 syntax cleanup 0.13: BUG-115 visibility keywords, `this.field→.field` (1,141 sites), `def name:T→def name():T` (38 sites), `^T` auto-boxing | 2026-05-05/14 |
| §21 0.11: REPL, JSON auto-inference, gzip, debugger/DAP, `--module-path`, build system, `--cpu` passthrough, debug-run fast path (`-fno-llvm -fno-lld`) | 2026-05-12/06-20 |
| selfhost artifact refresh — committed = bootstrap-canonical, idempotent (BUG-135 path markers; PascalCase rename) | 2026-06-18 |
| 1.0 gap checklist — all `[x]` (REPL, ImGui LowLevel, tuples, generics, Zig 0.16, `<-`, `Chan`, refinement types, WebSocket, IANA tz, `using`, for-destructuring, CHANGELOG, node-addon, libui-ng widgets/dialogs/consolidation, visibility keywords) | 2026-05/06 |
| 0.15 stdlib completeness: Http.serve, ThreadPool, Path.*, gzip, Tcp.serve, Atomic, Log json/file, Crypto AES/SHA, SQLite, UDP | 2026-05-25 |
| Named `cue init` construction (`Point(y:5)`, reorder + default-fill; cross-module selfhost fill deferred) | 2026-05-19 |
| `x!` force-unwrap; `with` bare-method desugar; remove `try` prefix; inline `if x: y`; `Scope` interface; `is not` precedence | 2026-05-23/24 |
| Nested namespaces; DynLib producer (`@export`); plugin vtable demo | 2026-05-16/26 |
| Contracts (`require`/`ensure`/`invariant`/`old`/`result`/`--turbo`) — 0.12 | 2026-04-24/27 |
| Chained comparisons `a<b<c`; `unless`/`until`; `for-else`; `branch` struct-field patterns; `@[...]` array literals | 2026-04-23/26 |
| SIMD types (`f32x8`/etc.); guarded for-in + `List.find`; `@profile`; `Profile` module | 2026-05-06/08 |
| `Json.parseStrict` + `@reflectable`; `interface` fat-pointer vtable codegen | 2026-04-24/27 |
| String interning; optional-unwrap `as`; named/default param parity (selfhost); Phase 22 selfhost cutover | 2026-04-21/23 |
| User-defined generics (`class Stack(T)`) — 0.8; batteries-included stdlib | 2026-04-10 |
| `@once` + `sys.readLine`; TC Phase 5 generic→interface conformance; `typecheck-merge` + git hook; BUG-099 `.unknown` split; per-commit zip snapshot; style guide | 2026-05-04/10 |
| Self-hosting bootstrap round-trip (5/5); `pro`/`get`/`set`/`body`/`post` keyword removal; source-mapped errors (Phase 19); ImGui backend (stub + GLFW) | 2026-04-06/21 |

---

*Full milestone plan: `wiki/pages/projects/project_zebra.md`*
*Open bug details: `BUGS.md`*
*Self-hosting history: `SELFHOST_JOURNAL.md`*

**Last reorganized:** 2026-07-15 (open work curated at top; completed clumped at
bottom — LSP epic + §28 campaign + node-addon kept in full, older work archived to
one-liners). Prior detail preserved in git history.
