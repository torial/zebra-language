#!/usr/bin/env python3
"""Sweep: class Main { static { ... } } -> top-level defs.

Converts the old entry-point pattern:
    class Main
        static
            def foo(params): RetType
                body
            def main
                body

to:
    def foo(params): RetType
        body
    def main()
        body

Also rewrites `Main.method(` -> `method(` for any lifted methods
(the caller used the class-qualified form before they were top-level).

Run from the repo root: python tools/sweep_class_main.py [--dry-run]
"""

import re
import sys
import glob
import os


def find_class_main_extent(lines):
    """Return (start, end) for the class Main block, or None."""
    start = None
    for i, line in enumerate(lines):
        if line.rstrip() == 'class Main':
            start = i
            break
    if start is None:
        return None
    # The block runs until the next non-blank line at column 0.
    end = len(lines)
    for i in range(start + 1, len(lines)):
        s = lines[i].rstrip()
        if s and not lines[i][0].isspace():
            end = i
            break
    return (start, end)


def static_method_names(lines, start, end):
    """Return names of all defs at the 8-space level inside the block."""
    names = []
    for line in lines[start:end]:
        if line.startswith('        '):
            m = re.match(r'        def (\w+)', line)
            if m:
                names.append(m.group(1))
    return names


def transform(content):
    lines = content.split('\n')

    result = find_class_main_extent(lines)
    if result is None:
        return None   # nothing to do

    start, end = result

    # Find the '    static' line — must immediately follow class Main.
    static_idx = None
    for i in range(start + 1, end):
        s = lines[i].rstrip()
        if s == '    static':
            static_idx = i
            break
        if s:
            return None  # unexpected structure; leave file alone

    if static_idx is None:
        return None

    # Names of all defs at the 8-space level (to rewrite Main.foo( -> foo().
    lifted = static_method_names(lines, start, end)

    out = []
    out.extend(lines[:start])          # before class Main

    # Lift the static content (lines after '    static', up to end).
    for line in lines[static_idx + 1:end]:
        stripped = line.rstrip()
        if stripped == '':
            out.append('')
            continue
        if line.startswith('        '):
            new = line[8:]             # remove 8-space prefix
            if new.rstrip() == 'def main':
                new = 'def main()'
            out.append(new)
        else:
            out.append(line)           # shouldn't happen; pass through

    out.extend(lines[end:])            # after class Main

    text = '\n'.join(out)

    # Rewrite Main.foo( -> foo( for every lifted method except 'main'
    # (main's call site is the entry thunk, not user code).
    for name in lifted:
        if name != 'main':
            text = text.replace(f'Main.{name}(', f'{name}(')

    return text


def main():
    dry_run = '--dry-run' in sys.argv

    patterns = [
        'test/**/*.zbr',
        'examples/**/*.zbr',
        'selfhost/**/*.zbr',
        'tools/**/*.zbr',
        'IDE/**/*.zbr',
    ]

    changed = []
    skipped = []

    for pattern in patterns:
        for path in sorted(glob.glob(pattern, recursive=True)):
            with open(path, 'r', encoding='utf-8', newline='') as f:
                original = f.read()
            result = transform(original)
            if result is None:
                skipped.append(path)
                continue
            if result == original:
                skipped.append(path)
                continue
            changed.append(path)
            if not dry_run:
                with open(path, 'w', encoding='utf-8', newline='\n') as f:
                    f.write(result)
                print(f'  converted: {path}')
            else:
                print(f'  [dry-run] would convert: {path}')

    print(f'\n{len(changed)} files {"would be " if dry_run else ""}converted, '
          f'{len(skipped)} already clean or skipped.')


if __name__ == '__main__':
    main()
