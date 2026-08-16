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
                                #   .md is TRACKED; D2 a repo path linked from a .md is
                                #   TRACKED;
                                #   TRACKED, NOT MERELY PRESENT — changed 2026-08-09, and
                                #   both directions had bitten. It enumerated documents with
                                #   a filesystem glob, so another agent's untracked working
                                #   note in the root turned this SHARED gate red for
                                #   everyone (a D7 "no doc-status" plus a D6 count drift) on
                                #   a file nobody else had. And it resolved a referenced
                                #   path with `.exists()`, which on this case-insensitive
                                #   filesystem answered YES for `selfhost/codegen.zbr` when
                                #   the file is `CodeGen.zbr` — so D2 was BLIND TO EVERY
                                #   CASE-WRONG PATH, and switching to `git ls-files`
                                #   (case-sensitive) immediately surfaced 10 stale
                                #   references to the pre-rename lowercase module names
                                #   across four live/design docs. The false-green was the
                                #   worse half: a red gets fixed. Same line corpus_ls.sh
                                #   draws, and the same refusal — no silent fallback to
                                #   globbing outside a git worktree.
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
bash tools/contract_mode_check.sh  # THE CONTRACT-STRIPPING CONTRACT (FULL tier, ~55s):
                                #   the ONLY gate that passes `--turbo`, and the only one
                                #   asserting what the two shipping flags DO. Matrix:
                                #     (none)            contracts fire   assert fires
                                #     --release         contracts FIRE   assert fires
                                #     --turbo           stripped         assert FIRES
                                #     --release --turbo stripped         assert FIRES
                                #   `--turbo` and `--release` are INDEPENDENT and compose;
                                #   a shipping build is `--release --turbo`. `assert`
                                #   deliberately survives `--turbo`: a contract is a proof
                                #   obligation on the caller, an assert is a check the
                                #   author wrote to RUN.
                                #   THE ASYMMETRIC LEGS ARE THE POINT. It would be easy to
                                #   assert "contracts off in release" and pass — that was the
                                #   documented and WRONG belief (BUG-257: docs claimed
                                #   "--turbo strips them, so release builds are unaffected",
                                #   which does not follow). What is gated is that --release
                                #   ALONE still fires them, and that --turbo does NOT touch
                                #   assert. Both are what a plausible "optimisation" breaks.
                                #   Precedent for the regression: BUG-228 shipped Debug from
                                #   `--release` for four days under 19 green gates, because
                                #   NO gate passed the flag. A flag no gate passes is
                                #   unverified by construction — docs/testing_strategy.md
                                #   had already named --turbo "a genuinely under-tested path".
                                #   Classifies on a SENTINEL the program prints past the
                                #   check, never on exit code alone — a build failure also
                                #   exits non-zero, and scoring that as "the contract fired"
                                #   would make a broken compiler look like a working guard.
                                #   THE RUNTIME LEGS ALONE FAIL OPEN on --release, though:
                                #   non-zero + no sentinel scores `fired`, so a binary that
                                #   crashed for an unrelated reason would pass while
                                #   contracts were being stripped. That is why the mechanism
                                #   legs cover ALL FOUR combos at EMIT level rather than
                                #   just plain-vs-turbo — the claim carrying the most weight
                                #   (a plain --release build KEEPS its contracts) must not
                                #   rest on a panic.
                                #   COVERS BOTH COMPILERS. `--gui-backend=*` delegates to
                                #   zebra-bootstrap, so a GUI app built --release --turbo
                                #   takes a path the selfhost legs never touch. The
                                #   bootstrap DOES honour --turbo (verified); it takes
                                #   --emit-zig, not --output-dir, so those legs cost no
                                #   build. Asserting this for one of two compilers under the
                                #   title "the contract-stripping contract" would be the
                                #   same over-read that let BUG-228 sit under green gates.
                                #   Verified red against four realistic regressions
                                #   (--release stripping contracts, at runtime AND at emit;
                                #   --turbo stripping assert; the bootstrap ignoring
                                #   --turbo): each mutant failed exactly one leg.
                                #   A vacuous run is a FAILURE — it refuses to report unless
                                #   all 13 checks ran.
python tools/grammar_export.py --check  # THE GRAMMAR-DRIFT GATE (static, instant).
                                #   `grammar.txt` is now GENERATED from the Earley parser's
                                #   own rule table (src/ZebraGrammar.zig, 474 comptime rule
                                #   literals). It used to be hand-maintained BNF alongside
                                #   the table — two copies of one thing, one compiled and
                                #   one prose.
                                #   THE DRIFT WAS NOT COSMETIC. `fuzz/gramgen.py` derives
                                #   its 960 programs FROM grammar.txt, so the
                                #   parser-robustness gate was generating **9 constructs the
                                #   parser does not have** (ProDecl, PropDecl, StmtUsing,
                                #   AllAnyExpr, MemberBlockOpt…) and **never reaching 40 it
                                #   does** — LambdaExpr, CaptureBlock, ExceptField*,
                                #   GenericConstruct, DeclUnion. Lambdas and capture blocks
                                #   had never been fuzzed. That also gives its standing
                                #   caveat ("accept/reject divergences are expected") a much
                                #   less innocent explanation than overgeneration.
                                #   Regenerate with `--write`; the RULE TABLE is the
                                #   authority, never the document.
                                #   CANNOT say the grammar is CORRECT, only that the
                                #   document matches the table. Precedence encoded via
                                #   nonterminal layering, and anything the parser does
                                #   outside the Earley table (the tokenizer's indent/dedent
                                #   synthesis especially), are invisible to it.
                                #   Refuses to report if it extracts <400 rules or cannot
                                #   find the start rule — a regex that has stopped matching
                                #   would otherwise blame the DOCUMENT for the extractor's
                                #   failure. 0 = clean. QUICK tier.
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

python tools/lint_bug_numbers.py   # THE BUG-NUMBER COLLISION GATE (static, instant, QUICK).
                                #   Two agents work in this tree and both allocate a
                                #   number the same way — read BUGS.md, take the next.
                                #   Between one reading and committing, the other can file
                                #   twice. It happened TWICE on 2026-08-06: BUG-260 (two
                                #   bugs, untangled only by `git log -S` archaeology) and
                                #   BUG-269 (caught because a grep happened to print two
                                #   identical headings side by side).
                                #   NO EXISTING GATE COULD SEE IT. `doc_lint` D4 checks a
                                #   cited BUG-NNN RESOLVES — and a duplicate resolves TWICE,
                                #   so a collision leaves D4 *more* satisfied. The failure
                                #   is invisible exactly because the thing that would notice
                                #   is looking for presence.
                                #   SUB-LETTERED NUMBERS ARE NOT COLLISIONS: `BUG-009 (a)` /
                                #   `BUG-060a` are parts of one bug and key to distinct
                                #   slots. Baselined (3 known: 106, and a 49-line block
                                #   containing 249+250 duplicated VERBATIM in BUGS.md — an
                                #   editing accident left in place because BUGS.md is
                                #   doc-status: historical and not mine to edit).
                                #   SECOND LEG, NOT BASELINED: "Last bug number generated"
                                #   must be >= the highest heading. That line is what the
                                #   next person reads, so when it lags it is not a stale
                                #   fact — it is the NEXT collision already scheduled.
                                #   THIRD LEG: a RESOLVED entry must not linger in the
                                #   OPEN ledger. BUGS.md answers "what is left to work
                                #   on", so a finished entry still sitting there makes
                                #   that answer wrong — silently: a reader counts 53 open
                                #   bugs when 50 are open. Found 2026-08-07 with exactly
                                #   that (BUG-255/256/257, all three carrying FIXED plus a
                                #   date in their own headings). HEADING-ONLY on purpose:
                                #   bodies routinely say FIXED about OTHER bugs and every
                                #   good entry has a "Control when fixing" section, which
                                #   scored 30 of 53 — a noise ratio that gets a gate
                                #   ignored. A part-done bug is legitimate and says so with
                                #   `<!-- bug-open-ok: reason -->` (BUG-267 has one: usage
                                #   half fixed, mutation half open).
                                #   Refuses to report if <150 headings parse or if a planted
                                #   duplicate is not detected. Reconfigures stdout to UTF-8:
                                #   printing a heading containing an em-dash or a tick
                                #   raised UnicodeEncodeError on this cp1252 console and
                                #   took the whole gate down with a traceback — a gate that
                                #   CRASHES reports nothing, and the cause looks like the
                                #   ledger rather than the terminal. 0 NEW = clean.
python tools/lint_reserved_words.py # THE RESERVED-WORD GATE (static, instant, QUICK tier):
                                #   a keyword must either be USED or be JUSTIFIED. A word in
                                #   the keyword table costs every user of the language the
                                #   right to name a variable, parameter, field or column with
                                #   it — a cost that is invisible until someone hits it, and
                                #   then looks like a compiler bug rather than a decision
                                #   nobody revisited.
                                #   RECEIPT: `aspect` was reserved for aspect-oriented
                                #   programming that was NEVER BUILT — the bootstrap parsed it
                                #   and then panicked "not yet implemented", and the selfhost
                                #   had no parse path at all (`AspectDecl` never appears under
                                #   selfhost/ in the whole git history). So it blocked a real
                                #   DB column name, forced a keyword-rename shield in another
                                #   project, and created a permanent bootstrap-accepts /
                                #   selfhost-rejects divergence for `gramgen` to trip over.
                                #   Freed under NEXT_STEPS U4, 2026-08-09.
                                #   TWO CLASSES, different fixes. R1 UNREACHABLE: no rule in
                                #   EITHER compiler mentions the token, so reserving it is
                                #   pure cost. R2 PARSED-THEN-REFUSED: a rule accepts it and
                                #   AstBuilder answers "not yet implemented" — the feature
                                #   does not exist, the reservation does.
                                #   BOTH COMPILERS, and the first draft got this wrong: it
                                #   scanned only the bootstrap's Earley table, but the
                                #   selfhost parses by hand and consumes TokenKind directly,
                                #   so a word invisible to the table can be live there. That
                                #   is rule 1c — an instrument's assumptions are quantified
                                #   over the subjects it had when written.
                                #   HOW IT NEARLY LIED: the first version asked "does this
                                #   token name appear downstream?" and classified `raise` and
                                #   `throws` as unused. Downstream code acts on the PNode, not
                                #   the token, so absence there means nothing. R2 now asks the
                                #   COMPILER's own answer instead of the author's inference.
                                #   Runs a 5-check selftest on synthetic input before every
                                #   scan and REFUSES if the classifier stops discriminating;
                                #   verified red by removing one baseline entry.
                                #   Baselined at 1 — `implies`, kept on LANGUAGE grounds
                                #   (Sean's call: it is intended as a contract operator,
                                #   `a implies b`). SEVEN words have now left this list:
                                #   weaves, expect, lock, from and trace under U4a
                                #   2026-08-09, then `error` and `try` on 2026-08-13.
                                #   The list shrinking is the gate working, and the last
                                #   two are the shape to remember — they were blocked on
                                #   the EMIT, not the parse, so what freed them was
                                #   BUG-280 plus the isZigKeyword oracle, and neither is
                                #   visible to this gate. A word can be R1 here and still
                                #   be unsafe to free. Shrink it; do not grow it.
                                #   0 NEW = clean.
bash tools/keyword_ident_check.sh  # THE ESCAPED-IDENTIFIER GATE (BUG-280, QUICK tier) —
                                #   the MIRROR IMAGE of reserved-words. That gate asks
                                #   whether a word Zebra reserves earns its keep; this
                                #   one asks what happens to a word Zebra does NOT
                                #   reserve but ZIG does: align, volatile, opaque,
                                #   packed, noalias, anyframe. A user may legally name a
                                #   field with one TODAY, so codegen must escape it as
                                #   @"name" on the way out.
                                #   `emitName` always did. The FIELD paths never called
                                #   it, so `var align: int` in a class emitted
                                #   `align: i64 = 0,` and the generated Zig did not
                                #   parse — while the same word as a LOCAL worked all
                                #   along, which is why it went unnoticed.
                                #   THE SITE MAP IS DERIVED, and that is the whole
                                #   point. Reading the source found FOUR sites. Emitting
                                #   a probe that uses a keyword field in every position
                                #   and grepping the output found NINE; a tenth surfaced
                                #   during the fix. So the probe is now the permanent
                                #   instrument rather than a one-off.
                                #   THE STATIC ALTERNATIVE WAS TRIED AND IT DOES NOT
                                #   WORK — measured 2026-08-15, recorded so nobody
                                #   re-proposes it. The obvious cheap lint is "an
                                #   expression passed through `emitName` somewhere must
                                #   not reach output BARE elsewhere", oracle derived from
                                #   the escaping call sites themselves. Run against the
                                #   commit BEFORE BUG-281 E it finds NOTHING: `mname` was
                                #   passed through emitName ZERO times then, so it was
                                #   never in the guarded set. The lint can only enforce
                                #   consistency with a decision ALREADY made; the bugs
                                #   that actually occur are the decision never made — a
                                #   name escaped NOWHERE that should be escaped
                                #   everywhere. It is also noisy in the other direction:
                                #   on today's tree it flags 10 sites, 0 real, because
                                #   `.` + mname for an Atomic/ThreadPool pass-through and
                                #   `um_cname + "." + mname` as a LOOKUP KEY are both
                                #   correctly bare. Structural, not tunable. The probe
                                #   works precisely because it reads the OUTPUT and so
                                #   needs no advance knowledge of which variable carries
                                #   the name.
                                #   HOW IT DECIDES: strips string-literal CONTENTS, then
                                #   flags any keyword left as a whole word. That single
                                #   rule makes `@"align"` pass AND the reflection string
                                #   `&.{"align"}` pass — the latter is DATA, must stay
                                #   bare, and escaping it would silently corrupt field
                                #   lookup. It needs no allow-list, deliberately: an
                                #   allow-list here would be the same hand-maintained
                                #   oracle that caused the bug.
                                #   AS OF 2026-08-13 IT ALSO COVERS THE METHOD NAME
                                #   (BUG-281 E) — declaration, static declaration, a bare
                                #   sibling call inside a method, and BOTH member-call
                                #   dispatches. Reading found 1 of those 5; the gate named
                                #   the other 4, including the one that matters most: the
                                #   EARLY user-method dispatch, which fires whenever
                                #   inference knows the receiver's class (the common
                                #   case), so fixing the default path alone left every
                                #   resolved call bare.
                                #   AND THE TYPE NAME
                                #   (BUG-281 B), and it covers it DIFFERENTLY: that
                                #   family was fixed by PREFIXING, not escaping, so a
                                #   Zebra type emits as `_zbr_ty_opaque` and the bare
                                #   word never reaches the output at all. `_zbr_ty_opaque`
                                #   is not a whole-word match for `opaque`, so the check
                                #   stays live rather than vacuous — verified by watching
                                #   it go RED on the new shapes before the fix (9 hits
                                #   across both words) and green after.
                                #   SELFHOST ONLY, and that is now structural: the
                                #   fixture no longer builds under the bootstrap, so
                                #   passing it `zebra-bootstrap.exe` is a permanent FAIL
                                #   rather than a check. gates.sh has never had a
                                #   bootstrap leg here; do not add one.
                                #   TWO BLIND SPOTS, both live. (1) THE FIXTURE IS THE
                                #   COVERAGE — on 2026-08-11 it reported the bootstrap
                                #   CLEAN while three further emit families were broken
                                #   in it (BUG-281). Extend the fixture with every fix.
                                #   Receipt that this is not a formality: B's landing
                                #   needed NINE emit sites the fixture (and the derived
                                #   probe) never reached, and every one came from a
                                #   different witness — the ROUND-TRIP (cross-module) and
                                #   selfhost_smoke. A keyword gate over a single-module
                                #   fixture cannot see either.
                                #   (2) It cannot see OVER-escaping, the dangerous
                                #   direction, since stripping strings is exactly what
                                #   lets the reflection strings pass. Diff a pre/post
                                #   emit for that: every changed line must be a keyword
                                #   acquiring @"…" and nothing else. Done for B against
                                #   tools/fixtures/bug281_typename_sites_probe.zbr:
                                #   32 changed lines, every one an identifier gaining the
                                #   prefix; the reflection field-type strings, the _ttag_
                                #   and _reflect_ symbols and the @derive toString format
                                #   literal all correctly UNCHANGED.
                                #   Carries a positive control (the names must appear in
                                #   the emit at all) and a negative one, and REFUSES
                                #   rather than reporting clean when either fails. A
                                #   clean escape with a failed BUILD is reported as a
                                #   separate defect, not as a pass. 0 = clean.
python tools/lint_zig_keywords.py  # THE KEYWORD-ORACLE GATE (BUG-280 defect 2, QUICK
                                #   tier) — the oracle BEHIND keyword-ident. `isZigKeyword`
                                #   decides which words get escaped, it exists TWICE
                                #   (src/CodeGen.zig, selfhost/CgHelpers.zbr), and both
                                #   copies were hand-written lists. A hand-maintained
                                #   oracle guarding against a bug caused by a
                                #   hand-maintained oracle.
                                #   THE RECEIPT IS NOT THE OBVIOUS DIRECTION. The lists
                                #   were missing 12 of Zig 0.16's 46 keywords — and every
                                #   one of the 12 is ALSO a Zebra keyword, so no user
                                #   could reach any of them and nothing was broken. What
                                #   proves the class is the other direction: both copies
                                #   still carry `async`, `await` and `usingnamespace`,
                                #   which Zig NO LONGER HAS. The list already drifted
                                #   across a version bump, silently.
                                #   MISSING fails; EXTRA is reported and NOT gated —
                                #   escaping a non-keyword is identity in Zig, so a stale
                                #   entry is inert, and deleting one would break a build
                                #   against an older Zig. Report, do not churn.
                                #   ORACLE = zig's own std/zig/tokenizer.zig keyword
                                #   table, located via `zig env`. Same philosophy as
                                #   grammar_export --check: the compiled table is the
                                #   authority, never a second copy. THE ONLY GATE THAT
                                #   READS THE ZIG INSTALLATION rather than the repo, so it
                                #   prints the version it judged against — the answer is
                                #   only true for one toolchain.
                                #   Refuses (exit 2) if it extracts <40 keywords, if
                                #   `zig env` cannot be parsed (it is ZON, not JSON), or
                                #   if either isZigKeyword cannot be found — a regex that
                                #   has stopped matching must blame ITSELF, not the
                                #   compiler. Runs both-direction controls on synthetic
                                #   input first (a planted gap must fire, a complete list
                                #   must not) and verified red by deleting one real entry.
                                #   NOT checked: isZigPrimitiveName, zigSafeName's other
                                #   half — already PATTERN-based for the open-ended part
                                #   (`i37`, `u3`, any iN/uN; verified by emitting a class
                                #   with an `i37` field and getting @"i37"), so it does not
                                #   have this failure mode. 0 = clean.
python tools/lint_diag_columns.py  # THE DIAGNOSTIC-POSITION GATE (QUICK tier, ~2s).
                                #   A front-end diagnostic that cannot say WHERE is
                                #   delivered half-finished — and `file:8:0` is NOT
                                #   "position unknown", it is a plausible-looking
                                #   coordinate that is simply wrong. It defeats caret
                                #   rendering (which reads line/col to quote the source)
                                #   and sends an editor to the wrong place. UNGIT
                                #   "nothing fabricated", in the one place the
                                #   move-checking-inward programme keeps landing.
                                #   RECEIPT: THREE bugs of exactly this shape were fixed
                                #   in two days — BUG-284 (zig literals had no span at
                                #   all), BUG-249 (this/nil/result were payload-less),
                                #   BUG-121 (checkExpr used the STATEMENT keyword's
                                #   position). Every one was found by a PERSON reading
                                #   output. A golden-output gate does not assert
                                #   positions and a compile gate cannot see them, so
                                #   nothing here could have caught any of them.
                                #   CANDIDATE SET IS DERIVED from the smoke suite's own
                                #   `smoke_tc_fail`/`smoke_run_fail` registrations —
                                #   where the suite already declares "this must be
                                #   refused". A hand-listed set would rot and silently
                                #   shrink coverage.
                                #   BASELINED at 18 (49 candidates, 45 producing
                                #   diagnostics). Each entry is a real diagnostic a user
                                #   can hit that cannot say where — branch
                                #   exhaustiveness, bare return, destructuring, interface
                                #   mismatches. Shrink it; do not grow it.
                                #   PRINTS ITS DENOMINATOR ON EVERY PATH, pass or fail:
                                #   a gate that hides how much it examined when it fails
                                #   leaves you unable to tell "18 of 49" from "18 of 18",
                                #   and the second means the scan collapsed.
                                #   Refuses if <30 candidates extract (the registration
                                #   regex stopped matching) or if NOT ONE must-fail
                                #   fixture produced a parseable diagnostic — that is a
                                #   harness failure, not a clean result. Runs a
                                #   4-check both-directions selftest first, and was
                                #   verified red by removing one baseline entry.
                                #   CANNOT SEE whether a non-zero column is the RIGHT
                                #   column: it asserts a position was computed, not that
                                #   it points at the token. 0 NEW = clean.
python tools/lint_expr_walkers.py  # THE WALKER-DRIFT GATE (static, instant, QUICK tier).
                                #   A function that searches the Expr tree for a name is
                                #   correct only if it descends into every variant that
                                #   CONTAINS expressions. Miss one and it silently answers
                                #   "not used" for an entire construct — and because these
                                #   walkers drive `_ = x;` discards, the symptom lands in
                                #   the emitted Zig as a "pointless discard" against code
                                #   the user wrote correctly.
                                #   THIS CLASS WAS DECLARED RETIRED ONCE, BY HAND.
                                #   `mightUseNameInExpr` carries the note "BUG-169
                                #   retirement: model every remaining ident-bearing expr …
                                #   Retires the walker-drift class (F2/F6/F11)". It came
                                #   back twice anyway: BUG-267 (`zig_lit`) and BUG-260
                                #   (`list_lit`/`array_lit`) — and note what those share.
                                #   The variant was not FORGOTTEN, it was MISCLASSIFIED:
                                #   someone wrote down that it holds no expressions.
                                #   Modelling everything by hand does not prevent that; a
                                #   machine comparison against the AST does.
                                #   THE ORACLE IS Ast.zbr ITSELF — each variant's payload
                                #   struct and field types are declared, so "does this hold
                                #   expressions" is DERIVED, through one level of
                                #   indirection (`List(DictPair)` -> `DictPair.key: Expr`).
                                #   35 variants, 27 ident-bearing, 8 leaf.
                                #   OPT-IN (`# expr-walker: exhaustive`), because 53
                                #   functions branch over Expr and most legitimately care
                                #   about two or three forms — `getVariantKey` wants
                                #   `member` and nothing else. Blanket checking would be
                                #   ~90% noise, and a gate at that ratio gets suppressed
                                #   wholesale (the doc_example_check lesson). The count of
                                #   NON-opted-in walkers prints every run so the gap stays
                                #   visible. Waive a variant with `# expr-walker-ok: <v>
                                #   <reason>`; a reason is required.
                                #   TWO VARIANTS ARE HARDCODED because nothing can derive
                                #   them: `zig_lit` (identifiers live in a STRING — exactly
                                #   how BUG-267 hid from structural reasoning) and `ident`
                                #   (structurally a leaf, yet a usage walker that skips it
                                #   is broken by definition).
                                #   CANNOT SEE: whether a handled variant is handled
                                #   CORRECTLY, and names inside a zig"…" string. Refuses to
                                #   report if <25 variants extract, if its list_lit/int_lit
                                #   controls flip, or if NO walker opted in — a gate with
                                #   nothing to check must not print clean. 0 = clean.
bash tools/ffi_lib_check.sh        # THE PREBUILT-LIBRARY GATE (BUG-266, QUICK tier):
                                #   `use foo` resolving to a prebuilt `foo.lib`/`.a` must
                                #   LINK and the foreign call must return the right value.
                                #   This is the shape a REAL third-party dependency takes —
                                #   a binary you did not build and cannot compile from
                                #   source. BUG-261 covered the `.c` SOURCE case; this is
                                #   the other half, and until 2026-08-06 there was NO route
                                #   to it at all: `BuildTarget.linkLib` takes another Zebra
                                #   build target rather than a path, and the CLI has no
                                #   passthrough, so every foreign call had to be linked by
                                #   hand with `zig build-exe`.
                                #   NO COMPILE-ONLY GATE CAN WITNESS THIS. compile_check and
                                #   full_sweep build with `-fno-emit-bin`, so they never
                                #   link, and an `extern fn` resolving to NO SYMBOL AT ALL
                                #   passes them cleanly. Only a gate that runs the binary
                                #   can tell the difference.
                                #   BUILDS ITS OWN LIBRARY at check time instead of
                                #   committing a binary to the corpus — which also means the
                                #   artifact under test cannot be a stale one passing for
                                #   the wrong reason. The expected value appears NOWHERE in
                                #   the Zebra source, so the program cannot print it without
                                #   really calling in.
                                #   CARRIES A NEGATIVE CONTROL: leg 2 removes the library
                                #   and REQUIRES the value to stop appearing, so leg 1
                                #   cannot pass for an unrelated reason. Classifies on
                                #   PRINTED OUTPUT, never exit code (BUG-259). Refuses to
                                #   report a pass if the library cannot be built.
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
                                #   --update-baseline takes THREE samples and, if they
                                #   disagree, a three-sample CONFIRMATION ROUND — only a
                                #   REPRODUCED difference is excluded, with its reason
                                #   recorded. A hand-written skip list rots and silently
                                #   shrinks coverage; what the confirmation round fixes is
                                #   that a DERIVED list could silently shrink too, which
                                #   is the same failure in better clothes.
                                #   THE ASYMMETRY IS THE ARGUMENT. A wrongly-EXCLUDED file
                                #   leaves behaviour coverage permanently and reports
                                #   nothing; a wrongly-INCLUDED flaky file fails the gate
                                #   loudly and names itself. Prefer the recoverable error.
                                #   RECEIPT (2026-08-15): a re-baseline dropped `log_test`
                                #   and `refinement_type_test` as nondeterministic. Both
                                #   are deterministic — 10x and 8x byte-identical on the
                                #   built executables, 5x through this harness's own
                                #   --show path. The disagreement appears only inside a
                                #   full 354-file sweep and IS STILL UNEXPLAINED; the
                                #   obvious pipe-capture theory was tested and FAILED
                                #   (12/12 identical through both `$(...)` and a file
                                #   redirect). Recorded as an open question rather than
                                #   given a tidy cause it has not earned.
                                #   TRANSIENTS ARE PRINTED EVERY RUN, including zero, and
                                #   named when non-zero: a rate that starts climbing is
                                #   the early warning that something in the environment
                                #   changed, and it is only legible against a number that
                                #   was always there.
                                #   Both paths are control-tested: a genuinely
                                #   nondeterministic file (log_json_test, which prints a
                                #   clock) must still be excluded, and a forced single
                                #   disagreement must be KEPT and counted.
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
| **a foreign symbol actually LINKS and returns** | **`ffi_lib_check`** (builds its own library + negative control) | 1 prebuilt lib |
| **an Expr walker descends into every variant that holds exprs** | **`lint_expr_walkers`** (oracle = `Ast.zbr`) | 2 of 53 walkers, opt-in |
| parser survives hostile input | `fuzz/gramgen.py` | 960 derived programs |
| static hazard classes | `lint_interp_escape`, `lint_fallthrough` | all `.zbr` |
| generated docs match the compiler | `str_ownership_extract --check` | 28 operations |
| **a bug number resolves to exactly one bug** | `lint_bug_numbers` (+ allocator line) | 199 slots, 2 ledgers |
| **the gates can still fail** | `gate_selfcheck.sh` | 7 gates |
| **our own tools are not lying** | `hazard_lint` (+ its controls) | 73 scripts | <!-- doc-gen: 73 = ls tools/*.sh tools/*.py fuzz/*.py *.py 2>/dev/null | wc -l | tr -d ' ' -->
| docs' checkable claims still resolve | `doc_lint` | 50 tracked documents <!-- doc-gen: 50 = git ls-files | grep -cE '^[^/]+\.md$|^docs/[^/]+\.md$' --> |
| **a reserved word is used, or justified** | `reserved-words` (both compilers) | 81 keywords, 1 baselined |
| **a diagnostic can say WHERE** | `diag-columns` (derived candidates, baselined) | 49 must-fail fixtures, 18 baselined |
| **a word ZIG reserves and Zebra does not survives codegen** | `keyword-ident` (derived site map, no allow-list) | 6 keywords × the positions one fixture reaches |
| **…and the list of such words is not STALE** | `zig-keywords` (oracle = zig's own tokenizer table) | 46 keywords × both compilers |
| **the docs' EXAMPLES actually parse** | `doc_example_check` | 161 blocks in 25 live docs | <!-- doc-gen: 50 = git ls-files | grep -cE '^[^/]+\.md$|^docs/[^/]+\.md$' -->

The last row is the one that keeps the rest honest; see its header for why.

## What the gates do NOT cover — and when it was last checked

`gates.sh` deliberately excludes three things so that "gates green" keeps a precise
meaning. That precision is only worth anything if the excluded set is actually run
sometimes, so record the date here when you do.

**BOTH HEAVY BASELINES RE-LOCKED 2026-08-16, and this closes a gap this file had been
flagging against itself.** `full_sweep` **337 → 374** (+37 insertions, **zero deletions** —
purely additive, so nothing dropped out of the pass set and it cannot be hiding a
regression behind a re-record). `output_sweep` **322 → 356**. Both captured at JOBS=1 on an
idle machine after `doctor` reported the tree trustworthy, in the documented order
(full_sweep FIRST — output_sweep derives its candidates from it).

The 32-accumulated-passes note above is now DISCHARGED: those files could not turn the
gate red however badly they broke, and they can now. QUICK was **22/22 in one invocation**
(smoke 335/335, round-trip byte-identical, `diag-columns` 18 known / 0 NEW) and
`output_sweep --gate` re-run afterwards is **356 files behaviour identical**.

**A method note that cost a re-measurement.** The first `output_sweep --gate` was taken on
a `zebra.exe` built from a source tree carrying a deliberately-injected dead `const` — the
residue of a break-the-gate-on-purpose test whose FIRST attempt was vacuous (Zig does not
analyse unused top-level declarations, so the build passed and rebuilt the binary; the same
lazy-analysis trap that made the BUG-269 probe lie). `doctor` caught the binary↔source
mismatch. The dead const cannot affect codegen, but that is reasoning rather than
measurement, so the gate was re-run after a clean rebuild — same result. **When you break
something on purpose, check that the break actually took, and check what the failed attempt
REBUILT.**

**BUG-269 landed 2026-08-15** — `str` in an `extern` signature is REFUSED at the
declaration instead of emitting `[]const u8` and letting `zig` reject it as an illegal
C-ABI return type. Same family, same place and same shape as BUG-270's `int` check.
FULL tier **29/29 in one invocation**: smoke **335/335**, `compile_check` **260/0/2** in
both runtime shapes, `output_sweep` 322 identical, `full_sweep` 0 vs 337, `divergence`
**0 selfhost gaps**.

**Two method notes from it.** First, the probe lied: declaring `extern def f(): str` and
compiling reported that `zig` ACCEPTED it — for the broken form AND the working one —
because `zig` analyses an `extern fn` LAZILY and a declaration that is never CALLED never
reaches the calling-convention check. Adding a call reproduced the ticket verbatim.
Second, the fixture is a PAIR on purpose: the refusal names `^byte` as the fix, and a
second fixture pins that `^byte` really lowers to `*u8` and is accepted where the slice is
not. **A refusal whose suggested fix does not itself work is advice pointing nowhere, and
only a positive fixture catches that.**

**And BUG-270 was found already FIXED, nine days stale in the open ledger** (`e8c68e7`,
two passing fixtures). Second instance in two days after BUG-283, same cause: the
resolved-entry lint is heading-only, so an entry whose heading never gains a FIXED marker
is invisible to it. The cost is now concrete rather than theoretical — I picked BUG-270
to work on and discovered the compiler already refused the case.

**BUG-249 landed 2026-08-14** — `this`, `nil` and `result` carry real source positions, so
a diagnostic anchored on one no longer reports `0:0`. The selfhost now reports
`bug108_this_outside_class_test.zbr:6:13`, byte-identical to what the BOOTSTRAP reports
for that file, and the `smoke_tc_fail` expectation was tightened from the message alone to
the full coordinate. Verified at JOBS=1 because RAM was down to 3.5 GB: smoke **333/333**,
`compile_check` **259/0/2** in both runtime shapes, `output_sweep` 322 identical,
`full_sweep` 0 vs 337, `examples_sweep` 0 vs 14.

**`divergence` CONFIRMED CLEAN 2026-08-14, after a detour worth recording.** Final result:
**0 selfhost gaps**, 490/490 files scored, bootstrap gaps steady at **48** — unchanged from
before BUG-249, which is what a front-end-only change that adds no corpus file should do.

Getting there took four failed attempts and one wrong diagnosis. It hit the tier's 2700 s
ceiling at JOBS=1, and I then read `ps -W | grep -c zebra-language` returning 0 as "the
background runs are dying" — **that probe returns 0 whether or not a worker is running**,
verified afterwards with a positive control. One "dead" run had in fact been alive for
three hours and died only because I EDITED `divergence_check.sh` WHILE IT WAS EXECUTING
(bash re-reads a script as it runs). The 0-byte logs that made runs look dead have a duller
cause: divergence buffers its whole report to the end, so a healthy long run and a corpse
look identical from outside.

The eventual clean run was a single uninterrupted background pass. **Background runs were
never the problem.** Two lessons, both already rules here and both applied too late: prove
an instrument can SEE before reading its zero as an answer, and never edit a running
script.

`divergence_check.sh` gained `--results` / `--max` / `--classify` out of that detour, which
make the heaviest gate resumable — worth having on the 2026-08-11 receipt alone (two
harness kills, every heavy witness lost), independent of the wrong reason I first gave.

**BUG-282 / BUG-284 / BUG-285 / BUG-286 / BUG-287 landed 2026-08-14** — five bugs, four
commits. FULL tier at JOBS=2 for the last of them: every gate PASS except `output_sweep`,
which is the story below; re-run afterwards with its fix, **322 files behaviour
identical**. `compile_check` **259/0/2** in both runtime shapes, `full_sweep` 0 vs 337,
`divergence` **0 selfhost gaps**.

`divergence` bootstrap gaps **46 → 48**, both accounted for by name rather than waved
through: `bug286_namespace_ctor_test` (a keyword-named namespace, fixed selfhost-only) and
`bug287_sibling_method_shadow_test` (the bootstrap still resolves a bare sibling call to
the same-named class — the same `genCall` ordering, not fixed there). `bug284`'s fixture
is a negative test that fails in BOTH, so it lands as agree-fail rather than a gap.

**BUG-284 / BUG-285 / BUG-287 landed 2026-08-14.** FULL tier at `JOBS=3`: **28/29**, the
one failure being `output_sweep`.

It reported `bug120_sys_readline_test` as having "produced NO record — they stopped being
measured", which the gate correctly calls *worse than failing*.

**FIRST DIAGNOSIS WAS WRONG, AND THE CORRECTION IS THE USEFUL PART.** It looked like
load: the program ran correctly on its own, `--show --only` produced the right record,
`--gate --only` failed again *while divergence was still running*, and idle passed. That
is a clean-looking contention story and this file briefly said "do not run at JOBS=3".
**Then it failed again at JOBS=2**, on a tier where an earlier JOBS=2 run had passed —
so the pattern was intermittent, not tiered, and the tidy explanation was wrong.

**THE REAL CAUSE: the sweep inherited the RUNNER's stdin.** A fixture that READS stdin
therefore behaved differently depending on what the harness handed it — closed gives an
instant EOF, an open handle blocks until the timeout. `run_one` now redirects
`</dev/null`, so a stdin-reading program is deterministic. Note the retry could never
have helped: **retrying a blocking read blocks twice**, and the retry exists for slow
programs, which is a different failure. The fix had to be at the input, not the
observation.

The general lesson, and it is one this repo has written down in other words: a first
explanation that fits every observation so far is still a hypothesis. This one predicted
"JOBS=2 is safe" and that prediction failed on the next run. **A diagnosis that has not
made a prediction has not been tested.**

**U4a's TAIL CLOSED 2026-08-13 — `error` and `try` are ordinary identifiers.** FULL tier
**29/29 in one invocation** again: smoke, round-trip byte-identical, `compile_check`
**257/0/2** in both runtime shapes (the +1 is the new fixture), `output_sweep` 322
identical, `full_sweep` 0 vs 337, `divergence` 0 selfhost gaps. `reserved-words` is now
**81 keywords, 1 baselined** — down from 83/3; only `implies` remains, kept on language
grounds.

**Neither word can be added to `keyword_ident_check`'s word list, and that is a property
of the gate rather than an oversight.** Its rule is "a keyword appearing BARE outside a
string literal is an unescaped identifier", which is sound for `align`/`opaque`/`packed`
because codegen never emits those itself. `error` and `try` are words the compiler emits
legitimately as ZIG keywords — `return error.ZebraError;`, `try f()` — and one generated
compiler module carries **56 bare `try` and 17 bare `error`**. Adding them would fire on
nearly every program that can raise. They are covered instead by
`test/bug280_freed_words_test.zbr`, a `smoke_run` fixture that names things with both
words in eleven positions and asserts the printed values. **The general rule: a word
codegen itself emits cannot be checked by absence.**

**FULL tier 2026-08-13: 29/29 PASS — and for the first time, IN ONE INVOCATION.** The
two previous sweeps were assembled from separate runs, which this file records as weaker
evidence because nothing proves the tree was the same throughout. This one was
`JOBS=2 bash tools/gates.sh --full`, start to finish, on the tree that was committed.

| gate | result |
|---|---|
| QUICK (21) | all PASS — smoke **329/329**, round-trip byte-identical, `zig-keywords` 46/46 |
| `compile_check` | 256 passed, 0 FAILED, 2 skipped |
| `compile_check-inline` | 256 / 0 — identical to the default shape |
| `output_sweep` | 322 files, behaviour identical |
| `full_sweep` | 0 regressions vs 337; `examples_sweep` 0 vs 14 |
| `divergence` | **0 selfhost gaps**; bootstrap gaps steady at **46** |
| `release-mode` / `contract-mode` | clean / 13/13 |

Bootstrap gaps did NOT move for E, and that is worth reading rather than skipping: the
only file carrying an E shape is `bug280_keyword_idents`, which was *already* a bootstrap
gap from B. A family landing selfhost-only adds a gap the first time and none after.

**BUG-281 E landed 2026-08-13** — a keyword-named METHOD is now escaped in the selfhost,
closing the sixth of seven families. Only G remains and it is bootstrap-only (the
selfhost is immune for free via `_zbr_fn_`), so it retires with the bootstrap.
`keyword-ident` watched red on the new shapes then green; the fixture RUNS and prints the
right values (11 / 42 / 111), which is the half that matters — an escaping bug that
swapped two methods would still compile. The regen control: a full rebuild moved
**only `CodeGen.zig`**, so no non-keyword method name anywhere in the compiler's own
25k lines was touched.

**Both B and E are SELFHOST-ONLY, deliberately.** E's bootstrap half is cheap and was
still declined: the bootstrap is the REGEN AUTHORITY, and
`test/bug280_keyword_idents.zbr` can no longer gate it (the file contains a keyword-named
class since B). An ungated change to the regen authority, for a retiring compiler, in a
family already half-broken there, is a poor trade. See BUG-281 for what it costs.

**BUG-281 B landed 2026-08-13** — a Zebra type now emits as `_zbr_ty_<name>` in the
selfhost. QUICK **20/20 in one invocation** (smoke **329/329**, round-trip byte-identical,
`keyword-ident` 6/6, registration 465), with one caveat recorded below. Heavy witnesses,
all run against the final tree in one scripted sequence: `compile_check` **256/0/2**,
`full_sweep` 0 regressions vs 337, `examples_sweep` 0 vs 14, `output_sweep` **322
identical**, `divergence` **0 selfhost gaps**. `compile_check --no-runtime-module` (the
INLINE runtime shape, which nothing else watches) is **256/0/2 — identical to the
default**, which matters here because the change touched ~40 emit sites.

`divergence` bootstrap gaps **45 → 46**. The +1 is `bug280_keyword_idents` and nothing
else — the fixture gained a keyword-named class and struct, which the bootstrap cannot
emit because B was landed **selfhost-only** (Sean's call; the bootstrap is being retired
and the standing rule only requires it to COMPILE the selfhost source, which it does since
no `.zbr` class was renamed). Selfhost-leads, informational, expected.

**The QUICK caveat, and it is an instrument note rather than a result.** `check-mode`
failed its TIMING leg at `-c 4723ms vs --check-full 7773ms`. Re-run alone on the same
binary minutes later: **59ms vs 2195ms, "fast path intact"**. The gate was measuring
machine contention — the whole gate took 48s in the tier run and 5s alone. Every other
leg of it passed both times. Treat a timing-only failure here as a load reading until it
reproduces on a quiet machine; the deterministic legs are the ones that mean something.

**A coverage fact worth knowing before trusting that `output_sweep` line.** It reported
322 files **identical** even though `test/bug280_keyword_idents.zbr` gained four `print`
statements — which looks wrong and is not. That file is in **neither** heavy baseline
(`full_sweep_baseline.txt`'s 337, `output_baseline.txt`'s 322), so no re-baseline was
needed and none was done. It is one of the ~32 accumulated new passes this file already
flags as unlocked-in. Its real coverage is `smoke_run` (runs it, greps `bug280: OK`) plus
`keyword_ident_check`, which emits it, **builds** it, and fails on either. That is
adequate — but it means the heavy sweeps say nothing about this fixture, and a future
session reading "322 identical" should not infer they do.

**BUG-283 landed 2026-08-12** (`zig"${Type}"`): QUICK **20/20** in one invocation —
smoke **329/329**, round-trip byte-identical, registration 465. Heavy witnesses run
individually: `output_sweep` 322 identical, `compile_check` 256/0, `full_sweep` 0
regressions vs 337, `divergence` **0 selfhost gaps**.

`divergence` bootstrap gaps **44 → 45**, and the +1 is accounted for rather than waved
through: the new `test/bug283_zig_lit_typeref_test.zbr` uses a feature the bootstrap does
not have, verified directly — `zebra-bootstrap --emit-zig` passes `${...}` through
verbatim (4 occurrences). The three MIGRATED literals added none, because
`features`/`greet`/`with_test` were already gaps. Selfhost-leads, informational, expected.

**A method note from this landing: do not edit docs while a gate tier is running.** The
QUICK run above reported `doc-lint` clean, and re-running it against the final tree
reported **1** — the two new corpus files moved the tracked count 463 → 465 and this
file's pinned counter went stale *after* the gate had read it. The gate was not wrong; it
measured a tree that no longer existed. Re-run the cheap static gates against the state
you actually commit.

**Swept 2026-08-12 after BUG-281 closed four families in BOTH compilers** — all
28 green, again assembled rather than observed in one invocation. QUICK 20/20 in a single
run (smoke 327/327, round-trip byte-identical); `output_sweep` 322 identical; `full_sweep`
0 regressions vs 337; `examples_sweep` 0 vs 14; `divergence` **0 selfhost gaps** with
bootstrap gaps steady at 44; `compile_check` 255/0 in both runtime shapes;
`contract-mode` 13/13; `release-mode` clean.

**`compile_check --bootstrap` is 219 passed / 19 FAILED / 20 skipped (2026-08-13), and
that is its NORMAL state — recorded here because it never has been.** The tool is manual,
so its number has no baseline anywhere, and a future session seeing 19 red has nothing to
compare against. The 19 break down as: **16 known bootstrap gaps** (the same files
`divergence` lists as *selfhost leads* — the bootstrap genuinely cannot compile them),
and **3 cross-module tests** (`crossmod_modvar_test`, `bug168_crossmod_prim_return_test`,
`bug235_exposing_test`) that fail with `unable to load '<dep>.zig': FileNotFound` because
`--emit-zig` writes ONE file and never emits the dependency. That third group is
`DEPMISS`, not breakage — the same distinction `examples_sweep` draws, and a gate that
libels a working file is one people learn to disbelieve. **If this number moves, check
which group moved before assuming a regression.**

Movement since it was first recorded (220/17/20 on 2026-08-11), accounted for in full
rather than re-recorded — the arithmetic is the check:

| | | |
|---|---|---|
| `bug283_zig_lit_typeref_test` | new corpus file, bootstrap has no `${...}` | 17 → 18, total 257 → 258 |
| `bug280_keyword_idents` | gained a keyword-named class; BUG-281 B is selfhost-only | 18 → 19, and **220 → 219** — it moved OUT of the pass set |

Both are selfhost-leads and both are in `divergence`'s bootstrap-gap list, which is the
cross-check: 46 there, 16 here, and the difference is `examples/` plus files this tool
skips. A move that does NOT reconcile against that list is the one to worry about.

**FULL tier swept 2026-08-11 — 28/28 PASS, but ASSEMBLED, not observed in one run.**
`gates.sh --full` was killed twice by the harness before reaching the heavy witnesses
(once at gate 23, once during `smoke`) with no contention to explain it — no processes
from this tree, 6 GB free, 0% CPU. So the 21 QUICK-plus-`release-mode` lines come from
the first partial run and the remaining 7 were each run individually. Every gate was
seen green; **no single invocation was**. Recorded that way deliberately: a tier result
stitched from separate runs is weaker evidence than one clean pass, because nothing
proves the tree was in the same state throughout.

| gate | result |
|---|---|
| `output_sweep --gate` | 322 files, behaviour identical to baseline (15 nondeterministic) |
| `compile_check` | 255 passed, 0 FAILED, 2 skipped |
| `compile_check-inline` | 255 passed, 0 FAILED — identical to the default shape |
| `full_sweep --gate` | 0 regressions vs baseline (337) |
| `examples_sweep` | 0 regressions vs baseline (14) |
| `divergence --gate` | **0 selfhost gaps**; 44 bootstrap gaps (informational) |
| `contract-mode` | 13/13 |
| QUICK (separate run, one invocation) | **20/20** — smoke 327/327, round-trip byte-identical |

Two numbers worth recording, neither of which this file previously carried.
`divergence` reports **44 bootstrap gaps** — cases where the selfhost LEADS. Still
informational, still "don't chase", but the last written-down figures are **14** in
`docs/divergence_audit.md` and 23 in a session memory, so it has roughly tripled
unremarked and no document here tracked it. And `full_sweep` reports
**369 PASS against a baseline of 337**, i.e. **32 accumulated new passes** nobody has
locked in. A baseline defines the pass set, so those 32 files cannot make the gate red
however broken they become. Re-baselining is a real coverage win and is **not** done —
`full_sweep --update-baseline` FIRST, then `output_sweep --update-baseline`.

**Previous sweep 2026-08-04, all clean** — run overnight with the machine otherwise idle,
so no gate measured contention as a failure. Sequential, not parallel.

| path | result |
|---|---|
| `bash tools/gates.sh --full` | **21/21 PASS** — smoke 293/293, compile_check 237/0, output_sweep 322 identical, full_sweep 0 regressions vs 337, examples_sweep 0 vs 14, divergence 0 selfhost gaps |
| `python fuzz/gramgen.py --gate` | PASS — 960 derived programs, 0 hangs, 0 crashes |
| `bash tools/node_addon_test.sh` | PASS |
| `bash tools/gui_scaffold_check.sh` | PASS — scaffold globals assigned, app got PAST the BUG-229 crash site and refused a non-tty cleanly (rc=3) |
| `zig build test` | **RED, and was already red — BUG-279.** Added to this table 2026-08-09 because it was in NEITHER a tier nor this list, which is the one state this table exists to make impossible. Three unrelated pre-existing failures: an AstPrinter switch missing `TypeRef.fn_type`, a CodeGen test calling `generate()` with 15 of 16 arguments, and a preamble `page_allocator` count drift (70 vs 72). Its selfhost-smoke leg passes 326/326. |

The tier grew 19 → 21 that night: `doc-example` (QUICK) and `release-mode` (FULL).

**Tier update 2026-08-07 — now 26, and `gates.sh --full` was 26/26** at JOBS=1 (smoke 320/320, output_sweep 322 identical, full_sweep 0 regressions, divergence 0 selfhost gaps). `bug-numbers` joined that day. The output_sweep line carried the weight: BUG-273 rewrote what every `assert` in 456 corpus files emits, and only a behaviour witness over the whole corpus could have caught a regression there. Previously — now 25, and `gates.sh --full` was 25/25 at JOBS=1 (smoke 317/317, compile_check 247/0 in both runtime shapes, output_sweep 322 identical, full_sweep 0 regressions vs 337, divergence 0 selfhost gaps). `expr-walker` joined that afternoon. Earlier the same day it was 24/24 (smoke 314/314,
compile_check 244/0 in both runtime shapes, output_sweep 322 identical, full_sweep 0
regressions vs 337, examples_sweep 0 vs 14, divergence 0 selfhost gaps). `ffi-lib` was
added that day (QUICK); the other two new lines are `contract-mode` and
`compile_check-inline`, which existed before but post-date the 21-gate count above.
**The three excluded items were NOT re-run** — their last sweep is still 2026-08-04, so
the table below stands unchanged.

**Previous sweep 2026-08-02** — 18/18, before those two gates existed.

**What a fully green board here does NOT mean.** `full_sweep` passes against a baseline of
**337** while the tracked corpus is **471** <!-- doc-gen: 471 = bash tools/corpus_ls.sh test | wc -l | tr -d ' ' -->.
A baseline defines the pass set, so files outside it cannot make the gate red no matter how
broken they are. BUG-241 and BUG-242 were both found sitting in exactly that gap. Green
and unexamined are not in tension; see `docs/INSTRUMENT_PASS_PLAN.md` §2.

The size of that gap is now **measured rather than estimated**, which it was not when this
paragraph was first written (it said "57 are in no known category" against a corpus of 421).
`registration_check` is the instrument: every tracked `test/*.zbr` must have its status
asserted by *something* — a smoke registration, the full_sweep pass baseline, or an entry in
`tools/registration_exempt.txt` **with a reason**. As of 2026-08-05 that leaves **19**
<!-- doc-gen: 19 = python tools/registration_check.py 2>/dev/null | grep -oE '[0-9]+ unasserted' | grep -oE '^[0-9]+' -->
unasserted, against 27 exempt-with-reason. Down from 57. Shrink it, never grow it — and note
the number now carries an oracle, so this paragraph cannot quietly go stale the way the last
version did.

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
