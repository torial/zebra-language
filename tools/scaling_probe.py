#!/usr/bin/env python
"""scaling_probe.py — selfhost vs bootstrap compile-time vs program size.

Generates VALID Zebra programs of controlled size N in several shapes (each stressing
a different algorithmic dimension) and times `--emit-zig` (front-end + codegen, no zig
compile) for both compilers. Reports time-vs-N and the doubling-ratio: ~2x per
size-doubling = linear, ~4x = quadratic.

Baseline (2026-07-23): the selfhost is LINEAR and 2-10x faster than the bootstrap on
breadth/stmts/classes — there is no super-linear blowup on program size. (The old
main.zbr >120s self-compile was fixed by the SS28a step-2 inference work, not a general
scaling issue.) Use this to catch a future O(n^2) regression: if any shape's selfhost
ratio starts sitting at ~4x per doubling, something regressed.

Known deep-nesting crash (see BUGS.md BUG-200): the `exprlen` shape stack-overflows both
compilers past ~400-1000 terms — a recursive AST tree-walk with no depth guard, not a
scaling problem. Low priority (no hand-written expression is that deep).

Usage:  python tools/scaling_probe.py [shape ...]   # default: all shapes
Requires zig-out/bin/zebra.exe + zebra-bootstrap.exe built.
"""
import subprocess, time, sys, os, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SELF = ROOT / 'zig-out' / 'bin' / 'zebra.exe'
BOOT = ROOT / 'zig-out' / 'bin' / 'zebra-bootstrap.exe'
WORK = Path(tempfile.gettempdir()) / 'zbr-scaling'
WORK.mkdir(parents=True, exist_ok=True)
(WORK / 'out').mkdir(exist_ok=True)

def gen_breadth(n):   # N sibling methods — per-decl work
    b = 'class C\n'
    for i in range(n):
        b += f'    def f{i}(): int\n        return {i}\n'
    return b + 'class Program\n    static\n        def main\n            print("ok")\n'

def gen_stmts(n):     # N dependent local vars — per-statement resolve/infer + scope lookup
    b = 'class Program\n    static\n        def main\n            var x0: int = 0\n'
    for i in range(1, n):
        b += f'            var x{i}: int = x{i-1} + 1\n'
    return b + f'            print(x{n-1})\n'

def gen_exprlen(n):   # one N-term expression — tree-walk depth (see BUG-200)
    return ('class Program\n    static\n        def main\n'
            f'            var y: int = {" + ".join(["1"] * n)}\n            print(y)\n')

def gen_classes(n):   # N sibling top-level classes — per-class / module-decl scan
    b = ''
    for i in range(n):
        b += f'class K{i}\n    var v: int = {i}\n    def get(): int\n        return .v\n'
    return b + 'class Program\n    static\n        def main\n            print("ok")\n'

SHAPES = {'breadth': gen_breadth, 'stmts': gen_stmts,
          'exprlen': gen_exprlen, 'classes': gen_classes}

def time_emit(compiler, zbr, is_boot):
    if is_boot:
        argv, out = [str(compiler), '--emit-zig', str(zbr)], open(WORK / 'b.zig', 'w')
    else:
        argv = [str(compiler), '--emit-zig', str(zbr), '--output-dir', str(WORK / 'out')]
        out = subprocess.DEVNULL
    t0 = time.perf_counter()
    try:
        p = subprocess.run(argv, stdout=out, stderr=subprocess.DEVNULL, cwd=str(ROOT), timeout=120)
        dt, ok = time.perf_counter() - t0, (p.returncode == 0)
    except subprocess.TimeoutExpired:
        dt, ok = float('inf'), False
    if is_boot:
        out.close()
    return dt, ok

def run(shape, sizes):
    gen = SHAPES[shape]
    print(f'\n=== shape: {shape} ===')
    print(f'{"N":>6} | {"selfhost":>10} {"ratio":>6} | {"bootstrap":>10} {"ratio":>6} | self/boot')
    ps = pb = None
    for n in sizes:
        zbr = WORK / f'{shape}_{n}.zbr'
        zbr.write_text(gen(n), encoding='utf-8', newline='\n')
        ds, oks = time_emit(SELF, zbr, False)
        db, okb = time_emit(BOOT, zbr, True)
        rs = f'{ds/ps:.1f}x' if ps and ds != float("inf") else '   -'
        rb = f'{db/pb:.1f}x' if pb and db != float("inf") else '   -'
        ratio = f'{ds/db:.1f}x' if db > 0 and ds != float("inf") else '  -'
        flags = ('' if oks else ' SELF-FAIL') + ('' if okb else ' BOOT-FAIL')
        print(f'{n:>6} | {ds*1000:>8.0f}ms {rs:>6} | {db*1000:>8.0f}ms {rb:>6} | {ratio:>6}{flags}')
        ps, pb = ds, db

if __name__ == '__main__':
    print(f'selfhost={SELF.name}  bootstrap={BOOT.name}  (times = --emit-zig wall-clock)')
    for sh in (sys.argv[1:] or list(SHAPES)):
        run(sh, [25, 50, 100, 200, 400, 800])
