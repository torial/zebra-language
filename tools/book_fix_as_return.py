"""Replace `def name(params) as Type` -> `def name(params): Type` in code blocks.

Operates only inside ```zebra fenced blocks to avoid mangling prose that
quotes the old form. Idempotent.
"""
from pathlib import Path
import re
import sys

# `def name(<params>) as TypeRef` (with optional `throws`)
# captures the part before `as` and the type after, plus any trailing keywords.
# Use a simple line-by-line regex: match "  def NAME(...) as " and replace.
# `def NAME(...whatever, may have nested parens...) as TypeRef[ throws]`
# Match a `def` line that ends `) as TYPE` (with optional `throws`).
# We use the rule "the LAST ' as ' before EOL" — simpler than nested-paren matching.
PAT = re.compile(r'^(\s*(?:static\s+)?def\s+\w+.*\))\s+as\s+(.+)$')


def fix_file(path: Path) -> int:
    text = path.read_text(encoding="utf-8", newline="\n")
    lines = text.split("\n")
    out = []
    in_fence = False
    fixed = 0
    for line in lines:
        if line.startswith("```zebra"):
            in_fence = True
            out.append(line)
            continue
        if in_fence and line.strip() == "```":
            in_fence = False
            out.append(line)
            continue
        if in_fence:
            m = PAT.match(line)
            if m:
                # Replace `as TypeRef` with `: TypeRef`
                new = f"{m.group(1)}: {m.group(2)}"
                out.append(new)
                fixed += 1
                continue
        out.append(line)
    new_text = "\n".join(out)
    if new_text != text:
        path.write_text(new_text, encoding="utf-8", newline="\n")
    return fixed


if __name__ == "__main__":
    total = 0
    for p in sys.argv[1:]:
        path = Path(p)
        n = fix_file(path)
        total += n
        if n:
            print(f"{path.name}: fixed {n} returns")
    print(f"total: {total}")
