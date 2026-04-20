#!/usr/bin/env python3
"""
Migrate Zebra source files from `as T` type annotation syntax to `: T`.

Rules:
  - Replace ` as ` with `: ` on lines that are NOT branch-on binding lines.
  - A branch-on line starts with optional whitespace followed by `on `.
  - `on Expr as id` (branch binding) keeps `as`.
  - Does NOT touch string literals or comments containing "as" on other lines
    because simple token replacement is safe: outside of `on` lines, ` as `
    only appears in type-annotation positions per the Zebra grammar.

Also handles is-capture migration:
  - In test/if_is_capture_test.zbr: `|r|` patterns after `if`/`else if` → `as r`

Usage:
  python tools/migrate_colon_syntax.py [--dry-run] [path ...]
"""
import re
import sys
import os
from pathlib import Path

DRY_RUN = "--dry-run" in sys.argv
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]

# Pattern: ` as ` preceded by a non-`on` context
# We transform every line that does NOT start (after stripping) with `on `.
AS_ANNOT_RE = re.compile(r' as (?=[A-Za-z\^?!])')

# is-capture: `|id|` after an expression (for if/else-if capture form)
# Only in the is-capture test file
IS_CAPTURE_RE = re.compile(r'\|(\w+)\|')


def is_on_line(stripped: str) -> bool:
    """True if this is a branch `on` clause line (keep `as`)."""
    return stripped.startswith("on ")


def migrate_line(line: str, in_zig_snippet: bool = False) -> str:
    """Migrate a single line of Zebra source."""
    stripped = line.lstrip()

    # Inside Zig test snippets: the actual Zebra line is after `\\ `
    if in_zig_snippet:
        # Match `\\    on foo as bar` → skip
        # Strip/restore trailing newline to avoid false change-counts from `(.*)` dot.
        trailing = "\n" if line.endswith("\n") else ""
        stripped_line = line.rstrip("\n")
        m = re.match(r'(\s*\\\\)(\s*)(.*)', stripped_line)
        if m:
            prefix, indent, rest = m.group(1), m.group(2), m.group(3)
            rest_stripped = rest.lstrip()
            # Skip branch-on lines and comment lines (not actual Zebra code)
            if is_on_line(rest_stripped):
                return line
            if rest_stripped.startswith("///") or rest_stripped.startswith("//") or rest_stripped.startswith("#"):
                return line
            new_rest = AS_ANNOT_RE.sub(': ', rest)
            return prefix + indent + new_rest + trailing
        return line

    # Regular .zbr lines
    if is_on_line(stripped):
        return line

    return AS_ANNOT_RE.sub(': ', line)


def migrate_file(path: Path, is_capture_migration: bool = False) -> int:
    """Migrate a file in place. Returns number of changed lines."""
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)

    is_zig = path.suffix == ".zig"
    new_lines = []
    changes = 0

    for line in lines:
        new_line = migrate_line(line, in_zig_snippet=is_zig)
        if is_capture_migration:
            # Also migrate |r| → as r in is-capture positions
            # Only on if/else-if lines (not on-branch lines)
            stripped = new_line.lstrip()
            if (stripped.startswith("if ") or stripped.startswith("else if ")):
                new_line2 = IS_CAPTURE_RE.sub(lambda m: f'as {m.group(1)}', new_line)
                if new_line2 != new_line:
                    new_line = new_line2
        if new_line != line:
            changes += 1
        new_lines.append(new_line)

    if changes > 0:
        print(f"  {path}: {changes} line(s) changed")
        if not DRY_RUN:
            path.write_text("".join(new_lines), encoding="utf-8")

    return changes


def collect_paths(roots):
    paths = []
    for root in roots:
        p = Path(root)
        if p.is_file():
            paths.append(p)
        elif p.is_dir():
            paths.extend(p.rglob("*.zbr"))
    return paths


def main():
    repo = Path(__file__).parent.parent

    if ARGS:
        zbr_paths = collect_paths(ARGS)
        zig_paths = []
    else:
        zbr_paths = list((repo / "selfhost").rglob("*.zbr"))
        zbr_paths += list((repo / "test").rglob("*.zbr"))
        zbr_paths += list((repo / "examples").rglob("*.zbr"))
        zig_paths = [
            repo / "src" / "CodeGen.zig",
            repo / "src" / "TypeChecker.zig",
            repo / "src" / "Resolver.zig",
        ]

    is_capture_file = repo / "test" / "if_is_capture_test.zbr"

    total = 0
    print("=== .zbr files ===")
    for p in sorted(zbr_paths):
        is_cap = (p.resolve() == is_capture_file.resolve())
        total += migrate_file(p, is_capture_migration=is_cap)

    if zig_paths:
        print("=== inline Zig snippets ===")
        for p in zig_paths:
            total += migrate_file(p)

    print(f"\nTotal lines changed: {total}")
    if DRY_RUN:
        print("(dry run — no files written)")


if __name__ == "__main__":
    main()
