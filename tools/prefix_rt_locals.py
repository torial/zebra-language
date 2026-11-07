#!/usr/bin/env python3
"""Prefix every bare local and parameter name in selfhost/zebra_rt.v (docket item 6, 2026-10-26).

The runtime file is compiled into the same V module as every emitted program, so a local or a
parameter there shares one namespace with the program's consts, and V 0.5.2 silently miscompiles
a local that shadows a const (v_backend_poc.md item 22: `&tmp[0]` lowered against
`_const_main__tmp`). The zfmt block carries `zf_`; everything else gets `zr_` here.

    python tools/prefix_rt_locals.py            # dry run: the plan, per function, nothing written
    python tools/prefix_rt_locals.py --apply    # rewrite selfhost/zebra_rt.v in place
    python tools/prefix_rt_locals.py --control  # prove the renamer sees: a scratch function with a
                                                # bare local must be rewritten, a prefixed one left

What is renamed, inside one top-level `fn` at a time: its receiver and parameters, and every
local declared in its body (`x :=`, `mut x :=`, `a, b :=`, `for x in`, `for i := 0;`, `if x :=`,
`x := f() or {`). Every whole-word occurrence of such a name in that function is rewritten,
including inside `${...}` of an interpolated string, EXCEPT after a `.` (a field or a method),
before a `:` that is not `:=` (a struct literal's field), inside a string literal's plain text,
and inside a backtick char literal. Names already prefixed (`zf_`, `zr_`), `_`, `it`, `err`,
`none`, V keywords and builtin type names are left alone. The file's top-level declarations
(consts, globals, structs, interfaces) are never touched: a struct field's name is read through
`.name`, which the dot rule leaves, and a const is what the rule protects.

The tool refuses to write if, after the rewrite, any function still declares a bare local (its
own re-scan), and prints the first such line: a checker that stopped checking must not look like
one that found nothing.
"""
import re
import sys

PATH = "selfhost/zebra_rt.v"
KEYWORDS = {
    "as", "asm", "assert", "atomic", "break", "const", "continue", "defer", "else", "enum", "false",
    "fn", "for", "go", "goto", "if", "import", "in", "interface", "is", "isreftype", "lock", "match",
    "module", "mut", "none", "or", "pub", "return", "rlock", "select", "shared", "sizeof", "spawn",
    "static", "struct", "true", "type", "typeof", "union", "unsafe", "volatile", "__global",
    "__offsetof", "dump", "it", "err", "_", "nil", "voidptr", "byteptr", "charptr", "string",
    "bool", "int", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "rune",
    "isize", "usize", "any", "thread", "chan", "map", "array", "C",
}
IDENT = r"[a-z_][A-Za-z0-9_]*"
FN_HEAD = re.compile(r"^(pub )?fn\s+(\(\s*(mut\s+)?(" + IDENT + r")\s+[^)]*\)\s*)?(" + IDENT + r")\s*(\[[^\]]*\])?\s*\((.*)\)\s*(.*)\{\s*$")


def split_params(text):
    """Parameter names of `a int, mut b []u8, c ...string` (a receiver is handled by FN_HEAD)."""
    names = []
    depth = 0
    cur = []
    parts = []
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    for part in parts:
        part = part.strip()
        if not part:
            continue
        m = re.match(r"(mut\s+|shared\s+)?(" + IDENT + r")\s", part)
        if m:
            names.append(m.group(2))
    return names


DECLS = [
    re.compile(r"^\s*(?:mut\s+)?(" + IDENT + r"(?:\s*,\s*(?:mut\s+)?" + IDENT + r")*)\s*:="),
    re.compile(r"^\s*for\s+(?:mut\s+)?(" + IDENT + r")(?:\s*,\s*(?:mut\s+)?(" + IDENT + r"))?\s+in\s"),
    re.compile(r"^\s*for\s+(?:mut\s+)?(" + IDENT + r")\s*:="),
    re.compile(r"^\s*(?:\}\s*)?(?:else\s+)?if\s+(?:mut\s+)?(" + IDENT + r")\s*:="),
    re.compile(r"\bor\s*\{\s*(" + IDENT + r")\s*:="),
]


def declared_locals(body_lines):
    names = []
    for line in body_lines:
        for rx in DECLS:
            m = rx.search(line)
            if not m:
                continue
            for g in m.groups():
                if not g:
                    continue
                for n in re.split(r"\s*,\s*", g):
                    n = n.replace("mut ", "").strip()
                    if n:
                        names.append(n)
    return names


def rename_in_code(text, names):
    """Rename whole-word names in a code segment (no string literals inside)."""
    if not names:
        return text
    rx = re.compile(r"(?<![A-Za-z0-9_])(" + "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True)) + r")(?![A-Za-z0-9_])")

    def sub(m):
        n = m.group(1)
        end = m.end()
        start = m.start()
        # after a single `.` it is a field or a method; after a range's `..` it is a local
        if start >= 1 and text[start - 1] == "." and not (start >= 2 and text[start - 2] == "."):
            return n
        # a struct literal's field (`name: value`) but not a declaration (`name :=`)
        rest = text[end:end + 2]
        if rest.startswith(":") and not rest.startswith(":="):
            return n
        return "zr_" + n

    return rx.sub(sub, text)


def rename_line(line, names):
    """Walk a line's string and char literals; rename in code and inside ${...} of strings."""
    out = []
    i = 0
    n = len(line)
    code_start = 0
    while i < n:
        ch = line[i]
        if ch == "/" and line.startswith("//", i):
            out.append(rename_in_code(line[code_start:i], names))
            out.append(line[i:])
            return "".join(out)
        if ch == "`":
            # a char literal: `x` or `\n` -- flushed as it is (the first cut renamed `b` to
            # `zr_b` inside one: the literal was skipped but never cut out of the code segment)
            out.append(rename_in_code(line[code_start:i], names))
            j = i + 1
            while j < n and line[j] != "`":
                if line[j] == "\\":
                    j += 1
                j += 1
            out.append(line[i:j + 1])
            i = j + 1
            code_start = i
            continue
        if ch in "'\"":
            out.append(rename_in_code(line[code_start:i], names))
            quote = ch
            j = i + 1
            seg = [quote]
            raw = i > 0 and line[i - 1] in "rc"
            while j < n and line[j] != quote:
                if line[j] == "\\":
                    seg.append(line[j:j + 2])
                    j += 2
                    continue
                if not raw and line.startswith("${", j):
                    k = j + 2
                    depth = 1
                    while k < n and depth:
                        if line[k] == "{":
                            depth += 1
                        elif line[k] == "}":
                            depth -= 1
                        k += 1
                    inner = line[j + 2:k - 1]
                    seg.append("${" + rename_in_code(inner, names) + "}")
                    j = k
                    continue
                seg.append(line[j])
                j += 1
            seg.append(quote)
            out.append("".join(seg))
            i = j + 1
            code_start = i
            continue
        i += 1
    out.append(rename_in_code(line[code_start:], names))
    return "".join(out)


def process(lines):
    """Rewrite every top-level fn; return (new_lines, plan) where plan lists (fn, names)."""
    out = []
    plan = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        m = FN_HEAD.match(line)
        if not m:
            out.append(line)
            i += 1
            continue
        # the body runs to the first line that is exactly "}"
        j = i + 1
        while j < n and lines[j] != "}":
            j += 1
        head = line
        body = lines[i + 1:j]
        names = set()
        if m.group(4):
            names.add(m.group(4))
        names.update(split_params(m.group(7)))
        names.update(declared_locals(body))
        names = {x for x in names if x not in KEYWORDS and not x.startswith(("zf_", "zr_")) and not x[0].isupper()}
        fname = m.group(5)
        plan.append((fname, sorted(names)))
        if names:
            # the head: parameters and receiver (the fn's own name is not a local)
            hm = FN_HEAD.match(head)
            pre = head[:hm.start(7)] if hm else head
            params = hm.group(7) if hm else ""
            post = head[hm.end(7):] if hm else ""
            recv_names = {hm.group(4)} if hm and hm.group(4) else set()
            pre2 = rename_in_code(pre, recv_names & names) if recv_names else pre
            head = pre2 + rename_in_code(params, names) + post
            body = [rename_line(b, names) for b in body]
        out.append(head)
        out.extend(body)
        if j < n:
            out.append(lines[j])
        i = j + 1
    return out, plan


def bare_locals_left(lines):
    """After a rewrite: any fn still declaring an unprefixed local or parameter."""
    _, plan = process(lines)
    for fname, names in plan:
        left = [x for x in names if not x.startswith(("zf_", "zr_"))]
        if left:
            return fname, left
    return None


def main():
    args = sys.argv[1:]
    if "--control" in args:
        src = ["fn scratch(a int, mut buf []u8) int {", "\tmut tmp := [4]u8{}", "\tfor i in 0 .. a {", "\t\ttmp[i] = buf[i]", "\t}",
               "\ts := 'len ${tmp.len} of ${a}'", "\tpt := Pt{x: a}", "\tif buf[0] == `b` { s = s + `a`.str() }", "\tq := s[0..a]", "\treturn tmp[0] + s.len + pt.x + q.len", "}",
               "fn clean(zr_a int) int {", "\tzr_b := zr_a", "\treturn zr_b", "}"]
        new, plan = process(src)
        joined = "\n".join(new)
        want = ["fn scratch(zr_a int, mut zr_buf []u8) int {", "\tmut zr_tmp := [4]u8{}", "\t\tzr_tmp[i] = zr_buf[i]" if False else "\t\tzr_tmp[zr_i] = zr_buf[zr_i]",
                "\tzr_s := 'len ${zr_tmp.len} of ${zr_a}'", "\tzr_pt := Pt{x: zr_a}", "\tif zr_buf[0] == `b` { zr_s = zr_s + `a`.str() }", "\tzr_q := zr_s[0..zr_a]", "\treturn zr_tmp[0] + zr_s.len + zr_pt.x + zr_q.len"]
        bad = [w for w in want if w not in new]
        if bad or new[11:] != src[11:]:
            print("control FAILED: the renamer does not see --", bad or "the clean fn changed")
            print("\n".join(new))
            sys.exit(3)
        print("control: a bare local, a parameter, a receiver-less fn, a ${} hole and a field name handled; the prefixed fn left alone -- the renamer sees")
        return
    text = open(PATH, encoding="utf-8", newline="").read()
    crlf = "\r\n" in text
    lines = text.replace("\r\n", "\n").split("\n")
    new, plan = process(lines)
    total = sum(len(names) for _, names in plan)
    fns = sum(1 for _, names in plan if names)
    print(f"{len(plan)} functions, {fns} with bare names, {total} names to prefix")
    if "--apply" not in args:
        for fname, names in plan:
            if names:
                print(f"  {fname}: {' '.join(names)}")
        print("dry run: nothing written (--apply to rewrite)")
        return
    left = bare_locals_left(new)
    if left:
        print(f"REFUSING to write: after the rewrite fn {left[0]} still declares {left[1]}")
        sys.exit(2)
    joined = "\n".join(new)
    if crlf:
        joined = joined.replace("\n", "\r\n")
    open(PATH, "w", encoding="utf-8", newline="").write(joined)
    print(f"written: {PATH}")


if __name__ == "__main__":
    main()
