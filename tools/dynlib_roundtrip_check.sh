#!/usr/bin/env bash
# dynlib_roundtrip_check.sh — THE PLUGIN GATE: a Zebra shared library, loaded by a Zebra host.
#
#   bash tools/dynlib_roundtrip_check.sh
#
# QUICKSTART §44 promises `zebra --shared greeter.zbr` + `DynLib.open` + `lib.lookup(IFace,
# "sym")`. This runs exactly that, as a user would: `--shared` builds the library next to
# the source, the host is a plain `zebra host.zbr -- <lib>`. The value printed
# ("Hello, World v7") appears in NEITHER source file as a literal, so the host cannot print
# it without calling into the library.
#
# STATUS: GREEN since 2026-09-09 (BUG-356 FIXED). The four legs, in the order they fell:
# no `--shared` flag; `try _dynlib_open` outside a throws fn; lookup yielding `?*IFace`;
# and the one that looked like memory corruption — the host was built on the fast
# `-fno-llvm -fno-lld` path WITHOUT libc, so `std.DynLib` was Zig's own ElfDynLib loader,
# which does not apply the library's RELATIVE relocations: the vtable read back held file
# offsets. A program that calls DynLib.open now always links libc (dlopen).
# LEG 5, found while closing it: a library has no main(), so its `_io` was undefined and
# the first print/sleep/File inside it faulted — the @export factory now initialises a
# Threaded Io on first use (`_libInit`). The fixture exercises that (print + sleep + a
# module var) so this gate would notice it regressing.
# pins: BUG-356 this gate IS the shared-library round trip QUICKSTART §44 promised
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEBRA="$REPO/zig-out/bin/zebra.exe"; [ -x "$ZEBRA" ] || ZEBRA="$REPO/zig-out/bin/zebra"
[ -x "$ZEBRA" ] || { echo "FAIL: zebra not built"; exit 1; }
WORK="${TMPDIR:-/tmp}/zbr-dynlib-$$"; rm -rf "$WORK"; mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT
cp "$REPO/test/dynlib_roundtrip/greeter.zbr" "$REPO/test/dynlib_roundtrip/host.zbr" "$WORK/"
cd "$WORK"
"$ZEBRA" --shared greeter.zbr >/dev/null 2>&1 || { echo "FAIL: zebra --shared greeter.zbr failed"; exit 1; }
case "$(uname -s)" in
  Linux)  lib="$WORK/libgreeter.so" ;;
  Darwin) lib="$WORK/libgreeter.dylib" ;;
  *)      lib="$WORK/greeter.dll" ;;
esac
[ -f "$lib" ] || { echo "FAIL: --shared produced no library at $lib"; exit 1; }
out=$("$ZEBRA" host.zbr --output-dir "$WORK" -- "$lib" 2>&1)
if echo "$out" | grep -qF "Hello, World v7"; then
  echo "dynlib round trip: PASS (--shared library built, loaded, called)"
  exit 0
fi
echo "dynlib round trip: FAIL (BUG-356 names the five legs; this was green 2026-09-09)"
echo "$out" | grep -v "^wrote\|^compiling\|^ *pars\|^ *resolved" | head -4 | sed 's/^/    /'
exit 1
