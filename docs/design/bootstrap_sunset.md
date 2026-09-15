<!-- doc-status: design -->
# Bootstrap sunset — retiring `src/` and `zebra-bootstrap`

**Status:** PLAN, decided in principle (Sean, 2026-09-15: "I agree re a). Let's move to no
bootstrap. Worth the effort imo"). Each step below is gated and lands as its own commit;
nothing is deleted until the step that replaces it is green.
**Supersedes:** `docs/design/regen_authority_decision.md` (2026-07-22, "keep the bootstrap
as the independent regen authority") — overtaken by events on 2026-08-30, when
`tools/rebuild.sh` and `tools/bootstrap_check.sh` Step 1 switched the regeneration of
`selfhost/*.zig` to `zebra.exe` itself (the N-1 selfhost). NEXT_STEPS_to_1.0 item 7 as
written on 2026-09-14 ("the FROZEN bootstrap is still the regen authority") was wrong on
that point; this document is the corrected read.

## 1. Where things actually stand

The selfhost has been its own regen authority for two weeks: `rebuild.sh` regenerates
with `zebra.exe`, `bootstrap_check.sh` proves the level-2 fixed point (A emits B, B emits
A's bytes) with no bootstrap in the loop. The bootstrap (`src/`, 16 files, 37,549 lines
of Zig) is built by `zig build` and installed as `zebra-bootstrap.exe`, and is still
consulted by:

| Consumer | What it uses the bootstrap for | Disposition |
|---|---|---|
| `selfhost-div` gate (`tools/selfhost_divergence_check.sh`) | the two-implementation comparison: does the bootstrap still read every selfhost module the selfhost reads? Informational when the selfhost has *outgrown* it (that number rises every time a keyword is freed), gated only for "the compiler refuses its own sources and the bootstrap accepts them" | **retire**; the property it gates ("the compiler accepts its own sources") is already `round-trip`'s Step 1 |
| `--zig-backend` (`zebra --zig-backend x.zbr`) | delegates the whole compile to the bootstrap | **remove** the flag (surface −1 flag, CHANGELOG line) |
| `--gui-backend=glfw` / `stub` | delegated to the bootstrap; `tui` and `libui_ng` are native | **remove** the two delegated values (`contract_mode_check.sh`'s bootstrap legs go with them) |
| `zebra debug --listen PORT` (TCP DAP) | delegates; stdio mode is native | **port or drop**: zebra-ide uses stdio; drop the TCP mode with a usage line saying so |
| `smoke_run_bootstrap` in `selfhost_smoke.sh` (4 fixtures) | `build_smoke`/`build_declarative` run under the bootstrap because of a *stale* comment ("selfhost parity for Build is pending" — `zebra build` was ported 2026-09-04 and `test/build_requires_test.zbr` runs the Build API through the selfhost today); `bug124`/`bug250` pin bugs *in the bootstrap's own codegen* | move the two Build fixtures to `smoke_run`; delete the two bootstrap-only pins (their bugs die with the code they pin) |
| `compile_check.sh --bootstrap`, `divergence_check.sh`, `diagnostic_parity.py`, `mutation_check.py`, `scaling_probe.py`, `triage_diagnostic_candidates.py` | compare the two compilers | **retire** the comparison modes; `mutation_check` keeps its selfhost-only mode |
| `lint_interp_escape.py` | a bootstrap-only hazard | **retire** (already noted as "retire with bootstrap") |
| `zbr_vocab.py` / `lint_reserved_words.py` | read the keyword table from `src/Token.zig` (and `zbr_vocab` cross-checks it against `selfhost/Token.zbr`) | **repoint** to `selfhost/Token.zbr` only; `surface_inventory.py` and `keyword_coverage` inherit the change |
| `zig-test` gate (131 tests: `src/*.zig` unit tests + `test/main.zig` integration) | tests of the *bootstrap's* tokenizer/parser/printer | **retire** the gate with the code; the selfhost's own tests are `.zbr` fixtures in the smoke (`selfhost/ast_test.zbr`, `typechecker_test.zbr`, …), which stay |
| `doctor.sh` / `rebuild.sh` footgun 4 / `rebuild_guard_check.sh` | "preamble newer than the bootstrap that embeds it" | the *selfhost* embeds the preamble the same way (`build.zig` `preamble_opts` is shared), so the guard survives with `zebra.exe` as the binary it compares against — mostly a rename |
| `n1_reference.sh` | builds the N-1 anchor from a tag; no bootstrap dependency of its own | unchanged |
| `release.yml`, `install/` | ship `zebra.exe` only already | unchanged |
| `CLAUDE.md` "Self-hosting" rule ("must be functionally equivalent to the Zig compiler in `src/`") | the rule that made the port complete | rewrite: the selfhost is the compiler; equivalence is with the *previous release* (the N-1 anchor), which is what `n1_reference` already measures |
| `keyword_coverage_baseline.txt` | the `abstract` note ("vanishes with the bootstrap") | drop the note and the word |

What the bootstrap is *not* needed for: regeneration (since 2026-08-30), the release, the
installer, the LSP, zebra-ide, or any documented user path except `--zig-backend`.

## 2. What is lost, honestly

1. **An independent second reader of the selfhost's sources.** `selfhost-div`'s
   gated half ("the compiler refuses its own source and the bootstrap accepts it")
   catches a class of self-inflicted wound: a front-end change that breaks the
   compiler's ability to read itself. After the sunset that is caught one step later,
   by `round-trip` Step 1 failing — same commit, same gate run, a less specific
   message. Acceptable.
2. **A codegen-independent oracle.** `output_sweep`'s golden files are committed text;
   whichever compiler first wrote them, the oracle is the file, not a second compiler.
   Nothing lost.
3. **A way to compile the selfhost if the selfhost is broken.** This is the real one.
   Today, if `zebra.exe` cannot compile `selfhost/*.zbr`, the bootstrap can. After the
   sunset there are two recovery paths, and both exist today:
   - **The committed `selfhost/*.zig`** — always. They are the previous generation of the
     compiler in source form; `git show <good>:selfhost/X.zig` into a scratch tree and
     `zig build` gives a working N-1 `zebra.exe` for any commit in history, with no
     Zebra compiler involved. This is what `rebuild.sh` already relies on every day.
   - **The N-1 anchor** — `tools/n1_reference.sh` builds the previous *release* from its
     tag. Works when the current sources use no feature newer than the anchor, which is
     usually and not always true (a compiler may use a feature the commit after it ships
     it); so it is the second path, not the first.
   This is the recovery every self-hosted compiler relies on (Zig's own stage1 → stage2
   history is the local precedent). **Step 0 below makes the first path a script and a
   gate before anything is removed.**

## 3. The steps, each gated

**Step 0 — prove the recovery path (no deletion).** DONE 2026-09-15 as
`tools/regen_recover.sh` (+ the `regen-recover` daily gate): build a scratch `zebra` from the *committed* `selfhost/*.zig`
(`git show HEAD:...`, no working-tree state), re-emit the working tree's `*.zbr` with it,
and report the diff against the working tree's `*.zig` — empty on a clean tree (which is
the round-trip property restated from git rather than from `zig-out`), and the
regenerated set when the working `zebra` is broken. A `daily`-tier gate runs it on a clean
tree and asserts the empty diff; `CLAUDE.md` gets the one-line recovery recipe. Must be
green before Step 3.

**Step 1 — stop *using* the bootstrap.** Remove `--zig-backend`, the `glfw`/`stub`
`--gui-backend` values, `debug --listen`; move the two Build fixtures to `smoke_run`;
drop the two bootstrap-only pins; repoint `zbr_vocab`/`lint_reserved_words` to
`selfhost/Token.zbr`. `docs/SURFACE.md` regenerates (−1 flag). CHANGELOG line. Quick
gate; `cli_check` gets a leg asserting `--zig-backend` is *refused by name* (a removed
flag is a surface change and gets the same receipt an added one does).

**Step 2 — retire the comparison tooling.** `selfhost-div` gate out of `gates.sh`;
`compile_check --bootstrap`, `divergence_check`, `diagnostic_parity`,
`triage_diagnostic_candidates`, `scaling_probe`'s bootstrap legs, `lint_interp_escape`
deleted (with their `CLAUDE.md` entries and `doc_lint` counts); `contract_mode_check`
bootstrap legs removed; `zig-test` gate retired. `tier_selfcheck.sh` after every
`gates.sh` edit. Gate counts change (static/fast/quick/full/daily) — each oracle in
`CLAUDE.md`'s table updated in the same commit.

**Step 3 — delete `src/` and the `zebra-bootstrap` build target.** `build.zig` loses
`bootstrap_exe`, the `earley`/module graph that only it used, `test/main.zig`,
`test/*.zig` hand-written integration tests. `rebuild.sh`/`doctor.sh` rename their
"bootstrap" guard to the selfhost binary. `CLAUDE.md` "Self-hosting" section rewritten.
`regen_authority_decision.md` gets a superseded banner pointing here. FULL gate, then a
DAILY run.

**Step 4 — the dead keyword machinery goes with it.** `StmtDefer` grammar rules,
`AstBuilder`/`CodeGen` `genDefer`, and `abstract` (`keyword_coverage_baseline.txt`)
were kept only because the bootstrap's tests referenced them. They leave in Step 3's
commit or the one after.

Order is not negotiable: 0 before 3. Steps 1 and 2 can land in either order and are
each a single quick-gate commit.

## 4. Non-goals

- Not a rewrite of anything the bootstrap did *well*; every user-visible path it still
  served is either already native or removed as a surface change with a receipt.
- Not single-file (`docs/design/regen_authority_decision.md` §"Single-file does not
  force the authority question" still holds; `--single-file` stays a shipped feature).
- Not a change to the N-1 anchor mechanism, which becomes *more* important, not less.
