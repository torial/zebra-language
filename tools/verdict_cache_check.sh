#!/usr/bin/env bash
# verdict_cache_check.sh -- attack the zig VERDICT CACHE in tools/zig_build_lib.sh.
#
# A cache fails by LYING: answering from memory when the inputs changed. So every leg
# here is a way the inputs can change, and each must reach zig (a MISS). The attacker is
# a stub `zig` on PATH that counts its invocations and answers `version` from $STUB_VER;
# the code under test is the SHIPPED zbr_zig_build, sourced, never a copy of it.
#
#   1. same files twice            -> miss, then HIT (zig not started the second time)
#   2. a DEP beside the root edits -> miss
#   3. a new `zig version`         -> miss
#   4. a genuine compile error     -> cached; the hit restores zig's stderr, same rc
#   5. an INFRA error (BUG-302)    -> NOT cached: the next call starts zig again
#   6. a timeout                   -> NOT cached
#   7. ZBR_VCACHE=0                -> zig started even though the answer is cached
#   8. a *.err file beside the root does not change the key (the gate's own evidence)
#   9. a SILENT failure (non-zero, nothing on stderr) -> NOT cached: zig never ran
#  11. the ROOT file reported missing ("unable to load 'p.zig': FileNotFound") -> NOT
#      cached (the input vanished under zig); a missing DEP stays cached (a real verdict)
#  10. output_sweep's OUTPUT cache: a run whose program output was lost (the compile
#      succeeded, the binary died at start) must NOT store its empty capture
#
# Legs 9 and 10 are 2026-10-02's receipt: under fork exhaustion processes died at start
# (0xC0000142), 29 empty captures were cached, and one replayed as a behaviour change on an
# idle machine. Leg 10 was watched RED against the pre-fix output_sweep.sh (1 entry stored).
#
# Legs 2, 3, 5 and 6 are the ones that matter: each is a stale or poisoned answer.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ORIG_PATH="$PATH"
TMP="${TMPDIR:-/tmp}/zz_verdict_cache_check"
rm -rf "$TMP"; mkdir -p "$TMP/bin"
export ZBR_VCACHE_DIR="$TMP/cache"          # never the real cache
export ZBR_VCACHE_LOG="$TMP/log"

INFRA_ERR="/c/x/.zvm/0.16.0/lib/std/debug.zig:1:1: error: unable to load 'debug.zig': Unexpected"
REAL_ERR="widget.zig:42:9: error: expected type 'i64', found '[]const u8'"
cat > "$TMP/bin/zig" <<STUB
#!/usr/bin/env bash
if [ "\$1" = version ]; then echo "\${STUB_VER:-0.16.0}"; exit 0; fi
n=\$(cat "$TMP/count" 2>/dev/null || echo 0); echo \$((n+1)) > "$TMP/count"
case "\${STUB_MODE:-pass}" in
  pass)    exit 0 ;;
  real)    echo "$REAL_ERR" >&2; exit 1 ;;
  infra)   echo "$INFRA_ERR" >&2; exit 1 ;;
  slow)    sleep 5; exit 0 ;;
  silent)  exit 1 ;;
  rootgone) echo "x/p.zig:1:1: error: unable to load 'p.zig': FileNotFound" >&2; exit 1 ;;
  depgone)  echo "x/p.zig:1:1: error: unable to load 'zebra_rt.zig': FileNotFound" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/zig"
export PATH="$TMP/bin:$PATH"
unset ZBR_ZIG_VERSION
. "$REPO/tools/zig_build_lib.sh"      # reads the STUB's version once, as a gate does
[ "$ZBR_ZIG_VERSION" = 0.16.0 ] || { echo "verdict-cache: REFUSING -- the library did not read zig's version ($ZBR_ZIG_VERSION)"; exit 2; }

count() { cat "$TMP/count" 2>/dev/null || echo 0; }
mkprog() {   # $1 = dir
  mkdir -p "$1"
  printf 'const rt = @import("zebra_rt.zig");\npub fn main() void {}\n' > "$1/p.zig"
  printf 'pub const x = 1;\n' > "$1/zebra_rt.zig"
}
fail=0
check() {   # $1 = leg  $2 = condition-result (0 ok)  $3 = detail
  if [ "$2" = 0 ]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s -- %s\n' "$1" "$3"; fail=1; fi
}

# positive control: the key is computable at all (a cache that cannot key is off, silently)
mkprog "$TMP/a"
k="$(zbr_verdict_key "$TMP/a/p.zig")"
[ ${#k} -eq 64 ] || { echo "verdict-cache: REFUSING -- no key computed ('$k')"; exit 2; }

# 1. miss, then hit
STUB_MODE=pass zbr_zig_build "$TMP/a/p.zig" "$TMP/a/build.err" 30; r1=$?; c1=$(count)
STUB_MODE=pass zbr_zig_build "$TMP/a/p.zig" "$TMP/a/build.err" 30; r2=$?; c2=$(count)
check "1 same files: miss then hit" $([ $r1 = 0 ] && [ $r2 = 0 ] && [ "$c1" = 1 ] && [ "$c2" = 1 ]; echo $?) "rc $r1/$r2, zig started $c1 then $c2 times"
# 8. the *.err the gate wrote beside the root (leg 1 created build.err) did not change the key
check "8 *.err ignored by the key" $([ "$(zbr_verdict_key "$TMP/a/p.zig")" = "$k" ]; echo $?) "key moved"

# 2. a dep changes
printf 'pub const x = 2;\n' > "$TMP/a/zebra_rt.zig"
STUB_MODE=pass zbr_zig_build "$TMP/a/p.zig" "$TMP/a/build.err" 30; c=$(count)
check "2 changed dep: miss" $([ "$c" = 2 ]; echo $?) "zig started $c times (want 2)"

# 3. a new zig
ZBR_ZIG_VERSION=0.17.0 STUB_VER=0.17.0 STUB_MODE=pass zbr_zig_build "$TMP/a/p.zig" "$TMP/a/build.err" 30; c=$(count)
check "3 new zig version: miss" $([ "$c" = 3 ]; echo $?) "zig started $c times (want 3)"

# 4. a genuine failure is cached with its stderr
mkprog "$TMP/b"; printf '// b\n' >> "$TMP/b/p.zig"
STUB_MODE=real zbr_zig_build "$TMP/b/p.zig" "$TMP/b/build.err" 30; r1=$?; c1=$(count)
rm -f "$TMP/b/build.err"
STUB_MODE=real zbr_zig_build "$TMP/b/p.zig" "$TMP/b/build.err" 30; r2=$?; c2=$(count)
check "4 genuine error: cached, stderr restored" $([ $r1 = 1 ] && [ $r2 = 1 ] && [ "$c2" = "$c1" ] && grep -qF "$REAL_ERR" "$TMP/b/build.err"; echo $?) "rc $r1/$r2, zig $c1 -> $c2, stderr: $(head -c 80 "$TMP/b/build.err" 2>/dev/null)"

# 5. an infra error is never cached
mkprog "$TMP/c"; printf '// c\n' >> "$TMP/c/p.zig"
STUB_MODE=infra zbr_zig_build "$TMP/c/p.zig" "$TMP/c/build.err" 30; c1=$(count)
STUB_MODE=infra zbr_zig_build "$TMP/c/p.zig" "$TMP/c/build.err" 30; c2=$(count)
check "5 infra error: not cached" $([ "$c2" -gt "$c1" ]; echo $?) "zig $c1 -> $c2 (the second call must start zig)"

# 6. a timeout is never cached
mkprog "$TMP/d"; printf '// d\n' >> "$TMP/d/p.zig"
STUB_MODE=slow zbr_zig_build "$TMP/d/p.zig" "$TMP/d/build.err" 1; r1=$?; c1=$(count)
STUB_MODE=pass zbr_zig_build "$TMP/d/p.zig" "$TMP/d/build.err" 30; r2=$?; c2=$(count)
check "6 timeout: not cached" $([ $r1 = 124 ] && [ $r2 = 0 ] && [ "$c2" -gt "$c1" ]; echo $?) "rc $r1/$r2, zig $c1 -> $c2"

# 7. the off switch
before=$(count)
ZBR_VCACHE=0 STUB_MODE=pass zbr_zig_build "$TMP/a/p.zig" "$TMP/a/build.err" 30; c=$(count)
check "7 ZBR_VCACHE=0 starts zig" $([ "$c" -gt "$before" ]; echo $?) "zig $before -> $c"

# 9. a silent failure is never cached
mkprog "$TMP/e"; printf '// e
' >> "$TMP/e/p.zig"
STUB_MODE=silent zbr_zig_build "$TMP/e/p.zig" "$TMP/e/build.err" 30; r1=$?; c1=$(count)
STUB_MODE=pass zbr_zig_build "$TMP/e/p.zig" "$TMP/e/build.err" 30; r2=$?; c2=$(count)
check "9 silent failure: not cached" $([ $r1 = 1 ] && [ $r2 = 0 ] && [ "$c2" -gt "$c1" ]; echo $?) "rc $r1/$r2, zig $c1 -> $c2"

# 11. a vanished ROOT is not a verdict; a missing DEP is
mkprog "$TMP/f"; printf '// f
' >> "$TMP/f/p.zig"
STUB_MODE=rootgone zbr_zig_build "$TMP/f/p.zig" "$TMP/f/build.err" 30; c1=$(count)
STUB_MODE=pass zbr_zig_build "$TMP/f/p.zig" "$TMP/f/build.err" 30; r2=$?; c2=$(count)
mkprog "$TMP/g"; printf '// g
' >> "$TMP/g/p.zig"
STUB_MODE=depgone zbr_zig_build "$TMP/g/p.zig" "$TMP/g/build.err" 30; c3=$(count)
STUB_MODE=depgone zbr_zig_build "$TMP/g/p.zig" "$TMP/g/build.err" 30; c4=$(count)
check "11 vanished root: not cached; missing dep: cached" $([ $r2 = 0 ] && [ "$c2" -gt "$c1" ] && [ "$c4" = "$c3" ]; echo $?) "root: zig $c1 -> $c2 (rc $r2); dep: zig $c3 -> $c4"

echo "  $(zbr_vcache_summary "$ZBR_VCACHE_LOG")  (this run's own lookups)"

# 10. the OUTPUT cache, with the REAL compiler and the real gate script: a stub zebra
# compiles for real (so the emit check matches) and loses the program's output.
ZREAL="$REPO/zig-out/bin/zebra.exe"; [ -x "$ZREAL" ] || ZREAL="${ZREAL%.exe}"
[ -x "$ZREAL" ] || { echo "verdict-cache: REFUSING -- leg 10 needs a built compiler"; exit 2; }
T10=bug406_print_containers_test
W="$TMP/oc"; mkdir -p "$W/tmp"
cat > "$W/zebra.exe" <<STUB10
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "--emit-zig" ] && exec "$ZREAL" "\$@"; done
"$ZREAL" "\$@" >/dev/null 2>&1
exit 0
STUB10
chmod +x "$W/zebra.exe"
sed -e "s#^ZEBRA=.*#ZEBRA=\"$W/zebra.exe\"#" -e "s#^OCACHE_DIR=.*#OCACHE_DIR=\"$W/ocache\"#"     -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=\"$REPO/tools\"#" "$REPO/tools/output_sweep.sh" > "$W/os.sh"
grep -q "^OCACHE_DIR=\"$W/ocache\"" "$W/os.sh" || { echo "verdict-cache: REFUSING -- leg 10 could not redirect the output cache"; exit 2; }
( export PATH="$ORIG_PATH" TMP="$W/tmp" TEMP="$W/tmp"; unset ZBR_VCACHE_DIR ZBR_VCACHE_LOG; bash "$W/os.sh" --gate --only "$T10" > "$W/log" 2>&1 )
grep -q "BEHAVIOUR CHANGED" "$W/log" || { echo "verdict-cache: REFUSING -- leg 10's stub did not lose the output (the attack never happened)"; exit 2; }
n10=$(find "$W/ocache" -type f 2>/dev/null | wc -l | tr -d ' ')
ok10=1; [ "$n10" = 0 ] && ok10=0
check "10 output cache: lost output not stored" "$ok10" "$n10 entry stored -- an empty capture would replay as a behaviour change"

rm -rf "$TMP"
if [ $fail = 0 ]; then echo "verdict-cache: all 11 legs pass"; exit 0; fi
echo "verdict-cache: FAILED"; exit 1
