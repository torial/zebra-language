<!-- doc-status: design -->
# Containers are references — BUG-501's fix

**Status:** §6 decided 2026-09-30; steps 2 (intent probe), 3 (the measure, §5.1) and 4 (Phase 0: the one spelling, gate `container-spelling`) done; Phase 1 split into prep steps 1a-1c and the flip 1d (§9). Direction decided by Sean, 2026-09-30 ("go with (a), start
the design note for 501"): containers get **shared (reference) semantics everywhere**.
Drafted by Opus 5.5 the same day. Nothing below is built; the decisions marked
**OPEN** are Sean's.
**Bug:** BUG-501 (`BUGS.md`) — filed by Fable for nested containers, re-scoped the same day
when the root turned out to be lower.

---

## 1. The defect, measured

A Zebra `List(T)` is emitted as a Zig `std.ArrayList(T)` — a **struct** holding a pointer to
its buffer plus its own length and capacity — and Zebra copies that struct **by value**
wherever a value is copied. The copy shares the buffer but not the length, so it is neither
a copy nor an alias: the next append on either side can overwrite the other's elements.
`HashMap` (`std.StringHashMap` / `_zbr_AutoMap`) and `Set` have the same shape.

Measured on `93c4f2b` (2026-09-30), none of these involves nesting:

| shape | result |
|---|---|
| `var b = a` (List of one), `b.add(20)`, `a.add(30)` | `b[1]` reads **30** |
| `def all(): List(int)` returning `.items`; `got.add(2)`, then `bag.items.add(3)` | `got[1]` reads **3** |
| a struct holding a List, copied, both appended to | the copy reads the original's element |
| `r1 except xs = r1.xs`, then append to the result | appends into the buffer `r1` still owns |
| `outer.set(k, local)`, then mutate `local` | the stored value does not see it (a real copy -- `_zbr_boxed`) |
| `if outer.get(k) as x`, then mutate `x` | the stored value DOES see it (a real alias) |
| a `def` returning a `get as`-bound map | shallow copy: works or loses the write depending on whether the map had storage |

So today's behaviour is not one rule applied badly; it is three rules (alias, copy,
half-copy) chosen by syntactic position. The field-return row is the common one -- a class
that hands out its list is ordinary code -- and it corrupts silently.

**What is NOT affected:** a container PARAMETER is already passed by pointer when the callee
mutates it (`fn fill(xs: *std.ArrayList(i64))`, called `fill(&c)`), so `def fill(xs)` that
adds is correct today. Strings are immutable slices. Classes are already references (`*T`).

## 2. The rule after the change

> **Primitives, `str`, structs, tuples, enums and unions are values. Classes and
> containers (`List`, `HashMap`, `Set`) are references.**

Containers join classes, which is the model Python and Cobra readers already hold, and the
one the GameEngine (and the book) assumed. Consequences, all deliberate:

- `var b = a` aliases. `b.add(x)` is visible through `a`.
- A method returning a field returns the field. `got.add(2)` mutates `bag.items`.
- `outer.set(k, local)` stores the same list; later mutations of `local` are visible in `outer`.
- `get as`, a returned element, a nested container: all the same object.
- A struct that holds a container is a value whose FIELD is a reference: copying the struct
  shares the list (Swift's class-in-struct). `except` shares unless the field is replaced.
- A copy is explicit: `xs.copy()` (see §6, OPEN).

## 3. Representation

A container value becomes a **pointer to a heap container**: `List(int)` emits as
`*std.ArrayList(i64)`, allocated from the current allocator at construction. Zig auto-derefs
a single pointer for field access and method calls, so the bulk of today's emit
(`xs.items.len`, `xs.append(alloc, v)`, `for (xs.items)`) is unchanged.

What changes: construction (allocate a header), field defaults (a pointer cannot default to
`.empty`), the `&c` that today makes a parameter mutable (the value is already the pointer),
and every runtime helper that type-switches on `std.ArrayList` (show/print, JSON, Reflect,
node-addon, FFI marshalling) -- they must see through the pointer.

**What goes away:** the nested-container boxing (`_zbr_boxed` / `_zbr_unboxed`,
`exprYieldsBox`, `storedElemBoxed`, `isBoxedElemType*`) -- an element of type `List(T)` is
already a pointer -- and the mutable-parameter machinery (`caller_ptr_params`, the
`&`-at-call-site decision, BUG-097's guard). Today's footprint: `std.ArrayList(` appears 34
times in `CodeGen.zbr` and 86 in the preamble; `std.StringHashMap(` 13 / 3; `_zbr_AutoMap(`
12 / 2; `.empty` 29 / 58; `caller_ptr_params` 12; `exprYieldsBox` 8.

**Rejected alternatives.** *Deep copy on every value copy* (value semantics) -- Sean chose
shared; it is also the expensive direction and contradicts what `get as` already does.
*Box only the containers that escape* (escape analysis) -- a fourth rule beside the three
already there, and the analysis is exactly the kind of position-sensitive judgement that
produced this bug. *An interim compile error on every container copy* -- would refuse
ordinary read-only code (`var items = obj.items`), much of it in the compiler's own source.

## 4. Isolation: one spelling first, then the flip

**Phase 0 -- one name, no behaviour change.** Codegen emits `_ZbrList(T)`, `_ZbrMap(V)`,
`_ZbrAutoMap(K, V)`, `_ZbrSet(T)` and one constructor per kind, all defined in the runtime as
TODAY's value types. Gates: `output_sweep` byte-identical; the round-trip byte-identical in
behaviour; and a new static lint -- **no emitted `std.ArrayList(` / `std.StringHashMap(` /
`_zbr_AutoMap(` outside the runtime's definitions** -- watched red on a deliberately
unconverted site. Phase 0 is shippable on its own and is the stopgap built as the endstate's
interface: the flip then happens in a handful of definitions plus the construction, default
and `&`/`.*` sites, which the lint has already enumerated.

**Phase 1 -- the flip.** The definitions become pointers; construction allocates; defaults
are handled per §6; the boxing and mutable-parameter machinery is deleted; runtime helpers
deref through one `_zbr_cont(x)` helper rather than each learning the new shape.

## 5. Measure first: where does a copy happen today?

Before Phase 1, instrument the codegen points where a container value is copied out of a
LIVE location -- exactly the sites whose meaning changes -- the way §28a instrumented its
guesses (`--warn-container-copy`, recorded unconditionally, reported on request):

| kind | shape |
|---|---|
| `bind` | `var x = <ident / member / index>` and plain assignment from one |
| `return_field` | `return .field` / `return local` of a container held elsewhere |
| `ctor_arg` | a container argument to a struct constructor or struct literal |
| `store` | a container argument to `set` / `add` / `put` / an index assignment |
| `except` | `except` on a value holding a container field |
| `struct_copy` | `var r2 = r1` where `r1`'s type holds a container |
| `capture` | a closure capturing a container local |

Run it over the corpus, `selfhost/` (the compiler's own source), the book and the GameEngine
(Fable runs the engine, controls first). Report counts per kind. The same flag is then the
migration aid for users: it names every site whose meaning the flip changes.

**The compiler is its own largest risk, and the round-trip will not say where.** The selfhost
copies a struct and mutates the copy as an idiom (`var then_g = ig`, `this except ...` on the
`Generator`). Today a List field mutated through such a copy changes the copy's length and
leaves the original's alone; after the flip it changes both. The round-trip would catch a
resulting miscompile but not point at it -- only the measure over `selfhost/` does, so it
runs, and its `selfhost/` sites are read by hand, before Phase 1.

### 5.1 Measured, 2026-09-30 (step 3 done)

`--warn-container-copy` on `228aa45`, each run gated on the control
(`tools/fixtures/container_copy_control.zbr`, every kind exactly once):

| kind | repo (818 files) | GameEngine (146, Fable) |
|---|---|---|
| bind_alias / bind_field / bind_call | 17 / 5 / 279 | 100 / 26 / 523 |
| return_alias / return_field / return_call | 65 / 3 / 13 | 209 / 27 / 5 |
| store | 13 | 61 |
| ctor_arg | 49 | 0 |
| struct_copy | 74 | 0 |
| except | 132 | 0 |
| **total** | **650** | **951** |

**The compiler's own source, read by hand.** Its exposure is one idiom: `Generator` is a
STRUCT, and its builders (`var g = this except ...; return g`, 26 sites) and child
generators (`var then_g = ig`, 9) copy it -- after the flip the copies share its eight
container fields. Every one was checked for a mutation THROUGH a copy:
`owner_members`, `owner_invariants`, `lam_hint` are only ever REASSIGNED wholesale (a
rebind, not a mutation, so sharing changes nothing); `exposed_module_vars` and
`ext_method_ret` are filled once on the root generator in the module pre-pass;
`closure_lambdas` / `closure_ret_fns` are name-keyed registries whose companion name set
(`closure_vars`, a `StrSet`) is a CLASS and so already shared by every copy today -- the flip
makes the map agree with the set it is consulted through. The other struct copies (AST
nodes in `returnedCaptureLambda`, `PModule` in main.zbr, `AstBuilder`'s `struct_pat`) are
returned or stored once and never mutated through the copy. **No compiler site depends on a
copy staying separate.** (The measure only became able to see this on the day it was written:
struct method bodies were not checked at all -- BUG-508 -- so its first run saw none of the
`Generator` sites.)

**The GameEngine, read by Fable** (site list: `container_copy_sites_228aa45.txt` in the GameEngine repo's `docs/` -- another repository):
336 of 951 are `var comps = .components.get(id)` then mutate -- the shape shared semantics
makes correct by definition; no caller writes through a returned field (the F18 audit); the
rebuild-then-assign sites replace a field wholesale. The wrapper classes (`TagList`,
`Inventory`, `Scope`) are classes, so they appear nowhere -- they are the sites that STOP
needing a wrapper.

**What this does not cover:** a container COPIED today and then mutated on the assumption that
the original is unaffected, where the copy happens inside a larger expression (the measure sees
statements, not nested stores), and `*_call` sites, which over-report. `output_sweep`'s 466
programs are the witness for those in Phase 1.

### 5.2 Review (Fable, reviewer of record -- Sean, 2026-10-01: "coordinate w/ Fable as a reviewer")

Fable reviews every Phase 1 step on the GameEngine (regen, suite, both live autoplays) and
signs 1d off in writing before it commits. Two findings from the first read, both adopted:

1. **Copy-then-iterate-while-mutating** is a changed-behaviour class `output_sweep` may not
   see: `var xs = .field` then `for x in xs` whose body adds to or removes from `.field`
   works today by accident (the copy has its own length) and after 1d iterates a list being
   edited -- possibly skipping or doubling an element without printing anything different.
   The `bind_field` rows are the list to read. **The repo's 5, read 2026-10-01:** the 3 in
   `selfhost/` are read-only (`mstmts_pre = m.stmts`, `sargs = sref2_ir.args`,
   `alias_value_args = aa.args`). The 2 in `examples/tears_of_the_tuon.zbr` (462, 1368) are
   the MVU immutable-update idiom -- `var lg = m.log; lg.add(line); return m except log = lg`
   -- which after 1d also mutates the OLD model's list. That is harmless only if nothing keeps
   the previous model: **checked**, both GUI sections replace it (`_model =
   _mvu_update(_model, msg)`) and retain nothing. The 1d-correct spelling for a program that
   does keep an old model is `m.log.copy()`. Fable reads the engine's 26.
2. **1c's allocation side.** Allocating every container field with no initializer would, for
   a field the constructor then assigns, allocate a header and drop it -- once per object, on
   the current allocator. So 1c allocates ONLY a container field that no constructor path
   assigns (no initializer, and not assigned at the top level of a `cue init` body); a field
   the constructor sets costs nothing extra. Measured before landing: heap growth per 1M
   constructions of a class with such a field, before vs after.

## 6. Decisions -- DECIDED (Sean, 2026-09-30: "agree with all four recommendations, proceed")

Settled as recommended: (1) `==` on containers is **structural**; (2) `xs.copy()` is a
**shallow** copy and no deep-copy method is added (`<<-` remains the deep copy);
(3) a container field with no initializer is **auto-allocated empty** at construction;
(4) **`StringBuilder` is in scope**, same phase. The options as they were laid out:


1. **`==` on containers.** Today it leaks: the front end accepts `a == b` on two Lists and
   zig refuses (`operator == not allowed for type 'array_list.Aligned(i64,null)'` --
   BUG-506, to be filed). Options: **structural** (Python; recommended -- element-wise, recursive
   for nested containers, using each element type's own `==`), **refused** with a message,
   or **identity** (`is`-style; surprising for Python readers and easy to misuse).
2. **The copy API.** Recommended: `xs.copy()` -- SHALLOW (a new container, the same element
   values; nested containers shared), Python's `list.copy()`. Is a deep copy wanted too
   (`deepCopy()`), or is `<<-` (which already deep-copies -- QUICKSTART "`<<-` copy-out operator") enough?
3. **A container field with no initializer.** Today it is `= undefined` -- the program reads
   garbage if the constructor forgets it. Recommended: **auto-allocate empty** at
   construction (the field is always a live, empty container). Alternative: refuse a
   container field that no constructor path initialises.
4. **`StringBuilder` in scope?** It is `std.ArrayList(u8)` underneath and has the same
   half-copy hazard. Recommended: yes, same phase -- a builder is mutable and Python/Cobra
   readers expect it to be an object.

## 7. Risks, each with its witness

| risk | witness |
|---|---|
| a program whose output depended on today's copy/half-copy | `output_sweep` (466 programs): every changed output is read and classified -- relied-on copy, or a corruption the change FIXED |
| the compiler mutating through a struct copy (§5) | the measure over `selfhost/`, read by hand; then the round-trip |
| MVU GUI models: `model except items = ...` now shares lists between old and new model | read both GUI sections for any keeping or comparing of the previous model; `gui-scaffold-*`; Sean clicking |
| `allocate` scopes: the container HEADER now lives in the inner arena | `<<-` must allocate a new header in the parent (today it allocates a new ArrayList, so the shape exists); a probe that copies out and then uses the result after the scope |
| `sys.go` captures and `Chan(List(T))`: what was half-copied is now shared, so races surface | `concurrency` fixtures under `output_sweep`; document that a container sent on a channel is shared |
| runtime helpers that switch on `std.ArrayList` | Phase 0's lint lists them; `full_sweep` + `compile_check-inline` |
| performance: one indirection + one arena allocation per container | **expected magnitude: <5%** on index-heavy loops (the header pointer is loop-invariant and hoists). Measured with `bench_ab` + `bench/index_bench.zbr`, interleaved, before and after Phase 1 |
| the GameEngine's wrapper-class workarounds (`TagList`, `Inventory`) | Fable regenerates and runs the suite + live autoplays before the commit, as for the sig change |

## 8. The intent probe -- written before any code

`docs/design/container_reference_probe.zbr` (+ `.expected`), STAGED here rather than in
`test/boundary/` because a probe there must pass today (`@boundary-pending` encodes CURRENT
behaviour, not intent), and this one fails by construction. It moves to `test/boundary/` in
Phase 1 as the acceptance test, unedited. It states every row of §1's table
under the NEW rule, plus the §2 consequences (struct copy shares, `except` shares, a returned
map is the map). Its expectations are authored from this document, committed UNRUN -- the
`boundary_check` discipline -- and it fails on today's compiler by construction. It becomes
the acceptance test for Phase 1.

## 9. Order of work

1. Sean settles §6.
2. The intent probe (§8), committed unrun.
3. The measure (§5), run over corpus / `selfhost/` / book / engine; `selfhost/` sites read.
4. Phase 0 (§4) -- no behaviour change, gated, shippable alone. **DONE 2026-09-30
   (`68eb161`).**
5. Phase 1, SPLIT (decided 2026-10-01): the flip itself is one atomic commit that cannot be
   left half-done on `main`, so everything that can land first without changing behaviour
   does, each gated on `output_sweep` byte-identical and an extended `container-spelling`:
   - **1a. Constructors.** Every construction of a Zebra-visible container -- emitted, or
     inside the runtime (the scratch list a `split` / `lines` / `tokenize` / `repeat` block
     builds and hands back) -- goes through `_zbr_list_new(T)` / `_zbr_map_new(V)` /
     `_zbr_automap_new(K, V)`, returning today's value. The lint then refuses
     `_ZbrList(...).empty` and `.init(` outside those definitions.
   - **1b. Runtime helper signatures.** A helper that TAKES a container accepts a value or a
     pointer (normalised through `_zbr_val`); one that RETURNS a container declares
     `_ZbrList(T)` and builds it with 1a's constructors. Measure first how many of the
     runtime's 106 container uses are Zebra-visible.
   - **1c. Container fields with no initializer** are allocated at construction (§6.3) --
     strictly a behaviour change, but only for programs that read undefined memory today;
     its own commit, with fixtures for the class `cue init` path and the struct-literal path.
   - **1d. The flip** -- the definitions become pointers, the boxing and mutable-parameter
     machinery is deleted. DAYTIME, with Sean and Fable reading the `output_sweep` diffs:
     every changed output is either a program that relied on today's half-copy or one the
     flip FIXED, and someone has to say which. FULL tier; Fable's engine witness;
     QUICKSTART §2 and the List / HashMap sections rewritten to the §2 rule; CHANGELOG
     states it as a semantics change; the intent probe moves to `test/boundary/`.
6. BUG-501 closes with the probe green.
