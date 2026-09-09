#!/usr/bin/env bash
# pins: BUG-300 the three failure-shape legs below ARE the regression test -- no
# test/*.zbr can express it, because what is asserted is what the compiler leaves
# behind in TMPDIR after it exits, not anything about the program it compiled.
# runtime_module_check.sh — end-to-end gate for runtime-module emission (#1),
# which has been the DEFAULT since 2026-07-28 (`--no-runtime-module` opts out).
#
# WHY A SEPARATE GATE
# -------------------
# `compile_check.sh` proves the emitted Zig COMPILES across the corpus, which is the
# big coverage win. It cannot prove three things that are the whole point of the
# change, because it never runs anything and never looks at the shape of what was
# emitted:
#
#   1. BUG-221 — module init is not transitive. A three-module program whose
#      DEEPEST module touches a file segfaults at 0xffffffffffffffff, because the
#      entry point initialised direct dependencies only. It compiles perfectly.
#      Only running it shows the bug, and only running it shows the fix.
#   2. That the runtime was actually externalised. If a future change quietly fell
#      back to splicing the preamble, everything would still compile and still run
#      — and the emitted file would be 3,800 lines again. The size assertion is
#      what makes "it worked" mean something.
#
#   3. That the routes users actually take work. Checks 1-2 drive
#      `--emit-zig --output-dir` and then invoke `zig` by hand; `zebra run` and
#      `zebra -c` take a DIFFERENT branch of zbrToZig (a temp dir, not
#      `--output-dir`) and let the compiler drive zig itself. One write site covers
#      every route by construction — but that is an argument from reading the code,
#      so §3 exercises them.
#
#   4. That the INLINE runtime still works. It is no longer the default, so it is
#      now the shape that can rot unnoticed — and it is still live, both via the
#      opt-out and as the fallback for every path the split runtime does not cover.
#
# All of it is cheap (a handful of tiny programs), so this runs in the QUICK tier.
#
#   bash tools/runtime_module_check.sh
#
# Note the checks deliberately pass NO flag where they can: `--runtime-module` is a
# no-op now, so a gate that passed it would still go green if the default silently
# reverted to inlining. Asserting on the default is the point.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

ZEBRA="$REPO/zig-out/bin/zebra.exe"; [ -x "$ZEBRA" ] || ZEBRA="$REPO/zig-out/bin/zebra"   # Linux build name (09-08)
OUT="${TMPDIR:-/tmp}/zbr-rtmod-$$"
FAIL=0

cleanup() { rm -rf "$OUT"; }
trap cleanup EXIT

pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -x "$ZEBRA" ] || { echo "runtime-module: $ZEBRA missing — run 'zig build'"; exit 1; }

echo "runtime-module gate"
echo

# ── 1. hello-world: emits, externalises the runtime, compiles, runs ───────────
hw="$OUT/hw"; mkdir -p "$hw"
printf 'def main()\n    print("hi")\n' > "$hw/hw.zbr"
if ! "$ZEBRA" --emit-zig --output-dir "$hw" "$hw/hw.zbr" >/dev/null 2>&1; then
    fail "hello-world did not emit"
else
    lines=$(wc -l < "$hw/hw.zig" | tr -d ' ')
    if [ ! -f "$hw/zebra_rt.zig" ]; then
        fail "zebra_rt.zig was not written beside the program"
    elif [ "$lines" -gt 100 ]; then
        # The inline shape is ~3,790 lines. Anything near that means the runtime
        # was spliced in after all and the split silently regressed.
        fail "emitted program is $lines lines — the runtime was NOT externalised"
    elif ! ( cd "$hw" && zig build-exe hw.zig -fno-llvm -fno-lld -femit-bin=hw.exe >/dev/null 2>&1 ); then
        fail "emitted hello-world does not compile"
    elif [ "$("$hw/hw.exe" 2>&1)" != "hi" ]; then
        fail "emitted hello-world does not run"
    else
        pass "hello-world: $lines-line program + shared runtime, compiles and runs"
    fi
fi

# ── 2. BUG-221: transitive module init (the reason the change exists) ─────────
b="$OUT/b221"; mkdir -p "$b"
cp test/bug221_transitive_init_leaf.zbr test/bug221_transitive_init_mid.zbr \
   test/bug221_transitive_init_test.zbr "$b/" 2>/dev/null || {
       fail "BUG-221 fixture missing from test/"; }
if [ -f "$b/bug221_transitive_init_test.zbr" ]; then
    if ! "$ZEBRA" --emit-zig --output-dir "$b" \
            "$b/bug221_transitive_init_test.zbr" >/dev/null 2>&1; then
        fail "BUG-221 fixture did not emit"
    elif ! ( cd "$b" && zig build-exe bug221_transitive_init_test.zig \
                -fno-llvm -fno-lld -femit-bin=b221.exe >/dev/null 2>&1 ); then
        fail "BUG-221 fixture does not compile"
    else
        got=$("$b/b221.exe" 2>&1)
        if [ "$got" = "missing" ]; then
            pass "BUG-221: depth-2 dep initialises and runs (was: segfault)"
        else
            fail "BUG-221: expected 'missing', got: $got"
        fi
    fi
fi

# ── 3. the paths users actually invoke ───────────────────────────────────────
# Checks 1 and 2 drive `--emit-zig --output-dir` and then run `zig` by hand. That
# is NOT the route a user takes, and it is not even the same code path: without
# `--output-dir`, zbrToZig emits into a TEMP dir instead, and the compiler invokes
# zig itself. `zebra_rt.zig` has to land there too and the relative `@import` has
# to resolve from there. One write site covers every route by construction — but
# that is an argument from reading the code, so exercise the routes.
# NOTE: Zebra's `print` emits `std.debug.print`, which writes to STDERR (true with
# and without the flag — verified against the default path). So these read the
# combined stream; discarding stderr here silently asserts nothing.
if [ "$("$ZEBRA" run "$hw/hw.zbr" 2>&1 | tail -1)" = "hi" ]; then
    pass "zebra run (temp-dir emit) runs"
else
    fail "zebra run did not print 'hi'"
fi

if "$ZEBRA" -c "$hw/hw.zbr" >/dev/null 2>&1; then
    # A check that passes everything is not a check. `-c` takes the fast backend
    # with a fallback to LLVM on failure, so confirm a real error still surfaces
    # rather than being swallowed by the fallback.
    printf 'def main()\n    var s: str = "x" + 1\n    print(s)\n' > "$hw/bad.zbr"
    if "$ZEBRA" -c "$hw/bad.zbr" >/dev/null 2>&1; then
        fail "zebra -c accepted a program with a type error"
    else
        pass "zebra -c passes clean code and rejects bad code"
    fi
else
    fail "zebra -c rejected a valid program"
fi

# Multi-module through the temp-dir route: the deps and the runtime all have to
# land in the same directory for the basename @imports to resolve.
if [ "$("$ZEBRA" run test/bug221_transitive_init_test.zbr 2>&1 | tail -1)" = "missing" ]; then
    pass "zebra run resolves a 3-module program + the runtime"
else
    fail "zebra run failed on the 3-module fixture"
fi

# ── 4. the opt-out and the fallbacks still produce the INLINE runtime ────────
# The split runtime is the default now, so the INLINE shape is the one that can rot
# unnoticed. It is still live: --no-runtime-module selects it, and every path the
# split runtime does not cover (--single-file, --target node-addon, --gui-backend)
# falls back to it. A fallback that silently emitted the SPLIT shape would produce a
# program importing a zebra_rt.zig that its own scaffold never places — that failure
# would appear only in those paths, which no other gate exercises.
off="$OUT/off"; mkdir -p "$off"
if ! "$ZEBRA" --emit-zig --output-dir "$off" --no-runtime-module "$hw/hw.zbr" >/dev/null 2>&1; then
    fail "--no-runtime-module did not emit"
elif [ -f "$off/zebra_rt.zig" ]; then
    fail "--no-runtime-module still wrote zebra_rt.zig"
elif [ "$(wc -l < "$off/hw.zig" | tr -d ' ')" -lt 1000 ]; then
    fail "--no-runtime-module did not inline the runtime"
elif ! ( cd "$off" && zig build-exe hw.zig -fno-llvm -fno-lld -femit-bin=off.exe >/dev/null 2>&1 ); then
    fail "--no-runtime-module output does not compile"
elif [ "$("$off/off.exe" 2>&1)" != "hi" ]; then
    fail "--no-runtime-module output does not run"
else
    pass "--no-runtime-module inlines the runtime, compiles and runs"
fi

# BUG-221 on the INLINE path. The inline runtime is not a museum piece: it is what
# --no-runtime-module selects and what --single-file, --target node-addon and every
# --gui-backend fall back to. It kept the direct-deps-only init sweep until 2026-07-29
# and reproduced the segfault exactly; a multi-module GUI app touching a file from
# depth 2 would have hit it. Nothing else covers those paths, so assert it here.
bi="$OUT/b221i"; mkdir -p "$bi"
cp test/bug221_transitive_init_leaf.zbr test/bug221_transitive_init_mid.zbr \
   test/bug221_transitive_init_test.zbr "$bi/" 2>/dev/null
if ! "$ZEBRA" --emit-zig --output-dir "$bi" --no-runtime-module \
        "$bi/bug221_transitive_init_test.zbr" >/dev/null 2>&1; then
    fail "BUG-221 fixture did not emit with --no-runtime-module"
elif ! ( cd "$bi" && zig build-exe bug221_transitive_init_test.zig \
            -fno-llvm -fno-lld -femit-bin=b221i.exe >/dev/null 2>&1 ); then
    fail "BUG-221 fixture does not compile with --no-runtime-module"
else
    got=$("$bi/b221i.exe" 2>&1)
    if [ "$got" = "missing" ]; then
        pass "BUG-221: fixed on the INLINE path too (was: segfault)"
    else
        fail "BUG-221 inline: expected 'missing', got: $got"
    fi
fi

sf="$OUT/sf"; mkdir -p "$sf"
if "$ZEBRA" --emit-zig --output-dir "$sf" --single-file "$hw/hw.zbr" >/dev/null 2>&1 \
   && [ ! -f "$sf/zebra_rt.zig" ]; then
    pass "--single-file falls back to the inline runtime"
else
    fail "--single-file did not fall back to the inline runtime"
fi

# pins: BUG-282 the two legs below ARE its regression test. --output-dir at a
# pins: BUG-282 nonexistent path used to panic; that is a CLI behaviour, so no
# pins: BUG-282 test/*.zbr can carry it and selfhost_smoke cannot see it. This gate
# pins: BUG-282 already drives --output-dir, which is why it hosts them.
# BUG-282: --output-dir at a path that does not exist used to PANIC (`File.write error`,
# empty stack trace) AFTER printing `parsed OK` / `resolved OK` -- every part of which
# points the reader at their program. It is now created at ARGUMENT-PARSING time and the
# creation is announced.
#
# Hosted here because this is the gate that already drives --output-dir, and because the
# failure is a CLI behaviour: no test/*.zbr can carry it, so smoke cannot see it.
#
# ASSERTS ON THE PRINTED MESSAGE, NOT THE EXIT CODE -- the ticket's own instruction. The
# old panic exited 3, and 3 is produced by unrelated failures too, so scoring on it would
# pass a compiler that died for a different reason.
missing="$OUT/made/up/deep"
rm -rf "$OUT/made"
got=$("$ZEBRA" --emit-zig --output-dir "$missing" "$hw/hw.zbr" 2>&1)
# The panic grep must not read the emitted SOURCE (`--emit-zig` echoes it, and every
# program carries `pub const panic = std.debug.FullPanic(...)`): look for the runtime's
# panic banner, not the word (refuter, 2026-09-08 — this conjunct failed on Linux and
# would have on Windows too).
if echo "$got" | grep -q "created output directory"    && [ -f "$missing/hw.zig" ]    && ! echo "$got" | grep -qE "^thread [0-9]+ panic|panic: "; then
    pass "--output-dir at a missing path is created, announced, and emitted into"
else
    fail "--output-dir at a missing path: expected a 'created output directory' line and hw.zig, got: $got"
fi

# ...and the SILENT half: an existing directory must not grow a new line of noise. A
# fix that announced on every run would be its own regression.
got2=$("$ZEBRA" --emit-zig --output-dir "$missing" "$hw/hw.zbr" 2>&1)
if ! echo "$got2" | grep -q "created output directory"; then
    pass "--output-dir at an EXISTING path stays silent"
else
    fail "--output-dir announced a creation for a directory that already existed"
fi

# pins: BUG-244 `zebra <file>` built a ~20 MB executable into TMPDIR and never removed
# pins: BUG-244 it -- 6,413 files / 120 GB observed. Cleanup happens on a CLEAN exit
# pins: BUG-244 only; a failing program keeps its .zig and binary because those ARE the
# pins: BUG-244 debugging evidence. `--keep-temp` opts out. CLI behaviour, so no
# pins: BUG-244 test/*.zbr can carry it and smoke cannot see it.
#
# THE TEMP DIR IS THE WINDOWS ONE, and that trap already cost one attempt: zebra.exe is a
# Windows binary reading TMP/TEMP, while Git Bash sets TMPDIR to the MSYS mount /tmp. A
# check that looks at $TMPDIR watches the wrong directory and reports a clean ~20 MB while
# 120 GB sits elsewhere. Ask the compiler where it actually wrote instead of assuming.
# On Linux the compiler makes a per-run mkdtemp subdirectory of $TMPDIR; on Windows it
# writes into TEMP itself. Look one level down too (2026-09-09), newest first.
wintmp=$("$ZEBRA" --keep-temp "$hw/hw.zbr" >/dev/null 2>&1; ls -dt "${TEMP:-${TMP:-/tmp}}"/hw.zig "${TEMP:-${TMP:-/tmp}}"/*/hw.zig 2>/dev/null | head -1)
if [ -n "$wintmp" ]; then
    tdir=$(dirname "$wintmp")
    rm -f "$tdir"/hw.zig "$tdir"/hw.zig.fast.exe "$tdir"/hw.zig.llvm.exe 2>/dev/null
    "$ZEBRA" "$hw/hw.zbr" >/dev/null 2>&1
    left=$(ls "$tdir"/hw.zig "$tdir"/hw.zig.*.exe 2>/dev/null | wc -l)
    if [ "$left" -eq 0 ]; then
        pass "a successful run leaves no scratch build in the temp dir"
    else
        fail "a successful run left $left scratch file(s) in $tdir"
    fi

    # BUG-300, 2026-08-23. THE SUCCESS PATH WAS THE ONLY ONE CHECKED, and it was the one
    # that already worked. Three separate leaks lived in the paths below:
    #   - the .pdb sibling had NO delete call at all (435 files / 1.4 GB measured)
    #   - a FAILING run kept its 20 MB binary by policy
    #   - the COMPILE-FAILURE exit had no cleanup whatever, so the most ordinary failure
    #     a user can hit orphaned a full binary
    # A gate that only exercises success cannot see any of them.
    #
    # THE POLICY BEING PINNED: the emitted .zig SURVIVES a failure (it is the diagnostic
    # artifact); executables and .pdb NEVER survive (`zig build-exe <the .zig>` rebuilds
    # them). Each leg below asserts BOTH halves -- a fix that deleted everything would
    # pass a "no binary" check while destroying the evidence.
    for shape in compile runtime; do
        if [ "$shape" = compile ]; then
            # Must pass the type checker and fail in zig (BUG-375 made
            # `x.nosuch()` on an int a typecheck refusal, so no .zig was emitted).
            # List(int).add("s") is currently unchecked at the Zebra level.
            printf 'def main()\n    var xs = List(int).new()\n    xs.add("s")\n' > "$hw/zzfail.zbr"
        else
            printf 'def main()\n    print("x")\n    sys.exit(3)\n' > "$hw/zzfail.zbr"
        fi
        rm -f "$tdir"/zzfail.zig "$tdir"/zzfail.zig.*.exe "$tdir"/zzfail.zig.*.pdb 2>/dev/null
        "$ZEBRA" "$hw/zzfail.zbr" >/dev/null 2>&1
        bins=$(ls "$tdir"/zzfail.zig.*.exe "$tdir"/zzfail.zig.*.pdb 2>/dev/null | wc -l)
        src=$(ls "$tdir"/zzfail.zig 2>/dev/null | wc -l)
        if [ "$bins" -ne 0 ]; then
            fail "a $shape-failure run left $bins binary/pdb file(s) in $tdir"
        elif [ "$src" -ne 1 ]; then
            fail "a $shape-failure run did NOT keep the emitted .zig — the evidence is gone"
        else
            pass "a $shape-failure run keeps the .zig and no binary"
        fi
        rm -f "$tdir"/zzfail.zig "$tdir"/zzfail.zig.*.exe "$tdir"/zzfail.zig.*.pdb "$hw/zzfail.zbr" 2>/dev/null
    done
    if false; then
        :
    fi

    # ...and the OPPOSITE direction, which is what stops this becoming a fix that
    # deletes the evidence: --keep-temp must still leave them.
    rm -f "$tdir"/hw.zig "$tdir"/hw.zig.*.exe 2>/dev/null
    "$ZEBRA" --keep-temp "$hw/hw.zbr" >/dev/null 2>&1
    kept=$(ls "$tdir"/hw.zig "$tdir"/hw.zig.*.exe 2>/dev/null | wc -l)
    if [ "$kept" -gt 0 ]; then
        pass "--keep-temp still leaves the scratch build"
    else
        fail "--keep-temp deleted the scratch build anyway"
    fi
    rm -f "$tdir"/hw.zig "$tdir"/hw.zig.*.exe 2>/dev/null

    # THIRD LEG, and it exists because the first version of the fix got this WRONG.
    # `--output-dir` means "put the output HERE" -- it is not scratch, and deleting it
    # destroys exactly what the user asked for. contract_mode_check caught it: it runs
    # `--turbo --output-dir DIR` and then READS the .zig, and its two --turbo legs went
    # blind. Note which legs failed: only the ones where the program EXITS 0, because
    # stripped contracts do not fire. The others passed only because their contracts
    # failed and the non-zero exit happened to keep the files.
    od="$OUT/keepdir"; rm -rf "$od"; mkdir -p "$od"
    "$ZEBRA" --output-dir "$od" "$hw/hw.zbr" >/dev/null 2>&1
    if [ -f "$od/hw.zig" ]; then
        pass "--output-dir output SURVIVES a successful run (it is not scratch)"
    else
        fail "--output-dir output was deleted after a successful run"
    fi
else
    fail "BUG-244: could not locate the compiler's temp dir, so the leak check never ran"
fi

echo
if [ "$FAIL" -gt 0 ]; then
    printf '\033[31mruntime-module: %d check(s) FAILED\033[0m\n' "$FAIL"
    exit 1
fi
printf '\033[32mruntime-module: all checks pass\033[0m\n'
