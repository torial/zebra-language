#!/usr/bin/env python
"""Validity oracle for a single generated Zebra program.

For each program:
  1. Emit Zig via zebra.exe.
  2. Classify:
       crash-B               — the compiler errored/panicked (a TIMEOUT in the detail
                               is a HANG; a panic marker is a CRASH; anything else is
                               a refusal, which is expected for grammar-valid garbage)
       zig-fail              — an emit that `zig` rejects (usually a generator-quality
                               issue; bucketed separately)
       ok                    — an emit that `zig` accepts (and runs, with run=True)

Until 2026-09-16 this was a DIFFERENTIAL oracle: the same program went through the
Zig-implemented bootstrap (zebra-bootstrap.exe) as compiler A and the selfhost as
compiler B, and the verdicts crash-A / emit-divergence / zig-diverge-A / run-divergence
named the two disagreeing. The bootstrap was retired (docs/design/bootstrap_sunset.md
Step 3); the B-side verdict names are kept so fuzz/gramgen.py's classifier reads the
same, and the A-side ones can no longer occur.

Runs from the zebra-language root so the emitted-Zig preamble path resolves.
Deterministic: same program in, same verdict out.
"""
import os, subprocess, tempfile, hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SELF = ROOT / 'zig-out' / 'bin' / ('zebra.exe' if os.name == 'nt' else 'zebra')
ZIG  = os.environ.get('ZIG', r'C:\Users\Sean\.zvm\bin\zig.exe')
WORK = Path(os.environ.get('FUZZ_WORK', str(ROOT / '.fuzz_tmp')))
WORK.mkdir(exist_ok=True)
TIMEOUT = 20


class Result:
    def __init__(self, verdict, detail='', a='', b=''):
        self.verdict = verdict      # ok | emit-divergence | crash-A | crash-B | both-crash | zig-fail
        self.detail = detail
        self.a = a                  # unused since 2026-09-16 (was the bootstrap's emit)
        self.b = b                  # emitted zig
    def __repr__(self):
        return f'<{self.verdict}: {self.detail[:60]}>'


def _emit(compiler, zbr_path, out_dir, mode):
    """Emit Zig via `compiler`. mode='outdir': `--emit-zig --output-dir D zbr` →
    D/<stem>.zig. (mode='stdout' was the bootstrap's shape; a stdout redirect of the
    selfhost writes the ROOT only, BUG-317, so never use it here.)
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
    # The equivalence checks that survive the bootstrap sunset: the compiler does not
    # crash or hang; the emit compiles with `zig`; and (run=True) the built program
    # runs. `b` carries the emit so callers that diff it still work.
    h = hashlib.sha1(zbr_src.encode()).hexdigest()[:10]
    zbr = WORK / f'{tag}_{h}.zbr'
    zbr.write_text(zbr_src, encoding='utf-8', newline='\n')
    bo, bz, berr = _emit(SELF, zbr, WORK / f'b_{h}', 'outdir')
    if not bo:
        return Result('crash-B', berr)
    if not zig_check:
        return Result('ok', b=bz)
    cb, artB, eb = _zig_build(bz, tag + 'B', exe=run)
    if not cb:
        return Result('zig-fail', f'emit rejected by zig: {eb[:120]}', b=bz)
    if run:
        rb, outB, codeB = _run(artB)
        if not rb:
            return Result('run-hang', f'B:(code={codeB},out={outB[:40]!r})', b=bz)
    return Result('ok', b=bz)


def _first_diff(a, b):
    la, lb = a.splitlines(), b.splitlines()
    for i in range(min(len(la), lb.__len__())):
        if la[i] != lb[i]:
            return f'line {i+1}: A={la[i].strip()[:50]!r} B={lb[i].strip()[:50]!r}'
    return f'length A={len(la)} B={len(lb)}'
