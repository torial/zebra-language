"""#1 phase 1: transform an emitted .zig into (zebra_rt.zig + program.zig).

This is the transformation the compiler will eventually perform inline. Doing it
first as a standalone tool means it can be validated against the WHOLE corpus
before any codegen is rewired — the emission surface for the mutable vars is 250+
sites embedded in string literals, so getting this wrong inside codegen would be
expensive to debug.

  python rtsplit.py <emitted.zig> <outdir>

Quote-awareness matters: the var qualification must not rewrite occurrences inside
Zig string literals (a user's `print("_allocator")` would otherwise be corrupted).
"""
import re
import sys
import pathlib

PRE = pathlib.Path(r"C:\Projects\zebra-language\selfhost\stdlib_preamble.zig")
RESERVED = {"std", "builtin"}
QUOTE, BSLASH = chr(34), chr(92)


def split_preamble(emit_lines, pre_lines):
    """Return (header, preamble, user). The preamble is spliced verbatim."""
    first = next(l for l in pre_lines if l.strip())
    start = next(i for i, l in enumerate(emit_lines) if l == first)
    return emit_lines[:start], emit_lines[start:start + len(pre_lines)], emit_lines[start + len(pre_lines):]


def qualify_outside_strings(line, names, prefix):
    """Rewrite bare `name` -> `prefix.name`, skipping Zig string/char literals."""
    out, i, n = [], 0, len(line)
    in_str = in_chr = esc = False
    tok = []

    def flush():
        if not tok:
            return
        w = "".join(tok)
        tok.clear()
        out.append(prefix + "." + w if w in names else w)

    while i < n:
        c = line[i]
        if in_str or in_chr:
            out.append(c)
            if esc:
                esc = False
            elif c == BSLASH:
                esc = True
            elif in_str and c == QUOTE:
                in_str = False
            elif in_chr and c == "'":
                in_chr = False
        elif c == QUOTE:
            flush(); out.append(c); in_str = True
        elif c == "'":
            flush(); out.append(c); in_chr = True
        elif c.isalnum() or c == "_":
            tok.append(c)
        else:
            flush(); out.append(c)
        i += 1
    flush()
    return "".join(out)


def main():
    emit_path, outdir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    outdir.mkdir(parents=True, exist_ok=True)

    pre = PRE.read_text(encoding="utf-8", errors="surrogateescape").split("\n")
    while pre and not pre[-1].strip():
        pre.pop()
    emit = emit_path.read_text(encoding="utf-8", errors="surrogateescape").split("\n")
    header, preamble, user = split_preamble(emit, pre)

    # runtime module: everything public
    decl = re.compile(r"^(fn |var |const |threadlocal var )")
    member = re.compile(r"^(\s+)(fn |const |var )")
    opens_type = re.compile(r"^(pub )?const [A-Za-z_][A-Za-z0-9_]* = (struct|union|enum|opaque)")

    # Top-level decls become pub. Members of top-level TYPES must also be pub when
    # user code calls them (e.g. `_TsAlloc.allocator`, a callback struct's `call`) —
    # but `pub` is ILLEGAL on a function-local, so track whether the enclosing
    # top-level block is a type declaration rather than pubbing every indented line.
    rt, in_type, depth = [], False, 0
    for l in preamble:
        if decl.match(l):
            if opens_type.match("pub " + l) or opens_type.match(l):
                in_type, depth = True, 0
            elif l.startswith("fn "):
                in_type = False
            rt.append("pub " + l)
        else:
            m = member.match(l)
            if in_type and depth >= 1 and m and not l.lstrip().startswith("pub "):
                rt.append(m.group(1) + "pub " + l.lstrip())
            else:
                rt.append(l)
        depth += l.count("{") - l.count("}")
        if depth <= 0:
            in_type = False
            depth = 0
    # Break the backward dependency: the preamble's _initIo calls _initModuleVars(),
    # which codegen emits into the USER file — a shared runtime cannot call a
    # per-program function. The entry module's `main` already calls it directly, and
    # dependency init is the fan-out that BUG-221's fix removes anyway.
    rt = [("    // _initModuleVars(); // removed: per-program, called from main"
           if l.strip() == "_initModuleVars();" else l) for l in rt]

    name_re = re.compile(r"^pub (?:threadlocal var|fn|var|const) ([A-Za-z_][A-Za-z0-9_]*)")
    exported = {m.group(1) for m in (name_re.match(l) for l in rt) if m} - RESERVED

    var_re = re.compile(r"^pub (?:threadlocal var|var) ([A-Za-z_][A-Za-z0-9_]*)")
    mutable = {m.group(1) for m in (var_re.match(l) for l in rt) if m} - RESERVED
    aliasable = exported - mutable

    # user section: qualify mutable vars, alias the rest
    user = [qualify_outside_strings(l, mutable, "_rt") for l in user]
    user_text = "\n".join(user)
    used = sorted(n for n in aliasable
                  if re.search(r"(?<![A-Za-z0-9_])" + re.escape(n) + r"(?![A-Za-z0-9_])", user_text))

    (outdir / "zebra_rt.zig").write_text("\n".join(header + rt) + "\n",
                                         encoding="utf-8", errors="surrogateescape", newline="\n")
    head = ['const std = @import("std");', 'const _rt = @import("zebra_rt.zig");']
    head += ["const %s = _rt.%s;" % (n, n) for n in used]
    head.append("")
    prog = outdir / (emit_path.stem + ".zig")
    prog.write_text("\n".join(head + user) + "\n",
                    encoding="utf-8", errors="surrogateescape", newline="\n")

    print("%s: %d -> %d lines (%d aliases, %d vars qualified)"
          % (emit_path.name, len(emit), len(head) + len(user), len(used), len(mutable)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
