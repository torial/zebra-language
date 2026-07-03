#!/usr/bin/env python
"""§28b step 2: consume IMPLICIT_TRY inventory lines and insert `?` at each
call's end position.  Bottom-up per file so offsets never shift; refuses any
site whose preceding character isn't `)` (prints SKIP instead of guessing);
LF-only writes (CLAUDE.md CRLF hazard).

Usage: python tools/sweep_implicit_try.py <inventory.txt>
Inventory lines: IMPLICIT_TRY: <file>:<line>:<col>:<end_line>:<end_col>
(end_col is 1-based exclusive — the insertion point.)
"""
import sys
from collections import defaultdict

inv = sys.argv[1]
sites = defaultdict(set)          # normalized file -> {(end_line, end_col)}
for raw in open(inv, encoding='utf-8'):
    raw = raw.strip()
    if not raw.startswith('IMPLICIT_TRY: '):
        continue
    body = raw[len('IMPLICIT_TRY: '):]
    parts = body.rsplit(':', 4)   # file may contain ':' (drive letter)
    f, line, col, eline, ecol = parts[0], *map(int, parts[1:])
    f = f.replace('\\', '/')
    sites[f].add((eline, ecol))

total_ins = total_skip = 0
for f, pts in sorted(sites.items()):
    lines = open(f, encoding='utf-8', newline='').read().split('\n')
    ins = skip = 0
    for eline, ecol in sorted(pts, reverse=True):
        ln = lines[eline - 1]
        # strip a trailing \r defensively (should not exist per .gitattributes)
        assert not ln.endswith('\r'), f'{f}:{eline}: CRLF detected — aborting'
        ip = ecol - 1              # 0-based insertion offset
        if ip < 1 or ip > len(ln) or ln[ip - 1] != ')':
            print(f'SKIP {f}:{eline}:{ecol} (char before is '
                  f'{ln[ip-1]!r} not \')\')' if 0 < ip <= len(ln)
                  else f'SKIP {f}:{eline}:{ecol} (out of range)')
            skip += 1
            continue
        if ip < len(ln) and ln[ip] == '?':
            skip += 1              # already explicit (idempotent re-run)
            continue
        lines[eline - 1] = ln[:ip] + '?' + ln[ip:]
        ins += 1
    open(f, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))
    print(f'{f}: {ins} inserted, {skip} skipped')
    total_ins += ins
    total_skip += skip
print(f'TOTAL: {total_ins} inserted, {total_skip} skipped')
