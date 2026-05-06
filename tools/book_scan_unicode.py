"""Scan the book for non-ASCII characters and report a histogram.

Lets us see which characters likely fail to render before kicking off
a full PDF build (faster iteration).
"""
from pathlib import Path
from collections import Counter
import sys
import unicodedata

ROOT = Path("C:/Projects/zebra-language-book")

PARTS = [
    "Part-1-Foundations",
    "Part-2-Objects-and-Interfaces",
    "Part-3-Advanced-Features",
    "Part-4-Practical-Projects",
    "Part-5-Ecosystem",
]

counts = Counter()
files_for = {}  # ch -> set of file paths
sample_for = {}  # ch -> first sample line

for part in PARTS:
    for md in (ROOT / part).glob("*.md"):
        text = md.read_text(encoding="utf-8")
        for line in text.split("\n"):
            for c in line:
                if ord(c) >= 128:
                    counts[c] += 1
                    files_for.setdefault(c, set()).add(md.name)
                    if c not in sample_for:
                        sample_for[c] = line.strip()[:120]

# Sort by frequency desc.  Write UTF-8 to a file so the Windows
# cp1252 console doesn't choke on emoji.
out = Path("C:/tmp/unicode_report.txt")
with out.open("w", encoding="utf-8", newline="\n") as f:
    f.write(f"{'Code':<8} {'Count':>6}  {'Name':<55}  Sample / Files\n")
    f.write("-" * 140 + "\n")
    for ch, n in counts.most_common():
        name = unicodedata.name(ch, "?")
        files = sorted(files_for[ch])
        files_short = files[0] if len(files) == 1 else f"{files[0]} (+{len(files)-1} more)"
        code = f"U+{ord(ch):04X}"
        f.write(f"{code:<8} {n:>6}  {name:<55}  [{ch}]  {files_short}\n")
print(f"wrote {out}")
