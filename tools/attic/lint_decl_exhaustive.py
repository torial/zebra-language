#!/usr/bin/env python3
# pins: BUG-103 this lint IS that ticket's regression test -- the defect only
# triggers when someone ADDS an Ast.Decl variant, so no test/*.zbr can express it.
"""THE Ast.Decl EXHAUSTIVENESS GATE (static, instant, no build) -- BUG-103's pin.

BUG-103 was fixed on 2026-05-06 by replacing four `else => {}` catch-alls in the
metadata-collection passes with fully exhaustive arms, so that adding a new `Ast.Decl`
variant becomes a Zig compile error at every site instead of being silently skipped.

IT STAYED OPEN FOR MONTHS BECAUSE NOTHING COULD FAIL. The defect only triggers when
someone ADDS a variant, so it cannot be written as a Zebra program -- no `test/*.zbr`
fixture can exist, and the evidence was an annotation plus a reading of the source, never
a run. Its own triage note asks for exactly this: "a check that every `Ast.Decl` variant
is handled, in the shape of `lint_expr_walkers` (whose oracle is `Ast.zbr` itself)".

WHAT IT ACTUALLY GUARDS. The compile-error guarantee holds only while the switches stay
exhaustive; one `else => {}` restores the original silent-skip and Zig stops complaining.
That reintroduction is what this catches, and it is invisible to every other gate: the
code compiles, every test passes, and a future variant is quietly dropped.

ORACLE = `src/Ast.zig`'s own `Decl` union, never a hand-written list -- the same argument
`grammar_export --check` and `lint_zig_keywords` make. A list here would be the very thing
the bug is about: a second copy that drifts.

NESTED SWITCHES ARE NOT THE SUBJECT. `extractFromDecls` legitimately contains `else =>`
arms on inner `TypeRef` switches; only the arm depth of the `Decl` switch matters. Checked
by brace depth relative to the switch, not by proximity.

0 = clean. Refuses (exit 2) rather than reporting clean if the oracle or a site cannot be
found, because a regex that has stopped matching must blame ITSELF, not the source.
"""
import io, re, sys

REPO = __file__.rsplit('\\', 2)[0] if '\\' in __file__ else __file__.rsplit('/', 2)[0]
AST = REPO + '/src/Ast.zig'
TC = REPO + '/src/TypeChecker.zig'
SITES = ['extractFromDecls', 'extractFromMembers']


def decl_variants(src):
    m = re.search(r'pub const Decl = union\(enum\) \{(.*?)\n\};', src, re.S)
    if not m:
        return []
    return re.findall(r'^\s{4}([a-z_]+)\s*:', m.group(1), re.M)


def switch_arms(src, fn):
    """Arms of the FIRST switch inside `fn`, at that switch's own brace depth."""
    fm = re.search(r'\bfn %s\b' % re.escape(fn), src)
    if not fm:
        return None, None
    sm = re.search(r'switch \([a-z_]+\) \{', src[fm.end():])
    if not sm:
        return None, None
    start = fm.end() + sm.end()
    depth, i, arms, has_else = 0, start, [], False
    while i < len(src):
        c = src[i]
        if c == '{':
            depth += 1
        elif c == '}':
            if depth == 0:
                break
            depth -= 1
        elif depth == 0:
            m = re.match(r'\.([a-z_]+)\s*=>', src[i:])
            if m:
                arms.append(m.group(1))
                i += m.end() - 1
            elif re.match(r'else\s*=>', src[i:]):
                has_else = True
        i += 1
    return arms, has_else


def main():
    ast = io.open(AST, encoding='utf-8', errors='replace').read()
    tc = io.open(TC, encoding='utf-8', errors='replace').read()

    variants = decl_variants(ast)
    if len(variants) < 8:
        print('[decl-exhaustive] REFUSING: extracted only %d Decl variants from src/Ast.zig'
              ' -- the oracle regex has stopped matching.' % len(variants))
        return 2

    # Both directions, on synthetic input, before trusting the scan.
    probe_ok = switch_arms('fn zzA() void { switch (d) { .use => {}, .class => {} } }', 'zzA')
    probe_el = switch_arms('fn zzB() void { switch (d) { .use => {}, else => {} } }', 'zzB')
    if probe_ok[1] is not False or probe_el[1] is not True or probe_ok[0] != ['use', 'class']:
        print('[decl-exhaustive] REFUSING: the self-test does not discriminate '
              '(exhaustive=%r, catch-all=%r)' % (probe_ok, probe_el))
        return 2

    bad = 0
    for fn in SITES:
        arms, has_else = switch_arms(tc, fn)
        if arms is None:
            print('[decl-exhaustive] REFUSING: could not locate the switch in %s()' % fn)
            return 2
        if has_else:
            print('  %s(): has an `else =>` catch-all on the Decl switch -- BUG-103 regressed.'
                  % fn)
            print('        A new Ast.Decl variant is now SILENTLY SKIPPED here instead of'
                  ' failing the build.')
            bad += 1
            continue
        missing = [v for v in variants if v not in arms]
        if missing:
            print('  %s(): missing Decl variant(s): %s' % (fn, ', '.join(missing)))
            bad += 1

    print('[decl-exhaustive] %d issue(s); %d Decl variants x %d site(s) checked'
          % (bad, len(variants), len(SITES)))
    if bad == 0:
        print('  NOT checked: whether an arm does the RIGHT thing -- only that every variant'
              ' is named and no catch-all hides a future one.')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
