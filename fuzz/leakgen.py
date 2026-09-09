#!/usr/bin/env python3
"""leakgen.py — THE "ZEBRA ACCEPTS, ZIG REJECTS" FUZZER (selfhost only).

The bug class: the front end accepts a program, codegen emits it, and `zig` refuses the
emit — so the user sees a ZIG diagnostic about code they never wrote. BUG-336, 337, 338,
339 and 354 are all this shape, and every one was found by a person writing an IDE, not by
a gate: `divergence`/`full_sweep` sweep a hand-written corpus, and `harness.py` is a
bootstrap-vs-selfhost differential that stopped being the question once the bootstrap froze.

What this does, per program:
  1. gen.py produces a WELL-FORMED program (type-aware; only in-scope names, typed exprs).
  2. The selfhost emits it (`--emit-zig --output-dir D`, so zebra_rt.zig lands beside it).
  3. `zig build-exe -fno-emit-bin -lc` on the emit.
Verdicts:
  reject   the selfhost refused it (a generator-quality issue OR a checker over-refusal;
           reported, counted, not a failure — gen.py's shapes are supposed to be legal)
  LEAK     the selfhost accepted, zig refused  ← the class. Signature = the zig message
           with names/numbers normalised, so one bug shape counts once.
  crash    the selfhost panicked (gramgen's territory; reported here because it is free)
  ok

Usage:
  python fuzz/leakgen.py -n 300 --seed 0          explore; prints unique LEAK signatures
                                                   and writes the smallest reproducer of
                                                   each to fuzz/findings/leakgen/
  python fuzz/leakgen.py --gate                    deterministic (fixed seeds); exit 1 on
                                                   any LEAK signature NOT in
                                                   fuzz/leak_baseline.txt, or any crash
  python fuzz/leakgen.py --gate --update-baseline  re-record the baseline (only after a
                                                   green run you have READ: every line in
                                                   it is a bug someone accepted)

The baseline is a list of signatures, one per line, each with the BUG number that owns it
(`# BUG-NNN` on the line). A signature with no ticket is not allowed in the baseline — a
leak nobody filed is a leak nobody will fix. Shrink it; do not grow it.

Cost: ~1.5 s per program (zig sema of a ~200-line module + the 4 k-line runtime). The gate
is 4 seeds x 25 programs = 100 programs, ~3 min; DAILY tier.
"""
import argparse, os, re, subprocess, sys, hashlib, shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'fuzz'))
import gen  # noqa: E402

def _find_zebra():
    for c in (ROOT / 'zig-out' / 'bin' / 'zebra', ROOT / 'zig-out' / 'bin' / 'zebra.exe'):
        if c.exists():
            return c
    return None

ZEBRA = _find_zebra()
ZIG = os.environ.get('ZIG', shutil.which('zig') or r'C:\Users\Sean\.zvm\bin\zig.exe')
WORK = Path(os.environ.get('FUZZ_WORK', str(ROOT / '.fuzz_tmp'))) / 'leakgen'
BASELINE = ROOT / 'fuzz' / 'leak_baseline.txt'
FINDINGS = ROOT / 'fuzz' / 'findings' / 'leakgen'
TIMEOUT_EMIT = 30
TIMEOUT_ZIG = 120

GATE_SEEDS = (11, 12, 13, 14)
GATE_N = 25


def emit(src, tag):
    d = WORK / tag
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    zbr = d / 'p.zbr'
    zbr.write_text(src, encoding='utf-8', newline='\n')
    try:
        p = subprocess.run([str(ZEBRA), '--emit-zig', '--output-dir', str(d), str(zbr)],
                           cwd=str(ROOT), capture_output=True, text=True, timeout=TIMEOUT_EMIT)
    except subprocess.TimeoutExpired:
        return ('crash', 'selfhost TIMEOUT', d)
    err = (p.stderr or '') + (p.stdout or '')
    if p.returncode != 0 or not (d / 'p.zig').exists():
        low = err.lower()
        if any(m in low for m in ('panic', 'internal compiler error', 'unreachable', 'segmentation')):
            return ('crash', err[-400:], d)
        # the selfhost's own diagnostic: `file:L:C: error: msg`
        m = re.search(r'error: (.*)', err)
        return ('reject', (m.group(1) if m else err[-200:]).strip(), d)
    return ('emitted', '', d)


def zig_check(d):
    try:
        p = subprocess.run([ZIG, 'build-exe', 'p.zig', '-fno-emit-bin', '-lc'],
                           cwd=str(d), capture_output=True, text=True, timeout=TIMEOUT_ZIG)
    except subprocess.TimeoutExpired:
        return (False, 'zig TIMEOUT')
    if p.returncode == 0:
        return (True, '')
    # first `error:` line is the one that matters; note-lines follow it
    lines = [l for l in (p.stderr or '').splitlines() if ' error: ' in l]
    return (False, lines[0] if lines else (p.stderr or '')[-300:])


def signature(msg):
    """Normalise a zig diagnostic so one bug shape dedups: drop paths and positions,
    collapse identifiers that carry generated numbers, collapse quoted names."""
    s = msg
    s = re.sub(r'^.*?p\.zig:\d+:\d+: ', '', s)
    # Quoted names are KEPT (a member name or a Zig type is what distinguishes one bug
    # shape from another -- "no field named 'at'" vs "'contains'" are different leaks);
    # only generated identifiers inside them are collapsed.
    s = re.sub(r'\b[A-Za-z_]+\d+\b', 'N', s)       # v12, xs7, S3, h4 …
    s = re.sub(r'\d+', '#', s)
    s = re.sub(r'\s+', ' ', s).strip()
    return s[:140]


def load_baseline():
    out = {}
    if not BASELINE.exists():
        return out
    for line in BASELINE.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if '  # ' not in line:
            raise SystemExit(f'leakgen: baseline line has no ticket (need `<sig>  # BUG-NNN`): {line}')
        sig, ticket = line.rsplit('  # ', 1)
        if not re.match(r'BUG-\d+', ticket.strip()):
            raise SystemExit(f'leakgen: baseline ticket is not a BUG number: {line}')
        out[sig.strip()] = ticket.strip()
    return out


def run_batch(seeds, n, caps=None, verbose=True):
    """Return (counts, leaks{sig: {src, msg, count}}, crashes{sig: ...}, rejects{sig: count})."""
    counts = {'ok': 0, 'reject': 0, 'LEAK': 0, 'crash': 0}
    leaks, crashes, rejects = {}, {}, {}
    total = 0
    for seed in seeds:
        for k in range(n):
            s = seed * 100000 + k
            src = gen.gen(s, caps)
            tag = hashlib.sha1(src.encode()).hexdigest()[:10]
            verdict, msg, d = emit(src, tag)
            total += 1
            if verdict == 'crash':
                counts['crash'] += 1
                sig = signature(msg)
                cur = crashes.get(sig)
                if cur is None or len(src) < len(cur['src']):
                    crashes[sig] = {'src': src, 'msg': msg, 'count': (cur['count'] + 1) if cur else 1}
                else:
                    cur['count'] += 1
                continue
            if verdict == 'reject':
                counts['reject'] += 1
                sig = signature(msg)
                rejects[sig] = rejects.get(sig, 0) + 1
                shutil.rmtree(d, ignore_errors=True)
                continue
            ok, zmsg = zig_check(d)
            if ok:
                counts['ok'] += 1
                shutil.rmtree(d, ignore_errors=True)
                continue
            counts['LEAK'] += 1
            sig = signature(zmsg)
            cur = leaks.get(sig)
            if cur is None:
                leaks[sig] = {'src': src, 'msg': zmsg, 'count': 1, 'seed': s}
            else:
                cur['count'] += 1
                if len(src) < len(cur['src']):
                    cur['src'], cur['seed'] = src, s
            shutil.rmtree(d, ignore_errors=True)
            if verbose and total % 25 == 0:
                print(f'  … {total} done: {counts}', flush=True)
    return counts, leaks, crashes, rejects, total


def write_repros(leaks, crashes):
    FINDINGS.mkdir(parents=True, exist_ok=True)
    for i, (sig, f) in enumerate(sorted(leaks.items(), key=lambda kv: -kv[1]['count'])):
        p = FINDINGS / f'LEAK_{i:02d}.zbr'
        p.write_text(f'# seed {f["seed"]}\n# zig: {f["msg"][:200]}\n' + f['src'], encoding='utf-8', newline='\n')
    for i, (sig, f) in enumerate(crashes.items()):
        p = FINDINGS / f'CRASH_{i:02d}.zbr'
        p.write_text(f['src'], encoding='utf-8', newline='\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-n', type=int, default=100)
    ap.add_argument('--seed', type=int, default=0)
    ap.add_argument('--gate', action='store_true')
    ap.add_argument('--update-baseline', action='store_true')
    args = ap.parse_args()
    if ZEBRA is None:
        print('leakgen: REFUSING -- zig-out/bin/zebra not built'); return 2
    if not shutil.which(ZIG) and not Path(ZIG).exists():
        print(f'leakgen: REFUSING -- no zig at {ZIG} (set ZIG=)'); return 2

    # POSITIVE CONTROL: a program Zebra accepts and zig MUST refuse, by construction --
    # a `zig"..."` literal (passed through verbatim) carrying a type error. It can never
    # be "fixed", so it never needs retiring, and every absence claim below rests on it.
    # (The first control was the BUG-354 shape; that was fixed the same day, which is
    # exactly why a control must not be a bug.)
    ctl = 'def main()\n    zig"const _ctl: i32 = \\"leakgen-control\\";"\n    print("x")\n'
    v, m, d = emit(ctl, 'control')
    if v != 'emitted':
        print(f'leakgen: REFUSING -- the positive control did not emit ({v}: {m[:80]})'); return 2
    ok, zm = zig_check(d)
    shutil.rmtree(d, ignore_errors=True)
    if ok:
        print('leakgen: REFUSING -- the positive control (a zig literal with a type error) no longer leaks; the instrument cannot see'); return 2

    if args.gate:
        seeds, n = GATE_SEEDS, GATE_N
    else:
        seeds, n = (args.seed,), args.n
    counts, leaks, crashes, rejects, total = run_batch(seeds, n)
    print(f'[leakgen] {total} programs: ok={counts["ok"]} reject={counts["reject"]} '
          f'LEAK={counts["LEAK"]} crash={counts["crash"]}')
    if rejects:
        print(f'[rejects] {len(rejects)} signature(s) -- the selfhost refused a gen.py program '
              f'(generator or over-refusal; NOT gated):')
        for sig, c in sorted(rejects.items(), key=lambda kv: -kv[1])[:8]:
            print(f'    x{c:<4} {sig[:110]}')
    write_repros(leaks, crashes)
    if leaks:
        print(f'[LEAKS] {len(leaks)} unique signature(s), most frequent first (repros in {FINDINGS}):')
        for i, (sig, f) in enumerate(sorted(leaks.items(), key=lambda kv: -kv[1]['count'])):
            print(f'    x{f["count"]:<4} LEAK_{i:02d}.zbr ({len(f["src"])}b): {sig[:105]}')
    if crashes:
        print(f'[CRASHES] {len(crashes)}:')
        for sig, f in crashes.items():
            print(f'    x{f["count"]:<4} {sig[:110]}')

    if not args.gate:
        return 0
    if args.update_baseline:
        # keep tickets already recorded; a NEW signature gets a placeholder that the loader
        # will REFUSE until someone files it -- writing the baseline must not be how a leak
        # gets accepted silently.
        old = load_baseline()
        lines = ['# leakgen baseline: one zig-diagnostic signature per line, `<sig>  # BUG-NNN`.',
                 '# Every line is an ACCEPTED leak with an owner. Shrink it; do not grow it.']
        for sig in sorted(leaks):
            lines.append(f'{sig}  # {old.get(sig, "BUG-FILE-ME")}')
        BASELINE.write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
        print(f'[baseline] wrote {len(leaks)} signature(s) to {BASELINE}; fill in any BUG-FILE-ME before committing')
        return 0
    base = load_baseline()
    new = [s for s in leaks if s not in base]
    gone = [s for s in base if s not in leaks]
    if gone:
        print(f'[baseline] {len(gone)} baselined signature(s) no longer reproduce -- fixed? remove them '
              f'(and close the ticket) so the baseline cannot hide a return:')
        for s in gone:
            print(f'    {base[s]}: {s[:100]}')
    if crashes:
        print(f'leakgen gate FAIL: {len(crashes)} crash signature(s)')
        return 1
    if new:
        print(f'leakgen gate FAIL: {len(new)} NEW leak signature(s) not in {BASELINE.name}:')
        for s in new:
            print(f'    {s}')
        return 1
    print(f'leakgen gate PASS: {total} programs, {len(leaks)} leak signature(s), all baselined'
          f'{" (" + ", ".join(sorted(set(base[s] for s in leaks))) + ")" if leaks else ""}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
