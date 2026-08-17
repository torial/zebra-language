#!/usr/bin/env python3
"""Does eta-leverage vary with how DISTRIBUTED the sources are?

leverage(k, frac) = mean dim(eta=0) - mean dim(eta=4), over seeds.
Reported with a standard error, and called resolved only if it clears 2 se.
"""
import math
import pathlib
import sys

rows = []
failed = 0
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    p = line.split("\t")
    if len(p) != 6:
        continue
    k, eta, src, frac, seed, dim = p
    if dim == "FAILED":
        failed += 1
        continue
    rows.append((float(k), float(eta), src, float(frac), int(seed), float(dim)))

if failed:
    print("!! %d run(s) produced no number and were EXCLUDED" % failed)
if not rows:
    sys.exit("REFUSING: no usable rows")


def st(v):
    n = len(v)
    m = sum(v) / n
    if n < 2:
        return m, 0.0, n
    return m, math.sqrt(sum((x - m) ** 2 for x in v) / (n - 1)), n


ks = sorted(set(r[0] for r in rows))
# order: most distributed -> least. edge is the limit of frac -> 0.
keys = []
for f in sorted(set(r[3] for r in rows if r[2] == "frac"), reverse=True):
    keys.append(("frac", f))
if any(r[2] == "edge" for r in rows):
    keys.append(("edge", 0.0))

print("eta-leverage = dim(eta=0) - dim(eta=4).  Sources go from fully distributed to a")
print("single hot boundary, with TOTAL generation held constant throughout.")
print()
print("%-7s %-14s %-9s %-9s %-9s %s" % ("k", "sources", "eta=0", "eta=4", "leverage", "verdict"))
for k in ks:
    for src, f in keys:
        v0 = [r[5] for r in rows if r[0] == k and r[2] == src and r[3] == f and r[1] == 0.0]
        v4 = [r[5] for r in rows if r[0] == k and r[2] == src and r[3] == f and r[1] == 4.0]
        if not v0 or not v4:
            continue
        m0, s0, n0 = st(v0)
        m4, s4, n4 = st(v4)
        lev = m0 - m4
        se = math.sqrt(s0 * s0 / n0 + s4 * s4 / n4)
        verdict = "resolved" if se > 0 and abs(lev) > 2 * se else "NOT resolved"
        label = "edge (f->0)" if src == "edge" else ("f = %.2f" % f)
        print("%-7g %-14s %-9.3f %-9.3f %+.3f+-%.3f  %s" % (k, label, m0, m4, lev, se, verdict))
    print()

# Monotonicity: does leverage fall as the sources concentrate?
print("Is leverage monotonic in source distribution (most -> least distributed)?")
for k in ks:
    seq = []
    for src, f in keys:
        v0 = [r[5] for r in rows if r[0] == k and r[2] == src and r[3] == f and r[1] == 0.0]
        v4 = [r[5] for r in rows if r[0] == k and r[2] == src and r[3] == f and r[1] == 4.0]
        if v0 and v4:
            seq.append(st(v0)[0] - st(v4)[0])
    if len(seq) < 3:
        continue
    drops = sum(1 for a, b in zip(seq, seq[1:]) if b <= a)
    print("  k=%-5g %s   (%d of %d steps non-increasing)"
          % (k, " -> ".join("%+.3f" % s for s in seq), drops, len(seq) - 1))
