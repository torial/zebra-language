#!/usr/bin/env bash
# doctor.sh — is this working tree in a state where results can be trusted?
#
# Every check here corresponds to a failure we have ACTUALLY HIT, not a
# hypothetical. The dangerous ones are silent: they do not make things break,
# they make things LIE — you run a gate, it passes, and it measured the wrong
# compiler.
#
#   bash tools/doctor.sh          # report; exit 1 if anything is WRONG
#   bash tools/doctor.sh --fix    # also clear what is safely clearable
#
# Checks, and the incident behind each:
#   1. STALE GENERATED ZIG — selfhost/*.zig older than its *.zbr source. The
#      compiler you run is built from the .zig, so an un-regenerated edit means
#      you are testing the OLD compiler while believing it is new. `zig build
#      update-selfhost` silently skips regeneration (BUG-210), which is exactly
#      how this happens. This made a real fix (BUG-219) appear not to work.
#   2. ORPHANED COMPILERS — a zebra/zig process left by a killed or timed-out run
#      holds a lock on zig-out/bin; the next build dies with AccessDenied.
#   3. STALE BOOTSTRAP SCRATCH — /tmp/bs-zig or /tmp/bs-pre left by a killed
#      bootstrap_check make the next run fail for reasons unrelated to your change.
#   4. MISSING/UNRUNNABLE COMPILER — zig-out/bin/zebra.exe absent, or present but
#      unable to compile a hello-world.
#   5. HEADROOM — heavy gates are RAM-bound; the host has been loaded enough that
#      concurrent zig jobs got killed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

FIX=0
[[ "${1:-}" == "--fix" ]] && FIX=1

WRONG=0
WARN=0
ok()    { printf '  \033[32mok\033[0m    %s\n' "$1"; }
warn()  { printf '  \033[33mwarn\033[0m  %s\n' "$1"; WARN=$((WARN+1)); }
wrong() { printf '  \033[31mWRONG\033[0m %s\n' "$1"; WRONG=$((WRONG+1)); }

echo "zebra doctor"
echo

# ── 1. stale generated .zig (the silent one) ─────────────────────────────────
stale=()
for zbr in selfhost/*.zbr; do
    zig="${zbr%.zbr}.zig"
    [[ -f "$zig" ]] || continue
    if [[ "$zbr" -nt "$zig" ]]; then
        stale+=("$(basename "$zbr")")
    fi
done
if [[ ${#stale[@]} -gt 0 ]]; then
    wrong "stale generated Zig — you would be testing the OLD compiler:"
    for f in "${stale[@]}"; do printf '           %s is newer than its .zig\n' "$f"; done
    printf '           fix: bash tools/rebuild.sh   (NOT `zig build update-selfhost` — BUG-210)\n'
else
    ok "generated selfhost/*.zig is current with its .zbr sources"
fi

# ── 1b. bootstrap older than the preamble it EMBEDS (the other silent one) ───
# build.zig:37-59 reads the preamble files and embeds them into zebra-bootstrap.exe
# via b.addOptions — at BUILD time. The bootstrap is the regen authority, so if it
# predates a preamble edit it regenerates the OLD runtime, the regen looks clean,
# and every gate afterwards measures a compiler that does not contain the change.
# Observed 2026-07-28: a preamble edit + rebuild.sh reported OK and changed nothing.
# Same family as check 1 — there the .zig lags the .zbr; here the BINARY lags the
# file it baked in. Both make results lie, so both are WRONG, not warn.
BOOT=zig-out/bin/zebra-bootstrap.exe
embed_stale=()
if [[ -f "$BOOT" ]]; then
    for f in selfhost/stdlib_preamble.zig selfhost/napi_preamble.zig; do
        [[ -f "$f" && "$f" -nt "$BOOT" ]] && embed_stale+=("$(basename "$f")")
    done
fi
if [[ ${#embed_stale[@]} -gt 0 ]]; then
    wrong "bootstrap predates a preamble it embeds — a regen now emits the OLD runtime:"
    for f in "${embed_stale[@]}"; do printf '           %s is newer than zebra-bootstrap.exe\n' "$f"; done
    printf '           fix: zig build   (then regenerate — bash tools/rebuild.sh does both, in order)\n'
elif [[ -f "$BOOT" ]]; then
    ok "bootstrap is current with the preamble files it embeds"
fi

# ── 2. orphaned compilers holding locks ──────────────────────────────────────
orph=0
# Counting and killing are both scoped to THIS tree. The old code counted every
# zebra.exe/zig.exe on the machine and, under --fix, killed them all — which on
# 2026-08-01 meant a mutation run in a sibling worktree and the shared zvm zig.exe.
# A process in another checkout is not an orphan of ours and is not a reason to
# call this tree untrustworthy.
orph_out=$(bash "$SCRIPT_DIR/kill_orphans.sh" $([[ $FIX -eq 1 ]] || echo --count) 2>/dev/null)
orph=$(echo "$orph_out" | grep -c "killed orphaned\|would kill" || true)
echo "$orph_out" | grep "leaving alone" | sed 's/^/           /' || true
[[ $FIX -eq 1 ]] && echo "$orph_out" | grep "killed orphaned" | sed 's/^/          /' || true
if [[ $orph -gt 0 ]]; then
    if [[ $FIX -eq 1 ]]; then
        ok "cleared $orph orphaned compiler process(es)"
    else
        warn "$orph compiler process(es) running — if no build is active these are orphans"
        printf '           holding a lock on zig-out/bin causes AccessDenied; clear with --fix\n'
    fi
else
    ok "no orphaned compiler processes"
fi

# ── 3. stale bootstrap scratch ───────────────────────────────────────────────
stale_dirs=()
for d in /tmp/bs-zig /tmp/bs-pre /tmp/selfhost-smoke; do
    [[ -e "$d" ]] && stale_dirs+=("$d")
done
if [[ ${#stale_dirs[@]} -gt 0 ]]; then
    if [[ $FIX -eq 1 ]]; then
        rm -rf "${stale_dirs[@]}"
        ok "cleared stale scratch: ${stale_dirs[*]}"
    else
        warn "stale bootstrap scratch present: ${stale_dirs[*]}"
        printf '           left by a killed run; causes unrelated failures. clear with --fix\n'
    fi
else
    ok "no stale bootstrap scratch"
fi

# ── 4. the compiler actually works ───────────────────────────────────────────
if [[ ! -x zig-out/bin/zebra.exe ]]; then
    wrong "zig-out/bin/zebra.exe missing — run: bash tools/rebuild.sh"
else
    probe=$(mktemp -t doctor-XXXXXX).zbr
    printf 'def main()\n    print("doctor ok")\n' > "$probe"
    if out=$(timeout 180 ./zig-out/bin/zebra.exe run "$probe" 2>&1) && echo "$out" | grep -qF "doctor ok"; then
        ok "zebra.exe compiles and runs a hello-world"
    else
        wrong "zebra.exe present but cannot run a hello-world"
        echo "$out" | tail -4 | sed 's/^/           /'
    fi
    rm -f "$probe"
fi

# ── 5. headroom ──────────────────────────────────────────────────────────────
load="$(bash "$SCRIPT_DIR/sysload.sh" 2>/dev/null || echo '')"
if [[ -n "$load" ]]; then
    free_gb="$(echo "$load" | grep -oE '[0-9]+\.[0-9]+ GB free' | grep -oE '^[0-9]+' || echo 99)"
    if [[ "$free_gb" -lt 4 ]]; then
        warn "low RAM — $load"
        printf '           heavy gates are RAM-bound; use JOBS=1 or wait\n'
    else
        ok "$load"
    fi
fi

echo
if [[ $WRONG -gt 0 ]]; then
    printf '\033[31mdoctor: %d problem(s) that would make results untrustworthy\033[0m\n' "$WRONG"
    exit 1
fi
if [[ $WARN -gt 0 ]]; then
    printf '\033[33mdoctor: %d warning(s) — safe to proceed, `--fix` to clear\033[0m\n' "$WARN"
    exit 0
fi
printf '\033[32mdoctor: environment sane\033[0m\n'
