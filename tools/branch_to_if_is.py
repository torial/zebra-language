#!/usr/bin/env python3
"""
Convert single-arm branch-on-as with else-pass to if-is-as form.

  branch SUBJECT
      on VARIANT as BINDING
          BODY...
      else
          pass

→

  if SUBJECT is VARIANT as BINDING
      BODY...

Only converts when:
  - exactly one `on ... as ...` arm (binding required)
  - else block contains only `pass` (single statement, ignoring blank/comment lines)

Usage: python tools/branch_to_if_is.py [--dry-run] [file ...]
"""
import re, sys
from pathlib import Path

DRY_RUN = "--dry-run" in sys.argv
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]

def leading_spaces(s):
    return len(s) - len(s.lstrip(" "))

def transform_file(path: Path) -> int:
    text = path.read_bytes().decode("utf-8")
    lines = text.splitlines(keepends=True)
    out = []
    i = 0
    changes = 0

    while i < len(lines):
        raw = lines[i]
        stripped = raw.rstrip("\n").rstrip("\r")
        content = stripped.lstrip()
        b_indent = leading_spaces(stripped)

        # Match `branch SUBJECT`
        m = re.match(r'^branch\s+(.+)$', content)
        if not m:
            out.append(raw)
            i += 1
            continue

        subject = m.group(1).strip()
        on_indent = None   # indent of 'on'/'else' keywords
        body_indent = None # indent of on-arm body lines
        on_variant = None
        on_binding = None
        on_body_lines = []  # raw lines of on-arm body
        else_body_lines = []  # raw lines of else body (ignoring blank lines)
        state = "start"
        j = i + 1

        while j < len(lines):
            raw2 = lines[j]
            s2 = raw2.rstrip("\n").rstrip("\r")
            c2 = s2.lstrip()
            ind2 = leading_spaces(s2)

            # Empty/blank lines: include in current body collection
            if not c2:
                if state == "on_body":
                    on_body_lines.append(raw2)
                elif state == "else_body":
                    else_body_lines.append(raw2)
                j += 1
                continue

            # Back to branch indent or less → block ends
            if ind2 <= b_indent:
                break

            if state == "start":
                on_indent = ind2
                # Must be an `on VAR as BINDING` line
                om = re.match(r'^on\s+(\S.*?)\s+as\s+(\w+)$', c2)
                if om:
                    on_variant = om.group(1).strip()
                    on_binding = om.group(2).strip()
                    state = "on_body"
                else:
                    # Not a single on-as arm — bail
                    state = "abort"
                    break

            elif state == "on_body":
                if ind2 == on_indent and (c2.startswith("on ") or c2 == "else" or c2.startswith("else ")):
                    # Another on arm or else
                    if c2.startswith("on "):
                        # Multiple on arms → abort
                        state = "abort"
                        break
                    else:
                        # else clause
                        state = "else_body"
                else:
                    if body_indent is None and c2:
                        body_indent = ind2
                    on_body_lines.append(raw2)

            elif state == "else_body":
                else_body_lines.append(raw2)

            j += 1

        if state == "abort" or on_variant is None:
            out.append(raw)
            i += 1
            continue

        # Check else body is exactly `pass` (ignoring blank lines)
        non_blank_else = [l.rstrip("\n").rstrip("\r").strip() for l in else_body_lines if l.strip()]
        if non_blank_else != ["pass"]:
            out.append(raw)
            i += 1
            continue

        # Trim trailing blank lines from on_body
        while on_body_lines and not on_body_lines[-1].strip():
            on_body_lines.pop()

        # Calculate indent shift: body goes from body_indent → b_indent + (body_indent - on_indent)
        # i.e., reduce each body line by on_indent - b_indent spaces
        indent_reduction = (on_indent or b_indent + 4) - b_indent

        def shift_line(raw_line):
            s = raw_line.rstrip("\n").rstrip("\r")
            cur = leading_spaces(s)
            new_indent = max(0, cur - indent_reduction)
            return " " * new_indent + s.lstrip() + "\n"

        # Emit the if statement
        prefix = " " * b_indent
        out.append(f"{prefix}if {subject} is {on_variant} as {on_binding}\n")
        for bl in on_body_lines:
            out.append(shift_line(bl))

        changes += 1
        i = j  # skip to after the branch block

    if changes > 0:
        new_text = "".join(out)
        print(f"  {path}: {changes} branch(es) converted")
        if not DRY_RUN:
            path.write_bytes(new_text.encode("utf-8"))
    return changes


def main():
    if ARGS:
        paths = [Path(a) for a in ARGS]
    else:
        repo = Path(__file__).parent.parent
        paths = (list((repo / "selfhost").rglob("*.zbr")) +
                 list((repo / "test").rglob("*.zbr")))

    total = 0
    for p in sorted(paths):
        total += transform_file(p)
    print(f"\nTotal branches converted: {total}")
    if DRY_RUN:
        print("(dry run)")


if __name__ == "__main__":
    main()
