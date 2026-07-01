#!/usr/bin/env python
"""Shrink a failing Zebra program to a minimal reproducer.

Line-granularity delta debugging: repeatedly try deleting each line; keep the
deletion iff the program still fails the *same way* (same verdict category, and
for an emit-divergence the same first-diff signature).  Converges to a minimal
program that still triggers the bug.
"""
from harness import check


def _sig(res):
    # What we preserve while shrinking.
    if res.verdict == 'emit-divergence':
        return ('emit-divergence', res.detail)
    return (res.verdict,)


def shrink(src, tag='shrink', max_rounds=6):
    target = _sig(check(src, tag))
    if target[0] == 'ok':
        return src, target
    lines = src.split('\n')
    for _ in range(max_rounds):
        changed = False
        i = 0
        while i < len(lines):
            trial = lines[:i] + lines[i + 1:]
            trial_src = '\n'.join(trial)
            if trial_src.strip() and _sig(check(trial_src, tag)) == target:
                lines = trial
                changed = True
            else:
                i += 1
        if not changed:
            break
    return '\n'.join(lines), target


if __name__ == '__main__':
    import sys
    src = open(sys.argv[1], encoding='utf-8').read()
    out, tgt = shrink(src)
    print(f'# shrunk, preserves {tgt}\n{out}')
