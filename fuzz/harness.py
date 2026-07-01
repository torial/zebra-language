#!/usr/bin/env python
"""Differential + validity oracle for a single generated Zebra program.

For each program:
  1. Emit Zig via the Zig-implemented compiler  (zebra-bootstrap.exe)
  2. Emit Zig via the Zebra-implemented compiler (zebra.exe, the selfhost)
  3. Classify:
       crash-A / crash-B     — one compiler errored/panicked, exposing a bug
       emit-divergence       — both emitted, but the Zig differs (THE key finding:
                               a self-hosting equivalence bug)
       zig-fail              — identical emit that `zig` rejects (usually a
                               generator-quality issue; bucketed separately)
       ok                    — identical emit that `zig` accepts

Runs from the zebra-language root so the emitted-Zig preamble path resolves.
Deterministic: same program in, same verdict out.
"""
import os, subprocess, tempfile, hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BOOT = ROOT / 'zig-out' / 'bin' / 'zebra-bootstrap.exe'
SELF = ROOT / 'zig-out' / 'bin' / 'zebra.exe'
ZIG  = os.environ.get('ZIG', r'C:\Users\Sean\.zvm\bin\zig.exe')
WORK = Path(os.environ.get('FUZZ_WORK', str(ROOT / '.fuzz_tmp')))
WORK.mkdir(exist_ok=True)
TIMEOUT = 20


class Result:
    def __init__(self, verdict, detail='', a='', b=''):
        self.verdict = verdict      # ok | emit-divergence | crash-A | crash-B | both-crash | zig-fail
        self.detail = detail
        self.a = a                  # emitted zig (bootstrap)
        self.b = b                  # emitted zig (selfhost)
    def __repr__(self):
        return f'<{self.verdict}: {self.detail[:60]}>'


def _emit(compiler, zbr_path, out_dir, mode):
    """Emit Zig via `compiler`. The two compilers differ in emit CLI:
       mode='stdout'  (bootstrap): `--emit-zig zbr`           → Zig on stdout
       mode='outdir'  (selfhost) : `--emit-zig --output-dir D zbr` → D/<stem>.zig
    Return (ok, zig_text, err)."""
    if mode == 'stdout':
        argv = [str(compiler), '--emit-zig', str(zbr_path)]
    else:
        out_dir.mkdir(parents=True, exist_ok=True)
        argv = [str(compiler), '--emit-zig', '--output-dir', str(out_dir), str(zbr_path)]
    try:
        p = subprocess.run(argv, cwd=str(ROOT), capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return (False, '', 'TIMEOUT')
    if p.returncode != 0:
        return (False, '', (p.stderr or p.stdout or f'exit {p.returncode}')[-400:])
    if mode == 'stdout':
        if not p.stdout.strip():
            return (False, '', (p.stderr or 'empty stdout')[-400:])
        return (True, p.stdout, '')
    zig_file = out_dir / f'{zbr_path.stem}.zig'
    if not zig_file.exists():
        return (False, '', (p.stderr or 'no output file')[-400:])
    return (True, zig_file.read_text(encoding='utf-8', errors='replace'), '')


def _zig_build(zig_text, tag, exe=False):
    """Compile the emitted module.  `exe=False` → `build-obj` (fast: semantic check,
    no linking, no run — enough for the validity differential that caught BUG-159).
    `exe=True` → `build-exe` (needed to run + compare output).
    Return (compiled, artifact_path_or_None, err)."""
    d = WORK / f'zc_{tag}'
    d.mkdir(parents=True, exist_ok=True)
    (d / 'm.zig').write_text(zig_text, encoding='utf-8', newline='\n')
    art = d / ('m.exe' if exe else 'm.o')
    cmd = 'build-exe' if exe else 'build-obj'
    try:
        p = subprocess.run([ZIG, cmd, 'm.zig', '-femit-bin=' + art.name],
                           cwd=str(d), capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        return (False, None, 'zig TIMEOUT')
    if p.returncode != 0 or not art.exists():
        return (False, None, (p.stderr or '')[-400:])
    return (True, art, '')


def _run(exe):
    """Run the built program.  Return (ran, output, code)."""
    try:
        p = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
        return (True, p.stdout, p.returncode)
    except subprocess.TimeoutExpired:
        return (False, 'TIMEOUT', -1)


def check(zbr_src, tag='t', zig_check=True, run=False):
    # The two compilers embed cosmetically-different preambles, so a byte-identical
    # *emit* comparison is confounded.  The real equivalence checks are: neither
    # compiler crashes; each emit compiles with `zig`; and (when zig_check) both
    # built programs produce the same output — a run-divergence is a semantic
    # self-hosting bug immune to emit-format cosmetics.
    h = hashlib.sha1(zbr_src.encode()).hexdigest()[:10]
    zbr = WORK / f'{tag}_{h}.zbr'
    zbr.write_text(zbr_src, encoding='utf-8', newline='\n')
    ao, az, aerr = _emit(BOOT, zbr, WORK / f'a_{h}', 'stdout')
    bo, bz, berr = _emit(SELF, zbr, WORK / f'b_{h}', 'outdir')
    if not ao and not bo:
        return Result('both-reject', f'A:{aerr[:70]} | B:{berr[:70]}')
    if not ao:
        return Result('crash-A', aerr, b=bz)
    if not bo:
        return Result('crash-B', berr, a=az)
    if not zig_check:
        return Result('ok', a=az)
    ca, artA, ea = _zig_build(az, tag + 'A', exe=run)
    cb, artB, eb = _zig_build(bz, tag + 'B', exe=run)
    if ca and not cb:
        return Result('zig-diverge-B', f'selfhost emit rejected by zig: {eb[:120]}', a=az, b=bz)
    if cb and not ca:
        return Result('zig-diverge-A', f'bootstrap emit rejected by zig: {ea[:120]}', a=az, b=bz)
    if not ca and not cb:
        return Result('both-zig-fail', (ea or eb)[:120], a=az)
    if run:
        ra, outA, codeA = _run(artA)
        rb, outB, codeB = _run(artB)
        if (outA, codeA) != (outB, codeB):
            return Result('run-divergence',
                          f'A:(code={codeA},out={outA[:40]!r}) B:(code={codeB},out={outB[:40]!r})', a=az, b=bz)
    return Result('ok', a=az)


def _first_diff(a, b):
    la, lb = a.splitlines(), b.splitlines()
    for i in range(min(len(la), lb.__len__())):
        if la[i] != lb[i]:
            return f'line {i+1}: A={la[i].strip()[:50]!r} B={lb[i].strip()[:50]!r}'
    return f'length A={len(la)} B={len(lb)}'
