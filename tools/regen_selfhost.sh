#!/usr/bin/env bash
# REGENERATE selfhost/*.zig USING THE SELFHOST (N-1 bootstrapping).
#
#   bash tools/regen_selfhost.sh            # emit + validate ONLY, touch nothing
#   bash tools/regen_selfhost.sh --apply    # ...then atomically move into selfhost/
#
# This is the bootstrap sunset's criterion 2. Until now `selfhost/*.zig` were emitted by
# zebra-bootstrap.exe, and that job is the last thing keeping a second compiler
# implementation alive.
#
# WHY THIS IS SAFE, given bootstrap_check.sh's standing objection ("using selfhost-A to
# regenerate itself is chicken-and-egg -- a codegen bug in CodeGen.zbr would reproduce
# itself"). That objection is real and is answered by N-1 rather than dismissed: stage-0 is
# the compiler built from the COMMITTED .zig, i.e. one we did not just build, exactly as
# GCC/Rust/Go take stage-0 from a previous release. The Thompson protection is that the
# generated files are TRACKED and the diff is reviewed. The round-trip (bootstrap_check
# steps 3-5) independently proves A's emit and B's emit agree.
#
# EMIT-ONLY BY DEFAULT. A regeneration that half-writes leaves a tree that builds the wrong
# compiler, and `doctor` calls that state one that makes results LIE. So this emits into
# scratch, validates every file, prints the diff size, and stops. `--apply` does the moves,
# and only after the same validation.
#
# THE SHAPE IS THE COMPILER'S DEFAULT, exactly as tools/bootstrap_check.sh emits it: one
# `--emit-zig --output-dir` on selfhost/main.zbr writes every module plus zebra_rt.zig, and
# that is what is committed (each module imports zebra_rt.zig). This script used to pass
# --no-runtime-module, from the days the committed files were INLINE. After the
# runtime-module default landed, that flag made every module ~5x the committed size
# (Ast.zig 352,234 bytes against 56,836), and the diff it showed was a shape change, not the
# review. Worse, `--apply` would have installed modules that cannot build beside the
# committed ones (a re-emitted main.zig calls Parser._initAllocator, which the inline shape
# does not have). Reported by the GameEngine session 2026-10-12; zebra_rt.zig is now
# validated and installed with the modules.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZEBRA="$REPO/zig-out/bin/zebra.exe"
# Linux/macOS build `zebra`, not `zebra.exe` (CI quick-linux, 2026-09-26): use it when the .exe is absent.
[ -x "$ZEBRA" ] || [ ! -x "${ZEBRA%.exe}" ] || ZEBRA="${ZEBRA%.exe}"
OUT="${TMPDIR:-/tmp}/zbr_regen"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

FILES=(Token Lexer Ast AstWalk Parser Resolver AstBuilder CgHelpers TypeChecker CodeGen Checker main)
MIN_BYTES=5000

[ -x "$ZEBRA" ] || { echo "regen: REFUSING -- not built: $ZEBRA" >&2; exit 2; }

rm -rf "$OUT"; mkdir -p "$OUT"
echo "── regenerating ${#FILES[@]} module(s) with the SELFHOST (zebra.exe) ──"

# ONE command, as in bootstrap_check.sh: the compiler resolves main's dependency graph and
# emits every module plus zebra_rt.zig into $OUT. The files are what gets checked below.
# RELATIVE PATH, FROM THE REPO ROOT, and this is not cosmetic: the compiler embeds the
    # path it was GIVEN into every `// zbr:<path>:<line>` provenance comment. Passing an
    # ABSOLUTE path changed ~29,000 lines in CodeGen.zig alone -- 78,997 across all twelve
    # modules -- every one of them a path prefix inside a comment. The emission is therefore
    # a function of HOW YOU INVOKE the compiler, not only of the source, which is a quiet
    # coupling: a regen script differing only in argument style produces a diff that reads
    # like a compiler change. The existing regen has always used a relative path; matching it
# keeps this diff to the REAL emission difference.
( cd "$REPO" && "$ZEBRA" --emit-zig --output-dir "$OUT" "selfhost/main.zbr" ) \
    > "$OUT/emit.log" 2>&1 || true

fail=0
total_diff=0
# FILES is hand-kept, and the emit is the truth: a module main.zbr now uses but FILES omits
# would be emitted and then silently never validated or installed (the v-backend-poc branch
# added CodeGenV and had to remember this list). Refuse on any emitted module not named.
for z in "$OUT"/*.zig; do
    [ -e "$z" ] || continue
    m="${z##*/}"; m="${m%.zig}"
    case " ${FILES[*]} zebra_rt " in *" $m "*) ;; *)
        printf '  %-14s %s\n' "$m" "EMITTED BUT NOT IN FILES — add it to FILES in this script"
        fail=$((fail + 1)) ;;
    esac
done
printf '  %-14s %9s %9s %8s\n' module emitted committed diff
for f in "${FILES[@]}" zebra_rt; do
    src="$OUT/$f.zig"
    dst="$REPO/selfhost/$f.zig"
    if [ ! -f "$src" ]; then
        printf '  %-14s %s\n' "$f" "MISSING — emit produced no file"
        grep -aiE 'error|panic' "$OUT/emit.log" | head -3 | sed 's/^/      /'
        fail=$((fail + 1)); continue
    fi
    b=$(wc -c < "$src" | tr -d ' ')
    if [ "$b" -lt "$MIN_BYTES" ]; then
        printf '  %-14s %s\n' "$f" "TOO SMALL ($b bytes) — a truncated emit would build the wrong compiler"
        fail=$((fail + 1)); continue
    fi
    # A file that exists and is large can still be the WRONG file. The emit header is the
    # cheap proof it came from this compiler rather than being left over from something.
    # zebra_rt.zig is the runtime written out verbatim, so it carries the preamble's own
    # first line instead of a module's emit header.
    hdr='Generated by'; [ "$f" = zebra_rt ] && hdr='Zebra selfhost runtime preamble'
    if ! head -3 "$src" | grep -q "$hdr"; then
        printf '  %-14s %s\n' "$f" "NO EMIT HEADER — not a generated file"
        fail=$((fail + 1)); continue
    fi
    d=$(diff "$src" "$dst" 2>/dev/null | grep -c '^[<>]')
    total_diff=$((total_diff + d))
    printf '  %-14s %9s %9s %8s\n' "$f" "$(wc -l < "$src" | tr -d ' ')" "$(wc -l < "$dst" | tr -d ' ')" "$d"
done

if [ "$fail" -gt 0 ]; then
    echo "regen: REFUSING -- $fail module(s) failed validation. Nothing moved." >&2
    exit 1
fi

echo "  total changed lines across all modules: $total_diff"
echo "  emissions kept in $OUT for review"

if [ "$APPLY" -eq 0 ]; then
    echo "regen: validated, NOTHING MOVED. Re-run with --apply to install."
    exit 0
fi

# Atomic-ish install: every file validated above, so a kill here leaves complete files.
for f in "${FILES[@]}" zebra_rt; do
    mv -f "$OUT/$f.zig" "$REPO/selfhost/$f.zig"
done

# THE BUILD STAMP MUST BE REBUILT WITH THE BINARY, or `doctor` refuses every gate tier
# afterwards with "zebra.exe was NOT built from the generated Zig now on disk" -- which
# reads as a serious alarm and is in fact just a stale stamp. `doctor` compares
# sha1(selfhost/*.zig) against zig-out/.selfhost-stamp, and only tools/rebuild.sh writes it.
# A plain `zig build` leaves the old one in place, so the tree LOOKS untrustworthy while
# being fine. Observed on this tool's first real use, 2026-08-29.
echo "regen: applied."
echo
echo "  NEXT, and not optional:  bash tools/rebuild.sh --no-regen"
echo "  A plain \`zig build\` leaves zig-out/.selfhost-stamp describing the PREVIOUS"
echo "  sources, and doctor then refuses every gate tier. rebuild.sh --no-regen builds"
echo "  and re-stamps together."
