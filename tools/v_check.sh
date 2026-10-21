#!/bin/bash
# The V target's check (2026-10-20; the docket's item 3, tooling parity): the
# V side's drift alarm and suites in one run, as `regen_selfhost.sh --check`
# and the Zig suites are for the Zig side.
#
#   tools/v_check.sh [--v <v.exe>]           (V 0.5.2 by default; V=<path> too)
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
V=${V:-/c/Projects/v-dist/v/v.exe}
[ "${1:-}" = "--v" ] && V=$2
OUT=${OUT:-$WT/.zig-cache/v_check}
ROUTE_REFUSALS_BASELINE=${ROUTE_REFUSALS_BASELINE:-2}   # main.zbr's two zig literals (Zig-backend code by definition): more is a regression
mkdir -p "$OUT/scratch"
[ -x "$ZEBRA" ] || { echo "v_check: no $ZEBRA (build the checkout)"; exit 2; }
[ -x "$V" ] || { echo "v_check: no V at $V"; exit 2; }
cp "$WT/selfhost/zebra_rt.v" "$WT/zig-out/bin/zebra_rt.v" 2>/dev/null
cp "$WT/selfhost/gui_libui_ng_section.v" "$WT/zig-out/bin/gui_libui_ng_section.v" 2>/dev/null
echo "v_check: $("$V" version), emitter $ZEBRA"
fail=0; rows=0
# compare <name> <emit-dir> <zbr-path-relative-to-emit-dir> <control-file> <v-file>
compare() {
  local name=$1 dir=$2 zbr=$3 ctl=$4 vfile=$5
  rows=$((rows + 1))
  (cd "$dir" && "$ZEBRA" "$zbr" > "$ctl" 2> "$OUT/${name}_zig_err.txt"); local zrc=$?
  (cd "$dir" && "$ZEBRA" --target v "$zbr" > "$OUT/${name}_emit.txt" 2>&1)
  local refusals; refusals=$(grep -cE '^    ' "$OUT/${name}_emit.txt")
  if [ ! -f "$vfile" ]; then echo "$name: EMIT FAILED"; grep -E "error" "$OUT/${name}_emit.txt" | head -2 | cut -c1-160; fail=1; return; fi
  if [ "$refusals" != 0 ]; then echo "$name: REFUSED $refusals (an example or a dump is the subset by definition)"; grep -E '^    ' "$OUT/${name}_emit.txt" | head -3 | cut -c1-160; fail=1; return; fi
  (cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$vfile" > "$OUT/${name}_v_out.txt" 2> "$OUT/${name}_v_err.txt"); local vrc=$?
  if [ ! -s "$ctl" ]; then echo "$name: NO CONTROL (the Zig run exited $zrc and printed nothing; nothing compared)"; grep -m2 "error" "$OUT/${name}_zig_err.txt" | cut -c1-160; fail=1; return; fi
  if [ "$vrc" != 0 ]; then echo "$name: V FAILED (exit $vrc)"; grep -E "error|panic" "$OUT/${name}_v_err.txt" | head -3 | cut -c1-160; fail=1; return; fi
  if diff -q "$OUT/${name}_v_out.txt" "$ctl" > /dev/null; then echo "$name: IDENTICAL ($(wc -l < "$ctl") lines)"; else echo "$name: DIFFERS"; diff "$OUT/${name}_v_out.txt" "$ctl" | head -6 | cut -c1-160; fail=1; fi
}
echo "── the examples ──"
for f in "$WT"/examples/v_poc*.zbr; do
  b=$(basename "$f" .zbr)
  compare "$b" "$WT" "examples/$b.zbr" "$OUT/control_$b.txt" "$WT/examples/$b.v"
done
echo "── the selfhost dumps ──"
for d in lexer_dump parser_dump ast_dump resolver_dump codegen_dump; do
  compare "$d" "$WT/selfhost" "$d.zbr" "$OUT/control_$d.txt" "$WT/selfhost/$d.v"
done
echo "── the route (refusals against the baseline, v -check) ──"
for m in CodeGen Checker main; do
  rows=$((rows + 1))
  (cd "$WT" && "$ZEBRA" --target v "selfhost/$m.zbr" > "$OUT/${m}_emit.txt" 2>&1)
  refusals=$(grep -cE '^    ' "$OUT/${m}_emit.txt")
  "$V" -check -enable-globals "$WT/selfhost/$m.v" > "$OUT/${m}_check.txt" 2>&1; crc=$?
  errs=$(grep -c 'error:' "$OUT/${m}_check.txt")
  verdict="ok"
  if [ "$m" = main ] && [ "$refusals" -gt "$ROUTE_REFUSALS_BASELINE" ]; then verdict="MORE REFUSALS than the baseline $ROUTE_REFUSALS_BASELINE"; fail=1; fi
  if [ "$m" != main ] && [ "$refusals" != 0 ]; then verdict="REFUSED"; fail=1; fi
  if [ "$crc" != 0 ]; then verdict="$verdict, v -check FAILED ($errs error lines)"; fail=1; fi
  echo "$m: refusals $refusals, v -check exit $crc -- $verdict"
  [ "$fail" = 1 ] && { grep -E '^    ' "$OUT/${m}_emit.txt" | sed -E 's/ \([^)]*:[0-9]+\)//' | sort | uniq -c | sort -rn | head -4; grep "error:" "$OUT/${m}_check.txt" | head -3 | cut -c1-160; }
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
echo "── the engine's roots: tools/v_engine_check.py (not run here) ──"
if [ "$fail" = 0 ]; then echo "v_check: ok -- $rows rows, every example and dump identical to its fresh Zig control, the route within its baseline"; exit 0; fi
echo "v_check: FAILED (see the rows above; outputs under $OUT)"; exit 1
