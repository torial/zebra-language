<!-- doc-status: live -->
# Compiler Workflow — Steps and Gotchas

A reference for doing compiler fixes and feature additions in the Zebra
codebase.  Written for someone who knows the language but hasn't touched
the compiler source before.

**See also:** [`QA_TOOLS.md`](QA_TOOLS.md) — which verification tool proves what and
how to read a failure (the gate sequence, diagnostic tells).
[`COVERAGE_MAP.md`](COVERAGE_MAP.md) — what those tools do *not* cover (the risk
surface). [`../tools/PROBES.md`](../tools/PROBES.md), [`../fuzz/README.md`](../fuzz/README.md).

---

## Architecture overview

One compiler, written in Zebra:

| Binary | Source | Role |
|--------|--------|------|
| `zig-out/bin/zebra.exe` | `selfhost/*.zig` (generated from `selfhost/*.zbr`) | the compiler |

The compiler is written *in Zebra* (`.zbr` files) and compiled to Zig (`.zig`
files) by the previous generation of itself — the `zebra.exe` built from the
COMMITTED `.zig` (the N-1 regen authority, since 2026-08-30). The `.zig` files
are checked into version control so the repo is always buildable with nothing
but `zig`; `tools/regen_recover.sh` rebuilds a compiler from them for any commit
in history when the working one is broken.

Until 2026-09-16 a second compiler existed — the Zig-implemented bootstrap in
`src/`, `zebra-bootstrap.exe` — and this document described keeping the two in
sync. It was retired in `docs/design/bootstrap_sunset.md`; the "both compilers"
sections below are gone with it, and its counterpart files (one `.zig` per stage
under `src/`) are only in `git log`.

---

## Build commands

```bash
export PATH="/c/Users/Sean/.zvm/bin:$PATH"   # add Zig to PATH (Git Bash)

zig build                        # build zebra.exe
zig build test                   # full test suite + selfhost smoke tests
zig build update-selfhost        # re-emit selfhost/*.zig from *.zbr sources
bash tools/bootstrap_check.sh   # 5-step round-trip identity check
```

`zbuild` / `zbuild.bat` are convenience wrappers — same as `zig build`.

---

## The edit-compile-test cycle

### A compiler change (`selfhost/*.zbr`)

1. Edit the relevant `selfhost/*.zbr` file(s).
2. `bash tools/rebuild.sh` — regenerate `selfhost/*.zig` with the N-1 compiler
   and build (`--module CodeGen` for the ~10 s inner loop). This is the step
   that validates your Zebra code actually compiles.
3. `bash tools/gates.sh` — the QUICK tier (smoke + round-trip + the static gates).
4. `bash tools/gates.sh --full` before committing a codegen change.

---

## The 5-step bootstrap check

`tools/bootstrap_check.sh` verifies the selfhost compiler can reproduce
its own source code byte-for-byte:

1. **Regenerate** — the committed compiler emits fresh `.zig` files into `/tmp/bs-zig`.
2. **Build A** — compile selfhost-A from those fresh `.zig` files.
3. **Re-emit** — selfhost-A emits its OWN source (selfhost compiles selfhost).
4. **Build B** — compile selfhost-B from selfhost-A's output.
5. **Diff** — selfhost-B's output must be byte-identical to selfhost-A's output.

A pass here means the selfhost compiler is self-consistent and round-trips
cleanly.  This is the primary gate before committing selfhost changes.

Use `--update` to also write the regenerated files back to `selfhost/`:
```bash
bash tools/bootstrap_check.sh --update
```

---

## Generated file workflow

`selfhost/*.zig` files are **artifacts**, not sources.  The sources are
`selfhost/*.zbr`.  Rules:

- Never edit `selfhost/*.zig` by hand — your changes will be overwritten by
  the next `update-selfhost`.
- Always commit both the `.zbr` source AND the corresponding regenerated
  `.zig` so the repo stays buildable without a selfhost binary.
- After an `update-selfhost`, check `git diff selfhost/*.zig` to confirm the
  generated output looks right before committing.

---

## Before you write it: grep here first

Three times in two days I built machinery the compiler already had, and each time the
existing version was better than what I was writing. The pattern is consistent enough to
be worth a checklist: **when you find yourself adding state to a walker, or a counter, or
a naming scheme for emitted temporaries, grep before you type.** The compiler is ~40k
lines of Zebra; the thing you need has usually already been needed.

| you are about to add | it already exists as | where |
|---|---|---|
| a counter tracking `(` / `)` nesting while scanning | `parenDepth`, maintained by `scanToken` | `selfhost/Lexer.zbr:70` (decl), `:349` (maintenance) |
| a scheme for naming a temporary in emitted Zig | `w.nextUid()` + a `blk_*` / `_*_` label pair — **37 call sites** | `selfhost/CodeGen.zbr:2330` (def), `:3656`, `:5808`, … |
| a set of "which union variants carry a `^T` payload" | `g.boxed_variants: StrSet`, keyed `"Union.variant"`, populated by `populateBoxedVariants` | `selfhost/CodeGen.zbr:2358` (field), `:863`, `:880` |

The receipts, because the failure is more instructive than the rule:

* **`parenDepth`.** Fixing BUG-231 (a `:` inside `${f(a, b)}` being read as a format
  spec) I wrote *three separate counters* across two attempts before noticing the lexer
  had tracked paren nesting since it was written. The tell I ignored: `scanToken()`
  consumes `f(` in one step, so any counter I maintained in the interpolation scanner was
  always going to be counting a different thing than the one that mattered.
* **The labeled-block emit idiom.** Fixing BUG-230 (an annotated non-empty list literal)
  I designed a label/variable naming scheme from scratch. There were already 37 uses of
  the identical shape a few hundred lines away, including the `uid`/`label`/`var` triple
  and the `break :label value;` terminator.
* **`boxed_variants`.** Re-derived "which variants need boxing" from the AST when the
  answer was a populated `StrSet` on the generator.

**Why this keeps happening, and the cheap defence.** The compiler's helpers are named for
what they *are* (`parenDepth`, `boxed_variants`), while you arrive knowing what you
*want* ("track nesting", "is this payload heap-indirected"). Those vocabularies do not
meet. So grep the **noun**, not the verb: `grep -n "Depth\|depth" selfhost/Lexer.zbr`
beats searching for "nesting". And when a fix feels like it needs new bookkeeping, that
is precisely the moment to look — new bookkeeping in a mature compiler is the unusual
case, not the normal one.

## Known traps

### Dep-mode vs root-mode emit

When the selfhost compiler emits `typechecker.zig` as a **dependency** of
`main.zbr`, it runs in *dep mode*.  Dep-mode files lack `_zbr_error_msg()`
(defined only in root-mode files).  Consequence:

- `e.message` in a `catch |e|` block calls `_zbr_error_msg()` — **breaks in dep mode**.
- **Fix:** use `zig"_error_ctx.message"` instead.  This reads `_error_ctx`
  directly from the preamble, which is available in all emitted files.

### AstBuilder dotted-type restriction in `is` expressions

`selfhost/AstBuilder.zbr` rejects `x is Some.Type.Variant` (dotted type path
in an `is` expression).  Use `branch kind on TokenKind.X` (19 arms) instead of
chained `if kind is Token.TokenKind.X` when dispatching on token kinds.

Existing methods `isEol()` and `isIndent()` use the `branch/on` pattern —
follow that style.

### Zig 0.16 "var never mutated" analysis

Zig 0.16 added stricter mutation analysis.  If you write:
```zebra
var decls = List(PNode)()
tryParseTopDeclInto(decls)   # auto-ref coercion: passes *List(PNode)
```
Zig 0.16 may flag `decls` as "never mutated" because the auto-ref coercion
(`*List(PNode)`) is not counted as a mutation of the local.

**Fix:** move the variable to a class field, eliminating the local entirely.

### CRLF hazard on `.zbr` files

The Zebra tokenizer requires LF-only (`\n`) line endings.  A `\r` character
triggers `error.UnexpectedCharacter` with no source location, making the
failure look unrelated.

On Windows, Python's `open(..., 'w')` writes CRLF by default:
```python
# CORRECT — LF only
with open('file.zbr', 'w', encoding='utf-8', newline='\n') as f:
    f.write(content)

# WRONG on Windows — crashes tokenizer
with open('file.zbr', 'w', encoding='utf-8') as f:
    f.write(content)
```

If you suspect CRLF: `file selfhost/foo.zbr` reports `CRLF line terminators`.

### The `--update` corpus-sweep hazard

Running `zebra --emit-zig` across the whole corpus (as some tools do)
writes `.zig` files into the source tree.  If you have WIP changes in
`selfhost/*.zig`, a corpus sweep will overwrite them.

**Rule:** stash or worktree-isolate before running any sweep.  Never
`git checkout -- .` with WIP present.

### `^T?` optional binding gives a pointer, not a value

`if x as n` on a **boxed optional** (`^T?`) binds `n` as `^T` (a pointer),
not `T` (the value).  Functions that accept `T` by value (e.g. `walkExpr`,
`inferExpr`, `exprHasTry`, `nameUsedInExpr`) will fail with a Zig type error
like `expected type 'ast.Expr', found '*ast.Expr'` — only surfaced in
dep-mode builds where strict typing is enforced.

```zebra
# WRONG — n has type ^Expr, not Expr
if node.init_expr as n
    walkExpr(n, ctx)

# CORRECT — to! generates .?.* which unwraps optional AND dereferences
if node.init_expr != nil
    walkExpr(node.init_expr to!, ctx)
```

The rule: `if x as n` is safe for plain optionals (`str?`, `int?`,
`List(T)?`).  For boxed optionals (`^T?`) always use `!= nil` + `to!`.

### `TypeRef?` fields behave like `^T?` in dep-mode

`TypeRef` is a union type.  The TypeChecker (a bootstrap-era gap that the
selfhost inherited) incorrectly resolves
`TypeRef?` field accesses as non-optional in certain dep-mode contexts —
`if x as n` then reports `'if x as n' requires an optional type, got
'TypeRef'`.

Apply the same fix: `if x.field != nil` + `x.field to!`.  Affected fields:
`type_`, `return_type`, `payload` (on `VariantDecl`), `elem_type`, `base`
(on `DeclEnum`).

### `on` is a reserved keyword — avoid as binding names

`on` is reserved for `branch ... on ...` arms.  Writing `if x as on` is a
parse error.  If you need a short binding name for an `on`-arm pattern value,
use a suffix: `obj_n`, `obj_name`, `vn`, etc.

### Concurrent bootstrap checks race on `/tmp/bs-zig`

`tools/bootstrap_check.sh` (and `zig build update-selfhost`) both write
generated files to `/tmp/bs-zig`.  Running two checks concurrently (e.g.
two background tasks) corrupts the directory mid-build, producing spurious
errors like "struct 'checker' has no member named '_initAllocator'".

**Rule:** run at most one bootstrap check at a time.  Wait for completion
before starting another.

---

## The equivalence rule, after the port

While the bootstrap existed the rule was "the selfhost must be functionally
equivalent to the Zig compiler in `src/`", and a feature too hard to port was
filed as a gap in `docs/SELFHOST_JOURNAL.md` rather than dropped. The port is
complete and the reference is gone; the rule is now **equivalence with the
previous release** — the N-1 anchor `tools/divergence_check.sh` compares
against — and a feature that stops working is a `REGRESSION` there, not a gap.

---

## Test infrastructure

### Full test suite

```bash
zig build test          # runs selfhost_smoke.sh + zig build unit tests
```

### Selfhost smoke tests

```bash
bash tools/selfhost_smoke.sh     # fast — emit-zig only, no Zig compilation
```

Smoke helpers:
- `smoke FILE` — expects exit 0
- `smoke_run FILE "expected output"` — expects exit 0 and specific stdout
- `smoke_tc_fail FILE "expected error substring"` — expects exit 1 and specific stderr
- `smoke_multi_parse_fail FILE "msg1" "msg2"` — expects exit 1 with both substrings

The smoke script uses `$REPO/zig-out/bin/zebra.exe` (selfhost binary).
Build it first with `zig build`.

### Race condition: parallel test runs

`tools/selfhost_smoke.sh` uses `/tmp/selfhost-smoke` as a shared output
directory.  Running `zig build test` concurrently from two terminals
causes `File.write error` panics (both processes racing to create files
in the same directory).  Always run one test at a time.

---

## Selfhost file map

Each `selfhost/*.zbr` file corresponds to one compiler phase:

| File | Phase | What it does |
|------|-------|--------------|
| `Lexer.zbr` | 1 | Tokenizes source text into `Token` stream |
| `Ast.zbr` | 2 | AST type definitions (`Expr`, `Stmt`, `Decl`, etc.) |
| `Parser.zbr` | 3 | Builds `PNode` parse tree from token stream |
| `Resolver.zbr` | 4 | Scope analysis, symbol binding |
| `AstBuilder.zbr` | 9 | Transforms `PNode` tree → typed AST (`Module`) |
| `TypeChecker.zbr` | 5 | Type inference (`inferExpr`), conformance checks |
| `CgHelpers.zbr` | 6 | Escape, mutation, and name-use analysis used by codegen |
| `CodeGen.zbr` | 7 | Zig emission from typed AST |
| `main.zbr` | 8 | CLI entry point, pipeline orchestration |
| `Checker.zbr` | — | `zebra check` dead-code detector (optional tool) |
| `stdlib_preamble.zig` | — | Hand-written Zig runtime included in every compiled output |

(The bootstrap's `src/` counterparts followed the same pipeline, one `.zig`
per stage; retired 2026-09-16.)

## Which file to edit

| Symptom | Start here |
|---------|------------|
| Parse error or wrong AST | `selfhost/Parser.zbr` |
| Resolver error / binding gap | `selfhost/Resolver.zbr` |
| Type mismatch / inference gap | `selfhost/TypeChecker.zbr` |
| Wrong Zig output / codegen bug | `selfhost/CodeGen.zbr` |
| Wrong helper emit | `selfhost/CgHelpers.zbr` |
| New AST node type | `selfhost/Ast.zbr`, then all phases |
| New token / keyword | `selfhost/Token.zbr` (the table), `selfhost/Lexer.zbr`, then Parser |
| New stdlib function | `selfhost/stdlib_preamble.zig` + codegen dispatch |
| Dead-code checker gap | `selfhost/Checker.zbr` |

---

## Selfhost code style

Follow these patterns when writing or modifying `selfhost/*.zbr`:

**Use `for-in` instead of manual while loops.**
```zebra
# Preferred
for item in list
    process(item)

# Avoid (unless you genuinely need the index)
var i: int = 0
while i < list.count()
    process(list.at(i))
    i = i + 1
```

**Use `if x as n` for plain optionals; use `!= nil` + `to!` for `^T?`.**
```zebra
if token.name as n      # str? — fine, n: str
    emit(n)

if node.init_expr != nil                        # ^Expr? — must deref
    emit_expr(node.init_expr to!)
```

**Use `branch` for exhaustive union dispatch, not `if-else if` chains.**
```zebra
branch expr
    on Expr.ident as id   # compiler warns if a variant is unhandled
        ...
    on Expr.call as c
        ...
    else
        pass
```

**Prefer `fetch()` over `contains()` + `fetch()` for HashMap lookups.**
```zebra
if map.fetch(key) as val   # single lookup
    use(val)
```

---

## Committing selfhost changes

1. Edit `.zbr` source(s).
2. `bash tools/rebuild.sh` — confirms `.zbr` compiles and updates `.zig`.
3. `bash tools/gates.sh` (or `--full`) — green.
4. Commit BOTH the `.zbr` and `.zig` files together.

Never commit `.zig` without the corresponding `.zbr` change — the files
must stay in sync or the next `update-selfhost` will diverge.
