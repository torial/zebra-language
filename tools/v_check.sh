#!/bin/bash
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
# pins: BUG-746 a class or struct as text on the V route is the Zig route's (`Name{field: value}`, or its own toString with no `&` before it in a hole) (the show row's show_types and show_fix2)
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
  elif [ "$(grep -cE '^    ' "$OUT/${p}_emit.txt")" != 0 ]; then sq_bad="$sq_bad $p(REFUSED: $(grep -m1 -E '^    ' "$OUT/${p}_emit.txt" | cut -c1-140))"
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
  elif [ "$(grep -cE '^    ' "$OUT/${p}_emit.txt")" != 0 ]; then nr_bad="$nr_bad $p(REFUSED: $(grep -m1 -E '^    ' "$OUT/${p}_emit.txt" | cut -c1-140))"
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
# Not in it: a class that reaches itself through a field (`next: Leaf?`), which the ZIG
# route does not build when printed (a dependency loop in _zbr_show_into; reported).
cp "$WT/test/bug723_chars_value_test.zbr" "$OUT/show_fix.zbr"
cp "$WT/test/bug734_json_depth_test.zbr" "$OUT/jd_fix.zbr"
cp "$WT/test/bug743_tostring_show_test.zbr" "$OUT/show_fix2.zbr"
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
show_bad=""
for p in show_fix jd_fix show_more show_fix2 show_types; do
  (cd "$OUT" && "$ZEBRA" $p.zbr > "$OUT/${p}_zig_out.txt" 2> "$OUT/${p}_zig_err.txt"); zrc=$?
  (cd "$OUT" && "$ZEBRA" --target v $p.zbr > "$OUT/${p}_emit.txt" 2>&1)
  (cd "$OUT/scratch" && "$V" -gc none -enable-globals run "$OUT/$p.v" > "$OUT/${p}_v_out.txt" 2> "$OUT/${p}_v_err.txt"); vrc=$?
  if [ "$zrc" != 0 ] || ! tail -1 "$OUT/${p}_zig_out.txt" | grep -q ': OK$'; then show_bad="$show_bad $p(NO CONTROL: the Zig run exited $zrc and ended '$(tail -1 "$OUT/${p}_zig_out.txt" | cut -c1-80)': $(tail -c 160 "$OUT/${p}_zig_err.txt" | tr '\n' ' '))"
  elif [ "$(grep -cE '^    ' "$OUT/${p}_emit.txt")" != 0 ]; then show_bad="$show_bad $p(REFUSED: $(grep -m1 -E '^    ' "$OUT/${p}_emit.txt" | cut -c1-140))"
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
elif [ "$show_refused" != 2 ]; then echo "show: FAILED -- a list of an optional and a printed interface must each be refused by name ($show_refused of 2): $(grep -E '^    ' "$OUT/show_refuse_emit.txt" | head -2 | cut -c1-120 | tr '\n' ' ')"; fail=1
else echo "show: ok -- five programs alike on both backends ($(wc -l < "$OUT/show_fix_zig_out.txt") + $(wc -l < "$OUT/jd_fix_zig_out.txt") + $(wc -l < "$OUT/show_more_zig_out.txt") + $(wc -l < "$OUT/show_fix2_zig_out.txt") + $(wc -l < "$OUT/show_types_zig_out.txt") lines); a list of an optional and a printed interface refused by name"; fi
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
elif ! grep -q 'nothing refused' "$OUT/rt_names_ok_emit.txt"; then echo "rt_names: FAILED -- the mapped control was refused (a false positive):"; grep -E '^    ' "$OUT/rt_names_ok_emit.txt" | head -3 | cut -c1-160; fail=1
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
elif grep -qE '^    ' "$OUT/sweep_v_emit.txt"; then echo "sweep_v: FAILED -- the V emit refused something:"; grep -E '^    ' "$OUT/sweep_v_emit.txt" | head -3 | cut -c1-160; fail=1
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
echo "── the engine's roots: tools/v_engine_check.py (not run here) ──"
if [ "$fail" = 0 ]; then echo "v_check: ok -- $rows rows, every example and dump identical to its fresh Zig control, the route within its baseline"; exit 0; fi
echo "v_check: FAILED (see the rows above; outputs under $OUT)"; exit 1
