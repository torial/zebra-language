#!/usr/bin/env bash
# release_mode_check.sh — THE ONLY GATE THAT BUILDS WITH `--release`.
# pins: BUG-468 the stack-overflow legs -- a --release program must print "Stack overflow" in both runtime shapes.
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
source "$REPO/tools/zig_toolchain.sh"   # the PINNED zig (.zig-version), not the shared ~/.zvm/bin default
ZEBRA="$REPO/zig-out/bin/zebra.exe"
# Linux/macOS build `zebra`, not `zebra.exe` (CI quick-linux, 2026-09-26): use it when the .exe is absent.
[ -x "$ZEBRA" ] || [ ! -x "${ZEBRA%.exe}" ] || ZEBRA="${ZEBRA%.exe}"

# A PRIVATE temp dir for every compile this gate runs (BUG-513). A plain `zebra x.zbr`
# writes `<TEMP>/x.zig` and the shared `<TEMP>/zebra_rt.zig`, so any other zebra running on
# the machine at the same time -- another tier, another session's regen -- could rewrite
# them mid-build. That is the shape of this gate's two non-reproducing reds (2026-09-18,
# 2026-10-01, the second while an engine regen ran beside it); CLAUDE.md said a second one
# should make the path unique before anything else.
_PRIV="$(mktemp -d)"
trap 'rm -rf "$_PRIV"' EXIT
if command -v cygpath >/dev/null 2>&1; then export TMP="$(cygpath -w "$_PRIV")"; else export TMP="$_PRIV"; fi
export TEMP="$TMP"
export TMPDIR="$_PRIV"
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
out="$(cd "$WORK" && timeout 600 "$ZEBRA" --keep-temp --release rel.zbr 2>&1)"
rc=$?
if [[ $rc -ne 0 ]]; then
    say FAIL "--release build did not complete (rc=$rc)"
    echo "$out" | tail -8 | sed 's/^/        /'
    fail=$((fail + 1))
elif ! grep -qF -- "sum=499500" <<<"$out"; then
    say FAIL "--release build ran but printed the wrong answer"
    echo "$out" | tail -8 | sed 's/^/        /'
    fail=$((fail + 1))
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
#
# `--keep-temp` IS passed, and it has to be: since BUG-244 the compiler REMOVES its scratch
# build after a clean run, so this gate would find nothing and correctly report that it
# knows nothing about the optimize flag. Before that fix it was silently relying on a
# 20 MB-per-run leak to leave its evidence lying around. Asking for what it needs is the
# honest version of the same dependency, and it keeps the branch under test the plain one.
# BUG-513: each run builds in its OWN scratch directory and, under --keep-temp, NAMES it
# ("note: the scratch build is kept in DIR"). The binaries are found there -- asked of the
# compiler, never guessed -- and both directories are removed at the end.
kept_dir() { sed -n 's/^note: the scratch build is kept in //p' | tail -1 | tr -d '\r'; }
rel_dir="$(printf '%s\n' "$out" | kept_dir)"
dbg_out="$(cd "$WORK" && timeout 600 "$ZEBRA" --keep-temp rel.zbr 2>&1)"
dbg_dir="$(printf '%s\n' "$dbg_out" | kept_dir)"
if command -v cygpath >/dev/null 2>&1; then
    [ -n "$rel_dir" ] && rel_dir="$(cygpath -u "$rel_dir")"
    [ -n "$dbg_dir" ] && dbg_dir="$(cygpath -u "$dbg_dir")"
fi
rel_exe="$rel_dir/rel.zig.run.exe"
dbg_exe="$dbg_dir/rel.zig.fast.exe"
# (a run that names no directory leaves rel_exe/dbg_exe pointing nowhere, and the existing
# "cannot find the binary" checks below fail loudly; the private TMP's trap removes both)

if [[ ! -f "$rel_exe" ]]; then
    say FAIL "cannot find the --release binary at $rel_exe — the size check could not run, so this gate knows NOTHING about the optimize flag"
    fail=$((fail + 1))
elif [[ ! -f "$dbg_exe" ]]; then
    say FAIL "cannot find the non-release binary at $dbg_exe — nothing to compare against"
    fail=$((fail + 1))
else
    rs=$(stat -c %s "$rel_exe"); ds=$(stat -c %s "$dbg_exe")
    if [[ "$ds" -le 0 ]]; then
        say FAIL "reference build reported size 0 — the comparison cannot be trusted"
        fail=$((fail + 1))
    elif [[ $(( rs * 100 / ds )) -gt 75 ]]; then
        say FAIL "release binary is $((rs/1024)) KB vs $((ds/1024)) KB unoptimised — the -O flag looks LOST (BUG-228)"
        fail=$((fail + 1))
    else
        say ok "release binary $((rs/1024)) KB vs $((ds/1024)) KB unoptimised — optimize flag is reaching zig"
    fi
fi

# ── BUG-313: indexing must REFUSE out of range, in a --release build ─────────────────────
# This is the only gate that passes --release, and it is the only place this can be tested:
# `.at()` lowered to raw slice indexing, which Zig checks in Debug and ReleaseSafe and NOT
# in ReleaseFast. So the defect was INVISIBLE to every other gate in every tier -- they all
# build Debug -- and a shipped build read out of bounds, invented a value, and carried on.
#
# TWO DOORS, and a fix that closes one leaves the other open: an index past the end, and a
# NEGATIVE index wrapping through the @intCast that converts Zebra's int to usize.
#
# CLASSIFIED ON THE PANIC TEXT, never on exit code alone -- a build failure also exits
# non-zero, and scoring that as "the check fired" would make a broken compiler look like a
# working guard (the same argument contract_mode_check makes for its sentinel).
_idx_probe() {   # $1 = label, $2 = zebra source
    local out
    out="$("$ZEBRA" --release "$2" 2>&1)"
    if printf '%s' "$out" | grep -q "index out of range"; then
        say ok "$1 refused in --release"
    else
        say FAIL "$1 was NOT refused in --release -- an out-of-range read returned a fabricated value"
        printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
        fail=$((fail + 1))
    fi
}

_idx_dir="$(mktemp -d)"
cat > "$_idx_dir/past_end.zbr" <<'ZBR'
def main()
    var xs = List(int)()
    xs.add(10)
    xs.add(20)
    var i = xs.len          # 2 -- one past the last valid index, computed at RUNTIME
    var v = xs.at(i)
    print("SURVIVED past-the-end: ${v}")
ZBR
cat > "$_idx_dir/negative.zbr" <<'ZBR'
def main()
    var xs = List(int)()
    xs.add(10)
    xs.add(20)
    var i = xs.len - 3      # -1 -- a Python reflex; here it wraps through the @intCast
    var v = xs.at(i)
    print("SURVIVED negative: ${v}")
ZBR
cat > "$_idx_dir/in_range.zbr" <<'ZBR'
def main()
    var xs = List(int)()
    xs.add(10)
    xs.add(20)
    print("in-range ok: ${xs.at(1)}")
ZBR

_idx_probe "index past the end" "$_idx_dir/past_end.zbr"
_idx_probe "negative index"     "$_idx_dir/negative.zbr"

# CONTROL. Without it, a compiler that refused EVERY index would pass both probes above --
# "it panics" is not the same claim as "it panics when it should".
if "$ZEBRA" --release "$_idx_dir/in_range.zbr" 2>&1 | grep -q "in-range ok: 20"; then
    say ok "in-range indexing still works in --release"
else
    say FAIL "in-range indexing BROKE in --release -- the check is refusing valid reads"
    fail=$((fail + 1))
fi
rm -rf "$_idx_dir"

# ── BUG-468: a --release binary must SAY it overflowed its stack ─────────────────────────
# ReleaseFast turns Zig's crash handler off, so a shipped program that recursed too deep
# died SILENTLY -- no message, a raw OS status -- while its Debug build printed "Stack
# overflow". The runtime now sets `std_options.enable_segfault_handler = true` (measured
# ~1% on a CPU-bound interpreter, +2 KB). Both runtime shapes, because they get the option
# from different places: the inline shape from the preamble in its root file, the module
# shape from a re-export in the root. Classified on the TEXT; the `start` sentinel proves
# the program ran (a build failure prints neither). Red-checked against rc4: silent.
# THE PROBE MUST NOT ALLOCATE (2026-10-03). It used a per-frame list (`pad`) to stop LLVM
# turning the recursion into a loop; under Zig 0.17 the frames got small enough that the
# HEAP ran out first and the program printed `panic: OOM` -- this leg went red on a probe
# that no longer overflowed its stack, while the handler was fine. A NON-associative step
# (`* 3 + n`, mod) defeats the accumulator transform without touching the heap. Red-checked
# again with the handler switched off in the preamble: silent, FAIL.
_so_dir="$(mktemp -d)"
cat > "$_so_dir/deep.zbr" <<'ZBR'
def down(n: int): int
    if n < 1
        return 0
    return (down(n - 1) * 3 + n) % 1000003

def main()
    print("start")
    print(down(100000000))
ZBR
for _so_shape in "" "--single-file"; do
    _so_out="$("$ZEBRA" --release $_so_shape "$_so_dir/deep.zbr" 2>&1)"
    if printf '%s' "$_so_out" | grep -q "^start" && printf '%s' "$_so_out" | grep -q "Stack overflow"; then
        say ok "stack overflow reported in --release ${_so_shape:-(module shape)}"
    else
        say FAIL "stack overflow NOT reported in --release ${_so_shape:-(module shape)} -- a shipped binary dies silently (BUG-468)"
        printf '%s\n' "$_so_out" | tail -3 | sed 's/^/      /'
        fail=$((fail + 1))
    fi
done
# CONTROL: the handler must not disturb a program that does not crash.
cat > "$_so_dir/shallow.zbr" <<'ZBR'
def down(n: int): int
    if n < 1
        return 0
    return down(n - 1) + 1

def main()
    print("depth ok: ${down(1000)}")
ZBR
if "$ZEBRA" --release "$_so_dir/shallow.zbr" 2>&1 | grep -q "depth ok: 1000"; then
    say ok "shallow recursion unaffected in --release"
else
    say FAIL "a NON-crashing --release program misbehaved with the crash handler installed"
    fail=$((fail + 1))
fi
rm -rf "$_so_dir"

# ── BUG-451: a GUI program's --release must reach ITS build too ──────────────────────────
# GUI programs do not go through `zig build-exe`: they are scaffolded into a small zig
# project and built with `zig build`, whose build.zig reads standardOptimizeOption. Nothing
# passed it one, so every `--release --gui-backend=...` binary was Debug -- the BUG-228
# shape again, in the one path this gate did not build. Same self-calibrating comparison as
# leg 2: two builds of one program, one with the flag. libui_ng backend (tui, which needed no
# native toolkit, was dropped with the Zig 0.17 move: zigzag has no 0.17 support).
# `-c --check-full` builds without launching the app (BUG-439).
_gui_dir="$(mktemp -d)"
_gui_build() {   # $1 = subdir, $2.. = extra flags; prints the app's size, or nothing
    mkdir -p "$_gui_dir/$1"
    (cd "$_gui_dir/$1" && timeout 900 "$ZEBRA" -c --check-full "${@:2}" --gui-backend=libui_ng \
        --output-dir . "$REPO/examples/counter.zbr" >build.log 2>&1)
    local app
    for app in "$_gui_dir/$1/counter_gui_libui_ng/zig-out/bin/app.exe" "$_gui_dir/$1/counter_gui_libui_ng/zig-out/bin/app"; do
        [[ -f "$app" ]] && { stat -c %s "$app"; return; }
    done
}
g_dbg="$(_gui_build dbg)"
g_rel="$(_gui_build rel --release)"
if [[ -z "$g_dbg" || -z "$g_rel" ]]; then
    say FAIL "GUI (libui_ng) build produced no app (debug='$g_dbg' release='$g_rel') -- the GUI size check could not run, so this gate knows NOTHING about GUI --release"
    tail -5 "$_gui_dir/rel/build.log" 2>/dev/null | sed 's/^/        /'
    fail=$((fail + 1))
elif [[ $(( g_rel * 100 / g_dbg )) -gt 75 ]]; then
    say FAIL "GUI release app is $((g_rel/1024)) KB vs $((g_dbg/1024)) KB without --release -- the optimize flag does not reach the GUI build (BUG-451)"
    fail=$((fail + 1))
else
    say ok "GUI (libui_ng) release app $((g_rel/1024)) KB vs $((g_dbg/1024)) KB -- --release reaches the GUI build"
fi
rm -rf "$_gui_dir"


echo
if [[ $fail -eq 0 ]]; then
    echo "release-mode: all checks pass"
    exit 0
fi
echo "release-mode: $fail check(s) FAILED" >&2
exit 1
