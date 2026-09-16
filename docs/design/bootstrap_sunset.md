<!-- doc-status: design -->
# Bootstrap sunset — retiring `src/` and `zebra-bootstrap`

**Status:** DONE, all four steps (2026-09-16). Decided in principle by Sean,
2026-09-15 ("I agree re a). Let's move to no bootstrap. Worth the effort imo"). Each step
below was gated and landed as its own commit; nothing was deleted until the step that
replaced it was green.
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
| `selfhost-div` gate (`tools/attic/selfhost_divergence_check.sh` since Step 2) | the two-implementation comparison: does the bootstrap still read every selfhost module the selfhost reads? Informational when the selfhost has *outgrown* it (that number rises every time a keyword is freed), gated only for "the compiler refuses its own sources and the bootstrap accepts them" | **retire**; the property it gates ("the compiler accepts its own sources") is already `round-trip`'s Step 1 |
| `--zig-backend` (`zebra --zig-backend x.zbr`) | delegates the whole compile to the bootstrap | **remove** the flag (surface −1 flag, CHANGELOG line) |
| `--gui-backend=glfw` / `stub` | delegated to the bootstrap; `tui` and `libui_ng` are native | **remove** `glfw`; `stub` is the native default said explicitly (`contract_mode_check.sh`'s bootstrap legs go with them) |
| `zebra debug --listen PORT` (TCP DAP) | delegates; stdio mode is native | **port or drop**: zebra-ide uses stdio; drop the TCP mode with a usage line saying so |
| `smoke_run_bootstrap` in `selfhost_smoke.sh` (4 fixtures) | `build_smoke`/`build_declarative` run under the bootstrap because of a *stale* comment ("selfhost parity for Build is pending" — `zebra build` was ported 2026-09-04 and `test/build_requires_test.zbr` runs the Build API through the selfhost today); `bug124`/`bug250` pin bugs *in the bootstrap's own codegen* | move the two Build fixtures to `smoke_run`; delete the two bootstrap-only pins (their bugs die with the code they pin) |
| `compile_check.sh --bootstrap`, `divergence_check.sh`, `diagnostic_parity.py`, `mutation_check.py`, `scaling_probe.py`, `triage_diagnostic_candidates.py` | compare the two compilers | **retire** the comparison modes; `mutation_check` keeps its selfhost-only mode |
| `lint_interp_escape.py` | a bootstrap-only hazard | **retire** (already noted as "retire with bootstrap") |
| `zbr_vocab.py` / `lint_reserved_words.py` | read the keyword table from `src/Token.zig` (and `zbr_vocab` cross-checks it against `selfhost/Token.zbr`) | **repoint** to `selfhost/Token.zbr` only; `surface_inventory.py` and `keyword_coverage` inherit the change | <!-- doc-lint-ok: the retired file, named as the record of what was repointed -->
| `zig-test` gate (131 tests: `src/*.zig` unit tests + `test/main.zig` integration) | tests of the *bootstrap's* tokenizer/parser/printer | **retire** the gate with the code; the selfhost's own tests are `.zbr` fixtures in the smoke (`selfhost/ast_test.zbr`, `typechecker_test.zbr`, …), which stay | <!-- doc-lint-ok: the retired files, named as the record of what was retired -->
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

**Step 1 — stop *using* the bootstrap.** DONE 2026-09-15. Remove `--zig-backend`, the `glfw`/`stub`
`--gui-backend` values, `debug --listen`; move the two Build fixtures to `smoke_run`;
drop the two bootstrap-only pins; repoint `zbr_vocab`/`lint_reserved_words` to
`selfhost/Token.zbr`. `docs/SURFACE.md` regenerates (−1 flag). CHANGELOG line. Quick
gate; `cli_check` gets a leg asserting `--zig-backend` is *refused by name* (a removed
flag is a surface change and gets the same receipt an added one does).

**Step 2 — retire the comparison tooling.** DONE 2026-09-16 (`zig-test` deliberately kept
until Step 3 removes the code it tests — an unrun suite is what BUG-279 forbids; and
`divergence_check`'s multi-module skip is now a coverage gap the N-1 anchor no longer
needs, listed as a follow-up in §5). `selfhost-div` gate out of `gates.sh`;
`compile_check --bootstrap`, `divergence_check`, `diagnostic_parity`,
`triage_diagnostic_candidates`, `scaling_probe`'s bootstrap legs, `lint_interp_escape`
deleted (with their `CLAUDE.md` entries and `doc_lint` counts); `contract_mode_check`
bootstrap legs removed; `zig-test` gate retired. `tier_selfcheck.sh` after every
`gates.sh` edit. Gate counts change (static/fast/quick/full/daily) — each oracle in
`CLAUDE.md`'s table updated in the same commit.

**Step 3 — delete `src/` and the `zebra-bootstrap` build target.** DONE 2026-09-16.
`src/` (16 files, 37,549 lines) and the Zig integration harness `test/main.zig` deleted; `build.zig` loses <!-- doc-lint-ok: the deleted file, named as the record -->
`bootstrap_exe`, the `earley` dependency (`build.zig.zon` has none now), the per-file
module graph, the `unit`/`integration` test binaries and `test-zig`/`grammar` steps;
`update-selfhost` depends on the install step. Three gates retired with their oracles
(`zig-test`, `grammar-export` — `grammar.txt` is FROZEN at the last export and
`gramgen` still reads it — and `decl-exhaustive`): tiers are 14 static / 28 fast / 30
quick / 38 full / 46 daily. `rebuild.sh`'s footgun-4 guard is GONE rather than renamed:
the selfhost reads the preamble from disk at codegen time, so there is no embedding
binary to be stale against (`rebuild_guard_check.sh` to the attic with it, and
`gate_selfcheck`'s doctor leg). `fuzz/harness.py` is a validity oracle rather than a
differential one; `extern_check.sh`, `check_inference_guess.sh`, `lint_zig_keywords.py`,
`escape_hatches_check.sh` lost their bootstrap legs; `unreachable_runtime.sh` and
`check_explicit_try.sh` retired. `lint_reserved_words.py` learned that the selfhost
parser reaches most keywords BY TEXT (`.textIs("and")`) — with the Earley table gone it
would have called 43 live keywords unreachable — and its one true finding was `has`,
which only the bootstrap's grammar ever accepted: freed (surface 69 → 68 keywords).
`CLAUDE.md` "Self-hosting" rewritten; `regen_authority_decision.md` carries the
superseded banner. `bug_fixture_baseline.txt` grew by two -- BUG-103 and BUG-279 were
pinned by the retired gates (`decl-exhaustive`, `zig-test`) and their subject is the
deleted code, so no fixture can exist; the baseline records that rather than a gate
pretending otherwise. FULL gate, then a DAILY run.

**Step 4 — the dead keyword machinery goes with it.** DONE 2026-09-16. `Stmt.defer_`,
`guard_`, `assert_eq_/ne_/true_/false_` and `TypeRef.same_` with their structs, the
PNode variants and AstBuilder arms that built them, every consumer arm across CgHelpers
(35), CodeGen (21), TypeChecker (7) and Checker (6), `genDefer`/`genGuard`/`genAssertCmp`/
`genAssertUnary`, the preamble's `_zebra_assert_cmp`/`_zebra_assert_bool`, `Modifiers.
is_abstract`/`is_readonly`, and the 13 dead `kw_*` variants in `TokenKind`. Nothing
user-visible: every one of these was unreachable since its keyword was freed, which is why
it could wait for the bootstrap's tests to stop referencing it.

Order is not negotiable: 0 before 3. Steps 1 and 2 can land in either order and are
each a single quick-gate commit.

## 4. Non-goals

- Not a rewrite of anything the bootstrap did *well*; every user-visible path it still
  served is either already native or removed as a surface change with a receipt.
- Not single-file (`docs/design/regen_authority_decision.md` §"Single-file does not
  force the authority question" still holds; `--single-file` stays a shipped feature).
- Not a change to the N-1 anchor mechanism, which becomes *more* important, not less.

## 5. Follow-ups the sunset exposed (not part of the steps)

- **`divergence_check` skips multi-module files** (any file with a local `use`) because
  the bootstrap could not materialise dependencies through stdout. The reference has been
  the N-1 anchor since 2026-09-01 and it takes `--output-dir`, so the skip is now a
  coverage gap, not a necessity. LIFTED 2026-09-16 (overnight): every file is compared;
  a pre-lift `--results` file is refused rather than scored. First run (torial, 57
  multi-module files now compared): 0 regressions from the lift itself; the one
  REGRESSION it reported was `branch_guard_test`, refused by the same night's
  unused-binding rule (two unguarded arms bound a payload they never read) -- a
  corpus file the smoke never registered, caught by this gate. Fixed in the fixture.
- **Generic interfaces.** Freeing `same` (2026-09-16) left the self-typed interface method
  with one spelling — the interface names itself — because `interface X(T)` does not
  parse. The proper replacement is a language addition, queued in NEXT_STEPS_to_1.0.
