#!/usr/bin/env bash
# THE STREAM-SEPARATION GATE (BUG-318): `print` goes to STDOUT, `sys.errln` to STDERR.
#
#   bash tools/stream_check.sh
#
# WHY IT EXISTS, and it is the only gate that can answer this question. Until 2026-08-29
# Zebra's `print` lowered to `std.debug.print`, which writes to STDERR. Every program's
# output therefore vanished under `> file` or `| grep`, with exit code 0 and nothing to
# indicate a problem -- for a release that means "ready for others", the first thing a
# stranger does after `print`.
#
# NO EXISTING GATE COULD SEE IT, and that is structural rather than an oversight:
#   output_sweep.sh:183  captures with `2>&1` -- the only gate that reads what programs
#                        PRINT merges the two streams it would need to tell apart
#   selfhost_smoke       greps combined output for a marker
#   every other gate     asks whether things COMPILE, not what they print, and least of
#                        all WHERE they print it
# A merged capture cannot distinguish "printed to stdout" from "printed to stderr", so the
# defect was invisible to the entire fleet by construction.
#
# It also retired a false belief: this repo recorded "Windows stdout-to-PIPE writes
# nothing (redirect/file fine)" as a platform quirk and shaped tooling around it. It was
# this bug. `prog | grep` works now.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZEBRA="$REPO/zig-out/bin/zebra.exe"
SRC="$REPO/test/stream_separation_test.zbr"
OUT="${TMPDIR:-/tmp}/zbr_streamchk"

OUT_MARK="STDOUT-MARKER-9f3a"
ERR_MARK="STDERR-MARKER-4c7b"

[ -x "$ZEBRA" ] || { echo "stream-check: REFUSING -- not built: $ZEBRA" >&2; exit 2; }
[ -f "$SRC" ]   || { echo "stream-check: REFUSING -- fixture missing: $SRC" >&2; exit 2; }

rm -rf "$OUT"; mkdir -p "$OUT"
if ! timeout 300 "$ZEBRA" --output-dir "$OUT" "$SRC" > "$OUT/build.log" 2>&1; then
    echo "stream-check: REFUSING -- could not build the fixture:" >&2
    tail -5 "$OUT/build.log" >&2
    exit 2
fi

EXE="$(find "$OUT" -name '*.exe' -type f | head -1)"
[ -n "$EXE" ] || { echo "stream-check: REFUSING -- no executable produced" >&2; exit 2; }

"$EXE" > "$OUT/stdout.txt" 2> "$OUT/stderr.txt"
rc=$?

o=$(cat "$OUT/stdout.txt" 2>/dev/null)
e=$(cat "$OUT/stderr.txt" 2>/dev/null)

# POSITIVE CONTROL FIRST. If the program produced nothing anywhere, both "not on the wrong
# stream" assertions below pass vacuously -- two empty strings satisfy every absence test.
# An absence is only evidence once a presence has been demonstrated.
if [ -z "$o" ] && [ -z "$e" ]; then
    echo "stream-check: REFUSING -- the program produced NO output on either stream" >&2
    echo "  (exit $rc). Every assertion below would pass vacuously." >&2
    exit 2
fi

fail=0
chk() {  # chk <description> <condition-result>
    if [ "$2" = "0" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); fi
}

echo "── stream separation (BUG-318) ──"
printf '  stdout: %s byte(s)   stderr: %s byte(s)   exit %s\n' \
    "$(wc -c < "$OUT/stdout.txt" | tr -d ' ')" "$(wc -c < "$OUT/stderr.txt" | tr -d ' ')" "$rc"

# Both directions. Either alone is satisfiable by sending everything to one stream.
case "$o" in *"$OUT_MARK"*) chk "print output is on STDOUT" 0;;  *) chk "print output is on STDOUT" 1;; esac
case "$e" in *"$ERR_MARK"*) chk "sys.errln output is on STDERR" 0;; *) chk "sys.errln output is on STDERR" 1;; esac
case "$e" in *"$OUT_MARK"*) chk "print output is NOT on stderr" 1;; *) chk "print output is NOT on stderr" 0;; esac
case "$o" in *"$ERR_MARK"*) chk "sys.errln output is NOT on stdout" 1;; *) chk "sys.errln output is NOT on stdout" 0;; esac

# The usage the bug actually broke, tested as the user meets it rather than inferred.
piped=$("$EXE" 2>/dev/null | grep -c "$OUT_MARK")
[ "$piped" -ge 1 ] && chk "\`prog | grep\` sees the output" 0 || chk "\`prog | grep\` sees the output" 1
"$EXE" 2>/dev/null > "$OUT/redir.txt"
grep -q "$OUT_MARK" "$OUT/redir.txt" && chk "\`prog > file\` captures the output" 0 \
                                     || chk "\`prog > file\` captures the output" 1

# LEG 7 — BUG-317, closed as a duplicate of 318 and tested here rather than separately.
# Its symptom was its own observable: `zebra --emit-zig f.zbr > out.zig` produced an EMPTY
# file and exited 0, because that path ends in `print(zig_src)` and print was stderr. One
# fix repaired both, but "the compiler can emit to a redirect" is not implied by "a program
# prints to stdout" -- the emit path could regress on its own.
# PINNED as an XFAIL against BUG-317, the @boundary-pending idiom applied to one leg: it
# is EXPECTED to fail today and FAILS THE GATE THE DAY IT STARTS PASSING, so the fix cannot
# land unnoticed. BUG-318's fix does NOT repair this -- the selfhost compiler's own code is
# emitted by the BOOTSTRAP, which still emits std.debug.print (138 calls in the committed
# main.zig). Moving the regen authority to the selfhost (sunset criterion 2) is what fixes
# it. Delete this pin and assert the positive when that lands.
EMIT="$OUT/emitted.zig"
"$ZEBRA" --emit-zig "$SRC" > "$EMIT" 2>/dev/null
emit_bytes=$(wc -c < "$EMIT" 2>/dev/null | tr -d ' ')
if [ "${emit_bytes:-0}" -gt 200 ] && grep -q 'pub fn main' "$EMIT" 2>/dev/null; then
    printf '  FAIL  `--emit-zig > file` now WORKS (%s bytes) — BUG-317 is fixed; retire this pin\n' "$emit_bytes"
    fail=$((fail + 1))
else
    printf '  xfail `--emit-zig > file` is empty (%s bytes) — BUG-317, pinned\n' "${emit_bytes:-0}"
fi

if [ "$fail" -eq 0 ]; then
    echo "stream-check: PASS — 7/7"
    exit 0
fi
echo "stream-check: $fail of 7 FAILED" >&2
exit 1
