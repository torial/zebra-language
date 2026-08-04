#!/usr/bin/env bash
# release_mode_check.sh — THE ONLY GATE THAT BUILDS WITH `--release`.
#
# WHY THIS EXISTS
# ---------------
# Every other gate in this repo builds in Debug. `zebra --release` is what users actually
# ship, and until 2026-08-03 it produced an **unoptimised binary** (BUG-228): the flag
# switched the backend to LLVM — a visible change, 20 MB to 2 MB — while the branch that
# emits the executable never passed an optimize flag, so Zig defaulted to Debug. Anyone
# shipping with the flag shipped Debug believing otherwise, which is the flag's whole
# purpose. Nineteen green gates could not see it, because none of them used the flag.
#
# WHAT IT ASSERTS
#   1. a `--release` build RUNS and prints the right answer  (optimisation must not change
#      behaviour — this is the half that matters most)
#   2. the release binary is materially SMALLER than the same program built without it
#
# THE SIZE ASSERTION IS SELF-CALIBRATING, and that is deliberate. It compares the two
# binaries built HERE, rather than checking against a recorded number. A hardcoded size
# rots on the next Zig release and then either fails for no reason or, worse, passes for
# no reason. What it really tests is "did the optimize flag reach zig at all" — and the
# regression it exists to catch, the flag silently going missing again, makes the two
# builds identical in size. Observed 2026-08-03: 813 KB release vs 1872 KB debug.
#
# Uses a 25% margin rather than an exact figure: enough that a lost `-O` flag cannot hide,
# loose enough to survive ordinary codegen drift.
#
# Not in the QUICK tier: it runs a full LLVM build. FULL tier / pre-release.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"
ZEBRA="$REPO/zig-out/bin/zebra.exe"

WORK="${TMP:-/tmp}"
command -v cygpath >/dev/null 2>&1 && WORK="$(cygpath -u "${TMP:-/tmp}")"
WORK="$WORK/zbr-relcheck"
rm -rf "$WORK"; mkdir -p "$WORK"

fail=0
say() { printf '  %-6s %s\n' "$1" "$2"; }

if [[ ! -x "$ZEBRA" ]]; then
    echo "REFUSING TO REPORT: $ZEBRA not built. A clean result would mean only that." >&2
    exit 2
fi

cat > "$WORK/rel.zbr" <<'EOF'
def main()
    var total = 0
    for i in 0:1000
        total = total + i
    print("sum=" + total.toString())
EOF

# ---- 1. behaviour: a release build must still be CORRECT -----------------------------
out="$(cd "$WORK" && timeout 600 "$ZEBRA" --release rel.zbr 2>&1)"
rc=$?
if [[ $rc -ne 0 ]]; then
    say FAIL "--release build did not complete (rc=$rc)"
    echo "$out" | tail -8 | sed 's/^/        /'
    fail=1
elif ! grep -qF -- "sum=499500" <<<"$out"; then
    say FAIL "--release build ran but printed the wrong answer"
    echo "$out" | tail -8 | sed 's/^/        /'
    fail=1
else
    say ok "--release builds and prints the correct result"
fi

# ---- 2. the optimize flag actually reached zig ----------------------------------------
#
# A SKIPPED SIZE CHECK IS A FAILURE, NOT A PASS. The first version of this gate could not
# locate either binary and printed "all checks pass" with its only real assertion never
# having run -- the exact vacuous-instrument shape the rest of this directory exists to
# prevent. If the artifacts cannot be found, this gate does not know anything and must say
# so.
#
# The executables land in the compiler's TEMP dir (TMP/TEMP on Windows), NOT in the cwd:
# `zebra --release x.zbr` writes `<temp>/x.zig.run.exe`. Deliberately NOT using
# --output-dir, because that is a DIFFERENT emit branch (see runtime_module_check) and the
# branch under test here is the plain one a user invokes.
ZTMP="${TMP:-${TEMP:-/tmp}}"
command -v cygpath >/dev/null 2>&1 && ZTMP="$(cygpath -u "$ZTMP")"
rel_exe="$ZTMP/rel.zig.run.exe"
rm -f "$ZTMP/rel.zig.fast.exe"
(cd "$WORK" && timeout 600 "$ZEBRA" rel.zbr >/dev/null 2>&1)
dbg_exe="$ZTMP/rel.zig.fast.exe"

if [[ ! -f "$rel_exe" ]]; then
    say FAIL "cannot find the --release binary at $rel_exe — the size check could not run, so this gate knows NOTHING about the optimize flag"
    fail=1
elif [[ ! -f "$dbg_exe" ]]; then
    say FAIL "cannot find the non-release binary at $dbg_exe — nothing to compare against"
    fail=1
else
    rs=$(stat -c %s "$rel_exe"); ds=$(stat -c %s "$dbg_exe")
    if [[ "$ds" -le 0 ]]; then
        say FAIL "reference build reported size 0 — the comparison cannot be trusted"
        fail=1
    elif [[ $(( rs * 100 / ds )) -gt 75 ]]; then
        say FAIL "release binary is $((rs/1024)) KB vs $((ds/1024)) KB unoptimised — the -O flag looks LOST (BUG-228)"
        fail=1
    else
        say ok "release binary $((rs/1024)) KB vs $((ds/1024)) KB unoptimised — optimize flag is reaching zig"
    fi
fi

echo
if [[ $fail -eq 0 ]]; then
    echo "release-mode: all checks pass"
    exit 0
fi
echo "release-mode: $fail check(s) FAILED" >&2
exit 1
