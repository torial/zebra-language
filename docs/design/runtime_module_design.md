<!-- doc-status: design -->
# Runtime module emission — design note (#1)

**Status:** designed and **spiked end-to-end**; implementation not started.
**Date:** 2026-07-28
**Supersedes nothing.** Adjacent to `single_file_emit_design.md` but a *different*
change: that one combines **modules**; this one stops copy-pasting the **runtime**.

---

## 1. What it is

Today the compiler splices `selfhost/stdlib_preamble.zig` — 3,767 lines, 186 KB —
**verbatim into every emitted program**. A two-line Zebra hello-world emits 3,791
lines of Zig, of which 3,767 are preamble.

The change: ship the preamble as a **runtime module** that emitted programs
`@import`, instead of inlining it.

## 2. Why — and explicitly NOT for speed

Measured 2026-07-28, so nobody re-derives it:

| | |
|---|---|
| Zebra front end, hello-world | 0.057 s |
| `zig build-exe`, **trivial 5-line Zig**, LLVM | 5.2 s |
| `zig build-exe`, Zebra's 3,790-line emit, LLVM | 6.2 s |
| `zig build-exe`, trivial Zig, `-fno-llvm -fno-lld` | 0.94 s |
| `zig build-exe`, Zebra's emit, `-fno-llvm -fno-lld` | 1.15 s |

**Zig's own floor dominates.** The whole preamble costs ~1 s on LLVM and ~0.2 s on
the fast backend. An earlier version of this note claimed the preamble drove compile
latency; measuring the floor refuted it. **This change is not a performance change.**

It is worth doing for three things, each of which arrived independently from a
different bug:

1. **Error locations.** Errors land in generated code — `_str_concat` at line 3779 of
   a file the user never wrote (BUG-215, BUG-218). With a ~30-line emitted file there
   is almost nowhere for an error to land except user code.
2. **Namespace isolation.** The emitted file's scope stops containing the runtime's 399
   names and contains only the subset the program actually references — a strict subset of
   what the inline path puts there, so it can only ever have *fewer* collisions, never more.
   **Caveat, added 2026-07-28:** an earlier version of this note claimed the change "closes
   BUG-220 completely, including the `@export`/`@node_export` residual." That claim is
   **unverified.** A probe found `@export` is a *class-factory* annotation here
   (`@export("sym") class Foo`), not a free-function one, so the obvious repro does not
   exercise the residual at all; and `@node_export` is a node-addon build, which
   `--runtime-module` currently refuses. Treat the BUG-220 benefit as "strictly fewer names
   in scope", which is demonstrable, rather than as a proven closure.
   Note also that runtime-module mode introduces one *new* reserved file-scope name, `_rt`,
   with no collision guard — the same shape as BUG-220. Harmless while the flag is off;
   it belongs on the list of things to settle before flipping the default.
3. **BUG-221 — module init is not transitive.** See §4; this change *dissolves* it.

## 3. Spike results (2026-07-28) — what is proven

A real emitted hello-world was split by script into `zebra_rt.zig` + `prog.zig` and
compiled. Findings, in order of how much they shape the design:

### ✅ PROVEN — `@import` shares file-scope state across modules, at any depth

Three modules (`top` → `mid` → `leaf`) all `@import("rt.zig")`; `top` sets
`rt.shared_value = 41`, `leaf` bumps it, `top` reads **42**. One instance, shared.

**This is the whole reason BUG-221 dissolves.** Put `_allocator`/`_io` in the runtime
module and every user module at every depth sees the same ones — no
`_initAllocator`/`_initIo` fan-out to propagate, and nothing to get wrong.

### ✅ PROVEN — the split itself works and is dramatic

```
before:  hw.zig        3,791 lines
after:   zebra_rt.zig  3,770 lines   (compiled once, shared)
         prog.zig         30 lines   ← the user's program
```

**126× smaller** user file. 395 preamble decls needed `pub`; 398 symbols exported; the
hello-world referenced **6** of them.

### ❌ CONSTRAINT — `usingnamespace` is gone in Zig 0.16

`pub usingnamespace @import("zebra_rt.zig");` → *"expected function or variable
declaration after pub"*. So symbols must be brought in **explicitly**.

### ❌ CONSTRAINT — a mutable `var` CANNOT be aliased across modules

```zig
const aliased = rt.shared_value;   // error: unable to resolve comptime value
rt.shared_value = 7;               // fine
```

Aliasing (`const X = _rt.X;`) works for `fn` and `const` but **not** for `var` — the
initializer of a container-level constant must be comptime-known.

**Consequence, and it is the main implementation cost:** the **19 mutable preamble
vars** (`_allocator`, `_io`, `_args`, `_error_ctx`, `_arena`, …) must be **qualified**
at every use site in emitted code — `_rt._allocator`, not `_allocator`. Functions and
consts can still be aliased cheaply.

This cuts *toward* correctness rather than against it: qualifying is precisely what
makes them shared, which is what fixes BUG-221. But it is a real codegen change
touching every site that emits one of those names.

### ❌ CONSTRAINT — there is a backward dependency to break

The preamble's `_initIo` calls `_initModuleVars()`, which **codegen emits into the
user file**. So the runtime module calls into generated code:

```
zebra_rt.zig:81: error: use of undeclared identifier '_initModuleVars'
```

Options: pass it as a function pointer set at startup; have the user's `main` call it
directly (it already does) and drop the call from `_initIo`; or keep a
settable `?*const fn () void` hook in the runtime module. **The second is simplest**
and should be checked first — `main` already emits `_initModuleVars();`.

## 3b. Corpus validation (2026-07-28) — 36/40, one known class remaining

The transformation was built as a standalone tool (`tools/rtsplit_spike.py`) and run
over the first 40 programs of `full_sweep_baseline.txt`: emit → split → compile.

| result | count |
|---|---|
| split **and compiled** clean | **36** |
| failed, all one class | 4 |

Validating the transformation *before* wiring it into codegen was the right call: the
mutable-var emission surface is 250+ sites embedded in string literals
(`_allocator` alone appears at 135 places in `CodeGen.zbr`, mostly inside larger
emitted snippets like `w.emit("(std.fmt.allocPrint(_allocator, …")`). Debugging this
inside codegen would have been far more expensive than debugging it as a text pass.

**The remaining 4 are one class:** members of preamble *types* need `pub` too, not just
top-level decls — `_TsAlloc.allocator`, `_AllocStats.allocator`, and a `call` method on
a struct declared *inside a function* (`_ws_invoke`'s `_Wrap`). The spike marks the
enclosing types `pub` but not their members; the brace/context tracking that decides
"is this a type member (pub legal) or a function local (pub illegal)?" is incomplete.

That is a **scaffolding bug, not a design problem** — nothing about it suggests the
runtime-module split fails. The real implementation has a better option available than
text heuristics: codegen *knows* which preamble decls are types, so it can mark members
structurally instead of guessing from indentation. Do that rather than porting the
spike's heuristic.

**Verified working end-to-end:** hello-world splits 3,791 → **25 lines**, compiles, and
prints `hi`.

## 3c. Step 1 landed 2026-07-28 — and it is inert until the flag exists

`tools/pub_mark_preamble.py` marks every preamble declaration `pub`: **396 top-level +
33 members of top-level types**. `pub` at container scope is legal and has no effect in a
file that is spliced inline, so this lands *before* any codegen change and is proven by
the ordinary gates while emission is unchanged. It is the largest mechanical part of the
work and `zig` can validate it on its own.

Deliberately **not** mirrored into `src/CodeGen.zig`. The bootstrap hardcodes the
pre-`STDLIB_PREAMBLE_HELPERS_START` header (build.zig strips that region from the file
before embedding the rest) and emits the GUI section from its own inline switch — so
bootstrap emit will lack `pub` in exactly those two regions while selfhost emit has it.
That is cosmetic: both compile, round-trip is selfhost-vs-selfhost, and divergence only
gates selfhost gaps. The bootstrap is sunsetting and keeps inlining the runtime, so it
never needs the markings.

Still unmarked, and required before the flag can cover the GUI paths:
`selfhost/gui_tui_section.zig` (89 decls) and `selfhost/gui_libui_ng_section.zig` (102).

### Ordering footgun found doing it — a preamble edit needs `zig build` FIRST

`build.zig:37-49` reads `stdlib_preamble.zig` and embeds it into `zebra-bootstrap.exe`
via `b.addOptions()` — at **bootstrap build time**, not at emit time. `rebuild.sh`
regenerates with the *existing* bootstrap binary and only then runs `zig build`, so after
a preamble edit the regen silently emits the **old** runtime and every downstream gate
measures it. Observed here: the first `rebuild.sh` reported OK and produced **zero**
changes to `selfhost/*.zig`. The correct order for a preamble edit is
`zig build` → regen → `zig build`; `rebuild.sh` now does this itself.

This is the same shape as the trap CLAUDE.md already records for BUG-219 (a preamble fix
that looked like it hadn't worked), one level further out: there, regeneration was
missing; here, regeneration ran against a binary that predated the edit.

## 3d. Steps 2–6 landed 2026-07-28 — behind `--runtime-module`, default off

`zebra --runtime-module` writes the runtime once as `zebra_rt.zig` beside the emitted
program and `@import`s it. Hello-world: **3,791 lines → 27**. `BUG-221 is dissolved` —
the three-module repro that segfaults today prints its answer.

**What was actually built**

| | |
|---|---|
| `rtScanNames` | splits the runtime's 399 `pub` decls into 22 mutable (qualify) and the rest (alias) |
| `rtQualify` | quote/comment/field-aware post-pass rewriting `_allocator` → `_rt._allocator` |
| `rtAliasHeader` | reads the referenced set back out of the emitted text — no new tracking in codegen |
| `rtRuntimeText` | the GUI-selected preamble, minus the `_initModuleVars()` back-call |
| `rtAssemble` | one assembly point; off the flag it reproduces the historical shape exactly |
| entry point | drives `_initModuleVars()` over the **transitive** dep list |

**Two findings worth keeping**

1. **The `pub` marking runs in BOTH directions.** Marking the runtime `pub` lets the
   program import it — but the runtime also calls *back into* the program:
   `_ThreadPool.submit(f: anytype)` does `@as(*T, …).call()` on a closure struct that
   *codegen* emitted. Across a module boundary that member needs `pub` too
   (`error: 'call' is not marked 'pub'`). Nothing in the spike surfaced this, because the
   spike only ever split a hello-world. `compile_check --runtime-module` found it on the
   three threading tests — 214/3/1 — and it is the clearest argument for gating the flag
   with the corpus witness rather than a handful of examples.
2. **Step 6 is smaller than "delete the fan-out".** `_allocator`/`_io` do become shared
   and need no propagation, but each module's own `_initModuleVars` still has to be
   reached — which is exactly the transitivity BUG-221 lacked. The fan-out collapses to
   one transitive `_initModuleVars` sweep from the entry point.

**Not yet covered, and refused rather than guessed:** `--runtime-module` errors out when
combined with `--single-file` (both restructure file scope), `--target node-addon`, or any
`--gui-backend` (both scaffold their own build; the GUI section files are not `pub`-marked).

**Gates:** `compile_check --runtime-module` **217/0/1 — identical to the default-mode
baseline**, plus `tools/runtime_module_check.sh` (in the QUICK tier), which is the only
gate that *runs* anything emitted in this mode and therefore the only one that can see
BUG-221 at all.

## 4. What this dissolves

| Bug | How |
|---|---|
| **BUG-220** residual (`@export`/`@node_export` keep source names, so still collidable) | preamble params leave user file scope — nothing to shadow |
| **BUG-221** (module init not transitive; 3-module program with I/O segfaults) | one shared `_allocator`/`_io` — no fan-out at all |
| BUG-215/218-class error locations | errors land in a 30-line file, not a 3,790-line one |

Three bugs, one change, each discovered independently. That convergence is the
strongest argument for doing it.

## 5. Implementation sketch

1. **`stdlib_preamble.zig` → `zebra_rt.zig`**: mark the 395 top-level decls `pub`
   (mechanical). Keep the GUI-backend section selection (`guiSelectPreamble`) — it now
   selects into the runtime module rather than the emitted program.
2. **Codegen — qualify the 19 vars.** The real work. Every emit site writing
   `_allocator`/`_io`/`_error_ctx`/… writes `_rt.` + name instead.
3. **Codegen — emit the header** instead of the preamble: `const _rt =
   @import("zebra_rt.zig");` plus one `const X = _rt.X;` per referenced fn/const.
   Referenced-set can be computed by scanning the emitted user text (a post-pass), so
   no new tracking is needed in codegen.
4. **Write `zebra_rt.zig`** next to the emitted `.zig` so the relative `@import`
   resolves; the GUI scaffold paths need the same.
5. **Break the `_initModuleVars` backward dependency** (§3).
6. Delete the `_initAllocator`/`_initIo` fan-out — BUG-221 goes with it.

## 6. Risks and gates

- **Blast radius is every emitted program.** `compile_check` (independent witness) and
  `full_sweep` are the load-bearing gates; `divergence` will show large bootstrap gaps
  (expected — the bootstrap keeps inlining) which are informational, not regressions.
- **Round-trip** should hold: selfhost-A and selfhost-B both emit the new shape.
  Verify early — it is the cheapest signal that the change is self-consistent.
- **GameEngine** compiles 28/29 today (2026-07-28 baseline, the 29th non-compiling by
  design); re-run after, since it is the largest external corpus.
- Sequencing suggestion: do step 1 + step 3 with vars still inlined (proves the
  import/alias machinery), then step 2, then step 6.
