#!/usr/bin/env python3
"""v_engine_check.py -- the game engine's headless tests through the V target
(2026-10-15). Every test root build.zig names (tools/affected_tests.py's
table) whose root is a Zebra source: emitted from the engine root with
--module-path zbra, the .v moved OUT of the engine tree at once, built by V,
run from the engine root, its stdout diffed against the Zig-built test's
(`zig build run-<name>`, taken only when the V side built). A root whose .zig
has no .zbr beside it is a host test, not a Zebra program: counted, never
guessed. Refusals and V errors are ranked by the roots they touch, so the
next emitter cut is the one that unblocks the most.

  python tools/v_engine_check.py [--only name,name] [--limit N] [--skip-controls]
  ENGINE=C:/Projects/GameEngine  ZEBRA=<zebra.exe>  V=<v.exe>  OUT=<dir>
Exit 0 when every Zebra root is identical; 1 otherwise (the report says why).
"""
import os, re, subprocess, sys, time, shutil, argparse, collections

ENGINE = os.environ.get('ENGINE', 'C:/Projects/GameEngine')
HERE = os.path.dirname(os.path.abspath(__file__))
ZEBRA = os.environ.get('ZEBRA', os.path.join(HERE, '..', 'zig-out', 'bin', 'zebra.exe'))   # hazard-ok:H14 it builds the ENGINE with the engine's own toolchain (pinned 0.16 there); the repo pin would be the wrong zig
V = os.environ.get('V', 'C:/Projects/v-dist/v/v.exe')
# Per-CHECKOUT scratch, as tools/scratch_paths.sh does for the shell gates (BUG-521): main and
# the v-backend worktree both carry this tool, and one fixed C:/tmp path let two runs clobber
# each other's emits and builds (hazard_lint H12).
import hashlib, tempfile  # noqa: E402
_CHECKOUT = os.path.realpath(os.path.join(HERE, '..'))
OUT = os.environ.get('OUT', os.path.join(tempfile.gettempdir(), 'v_engine_check-' + hashlib.md5(_CHECKOUT.encode()).hexdigest()[:8]))
sys.path.insert(0, os.path.join(ENGINE, 'tools'))
import affected_tests  # noqa: E402

def run(cmd, cwd, timeout=600):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, encoding='utf-8', errors='replace')
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -9, '', 'TIMEOUT'

def norm_refusal(line):
    # "    sys.spawnPiped (src/transport.zbr:25) [in start: stubbed]" -> "sys.spawnPiped"
    s = line.strip()
    s = re.sub(r' \([^)]*:\d+\)', '', s)
    s = re.sub(r' \[in [^\]]*\]', '', s)
    return s

def norm_verr(line):
    m = re.match(r'^[^ ]+:\d+:\d+: error: (.*)$', line)
    if not m:
        return None
    s = m.group(1)
    s = re.sub(r'`[^`]*`', 'X', s)
    return s

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only', default='')
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--skip-controls', action='store_true')
    a = ap.parse_args()
    if not os.path.isfile(ZEBRA):
        print(f'v_engine_check: no compiler at {ZEBRA}'); return 2
    os.makedirs(OUT, exist_ok=True)
    text = affected_tests.read(os.path.join(ENGINE, 'build.zig'))
    _, _, tests = affected_tests.parse_build(text)
    names = sorted(tests)
    if a.only:
        names = [n for n in names if n in set(a.only.split(','))]
    if a.limit:
        names = names[:a.limit]
    status = {}
    refusals = collections.Counter(); refusal_roots = collections.defaultdict(list)
    verrs = collections.Counter(); verr_roots = collections.defaultdict(list)
    host = []
    t0 = time.time()
    for i, name in enumerate(names):
        root_zig = tests[name]
        root_zbr = root_zig[:-4] + '.zbr'
        if not os.path.isfile(os.path.join(ENGINE, root_zbr)):
            host.append(name); status[name] = 'host'
            continue
        stem = os.path.basename(root_zbr)[:-4]
        emitted = os.path.join(ENGINE, os.path.dirname(root_zbr), stem + ('_prog.v' if stem.endswith('_test') else '.v'))
        rc, so, se = run([ZEBRA, '--target', 'v', '--module-path', 'zbra', root_zbr], ENGINE, 300)
        log = so + se
        vfile = os.path.join(OUT, stem + '_prog.v')
        if os.path.isfile(emitted):
            shutil.move(emitted, vfile)
        else:
            status[name] = 'emit-failed'
            with open(os.path.join(OUT, stem + '_emit.txt'), 'w', encoding='utf-8') as f: f.write(log)
            print(f'[{i+1}/{len(names)}] {name}: EMIT FAILED'); continue
        refs = [norm_refusal(l) for l in log.splitlines() if l.startswith('    ')]
        if refs:
            status[name] = 'refused'
            for r in sorted(set(refs)):
                refusals[r] += 1; refusal_roots[r].append(name)
            print(f'[{i+1}/{len(names)}] {name}: refused {len(set(refs))} kind(s)'); continue
        exe = os.path.join(OUT, stem + '.exe')
        if os.path.isfile(exe): os.remove(exe)
        rc, so, se = run([V, '-gc', 'none', '-enable-globals', '-o', exe, vfile], OUT, 900)
        errs = [norm_verr(l) for l in (so + se).splitlines()]
        errs = [e for e in errs if e]
        if errs or not os.path.isfile(exe):
            status[name] = 'vbuild'
            with open(os.path.join(OUT, stem + '_build.txt'), 'w', encoding='utf-8') as f: f.write(so + se)
            for e in sorted(set(errs)) or ['(no error line; no exe)']:
                verrs[e] += 1; verr_roots[e].append(name)
            print(f'[{i+1}/{len(names)}] {name}: V BUILD ({len(set(errs))} kind(s))'); continue
        rc, so, se = run([exe], ENGINE, 600)
        vout = so
        with open(os.path.join(OUT, stem + '_v_out.txt'), 'w', encoding='utf-8') as f: f.write(vout)
        with open(os.path.join(OUT, stem + '_v_err.txt'), 'w', encoding='utf-8') as f: f.write(se)
        if a.skip_controls:
            status[name] = 'ran' if rc == 0 else f'v-exit-{rc}'
            print(f'[{i+1}/{len(names)}] {name}: ran (exit {rc}, no control)'); continue
        crc, cso, cse = run(['zig', 'build', 'run-' + name], ENGINE, 900)
        if crc != 0 and 'no step named' in (cso + cse):
            # a root without a run-<name> step (the Tuon tests under test-tuon): the
            # executable the last `zig build test-*` left in the cache, newest first
            import glob
            cands = sorted(glob.glob(os.path.join(ENGINE, '.zig-cache', 'o', '*', name + '.exe')), key=os.path.getmtime, reverse=True)
            if cands:
                crc, cso, cse = run([cands[0]], ENGINE, 900)
                cso = cso + ('' if crc == 0 else '')
        with open(os.path.join(OUT, stem + '_control.txt'), 'w', encoding='utf-8') as f: f.write(cso)
        if crc != 0:
            status[name] = 'no-control'
            print(f'[{i+1}/{len(names)}] {name}: NO CONTROL (zig build run-{name} exit {crc})'); continue
        if rc != 0:
            status[name] = f'v-exit-{rc}'
            tail = (se.strip().splitlines() or [''])[-1][:120]
            print(f'[{i+1}/{len(names)}] {name}: V RUN exit {rc}: {tail}'); continue
        # a measured duration in a line ("laid X: N parts ... in 33 ms") is the
        # host's clock, not the program's: normalised on both sides
        def norm_out(t):
            return re.sub(r'\d+ ms', 'N ms', t)
        if norm_out(vout) == norm_out(cso):
            status[name] = 'identical'
            print(f'[{i+1}/{len(names)}] {name}: identical ({len(cso.splitlines())} lines)')
        else:
            status[name] = 'differs'
            import difflib
            dl = [l for l in difflib.unified_diff(norm_out(cso).splitlines(), norm_out(vout).splitlines(), 'zig', 'v', lineterm='', n=0) if not l.startswith(('---', '+++', '@@'))]
            print(f'[{i+1}/{len(names)}] {name}: DIFFERS ({len(dl)} lines) ' + ' | '.join(dl[:2])[:220])
    counts = collections.Counter(status.values())
    print(f'\nv_engine_check: {len(names)} roots in {int(time.time()-t0)} s --', ', '.join(f'{k} {v}' for k, v in sorted(counts.items())))
    print(f'  host tests (Zig roots, no .zbr): {len(host)}')
    if refusals:
        print('  refusals by roots touched:')
        for r, n in refusals.most_common(25):
            print(f'    {n:3d}  {r}   e.g. {", ".join(refusal_roots[r][:3])}')
    if verrs:
        print('  V build errors by roots touched:')
        for e, n in verrs.most_common(25):
            print(f'    {n:3d}  {e[:110]}   e.g. {", ".join(verr_roots[e][:3])}')
    for k in ('differs', 'no-control', 'emit-failed'):
        names_k = [n for n, s in status.items() if s == k]
        if names_k: print(f'  {k}: {", ".join(names_k)}')
    exits = [n for n, s in status.items() if s.startswith('v-exit')]
    if exits: print(f'  V run exits: {", ".join(exits)}')
    zebra_roots = [n for n in names if status.get(n) != 'host']
    return 0 if all(status[n] == 'identical' for n in zebra_roots) else 1

if __name__ == '__main__':
    sys.exit(main())
