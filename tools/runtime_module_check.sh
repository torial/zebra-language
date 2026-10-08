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
source "$REPO/tools/zig_toolchain.sh"   # the PINNED zig (.zig-version), not the shared ~/.zvm/bin default

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

# BUG-536: a dependency found on --module-path is read for TYPES only; a HOST supplies its
# .zig. The entry point @imports it but never initialised it, so its module-level List was
# `undefined` and the first append segfaulted. Arranged as a host does: the root emitted with
# --module-path, the library emitted separately into the same directory, then built by hand.
mp="$OUT/b536"; mkdir -p "$mp/lib" "$mp/app/out"
cp test/bug539_dep_mod.zbr "$mp/lib/" 2>/dev/null || fail "BUG-536: support module missing from test/"
printf 'use bug539_dep_mod\n\ndef main()\n    bug539_dep_mod.addItem(1)\n    print("b536 " + bug539_dep_mod.count().toString())\n' > "$mp/app/main536.zbr"
if ! ( cd "$mp/app" && "$ZEBRA" --emit-zig --module-path ../lib --output-dir out main536.zbr >/dev/null 2>&1 ); then
    fail "BUG-536: the root did not emit with --module-path"
elif ! ( cd "$mp/lib" && "$ZEBRA" --emit-zig --output-dir ../app/out bug539_dep_mod.zbr >/dev/null 2>&1 ); then
    fail "BUG-536: the host side (the library's own emit) failed"
elif ! ( cd "$mp/app/out" && zig build-exe main536.zig -fno-llvm -fno-lld -femit-bin=m536.exe >/dev/null 2>&1 ); then
    fail "BUG-536: the host-assembled program does not compile"
else
    got=$("$mp/app/out/m536.exe" 2>&1)
    if [ "$got" = "b536 1" ]; then
        pass "BUG-536: a --module-path dependency supplied by a host is initialised (was: segfault)"
    else
        fail "BUG-536: expected 'b536 1', got: $got"
    fi
fi

# BUG-539 on the INLINE path: the class-`static main` and `zebra test` entries initialise
# their dependencies there too (`_initAllocator`/`_initIo` per dependency, not
# `_initModuleVars`). The smoke suite registers both fixtures on the default shape only.
got=$("$ZEBRA" --no-runtime-module test/bug539_static_main_test.zbr 2>&1 | tail -1)
if [ "$got" = "bug539 static: 2/1" ]; then
    pass "BUG-539: a class static main initialises its dependencies on the INLINE path"
else
    fail "BUG-539 inline static main: expected 'bug539 static: 2/1', got: $got"
fi
if out=$("$ZEBRA" test --no-runtime-module test/bug539_test_entry_test.zbr 2>&1) && ! printf '%s' "$out" | grep -qF "FAIL:"; then
    pass "BUG-539: the zebra test entry initialises its dependencies on the INLINE path"
else
    fail "BUG-539 inline zebra test: $(printf '%s' "$out" | tail -3)"
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
# BUG-513 (2026-10-02): each run builds in its OWN `<TEMP>/zebra-<n>/`, removed on a clean
# exit and on a front-end failure, KEPT (and named on stderr) when the build or the program
# fails or --keep-temp asks. These legs run in a PRIVATE TEMP so that counting `zebra-*`
# directories measures this run and nothing else on the machine. Every count is preceded by
# a positive control (a --keep-temp run must leave exactly one), so a zero below is a
# measurement and not a blind spot.
st_priv="$(mktemp -d)"
st_win="$st_priv"; command -v cygpath >/dev/null 2>&1 && st_win="$(cygpath -w "$st_priv")"
zrun() { TMP="$st_win" TEMP="$st_win" TMPDIR="$st_priv" "$ZEBRA" "$@" 2>&1 >/dev/null; }
ndirs() { ls -d "$st_priv"/zebra-* 2>/dev/null | wc -l; }
named() { sed -n 's/^note: the scratch build is kept in //p' | tail -1 | tr -d '\r'; }
upath() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
clean_priv() { rm -rf "${st_priv:?}"/zebra-* 2>/dev/null; }

# 1. CONTROL: --keep-temp keeps exactly one directory, names it, and it holds hw.zig
err=$(zrun --keep-temp "$hw/hw.zbr"); kd=$(printf '%s\n' "$err" | named)
if [ "$(ndirs)" -eq 1 ] && [ -n "$kd" ] && [ -f "$(upath "$kd")/hw.zig" ]; then
    pass "--keep-temp keeps ONE scratch directory, names it, and it holds the .zig"
    st_ok=1
else
    fail "--keep-temp control: $(ndirs) dir(s), named '$kd' -- the legs below cannot be trusted"
    st_ok=0
fi
clean_priv

if [ "$st_ok" = 1 ]; then
    # 2. a successful run leaves nothing
    zrun "$hw/hw.zbr" >/dev/null
    if [ "$(ndirs)" -eq 0 ]; then pass "a successful run leaves no scratch directory"
    else fail "a successful run left $(ndirs) scratch directory(ies)"; fi
    clean_priv

    # 3. a FRONT-END failure leaves nothing -- even after a dep was already written
    mkdir -p "$hw/fe"
    printf 'def helper(): int\n    return 1\n' > "$hw/fe/fedep.zbr"
    printf 'use fedep\ndef main()\n    var s: str = 5\n    print(s)\n' > "$hw/fe/feroot.zbr"
    err=$(zrun "$hw/fe/feroot.zbr")
    if [ "$(ndirs)" -eq 0 ] && ! printf '%s' "$err" | grep -q 'scratch build is kept'; then
        pass "a front-end failure leaves no scratch directory (deps already written are removed)"
    else
        fail "a front-end failure left $(ndirs) directory(ies) -- one per failed attempt is BUG-244 again"
    fi
    clean_priv; rm -rf "$hw/fe"

    # 4. BUG-300's two failure shapes: the .zig SURVIVES (evidence), no binary or .pdb does
    for shape in compile runtime; do
        if [ "$shape" = compile ]; then
            # passes the type checker, fails in zig (a float literal into a List(int))
            printf 'def main()\n    var xs = List(int)()\n    xs.add(1.5)\n' > "$hw/zzfail.zbr"
        else
            printf 'def main()\n    print("x")\n    sys.exit(3)\n' > "$hw/zzfail.zbr"
        fi
        err=$(zrun "$hw/zzfail.zbr"); kd=$(printf '%s\n' "$err" | named)
        kdu=""; [ -n "$kd" ] && kdu="$(upath "$kd")"
        bins=$(ls "$kdu"/*.exe "$kdu"/*.pdb "$kdu"/*.dll 2>/dev/null | wc -l)
        if [ "$(ndirs)" -ne 1 ] || [ -z "$kd" ]; then
            fail "a $shape-failure run kept $(ndirs) directory(ies), named '$kd' (want exactly one, named)"
        elif [ ! -f "$kdu/zzfail.zig" ]; then
            fail "a $shape-failure run did NOT keep the emitted .zig -- the evidence is gone"
        elif [ "$bins" -ne 0 ]; then
            fail "a $shape-failure run left $bins binary/pdb file(s) in $kd"
        else
            pass "a $shape-failure run keeps its .zig in ONE named directory, and no binary"
        fi
        clean_priv
    done

    # 4b. BOUNDED: a failure keeps its evidence, but ONE directory per program -- the shared
    #     layout's overwrite used to guarantee that, and without it one FULL tier left 14.
    #     A second program whose name EXTENDS the first's (zzfail-2) must not be pruned.
    printf 'def main()
    print("x")
    sys.exit(3)
' > "$hw/zzfail.zbr"
    printf 'def main()
    print("y")
    sys.exit(4)
' > "$hw/zzfail-2.zbr"
    zrun "$hw/zzfail-2.zbr" >/dev/null
    zrun "$hw/zzfail.zbr" >/dev/null
    zrun "$hw/zzfail.zbr" >/dev/null
    n_same=$(ls -d "$st_priv"/zebra-zzfail-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] 2>/dev/null | wc -l)
    n_other=$(ls -d "$st_priv"/zebra-zzfail-2-* 2>/dev/null | wc -l)
    if [ "$n_same" -eq 1 ] && [ "$n_other" -eq 1 ]; then
        pass "two failing runs of one program keep ONE directory; a similarly named program's is untouched"
    else
        fail "after two failing runs: $n_same kept for zzfail (want 1), $n_other for zzfail-2 (want 1)"
    fi
    clean_priv
    rm -f "$hw/zzfail.zbr" "$hw/zzfail-2.zbr"

    # 5. THE BUG ITSELF, deterministically: two programs with the same stem. Under the shared
    #    layout the second run overwrote <TEMP>/same.zig; now the first run's kept .zig must
    #    still be the FIRST program's.
    mkdir -p "$hw/sa" "$hw/sb"
    printf 'def main()\n    print("from-a")\n' > "$hw/sa/same.zbr"
    printf 'def main()\n    print("from-b")\n' > "$hw/sb/same.zbr"
    err=$(zrun --keep-temp "$hw/sa/same.zbr"); kd=$(printf '%s\n' "$err" | named)
    zrun "$hw/sb/same.zbr" >/dev/null
    if [ -n "$kd" ] && grep -q 'from-a' "$(upath "$kd")/same.zig" 2>/dev/null; then
        pass "a second same-named program does not overwrite the first run's build (BUG-513)"
    else
        fail "the first run's same.zig was overwritten or not kept (BUG-513: shared TEMP)"
    fi
    clean_priv; rm -rf "$hw/sa" "$hw/sb"
fi
rm -rf "$st_priv"

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

echo
if [ "$FAIL" -gt 0 ]; then
    printf '\033[31mruntime-module: %d check(s) FAILED\033[0m\n' "$FAIL"
    exit 1
fi
printf '\033[32mruntime-module: all checks pass\033[0m\n'
