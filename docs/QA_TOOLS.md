# Verification & QA Tools — a field guide

*How to prove a Zebra compiler change is correct, which tool proves what, and how
to read a failure. Written for a future maintainer (human or Claude) who needs to
know **which tool to reach for and what its output is telling them** — the part
that was tribal knowledge before this doc.*

Companions: [`COMPILER_WORKFLOW.md`](COMPILER_WORKFLOW.md) (the edit→build→commit
cycle + language traps), [`../fuzz/README.md`](../fuzz/README.md) (the fuzzer
deep-dive), [`../tools/PROBES.md`](../tools/PROBES.md) (snapshots + golden probes),
[`COVERAGE_MAP.md`](COVERAGE_MAP.md) (what these tools do **not** cover — the risk
surface), [`DEBUGGING.md`](DEBUGGING.md).

---

## 1. The mental model — defense in depth

Correctness here rests on **two compilers that must be functionally equivalent**:
`zebra-bootstrap.exe` (Zig-implemented, `src/`, the trusted reference) and
`zebra.exe` (self-hosted, `selfhost/*.zbr`, the primary). Every tool below checks
a different slice of "do they agree, and is what they emit correct?". No single
tool is sufficient — each has a blind spot the next one covers:

| Layer | Tool | Proves | Blind spot (→ covered by) |
|---|---|---|---|
| Emit | `selfhost_smoke.sh` | parse→resolve→typecheck→emit **succeed** on the hand corpus | doesn't compile the emitted Zig (→ `compile_check`); only fixtures we wrote (→ fuzzer) |
| Compile | `compile_check.sh` | the emitted Zig **compiles** (`zig build-exe -fno-emit-bin`) | doesn't **run** it; only the positive smoke set |
| Round-trip | `bootstrap_check.sh` | selfhost compiles **itself** byte-identically (self-consistent, deterministic) | only code shapes **in the compiler's own source** (→ fuzzer) |
| Differential | `fuzz/run.py` | bootstrap ≡ selfhost on **random** user programs (emit + compile + run) | only the generator's grammar surface (→ `COVERAGE_MAP.md`) |
| Inference | `check_inference_guess.sh` | no type-dispatch site emits a **guess** Zig might reject | narrow — one bug class |
| Feature | `fmt_safety.py`, `lsp_*_smoke` | one subsystem behaves + preserves semantics | scoped to that subsystem |
| Style/discipline | `check_explicit_try.sh`, `escape_hatches_check.sh` | corpus stays on the intended idiom / memory model | prevents regressions, not new bugs |

The single most important idea: **the round-trip gate structurally cannot catch a
bug that only manifests on user-code shapes absent from the compiler's own
sources** (this is why the fuzzer exists — it found BUG-159/160 that way). And the
fuzzer only tests the shapes its generator produces (`COVERAGE_MAP.md` is the map
of what escapes even that).

---

## 2. The pre-commit gate sequence (the ritual)

Run these before committing a compiler change. Order is cheapest-signal-first, so
a fast gate fails before you wait on a slow one:

```bash
export PATH="/c/Users/Sean/.zvm/bin:$PATH"        # Zig on PATH (Git Bash)
bash tools/sysload.sh                              # 0. check RAM/CPU before heavy builds
bash tools/bootstrap_check.sh --quick              # 1. does the .zbr compile at all? (~fast)
# ...iterate until --quick passes, THEN:
bash tools/bootstrap_check.sh --update && zig build # 2. regen selfhost/*.zig + build zebra.exe
bash tools/selfhost_smoke.sh                       # 3. emit corpus (231 tests)
bash tools/bootstrap_check.sh                      # 4. FULL 5-step round-trip (byte-identical A≡B)
bash tools/check_inference_guess.sh                # 5. 0 inference-guess sites
python fuzz/run.py --n 25 --start 0 --run          # 6. differential + run oracle (25 seeds)
# subsystem gates, only if you touched them:
python tools/fmt_safety.py                         # if you changed the formatter
python tools/lsp_server_smoke.py                   # if you changed the LSP (runLsp)
bash tools/lsp_diagnostics_smoke.sh                # if you changed diagnostics
```

Green across #3–#6 is the bar this project has held for every commit. A change that
touches the **shared preamble** (`selfhost/stdlib_preamble.zig`) additionally needs
a `zig build` before any bootstrap-emitted parity check — see the tells below.

---

## 3. Tool reference

Each entry: **what it proves · how to run · reading the output · tells & gotchas.**

### Build / regen

**`tools/bootstrap_check.sh`** — the workhorse. Three modes:
- `--quick` — steps 1–2 only: bootstrap re-emits all `selfhost/*.zig` into
  `/tmp/bs-zig`, builds `zebra-selfhost.exe` from them. **Use this while iterating**
  — it's the fast "did my `.zbr` even compile?" loop (~1–2 min build). Does **not**
  touch `selfhost/*.zig` (working tree stays clean) and does **not** round-trip.
- `--update` — steps 1–2 then re-emits `selfhost/*.zig` **in place** via
  `zebra-bootstrap.exe` (== `zig build update-selfhost`). Run this + `zig build`
  when you need `zebra.exe` itself to reflect the change. Snapshots+restores on
  failure so a partial emit never leaves a mixed tree.
- (no flag) — the full **5-step round-trip**: regen → build selfhost-A → A re-emits
  its own source → build selfhost-B → **diff B vs A, must be byte-identical.** The
  commit gate. A pass means the selfhost compiler is self-consistent + deterministic.
- Reading it: `PASS: round-trip clean` is the goal. A diff in step 5 means selfhost
  emission is non-deterministic or A miscompiled itself — inspect the diffed file.
- **Tells:** never run two bootstrap checks concurrently (they share `/tmp/bs-zig`
  → spurious "has no member `_initAllocator`" errors). Never run `zig build` *during*
  an `--update` (they race the same output).

**`zig build`** — builds both binaries. `zebra.exe` uses the **fast backend**
(`-fno-llvm -fno-lld`, ~6× faster link); `zebra-bootstrap.exe` uses LLVM
(regen-authority conservatism). `zig build test` runs the unit tests + smoke.
`zig build update-selfhost` == `bootstrap_check.sh --update`.

**`tools/sysload.sh`** — one-line RAM/CPU report. Run before any heavy build (the
machine is often already loaded). One approvable command; the nested PowerShell
doesn't prompt separately.

### Correctness gates

**`tools/selfhost_smoke.sh`** — emit-only corpus gate (231 tests) via `zebra.exe
--emit-zig` to a temp dir. Fast (~0.5–2s/test, shared Zig cache). Helpers:
`smoke FILE` (exit 0), `smoke_run FILE "out"` (exit 0 + stdout), `smoke_tc_fail
FILE "err"` (exit 1 + stderr substring). **Does NOT compile the emitted Zig** — a
stale-stdlib or codegen bug that produces non-compiling Zig passes smoke. That gap
is `compile_check.sh`.

**`tools/compile_check.sh`** — closes smoke's gap: emits every positive smoke test
and runs `zig build-exe -fno-emit-bin` (semantic analysis, no link) on the result.
`--bootstrap` runs it through `zebra-bootstrap.exe`. Reach for this when you touch
codegen or the preamble and want to know the emitted Zig actually type-checks
(especially after a Zig-toolchain bump — the C1–C4 drift class in `FEATURE_AUDIT`).

**`tools/check_inference_guess.sh`** — fails if any type-dispatch site emits a
**guess** because the TypeChecker couldn't supply the operand/receiver type (the
F7/BUG-162/BUG-168 class: `add`, `len_count`, `list_dispatch`). Corpus is at **0**;
this keeps it there. `0 guess sites` = pass. A non-zero count names a site where
codegen fell back to an assumption Zig may reject (or, worse, accept wrongly).
Incremental by default; forces a full re-scan when the compiler binary is newer.

**`tools/check_explicit_try.sh`** — §28b gate: fails if any throws-call relies on
legacy auto-`try` instead of explicit `?`. Incremental; `--full` for CI certainty.

**`tools/escape_hatches_check.sh`** — fails if a **new** `std.heap.page_allocator`
use appears (Zebra uses one program-wide arena; each page_allocator escape is
reviewed). A new use requires a deliberate baseline bump here — forcing review.

### Differential (equivalence) testing

**`fuzz/run.py`** — the differential + validity fuzzer. See
[`../fuzz/README.md`](../fuzz/README.md) for the oracle and verdicts. Quick recipes:
```bash
python fuzz/run.py --n 200                 # 200 seeds, emit + zig-validity
python fuzz/run.py --n 25 --start 0 --run  # + build-exe + run + compare stdout (the strong oracle)
python fuzz/run.py --seed 12345            # reproduce ONE seed (A vs B)
python fuzz/gen.py 42                       # just print the program for seed 42
```
- **Reading it:** the `=== buckets ===` summary. `N ok` = all agreed. `zig-diverge-*`
  / `run-divergence` / `crash-*` = equivalence bugs (reproducers saved to
  `fuzz/findings/`). `both-zig-fail` = a **shared** gap (not equivalence). `both-reject`
  = generator tuning signal.
- **Gotcha:** `--seed X` short-circuits to a **single** seed and ignores `--n`. For a
  batch use `--start 0 --n 25` (no `--seed`). Its coverage ceiling is `DEFAULT_CAPS`
  in `gen.py` → see `COVERAGE_MAP.md` for what it can't reach.

**`tools/parity_check.zbr`** — the hand-corpus counterpart to the fuzzer: runs each
test file through **both** compilers and diffs exit code + program output. Random
where the fuzzer is; fixed-corpus where the fuzzer is random. `zig build run --
tools/parity_check.zbr`.

**`tools/corpus_snapshot.sh`** — before/after emit-shift detector for wave edits.
Writes a `file<TAB>backend<TAB>exit<TAB>content_sha<TAB>stderr_sha` TSV; `diff` the
pre/post. A changed `content_sha` with `exit=0` on both sides is the sneaky case
(emit changed silently). Full details + the re-emits-into-source-tree hazard in
[`PROBES.md`](../tools/PROBES.md).

### Feature / subsystem gates

**`tools/fmt_safety.py`** — the formatter safety gate (13 checks): string-preservation
fixtures + idempotence on all corpus files + **emit-equivalence** (format N files,
prove each emits byte-identical Zig → formatting preserved semantics). **Tell:** it
strips `// Source:` / `// zbr:PATH:LINE` lines before diffing emitted Zig — those
embed the input path, so a temp-dir copy would diff spuriously. If you add an
emit-equivalence check elsewhere, do the same or you'll chase phantom diffs.

**`tools/lsp_server_smoke.py`** — drives `zebra lsp` over stdio with a full JSON-RPC
conversation (14 checks: initialize → diagnostics → documentSymbol → formatting →
hover → definition → completion → member completion → signature help → MethodNotFound
→ shutdown). **Tell:** diagnostics are **debounced** — the test sends through
didChange, `time.sleep(0.6)` past the ~200ms window, then the rest; the clean
diagnostics come from the timer flush. If you shrink the debounce window in
`runLsp`, keep the test's sleep > it.

**`tools/lsp_diagnostics_smoke.sh`** — checks `zebra diagnostics <file> --out <json>`
(the JSON seam the LSP is built on) on a syntax-error and a clean file.

**`tools/node_addon_test.sh`** — end-to-end for `zebra --target node-addon`: builds
each `test/node_addon/*.zbr` to a `.node` and runs its `.check.js`. Not in `zig
build test` (needs Node + node-gyp headers); run on demand.

### Dev loop & hooks

**`tools/watch.zbr`** — recompile+run a `.zbr` on every change (`--interval N`,
`--check` for compile-only). `zig build run -- tools/watch.zbr path/to/file.zbr`.

**Golden probes** — hand `.zbr` files in `C:\tmp\verify_<bug>.zbr` that pinpoint one
emit behavior; promote load-bearing ones into `test/`. Convention + promotion recipe
in [`PROBES.md`](../tools/PROBES.md).

**`tools/install_merge_hook.sh`** — installs a pre-merge-commit hook running
`zebra typecheck-merge` on conflict-marked `.zbr` files (informational, exit 0).

---

## 4. Diagnostic tells — symptom → cause

The failures that look like one thing and are actually another. This table is the
hours-saver:

| Symptom | Almost certainly | Fix |
|---|---|---|
| Bootstrap-emitted Zig fails with **"method invocation only supports one level of implicit pointer dereferencing"** on a method you *just added to the preamble* | `zebra-bootstrap.exe` is **stale** — it embeds the OLD preamble (edited `.zbr`/preamble but didn't `zig build`) | `zig build`, then re-test |
| A build sits at **0% CPU for many minutes** | the **fast-backend link** is genuinely slow here (not hung) — `zebra.exe` links can take 10–15 min under memory pressure | wait; check `sysload.sh`; don't kill it |
| `--emit-zig` / `print` produces **empty stdout** when piped | on the **fast backend**, `print` and `--emit-zig` go to **stderr** (Zig's `std.debug.print`); real stdout is `Terminal.write` | redirect `2>file`, or use `--output-dir DIR` / `--out file` |
| `fmt_safety.py` reports hundreds of emit diffs after a clean format | you're comparing a **temp-dir copy** against the original path — the diffs are all `// Source:`/`// zbr:` path comments | strip those lines (the gate already does) |
| `npm`/`vsce` fails with **`ECOMPROMISED` "Lock compromised"** | corrupt/locked npm **cacache** (often many node procs running) | install into a scratch dir with an isolated `--cache DIR`; don't fight the shared cache |
| Tokenizer crash: **`error.UnexpectedCharacter`** with **no source location** | a **CRLF** `\r` in a `.zbr` (Python `open('w')` writes CRLF on Windows) | write with `newline='\n'`; `file foo.zbr` shows `CRLF` |
| Round-trip errors like **"struct 'checker' has no member `_initAllocator`"** | two bootstrap checks ran **concurrently** and corrupted `/tmp/bs-zig` | run one at a time |
| Zig **"expected type 'Expr', found '*Expr'"** only in dep-mode | `if x as n` on a boxed optional `^T?` binds a **pointer** | use `!= nil` + `to!` (see COMPILER_WORKFLOW) |
| Zig **"pointless discard of function parameter"** in emitted `zig"…"` code | param-discards emitted before inline Zig that uses the param (audit B3) | known gap |
| `check_inference_guess` non-zero after a TC change | codegen hit a dispatch site whose operand/receiver type the TC didn't infer | fix the TC to infer it (don't add a guess) |
| Smoke green but the program **won't compile as Zig** | smoke is **emit-only** | run `compile_check.sh` |

---

## 5. What none of this covers

Every tool above verifies **something is exercised**. The gap — language constructs
that no test, no fuzzer seed, and no compiler-internal use touches — is not visible
from any single tool. That blind-spot map is [`COVERAGE_MAP.md`](COVERAGE_MAP.md),
and closing it (chiefly by **growing the fuzzer's `DEFAULT_CAPS`** so more constructs
get randomly *combined*) is where the next undiscovered `List(char)`-class bug is
hiding.
