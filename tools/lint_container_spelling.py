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

PHASE 1a (2026-10-01): it also refuses a CONSTRUCTION spelled in place -- `.empty` /
`.init(_allocator)` in an emitted literal -- since every Zebra-visible construction goes
through the runtime's `_zbr_new(C)`, the one function the flip changes. `_ZbrScratch` (a list
never handed to Zebra code), ArenaAllocator, and a line marked `container-spelling-ok:
<reason>` are exempt. Red-checked by reverting one `_zbr_new` site.

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


# BUG-501 Phase 1a: a CONSTRUCTION spelled in place -- `.empty` / `.init(_allocator)` in an
# emitted literal -- bypasses `_zbr_new(C)`, the one constructor the flip changes. Allowed:
# an ArenaAllocator init, `_ZbrScratch` (scratch never handed to Zebra), and a line carrying
# `container-spelling-ok: <reason>` (the reason is required).
CTOR = (".empty", ".init(_allocator)")
CTOR_OK = ("ArenaAllocator", "_ZbrScratch")


def hits(text):
    out = []
    for no, line in enumerate(text.split("\n"), 1):
        if line.lstrip().startswith("#"):
            continue
        ok_marked = "container-spelling-ok:" in line and len(line.split("container-spelling-ok:", 1)[1].strip()) > 0
        for lit in STR.findall(line):
            for raw in RAW:
                if raw in lit:
                    out.append((no, raw, line.strip()))
            if not ok_marked and not any(k in lit for k in CTOR_OK):
                for c in CTOR:
                    if c in lit:
                        out.append((no, c, line.strip()))
    return out


def main():
    planted = ('w.emit("std.ArrayList(")\n# std.ArrayList( in a comment\nw.emit("_ZbrList(")\n'
               'w.emit(").empty")\n'
               'w.emit(".empty")   # container-spelling-ok: a reason\n'
               'w.emit("_ZbrScratch(u8).empty")\n')
    got = hits(planted)
    if len(got) != 2 or got[0][0] != 1 or got[1][0] != 4:
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
              f"(spell the type _ZbrList / _ZbrMap / _ZbrAutoMap; construct it with _zbr_new(C); "
              f"a deliberate exception carries `# container-spelling-ok: <reason>`):")
        print("\n".join(bad))
        return 1
    print(f"[container-spelling] 0 raw spellings across {len(files)} file(s); "
          f"{n_new} `_ZbrList(` literal(s) in CodeGen.zbr")
    return 0


if __name__ == "__main__":
    sys.exit(main())
