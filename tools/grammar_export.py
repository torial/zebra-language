#!/usr/bin/env python3
"""grammar_export.py -- generate grammar.txt from the parser's ACTUAL rule table.

Regression guard for BUG-255: `--check` is a QUICK-tier gate, so the document and the
rule table cannot drift apart again without a red board.

WHY
---
`grammar.txt` is a 520-line hand-maintained BNF. The Earley parser's real grammar lives in
`src/ZebraGrammar.zig` as 474 comptime rule literals. Two copies of the same thing, one of
which is compiled and one of which is prose, is a drift generator -- and the drift is not
cosmetic:

  * `fuzz/gramgen.py` derives its 960 deterministic programs FROM grammar.txt. If that file
    has diverged, the parser-robustness gate is exploring a language that does not exist.
  * Anyone (human or agent) checking "is this valid syntax?" reads grammar.txt. Three probes
    in one session on 2026-08-04 were written in syntax Zebra does not have (`&`, `/=`,
    `[|...|]`), each producing a parse error that briefly looked like a finding.

WHAT IT DOES
------------
Parses the rule literals out of ZebraGrammar.zig and renders them in grammar.txt's existing
notation (`Name -> Sym Sym`, alternatives under `|`, empty productions as ε). Terminals and
nonterminals are rendered identically, matching the file's existing convention.

  --check   compare against grammar.txt, exit 1 on any difference (gate-shaped)
  --write   regenerate grammar.txt
  default   print a summary and the first differences

THE RULE TABLE IS THE AUTHORITY, NOT THIS FILE. A difference means grammar.txt is stale, or
the extractor has stopped understanding a rule shape -- and the second is why the controls
below exist rather than trusting a clean diff.

WHAT THIS CANNOT SAY: whether the grammar is CORRECT, only that the document matches the
table. Precedence encoded via nonterminal layering, and anything the parser does outside the
Earley table (the tokenizer's indent/dedent synthesis especially), are invisible here.
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SRC = REPO / "src" / "ZebraGrammar.zig"
DOC = REPO / "grammar.txt"

# `.{ .lhs = .Name, .rhs = &.{ n(.A), t(.b) } }` -- rhs may span lines.
RULE = re.compile(r'\.\{\s*\.lhs\s*=\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*,\s*'
                  r'\.rhs\s*=\s*&\.\{(.*?)\}\s*\}', re.S)
SYM = re.compile(r'\b[nt]\(\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*\)')


def extract(text):
    """[(lhs, [sym, ...])] in source order."""
    out = []
    for m in RULE.finditer(text):
        out.append((m.group(1), SYM.findall(m.group(2))))
    return out


def render(rules):
    """grammar.txt notation: one block per LHS, alternatives aligned under `|`."""
    order, alts = [], {}
    for lhs, rhs in rules:
        if lhs not in alts:
            alts[lhs] = []
            order.append(lhs)
        body = " ".join(rhs) if rhs else "ε"
        if body not in alts[lhs]:
            alts[lhs].append(body)
    width = max((len(k) for k in order), default=20)
    width = max(width, 20)
    lines = []
    for lhs in order:
        first, rest = alts[lhs][0], alts[lhs][1:]
        lines.append(f"{lhs.ljust(width)} → {first}")
        for a in rest:
            lines.append(f"{' ' * width} |  {a}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main():
    argv = sys.argv[1:]
    if not SRC.is_file():
        print(f"REFUSING TO REPORT: {SRC} missing.")
        return 2
    rules = extract(SRC.read_text(encoding="utf-8"))

    # CONTROLS. A regex that has stopped matching produces a SHORT grammar, and a short
    # grammar diffed against a real one looks like "the document is hugely stale" -- a
    # confident wrong answer in the reassuring direction (blame the doc, not the tool).
    if len(rules) < 400:
        print(f"REFUSING TO REPORT: extracted only {len(rules)} rules from a file with "
              f"{SRC.read_text(encoding='utf-8').count('.lhs = .')} `.lhs` literals. The "
              f"rule-shape regex has stopped matching; any diff would blame the document "
              f"for the extractor's failure.")
        return 2
    if not any(l == "Program" and r == ["TopDeclList", "eof"] for l, r in rules):
        print("REFUSING TO REPORT: the start rule `Program → TopDeclList eof` was not "
              "extracted. The parser cannot see what it is supposed to see.")
        return 2

    text = render(rules)
    lhs_count = len({l for l, _ in rules})

    if "--write" in argv:
        DOC.write_text(text, encoding="utf-8", newline="\n")
        print(f"wrote {DOC.name}: {len(rules)} rules, {lhs_count} nonterminals")
        return 0

    if not DOC.is_file():
        print(f"{DOC.name} missing; --write to create it ({len(rules)} rules)")
        return 1

    current = DOC.read_text(encoding="utf-8")
    if current == text:
        print(f"grammar.txt matches the rule table ({len(rules)} rules, "
              f"{lhs_count} nonterminals)")
        return 0

    # Report WHICH nonterminals differ, not a raw text diff -- a formatting change would
    # otherwise drown the productions that actually moved.
    def by_lhs(t):
        d, cur = {}, None
        for ln in t.split("\n"):
            m = re.match(r'^(\S+)\s+→\s*(.*)$', ln)
            if m:
                cur = m.group(1)
                d.setdefault(cur, []).append(m.group(2).strip())
            elif ln.strip().startswith("|") and cur:
                d[cur].append(ln.strip()[1:].strip())
        return d

    gen, doc = by_lhs(text), by_lhs(current)
    only_gen = sorted(set(gen) - set(doc))
    only_doc = sorted(set(doc) - set(gen))
    differing = sorted(k for k in set(gen) & set(doc) if gen[k] != doc[k])

    print(f"grammar.txt DIFFERS from the rule table.")
    print(f"  rules in table: {len(rules)}   nonterminals: {lhs_count}")
    print(f"  in the PARSER but not the document: {len(only_gen)}")
    for k in only_gen[:10]:
        print(f"      {k}")
    print(f"  in the DOCUMENT but not the parser: {len(only_doc)}")
    for k in only_doc[:10]:
        print(f"      {k}")
    print(f"  productions differ: {len(differing)}")
    for k in differing[:10]:
        print(f"      {k}")
        for a in sorted(set(gen[k]) - set(doc[k]))[:3]:
            print(f"          parser only:   {a}")
        for a in sorted(set(doc[k]) - set(gen[k]))[:3]:
            print(f"          document only: {a}")
    print("\nThe RULE TABLE is the authority. `--write` to regenerate.")
    return 1 if "--check" in argv else 0


if __name__ == "__main__":
    sys.exit(main())
