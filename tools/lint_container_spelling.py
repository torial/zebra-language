#!/usr/bin/env python3
"""THE CONTAINER-SPELLING LINT (BUG-501 Phase 0), registered as `container-spelling` (STATIC).

docs/design/container_reference_semantics.md §4: emitted code names a Zebra container ONLY
through the runtime's `_ZbrList(T)` / `_ZbrMap(V)` / `_ZbrAutoMap(K, V)`. Phase 1 (containers
become references) then changes those definitions and the constructors rather than every
emit site -- which only works if no emit site spells the Zig type itself. This lint fails on
a string literal in selfhost/*.zbr containing `std.ArrayList(`, `std.StringHashMap(` or
`_zbr_AutoMap(`. Comment lines are skipped (history may name the old spelling).

CONTROLS, before the scan: a planted raw spelling must be found and the new spelling must not
be; and CodeGen.zbr must carry at least FLOOR `_ZbrList(` literals -- fewer means the scan or
the file changed shape, and a scan that sees nothing must not print clean (exit 2).

CANNOT SEE: a spelling assembled from pieces (`"std." + "ArrayList("`), and Zig the runtime
itself contains (selfhost/stdlib_preamble.zig is the runtime; its internal uses are its own).
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ("std.ArrayList(", "std.StringHashMap(", "_zbr_AutoMap(")
STR = re.compile(r'"(?:[^"\\\n]|\\.)*"')
FLOOR = 25


def hits(text):
    out = []
    for no, line in enumerate(text.split("\n"), 1):
        if line.lstrip().startswith("#"):
            continue
        for lit in STR.findall(line):
            for raw in RAW:
                if raw in lit:
                    out.append((no, raw, line.strip()))
    return out


def main():
    planted = 'w.emit("std.ArrayList(")\n# std.ArrayList( in a comment\nw.emit("_ZbrList(")\n'
    got = hits(planted)
    if len(got) != 1 or got[0][0] != 1:
        print(f"[container-spelling] REFUSING: control misclassified the planted text ({got})")
        return 2
    cg = (ROOT / "selfhost" / "CodeGen.zbr").read_text(encoding="utf-8")
    n_new = sum(lit.count("_ZbrList(") for lit in STR.findall(cg))
    if n_new < FLOOR:
        print(f"[container-spelling] REFUSING: only {n_new} `_ZbrList(` literal(s) in CodeGen.zbr "
              f"(floor {FLOOR}) -- the scan or the file changed shape")
        return 2
    bad = []
    files = sorted((ROOT / "selfhost").glob("*.zbr"))
    for f in files:
        for no, raw, line in hits(f.read_text(encoding="utf-8")):
            bad.append(f"  {f.relative_to(ROOT).as_posix()}:{no}: `{raw}` -- {line[:100]}")
    if bad:
        print(f"[container-spelling] {len(bad)} raw container spelling(s) in emitting code "
              f"(use _ZbrList / _ZbrMap / _ZbrAutoMap):")
        print("\n".join(bad))
        return 1
    print(f"[container-spelling] 0 raw spellings across {len(files)} file(s); "
          f"{n_new} `_ZbrList(` literal(s) in CodeGen.zbr")
    return 0


if __name__ == "__main__":
    sys.exit(main())
