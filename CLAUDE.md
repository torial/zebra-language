<!-- doc-status: live -->
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

## Rebuild + gate runners (start here)

Three wrappers encode the sequences below so you don't reassemble them by hand:

```bash
bash tools/doctor.sh           # is this tree in a state where results can be TRUSTED?
bash tools/doctor.sh --fix     # ...and clear what is safely clearable
bash tools/rebuild.sh          # make a selfhost/*.zbr edit REAL (regen + build)
bash tools/rebuild.sh --no-regen   # build only (no .zbr changed)
bash tools/rebuild.sh --module CodeGen   # THE INNER LOOP: regen ONE module + build, ~10s
bash tools/gates.sh            # QUICK tier (~6 min): lints + smoke + round-trip
bash tools/gates.sh --full     # FULL tier (~50 min): + compile_check, full_sweep, divergence
bash tools/gates.sh --list     # what each tier runs and what it cannot see
```

`rebuild.sh` exists because the regen sequence has four footguns that have each
cost real time: `zig build update-selfhost` **silently skips** regeneration after a
`.zbr`-only edit (BUG-210); a stale `/tmp/bs-zig` from a killed run causes unrelated
failures; an orphaned `zebra.exe`/`zig.exe` holds a file lock so the build dies
with `AccessDenied`; and a **preamble edit is invisible to the regen until the
bootstrap is rebuilt** (below). It also verifies the built compiler can actually run a
hello-world before reporting success.

**A `stdlib_preamble.zig` edit needs the full sequence *and* the right order.** Two
distinct traps, one at each end:
- The preamble is inlined at emit time, so the compiler only picks up a preamble
  change after **regeneration** (this is what made BUG-219's first fix look like it
  hadn't worked).
- `build.zig:37-59` **embeds** the preamble files into `zebra-bootstrap.exe` at *build*
  time, and the regen runs that binary — so regenerating before rebuilding the
  bootstrap emits the **old** runtime, and every gate downstream measures it. Observed
  2026-07-28: a preamble edit followed by `rebuild.sh` reported OK and changed zero
  generated files. The order is `zig build` → regen → `zig build`; `rebuild.sh` now
  does the leading build itself when a preamble file is newer than the binary.

**`--module NAME` is the inner loop, and it is ~10 s against several minutes.** The full
regen re-emits every selfhost module and rebuilds the intermediate compilers first; when
you have edited one `.zbr` and want to see whether the change took, that is almost all
waste. It is sound because the regeneration is done by the **bootstrap**, whose output for
the other modules your edit cannot have changed — verified by regenerating an untouched
module and getting a byte-identical file. (Extracted from `mutation_check.py`'s `regen()`,
which had already run this path thousands of times; two details carried over deliberately —
redirect to a **file**, never a pipe, and check the emit header is actually present rather
than trusting `rc=0`.)

What it does **not** do is prove the regenerated set is self-consistent — only the full
`rebuild.sh` runs the round-trip. So `--module` is for the edit/see/edit loop, and the full
sequence before gating or committing. It **refuses** if a `selfhost/*.zbr` is modified and
not named in `--module` (`--force` overrides): regenerating a subset leaves the tree
half-updated, and every gate downstream then measures a compiler that is partly old.

**Orphan-killing is scoped to this tree (`tools/kill_orphans.sh`), and that matters more
than it sounds.** `rebuild.sh` and `doctor.sh --fix` used to run `taskkill //F //IM
zebra.exe` — machine-wide. On 2026-08-01 that killed a mutation run's bootstrap in the
sibling worktree, mid-mutant, from a `rebuild.sh` in the main checkout. The victim of such
a kill does not see "someone killed me"; it sees a regeneration that failed for no visible
reason, and a harness scores that as a *result*. This repo regularly has two agents working
in it at once, plus isolated worktrees whose entire purpose is not to be affected from
outside. The lock being cleared (`AccessDenied` on `zig-out/bin`) is only ever held by a
process running from *this* tree, so path-scoping loses nothing — and the tool now prints
what it is leaving alone, because silence is what made the old behaviour look like an
unrelated failure.

`doctor.sh` checks the failure modes this environment actually produces, every one of
which has bitten us: **stale generated `.zig`** (you would be testing the OLD compiler —
`zig build update-selfhost` silently skips regeneration, BUG-210, and this made a real
BUG-219 fix appear not to work), orphaned compiler processes holding a lock on
`zig-out/bin` (→ `AccessDenied`), stale `/tmp/bs-*` scratch from a killed run causing
unrelated failures, a compiler that cannot run a hello-world, and low RAM before a
RAM-bound gate. It exits **1** only for states that make results *lie*; everything else
is a warning. **`gates.sh` runs it as a preflight and refuses to report on an
untrustworthy tree** — a green gate that measured the wrong compiler is worse than no
gate at all.

`gates.sh` runs the set in order with one summary line each and exits non-zero on
any failure. It deliberately does **not** fold in the GUI paths, `fuzz/gramgen.py`,
or `node_addon_test.sh`, so that "gates green" keeps a precise meaning — see its
`--list` for the honest limits. On GUIs the line moved on 2026-07-30: **no gate proves
RENDERING, but startup is now covered** by `tools/gui_scaffold_check.sh` (BUG-229). Four
GUI crashes have sat under fully green gates, and all four were at *startup* — which
needs neither a human nor a terminal to detect. Rendering, input, layout, resize and
colours still require Sean running it.

## Every document says what it is (read this before reading the docs)

Line 1 of each `.md` carries `<!-- doc-status: ... -->`, one of four values. It exists so
a session arriving cold can tell what to *skip* rather than guessing:

| status | meaning | what to do |
|---|---|---|
| `live` | describes CURRENT state | trust it — and keep it true when you change things |
| `historical` | append-only record or dated snapshot | **skip unless you want the history.** Accurate as of its entries; do NOT "fix" a stale reference — that falsifies the record |
| `design` | a design/decision note | read only when touching that subsystem; may describe intent that is not built. Each carries its own `Status:` line |
| `generated` | produced by a tool | **skip.** Edit the tool, not the file |

**12 of the 44 documents are `historical` or `generated`** <!-- doc-gen: 12 = for f in *.md docs/*.md; do head -1 "$f" | grep -qE 'doc-status: (historical|generated)' && echo x; done | wc -l | tr -d ' ' -->,
i.e. skippable with confidence. That is the point: the surface area of this repo's
documentation is what let one wrong claim live in four files at once, and "which of these
is current?" was previously answerable only by reading them.

`doc_lint` D7 enforces the declaration, and its own archival-vs-live split now READS it.
It used to hardcode four filenames — a list that was itself the hazard it guarded against,
since it would have gone silently wrong the first time someone added an append-only
document. A declaration cannot drift out of sync with the file it is written in.

## The corpus is what git TRACKS, not what is on disk

Every heavy gate used to enumerate its corpus with a filesystem glob (`ls test/*.zbr`),
which made its result depend on whatever untracked scratch happened to be in the
directory. Found 2026-08-01: `examples/zz_red_main.zbr`, a scratch probe, untracked, in a <!-- doc-lint-ok: the 2026-08-01 stray, named because a concrete instance is what makes the hazard real; cleared by tidy.sh --clean 2026-08-03, so a dangling name here is the tool having WORKED, not a broken link -->
directory `full_sweep --examples --gate` sweeps — invisible to anyone reading the commit
and not reproducible anywhere else.


The worst instance was not a sweep. `bug_fixture_check.py` decides whether a reported bug
has a regression fixture by looking for `test/bug<N>_*.zbr`, so an **untracked** file could
turn that gate **GREEN** by appearing to supply a fixture that exists for nobody else. The
sweeps could only add noise; that one could hide debt.

`tools/corpus_ls.sh` is now the single enumerator — `full_sweep`, `divergence_check`,
`boundary_check` and `bug_fixture_check` all go through it. It reads `git ls-files`, so
**staged counts**: staging is the point at which a file stops being scratch and becomes
something you are asking others to have. It **refuses** to fall back to a glob outside a
git worktree, because a silent fallback would reintroduce exactly the bug it exists to
remove. `gate_selfcheck` carries the inverse of its usual leg here: it plants an untracked
file and requires it to be **ignored** (having first confirmed a glob *would* have seen
it, so the control cannot pass vacuously).

`bash tools/tidy.sh` reports strays; `--clean` removes **only** known-scratch patterns
(`zz_*`, `_mut_*`, `probe_*`) and merely lists everything else. An untracked `.zbr` in
`test/` might be an abandoned probe or a fixture someone is three minutes from committing,
and the tool cannot tell — so it does not guess. **Name throwaway files `zz_*`** and they
become one command to clear.

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
python tools/lint_interp_escape.py # THE INTERP-ESCAPE GATE (static, instant, no build):
                                #   flags a Zebra string that is BOTH interpolated (`${`) and
                                #   contains `\"`. The bootstrap — still the REGEN AUTHORITY for
                                #   selfhost/*.zig — double-escapes that combination, so the
                                #   corruption lands in the shipping compiler. It silently broke
                                #   all 3 genCopyOut `<<-`/`<-` diagnostics (they emitted a Zig
                                #   PARSE error instead of their message) until 2026-07-27.
                                #   BUG-216. 0 = clean. Retire when the bootstrap is fixed/gone.
python tools/hazard_lint.py        # THE TOOLING GATE (static, instant, no build) — the
                                #   only gate pointed at `tools/` rather than at Zebra code.
                                #   Five bugs were found in tools/mutation_check.py between
                                #   2026-07-31 and 08-01 and NOT ONE crashed, warned, or
                                #   exited non-zero: each produced a confident wrong NUMBER,
                                #   and two were published before being caught (241 fake
                                #   "regen detections" from a CRLF restore; a "0 survivors"
                                #   headline from a fingerprint that was a constant).
                                #   Hazards with receipts, each citing its incident: H1 a
                                #   .zbr text-write without newline="\n"; H2 bare `bash`
                                #   (resolves to WSL here) or a wsl-prefixed command; H3 a
                                #   constant sentinel on a path feeding a comparison —
                                #   always biases toward "nothing changed"; H4 a
                                #   compiler-SPECIFIC emit header (two compilers, two
                                #   headers); H5 `git checkout -- .`. Suppress with
                                #   `# hazard-ok:<code> <reason>` — a reason is REQUIRED,
                                #   because an unexplained suppression is how a gate goes
                                #   quiet. It runs its own positive controls before every
                                #   scan and REFUSES to report clean if any stopped firing.
                                #   `--rev 7156d3e` is the non-circular proof: it re-derives
                                #   3 of the 5 real bugs on the commit that shipped them.
                                #   0 = clean. QUICK tier.
python tools/doc_lint.py           # THE DOC-DRIFT GATE (static, instant, no build) — checks
                                #   the CHECKABLE claims only. D1 a `tools/x.sh` named in a
                                #   .md exists; D2 a repo path linked from a .md exists;
                                #   D3 every gate registered in gates.sh is DESCRIBED here
                                #   in CLAUDE.md (an undocumented gate is how a tier's
                                #   meaning drifts — it found 3 on the day it was written);
                                #   D4 a cited BUG-NNN exists in one of the two ledgers.
                                #   Append-only records (BUGS.md, BUGS_FIXED.md, the journal,
                                #   CHANGELOG, dated audits) are REPORTED but not gated: an
                                #   entry naming a tool deleted three months later is accurate
                                #   history, and "fixing" it would falsify the record.
                                #   Suppress a deliberate dangling reference (a PROPOSED tool,
                                #   a promotion history) with `<!-- doc-lint-ok: reason -->`;
                                #   the reason is required. It prints its own uncovered set
                                #   every run — behaviour claims, coverage counts, and
                                #   anything inferred from a gate's SILENCE are NOT checked,
                                #   and a clean run must not be read as "the docs are
                                #   accurate". 0 = clean. QUICK tier.
bash tools/release_mode_check.sh   # THE ONLY GATE THAT BUILDS WITH `--release` (FULL tier).
                                #   Every other gate in every tier is DEBUG. That is exactly
                                #   how BUG-228 survived 19 green gates for four days:
                                #   `--release` switched the backend to LLVM (a visible
                                #   20 MB -> 2 MB change) while the branch that emits the
                                #   executable passed no optimize flag at all, so Zig
                                #   defaulted to Debug. Everyone shipping with the flag
                                #   shipped Debug believing otherwise — the flag's whole
                                #   purpose. No gate could see it because none used it.
                                #   Asserts (1) a --release build RUNS and prints the right
                                #   answer — optimisation must not change behaviour, the
                                #   half that matters most — and (2) the release binary is
                                #   materially smaller than the same program built without.
                                #   THE SIZE CHECK IS SELF-CALIBRATING: it compares two
                                #   binaries built in the same run rather than a recorded
                                #   number, because a hardcoded size rots on the next Zig
                                #   release and then passes or fails for no reason. What it
                                #   really asks is "did the -O flag reach zig", and the
                                #   regression it exists to catch makes the two builds
                                #   IDENTICAL in size. Verified red against that exact case
                                #   (812 KB vs 812 KB -> FAIL). 25% margin, not an exact
                                #   figure. Observed: 812 KB vs 19,072 KB.
                                #   A SKIPPED size check is a FAILURE, not a pass — the
                                #   first version could not find the binaries and printed
                                #   "all checks pass" with its only real assertion never
                                #   having run.
                                #   Runs a full LLVM build → FULL tier, not QUICK.
python tools/doc_example_check.py  # THE DOC-EXAMPLE GATE — the only gate pointed at what a
                                #   READER is told, rather than at what the compiler does.
                                #   224 fenced `zebra` blocks existed and NOTHING verified
                                #   one of them until 2026-08-03. That is not abstract debt:
                                #   QUICKSTART — the file whose header calls it the
                                #   authoritative reference — documented thread spawning as
                                #   `sys.go(lambda …)` in five blocks, and `lambda` is NOT A
                                #   ZEBRA KEYWORD. None had ever compiled. It was found by
                                #   trying to follow the doc and failing twice (BUG-245).
                                #   Scoped by `doc-status`: only `live` docs are checked —
                                #   BUGS.md is 24 blocks of deliberately-broken repros, and
                                #   "fixing" those would falsify the record.
                                #   SIGNAL vs ARTIFACT is what makes it usable. Checking
                                #   every block naively yields ~100 failures, ~90% noise
                                #   (fragments referring to prose: "undefined name: 'data'").
                                #   A gate at that ratio gets suppressed wholesale. So an
                                #   "undefined name" is an ARTIFACT and NOT gated, while
                                #   "the parser could not READ this construct" is SIGNAL and
                                #   IS. Elision (`...`), counterexamples (`# error:`) and
                                #   `<!-- doc-example-ok: reason -->` are skipped.
                                #   FRONT END ONLY (`zebra -c`) — a doc fragment has no
                                #   modules around it, so a full compile would drown syntax
                                #   errors in missing-dependency noise.
                                #   Baselined at 27, so it fails only on NEW breakage. That
                                #   baseline is REAL DEBT a reader hits, in three families:
                                #   `print` WITHOUT PARENS (pre-`()`-mandatory Cobra syntax),
                                #   the REMOVED `to!` operator, and assorted stale forms.
                                #   Shrink it; do not grow it. Runs its own good/bad controls
                                #   every invocation and exits 2 if either stops
                                #   discriminating. 0 = clean. QUICK tier.
python tools/lint_fallthrough.py   # THE FALL-THROUGH GATE (static, instant, no build):
                                #   flags a value-returning fn whose TAIL `branch` has a
                                #   value-producing arm that can fall through without
                                #   returning. Codegen TCO-wraps such fns in `while(true)`,
                                #   so a fall-through arm HANGS (not a compile error). Caught
                                #   nothing new when written (the hazard was isolated to the
                                #   §28f set-literal arms, since fixed) but re-flags that exact
                                #   bug if reintroduced. Run after adding any `branch` arm to a
                                #   recursive walker (exprHasTry/inferExpr/…). 0 = clean.
bash tools/runtime_module_check.sh # THE ONLY GATE THAT RUNS EMITTED OUTPUT: small programs
                                #   exercising the DEFAULT emit shape — hello-world (asserting
                                #   the emitted file is <100 lines, i.e. the runtime really was
                                #   externalised into zebra_rt.zig and did not silently go back
                                #   to being spliced), the BUG-221 three-module repro (which
                                #   SEGFAULTED before this change), `zebra run` / `zebra -c`
                                #   (a DIFFERENT branch of zbrToZig — temp dir, not
                                #   --output-dir), and that `--no-runtime-module` and
                                #   `--single-file` still produce the INLINE runtime.
                                #   compile_check never runs anything, so it cannot see any of
                                #   this; and every other gate is happy whichever shape is the
                                #   default, so this is the only one that would notice a silent
                                #   revert. It deliberately passes NO flag where it can.
                                #   Cheap → QUICK tier. Pair with:
JOBS=3 bash tools/compile_check.sh --no-runtime-module  # gate label: `compile_check-inline`
                                #   the SAME corpus with the INLINE
                                #   runtime. Runtime-module emission is the DEFAULT as of
                                #   2026-07-28, so the INLINE shape is the one that would
                                #   otherwise go unwatched — and it stays live via the opt-out
                                #   and as the fallback for --single-file / node-addon / every
                                #   --gui-backend. 217/0/1, identical to the default. FULL tier.
bash tools/boundary_check.sh    # THE INTENT WITNESS (A3, QUICK tier, ~30s): the only
                                #   gate whose expectations were WRITTEN FROM THE LANGUAGE
                                #   REFERENCE rather than recorded from the compiler. Every
                                #   other behaviour check here is a GOLDEN baseline, which
                                #   catches regressions and can NEVER find something that
                                #   was wrong on day one. Probes in test/boundary/, triage
                                #   in docs/boundary_triage.md.
                                #   FIRST RUN (2026-07-30) found BUG-230 (an annotated
                                #   non-empty list literal does not compile — invisible to
                                #   divergence BY CONSTRUCTION, since both compilers do the
                                #   identical wrong thing, and absent from the corpus so
                                #   compile_check never emits it), BUG-232 (arity checking
                                #   SKIPPED inside `${...}`) and BUG-231.
                                #   THE PROPERTY THAT MAKES IT WORK is that expectations are
                                #   authored BEFORE the first run — protected structurally by
                                #   the commit boundary (probes+intent unrun in 603a580,
                                #   findings after). If an .expected is ever written by
                                #   pasting observed output, this is output_sweep with extra
                                #   steps: delete it rather than keep it.
                                #   Probes marked `@boundary-pending BUG-NNN` pin KNOWN-BROKEN
                                #   behaviour on purpose — they pass today, print their ticket
                                #   every run, and FAIL when the bug is fixed. That failure is
                                #   the signal to rewrite the probe, NOT to re-baseline.
RE-BASELINE ORDER (learned 2026-07-31): output_sweep derives its CANDIDATE set from
the FULL_SWEEP baseline. When a corpus file changes compile status, re-baseline
**full_sweep FIRST, then output_sweep** — the other order leaves an output_sweep entry
whose file is no longer a candidate, and the gate correctly reports it as "stopped being
measured", which is a coverage loss rather than a behaviour change.

bash tools/check_mode_check.sh     # THE CHECK-MODE CONTRACT GATE: `-c` is front-end-only
                                #   and deliberately incomplete, so what needs gating is the
                                #   CONTRACT, not the coverage — valid code passes both modes,
                                #   a front-end error fails both, and the asymmetry `--help`
                                #   promises ACTUALLY EXISTS (it requires witnesses that pass
                                #   `-c` and fail `--check-full`). It also guards the SPEED,
                                #   so `-c` silently starting to invoke zig again fails here.
                                #   Carries a built-in failure when no asymmetry witness
                                #   survives, which is why gate_selfcheck lists it as
                                #   self-falsifying. QUICK tier.
python tools/bug_fixture_check.py --gate  # THE REGRESSION-FIXTURE GATE (A1): SQLite's "a
                                #   regression test for every reported bug", as a lint rather
                                #   than a habit. Fails only on NEW debt — the existing
                                #   backlog is baselined — and counts a fixture as real only
                                #   if something actually RUNS it, since an orphaned .zbr
                                #   nobody executes is the shape this class of debt takes.
                                #   Also globs test/boundary/*.zbr. Static; instant. QUICK.
python tools/registration_check.py # THE UNASSERTED-FILE GATE (BUG-243, static, instant):
                                #   every tracked test/*.zbr must have its status asserted by
                                #   SOMETHING — a smoke* registration, presence in the
                                #   full_sweep pass baseline, or an entry in
                                #   tools/registration_exempt.txt WITH A REASON.
                                #   Why: full_sweep gates against a BASELINE, so a file that
                                #   has NEVER passed cannot make it red however broken it is;
                                #   and with no registration nothing asserts it should fail
                                #   either. A permanently-broken file is then indistinguishable
                                #   from an intentionally-negative one. Fifteen were found in
                                #   exactly that state on 2026-08-02 — including the regression
                                #   fixtures for BUG-106 and BUG-108, which had NEVER RUN, so
                                #   those fixes were unverified. Baselined like bug-fixture:
                                #   fails only on NEW debt (24 known). Shrink it, never grow it.
                                #   QUICK tier.
python tools/lint_oom_unreachable.py  # THE RELEASE-ONLY-UB GATE (A4): `unreachable` is
                                #   undefined behaviour in ReleaseFast, which is what
                                #   `zebra --release` ships. Every gate here runs Debug,
                                #   where it TRAPS cleanly — so this hazard is invisible to
                                #   all of them and live only in what users distribute.
                                #   A static lint is the only witness that can see it at all.
                                #   0 = clean. QUICK tier.
bash tools/output_sweep.sh --gate  # THE BEHAVIOUR WITNESS — the only heavy gate that
                                #   RUNS the corpus and reads what it PRINTED. Everything
                                #   else in the FULL tier asks "does the emitted Zig
                                #   compile?", so valid Zig producing WRONG OUTPUT is
                                #   invisible to all of them at any corpus size (BUG-226:
                                #   a for-header `tokenize` emitted {any} and printed
                                #   `{ 97 }` for `a` — perfectly good Zig).
                                #   327 of the 335 compile-clean files, golden-baselined.
                                #   NONDETERMINISM IS DERIVED, never hand-listed:
                                #   --update-baseline runs every file TWICE and auto-
                                #   excludes any whose output differs, recording the
                                #   reason (8 today: clocks, timings, racy panics, and 3
                                #   server fixtures that never terminate). A hand-written
                                #   skip list rots and silently shrinks coverage.
                                #   LIMIT: golden baseline = catches REGRESSIONS, not
                                #   existing wrongness — same limit full_sweep_baseline
                                #   has. It refuses to write a baseline that is >25%
                                #   empty, so a broken capture cannot become a gate that
                                #   is green forever while measuring silence.
                                #   Sequential by design (parallel fixtures interfere).
                                #   --update-baseline to re-record, --only for a tight
                                #   loop, --show to see what is being captured.
JOBS=2 bash tools/full_sweep.sh --examples --gate  # gate label: `examples_sweep`
                                #   A5 — THE SAME SWEEP OVER examples/.
                                #   Until 2026-07-30 NO gate touched examples/ at all: every
                                #   heavy gate globs test/*.zbr. That was not theoretical —
                                #   examples/widget_smoke.zbr SHIPPED BROKEN on BUG-230, and
                                #   `zebra -c` exits 0 on it (check mode is front-end-only),
                                #   so the obvious spot-check could not see it either. BOTH
                                #   had to be true for it to go unnoticed.
                                #   First run: 18 examples, 14 baselined, and it found BUG-233
                                #   on the spot. Small (~90s) → FULL tier. Non-passing entries
                                #   are NAMED in its output, not just counted, because on this
                                #   corpus each one is a question worth answering.
                                #   `DEPMISS` ≠ broken: a search-path dep that --output-dir
                                #   never emitted (lsystem RUNS fine). A gate that libels a
                                #   working file is one people learn to disbelieve.
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

**But note the ceiling on that sentence, because it is easy to over-read (BUG-226,
2026-07-29).** `compile_check`, `full_sweep` and `divergence` all ask *"does the emitted
Zig compile?"* — none of them **runs** it. Only `selfhost_smoke.sh` (for its registered
fixtures) and `runtime_module_check.sh` execute anything. So a bug whose symptom is
**correct-compiling code that produces the wrong output** is invisible to the three
heaviest gates by construction, no matter how much corpus you throw at them.

BUG-226 is the receipt: `for t in s.tokenize(",")` typed its loop element wrongly and
emitted `{any}` instead of `{s}`, so it printed `{ 97 }` where `a` was meant. Perfectly
valid Zig. It would have survived every tier indefinitely. What catches this class is a
**run-and-compare fixture** — a `smoke_run` with expected output — which is why a
rendering or semantics fix should always land with one, and why "compile_check is the
independent witness" means *witness to compilability*, not to correctness of behaviour.

**`tools/output_sweep.sh` (added 2026-07-30) closes most of that gap** — see its entry
below. Behaviour coverage went from 126 files to 327. It does not remove the need for a
`smoke_run` on a new fix: the sweep is a *golden* baseline, so it can only tell you
behaviour CHANGED, never that it was right to begin with.

**`tools/boundary_check.sh` (added 2026-07-30) is the answer to that last clause**, and it
is the only gate here that can be. Its expectations were written from QUICKSTART *before*
the compiler was run, so it asserts what the language is supposed to do rather than what it
happens to do — which is why it found BUG-230 on its first run, a three-line program that
does not compile and that no corpus-based gate could ever have surfaced (both compilers
share the bend, and the `test/*.zbr` corpus the heavy gates sweep does not use the form —
the one file that does is `examples/widget_smoke.zbr`, which is **shipping broken**,
because no gate sweeps `examples/` at all). Treat "recorded" and "intended" as
genuinely different properties: everything else in this file measures the first.

### Which property does each gate actually assert?

Worth keeping straight, because "how many gates are green" answers a different question
than "what do we know":

| property | asserted by | corpus coverage |
|---|---|---|
| front end doesn't error | `smoke` (bare helper — emit only, does **not** compile) | 101 |
| emitted Zig compiles | `compile_check`, `full_sweep`, `divergence` | 335 |
| compiler is self-consistent | `bootstrap_check` (round-trip) | selfhost only |
| **program prints the right thing** | `smoke_run`/`smoke_test`, **`output_sweep`** | **327** |
| **…and it is the RIGHT thing, per the reference** | **`boundary_check`** (intent-authored, not recorded) | 12 probes / ~140 assertions |
| parser survives hostile input | `fuzz/gramgen.py` | 960 derived programs |
| static hazard classes | `lint_interp_escape`, `lint_fallthrough` | all `.zbr` |
| generated docs match the compiler | `str_ownership_extract --check` | 28 operations |
| **the gates can still fail** | `gate_selfcheck.sh` | 7 gates |
| **our own tools are not lying** | `hazard_lint` (+ its controls) | 60 scripts | <!-- doc-gen: 60 = ls tools/*.sh tools/*.py fuzz/*.py *.py 2>/dev/null | wc -l | tr -d ' ' -->
| docs' checkable claims still resolve | `doc_lint` | 45 documents |
| **the docs' EXAMPLES actually parse** | `doc_example_check` | 161 blocks in 25 live docs | <!-- doc-gen: 46 = ls *.md docs/*.md | wc -l | tr -d ' ' -->

The last row is the one that keeps the rest honest; see its header for why.

## What the gates do NOT cover — and when it was last checked

`gates.sh` deliberately excludes three things so that "gates green" keeps a precise
meaning. That precision is only worth anything if the excluded set is actually run
sometimes, so record the date here when you do.

**Swept 2026-08-02, all clean** — run together with the FULL tier as §3 of
`docs/INSTRUMENT_PASS_PLAN.md`. Sequential, not parallel: two heavy jobs at once on this
machine is how a RAM-bound gate reports contention as a failure.

| path | result |
|---|---|
| `bash tools/gates.sh --full` | **18/18 PASS** — compile_check 231/0, output_sweep 322 identical, full_sweep 0 regressions vs 337, examples_sweep 0 vs 14, divergence 0 selfhost gaps |
| `python fuzz/gramgen.py --gate` | PASS — 960 derived programs, 0 hangs, 0 crashes |
| `bash tools/node_addon_test.sh` | PASS |
| `bash tools/gui_scaffold_check.sh` | PASS — scaffold globals assigned, app got PAST the BUG-229 crash site and refused a non-tty cleanly (rc=3) |

**What a fully green board here does NOT mean.** `full_sweep` passes against a baseline of
**337** while the corpus is **421**. 27 of the difference are registered negative tests;
**57 are in no known category** — not passing, not asserted-to-fail, not ticketed. A
baseline defines the pass set, so files outside it cannot make the gate red no matter how
broken they are. BUG-241 and BUG-242 were both found sitting in exactly that gap. Green
and unexamined are not in tension; see `docs/INSTRUMENT_PASS_PLAN.md` §2.

**Previous sweep 2026-07-29** — after runtime-module emission became the default, because
that change made GUI and node-addon take a *new* fallback branch that no gate exercises.

The GUI check is the one that mattered: it confirmed the fallback does what it claims
— the emitted `src/main.zig` is the INLINE shape (3,947 lines, **zero** `zebra_rt.zig`
imports) with the tui backend selected. A fallback that had silently emitted the split
shape would have produced a program importing a runtime its own scaffold never places,
and nothing in any gate tier would have caught it.

**Updated 2026-07-30 — the GUI gap is now partial, not total.** BUG-229 (tui apps
segfaulting because the selfhost emit never assigned `_tui_env`) was the **fourth** GUI
crash to sit under fully green gates. All four were at **startup**, and a startup crash is
not a rendering problem — it needs neither a human nor a terminal. So
`tools/gui_scaffold_check.sh` now covers that half:

| | covered by | |
|---|---|---|
| scaffold declares a global `= undefined` and never assigns it | `gui_scaffold_check` leg 1 (static) | **gated** |
| app dies with a memory fault at startup | `gui_scaffold_check` leg 2 (runtime) | best-effort |
| rendering, input, layout, resize, colours | **a human running it** | still uncovered |

Run it as `bash tools/gui_scaffold_check.sh [examples/foo.zbr]`. It builds a real tui app,
so it is minutes, not seconds — treat it like `compile_check`: per-session and
pre-release, not in the QUICK tier. The tool prints its own uncovered list, so the
remaining gap cannot quietly be forgotten.

Sean confirmed BUG-229's fix by running `--gui-backend=tui examples/counter.zbr` and
clicking through it — which remains the only verification that can close a GUI bug.

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
