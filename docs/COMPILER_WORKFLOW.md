# Compiler Workflow — Steps and Gotchas

A reference for doing compiler fixes and feature additions in the Zebra
codebase.  Written for someone who knows the language but hasn't touched
the compiler source before.

---

## Architecture overview

Two compilers exist and must stay in sync:

| Binary | Source | Role |
|--------|--------|------|
| `zig-out/bin/zebra-bootstrap.exe` | `src/*.zig` | Zig-implemented; the "trusted" reference |
| `zig-out/bin/zebra.exe` | `selfhost/*.zig` (generated from `selfhost/*.zbr`) | Selfhost; the primary compiler |

The selfhost compiler is written *in Zebra* (`.zbr` files) and compiled to
Zig (`.zig` files) by the bootstrap compiler.  The `.zig` files are checked
into version control so the repo is always buildable without a pre-existing
selfhost binary.

---

## Build commands

```bash
export PATH="/c/Users/Sean/.zvm/bin:$PATH"   # add Zig to PATH (Git Bash)

zig build                        # build both binaries
zig build test                   # full test suite + selfhost smoke tests
zig build update-selfhost        # re-emit selfhost/*.zig from *.zbr sources
bash tools/bootstrap_check.sh   # 5-step round-trip identity check
```

`zbuild` / `zbuild.bat` are convenience wrappers — same as `zig build`.

---

## The edit-compile-test cycle

### Feature in bootstrap only (`src/*.zig`)

1. Edit the relevant file(s) in `src/`.
2. `zig build test` — full suite.
3. Update `selfhost/*.zbr` for parity (or file a gap note in `SELFHOST_JOURNAL.md`).
4. `zig build update-selfhost` — regenerate `selfhost/*.zig`.
5. `zig build test` again to confirm the selfhost side is green.
6. `bash tools/bootstrap_check.sh` — 5-step round-trip must pass.

### Feature in selfhost only (`selfhost/*.zbr`)

1. Edit the relevant `selfhost/*.zbr` file(s).
2. `zig build update-selfhost` — bootstrap compiles the `.zbr` → `.zig`.
   This is the step that validates your Zebra code actually compiles.
3. `zig build test` — full suite.
4. `bash tools/bootstrap_check.sh` — round-trip check.

### Both compilers (the common case)

Do both sequences above.  If you change `src/Parser.zig`, mirror it in
`selfhost/parser.zbr`; run `update-selfhost` after each `.zbr` change.

---

## The 5-step bootstrap check

`tools/bootstrap_check.sh` verifies the selfhost compiler can reproduce
its own source code byte-for-byte:

1. **Regenerate** — bootstrap emits fresh `.zig` files into `/tmp/bs-zig`.
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

## Known traps

### Dep-mode vs root-mode emit

When the selfhost compiler emits `typechecker.zig` as a **dependency** of
`main.zbr`, it runs in *dep mode*.  Dep-mode files lack `_zbr_error_msg()`
(defined only in root-mode files).  Consequence:

- `e.message` in a `catch |e|` block calls `_zbr_error_msg()` — **breaks in dep mode**.
- **Fix:** use `zig"_error_ctx.message"` instead.  This reads `_error_ctx`
  directly from the preamble, which is available in all emitted files.

### AstBuilder dotted-type restriction in `is` expressions

`selfhost/astbuilder.zbr` rejects `x is Some.Type.Variant` (dotted type path
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

`TypeRef` is a union type.  The bootstrap TypeChecker incorrectly resolves
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

## Filing a selfhost gap vs fixing in place

If a bootstrap feature is hard to port to the selfhost compiler right now,
file a gap note in `SELFHOST_JOURNAL.md` instead of dropping the feature.
The equivalence rule: **the selfhost and bootstrap compilers must be
functionally equivalent**.  Never drop a feature in the selfhost port.

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
| `ast.zbr` | 2 | AST type definitions (`Expr`, `Stmt`, `Decl`, etc.) |
| `parser.zbr` | 3 | Builds `PNode` parse tree from token stream |
| `resolver.zbr` | 4 | Scope analysis, symbol binding |
| `astbuilder.zbr` | 9 | Transforms `PNode` tree → typed AST (`Module`) |
| `typechecker.zbr` | 5 | Type inference (`inferExpr`), conformance checks |
| `cg_helpers.zbr` | 6 | Escape, mutation, and name-use analysis used by codegen |
| `codegen.zbr` | 7 | Zig emission from typed AST |
| `main.zbr` | 8 | CLI entry point, pipeline orchestration |
| `checker.zbr` | — | `zebra check` dead-code detector (optional tool) |
| `stdlib_preamble.zig` | — | Hand-written Zig runtime included in every compiled output |

The bootstrap (`src/`) counterparts follow the same pipeline:
`Tokenizer.zig` → `Parser.zig` → `Resolver.zig` → `TypeChecker.zig`
→ `CodeGen.zig` → `main.zig`.

## Which file to edit

| Symptom | Start here |
|---------|------------|
| Parse error or wrong AST | `src/Parser.zig` (bootstrap), `selfhost/parser.zbr` |
| Resolver error / binding gap | `src/Resolver.zig`, `selfhost/resolver.zbr` |
| Type mismatch / inference gap | `src/TypeChecker.zig`, `selfhost/typechecker.zbr` |
| Wrong Zig output / codegen bug | `src/CodeGen.zig`, `selfhost/codegen.zbr` |
| Wrong helper emit | `selfhost/cg_helpers.zbr`, `src/CodeGen.zig` |
| New AST node type | `src/ast.zig`, `selfhost/ast.zbr`, then all phases |
| New token / keyword | `src/Tokenizer.zig`, `selfhost/Lexer.zbr`, then Parser |
| New stdlib function | `selfhost/stdlib_preamble.zig` + codegen dispatch |
| Dead-code checker gap | `selfhost/checker.zbr` |

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
2. `zig build update-selfhost` — confirms `.zbr` compiles and updates `.zig`.
3. `zig build test` — full suite green.
4. `bash tools/bootstrap_check.sh` — round-trip clean.
5. Commit BOTH the `.zbr` and `.zig` files together.

Never commit `.zig` without the corresponding `.zbr` change — the files
must stay in sync or the next `update-selfhost` will diverge.
