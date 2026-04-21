# Phase 22 Prep — Selfhost Cutover Readiness

Pre-cutover work before the selfhost binary replaces the Zig compiler as the
default `zebra` command.  Complete all four items before starting Phase 22.

## Tasks

- [ ] **1. BUGS.md triage** — scan for open selfhost-only or parity-affecting bugs;
      label each as BLOCKER or non-blocker for cutover
- [ ] **2. `zig build selfhost` canonicalization** — confirm exact build command,
      canonical output path, add build.zig step if missing, document it
- [ ] **3. Error format compatibility test** — verify selfhost diagnostic output is
      parseable by `CompilerBridge.parseLine()` (ZebraIDE depends on this)
      → fixtures in `test/selfhost_compat/`
- [ ] **4. Parity runner** — `tools/parity_check.zbr`: compile+run each test/ file
      through both compilers; diff exit codes + stdout; primary cutover safety net

## Notes (updated as work proceeds)

<!-- Fill in as each task completes -->

### Task 1 — BUGS.md findings
_pending_

### Task 2 — selfhost build
_pending_

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
