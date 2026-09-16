#!/usr/bin/env bash
# rebuild.sh — make a `selfhost/*.zbr` edit REAL, correctly, in one command.
#
# WHY THIS EXISTS
# ---------------
# Editing a `.zbr` in selfhost/ does nothing on its own. The compiler you run is
# built from the *generated* `selfhost/*.zig`, so a source change only takes
# effect after: regenerate the .zig via the selfhost (N-1), then rebuild zebra.exe.
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
#   4. (RETIRED 2026-09-16 with the bootstrap, sunset Step 3.) The Zig-implemented
#      bootstrap EMBEDDED the preamble files at its own build time, so after a
#      preamble edit a regen with the existing binary emitted the OLD runtime
#      (observed 2026-07-28, and again 2026-08-26 for a src/*.zig edit). The
#      selfhost reads selfhost/stdlib_preamble.zig FROM DISK at codegen time,
#      repo-relative first, so the regen always sees the current preamble and
#      there is no binary to be stale against. The guard, and
#      tools/rebuild_guard_check.sh that falsified it, are in tools/attic/.
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
# SELFHOST built from the COMMITTED .zig -- the previous generation of itself -- whose
# output for the other modules your edit cannot have changed. NOTE: --module now emits
# the WHOLE program and installs one file, because emitting a module as a ROOT produces
# different output than emitting it as a DEPENDENCY (measured: 648 vs 643 lines for
# Token.zig, the extra being `fn _zbr_error_msg()`).
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
# what made BUG-219's first fix appear not to work.
#
# What this does NOT do: run any gate. Use tools/gates.sh for that.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

# Binary names differ by host: `zebra.exe` on Windows (the primary dev box), `zebra`
# on Linux (the cloud container). Every check below reads these, never a literal.
# (2026-09-08: the literal `.exe` made a SUCCESSFUL Linux build report "missing".)
ZEXE=zig-out/bin/zebra.exe
[[ "$(uname -s)" == Linux ]] && ZEXE=zig-out/bin/zebra

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

# Run `zig build`, and on failure SHOW THE ERROR rather than the epilogue.
#
# This used to be `zig build 2>&1 | tail -6`. On success that is the right summary; on
# FAILURE the last six lines of a zig build are the build-graph epilogue ("install
# transitive failure", the re-issued build command, the seed) and the compile errors are
# further up, so the one thing the reader needs is the one thing that scrolls away. On
# 2026-08-16 that turned a one-line diagnosis ("unreachable else prong; all cases already
# handled") into two wasted rebuild cycles: the caret line survived, the message above it
# did not.
#
# UNGIT "nothing withheld" — the tool HAS the error; it must not print boilerplate
# instead. The full log path is named too, because a 40-line cap is a judgement call and
# the reader deserves the escape hatch when it guesses wrong.
zbuild_or_fail() { # $1 = message for fail()
    local log="/tmp/_rebuild_build.log"
    if zig build > "$log" 2>&1; then
        tail -6 "$log"
        return 0
    fi
    grep -E -B1 -A4 'error:' "$log" 2>/dev/null | head -40 >&2 \
        || tail -20 "$log" >&2
    printf '  (full build log: %s)\n' "$log" >&2
    fail "$1"
}

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
    if [[ -n "$MODULES" ]]; then
        # ---- single-module regen -------------------------------------------------
        # Extracted from tools/mutation_check.py's regen(), which has run this path
        # thousands of times. Two details are load-bearing and both are documented there:
        #   * redirect to a FILE, never a pipe. The bootstrap's emit is large and a
        #     blocked pipe looks exactly like a compiler that refused the input — that
        #     confusion produced 80% of a published, later-retracted result.
        #   * the emitted text is written with LF only. Python is not the only thing that
        #     can put a CR in a .zig; be explicit anyway.
        # N-1 (criterion 2, 2026-08-30): the regen authority is the SELFHOST, matching
        # tools/bootstrap_check.sh. Emitting one module here with a DIFFERENT compiler than
        # the full regen uses would leave that module in the other emitter's shape.
        BOOT="$ZEXE"
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
            step "regenerating selfhost/$m.zig via the selfhost (N-1 regen authority)"
            # EMIT THE WHOLE PROGRAM AND INSTALL ONE FILE. Emitting "selfhost/$m.zbr" directly
            # makes it a ROOT, and a root gets scaffolding a DEPENDENCY does not -- measured:
            # Token.zig is 643 lines as a dependency and 648 as a root, the extra five being
            # `fn _zbr_error_msg()`. The full regen emits from main.zbr, so a per-module emit here
            # would install a file the full regen would never produce, and the tree would differ
            # depending on which command last touched it. That is the mixed-tree hazard, and the
            # first version of this change walked straight into it -- caught because regenerating
            # an UNCHANGED module must be byte-identical, and it was not.
            #
            # Costs one whole-program emit (~11 s) instead of ~1 s. Still far cheaper than the full
            # rebuild, which is what --module exists to avoid.
            #
            # --output-dir, never a stdout redirect: this compiler writes ZERO BYTES to one
            # (BUG-317), and the bare form also writes DEPENDENCIES next to the source (BUG-325),
            # which would rewrite selfhost/ behind your back.
            tmpd="$(mktemp -d)"
            if ! "$BOOT" --emit-zig --output-dir "$tmpd" selfhost/main.zbr >/dev/null 2>/tmp/_rebuild_mod_err; then
                tail -5 /tmp/_rebuild_mod_err >&2
                rm -rf "$tmpd"
                fail "the bootstrap refused selfhost/$m.zbr — selfhost/$m.zig left untouched"
            fi
            tmp="$tmpd/$m.zig"
            # The bootstrap prints progress chatter before the emitted source; the header
            # is where the actual Zig starts. Its ABSENCE with rc=0 is the silent-failure
            # case, so it is checked rather than assumed.
            if ! grep -qF "// Generated by" "$tmp" 2>/dev/null; then
                rm -rf "$tmpd"
                fail "the bootstrap emitted no source for $m despite rc=0 — refusing to write a truncated selfhost/$m.zig"
            fi
            tr -d '\r' < "$tmp" > "selfhost/$m.zig"
            rm -rf "$tmpd"
            echo "  selfhost/$m.zig  ($(wc -l < "selfhost/$m.zig") lines)"
        done
    else

    # Footgun 2: stale state from a killed run.
    step "clearing stale /tmp/bs-zig"
    rm -rf /tmp/bs-zig

    # Footgun 1: call bootstrap_check.sh DIRECTLY. Never `zig build update-selfhost`.
    step "regenerating selfhost/*.zig via the selfhost (N-1 regen authority)"
    if ! bash "$SCRIPT_DIR/bootstrap_check.sh" --update 2>&1 | tail -3; then
        fail "regeneration failed — selfhost/*.zig was restored from the pre-run snapshot"
    fi
    fi
fi

step "building zebra.exe"
zbuild_or_fail "zig build failed"

step "result"
if [[ -x "$ZEXE" ]]; then
    printf 'def main()\n    print("rebuild ok")\n' > /tmp/_rebuild_probe.zbr
    if out=$(timeout 120 "./$ZEXE" run /tmp/_rebuild_probe.zbr 2>&1) \
       && echo "$out" | grep -qF "rebuild ok"; then
        echo "  zebra.exe builds and runs"
        # Record WHICH generated Zig this binary was built from, so doctor can tell a
        # finished build from an interrupted one. CONTENT, not mtime: bootstrap_check
        # restores selfhost/*.zig byte-identically, so any timestamp-based check false-
        # positives after every round-trip gate (it did, twice, and blocked the tier).
        cat selfhost/*.zig 2>/dev/null | sha1sum | cut -d' ' -f1 > zig-out/.selfhost-stamp 2>/dev/null || true
    else
        fail "zebra.exe was built but cannot run a hello-world — something is badly wrong"
    fi
else
    fail "$ZEXE missing after build"
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
if [[ -x "$ZEXE" ]]; then
    touch "$ZEXE"
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
