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
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

PROBE=tools/zz_gates_probe
PASS=0; FAIL=0
trap 'rm -f "$PROBE"' EXIT

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

echo
echo "tier self-check: $PASS ok, $FAIL FAILED"
[[ $FAIL -eq 0 ]] || exit 1
