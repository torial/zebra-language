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
# pins: BUG-746 a class or struct as text on the V route is the Zig route's (`Name{field: value}`, or its own toString with no `&` before it in a hole), and so is an optional of one (`nil` or the value) (the show row's show_types, show_fix2 and show_opt)
# pins: BUG-749 on the V route a class met again on the path being printed is `Name{...}`, a shared object prints in full, the cut is at 256 levels and the path is each thread's own (the show row's show_fix3 and show_cycle)
# pins: BUG-752 a class, struct or function whose V name is a private function of V's builtin (`class Node` -> new_node, vlang/v#32404) is moved aside, and the emitter's list covers the V in use (the names row)
# pins: BUG-722 on the V route put/append of a JsonValue store a snapshot, an object's members keep the order they were stored in, and a wrong kind or a 257th level stops the program with the Zig route's message (the json row's four test/bug722 fixtures)
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
elif ! grep -qxF 'class Leaf{name: "leaf"} nil' "$OUT/show_opt_zig_out.txt" || ! grep -qxF 'Owner<Held{o: Owner<Held{...}>}>' "$OUT/show_opt_zig_out.txt"; then echo "show: FAILED -- NO CONTROL: the Zig run did not print the optional and the cue-toString cycle show_opt is about"; fail=1
elif ! grep -q 'if !zshow_enter(voidptr(zr_e))' "$OUT/show_cycle.v" || ! grep -q 'if !zshow_enter(voidptr(zr_e))' "$OUT/show_fix3.v"; then echo "show: FAILED -- the emitted class printers do not ask the path (zshow_enter): the cycle programs compared something else"; fail=1
elif [ "$show_refused" != 2 ]; then echo "show: FAILED -- a list of an optional and a printed interface must each be refused by name ($show_refused of 2): $(grep -E '^    ' "$OUT/show_refuse_emit.txt" | head -2 | cut -c1-120 | tr '\n' ' ')"; fail=1
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
elif [ "$(grep -cE '^    ' "$OUT/names_emit.txt")" != 0 ]; then echo "names: FAILED -- REFUSED: $(grep -m1 -E '^    ' "$OUT/names_emit.txt" | cut -c1-140)"; fail=1
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
#  - BUG-751's three fixtures, on THIS route against their own expected text: the Zig route's
#    flip to handles is the other half of the same change and lands with it; until it does
#    the Zig run of these is not a control (it does not build), and this row says so.
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
cat > "$OUT/json_handle.zbr" <<'ZBR'
# BUG-751 (Sean, 2026-11-15): a JsonValue is a SHARED HANDLE, like a List since BUG-501. Every
# name for a value sees every change made through any of them, and a value read out of an
# object or array (`get`, `tryObj`, the elements of `tryList`) is a handle INTO it. Storing a
# JsonValue with put/append still stores a snapshot (BUG-722): that is the one copying operation.
# Each value is checked here, so the final line prints only when all are right.

var failures: int = 0

def check(what: str, got: str, want: str)
    if got == want
        print("${what}: ok")
    else
        print("  WRONG: ${what}: got '${got}', want '${want}'")
        failures += 1

def addTag(j: JsonValue, t: str)
    j.put("tag", t)

def indexReads(d2: JsonValue)
    var a = d2["a"]?
    a.putInt("m", 5)
    var x0 = d2["xs"][0]?
    x0.putInt("m", 6)
    # converted to List(JsonValue): the List is new, its elements are handles
    var xl: List(JsonValue) = d2["xs"]?
    var e0 = xl.at(0)
    e0.putBool("seen", true)
    xl.add(Json.object())
catch |e|
    check("index-read", "raised ${e.message}", "no raise")

def main()
    # assignment shares: a changed key AND a new key are both seen through the other name
    var p = Json.object()
    p.putInt("a", 1)
    var q = p
    q.putInt("a", 2)
    q.putInt("b", 3)
    check("assign-object", p.stringify(), "{\"a\":2,\"b\":3}")
    check("assign-object-q", q.stringify(), "{\"a\":2,\"b\":3}")

    var xs = Json.array()
    xs.appendInt(1)
    var ys = xs
    ys.appendInt(2)
    check("assign-array", xs.stringify(), "[1,2]")

    # many stores through the second name: growth must not split the two
    var big = Json.object()
    var alias = big
    var i = 0
    while i < 40
        alias.putInt("k${i}", i)
        i += 1
    check("assign-grows", "${big.keys().len} ${big.tryInt("k39") orelse -1}", "40 39")

    # a parameter is the same value: a change made in a function is seen by the caller
    var r = Json.object()
    addTag(r, "x")
    check("param", r.stringify(), "{\"tag\":\"x\"}")

    # get() is a handle into the parent: a change through it is seen in the parent
    if Json.parse("{\"user\":{\"name\":\"a\"},\"tags\":[\"t\"]}") as doc
        if doc.get("user") as u
            u.put("name", "b")
            u.putInt("age", 7)
        check("get-handle", doc.stringify(), "{\"user\":{\"name\":\"b\",\"age\":7},\"tags\":[\"t\"]}")
        if doc.tryObj("user") as ub
            ub.putBool("admin", true)
        check("tryObj-handle", doc.stringify(), "{\"user\":{\"name\":\"b\",\"age\":7,\"admin\":true},\"tags\":[\"t\"]}")
        # the elements of tryList are handles; the List itself is a new list (adding to it does
        # not change the JSON array)
        if doc.tryList("tags") as tl
            tl.add(Json.object())
        check("tryList-list-is-new", doc.stringify(), "{\"user\":{\"name\":\"b\",\"age\":7,\"admin\":true},\"tags\":[\"t\"]}")
    else
        check("parse", "parse failed", "parsed")

    if Json.parse("[{\"n\":1},{\"n\":2}]") as rows
        for row in rows.tryList() orelse List(JsonValue)()
            var n = row.tryInt("n") orelse 0
            row.putInt("double", n * 2)
        check("tryList-elements", rows.stringify(), "[{\"n\":1,\"double\":2},{\"n\":2,\"double\":4}]")

    # a handle survives its parent growing
    var root = Json.object()
    root.put("child", Json.object())
    if root.get("child") as c
        var k = 0
        while k < 40
            root.putInt("pad${k}", k)
            k += 1
        c.put("late", "yes")
    check("handle-survives-growth", root.tryObj("child")?.tryStr("late") orelse "missing", "yes")

    # replacing a key swaps the node: a handle to the old child keeps it, detached
    var host = Json.object()
    host.put("child", Json.object())
    if host.get("child") as old
        host.put("child", "text")
        old.put("late", "yes")
        check("replace-detaches-handle", old.stringify(), "{\"late\":\"yes\"}")
    check("replace-parent", host.stringify(), "{\"child\":\"text\"}")

    # detached, the old child is the root of its own tree: depth counts from 1 again, so a
    # 255-deep value under it is legal (256 levels); under the attached child it would be 257
    var deep = Json.array()
    var lv = 1
    while lv < 255
        var nx = Json.array()
        nx.append(deep)
        deep = nx
        lv += 1
    var host2 = Json.object()
    host2.put("child", Json.object())
    if host2.get("child") as old2
        host2.putInt("child", 0)
        old2.put("deep", deep)
        check("detached-depth-from-1", "${old2.stringify().len}", "${255 * 2 + 9}")

    # a required read is a handle too: v[k]? and v[i]? with no annotation stay JsonValue
    if Json.parse("{\"a\":{\"n\":1},\"xs\":[{\"n\":2}]}") as d2
        indexReads(d2)
        check("index-handles", d2.stringify(), "{\"a\":{\"n\":1,\"m\":5},\"xs\":[{\"n\":2,\"m\":6,\"seen\":true}]}")

    # a handle storing its own root stays finite: the argument is copied before it is stored
    var top = Json.object()
    top.put("kid", Json.object())
    if top.get("kid") as kid
        kid.put("up", top)
    check("handle-stores-root", top.stringify(), "{\"kid\":{\"up\":{\"kid\":{}}}}")

    # put/append of a JsonValue is still a snapshot (BUG-722)
    var m = Json.object()
    m.put("role", "user")
    var arr = Json.array()
    arr.append(m)
    m.put("role", "system")
    check("put-still-copies", arr.stringify(), "[{\"role\":\"user\"}]")

    # a key replaced keeps its position
    var ord = Json.object()
    ord.putInt("x", 1)
    ord.putInt("y", 2)
    ord.putInt("x", 3)
    check("key-order", ord.stringify(), "{\"x\":3,\"y\":2}")

    # rule 14: a JsonValue as text is its JSON -- toString, a string hole and print alike; a
    # string node is JSON text too, quotes included (tryStr gets the string itself)
    var tx = Json.object()
    tx.put("a", "b")
    tx.putInt("n", 2)
    check("text-toString", tx.toString(), "{\"a\":\"b\",\"n\":2}")
    check("text-hole", "${tx}", "{\"a\":\"b\",\"n\":2}")
    if tx.get("a") as sn
        check("text-string-node", sn.toString(), "\"b\"")
    print(tx)

    if failures == 0
        print("bug751_json_handle: OK")
    else
        print("bug751_json_handle: ${failures} WRONG")
ZBR
cat > "$OUT/json_hdepth.zbr" <<'ZBR'
# BUG-751: with handles, a store can reach a tree through a value read out of it. The 256-level
# limit (BUG-722) counts from the tree's ROOT, not from the receiver: storing a 255-deep value
# under a handle that is itself the root's child makes the tree 257 deep, and is refused.

def main()
    var deep = Json.array()
    var level = 1
    while level < 255
        var next = Json.array()
        next.append(deep)
        deep = next
        level += 1
    var root = Json.object()
    root.put("child", Json.object())
    root.put("ok", deep)
    print("stored 255 levels under the root: tree is 256")
    if root.get("child") as c
        c.put("deep", deep)
    print("SURVIVED: a 257-level tree was built through a handle")
ZBR
cat > "$OUT/json_detached.zbr" <<'ZBR'
# BUG-751: a child detached by replacing its key is the root of its own tree, so the 256-level
# limit counts from it: a 255-deep value under it is legal (bug751_json_handle_test), one level
# more (256 under a root = 257) is refused with BUG-722's message.

def main()
    var deep = Json.array()
    var level = 1
    while level < 256
        var next = Json.array()
        next.append(deep)
        deep = next
        level += 1
    var host = Json.object()
    host.put("child", Json.object())
    if host.get("child") as old
        host.putInt("child", 0)
        old.put("deep", deep)
    print("SURVIVED: a 257-level tree was built under a detached handle")
ZBR
# json_edges: what Json.parse accepts, what a number is, and what stringify writes, alike on
# both routes line for line. Until 2026-11-16 this route read through x.json2, which made every
# number an f64 -- an integer past 2^53 came back changed (9223372036854775807 read
# 9223372036854776000 and was no int at all), a float was written with an exponent (1e+21,
# 1e-7) where the Zig route writes plain digits, a number too big for either type was lost
# (1e400 was nil), and a DUPLICATE KEY was accepted, the last one kept, where the Zig route
# answers nil. The runtime parses for itself now, by std.json's rules.
cat > "$OUT/json_edges.zbr" <<'ZBR'
def show(what: str, text: str)
    if Json.parse(text) as j
        var kind = "other"
        if j.tryInt() as i
            kind = "int ${i}"
        else if j.tryFloat() as f
            kind = "float ${f}"
        else if j.tryStr() as s
            kind = "str ${s.len}"
        else if j.isNull()
            kind = "null"
        print("${what}: ${j.stringify()} [${kind}]")
    else
        print("${what}: nil")

def main()
    show("int", "1")
    show("neg", "-7")
    show("zero", "0")
    show("neg-zero", "-0")
    show("float", "2.5")
    show("whole-float", "1.0")
    show("trailing-zeros", "2.50")
    show("exp", "1e3")
    show("exp-neg", "1e-3")
    show("exp-cap", "1E3")
    show("big-exp", "1e21")
    show("tiny", "1e-7")
    show("i64-max", "9223372036854775807")
    show("i64-over", "9223372036854775808")
    show("i64-min", "-9223372036854775808")
    show("huge-int", "123456789012345678901234567890")
    show("exp-overflow", "1e400")
    show("frac-long", "0.1234567890123456789")
    show("third", "0.3333333333333333")
    show("leading-zero", "01")
    show("plus", "+1")
    show("dot-only", "1.")
    show("hex", "0x10")
    show("nan", "NaN")
    show("dup-key", "{\"a\":1,\"b\":5,\"a\":2}")
    show("empty", "")
    show("space", "  [ 1 , 2 ]  ")
    show("trailing-comma", "[1,2,]")
    show("garbage-after", "{\"a\":1} x")
    show("single-quote", "{'a':1}")
    show("bare-key", "{a:1}")
    show("escape-slash", "\"a\\/b\"")
    show("escape-u", "\"\\u00e9\"")
    show("surrogates", "\"\\ud83d\\ude00\"")
    show("lone-surrogate", "\"\\ud83d\"")
    show("control", "\"a\\u0001b\"")
    show("tab-escape", "\"a\\tb\"")
    show("quote-escape", "\"a\\\"b\"")
    show("backslash", "\"a\\\\b\"")
    show("utf8", "\"é😀\"")
    show("key-escape", "{\"a\\\"b\":1}")
    show("key-unicode", "{\"\\u00e9\":1}")
    show("null", "null")
    show("true", "true")
    show("nested-empty", "{\"a\":{},\"b\":[]}")
    show("neg-zero-float", "-0.0")
    show("exp-plus", "1e+3")
    show("neg-exp", "-1E-2")
    show("zero-exp", "0e0")
    show("one-exp0", "1.0e0")
    show("exp-missing", "1e")
    show("exp-sign-only", "1e+")
    show("minus-only", "-")
    show("double-minus", "--1")
    show("int-as-float-big", "1e19")
    show("float-big-frac", "123456789.123456789")
    show("denormal", "5e-324")
    show("underflow", "1e-400")
    show("max-f64", "1.7976931348623157e308")
    show("nul-escape", "\"a\\u0000b\"")
    show("del-raw", "\"a\u{7f}b\"")
    show("empty-key", "{\"\":1}")
    show("nested", "[[1,[2,{\"a\":[3]}]],{}]")
    show("ws-all", " \t\n\r{ \"a\" : [ 1 , 2 ] } \n")
    show("unterminated", "\"abc")
    show("bad-escape", "\"a\\qb\"")
    show("short-u", "\"\\u12\"")
    show("upper-hex", "\"\\u00E9\"")
    show("low-then-high", "\"\\ude00\\ud83d\"")
    show("high-then-text", "\"\\ud83dx\"")
    show("raw-tab", "\"a\tb\"")
    show("raw-newline", "\"a\nb\"")
    show("true-prefix", "truex")
    show("capital-true", "True")
    show("null-long", "nulll")
    show("two-values", "1 2")
    show("comma-only", "[,]")
    show("colon-missing", "{\"a\" 1}")
    show("unclosed", "[1,2")
    show("unclosed-object", "{\"a\":1")
    show("key-not-string", "{1:2}")
    show("dup-key-nested", "{\"o\":{\"k\":1,\"k\":2}}")
    show("same-key-different-objects", "[{\"k\":1},{\"k\":2}]")
    var o = Json.object()
    o.putFloat("one", 1.0)
    o.putFloat("hundred", 100.0)
    o.putFloat("tenth", 0.1)
    o.putFloat("big", 1.0e21)
    o.putFloat("small", 0.000001)
    o.putFloat("neg", -2.5)
    o.putInt("i", 42)
    o.put("s", "tab\there \"quoted\" back\\slash é")
    print(o.stringify())
ZBR
for p in json_nest json_deep json_kind json_kind2 json_edges; do json_both $p; done
for p in json_handle json_hdepth json_detached; do json_v $p; done
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
# the three that must stop: the same message on both routes, the same lines before it
for p in json_deep json_kind json_kind2; do
  zmsg=$(grep -m1 -oE 'Json: .*' "$OUT/${p}_zig_err.txt" | tr -d '\r')
  vmsg=$(grep -m1 -oE 'Json: .*' "$OUT/${p}_v_err.txt" | tr -d '\r')
  if [ "$(cat "$OUT/${p}_zig_rc.txt")" = 0 ] || [ -z "$zmsg" ]; then json_bad="$json_bad $p(NO CONTROL: the Zig run did not stop with a Json: message)"
  elif [ "$(cat "$OUT/${p}_v_rc.txt")" = 0 ]; then json_bad="$json_bad $p(the V run was not stopped: $(tail -1 "$OUT/${p}_v_out.txt" | cut -c1-80))"
  elif [ "$zmsg" != "$vmsg" ]; then json_bad="$json_bad $p(the message differs, V then Zig: '$vmsg' / '$zmsg')"
  elif grep -q SURVIVED "$OUT/${p}_v_out.txt" "$OUT/${p}_zig_out.txt"; then json_bad="$json_bad $p(SURVIVED printed)"
  elif ! diff -q "$OUT/${p}_v_out.txt" "$OUT/${p}_zig_out.txt" > /dev/null; then json_bad="$json_bad $p(the lines before the stop differ)"; fi
done
# the handle fixtures, on this route against their own text
if [ "$(cat "$OUT/json_handle_v_rc.txt")" != 0 ]; then json_bad="$json_bad json_handle(v exit $(cat "$OUT/json_handle_v_rc.txt"): $(grep -m1 -E 'error|panic' "$OUT/json_handle_v_err.txt" | cut -c1-140))"
elif ! tail -1 "$OUT/json_handle_v_out.txt" | grep -qx 'bug751_json_handle: OK' || grep -q WRONG "$OUT/json_handle_v_out.txt"; then json_bad="$json_bad json_handle($(grep -m1 WRONG "$OUT/json_handle_v_out.txt" | cut -c1-140))"
elif [ "$(grep -c ': ok$' "$OUT/json_handle_v_out.txt")" -lt 20 ] || ! grep -qxF '{"a":"b","n":2}' "$OUT/json_handle_v_out.txt"; then json_bad="$json_bad json_handle(fewer than twenty checks ran, or print of a value was not its JSON text)"
elif grep -qE '^[[:space:]]*[A-Za-z_.0-9]+ = zjson_(put|append)' "$OUT/json_handle.v" || ! grep -q 'zjson_put_str(' "$OUT/json_handle.v"; then json_bad="$json_bad json_handle(the emitted V still rebinds a put, or calls none)"; fi
for p in json_hdepth json_detached; do
  if [ "$(cat "$OUT/${p}_v_rc.txt")" = 0 ] || grep -q SURVIVED "$OUT/${p}_v_out.txt"; then json_bad="$json_bad $p(a 257th level was stored)"
  elif ! grep -q 'Json: put/append would nest a value deeper than 256 levels' "$OUT/${p}_v_err.txt"; then json_bad="$json_bad $p(stopped, but not by the depth message: $(grep -m1 -E 'error|panic' "$OUT/${p}_v_err.txt" | cut -c1-120))"; fi
done
if ! grep -qxF 'stored 255 levels under the root: tree is 256' "$OUT/json_hdepth_v_out.txt"; then json_bad="$json_bad json_hdepth(NO CONTROL: the 256-level tree it starts from was not built)"; fi
json_refused=$(cat "$OUT"/json_*_emit.txt | grep -cE '^    ')
if [ -n "$json_bad" ]; then echo "json: FAILED --$json_bad"; fail=1
elif [ "$json_refused" != 0 ]; then echo "json: FAILED -- REFUSED: $(cat "$OUT"/json_*_emit.txt | grep -m1 -E '^    ' | cut -c1-140)"; fail=1
else echo "json: ok -- parse, numbers and stringify alike on both backends over $(wc -l < "$OUT/json_edges_zig_out.txt") edge lines; BUG-722's nest fixture alike on both backends ($(wc -l < "$OUT/json_nest_zig_out.txt") lines; right under the region check mode too) and its three refusals stopped by the same message on both; BUG-751's handle fixture ($(grep -c ': ok$' "$OUT/json_handle_v_out.txt") checks) and its two depth refusals on this backend against their own text (the Zig route's flip is the other half)"; fi
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
elif [ "$(grep -cE '^    ' "$OUT/ladder_emit.txt")" != 0 ]; then echo "ladder: FAILED -- REFUSED: $(grep -m1 -E '^    ' "$OUT/ladder_emit.txt" | cut -c1-140)"; fail=1
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
