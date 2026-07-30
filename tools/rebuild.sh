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
#   bash tools/rebuild.sh            # regen + build
#   bash tools/rebuild.sh --no-regen # build only (for a .zig / preamble edit)
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
[[ "${1:-}" == "--no-regen" ]] && REGEN=0

export PATH="/c/Users/Sean/.zvm/bin:$PATH"

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
fail() { printf '\033[31mrebuild: %s\033[0m\n' "$1" >&2; exit 1; }

step "system load"
bash "$SCRIPT_DIR/sysload.sh" 2>/dev/null || echo "(sysload unavailable)"

# Footgun 3: an orphaned compiler from a killed/timed-out run holds a lock on
# zig-out/bin and the install step fails with AccessDenied.
step "clearing orphaned processes"
for p in zebra.exe zebra-bootstrap.exe zebra-selfhost.exe zebra-selfhost-B.exe; do
    taskkill //F //IM "$p" >/dev/null 2>&1 && echo "  killed orphaned $p"
done
true

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

    # Footgun 2: stale state from a killed run.
    step "clearing stale /tmp/bs-zig"
    rm -rf /tmp/bs-zig

    # Footgun 1: call bootstrap_check.sh DIRECTLY. Never `zig build update-selfhost`.
    step "regenerating selfhost/*.zig via the bootstrap (regen authority)"
    if ! bash "$SCRIPT_DIR/bootstrap_check.sh" --update 2>&1 | tail -3; then
        fail "regeneration failed — selfhost/*.zig was restored from the pre-run snapshot"
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
echo "rebuild: OK — now run a gate:  bash tools/gates.sh"
echo "            (environment check: bash tools/doctor.sh)"
