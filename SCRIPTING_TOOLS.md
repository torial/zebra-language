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

### `tools/escape_hatches_check.sh` / `tools/escape_hatches_check.zbr`
**Language:** Bash (shell) + Zebra (port — ✅ first completed Zebra tool)  
**Purpose:** Guards against `page_allocator` calls creeping into Zebra source,
codegen, or the preamble.  Counts matching lines; exits non-zero if count drifts
from the hard-coded baseline.
**When to use:** Pre-commit hook candidate.  Shell version runs in `zig build test`.
**Zebra port status:** ✅ DONE 2026-05-05.  Uses `Dir.list` + `File.read` +
`str.split` + `str.contains`.  Outputs identical results to the shell version.
Timing: zbr→zig compile ~179ms, zig run ~228ms; comparable to shell ~518ms.

### `tools/install_merge_hook.sh`
**Language:** Bash  
**Purpose:** Installs `.git/hooks/pre-merge-commit` so `zebra typecheck-merge`
runs automatically on `git merge`.
**When to use:** Once per clone.
**Zebra port:** Needs `File.write` + `sys.run("chmod")`.
`File.write` exists; `chmod` via `sys.run` would work.

### `tools/branch_to_if_is.py` / `tools/branch_to_if_is.zbr`
**Language:** Python → ✅ Zebra port DONE 2026-05-08  
**Purpose:** Converts single-arm `branch X on V as B … else pass` to the
idiomatic `if X is V as B` form.  Multi-line state machine: tracks indentation,
accumulates on-arm body, verifies else body is exactly `pass`.
**When to use:** Style-guide sweep or after adding new selfhost code in the
old branch style.  Skips `as _` discard bindings (Zig 0.15 rejects `_` as an id).
**Zebra port notes:** Uses manual index-loop for stateful multi-line scanning;
avoids method chaining on `List.at()` returns (uses temp vars).  Applied 1
conversion to `selfhost/codegen.zbr` on first run.

### `tools/migrate_colon_syntax.py` / `tools/migrate_colon_syntax.zbr`
**Language:** Python → ✅ Zebra port DONE 2026-05-08  
**Purpose:** Migrates `def name(params) as Type` annotation syntax to
`def name(params): Type`.  Preserves `on X as y` branch bindings and
`if x as n` capture bindings (guards on uppercase-only replacement).
**Status:** One-shot; already applied across the repo.
**Zebra port notes:** Splits on ` as `, replaces only when next char is uppercase
or `^`/`!`/`?` — makes it safe for corpora that already have `if x as n` bindings.

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

### `tools/book_strip_invisibles.py` / `tools/book_strip_invisibles.zbr`
**Language:** Python → ✅ Zebra port DONE 2026-05-05  
**Origin:** `C:/tmp/strip_invisibles.py`  
**Purpose:** Strips U+FEFF (BOM) and U+FE0F (variation selector-16) from all
book `.md` files.  Both are invisible and break PDF rendering.
**Zebra port:** Uses `File.listDir` (per-Part, non-recursive) + `str.replace`
with literal UTF-8 bytes for the invisible characters.  48/48 smoke.

---

## Zebra Readiness Gate

**Definition:** Zebra is "Python-replaceable for its own tooling" when every
script above has a working Zebra equivalent checked into the repo.

### Missing features (blockers)

| Feature | Status | Blocks |
|---------|--------|--------|
| `Dir.walk(path): List(str)` — recursive file tree | ✅ DONE 2026-05-05 | All file-glob scripts |
| `re.replace(text, repl): str` — regex substitution on a compiled `Regex` | ✅ DONE (shipped with regex engine) | `branch_to_if_is`, `migrate_colon_syntax`, `book_fix_as_return` |
| `sys.run()` robustness — capture stdout+stderr, exit code | pending | `bootstrap_check`, `corpus_snapshot`, REPL |
| `sys.readLine(): str?` — stdin readline | ✅ DONE 2026-05-10 | REPL |

Items 1–5 in the porting order below are now fully unblocked (`Dir.walk` + `re.replace` both available). Only item 6 (`zebra-repl`) still needs `sys.run` (readLine is now done).

### Porting order

1. ✅ `book_strip_invisibles.zbr` — DONE 2026-05-05; `File.listDir` + `str.replace`
2. ✅ `sweep_class_main.zbr` — DONE 2026-05-05; BUG-116/117/118 (char methods, List.join,
   struct ctor) fixed 2026-05-05; workarounds removed from tool source after fixes
3. ✅ `escape_hatches_check.zbr` — DONE 2026-05-05; first completed Zebra tool port
4. `book_scan_unicode.zbr` — needs char iteration; drives that feature
5. ✅ `migrate_colon_syntax.zbr` — DONE 2026-05-08; `str.split` + `isTypeAnnotStart` guard
5b. ✅ `branch_to_if_is.zbr` — DONE 2026-05-08; multi-line state machine (not regex-replace)
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
