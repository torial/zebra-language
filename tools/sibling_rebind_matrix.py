"""THE SIBLING-REBINDING MATRIX (BUG-583) -- a report tool, not a gate.

One name bound at two sites in SIBLING blocks of one function, every ordered pair of eight
binding forms (a typed `var` of int / str / List / float, a tuple destructure, an
`is ... as x` capture, a for-in variable, a `branch` arm binding): 64 programs, each built and
run. Each prints `A:<site i>` then `B:<site j>`, and the expected output is derived by
CONSTRUCTION, never recorded from the compiler. Exits 1 on any BAD pair, 2 if the program
count is wrong (a collapsed generator must not read as a clean run).

    python tools/sibling_rebind_matrix.py [path/to/zebra]

Receipt: on the compiler before BUG-583's fix it reported 7 BAD of 64 (int<->destructure,
str->List, the `is ... as x` capture), 0 after. Pattern search 3's original matrix (3,000
programs, 30 type pairs) found the class; this is its distilled, re-runnable core.
"""
import os, subprocess, sys, pathlib, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zig_pin  # noqa: E402
zig_pin.apply()   # the PINNED zig for every program this builds (hazard_lint H14)
REPO = pathlib.Path(__file__).resolve().parent.parent

SITES = [  # (name, code lines binding x and printing it with the given tag, expected render)
    ("int",     ['var x: int = 5', 'print("{T}:${{x}}")'], "5"),
    ("str",     ['var x: str = "ab"', 'print("{T}:${{x}}")'], "ab"),
    ("list",    ['var x: List(int) = [1, 2]', 'print("{T}:${{x}}")'], "[1, 2]"),
    ("float",   ['var x: float = 1.5', 'print("{T}:${{x}}")'], "1.5"),
    ("destr",   ['var (x, z) = ("cd", 0)', 'print("{T}:${{x}}${{z}}")'], "cd0"),
    ("iscap",   None, "ef"),   # its own if-header
    ("forin",   None, "gh"),
    ("branch",  None, "ef"),
]

def block(site, tag):
    name, lines, _ = site
    if name == "iscap":
        return ['    if u is U.v as x', '        print("%s:${x}")' % tag]
    if name == "forin":
        return ['    for x in ["gh"]', '        print("%s:${x}")' % tag]
    if name == "branch":
        return ['    if c > 0', '        branch u', '            on U.v as x',
                '                print("%s:${x}")' % tag, '            on U.n as nn', '                print("%s:${nn}")' % tag]
    return ['    if c > 0'] + ['        ' + l.format(T=tag) for l in lines]

def program(a, b):
    src = ['union U', '    v: str', '    n: int', '', 'def main()', '    var c = 1', '    var u = U.v("ef")']
    src += block(a, "A") + block(b, "B")
    return '\n'.join(src) + '\n'

def main():
    default = REPO / "zig" "-out" / "bin" / ("zebra.exe" if os.name == "nt" else "zebra")
    zebra = sys.argv[1] if len(sys.argv) > 1 else str(default)
    work = pathlib.Path(tempfile.mkdtemp(prefix="zbr_sibling_"))
    bad = []
    n = 0
    for a in SITES:
        for b in SITES:
            n += 1
            f = work / f"zz583_{a[0]}_{b[0]}.zbr"
            f.write_text(program(a, b), encoding='utf-8', newline='\n')
            want = f"A:{a[2]}\nB:{b[2]}"
            try:
                p = subprocess.run([zebra, str(f)], capture_output=True, text=True, timeout=180)
                out = [l for l in p.stdout.splitlines() if l.startswith(("A:", "B:"))]
                got = "\n".join(out)
            except subprocess.TimeoutExpired:
                got = "TIMEOUT"
            if got != want:
                err = (p.stdout + p.stderr).strip().splitlines()
                first = next((l for l in err if 'error' in l), err[-1] if err else '')
                bad.append(f"{a[0]}->{b[0]}: {first[:110]}")
    for line in bad:
        print("BAD", line)
    print(f"[m583] {n} programs, {len(bad)} BAD")
    if n != len(SITES) ** 2:
        print("REFUSING: wrong program count"); sys.exit(2)
    sys.exit(1 if bad else 0)

main()
