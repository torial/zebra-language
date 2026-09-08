#!/usr/bin/env bash
# dynlib_roundtrip_check.sh — THE PLUGIN GATE: a Zebra shared library, loaded by a Zebra host.
#
#   bash tools/dynlib_roundtrip_check.sh
#
# QUICKSTART §44 promises `zebra --shared greeter.zbr` + `DynLib.open` + `lib.lookup(IFace,
# "sym")`. As of 2026-09-08 the selfhost has NO `--shared` flag, so this script builds the
# library the long way — `--emit-zig`, then `zig build-lib -dynamic` — and runs the host
# against it. The value printed ("Hello, World v7") appears in NEITHER source file as a
# literal, so the host cannot print it without calling into the library.
#
# STATUS: RED (BUG-356). Fixed on the way there: `try _dynlib_open` outside a throws fn,
# lookup yielding `?*IFace`, the factory pointer's calling convention. Still open: the fat
# pointer the factory returns holds garbage when read from the host (relocation / runtime
# init of the emitted .so). Pinned in gates.sh so a fix is noticed the day it lands.
#
# pins: BUG-356 the whole shared-library round trip
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEBRA="$REPO/zig-out/bin/zebra.exe"; [ -x "$ZEBRA" ] || ZEBRA="$REPO/zig-out/bin/zebra"
[ -x "$ZEBRA" ] || { echo "FAIL: zebra not built"; exit 1; }
WORK="${TMPDIR:-/tmp}/zbr-dynlib-$$"; rm -rf "$WORK"; mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT
cp "$REPO/test/dynlib_roundtrip/greeter.zbr" "$REPO/test/dynlib_roundtrip/host.zbr" "$WORK/"
cd "$WORK"
"$ZEBRA" --emit-zig greeter.zbr --output-dir "$WORK" >/dev/null 2>&1 || { echo "FAIL: emit-zig of the library failed"; exit 1; }
case "$(uname -s)" in
  Linux)  lib="$WORK/libgreeter.so" ;;
  Darwin) lib="$WORK/libgreeter.dylib" ;;
  *)      lib="$WORK/greeter.dll" ;;
esac
zig build-lib -dynamic -ODebug greeter.zig --name greeter >/dev/null 2>&1 || { echo "FAIL: zig build-lib of the emitted library failed"; exit 1; }
[ -f "$lib" ] || { echo "FAIL: no library produced at $lib"; exit 1; }
out=$("$ZEBRA" host.zbr --output-dir "$WORK" -- "$lib" 2>&1)
if echo "$out" | grep -qF "Hello, World v7"; then
  echo "dynlib round trip: PASS (BUG-356 is FIXED — unpin it in gates.sh)"
  exit 0
fi
echo "dynlib round trip: FAIL (BUG-356)"
echo "$out" | grep -v "^wrote\|^compiling\|^ *pars\|^ *resolved" | head -4 | sed 's/^/    /'
exit 1
