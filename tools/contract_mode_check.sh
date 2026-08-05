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

# ── Emit-level legs ──────────────────────────────────────────────────────────
#
# The runtime legs above prove OBSERVABLE behaviour; these prove the MECHANISM is
# removal at emit rather than an optimiser happening to drop a branch. That is a
# much stronger guarantee: an optimiser-dependent one could come back at any Zig
# release.
#
# ALL FOUR COMBOS, not just plain-vs-turbo. The first version checked only the
# two that made the point most easily, which left the leg carrying the most
# weight in Sean's ruling -- that a plain `--release` build KEEPS its contracts --
# asserted by a panic alone. And the runtime classifier fails OPEN there: a
# non-zero exit with no sentinel is scored `fired`, so a release binary that
# crashed for an unrelated reason would pass while contracts were being stripped.
# The emit check is what closes that, so it has to cover the release legs too.
#
# `emit_count SRC OUT FLAGS...` -> occurrences of the contract string.
# Prints nothing on failure and returns non-zero: never a fallback VALUE, because
# a fallback on a path feeding a comparison always biases toward "nothing
# changed" (hazard H3).
emit_count() {
    local out="$1"; shift
    mkdir -p "$out" || return 1
    "$ZEBRA" "$@" --output-dir "$out" "$WORK/contract.zbr" >/dev/null 2>&1
    local f="$out/contract.zig"
    [ -f "$f" ] || return 1
    # `grep -c` already prints 0 for no-match AND exits 1, so `|| echo 0` would
    # append a SECOND zero -- the value became "0\n0" and `[` rejected it as
    # not-an-integer. Take the count, ignore the exit status.
    grep -c 'require failed' "$f" 2>/dev/null || true
}

emit_check() {
    local label="$1" want="$2" n="$3"
    CHECKS=$((CHECKS + 1))
    if [ -z "$n" ]; then
        printf '  FAIL  %-34s emit produced no .zig -- check is blind\n' "$label"
        FAILED=$((FAILED + 1)); return
    fi
    if { [ "$want" = present ] && [ "$n" -gt 0 ]; } || { [ "$want" = absent ] && [ "$n" -eq 0 ]; }; then
        printf '  ok    %-34s %s (n=%s)\n' "$label" "$want" "$n"
    else
        printf '  FAIL  %-34s want=%s got n=%s\n' "$label" "$want" "$n"
        FAILED=$((FAILED + 1))
    fi
}

echo "── mechanism: stripping happens at EMIT, not in the optimiser (selfhost)"
emit_check "default"           present "$(emit_count "$WORK/e1")"
emit_check "--release"         present "$(emit_count "$WORK/e2" --release)"
emit_check "--turbo"           absent  "$(emit_count "$WORK/e3" --turbo)"
emit_check "--release --turbo" absent  "$(emit_count "$WORK/e4" --release --turbo)"

# ── The OTHER compiler ───────────────────────────────────────────────────────
#
# Everything above drives zig-out/bin/zebra.exe. But `--gui-backend=*` DELEGATES
# to zebra-bootstrap.exe, so a GUI app built `--release --turbo` takes a path
# none of the legs above touch. Titling this file "the contract-stripping
# contract" while asserting it for one of two compilers is the same over-read
# that let BUG-228 sit under green gates.
#
# The bootstrap does NOT accept --output-dir (and does not list --turbo in
# --help), so these go through --emit-zig to stdout, which is also why they cost
# no build at all.
BOOT="zig-out/bin/zebra-bootstrap.exe"
boot_count() {
    local f="$WORK/boot.$CHECKS.zig"
    "$BOOT" --emit-zig "$@" "$WORK/contract.zbr" > "$f" 2>/dev/null || return 1
    [ -s "$f" ] || return 1
    grep -c 'require failed' "$f" 2>/dev/null || true
}
if [ -x "$BOOT" ]; then
    echo "── mechanism: the BOOTSTRAP honours --turbo too (the --gui-backend path)"
    emit_check "bootstrap default" present "$(boot_count)"
    emit_check "bootstrap --turbo" absent  "$(boot_count --turbo)"
else
    echo "  FAIL  bootstrap not built -- cannot assert the --gui-backend path"
    FAILED=$((FAILED + 1)); CHECKS=$((CHECKS + 2))
fi

echo
# A skipped or vacuous run is a FAILURE, not a pass -- release_mode_check.sh
# shipped once printing "all checks pass" with its only real assertion never
# having run.
EXPECTED=13
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
