#!/usr/bin/env bash
# gui_scaffold_check.sh — the first gate that looks at a GUI path at all.
#
# WHY THIS EXISTS
# ---------------
# BUG-229 was the FOURTH GUI crash to sit underneath a full set of green gates. The house
# rule has been honest about it — "no gate clicks a button, rendering is only ever proven
# by Sean running it" — but that framing quietly conceded more than it needed to. A crash
# at STARTUP is not a rendering problem, and it does not need a human or a terminal to
# detect.
#
# BUG-229 specifically: the tui scaffold DECLARED `var _tui_env: *std.process.Environ.Map
# = undefined;` and passed it to `zz.Terminal.init(_io, _tui_env, …)`, but the selfhost
# emit never ASSIGNED it. Every tui app dereferenced an undefined pointer and segfaulted
# at 0x0 before drawing anything. The bootstrap had the assignment all along; the selfhost
# mirror was written without it, and it only started mattering when GUI scaffolding moved
# to selfhost emission.
#
# WHAT THIS CHECKS, AND WHAT IT STILL CANNOT
# ------------------------------------------
# Leg 1 (STATIC, reliable): the scaffolded main.zig must ASSIGN every `_tui_env`-style
#   pointer it declares. This is the precise shape of BUG-229 and it needs no terminal,
#   so it is the leg that actually gates.
# Leg 2 (RUNTIME, best-effort): the built app must not CRASH on startup when run with no
#   tty. A tui app may legitimately refuse to run headless — that is a clean exit and
#   passes. What fails is a segfault / access violation.
#
# Still out of reach, and not pretended otherwise: whether anything is drawn correctly,
# whether input works, whether the layout is right. Those need a human. This gate moves
# the line from "no gate touches a GUI" to "no gate touches a GUI *beyond startup*".
#
#   bash tools/gui_scaffold_check.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

ZEBRA="$REPO/zig-out/bin/zebra.exe"
EXAMPLE="${1:-examples/counter.zbr}"
FAIL=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '  \033[33m--\033[0m    %s\n' "$1"; }

[ -x "$ZEBRA" ] || { echo "no compiler at $ZEBRA — run \`zig build\` first" >&2; exit 2; }
[ -f "$EXAMPLE" ] || { echo "no example at $EXAMPLE" >&2; exit 2; }

echo "gui scaffold check — tui startup, on $(basename "$EXAMPLE")"
echo

BUILD_LOG=$(mktemp); trap 'rm -f "$BUILD_LOG"' EXIT
timeout 600 "$ZEBRA" --gui-backend=tui "$EXAMPLE" > "$BUILD_LOG" 2>&1
build_rc=$?

stem="$(basename "$EXAMPLE" .zbr)"
# The scaffold does NOT land in the repo — the compiler writes it to its temp root (on
# this machine C:\Presolved\tmp\<stem>_gui_tui). Searching only the repo found nothing and
# reported a build failure that had not happened. Recover the real location from the build
# log, which names it, and fall back to a repo search for other layouts.
scaffold_dir=$(grep -oE '[A-Za-z]:[\\/][^ "]*'"${stem}"'_gui_tui' "$BUILD_LOG" 2>/dev/null \
               | head -1 | tr '\\' '/')
main_zig=""
for cand in "$scaffold_dir/src/main.zig" "$scaffold_dir/main.zig" \
            "${stem}_gui_tui/src/main.zig" "${stem}_gui_tui/main.zig"; do
    [ -n "$cand" ] && [ -f "$cand" ] && main_zig="$cand" && break
done
if [ -z "$main_zig" ]; then
    main_zig=$(find . -maxdepth 3 -path "*_gui_tui*" -name main.zig 2>/dev/null | head -1)
fi

if [ -z "$main_zig" ] || [ ! -f "$main_zig" ]; then
    bad "no scaffolded main.zig found (build rc=$build_rc) — see log:"
    tail -8 "$BUILD_LOG" | sed 's/^/        /'
    echo; printf '\033[31mgui scaffold check: %d failure(s)\033[0m\n' "$((FAIL+1))"; exit 1
fi

# ── Leg 1: every declared `undefined` runtime pointer must be assigned ───────
# Generalised past the single BUG-229 symbol on purpose: the defect class is "the
# scaffold declares a global as undefined and the emit forgets to fill it in", and
# naming only _tui_env would let the next sibling through silently.
undef_vars=$(grep -oE '^var (_[A-Za-z_0-9]+): [^=]*= undefined;' "$main_zig" \
             | sed -E 's/^var (_[A-Za-z_0-9]+):.*/\1/' | sort -u)
if [ -z "$undef_vars" ]; then
    note "leg 1: no 'undefined' globals declared in $main_zig (nothing to check)"
else
    missing=""
    for v in $undef_vars; do
        grep -qE "^[[:space:]]*$v = " "$main_zig" || missing="$missing $v"
    done
    if [ -n "$missing" ]; then
        bad "declared-but-never-assigned global(s) in $main_zig:$missing"
        echo "        This is the BUG-229 shape: the scaffold declares the pointer and"
        echo "        Terminal.init dereferences it, so the app segfaults before drawing."
    else
        pass "every 'undefined' global in the scaffold is assigned ($(echo $undef_vars | wc -w) checked)"
    fi
fi

# ── Leg 2: the built app must not CRASH at startup ───────────────────────────
app=""
[ -n "$scaffold_dir" ] && app=$(find "$scaffold_dir" -name 'app.exe' 2>/dev/null | head -1)
[ -z "$app" ] && app=$(find . -maxdepth 4 -name 'app.exe' 2>/dev/null | head -1)
if [ -z "$app" ] || [ ! -x "$app" ]; then
    note "leg 2: skipped (no built app.exe — leg 1 still gates the regression)"
else
    out=$(timeout 15 "$app" < /dev/null 2>&1); rc=$?
    # CLASSIFY BY THE FAULT, NOT BY THE EXIT CODE, and not by the word "panic".
    #
    # Running headless, a healthy tui app panics with `gui init failed` from
    # enableRawMode -> GetConsoleFailed, and exits 3. That is CORRECT behaviour — there is
    # no console — and the first version of this check called it a crash purely because the
    # word "panic" appeared and rc was 3. It would have reported the BUG-229 fix as still
    # broken. What actually distinguishes the bug is a MEMORY fault: BUG-229 died in memcpy
    # at address 0x0 inside environ_map.get, long before reaching raw mode.
    if printf '%s' "$out" | grep -qiE 'segmentation fault|access violation|EXCEPTION_ACCESS|at address 0x0\b'; then
        bad "app hit a MEMORY fault at startup (rc=$rc) — the BUG-229 class:"
        printf '%s' "$out" | head -3 | sed 's/^/        /'
    elif printf '%s' "$out" | grep -qiE 'gui init failed|GetConsoleFailed|not a terminal|no console'; then
        pass "app reached terminal setup and refused a non-tty cleanly (rc=$rc)"
        note "      it got PAST environ_map.get — the BUG-229 crash site"
    elif [ "$rc" -eq 0 ]; then
        pass "app started and exited cleanly (rc=0)"
    else
        note "leg 2: inconclusive (rc=$rc, no known marker) — leg 1 still gates:"
        printf '%s' "$out" | head -3 | sed 's/^/        /'
    fi
fi

echo
echo "  NOT covered — still only a human can prove these:"
echo "    rendering correctness, input handling, layout, resize, colours"
echo

if [ "$FAIL" -gt 0 ]; then
    printf '\033[31mgui scaffold check: %d failure(s)\033[0m\n' "$FAIL"; exit 1
fi
printf '\033[32mgui scaffold check: startup path clean\033[0m\n'
