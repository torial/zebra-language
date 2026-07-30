#!/usr/bin/env bash
# gate_selfcheck.sh — prove the gates CAN FAIL.
#
# THE FAILURE MODE THIS EXISTS FOR
# --------------------------------
# A gate has three parts: an input it claims to measure, a mechanism, and an
# assertion. The dangerous failure is when the mechanism quietly stops being
# connected to the input while the assertion keeps passing. The gate is then not
# wrong — it is VACUOUS, and vacuous is worse than wrong, because a red gate gets
# investigated and a green one does not.
#
# This is not hypothetical. Three instances were found in this repo on 2026-07-28/29,
# in unrelated tools, all reporting success:
#
#   * bootstrap_check.sh steps 3/5 diffed a file against ITSELF. `--emit-zig` writes
#     to $TEMP (#230) but the script copied selfhost/$f.zig, which neither selfhost
#     pass touched. "byte-identical" could not fail. Fixed in 959f9f5.
#   * rebuild.sh regenerated using a zebra-bootstrap.exe that PREDATED the preamble
#     edit (build.zig embeds it at build time). Reported OK; changed nothing. Every
#     downstream gate then measured the unmodified compiler.
#   * stdlib_sig_check.py was about to be silently downgraded when `-c` became
#     front-end-only: 47 rows would have gone from "emits and zig-compiles" to
#     "parses", while printing the same green count.
#
# Each was caught by accident — by noticing a zero-diff that should have been
# non-zero, or by reasoning about a flag change. Accident is not a strategy, so:
# every gate that can be cheaply falsified is falsified here, and the ones that
# cannot are LISTED as uncovered rather than assumed fine.
#
# Run it after touching any gate, and when a gate's result surprises you.
#
#   bash tools/gate_selfcheck.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"
PY=/c/Users/Sean/AppData/Local/Programs/Python/Python311/python

FAIL=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '  \033[33m--\033[0m    %s\n' "$1"; }

# Scratch lives INSIDE the repo, deliberately. The first version used $TMPDIR, and on
# Windows a POSIX-style "/tmp/..." path is not `is_absolute()` to Python's pathlib, so
# the lint fell through to a repo-relative glob and raised. Repo-relative paths work
# for every checker here without per-tool special casing.
OUT="$REPO/.selfcheck_tmp"; rm -rf "$OUT"; mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT

# A checker that CRASHES must be reported as a crash, not as "found nothing". The first
# version of this harness piped stderr to /dev/null, so a NotImplementedError inside the
# lint was indistinguishable from a clean scan — the exact failure this tool exists to
# catch, committed inside the tool itself. Everything below keeps stderr.
run_checker() { # $@ = command; echoes combined output, prefixes a crash
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -gt 1 ]; then printf 'CRASH rc=%s :: %s' "$rc" "$out"; else printf '%s' "$out"; fi
}

echo "gate self-check — can each gate still fail?"
echo

# ── doctor: stale-bootstrap detection ────────────────────────────────────────
# Perturbs an mtime only; content is untouched, and the mtime is restored from a
# sibling file afterwards.
if [ -f selfhost/stdlib_preamble.zig ] && [ -f zig-out/bin/zebra-bootstrap.exe ]; then
    touch selfhost/stdlib_preamble.zig
    if bash tools/doctor.sh >/dev/null 2>&1; then
        bad "doctor did NOT flag a preamble newer than the bootstrap that embeds it"
    else
        pass "doctor flags a stale bootstrap (exit 1)"
    fi
    touch -r selfhost/napi_preamble.zig selfhost/stdlib_preamble.zig
else
    note "doctor: skipped (no built bootstrap to compare against)"
fi

# ── interp-escape lint: a known hazard must be reported ──────────────────────
# `${...}` interpolation plus an escaped quote is the BUG-216 shape the bootstrap
# double-escapes.
mkdir -p "$OUT/lint"
printf 'def f(x: str): str\n    return "a ${x} b \\" c"\n' > "$OUT/lint/hazard.zbr"
r=$(run_checker $PY tools/lint_interp_escape.py ".selfcheck_tmp/lint/hazard.zbr")
case "$r" in
    CRASH*)      bad "interp-escape lint CRASHED: ${r#CRASH }" ;;
    *"1 hazard"*) pass "interp-escape lint fires on a planted hazard" ;;
    *)           bad "interp-escape lint did NOT fire on a planted hazard" ;;
esac

# ── fallthrough lint: a known hazard must be reported ────────────────────────
# A value-returning fn whose TAIL branch has an arm that CONTAINS a return but can
# still fall through. Codegen TCO-wraps such a fn in while(true), so the arm HANGS
# rather than erroring.
#
# The inner `if` is load-bearing. The lint deliberately EXEMPTS arms with no return
# at all — those are pure side-effecting, not value-producing — so an arm body of
# just `var y = 2` reports nothing. The first fixture here made exactly that mistake
# and still appeared to PASS, because the assertion used `grep -qv`, which inverts
# per LINE and so matched almost any output. A wrong fixture and a wrong assertion
# cancelling out to green is precisely what this harness exists to expose.
printf 'def g(x: int): int\n    branch x\n        on 1\n            if x > 0\n                return 5\n        else\n            return 0\n' > "$OUT/lint/fall.zbr"
r=$(run_checker $PY tools/lint_fallthrough.py ".selfcheck_tmp/lint/fall.zbr")
case "$r" in
    CRASH*)      bad "fallthrough lint CRASHED: ${r#CRASH }" ;;
    *"0 hazard"*) bad "fallthrough lint did NOT fire on a planted hazard" ;;
    *hazard*)    pass "fallthrough lint fires on a planted hazard" ;;
    *)           bad "fallthrough lint gave no verdict: $r" ;;
esac

# ── compile_check: its worker must classify a known-bad file as FAIL ─────────
# bug099_unresolved_test emits cleanly and is then rejected by zig, and it is NOT
# smoke-registered, so the gate never sees it in a normal run — which makes it a
# clean input for testing the mechanism rather than the corpus.
if [ -f test/bug099_unresolved_test.zbr ]; then
    r=$(bash tools/compile_check.sh --worker selfhost test/bug099_unresolved_test.zbr 2>/dev/null | head -1)
    case "$r" in
        FAIL*) pass "compile_check worker reports FAIL on a known-bad emit" ;;
        *)     bad "compile_check worker said '$r' on a known-bad emit (expected FAIL)" ;;
    esac
else
    note "compile_check: skipped (witness file missing)"
fi

# ── stdlib_sig_check: a corrupted arity row must be caught ───────────────────
# Claims trim takes an argument. The positive leg compiles `s.trim("x")`, which the
# #5a checker now rejects, so the row must FAIL.
if [ -f tools/stdlib_signatures.tsv ]; then
    cp tools/stdlib_signatures.tsv "$OUT/sig.bak"
    $PY - <<'PYEOF'
import pathlib
p = pathlib.Path("tools/stdlib_signatures.tsv")
s = p.read_text(encoding="utf-8")
p.write_text(s.replace("str\ttrim\t0", "str\ttrim\t1\tstr"), encoding="utf-8", newline="\n")
PYEOF
    if $PY tools/stdlib_sig_check.py --only trim 2>/dev/null | grep -q 'FAILED: *0\|0 FAILED'; then
        bad "stdlib_sig_check accepted a CORRUPTED arity row"
    else
        pass "stdlib_sig_check rejects a corrupted arity row"
    fi
    cp "$OUT/sig.bak" tools/stdlib_signatures.tsv
else
    note "stdlib_sig_check: skipped (no signature table)"
fi

# ── round-trip: the freshness property whose absence made it vacuous ─────────
# The emits compared must be FRESH selfhost output, not copies of the committed
# bootstrap-emitted files. Checkable only if a prior full run left the dirs.
if [ -f /tmp/bs-A/main/main.zig ] && [ -f selfhost/main.zig ]; then
    if cmp -s /tmp/bs-A/main/main.zig selfhost/main.zig; then
        bad "round-trip emit is IDENTICAL to the committed .zig — it may be comparing copies again"
    else
        pass "round-trip emits are fresh selfhost output (differ from committed)"
    fi
else
    note "round-trip: skipped (run bootstrap_check.sh first to populate /tmp/bs-A)"
fi

# ── honest inventory of what is NOT self-checked ─────────────────────────────
echo
echo "  NOT self-checked (no cheap falsification — do not read the above as full coverage):"
echo "    smoke            — 260 fixtures; a planted failure means editing the suite"
echo "    full_sweep       — falsifying it means corrupting the baseline (25+ min to re-run)"
echo "    divergence       — needs both compilers over the whole corpus (~20 min)"
echo "    runtime-module   — its own size/BUG-221 assertions are already adversarial"
echo "    check-mode       — carries a built-in failure when no asymmetry witness survives"

echo
if [ "$FAIL" -gt 0 ]; then
    printf '\033[31mgate self-check: %d gate(s) could NOT be shown to fail\033[0m\n' "$FAIL"
    exit 1
fi
printf '\033[32mgate self-check: every covered gate demonstrably fails on a planted defect\033[0m\n'
