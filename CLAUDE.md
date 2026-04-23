# CLAUDE.md

Guidance for Claude Code (claude.ai/code) in this repository.

## What this is

**Zebra** is a programming language whose compiler is written in Zig, with an
in-progress self-hosted port in Zebra itself. The name is a portmanteau of Zig
and Cobra; language design draws on Python, Cobra, and Eiffel (contracts, nil
tracking) with a Zig runtime and error model.

History note: this repo was split out from the archived `torial/cobra-language`
repo on 2026-04-16. See `docs/archive/HERITAGE.md` for the background and where the older
history lives.

## Repository layout

- `src/` — the Zig-implemented Zebra compiler (Tokenizer, Parser, Resolver,
  TypeChecker, CodeGen, Builtins, etc.). This is the trusted/production compiler.
- `selfhost/` — the in-progress self-hosted compiler written in Zebra (`*.zbr`).
  Each phase mirrors a file in `src/` (e.g. `parser.zbr` ↔ `src/Parser.zig`).
  Paired `*.zig` files are generated artifacts.
- `test/` — integration test suite (`.zbr` fixtures + runners).
- `tools/` — ancillary tools (build/runner scripts, etc.).
- `IDE/` — self-hosted IDE experiments using the Dear ImGui GUI backend.
- `examples/` — sample Zebra programs.
- `build.zig` / `build.zig.zon` — Zig build driver.
- `zbuild` / `zbuild.bat` — convenience wrappers around `zig build`.
- `QUICKSTART.md` — **agent-facing Zebra language reference**. Read this before
  writing or reading `.zbr` code.
- `SELFHOST_JOURNAL.md` — phase-by-phase notes on porting the compiler to Zebra.
- `BUGS.md` — active compiler bug tracker.
- `NEXT_STEPS.md` — **authoritative priority queue** for upcoming work. Read this before generating a new task list.
- `STDLIB_ROADMAP.md` — standard library plan.
- `grammar.txt` — language grammar reference.

## Build and test

From the repo root:

```bash
zig build                                    # build the Zebra compiler
zig build run -- path/to/file.zbr            # compile and run a Zebra source file
zig build test                               # run the test suite
./zbuild                                     # convenience wrapper (Unix)
zbuild.bat                                   # convenience wrapper (Windows)
```

Module resolution: `use module_name` is looked up relative to the input file,
then in `selfhost/`, `test/`, and stdlib paths.

## Self-hosting

The self-hosting effort lives in `selfhost/`. Rule of thumb for this port:
**the Zebra compiler in `selfhost/` must be functionally equivalent to the
Zig compiler in `src/`.** When closing a gap, do not drop features in the
selfhost port — that creates a regression in the selfhosted side. See
`SELFHOST_JOURNAL.md` for how each phase was done.

## Language quick reference

`QUICKSTART.md` is the authoritative syntax/semantics cheat-sheet for the
Zebra language itself. Skim sections 1–14 before authoring any `.zbr` code.
Key idioms worth remembering up front:

- `var` is always mutable; the compiler emits `const` vs `var` in Zig based
  on mutation analysis.
- `^T` on a field type is heap-indirection (`*T` in Zig). Auto-boxed on
  assignment; transparent when bound inside a `branch` arm.
- `this except field = value, ...` is the immutable-update idiom for structs.
- `throws` methods return `anyerror!T` in Zig; same-file throws-to-throws calls
  auto-propagate, cross-module/local-variable calls need explicit `expr?`.
- Method chaining on struct temporaries (`f().method()`) is auto-materialized
  by the compiler in var-init, return, and assignment positions. Expression-
  position chains (call args, compound expressions) still need a manual temp.

## Common workflows

**Adding a feature to the compiler:**
1. Add the Zig implementation in the appropriate `src/` file.
2. Extend the test suite in `test/`.
3. Update `selfhost/` to keep parity, or file a gap note in `SELFHOST_JOURNAL.md`.
4. Update `QUICKSTART.md` if user-visible syntax or semantics change.

**Self-hosting (Phase 22 complete):**
- `zig build` now produces `zig-out/bin/zebra.exe` from `selfhost/main.zig` (primary).
- `zig-out/bin/zebra-bootstrap.exe` is the Zig-implemented compiler, used by
  `tools/bootstrap_check.sh` to regenerate `selfhost/*.zig` from `*.zbr` sources.
- Keep intermediate Zig files using `zebra --emit-zig` or `--output-dir DIR`.
- Escape hatch: `zebra --zig-backend file.zbr` delegates to `zebra-bootstrap.exe`.

## Notes

- Platform: Windows is the primary dev environment; bash paths via Git Bash.
- Binaries and build caches (`*.exe`, `*.pdb`, `.zig-cache/`, `zig-out/`) are
  gitignored — do not commit them.
- The `archive/pre-zebra-split` tag in the old cobra-language repo records
  the state at split time.

## Line endings — CRLF hazard for `.zbr` files

The Zebra tokenizer requires **LF-only** (`\n`) line endings. A `\r` character is
treated as an unexpected character and causes a tokenizer crash with the message
`internal compiler error: error.UnexpectedCharacter` — no source location is
reported, making the failure look unrelated.

**How this bites you on Windows:** Python's `open(..., 'w')` writes CRLF by
default. Any script that reads and rewrites a `.zbr` file must pass
`newline='\n'` explicitly:

```python
# CORRECT — LF only
with open('file.zbr', 'w', encoding='utf-8', newline='\n') as f:
    f.write(content)

# WRONG on Windows — writes CRLF, crashes the tokenizer
with open('file.zbr', 'w', encoding='utf-8') as f:
    f.write(content)
```

Git `core.autocrlf` can mask this on checkout, but the repo `.gitattributes`
normalises `.zbr` to LF. If you suspect CRLF: `file selfhost/foo.zbr` will
report `CRLF line terminators` vs `ASCII text`.
