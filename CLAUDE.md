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
  Each phase mirrors a file in `src/` (e.g. `Parser.zbr` ↔ `src/Parser.zig`).
  Compiler module files are **PascalCase** to match the Zig `src/` naming
  (`Ast`, `AstBuilder`, `CgHelpers`, `Checker`, `CodeGen`, `Parser`, `Resolver`,
  `TypeChecker`, `Token`, `Lexer`; `main` stays lowercase per Zig convention).
  Paired `*.zig` files are generated artifacts (`Parser.zbr` → `Parser.zig`).
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

## Verification gates (and what each one CANNOT catch)

Three complementary checks. They have **different blind spots** — running one is
not a substitute for another. After any codegen / inference / stdlib change, run
all three (`compile_check.sh` is the one most often forgotten and the one that most
often catches real emit bugs):

```bash
bash tools/selfhost_smoke.sh    # emits + runs fixtures. Blind to: emitted Zig that
                                #   fails to COMPILE (it only --emit-zig's most tests).
bash tools/bootstrap_check.sh   # selfhost round-trip (A/B byte-identical). Blind to:
                                #   (1) wrong-but-still-valid Zig (A & B share the bend
                                #   → identical wrong output, clean diff); (2) any program
                                #   it never compiles (the test corpus, ad-hoc probes).
JOBS=3 bash tools/compile_check.sh   # THE INDEPENDENT WITNESS: emits every positive
                                #   test/*.zbr with the selfhost and runs `zig build-exe`
                                #   on the output. Catches emit bugs the other two miss
                                #   because `zig` fails DIFFERENTLY than the selfhost does.
                                #   Currently a MANUAL tool (not gated) — so its coverage
                                #   is only real on days it's run. `--only <substr>` for a
                                #   tight loop; `--bootstrap` to check the bootstrap's emit.
JOBS=4 bash tools/divergence_check.sh --gate  # THE DRIFT WITNESS: emits the corpus with
                                #   BOTH compilers and compiles each. --gate exits non-zero
                                #   if any SELFHOST GAP (bootstrap compiles it, selfhost
                                #   doesn't) — i.e. the selfhost silently regressed vs the
                                #   reference. Catches selfhost↔bootstrap drift the others
                                #   miss (they all emit with ONE compiler). Baselined 0
                                #   selfhost gaps 2026-07-22. Bootstrap gaps (selfhost LEADS)
                                #   + agree-fails (negative tests) are informational, not gated.
                                #   Heavy → per-session/pre-release, like compile_check.
python fuzz/gramgen.py --gate   # THE PARSER-ROBUSTNESS GATE: derives 960 deterministic
                                #   grammar-valid programs (fixed seeds) and fails on any
                                #   HANG or CRASH (accept/reject divergences are expected,
                                #   don't fail it). Would have caught BUG-199 (an 18-byte
                                #   parser infinite loop) automatically. Complements the
                                #   above (which only ever see human-written programs).
                                #   Optional per-session; ~a few min. Needs both .exe built.
python tools/lint_fallthrough.py   # THE FALL-THROUGH GATE (static, instant, no build):
                                #   flags a value-returning fn whose TAIL `branch` has a
                                #   value-producing arm that can fall through without
                                #   returning. Codegen TCO-wraps such fns in `while(true)`,
                                #   so a fall-through arm HANGS (not a compile error). Caught
                                #   nothing new when written (the hazard was isolated to the
                                #   §28f set-literal arms, since fixed) but re-flags that exact
                                #   bug if reintroduced. Run after adding any `branch` arm to a
                                #   recursive walker (exprHasTry/inferExpr/…). 0 = clean.
JOBS=2 bash tools/full_sweep.sh --gate   # THE FULL-CORPUS WITNESS: emits + zig-
                                #   typechecks EVERY test/*.zbr (403), not just the ~210
                                #   compile_check covers. --gate fails on REGRESSION vs
                                #   tools/full_sweep_baseline.txt (the set that currently
                                #   emit+compile clean, 331). Known negatives/library/
                                #   triage-backlog files need no skip-list — the baseline
                                #   IS the allow-list; re-baseline (--update-baseline) when
                                #   the pass set intentionally grows. Heavy (~25 min, JOBS=2
                                #   — RAM-bound); per-session/pre-release like compile_check.
```

Why this matters: a green round-trip means the compiler is *self-consistent*, NOT that
what it emits is *correct*. The independent witness (`zig`, which has no idea what Zebra
intended) is the only gate that checks correctness of arbitrary emitted programs. A real
latent miscompile hid behind green round-trip + smoke once (see the §28a selfhost notes);
`compile_check.sh` is how you avoid rediscovering that class the hard way.

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
