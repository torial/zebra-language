"""Strip U+FEFF (zero-width no-break space / BOM) and U+FE0F (variation
selector-16) from every .md file under the book root.

Both are invisible glyphs — the BOM is almost certainly a stray
copy-paste from emoji-source-code, and FE0F only matters when an
emoji presentation engine cares about emoji-vs-text.  Neither has
useful semantics in book prose.
"""
from pathlib import Path

ROOT = Path("C:/Projects/zebra-language-book")
PARTS = [
    "Part-1-Foundations",
    "Part-2-Objects-and-Interfaces",
    "Part-3-Advanced-Features",
    "Part-4-Practical-Projects",
    "Part-5-Ecosystem",
]
TARGETS = ["﻿", "️"]

total = 0
for part in PARTS:
    for md in (ROOT / part).glob("*.md"):
        text = md.read_text(encoding="utf-8")
        new = text
        for t in TARGETS:
            new = new.replace(t, "")
        if new != text:
            md.write_text(new, encoding="utf-8", newline="\n")
            removed = sum(text.count(t) for t in TARGETS)
            total += removed
            print(f"{md.relative_to(ROOT).as_posix()}: removed {removed}")
print(f"total: {total}")
