<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-283. Next new bug: BUG-284.**

> **Numbering correction 2026-08-05.** Two different bugs were both filed as
> BUG-260 by sessions working in parallel. The query-param one below was filed
> first (`5717d80`) and keeps the number; the C-dependency one was filed later
> (`fcd9c7c`) and is **renumbered BUG-261**. Commit `fcd9c7c`'s message still
> says "BUG-260" — that is the record of what was written at the time and is
> left alone; look for BUG-261 in the ledgers.
>
> No gate could see this: `doc_lint` D4 only checks that a cited BUG-NNN exists
> *somewhere*, so a duplicate satisfies it twice over.

---

### BUG-271: unknown method on a builtin type is deferred to Zig but stamped `void`, so it can never return a value

**Found 2026-08-06** extending the sqlite preamble in the zebra-sprocket router
project. The resolver's deferral of unknown methods to Zig is what makes
preamble-seam extensions possible at all -- but the emitted binding annotates
the result as `void`:

```
var segs = d.query_segments("SELECT 1")
```

```
const segs: void = d.query_segments("SELECT 1");
```

So a method that genuinely exists in a modified preamble compiles, runs, and
cannot hand its result back to Zebra. Emitting `const segs = ...` (letting Zig
infer) would make the deferral fully usable. Worked around in zebra-sprocket by
routing through the known `query()` signature with a `"@segments "` SQL-prefix
marker, which keeps the known `List(SqliteRow)` return type.

### BUG-270: `extern def` returning `int` lowers to `i64` against C's `c_int` -- negative returns silently corrupt

**Found 2026-08-06** in zebra-sprocket (`probe_extern3.zbr` / `probe_extern4.zbr`).

```
extern def sqlite3_libversion_number(): int
```

```
extern fn sqlite3_libversion_number() i64;
```

The C function returns `c_int`. On x86-64 this LINKS and WORKS for non-negative
values (32-bit register writes zero-extend), which is what makes it dangerous:
`sqlite3_libversion_number()` returned 3053004 correctly, so nothing looks
wrong -- but a C function returning `-1` arrives as `4294967295`. Every sqlite
API that signals "no answer" with a negative return would misreport through
this path. The extern lowering needs a C-ABI integer type (`c_int`) rather than
Zebra's native `i64`, or a distinct declared type for C ints.

### BUG-269: `extern def` returning `str` lowers to `[]const u8`, which is not a legal C-ABI return type

**Found 2026-08-06** in zebra-sprocket (`probe_extern2.zbr`), first call through
`extern` into the vendored sqlite.

```
extern def sqlite3_libversion(): str
```

```
extern fn sqlite3_libversion() []const u8;
```

```
error: return type '[]const u8' not allowed in function with calling convention 'x86_64_win'
```

A C `const char*` is `[*:0]const u8` in Zig; the extern lowering emits the
native slice type instead. Declaration-only externs parse and resolve fine
(the gap is exactly at the ABI boundary), so BUG-258's fix is confirmed
working -- this is the next layer down.

### BUG-283: a `zig"..."` literal has no way to NAME a Zebra type except by guessing the emitted spelling

**Found 2026-08-12** designing BUG-281 B. Three literals in the corpus do exactly this:

```zebra
zig"Counter{}"      zig"Greeter{}"      zig"Point{}"
```

They work only because codegen happens to emit a Zebra `class Counter` as a Zig
`Counter`. That is an **ambient** dependency on an internal spelling — the UNGIT test the
escape hatch currently fails. Nothing declares it a contract, nothing checks it, and
`zig"..."` contents are the one construct every lint here is structurally blind to
(BUG-267), so a change to the emitted spelling breaks user code that no tool can find.

BUG-281 B changes that spelling deliberately (`_zbr_ty_Counter`), which is what surfaces
this. **The right fix is not to preserve the guess** — an alias that does so was tried and
silently defeated BUG-281 B's whole purpose, see that entry. It is to give the literal a
way to *ask*, so the compiler substitutes the current spelling and the user never encodes
it. Shape to consider (not decided):

```zebra
zig"${Counter}{}"          # interpolate the emitted spelling of a known type
```

The compiler already knows every type name (`class_names`, `struct_names`, `enum_names`,
`union_names`), so resolution is available; what is missing is a syntax and a refusal for
a name that does not resolve. Note the refusal matters as much as the substitution — a
typo must say *"no Zebra type named Countr"* at compile time rather than emit text that
fails later inside Zig.

**Control when fixing:** the three corpus literals migrated to the new form must still
produce a working program, AND an unknown name must be REFUSED with a Zebra diagnostic
naming it. A substitution that silently passes through an unrecognised name would restore
exactly the ambient guess this exists to remove.

### BUG-282: `--output-dir` at a path that does not exist PANICS instead of refusing

**Found 2026-08-11** as a side-effect of probing BUG-281 — I typo'd nothing, I simply
had not created the directory yet.

```
$ zebra --output-dir /some/dir/that/does/not/exist hello.zbr
  parsing...
  parsed OK
  resolved OK
thread 61956 panic: File.write error
error return context:
???:?:?: 0x140e47953 in ??? (zebra.exe)
stack trace:
(empty stack trace)
```

**Isolated with a negative control**, not inferred: the same invocation on a
*known-good* corpus file (`test/bug280_keyword_idents.zbr`) panics identically, so it is
the missing directory and not the input program. Exit code 3.

**Why this is worth a ticket rather than a shrug.** The message names neither the
directory, the flag, nor the fix, and the stack trace is empty — so the reader's most
natural conclusion is that their *program* broke the compiler. It arrives **after**
`parsed OK` / `resolved OK`, which actively points attention at the wrong end. This is
the UNGIT "nothing ambient" test failing at all three clauses: the refusal does not name
the reason, does not name the fix, and the condition is checked at *use* rather than at
*declaration* — the flag is known at startup and the directory could be validated (or
created) there, before any work is done.

The fix is a `makePath`-or-refuse at argument-parsing time, with a message naming the
path. Whether it should CREATE the directory or refuse is a real decision:
`--output-dir` reads like an instruction, and `mkdir -p` semantics would match how
`--emit-zig` behaves for its own file. Both compilers need whichever answer wins.

**Control when fixing:** assert on the printed message, not the exit code — exit 3 is
already produced by unrelated failures, so scoring on it would pass a compiler that
panicked for a different reason. A `smoke_run_fail`-style fixture asserting the path
appears in the diagnostic is the shape.

### BUG-281: SEVEN emit families print Zig keywords bare — A/C/D/F closed 2026-08-12, B/E/G open
<!-- bug-open-ok: four of seven families are closed in both compilers and pinned by test/bug280_keyword_idents.zbr; B, E and G are open and carry a decision for Sean (see RECOMMENDATION) -->

**STATE 2026-08-12.** A (`@derive` bodies), C (capture read), D (enum members, union
variants, switch prongs and construction) and F (bare field read in a method) are **fixed
in BOTH compilers** and pinned by `test/bug280_keyword_idents.zbr`, which now runs all
four shapes and is registered with `smoke_run`. B (the type name), E (a method name) and
G (a top-level fn name, bootstrap only) remain open — see the revised recommendation
below, which now offers a third option that was not visible when this was filed.

**Found 2026-08-11** finishing BUG-280's selfhost half, by a four-line probe rather than
by reading. BUG-280 fixed the field/constructor/member/literal paths in both compilers
and its gate reports clean. **The bootstrap is broken in all of these too** — so this is
not a selfhost gap, and `divergence_check` will not see it.

**FILED AS THREE FAMILIES; A WIDENED PROBE FOUND SEVEN.** The first version of this entry
listed A, B and C, derived from a probe that exercised `@derive`, a keyword-named class,
and a capture block. Adding a keyword as an enum member, a union variant, a method name,
a top-level function name and a bare field read inside a method — all legal Zebra
identifiers today — turned up four more in a single emit. That is the same ratio as
BUG-280 (reading found 4 of 9; a probe found 9), arriving immediately after the lesson
was written down. **The probe is the map. Widen it before believing a family count.**

| | family | bootstrap | selfhost |
|---|---|---|---|
| A | `@derive` bodies — `self.<field>` in toString/eql/hash | broken | broken |
| B | the type NAME itself — `pub const opaque = struct` | broken | broken |
| C | a capture READ in a lambda body | broken | broken |
| D | enum members and union variants | broken | broken |
| E | method name — declaration AND call site | broken | broken |
| F | bare field read inside a method (no `.` prefix) | broken | broken |
| G | top-level function name | **broken** | **OK** |

**G is the interesting one, and it points at the cheap general fix.** The selfhost emits
`pub fn _zbr_fn_anyframe()` while the bootstrap emits `pub fn anyframe()`. The selfhost is
immune *for free*, because the prefix already makes the name collision-free — exactly the
reasoning that governs `_zbr_mv_` for module vars and `_ttag_`/`_reflect_` for type tags.
Wherever a name is already prefixed, this whole bug class cannot occur.

**Note also what D, E and F share with C:** in each, a name is escaped at one end and bare
at the other, so the emitted Zig is internally inconsistent rather than uniformly wrong.
That is why no single error message describes the bug — Zig stops at the first one.

Repro: `tools/fixtures/bug281_keyword_gaps_repro.zbr` — deliberately OUTSIDE `test/`,
because neither compiler can build it and a corpus file in that state would put
`full_sweep`, `smoke` and `registration_check` in the red for known, filed debt.

```zebra
@derive(Debug, Eq, Hash)
struct Der
    var align: int = 0

class opaque
    var packed: int = 0
```

Emitted by `zebra-bootstrap --emit-zig`, and it does not compile:

```
error: expected pointer dereference, optional unwrap, or field access, found 'align'
```

**A — `@derive` bodies emit `self.<field>` bare.** `genDeriveToString`,
`genDeriveEql` and `genDeriveHash` build their member access with a raw `{s}`:

```zig
return std.fmt.allocPrint(_allocator, "Der(align={}, ...)", .{self.align, ...});
return (self.align == other.align) and ...;
std.hash.autoHashStrat(&hasher, self.align, .Deep);
```

The field is DECLARED `@"align": i64` two lines above. This is the first error Zig
reaches, which is why it masks B and C.

**B — the type NAME itself is never escaped.** `pub const opaque = struct {`,
`pub fn get(self: *const opaque)`, `pub fn init() *opaque`, `opaque.init()`. Note the
asymmetry that makes this easy to misread as fine: `_ttag_opaque` and
`_reflect_opaque_name` are *correct*, because the prefix already makes them
collision-free — the same reasoning that governs `_zbr_mv_` in `genFieldDecl`.
BUG-280 *did* escape `genType`'s class-name emits, which makes the two halves
**disagree**: an annotated local emits `*@"opaque"` while the declaration it names emits
`pub const opaque`. Escaped and bare are the same identifier for a Zig *primitive* (the
case `emitName` was originally written for) but not for a Zig *keyword*, where the bare
spelling does not parse at all. So fixing B means fixing the declaration side to match,
not reverting `genType`.

**C — a capture is declared escaped and read bare.** Within one emitted struct:

```zig
const addIt = struct {
    @"noalias": i64,                       // declaration — escaped
    fn call(self: @This(), v: i64) i64 {
        return (v + self.noalias);         // read — BARE
    }
}{ .@"noalias" = @"noalias", };            // designator — escaped
```

The declaration and designator were in BUG-280's site map; the body reference goes
through `genIdentRaw`'s capture-field path (`selfhost/CodeGen.zbr` ~10475) and was not.
Inconsistent inside a single struct is the sharpest statement of it.

**A, C, D and F are done** — each was a bounded set of emit sites and the same one-line
change BUG-280 made everywhere else: route the emit through `emitName`. D was the widest
and the least obvious: the enum member and union variant *declarations* are only half of
it, and the gate also named the **switch prongs** (`.align => {`) and the **construction
designator** (`Shape{ .volatile = 12 }`). Reading would have found the declarations and
stopped.

**B AND E ARE A DECISION, NOT A CHORE — and there are three options, not two.** The
counting matters: the escape is only ever needed at **emit** sites, because
`class_names` / `struct_names` / `enum_names` / the dotted `Owner.method` maps hold the
*Zebra* name and never change. A crude grep puts B at roughly **45** candidate emit sites
in the selfhost (12 of them the bare `owner` spelling) and E at roughly **21**, plus the
bootstrap's own set. So it is wide-but-mechanical, not a map audit — the word "invasive"
in the first version of this entry was an adjective derived from reading, which is the
habit this bug exists to discourage.

1. **Escape at every emit site.** Supports the names fully. Wide (~66 selfhost sites plus
   the bootstrap), but each edit is trivial and the probe-plus-gate makes completeness
   checkable rather than believed.
2. **Prefix the emitted spelling**, the way `_zbr_mv_` already does for module vars and
   `_zbr_fn_` for top-level functions. This *immunises the whole class permanently* — no
   escaping is ever needed again, at any emit site anyone adds later. That is why family
   G costs the selfhost nothing today. The catch is that type names cross module
   boundaries (`Module.ClassName`), so the prefix must be consistent across modules AND
   across the bootstrap/selfhost pair. Biggest change, biggest payoff.
3. **Refuse at the front end**, with a Zebra diagnostic naming the word and the fix.
   Cheapest by far — one check in the resolver — and *strictly better than today*, where
   the user gets a Zig parse error against generated code carrying no Zebra source
   location. The cost is that the name stays unusable, which is what reserving a word
   means; this is effectively "Zig's keywords are reserved for TYPE and METHOD names,
   but free everywhere else."

**DECIDED 2026-08-12: option 2, the prefix.** Sean's call — an investment against future
work, and he wants the bootstrap retired soon anyway, so paying a bootstrap tax here is
not worth it. **Selfhost-first is therefore acceptable**, under the standing rule: the
bootstrap must still COMPILE the selfhost source, which it does, because no `.zbr` source
changes.

**The argument for 2 over 1 is NOT "no escaping ever needed" — that is weak, since both
cost the same ~45 sites up front. It is the FAILURE MODE afterward:**

| | a newly-added emit site that forgets | |
|---|---|---|
| escaping (1) | breaks only for a keyword-named type — **silent, latent, rare** | this bug, twice |
| prefixing (2) | emits `Route` when nothing declares it — **Zig errors on the first test that uses any class** | loud, immediate, universal |

That converts a rare silent failure into an unmissable one, which is the principle the
rest of this repo is built on. It is also why family G costs the selfhost nothing today.

**THE ONE REAL COST, found by measuring rather than reasoning.** Of 70 `zig"..."` inline
literals, **three** reference a Zebra type by its emitted spelling — `zig"Counter{}"`,
`zig"Greeter{}"`, `zig"Point{}"`. So prefixing raises a language question: **is the
emitted Zig spelling of a Zebra type part of the public contract for `zig"..."` escape
hatches?** Note these are the construct the lints are structurally blind to (BUG-267), so
they cannot be found by any checker — only by grep.

**THE COMPATIBILITY ALIAS WAS TRIED AND IT IS WRONG. Do not reintroduce it.**

The proposal was to emit, alongside the prefixed declaration:

```zig
pub const _zbr_ty_Route = struct { ... };
pub const Route = _zbr_ty_Route;   // <- WRONG. Do not do this.
```

reasoning that generated code would use the prefix while hand-written `zig"Route{}"`
kept working. **It silently defeats the entire change**, and this was measured, not
argued:

| | 26 reference sites still un-migrated | result |
|---|---|---|
| alias emitted | every bare `ZqClass` RESOLVES through it | **whole probe compiles clean** |
| alias removed | nothing declares the bare name | `error: use of undeclared identifier 'ZqClass'`, ×26 |

So with the alias, the loud-failure property that is the *entire justification* for
prefixing over escaping does not exist. It is a silent fallback sitting on the exact path
that decides "is this correct", biased — as the repo's own instrument rules say they
always are — toward *nothing is wrong*. Both directions were run; the failure was seen,
not assumed.

**Accepted cost: the emitted Zig spelling of a Zebra type becomes PRIVATE.** A
hand-written `zig"Foo{}"` naming a type by that spelling stops resolving. Three such
literals exist in the corpus (`zig"Counter{}"`, `zig"Greeter{}"`, `zig"Point{}"`) and
must be migrated in the same commit. Naming a Zebra type from inside a `zig"..."` literal
then needs a real mechanism instead of ambient knowledge — **BUG-283**.

**Sequencing.** B (type names) first, since E (method names) is namespaced inside the
type and becomes easier once B lands. G disappears for free the moment the bootstrap is
retired, and is already a non-issue in the selfhost.

**THE SITE LIST IS DERIVED AND READY — `tools/fixtures/bug281_typename_sites_probe.zbr`.**
Every type in it is named `Zq…`, a token that appears nowhere else in the compiler or the
runtime, so `grep Zq` over the emit returns exactly the sites and nothing else. 51
occurrences collapse to **~15 distinct emit positions**, and the rule separating them is
the same one BUG-280 settled: **an identifier gets the prefix; a string never does.**

| must be prefixed (identifier) | |
|---|---|
| `pub const ZqClass = struct` | declaration — class, struct, enum, union |
| `pub fn bump(self: *ZqClass)` | method receiver |
| `pub fn init() *ZqClass` / `create(ZqClass)` | class init return + allocator arg |
| `pub fn init(a: i64) ZqDerived` | struct synth-init return type |
| `toString(self: *const ZqDerived)`, `eql(…, other: *const ZqDerived)` | derive receivers |
| `_zbr_fn_takesZq(c: *ZqClass, p: ZqPlain)` | parameter types (via `genType`) |
| `pub fn _zbr_fn_makesZq() ZqPlain` | return type |
| `return ZqPlain{ .b = 2 }` / `ZqUnion{ .num = 6 }` | struct + union construction |
| `inner: ZqPlain`, `maybe: ?*ZqClass` | field types |
| `ZqClass.init()`, `ZqClass.shared`, `ZqEnum.two` | qualified access |
| `std.ArrayList(ZqPlain)` | container type argument |

| must NOT be prefixed | why |
|---|---|
| `_ttag_ZqClass`, `_reflect_ZqClass_name` | **already prefixed** — and they are the existing proof this approach works |
| `_zbr_hash("ZqClass")`, `"ZqClass"`, `"ZqDerived(a={})"` | strings — data, not identifiers |
| `&.{"ZqPlain", "?ZqClass"}` | reflection FIELD TYPES — the Zebra type name AS DATA. Prefixing this would silently corrupt reflection, and no gate would see it |

That last row is the over-application hazard, in the same shape as BUG-280's reflection
strings: verify by diffing a pre/post emit of this probe, where every changed line must
be an identifier gaining the prefix and nothing else.

**What this does NOT fix, measured 2026-08-12 in answer to a direct question:** the
trailing-`_` convention in the selfhost sources. Of 94 such identifiers, **48** dodge a
**ZEBRA** keyword (`var_`, `class_`, `if_`, `int_`, `bool_`, `except_`…), 44 are
stylistic, and only **2** (`fn_`, `void_`) dodge a Zig name. A Zebra-keyword collision
happens in the TOKENIZER, before anything is emitted, so no emit-side scheme can touch
it. The lever for those 48 is freeing Zebra keywords — the `lint_reserved_words` / U4
line of work. Two problems that look like one.

**Do not fix these by hand-hunting `w.emit(<x>.name)` call sites.** There are hundreds,
most of them correct. The reliable procedure is the one that produced this table: extend
the probe with a new declaration form, emit, grep, and fix only what the grep names.

**Why no gate saw it.** `keyword_ident_check.sh` passed the bootstrap the whole time.
Its own header declares the limit — "the fixture is the coverage" — and this is the
receipt: three broken families, one gate, green. It is also invisible to
`divergence_check --gate` by construction, since both compilers are wrong identically,
and to `compile_check`/`full_sweep`, because no corpus file names a field or a class
after a Zig keyword.

**Control when fixing:** extend `test/bug280_keyword_idents.zbr` with the probe's three
shapes **before** touching codegen, and watch `keyword_ident_check.sh` go red first. The
fixture deliberately does *not* carry them today — a corpus file neither compiler can
build would put `full_sweep` and `smoke` in the red for known, filed debt.

### BUG-279: `zig build test` is red on committed code, in no gate tier, for three unrelated reasons

**Found 2026-08-09** by running it after a front-end change, on the assumption it was
part of the contract. It is not: `gates.sh` does not run it in either tier, and
CLAUDE.md's *"What the gates do NOT cover"* section — which exists precisely so the
unrun set stays visible — does not list it either. So it is neither run nor accounted
for as unrun, which is the one state that section is designed to make impossible.

It is also the first command in CLAUDE.md's **Build and test** block, three lines under
`zig build`. A newcomer types it before anything else.

**Three independent failures, none related to the others, all on committed code:**

1. **`src/AstPrinter.zig:283` — `switch must handle all possibilities`**, missing
   `TypeRef.fn_type`. The inline `def(P): R` function-type was added to
   `Ast.TypeRef` (the closure-factory work) and the printer never grew a case.
   Compile error, so `test/main.zig`'s whole integration binary does not build.

2. **`src/CodeGen.zig:17750` — `expected 16 argument(s), found 15`.** A test calls
   `generate(...)` with the signature it had before a parameter was added. The unit
   test binary does not build either.

3. **`escape_hatches_check`: `stdlib_preamble.zig` count drift, expected 70, actual
   **72**.** Two `page_allocator` uses were added without bumping `EXPECTED_PREAMBLE`
   in `tools/escape_hatches_check.sh`. That tool prints the correct procedure in its
   own failure message — verify each new use has a comment justifying why it must
   outlive the program arena, then bump the counter — so this one is **a review, not
   an edit**, and belongs to whoever added the uses. <!-- bug-open-ok: leg 3 is a review someone else owns; legs 1 and 2 are ordinary fixes -->

**Why the green board did not see any of it.** Legs 1 and 2 are in code that only the
Zig test binaries compile; `zig build` alone never analyses them, and every gate builds
the compiler rather than the tests. Leg 3's checker is only invoked from `zig build
test`. So `gates.sh --full` can be 27/27 — it was, on the commit before this entry —
while the command in the README is broken three ways.

**The structural fix is not "fix these three".** It is to decide whether `zig build
test` is part of the contract. If it is, it belongs in a tier and the drift stops being
possible. If it is not, it belongs in the *uncovered* table with a date, like
`gramgen`, `node_addon_test` and the GUI paths — which is the whole point of that
table. Leaving it in neither is how all three of these landed.

**Control when fixing:** legs 1 and 2 must be verified by `zig build test` reaching the
*run* phase, not merely by the compile error disappearing — a test binary that builds
and then fails is a different state from one that never built, and the second is what
has been hiding here.

### BUG-274: four broad Expr walkers default to FALSE and have gaps — the BUG-260 shape, surveyed

**Found 2026-08-07** by running `lint_expr_walkers`'s analysis read-only across ALL 53
functions that branch over `Expr`, rather than only the two that had opted in. This is a
SURVEY, not a reproduction: each gap below is a candidate, and each needs its own
judgement about whether the missing variant can actually carry the thing that walker
looks for.

**The survey answered two questions.** First, the opt-in design was right: **36 of 53
walkers handle 4 or fewer variants** and are legitimately narrow (`getVariantKey` wants
`member` and nothing else), so blanket checking would have been mostly noise. Second, the
danger is not "has gaps" — it is "has gaps AND defaults to FALSE":

| walker | handles | gaps | file |
|---|---|---|---|
| `exprMentionsThis` | 16 | **12** | CodeGen.zbr |
| `exprHasTry` | 17 | 10 | CgHelpers.zbr |
| ~~`containsResultRef`~~ | 22 | 6 | **CLOSED — BUG-278, 3 of 4 reproduced** |
| `exprHasSelfCall` | 25 | 2 | CgHelpers.zbr |

**Every gap count in that table is inflated by one, and the inflation is the LINT's, not
the code's.** `lint_expr_walkers` hardcodes `ident` as ident-bearing — correctly, because a
walker asking *"does this use the name X?"* that skips idents is broken by definition. But
`containsResultRef` and `collectAndEmitOldSnapshots` ask a different question, *"does this
contain a node of KIND K?"*, and an `ident` can never be one: `AstBuilder` builds
`Expr.result_` from `PNode.expr_result` and `Expr.old_` from an `old` construct, never from
an identifier. Both now carry an `expr-walker-ok: ident` waiver with that reasoning. Before
working `exprHasTry` (10) or `exprMentionsThis` (12), check which of their gaps are the
same artifact — and note this ticket already warns against working it by counting.

Five other broad walkers default conservatively (`true` / `pass`), so their gaps are
harmless — the same asymmetry that made BUG-260 silent while the identical omission in
its sibling was merely cautious.

**`exprMentionsThis` is the one to look at first.** The project memory records
"`stmtMentionsThis` must stay EXACT" as a live constraint from the differential fuzzer
work, and this walker has twelve unmodelled ident-bearing variants under a FALSE default.

**Precedent that these are not hypothetical:** `test/contract_old_compound_test.zbr`
exists because `collectAndEmitOldSnapshots` failed to recurse into `array_lit` and missed
an `old` snapshot — the identical class, already fixed once, in a walker that still shows
4 gaps.

**How to work it:** annotate one walker at a time with `# expr-walker: exhaustive`, let
the lint enumerate its gaps, and for each ask whether that variant can carry what the
walker seeks. Deliberate omissions get `# expr-walker-ok: <variant> <reason>`. Do NOT
bulk-add cases — a walker that answers a different question (does this mention `this`?
does it contain `try`?) has different right answers per variant.

**PROBED 2026-08-08 — `exprMentionsThis`'s gaps are NOT reachable via its main consumer,
so gap-count OVERSTATES risk and this ticket should not be worked by counting.**

Its answer feeds `bodyMentionsThis`, which decides whether to emit `_ = self;`. A wrong
FALSE would emit that discard beside a real use of `self` and Zig would reject the pair —
the exact BUG-260 symptom, and loud rather than silent. So it is directly testable, and I
tested it: `this` used ONLY inside a `list_lit`, `array_lit`, `tuple_lit` or `set_lit`,
as a return value, a `for` iterable and a `while` condition. **All compile.**

The probe was verified able to see before its negative was believed: a method that
genuinely does not mention `this` DOES get `_ = self;` (control = 1), and the list-literal
probe does not (0). So the walker detects `this` inside those constructs by some route —
either another mechanism reaches it first, or the answer is not consumed there.

**What this does and does not establish.** It does not prove the twelve gaps are harmless;
it proves I could not construct a reproducer through the consumer that matters, having
first shown the probe can distinguish the two cases. Treat the remaining three walkers
(`exprHasTry`, `containsResultRef`, `exprHasSelfCall`) the same way: find the consumer,
work out what a wrong FALSE would produce, and try to produce it. A walker whose wrong
answer nothing acts on is a cosmetic finding.

**Do NOT bulk-add the missing cases to `exprMentionsThis`** — it carries a live "must stay
EXACT" constraint from the differential-fuzzer work, and there is now measured evidence
that its gaps are unreached rather than latent. Changing a hot path on gap-count alone
would be change without evidence.

**PROBED 2026-08-08 — `containsResultRef` CLOSED as BUG-278, and the method worked.** Its
consumer emits `var _result: T` only when it says yes, while `genExpr` emits `_result`
unconditionally, so a wrong FALSE produces `use of undeclared identifier '_result'`. Three
of its four remaining candidates reproduced on the first attempt (`slice`, `opt_chain`,
`except_`). Two lessons for the two walkers still open:

1. **Diff the twin before editing.** `collectAndEmitOldSnapshots` does the same walk for
   `old()` and had *already* diverged — it handled `slice` and `except_`, this one did not.
   Neither had drifted from a spec; they had drifted from *each other*.
2. **Grade by loudness, not by gap count.** These gaps were real and worth fixing, but the
   symptom is a hard Zig error, not a wrong program. That is a different severity from
   BUG-260 and belongs in the triage, since `exprMentionsThis`'s probe found the same
   thing (loud, and unreachable besides).

**Control when fixing:** each walker needs BOTH directions, as BUG-260 and BUG-267 did —
the newly-handled construct must be detected, AND something that genuinely lacks the
property must still answer no. A one-sided fix here silently over-reports, which for
`exprHasTry` would wrap non-throwing expressions.

### BUG-272: a parameter used only inside `ensure … old p` is discarded, and the obvious fix breaks `--turbo`

**Found 2026-08-06** by `tools/lint_expr_walkers.py` on its first run — the only finding
across the two walkers that opted in, and the same gap I had reached by hand, which is
some evidence the oracle is calibrated.

```
class C
    var v: int = 0
    def bump(p: int)
        ensure
            v != old p
        v = v + 1
```

**Plain build fails.** The emit discards `p` and then snapshots it:

```zig
pub fn bump(self: *C, p: i64) void {
    _ = p;                    // <- walker says "unused"
    const _old_0 = p;         // <- but the old-snapshot reads it
```
```
error: pointless discard of local constant
```

**Same family as BUG-260/BUG-267** — `nameUsedInExpr` has no `old_` case, so a use inside
an `old` expression is invisible.

**Why it is NOT just a missing branch.** Measured both ways:

| build | snapshot emitted? | is `p` really used? | `_ = p;` |
|---|---|---|---|
| plain | yes | **yes** | wrong — breaks the build |
| `--turbo` | no (contracts stripped) | **no** | **required** |

So `old x` is a use *only when contracts survive*. Adding a plain `on Expr.old_` case
fixes the default build and breaks `--turbo`, where the parameter genuinely becomes
unused and the discard is what makes it compile. `nameUsedInExpr` is a pure helper in
`CgHelpers.zbr` with no view of `strip_contracts`, so this needs a signature change or a
decision moved to the call site — not a new branch.

Waived in the walker lint with that reason (`# expr-walker-ok: old_`), so it stays visible
rather than silently accepted.

**Control when fixing:** the program above must compile and run with NO flags **and** with
`--turbo`; and a parameter that is unused in both modes must still get its discard in
both. Three of those four combinations pass today, which is why a one-directional fix
would look convincing.

### BUG-267: `zig"…"` literals do not participate in MUTATION analysis (usage half ✅ FIXED 2026-08-06)
<!-- bug-open-ok: PARTIAL — the usage half is fixed and the heading says so, but the MUTATION half is still open, so this belongs in the open ledger. Move it when the write half lands. -->

**Found 2026-08-05** probing a real third-party DLL. Same root class as BUG-260 (a
parameter used only inside a query bind list), and worse-placed: `zig"…"` is the only way
to touch a C pointer, so the escape hatch reserved for FFI is exactly the construct the
analysis cannot see into.

    var p = Py_GetVersion()                       # read ONLY inside the escape
    zig"const _c: [*:0]const u8 = @ptrFromInt(p); out = std.mem.span(_c);"

    error: pointless discard of local constant   ->  _ = p;   emitted alongside the use
    error: cannot assign to constant             ->  `out` emitted const; escape assigns it

Both walks stop at the literal: a variable **read** only inside it is treated as unused,
and one **assigned** only inside it is treated as never mutated. Working around it needs
two unrelated dummy statements (a fake comparison to use `p`, a dead branch to make `out`
a var) — see `docs/extern_ffi_design.md` §9 for the full repro.

**Control when fixing:** a var read only inside a `zig"…"` must NOT get a discard, and one
assigned only inside it must be emitted `var`; a genuinely unused var must still get its
discard, and a genuinely non-mutated one must still be `const`. Both directions.

**READ HALF FIXED 2026-08-06.** `mightUseNameInExpr` now carries the `zig_lit` case its
sibling walker has had since B3, so a local read only inside an escape is no longer
discarded. Pinned by `test/bug267_ziglit_local_use_test.zbr`, which asserts BOTH
directions — the escape case compiles, AND a genuinely unused local still gets its
`_ =`, so a fix that simply stopped discarding anything fails there rather than passing.
**What remains open is the WRITE half only** (see the last section below).

**Re-scoped 2026-08-06 — the earlier scoping below was WRONG about the read half, and
wrong in the expensive direction: it argued for new language syntax to solve a problem
this codebase had already solved one walker over.**

**The read half is an INCONSISTENCY, not a missing capability.** `zigLitMentionsWord()`
already exists in `selfhost/CgHelpers.zbr`, and its own comment states why: *"A param
referenced from a `zig"…"` literal is used, so it must not be discarded."* There are two
usage walkers, and only one of them learned that lesson:

| walker | `zig_lit` case | used by |
|---|---|---|
| `nameUsedInExpr` | scans the text | parameter discards |
| `mightUseNameInExpr` | falls into "no user idents" -> false | **local** discards |

Measured, same construct both ways:

    param used only in zig"…"  ->  no discard    (correct, long-standing)
    local used only in zig"…"  ->  `_ = q;`      -> pointless discard of local constant

So the fix is to give `mightUseNameInExpr` the same `zig_lit` case the sibling walker
already has. No new syntax; it makes locals behave like parameters, which is what a reader
would assume already happens.

**The scan does not skip Zig strings or comments**, so a name appearing only inside one
counts as a use, the discard is suppressed, and Zig reports `unused local variable`. That
is a real limit and it is stated here rather than hidden — but it is **already accepted for
parameters**, has not bitten, and its failure direction is a compile error rather than a
silent miscompile.

**Two designs considered and NOT pursued, recorded so they are not re-derived:**

- **`zig"…" reads a, b`** (an explicit read list). Exact rather than heuristic, and it was
  the recommendation until `zigLitMentionsWord` turned up. Rejected because it adds
  language surface to answer a question the compiler already answers elsewhere, and would
  leave TWO mechanisms for "what does this escape touch" — the more likely long-term
  hazard than the false-positive it prevents. Revisit only if the string/comment
  false-positive is actually hit.
- **A `zig` BLOCK form with `reads` / `writes` clauses** (mirroring `capture`). The more
  complete design, and the only one that addresses the write half for multi-statement
  escapes. Not pursued because **the need was never demonstrated**: every real case so far
  is a value flowing OUT of C, which expression form already handles. Revisit when someone
  hits a genuine multi-statement escape that must mutate an existing local.

**The write half is separate and remains open.** No mutation walker scans `zig"…"` at all,
so a local assigned only inside a statement-form escape is still emitted `const` and Zig
rejects the assignment. Expression form (`var out = zig"…"`) avoids it entirely and is the
recommended shape, so this is a documented limit rather than a blocker.

**Related:** BUG-260 is the same walker question in a different construct (a parameter used
only inside a query bind list). It is NOT fixed by this — that construct is a list literal,
not a `zig_lit` — but it is worth checking against whatever fix lands here.


### BUG-264: the selfhost lowers a module-scope `StrSet.add` as `List.append`, so it cannot re-emit its own source

**Found 2026-08-05** by the round-trip gate, while adding a module-scope `StrSet` to
`selfhost/CodeGen.zbr` for BUG-261. Worked around there (`List(str)` instead); the
underlying defect is untouched.

A file-scope `var s: StrSet = StrSet()` followed by `s.add(x)`:

| | emit |
|---|---|
| bootstrap | `pub var _zbr_mv_s: *StrSet = undefined;` … `_zbr_mv_s.add(path);` — **correct** |
| selfhost | types it `StrSet`, then lowers the call as a List: `_zbr_mv_s.append(_zbr_rt._allocator, path)` |

The selfhost's output does not compile:

```
error: method invocation only supports up to one level of implicit pointer dereferencing
note: struct declared here -- pub const StrSet = struct {
```

So the type is resolved correctly and only the **method lowering** is wrong: `.add` on a
module-scope var is treated as `List.add` unconditionally. `_implicit_try_sites` and
`_inference_guess_sites`, the only pre-existing module-scope collections in that file, are
both `List(str)` — so the wrong branch has always been the right answer until now, which
is presumably why this has never fired.

**A selfhost-LEADS-vs-LAGS inversion worth noting:** here the bootstrap is right and the
shipping compiler is wrong, the same direction as BUG-254.

**Only the round-trip gate can see this class.** `zig build` builds `zebra.exe` from the
*bootstrap's* (correct) emit, so the compiler builds, runs, and passes all 313 smoke
fixtures while being unable to emit valid Zig for its own source. Nothing before step 3 of
`bootstrap_check` looks at what the selfhost emits for that file.

**Control when fixing:** a module-scope `StrSet` with `.add`/`.contains_` must round-trip;
a module-scope `List(str)` with `.add` must still emit `.append(allocator, …)`. Both
directions — the easy wrong fix is to stop treating module-var `.add` as List at all.

### BUG-263: `use foo exposing bar` emits no aliases when `foo` is a native dep

**Found 2026-08-05** while fixing BUG-261, by reading the bootstrap branch being
ported rather than by hitting it.

Both compilers attach the exposed-name aliasing to the **Zebra-dep** branch of
`genUse` only (`src/CodeGen.zig:4899-4930`, `selfhost/CodeGen.zbr` genUse). So on
a dep that resolved to `.c` or `.zig`:

    use CUtils exposing c_add          # c_add is never bound to anything

The `use` itself still works — `CUtils.c_add(...)` resolves — so this is a missing
convenience, not a miscompile. It fails at the Zig stage with an undefined
identifier rather than silently, which is why it has gone unnoticed.

**It is a SHARED hole, and that is the point.** Fixing it in the selfhost alone
would open a selfhost gap in `divergence_check`, which is currently 0 and is the
property the port exists to preserve. Either fix both compilers together or
neither. Filed rather than fixed for that reason.

### BUG-262: the selfhost never materializes a native `.zig` dep, so `use SomeZigModule` fails

**Found 2026-08-05** while verifying that BUG-261's fix did not disturb the native
`.zig` path. It did not — this is pre-existing and independent.

`test/zig_interop_test.zbr` (`use ZigMath`, with a tracked `test/ZigMath.zig`):

| | result |
|---|---|
| `zebra-bootstrap.exe test/zig_interop_test.zbr` | runs, prints its output |
| `zebra.exe test/zig_interop_test.zbr` | `unable to load 'ZigMath.zig': FileNotFound` |

`genUse` correctly emits `@import("ZigMath.zig")` — the emit is not the bug. The
selfhost writes its generated Zig to a **temp directory** and never copies the
native `.zig` dep beside it, so the import has nothing to resolve against. The
`.c` case escapes this because a `.c` is passed to `zig build-exe` as an argument
rather than resolved by path from the emitted file.

Note `selfhost/main.zbr`'s dep walk has **no `.zig` candidate at all** (it tries
`.zbr`, then `module_path/.zbr`, then `.c`); a native `.zig` dep falls through it
silently and is never recorded anywhere. The fix is to detect it there and copy
it into the output dir alongside the emitted `.zig`.

**Same class as BUG-261** — native-dependency support that exists in `src/` and
did not reach the shipping compiler. `zig_interop_test` is in
`registration_baseline.txt` as known debt and in `compile_check`'s SKIP list, so
nothing currently goes red on it.

### BUG-254: the BOOTSTRAP is over-strict on mixed numeric arithmetic — `1 + 2.0` is rejected — OPEN

**Found 2026-08-04** while porting BUG-253's arithmetic diagnostics, and notable because it
runs the OTHER WAY: here the **selfhost is right and the bootstrap is wrong**.

```zebra
var a: int = 1
var b: float = 2.0
var c = a + b        # bootstrap: error: arithmetic operands must have the same type: 'int' vs 'float'
var d = 1 + 2.0      # bootstrap: same error
```
The selfhost accepts both. `src/TypeChecker.zig` requires `Type.eql(lt, rt)` — exact
equality — for `+ - * / // % **`.

**Sean's decision, 2026-08-04:** *"I'd prefer to keep `1 + 2.0` … I think not supporting it
would cause a lot of headaches for something in the python-like space of languages."* So the
permissive behaviour is the intended semantic and the strict rule is the defect.

**It also contradicts the language's own stated principle.** QUICKSTART's untyped-numeric
rule is why `[1, 2.0, 3]` is a legal list literal — `int` and `float` are mutually
assignable. Arithmetic demanding exact equality is inconsistent with that.

**Consequence for BUG-253's triage, and this is the useful part:** "present in the bootstrap,
missing from the selfhost" is **NOT automatically a defect**. This is the first confirmed
case where the missing diagnostic *should* stay missing. `tools/diagnostic_parity.py`
reports candidates rather than gating precisely because this judgement cannot be automated —
and this ticket is the evidence that the caution was warranted rather than decorative.

**Fix:** relax `src/TypeChecker.zig` to mutual assignability (the rule `isAssignable`
already implements, and which the list-literal check uses) instead of `Type.eql`. Low
urgency — the bootstrap is the regen authority, not the shipping compiler, so this affects
`--zig-backend` users and the GUI paths rather than ordinary builds.

### BUG-253: the selfhost TypeChecker has roughly HALF the bootstrap's diagnostics — OPEN (umbrella)

**Found 2026-08-04**, by asking the question BUG-252 raised: *"which other bootstrap
diagnostics never reached the selfhost?"* Three had already been found by accident
(BUG-106, BUG-108/248, BUG-099/252). Three accidents is a class, not a coincidence.

Enumerated by `tools/diagnostic_parity.py`:

    bootstrap src/TypeChecker.zig   37 diagnostics
    selfhost  TypeChecker.zbr       19 diagnostics
    no counterpart found            26 candidates

**VERIFIED BY EXPERIMENT, not by the matcher.** Three candidates were tested directly
against both compilers; the tool is fuzzy by construction and its number means nothing on
its own:

| probe | bootstrap | selfhost `-c` | verdict |
|---|---|---|---|
| `var b = a - 1` where `a: str` | rejects | **accepts** | **gap confirmed** |
| `def f(): int` with a bare `return` | rejects | **accepts** | **gap confirmed** |
| `var b = a & 2` where `a: float` | accepts | rejects | **false positive** — the selfhost LEADS here |

So the hit rate on a 3-sample is 2/3, and the one miss errs in the harmless direction. The
26 are **candidates for triage**, not 26 defects.

**Impact is diagnostic quality, not silent wrongness.** Both confirmed gaps still FAIL to
compile — Zig catches them:

    p3.zbr:2: error: expected type 'i64', found 'void'

That is a message in **Zig's vocabulary, about emitted code the user never wrote**, for a
mistake (`return` with no value from a function declared `: int`) the front end could name
exactly. This is the same programme as `tools/frontend_gap.py`, which measured `-c` missing
**43%** of what `zig` rejects — and this ticket explains a large part of *why*.

**The missing set is substantive**, not cosmetic. Among the candidates: arithmetic operand
type mismatches, bitwise-on-non-integer, `if x as n` requiring an optional, destructuring
arity, `return` without a value, SIMD operand types, `raise` details lacking `toString`.

**Not made a gate, deliberately.** "Absent" is a candidate: a diagnostic may be legitimately
unported because it guards a bootstrap-only feature, or reworded past the matcher. Gating it
would demand a suppression list nobody maintains. It reports; a person decides.

### Triage, 2026-08-04 — 9 probes run against BOTH compilers

The matcher lists messages, not programs, so each candidate needed a minimal repro and a
run against both compilers. `scratchpad/triage_253.py`.

| candidate | verdict | action |
|---|---|---|
| bare `return` from `def f(): int` | real gap | ✅ **PORTED** |
| `"x" - 1` (non-numeric arithmetic operand) | real gap | ✅ **PORTED** |
| compound assignment on a non-numeric | real gap | ✅ **PORTED** |
| `if x as n` on a non-optional | real gap | ✅ **PORTED** |
| destructuring arity mismatch | real gap | ✅ **PORTED** |
| destructuring a non-tuple | real gap | ✅ **PORTED** |
| tuple index out of bounds | real gap | ✅ **PORTED** |
| `unary '-' requires numeric type` | real gap | ✅ **PORTED** (the `Expr.unary` arm was added) |
| `arithmetic operands must have the same type` | *selfhost is RIGHT* | ❌ **DO NOT PORT** — BUG-254 |

**Two candidates were BAD PROBES, not evidence.** `bitwise operator requires integer type`
and `bitwise 'not' …` both came back "rejected by both" — but the error was
`unexpected expression token: '&'`, a **parse** error. `&` and `~` are not Zebra syntax, so
the probes never reached the TypeChecker. Recorded because the same trap bit a guard later
in the session: a "guard" written with `/=` proved nothing, because Zebra has no `/=`
either. **A probe using syntax the language lacks tests nothing and looks like a result.**

**`unary '-'` is blocked for a structural reason, not effort.** `inferExpr` has NO
`Expr.unary` arm at all — unary expressions fall through to unknown. Porting the check means
ADDING inference for that node, which is a behaviour change well beyond restoring a
diagnostic. Identical situation to `array_lit` under BUG-106. Both are one call away once
the arm exists.

**Hit rate so far: 7 real gaps of 9 probed**, one of which must not be ported. That ratio is
why the tool reports candidates and does not gate.

**Suggested order:** the ones a beginner hits first — arithmetic/type-mismatch operands, and
`return` without a value. Each is a small port from a known-good reference implementation,
and each converts a leaked Zig error into a Zebra one.

### Status 2026-08-04 — all 8 portable candidates of the 9 probed are done

The two structural blockers named above (`Expr.unary` and `array_lit` having no `inferExpr`
arm) were resolved by adding the arms, so nothing from the triage remains open. Selfhost
TypeChecker diagnostics: **19 → 25**. The one candidate that must NOT be ported is
BUG-254, where the selfhost is right and the bootstrap is wrong.

**Two things the last four ports pinned down that are worth carrying forward:**

*The tuple index check was not only missing, the access itself was arity-capped.* The
selfhost tested `m.member` against the four string literals `"0".."3"` rather than parsing
it, so `t.4` on a 5-tuple never reached the tuple branch at all — it fell through to the
generic member paths and inferred as something unrelated. The emitted Zig still compiled,
which is why no gate saw it: this is the BUG-226 class, where valid Zig produces the wrong
answer. `test/bug253_tuple_index_high_test.zbr` is therefore a **run-and-compare** fixture,
not a compile check — only the printed value distinguishes the two.

*Every one of these ports is DELIBERATELY NARROWER than the bootstrap it came from.* The
bootstrap guards these diagnostics with `!isAbstract()`; the selfhost versions go through
`isConcretePrimitive`, which fires on `int`/`float`/`str`/`bool` and nothing else. The
reason is BUG-218: `isAbstractType` knows about `unknown_`/`unresolved`/`context_dependent`
but *not* about the places selfhost inference is simply weaker than the bootstrap's (§28a).
An expression that really is optional, or really is a tuple, but that the selfhost typed as
`named` would draw a false compile error on correct code. The cost of being narrow is a
missed diagnostic; the cost of being wide is rejecting a working program. Widen when
inference closes the gap — not before.

**False-positive evidence:** all 482 tracked `test/` + `examples/` files and every
`selfhost/*.zbr` were compiled with the new checks; 4 flags, all of them the deliberately
planted controls. A sweep that reports zero without a control that must fire is not
evidence, and an earlier run of exactly this sweep silently checked **0 files** because
`corpus_ls.sh` was called without its DIR argument — the controls are what caught it.

**Known shortfall, not chased:** the two destructuring diagnostics report column 0, because
`AstBuilder` constructs `StmtDestruct` with `Span(pd.line, 0, pd.line, 0)`. The line is
correct. Same span-plumbing class as BUG-249.

### Triage round 2, 2026-08-05 — the remaining candidates

With the first nine done, `diagnostic_parity.py` reports **37 bootstrap / 29 selfhost, 10
candidates** (down from 26). Two of the ten were already settled: `arithmetic operands must
have the same type` is BUG-254 (**do not port** — the selfhost is right) and `cannot
determine type for value assigned to` is BUG-252 (present, disabled, blocked on §28a).

The rest, each probed against BOTH compilers:

| candidate | bootstrap | selfhost | verdict |
|---|---|---|---|
| `'List(...)' requires explicit initialization` | rejects | accepted | ✅ **PORTED** |
| `struct destructuring requires a class or struct` | rejects | accepted | ✅ **PORTED** |
| `raise details must implement 'toString as str'` | rejects | accepted | real gap — **open** |
| `type alias constraint must be 'bool'` | rejects | accepted | real gap — **open**, see caveat |
| `type argument does not implement …` | not probed | — | open |
| `SIMD operands must have the same type` | **untestable this way** | — | see below |

**The uninitialized-collection check needed a locality distinction the selfhost did not
have.** The bootstrap guards it with an `is_local` flag, because a *class field* declared
`var items: List(int)` is correct Zebra — it gets its value in `cue init()`. The selfhost's
`checkVarDecl` serves both statement-scope `Stmt.var_` and declaration-scope `Decl.var_`, so
putting the check inside it would have rejected every class field in the language. It lives
at the `checkStmts` call site instead, which *is* the local one — the distinction is
structural rather than a flag someone has to keep true. `bug253_uninit_collection_field_test`
pins the exemption as a run-and-compare fixture so a later tightening cannot quietly break it.

**SIMD cannot be triaged by differential probe, and the reason is worth recording.** The
bootstrap rejects `f32x8` as *"not defined"* — including in `test/simd_test.zbr`, the
corpus's own SIMD test, which the selfhost compiles and runs. SIMD is a selfhost-LEADS
feature, so **the bootstrap is not a usable reference for it**, and a candidate that exists
only in the bootstrap says nothing about what the selfhost should do. Whether the selfhost
wants an operand-type check here is an *intent* question — `boundary_check`'s department,
not this one's. (Noticed in passing: `QUICKSTART.md` documents `f32x4`, which the bootstrap
also calls undefined. Unresolved; the selfhost's support is what matters and it is
untested at that width.)

**Caveat on the type-alias row.** The bootstrap rejects `type Even = int where value % 2`,
but with `expected type 'bool', found 'i64'` — *not* the candidate string. So a gap is
confirmed (the selfhost accepts a non-bool refinement predicate) while the specific
diagnostic that fired is a different one. Recorded honestly rather than counted as a match:
the probe proves the behaviour gap, not the provenance.

### BUG-252: BUG-099's check is present but disabled by default — OPEN (blocked on §28a)

> **Heading corrected 2026-08-05.** It read *"BUG-099's check is missing from the selfhost,
> same class as BUG-106/248"*. That was wrong on both counts — the check exists, and it is
> not that class. The original text is kept below because the reasoning that produced the
> wrong conclusion is the useful part; the correction is at the end of the entry.

**Found 2026-08-04** by auditing the `check_mode_check` witness set against a new criterion
(Sean): a witness must show a genuine LIMIT of front-end checking, not a check the selfhost
happens to lack. Two of the three failed that test.

    test/bug099_unresolved_test.zbr
      bootstrap  -> error: use of undeclared identifier 'Math'
      selfhost   -> `-c` exits 0

**Third instance of the pattern** (BUG-248 = BUG-108, BUG-106, now BUG-099): a check shipped
in the bootstrap in May 2026 and never ported to the compiler that ships. All three were
found the same way — by asking what the *reference implementation* does with a file the
selfhost accepts.

**It is currently load-bearing as a witness**, which is why it is filed rather than fixed on
the spot: retiring it drops the set to two. `witness_zig_backend_literal` was added first so
the set never falls below that. Port the check, then remove this file from `WITNESSES` in
`tools/check_mode_check.sh` and from the note in `selfhost/main.zbr`.

**Worth a sweep, not just a fix.** Three confirmed instances suggests the right question is
not "port this one" but *"which other bootstrap diagnostics never reached the selfhost?"* —
enumerable by diffing the two compilers' error strings.

### Correction 2026-08-05 — the check is NOT missing. It is present and switched off.

**The title above is wrong and the classification with it.** `selfhost/TypeChecker.zbr`
has this check. It lives in `checkVarDecl`, it is guarded by `ctx.strict`, and `strict` is
set by exactly one caller: `selfhost/main.zbr:651`, the **LSP diagnostics** seam. Normal
compilation constructs `InferCtx` with `.strict = false`, so `zebra -c` never runs it.

    if ctx.strict and inferred is Type_.unresolved
        ctx.addErr(…, "unresolved type for init expr of '" + dv.name + "' (TC gap)")

This is why `diagnostic_parity.py` counted it absent: the tool matches error *strings*, and
the selfhost's wording (`unresolved type for init expr of 'x' (TC gap)`) shares no phrase
with the bootstrap's (`cannot determine type for value assigned to 'x: int'`). A fuzzy
string matcher cannot distinguish "never ported" from "ported, reworded, and disabled" —
worth remembering before reading its remaining candidates as a defect count.

**So this is not a port. It is a decision about a default, and the measurement says no.**

Flipping `.strict = true`, regenerating, and compiling all 487 tracked `test/` +
`examples/` + `selfhost/*.zbr` files:

| | files newly rejected |
|---|---|
| `test/` | 9 |
| `examples/` | 6 |
| **`selfhost/`** | **13** |
| **total** | **28** |

The selfhost 13 include `CodeGen.zbr`, `Resolver.zbr`, `TypeChecker.zbr`, `AstBuilder.zbr`
and `main.zbr` — **the compiler could not compile itself.** The examples include
`lisp.zbr`, `pratt_calc.zbr` and `kv_store.zbr`, which are working programs.

Not one of those 28 is a bug in the program. Each is a place where selfhost inference
returns `unresolved` for something it ought to have derived — §28a, the same gap that makes
every diagnostic ported this week deliberately narrower than its bootstrap original. The
flag is off for a reason, and the comment above it (*"alarm bell for TC gaps"*) is accurate:
it is an instrument for finding inference gaps, not a user-facing check.

**Reframed, therefore:** BUG-252 is not "port BUG-099's check". It is **"close enough of
§28a that the alarm bell can be armed by default"**, and the 28-file list is a ready-made
worklist for that, ordered by how much it would embarrass us (`selfhost/` first — a
compiler that cannot compile itself under its own strictest setting is the honest measure
of the gap). Until then the LSP-only default is correct, not an oversight.

**Consequence for the witness set:** `test/bug099_unresolved_test.zbr` stays a valid
`check_mode_check` witness, and for a *better* reason than it was filed under. It does not
demonstrate a check the selfhost happens to lack; it demonstrates a genuine limit — the
front end declines to assert a type it could not derive. That is the criterion Sean asked
for. Nothing needs retiring.

*Measured with a positive control: with strict on, the bug099 fixture MUST be rejected, and
was; with the flip reverted it MUST be accepted again, and was. The tree was restored to
byte-identical `.zbr` and generated `.zig` before this note was written.*

### BUG-251: a request/response `Tcp` server DEADLOCKS — `conn.read()` appears to block until EOF — OPEN

**Found 2026-08-04** while giving `Tcp` its first real run fixture. The fixture had to be
**withdrawn rather than registered**, because a hanging fixture in the QUICK tier is worse
than an uncovered namespace: it teaches people to re-run gates until they pass.

**Repro** (server reads first, then replies — the ordinary request/response shape):

```zebra
def echoHandler(conn: TcpConn)
    var data = conn.read()          # <- blocks
    conn.write("ECHO:" + data)
    conn.close()

def main()
    sys.go(def()
        Tcp.serve(19921, echoHandler)
    )
    var c = Tcp.connect("127.0.0.1", 19921)
    if c as conn
        conn.write("ping")
        var reply = conn.read()     # <- and so does this
        conn.close()
```
Hangs. Killed at 200 s.

**Isolated — both halves work SEPARATELY**, which is what makes the diagnosis specific:

| probe | result |
|---|---|
| client connects, no read | ✅ `connected=true`, exits 0 |
| server WRITES first, client reads | ✅ `got=SERVER-HELLO`, exits 0 |
| **server READS first, then replies** | ❌ **hangs** |

**Reading:** `TcpConn.read()` appears to read **to EOF** rather than returning the first
available chunk. A server that reads before replying therefore waits for the client to
close, while the client waits for the reply — a deadlock, not a slow path. If that is the
intended semantic then `Tcp` cannot express request/response at all without a framing or
half-close mechanism, and **that is a design gap rather than an implementation bug**.

**Why this went unnoticed:** `test/tcp_serve_test.zbr` is the only Tcp fixture and its
`main` merely prints a string — the `Tcp.serve` call sits in a `startServer()` that nothing
calls (quality audit §1). `stdlib_run_coverage` counts Tcp as covered on that basis. It has
never opened a socket.

**Needed:** a decision on `read()`'s contract (chunk vs to-EOF), then either a documented
framing idiom or a `readSome`/`readLine`. Until then Tcp has no honest run coverage.

---

### BUG-250: `HttpResponse(status, body)` — the 2-arg constructor fails a full compile — OPEN

**Found 2026-08-04**, writing the Http run fixture.

```zebra
var a = HttpResponse(200, "x")     # error: type 'type' not a function
var b = HttpResponse.ok("x")       # fine
```

`-c` **accepts both**; only a full compile rejects the constructor form — so this is also an
instance of the front-end gap measured in `tools/frontend_gap.py` (23 of 54 failures are
invisible to `-c`).

**It is not hypothetical: `test/http_serve_test.zbr` uses the broken form**, in a
`handleRequest` that returns `HttpResponse(200, "Hello, World!")`.

QUICKSTART documents the factories (`HttpResponse.ok(body)` / `.notFound(body)`) and those
work; the 2-arg constructor is documented nowhere but is what the corpus reached for, which
suggests it is expected to exist. **Decide: implement it, or remove it from the corpus and
say the factories are the API.**

The new `test/http_echo_test.zbr` uses the factory form and passes 5/5.


### BUG-249: `Expr.this_` (and friends) carry a PLACEHOLDER span, so diagnostics report 0:0 — OPEN

**Found 2026-08-04** while porting BUG-108's check (BUG-248). The selfhost reports

    test/bug108_this_outside_class_test.zbr:0:0: error: 'this' used outside a class/…

where the bootstrap reports `6:13`. The message is right; the location is a placeholder.

**Cause.** `AstBuilder.zbr` builds these nodes with `zspan()`, which is literally
`Span(0, 0, 0, 0)`. It has no choice: `PNode.expr_this` is a **payload-less** parser
variant, so the token position never reaches the AST. Same for `expr_nil` / `expr_result`
and any other payload-less PNode.

**Fix is structural, not local:** give the PNode variant a position payload and thread it
through, which touches every construction and match site for that variant. Related to
**BUG-121** (TC diagnostics report col 0) but distinct — this is line AND col, and the
cause is upstream in the parser rather than in span resolution.

**Not urgent, but it caps diagnostic quality.** Every future front-end check anchored on one
of these nodes inherits the 0:0. That matters more now than it did, because the whole
front-end-gap programme (`tools/frontend_gap.py`) is about MOVING checks inward — and a
check that cannot say where is a check delivered half-finished.

---

### BUG-250: `HttpResponse(status, body)` — the 2-arg constructor fails a full compile — OPEN

**Found 2026-08-04**, writing the Http run fixture.

```zebra
var a = HttpResponse(200, "x")     # error: type 'type' not a function
var b = HttpResponse.ok("x")       # fine
```

`-c` **accepts both**; only a full compile rejects the constructor form — so this is also an
instance of the front-end gap measured in `tools/frontend_gap.py` (23 of 54 failures are
invisible to `-c`).

**It is not hypothetical: `test/http_serve_test.zbr` uses the broken form**, in a
`handleRequest` that returns `HttpResponse(200, "Hello, World!")`.

QUICKSTART documents the factories (`HttpResponse.ok(body)` / `.notFound(body)`) and those
work; the 2-arg constructor is documented nowhere but is what the corpus reached for, which
suggests it is expected to exist. **Decide: implement it, or remove it from the corpus and
say the factories are the API.**

The new `test/http_echo_test.zbr` uses the factory form and passes 5/5.


### BUG-249: `Expr.this_` (and friends) carry a PLACEHOLDER span, so diagnostics report 0:0 — OPEN

**Found 2026-08-04** while porting BUG-108's check (BUG-248). The selfhost reports

    test/bug108_this_outside_class_test.zbr:0:0: error: 'this' used outside a class/…

where the bootstrap reports `6:13`. The message is right; the location is a placeholder.

**Cause.** `AstBuilder.zbr` builds these nodes with `zspan()`, which is literally
`Span(0, 0, 0, 0)`. It has no choice: `PNode.expr_this` is a **payload-less** parser
variant, so the token position never reaches the AST. Same for `expr_nil` / `expr_result`
and any other payload-less PNode.

**Fix is structural, not local:** give the PNode variant a position payload and thread it
through, which touches every construction and match site for that variant. Related to
**BUG-121** (TC diagnostics report col 0) but distinct — this is line AND col, and the
cause is upstream in the parser rather than in span resolution.

**Not urgent, but it caps diagnostic quality.** Every future front-end check anchored on one
of these nodes inherits the 0:0. That matters more now than it did, because the whole
front-end-gap programme (`tools/frontend_gap.py`) is about MOVING checks inward — and a
check that cannot say where is a check delivered half-finished.

---

### BUG-106 (front-end check) — CONFLICT: the fixture serves two incompatible roles — NEEDS A DECISION

**Not a new defect. A collision, surfaced 2026-08-04**, and recorded because acting on it
without a decision would silently break a gate.

The selfhost does **not** implement BUG-106's heterogeneous-literal check. Verified:

| compiler | `var xs = [1, "two", 3]` |
|---|---|
| bootstrap | ✅ `error: list literal has heterogeneous element types: 'String' is not compatible with 'int'` |
| **selfhost** (`zebra.exe`, what ships) | ❌ `-c` exits **0**; fails later inside emitted Zig |

By the selfhost-equivalence rule that gap should simply be closed — as BUG-248 was, the
same night, for BUG-108. **It cannot be, without a decision**, because
`test/bug106_heterogeneous_list_test.zbr` is simultaneously:

1. **the regression fixture for BUG-106** — it must be REJECTED by the front end; and
2. **one of three asymmetry witnesses** named in `selfhost/main.zbr` and required by
   `tools/check_mode_check.sh` — it must PASS `-c` and fail `--check-full`, proving the
   documented `-c` limitation is real.

Those are contradictory. Porting the check satisfies (1) and destroys (2) for this file.

**It is survivable but not free:** `check_mode_check` fails only when *no* witness
survives, and there are three, so fixing this leaves two. What it costs is a **witness**,
and the comment in `selfhost/main.zbr` naming all three would go stale with it.

**The options:**
- **a.** Port the check; retire this file as a witness; pick a replacement witness first so
  the set never drops below two; update the `main.zbr` comment.
- **b.** Port the check and split the file: a new negative fixture for the check, and leave
  a *different* construct here as the witness.
- **c.** Leave the gap, and record explicitly that the selfhost does not implement it — the
  worst option, because the two compilers then disagree on what is a valid program.

**Recommend (b)** — a witness should not be load-bearing for a bug fixture, and the
coupling is what made this invisible. Sean's call.


### BUG-246: `Atomic(T).add()` inside a `capture` block mis-resolves to `.append()` — OPEN

**Found 2026-08-03**, writing the §1b `Ws` fixture.

```zebra
var t = Atomic(int)(0)
sys.go(def()
    capture
        var t: Atomic(int) = t
    var _ = t.add(1)
)
```
```
error: no field or member function named 'append' in 'zebra_rt._Atomic(i64)'
```

This is the **BUG-120 family** — the `.add()` → `.append()` List rewrite firing on a
receiver that is not a List. BUG-120 fixed the case of a lowercase class instance by
consulting `InferCtx` at the call site; a variable re-declared inside a `capture` block
evidently does not get the same treatment, so the heuristic wins again.

**Narrow, and the boundary is known:** `store` and `load` on a captured `Atomic` work
(verified). Only `add` is affected, because only `add` collides with the List method name.

**Impact is larger than it looks** — this is the documented idiom for a shared counter
across threads, and it cannot be written. `Chan(T)` is the workaround (sum on the
receiving side), which is what `test/chan_thread_test.zbr` does.

**QUICKSTART's shared-counter example was removed rather than repaired** when the
surrounding `lambda` errors were fixed (BUG-245's note); restore it when this is fixed.


---

### BUG-244: `zebra <file>` leaks a ~20 MB executable into TMPDIR on every run — OPEN

**Found 2026-08-03**, while Sean was freeing disk space; the machine had reached 40 GB free
on a 953 GB volume.

**Measured, not estimated.** One invocation of `zebra test/bug241_progress_io_test.zbr`
(no `--output-dir`) leaves behind:

    C:\Presolved\tmp\bug241_progress_io_test.zig            1 KB
    C:\Presolved\tmp\bug241_progress_io_test.zig.fast.exe   20,119,552 bytes

Neither is ever removed. **6,413 executables totalling 120 GB** had accumulated.

**The binary is not a cache.** Its mtime changes on every run, so it is re-linked each
time and nothing is reused — deleting it costs nothing. (Checked before proposing a fix,
because "clean up the temp files" is a bad idea if they are a warm cache.)

**Scale.** `selfhost_smoke.sh` runs 285 fixtures through this path, so a single smoke run
leaks ~5.7 GB, and smoke is in **both** the QUICK and FULL tiers.

**The heavy sweeps are NOT the culprit and need no change.** `full_sweep.sh` and
`compile_check.sh` emit into a scoped `$OUT/w-$name` subdirectory and `rm -rf` it on every
path including their failure paths. This is specifically the compiler's own run path
(`zbrToZig`'s temp-dir branch, the one `runtime_module_check.sh` describes as "temp dir,
not --output-dir").

**Why it went unnoticed for so long:** a temp directory is where nobody looks, nothing
warns, and no gate asserts. It is the same shape as BUG-241/243 in a different medium — an
unmeasured quantity that only becomes visible when it hits a hard limit.

**Fix (proposed).** Remove the emitted `.zig`/`.exe` after the child process exits on the
run path. Two things to decide first, which is why this is filed rather than patched:
1. **Keep artifacts on failure.** If the program crashes or the Zig build fails, the
   emitted source is the debugging evidence — delete only on a clean exit.
2. **An opt-out.** A `--keep-temp` flag (or honouring an existing debug flag) so anyone
   inspecting emitted output does not have to fight the cleanup.

**Interim mitigation, already landed:** `bash tools/tidy.sh` now reports the leak and
`--clean` clears it. Note the trap that cost a first attempt: `zebra.exe` is a **Windows**
binary reading `TMP`/`TEMP`, while Git Bash sets `TMPDIR` to the MSYS mount `/tmp`. A tool
that reads `$TMPDIR` looks at the wrong directory and cheerfully reports ~20 MB while
120 GB sits elsewhere.


---

### BUG-243: fifteen corpus files have never compiled, and no gate could say so

**Found 2026-08-02**, working §2 of `docs/INSTRUMENT_PASS_PLAN.md`. An umbrella ticket:
these are not one defect, they are fifteen — but they were found by one method, they share
one cause of invisibility, and the inventory is more useful in one place than scattered.

**How they hid.** `full_sweep` gates against a **baseline** (337 of 421 files). A file
that has *never* passed is not in the baseline, so it cannot make the gate red however
broken it is. And none of these carries a `smoke*` registration, so nothing asserts they
should fail either. **A permanently-broken file is indistinguishable from an intentionally
negative one**, and both look like a green board.

Every one was verified by running `zebra <file>` directly — not inferred from the sweep.

| file | error | class |
|---|---|---|
| `expose_dotted_test` | emitted Zig: `expected ';' after declaration` | **codegen emits invalid Zig** |
| `typechecker_test` | emitted Zig: `unused function parameter` | **codegen** |
| `tc_check_test` | emitted Zig: `expected type '*tc_infer.TcExpr'` | **codegen** |
| `tc_infer_test` | emitted Zig: `struct 'tc_types.TcTypes' has no member` | **codegen** |
| `zebra_ide` | emitted Zig: `use of undeclared identifier 'Lis…'` | **codegen** |
| `progress_test` | `zebra_rt.zig:3617: expected 2 argument(s), found 1` | **BUG-241** (filed) |
| `gui_test` | `local variable is never mutated` | the BUG-230 const/var family |
| `csv_test` | `use of undeclared identifier 'CsvWriter'` | **BUG-242** (filed) |
| `bug106_heterogeneous_list_test` | `expected type 'i64'` | **regression fixture that does not run** |
| `bug108_this_outside_class_test` | `use of undeclared identifier` | **regression fixture that does not run** |
| `crossmod_expose_test` | `type 'array_list.Aligned(…)'` | cross-module expose |
| `generic_pair_test` | `expected type 'T', found '*T'` | generics |
| `json_parse_typed_test` | `no field or member function named …` | stdlib/typing |
| `raise_details_test` | `error union is ignored` | error model |
| `tc_types_test` | `struct 'tc_types.TcTypes' has no member` | (tc_* family) |

**The two rows that matter most are the regression fixtures.** `bug106_*` and `bug108_*`
exist to prove BUG-106 and BUG-108 stay fixed. Neither has ever run. **Those two fixes are
unverified**, and have been for as long as the fixtures have existed.

**Second-most: five files fail inside EMITTED Zig**, not at the Zebra source. Those are
codegen defects — the compiler producing invalid or ill-typed Zig — which is the class
`compile_check` exists to catch, and it does not sweep these because they are not in its
smoke-derived worklist.

**The `tc_*` / `typechecker_test` / `zebra_ide` group** looks like an earlier
self-hosting/IDE experiment. They may be legitimately stale rather than defects — decide
per file, and if stale, **delete or quarantine explicitly** rather than leaving them to
look like coverage.

**Disposition:** triage each into runs-but-sweep-shape (register), broken (fix), or stale
(delete/quarantine). Then close the class — see `tools/registration_check.py`, which makes
an unregistered, unexplained `test/*.zbr` a gate failure instead of a silence.


### BUG-240: `var s: Set(T) = {}` — annotated EMPTY set literal does not compile — OPEN

**Symptom.** An empty set literal with a type annotation fails; the same
annotation with a non-empty literal is fine, and the `HashMap` equivalent is fine.

```
def main()
    var s: Set(str) = {}          # <- FAILS
    print(s.len.toString())
```
```
error: expected type 'hash_map.HashMap(str,void,hash_map.StringContext,80)',
         found 'hash_map.HashMap(str,str,hash_map.AutoContext(str),80)'
```

Controls, both of which **pass** — this is narrow, not a general set failure:

| Form | Result |
|---|---|
| `var s: Set(str) = {"a"}` | ✅ works |
| `var d: HashMap(str, int) = {}` | ✅ works |
| `var s: Set(str) = {}` | ❌ the error above |

**Cause.** A bare `{}` is ambiguous (empty set vs empty dict) and the parser
resolves it to **`dict_lit`** unconditionally — only the annotation can say
which was meant. `genLocalVar` already knows this and special-cases it, but
**only for `HashMap`**:

```
selfhost/CodeGen.zbr:5830
    if gtll.name == "HashMap"
        # §28f: `var m: HashMap(K,V) = {}` — only the annotation can type an
        # EMPTY dict literal, so handle it here ...
        if ie is Expr.dict_lit as dl_init
            if dl_init.entries.len == 0
```

There is no sibling branch for `Set`, so an annotated empty set falls through
to the generic `dict_lit` lowering and emits
`std.AutoHashMap([]const u8, []const u8)` against a declared
`std.StringHashMap(void)`. Generated line:

```zig
const s: std.StringHashMap(void) = (blk_dl_1: { const _dl_1 = std.AutoHashMap([]const u8, []const u8).init(...); ... });
```

**Suggested fix.** Add the `Set` sibling next to the `HashMap` branch at
`CodeGen.zbr:5830`, emitting the annotated type's `.init(_allocator)` directly —
the same shape, and like that branch it needs no `const`/`var` mutation guard
because no `.put` is emitted.

**Relationship to BUG-239.** Found while verifying a claim made in the BUG-239
commit message (that no source syntax reaches a zero-element `set_lit`). That
claim **holds** — this path proves it, since even the annotated set form lowers
through `dict_lit`, never `set_lit`. BUG-239's `const` guard already applies
here, so the *never-mutated* half is fixed; what remains is purely the type
selection. The comment left in the `set_lit` branch stays accurate.

**Not fixed here deliberately:** found during a session working elsewhere in the
tree while a concurrent mutation-testing run was in progress; logged rather than
patched to avoid colliding with it.

---

### BUG-237: a union used WITHOUT being `exposing`-imported silently mis-emits `^T` payloads ⚠ OPEN

**ROOT CAUSE FOUND 2026-07-31** — it is not about union payloads in general. It is that
**referencing a union that is not in the module's `use X exposing ...` list silently
skips its boxed-variant registration.**

```zebra
use Ast exposing Expr              # StringPart NOT exposed
if part is StringPart.expr_ as e   # still RESOLVES and compiles the front end
    someFn(e)                      # emits `someFn(e)` -- a raw *Expr. Zig rejects it.

use Ast exposing StringPart, Expr  # exposed
if part is StringPart.expr_ as e   # emits `const e_ptr = ...; const e = e_ptr.*;`
    someFn(e)                      # correct
```

`selfhost/CodeGen.zbr:6917` gates the deref on
`boxed_variants.contains_(union + "." + variant)`, and `boxed_variants` is populated
from same-module unions plus `populateBoxedVariants(..., deps_mt)` on each `use` — which
evidently follows the **exposed** names. So an unexposed union is still *referenceable*
(the front end resolves `StringPart.expr_` fine) but codegen has no record that its
payload is boxed.

**That combination — resolves, compiles the front end, emits wrong Zig — is the defect.**
Either the reference should be rejected ("StringPart is not exposed in this module"), or
the registration should follow reachability rather than the exposing list. The current
behaviour fails in the worst available way: a Zig type error naming `Ast.Expr` vs
`*Ast.Expr`, in generated code, for a mistake that is really a missing import clause.

**Cost of the ambiguity, measured:** six spellings tried before the import list was
suspected — bare binding, renamed binding, annotated local, pointer-typed parameter,
direct payload access, and a call in condition position. Every one emitted the pointer,
because none of them was the actual variable. `CgHelpers.zbr` "mysteriously" worked for
exactly one reason: it exposes `StringPart` and `TypeChecker` did not.

**Severity:** medium (silent mis-emit; the diagnostic points at generated types, and the
real fix is a missing name in an import list).
**Found:** 2026-07-31 while fixing BUG-232, which it blocked until the cause was found.

```zebra
union StringPart
    literal: String
    expr_: ^Expr

# inside a walker taking `Expr`:
if part is StringPart.expr_ as e
    someFn(e)          # emits `someFn(e)` where e is *Expr
                       # -> error: expected type 'Ast.Expr', found '*Ast.Expr'
```

A `^T` **struct field** derefs correctly — `cm.object` two lines away emits
`cm.object.*`, and `sx.start` (a `^Expr?`) emits `sx.start.?.*`. The gap is specific to
a `^T` reached through a **union payload binding**.

**Six spellings were tried, all emitting the bare pointer:**

1. bare binding as an argument — `someFn(e)`
2. renamed binding (matching a working precedent's names exactly) — `someFn(se)`
3. annotated local — `var pex: Expr = pe` emitted `const pex: Expr = pe;`, no deref
4. pointer-typed parameter — a `def f(be: ^Expr)` wrapper, which passed it on unchanged
5. direct payload access without a binding — `someFn(part.expr_)`
6. call in CONDITION position — `if boolReturningWrapper(e)`

**What makes it genuinely odd:** `selfhost/CgHelpers.zbr:268-269` does *the same thing*
and emits the deref (`const e_ptr = part.expr_; const e = e_ptr.*;`) — verified against a
FRESH emit from today's bootstrap, so it is not a stale artefact. The two source sites
are structurally identical down to the loop shape. Reduced probes of the same shape (bare
argument, void statement call, interpolated call, over a `union Part { expr_: ^Node }`)
all compile fine, so the trigger is not the construct alone and was not isolated.

Whatever the discriminator is, it is worth finding: it means the same source line emits
different code in two places, which is the kind of thing that makes a codegen bug look
like a user error.

**BUG-232 is no longer blocked** — adding `StringPart` to the exposing list fixed it, and
`bv_arity_interp_unchecked.zbr` now asserts the warning instead of pinning the silence.
This entry remains open on its own merits: the next person to reference an unexposed
union will lose the same hours, and a compiler that silently emits wrong code for a
missing import clause is a poor trade for the convenience of not writing the name.

---

### BUG-233: a lambda parameter that shadows an enclosing one emits invalid Zig ⚠ OPEN

**Severity:** medium (valid Zebra rejected; the error is a raw Zig one).
**Found:** 2026-07-30 by the **A5 examples sweep on its very first run** — the gate
that had never existed. `examples/panel_smoke.zbr` has been shipping broken.

```zebra
def view(g: Gui, model: Model)
    g.panel("Controls", def(g: Gui)      # lambda param deliberately named `g`
        if g.button("+1")
            ...
```

Emits a nested container whose `call` reuses the enclosing parameter name:

```zig
pub fn _zbr_fn_view(g: Gui, model: Model) void {
    g.panel("Controls", struct { pub fn call(g: Gui) void {   // <-- Zig: shadowing
```

```
panel_smoke.zig:45:46: error: function parameter 'g' shadows function parameter from outer scope
```

Shadowing an outer name in a nested lambda is ordinary in Zebra (and in Python,
which Zebra draws from). **Zig forbids it**, so codegen has to rename — it does not.
Re-using the receiver's name inside a UI callback is about as natural as Zebra
lambda code gets, which is why an example does it.

**Same family as BUG-220** (user names colliding with emitted names), and the fix is
probably the same shape: give the lambda parameter a reserved prefix, or rename only
on detected collision. BUG-220 chose `_zbr_fn_` for top-level defs for exactly this
class of reason.

**Why nothing caught it:** it is not in `test/*.zbr`, and every heavy gate globs
that. `examples/` had no gate until A5 (`tools/full_sweep.sh --examples`), which is
now in the FULL tier. Not baselined — it is one of the two named non-passing entries
the sweep prints on every run.

---

### BUG-231: named arguments do not parse inside `${...}` interpolation ⚠ OPEN

**Severity:** medium (documented feature unavailable in a documented context).
**Found:** 2026-07-30 by the A3 boundary suite. **Both compilers reject it.**

```zebra
def defaulted(a: int, b: int = 2, c: int = 3): int
    return a * 100 + b * 10 + c

var outside = defaulted(1, c: 7)     # fine — 127
print("${defaulted(1, c: 7)}")       # selfhost : unexpected expression token: ': 7)'
                                     # bootstrap: syntax error near ': 7)'
```

Named arguments are QUICKSTART section 4; interpolation is section 3. The
expression sub-parser used inside `${...}` does not accept the `name:` form. The
workaround is to bind the call to a local first.

Same family as BUG-232 — both are the interpolation sub-parser being a weaker path
than the ordinary expression parser. Worth fixing together.

**Expect TWO probes to go red from ONE fix.** `bv_named_arg_interp.zbr` and
`bv_arity_interp_unchecked.zbr` both pin interpolation-path behaviour, so whoever
fixes this family will very likely break both at once (and may also free the
hoisted `named` row in `bv_arity_ok.zbr` to be written inline again). That is the
`@boundary-pending` tripwire working as designed, not a regression — rewrite both
probes to assert the intent rather than re-baselining them.

Pinned by `test/boundary/bv_named_arg_interp.zbr`, which carries the statement-form
call as a control so the failure is attributable to the interpolation and nothing
else.

---

### BUG-230: an ANNOTATED, NON-EMPTY list literal does not compile ⚠ OPEN

**Severity:** high (a three-line, entirely reasonable program fails to build).
**Found:** 2026-07-30 by the A3 boundary suite, from the one-element List boundary.
**Both compilers fail identically.**

```zebra
var nums = [1, 2, 3]              # inferred            -> compiles
var nums: List(int) = []          # annotated, empty    -> compiles
var nums: List(int) = [1, 2, 3]   # annotated, NON-EMPTY -> error: expected type '*T',
                                  #                        found '*const T'
```

**Root cause** (from the emitted Zig): a list literal lowers to
`std.ArrayList(T).empty` followed by one generated `append` per element. The
const-vs-var mutation analysis does not count those *generated* appends as
mutations, so a binding the user never mutates afterwards is emitted as Zig
`const` — and its own initialisation then fails, because `append` requires
`*ArrayList`. Adding any user mutation (`nums.add(4)`) makes it compile, which is
why the error appears to be about whichever read-only method follows (`.count()`,
`.sort()`, `.map()`, `.all()`, `.find()`) and is not.

**IT IS SHIPPING BROKEN CODE TODAY.** `examples/widget_smoke.zbr:30` uses exactly
this form (`var items: List(str) = ["Apple", "Banana", "Cherry"]`) and **does not
compile** — its emitted Zig fails at `items.append`. Verified by emitting and running
`zig build-exe` on the result.

**Why no existing gate sees it, which is the transferable part.** Two independent
reasons, and correcting an earlier over-claim of mine: both compilers do the identical
wrong thing, so `divergence_check` cannot see it *by construction*; and the corpus the
heavy gates sweep is `test/*.zbr`, which does not use the form. The one file that does
is in **`examples/`, and NO gate sweeps `examples/` at all** — so a broken example has
been shipping unnoticed. That is a coverage hole worth more than this bug: `examples/`
is the first thing a new user reads, and 0.9 is the ready-for-others release.

Note also that `zebra -c examples/widget_smoke.zbr` exits 0. That is correct and
documented — `-c` is front-end-only — but it means check mode cannot be used to
confirm this class. I briefly mis-read that exit 0 as "the example is fine."

This is the "self-consistency is not correctness" class, and it is the first bug found
by A3 rather than by accident.

**Likely fix:** treat a literal's generated element-appends as mutations when
deciding `const` vs `var` (or emit the literal through the same path the
un-annotated form already uses, which is correct today).

**Open question, NOT part of this bug's claim:** `nums.sort()` — a *mutating*
method — also fails to mark the binding mutated, while `nums.add(4)` does. That
suggests a second gap in the same analysis, but it was not investigated and
BUG-230 stands without it. Recorded so it is not lost, not asserted.

Pinned by `test/boundary/bv_list_literal_annotated.zbr`.

---

### BUG-225: `s[i]` is typed `char` but yields a byte — ⬜ OPEN (1.x retype; 0.9 SEMANTICS DECIDED 2026-08-03)

> **DECIDED 2026-08-03 (Sean):** `s[i]` **is a byte**, and the documentation now says so
> plainly rather than hedging. This puts Zebra with **Go** (indexes to a byte, never
> pretends otherwise) and **Rust** (forbids `str` indexing outright) — good company, and
> the honest position: a UTF-8 string has no O(1) i-th character, so any language offering
> one is lying or copying.
>
> **This is NO LONGER A 0.9 BLOCKER.** What remains is the *type* (`char` holding a byte),
> which is a 1.x retype — see the blast radius below. QUICKSTART now leads with the rule
> ("index for bytes, iterate for characters") instead of burying it in a known-gap note.
>
> **BUG-247** (fixed) removed the one place the incoherence actively misled a user: the
> lexer reported a non-ASCII byte as a character that was not in the source file.
Found 2026-07-29 by the §28e derivation. `s[i]` is typed `char` (u21) but holds a raw
UTF-8 **byte**, so for any multi-byte codepoint it produces a character that is not in
the string — and it does so silently, with no error at any stage.

```zebra
def main()
    var s: str = "eéx"
    print(s.len.toString())              # 4  — bytes, honest
    print(s.codePointCount().toString()) # 3  — codepoints, honest
    print(s[1].toString())               # Ã  — WRONG. byte 0xC3 widened to U+00C3
    for c in s.chars()
        print(c.toString())              # e é x — correct
```

Emitted: `const a_index: u21 = s[@as(usize, @intCast(0))];` — the byte is widened to
u21, so `.toString()` UTF-8-encodes 0xC3 as the codepoint U+00C3 (`Ã`). Only `chars()`
is honest, because only `chars()` decodes.

**This is the one string incoherence with a real blast radius, and it is a language
design call, not a bug fix.** The selfhost compiler's own lexer is built on it —
`Lexer.zbr:116` is `def peek(): char` returning `src[pos]`, ~60 subscript sites in
that file alone, ~104 across `selfhost/`, and the 559 `c'x'` literals compare against
the result. Retyping `s[i]` to `byte` therefore requires deciding how `byte` and `char`
compare, which is design work.

Options, in ascending cost: (a) **document the limit for 0.9** and retype in 1.x —
Go and Rust both chose codepoint-with-a-documented-byte-layer and neither pretends an
index yields a character; (b) retype `s[i]` to `byte` and define `byte`/`char`
comparison; (c) make `s[i]` on a `str` an error and force `byteAt(i)` or `chars()`,
which is clearest and most disruptive. **Recommended: (a) for 0.9**, since the fix
competes directly with the pre-0.9 churn freeze and the honest documentation is most of
the value. Cross-ref [[§28e]] and BUG-223, which is the same incoherence at zero cost.

---

### BUG-212: selfhost emits `var` (not `const`) for a builtin-pointer local used only as a method receiver ⬜ OPEN
`var e = CodeEditor()` followed by `e.setText(...)` / `e.getText()` (and no reassignment)
emits `var e = _code_editor_new();`, which Zig rejects: `error: local variable is never
mutated`. `e` is a `*_CodeEditor` (a pointer) — calling `_code_editor_*(e, …)` passes the
pointer by value and never reassigns `e`, so it should be `const`. The mutation analysis
appears to treat a method call on the local as mutating its receiver, which is correct for
by-value struct receivers but wrong for these builtin heap-handle value types (code_editor;
likely also other pointer builtins). **Impact:** low — the IDE and normal code assign such
handles straight into a field (`m.editor = CodeEditor.forZebra()`), never a bare local, so
this only bites `var x = CodeEditor()` used purely as a receiver. Workaround: assign into a
field/struct, or add another use. **Fix direction:** in the const/var mutation scan, don't
count a method call as mutating the receiver when the receiver's inferred type is a
pointer-builtin value type (code_editor, …). Verify against the bootstrap's behavior.

### BUG-203: explicit `@derive(Eq)` `.eql(value)` call doesn't address the value argument
Calling a derived `eql` explicitly with a value argument fails to compile:
`a.eql(b)` → `error: expected type '*const Color', found 'Color'`. The derived
`eql(other: *const Self)` takes its argument by const-pointer, and an explicit
`.eql(b)` passes `b` (a value) without taking its address. The **`==` operator
works** (`a == b`, which the Eq trait rewires to `a.eql(b)`, DOES address the
argument), as do `toString()`, `hash()`, and struct-keyed `HashMap` — so only the
explicit `.eql(value)` form is affected. Repro:
```
@derive(Eq) struct Color { var r: int; var g: int; var b: int }
def main()
    var a = Color(r:1, g:2, b:3)
    var b = Color(r:1, g:2, b:3)
    print(a == b)        # OK → true
    print(a.eql(b))      # FAIL: expected '*const Color', found 'Color'
```
**Fix direction:** the explicit-member-call path should address a value argument
passed to a `*const Self` parameter the same way the `==` rewrite already does
(mirror the arg-addressing in genMemberCall). **Workaround:** use `==`.
Low severity (idiomatic `==` works; `.eql()` is the lower-level form). Found
2026-07-25 during the QUICKSTART dogfood. Related: `docs/emit_compile_triage.md`
`derive_test` entry.

### BUG-202: user top-level function name collides with preamble-internal parameter names
A user `def` whose name matches a parameter used inside a preamble helper emits Zig
that fails to compile with `error: function parameter shadows declaration of '<name>'`.
Found writing `examples/game_of_life.zbr`: a top-level `def key(x, y, w)` collided with
the preamble's `_json_get_str(v, key: []const u8)` (and `_json_get_int/float/bool/obj`),
which all take a parameter literally named `key`. Zig treats a file-scope `pub fn key`
and a same-scope fn parameter `key` as a shadow → hard error. Same class as `fill`
(collides with `_pad_fill(fill: …)`), hit earlier during §28f set-literal testing.
**Impact:** common identifiers (`key`, `val`, `fill`, …) are unusable as user function
names. **Workaround:** rename the user function (the example uses `cellKey`).
**Fix direction / disposition (2026-07-25):** SUBSUMED by the single-file-emit epic
(`docs/single_file_emit_design.md`) — deferred, do NOT hand-rename the preamble.
Verified: the repro (`def key(...)`) FAILS under default multi-file emit but COMPILES
CLEAN under `--single-file`, because single-file mode wraps user decls in
`const _Mod = struct {…}`, so user `key` becomes `_Mod.key` and a file-scope preamble
param `key` shadows nothing. When single-file becomes the default emission mode, this
class disappears wholesale. The alternative — prefixing preamble identifiers — is worse
than it looks: Zig forbids shadowing a container decl with ANY local, so a preamble
body `var key`/`const key` collides too (not just params); plus perpetual per-helper
maintenance and pre-`HELPERS_START` dual-maintenance. Disproportionate for a
low-severity papercut with a clean architectural cure already in flight. **Workaround
until then:** rename the user function (e.g. `key` → `cellKey`). Discovered 2026-07-24.

### BUG-201: nested-container dispatch on call-result / mutable-loop receivers ⛔ OPEN (found probing BUG-196)
Two distinct facets surfaced when probing BUG-196, each its own mechanism:
- **(b1) `.add`/`.at`/`.len` on a `.at()` CALL-RESULT** — `m.at(0).add(99)` on
  `List(List(int))` → "no member function named 'add' in ArrayList". genMemberCall's
  `recv_t = inferExpr(m.object)` dispatch (CodeGen ~10630) *should* fire the `Type_.list_`
  arm, but `inferExpr(m.at(0))` isn't resolving to `list_` at the codegen call site even
  though the standalone `.at` inferExpr handler (TypeChecker ~1844 returns the element
  type) and the outer `inferExpr(m)` both work. Likely a codegen-`infer_ctx` population
  gap for chained call receivers. A chained-dispatch/inference fix.
- **(b2) mutating a `for`-binding element** — `for r in m: r.add(5)` now *dispatches*
  correctly (post-BUG-196) but hits "expected '*T', found '*const T'": Zig loop bindings
  are `const` (`for (m.items) |r|`), so mutating the element needs the by-pointer form
  `for (m.items) |*r|` + deref. A separate mutation-aware loop-lowering feature (detect a
  mutating method on the loop var → emit `|*r|`). Matrix-in-place-build pattern.

### BUG-101: AstBuilder uses `std.debug.panic` instead of diagnostics for parse-tree shape violations
- **Severity:** Low today (only the parser produces trees and it's well-tested) / Critical for VCS-merge-oracle future (operation-patches could synthesize trees)
- **Status:** Open
- **Symptom:** ~20 sites in `src/AstBuilder.zig` use `std.debug.panic` to assert parse-tree shapes (e.g., `:159, 551, 869, 896, 924, 941, 1086, 1589, 1650, 1908, 1928, 2052, 2131, 2169, 2277, 2430` — partial list). Failure mode is hard panic with terse message and no source span.
- **Reproducer:** None today from any well-formed source (they're invariant assertions). But under a future operation-patch VCS where structural edits synthesize trees, every site is a live hazard.
- **Root cause:** AstBuilder predates the Diagnostic infrastructure; these sites were the historical fail-fast paths.
- **Fix sketch:** Long-horizon refactor — fold each panic into the `Diagnostic` system with a "synthesized AST violated invariant X" error class, including the offending parse-tree NT. Short-term: leave alone but document the assumption that only the parser produces trees.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P0-2]).

---

### BUG-103: TC `extractFromDecls`/`extractFromMembers` silently skip unknown declaration variants
- **Severity:** Low (only triggers on adding a new `Ast.Decl` variant; latent reliability hazard)
- **Status:** Closed — fixed 2026-05-06
- **Resolution:** All 4 `else => {}` catch-alls in the metadata-collection passes replaced with fully exhaustive arms listing every `Ast.Decl` variant explicitly. Adding a new `Ast.Decl` variant now causes a Zig compile error at all 4 sites (same guarantee `checkTopDecl` already had). Behavioral change: none — all new arms are `{}`. Bootstrap 5/5, smoke 44/44, full test suite.
  - `extractFromDecls` (4 new arms: `.use`, `.interface`, `.mixin`, `.extend`, `.sig_`, `.var_`, `.init`)
  - `extractFromMembers` (10 new arms: everything except `.method`, `.var_`, `.init`)
  - `collectExtMethodsInDecls` inner switch (extend members: 12 new arms)
  - `collectExtMethodsInDecls` outer switch (top-level decls: 11 new arms)
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-1]).

---

### BUG-104: Unknown `@directive` silently ignored by AstBuilder
- **Severity:** Low (typical case is benign; impacts merge-oracle and forward-compat)
- **Status:** Closed — fixed 2026-05-06
- **Resolution:** `src/AstBuilder.zig` now emits `warning: unknown @-directive '@foo'; ignored` via `std.debug.print` to stderr when an unrecognized `@name` directive is encountered. `selfhost/parser.zbr` emits the same message via `sys.errln`. Compilation continues normally; only the unknown directive is ignored. Bootstrap 5/5, smoke 44/44.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-2]).

---

### BUG-088: def-level `try/catch` in non-void return function falls off the end
- **Severity:** Medium (correctness — Zig refuses to compile the generated code)
- **Status:** Fixed
- **Symptom:** A method using the `def...catch` form (catch clause attached to the def itself, not a nested try/catch block) with a non-void return type fails to compile. The generated Zig has a `return` inside the success path, an unreachable `break`, then an `if (_try_err_1 != null) return ...;` afterwards — but no return on the path through both blocks where neither error occurred and the success block didn't already return. Zig errors with "function with non-void return type implicitly returns" + "unreachable code" at the orphan `break`.
- **Reproducer:** A `def f(): str` with `var v = try X()` followed by `return "ok"` and a `catch` clause returning `"err"` — see `test/bug088_try_return_test.zbr`.
- **Root cause:** `body_ends_in_break` in `genTryCatch` didn't handle `.return_` as a terminal statement; the orphan `break :_try_blk` was always emitted.
- **Fix:** `genTryCatch` now checks if the last stmt is `.return_`; if so, skips the `break :_try_blk` and emits `unreachable;` after the catch block. Both `src/CodeGen.zig` and `selfhost/codegen.zbr` updated. Also fixed `genBranch` to emit `=> |_| {` for `as _` discard on boxed union variants (was generating invalid `const _ = …`).
- **Discovered:** While writing `contract_result_throws_test.zbr` for the BUG-087 fix.

---

### BUG-014: Regex lazy match is global, not per-quantifier
- **Severity:** Medium
- **Status:** Open — architectural limitation
- **Symptom:** In a pattern mixing lazy and greedy quantifiers (e.g., `<.*?>.*>`), the global `lazy_match` flag makes ALL quantifiers lazy.
  - Simple lazy patterns `<.*?>` work correctly.
  - Mixed patterns `<.*?>STUFF.*>` misbehave.
- **Root cause:** The current Thompson NFA passes a global `shortest: bool` to `matchAt`. When ANY `*?`/`+?`/`??` is parsed, `flags.lazy_match = true` is set for the whole regex.
- **Fix (architectural):** Requires either a priority-first NFA simulation or a backtracking regex engine.
- **Workaround:** For patterns needing mixed lazy/greedy, split into multiple regex calls or restructure the pattern.

---

### BUG-017: `len` on unknown-TC-type emits `.items.len` heuristic — imprecise
- **Severity:** Low
- **Status:** Open — known imprecision; deferred until ModuleInterface preserves return types
- **Symptom:** When a local variable's TC type is `.unknown` and `.len` is accessed on it, CodeGen emits `.items.len` as a last-resort fallback. Correct for `ArrayList`-backed `List(T)` values but wrong for user-defined structs with a field named `len`.
- **Proper fix:** Add a `.list { elem_type }` variant to `TypeChecker.Type`, store it in `ModuleInterface.methods` for list-returning methods, propagate through `inferCall` for cross-module calls.

---

### BUG-026: `instance_method_return_types` gaps for exposed-type method chains
- **Severity:** Medium
- **Status:** Open
- **Target:** Phase 7b / post-audit
- **Symptom:** `var b = a.someMethod()` may still produce `const b` in generated Zig if `someMethod` isn't in `instance_method_return_types`.
- **Root cause:** `instance_method_return_types` is populated by `buildModuleInterface`. It only captures methods whose return type resolves to a `.named` symbol with a non-primitive type.
- **Fix direction:** Populate `instance_method_return_types` more comprehensively, including methods returning `Self` or generic types.

---

### BUG-027: Method chaining on struct temporaries requires manual intermediate vars
- **Severity:** Low (ergonomic / language design)
- **Status:** Fixed — expression-position call-arg chains now emit a labeled block `(blk_N: { var _mc_N = f(); break :blk_N _mc_N.method(args); })` in both Zig backend (`src/CodeGen.zig`) and selfhost (`selfhost/codegen.zbr`). Bootstrap 5/5. Throws sub-issue also fixed: `exprCallIsThrows` now handles call-expression receivers (looks up TC type, scans class/struct members); labeled block emits `break :blk_N try _mc_N.method(args)` when the chained method `throws`. Selfhost mirrors this via `inferExpr`+`isClassMethodThrows`.
- **Remaining sub-issue (deferred):** Expression-position chain `foo(f().throws_method())` inside a `try { }` block (`try_block_label != null`) — the labeled block emits the `try` prefix on `break`, but there is no catch redirect into the try-block's error variable. This path is rare (requires both a labeled try block and a throws chain in call-arg position) and not hit by current tests. Workaround: extract to a named variable before the call-arg site.
- **Symptom A (method-chain-on-temporary):** `display(makeBuilder(5).withVal(10))` fails: the struct temporary `makeBuilder(5)` becomes `*const Builder`, but `.withVal(10)` requires `*Builder`.
  **Fixed positions:** `var r = f().method()` (var-init), `return f().method()` (return), `x = f().method()` (assign) — hoisted via `hoistCallChain` in selfhost / statement-position fix in Zig backend. `foo(f().method(args))` (call-arg / expression) — now fixed via labeled block in both backends. `foo(f().throws_method())` — now emits `try` in both backends.
- **Symptom B (TC auto-deref annotation gap):** When a local variable is assigned from a `throws`-returning function via `?` propagation (`var x = foo()?`), the TypeChecker doesn't record the inferred type in `expr_types`. Downstream `^T` field accesses on `x` then silently omit the required `.*` deref because TC type is `.unknown`. Workaround: annotate explicitly — `var x as T = foo()?`. Fix tracked separately as BUG-077.
- **Root cause (A):** Zig temporary value semantics — caller's stack slot for a struct returned by value is `const`.
- **Root cause (B):** `inferCall` for `?`-propagated throws calls doesn't write back to `expr_types` for the receiving variable.

---

### BUG-079: Method chaining on struct-returning calls silently mis-compiles or is unnecessarily banned
- **Severity:** Medium (ergonomics + correctness; blocks natural call-chaining style)
- **Status:** Fixed — commits de0ec8e + 8c16fd9; auto-hoist in `genLocalVar`, `genReturn`, `genAssign` via `hoistCallChain`; expression-position (call args, compound expressions) remains open (BUG-027)
- **Target:** Pre-1.0 (ribbon ceremony blocker)
- **Symptom:** `f().method()` where `f()` returns a struct type is either silently mis-compiled or must be avoided by convention. The compiler does not enforce materialization; the hazard is invisible to the user until a runtime fault or a wrong-Zig-type error appears.
- **Example:**
  ```zebra
  # Broken — f() returns a struct temporary; .bar() has no stable address
  var result = makeWidget().label()

  # Required workaround
  var w = makeWidget()
  var result = w.label()
  ```
- **Root cause:** In the Zig codegen, a struct return value is a temporary on the Zig stack. Methods on Zebra classes/structs are emitted as `fn method(self: *T, ...)` — they require a pointer receiver. Calling `.method()` on a temporary is either rejected by the Zig compiler (`cannot take address of temporary`) or produces a dangling pointer if the optimizer moves the value.
- **Fix direction (two options):**
  1. **Compiler error:** In the TypeChecker or Resolver, detect `ExprCall` nodes whose callee is `ExprMember { object: ExprCall }` (chained call on a call result) and emit a hard error: `"method chaining on a struct return value is not allowed — assign to a variable first"`.
  2. **Auto-materialize:** In CodeGen, when emitting a method call whose object is itself a call expression, auto-insert a `const _tmp = <inner_call>; _tmp.method(...)` — transparent to the user but produces valid Zig.
- **Preferred fix:** Option 2 (auto-materialize) — better ergonomics, no user-visible restriction. Option 1 is faster to implement and safer as an interim gate.
- **Note:** This limitation is currently documented as a CLAUDE.md agent convention ("always materialize intermediates") rather than as a language/compiler constraint. That is the wrong layer — the language should either enforce or transparently handle it.

---

### BUG-083: `genGenericClass` skips `implements` conformance checks
- **Severity:** Low (conformance gap, not correctness gap — the class still compiles)
- **Status:** Fixed — `src/CodeGen.zig` and `selfhost/codegen.zbr` both emit `comptime { IFoo.check(@This()); }` in `genGenericClass`; `test/generic_iface_test.zbr` covers this; bootstrap 5/5.
- **Symptom:** A generic class declared `class Stack(T) implements IFoo` does not emit a `comptime { IFoo.check(@This()); }` block inside the generated Zig struct. The missing check means the compiler won't catch at compile time that `Stack(T)` is missing a required method — the error will only surface when a caller tries to use a `Stack(T)` value through the interface (if ever).
- **Root cause:** `genGenericClass` in both `src/CodeGen.zig` and `selfhost/codegen.zbr` handles `invariants` but has no `implements`/`ifaces` block. `genClass` delegates to `genGenericClass` early and never runs its own `implements` block. This was a pre-existing gap before interface vtable codegen was added.
- **Fix:** Added `implements.len > 0 → comptime { IFoo.check(@This()); }` block in `genGenericClass` (both backends), parallel to `genClass` and `genStruct`.

---

### BUG-084: Selfhost `Lexer.zbr` tracks `[`/`]` in `parenDepth`; Zig `Tokenizer.zig` does not
- **Severity:** Low — root divergence fixed; both backends now behave identically
- **Status:** Fixed — removed `[`/`]` and `@[` from `parenDepth` tracking in `selfhost/Lexer.zbr`; aligned with `src/Tokenizer.zig` (only `(`/`)` tracked); 26/26 smoke tests pass; bootstrap 5/5
- **Root cause:** Selfhost `Lexer.zbr` tracked both `[`/`]` and `(`/`)` in `parenDepth`. Zig `Tokenizer.zig` only tracks `(`/`)`. The divergence was accidental — the original selfhost port added `[`/`]` tracking without a design reason, and the `@[` emit path (added for array literals) was patched to compensate rather than root-cause fixed.
- **Fix:** Removed `parenDepth = parenDepth ± 1` from the `[`/`]` handling and the `@[` `scanAt` path in `selfhost/Lexer.zbr`. Both backends now only suppress EOL inside `(`...`)`. Multi-line `@[...]` is consistently unsupported in both backends (same behavior).

---

### BUG-085: `static def` methods — bare static field names incorrectly emit `self.field`
- **Severity:** Low (ergonomic; workaround available)
- **Status:** Fixed — `src/CodeGen.zig` and `selfhost/codegen.zbr` `genIdent`; `test/shared_var_test.zbr` updated to exercise the fix; bootstrap 5/5.
- **Symptom:** Inside a `static def` method, a bare field name (e.g. `count`) was treated by `genIdent`/`isFieldName` as an instance field and emitted as `self.count`. But static methods have no `self` parameter in the generated Zig — so the generated code was `self.count` in a `fn increment() void` with no `self`, causing a Zig compile error.
- **Root cause:** `genIdent` checked `in_method: bool` (set for both instance and static methods) and `isFieldName` returned true for any declared class field. There was no guard for the static case.
- **Fix:** Rather than adding an `in_static_method` flag (which would miss bare `static var` access from instance methods), the fix checks the field's own `static` modifier at the `genIdent` site:
  - **Zig backend:** After `if (sym.kind == .var_)`, added `if (sym.decl.var_.mods.static_) { emit owner.name; return; }`. Safe because `sym.kind == .var_` guarantees `sym.decl` is the `.var_` union variant.
  - **Selfhost:** Added `isStaticField(name: str): bool` helper (iterates `owner_members`, returns `fld.mods.is_static`). `genIdent` now calls `isStaticField` and emits `owner.name` instead of `self_name.name` for static fields.
- **Benefit:** Fixes bare `static var` access from BOTH static methods AND instance methods — strictly more correct than the `in_static_method` flag approach.
- **Files:** `src/CodeGen.zig` (`genIdent`), `selfhost/codegen.zbr` (`genIdent`, new `isStaticField`).

---

### DESIGN-001: Throws auto-propagation scope — nested expression calls require `?`
- **Not a bug** — by design
- **Description:** Throws auto-propagation emits `try` for direct self-method calls and statement-level calls whose receiver is a `throws` method. It does NOT auto-propagate for:
  - `localVar.method()` — receiver is a local variable
  - `this.field.method()` — chained member access through a field
  - Calls nested inside compound expressions
- **Required action:** Use explicit `?` suffix for these cases: `localVar.method()?`, `this.field.method()?`

---

### DESIGN-002: `collectAndEmitOldSnapshots` (selfhost) missing `Expr` arms
- **Status:** Fixed — `selfhost/codegen.zbr` `collectAndEmitOldSnapshots`; `test/contract_old_compound_test.zbr` covers the `array_lit` case; 31/31 smoke, bootstrap 5/5.
- **Was:** `selfhost/codegen.zbr` `collectAndEmitOldSnapshots` fell through to `else: pass` for 8 compound Expr variants. An `old expr` nested inside any of these produced an undeclared-identifier Zig compile error: the `defer` block referenced `_old_N` but no snapshot was ever emitted.
- **Confirmed failing test:** `ensure val in @[old val, n]` — `old val` inside `array_lit` — produced `error: use of undeclared identifier '_old_0'` before the fix.
- **Fixed arms added:**
  - `array_lit` — iterate `elems`, recurse each
  - `list_lit` — iterate `elems`, recurse each
  - `tuple_lit` — iterate `elems`, recurse each
  - `dict_lit` — iterate `entries`, recurse `entry.key` and `entry.value`
  - `string_interp` — iterate `parts`; recurse only `StringPart.expr_` arms
  - `type_check` — recurse into `tc.expr`
  - `slice` — recurse `sl.object`; recurse `sl.start to!` and `sl.stop_ to!` if non-nil
  - `except_` — recurse `ex.base`; recurse each `f.value` in `ex.fields`
  - `lambda` — left as no-op (correct: `old` inside a lambda body is semantically unsound)
  - Leaf nodes — left as `else: pass` (correct: can't contain `old_`)
- **Note on slice optional fields:** `ExprSlice.start: ^Expr?` uses `!= nil` + `to!` (not `if x as s`) — consistent with the existing `genExpr` slice handling in the selfhost.
- **Files:** `selfhost/codegen.zbr` (`collectAndEmitOldSnapshots`), `test/contract_old_compound_test.zbr` (new), `tools/selfhost_smoke.sh` (new smoke entry).


---

### INFRA-001: --update non-idempotence on first run after certain bootstrap states
- **Not a bug** — cosmetic only; both output forms compile and round-trip correctly
- **Symptom:** The first `bash tools/bootstrap_check.sh --update` (or `zig build update-selfhost`)
  after a full bootstrap or manual `/tmp/bs-zig` copy can produce `selfhost/*.zig` files with
  the header `// Generated by the Zebra compiler.` (bootstrap style) rather than the expected
  `// Generated by zebra-selfhost.` (selfhost style). Subsequent `--update` runs are stable and
  idempotent on the selfhost-style output.
- **What to do:** If you see bootstrap-style headers after `--update`, just run `--update` once
  more. The second run will produce the correct selfhost-style headers and stay there.
- **Root cause (partial):** `codegen.zbr` line 808 (`generateFullWithDeps`) and line 831
  (`generateDepWith`) both emit `"// Generated by zebra-selfhost.\n"`, so selfhost-A should
  always produce selfhost-style output. The first-run anomaly may be a stale `zebra-selfhost.exe`
  binary that predates step 2's rebuild, or Zig build-cache reuse in step 2 that skips the
  recompile when source timestamps haven't changed. Not fully traced.
- **Where this is also documented:** Comment in `tools/bootstrap_check.sh` update-mode header.

---

### BUG-121: TC diagnostics always report col 0 — span resolution needed

- **Severity:** Low (correct file:line, wrong column — usable but imprecise)
- **Status:** Open — deferred; noted in `checkExpr` with a TODO comment
- **Symptom:** All type-mismatch diagnostics emitted by `checkExpr` and `checkVarDecl` report column 0. The format `file:line:0: error: type mismatch: ...` is technically valid but unhelpful for editors and users.
- **Root cause:** Statement spans record the keyword position (e.g., the `return` token or `var` token), not the expression start. Column within the line is stored as 0 in most spans because the parser does not yet thread byte-offset-within-line into `Span.col`.
- **Proper fix:** Thread a true column (byte offset from start of line) into `Span` during tokenization. The tokenizer tracks `col` via `_col` already in `Lexer.zbr`; it needs to be passed through `PExprId` → `Span` in the ASTBuilder rather than defaulting to 0.
- **Where noted:** `selfhost/typechecker.zbr` `checkExpr` — `TODO BUG-121` comment.
- **Filed:** 2026-05-09


---

### BUG-122: Selfhost codegen — `opt_ptr_field_bindings` not seeded for local variables with inferred types

- **Severity:** Low (workaround exists; only hits when a local var holds a struct with `^T?` fields and those fields are accessed via `to!`)
- **Status:** Fixed (2026-05-26) — both sub-problems resolved via `infer_ctx` in `genLocalVar`

#### Background

`opt_ptr_field_bindings` is a `StrSet` on `Generator` tracking `"bindingName.fieldName"` pairs for fields typed `^T?` (optional heap-pointer). The `to_non_nil` (`to!`) codegen handler (codegen.zbr ~line 6245) emits `.?.*` instead of `.?` when the key is present, because Zig needs the extra `.*` deref for pointer fields.

The set is seeded in three places:
- **Named parameters** (line ~2613): at method entry, for each `TypeRef.named` param, scans `opt_ref_fields` for `"TypeName.*"` and adds `"paramName.*"`.
- **`capture` bindings** (line ~4195): when a union arm is bound with `if x is T as cap`, seeds for the variant payload's struct fields.
- **`if x as n` / `if x is T as n` bindings** (line ~5122): same seeding for optional-unwrap and type-check bindings.

**Local `var` declarations are not seeded.** So `var x = someFunc()` where `someFunc` returns `DeclTypeAlias?` does NOT get `"x.constraint"` added to `opt_ptr_field_bindings`, and `x to!.constraint to!` emits `.?` without `.*`, producing a Zig type error (`expected 'ast.Expr', found '*ast.Expr'`).

#### Two sub-problems

**Sub-problem 1 — explicit type annotation** (`var x: DeclTypeAlias = ...`)

When `n.type_` on a `StmtVar` is `TypeRef.named as nt`, the fix is identical to the parameter seeding logic already at line 2613. In `genLocalVar`, after emitting the declaration:

```zebra
if n.type_ is TypeRef.named as nt
    var nt_dot = nt.name + "."
    var orf = opt_ref_fields.items()
    var orfi = 0
    while orfi < orf.count()
        var orf_e: str = orf.at(orfi)
        if orf_e.startsWith(nt_dot)
            opt_ptr_field_bindings.add(makeDottedKey(n.name, extractAfterDot(orf_e)))
        orfi += 1
```

Scope cleanup: `opt_ptr_field_bindings` is reset at method entry (line ~1565: `opt_ptr_field_bindings = StrSet()`), so no per-scope removal is needed for local vars — they live for the method duration and cannot bleed across method boundaries.

This sub-problem is **easy (~1h)** and has no known risks.

**Sub-problem 2 — inferred type** (`var x = someFunc()` where return type is `SomeStruct?`)

The codegen does not currently know what a call expression returns. To seed `opt_ptr_field_bindings` for this case, you need to resolve the return type at the call site.

**Recommended approach:** add a `local_var_types: HashMap(str, str)` (var name → struct type name) to `Generator`. Populate it in `genLocalVar` by inspecting the RHS expression:

- `Expr.call` whose callee is a known function: look up the return type in `module_types` / `dep_types`. The key lookup is `module_types.funcReturnType(funcName)` — this method does not exist yet and would need to be added to `ModuleTypes` in `typechecker.zbr`. It mirrors how `inferExpr` for `Expr.call` already looks up `module_types.methodReturn(...)`.
- `Expr.member_call` (method call): look up via `module_types.methodReturn(typeName, methodName)`, strip `?` if the type is optional, then use the base struct name.

Once `local_var_types` is populated, the `to_non_nil` handler (line ~6245) should additionally check: if `tnn_obj` is in `local_var_types`, get the struct name, form `"structName.memberName"`, and check `opt_ref_fields` directly — eliminating the need for the key to be pre-seeded.

```zebra
# In to_non_nil handler, after the opt_ptr_field_bindings check:
if tnn_obj != nil
    var lv_type = local_var_types.get(tnn_obj to!)
    if lv_type != nil
        var orf_key = makeDottedKey(lv_type to!, tnn_m.member)
        if opt_ref_fields.contains_(orf_key)
            w.emit(".*")
```

**Complexity:** `local_var_types` must propagate into `indented()` child generators (branches, loops, etc.) so bindings declared in an outer scope are visible in inner scopes. The simplest approach is to pass a reference to the parent's `local_var_types` into child generators, or to copy it at `indented()` creation. Since the set only grows within a method and resets at method boundaries, copy-on-enter is safe.

`funcReturnType` on `ModuleTypes` is the new surface that needs implementing in `typechecker.zbr`. It needs to handle: plain functions, methods, and the `?`-strip for optional returns. This is roughly 30-50 lines in `typechecker.zbr` and a corresponding update to `selfhost/typechecker.zig` via `update-selfhost`.

Estimated effort: **~half a day** once sub-problem 1 is done as a warm-up.

#### Current workaround

Extract the code that accesses `^T?` fields into a helper method where the struct is a **named parameter** (not a local variable). This forces `opt_ptr_field_bindings` to be seeded at method entry.

Example: `genTypeAliasConstraint(alias_decl: DeclTypeAlias, ...)` — `alias_decl` is a parameter so `"alias_decl.constraint"` is seeded. See selfhost/codegen.zbr ~line 3557.

#### Files to change when fixing

- `selfhost/typechecker.zbr` — add `funcReturnType(name: str): str?` (or similar) to `ModuleTypes`
- `selfhost/codegen.zbr` — add `local_var_types: HashMap(str, str)` to `Generator`; populate in `genLocalVar`; consult in `to_non_nil` handler; propagate into `indented()`
- `selfhost/typechecker.zig`, `selfhost/codegen.zig` — regenerated via `zig build update-selfhost`
- Add a test: a local var holding a struct with `^T?` field, accessed via `to!`, without extracting into a helper

- **Discovered:** 2026-05-18 during type alias `^Expr?` constraint access in selfhost codegen.

---

### BUG-123: Generated `pub fn main(init: std.process.Init)` shadows user-defined `init` function

- **Status:** Fixed (2026-05-21)
- **Symptom:** An MVU program with `def init(): Model` would fail to compile. Inside the generated `main`, the parameter `init: std.process.Init` shadowed the user's top-level `init` function.
- **Fix:** Renamed the parameter from `init` to `_zinit` in `genMain` in `src/CodeGen.zig` (4 sites) and matching locations in `selfhost/codegen.zbr` (4 sites). Both compilers regenerated. Bootstrap 5/5.

---

### BUG-124: Bootstrap codegen — `^T?` constructor arg boxes as `*?T` instead of `?*T` for value-typed T

- **Severity:** Low (only affects bootstrap compiler for value-typed union/struct `^T?` constructor args; selfhost is correct)
- **Status:** Fixed (2026-05-26) — `genBoxedArgExpr` uses `payload` (nilable-stripped) instead of `inner` for `create()` type; same for same-module union-variant boxing path

#### Symptom

When the bootstrap compiler (`zebra-bootstrap.exe`, the Zig-implemented compiler) generates a constructor call where a `^T?` parameter receives a value-typed union or struct (not a class), it wraps it as `*?T` instead of `?*T`.

Example: `Container(v)` where `Container.opt_val: ^Val?` and `Val` is a union type emits something like:

```zig
// Bootstrap (wrong)
const _bp = _allocator.create(?Val) catch @panic("OOM");
_bp.* = v;  // _bp is *?Val but Container wants ?*Val
```

instead of the correct selfhost output:

```zig
// Selfhost (correct)
const _bv = v;
const _bp = _allocator.create(@TypeOf(_bv)) catch @panic("OOM");
_bp.* = _bv;  // _bp is *Val, then break gives ?*Val
```

#### Root cause

`src/CodeGen.zig` boxing logic for `^T?` arguments. When T is a value type (union, struct, primitive), the bootstrap compiler wraps the whole optional type instead of just T, producing `*?T`. The selfhost `_bx0:` labeled-block approach avoids this by creating a pointer to the concrete value first.

#### Files to change when fixing

- `src/CodeGen.zig` — fix boxing for `^T?` arguments when T is value-typed; use `@TypeOf(value)` or strip the `?` before `create()`
- `src/TypeChecker.zig` — may need `isValueType()` helper to distinguish class (heap-allocated) from value-typed (union/struct/primitive)

#### Discovered

2026-05-26 during BUG-122 testing: `val_test.zbr` (`val_lib.Val` union in `Container.opt_val: ^Val?`) compiled incorrectly through bootstrap.

---

*Last updated: 2026-05-26 — BUG-122 fixed (opt_ptr_field_bindings seeded for local vars); BUG-124 fixed (^T? boxing uses payload not inner); multi-error parse recovery added to both src/ and selfhost/ compilers*
