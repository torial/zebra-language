#!/usr/bin/env python3
"""THE RELEASE-SAFETY SITE MAP (BUG-667 / BUG-668).

Every function the compiler emits into a USER module must open with
`@setRuntimeSafety(true);`. `zebra --release` builds ReleaseFast, where Zig drops
its safety checks -- integer overflow, a nil `.?`, an `@intCast` out of range,
`unreachable` -- and treats the case as undefined behaviour: the program prints a
plausible wrong number and exits 0. A host that builds emitted Zebra ReleaseFast
(the GameEngine) is in the same place. The per-function switch puts Zig's own
checks back in Zebra's code and nowhere else; a per-MODULE optimize mode does not
(measured, BUG-667).

A function that misses the line is silently unchecked in release, and nothing in
a Debug gate can see it -- Debug is already safe. So the site map is DERIVED from
the emitted output rather than from reading codegen: reading found three sites,
the census prologue's, out of dozens.

Usage:
  python tools/runtime_safety_check.py DIR_OR_FILE...   # scan emitted .zig
  python tools/runtime_safety_check.py --selftest

zebra_rt.zig (the hand-written runtime) is skipped: it is not Zebra code. A few
GENERATED helpers that hold no user expression are exempt by name, each with its
reason (EXEMPT below); an exemption is never inferred.

Exit 0 = every function opens with the line; 1 = findings; 2 = the instrument
could not see (a control failed, or fewer functions than the floor).
"""
import bisect
import os
import re
import sys

SAFETY = "@setRuntimeSafety(true);"

# name regex -> reason. A generated function with no Zebra expression in it has
# nothing for the check to protect; listing it is still a decision, so it says why.
EXEMPT = [
    (r"^_reflect_lookup_", "reflection table lookup: a switch over constants"),
    (r"^_shim_", "interface shim: one forwarding call"),
    (r"^_napi_w_", "node-addon wrapper: marshals arguments, calls the Zebra fn"),
    (r"^napi_register_module_v1$", "node-addon registration table"),
    (r"^_zbr_error_msg$", "returns the error context's message field"),
    (r"^_initModuleVars$", "forwards to _initModuleVarsImpl, which is checked"),
    (r"^_zbr_mvref_", "module-var accessor: a state test and a call to _zbr_mvinit_, which is checked"),
    (r"^vtablePtr$", "interface vtable: comptime table of function pointers"),
    (r"^from$", "interface boxing: stores a pointer and a vtable"),
    (r"^check$", "interface conformance: comptime only"),
]


def strip(src):
    """Blank out comments, string and char literals (keeping newlines), so braces
    and the word `fn` inside them cannot be mistaken for code."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif c == "\\" and src.startswith("\\\\", i):     # multiline string line
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"' and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            out.append(" " * (j + 1 - i))
            i = j + 1
        elif c == "'" and re.match(r"'(\\.[^']*|[^\\'])'", src[i:i + 12]):
            m = re.match(r"'(\\.[^']*|[^\\'])'", src[i:i + 12])
            out.append(" " * m.end())
            i += m.end()
        else:
            out.append(c)
            i += 1
    return "".join(out)


FN_RE = re.compile(r"\bfn\s+(@\s*\"[^\"]*\"|[A-Za-z_][A-Za-z0-9_]*)\s*\(")
# the stripped text has the quoted name blanked, so match a blank @"" too
FN_RE_STRIPPED = re.compile(r"\bfn\s+(@\s+|[A-Za-z_][A-Za-z0-9_]*)\s*\(")
CONTAINER_KW = re.compile(r"\b(struct|enum|union|error|opaque)\s*(\([^()]*\))?\s*$")


def functions(src):
    """Yield (name, line, has_body, first_statement) for every named fn."""
    s = strip(src)
    nl = [m.start() for m in re.finditer("\n", src)]
    for m in FN_RE_STRIPPED.finditer(s):
        name = m.group(1)
        if name.startswith("@"):
            raw = FN_RE.match(src, m.start())
            name = raw.group(1) if raw else "@?"
        i = m.end()                       # just past "("
        depth = 1
        while i < len(s) and depth:
            if s[i] == "(":
                depth += 1
            elif s[i] == ")":
                depth -= 1
            i += 1
        # the return type: skip container literals (`error{A}!T`, `struct {...}`)
        ret_start = i
        body = None
        pd = 0
        while i < len(s):
            c = s[i]
            if c in "([":
                pd += 1
            elif c in ")]":
                pd -= 1
            elif c == ";" and pd == 0:
                break                     # a declaration without a body
            elif c == "{" and pd == 0:
                if CONTAINER_KW.search(s[max(0, i - 40):i]):
                    d = 1
                    i += 1
                    while i < len(s) and d:
                        d += {"{": 1, "}": -1}.get(s[i], 0)
                        i += 1
                    continue
                body = i
                break
            i += 1
        line = bisect.bisect_left(nl, m.start()) + 1
        if body is None:
            yield name, line, False, ""
            continue
        # a type constructor (`fn List(comptime T: type) type { return struct ... }`) runs
        # only at comptime: there is no run time for a check to guard
        if re.sub(r"\s+", "", s[ret_start:body]) == "type":
            yield name, line, False, ""
            continue
        rest = s[body + 1:body + 400].lstrip()
        # @branchHint must be a body's FIRST statement, so the safety line follows it
        hint = re.match(r"@branchHint\s*\([^()]*\)\s*;\s*", rest)
        if hint:
            rest = rest[hint.end():]
        first = rest.split(";", 1)[0].strip() + ";" if ";" in rest else rest
        yield name, line, True, re.sub(r"\s+", "", first)


def exempt(name):
    for rx, why in EXEMPT:
        if re.search(rx, name):
            return why
    return None


def scan_text(src):
    """-> (findings, checked_count)"""
    findings, checked = [], 0
    for name, line, has_body, first in functions(src):
        if not has_body or exempt(name):
            continue
        checked += 1
        if first != SAFETY:
            findings.append((name, line))
    return findings, checked


def selftest():
    good = 'pub fn f(x: i64) i64 {\n    @setRuntimeSafety(true);\n    return x + 1;\n}\n'
    bad = 'fn g() error{Oops}!void {\n    return;\n}\n'
    tricky = ('const s = "fn h() { }";\n'           # a fn in a string is not a fn
              "const T = fn (i64) i64;\n"           # a fn TYPE is not a fn
              "extern fn puts(p: [*]const u8) c_int;\n"   # no body
              'pub fn k() struct { a: i64 } {\n    @setRuntimeSafety(true);\n    return .{ .a = 1 };\n}\n'
              'fn @"align"() void { @setRuntimeSafety(true); }\n'
              "fn _shim_X_y(ptr: *anyopaque) void { _ = ptr; }\n"
              "pub fn Box(comptime T: type) type {\n    return struct { v: T };\n}\n"
              "fn cold() void {\n    @branchHint(.cold);\n    @setRuntimeSafety(true);\n}\n")
    checks = [
        (scan_text(good), ([], 1)),
        (scan_text(bad), ([("g", 1)], 1)),
        (scan_text(tricky), ([], 3)),
    ]
    ok = True
    for got, want in checks:
        if got != want:
            print(f"runtime-safety SELFTEST FAILED: got {got}, want {want}")
            ok = False
    return ok


# --gate: the committed selfhost/*.zig (the compiler's own emit) and a sample that reaches
# the constructs the compiler's source may not use -- one file per construct, chosen by the
# construct it carries, so a new emit path is added here with the construct that needs it.
SAMPLE = [
    "test/boundary/trip.zbr",                     # extend, @derive, interface, generic class, union, closures
    "test/bug554_yield_over_split_test.zbr",      # a generator (its next())
    "test/boundary/bv_contract_boundary.zbr",     # invariant, require/ensure
    "test/dynlib_export_class_test.zbr",          # an @export factory
    "test/boundary/bv_closure_capture_read.zbr",  # lambdas, statement and expression
    "test/module_var_test.zbr",                   # module-scope vars and their initialisers
]


def emit_sample(repo, out):
    import subprocess
    sys.path.insert(0, os.path.join(repo, "tools"))
    import zig_pin
    zig_pin.apply()
    zebra = os.path.join(repo, "zig-out", "bin", "zebra.exe" if os.name == "nt" else "zebra")
    if not os.path.exists(zebra):
        print(f"runtime-safety: REFUSING -- no compiler at {zebra}")
        return None
    dirs = []
    for rel in SAMPLE:
        src = os.path.join(repo, rel)
        if not os.path.exists(src):
            print(f"runtime-safety: REFUSING -- sample file {rel} is gone; pick another that carries its construct")
            return None
        d = os.path.join(out, os.path.basename(rel)[:-4])
        os.makedirs(d, exist_ok=True)
        r = subprocess.run([zebra, "--output-dir", d, src], capture_output=True, text=True, cwd=repo)
        if not any(f.endswith(".zig") and f != "zebra_rt.zig" for f in os.listdir(d)):
            print(f"runtime-safety: REFUSING -- {rel} emitted no module (rc={r.returncode}): {r.stderr[-200:]}")
            return None
        dirs.append(d)
    return dirs


def main(argv):
    if "--selftest" in argv:
        return 0 if selftest() else 2
    if not selftest():
        print("runtime-safety: REFUSING -- the scanner's controls failed")
        return 2
    if "--gate" in argv:
        import tempfile
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        tmp = tempfile.mkdtemp(prefix="zbr-rts-")
        dirs = emit_sample(repo, tmp)
        if dirs is None:
            return 2
        argv = [os.path.join(repo, "selfhost")] + dirs
        os.environ.setdefault("RTS_FLOOR", "1500")
    files = []
    for a in argv:
        if os.path.isdir(a):
            for root, _, names in os.walk(a):
                files += [os.path.join(root, f) for f in names if f.endswith(".zig")]
        elif a.endswith(".zig"):
            files.append(a)
    files = [f for f in sorted(files) if os.path.basename(f) != "zebra_rt.zig"]
    total, all_findings, skipped = 0, [], 0
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as fh:
            src = fh.read()
        # only what the COMPILER wrote: the hand-written runtime (the preamble, the GUI
        # sections, a test's own Zig) carries no emit header and is not Zebra code
        if not src.startswith("// Generated by zebra"):
            skipped += 1
            continue
        found, checked = scan_text(src)
        total += checked
        all_findings += [(f, n, l) for n, l in found]
    floor = int(os.environ.get("RTS_FLOOR", "10"))
    if total < floor:
        print(f"runtime-safety: REFUSING -- only {total} function(s) in {len(files)} file(s), "
              f"floor {floor}; the scan is not seeing the emitted code")
        return 2
    for f, n, l in all_findings[:60]:
        print(f"  {f}:{l}: fn {n} does not open with {SAFETY}")
    if len(all_findings) > 60:
        print(f"  ... and {len(all_findings) - 60} more")
    print(f"runtime-safety: {len(all_findings)} unchecked of {total} function(s) "
          f"in {len(files) - skipped} emitted file(s) ({skipped} hand-written skipped); "
          f"{len(EXEMPT)} exemption rule(s)")
    return 1 if all_findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
