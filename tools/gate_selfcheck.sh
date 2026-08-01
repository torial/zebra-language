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
trap 'rm -rf "$OUT" "$LAST_OUT_FILE"' EXIT

# A checker that CRASHES must be reported as a crash, not as "found nothing". The first
# version of this harness piped stderr to /dev/null, so a NotImplementedError inside the
# lint was indistinguishable from a clean scan — the exact failure this tool exists to
# catch, committed inside the tool itself. Everything below keeps stderr.
run_checker() { # $@ = command; echoes combined output, prefixes a crash
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -gt 1 ]; then printf 'CRASH rc=%s :: %s' "$rc" "$out"; else printf '%s' "$out"; fi
}

# For exit-code-driven checks, `if ! cmd; then pass` is NOT a falsification test: every
# non-zero exit reads as success, so a missing compiler or a crash inside the checker
# reports that the gate works. Reviewed 2026-07-29 and found in three checks here — the
# vacuity pattern this file exists for, inside this file, again.
#
# The fix is two-legged and applies to all of them: establish the BASELINE first and
# require silence, then plant the defect and require exactly the failure code. A rc the
# check does not expect is reported as a CRASH, never as a verdict.
# NOTE the file, not a variable. `got=$(run_rc ...)` runs run_rc in a COMMAND
# SUBSTITUTION SUBSHELL, so any variable it sets is discarded when that subshell exits —
# every "crash, not a verdict: $(last_out)" message printed an empty string, which is how a
# real bug-fixture failure got reported as an unexplained crash. A file survives the
# subshell. (Found 2026-07-30 by this harness reporting FAIL on itself.)
LAST_OUT_FILE="/tmp/gate_selfcheck_last_out.$$"
run_rc() { # $@ = command; writes combined output to LAST_OUT_FILE; echoes the exit code
    "$@" > "$LAST_OUT_FILE" 2>&1; echo $?
}
last_out() { head -c 400 "$LAST_OUT_FILE" 2>/dev/null; }

echo "gate self-check — can each gate still fail?"
echo

# ── doctor: stale-bootstrap detection ────────────────────────────────────────
# Perturbs an mtime only; content is untouched, and the mtime is restored from a
# sibling file afterwards.
if [ -f selfhost/stdlib_preamble.zig ] && [ -f zig-out/bin/zebra-bootstrap.exe ]; then
    base=$(run_rc bash tools/doctor.sh)
    if [ "$base" -ne 0 ]; then
        note "doctor: skipped (already exits $base on the UNPERTURBED tree, so a failure"
        note "        after planting would prove nothing — clear that first)"
    else
        touch selfhost/stdlib_preamble.zig
        got=$(run_rc bash tools/doctor.sh)
        touch -r selfhost/napi_preamble.zig selfhost/stdlib_preamble.zig
        case "$got" in
            1) pass "doctor flags a stale bootstrap (clean 0 -> planted 1)" ;;
            0) bad "doctor did NOT flag a preamble newer than the bootstrap that embeds it" ;;
            *) bad "doctor CRASHED (rc=$got) instead of reporting: $(last_out)" ;;
        esac
    fi
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
    base=$(run_rc $PY tools/stdlib_sig_check.py --only trim)
    if [ "$base" -ne 0 ]; then
        note "stdlib_sig_check: skipped (--only trim already fails rc=$base on the CLEAN"
        note "        table, so rejecting a corrupted row would prove nothing)"
        sig_ok=0
    else
        sig_ok=1
    fi
else
    sig_ok=0
fi
if [ "$sig_ok" = 1 ]; then
    cp -p tools/stdlib_signatures.tsv "$OUT/sig.bak"
    $PY - <<'PYEOF'
import pathlib
p = pathlib.Path("tools/stdlib_signatures.tsv")
s = p.read_text(encoding="utf-8")
p.write_text(s.replace("str\ttrim\t0", "str\ttrim\t1\tstr"), encoding="utf-8", newline="\n")
PYEOF
    got=$(run_rc $PY tools/stdlib_sig_check.py --only trim)
    cp -p "$OUT/sig.bak" tools/stdlib_signatures.tsv
    case "$got" in
        1) pass "stdlib_sig_check rejects a corrupted arity row (clean 0 -> planted 1)" ;;
        0) bad "stdlib_sig_check accepted a CORRUPTED arity row" ;;
        *) bad "stdlib_sig_check CRASHED (rc=$got) instead of reporting: $(last_out)" ;;
    esac
fi

# ── str-ownership: a perturbed generated table must be caught ────────────────
# The doc is DERIVED from emit, so drift means the shipped ownership claims are wrong
# while still carrying a GENERATED banner. Appending a bogus row stands in for a codegen
# change that flips an ownership.
if [ -f docs/str_ownership.md ]; then
    base=$(run_rc $PY tools/str_ownership_extract.py --check)
    if [ "$base" -ne 0 ]; then
        note "str-ownership: skipped (--check already fails rc=$base on the UNPERTURBED"
        note "        doc, so rejecting a planted row would prove nothing)"
    else
        cp -p docs/str_ownership.md "$OUT/own.bak"
        printf '\n| `s.bogus()` | **BORROW** | | | |\n' >> docs/str_ownership.md
        got=$(run_rc $PY tools/str_ownership_extract.py --check)
        cp -p "$OUT/own.bak" docs/str_ownership.md
        case "$got" in
            1) pass "str-ownership rejects a perturbed table (clean 0 -> planted 1)" ;;
            0) bad "str-ownership accepted a PERTURBED generated table" ;;
            *) bad "str-ownership CRASHED (rc=$got) instead of reporting: $(last_out)" ;;
        esac
    fi
else
    note "str-ownership: skipped (no generated table)"
fi

# ── oom-unreachable: an allocation with `catch unreachable` must be caught ───
# The hazard is UB in ReleaseFast only, so no runtime gate can see it — this lint is the
# sole witness, which makes proving it still fires more than usually important.
r=$(run_checker $PY tools/lint_oom_unreachable.py)
case "$r" in
    CRASH*)       bad "oom-unreachable lint CRASHED: ${r#CRASH }" ;;
    *"0 hazard"*) : ;;   # clean baseline as expected; the planted leg is below
    *)            bad "oom-unreachable lint is NOT clean on an unperturbed tree: $r" ;;
esac
if printf '%s' "$r" | grep -q '0 hazard'; then
    cp -p selfhost/CodeGen.zbr "$OUT/cg.bak"
    printf '\ndef _selfcheckProbe()\n    w.emit("_allocator.alloc(u8, 4) catch unreachable")\n' \
        >> selfhost/CodeGen.zbr
    r2=$(run_checker $PY tools/lint_oom_unreachable.py)
    cp -p "$OUT/cg.bak" selfhost/CodeGen.zbr
    case "$r2" in
        CRASH*)       bad "oom-unreachable lint CRASHED on the planted hazard: ${r2#CRASH }" ;;
        *"1 hazard"*) pass "oom-unreachable lint fires on a planted allocation (clean 0 -> 1)" ;;
        *)            bad "oom-unreachable lint did NOT fire on a planted allocation: $r2" ;;
    esac
fi

# ── bug-fixture: a newly FIXED bug with no test must be caught ───────────────
# Plants a synthetic FIXED bug in BUGS.md that no fixture covers. Restored immediately.
if [ -f tools/bug_fixture_baseline.txt ]; then
    base=$(run_rc $PY tools/bug_fixture_check.py --gate)
    if [ "$base" -ne 0 ]; then
        note "bug-fixture: skipped (--gate already fails rc=$base on the UNPERTURBED tree)"
    else
        cp BUGS.md "$OUT/BUGS.bak"
        $PY - <<'PYEOF'
import pathlib
p = pathlib.Path("BUGS.md"); s = p.read_text(encoding="utf-8")
i = s.index("\n---\n") + 5
p.write_text(s[:i] + "\n### BUG-901: planted by gate_selfcheck, no fixture FIXED\nSynthetic.\n\n---\n" + s[i:],
             encoding="utf-8", newline="\n")
PYEOF
        got=$(run_rc $PY tools/bug_fixture_check.py --gate)
        cp -p "$OUT/BUGS.bak" BUGS.md
        # rc alone is ambiguous — a crash also exits 1 — so require the planted bug be NAMED.
        if [ "$got" -eq 1 ] && printf '%s' "$(last_out)" | grep -q 'BUG-901'; then
            pass "bug-fixture catches a newly FIXED bug with no test (and names it)"
        elif [ "$got" -eq 0 ]; then
            bad "bug-fixture accepted a FIXED bug with NO fixture"
        else
            bad "bug-fixture rc=$got without naming BUG-901 — crash, not a verdict: $(last_out)"
        fi
    fi
else
    note "bug-fixture: skipped (no baseline — run --update-baseline)"
fi

# ── output-sweep: a perturbed RECORDED OUTPUT must be caught ─────────────────
# The behaviour gate compares what each corpus program PRINTS against a golden baseline.
# Perturbing one recorded output stands in for a codegen change that alters behaviour.
# Scoped with --only so this stays a few seconds rather than a full corpus run.
if [ -f tools/output_baseline.txt ]; then
    base=$(run_rc bash tools/output_sweep.sh --gate --only any_all_test)
    if [ "$base" -ne 0 ]; then
        note "output-sweep: skipped (--gate already fails rc=$base on the UNPERTURBED"
        note "        baseline, so catching a planted change would prove nothing)"
    else
        cp -p tools/output_baseline.txt "$OUT/outbase.bak"
        $PY - <<'PYEOF'
import pathlib
p = pathlib.Path("tools/output_baseline.txt")
s = p.read_text(encoding="utf-8")
i = s.index("=== any_all_test ")
j = s.index("=== ", i + 10)
p.write_text(s[:i] + s[i:j].replace("true", "false", 1) + s[j:],
             encoding="utf-8", newline="\n")
PYEOF
        got=$(run_rc bash tools/output_sweep.sh --gate --only any_all_test)
        cp -p "$OUT/outbase.bak" tools/output_baseline.txt
        case "$got" in
            1) pass "output-sweep catches a changed program output (clean 0 -> planted 1)" ;;
            0) bad "output-sweep accepted a PERTURBED recorded output" ;;
            *) bad "output-sweep CRASHED (rc=$got) instead of reporting: $(last_out)" ;;
        esac
    fi
else
    note "output-sweep: skipped (no behaviour baseline — run --update-baseline)"
fi

# ── boundary suite: a perturbed INTENDED output must be caught ───────────────
# The A3 suite compares each probe's stdout against a HAND-WRITTEN expectation. The
# failure mode it must not have is the one every diff-based check has: comparing
# against something that cannot disagree. Perturbing one intended value stands in for
# a compiler change that alters a boundary answer.
#
# Scoped with --only to one probe so this stays seconds. bv_empty_set is chosen because
# it is the smallest `runs` probe that is NOT `@boundary-pending` — perturbing a pending
# probe would test the tripwire rather than the diff.
if [ -f test/boundary/bv_empty_set.expected ]; then
    base=$(run_rc bash tools/boundary_check.sh --only bv_empty_set)
    if [ "$base" -ne 0 ]; then
        note "boundary: skipped (--only bv_empty_set already fails rc=$base on the"
        note "        UNPERTURBED tree, so catching a planted change would prove nothing)"
    else
        cp -p test/boundary/bv_empty_set.expected "$OUT/bv.bak"
        $PY - <<'PYEOF'
import pathlib
p = pathlib.Path("test/boundary/bv_empty_set.expected")
s = p.read_text(encoding="utf-8")
# "dupLen=1" is the de-duplication boundary: flipping it to 2 is exactly what a
# broken Set.add would produce, so the planted defect is a realistic one.
p.write_text(s.replace("dupLen=1", "dupLen=2", 1), encoding="utf-8", newline="\n")
PYEOF
        got=$(run_rc bash tools/boundary_check.sh --only bv_empty_set)
        cp -p "$OUT/bv.bak" test/boundary/bv_empty_set.expected
        case "$got" in
            1) pass "boundary catches a changed boundary answer (clean 0 -> planted 1)" ;;
            0) bad "boundary accepted a PERTURBED intended output" ;;
            *) bad "boundary CRASHED (rc=$got) instead of reporting: $(last_out)" ;;
        esac
    fi
else
    note "boundary: skipped (no boundary suite present)"
fi

# ── boundary suite: a probe with no directive must be reported, not skipped ──
# The runner is directive-driven, so the dangerous silent failure is a probe the loop
# does not know how to assert and quietly passes over — coverage lost while the count
# still looks healthy. A directive-less file must FAIL rather than vanish.
if [ -d test/boundary ]; then
    printf 'def main()\n    print("x")\n' > test/boundary/_selfcheck_nodirective.zbr
    got=$(run_rc bash tools/boundary_check.sh --only _selfcheck_nodirective)
    rm -f test/boundary/_selfcheck_nodirective.zbr
    # Grep the CAPTURE FILE, not last_out(): last_out truncates to 400 chars and the
    # relevant line sits below the runner's banner, so the assertion would have failed
    # for a reason unrelated to the gate — the exact "wrong assertion cancels out"
    # shape this harness exists to expose.
    if [ "$got" -eq 1 ] && grep -q "_selfcheck_nodirective (no" "$LAST_OUT_FILE"; then
        pass "boundary reports a probe with no directive (never silently skips one)"
    elif [ "$got" -eq 0 ]; then
        bad "boundary SILENTLY SKIPPED a probe with no directive"
    else
        bad "boundary rc=$got without naming the missing directive: $(last_out)"
    fi
fi

# ── boundary suite: the PENDING TRIPWIRE must actually fire ─────────────────
# Five of the twelve probes assert via `rejects`/`warns`, which are DIFFERENT branches of
# the runner from the diff path falsified above — and they carry the property the design
# leans on hardest: a probe pinning a known bug must FAIL once that bug is fixed, so the
# gap cannot be silently suppressed. That claim was documented and unproven.
#
# The direct test is a `rejects` probe over a program that compiles fine, which is exactly
# what a pending probe becomes the day its bug is fixed. If the runner passed that, every
# @boundary-pending probe in the suite would be a permanent green lie.
if [ -d test/boundary ]; then
    cat > test/boundary/_selfcheck_tripwire.zbr <<'ZEOF'
# @boundary rejects this program is fine and must not be rejected
def main()
    print("ok")
ZEOF
    got=$(run_rc bash tools/boundary_check.sh --only _selfcheck_tripwire)
    rm -f test/boundary/_selfcheck_tripwire.zbr
    if [ "$got" -eq 1 ] && grep -q 'but it built and ran' "$LAST_OUT_FILE"; then
        pass "boundary pending-tripwire fires when a 'rejects' probe starts compiling"
    elif [ "$got" -eq 0 ]; then
        bad "boundary PASSED a 'rejects' probe that compiled cleanly — every @boundary-pending probe is a green lie"
    else
        bad "boundary rc=$got without reporting the unexpected success: $(last_out)"
    fi

    # The `warns` branch, same argument: a probe asserting a warning must fail when the
    # warning is absent, or bv_arity_too_few/too_many would pass on a compiler that had
    # silently stopped checking arity anywhere at all.
    cat > test/boundary/_selfcheck_warn.zbr <<'ZEOF'
# @boundary warns a warning that is never emitted
def main()
    print("ok")
ZEOF
    got=$(run_rc bash tools/boundary_check.sh --only _selfcheck_warn)
    rm -f test/boundary/_selfcheck_warn.zbr
    if [ "$got" -eq 1 ] && grep -q 'intended warning is MISSING' "$LAST_OUT_FILE"; then
        pass "boundary reports a 'warns' probe whose warning never appears"
    elif [ "$got" -eq 0 ]; then
        bad "boundary PASSED a 'warns' probe that emitted no warning"
    else
        bad "boundary rc=$got without reporting the missing warning: $(last_out)"
    fi
fi

# ── examples sweep (A5): a baselined example that regresses must be caught ────
# full_sweep over test/ is listed below as NOT self-checked, because falsifying it means
# corrupting a 331-entry baseline and re-running for 25 minutes. The EXAMPLES corpus is
# 18 files and ~90s, so the same mechanism CAN be falsified cheaply here -- and it is the
# same code path, so this covers the gate logic for both corpora.
#
# Planting an entry that cannot pass is the realistic defect: it stands in for an example
# that regressed, which is precisely what shipped unnoticed with widget_smoke (BUG-230).
if [ -f tools/examples_sweep_baseline.txt ]; then
    base=$(run_rc env JOBS=2 bash tools/full_sweep.sh --examples --gate)
    if [ "$base" -ne 0 ]; then
        note "examples-sweep: skipped (--gate already fails rc=$base on the UNPERTURBED"
        note "        baseline, so catching a planted regression would prove nothing)"
    else
        cp -p tools/examples_sweep_baseline.txt "$OUT/exbase.bak"
        printf '_selfcheck_absent_example\n' >> tools/examples_sweep_baseline.txt
        sort -o tools/examples_sweep_baseline.txt tools/examples_sweep_baseline.txt
        got=$(run_rc env JOBS=2 bash tools/full_sweep.sh --examples --gate)
        cp -p "$OUT/exbase.bak" tools/examples_sweep_baseline.txt
        case "$got" in
            1) pass "examples-sweep catches a baselined example that stops passing" ;;
            0) bad "examples-sweep accepted a baseline entry that does NOT pass" ;;
            *) bad "examples-sweep CRASHED (rc=$got) instead of reporting: $(last_out)" ;;
        esac
    fi
else
    note "examples-sweep: skipped (no baseline -- run --examples --update-baseline)"
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

# ── hazard-lint: fires on a planted tooling hazard, and REFUSES when blinded ──
# Two legs, because this gate has two failure modes and only one of them is the usual one.
#
# Leg A is the ordinary falsification: plant a hazard, require rc=1.
#
# Leg B is the one specific to this tool. hazard_lint runs positive controls before every
# scan and is supposed to exit 2 — not 0 — if a check has stopped firing on its own
# control. That refusal is the whole reason to trust a clean report from it, and a refusal
# path that is never exercised is exactly the kind of thing this file exists to catch. So
# we blind a check on purpose and require the refusal.
if [ -f tools/hazard_lint.py ]; then
    base=$(run_rc $PY tools/hazard_lint.py)
    if [ "$base" -ne 0 ]; then
        note "hazard-lint: skipped (already reports rc=$base on the UNPERTURBED tree,"
        note "        so catching a planted hazard would prove nothing)"
    else
        # Leg A — a realistic defect: the CRLF restore that fabricated 241 detections.
        mkdir -p "$OUT/hz"
        printf 'import pathlib\np = pathlib.Path("selfhost/CodeGen.zbr")\np.write_text("x", encoding="utf-8")\n' \
            > "$OUT/hz/planted.py"
        got=$(run_rc $PY tools/hazard_lint.py ".selfcheck_tmp/hz/*.py")
        case "$got" in
            1) pass "hazard-lint fires on a planted .zbr CRLF write (clean 0 -> planted 1)" ;;
            0) bad "hazard-lint did NOT fire on a planted hazard: $(last_out)" ;;
            *) bad "hazard-lint CRASHED (rc=$got) instead of reporting: $(last_out)" ;;
        esac

        # Leg B — blind one check and require a REFUSAL (rc=2), not a clean report.
        cp -p tools/hazard_lint.py "$OUT/hz.bak"
        $PY - <<'PYEOF'
import pathlib
p = pathlib.Path("tools/hazard_lint.py")
s = p.read_text(encoding="utf-8")
# Disable H1 by making its file-level guard unsatisfiable. This is what a real
# regression looks like: the check still exists, still runs, and finds nothing.
s = s.replace('    if ".zbr" not in text:\n        return []',
              '    if True:\n        return []', 1)
p.write_text(s, encoding="utf-8", newline="\n")
PYEOF
        got=$(run_rc $PY tools/hazard_lint.py)
        cp -p "$OUT/hz.bak" tools/hazard_lint.py
        case "$got" in
            2) pass "hazard-lint REFUSES to report when a check stops firing (blinded -> 2)" ;;
            0) bad "hazard-lint reported CLEAN with H1 disabled — its controls are not wired" ;;
            *) bad "hazard-lint gave rc=$got when blinded; expected 2 (refusal): $(last_out)" ;;
        esac
    fi
else
    note "hazard-lint: skipped (tools/hazard_lint.py not present)"
fi

# ── doc-lint: fires on a planted dangling reference ───────────────────────
# The realistic defect is a doc naming a tool that was renamed or deleted -- which is what
# D1 found five times in the append-only records on the day it was written.
if [ -f tools/doc_lint.py ]; then
    base=$(run_rc $PY tools/doc_lint.py --quiet)
    if [ "$base" -ne 0 ]; then
        note "doc-lint: skipped (already reports rc=$base on the UNPERTURBED tree)"
    else
        cp -p CLAUDE.md "$OUT/claude.bak"
        printf '\nSee `tools/planted_by_selfcheck.sh` for details.\n' >> CLAUDE.md
        got=$(run_rc $PY tools/doc_lint.py --quiet)
        cp -p "$OUT/claude.bak" CLAUDE.md
        case "$got" in
            1) pass "doc-lint catches a planted dangling tool reference (clean 0 -> 1)" ;;
            0) bad "doc-lint did NOT catch a planted dangling reference: $(last_out)" ;;
            *) bad "doc-lint CRASHED (rc=$got) instead of reporting: $(last_out)" ;;
        esac
    fi
else
    note "doc-lint: skipped (tools/doc_lint.py not present)"
fi

# ── honest inventory of what is NOT self-checked ─────────────────────────────
echo
echo "  NOT self-checked (no cheap falsification — do not read the above as full coverage):"
echo "    smoke            — 262 fixtures; a planted failure means editing the suite"
echo "    full_sweep       — falsifying it means corrupting the baseline (25+ min to re-run);"
echo "                       its EXAMPLES sibling IS falsified above and shares the code path"
echo "    divergence       — needs both compilers over the whole corpus (~20 min)"
echo "    runtime-module   — its own size/BUG-221 assertions are already adversarial"
echo "    check-mode       — carries a built-in failure when no asymmetry witness survives"
echo "    mutation_check   — hours per run; its OWN baseline control is the falsification"
echo "                       (it refuses to start on a red detector or a blind fingerprint)"

echo
if [ "$FAIL" -gt 0 ]; then
    printf '\033[31mgate self-check: %d gate(s) could NOT be shown to fail\033[0m\n' "$FAIL"
    exit 1
fi
printf '\033[32mgate self-check: every covered gate demonstrably fails on a planted defect\033[0m\n'
