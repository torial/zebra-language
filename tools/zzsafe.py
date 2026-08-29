#!/usr/bin/env python3
"""Verified source edits. Import this instead of hand-rolling open/replace/write.

    import sys; sys.path.insert(0, 'tools')
    from zzsafe import edit_exact, edit_lines, show

    edit_exact('src/CodeGen.zig', old, new)          # exactly-once, or nothing happens
    edit_lines('selfhost/Parser.zbr', 2670, old_lines, new_lines)   # 1-BASED, verified

WHY THIS EXISTS. On 2026-08-26 a single session lost time to six distinct editing
failures, every one of which this module makes impossible or loud:

  PARTIAL WRITES. A patch script rewrote the head of an emit site, failed to anchor the
  tail, printed `WARN: could not anchor` and wrote the file anyway -- leaving an unbalanced
  `_zbr_set(` in the compiler. A warning on a path that has already written is the worst of
  both: the damage is done and the message is skimmable. Everything here VERIFIES FIRST and
  WRITES ONCE, so a failed edit is a no-op.

  PATTERNS COPIED OUT OF A RENDERING. An edit failed because the pattern was copied from
  `sed ... | sed 's/^/  /'` output, which had added two spaces of indent. The source was
  never what the terminal showed. `show()` prints with an explicit gutter that cannot be
  mistaken for content, and `edit_lines` takes coordinates rather than transcribed text.

  STALE LINE NUMBERS. A `sed -i '1877s/.../.../'` silently did nothing because an earlier
  edit in the same session had shifted the file. `edit_lines` requires the caller to state
  what it expects to find AT those lines and refuses if the block moved.

  CRLF. Python's default `open(..., 'w')` writes CRLF on Windows, which crashes the Zebra
  tokenizer with `error.UnexpectedCharacter` and no source location. Every write here is
  newline='\\n'.

  AMBIGUOUS MATCHES. `str.replace` silently rewrites all occurrences. `edit_exact` requires
  the expected count and names the alternatives when it disagrees.

  READING A RENDERING TO BUILD A PATTERN, then matching against the source. `find_block`
  searches the SOURCE and hands back real coordinates.
"""
import io
import os
import re
import sys

__all__ = ['edit_exact', 'edit_lines', 'find_block', 'show', 'read']


class EditRefused(Exception):
    """Raised INSTEAD of writing. Every failure path in this module raises."""


def read(path):
    return io.open(path, encoding='utf-8').read()


def _write(path, text):
    """One write, LF endings, no partial state."""
    io.open(path, 'w', encoding='utf-8', newline='\n').write(text)


def show(path, first, last, width=100):
    """Print lines with a 1-BASED gutter that cannot be mistaken for content.

    The gutter is `NNNN| ` -- a pipe, not spaces -- precisely so a pattern copied out of
    this output fails loudly rather than matching with phantom indentation.
    """
    lines = read(path).split('\n')
    for n in range(max(1, first), min(len(lines), last) + 1):
        print('%5d| %s' % (n, lines[n - 1][:width]))


def edit_exact(path, old, new, expect=1):
    """Replace `old` with `new`, which must occur exactly `expect` times.

    Verifies before writing; on any disagreement nothing is written.
    """
    text = read(path)
    n = text.count(old)
    if n != expect:
        head = old.split('\n')[0][:70]
        raise EditRefused(
            '%s: expected %d occurrence(s) of %r, found %d. Nothing written.%s'
            % (path, expect, head, n,
               '' if n else '\n  (a leading-whitespace mismatch is the usual cause -- did the '
                            'pattern come from formatted output rather than the file?)'))
    if old == new:
        raise EditRefused('%s: old and new are identical -- the edit would be a no-op' % path)
    _write(path, text.replace(old, new, expect))
    return n


def edit_lines(path, start, expect_lines, new_lines):
    """Replace a block by 1-BASED line number, verifying its current contents first.

    `expect_lines` is what must currently be at those lines. This is the form to use when a
    pattern is hard to make unique, and it is immune to the stale-coordinate failure because
    the coordinates are checked against content before anything is written.
    """
    lines = read(path).split('\n')
    i = start - 1
    got = lines[i:i + len(expect_lines)]
    if got != list(expect_lines):
        msg = ['%s: block at line %d does not match. Nothing written.' % (path, start)]
        for k, (w, g) in enumerate(zip(expect_lines, got + [''] * len(expect_lines))):
            if w != g:
                msg.append('  line %d' % (start + k))
                msg.append('    want %r' % w)
                msg.append('    got  %r' % g)
        raise EditRefused('\n'.join(msg))
    lines[i:i + len(expect_lines)] = list(new_lines)
    _write(path, '\n'.join(lines))
    return len(new_lines) - len(expect_lines)


def find_block(path, pattern, context=0):
    """Locate `pattern` (regex) in the SOURCE and return [(lineno1based, text), ...].

    Use this to derive coordinates instead of transcribing them from printed output.
    """
    lines = read(path).split('\n')
    rx = re.compile(pattern)
    out = []
    for n, ln in enumerate(lines, 1):
        if rx.search(ln):
            lo, hi = max(1, n - context), min(len(lines), n + context)
            out.append((n, '\n'.join(lines[lo - 1:hi])))
    return out


# ── selftest: every refusal path must actually refuse ────────────────────────────────────
def _selftest():
    import tempfile
    fails = []

    def check(name, fn, should_raise=True):
        try:
            fn()
            ok = not should_raise
        except EditRefused:
            ok = should_raise
        except Exception as e:                      # noqa: BLE001 -- any other error is a bug
            print('  ERROR %s: %r' % (name, e))
            fails.append(name)
            return
        print('  %-44s %s' % (name, 'ok' if ok else 'FAILED'))
        if not ok:
            fails.append(name)

    d = tempfile.mkdtemp()
    p = os.path.join(d, 't.txt')

    def fresh():
        _write(p, 'alpha\nbeta\ngamma\nbeta\n')

    fresh(); check('refuses when a pattern is absent',      lambda: edit_exact(p, 'zzz', 'q'))
    fresh(); check('refuses an AMBIGUOUS match (2 of 1)',   lambda: edit_exact(p, 'beta', 'q'))
    fresh(); check('accepts an unambiguous match',          lambda: edit_exact(p, 'alpha', 'q'), False)
    fresh(); check('refuses a no-op edit',                  lambda: edit_exact(p, 'alpha', 'alpha'))
    fresh(); check('refuses a MOVED block',                 lambda: edit_lines(p, 1, ['beta'], ['x']))
    fresh(); check('accepts a verified block',              lambda: edit_lines(p, 2, ['beta'], ['x']), False)

    # the CRLF guarantee, which is the one that crashes the Zebra tokenizer
    fresh(); edit_exact(p, 'alpha', 'delta')
    raw = io.open(p, 'rb').read()
    ok = b'\r\n' not in raw
    print('  %-44s %s' % ('writes LF, never CRLF', 'ok' if ok else 'FAILED'))
    if not ok:
        fails.append('crlf')

    # a refused edit must leave the file BYTE-IDENTICAL
    fresh(); before = io.open(p, 'rb').read()
    try:
        edit_exact(p, 'beta', 'q')
    except EditRefused:
        pass
    ok = io.open(p, 'rb').read() == before
    print('  %-44s %s' % ('a refused edit writes NOTHING', 'ok' if ok else 'FAILED'))
    if not ok:
        fails.append('atomic')

    print()
    if fails:
        print('zzsafe selftest: %d FAILED -- %s' % (len(fails), ', '.join(fails)))
        return 1
    print('zzsafe selftest: all checks ok')
    return 0


if __name__ == '__main__':
    sys.exit(_selftest())
