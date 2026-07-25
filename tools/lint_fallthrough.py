#!/usr/bin/env python3
"""Linter for the TCO fall-through hazard in the Zebra selfhost compiler.

THE HAZARD.  The selfhost codegen tail-call-optimizes recursive value-returning
functions into `var e = arg; while (true) { switch (e) { ... } }`, turning
`return f(x)` into `e = x; <loop>`.  A `branch` arm that is *value-producing*
(contains a `return`) but can *fall through* (its last statement is a plain
`for`/`while`/`if`, or a `branch` that doesn't return on every arm) therefore
does NOT fall to a default — it loops forever with the same value.  This is a
hang, not a compile error, so the normal "not all paths return" safety net never
fires.  It bit the §28f set-literal walker arms (a missing terminal `return
false`); this gate exists so that class can never silently return.

THE RULE (conservative, tuned to 0 false positives on the clean tree).  Flag a
`branch` arm when BOTH hold:
  1. the arm body contains a `return`/`raise` (so it is meant to produce a value
     on the paths it handles — pure side-effecting arms are exempt), AND
  2. the arm cannot be proven to exit on every path: its last base-indent
     statement is not a terminal (`return`/`raise`/`continue`/`break`) and not a
     `branch` all of whose arms themselves exit safely (recursively).

A `branch` is trusted exhaustive by the compiler's own default-on exhaustiveness
check, so "every arm exits" is sufficient — no need to require an `else`.
"""
import re, sys, glob

TERMINALS = ("return", "raise", "continue", "break")

def indent_of(line):
    return len(line) - len(line.lstrip(" "))

def is_code(line):
    s = line.strip()
    return s != "" and not s.startswith("#")

def block_end(lines, start, base_indent):
    """Index one past the last body line of a block whose header sits at base_indent."""
    i = start
    while i < len(lines):
        if is_code(lines[i]) and indent_of(lines[i]) <= base_indent:
            break
        i += 1
    return i

def base_indent_of(lines, start, end):
    b = None
    for i in range(start, end):
        if is_code(lines[i]):
            b = indent_of(lines[i]) if b is None else min(b, indent_of(lines[i]))
    return b

def last_base_line(lines, start, end):
    b = base_indent_of(lines, start, end)
    if b is None:
        return None
    last = None
    for i in range(start, end):
        if is_code(lines[i]) and indent_of(lines[i]) == b:
            last = i
    return last

def arms_of_branch(lines, header_i, end):
    """The (index, indent) of each top-level arm of the `branch` at header_i."""
    b_indent = indent_of(lines[header_i])
    body_end = block_end(lines, header_i + 1, b_indent)
    body_end = min(body_end, end)
    arms = []
    for k in range(header_i + 1, body_end):
        if is_code(lines[k]):
            s = lines[k].strip()
            ai = indent_of(lines[k])
            if s.startswith("on ") or s == "else" or s.startswith("else "):
                arms.append((k, ai))
    if not arms:
        return [], body_end
    arm_indent = min(ai for _, ai in arms)
    return [(k, ai) for k, ai in arms if ai == arm_indent], body_end

def exits_safely(lines, body_start, body_end):
    """True if this block exits (return/raise) on every path we can see:
    its last base statement is terminal, or a branch whose every arm exits safely."""
    li = last_base_line(lines, body_start, body_end)
    if li is None:
        return False
    s = lines[li].strip()
    if s.startswith(TERMINALS):
        return True
    if s.startswith("branch"):
        arms, _ = arms_of_branch(lines, li, body_end)
        if not arms:
            return False
        for idx, (ak, ai) in enumerate(arms):
            arm_end = arms[idx + 1][0] if idx + 1 < len(arms) else block_end(lines, ak + 1, ai)
            if not exits_safely(lines, ak + 1, min(arm_end, body_end)):
                return False
        return True
    return False  # for/while/if/plain stmt → may fall through

def contains_return(lines, start, end):
    for i in range(start, end):
        if is_code(lines[i]) and lines[i].strip().startswith(("return", "raise")):
            return True
    return False

def lint_file(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        lines = f.read().split("\n")
    hits = []
    for i, line in enumerate(lines):
        m = re.match(r'^(\s*)def\s+(\w+)\s*\(.*\)\s*:\s*(\S.*?)\s*$', line)
        if not m:
            continue
        if m.group(3).strip() == "void":
            continue
        f_indent, fname = len(m.group(1)), m.group(2)
        f_end = block_end(lines, i + 1, f_indent)
        # The TCO hang only occurs when a `branch` is in TAIL position — the last
        # statement directly in the function body. A branch nested in a for/while
        # (fall-through continues the loop) or followed by a base-level `return`
        # (fall-through hits it) is safe. So: consider only the function's LAST
        # base-indent statement, and only when it is a `branch`.
        fbase = base_indent_of(lines, i + 1, f_end)
        if fbase is None:
            continue
        base_stmts = [k for k in range(i + 1, f_end)
                      if is_code(lines[k]) and indent_of(lines[k]) == fbase]
        if not base_stmts:
            continue
        tail = base_stmts[-1]
        if not lines[tail].strip().startswith("branch"):
            continue
        arms, b_end = arms_of_branch(lines, tail, f_end)
        for idx, (ak, ai) in enumerate(arms):
            arm_end = arms[idx + 1][0] if idx + 1 < len(arms) else block_end(lines, ak + 1, ai)
            arm_end = min(arm_end, b_end)
            if contains_return(lines, ak + 1, arm_end) and not exits_safely(lines, ak + 1, arm_end):
                hits.append((path, ak + 1, fname, lines[ak].strip()))
    return hits

def main():
    files = []
    for pat in (sys.argv[1:] or ["selfhost/*.zbr"]):
        files.extend(glob.glob(pat))
    hits = []
    for f in sorted(files):
        hits.extend(lint_file(f))
    for path, ln, fn, arm in hits:
        print(f"{path}:{ln}: value-returning fn `{fn}`: arm `{arm}` is value-producing but may fall through (TCO hang risk) -- add a terminal return")
    print(f"\n[fallthrough-lint] {len(hits)} hazard(s) across {len(files)} file(s)")
    sys.exit(1 if hits else 0)

if __name__ == "__main__":
    main()
