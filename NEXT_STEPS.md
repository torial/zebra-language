# Zebra — Next Steps

Authoritative priority queue for the project. Update this file rather than regenerating the list from scratch each session.

**Last updated:** 2026-04-23

---

## Immediate (Near-Term Compiler Work)

### 1. Open compiler bugs

**BUG-002** — `guard` / `try_postfix` error propagation  
Top-level `try Main.main()` panics with `error: ZebraError` instead of clean display.
Test fixtures need `try/catch` wrapping; may also need a top-level error display fix in `src/main.zig`.
Files: `test/guard_test.zbr`, `test/try_postfix_test.zbr`

**BUG-026** — `instance_method_return_types` gaps for exposed-type method chains  
Method chains on cross-module types may emit `const` instead of `var`.
File: `src/TypeChecker.zig` → `buildModuleInterface`

**BUG-027** — Method chaining in expression position  
Statement-position auto-hoist (`var r = f().method()`) is fixed. Expression-position
(`return f().method()`, call-arg chains) still needs the same auto-materialize treatment.
File: `src/CodeGen.zig` → `genExpr`

**BUG-014** — Regex lazy match is global, not per-quantifier  
`<.*?>STUFF.*>` misbehaves; `lazy_match` is a whole-regex flag.
Architectural fix: priority-first NFA simulation or backtracking engine.
File: `src/CodeGen.zig` NFA preamble. Effort: L

### 2. `for-else` support
Python-style `for x in list\n    body\nelse\n    fallback` — else block runs when the iterable
was empty (or loop never broke). Needs: grammar rule, AST node, Resolver walk, CodeGen.

### 3. `interface` codegen
Parser/AST/Resolver for `interface` declarations are done. CodeGen needs to emit:
- A vtable struct from the interface declaration
- Method dispatch through the vtable (fat-pointer or explicit passing)

This is the prerequisite for the plugin system and unlocks clean Zebra-native vtable APIs.
Files: `src/CodeGen.zig`, then selfhost port in `selfhost/codegen.zbr`.

### 5. HashMap.remove — selfhost parity check
`HashMap.remove(key)` works in the Zig backend. Verify and add to `selfhost/codegen.zbr`
if missing from the `genHashMapMethod` dispatch.

---

## Medium Term (Milestone Features)

### 6. REPL (Milestone 0.6)
Two-phase approach: warm-up pre-compiled preamble once → per-input incremental compile.
"Accumulate and rerun" state model (all previous cells stay in scope).
See design notes in `selfhost/` journal and `SELFHOST_JOURNAL.md`.

### 7. Regex per-quantifier lazy/greedy (Milestone 0.7)
Unblocked by BUG-014 fix. Mixed lazy/greedy patterns (`<.*?>STUFF.*>`) require the NFA
to track per-node shortest/longest flags, not a global flag.

### 8. Pattern matching with destructuring in `branch` (Milestone 0.7)
Match on struct field values (`on Point{x: 0, y: 0}`), not only union tags.
Extends the existing branch/guard infrastructure.

### 9. Greek NT n-gram port (anytime — real-world stress test)
Port the Python Unicode n-gram analysis script for the Greek New Testament to Zebra.
Exercises: file I/O, `HashMap` with Unicode keys, sort, sliding n-gram window.
Good benchmark: if this runs correctly and fast, the language is production-capable for text work.

### 10. Plugin system — DynLib demo (after `interface` codegen)
Round-trip: a toy "Hello" plugin DLL loaded by a host program via `std.DynLib`.
Depends on `interface` codegen (step 4 above) and a thin `DynLib` stdlib wrapper.
See: `wiki/pages/concepts/concept_zebra-plugin-system.md`

### 11. Contracts runtime (Milestone 0.12)
`require`/`ensure`/`invariant`/`old` emit runtime checks. AST, parser, and TypeChecker
are already done — only CodeGen emission is missing.
`-turbo` flag strips contracts for production builds.
See: `wiki/pages/concepts/concept_zebra-0.12-contracts.md`

### 12. Syntax and ergonomics cleanup (Milestone 0.13)
- Audit which reserved keywords (`set`/`get`/`body`/`same`) are actually grammar-load-bearing
- `implements IfaceName` on the class declaration line (not a separate indented block)
- Float token merge (integer + `.` + integer as one token in more contexts)
- `^T` auto-boxing edge case fixes
- Book documentation for `sig`, raw strings, `"""`
See: `wiki/pages/concepts/concept_zebra-0.12-syntax-cleanup.md`

---

## Longer Term (1.0 and Beyond)

### 13. VCS in Zebra (agent-tools phase — before IDE)
A version-control tool written in Zebra, inspired by Mercurial and Fossil.
Priority over the IDE because VCS tooling is load-bearing for the self-hosting workflow itself
(safe WIP management, corpus snapshots, bisect). See: `wiki/pages/projects/project_zebra.md`

### 14. IDE — self-hosted (post contracts)
Self-hosted Zebra + ImGui editor with:
- Syntax highlighting via `ImGuiColorTextEdit` (pthom fork)
- Inline diagnostics (source-mapped errors already done)
- REPL pane
- Plugin loading via the DynLib plugin system

See: `wiki/pages/concepts/concept_zebra-imgui-backend.md`, `concept_zebra-pthom-editor.md`

### 15. 1.0 — Language stability
- Type aliases with constraints (`type Name = str where len > 0`)
- WebSocket (`Ws.connect/send/recv/close`)
- Allocator context (Odin-style named implicit allocator)
- `Chan(T)` channels (`ch <- val` / `var v <- ch`)
- CHANGELOG

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

---

*Full milestone plan: `wiki/pages/projects/project_zebra.md`*  
*Open bug details: `BUGS.md`*  
*Self-hosting history: `SELFHOST_JOURNAL.md`*
