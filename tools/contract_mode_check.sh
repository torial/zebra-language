#!/usr/bin/env bash
# contract_mode_check.sh — THE CONTRACT-STRIPPING CONTRACT.
#
# Asserts the four-way matrix of --release x --turbo, which is a BEHAVIOUR
# promise the language makes and that no other gate touches:
#
#   | flags               | require/ensure/invariant | assert  |
#   |---------------------|--------------------------|---------|
#   | (none)              | fire                     | fires   |
#   | --release           | FIRE                     | fires   |
#   | --turbo             | stripped                 | FIRES   |
#   | --release --turbo   | stripped                 | FIRES   |
#
# WHY THIS EXISTS. Three separate reasons, each with a receipt:
#
#  1. `--turbo` is named in docs/testing_strategy.md as "a genuinely under-tested
#     path". Nothing in any tier passed the flag until this file.
#
#  2. BUG-257: docs/testing_strategy.md asserted "--turbo strips them, so release
#     builds are unaffected", which does not follow — the flags are independent.
#     Nobody could catch that because nothing asserted what either flag did.
#     A documented behaviour with no test is a claim, not a feature.
#
#  3. BUG-228 is the precedent for how this regresses: `--release` switched the
#     backend to LLVM but passed no -O for four days under 19 green gates,
#     because no gate used the flag. A flag that no gate passes is a flag whose
#     behaviour is unverified by construction.
#
# THE ASYMMETRY IS THE POINT. It would be easy to write this as "contracts off in
# release" and have it pass — that was the documented (and wrong) belief. What is
# asserted here is that `--release` ALONE still fires contracts, and that `assert`
# survives `--turbo`. Both are checks that a plausible "optimisation" would break,
# and neither would be missed by anything else.
#
# NOT a size check — release_mode_check.sh owns that and self-calibrates.
set -uo pipefail
cd "$(dirname "$0")/.."
ZEBRA="zig-out/bin/zebra.exe"
[ -x "$ZEBRA" ] || { echo "contract-mode: $ZEBRA not built"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAILED=0
CHECKS=0

# A contract that is violated on the second call, and an assert that is violated
# after it. Both AFTER a successful print, so "reached the end" is observable and
# distinguishable from "never started" -- a program that fails to launch would
# otherwise look identical to one whose checks were stripped.
cat > "$WORK/contract.zbr" <<'ZBR'
class Halver
    def half(n: int): int
        require
            n % 2 == 0
        return n / 2

def main()
    var h = Halver()
    print(h.half(4))
    print(h.half(5))
    print("NO-CONTRACT")
ZBR

cat > "$WORK/assert.zbr" <<'ZBR'
def main()
    var n: int = 5
    print(n)
    assert n % 2 == 0, "n must be even"
    print("NO-ASSERT")
ZBR

# run SRC FLAGS -> echoes "fired" or "stripped".
#
# Decided by the SENTINEL the program prints past the check, never by exit code
# alone: a build failure also exits non-zero, and scoring that as "the contract
# fired" would make a broken compiler look like a working guard. If the build
# itself fails we say so and fail loudly rather than classifying.
run_mode() {
    local src="$1"; shift
    local sentinel="$1"; shift
    local out rc dir
    # --output-dir requires the directory to EXIST; the compiler panics with a
    # bare "File.write error" if it does not, which is indistinguishable from a
    # codegen crash. A fresh dir per run also keeps one mode's output from being
    # mistaken for the next one's.
    dir="$WORK/out.$$.$CHECKS"; mkdir -p "$dir"
    out="$("$ZEBRA" "$@" --output-dir "$dir" "$src" 2>&1)"; rc=$?
    if ! printf '%s' "$out" | grep -q "wrote "; then
        printf 'BUILD-FAILED'
        return
    fi
    if printf '%s' "$out" | grep -q "$sentinel"; then
        printf 'stripped'
    elif [ "$rc" -ne 0 ]; then
        printf 'fired'
    else
        printf 'INCONCLUSIVE'
    fi
}

check() {
    local label="$1" want="$2" got="$3"
    CHECKS=$((CHECKS + 1))
    if [ "$got" = "$want" ]; then
        printf '  ok    %-34s %s\n' "$label" "$got"
    else
        printf '  FAIL  %-34s want=%s got=%s\n' "$label" "$want" "$got"
        FAILED=$((FAILED + 1))
    fi
}

echo "── contracts (require/ensure/invariant)"
check "default"           fired    "$(run_mode "$WORK/contract.zbr" NO-CONTRACT)"
check "--release"         fired    "$(run_mode "$WORK/contract.zbr" NO-CONTRACT --release)"
check "--turbo"           stripped "$(run_mode "$WORK/contract.zbr" NO-CONTRACT --turbo)"
check "--release --turbo" stripped "$(run_mode "$WORK/contract.zbr" NO-CONTRACT --release --turbo)"

echo "── assert (must SURVIVE --turbo)"
check "default"           fired "$(run_mode "$WORK/assert.zbr" NO-ASSERT)"
check "--turbo"           fired "$(run_mode "$WORK/assert.zbr" NO-ASSERT --turbo)"
check "--release --turbo" fired "$(run_mode "$WORK/assert.zbr" NO-ASSERT --release --turbo)"

# Emit-level confirmation. The runtime legs above prove the OBSERVABLE behaviour;
# this proves the mechanism is removal-at-emit rather than an optimiser happening
# to drop a branch -- which would be a much weaker guarantee and could come back
# at any Zig release.
echo "── mechanism: stripping happens at EMIT, not in the optimiser"
mkdir -p "$WORK/e1" "$WORK/e2"
"$ZEBRA" --output-dir "$WORK/e1" "$WORK/contract.zbr" >/dev/null 2>&1
"$ZEBRA" --turbo --output-dir "$WORK/e2" "$WORK/contract.zbr" >/dev/null 2>&1
# NOTE: no `|| echo 0` here. `grep -c` ALREADY prints 0 when it matches nothing,
# and also exits 1 -- so the fallback appended a SECOND zero and the value became
# the two-line string "0\n0", which `[` then rejected as not-an-integer. A
# fallback on a path feeding a comparison is the H3 hazard; here it did not even
# have the decency to be silent.
n_plain=$(grep -c 'require failed' "$WORK/e1"/contract.zig 2>/dev/null); n_plain=${n_plain:-0}
n_turbo=$(grep -c 'require failed' "$WORK/e2"/contract.zig 2>/dev/null); n_turbo=${n_turbo:-0}
CHECKS=$((CHECKS + 1))
if [ "$n_plain" -gt 0 ] && [ "$n_turbo" -eq 0 ]; then
    printf '  ok    %-34s plain=%s turbo=%s\n' "emitted zig contains contract" "$n_plain" "$n_turbo"
else
    # n_plain==0 means the POSITIVE CONTROL failed: we could not find the contract
    # even without --turbo, so a zero under --turbo proves nothing.
    printf '  FAIL  %-34s plain=%s turbo=%s%s\n' "emitted zig contains contract" \
           "$n_plain" "$n_turbo" \
           "$([ "$n_plain" -eq 0 ] && printf '  (positive control did not fire -- check is blind)')"
    FAILED=$((FAILED + 1))
fi

echo
# A skipped or vacuous run is a FAILURE, not a pass -- release_mode_check.sh
# shipped once printing "all checks pass" with its only real assertion never
# having run.
EXPECTED=8
if [ "$CHECKS" -ne "$EXPECTED" ]; then
    printf 'contract-mode: RAN %d OF %d checks -- refusing to report\n' "$CHECKS" "$EXPECTED"
    exit 1
fi
if [ "$FAILED" -eq 0 ]; then
    printf 'contract-mode: %d/%d checks pass\n' "$CHECKS" "$EXPECTED"
    exit 0
fi
printf 'contract-mode: %d of %d checks FAILED\n' "$FAILED" "$EXPECTED"
exit 1
