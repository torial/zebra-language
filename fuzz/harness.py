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


def _emit(compiler, zbr_path, out_dir):
    """Run `compiler --emit-zig zbr --output-dir out_dir`. Return (ok, zig_text, err)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        p = subprocess.run(
            [str(compiler), '--emit-zig', '--output-dir', str(out_dir), str(zbr_path)],
            cwd=str(ROOT), capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return (False, '', 'TIMEOUT')
    stem = zbr_path.stem
    zig_file = out_dir / f'{stem}.zig'
    if p.returncode != 0 or not zig_file.exists():
        return (False, '', (p.stderr or p.stdout or f'exit {p.returncode}')[-400:])
    return (True, zig_file.read_text(encoding='utf-8', errors='replace'), '')


def _zig_ok(zig_text, tag):
    """True if `zig` accepts the emitted module (build-obj, no run)."""
    d = WORK / f'zc_{tag}'
    d.mkdir(parents=True, exist_ok=True)
    f = d / 'm.zig'
    f.write_text(zig_text, encoding='utf-8', newline='\n')
    try:
        p = subprocess.run([ZIG, 'build-obj', str(f), '-femit-bin=' + str(d / 'm.o')],
                           cwd=str(d), capture_output=True, text=True, timeout=60)
        return (p.returncode == 0, (p.stderr or '')[-400:])
    except subprocess.TimeoutExpired:
        return (False, 'zig TIMEOUT')


def check(zbr_src, tag='t', zig_check=True):
    h = hashlib.sha1(zbr_src.encode()).hexdigest()[:10]
    zbr = WORK / f'{tag}_{h}.zbr'
    zbr.write_text(zbr_src, encoding='utf-8', newline='\n')
    ao, az, aerr = _emit(BOOT, zbr, WORK / f'a_{h}')
    bo, bz, berr = _emit(SELF, zbr, WORK / f'b_{h}')
    if not ao and not bo:
        return Result('both-reject', f'A:{aerr[:80]} | B:{berr[:80]}')
    if not ao:
        return Result('crash-A', aerr, b=bz)
    if not bo:
        return Result('crash-B', berr, a=az)
    if az != bz:
        return Result('emit-divergence', _first_diff(az, bz), a=az, b=bz)
    if zig_check:
        ok, zerr = _zig_ok(az, tag)
        if not ok:
            return Result('zig-fail', zerr, a=az)
    return Result('ok', a=az)


def _first_diff(a, b):
    la, lb = a.splitlines(), b.splitlines()
    for i in range(min(len(la), lb.__len__())):
        if la[i] != lb[i]:
            return f'line {i+1}: A={la[i].strip()[:50]!r} B={lb[i].strip()[:50]!r}'
    return f'length A={len(la)} B={len(lb)}'
