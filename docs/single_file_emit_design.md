# Single-file emission — design note

**Status:** design / spike complete, implementation not started (2026-07-21).
**Origin:** F5 (preamble-internal names leak into the user namespace) from the
CherryCobbler dogfood; escalated to an architecture change on Sean's suggestion.
**Scope:** codegen only — changes what the Zebra compiler *emits*, in both
`src/CodeGen.zig` (bootstrap) and `selfhost/CodeGen.zbr`, kept equivalent.

---

## 1. Motivation

Today the compiler emits **one `.zig` file per Zebra module**, and each file
**inlines the entire ~3712-line runtime preamble** (`selfhost/stdlib_preamble.zig`)
at file scope, followed by the user's top-level declarations *in the same scope*.

Three problems fall out of that shape:

1. **F5 — name collisions.** A preamble helper's internal binding (`var h`,
   `const handle`, a parameter `handle`, a capture `|item|`, …) shares file scope
   with the user's top-level declarations. Zig forbids a function-local/param/capture
   from shadowing *any* enclosing-scope declaration, so a user `def h` collides with
   the preamble's `comptime var h` inside `_zbr_hash` (and 9 other `h` bindings), and
   `def handle` collides with the process helper's `const handle`. The collision
   surface is the preamble's *entire* identifier set — measured at **412 distinct
   non-`_` binding names** (locals + params + captures). There is no narrow rename
   that closes the class.

2. **Preamble duplication.** A multi-module program emits N copies of the preamble.
   Verified: a trivial 2-module program emits `app.zig` (183 KB) + `helper.zig`
   (183 KB), each a full preamble copy. The **selfhost compiler itself is ~9 core
   modules** (Parser, Resolver, AstBuilder, Ast, CodeGen, CgHelpers, TypeChecker,
   Checker, main) → ~9 preamble copies compiled on every `zig build` / round-trip.

3. **Cross-module runtime boilerplate.** Each module carries its *own*
   `_io`/`_allocator`/`_arena`/`_error_ctx`, so `selfhost/main.zig` hand-wires
   `@import("Parser.zig")._initAllocator(a)`, `._initIo(io)`, and a
   `_zbr_error_msg()` fan-out across all 8 dependency modules.

**Single-file emission** — merge all modules into one `.zig` file, each wrapped in a
namespace `struct`, with **one** shared preamble at file scope — resolves all three:
the preamble's internals no longer share scope with user top-level names (F5 gone),
the preamble appears once, and the per-module runtime state unifies into one set of
file-scope globals (the init fan-out is deleted).

---

## 2. Why the alternatives were rejected

| Approach | Verdict |
|---|---|
| **Prefix all preamble bindings** (`h`→`_h`, …) | Rejected. 412 sites incl. params/captures — a risky mass-rename of the most critical shared file, disproportionate to a low-sev bug. |
| **Separate imported preamble module** (`@import("_rt.zig")`) | Rejected on Zig 0.16: `usingnamespace` is **removed** (no cheap re-export), and mutable globals **cannot be `const`-aliased** across files (`const _allocator = _rt._allocator` → "must be comptime-known"). Forces qualifying every `_rt._allocator`/`_rt._str_concat` reference in both emitters. |
| **Wrap the preamble in a `struct`** (same file) | Rejected — *verified* that file-scope user decls still shadow into a file-scope struct's methods. Does not help. |
| **Wrap the user code in a struct** (bespoke) | This is essentially single-file for one module. Single-file generalizes it and adds the dedup + simplification wins, so it subsumes this. |

Single-file is the **only** design that closes F5 *without* reference qualification,
because everything shares one file scope and bare references to preamble
symbols/globals resolve outward for free.

---

## 3. Spike results (2026-07-21) — what is proven

A hand-built prototype (`app` + `helper` merged into one file, one preamble)
**compiled and ran** (`hi world 42 42`). Established:

- ✅ **F5 dissolves.** `pub fn h` / `pub fn handle` — matching the preamble's
  internal `h`/`handle` bindings — compile with **zero** shadow errors once
  namespaced inside a module struct (off file scope).
- ✅ **Bare outward resolution works.** A module struct's method referencing
  file-scope `_str_concat`/`_allocator` compiles — no qualification needed.
- ✅ **Cross-module `use ... exposing` works.** A second module referencing
  `model.Value` / `model.make` via `const Value = model.Value;` mirrors today's
  `const Value = @import("model.zig").Value;` — same reference model, `@import`
  becomes a nested struct name.

### Wiring problems found (by hitting them) and their fixes

1. **The main module must also be namespaced.** Leaving it at file scope makes a
   name declared in *both* a module struct and file scope an "ambiguous reference"
   from inside the struct. → Every module (incl. main) becomes `const M = struct{…}`;
   a thin file-scope `pub fn main(_zinit)` shim calls `mainmod.run()`.

2. **Module-var init must be restructured.** The preamble's `_initIo` calls a
   file-scope `_initModuleVars()`, but single-file has N modules each with their own.
   → One file-scope `_initModuleVars()` dispatcher fans out to
   `helper._initModuleVars()`, `app._initModuleVars()`, … (each idempotent).

3. **Runtime state unifies.** One file-scope `_io`/`_allocator`/`_arena`/`_error_ctx`
   shared by all module structs; the per-module `_initAllocator`/`_initIo`/
   `_zbr_error_msg` fan-out is deleted.

### Compile-time: the original motivation did NOT pan out

Honest finding: the speedup that motivated the idea is **modest and largely
unmeasurable on this host.**

- Frontend (`zig ast-check`, parse+AstGen) cost is **~12 ms per preamble copy**
  (72 ms with preamble vs a 60 ms floor). For the 9-module selfhost that is ~100 ms
  of parse saved. Real, small.
- Sema (semantic analysis of the *used* preamble subset ×N) is where a larger win
  could hide, but Zig analyzes lazily (unused preamble is DCE'd, never Sema'd), the
  2-module toy is too small to exercise it, and full-build timing was pure noise
  (variance 4 s–34 s as the shared machine contended). No trustworthy figure.

**Therefore the justification for this change is architecture + F5-closure +
emit-simplification, NOT compile speed.** The "single file is faster" folklore
most likely refers to avoiding redundant reparse across a large project; Zig
already dedups `@import`s and analyzes lazily, so our shape sees only a modest win.

---

## 4. Target emitted shape

```zig
// ── one shared preamble at file scope (globals + ~375 helpers) ──
const std = @import("std"); const builtin = @import("builtin");
var _io: std.Io = undefined; var _allocator: std.mem.Allocator = …;
// … the whole preamble once …

// ── each module → a namespace struct (dependency order) ──
const helper = struct {
    pub fn greet(name: []const u8) []const u8 { return _str_concat("hi ", name, _allocator); }
    var _vars_inited = false;
    pub fn _initModuleVars() void { if (_vars_inited) return; _vars_inited = true; }
};
const app = struct {
    const greet = helper.greet;               // `use helper exposing greet`
    pub fn h(x: i64) i64 { return x + 1; }     // user `def h` — no longer collides
    pub fn run() void { … }
    var _vars_inited = false;
    pub fn _initModuleVars() void { … }
};

// ── one file-scope init dispatcher + entry shim ──
pub fn _initModuleVars() void { helper._initModuleVars(); app._initModuleVars(); }
pub fn main(_zinit: std.process.Init) void {
    _io = _zinit.io; _allocator = _arena.allocator(); defer _arena.deinit();
    _initModuleVars(); app.run();
}
```

---

## 5. Integration cost

Smaller than first feared:

- **`build.zig`** already builds `zebra.exe` with `selfhost/main.zig` as the root
  (Zig discovers dependencies via `@import`). Single-file makes `main.zig`
  self-contained → the build barely changes; the per-module install artifacts retire.
- **`tools/bootstrap_check.sh`** regenerates + byte-diffs **one** artifact instead of
  9 — a *simplification* of the round-trip, not a complication.
- **The checked-in `selfhost/*.zig` per-module artifacts** are replaced by a single
  generated `selfhost/main.zig`. (Repo change: retire 8 files, one grows.)
- **Both emitters** gain the namespacing / init-dispatch / entry-shim / export-hoist
  logic and must stay equivalent through the round-trip.

---

## 6. Phased, de-risked plan

**Isolation tactic:** a *temporary* `--single-file` codegen mode flag (default off).
The new emit path develops alongside the trusted multi-file path; nothing flips until
each phase's gates are green. Once single-file is the default and multi-file is
retired, the flag is removed (no permanent dual-mode maintenance tax). Gates after
every phase: `selfhost_smoke.sh`, `bootstrap_check.sh`, `JOBS=3 compile_check.sh`.

- **Phase 1 — scaffold.** Add the `--single-file` flag + a parallel emit entry point
  that, for a *single-module* program, produces the namespaced shape (one module
  struct + shim). No multi-module merge yet. Prove parity on single-module fixtures.
- **Phase 2 — module namespacing + cross-module rebind.** Emit dependency modules as
  `const M = struct{…}` in topological order; `@import("X.zig").Y` → `X.Y`. Handle the
  `use ... exposing` rebindings. Prove on the 2-module fixtures.
- **Phase 3 — unify runtime + init dispatch.** One preamble, one shared runtime state,
  the file-scope `_initModuleVars` dispatcher; delete the cross-module init fan-out.
- **Phase 4 — edge cases.** `export fn` hoisting (lib mode), GUI preamble section,
  napi preamble, circular `use`, generics referenced across modules, and the selfhost
  compiling *itself* (`main.zbr` → one file).
- **Phase 5 — round-trip/build infra.** `build.zig` self-contained root;
  `bootstrap_check.sh` single-artifact regen+diff; update `compile_check.sh` /
  `divergence_check.sh` expectations; retire per-module `selfhost/*.zig`.
- **Phase 6 — flip default, remove the multi-file path and the flag.**

Keep bootstrap ↔ selfhost convergence at every step (this is gated, supervised work).

---

## 7. Open questions / risks

- **Circular `use`.** Two modules that `use` each other become mutually-referential
  structs in one file — Zig allows forward references within a file, but the init
  order and any comptime cross-refs need checking.
- **Generics across modules.** A generic type from module A instantiated in module B
  must resolve as `A.Stack(int)`; confirm the `_ttag_*` type-tag constants (emitted
  per class in the *user* region) land in the right namespace.
- **`export fn` / `--target node-addon`.** Exports must stay at file scope; they need
  hoisting out of the module struct with a file-scope wrapper.
- **Emitted-file size.** One `selfhost/main.zig` will be large (~all modules + one
  preamble). Diffable and buildable, but review tooling should expect it.
- **Whether single-file becomes the *default* or stays a mode.** Default = F5 fixed
  everywhere + simplification, but changes all emitted output and the round-trip. A
  permanent mode is a maintenance tax and would only fix F5 in that mode. Plan assumes
  **default**, multi-file retired.

---

## 7a. Implementation handoff — current emit map + next increment

**Status after commit `33996f3` (Phase 1 scaffold):** the `--single-file` flag and
`CodeGen.single_file` global exist and are inert (byte-identical emit verified). The
next increment is the **behavioral** single-module namespacing. Anchors below are in
`src/CodeGen.zig` `pub fn generate(...)` — reference by the quoted marker (line numbers
drift), and remember the **twin edit** in `selfhost/CodeGen.zbr` for parity.

The top-level emit is one linear sequence writing to `g.w`, in this order:
1. Header + `const std/builtin`, `_io`, `_args`, `_arena`, `_allocator`, `_str_pool`
   (search `"const std     = @import"`).
2. `_initAllocator` / `_initIo` — each loops `module.decls` `.use` nodes emitting
   `@import("X.zig")._initAllocator(a)` (single-module: loops are empty).
3. `_initModuleVars` — loops `module.decls` `.var_` with `deferredModuleVarType != null`,
   emits `{module_var_prefix}{v.name} = <init>` (search `"pub fn _initModuleVars"`).
   **References user module-globals by bare name → the crux of the wrap.**
4. `writeAll(build_options.stdlib_preamble_pre_gui)` — the shared preamble (stays file scope).
5. `_zbr_error_msg` (chains across `.use` deps).
6. GUI section + `writeAll(build_options.stdlib_preamble_post_gui)`.
7. `for (module.decls) |decl| try g.genTopDecl(decl);` — **the user decls to namespace.**
8. `emitInterfaceMembershipFns`, `flushPendingThunks` — may reference user types.
9. Entry: `node_addon` → `genNodeAddonGlue` + return; `test_mode` → `genTestMain` + return;
   else the `findMainClass` / `pub fn main` thunk that references the user entry.

**Next-increment plan (Approach A — colocate user-referencing scaffolding in the namespace):**
- Gate all new shape on `if (single_file)`; the `else` keeps today's emit verbatim.
- Emit the preamble + purely-runtime helpers (steps 1,2,4,5,6) at file scope unchanged.
- Wrap step 7 (user decls) **and** the user-referencing scaffolding — `_initModuleVars`'s
  body (step 3), interface RTTI (step 8), the user entry — inside `const _Mod = struct { … };`.
- Emit file-scope shims: `pub fn main(...)` → `_Mod.<entry>`; a file-scope `_initModuleVars()`
  (the preamble's `_initIo` calls it) → dispatches to `_Mod._initModuleVars()`.
- Start single-module (empty `.use` loops). Multi-module merge is Phase 2.

**Acceptance for the increment:** (a) all existing single-module fixtures emit + run
identically under `--single-file` (behavior parity); (b) a program with a top-level
`def h` — which fails to compile today (F5) — compiles + runs under `--single-file`.
**Gates (behavioral → run all):** `selfhost_smoke.sh`, `bootstrap_check.sh` (round-trip),
`JOBS=3 compile_check.sh` (independent witness).

**Prototype reference:** the verified hand-built shape is in this session's scratch
(`multimod/merged.zig`, `xmod.zig`) — module structs + one preamble + init dispatcher +
`pub fn main` shim; see §3/§4.

### 7a.1 — increment landed: single-module namespacing (both compilers, 2026-07-21)

Both `src/CodeGen.zig` (bootstrap) and `selfhost/CodeGen.zbr` implement Approach A behind
`--single-file` (default off), kept equivalent through the round-trip. The selfhost carries
a file-scope `var _single_file` + `setSingleFile()` (mirror of the bootstrap's
`pub var single_file`), wired from `selfhost/main.zbr`; `generateFullWithDeps` /
`generateFullWithDepsTest` emit the dispatcher + `_Mod` wrap, `generateModuleWith` renames
the body to `_initModuleVarsImpl`, and `generateEntryPoint` / `generateTestEntryPoint` do
the `_Mod.` qualification + top-level-main shim. Multi-module merge is still Phase 2 (the
selfhost's `generateDep*` dep files stay unwrapped).

What was emitted (single-module):
- `const _Mod = struct { <user decls> <interface RTTI> <closure thunks>
  <_initModuleVarsImpl> };` — the user region and everything referencing it by bare name.
- A file-scope dispatcher `pub fn _initModuleVars() void { _Mod._initModuleVarsImpl(); }`.
  The preamble's `_initIo` and the entry shims call the bare name; it fans out inward.
- Entry stays at file scope, qualified: class `shared def main` → `_Mod.<Class>.main()`;
  a top-level free `def main` (the dominant corpus shape, 296/388 fixtures) becomes
  `_Mod.main` with a thin file-scope `pub fn main(_zinit) { _Mod.main(_zinit); }` shim;
  the test runner calls `_Mod.test_*`.
- node-addon is left unwrapped (exports must stay at file scope — Phase 4).

**Wiring finding (beyond the spike's §3 list): the real `_initModuleVars` body must be
renamed inside the struct.** The inline top-level `main` injects a bare `_initModuleVars()`
call; with a struct member *and* a file-scope decl of that same name both visible from
inside `_Mod`, Zig raises `error: ambiguous reference` (it does not prefer the inner one).
Fix: the struct's real body is emitted as `_initModuleVarsImpl`, so the only `_initModuleVars`
visible from inside `_Mod` is the file-scope dispatcher — unambiguous.

Verification (bootstrap):
- Round-trip (`bootstrap_check.sh`) byte-identical → default multi-file emit unchanged.
- Single-file `compile_check`-style sweep (emit `--single-file` + `zig build-exe`
  semantic analysis) over the positive corpus: **187 pass / 4 fail**, and the multi-file
  `compile_check.sh --bootstrap` baseline fails the **same 4** (two multi-module dep
  `FileNotFound` — Phase 2; `sqlite_test` and `bug177_178_index_tostring_test` are
  pre-existing bootstrap-emit gaps, not single-file). → **zero single-file regressions.**
- F5 acceptance: a `def h` / `def handle` program fails `zig build-exe` under multi-file
  (`local variable shadows declaration of 'h'`) and compiles + runs under `--single-file`.

Verification (selfhost, after regenerating `selfhost/*.zig` via `bootstrap_check.sh --update`
— note the full round-trip leaves `main.zig` stale because it emits root files to stdout, so
a `main.zbr` change needs `--update`):
- `selfhost_smoke.sh` 236/236; `compile_check.sh` (default) 200 pass / 0 fail (baseline).
- Selfhost single-file sweep (`zebra.exe --single-file --output-dir` + `zig build-exe`):
  190 pass / 0 fail (+2 large stragglers separately confirmed to compile) — the 10 skips are
  7 cross-module (Phase 2) + library/no-main. Zero single-file regressions.
- `plain`→42, `f5`→42/42 under `zebra.exe --single-file`.

## 7b. Phase 2 design — multi-module merge (grounded in the drivers, 2026-07-21)

Phase 1 wraps ONE module; a program with `use` deps still emits each dep as its own `.zig`
file (full preamble each) and the wrapped root `@import`s them — a hybrid, not yet one file.
Phase 2 merges all transitive modules into a single `.zig`: one preamble at file scope, each
module a namespaced struct, cross-module refs rewritten, one init dispatcher + one entry.

**Target shape (multi-module):**
```zig
// one preamble at file scope (globals + helpers + ONE _error_ctx)
const _mod_Token  = struct { … };          // deps first (topological order)
const _mod_Lexer  = struct { const Token = _mod_Token; … };   // `use Token` → struct ref
const _mod_main   = struct { const Lexer = _mod_Lexer.Lexer;  // `use Lexer exposing Lexer`
                              … _initModuleVarsImpl … };
pub fn _initModuleVars() void { _mod_Token._initModuleVarsImpl(); _mod_Lexer…; _mod_main…; }
pub fn main(_zinit) void { … _initModuleVars(); _mod_main.run(); }
```

**Three code changes per compiler (`src/CodeGen.zig` + `selfhost/CodeGen.zbr`):**

1. **genUse rewrite.** Replace `@import("<path>.zig")` with the module struct name
   `_mod_<sanitized path>` (dots/slashes → `_`). So `use Mod` → `const Mod = _mod_Mod;`
   (or, for a sole same-named class, `const Mod = _mod_Mod.Mod;`); `use Mod exposing A` →
   `const A = _mod_Mod.A;`. The **`_mod_` prefix is load-bearing**: it keeps the module
   struct's name distinct from a same-named class the module exports (today's `Lexer` alias
   means the *class*; the struct must not also be bare `Lexer`).

2. **Driver assembly.** Both drivers already compile deps depth-first and write one `.zig`
   per module (`MultiCompiler.compileDep` → `generateDepWith`; `src/main.zig` →
   `compileZbrToZig`). Under `--single-file`, instead of writing per-module files, accumulate
   each module's `generateModuleWith` output (decls only, no preamble/entry) wrapped in
   `const _mod_<name> = struct { … };`, in the existing post-order (deps before root); after
   the root, emit ONE file: header + preamble once + all module structs + a file-scope
   `_initModuleVars()` fanning out to every `_mod_<name>._initModuleVarsImpl()` + the entry.

3. **Fan-out collapse.** The per-module `_initAllocator`/`_initIo`/`_zbr_error_msg`
   `@import` fan-out is deleted: one shared runtime state (already file scope), one dispatcher,
   and — because there is now ONE `_error_ctx` (one preamble) — `_zbr_error_msg` collapses to
   `return _error_ctx.message`. This is the emit-simplification win §1 promised.

**Decisions (mine, per the drop-bootstrap-parity latitude — surfaced):**
- **Module-struct naming = `_mod_<path with non-ident chars → _>`.** Collisions (two modules,
  same sanitized name) are rare and get a clear compile-time error, not silent mangling. The
  selfhost's own modules (Token, Lexer, Parser, …) are collision-free, so the endgame works.
- **Root unification.** In multi-module, the root is `_mod_<rootname>` like any module; Phase
  1's single-module `_Mod` name stays for the no-deps case (or is unified to `_mod_<root>` —
  decide during impl; unifying is cleaner but re-verifies the single-module shape).
- **Sequencing = selfhost-first.** Phase 2 lands in the selfhost (the primary compiler; it
  alone needs to compile *itself* as one file — the endgame). The bootstrap's multi-module
  single-file follows later or not at all: the bootstrap is being phased out, `--single-file`
  is default-off, and the bootstrap still compiles the selfhost source in default mode (the
  hard parity rule holds). `compile_check --bootstrap --single-file` already skips multi-module.

**Open risks (from §7, now concrete):** circular `use` (mutually-referential structs — Zig
allows forward refs within a file, but init order needs a topological guarantee, not just
post-order); generics instantiated across modules (`_ttag_*` land in the right `_mod_` struct);
`export fn` / node-addon (must hoist to file scope — Phase 4); same-basename collisions.

## 8. Interim (until this lands)

F5 is **low-severity** with a trivial workaround: do not name a top-level `def` after
a common short preamble-internal identifier (`h`, `handle`). No preamble stopgap was
applied — a partial rename (`h` has 10 binding sites incl. GUI `w,h` params) is itself
the whack-a-mole this change exists to avoid, and would be obsoleted by single-file.
See `zebra/FINDINGS.md` (CherryCobbler) F5 for the original report.
