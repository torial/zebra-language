#!/usr/bin/env bash
# pins: BUG-298 the build-failure guard and the "did the RUNTIME leg run" summary
# pins: BUG-358 the panel_smoke registration (gui-scaffold-panel): a closure-taking builder in view() past 64 frames
# pins: BUG-340 the gui_modules_smoke registration: `use` deps emitted beside a GUI scaffold
# pins: BUG-355 gui_modules_smoke hands a CodeEditor across a module boundary
# pins: BUG-357 gui_modules_smoke's used module reads sys.args()
# below ARE the regression test -- what is asserted is this gate not claiming to
# have checked something it did not, which no test/*.zbr can express.
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

ZEBRA="$REPO/zig-out/bin/zebra.exe"; [ -x "$ZEBRA" ] || ZEBRA="$REPO/zig-out/bin/zebra"   # Linux build name (09-08)
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

# CLEAR THE SCAFFOLD SCRATCH FIRST. BUG-298 made a failed build FATAL rather than
# silently skippable, which was the important half -- but it did not address the CAUSE,
# and the cause recurs: a corrupted `.zig-cache` under the temp scaffold root makes zig
# fail with "unable to read results of configure phase", which is a genuine build failure
# that this gate then correctly reports. Correct, and a false red on the daily.
# Observed 2026-08-19 and again on the 2026-08-26 overnight tier, where it was the only
# failing gate and passed immediately once this directory was removed by hand.
#
# Safe to delete unconditionally: the compiler creates it, nothing else reads it, and a
# stale one is exactly the hazard. Scoped by the example basename so a parallel run on a
# different example is untouched -- the same argument kill_orphans.sh makes for scoping
# to this tree rather than the machine.
# THE COMPILER WRITES TO THE **WINDOWS** TEMP DIR, NOT GIT BASH'S /tmp. Those are
# different directories: $TMPDIR is unset here, so `${TMPDIR:-/tmp}` resolves to Git
# Bash's own /tmp while the scaffold lands under %TEMP%. The first version of this clear
# used the former, deleted nothing, and the gate still went green -- caught only by
# planting a marker file and finding it survived. A cleanup that silently cleans nothing
# is worse than none, because it looks like the hazard is handled.
_ex_base="$(basename "$EXAMPLE" .zbr)"
_tmp_root="${TEMP:-${TMP:-${TMPDIR:-/tmp}}}"
for _d in "$_tmp_root/${_ex_base}_gui_tui" "$_tmp_root/${_ex_base}_gui_libui_ng"; do
    [ -d "$_d" ] && rm -rf "$_d"
done

# `-c --check-full` scaffolds AND builds the project but does not RUN the app (leg 2
# runs it, under its own timeout). Running it here hung the gate for ten minutes on
# Linux, where a tui app with no tty happily draws to the alternate screen and waits
# for input instead of refusing (2026-09-08).
timeout 600 "$ZEBRA" -c --check-full --gui-backend=tui "$EXAMPLE" > "$BUILD_LOG" 2>&1
build_rc=$?

# BUG-298. A FAILED BUILD IS FATAL, full stop. This was captured and then used only inside
# a message, so a build that failed could still reach a green summary: leg 1 reads the
# scaffolded main.zig, and a PREVIOUS run leaves one on disk, so leg 1 kept passing while
# leg 2 "skipped (no built app.exe)" -- and the gate printed "startup path clean" about a
# scaffold that did not exist. Observed 2026-08-19 with a corrupted .zig-cache in the temp
# scaffold root; the tui path itself was fine, and what was broken was the gate's ability
# to say it had not checked it.
#
# Checked BEFORE anything reads an artifact, because the whole failure mode is a stale
# artifact making a dead run look alive.
# A NON-ZERO rc DOES NOT MEAN THE BUILD FAILED, and assuming it does breaks the gate on
# the HEALTHY path — caught by a negative control before it shipped. `--gui-backend=tui`
# scaffolds, builds AND RUNS the app, and the documented healthy outcome is the app
# refusing a non-tty console with rc=3, which `zig build run` reports as its own exit 1.
# So the discriminator is whether the app RAN, in the build tool own vocabulary. Verified
# against both captured logs: present on the healthy run, absent on a real compile failure.
if [ "$build_rc" -ne 0 ] && ! grep -q "process exited with error code" "$BUILD_LOG"; then
    bad "the scaffold BUILD FAILED (rc=$build_rc) — nothing below was checked:"
    tail -12 "$BUILD_LOG" | sed 's/^/        /'
    echo; printf '\033[31mgui scaffold check: build failed\033[0m\n'; exit 1
fi

stem="$(basename "$EXAMPLE" .zbr)"
# The scaffold does NOT land in the repo — the compiler writes it to its temp root (on
# this machine C:\Presolved\tmp\<stem>_gui_tui). Searching only the repo found nothing and
# reported a build failure that had not happened. Recover the real location from the build
# log, which names it, and fall back to a repo search for other layouts.
scaffold_dir=$(grep -oE '[A-Za-z]:[\\/][^ "]*'"${stem}"'_gui_tui' "$BUILD_LOG" 2>/dev/null \
               | head -1 | tr '\\' '/')
main_zig=""
# The temp-root candidate comes FIRST: it is the directory this script cleared above, so
# a main.zig there was written by THIS run. (Found 2026-09-09: on Linux the drive-letter
# grep matches nothing, and the repo-relative `find` below picked up a scaffold left by an
# earlier `--output-dir .` run — the stale-artifact hazard BUG-298 is about, one level up.)
for cand in "$_tmp_root/${stem}_gui_tui/src/main.zig" \
            "$scaffold_dir/src/main.zig" "$scaffold_dir/main.zig" \
            "${stem}_gui_tui/src/main.zig" "${stem}_gui_tui/main.zig"; do
    [ -n "$cand" ] && [ -f "$cand" ] && main_zig="$cand" && break
done
if [ -z "$main_zig" ]; then
    # THIS example's scaffold only — a repo-wide search once found another example's
    # stale scaffold (refuter, 09-08)
    main_zig=$(find . -maxdepth 4 -path "*/${stem}_gui_tui/*" -name main.zig 2>/dev/null | head -1)
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
# 2026-09-08: GUI projects share one runtime (zebra_rt.zig beside main.zig, the GUI
# section spliced in and pub-marked), so the scaffold's globals are DECLARED there and
# ASSIGNED from main.zig as `_zbr_rt._tui_env = …`. Scan the section region of the
# runtime file as well as main.zig, and accept either spelling of the assignment —
# in main.zig, or inside the runtime itself (a section that fills its own globals in
# an init function). Without this the leg went vacuous ("nothing to check") the day
# the runtime moved, which is exactly the shape BUG-298 warns about.
rt_zig="$(dirname "$main_zig")/zebra_rt.zig"
section_txt=""
if [ -f "$rt_zig" ]; then
    # exact marker LINES: a prose comment on line 5 of the runtime mentions the marker
    # too and made the region 3,733 lines instead of 557 (refuter, 09-08)
    section_txt=$(awk '/^\/\/ === STDLIB_PREAMBLE_GUI_START ===$/{f=1} f{print} /^\/\/ === STDLIB_PREAMBLE_GUI_END ===$/{f=0}' "$rt_zig")
fi
# POINTER-typed only (`*` in the type): that is the BUG-229 shape. A `[N]u8 = undefined`
# scratch buffer is legitimately never "assigned".
undef_vars=$( { grep -oE '^(pub )?var (_[A-Za-z_0-9]+): [^=]*\*[^=]*= undefined;' "$main_zig"; printf '%s\n' "$section_txt" | grep -oE '^(pub )?var (_[A-Za-z_0-9]+): [^=]*\*[^=]*= undefined;'; } 2>/dev/null \
             | sed -E 's/^(pub )?var (_[A-Za-z_0-9]+):.*/\2/' | sort -u)
if [ -z "$undef_vars" ]; then
    bad "leg 1: no 'undefined' globals declared in $main_zig or the runtime's GUI section — the scaffold shape changed; this leg cannot see it"
else
    missing=""
    for v in $undef_vars; do
        if ! grep -qE "^[[:space:]]*(_zbr_rt\.)?$v = " "$main_zig" \
           && ! printf '%s\n' "$section_txt" | grep -qE "^[[:space:]]*$v = "; then
            missing="$missing $v"
        fi
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
# The app of THIS scaffold only (the one main_zig lives in) — a repo-wide search once
# picked up a stale app from another example's scaffold (09-08).
this_scaffold="$(cd "$(dirname "$main_zig")/.." && pwd)"
app=$(find "$this_scaffold" \( -name 'app.exe' -o -name 'app' \) -type f 2>/dev/null | head -1)
if [ -z "$app" ] || [ ! -x "$app" ]; then
    note "leg 2: skipped (no built app.exe — leg 1 still gates the regression)"
    LEG2_RAN=0
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
    elif [ "$rc" -eq 124 ] && printf '%s' "$out" | grep -qF '[?1049h'; then
        pass "app drew to the terminal and was still running at the 15 s timeout (Linux: no refusal, it just runs)"
        note "      it got PAST environ_map.get — the BUG-229 crash site"
    elif printf '%s' "$out" | grep -qE 'thread [0-9]+ panic: '; then
        # UNANCHORED on purpose: the banner lands on the same line as the last frame's
        # escape sequences (no newline precedes it) — an anchored `^thread` filed the
        # BUG-358 mutant as INCONCLUSIVE on the first red-control run.
        # BUG-358: panel_smoke drew 64 frames and then died ("closure-via-sig pool
        # exhausted") — rc=1 with a panic banner, which the branch below filed as
        # INCONCLUSIVE. A panic past startup is a crash, not an unknown outcome; only the
        # documented healthy refusal (matched above) is allowed to say "panic" and pass.
        bad "app PANICKED after starting (rc=$rc):"
        printf '%s' "$out" | grep -aoE 'thread [0-9]+ panic: .*' | head -2 | sed 's/^/        /'
    else
        LEG2_RAN=0
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
# BUG-298: SAY WHICH LEGS ACTUALLY RAN. "startup path clean" is a claim about the RUNTIME
# leg; printing it when that leg never executed is the exact false-green this gate was
# caught giving. Half a GUI gate reporting as a whole one takes the repo's only automated
# GUI coverage back to zero without anyone noticing.
if [ "${LEG2_RAN:-1}" -eq 0 ]; then
    printf '\033[33mgui scaffold check: leg 1 clean; RUNTIME leg did NOT run (see above)\033[0m\n'
    exit 0
fi
printf '\033[32mgui scaffold check: startup path clean\033[0m\n'
