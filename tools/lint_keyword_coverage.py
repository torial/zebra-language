#!/usr/bin/env python3
"""THE KEYWORD-COVERAGE GATE: a language feature nothing exercises is unverified.

    python tools/lint_keyword_coverage.py [--update-baseline] [--verbose]

WHY, WITH A RECEIPT. `registration_check` asks whether every tracked TEST is asserted by
something. This is the mirror: whether every KEYWORD is exercised by something. Nothing
asked that until 2026-08-29, and on the day it was first asked the answer was already
embarrassing -- the two modifiers with zero corpus uses were `protected` and `internal`,
and BOTH were defective:

    BUG-315  `protected` was a synonym for `private`, documented with semantics ("the class
             and subclasses") that need inheritance the grammar cannot express. Removed.
    BUG-316  `internal` means different things in each compiler, and the selfhost's
             diagnostic reports "is private" about a field the source declares `internal`.

Two for two. That is the argument for this gate: an unexercised keyword is not merely
untested, it is where defects were actually found.

WHAT NO EXISTING GATE COULD SEE. `divergence_check` compiles the corpus with both
compilers, so a keyword absent from the corpus is invisible to it BY CONSTRUCTION -- there
is nothing to compile. `lint_reserved_words` asks whether a keyword is REACHABLE in either
compiler, which both of these were. `registration_check` looks at files, not features. The
gap is real and it is between three gates that each stop just short of it.

WHAT THIS CANNOT DO, stated plainly. It measures whether a keyword APPEARS, not whether its
semantics are asserted. A file that merely parses `internal` would satisfy this gate while
proving nothing about what `internal` does -- BUG-316 needed a probe with a control to
surface, and no coverage tool would have written that probe. This aims attention; the
`construct_histogram` docstring makes the same disclaimer for the same reason.
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zbr_vocab import REPO, scan, tracked, vocabulary, selftest, CASES  # noqa: E402

BASELINE = os.path.join(REPO, 'tools', 'keyword_coverage_baseline.txt')

# The corpus is what the heavy gates actually sweep. selfhost/ is deliberately EXCLUDED:
# the compiler's own source exercises a keyword for the round-trip, but no test there
# asserts what the keyword MEANS, and this gate exists because "something parses it" was
# exactly the false comfort that let BUG-315 and BUG-316 sit.
CORPUS = ['test', 'examples']

# Floors. Each is a shape of collapse that would otherwise print a reassuring number.
MIN_FILES = 300
MIN_LINES = 5000
MIN_CONTROL = 100   # `def` must be everywhere, or the scanner is not reading code


def read_baseline():
    if not os.path.exists(BASELINE):
        return set()
    out = set()
    for line in io.open(BASELINE, encoding='utf-8'):
        line = line.split('#', 1)[0].strip()
        if line:
            out.add(line)
    return out


def main():
    update = '--update-baseline' in sys.argv
    verbose = '--verbose' in sys.argv

    # ---- the instrument proves itself before it reports anything ----------------------
    bad = selftest()
    if bad:
        for b in bad:
            print('  selftest FAIL: %s' % b, file=sys.stderr)
        print('keyword-coverage: REFUSING -- the scanner failed %d of %d selftest case(s). '
              'A scanner that miscounts comments or strings INFLATES coverage, which is the '
              'quiet direction: real gaps would disappear from this report.'
              % (len(bad), len(CASES)), file=sys.stderr)
        return 2

    kws = vocabulary(explain=verbose)

    files = []
    for sub in CORPUS:
        files += tracked(sub)
    files = [f for f in files if f.endswith('.zbr')]
    if len(files) < MIN_FILES:
        print('keyword-coverage: REFUSING -- corpus enumerated only %d file(s) (floor %d). '
              'With a small corpus almost every keyword looks uncovered, so the report would '
              'be alarming and meaningless at once.' % (len(files), MIN_FILES), file=sys.stderr)
        return 2

    counts, lines, where = scan(files, kws)
    if lines < MIN_LINES:
        print('keyword-coverage: REFUSING -- only %d code line(s) scanned (floor %d). The '
              'comment/string stripping has probably eaten the corpus.' % (lines, MIN_LINES),
              file=sys.stderr)
        return 2
    if counts.get('def', 0) < MIN_CONTROL:
        print('keyword-coverage: REFUSING -- positive control failed: `def` appears %d '
              'time(s) across %d file(s). The scanner is not reading code.'
              % (counts.get('def', 0), len(files)), file=sys.stderr)
        return 2

    uncovered = sorted(k for k in kws if counts[k] == 0)
    thin = sorted((k for k in kws if 0 < len(where[k]) <= 1), key=str)

    if update:
        with io.open(BASELINE, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write('# Keywords no tracked test/ or examples/ file uses.\n')
            fh.write('# SHRINK THIS LIST; never grow it. Each line is a language feature\n')
            fh.write('# shipped without a program that exercises it. The two entries this\n')
            fh.write('# gate was written over -- `protected` and `internal` -- were BOTH\n')
            fh.write('# defective (BUG-315, BUG-316).\n')
            for k in uncovered:
                fh.write(k + '\n')
        print('keyword-coverage: baseline written with %d uncovered keyword(s)' % len(uncovered))
        return 0

    known = read_baseline()
    new = [k for k in uncovered if k not in known]
    fixed = sorted(known - set(uncovered))

    print('  corpus: %d file(s), %d code line(s), %d keyword(s) in vocabulary'
          % (len(files), lines, len(kws)))
    if thin:
        print('  thin (used in exactly ONE file -- covered, but by a single program):')
        print('    ' + ' '.join(thin))
    if fixed:
        print('  now covered, remove from the baseline: %s' % ' '.join(fixed))
    for k in new:
        print('%s: [KWCOV] no tracked test/ or examples/ program uses `%s`. It is shipped '
              'without a program that exercises it.' % (BASELINE, k))

    print('[keyword-coverage] %d keyword(s); %d uncovered (%d known), %d NEW'
          % (len(kws), len(uncovered), len(known), len(new)))
    if new:
        print('  Add a program that uses it, or -- if the keyword has no reason to exist --'
              ' free it, as `protected` was (BUG-315).')
    return 1 if new else 0


if __name__ == '__main__':
    sys.exit(main())
