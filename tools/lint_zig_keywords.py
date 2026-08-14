#!/usr/bin/env python3
"""lint_zig_keywords.py — THE KEYWORD-ORACLE GATE (BUG-280 defect 2).

Codegen must escape a user identifier that is a ZIG keyword as `@"name"`, or the
generated Zig does not parse.  The decision is made by `isZigKeyword`, which exists
TWICE -- `src/CodeGen.zig` (bootstrap) and `selfhost/CgHelpers.zbr` -- and in both
places it is a hand-written list.

WHY THIS EXISTS, AND THE RECEIPT IS NOT THE OBVIOUS ONE.  On 2026-08-13 the list held
37 entries against Zig 0.16's 46, and every one of the 12 missing words was ALSO a
Zebra keyword -- so no user could reach any of them and nothing was broken.  The real
finding is the other direction: the list still carried `async`, `await` and
`usingnamespace`, which Zig **no longer has**.  That is proof the list already drifted
across a version bump, silently, with nothing in the repo noticing.  A hand-maintained
oracle guarding against a bug caused by a hand-maintained oracle (BUG-280) is the
shape this gate removes.

THE ORACLE IS ZIG'S OWN TABLE -- `std/zig/tokenizer.zig`'s `pub const keywords`,
located through `zig env`.  Same philosophy as `grammar_export.py --check`: the
compiled table is the authority, never a document or a second copy.  This is the FIRST
gate here that reads the Zig INSTALLATION rather than the repo, so the Zig version is
printed on every run -- the answer is only true for a specific toolchain.

MISSING is a FAILURE; EXTRA is REPORTED and not gated.  Escaping a word that is not a
keyword is identity in Zig (`@"async"` and `async` are the same identifier once the
keyword is gone), so a stale entry is inert -- and removing it would break a build
against an older Zig.  Report, do not churn.

NOT CHECKED: `isZigPrimitiveName`, the other half of `zigSafeName`.  It is already
PATTERN-based for the open-ended part (`i37`, `u3`, any `iN`/`uN`) -- verified by
emitting a class with an `i37` field and getting `@"i37"` -- so it does not have this
failure mode.  Its fixed tail (f16/f80/bool/type/anyopaque/...) is a closed set that
has not moved across Zig releases the way the keyword list did.

Exit 0 = clean, 1 = a compiler is missing a keyword, 2 = REFUSING (the instrument
could not establish what it needs to compare).
"""
import io
import os
import re
import subprocess
import sys
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent

# This console is cp1252, and every message below carries an em-dash.  lint_bug_numbers
# learned this the hard way: printing one raised UnicodeEncodeError and took the whole
# gate down with a traceback, which reads as the LEDGER being broken rather than the
# terminal.  Reconfigure rather than avoid the character.
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):
        pass

# A keyword table smaller than this means the extractor stopped matching -- blame the
# regex, never the compiler under test.
MIN_ZIG_KEYWORDS = 40
MIN_OURS = 30


def fail_refuse(msg):
    print("[zig-keywords] REFUSING — " + msg, file=sys.stderr)
    sys.exit(2)


def zig_lib_dir():
    """Resolve Zig's lib dir via `zig env`.  Output is ZON, not JSON."""
    exe = "zig"
    for cand in (os.environ.get("ZIG_EXE"), "/c/Users/Sean/.zvm/bin/zig.exe"):
        if cand and pathlib.Path(cand).exists():
            exe = cand
            break
    try:
        out = subprocess.run([exe, "env"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        fail_refuse("could not run `zig env` (%s). This gate needs a Zig install to "
                    "read its keyword table from." % e)
    if out.returncode != 0:
        fail_refuse("`zig env` exited %d:\n%s" % (out.returncode, out.stderr[:400]))
    m = re.search(r'\.lib_dir\s*=\s*"((?:[^"\\]|\\.)*)"', out.stdout)
    if not m:
        fail_refuse("could not find `.lib_dir` in `zig env` output. The format is ZON "
                    "and may have changed; fix this extractor, not the compiler.")
    ver = re.search(r'\.version\s*=\s*"([^"]*)"', out.stdout)
    return m.group(1).replace("\\\\", "/").replace("\\", "/"), (ver.group(1) if ver else "?")


def zig_keywords(lib_dir):
    tok = pathlib.Path(lib_dir) / "std" / "zig" / "tokenizer.zig"
    if not tok.exists():
        fail_refuse("no keyword table at %s — cannot establish the oracle." % tok)
    text = io.open(tok, encoding="utf-8").read()
    if "pub const keywords" not in text:
        fail_refuse("%s has no `pub const keywords` — the table moved; fix this "
                    "extractor." % tok)
    block = text.split("pub const keywords", 1)[1].split("});", 1)[0]
    kws = set(re.findall(r'\.\{\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*,\s*\.keyword_', block))
    if len(kws) < MIN_ZIG_KEYWORDS:
        fail_refuse("extracted only %d keyword(s) from %s (expected >= %d). The regex "
                    "has stopped matching." % (len(kws), tok, MIN_ZIG_KEYWORDS))
    return kws


def selfhost_keywords(text=None):
    if text is None:
        text = io.open(REPO / "selfhost" / "CgHelpers.zbr", encoding="utf-8").read()
    m = re.search(r"def isZigKeyword\(name: str\): bool\n(?:\s*#.*\n)*\s*return (.+)", text)
    if not m:
        return None
    return set(re.findall(r'name == "([^"]+)"', m.group(1)))


def bootstrap_keywords(text=None):
    if text is None:
        text = io.open(REPO / "src" / "CodeGen.zig", encoding="utf-8").read()
    m = re.search(r"fn isZigKeyword\(name: \[\]const u8\) bool \{(.*?)\n\}", text, re.S)
    if not m:
        return None
    return set(re.findall(r'\.\{\s*"([^"]+)"\s*,\s*\{\}\s*\}', m.group(1)))


# --------------------------------------------------------------------------- controls
#
# Both directions, on synthetic input, before every scan.  A gate that has stopped
# discriminating must never print clean -- and "the extractor still finds SOMETHING"
# is not the same as "the comparison still detects a gap".
COMPLETE = ['fn', 'pub', 'try']
GAPPED = ['fn', 'pub']


def _synth_selfhost(words):
    return ('def isZigKeyword(name: str): bool\n    return '
            + ' or '.join('name == "%s"' % w for w in words) + '\n')


def _synth_bootstrap(words):
    return ('fn isZigKeyword(name: []const u8) bool {\n'
            + '    const kws = std.StaticStringMap(void).initComptime(&.{\n'
            + '        ' + ' '.join('.{ "%s", {} },' % w for w in words) + '\n'
            + '    });\n    return kws.get(name) != null;\n}\n')


def selftest(oracle, verbose=False):
    dead = []
    for label, extract, synth in (("selfhost", selfhost_keywords, _synth_selfhost),
                                  ("bootstrap", bootstrap_keywords, _synth_bootstrap)):
        got_gapped = extract(synth(GAPPED))
        got_complete = extract(synth(COMPLETE))
        if got_gapped is None or got_complete is None:
            dead.append("%s: extractor returned nothing on synthetic input" % label)
            continue
        # A list missing a real keyword must be detected as missing it...
        if "try" not in (oracle - got_gapped):
            dead.append("%s: a planted GAP was not detected" % label)
        # ...and one that has it must not be.
        if "try" in (oracle - got_complete):
            dead.append("%s: a COMPLETE list was reported as gapped" % label)
        if verbose:
            print("  [ok  ] %s control: gap detected, complete list clean" % label)
    return dead


def main():
    argv = sys.argv[1:]
    lib_dir, ver = zig_lib_dir()
    oracle = zig_keywords(lib_dir)

    dead = selftest(oracle, verbose="--selftest" in argv)
    if dead:
        fail_refuse("SELF-TEST FAILED, so a clean result would mean nothing:\n    "
                    + "\n    ".join(dead))
    if "--selftest" in argv:
        print("[zig-keywords] self-test OK against Zig %s (%d keywords)" % (ver, len(oracle)))
        return 0

    rc = 0
    for label, path, got in (("bootstrap", "src/CodeGen.zig", bootstrap_keywords()),
                             ("selfhost", "selfhost/CgHelpers.zbr", selfhost_keywords())):
        if got is None:
            fail_refuse("could not find isZigKeyword in %s — it moved or was renamed. "
                        "Fix this extractor; do not assume the compiler is clean." % path)
        if len(got) < MIN_OURS:
            fail_refuse("extracted only %d entry(s) from %s (expected >= %d)."
                        % (len(got), path, MIN_OURS))
        missing = sorted(oracle - got)
        extra = sorted(got - oracle)
        if missing:
            rc = 1
            print("[zig-keywords] FAIL — %s (%s) is missing %d Zig keyword(s):"
                  % (label, path, len(missing)))
            print("    " + " ".join(missing))
            print("    A user identifier spelled like one of these emits BARE and the")
            print("    generated Zig will not parse. Add them to isZigKeyword.")
        if extra:
            print("[zig-keywords] note — %s carries %d word(s) Zig %s no longer has: %s"
                  % (label, len(extra), ver, " ".join(extra)))
            print("    Not gated: escaping a non-keyword is identity in Zig, so these are")
            print("    inert, and removing them would break a build against an older Zig.")

    print("              NOT checked: isZigPrimitiveName, the other half of zigSafeName —")
    print("              it is pattern-based for iN/uN and its fixed tail is a closed set.")
    if rc == 0:
        print("[zig-keywords] both compilers cover all %d keywords of Zig %s"
              % (len(oracle), ver))
    return rc


if __name__ == "__main__":
    sys.exit(main())
