#!/usr/bin/env python3
"""Compare the CONSTRUCT DISTRIBUTION of real programs against the test corpus.

    python tools/construct_histogram.py <dir-with-real-.zbr-programs>

WHY. Knuth's 1971 study did not theorise about what FORTRAN programs looked like -- he
collected real ones and MEASURED the distribution, and found it wildly skewed. The famous
quote is the conclusion; this is the method.

Three corpora exist here and none of them is what users write:

    test/*.zbr          COMPILER-TEST shaped -- small, targeted, one feature each
    fuzz/gramgen.py     GRAMMAR-UNIFORM -- every production equally likely
    a real program      whatever the domain actually needs

The gap between the first and the third is not a bug list. It is the map of where our
quality state is UNKNOWN -- constructs we ship without evidence, as distinct from
constructs we have tested and believe correct. Those are different kinds of ignorance and
only one of them is visible today.

WHAT THIS CANNOT DO, stated plainly: it finds COVERAGE gaps, not CORRECTNESS gaps. A
construct can be exercised constantly and still be wrong -- BUG-226 was exactly that (valid
Zig, wrong output, invisible to every compile gate at any corpus size). This aims
attention; it proves nothing.
"""
import io
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN = os.path.join(REPO, 'selfhost', 'Token.zbr')
STR = re.compile(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'')


def vocabulary():
    """Keywords, derived from the compiler's own token enum -- never hand-listed."""
    src = io.open(TOKEN, encoding='utf-8').read()
    kws = sorted({m.group(1) for m in re.finditer(r'^\s+kw_([a-z_0-9]+)\s*$', src, re.M)})
    if len(kws) < 40:
        print('construct_histogram: REFUSING -- derived only %d keyword(s) from %s. The '
              'enum pattern has stopped matching; every rate below would be wrong in the '
              'reassuring direction (everything looks untested).' % (len(kws), TOKEN),
              file=sys.stderr)
        sys.exit(2)
    return kws


def scan(paths, kws):
    """Whole-word keyword counts, with comments and string CONTENTS removed."""
    counts = {k: 0 for k in kws}
    lines = 0
    for p in paths:
        for raw in io.open(p, encoding='utf-8', errors='replace').read().split('\n'):
            code = STR.sub('""', raw)
            code = code.split('#', 1)[0]
            if not code.strip():
                continue
            lines += 1
            for w in re.findall(r'[a-z_][a-z_0-9]*', code):
                if w in counts:
                    counts[w] += 1
    return counts, lines


def collect(root):
    out = []
    for d, _, names in os.walk(root):
        out += [os.path.join(d, n) for n in names if n.endswith('.zbr')]
    return sorted(out)


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip().split('\n\n')[1], file=sys.stderr)
        return 2
    real_root = sys.argv[1]
    real = collect(real_root)
    if not real:
        print('construct_histogram: REFUSING -- no .zbr under %s' % real_root, file=sys.stderr)
        return 2

    kws = vocabulary()
    corpus = collect(os.path.join(REPO, 'test'))
    c_counts, c_lines = scan(corpus, kws)
    r_counts, r_lines = scan(real, kws)

    # POSITIVE CONTROL. `def` must be frequent in both, or the scanner is not seeing code.
    if c_counts.get('def', 0) < 10 or r_counts.get('def', 0) < 1:
        print('construct_histogram: REFUSING -- control failed: `def` appears %d time(s) in '
              'the corpus and %d in the sample. The scanner is not reading code.'
              % (c_counts.get('def', 0), r_counts.get('def', 0)), file=sys.stderr)
        return 2

    print('corpus : %4d file(s), %5d code line(s)  (%s)' % (len(corpus), c_lines, 'test/'))
    print('sample : %4d file(s), %5d code line(s)  (%s)' % (len(real), r_lines, real_root))
    print('rates are per 1000 code lines\n')

    rows = []
    for k in kws:
        rr = r_counts[k] * 1000.0 / max(r_lines, 1)
        cr = c_counts[k] * 1000.0 / max(c_lines, 1)
        if r_counts[k]:
            rows.append((rr / cr if cr else float('inf'), k, r_counts[k], rr, c_counts[k], cr))

    print('=== USED BY THE REAL PROGRAM, RARE OR ABSENT IN THE CORPUS ===')
    print('  (highest ratio first -- this is where quality state is UNKNOWN)')
    print('  %-16s %6s %8s   %6s %8s   %s' % ('construct', 'n', 'rate', 'n', 'rate', 'ratio'))
    shown = 0
    for ratio, k, rn, rr, cn, cr in sorted(rows, reverse=True):
        if ratio <= 2.0 or shown >= 18:
            continue
        print('  %-16s %6d %8.1f   %6d %8.1f   %s' %
              (k, rn, rr, cn, cr, 'NEVER in corpus' if cr == 0 else '%.1fx' % ratio))
        shown += 1
    if not shown:
        print('  (none over 2x -- the corpus covers this program\'s construct mix)')

    never = [k for k in kws if r_counts[k] == 0 and c_counts[k] == 0]
    print('\n=== IN NEITHER (untested AND unused by this sample): %d ===' % len(never))
    print('  ' + ' '.join(never[:24]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
