#!/usr/bin/env python3
"""complexity_report.py — cyclomatic complexity over Zebra source. REPORT ONLY, not a gate.

WHY REPORT-ONLY. Cyclomatic complexity is a PROXY, and the empirical link between it and
defect density is contested — most of its apparent predictive power in the literature
disappears once you control for size, because CC and line count correlate ~0.9. A number
like this earns attention, not a threshold. Gating on it would invite the worst kind of
refactor: splitting a function to move a number rather than to make it comprehensible.

WHAT IT COUNTS. CC = 1 + decision points, per `def`:

    if / else if          each adds one   (a bare `else` adds none — no new predicate)
    while                 one
    for ... in / for ...  one
    branch `on` arm       one per arm     (`else` arm adds none)
    and / or              one each        (short-circuit = a branch)
    `expr?` (try)         one             (an error path the reader must hold)
    catch / guard         one
    inline `if ... else`  one

DELIBERATELY NOT COUNTED: `pass`, `return`, `break`, `continue`. They change flow but add
no PREDICATE, and CC counts predicates.

HOW IT AVOIDS LYING. Comments and string literals are stripped before counting, so `# if
this` and `"and then"` cannot inflate a score. Bodies are found by INDENTATION, which is
how Zebra delimits them. Both facts are checked by controls that run before every report:
a function with no decisions must score exactly 1, a function with a known shape must
score exactly its known value, and a function whose only `if` is inside a comment or a
string must score 1. If any control fails the tool REFUSES rather than printing numbers.

    python tools/complexity_report.py                 # per-module summary + top functions
    python tools/complexity_report.py --top 40        # more functions
    python tools/complexity_report.py --module CodeGen
    python tools/complexity_report.py --selftest
"""
import io
import re
import sys
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):
        pass

STR_RE = re.compile(r'"(?:[^"\\]|\\.)*"' r"|'(?:[^'\\]|\\.)*'")


def strip_noise(line):
    """Remove string literals, then a trailing comment. Order matters: a `#` inside a
    string is not a comment, and stripping strings first makes that impossible to get
    wrong."""
    line = STR_RE.sub('""', line)
    h = line.find("#")
    if h >= 0:
        line = line[:h]
    return line


DECISION_PATTERNS = [
    (re.compile(r"(?<![A-Za-z0-9_])else\s+if(?![A-Za-z0-9_])"), "else if"),
    (re.compile(r"(?<![A-Za-z0-9_])if(?![A-Za-z0-9_])"), "if"),
    (re.compile(r"(?<![A-Za-z0-9_])while(?![A-Za-z0-9_])"), "while"),
    (re.compile(r"(?<![A-Za-z0-9_])for(?![A-Za-z0-9_])"), "for"),
    (re.compile(r"(?<![A-Za-z0-9_])on(?![A-Za-z0-9_])"), "branch arm"),
    (re.compile(r"(?<![A-Za-z0-9_])and(?![A-Za-z0-9_])"), "and"),
    (re.compile(r"(?<![A-Za-z0-9_])or(?![A-Za-z0-9_])"), "or"),
    (re.compile(r"(?<![A-Za-z0-9_])catch(?![A-Za-z0-9_])"), "catch"),
    (re.compile(r"(?<![A-Za-z0-9_])guard(?![A-Za-z0-9_])"), "guard"),
]
# `expr?` — a postfix try. Not `?` in a type (`int?`) and not `??`.
TRY_RE = re.compile(r"[A-Za-z0-9_\)\]]\?(?!\?)(?=\s*(?:$|[,\)\]]))")

DEF_RE = re.compile(r"^(\s*)def\s+([A-Za-z_][A-Za-z0-9_]*)")


def decisions_in(line):
    """Decision points on one already-stripped line."""
    n = 0
    # `else if` must be consumed before `if`, or it double-counts.
    tmp = line
    m = DECISION_PATTERNS[0][0]
    k = len(m.findall(tmp))
    n += k
    tmp = m.sub(" ELSEIF ", tmp)
    for pat, _name in DECISION_PATTERNS[1:]:
        n += len(pat.findall(tmp))
    n += len(TRY_RE.findall(tmp))
    return n


def analyse_text(text):
    """[(name, complexity, body_lines)] for each `def` in `text`."""
    lines = text.split("\n")
    out, cur, indent, cc, body = [], None, 0, 1, 0
    for raw in lines:
        m = DEF_RE.match(raw)
        stripped = strip_noise(raw)
        if m and not raw.lstrip().startswith("#"):
            if cur is not None:
                out.append((cur, cc, body))
            cur, indent, cc, body = m.group(2), len(m.group(1)), 1, 0
            cc += decisions_in(stripped[stripped.find("def"):])
            continue
        if cur is None:
            continue
        if raw.strip() == "":
            continue
        cur_indent = len(raw) - len(raw.lstrip())
        if cur_indent <= indent:
            out.append((cur, cc, body))
            cur = None
            continue
        body += 1
        cc += decisions_in(stripped)
    if cur is not None:
        out.append((cur, cc, body))
    return out


# ---------------------------------------------------------------- controls
CONTROLS = [
    ("def f()\n    return 1\n", "f", 1),                       # no predicates
    ("def f()\n    if a\n        pass\n", "f", 2),             # one if
    ("def f()\n    if a\n        pass\n    else if b\n        pass\n", "f", 3),
    ("def f()\n    if a and b or c\n        pass\n", "f", 4),  # if + and + or
    ("def f()\n    while x\n        pass\n", "f", 2),
    ("def f()\n    for x in xs\n        pass\n", "f", 2),
    ("def f()\n    branch e\n        on A\n            pass\n        on B\n"
     "            pass\n        else\n            pass\n", "f", 3),
    # the LIE tests: a decision word inside a comment or a string must not count
    ("def f()\n    # if this and that or other\n    return 1\n", "f", 1),
    ('def f()\n    var s = "if and or while for"\n    return s\n', "f", 1),
    ('def f()\n    var s = "# not a comment"\n    if a\n        pass\n', "f", 2),
]


def selftest(verbose=False):
    dead = []
    for src, name, want in CONTROLS:
        got = dict((n, c) for n, c, _b in analyse_text(src)).get(name)
        if got != want:
            dead.append("%r -> %s, wanted %s" % (src.split("\n")[1][:38], got, want))
        elif verbose:
            print("  [ok  ] %-40s = %d" % (src.split("\n")[1].strip()[:40], got))
    return dead


def main():
    argv = sys.argv[1:]
    dead = selftest(verbose="--selftest" in argv)
    if dead:
        print("[complexity] REFUSING — controls failed, so every number below would be "
              "unverified:", file=sys.stderr)
        for d in dead:
            print("    " + d, file=sys.stderr)
        return 2
    if "--selftest" in argv:
        print("[complexity] self-test OK: %d/%d controls" % (len(CONTROLS), len(CONTROLS)))
        return 0

    top_n = 25
    if "--top" in argv:
        top_n = int(argv[argv.index("--top") + 1])
    only = argv[argv.index("--module") + 1] if "--module" in argv else None

    files = sorted(REPO.glob("selfhost/*.zbr"))
    rows, allfns = [], []
    for f in files:
        name = f.stem
        if only and only.lower() not in name.lower():
            continue
        if name.endswith("_test"):
            continue
        fns = analyse_text(f.read_text(encoding="utf-8", errors="replace"))
        if not fns:
            continue
        ccs = [c for _n, c, _b in fns]
        rows.append((name, len(fns), sum(ccs) / len(ccs), max(ccs),
                     sum(1 for c in ccs if c > 20), sum(1 for c in ccs if c > 50)))
        allfns.extend((name, n, c, b) for n, c, b in fns)

    print("── cyclomatic complexity, selfhost compiler modules (tests excluded) ──")
    print("%-14s %5s %7s %6s %8s %8s" % ("module", "defs", "mean", "max", ">20", ">50"))
    for name, n, mean, mx, over20, over50 in sorted(rows, key=lambda r: -r[3]):
        print("%-14s %5d %7.1f %6d %8d %8d" % (name, n, mean, mx, over20, over50))

    tot = len(allfns)
    print("\ntotal defs: %d   mean CC: %.1f   >20: %d (%.0f%%)   >50: %d (%.0f%%)"
          % (tot, sum(c for _m, _n, c, _b in allfns) / tot,
             sum(1 for _m, _n, c, _b in allfns if c > 20),
             100.0 * sum(1 for _m, _n, c, _b in allfns if c > 20) / tot,
             sum(1 for _m, _n, c, _b in allfns if c > 50),
             100.0 * sum(1 for _m, _n, c, _b in allfns if c > 50) / tot))

    print("\n── the %d most complex functions ──" % top_n)
    print("%-14s %-34s %6s %7s" % ("module", "def", "CC", "lines"))
    for m, n, c, b in sorted(allfns, key=lambda r: -r[2])[:top_n]:
        print("%-14s %-34s %6d %7d" % (m, n[:34], c, b))

    print("\nNOT a gate and NOT a bug predictor on its own: CC correlates ~0.9 with line")
    print("count, so most of its apparent predictive power in the literature is size in")
    print("disguise. Read it as 'how much must a reader hold at once', not as a defect score.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
