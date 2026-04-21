# Phase 22 Prep — Selfhost Cutover Readiness

Pre-cutover work before the selfhost binary replaces the Zig compiler as the
default `zebra` command.  Complete all four items before starting Phase 22.

## Tasks

- [ ] **1. BUGS.md triage** — scan for open selfhost-only or parity-affecting bugs;
      label each as BLOCKER or non-blocker for cutover
- [x] **2. `zig build selfhost` canonicalization** — confirm exact build command,
      canonical output path, add build.zig step if missing, document it
- [x] **3. Error format compatibility test** — verify selfhost diagnostic output is
      parseable by `CompilerBridge.parseLine()` (ZebraIDE depends on this)
      → fixtures in `test/selfhost_compat/`
- [x] **4. Parity runner** — `tools/parity_check.zbr`: compile+run each test/ file
      through both compilers; diff exit codes + stdout; primary cutover safety net

## Notes (updated as work proceeds)

<!-- Fill in as each task completes -->

### Task 1 — BUGS.md findings

No open bugs are selfhost-only divergences. Summary:

| Bug | Status | Phase 22 relevance |
|-----|--------|--------------------|
| BUG-002 guard/try_postfix panic | Open | NON-BLOCKER — affects both compilers equally; test quality issue |
| BUG-014 regex lazy global | Open | NON-BLOCKER — both compilers, architectural |
| BUG-017 .len heuristic | Open | NON-BLOCKER — both compilers, low severity |
| BUG-019 fn_ref terminator | Open | NON-BLOCKER — code quality only |
| BUG-026 instance_method_return_types | Open | WATCH — could cause const/var divergence in parity runner; parity check will surface it |
| BUG-027 method-chain temporaries | Open | NON-BLOCKER — both compilers same behavior |
| BUG-029 HashMap field init → i64 | Open | NON-BLOCKER — both compilers same behavior |
| BUG-030 .contains() on param HashMap | Open | NON-BLOCKER — both compilers same behavior |
| BUG-079 method chain auto-materialize | Open | NON-BLOCKER — both compilers same behavior; pre-1.0 item |
| All others | Fixed/Closed | N/A |

**Conclusion:** Zero blockers. BUG-026 is the one to watch — the parity runner
will reveal any const/var divergence it causes. No emergency fixes needed before cutover.

### Task 2 — selfhost build

**Canonical build command:** `zig build selfhost`

**What it does:** calls `bash tools/bootstrap_check.sh --quick`, which:
1. Emits all `selfhost/*.zbr` files to `/tmp/bs-zig/` via `zig-out/bin/zebra.exe`
2. Compiles `/tmp/bs-zig/main.zig` → `zig-out/bin/zebra-selfhost.exe`

**Files compiled (order matters):**
`Token Lexer ast parser resolver astbuilder cg_helpers typechecker codegen main`

**Canonical output path:** `zig-out/bin/zebra-selfhost.exe`

**Full bootstrap (level-2 fixed-point):** `zig build bootstrap`
Runs all 5 steps: A emits, A builds B, B re-emits, diff A vs B output. Use this before a cutover commit.

**Step added to build.zig:** `zig build selfhost` + `zig build bootstrap` steps both wired in.
`zig build` verified clean (exit 0).

### Task 3 — error format

**Result: COMPATIBLE** — `zebra-selfhost -c file.zbr` delegates to the Zig backend and
passes stderr through unchanged. The first diagnostic line is byte-identical to what
`zebra.exe` emits. Extra Zig build scaffolding in the selfhost output is already filtered
by `parseLine()` returning nil for non-matching lines.

**Fixtures:** `test/selfhost_compat/` (2 cases: type error, undefined variable)
**Runner:** `bash test/selfhost_compat/run_compat.sh` → 2/2 PASS

**Known gap (non-blocker):** `--selfhost-compile` mode uses `remapZigErrors()` which emits
`file:LINE: error: msg` (no column field). `parseLine()` requires `path:LINE:COL:` and
returns nil for column-less lines. This only matters if `--selfhost-compile` ever becomes
the default for IDE `-c` checks — it is not the default today.

### Task 4 — parity runner

**Tool:** `tools/parity_check.zbr`

**How to run:**
```
zig build run -- tools/parity_check.zbr
```

**What it does:**
- Scans `test/` for `*_test.zbr` and other runnable `.zbr` files
- Runs each through `zig-out/bin/zebra.exe file` (Zig backend reference)
- Runs each through `zebra-selfhost --selfhost-compile --output-dir /tmp/parity_sh file`
  (selfhost pipeline: Lex → Parse → Resolve → TC → CodeGen → zig run)
- Compares exit codes and program output (stderr, with selfhost debug lines filtered)
- Reports PASS / BOTH_FAIL / DIVERGE / MISMATCH per file + summary

**Skip list:** `*_lib.zbr` (modules), `bench_zebra.zbr`, `dns_test.zbr`

**Known divergences seen in calibration run:**
| File | Direction | Cause |
|------|-----------|-------|
| `any_all_test.zbr` | zig=0, sh=1 | Selfhost emits `var` where Zig emits `const` (BUG-026 area); Zig tolerates, selfhost rejects |
| `greet.zbr` | zig=1, sh=0 | Zig backend emits `const g: *Greeter = Greeter{}` (type annotation bug); selfhost emits correct `var g = Greeter{}` |
| `features.zbr` | zig=1, sh=0 | Similar Zig backend type annotation bug |

**Note:** `zebra.exe` intercepts all `-flags`, so `--filter`/`--quick` cannot be passed at
invocation time. Edit `tools/parity_check.zbr` directly to enable filtering during development.

**Output routing:** Both compilers send program output to stderr (via Zebra's `print` → `std.debug.print`).
`sys.run().stderr` captures the program output for comparison.

## Cutover checklist (to fill in after prep is done)

- [ ] All parity runner tests PASS (or known divergences documented) — run `zig build run -- tools/parity_check.zbr`
- [x] No BLOCKER bugs open — confirmed 2026-04-21
- [x] Error format verified compatible — `bash test/selfhost_compat/run_compat.sh` 2/2 PASS
- [x] `zig build selfhost` step clean and documented — canonical: `zig build selfhost`
- [ ] Bootstrap 5/5 still green — run `zig build bootstrap` before cutover
- [ ] SELFHOST_JOURNAL.md Phase 22 entry drafted
