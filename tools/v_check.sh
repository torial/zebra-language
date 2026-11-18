#!/bin/bash
# pins: BUG-777 `--target v` runs the type check: a program -c refuses is refused there in the compile's words with no .v written, its well-typed twin is written, partial files are merged and a `use` is found by its exact name (the typecheck row)
# pins: BUG-773 x.hash() on a str, an integer, a bool and a char, and Hash.fnv64, answer the Zig route's FNV-1a 64 on the V route, held to values computed outside both; a derived or untyped hash() is refused by name (the hash row)
# pins: BUG-681 a V walk over a module list or field reassigned mid-walk ends over the old list (sweep_v row)
# pins: BUG-690 `catch nil` / `catch |e| v` / `catch v` over a nilable-and-throws def (examples/v_poc5.zbr, diffed against a fresh Zig run)
# pins: BUG-712 a char on the V route is a codepoint, and chars() yields the Zig route's items (examples/v_poc_utf8.zbr; the fmt_c row's text line)
# pins: BUG-713 `${n:c}` on an int is one byte on the V route, and traps out of 0..255 with the Zig route's words (the fmt_c row)
# pins: BUG-716 a refused SQLite statement is printed and kept on the V route as on the Zig route, where it panicked (the sqlite row)
# pins: BUG-717 busyMs on the V route, placed by name before position (the sqlite row: `Sqlite.open(p, busyMs: 0)` leaves write-ahead on)
# pins: BUG-726 Net.resolve on the V route answers what the Zig route answers, and refuses text that is no host name in the same words (the net row)
# pins: BUG-723 a container printed, interpolated or joined on the V route is the Zig route's text, and s.chars() / s.bytes() are values there too (the show row)
# pins: BUG-734 Json.parse answers nil past 256 levels of nesting on the V route as on the Zig route (the show row's jd_fix)
# pins: BUG-743 a container's toString() on the V route is the text print gives, as on the Zig route (the show row's show_more)
# pins: BUG-745 on the V route a struct built with fewer arguments than fields takes each missing field's default, and a class's list or class field keeps its declared default (the show row's show_types and show_fix2)
# pins: BUG-746 a class or struct as text on the V route is the Zig route's (`Name{field: value}`, or its own toString with no `&` before it in a hole), and so is an optional of one (`nil` or the value) (the show row's show_types, show_fix2 and show_opt)
# pins: BUG-749 on the V route a class met again on the path being printed is `Name{...}`, a shared object prints in full, the cut is at 256 levels and the path is each thread's own (the show row's show_fix3 and show_cycle)
# pins: BUG-752 a class, struct or function whose V name is a private function of V's builtin (`class Node` -> new_node, vlang/v#32404) is moved aside, and the emitter's list covers the V in use (the names row)
# pins: BUG-722 on the V route put/append of a JsonValue store a snapshot, an object's members keep the order they were stored in, and a wrong kind or a 257th level stops the program with the Zig route's message (the json row's four test/bug722 fixtures)
# pins: BUG-751 on the V route a JsonValue is a shared handle -- assignment, a parameter and every value read out share, put / append store a snapshot, a replaced key detaches the old node, the 256 levels count from the root -- as on the Zig route (the json row's three test/bug751 fixtures against the Zig run)
# pins: BUG-756 on the V route Json.parse reads an integer exactly, writes a float in plain digits, keeps a number that fits neither type as its text and refuses a duplicate key, as the Zig route does (the json row's json_edges, test/json_edges_test.zbr, 84 lines)
# pins: BUG-748 the V route's net.http checks certificates by default (the certs row: every validate bool in vlib/net/http/http.v and request.v defaults to true)
# The V target's check (2026-10-20; the docket's item 3, tooling parity): the
# V side's drift alarm and suites in one run, as `regen_selfhost.sh --check`
# and the Zig suites are for the Zig side.
#
#   tools/v_check.sh [--v <v.exe>]           (the V pin by default; V=<path> too)
#
# What it does, each from the checkout's own zebra.exe:
#   1. the seven examples/v_poc*.zbr: emitted to V, built and run under the
#      given V, and diffed against a FRESH Zig control (the same program
#      through the Zig backend, run now -- never a stored file); an example
#      with a refusal fails (the examples are the subset by definition);
#   2. the five selfhost dumps (lexer, parser, ast, resolver, codegen): the
#      same, run from selfhost/ as the compiler's own tests do;
#   3. the route's modules (CodeGen, Checker, main): emitted, the refusals
#      counted against the baseline below (the route's known stubs), and
#      `v -check` must pass;
#   4. the four engine roots the pipeline carried (signal, instance, tween,
#      health) are the engine ladder's (tools/v_engine_check.py), not here.
# A control the Zig run left empty is NO CONTROL and a failure: a diff
# against nothing is not a pass. Exit 0 only when every row passed.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/zig_toolchain.sh"   # the PINNED zig, also standalone (hazard_lint H14)
WT=$(cd "$(dirname "$0")/.." && pwd)
ZEBRA="$WT/zig-out/bin/zebra.exe"
# the pin (vlang/v master c4dee97 since 2026-11-15; b399a50 from 11-08), as tools/gates.sh
# passes it: the crypto row needs V's crypto.argon2, which 0.5.2 (the default here until
# 2026-11-12) lacks, and the certs row needs net.http's certificate check on by default,
# which b399a50 lacks
V=${V:-/c/Projects/v-c4dee97/v.exe}
[ "${1:-}" = "--v" ] && V=$2
# V master retries a build whose C does not compile with a cached V 0.5.2 ("retrying with
# `...v1-fallback/0.5.2/v.exe`"): a row could then be judged by a compiler it does not name.
# Switched off here (the name says macOS; cmd/v/v.v reads it on every OS), and the last row
# refuses any run whose stderr says the retry happened all the same.
export V_MACOS_V3_NO_FALLBACK=1
OUT=${OUT:-$WT/.zig-cache/v_check}
ROUTE_REFUSALS_BASELINE=${ROUTE_REFUSALS_BASELINE:-2}   # main.zbr's two zig literals (Zig-backend code by definition): more is a regression
mkdir -p "$OUT/scratch"
[ -x "$ZEBRA" ] || { echo "v_check: no $ZEBRA (build the checkout)"; exit 2; }
[ -x "$V" ] || { echo "v_check: no V at $V"; exit 2; }
cp "$WT/selfhost/zebra_rt.v" "$WT/zig-out/bin/zebra_rt.v" 2>/dev/null
cp "$WT/selfhost/gui_libui_ng_section.v" "$WT/zig-out/bin/gui_libui_ng_section.v" 2>/dev/null
echo "v_check: $("$V" version), emitter $ZEBRA"
fail=0; rows=0
# refusal_lines <emit-output>...: the emitter's refusal lines, which are the four-space lines of
# its REPORT -- the part after its "wrote" line. Since BUG-777 the type check's warnings are
# printed before that line, each with its source line and its caret, and a source line is
# indented too: counted over the whole output, a warning read as a refusal
# (v_format_specs_test, on the day the check landed). Several files: each has its own report.
refusal_lines() { awk 'FNR == 1 { on = 0 } /^zebra --target v: wrote / { on = 1; next } on && /^    /' "$@"; }
# its own control, before it judges anything: a warning's source line ahead of the report is
# no refusal, a report's line is one, and a second file starts afresh.
printf 'x.zbr:1:1: warning: w\n        print(x)\n        ^\nzebra --target v: wrote x.v\n  nothing refused: the whole file is in the subset\n' > "$OUT/refusal_lines_warn.txt"
printf 'zebra --target v: wrote y.v\n  refused 1 construct(s)\n    a thing (y.zbr:3)\n' > "$OUT/refusal_lines_ref.txt"
if [ "$(refusal_lines "$OUT/refusal_lines_warn.txt" | wc -l)" != 0 ] || [ "$(refusal_lines "$OUT/refusal_lines_ref.txt" | wc -l)" != 1 ] || [ "$(refusal_lines "$OUT/refusal_lines_ref.txt" "$OUT/refusal_lines_warn.txt" | wc -l)" != 1 ]; then
  echo "v_check: refusal_lines cannot tell a warning's source line from a refusal line: nothing judged"; exit 3
fi
# compare <name> <emit-dir> <zbr-path-relative-to-emit-dir> <control-file> <v-file>
compare() {
  local name=$1 dir=$2 zbr=$3 ctl=$4 vfile=$5
  rows=$((rows + 1))
  (cd "$dir" && "$ZEBRA" "$zbr" > "$ctl" 2> "$OUT/${name}_zig_err.txt"); local zrc=$?
  (cd "$dir" && "$ZEBRA" --target v "$zbr" > "$OUT/${name}_emit.txt" 2>&1)
  local refusals; refusals=$(refusal_lines "$OUT/${name}_emit.txt" | wc -l)
  if [ ! -f "$vfile" ]; then echo "$name: EMIT FAILED"; grep -E "error" "$OUT/${name}_emit.txt" | head -2 | cut -c1-160; fail=1; return; fi
  if [ "$refusals" != 0 ]; then echo "$name: REFUSED $refusals (an example or a dump is the subset by definition)"; refusal_lines "$OUT/${name}_emit.txt" | head -3 | cut -c1-160; fail=1; return; fi
  (cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$vfile" > "$OUT/${name}_v_out.txt" 2> "$OUT/${name}_v_err.txt"); local vrc=$?
  if [ ! -s "$ctl" ]; then echo "$name: NO CONTROL (the Zig run exited $zrc and printed nothing; nothing compared)"; grep -m2 "error" "$OUT/${name}_zig_err.txt" | cut -c1-160; fail=1; return; fi
  if [ "$vrc" != 0 ]; then echo "$name: V FAILED (exit $vrc)"; grep -E "error|panic" "$OUT/${name}_v_err.txt" | head -3 | cut -c1-160; fail=1; return; fi
  # a program const named like a runtime local: V 0.5.2 warns and may miscompile silently (v_backend_poc.md item 22); the lane refuses it
  if grep -q "duplicate of a const name" "$OUT/${name}_v_err.txt"; then echo "$name: CONST SHADOW (a runtime local shares a name with the program's const; item 22)"; grep "duplicate of a const name" "$OUT/${name}_v_err.txt" | head -3 | cut -c1-160; fail=1; return; fi
  if diff -q "$OUT/${name}_v_out.txt" "$ctl" > /dev/null; then echo "$name: IDENTICAL ($(wc -l < "$ctl") lines)"; else echo "$name: DIFFERS"; diff "$OUT/${name}_v_out.txt" "$ctl" | head -6 | cut -c1-160; fail=1; fi
}
echo "── the examples ──"
for f in "$WT"/examples/v_poc*.zbr; do
  b=$(basename "$f" .zbr)
  compare "$b" "$WT" "examples/$b.zbr" "$OUT/control_$b.txt" "$WT/examples/$b.v"
done
echo "── import names a program may use, and Crypto / Hash.hmac256, on both routes (2026-11-12) ──"
# v_import_names: locals, parameters and fields named after every symbol the emitted file's
# imports bind (a local `sync` broke the engine's V game). v_crypto: lengths and verdicts
# only, over hashes made by OpenSSL, by the Zig route and by the V route.
for t in v_import_names_test v_crypto_test; do
  compare "$t" "$WT" "test/$t.zbr" "$OUT/control_$t.txt" "$WT/test/${t}_prog.v"
done
echo "── format specs in a hole, on both routes (2026-11-16) ──"
# V's own interpolation knows no `>`, `<`, `^`, no fill character and no space sign, and it
# DROPS a spec that carries one without a word (`'${n:>3}'` prints "1", vlang/v#32420): until
# this row 21 of 37 holes differed from the Zig route, and `${f:8.2f}` did not compile. Every
# spec'd hole of a known type now goes through the runtime (CodeGenV.vSpecHole, read by the
# Zig route's own parseFmtSpec). v_format_specs: the holes over ints, bytes, floats, strs
# and chars, printed and compared line for line. (test/bug725_int_width_sign_test.zbr joined
# the lane with BUG-761, in the `sized` row below: its holes are over an int8 and a local
# bound to a count, which this route did not type before.) The refusals: what this route
# cannot write, each by name, never a spliced spec.
compare v_format_specs_test "$WT" test/v_format_specs_test.zbr "$OUT/control_v_format_specs_test.txt" "$WT/test/v_format_specs_test_prog.v"
rows=$((rows + 1))
cat > "$OUT/fmt_refuse.zbr" <<'ZBR'
def main()
    var n = sys.args().count()
    var k: int = n + 0
    var f: float = n * 1.5
    print("${f:.2e}")
    print("${f:.12f}")
    print("${k:.2f}")
    print("${f:x}")
ZBR
(cd "$OUT" && "$ZEBRA" --target v fmt_refuse.zbr > "$OUT/fmt_refuse_emit.txt" 2>&1)
fmt_refused=$(grep -cE '^    a format spec \((\.2e|\.12f|\.2f|x)\): ' "$OUT/fmt_refuse_emit.txt")
# the controls: the Zig run printed a padded int (a program with no spec'd hole would compare
# clean), and the emitted V reaches the runtime's pad over the sign text
if ! grep -qxF 'i >3    [  1] [ -1] [  0] [1234567]' "$OUT/control_v_format_specs_test.txt"; then echo "fmt: FAILED -- NO CONTROL: the Zig run did not print the padded ints the row is about"; fail=1
elif ! grep -q 'zfmt_pad(zfmt_itext(' "$WT/test/v_format_specs_test_prog.v"; then echo "fmt: FAILED -- the emitted V does not reach zfmt_pad over zfmt_itext: the comparison ran V's own interpolation"; fail=1
elif [ "$fmt_refused" != 4 ]; then echo "fmt: FAILED -- $fmt_refused of 4 unwritable specs refused by name (an exponent type, a precision over 9, a precision on an int, x on a float)"; grep -E '^    |error' "$OUT/fmt_refuse_emit.txt" | head -4 | cut -c1-160; fail=1
else echo "fmt: ok (the Zig control printed padded ints; the emitted V reaches zfmt_pad over zfmt_itext; 4 unwritable specs refused by name)"; fi
echo "── the sized integers and byte, on both routes (BUG-761, 2026-11-17) ──"
# Until this row the V route passed `int8`, `uint64`, `byte` through as written (unknown
# types in V), typed an int8 local as V's int, and had no mapping for a suffixed literal or
# a checked conversion. They are V's i8..u64 now; an operation on two of them is carried out
# in the checker's join and checked there, and a conversion traps as the Zig route's does.
# v_sized_ints: 40 lines over every mapped width (printing, arithmetic, joins, comparisons,
# bitwise, conversions, wrapping, compound assignment, suffixed literals, format specs,
# fields, lists, maps, sets, optionals, tuples, a module var, loops). The six fixtures after
# it are the compiler's own tests of these rules, which did not build as V before, and
# BUG-725's, the entry's stated control. Then the ATTACKERS: a matching printout proves
# nothing about a result that does not fit, so eighteen programs each overflow or convert
# out of range once, and each must die on BOTH routes with the Zig route's message and
# never print its SURVIVED line. (Written first as a comparison alone, the row was green
# while eight of these wrapped silently on V: a conversion's result had no type there, so
# the sum beside it went unchecked.)
compare v_sized_ints_test "$WT" test/v_sized_ints_test.zbr "$OUT/control_v_sized_ints_test.txt" "$WT/test/v_sized_ints_test_prog.v"
for t in bug534_sized_conversions_test bug672_673_join_fits_test bug674_bitwise_join_test numeric_types_test bug725_int_width_sign_test; do
  compare "$t" "$WT" "test/$t.zbr" "$OUT/control_$t.txt" "$WT/test/${t}_prog.v"
done
rows=$((rows + 1))
sz_body() {   # <name> -> the statements after `var n` (1 at run time); each leaves a `y`
  case $1 in
    i8add)    printf '    var a: int8 = (n * 127).toInt8()\n    var y: int8 = a + n.toInt8()\n' ;;
    u8sub)    printf '    var k: byte = n.toUint8()\n    var y: byte = k - (n * 2).toUint8()\n' ;;
    i16mul)   printf '    var s: int16 = (n * 300).toInt16()\n    var y: int16 = s * s\n' ;;
    u32add)   printf '    var u: uint32 = (n * 4000000000).toUint32()\n    var y: uint32 = u + u\n' ;;
    u64add)   printf '    var h: uint64 = 18446744073709551615\n    var y: uint64 = h + n.toUint64()\n' ;;
    u64sub)   printf '    var h: uint64 = n.toUint64()\n    var y: uint64 = h - (n * 2).toUint64()\n' ;;
    u64mul)   printf '    var h: uint64 = (n * 5000000000).toUint64()\n    var y: uint64 = h * h\n' ;;
    i8neg)    printf '    var a: int8 = (0 - n * 128).toInt8()\n    var y: int8 = -a\n' ;;
    i8pluseq) printf '    var y: int8 = 127\n    y += n.toInt8()\n' ;;
    i8div)    printf '    var a: int8 = (0 - n * 128).toInt8()\n    var y: int8 = a / (0 - n).toInt8()\n' ;;
    elem)     printf '    var xs: List(int8) = []\n    xs.add(127)\n    xs[0] += n.toInt8()\n    var y: int8 = xs.at(0)\n' ;;
    field)    printf '    var c = Cell(v: 65535)\n    c.v = c.v + n.toUint16()\n    var y: uint16 = c.v\n' ;;
    conv8)    printf '    var y: int8 = (n * 300).toInt8()\n' ;;
    convneg)  printf '    var y: uint64 = (0 - n).toUint64()\n' ;;
    convbyte) printf '    var y: byte = (n * 256).toUint8()\n' ;;
    convdown) printf '    var h: uint64 = (n * 70000).toUint64()\n    var y: uint16 = h.toUint16()\n' ;;
    convint)  printf '    var h: uint64 = 18446744073709551615\n    var y: int = h.toInt() + n\n' ;;
    convi8u)  printf '    var a: int8 = (0 - n).toInt8()\n    var y: uint32 = a.toUint32()\n' ;;
  esac
}
sz_bad=""; sz_n=0; sz_msgs=""
for p in i8add u8sub i16mul u32add u64add u64sub u64mul i8neg i8pluseq i8div elem field conv8 convneg convbyte convdown convint convi8u; do
  sz_n=$((sz_n + 1))
  { printf 'struct Cell\n    var v: uint16\n\ndef main()\n    var n: int = sys.args().count()\n'; sz_body $p; printf '    print("SURVIVED %s: " + y.toString())\n' $p; } > "$OUT/sz_$p.zbr"
  (cd "$OUT" && "$ZEBRA" sz_$p.zbr > "$OUT/sz_${p}_zig_out.txt" 2> "$OUT/sz_${p}_zig_err.txt"); zrc=$?
  rm -f "$OUT/sz_$p.v"
  (cd "$OUT" && "$ZEBRA" --target v sz_$p.zbr > "$OUT/sz_${p}_emit.txt" 2>&1)
  (cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/sz_$p.v" > "$OUT/sz_${p}_v_out.txt" 2> "$OUT/sz_${p}_v_err.txt"); vrc=$?
  zmsg=$(grep -o 'panic: .*' "$OUT/sz_${p}_zig_err.txt" | head -1 | sed 's/^panic: //' | tr -d '\r')
  case $p in conv*) want='integer conversion out of range' ;; *) want='integer overflow' ;; esac
  if [ "$zrc" = 0 ] || [ "${zmsg#"$want"}" = "$zmsg" ]; then sz_bad="$sz_bad $p(zig exit $zrc, no '$want' trap: NO CONTROL)"
  elif [ "$vrc" = 0 ] || grep -q SURVIVED "$OUT/sz_${p}_v_out.txt" || ! grep -qF "$zmsg" "$OUT/sz_${p}_v_err.txt"; then sz_bad="$sz_bad $p(v exit $vrc, wanted '$zmsg': $(head -c 90 "$OUT/sz_${p}_v_out.txt" | tr '\n' ' '))"
  elif ! grep -qE '^  0 integer operation' "$OUT/sz_${p}_emit.txt"; then sz_bad="$sz_bad $p(the emit left an integer operation unchecked: $(grep 'not overflow-checked' "$OUT/sz_${p}_emit.txt"))"; fi
  case $p in conv*) sz_msgs="$sz_msgs; ${zmsg#integer conversion out of range: }" ;; esac
done
# what this route cannot write is refused by name: a 128-bit type, and a conversion on a
# value whose type the emitter does not know (it would have guessed a V method). The
# untyped value is a str's `.len` bound to an unannotated local; on the day the emitter
# types that, this leg needs another untyped value, not a weaker check.
cat > "$OUT/sz_refuse.zbr" <<'ZBR'
def wide(x: int128): int128
    return x

def main()
    var parts = "1,2".split(",")
    var first = parts.at(0).len
    print(first.toInt16())
    print(wide(5))
ZBR
(cd "$OUT" && "$ZEBRA" --target v sz_refuse.zbr > "$OUT/sz_refuse_emit.txt" 2>&1)
sz_ref128=$(grep -cE '^    the type int128 \(V has no 128-bit integer\)' "$OUT/sz_refuse_emit.txt")
sz_refconv=$(grep -cE '^    `toInt16\(\)` on a value whose type this route does not know' "$OUT/sz_refuse_emit.txt")
if [ -n "$sz_bad" ]; then echo "sized: FAILED -- did not trap alike on both backends:$sz_bad"; fail=1
elif ! grep -qxF 'join  100 4999930000 9000000000 5000000200 30000 60200' "$OUT/control_v_sized_ints_test.txt"; then echo "sized: FAILED -- NO CONTROL: the Zig run did not print the joined sums the row is about"; fail=1
elif ! grep -qE '^  0 integer operation' "$OUT/v_sized_ints_test_emit.txt"; then echo "sized: FAILED -- the fixture's emit left an integer operation unchecked: $(grep 'not overflow-checked' "$OUT/v_sized_ints_test_emit.txt")"; fail=1
elif ! grep -q 'zfit(zadd(' "$WT/test/v_sized_ints_test_prog.v" || ! grep -q 'zuadd(' "$WT/test/v_sized_ints_test_prog.v"; then echo "sized: FAILED -- the emitted V does not reach zfit over zadd, or zuadd: the comparison ran V's own wrapping operators"; fail=1
elif [ "$sz_ref128" = 0 ] || [ "$sz_refconv" = 0 ]; then echo "sized: FAILED -- not refused by name: int128 ($sz_ref128 lines), a conversion on an untyped value ($sz_refconv lines)"; grep -E '^    |error' "$OUT/sz_refuse_emit.txt" | head -4 | cut -c1-160; fail=1
else echo "sized: ok -- $sz_n programs that overflow or convert out of range die on both backends with the Zig route's message, none survives and none has an unchecked operation (the conversions said:${sz_msgs#;}); int128 and a conversion on an untyped value are refused by name"; fi
echo "── float32, and a float's edges, on both routes (BUG-768, 2026-11-17) ──"
# Until this row the V route passed `float32` through as written (no V type), knew one float
# type in arithmetic, wrote V's `%` on a float (which V refuses) and V's cast for a float's
# toInt() (which answers i64's minimum for a value no int holds, where the Zig route traps).
# float32 is V's f32 now; an operation with a float operand is written in the checker's join
# with each operand cast to it; `%` is the runtime's zfmod; toInt() is the runtime's checked
# zfloat_int; a float32's text is its own shortest digits (zshow_f32), in a hole, in print(x)
# and in toString(). v_float32: 51 lines chosen so that float32 and float arithmetic print
# different digits and so that a float32 reaches a print through every position the emitter
# types separately. bug445 is the entry's stated control; bug471 returns an int from a
# float32 function. Then the EDGES, each its own program: five float-to-int conversions out
# of range must die on both routes with the Zig route's message, and a remainder by zero
# must print the same NaN on both (the sign differed: V's fmod answers nan, the Zig route's
# compiler-rt -nan on this machine).
compare v_float32_test "$WT" test/v_float32_test.zbr "$OUT/control_v_float32_test.txt" "$WT/test/v_float32_test_prog.v"
for t in bug445_mixed_numeric_test bug471_return_int_as_float_test; do
  compare "$t" "$WT" "test/$t.zbr" "$OUT/control_$t.txt" "$WT/test/${t}_prog.v"
done
rows=$((rows + 1))
fl_body() {   # <name> -> the expression bound to `y`
  case $1 in
    toint32)  printf '(one * 1.0e30).toInt()' ;;
    toint64)  printf '(d * 1.0e30).toInt()' ;;
    tointtop) printf '(d * 9223372036854775807.0).toInt()' ;;
    tointlow) printf '(d * -9223372036854777856.0).toInt()' ;;
    tointinf) printf '(d / dz).toInt()' ;;
    mod32)    printf 'one %% zero' ;;
    mod64)    printf 'd %% dz' ;;
    modinf)   printf '(d / dz) %% d' ;;
  esac
}
fl_bad=""; fl_n=0
for p in toint32 toint64 tointtop tointlow tointinf mod32 mod64 modinf; do
  fl_n=$((fl_n + 1))
  { printf 'def main()\n    var n = sys.args().count()\n    var one: float32 = n.toFloat32()\n    var zero: float32 = one - one\n    var d: float = n * 1.0\n    var dz: float = d - d\n    var y = '; fl_body $p; printf '\n    print("SURVIVED %s: ${y}")\n' $p; } > "$OUT/fl_$p.zbr"
  (cd "$OUT" && "$ZEBRA" fl_$p.zbr > "$OUT/fl_${p}_zig_out.txt" 2> "$OUT/fl_${p}_zig_err.txt"); zrc=$?
  rm -f "$OUT/fl_$p.v"
  (cd "$OUT" && "$ZEBRA" --target v fl_$p.zbr > "$OUT/fl_${p}_emit.txt" 2>&1)
  (cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/fl_$p.v" > "$OUT/fl_${p}_v_out.txt" 2> "$OUT/fl_${p}_v_err.txt"); vrc=$?
  case $p in
    toint*)
      zmsg=$(grep -o 'panic: .*' "$OUT/fl_${p}_zig_err.txt" | head -1 | sed 's/^panic: //' | tr -d '\r')
      if [ "$zrc" = 0 ] || [ "$zmsg" != 'integer part of floating point value out of bounds' ]; then fl_bad="$fl_bad $p(zig exit $zrc, no out-of-bounds trap: NO CONTROL)"
      elif [ "$vrc" = 0 ] || grep -q SURVIVED "$OUT/fl_${p}_v_out.txt" || ! grep -qF "$zmsg" "$OUT/fl_${p}_v_err.txt"; then fl_bad="$fl_bad $p(v exit $vrc, wanted '$zmsg': $(head -c 90 "$OUT/fl_${p}_v_out.txt" | tr '\n' ' '))"; fi ;;
    mod*)
      if [ "$zrc" != 0 ] || ! grep -q 'SURVIVED .*nan' "$OUT/fl_${p}_zig_out.txt"; then fl_bad="$fl_bad $p(zig exit $zrc and no NaN printed: NO CONTROL)"
      elif [ "$vrc" != 0 ] || ! diff -q "$OUT/fl_${p}_zig_out.txt" "$OUT/fl_${p}_v_out.txt" > /dev/null; then fl_bad="$fl_bad $p(v exit $vrc printed '$(head -c 60 "$OUT/fl_${p}_v_out.txt" | tr -d '\r\n')', zig '$(head -c 60 "$OUT/fl_${p}_zig_out.txt" | tr -d '\r\n')')"; fi ;;
  esac
done
# what this route cannot write the Zig route's way is refused by name: a 16-bit float, and
# Math.* on a float32 argument (the Zig route's builtins compute in the argument's type;
# this route's math is f64, and its digits would differ).
cat > "$OUT/fl_refuse.zbr" <<'ZBR'
def small(x: f16): f16
    return x

def main()
    var n = sys.args().count()
    var one: float32 = n.toFloat32()
    print(Math.sqrt(one))
    print(small(1.5))
ZBR
(cd "$OUT" && "$ZEBRA" --target v fl_refuse.zbr > "$OUT/fl_refuse_emit.txt" 2>&1)
fl_ref16=$(grep -cE '^    the type f16 \(V has no 16-bit float\)' "$OUT/fl_refuse_emit.txt")
fl_refmath=$(grep -cE '^    Math\.sqrt on a float32 argument' "$OUT/fl_refuse_emit.txt")
if [ -n "$fl_bad" ]; then echo "float32: FAILED -- an edge did not behave alike on both backends:$fl_bad"; fail=1
elif ! grep -qxF 'sum   0.3 0.30000000000000004 true 0.33333334' "$OUT/control_v_float32_test.txt"; then echo "float32: FAILED -- NO CONTROL: the Zig run did not print a float32 sum beside the float sum of the same operands"; fail=1
elif ! grep -qE '^  0 integer operation' "$OUT/v_float32_test_emit.txt"; then echo "float32: FAILED -- the fixture's emit left an integer operation unchecked: $(grep 'not overflow-checked' "$OUT/v_float32_test_emit.txt")"; fail=1
elif ! grep -q 'zshow_f32(' "$WT/test/v_float32_test_prog.v" || ! grep -q 'f32(zfmod(' "$WT/test/v_float32_test_prog.v" || ! grep -q 'zfloat_int(' "$WT/test/v_float32_test_prog.v"; then echo "float32: FAILED -- the emitted V does not reach zshow_f32, zfmod in f32 or zfloat_int: the comparison ran something else"; fail=1
elif [ "$fl_ref16" = 0 ] || [ "$fl_refmath" = 0 ]; then echo "float32: FAILED -- not refused by name: f16 ($fl_ref16 lines), Math.sqrt on a float32 ($fl_refmath lines)"; grep -E '^    |error' "$OUT/fl_refuse_emit.txt" | head -4 | cut -c1-160; fail=1
else echo "float32: ok -- $fl_n edge programs behave alike on both backends (five float-to-int conversions out of range die with the Zig route's message; three remainders with no value print the same NaN); f16 and Math.* on a float32 are refused by name"; fi
echo "── a builtin receiver's method through ?. and beside a class's of the same name (2026-11-17) ──"
# BUG-765 made the Zig route build `xs?.contains(5)`; its fixture was the first comparison of
# one, and it differed: the V route had no type for a builtin receiver's predicate, so the
# option of one was shown as V's `Option(true)`. Three things in CodeGenV since: a builtin
# receiver's predicate is a bool (vBuiltinBoolMethod); a string's isEmpty() is `.len == 0`
# (it was `.is_empty()`, no V string method: the V did not compile); and a builtin receiver's
# method is never typed by a declaration of the program's with the same name (with a class
# that has `def contains(...): str`, a list's contains was typed `string` and the V did not
# compile). v_optchain_bool has that class as its control: its own contains / indexOf answer
# a str on both routes, the string's and the containers' their own types.
for t in bug765_optchain_builtin_method_test v_optchain_bool_test; do
  compare "$t" "$WT" "test/$t.zbr" "$OUT/control_$t.txt" "$WT/test/${t}_prog.v"
done
rows=$((rows + 1))
if ! grep -qxF 'idx  2 nil 4 1 nil 42' "$OUT/control_v_optchain_bool_test.txt" || ! grep -qxF 'own  top:cup nil cup@top' "$OUT/control_v_optchain_bool_test.txt"; then echo "optchain: FAILED -- NO CONTROL: the Zig run did not print the string's indexOf beside the class's of the same name"; fail=1
elif ! grep -qF '.len == 0)' "$WT/test/v_optchain_bool_test_prog.v" || ! grep -qF 'zlist_contains(' "$WT/test/v_optchain_bool_test_prog.v"; then echo "optchain: FAILED -- the emitted V reaches neither the string's length test nor the list's contains: the comparison ran something else"; fail=1
elif grep -qF 'Option(' "$OUT/v_optchain_bool_test_v_out.txt" "$OUT/bug765_optchain_builtin_method_test_v_out.txt"; then echo "optchain: FAILED -- an option printed as V's own text"; fail=1
else echo "optchain: ok -- an optional predicate, an optional index and a string's isEmpty print alike on both backends, beside a class whose methods share the names"; fi
echo "── x.hash() on a builtin and Hash.fnv64 are FNV-1a 64 on both backends; a hash() the route cannot answer is refused by name (BUG-773) ──"
# BUG-773 gave str, every integer width, char and bool a `hash()` (Hash.fnv64: a str's bytes,
# an integer or a bool as the eight little-endian bytes of its i64, a char as its
# one-character string). The V route refused all of them and Hash.fnv64 itself; they are
# zebra_rt.v's zhash_fnv64 / zhash_int / zhash_bool / zhash_char now. The compiler's own
# fixture is compared, and both routes' printout is held to values computed OUTSIDE both
# (a Python FNV-1a 64 over the same bytes; "a" is the published vector 0xaf63dc4c8601ec8c
# read as an int): a matching pair of wrong hashes would otherwise be IDENTICAL.
# hash_shapes: the receiver as a call's result, a list's element three ways, a map's key, a
# walked item, a comparison, a sum and a concatenation, a class's own `cue hash` beside
# them (its 7 is the program's, never FNV), and the widths' edges: a uint64 above an int's
# range and an int8 of -1 hash as the int -1 does (the same 64 bits), a uint32 as its value.
# Two refusals, each with its control. A struct's hash() that only @derive(Hash) writes: the
# Zig route's is Wyhash over the fields and this route writes no method, so the emitted V
# named a method the struct did not have under "nothing refused" (test/bug776's fixture); a
# struct with @derive(Hash) AND its own `cue hash` is the program's and is written clean. A
# receiver whose type the emitter does not know: a V string has a `hash()` of its own (an
# int, not Zebra's), so the call passed through could be V's without a word. Those cases
# are held to the property, not to today's gaps: refused by name OR what the Zig route
# prints.
compare bug773_builtin_hash_test "$WT" test/bug773_builtin_hash_test.zbr "$OUT/control_bug773_builtin_hash_test.txt" "$WT/test/bug773_builtin_hash_test_prog.v"
cat > "$OUT/hash_shapes.zbr" <<'ZBR'
class Tag
    var name: str
    cue init(name: str)
        .name = name
    cue equals(o: Tag): bool
        return .name == o.name
    cue hash(): int
        return 7

def pick(xs: List(str), i: int): str
    return xs.at(i)

def first(xs: List(Tag)): Tag
    return xs.at(0)

def main()
    var xs = ["a", "b"]
    var ts = List(Tag)()
    ts.add(Tag("x"))
    var m = HashMap(str, int)()
    m["a"] = 1
    print("call [${pick(xs, 0).hash()}] at [${xs.at(1).hash()}] idx [${xs[0].hash()}]")
    print("tag [${first(ts).hash()}] [${ts.at(0).hash()}] [${ts[0].hash()}]")
    for k in m.keys()
        print("key [${k.hash()}]")
    for x in xs
        print("item [${x.hash()}]")
    print("cmp [${(1 < 2).hash()}]")
    print("sum [${(2 + 3).hash()}]")
    print("cat [${("a" + "b").hash()}]")
    print("fnv [${Hash.fnv64("ab")}]")
    var big: uint64 = 18446744073709551615
    var s8: int8 = -1
    var neg: int = -1
    var w: uint32 = 4000000000
    print("wide [${big.hash() == neg.hash()}] [${s8.hash() == neg.hash()}] [${big.hash()}] [${w.hash() == 4000000000.hash()}]")
ZBR
compare hash_shapes "$OUT" hash_shapes.zbr "$OUT/control_hash_shapes.txt" "$OUT/hash_shapes.v"
rows=$((rows + 1))
hash_bad=""
for o in "$OUT/control_bug773_builtin_hash_test.txt" "$OUT/bug773_builtin_hash_test_v_out.txt"; do
  [ -f "$o" ] || { hash_bad="$hash_bad no-$(basename "$o")"; continue; }
  grep -qxF 'str [-5808556873153909620] [-6615550055289275125] [-3750763034362895579] [true]' "$o" || hash_bad="$hash_bad $(basename "$o"):str"
  grep -qxF 'int [1000385178204227360] [-8289690350564177859] [-8064062821143829734] [true] [true]' "$o" || hash_bad="$hash_bad $(basename "$o"):int"
  grep -qxF 'char [-5808556873153909620] [true] [true] [true] [false]' "$o" || hash_bad="$hash_bad $(basename "$o"):char"
  grep -qxF 'bool [-6284781860667377211] [true]' "$o" || hash_bad="$hash_bad $(basename "$o"):bool"
  grep -qxF 'user [7]' "$o" || hash_bad="$hash_bad $(basename "$o"):user"
done
for o in "$OUT/control_hash_shapes.txt" "$OUT/hash_shapes_v_out.txt"; do
  [ -f "$o" ] || { hash_bad="$hash_bad no-$(basename "$o")"; continue; }
  grep -qxF 'tag [7] [7] [7]' "$o" || hash_bad="$hash_bad $(basename "$o"):tag"
  grep -qxF 'cat [620445648566982762]' "$o" || hash_bad="$hash_bad $(basename "$o"):cat"
  grep -qxF 'fnv [620445648566982762]' "$o" || hash_bad="$hash_bad $(basename "$o"):fnv"
  grep -qxF 'wide [true] [true] [-8289690350564177859] [true]' "$o" || hash_bad="$hash_bad $(basename "$o"):wide"
done
# the derived hash(): refused by name; with the struct's own cue beside the derive, written and run
(cd "$WT" && "$ZEBRA" --target v test/bug776_derive_hash_int_test.zbr > "$OUT/hash_derived_emit.txt" 2>&1)
grep -qF 'the hash() that @derive(Hash) writes for P' "$OUT/hash_derived_emit.txt" || hash_bad="$hash_bad derived-hash-not-refused"
rm -f "$WT/test/bug776_derive_hash_int_test_prog.v"
printf '@derive(Eq, Hash)\nstruct Q\n    var x: int\n    cue hash(): int\n        return .x + 40\n\ndef main()\n    print("own [${Q(2).hash()}]")\n' > "$OUT/hash_own_cue.zbr"
compare hash_own_cue "$OUT" hash_own_cue.zbr "$OUT/control_hash_own_cue.txt" "$OUT/hash_own_cue.v"
grep -qxF 'own [42]' "$OUT/hash_own_cue_v_out.txt" 2>/dev/null || hash_bad="$hash_bad own-cue-not-42"
# a receiver of unknown type: refused by name, or the Zig route's own answer. Three found
# untyped on 2026-11-17: a string's .len (V refuses the call written: an int has no hash), and
# two STRINGS -- a lambda's result and a map's value by index -- where the call written
# compiles as V's own string.hash and prints another number without a word
hash_unknown=""
unk() {   # <name> <the Zig route's line> ; the program is $OUT/hash_unk_<name>.zbr
  local n=$1 want=$2
  (cd "$OUT" && "$ZEBRA" "hash_unk_$n.zbr" > "$OUT/control_hash_unk_$n.txt" 2> "$OUT/hash_unk_${n}_zig_err.txt")
  (cd "$OUT" && rm -f "hash_unk_$n.v" && "$ZEBRA" --target v "hash_unk_$n.zbr" > "$OUT/hash_unk_${n}_emit.txt" 2>&1)
  if ! grep -qxF "$want" "$OUT/control_hash_unk_$n.txt"; then hash_bad="$hash_bad unknown-$n:NO-CONTROL(the-Zig-run-did-not-print-the-value-computed-outside)"
  elif grep -qF 'hash() on a receiver whose type the emitter does not know' "$OUT/hash_unk_${n}_emit.txt"; then hash_unknown="$hash_unknown $n=refused"
  elif [ -n "$(refusal_lines "$OUT/hash_unk_${n}_emit.txt")" ]; then hash_bad="$hash_bad unknown-$n:refused-in-other-words"
  else
    (cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/hash_unk_$n.v" > "$OUT/hash_unk_${n}_v_out.txt" 2> "$OUT/hash_unk_${n}_v_err.txt")
    if diff -q "$OUT/hash_unk_${n}_v_out.txt" "$OUT/control_hash_unk_$n.txt" > /dev/null; then hash_unknown="$hash_unknown $n=typed-and-the-Zig-answer"
    elif [ -s "$OUT/hash_unk_${n}_v_out.txt" ]; then hash_bad="$hash_bad unknown-$n:WRITTEN-RAN-AND-PRINTED-ANOTHER-HASH($(head -1 "$OUT/hash_unk_${n}_v_out.txt" | cut -c1-40))"
    else hash_bad="$hash_bad unknown-$n:written-and-V-refused-it"; fi
  fi
}
printf 'def main()\n    print("len [${"abc".len.hash()}]")\n' > "$OUT/hash_unk_len.zbr"
printf 'def main()\n    var f = def(x: str): str = x + "!"\n    print("lambda [${f("a").hash()}]")\n' > "$OUT/hash_unk_lambda.zbr"
printf 'def main()\n    var m = HashMap(str, str)()\n    m["k"] = "v"\n    print("mapget [${m["k"].hash()}]")\n' > "$OUT/hash_unk_mapget.zbr"
unk len 'len [-4052466453699787802]'
unk lambda 'lambda [620374180311149047]'
unk mapget 'mapget [-5808540380479486455]'
if [ -n "$hash_bad" ]; then echo "hash: FAILED --$hash_bad"; fail=1
else echo "hash: ok -- both routes print the values computed outside them; a class's own cue hash is the program's; @derive(Hash)'s hash() is refused by name and a struct's own cue beside the derive answers 42; a receiver of unknown type:$hash_unknown"; fi
echo "── the V target runs the type check (BUG-777, 2026-11-17) ──"
# Until BUG-777 `--target v` ran the parser and the resolver and never checkModule: a program
# `-c` refuses for a type mismatch was written out with "nothing refused" and could run (a
# List's `isEmpty()`, which the language does not have, printed `true`). vTarget checks every
# collected module now, as written, with the context a compile gives the checker. Six
# programs the checker refuses -- in the root, in a module beside it, against a module found
# on --module-path, a warning under --warnings-as-errors, a gap under --strict, a method the
# receiver does not have -- must each exit 1 with the checker's own line and the refusal
# line, and leave NO .v. The controls: the same shapes well typed must be written (the row
# can see a pass), `-c` must agree with every verdict, and the warning and the gap must be
# WRITTEN without their flag (the flags are what refuses them).
# Two things a compile does before it checks, which this route did not: the partial sibling
# files (Foo.extra.zbr) are merged into the module -- they were never read here, so a method
# declared in one was an unknown function to V; partial_test and partial_shared_test are
# compared now -- and a `use` is found by its exact name (BUG-450: `use Dep_ok` found
# dep_ok.zbr on a filesystem that ignores case, and nowhere else).
# NOT covered, and said in the doc: the refusals the Zig emitter makes at emit time (BUG-546,
# BUG-764, BUG-767 ...) are not the checker's and do not reach this route.
for t in partial_test partial_shared_test; do
  compare "$t" "$WT" "test/$t.zbr" "$OUT/control_$t.txt" "$WT/test/${t}_prog.v"
done
rows=$((rows + 1))
TC="$OUT/tc777"; rm -rf "$TC"; mkdir -p "$TC/lib"
printf 'def half(n: int): int\n    return n / 2\n\nclass Box\n    var w: int = 3\n    def area(k: int): int\n        return .w * k\n' > "$TC/dep_ok.zbr"
printf 'def half(n: int): int\n    var s: str = n\n    return n / 2\n' > "$TC/dep_bad.zbr"
printf 'def far(n: int): str\n    return "far${n}"\n' > "$TC/lib/farmod.zbr"
printf 'use dep_ok exposing half, Box\n\ndef main()\n    print(half(8))\n    print(Box().area(2))\n' > "$TC/ok_root.zbr"
printf 'use farmod exposing far\n\ndef main()\n    print(far(2))\n' > "$TC/ok_mp.zbr"
printf 'use dep_ok exposing half, Box\n\ndef main()\n    print(half("eight"))\n    print(Box().area("two"))\n' > "$TC/bad_call.zbr"
printf 'use dep_bad exposing half\n\ndef main()\n    print(half(8))\n' > "$TC/bad_dep.zbr"
printf 'use farmod exposing far\n\ndef main()\n    var n: int = far(2)\n    print(n)\n' > "$TC/bad_mp.zbr"
printf 'def main()\n    var xs = List(int)()\n    print(xs.isEmpty())\n' > "$TC/bad_method.zbr"
printf 'use Dep_ok exposing half\n\ndef main()\n    print(half(8))\n' > "$TC/bad_case.zbr"
printf '@deprecated("use g2")\ndef g(): int\n    return 1\ndef main()\n    print(g())\n' > "$TC/warned.zbr"
printf 'def main()\n    var x: int = Math\n    print(x)\n' > "$TC/gap.zbr"
tc_bad=""; tc_n=0
# tc_case <name> <want: refused|written> <expected text in the output, "" for none> [flags...]
tc_case() {
  local name=$1 want=$2 text=$3; shift 3
  tc_n=$((tc_n + 1))
  rm -f "$TC/$name.v"
  (cd "$TC" && "$ZEBRA" -c "$@" "$name.zbr" > "$TC/${name}_c.txt" 2>&1); local crc=$?
  (cd "$TC" && "$ZEBRA" --target v "$@" "$name.zbr" > "$TC/${name}_v.txt" 2>&1); local vrc=$?
  if [ "$want" = refused ]; then
    [ "$crc" != 0 ] || tc_bad="$tc_bad $name(NO-CONTROL:-c-accepts-it)"
    [ "$vrc" = 1 ] || tc_bad="$tc_bad $name(exit-$vrc-not-1)"
    [ ! -f "$TC/$name.v" ] || tc_bad="$tc_bad $name(a-.v-was-written)"
    grep -qF 'nothing written' "$TC/${name}_v.txt" || tc_bad="$tc_bad $name(no-refusal-line)"
    grep -qF "$text" "$TC/${name}_v.txt" || tc_bad="$tc_bad $name(not-the-checker's-line)"
  else
    [ "$crc" = 0 ] || tc_bad="$tc_bad $name(NO-CONTROL:-c-refuses-it)"
    [ "$vrc" = 0 ] && [ -f "$TC/$name.v" ] || tc_bad="$tc_bad $name(not-written:exit-$vrc)"
    if [ -n "$text" ]; then grep -qF "$text" "$TC/${name}_v.txt" || tc_bad="$tc_bad $name(lost:$text)"; fi
  fi
}
tc_case ok_root    written ""
tc_case ok_mp      written "" --module-path lib
tc_case warned     written "warning: 'g' is deprecated"
tc_case gap        written ""
tc_case bad_call   refused "bad_call.zbr:4:16: error: type mismatch"
tc_case bad_dep    refused "dep_bad.zbr:2:18: error: type mismatch"
tc_case bad_mp     refused "bad_mp.zbr:4:18: error: type mismatch" --module-path lib
tc_case bad_method refused "'List' has no method 'isEmpty'"
tc_case bad_case   refused "module names are case-sensitive, and the file here is dep_ok.zbr"
tc_case warned     refused "warning(s) with --warnings-as-errors" --warnings-as-errors
tc_case gap        refused "strict check" --strict
if [ -n "$tc_bad" ]; then echo "typecheck: FAILED --$tc_bad"; fail=1
else echo "typecheck: ok -- $tc_n cases: six programs the checker refuses and a module used in the wrong case are refused by --target v with the compile's own line and nothing written; their well-typed twins, and the warning and the gap without their flags, are written; -c agrees with each"; fi
echo "── the selfhost dumps ──"
for d in lexer_dump parser_dump ast_dump resolver_dump codegen_dump; do
  compare "$d" "$WT/selfhost" "$d.zbr" "$OUT/control_$d.txt" "$WT/selfhost/$d.v"
done
echo "── the route (refusals against the baseline, v -check) ──"
for m in CodeGen Checker main; do
  rows=$((rows + 1))
  (cd "$WT" && "$ZEBRA" --target v "selfhost/$m.zbr" > "$OUT/${m}_emit.txt" 2>&1)
  refusals=$(refusal_lines "$OUT/${m}_emit.txt" | wc -l)
  "$V" -check -enable-globals "$WT/selfhost/$m.v" > "$OUT/${m}_check.txt" 2>&1; crc=$?
  errs=$(grep -c 'error:' "$OUT/${m}_check.txt")
  verdict="ok"
  if [ "$m" = main ] && [ "$refusals" -gt "$ROUTE_REFUSALS_BASELINE" ]; then verdict="MORE REFUSALS than the baseline $ROUTE_REFUSALS_BASELINE"; fail=1; fi
  if [ "$m" != main ] && [ "$refusals" != 0 ]; then verdict="REFUSED"; fail=1; fi
  if [ "$crc" != 0 ]; then verdict="$verdict, v -check FAILED ($errs error lines)"; fail=1; fi
  echo "$m: refusals $refusals, v -check exit $crc -- $verdict"
  [ "$fail" = 1 ] && { refusal_lines "$OUT/${m}_emit.txt" | sed -E 's/ \([^)]*:[0-9]+\)//' | sort | uniq -c | sort -rn | head -4; grep "error:" "$OUT/${m}_check.txt" | head -3 | cut -c1-160; }
done
echo "── a nil unwrapped names its place (the Zig side's runtime faults do; the V side's did not until 2026-10-20) ──"
rows=$((rows + 1))
printf 'def main()\n    var x: int? = nil\n    if sys.args().count() > 100\n        x = 5\n    print(x!.toString())\n' > "$OUT/nil_at.zbr"
(cd "$OUT" && "$ZEBRA" nil_at.zbr > "$OUT/nil_at_zig_out.txt" 2> "$OUT/nil_at_zig_err.txt"); zrc=$?
(cd "$OUT" && "$ZEBRA" --target v nil_at.zbr > "$OUT/nil_at_emit.txt" 2>&1)
(cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/nil_at.v" > "$OUT/nil_at_v_out.txt" 2> "$OUT/nil_at_v_err.txt"); vrc=$?
if [ "$zrc" = 0 ] || [ "$vrc" = 0 ]; then echo "nil_at: FAILED -- a nil unwrapped must die on both backends (zig exit $zrc, v exit $vrc)"; fail=1
elif grep -q 'nil unwrapped at nil_at.zbr:5' "$OUT/nil_at_v_err.txt"; then echo "nil_at: ok -- V says: $(grep -m1 -o 'nil unwrapped at nil_at.zbr:5' "$OUT/nil_at_v_err.txt") (zig exit $zrc, v exit $vrc)"
else echo "nil_at: FAILED -- V died without naming the place:"; head -3 "$OUT/nil_at_v_err.txt" | cut -c1-160; fail=1; fi
echo "── integer overflow TRAPS on both backends (BUG-667, Sean 2026-10-30: trap, not wrap; V's operators wrap) ──"
rows=$((rows + 1))
# every operand from sys.args().count() (1), so nothing folds at compile time; each must die
# with Zig's message on BOTH backends and never print its SURVIVED line; the in-range control
# must print the same on both, and its emit must report no unchecked integer operation.
ov_body() {   # <name> -> the statements after `var n`
  case $1 in
    add)    printf '    var x: int = 9223372036854775807\n    var y: int = x + n\n' ;;
    sub)    printf '    var x: int = 0 - 9223372036854775807\n    var y: int = x - n - n\n' ;;
    mul)    printf '    var x: int = 5000000000000000000\n    var y: int = x * (n + 1)\n' ;;
    neg)    printf '    var x: int = 0 - 9223372036854775807 - n\n    var y: int = -x\n' ;;
    pluseq) printf '    var y: int = 9223372036854775807\n    y += n\n' ;;
    div)    printf '    var x: int = 0 - 9223372036854775807 - n\n    var y: int = x / (0 - n)\n' ;;
    mod)    printf '    var x: int = 0 - 9223372036854775807 - n\n    var y: int = x %% (0 - n)\n' ;;
  esac
}
ov_bad=""
for p in add sub mul neg pluseq div mod; do
  { printf 'def main()\n    var n: int = sys.args().count()\n'; ov_body $p; printf '    print("SURVIVED %s: " + y.toString())\n' $p; } > "$OUT/ov_$p.zbr"
  (cd "$OUT" && "$ZEBRA" ov_$p.zbr > "$OUT/ov_${p}_zig_out.txt" 2> "$OUT/ov_${p}_zig_err.txt"); zrc=$?
  (cd "$OUT" && "$ZEBRA" --target v ov_$p.zbr > "$OUT/ov_${p}_emit.txt" 2>&1)
  (cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/ov_$p.v" > "$OUT/ov_${p}_v_out.txt" 2> "$OUT/ov_${p}_v_err.txt"); vrc=$?
  if [ "$zrc" = 0 ] || ! grep -q 'integer overflow' "$OUT/ov_${p}_zig_err.txt"; then ov_bad="$ov_bad $p(zig exit $zrc, no trap)"
  elif [ "$vrc" = 0 ] || grep -q SURVIVED "$OUT/ov_${p}_v_out.txt" || ! grep -q 'integer overflow' "$OUT/ov_${p}_v_err.txt"; then ov_bad="$ov_bad $p(v exit $vrc: $(head -c 80 "$OUT/ov_${p}_v_out.txt" "$OUT/ov_${p}_v_err.txt" | tr '\n' ' '))"; fi
done
printf 'def main()\n    var n: int = sys.args().count()\n    var x: int = 9223372036854775806 + n\n    var y: int = 0 - x\n    y -= n\n    print(x.toString() + " " + y.toString() + " " + (x * n).toString() + " " + (x / (0 - n)).toString() + " " + (x %% 7).toString() + " " + (y + x).toString())\n' > "$OUT/ov_ok.zbr"
(cd "$OUT" && "$ZEBRA" ov_ok.zbr > "$OUT/ov_ok_zig_out.txt" 2> "$OUT/ov_ok_zig_err.txt")   # stdout only: the compiler's progress goes to stderr
(cd "$OUT" && "$ZEBRA" --target v ov_ok.zbr > "$OUT/ov_ok_emit.txt" 2>&1)
(cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/ov_ok.v" > "$OUT/ov_ok_v_out.txt" 2> "$OUT/ov_ok_v_err.txt")   # stdout only: V prints notices on stderr
if [ -n "$ov_bad" ]; then echo "overflow: FAILED -- did not trap on both backends:$ov_bad"; fail=1
elif [ ! -s "$OUT/ov_ok_zig_out.txt" ]; then echo "overflow: FAILED -- the in-range control printed nothing on Zig (NO CONTROL)"; fail=1
elif ! diff -q "$OUT/ov_ok_v_out.txt" "$OUT/ov_ok_zig_out.txt" > /dev/null; then echo "overflow: FAILED -- the in-range control differs:"; diff "$OUT/ov_ok_v_out.txt" "$OUT/ov_ok_zig_out.txt" | head -4; fail=1
elif ! grep -q 'not overflow-checked' "$OUT/ov_ok_emit.txt"; then echo "overflow: FAILED -- the V report printed no overflow count for the control (the line is printed at zero too, so its absence means the report is not being read)"; fail=1
elif ! grep -qE '^  0 integer operation' "$OUT/ov_ok_emit.txt"; then echo "overflow: FAILED -- the control's emit left an integer operation unchecked: $(grep 'not overflow-checked' "$OUT/ov_ok_emit.txt")"; fail=1
else echo "overflow: ok -- + - * neg += / % trap on both backends with Zig's message; the in-range control agrees ($(cat "$OUT/ov_ok_zig_out.txt"))"; fi
echo "── \${n:c} on an int is ONE byte, and out of 0..255 it TRAPS with the same words on both backends (BUG-703 / 713) ──"
rows=$((rows + 1))
# The trap fixture is the Zig smoke's own (test/bug703_fmt_c_runtime_trap_test.zbr: 300 from
# sys.args().count() + 299, so nothing folds). The control prints two in-range bytes that
# are one character together -- the pair BUG-713 wrote as four bytes here -- as hex.
FC_MSG='integer conversion out of range: 300 does not fit in byte'
cp "$WT/test/bug703_fmt_c_runtime_trap_test.zbr" "$OUT/fmtc_trap.zbr"
(cd "$OUT" && "$ZEBRA" fmtc_trap.zbr > "$OUT/fmtc_trap_zig_out.txt" 2> "$OUT/fmtc_trap_zig_err.txt"); fzrc=$?
(cd "$OUT" && "$ZEBRA" --target v fmtc_trap.zbr > "$OUT/fmtc_trap_emit.txt" 2>&1)
(cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/fmtc_trap.v" > "$OUT/fmtc_trap_v_out.txt" 2> "$OUT/fmtc_trap_v_err.txt"); fvrc=$?
# Its later lines are what examples/v_poc_utf8.zbr cannot tell apart on this route, because
# its vectors there are all single-byte items or symmetric: VALID multi-byte text reversed
# (V's own reverse() is by byte), an ODD centre (which side takes the spare byte), a width
# over a str in an interpolation (V counts visible characters), and the case of a
# non-ASCII letter (V's to_upper changes it; the Zig route's is ASCII-only).
cat > "$OUT/fmtc_ok.zbr" <<'ZBR'
def hexOf(s: str): str
    var sb = StringBuilder()
    for b in s.bytes()
        var k: int = b
        sb.append("${k:x} ")
    return sb.build()

def main()
    var n: int = sys.args().count()
    var s = "${n + 205:c}${n + 183:c}"
    print(hexOf(s) + "len ${s.len} items ${s.codePointCount()}")
    var t = "aé世"
    print("reverse " + hexOf(t.reverse()) + "| upper " + hexOf(t.upper()) + "| lower " + hexOf("AÉZ".lower()))
    print("center [" + "abc".center(8) + "] [" + "é".center(5) + "] width [${t:>8}] [${t:<8}] [${t:^9}] [${t:2}]")
    var items = 0
    for c in t.chars()
        items = items + 1
    print("items ${items} of ${t.len} bytes")
ZBR
(cd "$OUT" && "$ZEBRA" fmtc_ok.zbr > "$OUT/fmtc_ok_zig_out.txt" 2> "$OUT/fmtc_ok_zig_err.txt")
(cd "$OUT" && "$ZEBRA" --target v fmtc_ok.zbr > "$OUT/fmtc_ok_emit.txt" 2>&1)
(cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/fmtc_ok.v" > "$OUT/fmtc_ok_v_out.txt" 2> "$OUT/fmtc_ok_v_err.txt")
if [ "$fzrc" = 0 ] || grep -q SURVIVED "$OUT/fmtc_trap_zig_out.txt" || ! grep -qF "$FC_MSG" "$OUT/fmtc_trap_zig_err.txt"; then echo "fmt_c: FAILED -- the Zig run did not trap with the agreed words (exit $fzrc): NO CONTROL"; fail=1
elif [ "$fvrc" = 0 ] || grep -q SURVIVED "$OUT/fmtc_trap_v_out.txt" || ! grep -qF "$FC_MSG" "$OUT/fmtc_trap_v_err.txt"; then echo "fmt_c: FAILED -- the V run did not trap with the Zig run's words (exit $fvrc): $(head -c 160 "$OUT/fmtc_trap_v_out.txt" "$OUT/fmtc_trap_v_err.txt" | tr '\n' ' ')"; fail=1
elif [ "$(head -1 "$OUT/fmtc_ok_zig_out.txt")" != "ce b8 len 2 items 1" ] || [ "$(wc -l < "$OUT/fmtc_ok_zig_out.txt")" != 4 ]; then echo "fmt_c: FAILED -- the in-range control is not four lines beginning with two bytes and one item on Zig (NO CONTROL): $(head -c 200 "$OUT/fmtc_ok_zig_out.txt" "$OUT/fmtc_ok_zig_err.txt" | tr '\n' ' ')"; fail=1
elif ! diff -q "$OUT/fmtc_ok_v_out.txt" "$OUT/fmtc_ok_zig_out.txt" > /dev/null; then echo "fmt_c: FAILED -- the in-range control differs (V, then Zig):"; diff "$OUT/fmtc_ok_v_out.txt" "$OUT/fmtc_ok_zig_out.txt" | head -6 | cut -c1-200; grep -E "error" "$OUT/fmtc_ok_v_err.txt" "$OUT/fmtc_ok_emit.txt" | head -3 | cut -c1-200; fail=1
else echo "fmt_c: ok -- 300 under :c traps on both backends (zig exit $fzrc, v exit $fvrc: $FC_MSG); 206 and 184 are two bytes, one item; valid text reversed, centred, padded and cased alike ($(wc -l < "$OUT/fmtc_ok_zig_out.txt") lines)"; fi
echo "── a refused SQLite statement is reported the same way on both backends, and busyMs is the busy timeout wherever it is named (BUG-716 / 717) ──"
rows=$((rows + 1))
# Two programs, each run on both routes. The first is the Zig smoke's own fixture
# (test/bug716_717_sqlite_refusals_test.zbr): a constraint, a statement SQLite cannot read,
# a write and a read under another connection's lock with busyMs: 0, the default wait, a
# negative busyMs. The second is what that fixture does not reach: begin / commit /
# rollback refused by name, a query refused on its SECOND row (no rows, not one), a refusal
# with bound parameters, the open's own pragma refused under a lock (the connection comes
# back carrying it), and writeAhead / busyMs given by position and by name in both orders.
# Compared: stdout whole, and stderr's `sqlite: ...` and `Sqlite.open: ...` lines -- the
# agreed words, which stdout alone does not carry.
cp "$WT/test/bug716_717_sqlite_refusals_test.zbr" "$OUT/sq_fix.zbr"
cat > "$OUT/sq_more.zbr" <<'ZBR'
def clean(p: str)
    File.delete(p)
    File.delete(p + "-wal")
    File.delete(p + "-shm")

def say(what: str, db: SqliteDb)
    print(what + ": code " + db.lastErrorCode().toString() + " " + (db.lastError() orelse "nil"))

def main()
    var path: str = "zz_v_sqlite_more.db"
    clean(path)
    var a: SqliteDb = Sqlite.open(path, false, 0)!
    print("positional false, 0: " + a.journalMode())
    a.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)")
    a.exec("INSERT INTO t (id, v) VALUES (1, 'one')")
    a.exec("INSERT INTO t (id, v) VALUES (?, ?)", [2, "two"])
    say("three good statements", a)
    a.exec("INSERT INTO t (id, v) VALUES (?, ?)", [2, "again"])
    say("a duplicate key, with parameters", a)
    a.exec("SELEC (1)")
    say("an exec SQLite cannot read", a)
    a.commit()
    say("commit with none open", a)
    a.begin()
    say("begin", a)
    a.begin()
    say("begin inside one", a)
    a.rollback()
    say("rollback", a)
    a.rollback()
    say("rollback with none open", a)
    var part = a.query("SELECT CASE WHEN id = 2 THEN abs(-9223372036854775807 - 1) ELSE id END AS n FROM t ORDER BY id")
    print("rows ${part.count()}")
    say("a query refused on its second row", a)
    var whole = a.query("SELECT id FROM t ORDER BY id")
    print("rows ${whole.count()}")
    say("the next query", a)
    a.exec("BEGIN EXCLUSIVE")
    var tm = Timer.start()
    var b: SqliteDb = Sqlite.open(path, writeAhead: false, busyMs: 0)!
    say("an open under another's lock", b)
    b.exec("INSERT INTO t (id, v) VALUES (9, 'nine')")
    say("a write under it", b)
    # a busyMs ignored for the default would refuse just the same, five seconds later each
    print("busyMs: 0 refused at once: ${tm.elapsed() < 2500.0}")
    a.exec("COMMIT")
    b.exec("INSERT INTO t (id, v) VALUES (3, 'three')")
    say("its first statement after the lock went", b)
    a.close()
    b.close()
    var c: SqliteDb = Sqlite.open(path, busyMs: 0, writeAhead: true)!
    print("named, busyMs first: " + c.journalMode())
    say("a clean open", c)
    c.close()
    var d: SqliteDb = Sqlite.open(path, writeAhead: false)!
    print("named false: " + d.journalMode() + ", rows ${d.query("SELECT id FROM t").count()}")
    d.close()
    var neg: int = 0 - sys.args().count() - 6
    var e: SqliteDb? = Sqlite.open(path, busyMs: neg)
    print("negative busyMs answers nil: ${e == nil}")
    clean(path)
    print("sq_more: OK")
ZBR
sq_bad=""
for p in sq_fix sq_more; do
  (cd "$OUT" && "$ZEBRA" $p.zbr > "$OUT/${p}_zig_out.txt" 2> "$OUT/${p}_zig_err.txt"); zrc=$?
  (cd "$OUT" && "$ZEBRA" --target v $p.zbr > "$OUT/${p}_emit.txt" 2>&1)
  (cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/$p.v" > "$OUT/${p}_v_out.txt" 2> "$OUT/${p}_v_err.txt"); vrc=$?
  grep -E '^(sqlite: |Sqlite\.open: )' "$OUT/${p}_zig_err.txt" > "$OUT/${p}_zig_said.txt"
  grep -E '^(sqlite: |Sqlite\.open: )' "$OUT/${p}_v_err.txt" > "$OUT/${p}_v_said.txt"
  if [ "$zrc" != 0 ] || ! tail -1 "$OUT/${p}_zig_out.txt" | grep -q ': OK$'; then sq_bad="$sq_bad $p(NO CONTROL: the Zig run exited $zrc: $(tail -c 160 "$OUT/${p}_zig_err.txt" | tr '\n' ' '))"
  elif [ "$(refusal_lines "$OUT/${p}_emit.txt" | wc -l)" != 0 ]; then sq_bad="$sq_bad $p(REFUSED: $(refusal_lines "$OUT/${p}_emit.txt" | head -1 | cut -c1-140))"
  elif [ "$vrc" != 0 ]; then sq_bad="$sq_bad $p(v exit $vrc: $(grep -m2 -E 'error|panic|assert' "$OUT/${p}_v_err.txt" | cut -c1-200 | tr '\n' ' '))"
  elif ! diff -q "$OUT/${p}_v_out.txt" "$OUT/${p}_zig_out.txt" > /dev/null; then sq_bad="$sq_bad $p(stdout differs, V then Zig: $(diff "$OUT/${p}_v_out.txt" "$OUT/${p}_zig_out.txt" | head -4 | cut -c1-160 | tr '\n' ' '))"
  elif ! diff -q "$OUT/${p}_v_said.txt" "$OUT/${p}_zig_said.txt" > /dev/null; then sq_bad="$sq_bad $p(the refusal lines differ, V then Zig: $(diff "$OUT/${p}_v_said.txt" "$OUT/${p}_zig_said.txt" | head -4 | cut -c1-160 | tr '\n' ' '))"; fi
done
# the controls of the comparison itself: the Zig run must have SAID refusals (an empty list
# equals an empty list), a lock refusal and the negative-busyMs words among them
if [ -n "$sq_bad" ]; then echo "sqlite: FAILED --$sq_bad"; fail=1
elif ! grep -qF 'sqlite: exec failed: database is locked (code 5)' "$OUT/sq_fix_zig_said.txt" || ! grep -qF 'sqlite: open failed: ' "$OUT/sq_more_zig_said.txt" || ! grep -qF 'is negative -- it is the wait in milliseconds, 0 to refuse at once' "$OUT/sq_more_zig_said.txt"; then echo "sqlite: FAILED -- the Zig run did not say the refusals the comparison rests on (NO CONTROL): $(cat "$OUT/sq_fix_zig_said.txt" "$OUT/sq_more_zig_said.txt" | head -4 | cut -c1-120 | tr '\n' ' ')"; fail=1
else echo "sqlite: ok -- both programs alike on both backends: stdout ($(wc -l < "$OUT/sq_fix_zig_out.txt") + $(wc -l < "$OUT/sq_more_zig_out.txt") lines) and the refusal lines on stderr ($(wc -l < "$OUT/sq_fix_zig_said.txt") + $(wc -l < "$OUT/sq_more_zig_said.txt"))"; fi
echo "── Net.resolve asks the system resolver on both backends, and refuses what is no host name in the same words (BUG-726) ──"
rows=$((rows + 1))
# The V route had no Net at all until 2026-11-14 (a program naming it was refused). Two
# programs, each through both backends: the Zig route's own fixture for BUG-726, and one
# with the refusals written out and a local named `net` (the emitted V file imports a module
# of that name). Compared: stdout whole, and stderr's refusals of text that is no host name
# -- the words both routes agree on. A lookup that FAILS says the resolver's own reason,
# which differs by backend and by machine, so no such host is in either program.
cp "$WT/test/bug726_net_resolve_test.zbr" "$OUT/nr_fix.zbr"
cat > "$OUT/nr_more.zbr" <<'ZBR'
def main()
    var net = Net.resolve("localhost")
    print("localhost: ${net.len > 0}, first ${net.at(0)}")
    print("an IPv4 literal: " + Net.resolve("192.0.2.7").join(" "))
    print("an IPv6 literal: " + Net.resolve("::1").join(" "))
    var bad: List(str) = ["bad host", "", "-lead.example", "a..b", "trail-.example", "under_score.example", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example"]
    for b in bad
        var got = Net.resolve(b)
        print("no host name '" + b + "': ${got.len == 0}")
    var grown = Net.resolve("127.0.0.1")
    grown.add("more")
    print("a list like any other: ${grown.len} " + grown.join(" "))
    print("nr_more: OK")
ZBR
nr_bad=""
for p in nr_fix nr_more; do
  (cd "$OUT" && "$ZEBRA" $p.zbr > "$OUT/${p}_zig_out.txt" 2> "$OUT/${p}_zig_err.txt"); zrc=$?
  (cd "$OUT" && "$ZEBRA" --target v $p.zbr > "$OUT/${p}_emit.txt" 2>&1)
  (cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/$p.v" > "$OUT/${p}_v_out.txt" 2> "$OUT/${p}_v_err.txt"); vrc=$?
  grep -E '^net: cannot resolve ".*": [A-Za-z]+ \(not a host name or an IP address\)' "$OUT/${p}_zig_err.txt" > "$OUT/${p}_zig_said.txt"
  grep -E '^net: cannot resolve ".*": [A-Za-z]+ \(not a host name or an IP address\)' "$OUT/${p}_v_err.txt" > "$OUT/${p}_v_said.txt"
  if [ "$zrc" != 0 ] || ! tail -1 "$OUT/${p}_zig_out.txt" | grep -q ': OK$'; then nr_bad="$nr_bad $p(NO CONTROL: the Zig run exited $zrc: $(tail -c 160 "$OUT/${p}_zig_err.txt" | tr '\n' ' '))"
  elif [ "$(refusal_lines "$OUT/${p}_emit.txt" | wc -l)" != 0 ]; then nr_bad="$nr_bad $p(REFUSED: $(refusal_lines "$OUT/${p}_emit.txt" | head -1 | cut -c1-140))"
  elif [ "$vrc" != 0 ]; then nr_bad="$nr_bad $p(v exit $vrc: $(grep -m2 -E 'error|panic|assert' "$OUT/${p}_v_err.txt" | cut -c1-200 | tr '\n' ' '))"
  elif ! diff -q "$OUT/${p}_v_out.txt" "$OUT/${p}_zig_out.txt" > /dev/null; then nr_bad="$nr_bad $p(stdout differs, V then Zig: $(diff "$OUT/${p}_v_out.txt" "$OUT/${p}_zig_out.txt" | head -4 | cut -c1-160 | tr '\n' ' '))"
  elif ! diff -q "$OUT/${p}_v_said.txt" "$OUT/${p}_zig_said.txt" > /dev/null; then nr_bad="$nr_bad $p(the refusal lines differ, V then Zig: $(diff "$OUT/${p}_v_said.txt" "$OUT/${p}_zig_said.txt" | head -4 | cut -c1-160 | tr '\n' ' '))"; fi
done
# the controls of the comparison itself: the Zig run must have SAID the refusals (an empty
# list equals an empty list), seven of them in the second program, and the V file must have
# been built WITH the net section (a program that named no znet_ call would diff clean)
if [ -n "$nr_bad" ]; then echo "net: FAILED --$nr_bad"; fail=1
elif [ "$(wc -l < "$OUT/nr_more_zig_said.txt")" != 7 ] || ! grep -qF 'net: cannot resolve "bad host": InvalidHostName (not a host name or an IP address)' "$OUT/nr_fix_zig_said.txt"; then echo "net: FAILED -- NO CONTROL: the Zig runs did not say the refusals the comparison is about ($(wc -l < "$OUT/nr_fix_zig_said.txt") and $(wc -l < "$OUT/nr_more_zig_said.txt") lines, wanted 1 and 7)"; fail=1
elif ! grep -q 'znet_resolve(' "$OUT/nr_more.v" || ! grep -q '^import net$' "$OUT/nr_more.v"; then echo "net: FAILED -- the emitted V names no znet_resolve or does not import net: the row compared something else"; fail=1
else echo "net: ok -- both programs alike on both backends: stdout ($(wc -l < "$OUT/nr_fix_zig_out.txt") + $(wc -l < "$OUT/nr_more_zig_out.txt") lines) and the refusals of what is no host name ($(wc -l < "$OUT/nr_fix_zig_said.txt") + $(wc -l < "$OUT/nr_more_zig_said.txt") lines)"; fi
echo "── the V this runs with verifies HTTPS certificates by default (the V route's Http.get is V's http.get) ──"
rows=$((rows + 1))
# zebra_rt.v's zhttp_get / zhttp_post call V's http.get / http.post with no config, so the V
# route's answer to a certificate nobody signed is V's default. Until vlang/v 40774847a9
# (2026-11-08) that default was NOT to check: under the pin before this one (b399a50) http.get
# answered 200 from a self-signed host and from an expired one, where the Zig route refuses
# both. A test of the behaviour needs the network, which no gate has; this leg reads the
# default out of the V it was given instead. Every `validate bool` field in the two files must
# say `= true`. A file that is missing, or that has no such field any more, is REFUSED too:
# when the shape changes this leg can no longer tell, and must not read that as a pass.
cert_root=$(dirname "$V"); cert_bad=""
for f in vlib/net/http/http.v vlib/net/http/request.v; do
  if [ ! -f "$cert_root/$f" ]; then cert_bad="$cert_bad $f(not found beside $V: nothing was read)"; continue; fi
  cert_fields=$(grep -cE '^[[:space:]]+validate[[:space:]]+bool' "$cert_root/$f")
  cert_on=$(grep -cE '^[[:space:]]+validate[[:space:]]+bool[[:space:]]*=[[:space:]]*true' "$cert_root/$f")
  if [ "$cert_fields" = 0 ]; then cert_bad="$cert_bad $f(no \`validate bool\` field: the file's shape changed and this leg can no longer tell)"
  elif [ "$cert_on" != "$cert_fields" ]; then cert_bad="$cert_bad $f($cert_on of $cert_fields \`validate\` fields default to true)"; fi
done
if [ -n "$cert_bad" ]; then echo "certs: FAILED -- this V does not verify HTTPS certificates by default, or it cannot be told:$cert_bad -- use a V at or after vlang/v 40774847a9 (the pin, /c/Projects/v-c4dee97/v.exe)"; fail=1
else echo "certs: ok -- FetchConfig.validate and Request.validate default to true in $cert_root/vlib/net/http"; fi
echo "── a container printed, interpolated or joined is the Zig route's text; Json.parse stops at 256 levels (BUG-723, BUG-734) ──"
rows=$((rows + 1))
# Three programs through both backends, stdout compared whole, and a fourth that must be
# REFUSED. show_fix and jd_fix are the Zig route's own fixtures (test/bug723_chars_value_test.zbr:
# s.chars() and s.bytes() as values, printed, counted, joined; test/bug734_json_depth_test.zbr:
# arrays, objects and mixed nesting at 256 and 257, 100,000 levels, brackets inside strings).
# show_more is what the first does not reach: every element kind the V route prints, in a
# print, a hole and a join, empty, nested three deep, as a map's value, through a field.
# Until BUG-723 a container in a print or a hole was V's own str() of the boxed type
# (`&ZList[rune]{ items: [...] }`). A map and a set are printed with ONE entry: their order
# is promised on neither route. A container's toString() is the same text (BUG-743: the Zig
# route printed Zig's own struct dump there until 718330a; this row's first run found it).
# show_fix2 is the Zig route's fixture for that (test/bug743_tostring_show_test.zbr), which
# also asks for a class, a struct and an enum as text and writes a set literal. show_types
# is what IT does not reach, and what it found on this route: a class without its own
# toString printed V's dump and one with its own printed `&Named(own)` in a hole (BUG-746);
# a struct built with fewer arguments than fields got zero, not the field's default, and a
# class's list or class field with a declared default started empty or nil (BUG-745).
# show_fix3 is the Zig route's fixture for a class that reaches itself (BUG-749,
# test/bug749_show_self_ref_test.zbr: one met again on the path being printed is
# `Name{...}`, a shared one prints in full). show_cycle is what it does not reach: the way
# back through a list, a map and a struct, the cut at 256 levels, and four threads printing
# one cyclic object at once (the path is each thread's own). show_opt is an optional as text:
# printed and in a hole it was still V's own (`Option(none)`, V's dump of the class inside).
cp "$WT/test/bug723_chars_value_test.zbr" "$OUT/show_fix.zbr"
cp "$WT/test/bug734_json_depth_test.zbr" "$OUT/jd_fix.zbr"
cp "$WT/test/bug743_tostring_show_test.zbr" "$OUT/show_fix2.zbr"
cp "$WT/test/bug749_show_self_ref_test.zbr" "$OUT/show_fix3.zbr"
cat > "$OUT/show_cycle.zbr" <<'ZBR'
# What the Zig route's BUG-749 fixture does not reach: a cycle that passes through a list,
# a map, a struct and an optional on its way back; the cut at 256 levels; and the path being
# each thread's own (four threads print one cyclic object at once: a path shared between
# them would write `Node{...}` for an object another thread is in the middle of).

class Node
    var name: str = "n"
    var kids: List(Node) = List(Node)()
    var by: HashMap(str, Node) = HashMap(str, Node)()

struct Slot
    var held: Link? = nil

class Link
    var id: int = 0
    var slot: Slot = Slot()
    var next: Link? = nil

var failures: int = 0

def check(what: str, got: str, want: str)
    if got == want
        print("${what}: ok")
    else
        print("  WRONG: ${what}: got '${got}', want '${want}'")
        failures += 1

def count(hay: str, needle: str): int
    var n: int = 0
    var at: int = hay.indexOf(needle)
    while at >= 0
        n += 1
        var rest: str = hay.substring(at + needle.len, hay.len)
        var nx: int = rest.indexOf(needle)
        if nx < 0
            at = -1
        else
            at = at + needle.len + nx
    return n

def main()
    var root = Node()
    root.name = "root"
    root.kids.add(root)
    check("through-a-list", root.toString(), "Node{name: \"root\", kids: [Node{...}], by: {}}")

    var m = Node()
    m.name = "m"
    m.by.set("me", m)
    check("through-a-map", "${m}", "Node{name: \"m\", kids: [], by: {me: Node{...}}}")

    var a = Link()
    a.id = 1
    var b = Link()
    b.id = 2
    a.slot = Slot(held: b)
    b.next = a
    check("through-a-struct", a.toString(), "Link{id: 1, slot: Slot{held: Link{id: 2, slot: Slot{held: nil}, next: Link{...}}}, next: nil}")

    # 300 links in a line: 256 are written, the 257th is cut
    var head = Link()
    var tail = head
    for i in 1..300
        var nx = Link()
        nx.id = i
        tail.next = nx
        tail = nx
    var deep: str = head.toString()
    check("deep-written", count(deep, "Link{id:").toString(), "256")
    check("deep-cut", count(deep, "Link{...}").toString(), "1")
    # and the path is empty again after it: the same value prints the same
    check("deep-again", (head.toString() == deep).toString(), "true")
    check("after-deep", root.toString(), "Node{name: \"root\", kids: [Node{...}], by: {}}")

    # four threads, one cyclic object, 500 prints each
    var want: str = root.toString()
    var done: Chan(int) = Chan(int)(8)
    for t in 0..4
        sys.go(def()
            capture
                var r: Node = root
                var w: str = want
                var d: Chan(int) = done
            var bad: int = 0
            for k in 0..500
                if r.toString() != w
                    bad += 1
            d.send(bad)
        )
    var wrong: int = 0
    for t in 0..4
        var got: int? = done.recv()
        if got as g
            wrong += g
        else
            wrong += 1000
    check("four-threads", wrong.toString(), "0")

    if failures == 0
        print("show_cycle: OK")
    else
        print("show_cycle: ${failures} WRONG")
ZBR
cat > "$OUT/show_types.zbr" <<'ZBR'
# BUG-745 / BUG-746, the V half: a class, a struct and an enum as text -- printed,
# in a hole, from toString(), inside a container, as a field of another -- and a
# struct built with fewer arguments than it has fields.

class Leaf
    var name: str = "leaf"
    var n: int = 2
    var note: str? = nil
    var count: int? = 5

class Tagged
    var t: str = "own"
    cue toString(): str
        return "Tagged(${.t})"

struct Rgb
    var r: int = 3
    var g: int = 4

enum Hue
    warm
    cold

class Box
    var hue: Hue = Hue.cold
    var rgb: Rgb = Rgb()
    var tags: List(str) = ["a"]
    var tagged: Tagged = Tagged()

def main()
    # a class without its own toString: Name{field: value, ...}, a string field quoted
    var lf = Leaf()
    print(lf)
    print("hole: ${lf}")
    print("toString: " + lf.toString())
    var two = Leaf()
    two.name = "two"
    two.note = "noted"
    two.count = nil
    print(two)

    # a class with its own: that text, with no `&` before it in a hole
    var tg = Tagged()
    print(tg)
    print("hole: ${tg}")
    print("toString: " + tg.toString())

    # a struct with no cue init: a missing argument is the field's default (BUG-745)
    var none_given = Rgb()
    print(none_given)
    var one_given = Rgb(9)
    print(one_given)
    var both_given = Rgb(7, 8)
    print("hole: ${both_given} toString: " + both_given.toString())
    print("fields: ${none_given.r} ${none_given.g} ${one_given.r} ${one_given.g}")

    # an enum, and all of them as fields of a class
    var h = Hue.warm
    print(h)
    print("hole: ${h} toString: " + h.toString())
    var bx = Box()
    print(bx)

    # inside containers
    var leaves: List(Leaf) = [lf]
    print(leaves)
    var tgs: List(Tagged) = [tg]
    print(tgs)
    var hues: List(Hue) = [Hue.warm, Hue.cold]
    print(hues)
    var rgbs: List(Rgb) = [none_given, one_given]
    print("hole: ${rgbs}")
    var by_name: HashMap(str, Leaf) = HashMap(str, Leaf)()
    by_name.set("k", lf)
    print(by_name)

    # a set literal
    var st: Set(int) = {4}
    print(st)
    var words: Set(str) = {"w"}
    print("hole: ${words} count ${words.count()}")
    print("show_types: OK")
ZBR
cat > "$OUT/show_more.zbr" <<'ZBR'
# BUG-723, the V half: what the Zig fixture does not reach. A container printed
# by print, by an interpolation hole and by toString(), for every element kind
# the V route prints, nested, empty, and as a map's value. A map and a set are
# printed with ONE entry only: their order is not promised on either route.

class Shelf
    var names: List(str)
    var counts: HashMap(str, int)

    cue init()
        .names = ["a", "b"]
        .counts = HashMap(str, int)()
        .counts.set("only", 7)

    def show(): str
        return "${.names} ${.counts}"

def main()
    var ints: List(int) = [1, 2, 3]
    var strs: List(str) = ["a", "b c", ""]
    var floats: List(float) = [1.0, 2.5, 0.1]
    var bools: List(bool) = [true, false]
    var cs: List(char) = "aéb".chars()
    var bs: List(byte) = "hi".bytes()
    print(ints)
    print(strs)
    print(floats)
    print(bools)
    print(cs)
    print(bs)
    print("holes: ${ints} ${strs} ${floats} ${bools} ${cs} ${bs}")
    print("two args:", ints, strs)
    print("toString: " + ints.toString() + " " + strs.toString() + " " + cs.toString() + " " + floats.toString())
    # joins of what is not a list of strings
    print("joins: " + ints.join("+") + " " + floats.join(" ") + " " + bools.join("/") + " " + cs.join("-") + " " + bs.join(","))

    # empty ones
    var none: List(str) = List(str)()
    print(none)
    print("empty hole: ${none}")

    # nested
    var grid: List(List(int)) = [[1, 2], [3], List(int)()]
    print(grid)
    print("grid hole: ${grid}")
    var words: List(List(str)) = [["a"], ["b", "c"]]
    print(words)
    var deep: List(List(List(int))) = [[[1], [2, 3]], [[4]]]
    print(deep)

    # a map and a set, one entry each
    var m: HashMap(str, int) = HashMap(str, int)()
    m.set("a", 1)
    print(m)
    print("map hole: ${m}")
    var ms: HashMap(str, str) = HashMap(str, str)()
    ms.set("k", "v")
    print(ms)
    var ml: HashMap(str, List(str)) = HashMap(str, List(str))()
    ml.set("k", ["x", "y"])
    print(ml)
    var mi: HashMap(int, List(int)) = HashMap(int, List(int))()
    mi.set(4, [5])
    print(mi)
    var empty_map: HashMap(str, int) = HashMap(str, int)()
    print(empty_map)
    var s: Set(str) = Set(str)()
    s.add("x")
    print(s)
    var si: Set(int) = Set(int)()
    si.add(9)
    print("set hole: ${si}")
    var lm: List(HashMap(str, int)) = [m]
    print(lm)
    print("map toString: " + m.toString() + " " + ml.toString() + " set: " + s.toString() + " nested: " + grid.toString())

    # through fields
    var sh = Shelf()
    print(sh.show())
    print(sh.names)

    # a char and a string OUTSIDE a container are bare, as they always were
    print(cs.at(1))
    print(strs.at(1))
    print("show_more: OK")
ZBR
cat > "$OUT/show_refuse.zbr" <<'ZBR'
interface Labelled
    def label(): str

class Tag implements Labelled
    var t: str = "x"
    def label(): str
        return .t

def main()
    var os: List(int?) = [1, nil]
    print("${os}")
    var ls: List(Labelled) = [Tag()]
    print(ls)
ZBR
cat > "$OUT/show_opt.zbr" <<'ZBR'
# An optional as text (BUG-746's ground): printed and in a hole, `nil` or the value as the Zig
# route writes it -- never V's `Option(none)` / `&Option(&nil)` or its dump of a class inside.
# The last lines are a cycle that goes round through a cue toString's own hole (`"${.b}"`):
# V's dump recursed there until the stack ended.

class Leaf
    var name: str = "leaf"

struct Rgb
    var r: int = 1

enum Hue
    warm
    cold

class Holder
    var l: Leaf? = nil
    var n: int? = nil
    def show(): str
        return "l=${.l} n=${.n}"

class Owner
    var b: Held? = nil
    cue toString(): str
        return "Owner<${.b}>"

class Held
    var o: Owner? = nil

def main()
    var a: int? = 5
    var b: int? = nil
    var s: str? = "hi"
    var t: str? = nil
    var f: float? = 2.0
    var k: bool? = true
    var c: char? = c'x'
    var l: Leaf? = Leaf()
    var m: Leaf? = nil
    var r: Rgb? = Rgb()
    var h: Hue? = Hue.cold
    var xs: List(int)? = [1, 2]
    print("int ${a} ${b}")
    print("str ${s} ${t}")
    print("float ${f} bool ${k} char ${c}")
    print("class ${l} ${m}")
    print("struct ${r} enum ${h}")
    print("list ${xs}")
    print(a)
    print(s)
    print(l)
    print(m)
    print(xs)
    var hd = Holder()
    print(hd.show())
    hd.l = Leaf()
    hd.n = 3
    print(hd.show())
    var ow = Owner()
    var held = Held()
    ow.b = held
    held.o = ow
    print(ow.toString())
    print("${held}")
    print("show_opt: OK")
ZBR
show_bad=""
for p in show_fix jd_fix show_more show_fix2 show_types show_fix3 show_cycle show_opt; do
  (cd "$OUT" && "$ZEBRA" $p.zbr > "$OUT/${p}_zig_out.txt" 2> "$OUT/${p}_zig_err.txt"); zrc=$?
  (cd "$OUT" && "$ZEBRA" --target v $p.zbr > "$OUT/${p}_emit.txt" 2>&1)
  (cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/$p.v" > "$OUT/${p}_v_out.txt" 2> "$OUT/${p}_v_err.txt"); vrc=$?
  if [ "$zrc" != 0 ] || ! tail -1 "$OUT/${p}_zig_out.txt" | grep -q ': OK$'; then show_bad="$show_bad $p(NO CONTROL: the Zig run exited $zrc and ended '$(tail -1 "$OUT/${p}_zig_out.txt" | cut -c1-80)': $(tail -c 160 "$OUT/${p}_zig_err.txt" | tr '\n' ' '))"
  elif [ "$(refusal_lines "$OUT/${p}_emit.txt" | wc -l)" != 0 ]; then show_bad="$show_bad $p(REFUSED: $(refusal_lines "$OUT/${p}_emit.txt" | head -1 | cut -c1-140))"
  elif [ "$vrc" != 0 ]; then show_bad="$show_bad $p(v exit $vrc: $(grep -m2 -E 'error|panic|assert' "$OUT/${p}_v_err.txt" | cut -c1-200 | tr '\n' ' '))"
  elif ! diff -q "$OUT/${p}_v_out.txt" "$OUT/${p}_zig_out.txt" > /dev/null; then show_bad="$show_bad $p(stdout differs, V then Zig: $(diff "$OUT/${p}_v_out.txt" "$OUT/${p}_zig_out.txt" | head -4 | cut -c1-160 | tr '\n' ' '))"; fi
done
# the refusals: a container of an optional (V's generics take no option type: named where the
# type is spelled, where until BUG-746's work it reached V and failed there), and an interface
# value printed -- each by name, never V's str()
(cd "$OUT" && "$ZEBRA" --target v show_refuse.zbr > "$OUT/show_refuse_emit.txt" 2>&1)
show_refused=$(grep -cE '^    (a List of an optional \(\?i64\)|printing a Labelled )' "$OUT/show_refuse_emit.txt")
# the controls of the comparison itself: the Zig run must have printed the containers the
# row is about (the spelling the V side is held to), the emitted V must reach the runtime's
# printers and a nested helper (a program that printed no container would diff clean), and
# the depth fixture's V file must call the scan
if [ -n "$show_bad" ]; then echo "show: FAILED --$show_bad"; fail=1
elif ! grep -qxF "['a', 'é', 'b']" "$OUT/show_more_zig_out.txt" || ! grep -qxF '{k: ["x", "y"]}' "$OUT/show_more_zig_out.txt" || ! grep -qxF '[[[1], [2, 3]], [[4]]]' "$OUT/show_more_zig_out.txt"; then echo "show: FAILED -- NO CONTROL: the Zig run did not print the containers the comparison is about"; fail=1
elif ! grep -q 'zshow_list(' "$OUT/show_more.v" || ! grep -q '^fn zshow_h[0-9]' "$OUT/show_more.v" || ! grep -q 'zjoin_with(' "$OUT/show_more.v" || ! grep -q 'zshow_map(' "$OUT/show_more.v"; then echo "show: FAILED -- the emitted V names no zshow_list / zshow_map / zjoin_with or no nested helper: the row compared something else"; fail=1
elif ! grep -q 'if zjson_too_deep(zr_s)' "$OUT/jd_fix.v"; then echo "show: FAILED -- the depth fixture's V file does not call the scan"; fail=1
elif ! grep -qxF 'Box{hue: cold, rgb: Rgb{r: 3, g: 4}, tags: ["a"], tagged: Tagged(own)}' "$OUT/show_types_zig_out.txt" || ! grep -qxF 'Rgb{r: 9, g: 4}' "$OUT/show_types_zig_out.txt" || ! grep -qxF 'hole: Tagged(own)' "$OUT/show_types_zig_out.txt"; then echo "show: FAILED -- NO CONTROL: the Zig run did not print the class, struct and default lines show_types is about"; fail=1
elif ! grep -qE '^fn zshow_h[0-9]+\(zr_e &Leaf\) string' "$OUT/show_types.v" || ! grep -q 'zset_of\[' "$OUT/show_types.v"; then echo "show: FAILED -- the emitted V has no class printer or no set literal: show_types compared something else"; fail=1
elif ! grep -qxF 'class Leaf{name: "leaf"} nil' "$OUT/show_opt_zig_out.txt" || ! grep -qxF 'Owner<Held{o: Owner<Held{...}>}>' "$OUT/show_opt_zig_out.txt"; then echo "show: FAILED -- NO CONTROL: the Zig run did not print the optional and the cue-toString cycle show_opt is about"; fail=1
elif ! grep -q 'if !zshow_enter(voidptr(zr_e))' "$OUT/show_cycle.v" || ! grep -q 'if !zshow_enter(voidptr(zr_e))' "$OUT/show_fix3.v"; then echo "show: FAILED -- the emitted class printers do not ask the path (zshow_enter): the cycle programs compared something else"; fail=1
elif [ "$show_refused" != 2 ]; then echo "show: FAILED -- a list of an optional and a printed interface must each be refused by name ($show_refused of 2): $(refusal_lines "$OUT/show_refuse_emit.txt" | head -2 | cut -c1-120 | tr '\n' ' ')"; fail=1
else echo "show: ok -- eight programs alike on both backends ($(wc -l < "$OUT/show_fix_zig_out.txt") + $(wc -l < "$OUT/jd_fix_zig_out.txt") + $(wc -l < "$OUT/show_more_zig_out.txt") + $(wc -l < "$OUT/show_fix2_zig_out.txt") + $(wc -l < "$OUT/show_types_zig_out.txt") + $(wc -l < "$OUT/show_fix3_zig_out.txt") + $(wc -l < "$OUT/show_cycle_zig_out.txt") + $(wc -l < "$OUT/show_opt_zig_out.txt") lines); a list of an optional and a printed interface refused by name"; fi
echo "── a program name V's builtin module keeps privately is moved aside (vlang/v#32404: class Node was built by the sorted map's new_node) ──"
rows=$((rows + 1))
# V master gives a program function the BODY of a private builtin function of the same name
# and signature, silently: `fn new_node() &Node` returned a mapnode, so a `class Node` came
# back with no field defaults and a nil list. CodeGenV carries the private names and writes
# such a name with a trailing `_`. Three legs: the program below is alike on both routes;
# its V names the moved constructor (a program that met no such name would diff clean);
# and the emitter's list still covers the private names of the V in use, read from the
# vlib beside it -- a pin move that adds one fails here, by name, before it bites.
cat > "$OUT/names.zbr" <<'ZBR'
# Names V's builtin module keeps privately (vlang/v#32404): a class Node's constructor is
# `new_node`, which V master silently swaps for its sorted map's. Each shape a program can
# write such a name in -- a class with defaults, a class with an init, a struct, a function,
# a method, a field, a local -- must behave as on the Zig route.

class Node
    var name: str = "n"
    var kids: List(Node) = List(Node)()

class MapInit
    var size: int
    cue init(size: int)
        .size = size
    def newNode(): int
        return .size + 1

struct MapData
    var cap: int = 4
    var newMap: int = 9

def isTerminal(): bool
    return true

def newDenseArray(a: int, b: int): int
    return a * 10 + b

def main()
    var root = Node()
    root.kids.add(root)
    print("node: ${root.name} ${root.kids.count()}")
    var sm = MapInit(3)
    print("map init: ${sm.size} ${sm.newNode()}")
    var da = MapData()
    print("map data: ${da.cap} ${da.newMap}")
    var d2 = MapData(cap: 6)
    print("map data 2: ${d2.cap} ${d2.newMap}")
    print("def: ${isTerminal()} ${newDenseArray(4, 2)}")
    var vqsort: int = 5
    var abs64: int = vqsort + 1
    print("locals: ${vqsort} ${abs64}")
    print("names: OK")
ZBR
(cd "$OUT" && "$ZEBRA" names.zbr > "$OUT/names_zig_out.txt" 2> "$OUT/names_zig_err.txt"); zrc=$?
(cd "$OUT" && "$ZEBRA" --target v names.zbr > "$OUT/names_emit.txt" 2>&1)
(cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/names.v" > "$OUT/names_v_out.txt" 2> "$OUT/names_v_err.txt"); vrc=$?
names_root=$(dirname "$V")
ls "$names_root"/vlib/builtin/*.v 2>/dev/null | grep -v '_test\.v$' | xargs -r grep -hoE '^fn [a-z_0-9]+\(' 2>/dev/null | sed -E 's/^fn //; s/\($//' | grep -vxE 'main|init' | LC_ALL=C sort -u > "$OUT/names_v_private.txt"
grep -A3 '^def vBuiltinPrivateNames' "$WT/selfhost/CodeGenV.zbr" | grep -oE 'return " [^"]*"' | tr ' ' '\n' | grep -E '^[a-z_0-9]+$' | LC_ALL=C sort -u > "$OUT/names_emitter.txt"
names_missing=$(LC_ALL=C comm -23 "$OUT/names_v_private.txt" "$OUT/names_emitter.txt" | tr '\n' ' ')
if [ "$zrc" != 0 ] || ! tail -1 "$OUT/names_zig_out.txt" | grep -qx 'names: OK'; then echo "names: FAILED -- NO CONTROL: the Zig run exited $zrc and ended '$(tail -1 "$OUT/names_zig_out.txt" | cut -c1-80)'"; fail=1
elif [ "$(refusal_lines "$OUT/names_emit.txt" | wc -l)" != 0 ]; then echo "names: FAILED -- REFUSED: $(refusal_lines "$OUT/names_emit.txt" | head -1 | cut -c1-140)"; fail=1
elif [ "$vrc" != 0 ]; then echo "names: FAILED -- v exit $vrc: $(grep -m2 -E 'error|panic|Unhandled' "$OUT/names_v_err.txt" | cut -c1-200 | tr '\n' ' ')"; fail=1
elif ! diff -q "$OUT/names_v_out.txt" "$OUT/names_zig_out.txt" > /dev/null; then echo "names: FAILED -- stdout differs, V then Zig: $(diff "$OUT/names_v_out.txt" "$OUT/names_zig_out.txt" | head -4 | cut -c1-160 | tr '\n' ' ')"; fail=1
elif ! grep -q '^fn new_node_() &Node' "$OUT/names.v" || ! grep -q '^fn is_terminal_() bool' "$OUT/names.v"; then echo "names: FAILED -- the emitted V does not move new_node / is_terminal aside: the program met no private name and compared nothing"; fail=1
elif ! grep -qx 'new_node' "$OUT/names_v_private.txt" || [ "$(wc -l < "$OUT/names_v_private.txt")" -lt 100 ]; then echo "names: FAILED -- cannot read builtin's private functions beside this V ($names_root/vlib/builtin: $(wc -l < "$OUT/names_v_private.txt") names, new_node not among them or too few): the emitter's list cannot be checked against it"; fail=1
elif [ -n "$names_missing" ]; then echo "names: FAILED -- this V's builtin has private functions the emitter's list (vBuiltinPrivateNames in CodeGenV.zbr) lacks: $(echo "$names_missing" | cut -c1-200)"; fail=1
else echo "names: ok -- a class Node, a struct, a function, a field and a local named like builtin's private functions are alike on both backends ($(wc -l < "$OUT/names_zig_out.txt") lines); the emitter's list covers all $(wc -l < "$OUT/names_v_private.txt") private names of $names_root/vlib/builtin"; fi
echo "── a JsonValue is a shared handle (BUG-751); put / append store a snapshot and refuse a wrong kind or a 257th level (BUG-722) ──"
rows=$((rows + 1))
# Until 2026-11-16 a JsonValue was x.json2's Any BY VALUE on this route and `j.put(k, v)` was
# rewritten `j = zjson_put(j, k, v)`: a second name, a parameter and a value read out with
# get were each a copy, an object's members came out in ALPHABETICAL order (json2's encoder),
# put on an array silently made an object of it, and nothing held the builder to 256 levels.
# It is `&ZJson` now, a node of the runtime's own tree. Two halves:
#  - BUG-722's four fixtures (test/), alike on both routes: the nest fixture line for line,
#    and the three that must STOP -- both routes exit non-zero with the same `Json: ...`
#    message and neither prints SURVIVED.
#  - BUG-751's three fixtures (test/), alike on both routes: the handle fixture line for line
#    (both routes took the flip together, 2026-11-16), the two depth refusals stopped by the
#    same message. A JsonValue as text is its JSON text on both (BUG-754, the fixture's last
#    three checks and its print).
json_both() {
  (cd "$OUT" && "$ZEBRA" "$1.zbr" > "$OUT/$1_zig_out.txt" 2> "$OUT/$1_zig_err.txt"); echo $? > "$OUT/$1_zig_rc.txt"
  json_v "$1"
}
json_v() {
  rm -f "$OUT/$1.v"
  (cd "$OUT" && "$ZEBRA" --target v "$1.zbr" > "$OUT/$1_emit.txt" 2>&1)
  (cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/$1.v" > "$OUT/$1_v_out.txt" 2> "$OUT/$1_v_err.txt"); echo $? > "$OUT/$1_v_rc.txt"
}
cp "$WT/test/bug722_json_nest_test.zbr" "$OUT/json_nest.zbr"
cp "$WT/test/bug722_json_too_deep_test.zbr" "$OUT/json_deep.zbr"
cp "$WT/test/bug722_json_wrong_kind_test.zbr" "$OUT/json_kind.zbr"
cp "$WT/test/bug722_json_wrong_kind2_test.zbr" "$OUT/json_kind2.zbr"
cp "$WT/test/bug751_json_handle_test.zbr" "$OUT/json_handle.zbr"
cp "$WT/test/bug751_json_handle_depth_test.zbr" "$OUT/json_hdepth.zbr"
cp "$WT/test/bug751_json_detached_depth_test.zbr" "$OUT/json_detached.zbr"
# json_edges: what Json.parse accepts, what a number is, and what stringify writes, alike on
# both routes line for line. Until 2026-11-16 this route read through x.json2, which made every
# number an f64 -- an integer past 2^53 came back changed (9223372036854775807 read
# 9223372036854776000 and was no int at all), a float was written with an exponent (1e+21,
# 1e-7) where the Zig route writes plain digits, a number too big for either type was lost
# (1e400 was nil), and a DUPLICATE KEY was accepted, the last one kept, where the Zig route
# answers nil. The runtime parses for itself now, by std.json's rules (BUG-756). The program is
# test/json_edges_test.zbr, which the Zig route's suite holds to a golden file: one source for
# both parsers.
cp "$WT/test/json_edges_test.zbr" "$OUT/json_edges.zbr"
for p in json_nest json_deep json_kind json_kind2 json_edges json_handle json_hdepth json_detached; do json_both $p; done
# the nest fixture again under the region check mode: a string a tree kept but did not copy is
# POISONED at its block's end there ("<freed at ..."), where the plain run reads it right
# whenever the allocator has not reused the bytes yet -- seen: with the copy taken out the
# plain run said OK and this one said WRONG
(cd "$OUT/scratch" && "$V" -gc none -enable-globals -d zbr_region_check run "$OUT/json_nest.v" > "$OUT/json_nest_chk_out.txt" 2> "$OUT/json_nest_chk_err.txt"); echo $? > "$OUT/json_nest_chk_rc.txt"
json_bad=""
# the nest fixture: alike, and both say OK
if [ "$(cat "$OUT/json_nest_zig_rc.txt")" != 0 ] || ! tail -1 "$OUT/json_nest_zig_out.txt" | grep -qx 'bug722_json_nest: OK'; then json_bad="$json_bad json_nest(NO CONTROL: the Zig run did not end 'bug722_json_nest: OK')"
elif [ "$(cat "$OUT/json_nest_v_rc.txt")" != 0 ]; then json_bad="$json_bad json_nest(v exit $(cat "$OUT/json_nest_v_rc.txt"): $(grep -m1 -E 'error|panic' "$OUT/json_nest_v_err.txt" | cut -c1-120))"
elif ! diff -q "$OUT/json_nest_v_out.txt" "$OUT/json_nest_zig_out.txt" > /dev/null; then json_bad="$json_bad json_nest(differs: $(diff "$OUT/json_nest_v_out.txt" "$OUT/json_nest_zig_out.txt" | head -3 | cut -c1-140 | tr '\n' ' '))"; fi
if [ "$(cat "$OUT/json_nest_chk_rc.txt")" != 0 ] || ! grep -qx 'bug722_json_nest: OK' "$OUT/json_nest_chk_out.txt"; then json_bad="$json_bad json_nest(under -d zbr_region_check: $(grep -m1 -E 'WRONG|error|panic' "$OUT/json_nest_chk_out.txt" "$OUT/json_nest_chk_err.txt" | cut -c1-160))"; fi
if [ "$(cat "$OUT/json_edges_zig_rc.txt")" != 0 ] || [ "$(wc -l < "$OUT/json_edges_zig_out.txt")" -lt 80 ] || ! grep -qxF 'i64-max: 9223372036854775807 [int 9223372036854775807]' "$OUT/json_edges_zig_out.txt" || ! grep -qxF 'dup-key: nil' "$OUT/json_edges_zig_out.txt" || ! grep -qxF 'tiny: 0.0000001 [float 0.0000001]' "$OUT/json_edges_zig_out.txt" || ! grep -qxF 'exp-overflow: 1e400 [float inf]' "$OUT/json_edges_zig_out.txt"; then json_bad="$json_bad json_edges(NO CONTROL: the Zig run did not print the eighty-odd lines, or not the exact i64, the refused duplicate key, the plain-digit float and the kept number text the program is about)"
elif [ "$(cat "$OUT/json_edges_v_rc.txt")" != 0 ]; then json_bad="$json_bad json_edges(v exit $(cat "$OUT/json_edges_v_rc.txt"): $(grep -m1 -E 'error|panic' "$OUT/json_edges_v_err.txt" | cut -c1-140))"
elif ! diff -q "$OUT/json_edges_v_out.txt" "$OUT/json_edges_zig_out.txt" > /dev/null; then json_bad="$json_bad json_edges(differs, V then Zig: $(diff "$OUT/json_edges_v_out.txt" "$OUT/json_edges_zig_out.txt" | head -3 | cut -c1-160 | tr '\n' ' '))"; fi
# the five that must stop: the same message on both routes, the same lines before it
for p in json_deep json_kind json_kind2 json_hdepth json_detached; do
  zmsg=$(grep -m1 -oE 'Json: .*' "$OUT/${p}_zig_err.txt" | tr -d '\r')
  vmsg=$(grep -m1 -oE 'Json: .*' "$OUT/${p}_v_err.txt" | tr -d '\r')
  if [ "$(cat "$OUT/${p}_zig_rc.txt")" = 0 ] || [ -z "$zmsg" ]; then json_bad="$json_bad $p(NO CONTROL: the Zig run did not stop with a Json: message)"
  elif [ "$(cat "$OUT/${p}_v_rc.txt")" = 0 ]; then json_bad="$json_bad $p(the V run was not stopped: $(tail -1 "$OUT/${p}_v_out.txt" | cut -c1-80))"
  elif [ "$zmsg" != "$vmsg" ]; then json_bad="$json_bad $p(the message differs, V then Zig: '$vmsg' / '$zmsg')"
  elif grep -q SURVIVED "$OUT/${p}_v_out.txt" "$OUT/${p}_zig_out.txt"; then json_bad="$json_bad $p(SURVIVED printed)"
  elif ! diff -q "$OUT/${p}_v_out.txt" "$OUT/${p}_zig_out.txt" > /dev/null; then json_bad="$json_bad $p(the lines before the stop differ)"; fi
done
# BUG-751's handle fixture: the Zig run ends OK after its checks and its print, the V run is
# the same text, and the emitted V calls the runtime on the value (no rebind left)
if [ "$(cat "$OUT/json_handle_zig_rc.txt")" != 0 ] || ! tail -1 "$OUT/json_handle_zig_out.txt" | grep -qx 'bug751_json_handle: OK' || [ "$(grep -c ': ok$' "$OUT/json_handle_zig_out.txt")" -lt 20 ] || ! grep -qxF '{"a":"b","n":2}' "$OUT/json_handle_zig_out.txt"; then json_bad="$json_bad json_handle(NO CONTROL: the Zig run did not end 'bug751_json_handle: OK' after twenty checks and a value printed as its JSON text)"
elif [ "$(cat "$OUT/json_handle_v_rc.txt")" != 0 ]; then json_bad="$json_bad json_handle(v exit $(cat "$OUT/json_handle_v_rc.txt"): $(grep -m1 -E 'error|panic' "$OUT/json_handle_v_err.txt" | cut -c1-140))"
elif ! diff -q "$OUT/json_handle_v_out.txt" "$OUT/json_handle_zig_out.txt" > /dev/null; then json_bad="$json_bad json_handle(differs, V then Zig: $(diff "$OUT/json_handle_v_out.txt" "$OUT/json_handle_zig_out.txt" | head -3 | cut -c1-160 | tr '\n' ' '))"
elif grep -qE '^[[:space:]]*[A-Za-z_.0-9]+ = zjson_(put|append)' "$OUT/json_handle.v" || ! grep -q 'zjson_put_str(' "$OUT/json_handle.v"; then json_bad="$json_bad json_handle(the emitted V still rebinds a put, or calls none)"; fi
# the two depth refusals are the DEPTH message (the loop above held them to the same one on
# both routes), and the first starts from the 256-level tree it says it built
for p in json_hdepth json_detached; do
  if ! grep -q 'Json: put/append would nest a value deeper than 256 levels' "$OUT/${p}_zig_err.txt"; then json_bad="$json_bad $p(NO CONTROL: the Zig run was not stopped by the depth message)"; fi
done
if ! grep -qxF 'stored 255 levels under the root: tree is 256' "$OUT/json_hdepth_zig_out.txt"; then json_bad="$json_bad json_hdepth(NO CONTROL: the 256-level tree it starts from was not built)"; fi
json_refused=$(refusal_lines "$OUT"/json_*_emit.txt | wc -l)
if [ -n "$json_bad" ]; then echo "json: FAILED --$json_bad"; fail=1
elif [ "$json_refused" != 0 ]; then echo "json: FAILED -- REFUSED: $(refusal_lines "$OUT"/json_*_emit.txt | head -1 | cut -c1-140)"; fail=1
else echo "json: ok -- parse, numbers and stringify alike on both backends over $(wc -l < "$OUT/json_edges_zig_out.txt") edge lines; BUG-722's nest fixture alike on both backends ($(wc -l < "$OUT/json_nest_zig_out.txt") lines; right under the region check mode too) and its three refusals stopped by the same message on both; BUG-751's handle fixture alike on both ($(grep -c ': ok$' "$OUT/json_handle_zig_out.txt") checks) and its two depth refusals stopped by the same message on both"; fi
echo "── three shapes the engine's ladder met: a capture's name declared again, a class's own pop(), the free-at-sweep queue ──"
rows=$((rows + 1))
# The four engine tests that stood red on this route until 2026-11-16 (tools/v_engine_check.py:
# instance_test and wire_build_test did not build, signal_test and door_block_test failed an
# assert), as one program alike on both routes:
#  1. a lambda's capture is declared in the ENCLOSING V scope and outlives the lambda there, so a
#     later local of that name in the same function was V's "redefinition"; the later local is
#     declared under a name of its own (genLocal), and a second lambda capturing it gets that one.
#  2. a zero-argument pop() was typed as the List's (a result) whatever the receiver, so a class's
#     own `pop(): str` as a statement was emitted with a `!`.
#  3. the free-at-sweep queue was a constant 0 here; the runtime keeps it now (a container once
#     however often queued, emptied by the sweep, nothing freed: V's collector does that).
# The emitted V must show each shape was met (a renamed local, the bare pop statement, the
# queue call), or the program compared nothing.
cat > "$OUT/ladder.zbr" <<'ZBR'
sig VoidCallback()

class Counter
    var n: int = 0
    def bump()
        .n = .n + 1

class Bell
    var handlers: List(VoidCallback)
    cue init()
        .handlers = List(VoidCallback)()
    def connect(h: VoidCallback)
        .handlers.add(h)
    def ring()
        for h in .handlers
            h()

class Sink
    var sent: List(str)
    cue init()
        .sent = List(str)()
    def push(s: str)
        .sent.add(s)
    def pop(): str
        if .sent.count() == 0
            return ""
        var last = .sent.at(.sent.count() - 1)
        var keep = List(str)()
        var i = 0
        while i < .sent.count() - 1
            keep.add(.sent.at(i))
            i = i + 1
        .sent = keep
        return last

def main()
    # 1. a capture's name declared again as a local, later in the same function
    var bell = Bell()
    var counter = Counter()
    bell.connect(def(): void
        capture
            var c: Counter = counter
        c.bump()
    )
    bell.ring()
    var c = "a later local of the capture's name"
    print(c + " / " + counter.n.toString())
    c = c + "!"
    print(c)
    # and a second lambda that captures the later local itself
    bell.connect(def(): void
        capture
            var c: str = c
        print("captured: " + c)
    )
    bell.ring()
    print("bumped ${counter.n}")
    # 2. a class's own pop() as a statement (not a List's, which may fail)
    var s = Sink()
    s.push("one")
    s.push("two")
    s.pop()
    print(s.pop())
    var xs = List(int)()
    xs.add(4)
    xs.add(5)
    var top: int = xs.pop() catch -1
    print("list pop ${top}")
    # 3. the free-at-sweep queue: queued once however often asked, emptied by the sweep
    var pend0: int = zig"@as(i64, @intCast(_zbr_sweep_pending()))"
    var stale = List(int)()
    stale.add(1)
    var other = List(int)()
    zig"_zbr_free_at_sweep(stale)"
    zig"_zbr_free_at_sweep(stale)"
    var pend1: int = zig"@as(i64, @intCast(_zbr_sweep_pending()))"
    zig"_zbr_free_at_sweep(other)"
    var pend2: int = zig"@as(i64, @intCast(_zbr_sweep_pending()))"
    zig"_zbr_sweep()"
    var pend3: int = zig"@as(i64, @intCast(_zbr_sweep_pending()))"
    print("pending ${pend0} ${pend1} ${pend2} ${pend3}")
    print("ladder: OK")
ZBR
(cd "$OUT" && "$ZEBRA" ladder.zbr > "$OUT/ladder_zig_out.txt" 2> "$OUT/ladder_zig_err.txt"); zrc=$?
(cd "$OUT" && "$ZEBRA" --target v ladder.zbr > "$OUT/ladder_emit.txt" 2>&1)
(cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/ladder.v" > "$OUT/ladder_v_out.txt" 2> "$OUT/ladder_v_err.txt"); vrc=$?
if [ "$zrc" != 0 ] || ! tail -1 "$OUT/ladder_zig_out.txt" | grep -qx 'ladder: OK'; then echo "ladder: FAILED -- NO CONTROL: the Zig run exited $zrc and ended '$(tail -1 "$OUT/ladder_zig_out.txt" | cut -c1-80)'"; fail=1
elif ! grep -qxF 'pending 0 1 2 0' "$OUT/ladder_zig_out.txt" || ! grep -qxF 'bumped 2' "$OUT/ladder_zig_out.txt" || ! grep -qxF 'one' "$OUT/ladder_zig_out.txt"; then echo "ladder: FAILED -- NO CONTROL: the Zig run did not print the queue's four counts, the two bumps and the popped text the row is about"; fail=1
elif [ "$(refusal_lines "$OUT/ladder_emit.txt" | wc -l)" != 0 ]; then echo "ladder: FAILED -- REFUSED: $(refusal_lines "$OUT/ladder_emit.txt" | head -1 | cut -c1-140)"; fail=1
elif [ "$vrc" != 0 ]; then echo "ladder: FAILED -- v exit $vrc: $(grep -m2 -E 'error|panic|Unhandled' "$OUT/ladder_v_err.txt" | cut -c1-200 | tr '\n' ' ')"; fail=1
elif ! diff -q "$OUT/ladder_v_out.txt" "$OUT/ladder_zig_out.txt" > /dev/null; then echo "ladder: FAILED -- stdout differs, V then Zig: $(diff "$OUT/ladder_v_out.txt" "$OUT/ladder_zig_out.txt" | head -4 | cut -c1-160 | tr '\n' ' ')"; fail=1
elif ! grep -qE '^[[:space:]]*mut c_r[0-9]+ := ' "$OUT/ladder.v"; then echo "ladder: FAILED -- the emitted V declares no renamed local c_rN: the later local met no capture of its name and the row compared nothing"; fail=1
elif ! grep -qE '^[[:space:]]*s\.pop\(\)$' "$OUT/ladder.v"; then echo "ladder: FAILED -- the emitted V has no bare s.pop() statement (a class's own pop, no result mark)"; fail=1
elif [ "$(grep -c 'zsweep_queue(voidptr(' "$OUT/ladder.v")" -lt 3 ] || ! grep -q 'zsweep_pending()' "$OUT/ladder.v"; then echo "ladder: FAILED -- the emitted V does not queue through the runtime (zsweep_queue at the three queueings, zsweep_pending at the reads)"; fail=1
else echo "ladder: ok -- a capture's name declared again as a local, a class's own pop() as a statement and the free-at-sweep queue's counts are alike on both backends ($(wc -l < "$OUT/ladder_zig_out.txt") lines)"; fi
echo "── a name the V runtime does not define is REFUSED by name, not reported clean (2026-10-30: 152 'clean' census files did not build) ──"
rows=$((rows + 1))
# three shapes: a stdlib namespace the emitter does not map, a ZList method zebra_rt.v
# does not declare, a Zebra method passed through onto a V string; and a control that
# is fully mapped and must stay clean (a refusal there is a false positive)
printf 'def main()\n    var r = Regex.compile("a+")\n    var xs = [1, 2, 3]\n    print(xs.any(def(x) = x > 2).toString())\n    print("abc".tokenize(",").count().toString())\n' > "$OUT/rt_names.zbr"
printf 'def main()\n    var xs = [1, 2, 3]\n    print(xs.count().toString() + " " + "banana".count("na").toString())\n' > "$OUT/rt_names_ok.zbr"
(cd "$OUT" && "$ZEBRA" --target v rt_names.zbr > "$OUT/rt_names_emit.txt" 2>&1)
(cd "$OUT" && "$ZEBRA" --target v rt_names_ok.zbr > "$OUT/rt_names_ok_emit.txt" 2>&1)
missing=""
grep -q 'Regex.compile (the V runtime has no Regex' "$OUT/rt_names_emit.txt" || missing="$missing Regex"
grep -q '`ZList.any_` (the emitter writes it; zebra_rt.v declares no such method)' "$OUT/rt_names_emit.txt" || missing="$missing ZList.any"
grep -q 'string.tokenize (no mapping' "$OUT/rt_names_emit.txt" || missing="$missing str.tokenize"
if [ -n "$missing" ]; then echo "rt_names: FAILED -- not refused:$missing"; grep -E '^  |^    ' "$OUT/rt_names_emit.txt" | head -5 | cut -c1-160; fail=1
elif ! grep -q 'nothing refused' "$OUT/rt_names_ok_emit.txt"; then echo "rt_names: FAILED -- the mapped control was refused (a false positive):"; refusal_lines "$OUT/rt_names_ok_emit.txt" | head -3 | cut -c1-160; fail=1
else echo "rt_names: ok -- the three unmapped names refused by name, the mapped control clean"; fi
echo "── free-at-sweep on V (the GameEngine's release paths): the three runtime calls mapped, a list rebuilt mid-walk walked to the end (BUG-681), an unknown zig literal still refused ──"
rows=$((rows + 1))
# The walk reassigns the MODULE list it is walking (release(5) at x == 2): Zig evaluates the
# for header once and sums the old list (45); V's C re-read the global's .items every
# iteration and summed the new one (40) until the header was bound to a temporary.
printf 'var _xs = List(int)()\n\ndef release(k: int)\n    var keep = List(int)()\n    for x in _xs\n        if x != k\n            keep.add(x)\n    var old = _xs\n    zig"_zbr_free_at_sweep(old)"\n    _xs = keep\n\nclass Holder\n    var ys: List(int) = List(int)()\n    def fill()\n        var i = 0\n        while i < 6\n            .ys.add(i)\n            i = i + 1\n    def walk(): int\n        var t = 0\n        for y in .ys\n            if y == 1\n                .ys = List(int)()\n            t = t + y\n        return t\n\ndef main()\n    var i = 0\n    while i < 10\n        _xs.add(i)\n        i = i + 1\n    var s = 0\n    for x in _xs\n        if x == 2\n            release(5)\n        s = s + x\n    zig"_zbr_sweep()"\n    var n: int = zig"@as(i64, @intCast(_zbr_sweep_pending()))"\n    var h = Holder()\n    h.fill()\n    print(s.toString() + " " + _xs.count().toString() + " " + n.toString() + " " + h.walk().toString())\n' > "$OUT/sweep_v.zbr"
printf 'def main()\n    zig"_zbr_not_a_runtime_call()"\n' > "$OUT/sweep_v_bad.zbr"
(cd "$OUT" && "$ZEBRA" sweep_v.zbr > "$OUT/sweep_v_zig_out.txt" 2> "$OUT/sweep_v_zig_err.txt")
(cd "$OUT" && "$ZEBRA" --target v sweep_v.zbr > "$OUT/sweep_v_emit.txt" 2>&1)
(cd "$OUT" && "$ZEBRA" --target v sweep_v_bad.zbr > "$OUT/sweep_v_bad_emit.txt" 2>&1)
(cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/sweep_v.v" > "$OUT/sweep_v_v_out.txt" 2> "$OUT/sweep_v_v_err.txt")   # stdout only: V prints notices on stderr
if ! grep -qx '45 9 0 15' "$OUT/sweep_v_zig_out.txt"; then echo "sweep_v: NO CONTROL -- the Zig run did not print '45 9 0 15': $(head -c 120 "$OUT/sweep_v_zig_out.txt" "$OUT/sweep_v_zig_err.txt" | tr '\n' ' ')"; fail=1
elif [ -n "$(refusal_lines "$OUT/sweep_v_emit.txt")" ]; then echo "sweep_v: FAILED -- the V emit refused something:"; refusal_lines "$OUT/sweep_v_emit.txt" | head -3 | cut -c1-160; fail=1
elif ! diff -q "$OUT/sweep_v_v_out.txt" "$OUT/sweep_v_zig_out.txt" > /dev/null; then echo "sweep_v: DIFFERS (V vs Zig):"; diff "$OUT/sweep_v_v_out.txt" "$OUT/sweep_v_zig_out.txt" | head -4 | cut -c1-160; fail=1
elif ! grep -q 'a zig literal (Zig-backend code; no V for it)' "$OUT/sweep_v_bad_emit.txt"; then echo "sweep_v: FAILED -- an unknown zig literal was not refused (the mapping is too wide)"; fail=1
else echo "sweep_v: ok -- the free-at-sweep calls map, a rebuilt module list and field are walked to the end on both backends ($(cat "$OUT/sweep_v_zig_out.txt")), an unknown zig literal is still refused"; fi
echo "── stdin polled without blocking (the debugger bridge's readStdinAvailable / stdinClosed): the same bytes and the same hang-up on both backends ──"
rows=$((rows + 1))
printf 'def main()\n    var got: str = ""\n    var spins = 0\n    while true\n        var a = sys.readStdinAvailable()\n        if a != ""\n            got = got + a\n        else if sys.stdinClosed()\n            break\n        else\n            spins = spins + 1\n            sys.sleep(5)\n            if spins > 400\n                print("gave up")\n                break\n    print("got [" + got + "] closed " + sys.stdinClosed().toString())\n' > "$OUT/poll_in.zbr"
printf 'hello from a pipe' > "$OUT/poll_input.txt"
# a pipe, not a redirected file: a file handle on stdin reads as closed (PeekNamedPipe fails on it) on both backends, as it does for the bridge
poll_zig() {   # the program's status, not cat's: PIPESTATUS (H10)
  cd "$OUT" && cat "$OUT/poll_input.txt" | "$ZEBRA" poll_in.zbr > "$OUT/poll_zig_out.txt" 2> "$OUT/poll_zig_err.txt"
  return "${PIPESTATUS[1]}"
}
poll_v() {
  cd "$OUT" && cat "$OUT/poll_input.txt" | timeout 30 "$OUT/poll_in.exe" > "$OUT/poll_v_out.txt" 2> "$OUT/poll_v_err.txt"
  return "${PIPESTATUS[1]}"
}
(poll_zig); zrc=$?
(cd "$OUT" && "$ZEBRA" --target v poll_in.zbr > "$OUT/poll_emit.txt" 2>&1)
(cd "$OUT/scratch" && "$V" -gc none -enable-globals -o "$OUT/poll_in.exe" "$OUT/poll_in.v" > "$OUT/poll_build.txt" 2>&1)
if [ ! -f "$OUT/poll_in.exe" ]; then echo "poll_in: FAILED -- the V build:"; grep -E 'error' "$OUT/poll_build.txt" | head -3 | cut -c1-160; fail=1
else
  (poll_v); vrc=$?
  if [ "$zrc" != 0 ] || [ "$vrc" != 0 ]; then echo "poll_in: FAILED (zig exit $zrc, v exit $vrc)"; head -2 "$OUT/poll_v_err.txt" | cut -c1-160; fail=1
  elif ! grep -q 'got \[hello from a pipe\] closed true' "$OUT/poll_zig_out.txt"; then echo "poll_in: NO CONTROL -- the Zig run did not read the pipe: $(cat "$OUT/poll_zig_out.txt")"; fail=1
  elif diff -q "$OUT/poll_v_out.txt" "$OUT/poll_zig_out.txt" > /dev/null; then echo "poll_in: ok -- both say: $(cat "$OUT/poll_zig_out.txt")"
  else echo "poll_in: DIFFERS"; diff "$OUT/poll_v_out.txt" "$OUT/poll_zig_out.txt" | head -4 | cut -c1-160; fail=1; fi
fi
echo "── the V-built compiler answers the LSP (initialize, shutdown, exit over stdin: the goroutine, the channel, the atomic, readBytes) ──"
rows=$((rows + 1))
lsp_frames() {   # the three requests, Content-Length framed
  local b1='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
  local b2='{"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}}'
  local b3='{"jsonrpc":"2.0","method":"exit","params":{}}'
  printf 'Content-Length: %d\r\n\r\n%s' "${#b1}" "$b1"; printf 'Content-Length: %d\r\n\r\n%s' "${#b2}" "$b2"; printf 'Content-Length: %d\r\n\r\n%s' "${#b3}" "$b3"
}
lsp_answers() {   # <exe> -> "<responses> <capabilities 0/1> <shutdown 0/1> <exit>"
  lsp_frames > "$OUT/lsp_in.txt"
  (cd "$WT" && timeout 30 "$1" lsp < "$OUT/lsp_in.txt" > "$OUT/lsp_out.txt" 2> "$OUT/lsp_err.txt"); local rc=$?   # no pipe: the status is the compiler's (H10)
  local n; n=$(grep -c 'Content-Length' "$OUT/lsp_out.txt")
  local caps=0; grep -q capabilities "$OUT/lsp_out.txt" && caps=1
  local sd=0; grep -q '"id":2' "$OUT/lsp_out.txt" && sd=1
  echo "$n $caps $sd $rc"
}
rm -f "$OUT/zebra_v.exe"
"$V" -cc tcc -gc none -enable-globals -o "$OUT/zebra_v.exe" "$WT/selfhost/main.v" > "$OUT/zebra_v_build.txt" 2>&1
if [ ! -f "$OUT/zebra_v.exe" ]; then echo "lsp: FAILED -- the route did not build under $V:"; grep -E 'error' "$OUT/zebra_v_build.txt" | head -3 | cut -c1-160; fail=1
else
  zig_ans=$(lsp_answers "$ZEBRA"); v_ans=$(lsp_answers "$OUT/zebra_v.exe")
  if [ "$zig_ans" = "2 1 1 0" ] && [ "$v_ans" = "2 1 1 0" ]; then echo "lsp: ok -- both answer initialize (capabilities) and shutdown, and exit on exit (zig: $zig_ans, v: $v_ans)"
  else echo "lsp: FAILED -- responses capabilities shutdown exit: zig [$zig_ans] v [$v_ans] (want [2 1 1 0] on both)"; head -3 "$OUT/lsp_err.txt" | cut -c1-160; fail=1; fi
fi
echo "── no run was handed to V's fallback compiler ──"
rows=$((rows + 1))
# V master's retry with a cached 0.5.2 is switched off at the top; this reads what the runs
# of THIS invocation said (the outputs are rewritten by every row) and refuses the retry's
# own words, in case the switch is renamed under a later pin
fallback_hits=$(grep -l 'retrying with' "$OUT"/*_v_err.txt "$OUT"/*_build.txt "$OUT"/*_check.txt 2>/dev/null | head -5 | xargs -r -n1 basename | tr '\n' ' ')
if [ -n "$fallback_hits" ]; then echo "fallback: FAILED -- V retried with its fallback compiler in: $fallback_hits(a row judged by a compiler it does not name)"; fail=1
elif [ "$(ls "$OUT"/*_v_err.txt 2>/dev/null | wc -l)" -lt 10 ]; then echo "fallback: FAILED -- fewer than ten V error logs under $OUT: nothing to read"; fail=1
else echo "fallback: ok -- none of $(ls "$OUT"/*_v_err.txt | wc -l) V runs says 'retrying with'"; fi
echo "── the engine's roots: tools/v_engine_check.py (not run here) ──"
if [ "$fail" = 0 ]; then echo "v_check: ok -- $rows rows, every example and dump identical to its fresh Zig control, the route within its baseline"; exit 0; fi
echo "v_check: FAILED (see the rows above; outputs under $OUT)"; exit 1
