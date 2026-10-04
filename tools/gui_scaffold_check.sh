#!/usr/bin/env bash
# pins: BUG-298 the build-failure guard and the "did the RUNTIME leg run" summary
# pins: BUG-358 the panel_smoke registration (gui-scaffold-panel): a closure-taking builder in view() past 64 frames
# pins: BUG-340 the gui_modules_smoke registration: `use` deps emitted beside a GUI scaffold
# pins: BUG-355 gui_modules_smoke hands a CodeEditor across a module boundary
# pins: BUG-357 gui_modules_smoke's used module reads sys.args()
# below ARE the regression test -- what is asserted is this gate not claiming to
# have checked something it did not, which no test/*.zbr can express.
# gui_scaffold_check.sh — the gate that looks at a GUI path without a human.
#
# WHY THIS EXISTS
# ---------------
# BUG-229 was the FOURTH GUI crash to sit underneath a full set of green gates. A crash at
# STARTUP is not a rendering problem, and it does not need a human or a display to detect.
# BUG-229 itself: a scaffold DECLARED a pointer global `= undefined` that the emit never
# ASSIGNED, and every app segfaulted before drawing anything.
#
# WHAT CHANGED WITH ZIG 0.17 (2026-10-03, docs/design/zig017_migration.md)
# -----------------------------------------------------------------------
# Until then this gate BUILT and RAN a tui app headless. The tui backend is built on zigzag,
# which has no Zig 0.17 support, so it was dropped (Sean's call) and both legs moved:
#
# Leg 1 (STATIC, gates): the libui_ng scaffold (`--scaffold-only`: written, not built, not
#   run -- no network, no window) must ASSIGN every pointer global it declares `undefined`,
#   in main.zig or in the GUI section of its zebra_rt.zig. The BUG-229 shape, generalised.
# Leg 2 (RUNTIME, gates): the program runs on the STUB backend for $FRAMES frames
#   (ZEBRA_GUI_STUB_FRAMES), headless, and must neither fault nor panic -- and must REALLY
#   have run that many frames (the stub prints `[gui] frame N` under the knob; counted).
#   This is what keeps BUG-358's class covered: a closure-taking builder in view() that
#   exhausted a per-frame pool on the 65th frame. That plumbing is codegen plus the shared
#   runtime, the same for every backend (the gui-surface gate keeps the stub's verbs equal
#   to the real backends').
#
# What the move LOST, said rather than hidden: the tui app's own startup (terminal setup)
# is no longer run by anything -- the backend is refused. And as before: rendering, input,
# layout, resize and colours need a human running a real backend.
#
#   bash tools/gui_scaffold_check.sh [examples/foo.zbr]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
source "$REPO/tools/zig_toolchain.sh"   # the PINNED zig (.zig-version), not the shared ~/.zvm/bin default

ZEBRA="$REPO/zig-out/bin/zebra.exe"; [ -x "$ZEBRA" ] || ZEBRA="$REPO/zig-out/bin/zebra"   # Linux build name (09-08)
EXAMPLE="${1:-examples/counter.zbr}"
FRAMES="${GUI_SCAFFOLD_FRAMES:-100}"   # > 64: BUG-358 died on the 65th frame
FAIL=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '  \033[33m--\033[0m    %s\n' "$1"; }

[ -x "$ZEBRA" ] || { echo "no compiler at $ZEBRA — run \`zig build\` first" >&2; exit 2; }
[ -f "$EXAMPLE" ] || { echo "no example at $EXAMPLE" >&2; exit 2; }

echo "gui scaffold check — libui_ng scaffold + $FRAMES stub frames, on $(basename "$EXAMPLE")"
echo

# A PRIVATE scratch dir per run: a stale scaffold from an earlier run is the BUG-298 hazard
# (a dead run looking alive because an old artifact was still on disk).
SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
stem="$(basename "$EXAMPLE" .zbr)"

# ── Leg 1: every declared `undefined` pointer global must be assigned ─────────
timeout 300 "$ZEBRA" --gui-backend=libui_ng --scaffold-only --output-dir "$SCRATCH" "$EXAMPLE" > "$SCRATCH/scaffold.log" 2>&1
sc_rc=$?
main_zig="$SCRATCH/${stem}_gui_libui_ng/src/main.zig"
if [ "$sc_rc" -ne 0 ] || [ ! -f "$main_zig" ]; then
    # BUG-298: a failed scaffold is FATAL -- nothing below may run against a missing artifact.
    bad "the libui_ng SCAFFOLD FAILED (rc=$sc_rc, main.zig present: $([ -f "$main_zig" ] && echo yes || echo no)) — nothing below was checked:"
    tail -10 "$SCRATCH/scaffold.log" | sed 's/^/        /'
    echo; printf '\033[31mgui scaffold check: scaffold failed\033[0m\n'; exit 1
fi
rt_zig="$(dirname "$main_zig")/zebra_rt.zig"
section_txt=""
if [ -f "$rt_zig" ]; then
    # exact marker LINES: a prose comment mentions the marker too (refuter, 09-08)
    section_txt=$(awk '/^\/\/ === STDLIB_PREAMBLE_GUI_START ===$/{f=1} f{print} /^\/\/ === STDLIB_PREAMBLE_GUI_END ===$/{f=0}' "$rt_zig")
fi
# POINTER-typed only (`*` in the type): the BUG-229 shape. A `[N]T = undefined` scratch
# buffer is legitimately never "assigned" as a whole.
undef_vars=$( { grep -oE '^(pub )?var (_[A-Za-z_0-9]+): [^=[]*\*[^=]*= undefined;' "$main_zig"; printf '%s\n' "$section_txt" | grep -oE '^(pub )?var (_[A-Za-z_0-9]+): [^=[]*\*[^=]*= undefined;'; } 2>/dev/null \
             | sed -E 's/^(pub )?var (_[A-Za-z_0-9]+):.*/\2/' | sort -u)
if [ -z "$undef_vars" ]; then
    bad "leg 1: no 'undefined' pointer globals in $main_zig or the runtime's GUI section — the scaffold shape changed; this leg cannot see it"
else
    missing=""
    for v in $undef_vars; do
        if ! grep -qE "^[[:space:]]*(_zbr_rt\.)?$v = " "$main_zig" \
           && ! grep -qE "^[[:space:]]*$v = " <<< "$section_txt"; then
            # A HERE-STRING, not `printf | grep -q`: under `set -o pipefail`, grep -q exits at
            # its first match, printf dies of SIGPIPE writing the rest, and the pipeline FAILS
            # although grep matched. The tui section (557 lines) always finished writing first;
            # the libui_ng section (3,417) does not, and every assigned global read as missing.
            missing="$missing $v"
        fi
    done
    if [ -n "$missing" ]; then
        bad "declared-but-never-assigned pointer global(s):$missing — the BUG-229 shape"
    else
        pass "every 'undefined' pointer global in the libui_ng scaffold is assigned ($(echo $undef_vars | wc -w) checked: $(echo $undef_vars))"
    fi
fi

# ── Leg 2: $FRAMES headless frames on the stub, no fault, no panic ─────────────
out=$(ZEBRA_GUI_STUB_FRAMES="$FRAMES" timeout 300 "$ZEBRA" "$EXAMPLE" < /dev/null 2>&1); rc=$?
frames_seen=$(printf '%s\n' "$out" | grep -c '^\[gui\] frame [0-9]')
if printf '%s' "$out" | grep -qiE 'segmentation fault|access violation|EXCEPTION_ACCESS|at address 0x0\b'; then
    bad "the program hit a MEMORY fault (rc=$rc, after $frames_seen frame(s)) — the BUG-229 class:"
    printf '%s' "$out" | grep -aiE 'segmentation|access violation|address' | head -3 | sed 's/^/        /'
elif printf '%s' "$out" | grep -qE 'thread [0-9]+ panic: '; then
    # UNANCHORED on purpose: the banner can share a line with earlier output.
    bad "the program PANICKED (rc=$rc, after $frames_seen of $FRAMES frame(s)) — BUG-358's class if past frame 64:"
    printf '%s' "$out" | grep -aoE 'thread [0-9]+ panic: .*' | head -2 | sed 's/^/        /'
elif [ "$rc" -ne 0 ]; then
    bad "the program exited rc=$rc after $frames_seen of $FRAMES frame(s):"
    printf '%s\n' "$out" | grep -v '^\[gui\]' | tail -4 | sed 's/^/        /'
elif [ "$frames_seen" -ne "$FRAMES" ]; then
    # The positive control: without it, a stub that quietly ran ONE frame would pass a
    # check whose whole point is frame 65.
    bad "the stub ran $frames_seen frame(s), not the $FRAMES asked for — the frame leg measured nothing"
else
    pass "$FRAMES frames rendered headless on the stub backend, clean exit"
fi

echo
echo "  NOT covered — still only a human running a real backend can prove these:"
echo "    rendering correctness, input handling, layout, resize, colours"
echo

if [ "$FAIL" -gt 0 ]; then
    printf '\033[31mgui scaffold check: %d failure(s)\033[0m\n' "$FAIL"; exit 1
fi
printf '\033[32mgui scaffold check: startup path clean\033[0m\n'
