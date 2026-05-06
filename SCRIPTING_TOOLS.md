# Zebra — Scripting Tools Catalog

All scripts written in service of the Zebra compiler, book, or toolchain.
Python is the interim language; Zebra is the target once the readiness gate
(see bottom of this file) is met.

**Rule:** before writing a new Python script, check this file — there may be
one that already solves the problem or can be adapted.  After writing one,
add it here.

---

## Compiler & Repository Tools

### `tools/bootstrap_check.sh`
**Language:** Bash  
**Purpose:** Five-step byte-identical round-trip bootstrap verification.
Regenerates `selfhost/*.zig`, builds selfhost-A, has selfhost-A re-emit
its own source, builds selfhost-B, diffs against selfhost-A output.
**When to use:** After any change to `selfhost/*.zbr` before committing.
**Zebra port:** Needs `sys.run()` (subprocess capture), `Dir.list`.
`sys.run` exists but is partial; main gap is multi-step pipeline plumbing.

### `tools/selfhost_smoke.sh`
**Language:** Bash  
**Purpose:** Quick sanity check — runs `zebra.exe --emit-zig` over a small
set of representative fixtures; passes if each exits 0 and output is non-empty.
**When to use:** Fast pre-commit check when `bootstrap_check.sh` is too slow.
**Zebra port:** Needs `sys.run()`.

### `tools/corpus_snapshot.sh`
**Language:** Bash  
**Purpose:** Emit-zig every `.zbr` in the corpus and record a diff-able TSV.
Used to measure convergence progress during parity sprints.
**When to use:** Before/after a parity sprint to count mismatches.
**Zebra port:** Needs `sys.run()` + `Dir.walk()`.

### `tools/escape_hatches_check.sh`
**Language:** Bash  
**Purpose:** Guards against `page_allocator` calls creeping into Zebra source,
codegen, or the preamble.  Grep-based; exits non-zero if any are found.
**When to use:** Pre-commit hook candidate.
**Zebra port:** Can be written today — `File.read` + `str.contains`.
Blocked only by `Dir.walk` for the file-glob step.

### `tools/install_merge_hook.sh`
**Language:** Bash  
**Purpose:** Installs `.git/hooks/pre-merge-commit` so `zebra typecheck-merge`
runs automatically on `git merge`.
**When to use:** Once per clone.
**Zebra port:** Needs `File.write` + `sys.run("chmod")`.
`File.write` exists; `chmod` via `sys.run` would work.

### `tools/branch_to_if_is.py`
**Language:** Python  
**Purpose:** Converts single-arm `branch X on V as B … else pass` to the
idiomatic `if X is V as B` form.  Regex-based line transform.
**When to use:** Style-guide sweep or after adding new selfhost code in the
old branch style.
**Zebra port:** Needs `Dir.walk` + `Regex.replace`.

### `tools/migrate_colon_syntax.py`
**Language:** Python  
**Purpose:** Migrates `def name(params) as Type` annotation syntax to
`def name(params): Type`.  Preserves `on X as y` branch bindings.
**Status:** One-shot; already applied across the repo.
**Zebra port:** Needs `Dir.walk` + `Regex.replace`.  Good template for future
syntax-migration scripts.

### `tools/sweep_class_main.py`
**Language:** Python  
**Purpose:** Converts `class Main { static { def main ... } }` to top-level
`def main()`.  Lifts all static helper methods; rewrites `Main.helper(` calls.
**Status:** Applied 2026-05-06 (103 files).  Kept for re-use on future files.
**Zebra port:** Needs `Dir.walk` + `str.split/replace`.  No regex needed.
One of the cleanest porting targets once `Dir.walk` lands.

---

## REPL Prototype

### `zebra-repl.py`
**Language:** Python  
**Purpose:** Interactive Zebra REPL (Phase 0).  Wraps single-line expressions
in valid Zebra programs, calls the `zebra` compiler, displays results.
**Status:** Prototype — drives the design for the real REPL (NEXT_STEPS §6).
The file itself notes: "When `sys.run()` and `System.readLine()` are
implemented in Zebra, this logic can be ported directly."
**Zebra port:** Needs `sys.run()` (to invoke `zebra` as a subprocess) +
`sys.readLine()` (stdin readline).  `sys.run` is partially implemented.

### `debug_repl.py` / `test_repl_manual.py`
**Language:** Python  
**Purpose:** Debug harness and manual test driver for `zebra-repl.py`.
**Zebra port:** Follows automatically once `zebra-repl.py` is ported.

---

## Book Tools

These operate on `C:/Projects/zebra-language-book/` (the companion book repo).
Paths are hard-coded to that root; adjust if the book repo moves.

### `tools/book_deindent_main.py`
**Language:** Python  
**Origin:** `C:/tmp/deindent_main.py`  
**Purpose:** In book markdown, fixes `def main()` body indentation inside
fenced ```zebra blocks after the `class Main → def main()` sweep.  Bodies
that were nested 3 levels (12 spaces) need to drop to 4 spaces.
**Zebra port:** Needs `Dir.walk` + `File.read/write`.  Straightforward port.

### `tools/book_fix_as_return.py`
**Language:** Python  
**Origin:** `C:/tmp/fix_as_return.py`  
**Purpose:** In book markdown, rewrites `def name(params) as Type` →
`def name(params): Type` inside fenced ```zebra blocks.  Idempotent.
**Zebra port:** Needs `Dir.walk` + `Regex.replace`.

### `tools/book_scan_unicode.py`
**Language:** Python  
**Origin:** `C:/tmp/scan_unicode.py`  
**Purpose:** Scans book markdown for non-ASCII characters and reports a
histogram.  Run before a PDF build to catch rendering hazards.
**Zebra port:** Needs `Dir.walk` + `File.read` + Unicode codepoint iteration.
Zebra has `str.codePointCount` but not yet a codepoint-by-codepoint iterator
for histogram building.  Near-term port once `Dir.walk` + char iteration land.

### `tools/book_strip_invisibles.py`
**Language:** Python  
**Origin:** `C:/tmp/strip_invisibles.py`  
**Purpose:** Strips U+FEFF (BOM) and U+FE0F (variation selector-16) from all
book `.md` files.  Both are invisible and break PDF rendering.
**Zebra port:** Needs `Dir.walk` + `str.replace` (literal char).  Very simple
port once `Dir.walk` exists — no regex required.

---

## Zebra Readiness Gate

**Definition:** Zebra is "Python-replaceable for its own tooling" when every
script above has a working Zebra equivalent checked into the repo.

### Missing features (blockers)

| Feature | Status | Blocks |
|---------|--------|--------|
| `Dir.walk(path): List(str)` — recursive file tree | ✅ DONE 2026-05-05 | All file-glob scripts |
| `Regex.replace(pattern, repl): str` — substitution (not just match) | pending | `branch_to_if_is`, `migrate_colon_syntax`, `book_fix_as_return` |
| `sys.run()` robustness — capture stdout+stderr, exit code | pending | `bootstrap_check`, `corpus_snapshot`, REPL |
| `sys.readLine(): str?` — stdin readline | pending | REPL |

`Dir.walk` has landed. `Regex.replace` is the next blocker — see `NEXT_STEPS.md` §12.

### Porting order (once blockers land)

1. `book_strip_invisibles.zbr` — simplest; only `Dir.walk` + `str.replace`
2. `sweep_class_main.zbr` — `Dir.walk` + multiline string transform; good
   stress test of Zebra string handling
3. `escape_hatches_check.zbr` — grep-style; tests `str.contains` at scale
4. `book_scan_unicode.zbr` — needs char iteration; drives that feature
5. `branch_to_if_is.zbr` + `migrate_colon_syntax.zbr` — regex-replace variants
6. `zebra-repl.zbr` — needs `sys.run` + `sys.readLine`; caps the gate

When #6 is done, Zebra can bootstrap its own interactive tooling loop.

---

## Adding a new script

1. Write it in Python (or Bash for process orchestration).
2. Put it in `tools/` if it operates on the compiler repo; `tools/book_*.py`
   if it operates on the book repo.
3. Add an entry to this file: name, language, purpose, Zebra port readiness.
4. If it lives in `c:/tmp` first, move it to `tools/` before closing the
   session — `c:/tmp` is ephemeral.
