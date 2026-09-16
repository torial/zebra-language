"""Triage BUG-253's parity candidates by EXPERIMENT, not by the matcher.

The parity tool lists messages, not programs. So for each candidate a minimal program is
written that should trigger it, and BOTH compilers are run:

    bootstrap rejects + selfhost accepts  -> REAL GAP        (port it)
    both reject                           -> matcher artifact (already present, reworded)
    both accept                           -> probe is wrong  (my repro missed the case)
    bootstrap accepts + selfhost rejects  -> SELFHOST LEADS  (do NOT port)

The last column is the one that matters most and the reason this cannot be automated from
the message text alone: BUG-254 already proved "missing from the selfhost" can mean the
selfhost is RIGHT.

`-c` is used for the selfhost (front-end only, which is what a front-end diagnostic is) and
--emit-zig for the bootstrap. A probe that neither compiler rejects tells us nothing about
parity -- it tells us the probe failed to reproduce, which is recorded rather than hidden.
"""
import pathlib
import subprocess
import sys

REPO = pathlib.Path(r"C:\Projects\zebra-language")
Z = REPO / "zig-out" / "bin" / "zebra.exe"
B = REPO / "zig-out" / "bin" / "zebra-bootstrap.exe"
WORK = pathlib.Path(r"C:\tmp\tri")
WORK.mkdir(parents=True, exist_ok=True)

PROBES = {
 "if_as_nonoptional": 'def main()\n    var x = 5\n    if x as n\n        print(n.toString())\n',
 "unary_minus_str":   'def main()\n    var s = "a"\n    var y = -s\n    print(y)\n',
 "compound_assign":   'def main()\n    var s = "a"\n    s += 1\n    print(s)\n',
 "destructure_arity": 'def main()\n    var t = (1, 2, 3)\n    var (a, b) = t\n    print(a.toString() + b.toString())\n',
 "destructure_nontuple": 'def main()\n    var z = 5\n    var (a, b) = z\n    print(a.toString())\n',
 "tuple_index_oob":   'def main()\n    var t = (1, 2)\n    print(t.5.toString())\n',
 "bitwise_float":     'def main()\n    var a = 1.5\n    var b = a & 2\n    print(b.toString())\n',
 "bitwise_not_float": 'def main()\n    var a = 1.5\n    var b = ~a\n    print(b.toString())\n',
 "arith_same_type":   'def main()\n    var a: int = 1\n    var b: float = 2.0\n    print((a + b).toString())\n',
}


def run(exe, args, path):
    try:
        r = subprocess.run([str(exe)] + args + [str(path)], capture_output=True,
                           cwd=str(WORK), timeout=240)
    except subprocess.TimeoutExpired:
        return None
    txt = (r.stdout + r.stderr).decode("utf-8", "replace")
    return [l.strip() for l in txt.split("\n") if "error" in l.lower()]


def main():
    if not Z.is_file() or not B.is_file():
        print("REFUSING TO REPORT: one of the compilers is not built.")
        return 2
    rows = []
    for name, src in PROBES.items():
        f = WORK / f"{name}.zbr"
        f.write_text(src, encoding="utf-8", newline="\n")   # LF only: CRLF crashes the lexer
        be = run(B, ["--emit-zig"], f)
        se = run(Z, ["-c"], f)
        if be is None or se is None:
            verdict, detail = "TIMEOUT", ""
        elif be and not se:
            verdict, detail = "** REAL GAP **", be[0][-70:]
        elif be and se:
            verdict, detail = "both reject", se[0][-58:]
        elif not be and se:
            verdict, detail = "SELFHOST LEADS", se[0][-58:]
        else:
            verdict, detail = "probe did not repro", ""
        rows.append((name, verdict, detail))

    w = max(len(n) for n, _, _ in rows)
    for n, v, d in rows:
        print(f"  {n:<{w}}  {v:<20} {d}")
    gaps = sum(1 for _, v, _ in rows if "REAL GAP" in v)
    print(f"\n{len(rows)} probes: {gaps} real gap(s), "
          f"{sum(1 for _,v,_ in rows if v=='both reject')} already present, "
          f"{sum(1 for _,v,_ in rows if v=='SELFHOST LEADS')} selfhost-leads, "
          f"{sum(1 for _,v,_ in rows if v=='probe did not repro')} inconclusive")
    return 0


if __name__ == "__main__":
    sys.exit(main())
