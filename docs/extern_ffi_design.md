<!-- doc-status: design -->
# `extern` — declaring foreign symbols (BUG-258)

**Status:** designed, not implemented. Findings below are measured; the plan is not built.
**Decided by Sean 2026-08-05:** `extern` is meant to exist, to enable the FFI work.
**Written 2026-08-05 by Opus 5** after verifying BUG-258 in the tree.

---

## 1. What is actually true today (measured, not assumed)

| | `extern def foo(): int` |
|---|---|
| **selfhost** (`zebra.exe`) | rejects: *unexpected top-level token: 'extern'* — **correct** |
| **bootstrap** (`zebra-bootstrap.exe`) | **accepts**, drops the modifier, emits `unreachable; // abstract` |

The bootstrap's output **compiles** (verified by building it to an `.exe`). So an `extern`
declaration today becomes an abstract method that traps in Debug and is **undefined
behaviour under `zebra --release`** (ReleaseFast). That is worse than a clean rejection,
and it means **the selfhost is right and the bootstrap is wrong here** — the same inversion
as BUG-254.

**There is no other way to declare a foreign symbol.** The `zig"…"` escape hatch is
statement-level only; at top level **both** compilers reject it:

    zz_ziglit_top.zbr:1:1: error: unexpected top-level token: 'zig"extern fn strlen(…) usize;"'
    zz_ziglit_top.zbr:1:1: syntax error near 'zig"extern fn strlen(…) usize;"'   (bootstrap)

So the blockage reported against `zebra-sprocket` is real: there is no route from Zebra to
`sqlite3_proc_next_resultset()`.

**Two of the three pieces already exist**, which is what makes this tractable:

- **C-ABI-sized types.** `int8/16/32/64`, `uint8/16/32/64`, `float32/64` all exist and map
  to `i32`, `u8`, … (`src/Builtins.zig:201+`). `int32` is `c_int` on every platform Zebra
  targets, so the ABI is expressible without new syntax.
- **Linking.** `BuildTarget.linkLib` exists in the Build stdlib
  (`src/CodeGen.zig:10059` → `_build_target_link_lib`), reachable from `build.zbr`.
  *Caveat: `BuildTarget` is one of the seven names with no corpus coverage at all
  (see the 0.9-beta checklist §E), so it is declared but unexercised — confirm it works
  before depending on it.*
- **Missing: the declaration itself.** That is this document.

`@cImport(@cInclude("x.h"))` also exists for C deps that ship a header
(`src/CodeGen.zig:4908`). `extern` is for the case with no header, or where you want a
single symbol without pulling a translation unit.

---

## 2. The design decision, and the default

**Default (A): minimal and honest.** `extern def name(params): ret` with **no body** emits

    extern fn name(params) ret;

using the existing Zebra→Zig type mapping and Zig's default C calling convention for
`extern fn`. The author is responsible for two things, both already expressible:

- using ABI-correct types (`int32`, not `int` — `int` is `i64`, which is *not* C's `int`)
- linking the library from `build.zbr` via `BuildTarget.linkLib`

**Rejected (B): the fuller surface** — C-type aliases (`cint`, `csize`, `cstr`), symbol
renaming (`extern def foo(): int = "c_foo"`), calling-convention control, automatic libc
linking. Each is defensible and none is needed to unblock the sprocket work. B is a
feature programme; A is one increment that makes the programme possible. Ship A, and let
real FFI use say which part of B is actually wanted.

**The one thing A must not do is what the bootstrap does now**: accept the declaration and
emit something that compiles but is wrong.

---

## 3. Implementation plan

Ordered so that each step is independently verifiable, and so the tree is never
half-updated (`rebuild.sh --module` refuses a partial regen for exactly this reason).

### 3.1 Selfhost front end

The selfhost parses into a `PNode`/`PMethod` layer carrying explicit booleans, which
`AstBuilder` converts to `Ast.Modifiers`. `Ast.Modifiers` **already has `is_extern`**
(`selfhost/Ast.zbr:63`) — it is declared and never set. So:

1. `selfhost/Parser.zbr` — add `is_extern` to `PMethod` (near `is_export`, line ~358) and
   to its `cue init` (line ~364). Thread it through `parseMethodDecl` (line ~1898) and the
   `PNode.method_` construction (line ~1986).
2. `selfhost/Parser.zbr` — accept `kw_extern` in the top-level modifier position. Note
   `isRecoveryStarter` (line ~886) **already lists `kw_extern`**, so error recovery knows
   about it while the decl dispatcher does not; that asymmetry is the bug.
3. `selfhost/AstBuilder.zbr` — map `PMethod.is_extern` → `Modifiers.is_extern`. Watch the
   positional `Modifiers(...)` constructors (`zmods()`, `zstatic()`, line ~34) — 15
   positional booleans, so an inserted field silently shifts every later argument. **Add at
   the end or use named fields; do not insert in the middle.**

*The signature change is the risk in this step.* `parseMethodDecl` has many call sites and
the booleans are positional. A defaulted parameter (`is_extern: bool = false`) keeps every
existing call correct.

### 3.2 Selfhost codegen

4. `selfhost/CodeGen.zbr` — when `mods.is_extern`, emit `extern fn NAME(params) RET;` and
   **no body**. A body on an extern declaration is a Zig compile error, which is a useful
   property: getting this wrong fails loudly rather than silently.

### 3.3 Bootstrap

5. `src/CodeGen.zig:6141` is the `unreachable; // abstract` site. An extern method must
   take a different branch and emit the declaration. **This is not optional politeness** —
   the bootstrap is the regen authority *and* the `--gui-backend` path, and leaving it
   emitting UB for a now-supported keyword is worse than the current state, because the
   selfhost would start accepting programs the bootstrap silently miscompiles.

### 3.4 Gates

6. `test/` fixtures: a declaration-only extern that **compiles** (link not required if
   never called), and — the important one — a `smoke_run` that actually **calls** a
   foreign function and checks the printed result. Compile-only proves nothing here; the
   whole failure mode of this feature is a declaration that links to nothing or to the
   wrong ABI.
7. A `boundary_check` probe, since this is a language-reference claim.
8. `divergence_check` must stay at 0 selfhost gaps — with step 5 done, both compilers
   emit the same thing.

### 3.5 Docs

9. QUICKSTART §23 currently presents `zig"…"` as *the* escape hatch. It needs an `extern`
   section stating the ABI rule (`int32`, not `int`) and pointing at `BuildTarget.linkLib`.
10. `grammar.txt` needs no edit — it is generated, and `kw_extern` is already in the rule
    table at `src/ZebraGrammar.zig:348,351,370`. This implementation makes the document
    true rather than requiring it to change.

---

## 4. What would make this wrong

Recorded so the implementer checks these rather than rediscovering them:

- **`int` is `i64`, not C's `int`.** An `extern def f(n: int)` against a C `int` parameter
  is an ABI mismatch that links fine and corrupts the stack. This is the single most
  likely way to get a green build and a wrong program, so the doc change (step 9) is part
  of the feature, not follow-up.
- **A compile-only fixture would pass while the feature is broken.** See §3.4.
- **The 15 positional booleans in `Modifiers(...)`.** Inserting a field mid-list shifts
  every argument after it, and they are all `bool`, so nothing type-errors.
- **Symbol name = Zebra name.** With no renaming (decision A), a C symbol that is not a
  legal Zebra identifier cannot be reached. That is a known limit of A, not an oversight;
  it is the first thing to revisit if real use hits it.

---

## 5. Not in scope

Deliberately out, and each would be its own decision:

- `extern` on anything but a `def` (variables, types, classes).
- Varargs (`printf`-style).
- Struct-by-value across the boundary — Zebra structs are not `extern struct`.
- Callbacks from C into Zebra (needs `export` plus a stable calling convention; `export`
  already works, so this is closer than the rest).
- Any `zebra build` change. `BuildTarget.linkLib` is assumed sufficient and **unverified**.
