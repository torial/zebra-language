#!/usr/bin/env python3
"""Aggregate the multi-seed constructal sweep into mean +/- sd, and say which differences
actually survive the noise.

The whole point: every number reported before this was n=1. A difference smaller than the
seed-to-seed spread is not a finding, and the eta null was exactly that mistake.
"""
import math
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
rows = []
failed = 0
for line in path.read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) != 6:
        continue
    k, eta, src, seed, dim, tips = parts
    if dim == "FAILED" or tips == "FAILED":
        failed += 1
        continue
    rows.append((src, float(k), float(eta), int(seed), float(dim), int(tips)))

if failed:
    print("!! %d run(s) produced no number and were EXCLUDED (not averaged in as zero)" % failed)
if not rows:
    sys.exit("REFUSING: no usable rows")


def stats(vals):
    n = len(vals)
    m = sum(vals) / n
    if n < 2:
        return m, 0.0, n
    var = sum((v - m) ** 2 for v in vals) / (n - 1)
    return m, math.sqrt(var), n


srcs = sorted(set(r[0] for r in rows))
ks = sorted(set(r[1] for r in rows))
etas = sorted(set(r[2] for r in rows))

# pooled seed-to-seed sd, the noise floor every claim must clear
all_sds = []
for s in srcs:
    for k in ks:
        for e in etas:
            v = [r[4] for r in rows if r[0] == s and r[1] == k and r[2] == e]
            if len(v) >= 2:
                all_sds.append(stats(v)[1])
floor = sum(all_sds) / len(all_sds) if all_sds else 0.0

print("seeds per cell: %d   pooled seed-to-seed sd: %.4f" % (len(rows) // (len(srcs) * len(ks) * len(etas)), floor))
print("=> a difference below ~%.3f (2 sd) is NOT resolvable by this data" % (2 * floor))
print()

for s in srcs:
    print("--- src = %s ---" % s)
    hdr = "k \\ eta   " + "".join("%-16s" % ("%g" % e) for e in etas)
    print(hdr)
    for k in ks:
        cells = []
        for e in etas:
            v = [r[4] for r in rows if r[0] == s and r[1] == k and r[2] == e]
            m, sd, n = stats(v)
            cells.append("%.3f+-%.3f" % (m, sd))
        print("%-10s" % ("%g" % k) + "".join("%-16s" % c for c in cells))
    # eta effect within each k, tested against the noise floor
    print("   eta sweep significance (eta=0 vs eta=max):")
    for k in ks:
        v0 = [r[4] for r in rows if r[0] == s and r[1] == k and r[2] == min(etas)]
        v1 = [r[4] for r in rows if r[0] == s and r[1] == k and r[2] == max(etas)]
        m0, sd0, n0 = stats(v0)
        m1, sd1, n1 = stats(v1)
        d = m0 - m1
        se = math.sqrt(sd0 * sd0 / max(n0, 1) + sd1 * sd1 / max(n1, 1))
        verdict = "RESOLVED" if se > 0 and abs(d) > 2 * se else "not resolved"
        print("     k=%-6g delta %+.3f  se %.3f   %s" % (k, d, se, verdict))
    print()
