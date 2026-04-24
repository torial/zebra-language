# Zebra — Next Steps

Authoritative priority queue for the project. Update this file rather than regenerating the list from scratch each session.

**Last updated:** 2026-04-24 (session 12 — `--turbo` flag implemented; DESIGN-002 closed)

---

## Immediate (Near-Term Compiler Work)

### 1. Open compiler bugs

**BUG-026** — `instance_method_return_types` gaps for exposed-type method chains  
Not manifesting in practice — `scanMutationsInExpr` conservatively marks cross-module calls as mutated.  
Defer unless a concrete failing case is found.

~~**BUG-083** — `genGenericClass` skips `implements` conformance checks~~ ✓ DONE  
~~**BUG-084** — Selfhost `Lexer.zbr` `parenDepth` tracks `[`/`]`; Zig Tokenizer does not~~ ✓ DONE

~~**BUG-027** — Method chaining in expression position~~  ✓ DONE  
Labeled-block fix in both backends: `(blk_N: { var _mc_N = f(); break :blk_N _mc_N.method(args); })`. Bootstrap 5/5. Throws sub-issue also fixed: `exprCallIsThrows` extended to handle call receivers; `break :blk_N try _mc_N.method(args)` emitted when method `throws`. Selfhost mirrors via `inferExpr`+`isClassMethodThrows`.

**BUG-014** — Regex lazy match is global, not per-quantifier  
`<.*?>STUFF.*>` misbehaves; `lazy_match` is a whole-regex flag.
Architectural fix: priority-first NFA simulation or backtracking engine.
File: `src/CodeGen.zig` NFA preamble. Effort: L

### 2. ~~`for-else` — while-path support (Path 2)~~ ✓ DONE
All paths complete: native `for...else` for list/items; labeled-block pattern for HashMap/split/chars/for-num.
Commit: `79aa9fb`. Bootstrap 5/5.

### ~~3. `interface` codegen~~  ✓ DONE
`interface IFoo` now emits a fat-pointer vtable struct: `ptr: *anyopaque`, `vtable: *const VTable`, forwarding methods, and a `check(comptime T: type)` conformance verifier. `class Foo implements IFoo` sites call `IFoo.check(@This())` in a `comptime` block. Both backends (Zig + selfhost) ported, bootstrap 5/5. Deferred: `wrap()` factory, `callconv(.C)` for DLL crossing, throws-in-vtable — tracked in item #10 (plugin system demo).
Files: `src/CodeGen.zig` (`genInterface` + `genClass`/`genStruct` implements sites), `selfhost/codegen.zbr` (parity).

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

### 11. Contracts: `ensure` + `old` + `--turbo` — core complete
**Done (2026-04-24):** `ensure` now emits a `defer { if (!(expr)) panic(); }` block; `old expr` emits `const _old_N = snapshot;` before body, then substitutes `_old_N` in the defer check. Both Zig and selfhost backends pass 32/32 smoke; bootstrap 5/5.
**Option C refactor done (2026-04-24, session 10):** `old` is now its own `Expr.old_` union variant (`ExprOld { uid: int, operand }`) instead of a `UnaryOp` enum value. UIDs assigned at ASTBuilder construction time (not traversal order), eliminating the ordering dependency. `collectOldInner` retired in favour of single-pass `collectAndEmitOldSnapshots`.
**`--turbo` done (2026-04-24, session 12):** `strip_contracts: bool` field on Generator; `require`/`ensure`/`invariant` emit sites all guarded; `_ = self;` suppression updated; `generateFullWithDeps`/`generateDepWith` chain threads `strip_contracts`; `smoke_turbo` verifies absence of contract strings; both backends; bootstrap 5/5.
**Remaining:**
- `result` capture: no-op today; Resolver gives natural unbound-ident error (acceptable for now)
Note: `wiki/pages/concepts/concept_zebra-0.12-contracts.md` design doc is stale — update alongside a future `result` implementation.
See: `wiki/pages/concepts/concept_zebra-0.12-contracts.md`

### 12. Syntax and ergonomics cleanup (Milestone 0.13)
- ~~Audit which reserved keywords (`set`/`get`/`body`/`same`) are grammar-load-bearing~~ ✓ DONE (`set`/`get`/`body`/`post`/`pro` removed 2026-04-19; `same` kept — TypeRef)
- ~~`implements IfaceName` on the class declaration line~~ ✓ DONE (already on class line; old nested form was never the real parser)
- ~~Float token merge~~ ✓ DONE — `float_lit`/`float_lit_exp`/`fractional_lit` → `float_lit`; bootstrap 5/5.
- ~~`_f32`/`_f64` suffix literal codegen~~ ✓ DONE — `genFloatLit` emits `@as(f32, val)` / `@as(f64, val)`; selfhost parity via `replace()`; 27/27 smoke, bootstrap 5/5.
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
| BUG-085: shared-field bare-name emit — `genIdent` now checks field's own `shared` mod; emits `TypeName.field` not `self.field`; `isSharedField` added to selfhost; both backends; bootstrap 5/5 | 2026-04-24 |
| DESIGN-002: `collectAndEmitOldSnapshots` 8 missing Expr arms — `array_lit`/`list_lit`/`tuple_lit`/`dict_lit`/`string_interp`/`type_check`/`slice`/`except_` added; regression test `contract_old_compound_test.zbr`; 31/31 smoke, bootstrap 5/5 | 2026-04-24 |
| `--turbo` flag: `strip_contracts: bool` on Generator; all require/ensure/invariant emit sites guarded; `_ = self;` suppression updated; generate* chain threads `strip_contracts`; `smoke_turbo` verifier; `turbo_test.zbr`; both backends; bootstrap 5/5 | 2026-04-24 |

---

*Full milestone plan: `wiki/pages/projects/project_zebra.md`*  
*Open bug details: `BUGS.md`*  
*Self-hosting history: `SELFHOST_JOURNAL.md`*
