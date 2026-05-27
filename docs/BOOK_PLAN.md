# Zebra Book Plan — Master TOC and Gap Tracker

Working document for the documentation effort. Each row tracks one chapter/section
against its current coverage in `QUICKSTART.md` (the primary reference document).

**Status legend:**
- ✅ good — complete and accurate
- ⚠️ thin — exists but needs significant expansion
- ❌ missing — feature exists, no docs
- 🔴 stale — docs exist but are wrong/outdated
- 🚫 deferred — intentionally post-1.0

Update status and check the box as each item is addressed.

---

## Part I — Getting Started

| Done | # | Topic | Status | Notes |
|------|---|-------|--------|-------|
| [x] | 1.1 | What is Zebra — philosophy, design goals, Zig backend | ✅ good | Added to Getting Started preamble (2026-05-26) |
| [x] | 1.2 | Installation and setup (Zig version, zvm, PATH) | ✅ good | Added to Getting Started preamble (2026-05-26) |
| [x] | 1.3 | Hello, World — first program, compile and run | ✅ good | Added to Getting Started preamble (2026-05-26) |
| [x] | 1.4 | Compiler subcommands overview | ✅ good | Table in §29 + Getting Started preamble (2026-05-26) |

---

## Part II — Core Language

| Done | # | Topic | Status | Notes |
|------|---|-------|--------|-------|
| [x] | 2.1 | Variables and mutability | ✅ good | §2 |
| [x] | 2.2 | Primitive types | ✅ good | §3 |
| [x] | 2.3 | Operators and expressions (precedence table) | ✅ good | §3.1 added 2026-05-26: 10-level precedence table (postfix → pipeline) |
| [x] | 2.4 | String operations and interpolation | ✅ good | §14 |
| [x] | 2.5 | Raw strings (`r"…"`), triple-quoted strings (`"""…"""`) | ✅ good | §14 expanded 2026-05-26: r'/r" distinction, single-line vs multiline """, exact 3-step stripping rules, content-indent preservation, what each form can contain |
| [x] | 2.6 | Control flow — if/else, inline if, while, for, for-else | ✅ good | §13 |
| [x] | 2.7 | Pattern matching — `branch`/`on`, multi-pattern, guard | ✅ good | §9 (within unions) |
| [x] | 2.8 | Functions — def, parameters, named/default args, return types | ✅ good | §4 expanded 2026-05-26: mixing order, non-contiguous skipping, runtime defaults, type annotation rule |
| [x] | 2.9 | Error handling — `throws`, `raise`, `?`, `catch` | ✅ good | §12 covers throws/raise/catch/?; Result(T) was removed (BUG-074, 2026-04-19) — stale note purged (2026-05-26) |

---

## Part III — Type System

| Done | # | Topic | Status | Notes |
|------|---|-------|--------|-------|
| [x] | 3.1 | Structs — value semantics, `.field` shorthand, `this except` | ✅ good | §6, §7 |
| [x] | 3.2 | Classes — `cue init`, methods, `static def/var` | ✅ good | §5 expanded 2026-05-26: static var/def standalone section with inline + group form |
| [x] | 3.3 | Enums | ✅ good | §8 |
| [x] | 3.4 | Tagged unions — `branch`/`on`, payloads, `is` operator | ✅ good | §9 |
| [x] | 3.5 | Optional types — `T?`, nil, `if x as n`, `?.` chaining, `x!` | ✅ good | §11 expanded 2026-05-26: `?.` semantics, orelse vs catch, chaining; §3.1 precedence table |
| [x] | 3.6 | Collections — `List(T)`, `HashMap(K,V)`, `StrSet` | ✅ good | §10 |
| [x] | 3.7 | Generics | ✅ good | §17 |
| [x] | 3.8 | Interfaces and structural typing | ✅ good | §16 |
| [x] | 3.9 | Type aliases and refinement types | ✅ good | §36, §37 |
| [x] | 3.10 | Tuples and multi-return | ✅ good | §34 |
| [x] | 3.11 | `^T` heap indirection — recursive types | ✅ good | §22 expanded 2026-05-26: auto-boxing rules, `^T?` + nil, branch patterns, List(^T) iteration |

---

## Part IV — Organizing Code

| Done | # | Topic | Status | Notes |
|------|---|-------|--------|-------|
| [x] | 4.1 | Modules and imports — `use`, `exposing`, resolution | ✅ good | §15 |
| [x] | 4.2 | Visibility — `public/private/internal/protected` | ✅ good | §18 covers all 4 keywords + code example; default-to-public rule documented |
| [x] | 4.3 | `namespace` keyword — grouping declarations | ✅ good | §41 added 2026-05-26 |
| [x] | 4.4 | `extend` keyword — adding methods to existing types | ✅ good | §42 added 2026-05-26 |
| [x] | 4.5 | Properties — why there aren't any; methods for computed state | ✅ good | §18 documents removal of prop/get/set/body/post; methods-for-computed-state pattern shown |

---

## Part V — Functions as Values

| Done | # | Topic | Status | Notes |
|------|---|-------|--------|-------|
| [x] | 5.1 | Lambda / closures — syntax, capture semantics, lifetime | ✅ good | §19.1 expanded 2026-05-26: mutation detection (`*@This()` vs `@This()`), class-ptr vs value-type captures, factory pattern |
| [x] | 5.2 | `capture` blocks — persistent per-instance state | ✅ good | §19.1 added 2026-05-26: full semantics, factory pattern, GUI example |
| [x] | 5.3 | `sig` — function type aliases | ✅ good | §20 expanded 2026-05-26: structural typing, calling through sig var, lambda assignment, field pattern |
| [x] | 5.4 | `with` — contextual self | ✅ good | §39 expanded 2026-05-26: rewrite table, nested with, captures, top-level-only rule |
| [x] | 5.5 | `orelse` operator | ✅ good | §11 updated 2026-05-26: `??` error corrected to `orelse`, vs-catch distinction, clear semantics |

---

## Part VI — Annotations and Reflection

| Done | # | Topic | Status | Notes |
|------|---|-------|--------|-------|
| [x] | 6.1 | `@derive(Debug, Eq, Hash)` — auto-generated methods | ✅ good | §43 added 2026-05-26 |
| [x] | 6.2 | Contracts — `require`, `ensure`, `invariant`, `old`, `--turbo` | ✅ good | §24 |
| [x] | 6.3 | Reflection — `@reflectable`, `Reflect.*`, `Json.parseStrict` | ✅ good | §25 expanded 2026-05-26: why @reflectable required (binary size opt-in), T?/List field hard-error, hard-error gate messages |

---

## Part VII — Advanced Features

| Done | # | Topic | Status | Notes |
|------|---|-------|--------|-------|
| [x] | 7.1 | Optional chaining `?.` | ✅ good | §11 expanded 2026-05-26: chaining, flattening, `?.` + `!` combo |
| [x] | 7.2 | `using EXPR` — resource scope blocks | ✅ good | §38 |
| [x] | 7.3 | `DynLib` — plugin / FFI system | ✅ good | §44 added 2026-05-26: open/close/lookup, factory function contract, @export class pre-1.0 note |
| [x] | 7.4 | `zig"…"` escape hatch | ✅ good | §23 |
| [x] | 7.5 | SIMD vector types | ✅ good | §32 |

---

## Part VIII — Concurrency

| Done | # | Topic | Status | Notes |
|------|---|-------|--------|-------|
| [x] | 8.1 | `Chan(T)` channels + `sys.go()` goroutines | ✅ good | §35 |
| [x] | 8.2 | `ThreadPool(n)` — bounded worker pool | ✅ good | §35 expanded 2026-05-26: submit-after-wait, panic policy, vs sys.go() table, chan+pool pattern |
| [x] | 8.3 | `Atomic(T)` — lock-free atomic cells | ✅ good | §31 expanded 2026-05-26: seq-cst ordering, vs Chan table, counter + done-flag examples |

---

## Part IX — Memory Model

| Done | # | Topic | Status | Notes |
|------|---|-------|--------|-------|
| [x] | 9.1 | Memory model overview — arena allocator | ✅ good | §28 |
| [x] | 9.2 | `allocate` blocks — scoped, Arena, Debug, FixedBuffer | ✅ good | §28 |
| [x] | 9.3 | `<-` copy-out semantics | ✅ good | §28 |

---

## Part X — Standard Library Reference

| Done | # | Topic | Status | Notes |
|------|---|-------|--------|-------|
| [x] | 10.1 | `sys` | ✅ good | §31 |
| [x] | 10.2 | `File`, `Dir` | ✅ good | §31 |
| [x] | 10.3 | `Path` | ✅ good | §31 (added 2026-05-26) |
| [x] | 10.4 | `Arg` | ✅ good | §31 |
| [x] | 10.5 | `Math` | ✅ good | §31 |
| [x] | 10.6 | String methods — complete reference table | ✅ good | §14 expanded 2026-05-26: full table (str/int/bool/sequence returns) from TC source |
| [x] | 10.7 | `Json` | ✅ good | §31 |
| [x] | 10.8 | `Hash`, `Random` | ✅ good | §31 |
| [x] | 10.9 | `Regex` | ✅ good | §31 |
| [x] | 10.10 | `DateTime` + IANA timezones | ✅ good | §31 |
| [x] | 10.11 | `Http` client + `Http.serve` | ✅ good | §31 (serve added 2026-05-26) |
| [x] | 10.12 | `Ws` — WebSocket | ✅ good | §31 |
| [x] | 10.13 | `Tcp`, `Udp`, `Net` | ✅ good | §31 |
| [x] | 10.14 | `SQLite` | ✅ good | §40 |
| [x] | 10.15 | `Csv`, `Mime`, `Uri` | ✅ good | §31 |
| [x] | 10.16 | `Compress` (`gzip`/`gunzip`) | ✅ good | §31 (added 2026-05-26) |
| [x] | 10.17 | `Crypto` | ✅ good | §31 (added 2026-05-26) |
| [x] | 10.18 | `Log` | ✅ good | §31 (added 2026-05-26) |
| [x] | 10.19 | `Terminal`, `Timer`, `Progress` | ✅ good | §31 |
| [x] | 10.20 | `Result(T)` — error as value | ✅ good | Feature was removed (BUG-074, 2026-04-19); stale §12 note also removed (2026-05-26) |

---

## Part XI — Tooling

| Done | # | Topic | Status | Notes |
|------|---|-------|--------|-------|
| [x] | 11.1 | `zebra repl` — interactive REPL | ✅ good | §29.repl added 2026-05-26: :help/:clear/:history/:load/:save, multi-line, accumulation model |
| [x] | 11.2 | `zebra test` | ✅ good | §33 |
| [x] | 11.3 | `zebra build` | ✅ good | §29 |
| [x] | 11.4 | `zebra check` — dead-code analysis | ✅ good | §29.check added 2026-05-26: unused arms + unreachable fns |
| [x] | 11.5 | `zebra debug` — DAP integration | ✅ good | §29.debug added 2026-05-26: cross-link to docs/DEBUGGING.md, --listen, IDE setup |
| [x] | 11.6 | Flags reference — `--emit-zig`, `--turbo`, `--gui-backend`, `--zig-backend`, `--output-dir` | ✅ good | §29.flags added 2026-05-26: consolidated table |

---

## Part XII — GUI Programming

| Done | # | Topic | Status | Notes |
|------|---|-------|--------|-------|
| [x] | 12.1 | MVU architecture — init/update/view | ✅ good | §30 (updated 2026-05-26) |
| [x] | 12.2 | Running a GUI program — backends | ✅ good | §30 |
| [x] | 12.3 | Widget reference | ✅ good | §30 |
| [x] | 12.4 | Layout — `beginHBox`, `beginVBox`, `beginPanel` | ✅ good | §30 |
| [x] | 12.5 | File dialogs | ✅ good | §30 (added 2026-05-26) |
| [x] | 12.6 | `CodeEditor` widget | ✅ good | §30 |
| [x] | 12.7 | Frame-callback form (legacy) + tradeoffs vs MVU | ✅ good | §30 expanded 2026-05-26: backend support matrix, when-to-use table, MVU vs frame-callback |

---

## Priority Queue

Items in rough priority order for the next documentation sprint:

### P1 — Missing fundamentals (blocks readers immediately)
1. [x] **1.1** What is Zebra (intro/philosophy) — Getting Started preamble (2026-05-26)
2. [x] **1.2** Installation and setup — Getting Started preamble (2026-05-26)
3. [x] **1.3** Hello, World — Getting Started preamble (2026-05-26)
4. [x] **4.4** `extend` keyword — §42 (2026-05-26)
5. [x] **4.3** `namespace` keyword — §41 (2026-05-26)
6. [x] **6.1** `@derive(Debug, Eq, Hash)` — §43 (2026-05-26)
7. [x] **10.20** `Result(T)` API — feature removed (BUG-074); stale note purged from §12

### P2 — Thin sections that confuse or mislead
8. [x] **2.8** Named/default parameters — expanded §4 (2026-05-26)
9. [x] **5.2** `capture` blocks — §19.1 added (2026-05-26)
10. [x] **3.2** `static def/var` on classes — expanded §5 (2026-05-26)
11. [x] **5.4** `with` — expanded §39 (2026-05-26)
12. [x] **5.5** `orelse` — §11 corrected + expanded (2026-05-26)
13. [x] **7.1** Optional chaining `?.` — §11 expanded (2026-05-26)
14. [x] **10.6** String methods — complete reference table (2026-05-26)

### P3 — Missing tooling docs
15. [x] **11.1** `zebra repl` commands section — §29.repl (2026-05-26)
16. [x] **11.4** `zebra check` section — §29.check (2026-05-26)
17. [x] **11.5** `zebra debug` summary — §29.debug (2026-05-26)
18. [x] **11.6** Consolidated flags reference — §29.flags (2026-05-26)

### P4 — Completeness (advanced/niche)
19. [x] **7.3** `DynLib` section — §44 added (2026-05-26)
20. [x] **5.1** Lambda/closure capture semantics — §19.1 expanded (2026-05-26)
21. [x] **5.3** `sig` edge cases — §20 expanded (2026-05-26)
22. [x] **6.3** Reflection Tier 3 depth — §25 expanded (2026-05-26)
23. [x] **8.2** `ThreadPool` depth — §35 expanded (2026-05-26)
24. [x] **2.3** Operators and precedence table — §3.1 added (2026-05-26)
25. [x] **12.7** Frame-callback vs MVU tradeoffs — §30 expanded (2026-05-26)

### P5 — Stale cleanup
26. [x] **4.5** Properties section — §18 documents removal of prop/get/set/body/post (2026-05-26)
27. [x] **2.9** `Result(T)` stale note — Result(T) removed (BUG-074); note purged (2026-05-26)

### P6 — All resolved

All 81 items now ✅ good.

---

## Stats snapshot (2026-05-26, sprint 2 final)

| Status | Count |
|--------|-------|
| ✅ good | 81 |
| ⚠️ thin | 0 |
| ❌ missing | 0 |
| 🔴 stale | 0 |
| **Total tracked** | **81** |

_Sprint 2 complete: all 81 items ✅ good._

_New items captured as pre-1.0 (added to NEXT_STEPS.md 0.15 cluster):_
- _Nested namespace syntax (`namespace Foo.Bar` / `struct`-inside-namespace workaround documented)_
- _DynLib producer side: `@export class` + `export def` + `zebra build --shared`_
