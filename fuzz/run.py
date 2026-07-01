#!/usr/bin/env python
"""Fuzzer driver: generate N seeded programs, run the differential+validity
oracle on each, bucket the verdicts, and save (shrunk) reproducers for any
real finding (emit-divergence / crash).

Usage:
    python fuzz/run.py --n 500 --start 0
    python fuzz/run.py --seed 12345          # reproduce/inspect one seed
"""
import argparse, sys, os
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen as G
from harness import check
from shrink import shrink

FIND_DIR = Path(__file__).resolve().parent / 'findings'


def one(seed, zig_check=True, run=False):
    src = G.gen(seed)
    res = check(src, tag=f's{seed}', zig_check=zig_check, run=run)
    return src, res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=200)
    ap.add_argument('--start', type=int, default=0)
    ap.add_argument('--seed', type=int, default=None)
    ap.add_argument('--no-zig', action='store_true', help='skip the zig-compile validity check (faster)')
    ap.add_argument('--run', action='store_true', help='also build-exe + run + compare output (slower)')
    ap.add_argument('--shrink', action='store_true', help='shrink findings')
    args = ap.parse_args()

    if args.seed is not None:
        src, res = one(args.seed, zig_check=not args.no_zig, run=args.run)
        print(f'=== seed {args.seed}: {res.verdict} ===')
        print(res.detail)
        print('--- program ---'); print(src)
        return

    FIND_DIR.mkdir(exist_ok=True)
    buckets = Counter()
    findings = []
    for i in range(args.start, args.start + args.n):
        src, res = one(i, zig_check=not args.no_zig, run=args.run)
        buckets[res.verdict] += 1
        if res.verdict in ('run-divergence', 'zig-diverge-A', 'zig-diverge-B', 'crash-A', 'crash-B'):
            findings.append((i, res.verdict, res.detail))
            out = src
            if args.shrink:
                out, _ = shrink(src, tag=f'sh{i}')
            (FIND_DIR / f'seed{i}_{res.verdict}.zbr').write_text(
                f'# seed {i} — {res.verdict}: {res.detail}\n{out}', encoding='utf-8', newline='\n')
        if (i - args.start + 1) % 50 == 0:
            print(f'  [{i - args.start + 1}/{args.n}] {dict(buckets)}', flush=True)
    print('\n=== buckets ===')
    for k, v in buckets.most_common():
        print(f'  {v:5d}  {k}')
    if findings:
        print(f'\n=== {len(findings)} findings (saved to fuzz/findings/) ===')
        for seed, verd, det in findings[:40]:
            print(f'  seed {seed:6d}  {verd:16s} {det[:60]}')


if __name__ == '__main__':
    main()
