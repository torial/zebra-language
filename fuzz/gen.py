#!/usr/bin/env python
"""Type-aware random Zebra program generator (fuzzer front end).

Generates *well-formed* programs — ones that resolve and type-check — so the
differential harness exercises real codegen paths rather than error paths.
Seed-reproducible: gen(seed) always yields the same program.

Design: a small typed-expression grammar.  `gen_expr(ty, env)` only ever emits
an expression of type `ty` built from in-scope vars (env: name -> type) and
size-bounded literals (so comptime arithmetic can't overflow i64 at Zig compile
time).  The subset grows over time (see CAPS); start conservative so a clean
baseline means "both compilers agree", then widen to hunt divergences.
"""
import random
import re

PRIMS = ('int', 'float', 'bool', 'str')


class Gen:
    def __init__(self, seed, caps=None):
        self.rng = random.Random(seed)
        self.seed = seed
        self.n = 0            # unique-name counter
        self.caps = caps or DEFAULT_CAPS
        self.funcs = []       # [(name, [param_types], ret_type)] — callable helpers
        self._params = set()  # read-only names in scope (fn params — Zig consts)

    # ── helpers ──────────────────────────────────────────────────────────────
    def fresh(self, prefix='v'):
        self.n += 1
        return f'{prefix}{self.n}'

    def pick(self, seq):
        return self.rng.choice(list(seq))

    def maybe(self, p=0.5):
        return self.rng.random() < p

    # ── expressions (typed) ──────────────────────────────────────────────────
    def lit(self, ty):
        if ty == 'int':
            return str(self.rng.randint(0, 20))   # small → runtime arithmetic won't overflow i64
        if ty == 'float':
            return f'{self.rng.randint(0, 100)}.{self.rng.randint(0, 9)}'
        if ty == 'bool':
            return self.pick(('true', 'false'))
        if ty == 'str':
            n = self.rng.randint(0, 6)
            return '"' + ''.join(self.pick('abcdefg ') for _ in range(n)) + '"'
        raise ValueError(ty)

    def vars_of(self, env, ty):
        return [k for k, v in env.items() if v == ty]

    def gen_expr(self, ty, env, depth):
        # optional target `T?`: an in-scope T? var, `nil`, or a bare T (coerces).
        if ty.endswith('?'):
            base = ty[:-1]
            optvars = self.vars_of(env, ty)
            r = self.rng.random()
            if optvars and r < 0.4:
                return self.pick(optvars)
            if r < 0.65:
                return 'nil'
            return self.gen_expr(base, env, max(0, depth - 1))
        # base case: literal or in-scope var
        if depth <= 0 or self.maybe(0.35):
            vs = self.vars_of(env, ty)
            if vs and self.maybe(0.6):
                return self.pick(vs)
            return self.lit(ty)
        # `optvar orelse default` — unwrap a T? into a T
        optcands = self.vars_of(env, ty + '?')
        if optcands and self.maybe(0.2):
            return f'({self.pick(optcands)} orelse {self.lit(ty)})'
        # call a helper function that returns `ty`
        callable_here = [f for f in self.funcs if f[2] == ty]
        if callable_here and self.maybe(0.3):
            name, ptypes, _ = self.pick(callable_here)
            args = ', '.join(self.gen_expr(pt, env, depth - 1) for pt in ptypes)
            return f'{name}({args})'
        r = self.rng.random()
        if ty == 'int':
            if r < 0.7:
                op = self.pick(('+', '-', '*'))
                return f'({self.gen_expr("int", env, depth-1)} {op} {self.gen_expr("int", env, depth-1)})'
            return self.lit('int') if not self.vars_of(env, 'int') else self.pick(self.vars_of(env, 'int'))
        if ty == 'float':
            op = self.pick(('+', '-', '*'))
            return f'({self.gen_expr("float", env, depth-1)} {op} {self.gen_expr("float", env, depth-1)})'
        if ty == 'str':
            if r < 0.5:
                return f'({self.gen_expr("str", env, depth-1)} + {self.gen_expr("str", env, depth-1)})'
            return self.lit('str')
        if ty == 'bool':
            if r < 0.4:
                cty = self.pick(('int', 'float', 'str'))
                op = self.pick(('==', '!=')) if cty == 'str' else self.pick(('==', '!=', '<', '>', '<=', '>='))
                return f'({self.gen_expr(cty, env, depth-1)} {op} {self.gen_expr(cty, env, depth-1)})'
            if r < 0.7:
                op = self.pick(('and', 'or'))
                return f'({self.gen_expr("bool", env, depth-1)} {op} {self.gen_expr("bool", env, depth-1)})'
            if r < 0.85:
                return f'(not {self.gen_expr("bool", env, depth-1)})'
            return self.lit('bool')
        raise ValueError(ty)

    # ── statements ───────────────────────────────────────────────────────────
    def gen_block(self, env, indent, budget):
        """Return list of source lines (already indented).  `env` is mutated with
        new bindings (block scope is approximated — fine for codegen coverage)."""
        lines = []
        ind = '    ' * indent
        stmts = self.rng.randint(1, self.caps['stmts'])
        for _ in range(stmts):
            if budget[0] <= 0:
                break
            budget[0] -= 1
            lines += self.gen_stmt(env, indent, budget)
        if not lines:
            lines = [ind + 'pass']
        return lines

    def gen_stmt(self, env, indent, budget):
        ind = '    ' * indent
        choices = ['decl', 'print']
        assignable = [k for k in env if k not in self._params]  # params are const in Zig
        if assignable:
            choices += ['assign', 'assign']
        opt_in_scope = [k for k, v in env.items() if v.endswith('?')]
        if indent < self.caps['depth']:
            choices += ['if', 'while']
            if opt_in_scope:
                choices += ['ifas']    # `if optvar as bound` — nil-narrowing
        k = self.pick(choices)
        d = self.caps['expr_depth']
        if k == 'decl':
            ty = self.pick(PRIMS)
            name = self.fresh()
            if self.caps.get('optionals') and self.maybe(0.25):
                e = self.gen_expr(ty + '?', env, d)   # init BEFORE binding — no self-reference
                env[name] = ty + '?'
                return [f'{ind}var {name}: {ty}? = {e}']
            e = self.gen_expr(ty, env, d)
            env[name] = ty
            # annotate sometimes to exercise both inferred + annotated paths
            if self.maybe(0.5):
                return [f'{ind}var {name}: {ty} = {e}']
            return [f'{ind}var {name} = {e}']
        if k == 'assign':
            name = self.pick(assignable)
            return [f'{ind}{name} = {self.gen_expr(env[name], env, d)}']
        if k == 'ifas':
            ov = self.pick(opt_in_scope)
            bound = self.fresh('u')
            env2 = dict(env); env2[bound] = env[ov][:-1]   # narrowed to base type
            return [f'{ind}if {ov} as {bound}'] + self.gen_block(env2, indent + 1, budget)
        if k == 'print':
            # don't interpolate an optional directly (not printable); prefer a base-typed var
            printable = [x for x, v in env.items() if not v.endswith('?')]
            if printable and self.maybe(0.6):
                name = self.pick(printable)
                return [f'{ind}print("v=${{{name}}}")']
            return [f'{ind}print({self.gen_expr("str", env, d)})']
        if k == 'if':
            cond = self.gen_expr('bool', env, d)
            body = self.gen_block(dict(env), indent + 1, budget)
            out = [f'{ind}if {cond}'] + body
            if self.maybe(0.4):
                out += [f'{ind}else'] + self.gen_block(dict(env), indent + 1, budget)
            return out
        if k == 'while':
            # Bounded induction loop so programs always terminate (the run oracle
            # needs it).  The counter is NOT put in the body's env, so the body can't
            # reference or reassign it — guaranteeing progress.
            ctr = self.fresh('k')     # not 'i' — `i{n}` collides with Zig `iN` int types
            lim = self.rng.randint(1, 4)
            body = self.gen_block(dict(env), indent + 1, budget)
            inc = '    ' * (indent + 1) + f'{ctr} = {ctr} + 1'
            return [f'{ind}var {ctr} = 0', f'{ind}while {ctr} < {lim}'] + body + [inc]
        return [f'{ind}pass']

    # ── program ──────────────────────────────────────────────────────────────
    def _use_unused(self, lines):
        """Zig (like Rust) rejects an unused local; Zebra surfaces that as a Zig-
        level error.  Keep the fuzzer testing real equivalence (not unused-var
        noise) by discarding any generated `var` that is never referenced again —
        insert `var _ = name` at the same indent right after its declaration."""
        text = '\n'.join(lines)
        out = []
        for ln in lines:
            out.append(ln)
            m = re.match(r'(\s*)var (\w+)', ln)
            if m and not m.group(2).startswith('_'):
                name = m.group(2)
                if len(re.findall(r'\b' + re.escape(name) + r'\b', text)) <= 1:
                    out.append(f'{m.group(1)}var _ = {name}')
        return out

    def gen_function(self):
        """A top-level `def h(p0: T, …): R` with a body that returns an R.  Only
        callable helpers defined *earlier* are visible in its body (registered
        after emission), so no self-/mutual recursion — programs always terminate."""
        name = self.fresh('h')
        np = self.rng.randint(0, 3)
        ptypes = [self.pick(PRIMS) for _ in range(np)]
        pnames = [f'p{i}' for i in range(np)]
        ret = self.pick(PRIMS)
        env = dict(zip(pnames, ptypes))
        self._params = set(pnames)     # params are read-only (const in Zig)
        budget = [self.caps['stmts'] + 2]
        body = self.gen_block(env, 1, budget)
        body.append('    return ' + self.gen_expr(ret, env, self.caps['expr_depth']))
        self._params = set()
        # discard any never-referenced param (Zig rejects unused params)
        text = '\n'.join(body)
        for pn in pnames:
            if len(re.findall(r'\b' + pn + r'\b', text)) <= 1:
                body.insert(0, f'    var _ = {pn}')
        body = self._use_unused(body)
        sig = ', '.join(f'{pn}: {pt}' for pn, pt in zip(pnames, ptypes))
        self.funcs.append((name, ptypes, ret))
        return [f'def {name}({sig}): {ret}'] + body

    def program(self):
        decls = []
        if self.caps.get('funcs'):
            for _ in range(self.rng.randint(0, self.caps['funcs'])):
                decls += self.gen_function() + ['']
        env = {}
        budget = [self.caps['total_stmts']]
        body = self.gen_block(env, 1, budget)
        body = self._use_unused(body)
        return '\n'.join(decls) + 'def main()\n' + '\n'.join(body) + '\n'


DEFAULT_CAPS = {
    'stmts': 4,          # statements per block
    'depth': 3,          # max nesting depth for if/while
    'expr_depth': 3,     # max expression tree depth
    'total_stmts': 40,   # global statement budget
    'funcs': 3,          # up to this many top-level helper functions
    'optionals': True,   # generate T? optionals, nil, `if x as y`, orelse
}


def gen(seed, caps=None):
    return Gen(seed, caps).program()


if __name__ == '__main__':
    import sys
    s = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    print(gen(s))
