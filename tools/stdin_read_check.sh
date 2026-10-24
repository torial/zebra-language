#!/usr/bin/env bash
# pins: BUG-619 sys.readLine / sys.readBytes read stdin through the buffer, not a read per byte
# stdin_read_check.sh — THE STDIN-READER GATE (`stdin-read`, FAST tier, 2026-10-23, BUG-619).
#
# `sys.readLine()` and `sys.readBytes(n)` took one byte per `readSliceShort`, and on an empty
# buffer that call reads straight into the caller's 1-byte slice: a read per byte. 10 MB of
# stdin took 18.5 s -- in a --release build too -- where the buffered reader takes 0.09 s.
# No gate fed a program more than a few bytes of stdin, so nothing could see it; the census
# (2026-10-23) found it timing Sean's 100 MB loop.
#
# Leg 1, CORRECTNESS, oracle = the input file: CRLF lines lose the '\r', empty lines stay
# empty, a 10,000-byte line spans the 4 KB buffer, the last line has no '\n'. The expected
# output is derived from the bytes the gate wrote, never from the program.
# Leg 2: readBytes and readLine share one reader (the LSP's Content-Length framing): a 5-byte
# header read with readBytes, then lines.
# Leg 3, SPEED: 4 MB of lines (120,000 lines, printed back) must be read in under 1.5 s
# (MIN of two runs). Measured 2026-10-23: 3.84 s before the fix (the gate went red against the
# old runtime, the real attacker), 0.42 s after -- 2.6x and 3.6x clear of the threshold.
# Leg 0 is the control: the program must print one record per input line, or the gate refuses.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/zig_toolchain.sh"   # the PINNED zig, also standalone (hazard_lint H14)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
ZEBRA="$REPO/zig-out/bin/zebra.exe"
[ -x "$ZEBRA" ] || [ ! -x "${ZEBRA%.exe}" ] || ZEBRA="${ZEBRA%.exe}"
[ -x "$ZEBRA" ] || ZEBRA="$REPO/zig-out/bin/zebra"
W="$(mktemp -d "${TMPDIR:-/tmp}/zbr_stdin.XXXXXX")"
trap 'rm -rf "$W"' EXIT
die() { printf 'stdin-read: REFUSING to report — %s\n' "$1"; exit 2; }
[ -x "$ZEBRA" ] || die "zebra not built"
cp tools/fixtures/stdin_read_probe.zbr "$W/"
( cd "$W" && "$ZEBRA" --output-dir "$W/out" stdin_read_probe.zbr < /dev/null > "$W/build.log" 2>&1 ) || true
EXE="$(ls "$W"/out/stdin_read_probe*.exe "$W"/out/stdin_read_probe.zig.*exe 2>/dev/null | head -1)"
[ -n "$EXE" ] && [ -x "$EXE" ] || { tail -5 "$W/build.log"; die "the probe did not build"; }
PY=python; command -v python >/dev/null 2>&1 || PY=python3
"$PY" - "$W" "$EXE" <<'PY'
import os, subprocess, sys, time, pathlib
w, exe = pathlib.Path(sys.argv[1]), sys.argv[2]
passed = failed = 0
def ok(m):
    global passed; passed += 1; print(f"  ok   {m}")
def bad(m):
    global failed; failed += 1; print(f"  FAIL {m}")
def expected(data, skip=0):
    # The documented rule: a line ends at '\n' (stripped), every '\r' is dropped, and a final
    # line without '\n' is still a line; no line after a trailing '\n'.
    body = data[skip:]
    parts = body.split(b"\n")
    if parts and parts[-1] == b"":
        parts = parts[:-1]
    out = []
    for p in parts:
        t = p.replace(b"\r", b"")
        out.append(f"{len(t)}:{t[:8].decode()}")
    out.append(f"lines={len(parts)}")
    return out
def run(data, *args):
    r = subprocess.run([exe, *args], input=data, capture_output=True, timeout=120)
    return r.stdout.decode(errors="replace").replace("\r\n", "\n").splitlines()
data = (b"alpha\r\nbeta\n\n" + b"x" * 10000 + b"\r\n" + b"\r\n" + b"gamma line one\n"
        + (b"y" * 4095 + b"\n") + b"last-without-newline")
got = run(data)
want = expected(data)
if len(got) < 3:
    print(f"stdin-read: REFUSING to report — the probe printed {len(got)} lines for 8 input lines"); sys.exit(2)
(ok if got == want else bad)(f"lines: CRLF, empty, a 10,000-byte line, a 4,095-byte line, no final newline ({len(want)-1} lines)" + ("" if got == want else f"\n         want {want}\n         got  {got}"))
got2 = run(b"HEAD!" + data, "bytes")
want2 = ["head=HEAD!"] + expected(data)
(ok if got2 == want2 else bad)("readBytes(5) then readLine share one buffered reader" + ("" if got2 == want2 else f"\n         want {want2[:4]}\n         got  {got2[:4]}"))
(ok if run(b"") == ["lines=0"] else bad)("empty stdin: no line, readLine returns nil at once")
big = b"".join(b"field%06d*alpha*beta*gamma*delta\n" % i for i in range(120000))  # ~4 MB
times = []
for _ in range(2):
    t0 = time.perf_counter(); g = run(big); times.append(time.perf_counter() - t0)
best = min(times)
(ok if g[-1] == "lines=120000" else bad)(f"4 MB of lines read completely ({g[-1] if g else 'no output'})")
(ok if best < 1.5 else bad)(f"4 MB of lines in under 1.5 s, min of two (took {best:.2f} s; the per-byte read took 3.84 s)")
print(f"stdin-read: {passed} passed, {failed} failed ({len(big)} bytes timed, best {best:.2f} s)")
sys.exit(1 if failed else 0)
PY
