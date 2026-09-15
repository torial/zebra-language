#!/usr/bin/env bash
# regen_recover.sh — THE RECOVERY PATH once the bootstrap is gone (bootstrap_sunset.md Step 0).
#
#   bash tools/regen_recover.sh              # report: what a compiler built from the COMMITTED
#                                            #   selfhost/*.zig emits for the working tree's *.zbr,
#                                            #   diffed against the working tree's *.zig
#   bash tools/regen_recover.sh --install    # ... and install that emit over selfhost/*.zig
#   bash tools/regen_recover.sh --gate       # exit 1 unless the diff is empty (a clean tree)
#   bash tools/regen_recover.sh --from REV   # use REV's selfhost/*.zig instead of HEAD's
#
# WHY THIS EXISTS
# ---------------
# Every day the compiler regenerates itself from itself (rebuild.sh, N-1 since 2026-08-30):
# the zebra.exe built from the COMMITTED selfhost/*.zig re-emits selfhost/*.zbr. That loop
# has one failure mode the bootstrap used to cover: a zebra.exe that cannot compile its own
# source -- a bad edit to CodeGen.zbr that was regenerated INTO the .zig, then built, then
# run. The bootstrap (src/, a second compiler in Zig) could always re-emit the .zbr from
# scratch. When it is retired, THIS is what covers that case, and it is stronger than the
# bootstrap in one way: it works for ANY commit in history, not just the one the bootstrap
# was frozen at.
#
# The mechanism is the observation that the committed selfhost/*.zig ARE the previous
# generation of the compiler in source form, and `zig build-exe selfhost/main.zig` builds a
# compiler from them with no Zebra compiler in the loop (bootstrap_check.sh Step 2 does
# exactly this from /tmp/bs-zig). So:
#
#   1. take selfhost/*.zig from git (HEAD, or --from REV) into a scratch tree OUTSIDE the
#      repo (tools/kill_orphans.sh and doctor --fix sweep scratch under $REPO);
#   2. zig build-exe them → zebra-recover;
#   3. zebra-recover --emit-zig --output-dir <scratch> selfhost/main.zbr (the WORKING tree's
#      sources, whatever state they are in);
#   4. diff that emit against the working tree's selfhost/*.zig.
#
# On a clean tree the diff is EMPTY -- that is the round-trip fixed point restated from git
# rather than from zig-out, and --gate asserts it (daily tier). On a broken tree the emit is
# the regenerated set, and --install puts it in place; then `zig build` gives a working
# zebra.exe again. The recipe in CLAUDE.md is one line: "if zebra.exe cannot build itself,
# run tools/regen_recover.sh --install, then zig build".
#
# RED-CHECKED 2026-09-15 on torial: an un-regenerated `def rrProbe()` appended to Token.zbr
# → "differs: selfhost/Token.zig (6 lines)", FAIL. Green from HEAD, from 74aab4e and from
# the rc2 commit 62b4387 -- three weeks of codegen changes re-emit the compiler's own
# sources byte-identically, which is its own small receipt for how conservative a subset
# the selfhost is written in.
#
# Every module present and NON-EMPTY before anything is installed (the zero-byte-emit
# hazard bootstrap_check.sh Step 1 guards against), and --install moves files only after
# all of them exist, so an interrupted run never touches the checked-in set.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO" || exit 2

MODE=report
REV=HEAD
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) MODE=install ;;
        --gate)    MODE=gate ;;
        --from)    REV="${2:?--from needs a revision}"; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "regen_recover: unknown argument '$1'" >&2; exit 2 ;;
    esac
    shift
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "regen_recover: REFUSING -- not a git worktree (the committed *.zig are the point)" >&2; exit 2; }
git rev-parse --verify -q "$REV^{commit}" >/dev/null \
    || { echo "regen_recover: REFUSING -- '$REV' is not a commit" >&2; exit 2; }
command -v zig >/dev/null || { echo "regen_recover: zig not on PATH" >&2; exit 2; }

EXE=""; [[ "$(uname -s)" != Linux && "$(uname -s)" != Darwin ]] && EXE=.exe
SCRATCH="$(cd "$REPO/.." && pwd)/zebra-recover"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/src" "$SCRATCH/emit"

FILES=$(grep -m1 '^FILES=(' "$SCRIPT_DIR/bootstrap_check.sh" | sed 's/^FILES=(//; s/)$//')
[[ -n "$FILES" ]] || { echo "regen_recover: could not read FILES from bootstrap_check.sh" >&2; exit 2; }

echo "── 1. selfhost/*.zig at $(git rev-parse --short "$REV") → $SCRATCH/src"
# The emitted set is self-contained (main + deps + zebra_rt); the GUI section files are
# @embedFile'd by the runtime, so take every .zig under selfhost/ at REV.
git archive "$REV" selfhost | tar -x -C "$SCRATCH/src" || { echo "regen_recover: git archive failed" >&2; exit 2; }
for f in $FILES zebra_rt; do
    [[ -s "$SCRATCH/src/selfhost/$f.zig" ]] || { echo "regen_recover: $f.zig missing or empty at $REV" >&2; exit 2; }
done

echo "── 2. zig build-exe → zebra-recover (no Zebra compiler in the loop)"
FAST_FLAGS=""; [[ "${FAST_BACKEND:-0}" == 1 ]] && FAST_FLAGS="-fno-llvm -fno-lld"
if ! zig build-exe "$SCRATCH/src/selfhost/main.zig" -femit-bin="$SCRATCH/zebra-recover$EXE" $FAST_FLAGS 2>"$SCRATCH/build.err"; then
    echo "FAIL: the committed selfhost/*.zig at $REV do not build:" >&2
    head -20 "$SCRATCH/build.err" >&2
    exit 1
fi

echo "── 3. zebra-recover --emit-zig selfhost/main.zbr (the WORKING tree's sources)"
if ! "$SCRATCH/zebra-recover$EXE" --emit-zig --output-dir "$SCRATCH/emit" selfhost/main.zbr >/dev/null 2>"$SCRATCH/emit.err"; then
    echo "FAIL: the recovered compiler refused the working tree's selfhost/*.zbr:" >&2
    grep -aiE 'error|panic' "$SCRATCH/emit.err" | head -5 >&2
    exit 1
fi
for f in $FILES zebra_rt; do
    [[ -s "$SCRATCH/emit/$f.zig" ]] || { echo "FAIL: $f.zig missing or empty after the recovered emit -- refusing" >&2; exit 1; }
done

echo "── 4. diff against the working tree's selfhost/*.zig"
changed=()
for f in $FILES zebra_rt; do
    if ! cmp -s "$SCRATCH/emit/$f.zig" "selfhost/$f.zig"; then
        changed+=("$f")
        echo "  differs: selfhost/$f.zig ($(diff "selfhost/$f.zig" "$SCRATCH/emit/$f.zig" | grep -c '^[<>]') lines)"
    fi
done

if [[ ${#changed[@]} -eq 0 ]]; then
    echo "regen_recover: PASS -- a compiler built from $(git rev-parse --short "$REV")'s selfhost/*.zig re-emits the working tree byte-for-byte"
    exit 0
fi
case "$MODE" in
    gate)
        echo "regen_recover: FAIL -- ${#changed[@]} module(s) differ (${changed[*]}); on a clean tree this must be empty" >&2
        exit 1 ;;
    install)
        for f in "${changed[@]}"; do cp "$SCRATCH/emit/$f.zig" "selfhost/$f.zig"; done
        echo "regen_recover: installed ${#changed[@]} regenerated module(s): ${changed[*]}"
        echo "  now: zig build   (then bash tools/gates.sh)"
        exit 0 ;;
    *)
        echo "regen_recover: ${#changed[@]} module(s) would change (${changed[*]}); --install to apply, --gate to fail on this"
        exit 0 ;;
esac
