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

# F1/BUG-162 regression surface: names that shadow a Zig primitive.  The
# compilers escape these to @"name" since 2026-07-02; generating them
# occasionally keeps the escaping differentially tested.  (Before the fix
# these were masked out of generator prefixes to stop F1 noise burying
# genuine divergences — see FINDINGS.md F1.)
PRIM_SHADOW = ('i8', 'u32', 'f64', 'usize', 'c_int', 'i64', 'u8', 'f32')


class Gen:
    def __init__(self, seed, caps=None):
        self.rng = random.Random(seed)
        self.seed = seed
        self.n = 0            # unique-name counter
        self.caps = caps or DEFAULT_CAPS
        self.funcs = []       # [(name, [param_types], ret_type, throws_bool)] — callable helpers
        self.structs = {}     # name -> [(field, type)] — user struct types
        self.classes = {}     # name -> {'fields': [(f,ty)], 'methods': [(m,[pt],ret)]}
        self.enums = {}       # name -> [variant_name, ...] — bare enums
        self.unions = {}      # name -> [(variant, payload_type|None), ...] — tagged unions
        self._params = set()  # read-only names in scope (fn params — Zig consts)
        self._self_fields = {}  # field -> type, when generating inside a class method body
        self._shadow_used = set()  # primitive-shadowing names already declared (must stay unique)
        self._throw_ok = False  # true in a `throws` fn body or a catch-wrapper body — where a
                                # throws call `f()?` is legal (§28b: always explicit `?`)

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

    def _user_fields(self, tn):
        if tn in self.structs:
            return self.structs[tn]
        if tn in self.classes:
            return self.classes[tn]['fields']
        return []

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
        # `list.len` → int
        if ty == 'int':
            lists = [k for k, v in env.items() if v.startswith('List(')]
            if lists and self.maybe(0.2):
                return f'{self.pick(lists)}.len'
        # `.field` — a same-typed field of the enclosing class (inside a method body)
        if self._self_fields:
            sf = [fn for fn, ft in self._self_fields.items() if ft == ty]
            if sf and self.maybe(0.25):
                return '.' + self.pick(sf)
        # `structvar.field` / `classvar.field` → the field's type
        fcands = [(k, fn) for k, v in env.items()
                  for fn, ft in self._user_fields(v) if ft == ty]
        if fcands and self.maybe(0.25):
            sv, fn = self.pick(fcands)
            return f'{sv}.{fn}'
        # `classvar.method(args)` returning `ty`
        mcands = [(k, m, pts) for k, v in env.items() if v in self.classes
                  for (m, pts, r) in self.classes[v]['methods'] if r == ty]
        if mcands and self.maybe(0.2):
            cv, m, pts = self.pick(mcands)
            args = ', '.join(self.gen_expr(pt, env, depth - 1) for pt in pts)
            return f'{cv}.{m}({args})'
        # call a helper function that returns `ty`.  A `throws` helper is only
        # callable where `?` is legal (self._throw_ok — a throws-fn body or a
        # catch-wrapper body) and is emitted with the explicit `?` (§28b: the
        # generator produces explicit-`?` to match the migration and to
        # differential-test the `?`-propagation codegen).
        callable_here = [f for f in self.funcs if f[2] == ty and (not f[3] or self._throw_ok)]
        if callable_here and self.maybe(0.3):
            name, ptypes, _ret, throws = self.pick(callable_here)
            args = ', '.join(self.gen_expr(pt, env, depth - 1) for pt in ptypes)
            return f'{name}({args})?' if throws else f'{name}({args})'
        # ternary if(cond, a, b) — any prim type (BUG-167/F8 surface)
        if self.caps.get('ternary') and self.maybe(0.12):
            c = self.gen_expr('bool', env, depth - 1)
            return f'if({c}, {self.gen_expr(ty, env, depth-1)}, {self.gen_expr(ty, env, depth-1)})'
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
        # params are const in Zig; List vars are construct-once (never reassigned —
        # gen_expr produces no List values, and reassigning a list isn't interesting)
        assignable = [k for k in env if k not in self._params and not env[k].startswith('List(')
                      and env[k] not in self.structs and env[k] not in self.classes
                      and env[k] not in self.enums and env[k] not in self.unions]
        if assignable:
            choices += ['assign', 'assign']
        opt_in_scope = [k for k, v in env.items() if v.endswith('?')]
        list_in_scope = [k for k, v in env.items() if v.startswith('List(')]
        # struct + class instances share field-write; struct/class construction
        # is offered whenever a type exists.
        udt_in_scope = [k for k, v in env.items() if v in self.structs or v in self.classes]
        if self.caps.get('lists'):
            choices += ['listdecl']
        if self.structs:
            choices += ['structdecl']
        if self.classes:
            choices += ['classdecl']
        if self.enums:
            choices += ['enumdecl']
        if self.unions:
            choices += ['uniondecl']
        # in-scope enum/union vars can be dispatched with `branch`
        tagged_in_scope = [k for k, v in env.items() if v in self.enums or v in self.unions]
        if udt_in_scope:
            choices += ['fieldwrite']
        if self._self_fields:
            choices += ['selffieldwrite']   # `.field = expr` — mutating method
        if indent < self.caps['depth']:
            choices += ['if', 'while']
            if opt_in_scope:
                choices += ['ifas']    # `if optvar as bound` — nil-narrowing
            if list_in_scope:
                choices += ['forin']   # `for e in list`
            if self.caps.get('ranges'):
                choices += ['fornum']  # `for i in a : b [: s]` / `a..b` (BUG-165/F9)
            if tagged_in_scope:
                choices += ['branch']  # `branch v` over enum/union variants
        k = self.pick(choices)
        d = self.caps['expr_depth']
        if k == 'listdecl':
            et = self.pick(PRIMS)
            name = self.fresh('xs')
            lines = [f'{ind}var {name}: List({et}) = List({et})()']
            for _ in range(self.rng.randint(0, 3)):
                lines.append(f'{ind}{name}.add({self.gen_expr(et, env, d)})')
            env[name] = f'List({et})'
            return lines
        if k == 'fornum':
            # Numeric range loop — all three spellings lower to the same i64
            # for_num counter (BUG-165/F9).  Bounds are small literals so the
            # run oracle terminates; the counter is read-only in the body.
            v = self.fresh('r')
            lo = self.rng.randint(-3, 3)
            hi = lo + self.rng.randint(0, 4)
            form = self.pick(('colon', 'dotdot', 'step'))
            if form == 'colon':
                head = f'{ind}for {v} in {lo} : {hi}'
            elif form == 'dotdot':
                head = f'{ind}for {v} in {lo}..{hi}'
            else:
                head = f'{ind}for {v} in {lo} : {hi} : {self.rng.randint(1, 3)}'
            env2 = dict(env); env2[v] = 'int'
            self._params.add(v)           # counter is read-only in the body
            body = self.gen_block(env2, indent + 1, budget)
            self._params.discard(v)
            return [head] + body
        if k == 'enumdecl':
            en = self.pick(list(self.enums.keys()))
            v = self.pick(self.enums[en])
            name = self.fresh('en')
            env[name] = en
            return [f'{ind}var {name} = {en}.{v}']
        if k == 'uniondecl':
            un = self.pick(list(self.unions.keys()))
            (v, pt) = self.pick(self.unions[un])
            name = self.fresh('un')
            env[name] = un
            if pt is not None:
                return [f'{ind}var {name} = {un}.{v}({self.gen_expr(pt, env, d)})']
            return [f'{ind}var {name} = {un}.{v}()']
        if k == 'branch':
            bv = self.pick(tagged_in_scope)
            tname = env[bv]
            if tname in self.enums:
                variants = [(v, None) for v in self.enums[tname]]
            else:
                variants = self.unions[tname]
            ind2 = '    ' * (indent + 1)
            ind3 = '    ' * (indent + 2)
            out = [f'{ind}branch {bv}']
            # Full coverage exercises exhaustiveness codegen; else-form ~40%.
            use_else = self.maybe(0.4)
            covered = variants if not use_else else variants[:max(1, len(variants) - 1)]
            for (v, pt) in covered:
                if pt is not None:
                    b = self.fresh('bp')      # payload binding — a prim value
                    out.append(f'{ind2}on {tname}.{v} as {b}')
                    out.append(f'{ind3}print("v=${{{b}}}")')   # use the binding
                else:
                    out.append(f'{ind2}on {tname}.{v}')
                    out.append(f'{ind3}print("hit")')
            if use_else:
                out.append(f'{ind2}else')
                out.append(f'{ind3}pass')
            return out
        if k == 'forin':
            lv = self.pick(list_in_scope)
            et = env[lv][5:-1]            # List(T) → T
            e = self.fresh('e')
            env2 = dict(env); env2[e] = et
            self._params.add(e)           # loop capture is read-only
            body = self.gen_block(env2, indent + 1, budget)
            self._params.discard(e)
            # No unused-var guard: since BUG-164 the compilers discard unused
            # loop captures themselves — generating them keeps that tested.
            return [f'{ind}for {e} in {lv}'] + body
        if k == 'structdecl':
            sname = self.pick(list(self.structs.keys()))
            args = ', '.join(self.gen_expr(ft, env, d) for _, ft in self.structs[sname])
            name = self.fresh('s')
            env[name] = sname
            return [f'{ind}var {name} = {sname}({args})']
        if k == 'classdecl':
            cname = self.pick(list(self.classes.keys()))
            args = ', '.join(self.gen_expr(ft, env, d) for _, ft in self.classes[cname]['fields'])
            name = self.fresh('c')
            env[name] = cname
            return [f'{ind}var {name} = {cname}({args})']
        if k == 'fieldwrite':
            sv = self.pick(udt_in_scope)
            fn, ft = self.pick(self._user_fields(env[sv]))
            return [f'{ind}{sv}.{fn} = {self.gen_expr(ft, env, d)}']
        if k == 'selffieldwrite':
            fn, ft = self.pick(list(self._self_fields.items()))
            return [f'{ind}.{fn} = {self.gen_expr(ft, env, d)}']
        if k == 'decl':
            ty = self.pick(PRIMS)
            name = self.fresh()
            # Occasionally shadow a Zig primitive (exact name required — the
            # whole point is the @"name" escape path).  Must be globally fresh:
            # a repeat would be a Zebra redeclaration error.
            if self.maybe(0.10):
                cand = self.pick(PRIM_SHADOW)
                if cand not in self._shadow_used:
                    self._shadow_used.add(cand)
                    name = cand
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
            bound = self.fresh('ob')   # not 'u' — `u{n}` collides with Zig `uN` uint types (F1)
            env2 = dict(env); env2[bound] = env[ov][:-1]   # narrowed to base type
            self._params.add(bound)        # `if x as y` capture is read-only (const in Zig) — no reassign
            body = self.gen_block(env2, indent + 1, budget)
            self._params.discard(bound)
            return [f'{ind}if {ov} as {bound}'] + body
        if k == 'print':
            # only interpolate a plain prim var (optionals/lists/structs aren't printable)
            printable = [x for x, v in env.items() if v in PRIMS]
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

    def gen_struct(self):
        """A top-level `struct S` with 1–3 typed prim fields + a `cue init` that sets
        them.  Registered in self.structs so bodies can construct it and read/write
        its fields."""
        name = self.fresh('S')
        nf = self.rng.randint(1, 3)
        fields = [(f'f{i}', self.pick(PRIMS)) for i in range(nf)]
        self.structs[name] = fields
        lines = [f'struct {name}']
        for fn, ft in fields:
            lines.append(f'    var {fn}: {ft}')
        lines.append('    cue init(' + ', '.join(f'{fn}: {ft}' for fn, ft in fields) + ')')
        for fn, _ in fields:
            lines.append(f'        .{fn} = {fn}')
        return lines

    def gen_enum(self):
        """A top-level `enum E` with 2–4 bare (payload-less) variants.  Registered
        so bodies can build `E.variant` values and `branch` over them."""
        name = self.fresh('E')
        nv = self.rng.randint(2, 4)
        variants = [f'ev{i}' for i in range(nv)]   # ev* — never shadows a Zig primitive
        self.enums[name] = variants
        return [f'enum {name}'] + [f'    {v}' for v in variants]

    def gen_union(self):
        """A top-level `union U` with 2–4 variants, each payload-less or a single
        prim payload.  Registered with payload types so bodies can construct
        `U.variant(x)` / `U.variant()` and `branch` with payload binding."""
        name = self.fresh('U')
        nv = self.rng.randint(2, 4)
        variants = []
        lines = [f'union {name}']
        for i in range(nv):
            v = f'wv{i}'                            # wv* — distinct, non-primitive
            if self.maybe(0.6):
                pt = self.pick(PRIMS)
                lines.append(f'    {v}: {pt}')
                variants.append((v, pt))
            else:
                lines.append(f'    {v}')            # payload-less
                variants.append((v, None))
        self.unions[name] = variants
        return lines

    def gen_class(self):
        """A top-level `class C` (reference type): typed prim fields + `cue init` +
        1–2 methods.  Method bodies read `.field` and may write `.field` (exercising
        both `*const self` and mutating `*self` codegen) and return a prim."""
        name = self.fresh('C')
        nf = self.rng.randint(1, 3)
        fields = [(f'f{i}', self.pick(PRIMS)) for i in range(nf)]
        lines = [f'class {name}']
        for fn, ft in fields:
            lines.append(f'    var {fn}: {ft}')
        lines.append('    cue init(' + ', '.join(f'{fn}: {ft}' for fn, ft in fields) + ')')
        for fn, _ in fields:
            lines.append(f'        .{fn} = {fn}')
        methods = []
        for _ in range(self.rng.randint(1, 2)):
            mname = self.fresh('m')
            np = self.rng.randint(0, 2)
            ptypes = [self.pick(PRIMS) for _ in range(np)]
            pnames = [f'p{i}' for i in range(np)]
            ret = self.pick(PRIMS)
            env = dict(zip(pnames, ptypes))
            saved_p, saved_sf = self._params, self._self_fields
            self._params, self._self_fields = set(pnames), dict(fields)
            mbody = self.gen_block(env, 2, [self.caps['stmts']])
            mbody.append('        return ' + self.gen_expr(ret, env, self.caps['expr_depth']))
            self._params, self._self_fields = saved_p, saved_sf
            text = '\n'.join(mbody)
            for pn in pnames:
                if len(re.findall(r'\b' + pn + r'\b', text)) == 0:
                    mbody.insert(0, '        var _ = ' + pn)
            mbody = self._use_unused(mbody)
            sig = ', '.join(f'{pn}: {pt}' for pn, pt in zip(pnames, ptypes))
            lines.append(f'    def {mname}({sig}): {ret}')
            lines += mbody
            methods.append((mname, ptypes, ret))
        self.classes[name] = {'fields': fields, 'methods': methods}
        return lines

    def gen_function(self):
        """A top-level `def h(p0: T, …): R` with a body that returns an R.  Only
        callable helpers defined *earlier* are visible in its body (registered
        after emission), so no self-/mutual recursion — programs always terminate.

        Kinds (BUG-16x/§28b throws surface):
          - 'normal'  : non-throws, cannot call throws helpers.
          - 'throws'  : `def h(...): R throws` with a conditional `raise`; its
                        body may call earlier throws helpers with `?`
                        (throws→throws propagation).  Reachable only from other
                        throws/catch contexts, so any raise is contained.
          - 'catch'   : non-throws wrapper with a method-level `catch` clause;
                        its body forces a throws call `f()?` (so the catch is
                        meaningful) and the clause returns a default on error.
                        Callable from main → makes throws reachable + runnable."""
        # Does any earlier helper throw?  A catch-wrapper needs one to call.
        have_throwers = any(f[3] for f in self.funcs)
        kind = 'normal'
        if self.caps.get('throws'):
            r = self.rng.random()
            if r < 0.30:
                kind = 'throws'
            elif r < 0.55 and have_throwers:
                kind = 'catch'
        name = self.fresh('h')
        np = self.rng.randint(0, 3)
        ptypes = [self.pick(PRIMS) for _ in range(np)]
        pnames = [f'p{i}' for i in range(np)]
        ret = self.pick(PRIMS)
        env = dict(zip(pnames, ptypes))
        self._params = set(pnames)     # params are read-only (const in Zig)
        self._throw_ok = kind in ('throws', 'catch')
        budget = [self.caps['stmts'] + 2]
        body = self.gen_block(env, 1, budget)
        # A catch-wrapper must actually call something throwing, or the `catch`
        # clause is on a non-throwing function.  Force one throws call.
        if kind == 'catch':
            throwers = [f for f in self.funcs if f[3]]
            fn, fpt, _fret, _t = self.pick(throwers)
            fargs = ', '.join(self.gen_expr(pt, env, self.caps['expr_depth']) for pt in fpt)
            body.append(f'    var _cw = {fn}({fargs})?')
            body.append('    var _ = _cw')
        # A throws function needs a real raise so the `throws` is not vacuous.
        if kind == 'throws':
            cond = self.gen_expr('bool', env, self.caps['expr_depth'])
            body.append(f'    if {cond}')
            body.append(f'        raise "e{self.n}"')
        body.append('    return ' + self.gen_expr(ret, env, self.caps['expr_depth']))
        self._throw_ok = False
        self._params = set()
        # discard any never-referenced param (Zig rejects unused params).  A param
        # name appears in the body text only when *used*, so count == 0 ⇒ unused
        # (unlike a local `var`, whose own declaration line counts as one use).
        text = '\n'.join(body)
        for pn in pnames:
            if len(re.findall(r'\b' + pn + r'\b', text)) == 0:
                body.insert(0, f'    var _ = {pn}')
        body = self._use_unused(body)
        sig = ', '.join(f'{pn}: {pt}' for pn, pt in zip(pnames, ptypes))
        throws_kw = ' throws' if kind == 'throws' else ''
        out = [f'def {name}({sig}): {ret}{throws_kw}'] + body
        if kind == 'catch':
            # Method-level catch clause (column-0 `catch`, indented body) —
            # runs when a `?` inside the body propagates an error.
            out.append('catch')
            out.append('    return ' + self.lit(ret))
        self.funcs.append((name, ptypes, ret, kind == 'throws'))
        return out

    def program(self):
        decls = []
        # enums/unions first — simplest, no deps; bodies branch over them.
        if self.caps.get('enums'):
            for _ in range(self.rng.randint(0, self.caps['enums'])):
                decls += self.gen_enum() + ['']
        if self.caps.get('unions'):
            for _ in range(self.rng.randint(0, self.caps['unions'])):
                decls += self.gen_union() + ['']
        if self.caps.get('structs'):
            for _ in range(self.rng.randint(0, self.caps['structs'])):
                decls += self.gen_struct() + ['']
        if self.caps.get('classes'):
            for _ in range(self.rng.randint(0, self.caps['classes'])):
                decls += self.gen_class() + ['']
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
    'lists': True,       # generate List(T) — construction, .add, .len, for-in
    'structs': 2,        # up to this many struct types (fields, construction, access)
    'classes': 2,        # up to this many class types (fields, methods, dispatch)
    'enums': 2,          # up to this many enum types (E.variant values, branch)
    'unions': 2,         # up to this many union types (payload variants, branch binding)
    'ternary': True,     # if(cond, a, b) call-form ternary (BUG-167/F8)
    'ranges': True,      # for_num range loops: `a : b [: s]` and `a..b` (BUG-165/F9)
    'throws': True,      # `throws` fns + `?` propagation + method-level `catch` (§28b surface)
}


def gen(seed, caps=None):
    return Gen(seed, caps).program()


if __name__ == '__main__':
    import sys
    s = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    print(gen(s))
