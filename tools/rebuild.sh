#!/usr/bin/env bash
# rebuild.sh — make a `selfhost/*.zbr` edit REAL, correctly, in one command.
#
# WHY THIS EXISTS
# ---------------
# Editing a `.zbr` in selfhost/ does nothing on its own. The compiler you run is
# built from the *generated* `selfhost/*.zig`, so a source change only takes
# effect after: regenerate the .zig via the bootstrap, then rebuild zebra.exe.
# That sequence has three documented footguns, each of which has actually cost
# real time:
#
#   1. `zig build update-selfhost` SILENTLY SKIPS the regeneration when only
#      .zbr files changed — its build step declares no .zbr inputs, so Zig's
#      cache considers it up to date (BUG-210). You edit, rebuild, and run the
#      OLD compiler while believing you tested the new one.
#   2. A stale `/tmp/bs-zig` left by a killed run makes bootstrap_check fail for
#      reasons unrelated to your change.
#   3. An orphaned `zebra.exe`/`zig.exe` from a timed-out run keeps a file lock
#      on zig-out/bin, and the build dies with `AccessDenied` on compiler_rt.dll.
#   4. The regen runs `zebra-bootstrap.exe`, which EMBEDS the preamble files at
#      its own build time (build.zig:37-59, `b.addOptions`). So after a preamble
#      edit, regenerating with the existing binary emits the OLD runtime — and
#      every gate downstream then measures it. Observed 2026-07-28: a preamble
#      edit + rebuild.sh reported OK and produced zero changes to selfhost/*.zig.
#      Fixed below by rebuilding the bootstrap BEFORE the regen when a preamble
#      file is newer than the binary.
#
# Encoding the sequence once beats remembering it every time.
#
#   bash tools/rebuild.sh                    # regen + build (all modules)
#   bash tools/rebuild.sh --no-regen         # build only (for a .zig / preamble edit)
#   bash tools/rebuild.sh --module CodeGen   # regen ONE module + build  (the inner loop)
#
# --module is the fast inner loop: ~25 s against several minutes, because the full regen
# re-emits every selfhost module and rebuilds the intermediate compilers first. It is
# sound for the common case (you edited one .zbr) because the regeneration is done by the
# BOOTSTRAP, whose output for the other modules your edit cannot have changed.
#
# The footgun it guards is not speed, it is SCOPE: editing two modules and regenerating
# one leaves the tree half-updated, and every gate downstream then measures a compiler
# that is partly old. So --module compares its argument against the .zbr files actually
# modified in the working tree and REFUSES if any changed module was left out. `--force`
# overrides, for the case where an unrelated .zbr has long-standing uncommitted work in it
# (a parallel session, a WIP experiment).
#
# NOTE: a `selfhost/stdlib_preamble.zig` edit needs the FULL sequence too. The
# preamble is inlined into each emitted program at emit time, so the compiler
# itself only picks up a preamble change after regeneration — this is exactly
# what made BUG-219's first fix appear not to work. Footgun 4 above is the same
# trap one level further out: there, regeneration was skipped; here, it ran
# against a binary that predated the edit.
#
# What this does NOT do: run any gate. Use tools/gates.sh for that.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

REGEN=1
MODULES=""
FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-regen) REGEN=0 ;;
        --module)   MODULES="${MODULES}${MODULES:+ }${2:?--module needs a module name, e.g. CodeGen}"; shift ;;
        --module=*) MODULES="${MODULES}${MODULES:+ }${1#--module=}" ;;
        --force)    FORCE=1 ;;
        -h|--help)
            echo "usage: $0 [--no-regen] [--module NAME]... [--force]" >&2
            exit 0 ;;
        *) echo "rebuild: unknown argument '$1'" >&2; exit 2 ;;
    esac
    shift
done

export PATH="/c/Users/Sean/.zvm/bin:$PATH"

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
fail() { printf '\033[31mrebuild: %s\033[0m\n' "$1" >&2; exit 1; }

step "system load"
bash "$SCRIPT_DIR/sysload.sh" 2>/dev/null || echo "(sysload unavailable)"

# Footgun 3: an orphaned compiler from a killed/timed-out run holds a lock on
# zig-out/bin and the install step fails with AccessDenied.
step "clearing orphaned processes (this tree only)"
# Was `taskkill //F //IM zebra.exe` — MACHINE-WIDE, and it killed a mutation run's
# bootstrap in the sibling worktree on 2026-08-01, mid-mutant. The victim scores that as
# "regeneration failed", i.e. as a RESULT. The lock this clears is only ever held by a
# process running from THIS tree, so path-scoping loses nothing. See tools/kill_orphans.sh.
bash "$SCRIPT_DIR/kill_orphans.sh" || true

if [[ $REGEN -eq 1 ]]; then
    # Footgun 4: the regen below runs zebra-bootstrap.exe, and build.zig EMBEDS
    # the preamble files into that binary at build time. A preamble edit is
    # therefore invisible to the regen until the bootstrap itself is rebuilt, and
    # the regen silently emits the previous runtime. Only pre-build when a
    # preamble file is actually newer than the binary — a .zbr-only edit (the
    # common case) pays nothing, and a tree whose selfhost/*.zig is currently
    # broken is not blocked from being regenerated back to health.
    BOOT=zig-out/bin/zebra-bootstrap.exe
    for f in selfhost/stdlib_preamble.zig selfhost/napi_preamble.zig; do
        if [[ -f "$f" && ( ! -f "$BOOT" || "$f" -nt "$BOOT" ) ]]; then
            step "rebuilding the bootstrap first ($f is newer; it is embedded at build time)"
            if ! zig build 2>&1 | tail -6; then
                fail "zig build failed — the bootstrap still embeds the OLD $f, so regenerating now would emit a stale runtime"
            fi
            break
        fi
    done

    if [[ -n "$MODULES" ]]; then
        # ---- single-module regen -------------------------------------------------
        # Extracted from tools/mutation_check.py's regen(), which has run this path
        # thousands of times. Two details are load-bearing and both are documented there:
        #   * redirect to a FILE, never a pipe. The bootstrap's emit is large and a
        #     blocked pipe looks exactly like a compiler that refused the input — that
        #     confusion produced 80% of a published, later-retracted result.
        #   * the emitted text is written with LF only. Python is not the only thing that
        #     can put a CR in a .zig; be explicit anyway.
        BOOT=zig-out/bin/zebra-bootstrap.exe
        [[ -x "$BOOT" ]] || fail "$BOOT missing — run a full 'bash tools/rebuild.sh' first"

        # SCOPE CHECK. A half-regenerated tree is the failure this guards.
        if [[ $FORCE -eq 0 ]]; then
            changed=$( { git diff --name-only -- 'selfhost/*.zbr'
                         git diff --name-only --cached -- 'selfhost/*.zbr'
                         git ls-files --others --exclude-standard -- 'selfhost/*.zbr'
                       } | sort -u )
            missing=""
            for c in $changed; do
                base="$(basename "$c" .zbr)"
                echo " $MODULES " | grep -qF " $base " || missing="$missing $base"
            done
            if [[ -n "$missing" ]]; then
                echo
                printf '\033[31mrebuild: these selfhost modules are MODIFIED but not in --module:\033[0m\n' >&2
                for m in $missing; do echo "    $m" >&2; done
                echo >&2
                echo "  Regenerating a subset would leave selfhost/*.zig half-updated, and every" >&2
                echo "  gate downstream would then measure a compiler that is partly old." >&2
                echo "  Either add them (--module NAME each), run the full 'bash tools/rebuild.sh'," >&2
                echo "  or pass --force if their changes are unrelated to what you are testing." >&2
                exit 1
            fi
        fi

        for m in $MODULES; do
            [[ -f "selfhost/$m.zbr" ]] || fail "selfhost/$m.zbr does not exist"
            step "regenerating selfhost/$m.zig via the bootstrap (regen authority)"
            tmp="$(mktemp)"
            if ! "$BOOT" --emit-zig "selfhost/$m.zbr" > "$tmp" 2>/tmp/_rebuild_mod_err; then
                tail -5 /tmp/_rebuild_mod_err >&2
                rm -f "$tmp"
                fail "the bootstrap refused selfhost/$m.zbr — selfhost/$m.zig left untouched"
            fi
            # The bootstrap prints progress chatter before the emitted source; the header
            # is where the actual Zig starts. Its ABSENCE with rc=0 is the silent-failure
            # case, so it is checked rather than assumed.
            if ! grep -qF "// Generated by" "$tmp"; then
                rm -f "$tmp"
                fail "the bootstrap emitted no source for $m despite rc=0 — refusing to write a truncated selfhost/$m.zig"
            fi
            sed -n '/\/\/ Generated by/,$p' "$tmp" | tr -d '\r' > "selfhost/$m.zig"
            rm -f "$tmp"
            echo "  selfhost/$m.zig  ($(wc -l < "selfhost/$m.zig") lines)"
        done
    else

    # Footgun 2: stale state from a killed run.
    step "clearing stale /tmp/bs-zig"
    rm -rf /tmp/bs-zig

    # Footgun 1: call bootstrap_check.sh DIRECTLY. Never `zig build update-selfhost`.
    step "regenerating selfhost/*.zig via the bootstrap (regen authority)"
    if ! bash "$SCRIPT_DIR/bootstrap_check.sh" --update 2>&1 | tail -3; then
        fail "regeneration failed — selfhost/*.zig was restored from the pre-run snapshot"
    fi
    fi
fi

step "building zebra.exe"
if ! zig build 2>&1 | tail -6; then
    fail "zig build failed"
fi

step "result"
if [[ -x zig-out/bin/zebra.exe ]]; then
    printf 'def main()\n    print("rebuild ok")\n' > /tmp/_rebuild_probe.zbr
    if out=$(timeout 120 ./zig-out/bin/zebra.exe run /tmp/_rebuild_probe.zbr 2>&1) \
       && echo "$out" | grep -qF "rebuild ok"; then
        echo "  zebra.exe builds and runs"
    else
        fail "zebra.exe was built but cannot run a hello-world — something is badly wrong"
    fi
else
    fail "zig-out/bin/zebra.exe missing after build"
fi

# Footgun 5 (found 2026-07-30): rebuild.sh could report OK on a tree doctor calls
# UNTRUSTWORTHY, and both were right under their own model.
#
# doctor uses "is a preamble NEWER than the binary that embeds it?" as a proxy for "does
# the binary embed stale content". The proxy breaks when zig CACHE-HITS: the build is
# genuinely current, but zig restores the artifact with its ORIGINAL mtime, so a preamble
# whose timestamp moved (even without a content change) stays permanently "newer" and
# doctor refuses forever. `zig build` cannot fix it, because there is nothing to rebuild —
# deleting the binary and rebuilding restores the same cached artifact, old mtime and all.
#
# After a SUCCESSFUL build the binaries correspond to the current sources by construction,
# so stamping them is not faking the check — it is recording what the build just
# established, in the medium the check reads. Only ever done on the success path.
if [[ -x zig-out/bin/zebra-bootstrap.exe ]]; then
    touch zig-out/bin/zebra-bootstrap.exe
fi
if [[ -x zig-out/bin/zebra.exe ]]; then
    touch zig-out/bin/zebra.exe
fi

echo
if [[ -n "$MODULES" ]]; then
    echo
    echo "rebuild: OK (single-module: $MODULES)"
    echo "  This is the inner loop. Before gating or committing, run the FULL"
    echo "  'bash tools/rebuild.sh' — the round-trip check it performs is the only thing"
    echo "  that proves the regenerated set is self-consistent."
    echo "  (environment check: bash tools/doctor.sh)"
    exit 0
fi

echo "rebuild: OK — now run a gate:  bash tools/gates.sh"
echo "            (environment check: bash tools/doctor.sh)"
