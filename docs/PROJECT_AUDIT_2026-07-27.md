# Four-Project Audit — Zebra, Book, libui-ng fork, GameEngine

**Date:** 2026-07-27
**Scope:** `C:\Projects\zebra-language`, `C:\Projects\zebra-language-book`,
`C:\Projects\zig-libui-ng`, `C:\Projects\GameEngine`
**Brief:** state of each project; cleanup/organization (docs, generated artifacts);
consistency (does the book match the language?); centralization/refactoring
opportunities; anything bearing on long-term quality and maintenance.

**Method note:** every finding below is backed by a command that was actually run,
not by reading prose. Where a claim is an estimate it says so. Counts are as of
2026-07-27.

---

## 0a. Work completed (same day, 2026-07-27)

Everything in the "half-day" and "hygiene" blocks of §6 was executed. Status of
each finding:

| # | Finding | Status |
|---|---|---|
| A1 | Book `print` drift | ✅ **DONE** — 772 + 31 sites rewritten across 31 chapters |
| A2 | Book `to!` | ✅ **DONE** — 12 sites → `!` force-unwrap; zero remain |
| A3 | `examples/` fossilized | ✅ **DONE** — regenerated; 180 stale → **679** current, all LF |
| A4 | Extractor silently extracted nothing | ✅ **DONE** — and found **two more** breaks (below) |
| A5 | Validator could not fail | ✅ **DONE** — rewritten; regression gate, falsification-tested |
| A6 | Book CRLF | ✅ **DONE** — `.gitattributes` added **and** the generator's write fixed |
| A8 | No GUI chapter | ⬜ open — genuine new content, not a mechanical fix |
| A9/A10 | Filename + duplicate chapters | ⬜ open — **needs your call**, see below |
| B1 | README hello-world broken | ✅ **DONE** — plus a broken link and two stale claims |
| B2/B3/B4/B5 | Root sprawl, naming, debris, scripts | ✅ **DONE** — 15 root docs → 10 |
| B6/C3 | Generated-`.zig` diff noise | ✅ **DONE** (zebra-language); ⬜ GameEngine `zbra/` |
| C1 | GameEngine root artifacts | ✅ **DONE** — 474 quarantined; **diagnosis corrected, below** |
| C2 | GameEngine doc archiving | ⬜ open — left alone, repo has uncommitted WIP |
| D1 | libui fork branch | ✅ **DONE** — on `main`, stale branches deleted |

### Correction to C1 — my original diagnosis was wrong

I reported the 476 root artifacts as an ongoing build-configuration problem ("the
test driver writes to the invocation directory"). The evidence says otherwise:
**all 237 executables date from May 2026**, and the `.zbr` sources for them no
longer exist (`ability_charge_test.zbr`, `aggro_table_test.zbr`, … all gone —
the corpus was reorganized since). Exactly **one** of 238 (`math_test.exe`) has a
live source in `zbra/`.

So these were one-time leftovers from the May test campaign, not a recurring
emission problem. Moved to `zig-out/legacy-artifacts-2026-05/` (already
gitignored) rather than deleted, since that is reversible and they are not
regenerable — their sources are gone. Root went from ~290 entries to 32.

The broader point I drew from it still stands independently — Zebra tools writing
into the invocation directory is a real pattern (three IDE scratch files needed
gitignoring today) — but it is not what produced these particular files.

### Two more breaks found while fixing A4

The extractor had **three** independent defects, not one. Each still exited 0:

1. The glob (the one I found in the audit).
2. `_parse_metadata` recognised only `// file:` — **Cobra-era comment syntax**.
   Zebra comments are `#`, so no modern block carried a filename and
   `write_example` dropped every one, reporting "Extracted 0 examples" per
   chapter. This also explains why the stale `examples/` were all `//`-commented:
   they were extracted before the comment syntax changed.
3. It wrote `.zbr` with `open(..., 'w')` and **no `newline='\n'`** — Python on
   Windows emits CRLF, which the tokenizer rejects. Every generated example was
   unusable *by construction*. This is the exact footgun `CLAUDE.md` documents.

So finding A6 (CRLF) was a *symptom* of A4, not an independent problem. Fixing the
generator fixes it at the source; the `.gitattributes` is now belt-and-braces.

### The validator is now a real gate — verified in both directions

The original sin here was a gate that could not fail, so I tested that the
replacement can:

```
clean tree                          → exit 0, "no regressions vs baseline (118 examples)"
break one baselined example         → exit 1, names the file and the error
```

`validation-baseline.txt` holds the 118 examples that currently compile, in the
same allow-list style as `tools/full_sweep_baseline.txt`. 679 extracted, 118
compile; the rest are fragments, deliberately-wrong teaching examples, and
half-of-a-pair module examples — which is why the gate is on *regression*, not on
absolute pass rate.

### Still needs your decision

- **A10 — duplicate chapters.** `19-22_Final-Chapters.md` (374 lines) covers the
  same ground as standalone `19-`/`20-`/`21-`/`22-` files; `17-18_Projects-2-3.md`
  likewise. I did not delete either — which is canonical is a content call, and
  it is your book. Both currently feed the extractor, so duplicated examples are
  in the corpus.
- **A8 — the GUI chapter.** Happy to draft it; `docs/UI_QUICKSTART.md` is most of
  the raw material and the IDE is a ready-made worked example.
- **BUG-218**, filed today, came out of this audit: chapter 1 promised an error
  message the compiler does not actually produce.

---

## 0. Executive summary

The **compiler is in the best shape of the four** and is not the problem. The
**book is the problem**, and it is worse than it looks from the outside — but it is
also cheaper to fix than it looks, because one mechanical change accounts for most
of it.

| # | Finding | Severity | Est. cost |
|---|---|---|---|
| A1 | Book: `print` statement → function accounts for **108 of 288** failing programs | **HIGH** | 1–2 h (scripted) |
| A4 | Book: `extract-examples.py` silently extracts **nothing** (path break) | **HIGH** | 15 min |
| A5 | Book: `validate-examples.py` has **never validated a single example** | **HIGH** | 30 min |
| B1 | Language: **README hello-world does not compile** | **HIGH** | 5 min |
| A3 | Book: `examples/` (180 files) fossilized at pre-Zebra Cobra syntax; 0 compile | HIGH | free (regenerate) |
| A6 | Book: 179/180 examples CRLF; repo has **no `.gitattributes`** | MEDIUM | 5 min |
| A2 | Book: Ch11 teaches `to!`, a **removed** construct | MEDIUM | 30 min |
| A8 | Book: **no GUI chapter** although the GUI now ships and is run-verified | MEDIUM | 1–2 days (new content) |
| C1 | GameEngine: **476 build artifacts** in the repo root | MEDIUM | 30 min |
| B6 | Language: generated `.zig` produce **22,685-line diffs** for 57-line changes | MEDIUM | 15 min |
| B2 | Language: 6 of 15 root docs stale; `docs/archive/` exists but is unused | LOW | 30 min |
| A10 | Book: merged chapter files duplicate standalone chapters | LOW | 20 min |
| D1 | libui fork: local branch `consolidate-tmp`, not `main` (no divergence) | LOW | 2 min |

**The single highest-leverage action** is A1+A4+A5 together, roughly half a day, and
it converts the book from "unknown, probably broken" to "measured, with a gate."

---

## 1. Zebra language — `C:\Projects\zebra-language`

**State: healthy.** 772 tracked files, six verification gates, all green as of today.
Two compilers (`src/` 37,930 lines of Zig; `selfhost/` 34,461 lines of Zebra) with a
byte-identical round-trip. Five bugs closed today (BUG-214/215/216/217), each with a
gate rather than a one-off fix. This is the mature project of the four.

### B1 — The README's "Hello, world" does not compile — **HIGH**

`README.md` is the first artifact a newcomer meets, and the first code it shows is:

```zebra
def main
    print "Hello, Zebra!"
```

Both halves are removed syntax. Verified:

```
$ zebra -c readme_hello.zbr
    print "Hello, Zebra!"
          ^   error: expected '(', got '"Hello, Zebra!"'
```

`README.md` was last touched 2026-05-17 and predates the §28 `print`-statement
removal. For a project whose stated public release is **0.9 / ready-for-others**,
a non-compiling first example is the most expensive five-minute bug in the portfolio.
There is a `test/print_stmt_removed_test.zbr` asserting the compiler rejects this —
the language is self-consistent; only the README missed the memo.

### B2/B3 — Root-doc sprawl, and an archive convention that exists but is unused

15 markdown files at the repo root, by last-commit date:

| Date | File | Assessment |
|---|---|---|
| 2026-04-21 | `PHASE22_PREP.md` | Prep doc for a **completed** phase — archive |
| 2026-05-01 | `JJ-Quickstart.md` | jj/VCS notes — move to `docs/` |
| 2026-05-05 | `STYLE_GUIDE.md` | Still valid; keep at root |
| 2026-05-07 | `stdlib_audit.md` | Superseded by `STDLIB_ROADMAP.md`; also the **only lowercase** root doc |
| 2026-05-10 | `SCRIPTING_TOOLS.md` | Move to `docs/` |
| 2026-05-12 | `FixedBugs.md` | Companion to `BUGS.md`; mixedCase, unlike its sibling |
| 2026-05-17 | `README.md` | **Stale — see B1** |
| 2026-06-28 | `MORNING_REPORT_2026-06-28.md` | Dated one-off — archive |
| 2026-06-29 → 07-27 | `SELFHOST_JOURNAL`, `STDLIB_ROADMAP`, `QUICKSTART`, `BUGS`, `CHANGELOG`, `CLAUDE`, `NEXT_STEPS` | Current — keep |

`docs/archive/` already exists with 3 files, so the convention is established; it just
hasn't been applied since. `docs/` itself holds 27 files including one dated one-off
(`FEATURE_AUDIT_2026-07-05.md`).

**Recommendation:** archive the two dated reports and `PHASE22_PREP.md`; move
`JJ-Quickstart.md` and `SCRIPTING_TOOLS.md` into `docs/`; fold `stdlib_audit.md` into
`STDLIB_ROADMAP.md`; rename `FixedBugs.md` → `BUGS_FIXED.md` to match `BUGS.md`.
Target: root holds only README, CLAUDE, QUICKSTART, BUGS, CHANGELOG, NEXT_STEPS,
STDLIB_ROADMAP, SELFHOST_JOURNAL, STYLE_GUIDE.

### B4/B5 — Working-tree debris and inconsistent script placement

Present in the working tree, gitignored but permanently cluttering the directory:
`test_out.txt`, `repl_output.txt`, `test_session.txt`, `test_session2.txt`, `parser`,
`hello_incr.zcs`, `compiler_rt.dll`, `_parity_sh/`, and `fix_016_arraylist.py` /
`fix_016_batch2.py` — one-off Zig 0.16 migration scripts long since spent.

Separately, **5 Python scripts live at the repo root** (`debug_repl.py`,
`zebra-repl.py`, `test_repl_manual.py`, plus the two `fix_016_*`) while 13 others live
in `tools/`. Same kind of thing, two locations.

**Recommendation:** delete the spent one-offs, move the REPL scripts into `tools/`.
Being gitignored makes these invisible to git but not to a human opening the folder.

### B6 — Generated `.zig` create enormous diffs — **MEDIUM, cheap fix**

`selfhost/*.zig` is 145,151 tracked lines, of which **22,822 (16%) are `// zbr:file:N`
line-marker comments**. Because those markers renumber whenever anything shifts, a
small source edit rewrites most of the file. Measured on today's BUG-214 commit:

```
57-line change to selfhost/CodeGen.zbr
  → selfhost/CodeGen.zig | 22685 +++++-----
    1 file changed, 11377 insertions(+), 11308 deletions(-)
```

These files **must** stay tracked — they are the bootstrap seed, and the chicken-and-egg
of a self-hosted compiler depends on them. The problem is not that they're committed;
it's that they're indistinguishable from hand-written code in every diff, review, blame
and search.

**Recommendation** (15 minutes, no behavior change): add to `.gitattributes` —

```gitattributes
selfhost/*.zig linguist-generated=true -diff
```

`-diff` collapses them to "Binary files differ" in `git diff`/`git log -p`, and
`linguist-generated` hides them from GitHub review and language stats. `git diff
--text` still shows content when you actually want it. Consider also dropping the
`zbr:` markers under a flag when they aren't needed for debugging — but the
`.gitattributes` line captures most of the benefit for none of the risk.

### Refactoring/centralization

The obvious "duplication" — two complete compilers — is **deliberate and already has a
retirement plan** (the bootstrap sunsets; endgame is Zig only in special-case files).
I would not touch it. Two smaller observations:

- The `Resolver.isBuiltin` / `CodeGen.isStdlibNamespace` drift class was **already
  root-fixed** on 2026-07-23 by extracting `CgHelpers.isStdlibNs`. That is the right
  pattern and the right instinct; the remaining question is whether other
  hand-maintained parallel lists exist. `NEXT_STEPS.md` flags this class explicitly.
- **BUG-215 exposed a real gap:** stdlib method **arity is unchecked** across the
  board — `if args.len > 0 genExpr(args[0])` is the pervasive shape, and extra
  arguments are silently discarded. Today's fix guarded `indexOf` specifically. The
  general fix is a stdlib signature table in the front end so arity errors become
  proper Zebra diagnostics with a source location. **This is a genuine pre-1.0 item**
  and the highest-value refactor in the compiler: it converts a whole class of silent
  miscompiles into compile errors. Estimated 1–2 days.

---

## 2. The Book — `C:\Projects\zebra-language-book`

**State: significantly drifted, with a broken toolchain masking how far.** Last
chapter commit **2026-06-07** — seven weeks, during which the language shipped the
§28b explicit-`?` flip, `Set(T)`, dict/set literals, three SIMD tiers, the `<<-`
copy-out split, and a working GUI.

33 chapters, 686 `zebra` code blocks, 180 extracted example files.

### A1 — One change accounts for most of the breakage — **HIGH**

I extracted all 686 blocks from the live chapters and compiled the 296 that are
complete programs (contain `def main`):

| | compiles | fails |
|---|---|---|
| As written | **8** | 288 |
| After mechanically rewriting `print X` → `print(X)` | **116** | 180 |

**772 `print` statements** were rewritten. That single change — `print` became a
function in §28 — recovers **108 programs, 37% of all failures**, and it is
scriptable. Chapter 1, the first thing any reader compiles, is `print "${name} is
${age}"`.

The remaining 180 have no dominant cause (23 stray top-level tokens, 23 unexpected
members, 14 identifier errors, 11 undeclared names, …), and that residue includes
**35 blocks that are *deliberately* wrong** (marked ❌ / "Mistake" — teaching
anti-patterns, correctly non-compiling) and **8 multi-module examples** that fail only
because their companion block isn't present. So the realistic target is ~253
should-compile blocks, of which 116 pass after the one-line-per-site fix.

### A4/A5 — The book's own validation toolchain is broken in two independent ways — **HIGH**

This is why the drift went unnoticed for seven weeks, and it is the most important
finding in the book.

**A4 — the extractor extracts nothing.** `extract-examples.py` looks for chapters with
`self.book_root.glob("Part-*")`. The chapters were reorganized under `book/Part-*`.
The glob now matches **zero** directories, `find_chapters()` returns an empty list, and
the script **exits successfully**. It has been a silent no-op since the reorg.

**A5 — the validator validates nothing.** `validate-examples.py` runs a `validate_syntax`
pre-check requiring `"class " in content` and `"def " in content` before it will attempt
compilation. Most examples are snippets that satisfy neither, so they are marked
*skipped* and never compiled. The checked-in report proves it:

```
Generated: 2026-04-07T09:43:32
Total examples:  180
Passed:          0
Failed:          0
Skipped:         180
```

**Zero passed, zero failed, 180 skipped** — a green-looking report from a harness that
has never compiled a single line. `validation-report.json` and `lint-report.txt` carry
the same April 7 timestamp.

This is the same hazard the language repo learned the hard way and documented in
`CLAUDE.md`: *a gate that cannot fail is worse than no gate*, because it manufactures
confidence. The book has two of them stacked.

**Recommendation:** fix the glob to `book/Part-*`; delete the `validate_syntax`
pre-check entirely and let the compiler be the judge (it is the only authority that
matters); have the validator exit non-zero on failure so it can be a real gate.

### A3/A6 — `examples/` is fossilized, and it's generated, so this is nearly free

All 180 files are **pre-Zebra Cobra-era syntax**, not merely stale Zebra:

| Marker | Files (of 180) | Status in Zebra today |
|---|---|---|
| `//` comments | **180** | Comments are `#` |
| `shared` blocks | 133 | Removed |
| `class Main` | 106 | Not the idiom |
| `def main` (no parens) | 105 | Parse error |
| `print "…"` | 57 | Parse error |

**179 of 180 also have CRLF line endings**, which the tokenizer rejects outright —
so they fail before syntax is even considered. The book repo has **no `.gitattributes`**;
the language repo has one precisely for this (`*.zbr text eol=lf`) because it's a
documented Windows footgun.

Because `examples/` is **generated output**, none of this needs hand-editing: fix A4
and regenerate. Add the `.gitattributes` line so it stays fixed.

### A2 — Chapter 11 teaches a removed operator — **MEDIUM**

`11-Nil-Tracking-and-Safety.md` has a full section, *"## The `to!` Operator (Unwrap)"*,
plus it in the chapter's stated learning objectives and in a "common mistakes" callout —
8 sites. `to!` was removed in §28. Verified:

```
$ zebra -c tobang.zbr
3:15: error: unexpected expression token: 'to'
```

`test/to_bang_removed_test.zbr` exists as a negative test asserting rejection. The
replacement (`!` postfix, and `if x as n` binding) is already taught in the same
chapter — so the fix is deletion and a pointer, not new writing.

### A8 — No GUI chapter — **MEDIUM (gap, not defect)**

Grepping all 33 chapters for `Gui.run`, `g.button`, `gui-backend`, `MVU` yields **3
files**, and all 3 are incidental: a `with`-block example that happens to use
`g.button`, an arena-lifetime example, and a CLI-flags table listing the backends.

There is **no chapter on GUI programming** — no MVU model, no `Gui.run`, no widget
tour, no backend discussion. This was entirely defensible a week ago. As of today the
libui-ng backend is run-verified end-to-end and there is a self-hosted IDE with four
Scintilla editors built in Zebra. Meanwhile a current, 250-line `docs/UI_QUICKSTART.md`
lives in the **language** repo (last touched today).

This is the book's biggest *content* gap, as distinct from its drift. It is also the
most compelling chapter the book could add — "build a GUI app in Zebra" is a far better
advertisement than another collections tour.

### A9/A10 — Naming and duplication — **LOW**

- `12-Error-Handling-with-Results.md` — the **filename** is stale; the content is
  correct and current (opens with *"Zebra's error model is exceptions"*, 79
  throws/raise/try/catch references). Rename only.
- `19-22_Final-Chapters.md` (374 lines) **coexists with** standalone
  `19-Standard-Library-Tour.md`, `20-…`, `21-…`, `22-…`. Both contain a "Chapter 19:
  Standard Library Tour". Same pattern with `17-18_Projects-2-3.md`. These look like
  superseded drafts that were never deleted — a reader (or a PDF build) may pick up
  either.

### Book repo organization

**20 markdown files at the root**, 14 of which are status/meta documents:
`_WRITING_STATUS`, `BOOK_COMPLETION_STATUS`, `PROJECT_STATUS`, `COMPLETION_SUMMARY`,
`CRITICAL_FIXES_APPLIED`, `CRITICAL_REVIEW`, `BUILD_SYSTEM_STATUS`, `BUILD_PDF_README`,
`PDF_BUILD_GUIDE`, `BUILD_WITH_PNG_DIAGRAMS`, `MANUAL_CONVERSION`, `DIAGRAMS_EMBEDDED`,
`README`, `README-BOOK-GUIDE`. Four of them describe how to build the PDF; two are
READMEs; four are status snapshots of a moment that has passed.

Plus **12 loose scripts** at the root, several clearly one-off (`fix_syntax.py`,
`fix_modern_syntax.py`, `strip-images.py`, `update-image-refs.py`,
`fix-diagram-paths.py`, `convert-svg-to-png.bat`, `MANUAL_CONVERSION.md`'s companions).

Two PDFs are checked in: `zebra-programming-book.pdf` (Jun 7) and
`zebra-programming-book_def.pdf` (Apr 30) — the latter apparently an artifact of a `def`
experiment; there is also a stray file literally named `def`.

**Recommendation:** one `STATUS.md`; one `BUILDING.md`; `tools/` for the scripts;
`docs/` for the rest; delete `_def` leftovers; keep one PDF (or none, and build on
release).

---

## 3. zig-libui-ng fork — `C:\Projects\zig-libui-ng`

**State: healthiest of the four.** 621 tracked files, clean tree apart from an
untracked `zig-pkg/` cache dir.

### D1 — Local branch is not `main`, but there is **no divergence** — **LOW**

The checkout sits on `consolidate-tmp` while `origin/HEAD → origin/main`. I verified
this is cosmetic, not a correctness problem:

```
$ git log --oneline origin/main..consolidate-tmp   → (empty)
$ git log --oneline consolidate-tmp..origin/main   → (empty)
```

The branches are identical, and Zebra pins the exact commit that is checked out:

```
selfhost/main.zbr:1940
  .url = "git+https://github.com/torial/zig-libui-ng?ref=main#93c7f54b…"
```

`93c7f54` is HEAD. So yesterday's `@alignCast` Scintilla fix **is** what a cold build
consumes. Worth confirming since a fork/pin mismatch would be invisible until a
cache-cold build on another machine.

**Recommendation:** `git checkout main && git branch -d consolidate-tmp zig-0.16` to
remove the ambiguity. Two minutes, purely hygienic.

One structural note: `zig-pkg/` appears untracked here **and** in `zebra-language` and
`GameEngine` — three repos, same directory, no shared ignore convention. Worth one line
in each `.gitignore` (`zebra-language` and `GameEngine` already have it; this fork does
not).

---

## 4. GameEngine — `C:\Projects\GameEngine`

**State: large and functional; by far the worst workspace hygiene.** 4,326 tracked
files. `docs/ENGINE_ROADMAP.md` (last updated 2026-06-18) reports the engine
**feature-complete** with the remaining work being script-porting volume, not
architecture — and the repo bears that out.

### C1 — 476 build artifacts in the repository root — **MEDIUM**

`ls` in the project root returns **238 `.exe` and 238 `.pdb` files**
(`ability_charge_test.exe`, `aggro_table_test.exe`, … `zone_capture_test.exe`).

Important distinction: these are **gitignored, not tracked** — `git ls-files` returns
**0** exe/pdb, and the `.gitignore` is comprehensive. So the *repository* is clean;
the *working directory* is not. This is a usability problem, not a repo-integrity one,
and the fix is different than it would be for tracked binaries.

Cause: the test corpus is `.zbr` files compiled by `zebra.exe`, which emits the
executable next to the invocation's working directory. The `build.zig` executables use
`b.installArtifact` correctly and land in `zig-out/`; it's the Zebra-compiled tests
that scatter.

**Recommendation:** have the test driver `cd` into a scratch directory (or pass
`--output-dir`) so artifacts land in `zig-out/test/` or `.testbin/`. 30 minutes, and
it makes the project root navigable again. This is the same class as the three IDE
scratch files (`untitled.zbr`, `.ide_build.tmp`, `_ide_tmp_check.zbr`) that had to be
gitignored in `zebra-language` today — **a general pattern worth fixing once as a
convention: Zebra tools should never write into the invocation directory by default.**

### C2 — Docs: same archive-convention gap

27 files in `docs/`, including four dated one-off reports
(`MORNING_REPORT_2026-06-22`, `OVERNIGHT_REPORT_2026-06-19`, `OVERNIGHT_REPORT_2026-06-21`,
`SESSION_SUMMARY_2026-06-08`) and versioned design docs kept side by side
(`BOSS_DSL_PROPOSAL.md`, `BOSS_DSL_v2.md`, `BOSS_DSL_v2.1.md`, plus two PDFs of the
latter two). No `docs/archive/`.

`ENGINE_ROADMAP.md` is itself honest about staleness — it explicitly says the 2026-06-07
sections are "largely superseded" and points to `ENGINE_API_SURFACE.md` as the
authoritative inventory. That is good practice; it would be better as an actual archive
move.

### C3 — Generated `.zig` alongside sources, again

`zbra/` tracks **51 generated `.zig` next to 66 `.zbr`**, mirroring the `selfhost/`
convention — and inheriting the same diff-noise problem (B6). The same
`.gitattributes` remedy applies.

### C4 — The real state of the port

`ported_scripts/` holds **1,780 `.zbr`** files, and grep finds TODO/stub markers in
2,786 files across that tree (counting both `.zbr` and generated `.zig`). This matches
the roadmap's framing that the remaining work is porting volume. Not a defect — but
worth stating plainly in the roadmap as a number, because "feature-complete engine"
and "most scripts are stubs" are both true and easy to conflate.

---

## 5. Cross-project consistency

**E1 — The book is isolated from the ecosystem it documents.** Zero chapters mention
GameEngine; one mentions the IDE in passing. The two most impressive things built *in
Zebra* — a game engine with 293 passing test executables, and a self-hosted IDE with
embedded Scintilla editors — appear nowhere in the book as case studies. Part 4 is
"Practical Projects" and builds a CLI tool.

**E2 — UI documentation lives in the wrong repo.** `docs/UI_QUICKSTART.md` (250 lines,
current) is in the *language* repo and is explicitly *"agent-facing."* There is no
human-facing equivalent, and the book has no GUI chapter (A8). The content largely
exists; it is in the wrong place and the wrong register.

**E3 — The book's plan lives in the language repo, and they have diverged.**
`zebra-language/docs/BOOK_PLAN.md` tracks book chapters against `QUICKSTART.md`. It
records a **dogfood pass on 2026-07-25** that extracted 126 code blocks, compiled them,
and fixed — among other things — *"`print` documented as a statement… it's a function
now."*

**That is exactly finding A1.** The identical drift was found and fixed in
`QUICKSTART.md` two days ago, and the book (which has 772 instances of it) was never
touched, because it is a different repository and the plan for it lives on the other
side of the boundary. This is the single clearest structural cause of the book's
drift, and it will recur.

**Recommendation:** move `BOOK_PLAN.md` into the book repo, and give the book the same
kind of gate the language has — a `validate.py` that compiles every extracted block and
exits non-zero. The language repo's whole quality story is "gates that can actually
fail"; the book has none.

**E4 — Four repos, four conventions.** Generated artifacts are tracked in
`zebra-language/selfhost/` and `GameEngine/zbra/` with no `.gitattributes` marking;
`.gitattributes` for LF exists only in `zebra-language`; `docs/archive/` exists only in
`zebra-language` and is unused; dated one-off reports accumulate at the root in three of
the four. None of these is important alone. Together they are why each repo feels
different to work in.

---

## 6. Recommended order

**Half-day, highest leverage — makes the book measurable:**
1. Fix `extract-examples.py` glob → `book/Part-*` (A4) — 15 min
2. Delete `validate_syntax` pre-check; make the validator exit non-zero (A5) — 30 min
3. Add `.gitattributes` (`*.zbr text eol=lf`) to the book repo (A6) — 5 min
4. Script the `print X` → `print(X)` rewrite across chapters (A1) — 1–2 h
5. Regenerate `examples/`, re-run validation, record the real number (A3)
6. Fix the README hello-world (B1) — 5 min

That sequence turns "the book is probably broken" into a number with a gate behind it,
and it fixes ~37% of the breakage on the way.

**Then, hygiene — an afternoon:**
7. `.gitattributes` for generated `.zig` in both repos (B6, C3) — 15 min
8. GameEngine test artifacts → `zig-out/` or `.testbin/` (C1) — 30 min
9. Archive stale root docs in all three repos (B2, C2) — 1 h
10. `git checkout main` in the libui fork; delete stale branches (D1) — 2 min

**Then, real work — schedule it:**
11. Remove `to!` from Ch11; sweep chapters for other §28 removals (A2) — 30 min
12. **Stdlib arity checking in the front end** (B6 refactor) — 1–2 days. The BUG-215
    class: silent argument dropping should be a compile error with a source location.
    Highest-value compiler refactor identified.
13. **Write the GUI chapter** (A8) — 1–2 days. Promote `UI_QUICKSTART.md` to
    human-facing prose; use the IDE as the worked example.
14. Move `BOOK_PLAN.md` into the book repo (E3) — the structural fix that stops A1
    from recurring.

---

## 7. What I am least sure of

- **The 116/296 figure is a floor, not a ceiling.** I counted a block as "should
  compile" if it contains `def main`. Some of those are deliberately-wrong teaching
  examples beyond the 35 I could detect by marker, and some multi-module examples fail
  only for want of a companion block. The true "broken" number is somewhat lower than
  180. It is not lower than ~100.
- **I did not audit book prose for factual drift**, only code. A chapter can compile
  perfectly and still describe semantics that changed (§28b's explicit-`?` flip is the
  likeliest candidate — it changes when you must write `?`, not whether code parses).
  That needs a read, not a grep, and it is the obvious next audit.
- **GameEngine's runtime state is unverified here.** I audited its structure, docs and
  artifacts, not whether its 293 test executables still pass against today's compiler.
  Given the compiler has moved considerably since 2026-07-14, that is worth a run.
