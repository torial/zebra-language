#!/usr/bin/env python
"""gramgen.py — coverage-guided GRAMMAR fuzzer for the Zebra front-end.

Complements fuzz/gen.py.  Where gen.py generates *semantically-valid* programs to
differential-test the whole pipeline (emit → zig → run), gramgen.py generates
*syntactically-valid* programs straight from `grammar.txt` to stress the FRONT-END
(tokenizer → parser → resolver → typechecker) and, above all, to catch places where
the two compilers DISAGREE on whether a grammar-valid program is accepted.

Why this is a distinct instrument:
  * gen.py / the corpus / compile_check / divergence_check all only ever see programs
    a human thought to write.  A CFG derivation systematically explores the *syntactic*
    space — constructs no fixture exercises.
  * A grammar-valid program is NOT necessarily semantically valid (undefined names,
    type errors).  So the useful oracle signals here are:
      - CRASH: a panic / "internal compiler error" / unreachable / tokenizer crash on
        grammar-valid input — always a bug, regardless of semantics.
      - ACCEPT/REJECT DIVERGENCE: one compiler emits, the other errors.  Two
        implementations of the *same* grammar must agree on accept/reject.  (Gold.)
    A clean "syntax error at line N" that BOTH compilers report is expected noise
    (the program was semantically bogus) and is bucketed as agreement.

Note on "Earley": generating from a CFG is *derivation* (expand nonterminals forward),
which needs no parsing algorithm at all — Earley matters for the inverse (parsing an
arbitrary/ambiguous/left-recursive CFG).  Left-recursion in the grammar (Expr → Expr …)
is harmless for generation as long as we budget recursion depth.

Coverage-guided: we weight production choice by 1/(1+times_used), which drives the
sample toward uniform *production coverage* (every `A → alt` alternative exercised).
Past a depth budget we bias to the alternative with the fewest nonterminals so
derivation terminates.

Usage:
  python fuzz/gramgen.py --dry -n 20 --seed 1     # generate + print, NO compiler
  python fuzz/gramgen.py -n 200 --seed 1          # generate + differential-check
  python fuzz/gramgen.py --coverage-report        # just print grammar coverage after N
"""
import argparse, random, sys, re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GRAMMAR = ROOT / 'grammar.txt'

# ── Grammar loader ────────────────────────────────────────────────────────────
def load_grammar(path):
    """Parse the BNF in grammar.txt → {NonTerm: [production, ...]} where each
    production is a list of symbol strings ([] == the ε production).  A symbol is a
    NONTERMINAL iff it is itself a key in the returned dict; everything else is a
    terminal."""
    rules = {}
    order = []
    cur = None
    acc = ''
    def flush():
        nonlocal cur, acc
        if cur is None:
            return
        alts = []
        for chunk in acc.split('|'):
            syms = chunk.split()
            # 'ε' (epsilon) → the empty production
            syms = [s for s in syms if s != 'ε']
            alts.append(syms)
        rules[cur] = alts
        order.append(cur)
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = re.match(r'^(\w+)\s*→\s*(.*)$', line)
        if m:
            flush()
            cur = m.group(1)
            acc = m.group(2)
        elif line.lstrip().startswith('|'):
            acc += ' ' + line.strip()
        else:
            # stray continuation without '|' — append defensively
            acc += ' ' + line.strip()
    flush()
    return rules, order


# ── Terminal rendering ────────────────────────────────────────────────────────
# Fixed-text terminals (punctuation / operators).  kw_* are handled generically
# (strip the "kw_" prefix — verified against src/Token.zig keyword_map).
PUNCT = {
    'eof': '', 'dot': '.', 'comma': ',', 'colon': ':', 'assign': '=',
    'bang': '!', 'question': '?', 'star': '*', 'tilde': '~', 'vertical_bar': '|',
    'lparen': '(', 'rparen': ')', 'lbracket': '[', 'rbracket': ']',
    'at_lbracket': '@[', 'rbracket_special': ']',
    'eq': '==', 'ne': '!=', 'lt': '<', 'gt': '>', 'le': '<=', 'ge': '>=',
    'plus': '+', 'minus': '-', 'slash': '/', 'slashslash': '//', 'percent': '%',
    'starstar': '**',
    'plus_equals': '+=', 'minus_equals': '-=', 'star_equals': '*=',
    'slash_equals': '/=', 'slashslash_equals': '//=', 'percent_equals': '%=',
    'starstar_equals': '**=', 'ampersand_equals': '&=', 'vertical_bar_equals': '|=',
    'caret_equals': '^=', 'double_lt_equals': '<<=', 'double_gt_equals': '>>=',
    'question_equals': '?=',
}

# Terminals whose text glues to the *previous* token (no leading space).
GLUE_LEFT = {'dot', 'comma', 'colon', 'question', 'rparen', 'rbracket', 'lparen',
             'lbracket', 'bang'}

_ID_POOL = ['a', 'b', 'c', 'x', 'y', 'foo', 'bar', 'baz', 'item', 'n', 'i', 'val',
            'Thing', 'Node', 'Point', 'T', 'U', 'p', 'q', 'result']

class Renderer:
    """Turns a flat stream of terminals into indentation-correct source text.
    Model: track current indent level; emit the line's indentation lazily at the
    first token of each line.  `eol` ends a line; `indent`/`dedent` adjust the level
    of the *next* line — matching how `... eol indent Block dedent` lays out."""
    def __init__(self, rng):
        self.rng = rng
        self.parts = []
        self.level = 0
        self.line_start = True

    def _ident(self):
        return self.rng.choice(_ID_POOL)

    def term(self, t):
        txt, glue = self._text(t)
        if t == 'eol':
            self.parts.append('\n')
            self.line_start = True
            return
        if t == 'indent':
            self.level += 1
            return
        if t == 'dedent':
            self.level = max(0, self.level - 1)
            return
        if txt == '':
            return
        if self.line_start:
            self.parts.append('    ' * self.level)
            self.parts.append(txt)
            self.line_start = False
        else:
            prev = self.parts[-1] if self.parts else ''
            no_space = glue or prev.endswith('(') or prev.endswith('[') \
                       or prev.endswith('.') or prev.endswith('@')
            self.parts.append(('' if no_space else ' ') + txt)

    def _text(self, t):
        """Return (text, glue_left) for a terminal."""
        if t.startswith('kw_'):
            return (t[3:], False)
        if t in PUNCT:
            return (PUNCT[t], t in GLUE_LEFT)
        r = self.rng
        if t == 'id':                       return (self._ident(), False)
        if t == 'identifier':               return (self._ident(), False)
        if t == 'at_id':                    return ('@' + self._ident(), False)
        if t == 'open_call':                return (self._ident() + '(', False)
        if t == 'int_size':                 return (r.choice(['i8','i16','i32','i64']), False)
        if t == 'uint_size':                return (r.choice(['u8','u16','u32','u64']), False)
        if t == 'float_size':               return (r.choice(['f32','f64']), False)
        if t in ('integer_lit','number_lit','decimal_lit'):
            return (str(r.randint(0, 999)), False)
        if t == 'integer_lit_explicit':     return (str(r.randint(0,99)) + 'i32', False)
        if t in ('hex_lit','hex_lit_unsign'):
            return ('0x' + format(r.randint(0,255), 'X'), False)
        if t == 'hex_lit_explicit':         return ('0xFF' + 'u8', False)
        if t in ('float_lit','fractional_lit'):
            return (f'{r.randint(0,99)}.{r.randint(0,99)}', False)
        if t == 'float_lit_exp':            return ('1.5e3', False)
        if t == 'string_single':            return ("'" + self._ident() + "'", False)
        if t == 'string_double':            return ('"' + self._ident() + '"', False)
        if t == 'string_nosub_single':      return ("c'" + self._ident() + "'", False)
        if t == 'string_nosub_double':      return ('c"' + self._ident() + '"', False)
        if t == 'string_raw_single':        return ("r'" + self._ident() + "'", False)
        if t == 'string_raw_double':        return ('r"' + self._ident() + '"', False)
        if t == 'zig_single':               return ("zig'" + self._ident() + "'", False)
        if t == 'zig_double':               return ('zig"' + self._ident() + '"', False)
        if t == 'doc_string_line':          return ('"""doc"""', False)
        # Interpolation-string terminals are not modeled in v1 → emit a plain string
        # so any production that reaches them still renders *something* legal-ish.
        if t.startswith('string_'):         return ('"' + self._ident() + '"', False)
        # Unknown terminal — surface it rather than silently emit nothing.
        return ('/*?' + t + '*/', False)

    def text(self):
        return ''.join(self.parts)


# ── Coverage-guided derivation ────────────────────────────────────────────────
class Generator:
    def __init__(self, grammar, rng, max_depth=18, size_cap=4000):
        self.g = grammar
        self.rng = rng
        self.max_depth = max_depth
        self.size_cap = size_cap
        self.use_count = {}          # (NT, alt_idx) -> times chosen (coverage weight)

    def _nt_count(self, alt):
        return sum(1 for s in alt if s in self.g)

    def _choose(self, nt, depth):
        alts = self.g[nt]
        if depth >= self.max_depth:
            # Terminate: fewest nonterminals (ε/atoms win); ties broken by low use.
            minnt = min(self._nt_count(a) for a in alts)
            cand = [i for i, a in enumerate(alts) if self._nt_count(a) == minnt]
        else:
            cand = list(range(len(alts)))
        # coverage-guided weight: prefer least-used alternatives
        weights = [1.0 / (1 + self.use_count.get((nt, i), 0)) for i in cand]
        idx = self.rng.choices(cand, weights=weights, k=1)[0]
        self.use_count[(nt, idx)] = self.use_count.get((nt, idx), 0) + 1
        return alts[idx]

    def _expand(self, sym, rend, depth):
        if len(rend.parts) > self.size_cap:
            return
        if sym in self.g:
            for s in self._choose(sym, depth):
                self._expand(s, rend, depth + 1)
        else:
            rend.term(sym)

    def generate(self):
        rend = Renderer(self.rng)
        self._expand('Program', rend, 0)
        return rend.text()

    def coverage(self):
        total = sum(len(alts) for alts in self.g.values())
        hit = len(self.use_count)
        return hit, total


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-n', type=int, default=100, help='programs to generate')
    ap.add_argument('--seed', type=int, default=0)
    ap.add_argument('--dry', action='store_true', help='generate + print, no compiler')
    ap.add_argument('--max-depth', type=int, default=18)
    ap.add_argument('--show', type=int, default=3, help='sample programs to print')
    args = ap.parse_args()

    grammar, order = load_grammar(GRAMMAR)
    rng = random.Random(args.seed)
    gen = Generator(grammar, rng, max_depth=args.max_depth)

    if args.dry:
        for k in range(args.n):
            src = gen.generate()
            if k < args.show:
                print(f'----- sample #{k} ({len(src)} chars) -----')
                print(src)
        hit, total = gen.coverage()
        print(f'\n[coverage] {hit}/{total} productions exercised '
              f'({100*hit/total:.0f}%) over {args.n} programs')
        # report never-hit productions (grammar reachability gaps in the sampler)
        missed = []
        for nt in order:
            for i in range(len(grammar[nt])):
                if (nt, i) not in gen.use_count:
                    missed.append(f'{nt}#{i}')
        if missed:
            print(f'[uncovered {len(missed)}] ' + ' '.join(missed[:40])
                  + (' …' if len(missed) > 40 else ''))
        return

    # differential mode — import the existing oracle
    sys.path.insert(0, str(ROOT / 'fuzz'))
    import harness
    out_dir = ROOT / 'fuzz' / 'findings' / 'gramgen'   # gitignored (findings/)
    out_dir.mkdir(parents=True, exist_ok=True)
    buckets = {}
    # signature -> {kind, detail, src (smallest), count}
    uniq = {}
    for k in range(args.n):
        src = gen.generate()
        res = harness.check(src, tag='gg', zig_check=False)
        buckets[res.verdict] = buckets.get(res.verdict, 0) + 1
        kind = _classify(res)
        if kind is None:
            continue
        sig = kind + '|' + _signature(res.detail)
        cur = uniq.get(sig)
        if cur is None:
            uniq[sig] = {'kind': kind, 'detail': res.detail, 'src': src, 'count': 1}
        else:
            cur['count'] += 1
            if len(src) < len(cur['src']):      # keep the SMALLEST reproducer
                cur['src'] = src
        if k and k % 200 == 0:
            print(f'  … {k}/{args.n} done, {len(uniq)} unique findings so far', flush=True)
    hit, total = gen.coverage()
    print(f'[coverage] {hit}/{total} productions ({100*hit/total:.0f}%)')
    print('[verdicts] ' + '  '.join(f'{v}={c}' for v, c in sorted(buckets.items())))
    _report_unique(uniq, out_dir)


# HANG and CRASH are unambiguous bugs (any input). DIVERGENCE (one side cleanly
# rejects, the other accepts) is real but needs a which-is-right judgment.
CRASH_MARKERS = ('internal compiler error', 'panic', 'unreachable',
                 'index out of bounds', 'segmentation', 'cast truncated',
                 'integer overflow', 'reached unreachable')
# UnexpectedCharacter is the tokenizer's crash on a bad char — a crash, but our
# renderer only emits legal chars, so treat it as a crash marker if it appears.
CRASH_MARKERS += ('unexpectedcharacter',)

# Message-stage heuristic — a poor-man's front-end oracle. Grammar-valid programs
# SHOULD all parse (semantics aside), so a PARSE-stage rejection is high-signal
# (grammar↔parser drift or a parser divergence); resolve/type rejections are the
# expected noise for semantically-garbage generated programs.
PARSE_MARKERS   = ('syntax error', 'unexpected top-level', 'unexpected member',
                   'expected identifier', "expected '", 'unexpected end of input',
                   'unexpected token', 'expected a declaration')
RESOLVE_MARKERS = ('is not defined', 'cannot find module', 'unresolved',
                   'unknown @-directive', 'undeclared', 'no field', 'unknown')

def _stage(detail):
    """Best-effort: which pipeline stage rejected? 'parse' | 'resolve' | 'other'."""
    d = (detail or '').lower()
    if any(m in d for m in PARSE_MARKERS):
        return 'parse'
    if any(m in d for m in RESOLVE_MARKERS):
        return 'resolve'
    return 'other'

def _classify(res):
    """Return 'HANG'|'CRASH'|'PARSE-DIVERGENCE'|'DIVERGENCE'|None (no signal).

    PARSE-DIVERGENCE = one compiler accepted a grammar-valid program the other
    rejected AT THE PARSE STAGE — the purest front-end signal (two implementations
    of one grammar disagreeing on acceptance). Split out from resolve/type
    divergences, which are expected for semantic garbage."""
    d = (res.detail or '')
    if 'TIMEOUT' in d:
        return 'HANG'
    if any(m in d.lower() for m in CRASH_MARKERS):
        return 'CRASH'
    if res.verdict in ('crash-A', 'crash-B'):
        return 'PARSE-DIVERGENCE' if _stage(d) == 'parse' else 'DIVERGENCE'
    return None

def _signature(detail):
    """Normalize a detail string so identical bug shapes dedup: drop temp paths,
    hashes, line:col numbers."""
    d = (detail or '')
    d = re.sub(r'[A-Za-z]:[\\/][^\s]*gg_[0-9a-f]+\.zbr', '<f>', d)
    d = re.sub(r'\.fuzz_tmp[\\/][^\s]+', '<f>', d)
    d = re.sub(r':\d+:\d+', ':L:C', d)
    d = re.sub(r"'[^']*'", "'X'", d)          # collapse quoted tokens/names
    d = re.sub(r'\s+', ' ', d).strip()
    return d[:120]

def _report_unique(uniq, out_dir):
    if not uniq:
        print('[findings] none (no hangs, crashes, or accept/reject divergences)')
        return
    order = {'HANG': 0, 'CRASH': 1, 'PARSE-DIVERGENCE': 2, 'DIVERGENCE': 3}
    items = sorted(uniq.items(), key=lambda kv: (order[kv[1]['kind']], -kv[1]['count']))
    print(f'[findings] {len(uniq)} UNIQUE (by signature), most-severe first:')
    for i, (sig, f) in enumerate(items):
        # persist the smallest reproducer for each unique finding
        repro = out_dir / f'{f["kind"]}_{i:02d}.zbr'
        repro.write_text(f['src'], encoding='utf-8', newline='\n')
        d1 = _signature(f['detail'])
        print(f'  [{f["kind"]}] x{f["count"]:<4} ({len(f["src"])}b -> {repro.name}): {d1[:88]}')


if __name__ == '__main__':
    main()
