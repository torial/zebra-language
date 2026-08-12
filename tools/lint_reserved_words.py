"""THE RESERVED-WORD GATE — a keyword must either be USED or be JUSTIFIED.

A word in the keyword table costs every user of the language the right to name a
variable, a parameter, a field or a column with it. That cost is invisible until
someone hits it, and then it looks like a compiler bug rather than a decision
nobody revisited.

RECEIPTS, all from 2026-08-08/09:
  · `aspect` was reserved for aspect-oriented programming that was never built. The
    bootstrap parsed `aspect Foo` and then panicked "not yet implemented"; the
    selfhost had NO parse path for it at all (verified: `AspectDecl` never appears
    anywhere under selfhost/ in the whole git history). So its only live effect was
    to block a real DB column name, force a keyword-rename shield in procgen, and
    create a permanent bootstrap-accepts / selfhost-rejects divergence for the
    grammar fuzzer to trip over. Removed under NEXT_STEPS U4.
  · The audit that found it ALSO turned up `expect` and `lock`, which nobody had
    flagged and which are at least as likely to collide with user code.
  · And it cleared `cue` and `vari`, which had been guessed at. Two guesses, both
    wrong in opposite directions — which is the argument for a lint over a memory.

WHAT IT CHECKS. Two independent classes, because they have different fixes:

  R1  UNREACHABLE — the word is in the keyword table but NO grammar rule mentions
      its token. The parser can never accept it in any position, so reserving it
      is pure cost. Fix: delete it from the table.

  R2  PARSED-THEN-REFUSED — a grammar rule accepts it, and AstBuilder answers with
      `not yet implemented`. The feature does not exist; the reservation does.
      Fix: remove the rules and the word, or implement it.

HOW IT NEARLY LIED, recorded because the correction is the interesting part. The
first version asked "does this token name appear in a downstream file?" and
classified `raise` and `throws` as unused — two of the most load-bearing keywords
in the language, which the author had been using all evening. The bug: downstream
code acts on the PNode the grammar produces, never on the token name, so absence
downstream means nothing at all. Arithmetic implausibility caught it. R2 now asks
the COMPILER's own answer (AstBuilder's refusal) instead of the author's inference.

REACHABILITY IS CHECKED IN BOTH COMPILERS, and the first draft got this wrong. It
scanned only `src/ZebraGrammar.zig` — the bootstrap's Earley table — because that is
where the bootstrap decides what it can parse. But the selfhost has its own
hand-written recursive-descent parser that consumes `TokenKind` values directly, so a
word invisible to the Earley table can be perfectly live there. Scanning one compiler
would have reported a false R1 the first time anyone added a selfhost-only construct.
That is the general shape of rule 1c: an instrument's assumptions are quantified over
the subjects it had when it was written.

BASELINED, like `bug_fixture_check` and `registration_check`. Its first run surfaced
five words; each is a decision for the language's owner rather than hygiene, so they
are recorded below and the gate fails only on words that JOIN them. Shrink the list,
never grow it. An entry carries why it is there, so removing one is an argument
someone can check rather than a judgement call.

CANNOT SEE: whether a keyword that IS reachable is reachable in a USEFUL way, or
whether a word not in the keyword table is nonetheless unusable for some other
reason (a stdlib name, a builtin). 0 NEW = clean.
"""
import re
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Baseline: known at the lint's first run, 2026-08-09. Each is a language decision,
# not hygiene, and each says why it is here. Shrink this; do not grow it.
BASELINE = {
    "implies": "R1, and the one word deliberately kept on LANGUAGE grounds \u2014 Sean's call, "
               "2026-08-09. It sits under Contracts in the token table because it is "
               "intended as a contract operator (`a implies b`). Reserving for an intended "
               "feature is legitimate; this entry is what keeps it a decision.",
    "error":   "R1. The ENGINEERING blocker is GONE as of 2026-08-11: BUG-280 landed in "
               "both compilers, the field path now calls emitName, and `error` is one of "
               "the 37 words isZigKeyword already knows \u2014 so a field named `error` "
               "emits `@\"error\"`. That is derived from the mechanism rather than "
               "measured, because the word cannot be WRITTEN in Zebra today; `opaque` "
               "takes the identical path and is covered by test/bug280_keyword_idents.zbr. "
               "What remains is the tokenizer change plus flipping the two Parser tests "
               "that assert `error` is rejected. Freeing it is now a language decision, "
               "not an engineering one.",
    "try":     "R1, and STILL BLOCKED after BUG-280 \u2014 by its second defect, not its "
               "first. isZigKeyword is a hand-maintained 37-entry list against Zig's 46 "
               "and does not contain `try`, so escaping would not fire and `try` fails in "
               "every position, not just as a field. Closing that gap is the prerequisite; "
               "see BUG-280 in BUGS_FIXED.md, defect 2.",
}


def fail(msg):
    print(f"[reserved-words] REFUSING: {msg}", file=sys.stderr)
    sys.exit(2)


def classify(pairs, gram, ast, selfhost):
    """(word -> 'R1'|'R2') for every keyword that is unreachable or parsed-then-refused.

    Split out from main so it can be exercised on synthetic input by --selftest. A
    classifier that has quietly stopped classifying prints the same '0 NEW' as a clean
    tree, and this is the only way to tell those apart without editing the compiler.
    """
    refused = set(re.findall(r"error: (\w+)[^\"]*? are not yet implemented", ast))
    refused |= set(re.findall(r"error: '(\w+)' statements are not yet implemented", ast))

    out = {}
    for word, token in sorted(pairs):
        if f"t(.{token})" not in gram and token not in selfhost:
            out[word] = "R1"
        elif word in refused or (word + "s") in refused or word.rstrip("s") in refused:
            out[word] = "R2"
    return out


def selftest():
    """Both directions, on inputs whose answers are facts about the classifier rather
    than facts about today's compiler — so this does not break on the day a real
    keyword is freed (rule 4: pin controls to the mechanism, not to a known gap)."""
    pairs = [("alive", "kw_alive"), ("selfhostonly", "kw_selfhostonly"),
             ("ghost", "kw_ghost"), ("halfdone", "kw_halfdone")]
    gram = "rule: t(.kw_alive) ... rule: t(.kw_halfdone)"
    selfhost = "if k is TokenKind.kw_selfhostonly"
    ast = 'std.debug.panic("{d}:{d}: error: halfdone declarations are not yet implemented"'
    got = classify(pairs, gram, ast, selfhost)
    want = {"ghost": "R1", "halfdone": "R2"}
    checks = [
        ("a keyword used by the Earley grammar is not flagged", "alive" not in got),
        ("a keyword used ONLY by the selfhost parser is not flagged",
         "selfhostonly" not in got),
        ("a keyword no compiler accepts is flagged R1", got.get("ghost") == "R1"),
        ("a keyword that parses then panics is flagged R2", got.get("halfdone") == "R2"),
        ("nothing else is flagged", got == want),
    ]
    bad = [n for n, ok in checks if not ok]
    for n, ok in checks:
        print(f"  {'ok  ' if ok else 'FAIL'}  {n}")
    if bad:
        print(f"[reserved-words] SELFTEST FAILED ({len(bad)}) — the classifier is not "
              f"discriminating; a clean gate run would mean nothing.", file=sys.stderr)
        return 2
    print(f"[reserved-words] selftest: {len(checks)}/{len(checks)} discriminate")
    return 0


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    tok = (ROOT / "src" / "Token.zig").read_text(encoding="utf-8", errors="replace")
    pairs = re.findall(r'\.\{\s*"([a-z_]+)"\s*,\s*\.(kw_\w+)\s*\}', tok)
    if len(pairs) < 40:
        fail(f"extracted only {len(pairs)} keyword pairs from src/Token.zig (expected 40+); "
             "the regex has stopped matching, so this would blame the LANGUAGE for the "
             "tool's failure")

    gram = (ROOT / "src" / "ZebraGrammar.zig").read_text(encoding="utf-8", errors="replace")
    ast = (ROOT / "src" / "AstBuilder.zig").read_text(encoding="utf-8", errors="replace")

    # The selfhost parses by hand, consuming TokenKind values directly, so its sources
    # are a second and independent place a keyword can be reachable from. Scanning only
    # the Earley table would false-positive the first selfhost-only construct.
    selfhost = "\n".join(
        p.read_text(encoding="utf-8", errors="replace")
        for p in sorted((ROOT / "selfhost").glob("*.zbr"))
        if p.name != "Token.zbr"          # Token.zbr DEFINES them; a hit there is not use
    )
    if not selfhost.strip():
        fail("read no selfhost/*.zbr sources — reachability would be judged from the "
             "bootstrap alone, which is how this lint reported a false R1 in draft")

    # Controls, derived at run time rather than pinned to a known gap: `def` is the
    # most load-bearing keyword there is and MUST be reachable; a token that does not
    # exist MUST classify unreachable. If either flips, the scan is broken.
    kws = dict(pairs)
    if "def" not in kws:
        fail("control keyword 'def' is absent from the keyword table")
    if f"t(.{kws['def']})" not in gram:
        fail(f"positive control {kws['def']} classified UNREACHABLE in the grammar — "
             "the Earley scan is not seeing rule text")
    if kws["def"] not in selfhost:
        fail(f"positive control {kws['def']} classified UNREACHABLE in the selfhost — "
             "the .zbr scan is not seeing parser text")
    if "kw_thisdoesnotexist" in gram or "kw_thisdoesnotexist" in selfhost:
        fail("negative control matched — the scan is not discriminating")

    # Run the classifier's own controls before believing anything it says here.
    if selftest() != 0:
        sys.exit(2)

    flagged = classify(pairs, gram, ast, selfhost)
    unreachable = [w for w, c in flagged.items() if c == "R1"]
    parsed_refused = [w for w, c in flagged.items() if c == "R2"]
    new = sorted(w for w in flagged if w not in BASELINE)

    for w in new:
        why = ("reserved but NO rule in EITHER compiler can accept it"
               if flagged[w] == "R1" else
               "parses, then AstBuilder refuses it as unimplemented")
        print(f"  src/Token.zig: [{flagged[w]}] `{w}` — {why}. Free the word, implement "
              f"the feature, or add it to BASELINE in tools/lint_reserved_words.py "
              f"with the reason it stays.")

    known = sorted(set(BASELINE) & set(flagged))
    stale = sorted(set(BASELINE) - set(flagged))
    if known:
        print(f"              baselined (each a pending language decision): {', '.join(known)}")
    if stale:
        # A baseline entry for a word that is no longer flagged is a stale claim, and
        # stale entries are how an allow-list becomes the hand-maintained oracle this
        # gate exists to replace. Reported, not gated — the word may have been freed,
        # which is the outcome this list is FOR.
        print(f"              NOTE: BASELINE entries that no longer match anything — "
              f"remove them: {', '.join(stale)}")
    print("              NOT checked: whether a REACHABLE keyword is reachable in a "
          "useful way, nor words made unusable by something other than the keyword table.")

    print(f"[reserved-words] {len(pairs)} keywords; {len(unreachable)} unreachable, "
          f"{len(parsed_refused)} parsed-then-refused, {len(known)} known; "
          f"{len(new)} NEW")

    if "--gate" in sys.argv and new:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
