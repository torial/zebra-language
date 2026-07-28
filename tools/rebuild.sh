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
#
# Encoding the sequence once beats remembering it every time.
#
#   bash tools/rebuild.sh            # regen + build
#   bash tools/rebuild.sh --no-regen # build only (for a .zig / preamble edit)
#
# NOTE: a `selfhost/stdlib_preamble.zig` edit needs the FULL sequence too. The
# preamble is inlined into each emitted program at emit time, so the compiler
# itself only picks up a preamble change after regeneration — this is exactly
# what made BUG-219's first fix appear not to work.
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

echo
echo "rebuild: OK — now run a gate:  bash tools/gates.sh"
