#!/usr/bin/env python3
"""Zebra's keyword vocabulary and a whole-word scanner, derived once for several consumers.

`construct_histogram.py` (a report) and `lint_keyword_coverage.py` (a gate) both need to
answer "which keywords does this code use". They had one copy of that between them and were
about to have two -- the shape `corpus_ls.sh` and `positive_set.sh` were each extracted to
avoid: one derivation, several consumers.

THE ORACLE IS A TYPABLE WORD, NOT AN ENUM VARIANT NAME, and getting that wrong is the
defect this module was written to fix. `construct_histogram` derived its vocabulary from
`selfhost/Token.zbr`'s `kw_*` enum, and the variant name is NOT always the word:

    kw_arena   <- the selfhost's name; the word the BOOTSTRAP maps is `allocate`
    kw_old / kw_result / kw_stop   <- enum variants with no entry in the bootstrap's table

So a vocabulary read off the enum contains `arena`, which no current program can type
(QUICKSTART: "the old `arena { }` keyword is removed"), and MISSES `allocate`, which every
arena-scoped program uses. A coverage tool built on it would report a live keyword as
untested and a removed one as uncovered, in both directions at once.

THREE SOURCES EXIST AND THEY DISAGREE, so all three are read and reconciled rather than one
being trusted:

    src/Token.zig       `.{ "word", .kw_x }`   -- the bootstrap's table, 80 words
    selfhost/Token.zbr  `if word == "..."`     -- the selfhost's table, 79 words
    selfhost/Parser.zbr a pipe-delimited string of statement keywords, hand-maintained

`allocate` is in the first and third but not the second; the selfhost reaches it
contextually. A tool that read any single source would be wrong about something.
"""
import io
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BS_TOKEN = os.path.join(REPO, 'src', 'Token.zig')
SH_TOKEN = os.path.join(REPO, 'selfhost', 'Token.zbr')
SH_PARSER = os.path.join(REPO, 'selfhost', 'Parser.zbr')

# String literals go wholesale, not just quoted-out: the word `private` inside a message
# must not count as a use of the keyword. Same rule keyword_ident_check.sh applies.
STR = re.compile(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'')

VOCAB_FLOOR = 60
DISAGREE_CEILING = 6


def _bootstrap_words():
    src = io.open(BS_TOKEN, encoding='utf-8').read()
    return {m.group(1) for m in re.finditer(r'\.\{\s*"([a-z_]+)"\s*,\s*\.kw_\w+\s*\}', src)}


def _selfhost_words():
    src = io.open(SH_TOKEN, encoding='utf-8').read()
    return {m.group(1) for m in re.finditer(r'if\s+word\s*==\s*"([a-z_]+)"', src)}


def _selfhost_stmt_words():
    """The pipe-delimited statement-keyword string in Parser.zbr -- a third, hand-kept list."""
    src = io.open(SH_PARSER, encoding='utf-8').read()
    out = set()
    for m in re.finditer(r'"\|((?:[a-z_]+\|){4,})"', src):
        out |= {w for w in m.group(1).split('|') if w}
    return out


def vocabulary(explain=False):
    """The union of every source, because each is incomplete in a different direction."""
    bs, sh, st = _bootstrap_words(), _selfhost_words(), _selfhost_stmt_words()
    words = bs | sh | st
    if len(words) < VOCAB_FLOOR:
        print('zbr_vocab: REFUSING -- derived only %d keyword(s) (floor %d) from\n'
              '  %s: %d\n  %s: %d\n  %s: %d\n'
              'A pattern has stopped matching, and every count downstream would be wrong in '
              'the REASSURING direction: with a small vocabulary almost nothing looks '
              'uncovered.' % (len(words), VOCAB_FLOOR, BS_TOKEN, len(bs), SH_TOKEN, len(sh),
                              SH_PARSER, len(st)), file=sys.stderr)
        sys.exit(2)
    if explain:
        only_bs = sorted(bs - sh - st)
        only_sh = sorted((sh | st) - bs)
        print('  vocabulary: %d word(s)  [bootstrap %d, selfhost %d, stmt-string %d]'
              % (len(words), len(bs), len(sh), len(st)))
        if only_bs:
            print('  only the BOOTSTRAP maps: %s' % ' '.join(only_bs))
        if only_sh:
            print('  only the SELFHOST maps: %s' % ' '.join(only_sh))
        if len(only_bs) + len(only_sh) > DISAGREE_CEILING:
            print('zbr_vocab: REFUSING -- the two compilers disagree on %d keyword(s), over '
                  'the ceiling of %d. That is either a real divergence worth a ticket or an '
                  'extraction that has drifted; either way the union below is not trustworthy.'
                  % (len(only_bs) + len(only_sh), DISAGREE_CEILING), file=sys.stderr)
            sys.exit(2)
    return sorted(words)


def scan(paths, kws):
    """Whole-word keyword counts with comments and string CONTENTS removed.

    Returns (counts, code_lines, files_per_keyword). The third is kept because "used once
    in one file" and "used throughout" are different coverage claims and a bare count
    cannot tell them apart.
    """
    counts = {k: 0 for k in kws}
    where = {k: set() for k in kws}
    lines = 0
    for p in paths:
        try:
            src = io.open(p, encoding='utf-8', errors='replace').read()
        except (IOError, OSError):
            continue
        for raw in src.split('\n'):
            code = STR.sub('""', raw)
            code = code.split('#', 1)[0]
            if not code.strip():
                continue
            lines += 1
            # Tokenising rather than substring-matching is what stops `internalize`
            # counting as a use of `internal`.
            for w in re.findall(r'[a-z_][a-z_0-9]*', code):
                if w in counts:
                    counts[w] += 1
                    where[w].add(p)
    return counts, lines, where


# BARE `bash` RESOLVES TO WSL ON THIS MACHINE, which is hazard_lint's H2 and which this
# module walked straight into on its first run: corpus_ls.sh exited 127 with
# "wsl: Failed to start the systemd user session" and a Windows path stripped of its
# separators. The fix is not to hope PATH is right but to IDENTIFY the shell -- Git Bash
# reports `uname -o` as Msys, WSL reports GNU/Linux -- and refuse rather than run the wrong
# one. A silent fall-through to WSL would have produced an empty corpus, and an empty
# corpus makes every keyword look uncovered.
_BASH = None
_BASH_CANDIDATES = [
    r'C:\Program Files\Git\bin\bash.exe',
    r'C:\Program Files\Git\usr\bin\bash.exe',
    r'C:\Program Files (x86)\Git\bin\bash.exe',
    # hazard-ok:H2 last-resort candidate only, and it is VERIFIED before use: every
    # candidate must answer `uname -o` with Msys/MINGW or it is rejected, so a PATH
    # `bash` that resolves to WSL is refused rather than run. Kept because Git Bash is
    # not always at one of the paths above on another machine.
    'bash',  # hazard-ok:H2 verified before use -- a candidate must answer `uname -o` with Msys/MINGW or it is rejected, so a PATH bash resolving to WSL is refused, not run
]


def _git_bash():
    """A bash that identifies itself as Msys, or a refusal. Never a guess."""
    global _BASH
    if _BASH:
        return _BASH
    tried = []
    for cand in _BASH_CANDIDATES:
        try:
            r = subprocess.run([cand, '-c', 'uname -o'], capture_output=True, text=True,
                               timeout=30)
        except (OSError, subprocess.SubprocessError) as e:
            tried.append('%s: %s' % (cand, e))
            continue
        got = (r.stdout or '').strip()
        if got.lower().startswith('msys') or 'mingw' in got.lower():
            _BASH = cand
            return _BASH
        tried.append('%s: uname -o = %r' % (cand, got))
    print('zbr_vocab: REFUSING -- no Git Bash found. `bash` on PATH here resolves to WSL, '
          'which cannot read this repo\'s Windows paths and would return an EMPTY corpus -- '
          'making every keyword look uncovered. Tried:\n  %s' % '\n  '.join(tried),
          file=sys.stderr)
    sys.exit(2)


def tracked(subdir):
    """Corpus enumeration via git, never a filesystem glob -- see corpus_ls.sh for why."""
    try:
        out = subprocess.run([_git_bash(), os.path.join(REPO, 'tools', 'corpus_ls.sh'), subdir],
                             capture_output=True, text=True, cwd=REPO, timeout=180)
    except (OSError, subprocess.SubprocessError) as e:
        print('zbr_vocab: REFUSING -- could not run corpus_ls.sh: %s' % e, file=sys.stderr)
        sys.exit(2)
    if out.returncode != 0:
        print('zbr_vocab: REFUSING -- corpus_ls.sh %s exited %d: %s'
              % (subdir, out.returncode, out.stderr.strip()), file=sys.stderr)
        sys.exit(2)
    paths = [os.path.join(REPO, p.strip().replace('/', os.sep))
             for p in out.stdout.split('\n') if p.strip()]
    if not paths:
        print('zbr_vocab: REFUSING -- corpus_ls.sh %s returned nothing. An empty corpus is '
              'indistinguishable from a corpus where nothing is covered.' % subdir,
              file=sys.stderr)
        sys.exit(2)
    return paths


CASES = [
    ('code',      'internal var x: int = 1',    1),
    ('comment',   '# internal detail here',     0),
    ('string',    'print("internal")',          0),
    ('interp',    'print("a ${b} internal c")', 0),
    ('substring', 'var internalize = 1',        0),
    ('absent',    'def f(): int',               0),
    ('trailing',  'var y = 1  # internal',      0),
]


def selftest():
    """Both directions, on synthetic input, before any real scan.

    A scanner that has stopped seeing code reports every keyword as uncovered, which reads
    as a huge finding rather than a broken tool -- so that failure at least biases toward
    alarm. The comment/string/substring legs are the dangerous ones: each would INFLATE
    coverage and hide a real gap, which is the quiet direction.
    """
    import tempfile
    bad = []
    for name, line, want in CASES:
        with tempfile.NamedTemporaryFile('w', suffix='.zbr', delete=False,
                                         encoding='utf-8', newline='\n') as fh:
            fh.write(line + '\n')
            path = fh.name
        try:
            counts, _, _ = scan([path], ['internal', 'private', 'def'])
            got = counts['internal']
            if got != want:
                bad.append('%s: %r -> counted %d, want %d' % (name, line, got, want))
        finally:
            os.unlink(path)
    return bad


if __name__ == '__main__':
    bad = selftest()
    for b in bad:
        print('  FAIL ' + b)
    print('zbr_vocab selftest: %d/%d' % (len(CASES) - len(bad), len(CASES)))
    vocabulary(explain=True)
    sys.exit(1 if bad else 0)
