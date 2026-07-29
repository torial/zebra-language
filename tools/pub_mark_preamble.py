"""Mark the runtime preamble's declarations `pub` (#1 step 1).

The runtime-module change (docs/runtime_module_design.md) needs every preamble
declaration reachable from an emitted program to be `pub`, because emitted code
will `@import` the runtime instead of inlining it. `pub` at container scope is
legal — and inert — in a root file too, so this edit can land BEFORE any codegen
change and be validated by the ordinary gates while the preamble is still spliced
inline. That is the point of doing it first: it is the largest mechanical part of
the change and `zig` can prove it on its own.

Scope is `selfhost/stdlib_preamble.zig` only. The bootstrap hardcodes its own copy
of the pre-HELPERS header (build.zig strips that region from the file before
embedding the rest), and the bootstrap keeps inlining the runtime — it is not
becoming a runtime-module emitter. `pub` is a visibility marker with no effect on
an inlined file, so leaving the bootstrap's copy unmarked is not semantic drift.

What gets marked: a `fn`/`var`/`const`/`threadlocal var` declaration whose every
enclosing block is a CONTAINER (file scope, struct, union, enum, opaque). `pub` is
illegal on a statement inside a function body, so a non-container block poisons
everything nested in it. Brace depth is counted with comments and string / char
literals removed, since `"{s}"` and `// {` both occur in this file.

  python tools/pub_mark_preamble.py           # rewrite in place
  python tools/pub_mark_preamble.py --check   # report only; exit 1 if any unmarked
"""
import re
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PREAMBLE = ROOT / "selfhost" / "stdlib_preamble.zig"

QUOTE, BSLASH = chr(34), chr(92)

DECL = re.compile(r"^(\s*)(threadlocal var|inline fn|fn|var|const)\s+[A-Za-z_]")
OPENS_CONTAINER = re.compile(r"=\s*(?:packed\s+|extern\s+)?(?:struct|union|enum|opaque)\b")


def strip_noncode(line):
    """Remove // comments and string/char literal bodies so braces can be counted."""
    out, i, n = [], 0, len(line)
    in_str = in_chr = esc = False
    while i < n:
        c = line[i]
        if in_str or in_chr:
            if esc:
                esc = False
            elif c == BSLASH:
                esc = True
            elif in_str and c == QUOTE:
                in_str = False
            elif in_chr and c == "'":
                in_chr = False
        elif c == QUOTE:
            in_str = True
        elif c == "'":
            in_chr = True
        elif c == "/" and i + 1 < n and line[i + 1] == "/":
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def mark(lines):
    """Return (marked_lines, count) for a list of source lines without newlines."""
    stack, out, count = [], [], 0   # stack[k] is True when block k+1 is a container
    for raw in lines:
        stripped = raw.lstrip()
        # A Zig multiline-string line is data: never a declaration, and its braces
        # are literal text rather than block structure.
        is_data = stripped.startswith(BSLASH * 2)
        code = "" if is_data else strip_noncode(raw)

        m = None if is_data else DECL.match(raw)
        if m and all(stack) and not stripped.startswith("pub "):
            raw = m.group(1) + "pub " + stripped
            count += 1
        out.append(raw)

        opens_container = bool(OPENS_CONTAINER.search(code))
        for c in code:
            if c == "{":
                stack.append(opens_container)
            elif c == "}" and stack:
                stack.pop()
    return out, count


def main():
    text = PREAMBLE.read_text(encoding="utf-8", errors="surrogateescape")
    out, n = mark(text.split("\n"))
    print("%s: %d declaration(s) marked pub" % (PREAMBLE.name, n))
    if "--check" in sys.argv:
        return 1 if n else 0
    PREAMBLE.write_text("\n".join(out), encoding="utf-8",
                        errors="surrogateescape", newline="\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
