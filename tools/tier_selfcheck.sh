#!/usr/bin/env bash
# tier_selfcheck.sh — can the TIER MACHINERY in gates.sh still fail?
#
# `gate_selfcheck.sh` asks that question of the individual gates. This asks it of the
# thing that decides WHICH gates run, which arrived 2026-08-19 with the static/fast/
# quick/full/daily ladder. A selector is a new way to print green: filter wrongly and the
# board shows fewer PASSes and no failures, which reads exactly like success.
#
#   bash tools/tier_selfcheck.sh
#
# Every mutation is applied to a COPY, never to the real gates.sh: this repo regularly has
# two agents in one tree, and a half-mutated gate runner is precisely the artefact that
# makes someone else's run lie (the 2026-08-01 kill_orphans incident, in a new costume).
#
# THE PROBE HAS NO .sh EXTENSION ON PURPOSE. CLAUDE.md carries a live doc-gen oracle
# counting `ls tools/*.sh tools/*.py fuzz/*.py *.py`, so a probe named `.sh` turns
# `doc-lint` red BY EXISTING -- which is what failed this harness's own control the first
# time it ran. Same shape as the untracked working note that turned a shared gate red for
# everyone on 2026-08-01.
#
# WHAT IT CANNOT SEE: whether the CLASSIFICATION is right -- that `run_static` gates truly
# need no compiler. `_static_purity_check` inside gates.sh covers the cheap half of that
# statically; the real control is the experiment that established it, which is to hide
# zig-out/bin/zebra*.exe and run the static tier. Do that by hand when adding a static
# gate; all 12 must still pass.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
source "$REPO/tools/zig_toolchain.sh"   # the PINNED zig (.zig-version), not the shared ~/.zvm/bin default

PROBE=tools/zz_gates_probe
PASS=0; FAIL=0
# Every probe run records its passes in a PRIVATE store (gates.sh --resume, 2026-11-11):
# a probe must never write into, or resume from, the real ${ZBR_BS}-gates-resume.
RDIR="$(mktemp -d)"; KF="$RDIR/key"; MARK=tools/zz_resume_probe_marker
export GATES_RESUME_DIR="$RDIR/store"
trap 'rm -f "$PROBE" "$MARK"; rm -rf "$RDIR"' EXIT

fresh() { cp tools/gates.sh "$PROBE"; }

expect() {  # <name> <want-rc> <want-substring>   (the probe is already mutated)
    local name="$1" want_rc="$2" want="$3" out rc
    out=$(bash "$PROBE" --static 2>&1); rc=$?
    if [[ "$rc" == "$want_rc" ]] && echo "$out" | grep -qF "$want"; then
        printf '  ok    %-34s rc=%s, said "%s"\n' "$name" "$rc" "$want"
        PASS=$((PASS+1))
    else
        printf '  FAIL  %-34s rc=%s (wanted %s), looking for "%s"\n' "$name" "$rc" "$want_rc" "$want"
        echo "$out" | tail -6 | sed 's/^/          /'
        FAIL=$((FAIL+1))
    fi
}

# DERIVED, never written down -- see the note at the top of this block.
_NSTATIC=$(grep -cE '^[[:space:]]*(run|pin)_static "' "$REPO/tools/gates.sh")
if [ "${_NSTATIC:-0}" -lt 5 ]; then
    echo "tier-selfcheck: REFUSING — counted only ${_NSTATIC:-0} static gates in gates.sh;" \
         "the registration regex has stopped matching, so every expectation below would be" \
         "measuring nothing." >&2
    exit 2
fi

echo "tier self-check — each mutation on a copy of gates.sh (${_NSTATIC} static gates):"

# CONTROL 0 -- the UNMUTATED copy must pass. Without it, every mutation below could be
# "detected" for an unrelated reason (a broken copy, a bad path) and this suite would
# still look green: refusals would be observed, just not the ones claimed.
fresh
expect "control: unmutated copy passes" 0 "${_NSTATIC}/${_NSTATIC} PASS"

# M1 -- a build-dependent gate registered as static must be REFUSED, not run. This is the
# decay the static tier is actually exposed to: a lint that grows an emit-and-check leg.
fresh
sed -i 's|^run_fast "diag-columns"|run_static "diag-columns"|' "$PROBE"
expect "M1 impure gate tagged static" 2 "registered as static reference the compiler"

# M2 -- if the purity DETECTOR stops matching, it must refuse rather than report purity.
# THE MUTATION MUST DESTROY THE WHOLE PATTERN: the first version replaced only the
# 'zig-out' branch and left 'zebra.exe' in the alternation, which still matched the
# control tool -- so the guard correctly did not fire and the harness scored gates.sh a
# failure. A cooperative mutation proves nothing; break the thing itself.
fresh
sed -i "s|^    local pat=.*|    local pat='zzz_no_such_token_anywhere'|" "$PROBE"
expect "M2 purity control stops firing" 2 "static-purity control stopped firing"

# M3 -- if the per-tier counter collapses, the vacuity floor must refuse. Without it a
# broken derivation yields 0 expected, 0 actual, "0/0 PASS", exit 0.
fresh
sed -i 's|(run\|pin)_\$1 |(run\|pin)_zzz_$1 |' "$PROBE"
expect "M3 expectation collapses to zero" 2 "REFUSING"

# M4 -- a gate that silently does not run must surface as RAN N OF M rather than as a
# smaller, plausible-looking green board.
fresh
sed -i 's|^_run() {|_run() { if [[ "${2:-}" == "fallthrough" ]]; then return 0; fi;|' "$PROBE"
expect "M4 one gate silently skipped" 1 "RAN $((_NSTATIC - 1)) OF ${_NSTATIC}"

# M5 -- a PINNED gate that starts passing must FAIL the tier. A pin that has come good is
# a registration nobody updated, and it must not be able to outlive its bug.
fresh
sed -i 's|^run_daily()  { _PIN_TICKET=""; _run daily  "\$@"; }|&\npin_static() { local l="$1" t="$2"; shift 2; _PIN_TICKET="$t"; _run static "$l" "$@"; _PIN_TICKET=""; }|' "$PROBE"
sed -i 's|^run_static "hazard-lint"    "0 hazard"  python tools/hazard_lint.py|pin_static "hazard-lint" "BUG-000" "0 hazard" python tools/hazard_lint.py|' "$PROBE"
expect "M5 pinned gate that now passes" 1 "retire the pin"

# -- RESUME (2026-11-11) -------------------------------------------------------------
# `--resume` SKIPS gates, which makes it the most direct way yet for this runner to print
# green without checking anything. Each leg below is the attack it exists to stop. The
# probe is trimmed to two instant static gates so a leg costs one doctor run, and every
# leg writes its records into a private directory: probe runs must not resume each other,
# and must never touch the real ${ZBR_BS}-gates-resume store.
trim() {  # keep two instant static gates; the expectation is derived from the probe itself
    sed -i -E '/^run_static "(fallthrough|fn-twins)"/!{/^[[:space:]]*(run|pin)_static "/d}' "$PROBE"
    # The vacuity floor (10) guards the REAL tier; M3 tests it on an untrimmed copy.
    sed -i 's/^_floor=10;/_floor=2;/' "$PROBE"
}
trimq() { trim; sed -i -E '/^[[:space:]]*(run|pin)_(fast|quick|full|daily) "/d' "$PROBE"; }  # default tier = the same two gates
rexpect() {  # <name> <want-rc> <want-substring> <gates.sh args...>  (hooked key unless NOHOOK=1)
    local name="$1" want_rc="$2" want="$3" out rc; shift 3
    if [[ "${NOHOOK:-0}" == 1 ]]; then
        out=$(GATES_RESUME_DIR="$RDIR/store" bash "$PROBE" "$@" 2>&1); rc=$?
    else
        out=$(GATES_RESUME_DIR="$RDIR/store" GATES_RESUME_KEY_FILE="$KF" bash "$PROBE" "$@" 2>&1); rc=$?
    fi
    if [[ "$rc" == "$want_rc" ]] && echo "$out" | grep -qF "$want"; then
        printf '  ok    %-34s rc=%s, said "%s"\n' "$name" "$rc" "$want"
        PASS=$((PASS+1))
    else
        printf '  FAIL  %-34s rc=%s (wanted %s), looking for "%s"\n' "$name" "$rc" "$want_rc" "$want"
        echo "$out" | tail -8 | sed 's/^/          /'
        FAIL=$((FAIL+1))
    fi
}

# R0 CONTROL -- a clean run records, and --resume on the same key skips both gates.
fresh; trim; echo k1 > "$KF"
rexpect "R0 control: clean run records"     0 "2/2 PASS (static, 0 resumed)"            --static --resume
rexpect "R0 control: --resume skips both"   0 "2/2 PASS (static, 2 resumed)" --static --resume

# R1 -- a record for ANOTHER tree must not resume, and the run must say what differs.
echo k2 > "$KF"
rexpect "R1 stale key resumes nothing"      0 "(static, 0 resumed)"          --static --resume

# R2 -- a gate that FAILS after it once passed must lose its record. The failure is forced
# inside _run, so the registration (and hence the gate's own key) is unchanged: the record
# can only disappear because the failure removed it. It runs on the DEFAULT tier, which
# records without --resume: a forced failure under --resume would be skipped, not run.
fresh; trimq; echo k3 > "$KF"
rexpect "R2 setup: clean run records"       0 "2/2 PASS (quick)"
sed -i 's|^    local ok=0$|    local ok=0; [[ "$label" == "fallthrough" ]] \&\& rc=1|' "$PROBE"
rexpect "R2 setup: forced failure"          1 "FAILED"
fresh; trimq
rexpect "R2 failed gate is not resumed"     0 "2/2 PASS (quick, 1 resumed)"  --resume
# R3 -- a resumed gate must be COUNTED; a skip that is not counted is a gate that silently
# did not run, and RAN N OF M must catch it.
sed -i 's|PASSED=\$((PASSED + 1)); RESUMED=\$((RESUMED + 1))|RESUMED=$((RESUMED + 1))|' "$PROBE"
echo k1 > "$KF"
rexpect "R3 uncounted resume -> RAN N OF M" 1 "RAN 0 OF 2"                   --static --resume

# R4 -- the tree moves DURING the run: every record that run wrote is discarded, under the
# old key and the new one alike.
fresh; trim; echo k5 > "$KF"
sed -i 's|^run_static "fallthrough".*|&\necho k5b > "$GATES_RESUME_KEY_FILE"|' "$PROBE"
rexpect "R4 mid-run move is reported"       0 "tree CHANGED during this run" --static --resume
fresh; trim; echo k5b > "$KF"
rexpect "R4 no record under the new key"    0 "(static, 0 resumed)"          --static --resume
echo k5 > "$KF"
rexpect "R4 no record under the old key"    0 "(static, 0 resumed)"          --static --resume

# R5 -- a PINNED gate is never recorded: it must run on every resume.
fresh; trim; echo k6 > "$KF"
sed -i 's|^run_daily()  { _PIN_TICKET=""; _run daily  "\$@"; }|&\npin_static() { local l="$1" t="$2"; shift 2; _PIN_TICKET="$t"; _run static "$l" "$@"; _PIN_TICKET=""; }|' "$PROBE"
sed -i 's|^run_static "fallthrough".*|pin_static "fallthrough" "BUG-000" "zz_never_printed" python tools/lint_fallthrough.py|' "$PROBE"
rexpect "R5 setup: pin XFAILs"              0 "1/2 PASS (static, 0 resumed)"            --static --resume
rexpect "R5 pinned gate runs again"         0 "1/2 PASS (static, 1 resumed)" --static --resume

# R6 -- THE REAL KEY, no hook: an untracked file appearing is a different tree. Without this
# leg every check above could pass while _key_parts ignored the tree entirely.
fresh; trim; rm -f "$MARK"
NOHOOK=1 rexpect "R6 real key: clean run records"   0 "2/2 PASS (static, 0 resumed)"            --static --resume
echo "a different tree" > "$MARK"
NOHOOK=1 rexpect "R6 real key: untracked file moves it" 0 "differs in: untracked"    --static --resume
rm -f "$MARK"
NOHOOK=1 rexpect "R6 real key: same tree resumes"   0 "2/2 PASS (static, 2 resumed)" --static --resume

# R7 -- WHICH tiers record. --static without --resume must NOT record (the key costs more
# than the tier is worth restarting); the default tier must record without being asked, or
# the first red FULL leaves nothing to resume from. The probe's higher tiers are emptied so
# the default tier is the same two static gates.
fresh; trim; echo k7 > "$KF"
rexpect "R7 plain --static records nothing" 0 "2/2 PASS (static)"            --static
rexpect "R7 ...so --resume finds nothing"   0 "(static, 0 resumed)"          --static --resume
fresh; trimq; echo k8 > "$KF"
rexpect "R7 default tier records unasked"   0 "2/2 PASS (quick)"
rexpect "R7 ...and resumes"                 0 "2/2 PASS (quick, 2 resumed)"  --resume

echo
echo "tier self-check: $PASS ok, $FAIL FAILED"
[[ $FAIL -eq 0 ]] || exit 1
