#!/usr/bin/env bash
# pins: BUG-264 the round trip IS the regression test. StrSet is not a user-facing type
# (a bare `StrSet()` in user code is "undefined name"), so no test/*.zbr can express
# this -- the compiler's own source is the fixture, and selfhost/CodeGen.zbr carries
# two module-scope StrSets again precisely so this stays covered.
# bootstrap_check.sh — verify selfhost round-trip and level-2 fixed point.
#
# BLIND SPOT (important): this checks SELF-CONSISTENCY, not correctness. It diffs the
# selfhost against itself, so it cannot see (1) wrong-but-still-valid Zig (both passes
# share the bend → identical wrong output, clean diff), nor (2) any program it never
# compiles (the test corpus, ad-hoc probes). To check that emitted Zig actually
# COMPILES, run the independent witness:  JOBS=3 bash tools/compile_check.sh
# (See CLAUDE.md "Verification gates" for the full picture.)
#
# Usage:
#   tools/bootstrap_check.sh           # full 5-step round-trip (commit gate)
#   tools/bootstrap_check.sh --quick   # stop after step 2 (iterative rebuild)
#   tools/bootstrap_check.sh --update  # steps 1+2, then update selfhost/*.zig
#
# What it does (full mode):
#   1. Regenerates all selfhost .zig files from the Zig-compiled zebra into
#      /tmp/bs-zig (leaving selfhost/*.zig untouched at this stage).
#   2. Builds zebra-selfhost-A.exe from /tmp/bs-zig.
#   3. Has A re-emit every module into /tmp/bs-A/<mod>/ (one dir per root, so a
#      later root's deps cannot clobber an earlier root's emit).
#   4. Builds zebra-selfhost-B.exe from A's OWN emit (/tmp/bs-A/main/) — that is
#      what makes it level-2; building from the committed .zig would just rebuild A.
#   5. Has B re-emit the same way; diffs /tmp/bs-A against /tmp/bs-B.
#
# Quick mode runs only steps 1+2 and exits. Use it for iterative work after
# editing selfhost/*.zbr — you get a fresh zebra-selfhost.exe in ~10s without
# the A/B round-trip. selfhost/*.zig is never touched in quick mode, so the
# working tree stays clean. Run full mode before commit.
#
# Update mode (--update) runs steps 1+2 then uses zebra-bootstrap.exe (the
# authoritative Zig-compiled compiler) to re-emit all selfhost/*.zig in place.
# Equivalent to `zig build update-selfhost`.
# Use after editing selfhost/*.zbr when you need zebra.exe to reflect the
# changes: run --update, then `zig build`.
# Like full mode, --update snapshots selfhost/*.zig before writing and restores
# on any failure, so a partial emit never leaves the working tree in a mixed state.
#
# Why bootstrap, not selfhost-A? Using selfhost-A to regenerate itself is
# chicken-and-egg: a codegen bug in selfhost/CodeGen.zbr would cause selfhost-A
# to reproduce that same bug in the output .zig files, making it impossible to
# fix without bypassing the step manually.  Bootstrap is the ground truth;
# selfhost-A's correctness is tested by the full round-trip (steps 3-5).
#
# Why these flags exist: running `zebra --emit-zig selfhost/X.zbr` manually and
# copying into selfhost/X.zig mixes emit shapes (root vs dep), causing runtime
# crashes. Always regenerate the whole set; --update is the safe, fast path.
#
# Prerequisites: zig build has already produced zig-out/bin/zebra.exe.
#
# Safety: in full mode, selfhost/*.zig is snapshotted at start; on ERR/INT
# the snapshot is restored so a failed bootstrap never leaves the working
# tree in half-emitted state. A successful full run leaves selfhost/*.zig
# in the deterministic selfhost-B-emitted fixed point. Quick mode never
# writes to selfhost/.

set -euo pipefail

QUICK=0
UPDATE=0
for arg in "$@"; do
    case "$arg" in
        --quick)  QUICK=1 ;;
        --update) QUICK=1; UPDATE=1 ;;
        -h|--help)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *)
            echo "bootstrap_check: unknown argument: $arg" >&2
            echo "  usage: $0 [--quick | --update]" >&2
            exit 2
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

# N-1 BOOTSTRAPPING (criterion 2, landed 2026-08-30). The regeneration authority is the
# SELFHOST built from the COMMITTED selfhost/*.zig -- the previous generation of itself,
# exactly as GCC/Rust/Go take stage-0 from a previous release. The bootstrap is FROZEN,
# not deleted: it must still COMPILE the selfhost source, and --zig-backend delegates.
#
# THE MECHANISM IS `--emit-zig --output-dir`, NOT `--emit-zig >`, AND THAT IS LOAD-BEARING.
# A stdout redirect writes ZERO BYTES under this compiler (BUG-317: its own print calls
# were emitted by the bootstrap and go to stderr). The ticket for this change said "point
# ZEBRA at zebra.exe, everything else follows"; doing only that regenerates twelve EMPTY
# files. Measured 2026-08-30 before running it.
ZEBRA="$REPO/zig-out/bin/zebra.exe"
SELFHOST_A="$REPO/zig-out/bin/zebra-selfhost.exe"
SELFHOST_B="$REPO/zig-out/bin/zebra-selfhost-B.exe"

# Build the round-trip's verification binaries (selfhost-A/B) with Zig's self-hosted
# x86_64 backend + linker by default: ~6x faster than LLVM+LLD (1.4s vs 8.5s for the
# ~25k-line compiler) and verified to emit byte-identically to the LLVM build.  These
# are ephemeral round-trip *checkers* — the committed selfhost/*.zig is produced by the
# Zig-compiled bootstrap (LLVM), not by A/B — so the speedup carries no artifact risk.
# Each build below falls back to LLVM automatically if the self-hosted backend hits a
# gap (a real codegen error becomes a fallback, never a false gate failure).
# Set BOOTSTRAP_FAST=0 to force LLVM for both (e.g. to cross-check the backend).
FAST_BACKEND="${BOOTSTRAP_FAST:-1}"
FAST_FLAGS=""
[[ "$FAST_BACKEND" == "1" ]] && FAST_FLAGS="-fno-llvm -fno-lld"

# build_compiler <root.zig> <out.exe> <errfile> — try the fast backend, fall back to LLVM.
build_compiler() {
    local root="$1" out="$2" err="$3"
    if [[ -n "$FAST_FLAGS" ]]; then
        zig build-exe "$root" -femit-bin="$out" $FAST_FLAGS 2>"$err" && return 0
    fi
    zig build-exe "$root" -femit-bin="$out" 2>"$err"
}

# typechecker is part of the selfhost dep graph as of Phase 16c. It is
# included here so the round-trip fixed-point check covers it.
FILES=(Token Lexer Ast AstWalk Parser Resolver AstBuilder CgHelpers TypeChecker CodeGen Checker main)

if [[ ! -x "$ZEBRA" ]]; then
    echo "bootstrap_check: $ZEBRA missing. Run 'zig build' first." >&2
    exit 1
fi

# ── Safety net: snapshot selfhost/*.zig up front; restore on premature exit.
# A clean successful run leaves selfhost/ in the fixed-point state without
# restore. A failure (build error, interrupt) puts the tree back to the
# pre-bootstrap state rather than leaving half-emitted intermediates.
# Active in full mode (QUICK=0) and --update mode (UPDATE=1); plain --quick
# never writes to selfhost/ so it needs no snapshot.
if [[ $QUICK -eq 0 || $UPDATE -eq 1 ]]; then
    BS_PRE=/tmp/bs-pre
    rm -rf "$BS_PRE"
    mkdir -p "$BS_PRE"
    for f_zig in selfhost/*.zig; do
        cp "$f_zig" "$BS_PRE/$(basename "$f_zig")"
    done

    restore_selfhost() {
        local ec=$?
        if [[ $ec -ne 0 ]]; then
            echo "bootstrap_check: restoring selfhost/*.zig from pre-run snapshot ($BS_PRE)" >&2
            for f_zig in "$BS_PRE"/*.zig; do
                cp "$f_zig" "selfhost/$(basename "$f_zig")"
            done
        fi
    }
    trap restore_selfhost EXIT INT
fi

echo "── Step 1: regenerate .zig into /tmp/bs-zig (zebra.exe — the N-1 selfhost)"
# Emit into /tmp/bs-zig instead of selfhost/ so the checked-in selfhost/*.zig
# is never polluted with zebra's header style ("Generated by the Zebra
# compiler."). This keeps `git status` readable during bootstrap: any dirt
# in selfhost/ is genuinely from the selfhost pass in steps 3/5.
BS_ZIG=/tmp/bs-zig
rm -rf "$BS_ZIG"
mkdir -p "$BS_ZIG"
# STDERR IS KEPT, and that is not a nicety. It used to go to /dev/null, so a compile
# error in the compiler'"'"'s OWN source surfaced only as "regeneration failed" with no
# reason -- the caller then has to re-run the emit by hand to learn what broke, in the
# innermost loop of every selfhost change. A refusal that cannot say why is the thing
# this repo keeps writing down and then shipping anyway. Cost 20 minutes on 2026-08-20
# (a top-level def written as a method: "'"'"'this'"'"' used outside a class/struct method").
# ONE command emits main plus every dependency plus zebra_rt.zig into $BS_ZIG. The old
# per-module loop existed because `--emit-zig >` writes a single file to stdout; with
# --output-dir the compiler resolves the dependency graph itself.
if ! "$ZEBRA" --emit-zig --output-dir "$BS_ZIG" selfhost/main.zbr >/dev/null 2>"/tmp/bs-emit-err"; then
    echo "FAIL: regenerating the selfhost — the compiler refused its own source:" >&2
    grep -aiE 'error|panic' "/tmp/bs-emit-err" | head -5 >&2
    exit 1
fi
# EVERY module present and NON-EMPTY. Step 1 had no such guard while update mode did,
# which is precisely how a zero-byte regeneration could have reached the build.
for f in "${FILES[@]}" zebra_rt; do
    if [[ ! -s "$BS_ZIG/$f.zig" ]]; then
        echo "FAIL: $BS_ZIG/$f.zig missing or empty after regeneration — refusing to build" >&2
        exit 1
    fi
done

echo "── Step 2: build selfhost-A (from /tmp/bs-zig)"
rm -f "$SELFHOST_A"
if ! build_compiler "$BS_ZIG/main.zig" "$SELFHOST_A" /tmp/bs-rebuildA.err; then
    echo "FAIL: selfhost-A build errors:" >&2
    head -30 /tmp/bs-rebuildA.err >&2
    exit 1
fi

if [[ $QUICK -eq 1 ]]; then
    if [[ $UPDATE -eq 1 ]]; then
        echo "── Step 3 (update): re-emitting selfhost/*.zig via the selfhost (N-1 regen authority)"
        # Use the Zig-compiled bootstrap compiler — never selfhost-A — to avoid
        # the chicken-and-egg where selfhost-A has a codegen bug that regenerates
        # itself incorrectly.  Bootstrap is the authoritative, self-contained emitter.
        # The round-trip fidelity test (selfhost-A == selfhost-B) lives in full mode.
        #
        # Kill-safety: emit every file into a temp dir FIRST, validate each is
        # non-empty, and only then atomically `mv` them into selfhost/.  A redirect
        # `> selfhost/$f.zig` truncates the target the instant it opens, so a kill
        # mid-emit (timeout / OOM under memory pressure) used to leave a source
        # `.zig` empty — a half-regenerated tree that broke subsequent builds
        # (observed repeatedly 2026-07-14).  Writing to a temp then moving means an
        # interrupted run never touches the checked-in files; the final mv loop is
        # sub-second (11 renames) so its own kill window is negligible, and even
        # then each moved file is complete (never truncated).
        BS_UP=/tmp/bs-up
        rm -rf "$BS_UP"; mkdir -p "$BS_UP"
        if ! "$ZEBRA" --emit-zig --output-dir "$BS_UP" selfhost/main.zbr >/dev/null 2>/tmp/bs-update-err; then
            echo "FAIL: could not emit the selfhost sources" >&2
            grep -v "^wrote " /tmp/bs-update-err >&2 || true
            exit 1
        fi
        for f in "${FILES[@]}" zebra_rt; do
            if [[ ! -s "$BS_UP/$f.zig" ]]; then
                echo "FAIL: emitted $f.zig is empty — refusing to overwrite selfhost/$f.zig" >&2
                exit 1
            fi
        done
        # zebra_rt.zig moves with them: the selfhost emits the runtime as a
        # MODULE, so it is part of the committed set, not spliced into every file.
        for f in "${FILES[@]}" zebra_rt; do
            mv "$BS_UP/$f.zig" "selfhost/$f.zig"
        done
        echo "PASS: selfhost/*.zig updated — run 'zig build' to rebuild zebra.exe"
    else
        echo "PASS: quick rebuild — zebra-selfhost.exe rebuilt (selfhost/*.zig not updated; use --update to refresh)"
    fi
    exit 0
fi

# Emit each root into its OWN directory.
#
# This used to be `--emit-zig` with no --output-dir, then `cp selfhost/$f.zig`.
# That has not worked since --emit-zig started writing to $TEMP (#230, to stop
# run-mode polluting the source tree): selfhost-A never touched selfhost/$f.zig,
# so both this step and step 5 copied the same UNCHANGED committed file and the
# A-vs-B diff compared a file to itself. It could not fail. Found 2026-07-28;
# the property itself does hold (verified by hand, 0 divergent over all 11
# modules) — it simply was not being checked.
#
# Per-file directories, not one shared dir: emitting a root also emits its deps
# alongside it, dep-shaped (no entry thunk, no _zbr_error_msg). A shared dir
# would let a later root's deps overwrite an earlier root's emit — the same
# clobber the old `cp`-immediately comment was defending against.
echo "── Step 3: selfhost-A re-emits its own source"
rm -rf /tmp/bs-A /tmp/bs-B
for f in "${FILES[@]}"; do
    mkdir -p "/tmp/bs-A/$f"
    if ! "$SELFHOST_A" --emit-zig --output-dir "/tmp/bs-A/$f" "selfhost/$f.zbr" >/dev/null 2>/tmp/bs-emit-err; then
        echo "FAIL: selfhost-A could not emit selfhost/$f.zig" >&2
        grep -v "^wrote " /tmp/bs-emit-err >&2 || true
        exit 1
    fi
done

# Build B from selfhost-A's OWN OUTPUT — that is what makes this level-2.
# It used to build from the committed selfhost/*.zig, which is bootstrap-emitted,
# so B was the same compiler as A and the step proved nothing about A's emit.
# /tmp/bs-A/main/ is the right set: emitting main.zbr produces main.zig root-shaped
# plus every dep dep-shaped, in one directory — exactly a buildable tree.
echo "── Step 4: build selfhost-B from selfhost-A's emit (level-2 bootstrap)"
rm -f "$SELFHOST_B"
if ! build_compiler /tmp/bs-A/main/main.zig "$SELFHOST_B" /tmp/bs-rebuildB.err; then
    echo "FAIL: selfhost-B build errors:" >&2
    grep -E "^selfhost[\\\\/].+:[0-9]+:[0-9]+: error:" /tmp/bs-rebuildB.err >&2 || head -30 /tmp/bs-rebuildB.err >&2
    exit 1
fi

echo "── Step 5: selfhost-B re-emits + diff against selfhost-A output"
for f in "${FILES[@]}"; do
    mkdir -p "/tmp/bs-B/$f"
    if ! "$SELFHOST_B" --emit-zig --output-dir "/tmp/bs-B/$f" "selfhost/$f.zbr" >/dev/null 2>/tmp/bs-emit-err; then
        echo "FAIL: selfhost-B could not emit selfhost/$f.zig" >&2
        grep -v "^wrote " /tmp/bs-emit-err >&2 || true
        exit 1
    fi
done

DIVERGENT=0
for f in "${FILES[@]}"; do
    if ! diff -q "/tmp/bs-A/$f/$f.zig" "/tmp/bs-B/$f/$f.zig" >/dev/null; then
        echo "DIVERGENT: $f.zig"
        DIVERGENT=$((DIVERGENT+1))
    fi
done

if [[ $DIVERGENT -ne 0 ]]; then
    echo "FAIL: $DIVERGENT file(s) diverge between selfhost-A and selfhost-B" >&2
    exit 1
fi

# The working tree is untouched by steps 3-5: both selfhost passes emit into
# /tmp/bs-A and /tmp/bs-B, so selfhost/*.zig keeps whatever the bootstrap (the
# regen authority) last wrote. The old comment here claimed the tree was left
# "in selfhost-B-emitted state ... the deterministic fixed point"; that stopped
# being true when --emit-zig moved to $TEMP, and it is now false by design
# rather than by accident.

echo "PASS: round-trip clean, selfhost-B produces output byte-identical to selfhost-A"
