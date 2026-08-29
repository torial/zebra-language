#!/usr/bin/env python3
"""Cheap assertions for numbers you are about to believe.

    import sys; sys.path.insert(0, 'tools')
    from zzcheck import reconcile, magnitude, occurrences, lines_matching

Every catch in the 2026-08-26 session came from arithmetic that did not add up, never from
noticing a result looked wrong. This module makes that arithmetic one call instead of a
habit, because a habit is what fails at 2am.

  reconcile()  -- parts must sum to the total. THREE separate wrong numbers were published
                  or nearly published because a classification silently dropped what it
                  could not parse: a bucket table that covered 63 of 91 sites (a regex that
                  could not cross nested parens), a must-reject set that extracted 48 of 52
                  (a pattern requiring a flat path), and a survey whose refusal-on-mismatch
                  was itself vacuous. A partial classification prints a TIDY TABLE, and a
                  tidy table reads as complete.

  magnitude()  -- state the expected size FIRST, then compare. `grep -E 'a|b*|c'` returned
                  38128 matches; the file has 38128 lines. Under -E those pipes are
                  alternation and `[a-z_]*` matches empty, so it matched everything. The
                  number was not suspicious in isolation -- it became obvious the moment it
                  was compared against the only other number in view.

  occurrences() vs lines_matching() -- `grep -c` counts LINES, not matches. "83 catch {}
                  sites" was really 91; eight lines held two each. Naming the two operations
                  differently is the whole fix.
"""
import re
import sys

__all__ = ['reconcile', 'magnitude', 'occurrences', 'lines_matching', 'distinct', 'CheckFailed']


class CheckFailed(Exception):
    """Raised instead of returning a number you should not trust."""


def reconcile(what, total, parts, tolerate=0):
    """`parts` (a dict name->count) must sum to `total`.

    Returns the breakdown on success. Raises on any shortfall, because the shortfall IS the
    finding: whatever was not classified is exactly what nobody has looked at.
    """
    s = sum(parts.values())
    gap = total - s
    if abs(gap) > tolerate:
        lines = ['%s: parts do not reconcile.' % what,
                 '  total  %d' % total,
                 '  parts  %d  (%s)' % (s, ', '.join('%s=%d' % kv for kv in sorted(parts.items()))),
                 '  UNACCOUNTED %+d' % gap,
                 '  An unclassified item is an unexamined one. Do not report the classified',
                 '  subset as though it were the whole -- that is how a partial answer reads',
                 '  as a complete one.']
        raise CheckFailed('\n'.join(lines))
    return parts


def magnitude(what, value, lo, hi, note=''):
    """Assert `value` is within the size you predicted BEFORE measuring."""
    if not (lo <= value <= hi):
        raise CheckFailed(
            '%s: %d is outside the expected range [%d, %d].%s\n'
            '  Either the expectation was wrong or the instrument is. Decide which BEFORE\n'
            '  using this number -- an implausible magnitude is the cheapest signal there is.'
            % (what, value, lo, hi, (' ' + note) if note else ''))
    return value


def occurrences(text, pattern, flags=0):
    """Count MATCHES (not lines). Use where `grep -c` would have undercounted."""
    return len(re.findall(pattern, text, flags))


def lines_matching(text, pattern, flags=0):
    """Count LINES containing a match -- what `grep -c` does. Named so the choice is explicit."""
    rx = re.compile(pattern, flags)
    return sum(1 for ln in text.split('\n') if rx.search(ln))


def distinct(what, seq):
    """Refuse duplicates. A registration added twice inflates every count downstream."""
    seen, dupes = set(), []
    for x in seq:
        (dupes.append(x) if x in seen else seen.add(x))
    if dupes:
        raise CheckFailed('%s: %d duplicate(s): %s'
                          % (what, len(dupes), ', '.join(map(str, sorted(set(dupes))[:8]))))
    return list(seq)


def _selftest():
    fails = []

    def check(name, fn, should_raise=True):
        try:
            fn()
            ok = not should_raise
        except CheckFailed:
            ok = should_raise
        print('  %-52s %s' % (name, 'ok' if ok else 'FAILED'))
        if not ok:
            fails.append(name)

    # the real receipt: 63 of 91 classified
    check('reconcile refuses a partial classification',
          lambda: reconcile('buckets', 91, {'append': 25, 'write': 14, 'other': 24}))
    check('reconcile accepts a complete one',
          lambda: reconcile('buckets', 64, {'append': 25, 'write': 14, 'other': 25}), False)
    # the real receipt: 38128 matches in a 38128-line file
    check('magnitude refuses an implausible count',
          lambda: magnitude('regex hits', 38128, 0, 500))
    check('magnitude accepts a plausible one',
          lambda: magnitude('regex hits', 29, 0, 500), False)
    check('distinct refuses a duplicate registration',
          lambda: distinct('smoke regs', ['a', 'b', 'a']))
    check('distinct accepts unique items',
          lambda: distinct('smoke regs', ['a', 'b']), False)

    # the real receipt: 83 lines vs 91 occurrences
    t = 'x catch {} y catch {}\nz catch {}\n'
    got_l, got_o = lines_matching(t, r'catch \{\}'), occurrences(t, r'catch \{\}')
    ok = (got_l, got_o) == (2, 3)
    print('  %-52s %s' % ('lines_matching(2) and occurrences(3) differ', 'ok' if ok else 'FAILED'))
    if not ok:
        fails.append('counting')

    print()
    print('zzcheck selftest: %s' % ('all checks ok' if not fails else '%d FAILED' % len(fails)))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(_selftest())
