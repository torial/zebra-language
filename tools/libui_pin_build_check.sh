#!/usr/bin/env bash
# libui_pin_build_check.sh -- build a libui_ng program EXACTLY as a stranger would.
#
#   * ZEBRA_LIBUI_PATH unset, so the scaffold's build.zig.zon fetches zig-libui-ng at the
#     commit PINNED in the compiler -- not the author's checkout;
#   * from a scratch directory OUTSIDE the repo (BUG-322's lesson: things that work from
#     the repo root can fail everywhere else);
#   * `zig build`, i.e. a real compile and link, not `-fno-emit-bin` sema.
#
# WHY (2026-09-25): on main every libui_ng program failed to build for anyone without
# ZEBRA_LIBUI_PATH -- 14 compile errors, examples/counter.zbr included -- and every
# existing witness passed, because `libui-section` and zebra-ide's check.sh compile
# against the LOCAL checkout. tools/libui_pin_check.py (FAST) now catches the cheap half:
# a pin that is unpublished, or missing a declaration the section names. This is the
# other half, which only a real build can see: a changed SIGNATURE or FIELD at the pin
# (that day's build also failed on `MinWidth` and on a table-callback type, neither of
# which a name lookup finds).
#
# Needs network the first time a pin is fetched (zig caches it after). DAILY tier: the
# first build compiles libui and Scintilla from source (~15 min); later runs reuse zig's
# global cache.
#
# Exit 0 = built; 1 = the stranger's build FAILED (errors printed); 2 = could not run.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEBRA="$REPO/zig-out/bin/zebra.exe"; [ -x "$ZEBRA" ] || ZEBRA="$REPO/zig-out/bin/zebra"
[ -x "$ZEBRA" ] || { echo "libui-pin-build: REFUSED -- no built compiler in zig-out/bin"; exit 2; }
command -v zig >/dev/null 2>&1 || { echo "libui-pin-build: REFUSED -- zig not on PATH"; exit 2; }

EX="${1:-examples/counter.zbr}"
[ -f "$REPO/$EX" ] || { echo "libui-pin-build: REFUSED -- no $EX"; exit 2; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/zbr_libui_pin_build.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
case "$scratch" in "$REPO"*) echo "libui-pin-build: REFUSED -- scratch dir is inside the repo"; exit 2;; esac

cd "$scratch" || exit 2
# `env -u` so a developer's own ZEBRA_LIBUI_PATH cannot make this pass for the wrong reason.
if ! env -u ZEBRA_LIBUI_PATH "$ZEBRA" --gui-backend=libui_ng --scaffold-only --output-dir "$scratch/out" "$REPO/$EX" > scaffold.log 2>&1; then
    echo "libui-pin-build: FAIL -- scaffolding $EX failed:"; tail -5 scaffold.log; exit 1
fi
zon="$(find "$scratch/out" -name build.zig.zon | head -1)"
[ -n "$zon" ] || { echo "libui-pin-build: REFUSED -- scaffold wrote no build.zig.zon"; exit 2; }
pin="$(grep -oE 'zig-libui-ng\?ref=main#[0-9a-f]{8}' "$zon" | cut -d'#' -f2)"
# The control: the scaffold must fetch by URL. A `.path` dependency means some override
# pointed it at a checkout, which is precisely the author's-machine build this gate
# exists NOT to be.
# `\.path *=` and not `\.path`: every build.zig.zon has a `.paths = .{...}` field, and the
# first version of this line matched it and refused on a perfectly pinned scaffold.
if [ -z "$pin" ] || grep -qE '\.path *=' "$zon"; then
    echo "libui-pin-build: REFUSED -- the scaffold does not fetch zig-libui-ng by pinned URL"; exit 2
fi

proj="$(dirname "$zon")"
if (cd "$proj" && env -u ZEBRA_LIBUI_PATH zig build > "$scratch/build.log" 2>&1); then
    echo "libui-pin-build: PASS -- $EX built from a clean scaffold against pinned zig-libui-ng $pin"
    exit 0
fi
n=$(grep -c 'error:' "$scratch/build.log")
echo "libui-pin-build: FAIL -- a stranger cannot build $EX: $n error line(s) against pinned zig-libui-ng $pin"
grep 'error:' "$scratch/build.log" | sed -E 's/.*error: /    /' | sort | uniq -c | sort -rn | head -15
exit 1
