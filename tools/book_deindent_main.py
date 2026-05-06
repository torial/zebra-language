"""De-indent over-indented `def main()` bodies in book chapters.

After bulk-replacing `class Main / static / def main` with bare `def main()`,
the bodies that were nested 3 levels deep (12 spaces) are now flat under the
top-level def — they should be at 4 spaces, not 12.

Strategy: walk each line. Inside a fenced ```zebra block, after seeing a
`def main()` at column 0, drop 8 spaces from each subsequent body line until
the block ends or a blank line followed by a non-indented line breaks the body.
"""
from pathlib import Path
import sys

def fix_file(path: Path) -> int:
    text = path.read_text(encoding="utf-8", newline="\n")
    lines = text.split("\n")
    out = []
    in_fence = False
    in_main_body = False
    fixed = 0

    for line in lines:
        stripped_left = line.lstrip()

        if line.startswith("```zebra"):
            in_fence = True
            in_main_body = False
            out.append(line)
            continue
        if in_fence and line.strip() == "```":
            in_fence = False
            in_main_body = False
            out.append(line)
            continue

        if in_fence:
            # Detect entry into main body
            if line == "def main()" or line.startswith("def main()"):
                # only at column 0 — treat as our entry
                if not line.startswith(" "):
                    in_main_body = True
                    out.append(line)
                    continue

            if in_main_body:
                # End body when a non-indented, non-empty line appears.
                if line and not line.startswith(" "):
                    in_main_body = False
                    out.append(line)
                    continue
                # Body line: if 12+ spaces of leading indent, strip 8.
                if line.startswith("            "):  # 12+ spaces
                    out.append(line[8:])
                    fixed += 1
                    continue
                # Lesser indent: leave as-is (already-fixed lines from later fixes)
                out.append(line)
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
        print(f"{path.name}: fixed {n} lines")
    print(f"total: {total}")
