# Phase 22 Prep — Selfhost Cutover Readiness

Pre-cutover work before the selfhost binary replaces the Zig compiler as the
default `zebra` command.  Complete all four items before starting Phase 22.

## Tasks

- [ ] **1. BUGS.md triage** — scan for open selfhost-only or parity-affecting bugs;
      label each as BLOCKER or non-blocker for cutover
- [x] **2. `zig build selfhost` canonicalization** — confirm exact build command,
      canonical output path, add build.zig step if missing, document it
- [ ] **3. Error format compatibility test** — verify selfhost diagnostic output is
      parseable by `CompilerBridge.parseLine()` (ZebraIDE depends on this)
      → fixtures in `test/selfhost_compat/`
- [ ] **4. Parity runner** — `tools/parity_check.zbr`: compile+run each test/ file
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
_pending_

### Task 4 — parity runner
_pending_

## Cutover checklist (to fill in after prep is done)

- [ ] All parity runner tests PASS (or known divergences documented)
- [ ] No BLOCKER bugs open
- [ ] Error format verified compatible
- [ ] `zig build selfhost` step clean and documented
- [ ] Bootstrap 5/5 still green
- [ ] SELFHOST_JOURNAL.md Phase 22 entry drafted
