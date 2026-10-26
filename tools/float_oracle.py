#!/usr/bin/env python3
"""The V runtime's fixed-precision float spelling against Python's format() (2026-10-26).

The language's rule since 2026-10-26 is the exact binary value rounded at N places with ties to
even -- Python's digits -- and selfhost/zebra_rt.v spells it itself (zfmt_fixed: the double taken
apart, its digits produced with no C runtime). This oracle holds that against Python over 356
values x 7 precisions (2,492 rows): every exact-half parity, the near-ties a 17-digit C runtime
misreads (1.05, 1.45, 1.55, 1.95, 10.15, 10.35, 10.65, 10.85), 1e300, 5e-324, the smallest normal,
the largest double, -0.0, 2^53 and its neighbours, and 300 seeded random values of five kinds
(uniform, decimal-looking, near ties, wide magnitudes, raw 64-bit patterns).

    python tools/float_oracle.py              # build the harness, run it under V, compare; exit 1 on a difference
    python tools/float_oracle.py --control    # one expectation flipped on purpose must be reported, else exit 3

The harness is the runtime file as the emitter inlines it (the sqlite and http sections cut) with
the emitted programs' imports and a main that prints zfmt_one(x, N) per row; built under
.zig-cache/float_oracle/. V: $V, else /c/Projects/v-dist/v/v.exe (the pin).
"""
import os
import random
import struct
import subprocess
import sys

WT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(WT, ".zig-cache", "float_oracle")
V = os.environ.get("V", "C:/Projects/v-dist/v/v.exe")
IMPORTS = ["import crypto.sha256", "import math", "import math.bits", "import os", "import rand",
           "import strconv", "import sync", "import time", "import x.json2"]
SPECS = [0, 1, 2, 3, 4, 6, 9]
MAIN = """
fn main() {
	lines := os.read_lines('values.txt') or { panic(err) }
	for l in lines {
		if l.len == 0 {
			continue
		}
		parts := l.split(' ')
		x := parts[0].f64()
		p := parts[1].int()
		println(zfmt_one(x, p))
	}
}
"""


def values():
    random.seed(20261026)
    vals = [2.675, 0.125, 0.5, 1.5, 2.5, 3.5, -0.5, -1.5, -2.5, 1.45, 1.55, 1.05, 1.95, 10.15, 10.35,
            10.65, 10.85, 9.995, 9.996, 0.995, 1.005, 0.045, 99.5, -2.675, -9.995, 0.375, 1e16, 1e20,
            1e300, 5e-324, 2.2250738585072014e-308, 1.7976931348623157e308, -0.0, 0.0, 0.1, 1 / 3,
            123456789012345680000.0, 1e-7, -1.5e-10, 2.0, 12345.678, 4611686018427387904.0,
            0.30000000000000004, 1.0000000000000002, 2 ** 53 + 0.0, 2 ** 53 - 1.0, 1e15 + 0.125,
            0.5e-9, 1234567890123.125, 65535.5, 0.0000005, 0.0000015, 0.0000025, 7.0, 100.0]
    for _ in range(300):
        kind = random.randrange(5)
        if kind == 0:
            v = random.uniform(-1000, 1000)
        elif kind == 1:
            v = random.randrange(-100000, 100000) / 10 ** random.randrange(1, 6)
        elif kind == 2:
            v = (random.randrange(-2000, 2000) + 0.5) / 10 ** random.randrange(0, 4)
        elif kind == 3:
            v = random.uniform(-1, 1) * 10.0 ** random.randrange(-12, 25)
        else:
            v = struct.unpack("<d", struct.pack("<Q", random.getrandbits(64)))[0]
            if v != v or v in (float("inf"), float("-inf")):
                v = 1.0
        vals.append(v)
    return vals


def build_harness():
    rt = open(os.path.join(WT, "selfhost", "zebra_rt.v"), encoding="utf-8").read()
    for name in ("sqlite", "http"):
        a = rt.index("// == %s begin ==" % name)
        b = rt.index("// == %s end ==" % name) + len("// == %s end ==" % name)
        rt = rt[:a] + "// (the %s section left out, as the emitter leaves it out of a program without it)\n" % name + rt[b:]
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "harness.v"), "w", encoding="utf-8", newline="") as f:
        f.write("\n".join(IMPORTS) + "\n\n" + rt + "\n" + MAIN)


def main():
    control = "--control" in sys.argv
    build_harness()
    rows = [(v, p) for v in values() for p in SPECS]
    with open(os.path.join(OUT, "values.txt"), "w") as f:
        for v, p in rows:
            f.write("%r %d\n" % (v, p))
    expected = [format(v, ".%df" % p) for v, p in rows]
    if control:
        i = rows.index((2.675, 2))
        expected[i] = "2.68"  # the old rule's digit: the oracle must report this row
    r = subprocess.run([V, "-gc", "none", "-enable-globals", "run", "harness.v"], cwd=OUT,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    got = r.stdout.splitlines()
    if r.returncode != 0 or len(got) != len(rows):
        print("float_oracle: the V harness did not run to the end (exit %d, %d of %d lines)" % (r.returncode, len(got), len(rows)))
        print("\n".join(l for l in r.stderr.splitlines() if "error" in l)[:2000])
        sys.exit(2)
    diffs = [(rows[i], expected[i], got[i]) for i in range(len(rows)) if expected[i] != got[i]]
    if control:
        if len(diffs) == 1 and diffs[0][0] == (2.675, 2):
            print("control: the flipped expectation (2.675 at .2f as 2.68) is the one row reported -- the oracle sees")
            return
        print("control FAILED: %d row(s) reported, wanted exactly the flipped one" % len(diffs))
        for d in diffs[:5]:
            print("  ", d)
        sys.exit(3)
    for (v, p), e, g in diffs[:20]:
        print("  %r at .%df: Python %s, V %s" % (v, p, e, g))
    print("float_oracle: %d of %d rows differ from Python's format() (%s)" % (len(diffs), len(rows), "the digits are the language's" if not diffs else "NOT the language's"))
    sys.exit(1 if diffs else 0)


if __name__ == "__main__":
    main()
