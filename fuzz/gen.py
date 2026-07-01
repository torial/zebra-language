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

PRIMS = ('int', 'float', 'bool', 'str')


class Gen:
    def __init__(self, seed, caps=None):
        self.rng = random.Random(seed)
        self.seed = seed
        self.n = 0            # unique-name counter
        self.caps = caps or DEFAULT_CAPS

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
        # base case: literal or in-scope var
        if depth <= 0 or self.maybe(0.35):
            vs = self.vars_of(env, ty)
            if vs and self.maybe(0.6):
                return self.pick(vs)
            return self.lit(ty)
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
        if env:
            choices += ['assign', 'assign']
        if indent < self.caps['depth']:
            choices += ['if', 'while']
        k = self.pick(choices)
        d = self.caps['expr_depth']
        if k == 'decl':
            ty = self.pick(PRIMS)
            name = self.fresh()
            e = self.gen_expr(ty, env, d)
            env[name] = ty
            # annotate sometimes to exercise both inferred + annotated paths
            if self.maybe(0.5):
                return [f'{ind}var {name}: {ty} = {e}']
            return [f'{ind}var {name} = {e}']
        if k == 'assign':
            name = self.pick(list(env.keys()))
            return [f'{ind}{name} = {self.gen_expr(env[name], env, d)}']
        if k == 'print':
            if env and self.maybe(0.6):
                name = self.pick(list(env.keys()))
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
    def program(self):
        env = {}
        budget = [self.caps['total_stmts']]
        body = self.gen_block(env, 1, budget)
        return 'def main()\n' + '\n'.join(body) + '\n'


DEFAULT_CAPS = {
    'stmts': 4,          # statements per block
    'depth': 3,          # max nesting depth for if/while
    'expr_depth': 3,     # max expression tree depth
    'total_stmts': 40,   # global statement budget
}


def gen(seed, caps=None):
    return Gen(seed, caps).program()


if __name__ == '__main__':
    import sys
    s = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    print(gen(s))
