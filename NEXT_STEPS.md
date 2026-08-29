<!-- doc-status: live -->
# Zebra — Next Steps

Authoritative priority queue for the project. **Update this file rather than
regenerating it.** Open work is curated at the top (scan the index first);
completed work is clumped at the bottom (recent items in full, older items as
one-line archive rows). Full history for anything archived lives in git, `BUGS.md`,
`SELFHOST_JOURNAL.md`, `CHANGELOG.md`, and the wiki.

> **Milestone cumulative semantics:** each milestone is *additive*. A feature
> labeled 0.14 lands at 0.14 and is then part of the **1.0 stability commitment**
> (1.0 = everything delivered 0.1 → 0.15, locked). Same rule for 2.0 (kernel
> track = 1.0 + the 2.0 additions). "What blocks 1.0" = everything labeled for any
> 0.x milestone not yet shipped + stable. Public release = **0.9** (ready-for-
> others, not-yet-1.0). Authoritative version-by-version breakdown:
> `wiki/pages/projects/project_zebra.md`.

---

# ▶ Open work — scan me first

## 0.9 — RETIRE THE IMGUI GUI BACKEND (Sean, 2026-08-25). SURVIVORS: **tui** and **libui-ng**.

Decision: **imgui dies**, along with the imgui IDE and the vendored ImGuiColorTextEdit.
`tui` and `libui_ng` are the two backends going forward.

**MEASURED FIRST, so nobody re-derives the scope.** It is smaller than the 278 textual
mentions suggest, because almost all of it is one contiguous emitted-template block.

| what | where | size |
|---|---|---|
| the `.glfw` arm — THE imgui backend | `src/CodeGen.zig:3252-3674` | **422 lines**, one `writeAll` of a `\\` template |
| `.sdl2, .dx12` arm | `src/CodeGen.zig:3675-3852` | **178 lines** |
| enum members | `GuiBackend = enum { stub, glfw, sdl2, dx12, tui, libui_ng }` | 3 to drop |
| build template line | `src/main.zig:1217` (`exe.linkLibrary(zgui_dep.artifact("imgui"))`) | 1 |
| vendored | `vendor/ImGuiColorTextEdit` (43 tracked files), `vendor/fonts` (36 files, 15 MB) | |
| the IDE | `IDE/ZebraIDE.zbr` + `IDE/ZebraIDE_gui/` | 5 tracked `.zbr` |

**`sdl2`/`dx12` ARE NOT IMGUI — checked, because the assumption was that they were.** That
arm is 178 lines of DUPLICATED STUB under a single comment:

```
// TODO: sdl2/dx12 GUI backend not yet implemented; using stub.
```

They were never implemented at all, so they are an independent deletion rather than
imgui's dependents. **Same shape as `aspect` in the reserved-words work** (BUG/U4a): an
enum member reserved for something never built, costing real surface area — every
`--gui-backend` value is a promise the CLI appears to make.

**THREE FACTS THAT MAKE THIS CHEAP:**
1. **`selfhost/*.zbr` mentions imgui ZERO times.** The selfhost never implemented it;
   `--gui-backend=glfw` delegates to the bootstrap, and the bootstrap is being retired
   anyway. This is code that dies with it regardless.
2. **No gate covers it.** `gui_scaffold_check` is tui-only, so nothing goes red — and
   nothing is verifying it today either.
3. **No corpus file builds with it.** Only docs and the IDE reference `--gui-backend=glfw`.

**DO NOT "FIX" THE HISTORICAL DOCS.** `SELFHOST_JOURNAL.md` and `CHANGELOG.md` are
`doc-status: historical`; an entry describing a backend that existed in May is accurate
history, and rewriting it falsifies the record. `doc_lint` already exempts them. What DOES
need updating: `QUICKSTART.md` (the backend table), `IDE/README.md`,
`docs/BETA_REVIEW_CHECKLIST.md`, `docs/UI_QUICKSTART.md`.

**ORDER:** delete the arms and enum members first and let `doc_lint` name every stale
reference — that is the tool doing the inventory rather than a hand-written list, which is
the same argument `corpus_ls.sh` makes.

## POST-0.9, PRE-1.0 — ADOPT ZIGZAG'S FALLIBLE `init`/`update`/`view` (Sean, 2026-08-25)

We are pinned to `git+https://github.com/meszmate/zigzag#v0.1.5`, which **is the latest
release** (2026-05-06) — there is nothing to bump to. The resolved hash reads
`zigzag-0.1.2-…`; that is upstream's `.zon` version lagging its own tag, not a stale pin.
Main is ~20+ commits ahead through 2026-08-14.

**THE CHANGE TO ADOPT: PR #132, "let init, update and view return error unions".**

**It is OPT-IN and backward compatible** — both signatures compile simultaneously,
detected per-function at comptime, existing code unchanged. An earlier note in this file
called it a "BREAKING MVU signature change" and advised waiting; that was read off the
commit TITLE, and the PR says otherwise. Corrected rather than left, because this queue is
what the next session works from.

**WHY IT IS WORTH ADOPTING, in this repo's own terms.** The stated motivation is 245
instances of `catch ""` / `catch "?"` / `catch "Error"` in their examples — allocation
failures becoming rendering artifacts *indistinguishable from legitimate output*. That is
UNGIT "nothing fabricated" exactly, and the same defect class as `gui_scaffold_check`
printing "startup path clean" about a scaffold that did not exist (BUG-298).

Note the direction of the purity argument, because it is easy to get backwards: a fallible
`update` does NOT erode MVU's replayability. The alternative is not a pure `update`, it is
one that **silently produces a wrong model**. A propagated error is honest and replays as
"it failed here"; a swallowed OOM destroys replay fidelity far more thoroughly. `update`
still does no I/O and holds no hidden state either way.

**WHAT IT TOUCHES HERE:** the tui template in `src/CodeGen.zig` (the `.tui` arm, ~3853+)
declares `init`/`update`/`view`, plus the `build.zig.zon` fingerprint whose regeneration
procedure is documented at `src/main.zig:1281`.

**ALSO WORTH TRACKING, not adopting:** their recent Windows resize-detection and Kitty
graphics fixes. This repo is Windows-primary, so that work is directly relevant — and it
is the platform long tail we would inherit if we ever forked, which is the main argument
against doing so. If insulation is wanted without a fork, VENDOR A PINNED COPY the way
`sqlite` is vendored; the shape already exists under
`examples/counter_gui/zig-pkg/zigzag-0.1.2-…`.

**THE THING TO WATCH is not this change but whether the opt-in discipline HOLDS.** A
framework that adds capability without forcing migrations can be followed at our own pace;
the day that stops being true is the day the vendor-and-pin question becomes urgent.


## 0.9 — BITWISE OPERATORS (Sean, 2026-08-21). MEASURED, so nobody re-derives the state.

`~a` **already works** (BUG-256, 2026-08-04). The five BINARY operators do not, and they
fail in exactly the shape `~` did before that fix — **the lexer already produces the
tokens; the parser has no rule**:

| form | today |
|---|---|
| `~a` | works |
| `a & b`, `a \| b`, `a ^ b`, `a << 2`, `a >> 2` | `error: unexpected expression token: '&'` (etc.) |

`ampersand`, `ampersand_equals`, `tilde` and `caret_equals` are all in the token set, and
`&=` / `^=` are already grammar productions — so the language has **half-committed to the
C/Python spelling already**. Diverging now would make the set internally inconsistent, and
that is the main argument for keeping it.

**THE ONE REAL CONFLICT: `^` is the heap-indirection TYPE prefix (`^T`).** Python and Zig
do not have this problem. It is resolvable the way unary and binary `-` coexist — at the
start of an operand `^` means "pointer to", after a complete operand it means xor — but
note Zebra passes TYPES AS CALL ARGUMENTS (`Atomic(int)(0)`), so `f(^Bar)` and `f(a ^ b)`
are both expression-position. A precedence parser handles it; it is still a genuine wart
rather than a free lunch. If it proves confusing, `xor` as a word operator is the clean
escape, and arguably fits better anyway since Zebra already uses `and`/`or`/`not`.

**PRECEDENCE — DECIDED 2026-08-21: PYTHON'S, NOT C'S.** An earlier draft of this entry
had this exactly backwards and recommended the footgun; corrected here so it does not
drive an implementation the wrong way.

| | `x & 1 == 0` parses as | |
|---|---|---|
| **C** | `x & (1 == 0)` | `&` binds LOOSER than `==`. Ritchie acknowledged it as a mistake — `&` predated `&&`, and by the time `&&` arrived the precedence could not be changed without breaking code |
| **Python** | `(x & 1) == 0` | `\| ^ & << >>` all bind TIGHTER than comparison |

Zebra takes Python's. In the grammar that is three new levels between `Expr4`
(comparisons) and `Expr5` (additive) — `Expr4a → |`, `Expr4b → ^`, `Expr4c → &` — and
the RHS of every comparison rule drops to `Expr4a`.

Reversing it does not silently change an answer, which is the property worth having:
under C's precedence `x & 1 == 0` is `int & bool`, and the bitwise operand check rejects
that outright. Pinned by `test/bitwise_semantics_test.zbr` leg 1.

**GOLDEN VECTORS EXIST — use them rather than hand-computing.** Fable supplied
`zebra_bits_golden_vectors.json` (2026-08-21): 24 `primitive_ops` vectors with
xor/and/or/not64/shl64/shr plus FNV and xorshift steps, and hash-function vectors.

Two things to know before wiring them in, both from the file itself:
- **They are u64.** Several `a` values exceed i64 max, and `not64` is u64-interpreted, so
  they cannot all be written as Zebra `int` (i64) literals. `uint` exists in the type
  system (`Type_.uint_`) and is the natural home for the full set; the i64-representable
  subset can pin the signed path meanwhile.
- Its note flags the overflow idiom: *"Zig default arith panics on overflow; wrapping mul
  or masking required"* for the FNV step — relevant to how `<<` is lowered.

**SLICE 1 LANDED 2026-08-22: `& | ^`, BOTH COMPILERS.** The parser was the ENTIRE gap, in both compilers.
Everything downstream already existed and had simply never been reachable: the
`bit_and`/`bit_or`/`bit_xor` AST tags in both ASTs, `binaryOpStr` in the selfhost, the
`.bit_and => "&"` emit at `src/CodeGen.zig:692`, and — decisively — the typing rule at
`src/TypeChecker.zig:4306`, whose comment already read *"preserve the operand type"*.
Type-following was not a new decision; it was a decision someone made months ago and
never wired a parser to.

That also means none of that code had ever been TYPE-CHECKED, and one piece of it was
wrong: `.shl => "<<"` emits a bare Zig `<<`, and Zig requires the shift amount to coerce
to `Log2Int(T)` — `u6` for 64-bit. `a << b` on two `i64`s is a compile error
(*expected type 'u6', found 'i64'*). Classic unreached-code false-green.

**Verification.** Two fixtures, both `smoke_run` (running them is the point — `&` and `|`
are one character apart, both emit valid Zig and both yield a number, so a swapped operator
is invisible to every compile-only gate in the tree):

- `test/bitwise_golden_vectors_test.zbr` — 96 assertions over 24 vectors, GENERATED from
  Fable's `test/data_bits_golden_vectors.json`. An EXTERNAL oracle: computed by a different
  implementation, so it cannot agree with a bug of ours.
- `test/bitwise_semantics_test.zbr` — the decisions the vectors CANNOT discriminate:
  precedence, signed operands, unsigned operands, `^` sharing a file with `^T`, and the
  relative order of `&`/`^`/`|`.

**Falsified, not merely passed.** Mutating `binaryOpStr`'s `bit_and` to emit `"|"` turned
both red, and turned red PRECISELY: in the golden fixture only the `and` legs failed while
xor/or/not64 stayed green, and in the semantics fixture only the `&`-dependent legs. A
mutation that reddened everything would have proved much less. Restored and re-verified
green.

Both compilers agree: the bootstrap emits `(a & 1)`, `(a ^ 5)`, `(a | 3)` and the selfhost
runs the same program to `0, 15, 9, prec ok`. No selfhost-only divergence to account for.

One note for whoever writes slice 2: `^T` needs a VALUE type. The first draft of the
semantics fixture used `^Cell` on a CLASS and the compiler refused it by name — *"a class
is already a reference; drop the '^'"* — which is the diagnostic behaving exactly as it
should, and is why that leg now uses a `struct`.

**SLICE 2 LANDED 2026-08-22: `<< >>`, BOTH COMPILERS. THE OPERATOR SET IS COMPLETE.**

`>>` follows the operand type (arithmetic on `int`, logical on `uint`), so no `>>>` was
needed. Lowered through `_zbr_shl`/`_zbr_shr` in the preamble, wrapping `std.math.shl/shr`,
which are TOTAL -- no UB, no panic, at any shift amount.

**The one real bug was found by the intent-authored fixture, and the golden vectors could
not have found it.** A literal-only shift (`1 << 3`) arrives as `comptime_int`, which has
no `Log2Int`; `std.math` answers with `comptime unreachable`, so the build dies inside
zig's own std naming `math.zig` rather than the user's program. All 24 of Fable's vectors
use typed `uint` variables, so every shift there has a concrete type. Only the hand-written
fixture shifts bare literals -- which is what a person writes first. **An external oracle
is stronger about VALUES; an intent-authored fixture is the only thing covering SHAPES.**

Falsified by emitting `shr` for `shl`: 5 failures, all shift-left legs, `>>` legs green;
golden 22 of 24, the 2 misses being vectors where `a<<s` and `a>>s` are both 0 (s=63/62,
small operand) so the swap is genuinely invisible. `gramgen` 960/0/0 on the new rules --
which only became possible after regenerating `grammar.txt`, since that is what it derives
its programs from.

The old decisions, for the record -- all three were settled by measurement:
- **lowering** — `std.math.shl`/`shr` are TOTAL (no UB, no panic at any shift amount) and
  were measured: `shl(i64,-8,70)` = 0, `shr(i64,-8,70)` = -1 (saturates to the sign bit,
  matching Python), `shl(i64,-8,-1)` = -4 (a negative amount reverses direction).
- **out-of-range** — Fable's vectors all use in-range amounts, so they go green under any
  choice. Needs its own fixture or it ships undecided.
- **`>>` under implicit conversion** — `int → uint` and `uint → int` are BOTH implicit
  today (measured), so a shift's kind can depend on a type that is not visible at the use
  site. An accumulator that lands in `int` gets an arithmetic shift and a silently wrong
  hash. Pin it with the same bit pattern shifted under both types.

`a << -b` needs the space: `<<-` is the arena deep-copy-out token and out-munches `<<`.
That is now pinned by leg 10 of `test/bitwise_semantics_test.zbr`.

**REMAINING for bitwise, none of it blocking 0.9:**
- **Compound assignment `&= |= ^= <<= >>=`** is still parser-blocked in the SELFHOST only.
  The bootstrap has had `AssignOp -> caret_equals` and the `AstBuilder` mapping to
  `.caret_eq` all along; the selfhost's `parseExprOrAssignStmt` has no case, so `x ^= 1`
  is `error: unexpected expression token: '^='`. Same lexer-yes/parser-no shape the binary
  operators had.
- **Hex literals are SELFHOST-only-blocked too**, and this one is a genuine divergence
  worth closing: the bootstrap grammar has `Atom -> hex_lit` plus `hex_lit_unsign` and
  `hex_lit_explicit` (the `_u` / `_8 _16 _32 _64` suffixes), and `zebra-bootstrap` accepts
  `0xFF` and `0x9E3779B97F4A7C15_u` today. The selfhost refuses both. No corpus file uses
  a hex literal, which is why `divergence` never reported it.



Every genuinely-open item, grouped. Each links to its detail section below or to
the tracker. `[ ]` = open, `[~]` = partially done / has an open tail.

## 0.9 — BRAINSTORM: THE COMPILER SHOULD TELL YOU WHAT COSTS THE MOST, BY DEFAULT (Sean, 2026-08-26)

> "After working with such tools for seven years, I've become convinced that all compilers
> written from now on should be designed to provide all programmers with feedback indicating
> what parts of their programs are costing the most; indeed, **this feedback should be
> supplied automatically unless it has been specifically turned off.**"
> — Knuth, *Structured Programming with go to Statements*,
> ACM Computing Surveys **6**(4), pp. 261-301, December 1974

Sean's, via Casey Muratori's *The Root of The Root of All Evil* (BSC 2026). This is the SAME
paper that produced "premature optimization is the root of all evil", and the quote above is
the constructive half nobody quotes. Read together, Knuth is not saying don't optimise — he
is saying **don't guess**, and then putting the obligation on the COMPILER to remove the need
to guess.

**CITATION CORRECTED, and the correction is instructive.** This was first written here as
*An Empirical Study of FORTRAN Programs* (1971) from memory. That is a real Knuth paper, and
the 1974 one draws on it — but it is not the source of either quote. The filename in Sean's
link (`p261-knuth.pdf`) is what gave it away: Computing Surveys 6(4) begins at page 261.
Verified against the venue; a plausible-sounding citation from recall is exactly the kind of
thing this repo does not let stand.

**READ 2026-08-26** (Sean supplied the PDF; `pdftotext -layout` extracts it cleanly — note
poppler IS installed and on PATH for Bash, though the Read tool cannot see it). What follows
is against the paper, not against the one quote.

### What Knuth actually argues, which is THREE things, not one

His own abstract states the programme: "(a) improved syntax for iterations and error exits,
making it possible to write a larger class of programs clearly and efficiently without go to
statements; (b) a methodology of program design, beginning with readable and correct, but
possibly inefficient programs that are systematically transformed if necessary into efficient
and correct, but possibly less readable code."

The profiling mandate is (c), and it exists to serve (b). The full passage, and the sentence
that is doing the real work is NOT the famous one:

> "It is often a mistake to make a priori judgments about what parts of a program are really
> critical, since **the universal experience of programmers who have been using measurement
> tools has been that their intuitive guesses fail.** After working with such tools for seven
> years, I've become convinced that all compilers written from now on should be designed to
> provide all programmers with feedback indicating what parts of their programs are costing
> the most; indeed, this feedback should be supplied automatically unless it has been
> specifically turned off."

And the famous line, in its actual context, is a *bridge* to that claim rather than a caution
against optimising: "We should forget about small efficiencies, say about 97% of the time:
premature optimization is the root of all evil. Yet we should not pass up our opportunities in
that critical 3%... he will be wise to look carefully at the critical code; **but only after
that code has been identified.**"

**So the mandate rests on an empirical claim about people, not a preference about tools:
intuition about hot code fails, reliably, and the compiler is the thing positioned to fix
that.** Zebra's `@profile` annotation requires the programmer to have already guessed
correctly — it is precisely the failure mode Knuth names.

### THE DEEPEST ITEM, and it is a LANGUAGE requirement, not a tooling one

> "This veil was first lifted from my eyes in the Fall of 1973, when I ran across a remark by
> Hoare that, ideally, **a language should be designed so that an optimizing compiler can
> describe its optimizations in the source language.** Of course! Why hadn't I ever thought
> of it?"

Knuth builds his "programming system of the future" on this: an interactive
program-manipulation system where you write the readable-correct version and transform it,
with the transformations expressible in the language itself.

**Zebra transforms user code constantly and describes none of it.** TCO-wrapping a
value-returning `fn` in `while(true)`; auto-boxing on `^T` assignment; choosing `const` vs
`var` from mutation analysis; materializing temporaries for method chains; auto-propagating
`throws`. Every one is a decision the compiler makes and the user cannot see — and at least
one has already bitten as a HAZARD rather than a nicety (a `branch` arm that falls through
inside a TCO wrapper HANGS; see `lint_fallthrough` and the TCO memory note).

Hoare's criterion says those should be describable IN ZEBRA. That is the same claim as UNGIT
"nothing withheld", arrived at from the opposite direction, and it is a far better feature
than a profiler: **`zebra --explain` showing what the compiler did to your code, in your
language.** It teaches the cost model instead of reporting a number, it is deterministic
(so it can be GATED, unlike timings), and it needs no measurement infrastructure at all.

### Where Zebra already stands against (a) and (b)

- **(a) is largely satisfied**: no `goto`; iteration and error exits are structured
  (`throws`/`raise`/`try`, `branch` with exhaustiveness).
- **(b) is not addressed at all.** There is no supported notion of "here is the readable
  version, here is the transformed version, and here is the proof they agree". The nearest
  thing in the repo is the round-trip gate, which asserts exactly that property for the
  COMPILER's own output — which is suggestive.

### What already exists (measured 2026-08-26, so nobody re-derives it)

| piece | where | shape |
|---|---|---|
| `@profile` method modifier | `QUICKSTART.md` §"Method modifiers" | wraps a body in `Profile.start/end` |
| `Profile.report()` | `selfhost/stdlib_preamble.zig` | sorts entries by total ns, descending |
| per-entry data | same | `{ total_ns, call_count }`, keyed by `"Class.method"` |

So the RUNTIME is largely built. **The whole gap is the trigger**: it is opt-in, per-method,
and hand-annotated. A user must already suspect a function before they can measure it —
which is precisely the guessing Knuth is arguing against. Nothing is automatic, and there is
nothing to turn off.

### Two assets that make this much cheaper here than it looks

**1. `--turbo` is already the "specifically turned off" switch, and the pattern is GATED.**
Contracts are on by default and stripped by an explicit flag; `tools/contract_mode_check.sh`
asserts that four-way matrix (and asserts, deliberately, that `--release` ALONE does not
strip them). Automatic cost feedback wants exactly that shape, and it can copy a mechanism
that already exists, already has a gate, and has already survived one wrong belief about it
(BUG-257).

**2. Source attribution across the Zebra→Zig boundary is ALREADY SOLVED.** The emit carries
`// zbr:<file>:<line>` comments next to generated statements. Mapping a cost measured in
emitted Zig back to the Zebra line that caused it is usually the hard part of this feature,
and it is done.

### Directions worth arguing about

*Runtime measurement*
1. Instrument every user function automatically rather than the `@profile`-annotated ones;
   `--turbo`/`--release` strips it. The smallest change that satisfies the quote literally.
2. Sampling instead of instrumentation — much lower overhead, which matters if this is ON by
   default; costs exactness on short runs.
3. Attribute per CALL SITE, not per function. "`fmt` is 40% of runtime" is much less useful
   than "40% of runtime is `fmt`, called from `render`".
4. Print the top 3 at exit, one line each, not a wall. Automatic feedback that is a wall is
   feedback people turn off — and the quote's whole force is that it stays on.
5. A `zebra profile <file>` subcommand: build, run, report, no flag to remember.

*Static — no run required, and available in `-c`*
6. Cost estimates from structure alone: loop nesting depth, allocations inside loops, string
   `+` inside loops. The compiler knows all of it at emit time.
7. **Code-size attribution**: which functions generated the most Zig. Free, deterministic,
   and a decent proxy nobody has looked at.
8. Report what the compiler DID to the code — TCO applied here, `^T` auto-boxed there, a copy
   inserted, dynamic dispatch not devirtualised. This teaches the cost model rather than just
   reporting a number, and it is pure UNGIT: the compiler knows and does not say.

*Contracts, which is Zebra's own heritage*
9. `@cost(allocs=0)` as a compile-time or run-time obligation, in the same family as
   `require`/`ensure`. A performance property that FAILS rather than being merely reported.
10. Budget regression: record a program's profile, fail when it moves — `output_sweep`'s
    golden-baseline argument applied to cost instead of behaviour.

*Delivery*
11. Cost shown inline in diagnostics, on the source line, where the reader already is.
12. Differential profiling between two runs ("what got slower"), which is the question people
    actually have.
13. Fold in the existing `memStats` so allocation and time are one report, not two.

### The honest objections

- **On-by-default instrumentation changes what you measure.** Sampling (2) or emit-time
  static reports (6-8) dodge this; naive wrapping does not.
- **A default that is noisy gets disabled**, which loses the argument entirely. Whatever
  ships must be small enough to leave on — hence (4).
- **This repo has no gate that measures TIME**, and CLAUDE.md is emphatic that timings here
  swing 2x on identical binaries. Any cost feature that we gate must be gated on
  DETERMINISTIC counts (allocations, call counts, emitted bytes), never on nanoseconds.

That last one is the real design constraint, and it points at the static directions (6-8)
being the ones that can actually be gated.

## STANDING ITEM — THE FOUNDERS THREAD IS OPEN, NOT DONE (Sean, 2026-08-26)

**Sean's convention: this is not a section to be completed and closed. Work other tickets,
then come back every few days and see whether the intervening work has spurred new
insight.** The evidence that this is the right shape is that the best items here did not
come from a planning session -- they came from bouncing an idea back and forth until it
turned into something neither of us started with:

- Sean's `algorithms.sorting.<bigO>.<name>` became **complexity as reflection data**, which
  then became **a static cost diagnostic** -- Knuth's mandate delivered before the program
  runs.
- "does a `List` local get freed?" became a **measured 20x allocation lever**.
- "track auto-scoping in the transform list" became the argument that the transform
  interface is a **prerequisite** for auto-scoping rather than a companion to it.

**Nothing enforces the cadence.** This is a habit, in the same sense that "`--daily` is the
last thing run when overnight work stops" is a habit -- stated so it can be kept, not
automated. When picking it up again, the useful prompt is not "what is left on the list" but
**"what has the last few days' work taught us that changes an item here?"**

### BUG-313's COST: ~17%, and the FIRST measurement of it was wrong (2026-08-26)

**CORRECTED. The first figure published here was 91% and it was an artifact of one noisy
batch.** The honest number is **~17%**, and the correction is the more useful result,
because the method that produced the wrong number looked rigorous.

Measured IN-PROCESS (`tools/bench/index_bench.zbr`): best-of-25 timed rounds inside the program,
5 independent paired runs, `--release --single-threaded`.

| run | checked | unchecked | overhead |
|---|---|---|---|
| 1 | 241 | 200 | 20.5% |
| 2 | 248 | 217 | 14.3% |
| 3 | 264 | 222 | 18.9% |
| 4 | 238 | 209 | 13.9% |
| 5 | 236 | 204 | 15.7% |

**Checked is slower in 5 of 5 pairs, by 14-21%.** The consistent SIGN across independent
pairs is what makes this trustworthy, more than any single ratio.

**WHY THE FIRST MEASUREMENT LIED.** It timed the whole PROCESS and subtracted a
zero-work baseline. That looked careful -- interleaved, minimum-of-10, baseline subtracted --
and still produced 91%, because on an IDLE machine the MINIMUM over 15 rounds moves
517 / 555 / 560 ms for the same binary. Process-level noise alone is ~8%, and one unlucky
batch put the checked build at 784 ms where later runs put it at 503.

**A minimum is only as good as the number of samples it is drawn from, and process startup
adds noise that no amount of interleaving removes.** Timing inside the process removes
loader, first-touch and scheduler-entry costs from the sample entirely, and makes rounds
cheap enough to take a best-of-25 rather than a best-of-10.

**This is a WORST CASE and should be read as one.** The loop does almost nothing except
index; real code does more work per index and will see less. What it bounds is the ceiling,
and the ceiling is high enough to matter against a 30-50%-of-Zig target.

**Three instrument failures on the way to that number, all caught by arithmetic:**

1. **The first benchmark measured process startup.** 0 iterations cost 165 ms; 100
   iterations cost *less* (149 ms, pure noise); 400 cost 208 ms. Fixed overhead was ~10x the
   signal. An early "64% overhead" reading from that setup was measuring nothing.
2. **Doubling the work did not double the time** (100 iters 254 ms, 200 iters 242 ms), which
   is what exposed (1). Iterations were made mutually dependent so nothing could be elided,
   and a 0-iteration build was added as an explicit baseline.
3. **The first mutant differed in TWO ways.** It removed the check *and* changed the cast
   from `@intCast` to `@bitCast`. Those are not the same: `@intCast` tells LLVM the value
   fits the target range, `@bitCast` tells it nothing. The "unchecked" build came out **3.6x
   SLOWER than checked** -- a backwards result that was the mutant's fault, not the
   compiler's. Rebuilt with `@intCast` retained, i.e. exactly the pre-fix emit.

The third is the reusable one: **a mutant that differs in two ways attributes the whole
delta to one of them**, and here the wrong reading was the flattering one (checking is
free!). Same shape as the cooperative-attacker rule, in a benchmark rather than a test.

**WHAT THE NUMBER DECIDES.** Part 2 of the design (an explicitly-unchecked accessor) is
now clearly needed rather than merely tidy, and part 3 (range-`for` elision) moves from
"the nice half" to the one that carries the argument: a hot loop written as
`for i in 0..xs.len` should pay nothing, and today it pays the same ~17% as a hand-managed
index.

**HYPOTHESIS REFUTED BY LOOKING AT THE ASM (2026-08-26).** The natural story was that the
cost is lost VECTORIZATION rather than the branch. It is not. The two inner loops, isolated
by content after two failed attempts to find them by symbol and by loop-span heuristics:

```
unchecked, 6 instructions        checked, 8 instructions
                                 cmp    rax, rbx          <- the bounds check
                                 je     .LBB5_133         <- branch to panic
vmovsd xmm1, [rcx + 8*rdx]       vmovsd xmm2, [rdi + 8*rbx]
vmulsd xmm1, xmm1, [rsi + 8*rdx] vmulsd xmm2, xmm2, [r9 + 8*rbx]
vaddsd xmm0, xmm0, xmm1          vaddsd xmm1, xmm1, xmm2
inc / cmp / jne                  inc / cmp / jne
```

**Both are SCALAR** -- `vmulsd`/`vaddsd`, not `vmulpd`/`vaddpd`. Neither build vectorizes
this loop, so there was no vectorization to lose. The cost is exactly two instructions, one
`cmp` and one conditional branch, added to a six-instruction body: 33% more instructions
producing ~17% more time -- an unremarkable ratio once the number is right, and one that
no longer needs the basic-block split or dependency chain invoked to explain it. (The
earlier text reached for those to explain 91%, which is a reminder that a wrong measurement
recruits plausible mechanisms to justify itself.)

**AND LLVM ALREADY ELIDES HALF OF IT.** The loop performs TWO indexed reads (`row.at(j)`
and `v.at(j)`) and emits only ONE check -- the optimizer hoisted or merged the other,
unprompted, from a hand-managed `while` index.

**That is the strongest argument yet for the elision, and it changes the ordering.** If
LLVM removes one check with no help at all, giving it a provable bound from a range-`for`
should let it remove the rest -- so the elision plausibly recovers the whole ~17%,
automatically, for code already written in the safe form. The unchecked accessor recovers
the same but only where a user opts in, and it hands back the safety.

**Method note worth more than the result: three instruments failed before one worked.**
Symbol lookup failed (`matvec` was inlined and survives only as a reflection string); a
whole-function instruction count was too diluted to say anything (2346 vs 2319); a
"smallest backward jump" heuristic found the integer-to-string formatting loop in one build
and the real loop in the other, and dutifully reported a comparison between them. What
worked was searching for the loop by its CONTENT -- the accumulator pattern
`vaddsd xmm, xmm, xmm` -- and then READING the two bodies instead of counting them.

### THE GAP TO HAND-WRITTEN ZIG: ~18%, MEASURED FOR THE FIRST TIME (2026-08-26)

Sean's stated target is **within 30-50% of hand-written Zig**. Nobody had ever measured it.
The number is **~18%, comfortably inside the target**, and essentially all of it is the
bounds check added by BUG-313.

Identical algorithm, identical work (12000 matvec calls, n=128), identical timing method
(best-of-25 in-process rounds), `--release --single-threaded` / `-OReleaseFast
-fsingle-threaded`, identical checksum (1040.384). Run INTERLEAVED:

| run | Zebra (checked) | Zig (flat slice) | Zig (ArrayList layout) |
|---|---|---|---|
| 1 | 328 | 277 | 288 |
| 2 | 308 | 267 | 275 |
| 3 | 324 | 254 | 256 |
| 4 | 298 | 264 | 285 |

Zebra is slower in **4 of 4** pairs, by 13-28%.

**TWO INDEPENDENT MEASUREMENTS AGREE, which is what makes this trustworthy.** The bounds
check costs ~17% (measured separately, checked vs unchecked). Zebra-checked is ~18% behind
Zig. So **Zebra-unchecked sits at parity with hand-written Zig** -- the codegen itself is
not the gap, the safety check is.

**THE DATA STRUCTURE IS NOT THE GAP EITHER.** Zig using an ArrayList-of-ArrayLists (exactly
what Zebra emits) measures 256-288; Zig using a flat slice measures 254-277. Indistinguishable.
So the emitted representation is not costing anything either -- which is worth knowing before
anyone proposes changing it.

**METHOD NOTE, and it changed the answer.** Run standalone rather than interleaved, the same
binaries suggested PARITY (Zebra 236-264 against Zig 253-256). That reading was flattering
and wrong: the two sets were taken minutes apart under different machine conditions.
Interleaving put Zebra consistently behind. **A favourable result deserves more scrutiny
than an unfavourable one**, and on this machine a comparison that is not interleaved is not
a comparison.

Reference implementation kept at `tools/bench/zig_reference.zig`; the Zebra side is
`tools/bench/index_bench.zbr`.

### THE ELISION: NOT BUILT, and the measurement is why (2026-08-26)

Part 3 of BUG-313's design was to make `for i in 0..xs.len` elide its bounds check, on the
Wirth/Hoare argument that a well-designed `for` lets even a simple compiler prove the index.
**It was not built, and the case for building it now does not survive the numbers.**

| | |
|---|---|
| prize | **~17%** ceiling -- the unchecked build IS the perfectly-elided build for that loop |
| loops it would apply to in the dogfood code | **0** (171 `while`, zero range-`for`) |
| loops in the whole `test/` corpus | 4 |
| what enforces its precondition | **nothing** |

**The precondition problem is the deciding one.** The lowering snapshots the bound before
the loop:

```zig
var i: i64 = 0;
const _stop_i: i64 = @as(i64, @intCast(xs.items.len));   // taken ONCE
while (i < _stop_i) : (i += 1) { s += _zbr_at(xs.items, i); }
```

If the body shrinks the list, `i` outruns the real length and the CHECK is what saves you.
So eliding is sound only when the receiver is not mutated in the body and the loop variable
is not reassigned -- and **nothing independently enforces either**. By the trigger rule
derived earlier the same day, that makes it opt-in at best, and a wrong analysis silently
reintroduces the exact memory-unsafety BUG-313 removed.

**The blocker is ADOPTION, not codegen.** A perfect elision today would speed up four loops
in our corpus and none in the real program. The range-`for` has to be the form people
actually reach for before the optimisation has anything to optimise -- which is a docs and
ergonomics problem, already started in `QUICKSTART` and in tinylm's notes.

**Revisit when:** a real program is written in range-`for` form, or the transform interface
exists (so the elision can ship as a described, disableable transform rather than invisible
codegen), whichever comes first. The measurement to re-take then is the same in-process
paired benchmark; the tooling for it is `tools/bench/index_bench.zbr`.

**Worth recording as a positive result:** LLVM already elides one of the two checks in the
hand-written `while` loop, unprompted. Whatever we build should be measured against that
baseline rather than against "no elision at all", because a chunk of the available win is
already being taken automatically.

### RUN EVERY GATE RED ONCE, AND READ WHAT IT SAYS (2026-08-26)

`gate_selfcheck` and `tier_selfcheck` prove a gate CAN fail. That is not the same as
reading what it says WHEN it fails -- and the failure output is simultaneously the part
most likely to be wrong and the part least likely to be seen.

**Receipt, found within minutes of writing this down.** Falsifying the new BUG-313 legs
against a real attacker (a compiler rebuilt with the check stripped from `_zbr_at`) made
`release_mode_check` print:

```
   FAIL   index past the end was NOT refused in --release
   FAIL   negative index was NOT refused in --release
release-mode: 1 check(s) FAILED
```

Two failures, reported as one. `fail=1` was a FLAG being printed as a COUNT, in all eight
of that gate's failure paths -- so it had reported "1 check(s) FAILED" for its entire
existence regardless of how many checks failed. **No green run could ever have shown this.**
Fixed to a real counter and verified in both directions (2 against the mutant, silent when
clean).

**The shape generalises.** Everything a gate checks about itself -- a sentinel, a panic
text, a count, a refusal message -- lives on the failure path. `contract_mode_check`
classifies on a printed sentinel rather than exit code for exactly this reason (a build
failure also exits non-zero); `output_sweep` prints its transient count even when zero.
A gate whose PASS line is honest and whose FAIL line is not is half-instrumented, and the
half that is broken is the half you consult under pressure.

**The practice:** when adding or touching a gate, break it deliberately once and *read the
output*, not just the exit code. Ask the same question the instrument-discipline rules ask
of a clean result -- "what would make this print the wrong thing?" -- of the red one.

### THE TRIGGER RULE, derived 2026-08-26 — when may a transform fire automatically?

Sean proposed detecting statically that a program never threads, and applying
`--single-threaded` inherently. That is safe, and the reason it is safe generalises into the
rule the transform interface needs for its `trigger` field:

> **A transform may fire AUTOMATICALLY when its precondition is INDEPENDENTLY ENFORCED.
> Otherwise it must be opt-in.**

| transform | precondition | independently enforced? | trigger |
|---|---|---|---|
| infer `--single-threaded` | no thread spawn reachable | **yes** — the flag already makes a spawn a COMPILE ERROR, so a wrong analysis fails the build rather than miscompiling | automatic |
| automatic arena scoping | no allocation outlives the call | **no** — a wrong escape analysis frees live memory, in release, silently | opt-in, until escape analysis has its own verifier |

Two transforms of the same shape with opposite safety profiles, separated by a criterion
rather than by taste. It also gives a research direction for anything we *want* automatic:
find the independent enforcement first, and the transform becomes safe by construction.

### TRANSFORM PROVENANCE — intrinsic vs third-party (Sean, 2026-08-26)

When a miscompile is reported, the first question is **which transform produced this**, and
whether it was ours determines who owns the defect. So:

- `metadata` carries an **origin** (intrinsic / plugin name + version).
- A diagnostic arising from transformed code should be able to **name the transform that
  touched it**.
- Plugins are **added and removed explicitly**, not picked up by directory scanning. A
  plugin present-but-undeclared is invisible at exactly the moment it matters -- the same
  argument `corpus_ls.sh` makes about untracked files, and `registration_check` about
  unasserted ones.

## POST-0.9, PRE-1.0 — BRAINSTORM: WHAT THE FOUNDERS ACTUALLY RECOMMENDED (Sean, 2026-08-26)

Sean's: mine the foundational SE literature for things worth *employing*, not quoting. The
companion to the Knuth item above, and the reason it is worth doing is not reverence — it is
that **several of these were arrived at here independently**, which is decent evidence the
ideas are load-bearing rather than decorative. Where that has happened it is noted, because
"we already do this" is the most useful entry in a list like this.

### Already here, arrived at independently

| idea | who | where it lives in Zebra |
|---|---|---|
| Design by Contract | Meyer (Eiffel) | `require`/`ensure`/`invariant`, gated by `contract_mode_check` |
| Null tracking as a language property | Hoare's "billion-dollar mistake" | nil tracking, `if x != nil` narrowing |
| Guarded commands must be exhaustive | Dijkstra | `branch` exhaustiveness — default-on since the §28 review |
| CSP | Hoare | `Chan(T)` + `sys.go` |
| Pipelines / do one thing well | McIlroy | the `->` pipeline operator |
| Removing features is progress | Wirth (Oberon) | `lint_reserved_words` — seven keywords freed so far |
| Programming as theory building | Naur | this repo's habit of recording WHY, not just what |

That last row is the one worth sitting with. Naur's claim is that a program IS the theory in
the builders' heads, and that documentation cannot fully carry it — which is precisely why
this repo's comments record *the failure that motivated the code* rather than restating the
code. It was not adopted from Naur; it was rediscovered by getting burned.

### Candidates worth arguing about

*Dijkstra*
1. **`branch` with no matching guard should be a defined outcome, not a fall-through.** In
   guarded commands, "no guard true" is an ERROR — a named one. Worth checking what Zebra
   does today (see BUG-288 / the exhaustiveness diagnostics, which cannot currently say
   WHERE).
2. **Weakest-precondition reasoning as the semantics under `require`/`ensure`.** Zebra
   inherited contracts from Eiffel's ergonomics; wp is the theory that makes them composable.
   Would inform what `ensure` may legally refer to.
3. "The competent programmer is fully aware of the limited size of his own skull" — the
   argument for the move-checking-inward programme already in this file.

*Meyer, beyond contracts*
4. **Command-Query Separation as a lint**: a method either changes state or returns a value,
   never both. Mechanically checkable, and Zebra already knows which methods mutate (it uses
   that for `const` vs `var` emission).
5. **Uniform Access**: a field and a zero-argument method should be indistinguishable at the
   call site. Affects whether `x.size` and `x.size()` should both work.

*Parnas*
6. **Information hiding as the module criterion** — decompose by "what is likely to change",
   not by execution order. A lens for the `selfhost/` module split.
7. **"A rational design process and how to fake it"**: documentation written as though the
   design were derived cleanly, even though it never is. This repo does the opposite
   (records the mess) and that is a deliberate disagreement worth stating rather than
   drifting into.

*Knuth, beyond the profiling quote*
8. Literate programming — the inverse of `doc_example_check`, which already asserts the
   docs' code is real. The remaining half is code that carries its prose.

*Brooks*
9. **Essential vs accidental complexity as a feature-acceptance test** for 1.0: does this
   feature remove essential complexity from users, or only accidental complexity we created?
10. **The second-system effect** as an explicit hazard for 1.0 scope.

*Lamport*
11. A written specification of the concurrency model (threads, `Chan`, `Atomic`, the two-tier
    allocator). Zebra has the primitives and no stated memory model.

### DRAFT: A WRITTEN SYSTEM CONCEPT — Sean's to accept, rewrite or reject

Wirth's test for a feature is not "is it useful" but "is it compatible with the original
system concept", and his claim is that the incompatibility usually *passes unrecognized*
rather than being argued and lost. That test needs something to test against, and Zebra has
never written one down. **This is a DRAFT proposed by Claude, not a decision** -- the
identity of the language is Sean's call. It is offered because a concept nobody has written
cannot adjudicate anything, and the 0.9 docket is exactly where it would be used.

The test of a good concept is not that it sounds nice but that **it settles arguments**. The
candidate below is checked against real open questions at the end.

---

> **Zebra is a high-level language that does not make you choose between saying what you
> mean and knowing what it costs.**
>
> Three commitments follow, in priority order:
>
> **1. Safety is not optional at run time.** Where the compiler can prove a check
> unnecessary it removes it. Where it cannot, the check stays, and there is no switch to
> turn it off. (Hoare 1981: his users, offered exactly that switch, refused it.)
>
> **2. The compiler says what it did.** Any transformation applied to a program is
> describable in Zebra itself, and queryable. A transformation that cannot describe itself
> does not ship. (Hoare via Knuth 1974.)
>
> **3. Cost is legible before the program runs.** The language does not hide asymptotics or
> allocation behind convenient syntax, and the compiler reports what parts of a program cost
> the most without being asked. (Knuth 1974; Lampson 1983 on abstractions whose cost only a
> "lively awareness" avoids.)
>
> The performance claim that makes (1) affordable: **within 30-50% of hand-written Zig**,
> measured, not asserted. As of 2026-08-26 the measured gap on numeric array code is ~18%.

---

**Does it adjudicate? Checked against questions actually open today:**

| question | the concept's answer |
|---|---|
| build an unchecked `.atUnchecked()` accessor? | **No** -- violates (1). This is the answer Hoare's users gave. |
| automatic arena scoping? | **Only after the transform interface** -- (2) forbids invisible transformation, and this one frees live memory when wrong. |
| infer `--single-threaded` automatically? | **Yes** -- (2) is satisfied because the precondition is independently enforced (a spawn becomes a compile error). |
| complexity in the import path vs reflection data? | **Reflection** -- (3) wants cost legible, and (2) wants it queryable rather than encoded in a name that then cannot change. |
| retire the imgui backend? | **Yes** -- carries no commitment; three backends for one job is the "bells and whistles" Wirth names. |
| keep `.at()` bounds-checked by default at ~17%? | **Yes** -- (1) is first in priority order precisely so this is not re-argued each time it is measured. |

Six questions, six answers, and none of them "it depends". That is the property worth
keeping if the wording changes.

**What it deliberately does NOT claim:** that Zebra is fast, small, simple, or general.
Those are consequences or trade-offs, not the concept, and a concept that claims everything
adjudicates nothing.

### PRIMARY SOURCES, NIGHT OF 2026-08-26 — and they settle BUG-313 part 2

Two more papers read in full rather than quoted from memory. Both turned out to be about
work done the same day, which is either a good sign about the choice of papers or a bad one
about the novelty of our mistakes.

#### Hoare, *The Emperor's Old Clothes* (Turing lecture, CACM 24(2), 1981)

**On bounds checking, and it is about us:**

> "…every occurrence of every subscript of every subscripted variable was on every occasion
> checked at run time against both the upper and the lower declared bounds of the array.
> Many years later we asked our customers whether they wished us to provide an option to
> switch off these checks in the interests of efficiency on production runs. **Unanimously,
> they urged us not to** — they already knew how frequently subscript errors occur on
> production runs where failure to detect them could be disastrous. **I note with fear and
> horror that even in 1980, language designers and users have not learned this lesson. In
> any respectable branch of engineering, failure to observe such elementary precautions
> would have long been against the law.**"

Zebra shipped precisely the option his customers refused: checks present in debug, absent in
`--release`. BUG-313, described in 1981.

**THIS SETTLES PART 2 OF BUG-313's DESIGN: do not build the unchecked accessor.**

There is an apparent conflict between the two founders, and resolving it is the useful part.
Knuth (1974, citing Wirth and Hoare) says range checking "should be used far more often than
it currently is, **but not everywhere**". Hoare's users, offered exactly that escape hatch,
refused it. The two are reconcilable and the reconciliation is the design:

| | whose job |
|---|---|
| **Elide where the bound is PROVABLE** | the compiler's -- Knuth's "not everywhere", and the elision item |
| **Offer a user-facing off switch** | nobody's -- Hoare's users refused it, and the temptation is the point |

A check the compiler proves unnecessary costs nothing and gives up nothing. A switch the
programmer flips gives up safety at exactly the moment they are most confident and least
correct. **We now know the price of that safety: ~17%, and it is the entire gap to
hand-written Zig.** That is the number to defend, not to escape.

**On approaching a release, which is where Zebra is:**

> "When any new language design project is nearing completion, there is always a mad rush to
> get new features added before standardization. The rush is mad indeed, because it leads
> into a trap from which there is no escape. **A feature which is omitted can always be added
> later, when its design and its implications are well understood. A feature which is
> included before it is fully understood can never be removed later.**"

Read against this file's own 0.9 docket, that is a warning with our name on it. It also
gives the `reserved-words` gate a pedigree: seven keywords have been REMOVED, and Hoare's
point is that removal is the operation you will not get to perform later.

The lecture closes on a parable whose master tailor advises **removing layers** rather than
adding embroidery, and is dismissed as out of touch for it. That is the size-budget item, in
1981, as a bedtime story.

#### Wirth, *A Plea for Lean Software* (IEEE Computer, 1995)

**On why software grows**, he cites two laws and then names the mechanism:

> "Software expands to fill the available memory." (Parkinson)
> "Software is getting slower more rapidly than hardware becomes faster." (Reiser)

> "A primary cause of complexity is that software vendors **uncritically adopt almost any
> feature that users want**. Any incompatibility with the original system concept is either
> ignored or passes unrecognized…"

> "Increasingly, people seem to **misinterpret complexity as sophistication**, which is
> baffling — the incomprehensible should cause suspicion."

> "To reduce software complexity by concentrating only on the essentials is a proposal
> **swiftly dismissed as ridiculous** in view of customers' love for bells and whistles. When
> 'everything goes' is the modus operandi, **methodologies and disciplines are the first
> casualties**."

**THE PHRASE THAT IS ACTIONABLE IS "the original system concept".** Wirth's test for a
feature is not "is it useful" but "is it compatible with the concept the system was built
on" -- and his claim is that the incompatibility usually "passes unrecognized" rather than
being argued and lost. **Zebra has no written system concept.** Without one, that test cannot
be applied, and every feature request is evaluated on its own merits, which is exactly the
ratchet he describes. Writing one -- a paragraph, not a manifesto -- would make the 0.9
docket answerable rather than a matter of taste. It also pairs with Hoare's warning about
the mad rush before standardization: the concept is what a rushed feature is measured
against.

**On the size budget, a precedent with a number.** Oberon -- a complete operating system
*and* compiler, with storage management, a file system, a window display manager, a network
with servers, and a document editor -- was "designed and implemented by two people within
three years". That is the existence proof behind the size-budget item; the budget is not
asceticism, it is a claim that the whole thing stays comprehensible.

**And a rationale for Zebra's own typing discipline**, in his pull-quote:

> "ABSTRACTION WORKS ONLY WITH LANGUAGES THAT POSTULATE STRICT TYPING OF VARIABLES AND
> FUNCTIONS. IN THIS RESPECT, C FAILS."

Zebra postulates strict typing, nil tracking and contracts, and emits into a language that
also has them. On Wirth's argument that is not incidental -- it is the precondition for the
abstraction boundaries the rest of these items depend on.

#### Parnas, *On the Criteria To Be Used in Decomposing Systems into Modules* (CACM, 1972)

**His criterion is not "split by phase", it is the opposite of that**, and he names our
decomposition as the anti-pattern:

> "In the first decomposition the criterion used was **to make each major step in the
> processing a module**. One might say that to get the first decomposition one **makes a
> flowchart**. This is the most common approach to decomposition or modularization. It is an
> outgrowth of all programmer training… The flowchart was a useful abstraction for systems
> with on the order of 5,000-10,000 instructions, but as we move beyond that it does not
> appear to be sufficient."

The criterion he proposes instead is that "each module hides some design decision from the
rest of the system", and his first specific rule is:

> "A data structure, its internal linkings, accessing procedures and modifying procedures
> are part of a **single module**. They are **not shared by many modules** as is
> conventionally done."

**ZEBRA'S SELFHOST IS THE FIRST DECOMPOSITION.** Lexer -> Parser -> AstBuilder -> Resolver ->
TypeChecker -> CodeGen is a flowchart, and `Ast` is a data structure shared by everything.
Measured: **899 pattern-match sites on Ast variants across five modules** (CodeGen 334,
CgHelpers 280, TypeChecker 192, Checker 68, AstWalk 25).

**And it predicts our defect classes, which is what makes this more than a taxonomy:**

| what we have | Parnas's account of it |
|---|---|
| `lint_expr_walkers` exists at all | a GATE armoring a seam that information hiding would have removed |
| BUG-267, BUG-260 -- walker drift | an Ast variant added; some traversers updated, others not, because no module owns it |
| BUG-293 / BUG-294 -- seeding failures | a registry populated in one pipeline stage and consumed in another |
| BUG-306 -- `inferExpr` cannot see module-scope decls | the same structure, from the other side |

**NOT A PROPOSAL TO RESTRUCTURE THE COMPILER.** The pipeline decomposition has real virtues
here -- it matches how compilation is taught, it makes the round-trip gate expressible, and
899 call sites is not a refactor anyone should start on a whim. Recorded because it explains
a recurring class rather than treating each instance as a surprise, and because it gives a
criterion for boundaries we have NOT yet drawn.

**IT ALSO VALIDATES THE TRANSFORM-INTERFACE-AS-PLUGIN-BOUNDARY, on Parnas's own terms.**
Sean proposed the transform interface as the extension point. Parnas's test is whether a
boundary corresponds to **a design decision likely to change**:

- a `transform` (match / rewrite / metadata / trigger) IS such a decision -- which
  transformations exist, and when they fire, is exactly what varies between versions and
  between third parties;
- a "plugin per compiler phase" would be the flowchart decomposition again, and would freeze
  the seam where our defects already cluster.

So the earlier recommendation -- adopt the size budget, defer the plugin architecture, and
if modularity is needed put the boundary at the transform -- turns out to be Parnas's
criterion rather than a hunch. Good; a hunch that survives contact with the source is worth
more than one that does not.

#### Lampson, *Hints for Computer System Design* (1983)

**The single most on-point sentence found tonight:**

> "The interface must not promise **more than the implementer knows how to deliver**."

That is BUG-313 exactly -- QUICKSTART promised `.at()` was "bounds-checked", the
implementation delivered it only in debug -- and it is stated as a general design rule
forty-three years ago. Worth adopting verbatim as a review question: *does this interface
promise anything the implementation does not deliver in every configuration we ship?*

**On cost visibility, which is the Knuth mandate from the other direction.** On an
over-general design he writes that "it is hard for the programmer to tell what will be fast
and what will be slow", and of an O(n^2) field lookup reached through a convenient
abstraction: "**only a lively awareness of its cost will avoid this disaster**". Knuth argues
the compiler should supply that awareness; Lampson observes what happens when nothing does.
Both land on the complexity-as-reflection-data item.

**Other hints that map onto things here, listed so they are not rediscovered:**

| Lampson | already in Zebra as |
|---|---|
| "Plan to throw one away" | the bootstrap, being retired |
| "Exterminate features" (Thacker) | `lint_reserved_words` |
| "End-to-end" -- application-level checking is what is logically necessary, other checks are for performance | the gate ladder: only `output_sweep`/`smoke_run` RUN anything, and the compile-only gates are the "for performance" ones |
| "Keep basic interfaces stable" / "keep a place to stand" | the 0.9 versioning question |
| "Separate normal and worst case" -- normal must be fast, worst must make progress | not addressed; a lens for the allocator work |

**The end-to-end row is worth pausing on.** Lampson's claim is that intermediate checks are
*not logically necessary* -- they are performance optimisations, because only the end-to-end
check proves anything. Our ladder has independently arrived at the same shape and says so in
its own words: the compile-only gates cannot see a program that compiles and prints the wrong
answer (BUG-226), and `output_sweep` exists because of it. What Lampson adds is the
justification for keeping the cheap intermediate gates anyway: they are not there to prove
correctness, they are there to find failures sooner.

### THE AUDIT THAT CAME OUT OF THIS, and its first receipt (2026-08-26)

Two founders, two questions, in sequence. Run against real dogfood code they found a
shipped memory-safety bug in under an hour, and **neither question alone would have found
it**:

**1. Knuth — what do REAL programs do that our tests do not?**
`tools/construct_histogram.py <dir>` diffs the construct distribution of a real program
against `test/`. On 1116 lines of neural-network Zebra (`C:/Projects/tinylm`):

| construct | real, per 1k lines | corpus | ratio |
|---|---|---|---|
| `float` | 331.5 | 3.6 | **92x** |
| `while` | 152.3 | 4.0 | **38x** |

and the combination is starker than either number: files exercising float + `.at()` +
`while` together are **6 of 6** real files against **0 of 522** corpus files (the one
apparent corpus match is `tc_types.zbr`, where "float" is the enum variant name `float_`).

**2. Hoare — what did the COMPILER DO to that code?**
`.at(j)` lowers to `row.items[@intCast(j)]`: raw slice indexing. Zig checks that in Debug
and ReleaseSafe and **not** in ReleaseFast, which is what `--release` passes. Measured both
ways: a 2-element list read at index 2 panics in debug and, in `--release`, returns `0` and
carries on. **BUG-313.**

**WHY THE PAIR IS THE POINT.** The histogram alone says "`.at()` is popular" -- not a
finding. The transformation audit alone, run against our own corpus, shows the identical
lowering on code that barely indexes anything and looks unremarkable. The defect lives in
the intersection: *a construct we do not test, examined for what the compiler silently does
to it.* Knuth's empiricism aimed by Hoare's criterion.

Neither is a gate and neither should be. They are an **audit** — run against each new real
program, because each one is a fresh sample of the distribution users actually write.

### THE DIJKSTRA READING, which changes what BUG-313's fix should be

The dogfood code contains **171 `while` loops**, 35 of them the exact `while i < n` /
`i += 1` shape, every one hand-managing an index.

Zebra already has the safe form. Verified: `for i in 0..xs.len` compiles and runs with a
**runtime** bound, and nests with runtime bounds at both levels. The language is not
missing the construct; the construct is not being reached for. `QUICKSTART` demonstrates
`for i in 0..10` only with a **literal**, which is plausibly why.

That is Dijkstra's argument in one observation: **a structured construct eliminates an
error class that discipline can only mitigate.** Every hand-rolled index loop is an
opportunity for the off-by-one that BUG-313 turns from a trap into a silent fabricated
value. Bounds-checking `.at()` makes that failure *loud*; a range-`for` makes it
*impossible*.

So BUG-313's fix is two-sided, and the second half is cheaper than the first:
- **check the index** (the filed fix), and
- **make the safe loop the obvious one** -- document `for i in 0..list.len` with a runtime
  bound, next to the indexing section, where someone writing a numeric loop is already
  looking. UNGIT: the safer path should be the one you find first.

### THE RANGE-CHECK RESOLUTION — the paper already answered BUG-313 (p.271)

Reading past the famous quote found the answer to the question BUG-313 poses. Discussing
bounds checks, Knuth writes:

> "Wirth [94] and Hoare [39] have pointed out that **a well-designed `for` statement can
> permit even a rather simple-minded compiler to avoid most range checks within loops.**
>
> I believe that range checking **should be used far more often than it currently is, but
> not everywhere.**"

**This dissolves the tradeoff BUG-313 was filed with.** That entry frames it as a choice --
check every `.at()` and pay a compare-and-branch, or stay fast and unsafe. It is not a
choice; it is three parts:

| | Knuth's phrasing |
|---|---|
| `.at()` checked by default | "far more often than it currently is" |
| an explicitly-unchecked accessor for hot paths | "but not everywhere" |
| **`for i in 0..xs.len` ELIDES the check** | a well-designed `for` lets the compiler prove the bound |

The third line is the prize and it is the one nobody proposed: **the safe form becomes the
fast form.** A hand-managed index cannot be proved in range, so it must be checked; a range
`for` can be. The dogfood code's 171 hand-rolled `while` loops would therefore pay for
checks that the range-`for` would not need. So "make the safe loop obvious" is not merely
ergonomics -- it is what makes checking affordable enough to leave on.

Attribution correction: this was recorded here first as "the Dijkstra reading". It is
**Wirth and Hoare's**, cited by Knuth.

### THE ORACLE ARGUMENT FOR AN `algorithms` NAMESPACE (Sean, 2026-08-26)

Sean's proposal: a stdlib `algorithms` namespace implementing the major classes from *The
Art of Computer Programming*, as a dogfooding exercise that stresses the language outside
compiler work.

The obvious virtues are real -- TAOCP is array- and numeric-heavy, which is precisely the
coverage gap `construct_histogram` measured; and it exercises the language somewhere other
than its own implementation. **But the strongest argument is a different one.**

**IT GIVES US AN ORACLE WE DO NOT CONTROL.** Every test in this repository asserts what
*we* decided is correct. That is why `boundary_check` is singular: its expectations were
written from the language reference BEFORE the compiler was run, so it can find something
that was wrong on day one. Everything else is a golden baseline and can only find drift.

TAOCP algorithms have externally-defined correct behaviour, published invariants, and
worked examples. A wrong answer is *definitively* wrong rather than wrong-by-our-own-
declaration. That is `boundary_check`'s property, available at scale, from a source with no
stake in our compiler. **Volume 2's random-number generators are the sharpest case: they
come with exact expected outputs, and there is no arguing with them.**

Secondary: TAOCP algorithms are specified with loop invariants, which is Meyer's
`require`/`ensure` territory and would be the first serious exercise of Zebra's contracts
outside the compiler.

### COMPLEXITY AS REFLECTION DATA, AND THE STATIC COST DIAGNOSTIC

Sean's first shape was `algorithms.sorting.<bigO>.<name>` -- put the cost in the import
path so it is visible where the programmer already is. **The instinct is right and is
exactly Knuth's mandate moved EARLIER than he moved it**; the mechanism has problems:

- complexity is not one number (quicksort: n log n average, n^2 worst -- which goes in the
  path?), and space complexity is a second axis;
- it makes a *property* into an *identity*, so improving an implementation changes its
  import path and breaks callers.

So keep the instinct and change the mechanism -- identity in the path, cost in the
reflection data, which is the substrate already proposed above for the Hoare criterion:

```
algorithms.sorting.quick          # identity
Reflect.complexity(quick)         # { best, average, worst, space }
```

**AND THEN IT COMPOSES INTO SOMETHING NEITHER OF US STARTED WITH.** If complexity is
queryable metadata and the compiler already has the call graph, then *a quadratic sort
called inside a linear loop is a compile-time diagnostic*. That is "tell the programmer
what parts of their program are costing the most" delivered **statically** -- before the
program runs, with no profiler, no instrumentation, and no measurement infrastructure to
keep honest. It is also deterministic, which means unlike anything timing-based it could
actually be GATED (this repo's timings swing 2x on identical binaries).

The `algorithms` namespace is what would make it real: the first body of code carrying
honest complexity annotations to reason over.

### MEMORY: dead locals are NEVER reclaimed, and `allocate Arena()` is the lever (measured 2026-08-26)

Sean asked, while chasing the NN performance gap, whether a `List` local is freed when its
function returns, and proposed per-type allocators to control fragmentation. Measured:

`_prog_alloc()` returns `_arena.allocator()` -- a single **program-lifetime arena**. The
only `deinit` in an emitted program is `defer _zbr_rt._arena.deinit()` at the end of `main`.
So **nothing is ever freed until the process exits.**

| 200 calls x 20000 floats, all locals dead on return | arena bytes |
|---|---|
| plain calls | **37,170,786** |
| each iteration wrapped in `allocate Arena()` | **1,790,872** |

200 x 20000 x 8 = 32 MB, so essentially 100% of the allocation is retained in the first
case. The scoped form reclaims, 20x.

**THIS REFRAMES THE PER-TYPE-ALLOCATOR IDEA.** Partitioning by type controls fragmentation;
Zebra has no fragmentation, because it never frees. The lever is **scope**, not partition.
And note §28j is about the allocator's THREAD-SAFETY, not reclamation -- the planned
two-tier design is per-thread arenas, which are still arenas.

**Actionable now:** wrap each training iteration in `allocate Arena()`, with `<<-` copy-out
for values that must survive (weights, gradients). The likely dominant cost in a long
training run is not arithmetic but an ever-growing working set destroying cache locality.

**Worth investigating (not yet measured):** whether the compiler could place an
`allocate` scope automatically where escape analysis proves no allocation outlives the
call. That is the Hoare criterion again -- a transformation the compiler is positioned to
make and the user cannot see.

### THE TRANSFORM INTERFACE (Sean's design, 2026-08-26)

Sean proposed wrapping each compiler transformation in an interface: the code shape to
match, the code to generate, the metadata for reflection, and the transform command.
**Agreed, with names:** `match` / `rewrite` / `metadata` / `trigger`.

The reason to insist on it is not tidiness. **A transform that cannot describe itself cannot
be listed, cannot be disabled, and cannot be tested.** Today's five known transformations
(TCO-wrapping, `^T` auto-boxing, const-vs-var from mutation analysis, temp materialization,
`throws` auto-propagation) are ad-hoc code in CodeGen, which is exactly why nobody can
enumerate them and why the TCO fall-through hazard needed a lint rather than a diagnostic.

**Opt-in reporting is right** (automated workflows must not have to parse new output), with
one refinement: the *list of applicable transforms* should stay queryable even when the
*report* is off. "What could have happened here?" is then answerable at zero cost.

### RUN SPEED AS A DESIGN CONSTRAINT, with a number (Sean, 2026-08-26)

Sean's target: **within 30-50% of hand-written Zig**, alongside compile speed (cf. V and
FRED using TCC, where fast iteration is a headline feature). Current dogfood evidence: ~8x
faster than Python, not close to Zig.

The value of the number is that it is unambiguous -- "minimal performance cost" is not
falsifiable and 30-50% is. It also needs a benchmark corpus that is NOT the compiler, which
is what the `algorithms` namespace would provide.

First suspects from today's measurement, in order: (1) allocation retention, above -- and
it is testable immediately by re-running a dogfood benchmark inside an `allocate` scope;
(2) `.at()` bounds behaviour once BUG-313 is fixed, where the range-`for` elision matters;
(3) whether hand-rolled index loops defeat optimisations a range-`for` would enable.

### A WARNING TIER, which several of these items need (Sean, 2026-08-26)

Zebra has no warnings today: everything is an error or silence. The complexity budget wants
to be a warning class with `--warnings-as-errors` for those who want the tighter contract.
So do cost diagnostics, transformation notices, and any future advisory. **Building the tier
once unblocks all of them**; adding each as a bespoke flag does not.

### ITERATORS / GENERATORS — a real gap, with a real receipt

`yield` was removed and nothing replaced it. Sean's case: parsing a large string with
`.split()`, forced to materialise a full `List(str)` to walk it once; writing a custom
lazy splitter in .NET cut RAM pressure **and** increased speed.

That is the Perlis test failing -- materialising a list you will walk once and discard is
attention to the irrelevant. Liskov's CLU had iterators for exactly this. Reopen with the
dogfood evidence rather than in the abstract.

### THE WRITTEN MEMORY MODEL — what it would actually contain

Not formality: today these answers exist only as folklore plus one hazard test, so nobody
can reason about a concurrent Zebra program without reading the runtime. Roughly two pages
answering:

- what does `sys.go` guarantee about writes made **before** the spawn?
- is `Atomic` sequentially consistent, or acquire/release?
- what edge does a `Chan` send/receive establish?
- may an `allocate Arena()` scope cross a thread boundary? (**Today: no** -- 77% crash,
  captured by `arena_concurrency_hazard_test`, and the rule "allocate-scopes are
  single-threaded-only" lives in a NEXT_STEPS bullet rather than in the language docs.)
- what does sharing a `List` across threads guarantee? (Today: nothing, unstated.)

### PARNAS TABLES — a worked example, not a description

Parnas's argument: for a function whose behaviour splits into cases, prose and nested `if`s
both hide whether the cases are **complete** and **disjoint**. A table makes both
mechanically checkable.

Zebra's `File.delete` after BUG-307/308 is a live example:

| condition | result |
|---|---|
| file exists, delete succeeds | returns; file is gone |
| file absent (`FileNotFound`) | returns; treated as success |
| any other error (lock, `IsDir`, `AccessDenied`) | **panics**, naming path and error |

Reading it as a table immediately exposes what prose did not: the third row is why a retry
loop around `delete` was unreachable (BUG-308), and the second row is why `deleteScratch`'s
one tolerated error was the one that could not occur on its path. **Both defects are visible
in the table and were invisible in the code for months.**

The tooling claim is that such a table can be checked: rows exhaustive over the error set,
rows mutually exclusive, and every row exercised by a fixture. `contract_mode_check` already
does this informally -- its four-way `--release` x `--turbo` matrix IS a Parnas table, and
the entry says the asymmetric cells are the point. Worth naming the pattern and reusing it.

### KNUTH'S TRIP TEST — the highest-yield tool on this list

TeX has `trip` and METAFONT has `trap`: single, deliberately fiendish programs exercising
every feature IN COMBINATION, with byte-pinned output. Knuth credits them for TeX's
convergence to near-zero defects.

**This is the direct answer to what `construct_histogram` measured.** Our 522 tests each
exercise one thing, and ZERO combine float + `.at()` + `while`. Isolated tests are
structurally incapable of finding interaction defects. `trip.zbr` would be the corpus's
opposite by design: generics inside contracts inside `branch` arms inside TCO'd recursion,
output pinned byte-for-byte.

It also fixes a defect that adding more files cannot: every test we write is shaped by what
we already believe matters.

### AUTOMATIC ARENA SCOPING — and why it makes the transform interface a PREREQUISITE

Sean's proposal: place an `allocate Arena()` scope automatically where a function's
allocations provably do not outlive the call. Sean also noted, correctly, that it would
have to be tracked in the transform list -- and that instinct is load-bearing rather than
tidy-minded.

**This transformation is DANGEROUS if the escape analysis is wrong.** A value the compiler
wrongly proves does not escape is freed while still referenced: use-after-free, in release,
silently. Compare BUG-313, where the failure at least announces itself as a wrong number;
this one hands out reclaimed memory.

So being listable, queryable and disableable is a **safety requirement**, not documentation.
This transformation cannot ship as invisible compiler magic, which makes the transform
interface a **prerequisite** for it rather than a companion to it. Sequence: interface
first, auto-scoping second.

Related lever, measured 2026-08-26 and available today with no compiler work: in a
multi-threaded build EVERY allocation takes a mutex (`_TsAlloc` wraps the shared arena);
`--single-threaded` makes `builtin.single_threaded` comptime-true and the wrapper is
compiled out. For allocation-heavy single-threaded programs that is serialization removed
from the hottest path. (Mechanism confirmed in the emit; the speedup is NOT yet measured.)

### THE TRANSFORM INTERFACE AS THE PLUGIN MECHANISM (Sean, 2026-08-26)

Sean's: let the transform interface BE the extension point, so people other than the core
maintainers can extend the language within its constraints.

**This is better than a general plugin API for a precise reason: it is a CONSTRAINED
extension point.** Anything a plugin can do it does through `match` / `rewrite` /
`metadata` / `trigger` -- so every third-party transform is automatically listable,
disableable and self-describing, because the interface does not permit otherwise.
Extensibility without surrendering the Hoare property. It also sidesteps the objection
recorded above against plugin boundaries inside a compiler: this is not a new seam through
the compiler's internals, it is one narrow, already-necessary interface.

**Design for this early: a wrong user transform is a MISCOMPILE, and it will be blamed on
Zebra.** So the interface likely needs a fifth part beside the four: a **preserved
property** the rewrite declares and that can be checked against real inputs. That is Meyer
applied to a transformation rather than a function -- and Zebra is unusually well placed
for it, since `bootstrap_check`'s round-trip is already a preserved-property test at
whole-compiler scale.

### PARNAS TABLES — ADOPTED (Sean, 2026-08-26)

Adopted on the strength of the `File.delete` worked example above, where a three-row table
makes BUG-307 and BUG-308 visible on inspection after both sat invisible in the code for
months.

Where to apply first: any function with an **error taxonomy** -- most of the `File`,
`Dir` and process surface. The check the table enables is mechanical: rows exhaustive over
the error set, rows mutually exclusive, every row exercised by a fixture.

`contract_mode_check`'s four-way `--release` x `--turbo` matrix is already a Parnas table
built without the name; its own notes say the asymmetric cells are the point, which is
exactly the completeness property a table makes visible.

### SMALLER, RECORDED

- **Version string: `0.9_zig0.16`**, not `0.9_0.16` -- the bare form reads as a four-part
  version, and the Zig version is semantically load-bearing here (BUG-280's keyword list
  already drifted across a Zig bump; `--release` semantics depend on it). It belongs in the
  string because it changes behaviour.
- **Total-size budget: adopt the BUDGET, defer the plugin architecture.** A size ceiling is
  free and forces the conversation at every feature. Modularity is one possible *response*
  to exceeding it, not the mandated one -- and plugin boundaries inside a compiler are
  unusually expensive, because this project's defects cluster at seams (BUG-293/294 were
  both seeding failures across a boundary). Let the budget reveal the fault lines before
  pouring concrete into them.
- **Reward checks: declined for now, on Sean's read** -- a $2.56 cheque is a trophy because
  of who signed it, so the mechanism does not transfer without the stature. Revisit if that
  changes.
- **`BUGS_FIXED.md` wants organising before a public release.** It is already TAOCP-style
  errata treated as a first-class artifact rather than an apology; that is worth keeping
  deliberately and structuring by version once versions exist.
- **Read the primary source before quoting it.** Knuth, Royce and Brooks are all
  systematically misquoted, and this session made the mistake twice in one afternoon: the
  wrong Knuth paper cited from memory (caught by the filename `p261-knuth.pdf`), and the
  range-check argument attributed to Dijkstra when it is Wirth and Hoare's. Same discipline
  as "do not trust the instrument", pointed at literature.

### Smaller observations from the same sample, recorded not filed

- **`continue` appears in NEITHER corpus** -- zero uses across 522 test files and 1116 lines
  of real code. `lint_reserved_words` cannot see this: the word is parsed, just never
  exercised. Either a feature nobody needs or a gap nobody has noticed.
- **A `float` prints without its fractional part**: `7.0` renders as `7` (full precision is
  kept -- `1.0/3.0` gives `0.3333333333333333`). Languages disagree here (JS drops it,
  Python keeps it), so this is a design question rather than a defect, but it makes a float
  and an int indistinguishable in output, which matters when eyeballing tensor values.
- **The six dogfood files should become fixtures.** They compile, they are real, and they
  are the only evidence we hold of the distribution users write. Registering them moves the
  numeric path from *present* to *asserted*.

### The honest filter

Most "founder wisdom" lists are decorative. The test for anything above earning a place:
**does it become a gate, a lint, a diagnostic, or a removed feature?** Items 1, 4, 5 and 9
can. Items 3 and 7 are stances, not mechanisms — worth stating once and not re-litigating.

## Language & compiler direction — 2026-07-28 assessment

Sean asked what would make Zebra a daily driver on technical grounds (ecosystem/user-base
explicitly excluded). Items below are that answer, re-ordered by MEASUREMENT after the first
pass got the cause wrong. **#2 and #4 are flagged DISCUSS-FIRST at Sean's request** — he wants
to weigh strategies before implementation.

### The measurements everything below rests on (don't re-derive these)

| What | Time |
|---|---|
| Zebra front end, hello-world (`--emit-zig`) | **0.057 s** |
| `zig build-exe`, trivial 5-line Zig, LLVM | **5.2 s** |
| `zig build-exe`, Zebra 3,790-line emit, LLVM | 6.2 s |
| `zig build-exe`, trivial Zig, `-fno-llvm -fno-lld` | **0.94 s** |
| `zig build-exe`, Zebra 3,790-line emit, `-fno-llvm -fno-lld` | **1.15 s** |

**The conclusions, which are not what I first claimed:**
- The front end is *excellent* — 57 ms. Latency is entirely downstream of it.
- **Zig's own floor dominates**: ~5.2 s LLVM / ~0.94 s self-hosted, for ANY program.
- The entire 186 KB preamble therefore costs **~1 s on LLVM and ~0.2 s on the fast backend** —
  not the bulk of the time. My first analysis attributed the 5.2 s to the preamble without
  measuring the floor; one probe refuted it. **Preamble work is NOT a latency fix.**
- Therefore *tree-shaking the preamble* (conditional population — Sean's alternative) buys
  ~0.2 s. See the verdict under #1.

### THE ORGANIZING GOAL (agreed with Sean, 2026-07-28): move checking INTO Zebra

The measurement that produced this frame:

| `zebra -c` outcome | time |
|---|---|
| clean program | 0.81 s |
| error only `zig` can see | 1.88 s |
| **error the Zebra front end catches itself** | **0.062 s** |

A check the front end can answer costs **62 milliseconds**, because it never invokes
Zig at all. So the question was never "how do we make checking fast" — it is
**"how much checking can Zebra do itself?"** Every check moved into the front end is
simultaneously ~25x faster, reported against the user's own source instead of
generated Zig, and available to the IDE/LSP without a build.

That reframes three items below as **one project wearing three hats**:

- **#3** (nil-narrowing into the TypeChecker) — makes the TC authoritative about what
  is known, which everything else builds on.
- **#5a** (stdlib arity/signature table) — moves a whole class of silent miscompiles
  (BUG-215) into front-end diagnostics.
- **#4** (what `-c` should promise) — becomes a *consequence* rather than a separate
  design question: the more the front end checks, the more a fast check is a real one.

Related, same direction: BUG-218 (`str + int`) was exactly this move — a mistake that
used to surface as a Zig error about `_str_concat` in a 3,790-line generated file now
resolves in 62 ms against the user's own line, with a caret. That is the template.

**Sequencing:** ~~#5a first, then #3~~ — **#3 landed first** (2026-07-28, `81501dc`), which
makes the TC authoritative about what is known and unblocks the rest. **#5a is next** in this
group (self-contained, immediate user-visible payoff, no dependencies); then revisit #4 with
Sean once the front end's coverage is actually worth promising something about.

### F1 — SPIKE: move stdlib method-name checking out of CodeGen so `-c` can see it (2026-08-17)

**Sean's framing:** *"do we have places that are in the CodeGen that we could push into
the CgHelpers to free up more `-c` functionality?"* Yes, and the largest class is one
shape repeated ~35 times.

**THE MEASUREMENT.** `selfhost/CodeGen.zbr` contains **49** `@compileError` emissions.
About **35** are the identical shape:

    @compileError("selfhost: unknown Path.<method>")
    @compileError("selfhost: unknown File.<method>")
    ... sys, Json, Http, HttpResponse, Ws, Regex, DateTime, Hash, Crypto, Random,
        Terminal, Log, Csv, Timer, Progress, Profile, Base64, Uri, Compress, Mime,
        Tcp, Udp, Sqlite, Net, Gui, Shell, Dir, Reflect, Arg, Build, ...

Each is a **pure name lookup** — namespace + method name, both present in the AST. No
emit context, no inference, no allocator. That is exactly `CgHelpers`' stated contract
("pure analysis passes on the Zebra AST: no I/O, no allocator dependencies").

**WHAT IT COSTS TODAY.** `Path.bogus()` produces a Zig `@compileError` against GENERATED
code. So `zebra -c` exits **0** (front-end only — it never compiles the emitted Zig), and
when the user does hit it the message points at generated Zig rather than at their source
line. That is `tools/frontend_gap.py`'s 23-of-54 gap, and the same UNGIT failure as
BUG-259: the system knows and does not say, where the user is already looking.

**THE PRECEDENT ALREADY EXISTS — this is not a new architecture.**
`selfhost/Resolver.zbr:26` already does `use CgHelpers exposing isStdlibNs`, so a
FRONT-END phase consuming shared AST helpers is proven in-tree. The namespace-level
knowledge is already shared; only the per-namespace METHOD tables are not. It also lines
up with the root cause recorded in the divergence notes: *"Resolver.isBuiltin vs
CodeGen.isStdlibNamespace drift — unify."*

**WHY THIS IS A SPIKE AND NOT A GRIND-THROUGH-35.** Three hazards, in severity order:

1. **Getting a table wrong REFUSES VALID CODE**, which is the expensive direction — a
   false accusation against a correct program, not a miss. If an extracted table omits a
   method CodeGen actually handles, the front end rejects a working call.
2. **A hand-copied table above a default is rule 1b** — "a comment or list enumerating
   what a default applies to is a hand-maintained oracle wearing documentation as a
   disguise", the hazard recorded on `isStringExpr` (BUG-277). Copying 35 lists by hand
   would be minting 35 of them.
3. The method names are woven into `if mname == "..."` CONTROL FLOW inside each
   `genXCall`, so extraction means turning control flow into data, 35 times.

**SO THE SPIKE'S REAL QUESTION IS NOT "can we move it" BUT "can the table be DERIVED
rather than copied?"** — the rule `lint_zig_keywords` (oracle = zig's own tokenizer
table) and `grammar_export --check` (oracle = the Earley rule table) are both built on.
If the table can be derived from the emit branches, the remaining 34 are a mechanical
grind with a real gate behind them. **If it cannot be derived, the honest outcome may be
a LINT that cross-checks the two lists rather than a move** — and that is a legitimate
result of the spike, not a failure of it.

**DO ONE NAMESPACE END TO END.** `Path` is the smallest (see `genPathCall`,
`CodeGen.zbr:~17100`). Deliverable: the front end refuses `Path.bogus()` with a Zebra
diagnostic carrying a source position, `zebra -c` catches it, and the table is derived or
the derivation is proven impossible with the reason written down.

**CONTROL BEFORE BELIEVING IT WORKS:** a probe calling every method `genPathCall` really
does handle must still compile. A spike that only tests the REJECT direction has
confirmed nothing about the 2.-hazard above — that is the negative-control rule
(*"probe a failure and you overestimate the damage; probe a success and you
underestimate it"*).

### UNGIT pass — migrate every SILENT surface into a LOUD one (Fable, 2026-08-08)

Same organizing goal, arrived at from a different door: an UNGIT review of
`QUICKSTART.md` (the design principle: *a tool owes its user the whole truth it
holds, and no more; nothing withheld, nothing fabricated, nothing ambient* —
`wiki/pages/concepts/concept_ungit-principle.md`). The finding is that the
quickstart is *unusually honest* — its §1.5 already splits Python gotchas into
**Loud** (compile error) and **SILENT** (different answer, no warning), tags
each with a BUG number, and one section literally opens *"read this one, it
fails silently."* That honesty is the documentation compensating for language
silence. **The program: move each SILENT row across the line into Loud** — which
is precisely "move checking into Zebra," and BUG-218 (`str + int`) is the
template each item below follows: a mistake that surfaced as a Zig error in
generated code becomes a 62 ms diagnostic against the user's own source.

Distinction held deliberately: some SILENT surprises are *correct design* and
must stay documented, not "fixed" — `-7/2 == -3` (C/Zig truncation, self-
consistent) is not a defect and is out of scope. Ungitting makes *silence*
loud; it does not make a language refuse to have opinions.

- [x] **BUG-292 — `old <parameter>` is REFUSED. DONE 2026-08-17 (`31ff0d0`).** The
  first UNGIT migration of this batch to actually land, and the template holds: a
  silent surface (a post-condition that passes under any implementation of `old`,
  including a broken one) became a 62 ms front-end diagnostic against the user's own
  line, with a caret. `zebra -c` catches it.
  **What it cost was placement, not logic.** The traversal is shared with CodeGen, and
  the plan recorded in BUGS.md said to put it in `CgHelpers` — which closes a cycle,
  because `CgHelpers` imports `TypeChecker`. That surfaced **BUG-295** (an import cycle
  builds clean and yields a compiler that stack-overflows, no diagnostic) and a second
  manifestation of **BUG-294**. It lives in the new `selfhost/AstWalk.zbr`.
  **Two receipts worth carrying into the remaining U-items.** (1) Landing a refusal is
  the cheapest moment to find every document that taught the thing you just refused —
  `doc_example_check` failed with 1 NEW and named `STYLE_GUIDE.md`, a file I had not
  looked at, carrying the same example and the same wrong rationale. Run it
  deliberately after the next one. (2) A refusal needs a POSITIVE control that
  discriminates, or you have only proved the compiler can say no.

- [x] **BUG-294 + BUG-293 — FIXED overnight 2026-08-18** (`8d26aad`, `e7b9679`), both
  FULL tier 30/30 in one invocation. Not UNGIT items themselves, but they came out of
  BUG-292's placement hunt and both share its moral: **the defect was in how a decision
  gets SEEDED, not in the decision.**
  - BUG-294 (`^T` deref) had two manifestations and ONE root — the deref is driven by
    name-keyed side tables, and the loop-variable half was a hardcoded special case for
    `DictEntry.key`/`.value` while the current module's fields were registered as a side
    effect of EMITTING the struct. Fixed by deriving both. The removed special case was
    proven subsumed by the round-trip, not merely deleted.
  - BUG-293 (cross-module container out-param) was a mirror: `fn_param_lists` crossed
    the module boundary under §27b and the BODY did not, so the caller could not tell
    whether to pass `&`. It now travels the same route.
  - **Two pending tripwires fired on their own** when the fixes landed, which is the
    convention working: `bv_hat_deref_loopvar` and `bug293_xmod_container_test` both
    passed by asserting broken behaviour, went red on the fix, and were rewritten to
    assert intent.

- [~] **BUG-295 — import cycles: DIAGNOSTICS LANDED, refusal DEFERRED by decision**
  (`2b18579`, `39bad44`, 2026-08-18). A cycle is reported with its full path and the
  rule stated (*first import wins; the second module sees a PARTIAL view*), and a
  shared module that declares module-level state is named at end of compilation. Both
  fire on real code; the selfhost compiling itself is silent.
  **HELD AT WARNING, deliberately — the reasoning is recorded in BUG-295 and should not
  be re-derived.** Short version: a refusal must be actionable, and *"extract a third
  module"* is not advice a user can take about a VENDORED dependency. Measured: a cycle
  reached via `--module-path` is invisible today (type-scanned, never compiled) while
  one vendored by COPYING INTO THE TREE is detected — so refusal would wall exactly the
  population that cannot fix it. Promoting needs three things together: an escape hatch
  modelled on `--allow-implicit-try` (§28b already solved this shape), a different
  message when the cycle is not yours, and a deliberate answer for the `--module-path`
  blind spot. `MultiCompiler.cycle_is_error` flips the switch in one line and both
  directions are verified, so the decision is cheap to revisit and expensive to get
  wrong.
  **Small, decoupled follow-up:** make a vendored (`--module-path`) cycle WARN, so the
  blind spot is closed without touching the refuse/allow question.

- [ ] **U1 — `for-else` silently DROPS the `else` block** on HashMap /
  string-split / chars iterators (BUG-16; QUICKSTART §26, §27#11). This is the
  sharpest item: not a wrong answer but *code the author wrote, deleted with no
  word* — the worst shape a SILENT surface can take. **Interim fix is cheap and
  should not wait on the real feature:** reject `for-else` on the unsupported
  iterator forms with a front-end error — `error: for-else is not yet supported
  on <chars/split/HashMap> iterators` — pointing at the `else` keyword.
  *Acceptance:* a `for … else` over `.chars()` compiles to that diagnostic, not
  to a binary missing the block. Milestone: 0.9 (a dropped block is a
  correctness hazard, not polish).

- [ ] **U2 — map/filter element type not inferred through a binding** (BUG-17;
  QUICKSTART §10, stated 3×: *"annotate the binding … isn't inferred through the
  binding yet"*). The ambient-knowledge tax: the user must know to write
  `var d: List(int) = xs.map(...)` or silently lose the ability to call List
  methods on `d`. Two honest exits, either acceptable: (a) propagate the
  map/filter result's element type through the binding (the real fix), or (b)
  interim — when a List method is called on an un-annotated map/filter binding
  and inference fails, emit a diagnostic that *names the annotation fix* instead
  of a downstream type error. *Acceptance:* `[1,2,3].map(def(x)=x*2)` bound and
  then `.sort()`-ed either works or errors saying "annotate the binding as
  List(int)". Milestone: 0.x.

- [ ] **U3 — `extern` `int`-size ABI mismatch is silent** (BUG-18; QUICKSTART
  §ABI, *"read this one, it fails silently"*). `extern def f(x: int)` against a C
  `int` links cleanly and corrupts the call (Zebra `int` is 64-bit; C's is 32).
  The front end *knows the declared type* — this is a 62 ms check. **Fix:** a
  front-end lint on `extern def` parameters/returns typed `int` (and `uint`):
  `warning: C 'int' is 32-bit; use int32 for a C ABI boundary`. *Acceptance:*
  an `extern def` with an `int` param warns with the int32 suggestion; using
  `int32` is silent. Milestone: 0.x (cheap, high-value at the FFI boundary Graze
  will lean on).

- [x] **U4 — free the reserved word `aspect`; move AOP (if ever) to `@aspect`**
  — **DONE 2026-08-09.** `aspect` is an ordinary identifier: `var aspect = 1`,
  `def f(aspect: str)` and `var aspect: str` in a class all compile and run.
  Removed `kw_aspect` from both tokenizers, the nine `AspectDecl` /
  `AspectBodyItem` grammar rules, the three nonterminals, the two `TopDecl` /
  `MemberDecl` productions, AstBuilder's three arms, and the six Parser
  acceptance tests — which are replaced by their inverse (the word must now
  reach the parser as a plain `id`). `grammar.txt` regenerated from the rule
  table: 474 → 465 rules, 149 → 146 nonterminals.
  **Two things the removal surfaced.** (1) It also closed a *permanent*
  accept/reject divergence: `AspectDecl` never appears anywhere under
  `selfhost/` in the whole git history, so the bootstrap accepted a construct
  the selfhost had no parse path for — and `fuzz/gramgen.py` derives its
  programs from `grammar.txt`, so it was generating exactly that. (2) It
  orphaned `kw_error`, whose *only* grammar uses were inside the `on error(e)`
  advice clauses. Baselined rather than removed — see below.
  The old construct now gives a clean `unexpected top-level token: 'aspect'`
  instead of the `std.debug.panic` it used to.

- [x] **U4a — the rest of the reserved-word audit** — **DONE 2026-08-09.**
  Sean's call: *"implies I think is the only one to keep. weaves could be turned
  into a decorator so no kw needed there."* **Five freed, three still reserved** —
  and the split is not the one either of us expected.

  | word | was | now |
  |---|---|---|
  | `weaves` | R2 — clause parsed, nothing read it; project-level form panicked | **freed**; `@weaves` if AOP is ever built, matching `@aspect` |
  | `expect`, `lock` | R2 — parsed, then `std.debug.panic("not yet implemented")` | **freed** |
  | `from`, `trace` | R1 — no rule in either compiler | **freed** |
  | `error` | R1 — orphaned when `aspect` took the `on error(e)` clauses | **still reserved** — BUG-280 |
  | `try` | R1 — no construct since §28b replaced it with `expr?` | **still reserved** — BUG-280 |
  | **`implies`** | R1 — sits under *Contracts* | **kept**, on language grounds |

  **Why two of the five you asked for did not ship.** Freeing a word at the tokenizer
  is only half the job: the compiler then has to be able to EMIT it. Measured after
  the change, per word and per position — `error` works as a local and a parameter and
  fails as a **field** (`error: i64 = 0,` in the generated Zig); `try` fails
  everywhere. Both are Zig keywords, and `isZigKeyword` is a hand-maintained list
  missing `try` while the field-declaration path never consults it at all (BUG-280).

  Freeing them anyway would have replaced a clear Zebra diagnostic
  (`expected identifier, got 'try'`) with a Zig parse error against generated code
  carrying no Zebra source location. That is a worse surface, so they wait. The
  Parser tests assert they are STILL rejected, so the tokenizer cannot be freed
  without the emit being fixed first.

  **BUG-280 is a live bug regardless**, which is the part worth acting on: Zebra never
  reserved `align`, `packed`, `opaque`, `volatile`, `threadlocal`, `anyframe` — all Zig
  keywords, all legal Zebra identifiers today. `class C / var align: int = 0` does not
  compile, and has not for as long as the field path has skipped `emitName`.

  **BUG-280 is FIXED in both compilers as of 2026-08-11** (18 emit sites each, not the
  same 18 — see the entry in `BUGS_FIXED.md`), gated by `keyword-ident` in the QUICK
  tier.

  **U4a's TAIL IS CLOSED — `error` and `try` are FREED, 2026-08-13.** Sean's call, after
  the scan corrected a premise: `error` was never a competing error mechanism, it was the
  `on error(e)` **advice clause inside an aspect body**, orphaned when `aspect` went; and
  `try` lost its construct when §28b replaced `try expr` with `expr?`. What survives is
  the method-level `catch |e|` clause, which synthesises `Ast.StmtTryCatch` with no `try`
  token — so `buildStmtTryCatch` in the bootstrap is dead code (flagged in place, not
  deleted). Verified in BOTH compilers, structurally (zero occurrences in `grammar.txt`,
  which is GENERATED from the rule table) and empirically (statement prefix, expression
  prefix, `try`/`catch` block and bare identifier all rejected before the change).
  Nothing planned claims either word: typed error sets (#2) is `throws ParseError`, an
  ordinary identifier, with no `error{...}` syntax.

  **What actually unblocked them was the EMIT, and that is the lesson.** They were held
  back not by the parse but by codegen's inability to spell them, which
  `lint_reserved_words` cannot see — it classified both R1 (unreachable) the whole time.
  BUG-280's field paths plus the `isZigKeyword` oracle (`tools/lint_zig_keywords.py`,
  2026-08-13) closed it. **A word can be R1 in that gate and still be unsafe to free.**

  Proof is `test/bug280_freed_words_test.zbr`, registered with `smoke_run`: both words as
  a local, a parameter, a field, a static field, a class name, a struct name, a method
  name, a static method name, an enum member, a union variant and inside `@derive`
  bodies — all compiling and printing the right values. Deliberately NOT added to
  `keyword_ident_check`'s word list: codegen emits `error` and `try` legitimately as ZIG
  keywords (`return error.ZebraError;`, `try f()` — 56 and 17 bare occurrences in a
  single generated module), so that gate's rule would fire on nearly every program.
  Reserved-words baseline 3 → **1**; only `implies` remains, kept on language grounds.

  Three further emit families were still unescaped in BOTH compilers when this was
  written (`@derive` bodies, the type name itself, a capture read in a lambda body):
  **BUG-281**, now six of seven closed.

  Grammar: 465 → **456 rules**, 146 → **143 nonterminals** — exactly the 9 rules and
  3 nonterminals removed here. `grammar.txt` is regenerated from the rule table.

- [ ] **U4b — delete the vestigial `WeavesOpt` nonterminal (small, and a real hazard)**
  U4a freed `weaves` by deleting the rule `WeavesOpt → kw_weaves TypeRefListNE`
  and **keeping the ε production**, so `WeavesOpt` still occupies a slot in the
  RHS of **14 declaration rules** while always matching empty.

  That was deliberate, and the reason is the interesting part: `src/AstBuilder.zig`
  addresses parse-tree children by **hardcoded index** — `kids[11]`, `kids[9]` —
  with the rule's layout written in a **comment** above each function, e.g.

  ```
  // Non-generic: ModList kw_class id ClassHeader IsClauseOpt HasOpt WeavesOpt eol indent MemberDeclList dedent
  //   indices:   0       1         2  3           4           5      6         7    8      9              10
  ```

  Deleting `WeavesOpt` shifts every index after position 6 in all 14 rules, across
  generic and non-generic variants, checked against nothing but that prose. There
  are 503 `kids[N]` sites in the file. A wrong index does not necessarily fail
  loudly — landing on an adjacent optional (`IsClauseOpt` vs `HasOpt`) yields an
  empty list rather than an error.

  So this is **rule 1b at the scale of a whole file**: a comment enumerating a
  layout, load-bearing, unchecked. The cleanup is worth doing, but it wants its own
  session and probably wants the positional access replaced by a
  find-child-by-nonterminal helper first — which would retire the hazard rather
  than move it. Filed rather than rushed.

  <details><summary>original U4 text, kept for the record</summary>

  (bugbook BUG-10; Sean's call, confirmed by investigation 2026-08-08).
  `kw_aspect` is reserved but the feature does not exist: the bootstrap parses
  `AspectDecl` into a dead node (0 references in `CodeGen.zig` /
  `TypeChecker.zig`), and the selfhost does not parse it at all — `aspect Foo`
  today errors `unexpected top-level token: 'aspect'`. So the keyword's only
  live effect is to *block `aspect` as an identifier*, at real cost: it is the
  collision behind procgen's keyword-rename shield, it cannot be a parameter or
  field name, and it is a real DB column name in the wild (Mosaic's
  `claim_confidence.aspect`). **Fix:** remove `aspect` from the keyword token
  list (same hygiene as the `pro`/`get`/`set`/`body`/`post` removal already
  done); if aspect-oriented programming is ever built, `@aspect` decorator
  syntax (matching `@reflectable`/`@once`/`@profile`) is the modern idiom and
  needs no reserved word. *Acceptance:* `var aspect = 1` and `def f(aspect: str)`
  compile; the AOP grammar production, if kept, is unreachable and can be
  deleted or gated behind `@`. Milestone: 0.x (small, removes a whole friction
  class). **Likely companions:** a quick audit for other reserved-but-
  unimplemented words (`weaves`, `cue`, `vari`?) may free several at once.

  </details>

**Same template, already tracked — fold in when their sections are touched:**
BUG-225 (`s[i]` typed `char` while holding a byte — the type lies about the
value), BUG-227 (`tokenize(seps)` splits on the whole sequence, disagreeing with
its own docs). Both are SILENT rows awaiting the same Loud migration.

Cross-reference for all of the above: bugbook BUG-16/17/18 + BUG-10 (Fable's
tracker, `C:\Projects\bugbook`), filed 2026-08-08.

### ~~FREE WIN — `-c` is excluded from the fast backend~~ — **DONE 2026-07-28 (`3fabc50`)**

`selfhost/main.zbr:2414` read `if not mode_c and not release and …`, so check mode — the
compiler's most latency-sensitive command, and the one `IDE/ZebraIDE.zbr`'s Check button runs —
was **explicitly excluded** from the `-fno-llvm -fno-lld` path and took the slowest available
route. The exclusion turned out not to be load-bearing: the comment's argument (the self-hosted
linker does not error on unresolved C symbols) is about C deps, which the condition already
tests separately, and the compile-failure fallback to the authoritative LLVM path protects the
rest. A check also needs no binary, so it now passes `-fno-emit-bin` and skips linking
entirely — measured as most of the remaining cost. **3.97 s → 0.81 s**, identical diagnostics.

- [~] **#1 — Stop inlining the preamble; ship it as a runtime module. NOW THE DEFAULT (2026-07-28; `--no-runtime-module` opts out) — read `docs/runtime_module_design.md` before touching it.** Emitted programs
  would `@import` a runtime package instead of carrying 3,790 lines of copy-pasted preamble for a
  2-line source. **Re-justified after measurement — this is NOT about speed** (worth ~0.2 s on
  the fast path). It is about three things that are real:
  1. **Error locations.** Errors currently land in generated code (`_str_concat` at line 3779 of
     a file the user never wrote — BUG-215/218). With a ~50-line emitted file there is almost
     nowhere for an error to land except user code.
  2. **Namespace isolation.** Closes BUG-220 *completely*, including the `@export`/`@node_export`
     cases the `_zbr_fn_` prefix cannot cover.
  3. **Artifact comprehensibility** — debugging, DAP, `remapZigErrors`, and anyone reading the
     emitted Zig.

  **Verdict on the tree-shaking alternative** (conditionally populate the preamble by what the
  program uses): *not recommended as a substitute.* It buys ~0.2 s; it requires a call-graph
  reachability analysis over the preamble (whose helpers call each other) that must be
  conservative or it emits undefined identifiers; and — the decisive objection — it makes
  BUG-220-class collisions **input-dependent**: a program compiles until you add a call that
  drags in a preamble chunk containing your function's name. A collision that appears when you
  add an unrelated line is a far worse failure mode than one that is either always present or
  never. Tree-shaking is a reasonable *optimisation* later; it is not the fix for what #1 is for.

  Overlaps `docs/single_file_emit_design.md` but is distinct: that combines *modules*; this stops
  copy-pasting the *runtime*.

  **Spike outcome (do not re-derive):** `@import` shares file-scope state across modules at
  any depth (proven 3 levels deep) — so one shared `_allocator`/`_io` **dissolves BUG-221**
  outright, no fan-out. A real hello-world split cleanly: **3,791 lines → a 30-line user file
  + a 3,770-line runtime module (126×)**. Two constraints found before writing any compiler
  code: (a) `usingnamespace` is **removed in Zig 0.16**, so symbols come in by explicit alias;
  (b) a mutable `var` **cannot be aliased** across modules (`const x = _rt.x` → "unable to
  resolve comptime value"), so the **19 mutable preamble vars must be QUALIFIED** at every
  emit site — that is the main implementation cost, and it is also exactly what makes them
  shared. Plus one backward dependency to break: the preamble's `_initIo` calls
  `_initModuleVars()`, which codegen emits into the *user* file.

  **PHASING (decided 2026-07-28): behind a default-off `--runtime-module` flag**, exactly as
  single-file emission was phased. The reason is more than caution: `bootstrap_check.sh` step 3
  has selfhost-A re-emit into `selfhost/` itself, so an unconditional change would make the
  compiler's own committed `.zig` shape depend on which tool last regenerated it (bootstrap =
  monolithic, selfhost-A = split). A flag the round-trip never passes removes that entirely.
  **Invariant: `bootstrap_check.sh` must never pass `--runtime-module`.**

  - [x] **Step 1 — mark the preamble `pub` (2026-07-28, `f115795`).** 429 declarations (396
    top-level + 33 type members) via `tools/pub_mark_preamble.py`, marked structurally — only
    where every enclosing block is a container, since `pub` on a function-body statement is
    illegal. Inert while the preamble is spliced inline, so it landed alone and was proven by
    the full tier: **7/7 — compile_check 217/0/1, round-trip byte-identical, full_sweep 0
    regressions (333), divergence 0 selfhost gaps.** NOT mirrored into `src/CodeGen.zig`: the
    bootstrap keeps inlining, so it never needs the markings. Still unmarked, and required
    before the flag can cover GUI: `gui_tui_section.zig` (89 decls), `gui_libui_ng_section.zig`
    (102).
  - [x] **Steps 2-6 — the codegen change, LANDED 2026-07-28 behind `--runtime-module`.**
    `zebra --runtime-module` writes `zebra_rt.zig` beside the program and `@import`s it:
    hello-world **3,791 lines -> 27**, and **BUG-221 is dissolved** (the three-module repro
    that segfaults on the default path prints its answer). Qualification runs as a
    quote/comment/field-aware post-pass over the assembled emit — `_allocator` alone is
    written at 135 emit sites, mostly inside larger `w.emit(...)` literals, so one pass that
    cannot miss a site beats 250+ hand edits. The alias set is read back out of the emitted
    text, so codegen needed no new tracking. Off the flag, assembly reproduces the historical
    shape exactly.
    - **The `pub` marking runs in BOTH directions — this is the finding worth keeping.**
      Step 1 marked the runtime `pub` so the program could import it; but the runtime also
      calls back INTO the program (`_ThreadPool.submit(f: anytype)` does `@as(*T, ...).call()`
      on a closure struct that *codegen* emitted), and across a module boundary that member
      needs `pub` too. The spike never saw it because it only ever split a hello-world.
      `compile_check --runtime-module` caught it on the three threading tests (214/3/1) —
      the clearest argument for gating the flag with the corpus witness rather than examples.
    - **Refused, not guessed:** `--runtime-module` errors out with `--single-file` (both
      restructure file scope), `--target node-addon`, and any `--gui-backend` (both scaffold
      their own build; the GUI section files are not `pub`-marked yet).
    - **Gates added:** `tools/runtime_module_check.sh` (QUICK tier — the only gate that RUNS
      anything emitted in this mode, hence the only one that can see BUG-221) and
      `compile_check.sh --runtime-module` (FULL tier), which is **217/0/1, identical to the
      default-mode baseline**.
  - [x] **FLIPPED TO DEFAULT 2026-07-28 (`ade34cf`).** `--no-runtime-module` opts out.
    **BUG-221 is fixed on the default path.** The three refusals became FALLBACKS, which is
    the substance of the flip: under a flag, refusing an uncovered combination is honest; as
    the default it would simply break those paths. `--single-file`, `--target node-addon` and
    every `--gui-backend` now silently select the inline runtime. The import binds to
    `_zbr_rt` (not `_rt`) — the mode adds a file-scope name to every emitted program, which
    is exactly the BUG-220 hazard, and `_zbr_` is already the reserved prefix for it.
    Gates 9/9, including a round-trip where **selfhost-B is built from selfhost-A's split
    emit and reproduces it byte-identically** — the compiler bootstraps itself through the
    new runtime.
  - [ ] **Residual work, in priority order:**
    1. **~70ms per emit vs the inline runtime** (hello-world ~120ms vs ~52ms; smoke 213s vs
       187s baseline). `96c09b2` cached the render and the name scan, taking the regression
       from 3.6x to ~1.15x on the suite, but the caches do NOT help a single-module program —
       each is populated and used once. What remains is one render, one 3,767-line scan, and
       one 186 KB read-and-compare per emit. **Needs instrumentation, not another guess**;
       the read-and-compare is the first thing to attack (it exists only to narrow the
       concurrent-write window on the shared temp path, which `--output-dir` avoids).
    2. **Cover the fallback paths**: `pub`-mark `gui_tui_section.zig` (89 decls) and
       `gui_libui_ng_section.zig` (102) for the GUI backends; decide the node-addon story.
       Until then those emit the inline runtime, guarded by `runtime_module_check.sh`.
       **No longer a correctness gap** — BUG-221 was closed on the inline path too
       (2026-07-29), so the fallback shape is merely *older*, not *broken*. It had been
       live there: the fixture segfaulted under `--no-runtime-module` because the fan-out
       walked direct `use` decls; it now sweeps the same transitive list. Both shapes are
       gated.
    3. The design note's claim that this "closes BUG-220 completely including the `@export`
       residual" is **unverified** — `@export` is a class-factory annotation here, so the
       obvious repro does not exercise it. What IS demonstrable: the emitted file's scope
       holds only the *referenced* subset of the runtime's 399 names, a strict subset of the
       inline path's, so collisions can only decrease.

- [x] **#3 — Move nil-narrowing into the TypeChecker. DONE 2026-07-28 (`81501dc`).** Narrowing
  was codegen-only (the BUG-188 note in `genMemberCall`): `inferExpr` still reported `?T` inside
  `if x != nil`, so the type checker and codegen disagreed about what was known. The cost was
  user-visible — the same mistake got a Zebra diagnostic with a caret outside a nil-check and a
  raw Zig error with no column inside one. `InferCtx.scope` is flat, so the then-branch saves and
  restores the original type; four of the six cases in `test/nil_narrow_tc_test.zbr` exist to
  prove the restore works, because a leak would produce FALSE errors on valid code rather than a
  missing one. Detection mirrors CodeGen's `nilCheckedIdent` exactly so the two cannot drift.
  Gates: 7/7 full.

- [ ] **#5a — Stdlib arity/signature checking.** The BUG-215 class: `indexOf(a, b)` silently
  discarded its second argument, turning a typo into a runtime panic three frames away. Today
  only `indexOf` is guarded, via `@compileError`. The real fix is a stdlib signature table in the
  front end so arity errors become proper Zebra diagnostics with a source location.

  **Groundwork done 2026-07-28 — read this before starting, it rules out two approaches.**
  1. **Deriving arities from CodeGen is UNSOUND.** Scanning each `if mname == "X"` block for the
     highest `args.at(N)` it reads gives 292 method names but wrong numbers — it reports
     `addDays 0`, `abs 0`, `ceil 0`, because codegen reads arguments through several idioms
     (`genArgList`, loops, helpers) an AST-free scan cannot see. A wrong table produces FALSE
     errors on valid code, which is worse than no table. Do not revive this.
  2. **QUICKSTART's documented signatures are a good source, and 42 of 45 string methods
     validate against the compiler** (script: build a call at the documented arity, run `-c`).
     But the section is not receiver-uniform — `join` is documented under "String method
     reference" while being a `List` method (`parts.join(", ")`), which my first validator
     mis-reported as a doc bug. **Any signature table or doc-checking gate must carry the
     receiver KIND per row, not assume it from the section heading.**
  3. Real finding from that pass, already fixed: `chars()`/`bytes()` were documented as
     returning `List(char)`/`List(int)` but are **`for`-only iterators** — `for c in s.chars()`
     compiles, `var cs = s.chars()` does not.

  **Recommended shape:** a table keyed by *(receiver kind, method name) -> arity*, consulted by
  the TypeChecker only where the receiver type is KNOWN (unknown receiver -> no check, so an
  inference gap can never manufacture a false error). Pair it with a gate that, for every table
  row, compiles a call at the declared arity — so a wrong entry fails loudly at gate time
  instead of silently breaking users. That gate is the artifact worth having; it also
  doubles as a doc-vs-implementation check for the language reference, which is how the
  `chars`/`bytes` inaccuracy surfaced.

- [ ] **#5b — Spans on all AST nodes.** `AstBuilder` uses `zspan()` for 95 of its node kinds.
  Measured impact is *narrower than first claimed* (17 corpus diagnostics carry locations, 0 land
  at `0:0`; the only reproducible case is a two-literal concat), so this is a cap on how good
  diagnostics can get, not a present emergency. Do it when it blocks something.

- [x] **BUG-142 — arity is a hard ERROR. CLOSED 2026-07-31 (Sean's call).** Too few AND
  too many arguments now reject instead of warning. Unblocked by BUG-235: the promotion
  was gated on a corpus baseline that turned out to be five weeks stale, and two scans
  returned a confident "0 too-few" that was a broken instrument rather than a clean
  corpus. Regenerating the corpus and adding a control produced the real number — 28
  too-few lines / 19 files, and exactly **1** too-many site in 1,581 files, which is why
  splitting the promotion by direction was worth doing even though both landed together.

- [ ] **#2 — Typed error sets. STRATEGY DECIDED 2026-07-29: declared-only, opt-in.**
  `def parse(s: str) throws ParseError` declares an explicit set; a bare `throws` keeps
  meaning "anything". Migration is therefore per-function and nothing breaks on day one.
  **Inferred sets were considered and rejected**: they are more ergonomic, but a new
  failure mode added to a leaf function would silently change the signature of callers
  several modules up, which is exactly the invisible-ripple behaviour a contracts
  language should not have. A function should state what it promises. Original framing: Errors are stringly-typed:
  `raise "division by zero"`, caught as `e.message`, everything `anyerror!T`. A caller cannot
  know which errors a function raises, cannot handle them exhaustively, gets no compiler help
  when a new failure mode is added, and breaks silently when someone rewords a string. This is
  the one place Zebra is **less typed than the Zig it compiles to** (Zig has error sets; we
  flatten them). In a language whose differentiator is Eiffel-style contracts — careful machinery
  for stating what must hold going in and out — leaving "what can go wrong" untyped is the
  design's biggest internal inconsistency. Sketch: `def parse(s: str) throws ParseError` with
  exhaustive `catch`. Design space includes declared vs inferred sets, subtyping/widening, and
  migrating every existing `raise`.

- [ ] **#4 — A check mode that actually checks. STRATEGY DECIDED 2026-07-29: fast default
  + `--check-full`.** `-c` becomes front-end-only (~62 ms where the front end can answer);
  `--check-full` keeps today's full `zig build-exe` pass. The IDE Check button is the
  dominant caller and that is the difference between live feedback and a pause.
  **Non-negotiable part of this decision:** the asymmetry must be NAMED in `--help` —
  a fast `-c` can pass on code that `zebra run` then fails to build, and a check whose
  limits are undocumented is the same class of problem as a gate that cannot fail.
  Best sequenced after #5a, which raises what the front end can answer. Original framing: `zebra -c`
  runs a full `zig build-exe`. A check that stops after typecheck would be **~0.06 s instead of
  5.2 s** — 90x on the compiler's most-run command, and it would make the IDE Check button
  instant. The strategy question is what `-c` should *promise*: front-end-only (fast, misses
  emit/codegen bugs only `zig` catches) versus today's full build (slow, total). Plausible answer
  is both — a fast default plus an opt-in `--check-full` — but that contract is worth agreeing
  before building. The FREE WIN above is independent and can land first regardless.

## Pre-1.0 blockers (the road to 0.9 / 1.0)

> **AUDITED 2026-07-28 — the list was longer than the work.** Every item was checked
> against reality. Of 8 entries, 3 were already complete, and of the 5 that read as
> open:
> - **1 is a real blocker, and more serious than it was labelled** — BUG-221 (module
>   init is not transitive) was recorded as "harmless today"; it is a live segfault.
> - **1 is the milestone act itself** (§15) — not work, the promise to freeze.
> - **1 is explicitly NOT a blocker by its own text** — §28a, which records Sean's
>   2026-07-23 framing verbatim: *"NOT a 1.0/1.5 gate … Doesn't block anything."* It
>   was sitting in the blocker list anyway.
> - **1 had a stale premise** — §19.5d claims 5–10 min; measured 163–180 s.
> - **1 is 1.5 groundwork by its own description** — §28e exists to ground the *1.5*
>   `str_view` design. Left in place pending Sean's call rather than moved unilaterally.
> - **1 was already resolved months ago** — BUG-174, closed 2026-07-28.
>
> **So the honest road to 1.0 is one technical bug plus the freeze**, not five open
> items. A stale blocker is not free: it makes the distance look longer than it is and
> invites re-litigating decisions already shipped.


## HARDENING PROGRAMME — adopted 2026-07-30, ahead of 0.9

**Sean's framing, verbatim (2026-07-30):** *"I'd much rather a system that has no
surprises for anyone (or as little as possible) rather than more new features (not that
I don't want features!)"* — and **0.9 may slip as far as needed** to buy real quality
information. That reorders the queue: the items below come BEFORE the 0.9 ship.

Full reasoning, including what we deliberately do NOT copy from SQLite and why, is in
**`docs/testing_strategy.md`**. Summary of the ranked plan:

- [x] **A1 — bug-fixture gate. DONE 2026-07-30.** Every FIXED `BUG-NNN` must be pinned by
  a test that actually RUNS. `tools/bug_fixture_check.py`, gated in the QUICK tier and
  falsified in `gate_selfcheck.sh`. **First measurement: 175 fixed bugs, only 64 pinned by
  a test that runs, 104 with no fixture, 7 with a fixture nothing executes.** Debt is
  baselined (111) so the gate fails on NEW debt only; the count prints every run so it
  cannot become invisible. "Exercised" deliberately includes fixtures driven by another
  tool or imported by a registered test — a gate that cries wolf gets switched off.
- [x] **A4 — OOM policy. DONE 2026-07-30.** `unreachable` is **undefined behaviour** in
  ReleaseFast.

  > **Correction, same day (and it matters for how urgent this was).** The commit message
  > and the first version of this entry said "`zebra --release` builds with
  > `-OReleaseFast`, so OOM in a user's shipped program was UB." **That was wrong**, found
  > while scoping the contracts pilot. `--release` switches to LLVM but never passes an
  > optimize flag on the exe-producing path, so it builds **Debug** — see **BUG-228**.
  > `-OReleaseFast` is reached only by the **node-addon** build and by a `-fno-emit-bin`
  > check that produces no binary.
  >
  > So the exposure was: node addons (real), and anyone taking `--emit-zig` output and
  > building it themselves with `-OReleaseFast` (a documented workflow) — **not** ordinary
  > `--release` users. Narrower than claimed.
  >
  > The fix stands, and the ORDER turns out to be load-bearing: fixing BUG-228 by adding
  > `-OReleaseFast` would have switched on every `unreachable`-is-UB site at once. Doing
  > A4 first means that flag can now be added safely. A4 is BUG-228's prerequisite. **21 allocation
  sites fixed** (20 emit sites in `CodeGen.zbr` + 1 in `stdlib_preamble.zig`) to
  `catch @panic("OOM")`, which aborts cleanly with a message in every build mode and is
  already what ~148 sibling sites do. Verified end-to-end: an emitted user program now
  carries `allocUpperString(...) catch @panic("OOM")`.

  **Why no gate could ever have caught this, which is the transferable part:** every gate
  runs the DEFAULT build, and the default is Debug (self-hosted backend, no `-O`), where
  `unreachable` traps cleanly. The hazard was invisible in testing and live only in the
  artifact users distribute. Works in test, undefined in production. A static lint is the
  only possible witness → `tools/lint_oom_unreachable.py`, gated in QUICK and falsified in
  `gate_selfcheck.sh`. Two `std.fmt.bufPrint` sites keep `catch unreachable` deliberately:
  the buffer is sized exactly, so the error is impossible rather than merely unlikely, and
  the exemption list is kept narrow on purpose.

  *Build-mode note (Sean, 2026-07-30 — "whichever is fastest for our tests"): no tradeoff
  exists. The default fast backend (`-fno-llvm -fno-lld`, Debug) is both the fastest to
  compile (~6×) and the mode where `unreachable` traps. Tests are already on it.*
- [~] **A2 — behaviour differential across emit modes. TWO OF FOUR AXES DONE
  2026-07-30 (`16922ef`, `c161733`).** `tools/output_sweep.sh` gained `--mode`, comparing
  each mode against the SAME baseline rather than giving each its own — a difference IS
  the bug, which is what made it nearly free.
  - [x] **inline** (`--no-runtime-module`) — zero real differences.
  - [x] **turbo** (`--turbo`, contracts stripped) — zero real differences. Both controls
    proved first, because "no differences" is also what a silently-dropped flag produces.
  - [ ] **release** (`--release`, LLVM backend) — implemented as `--mode release` but
    **not yet run across the corpus**; also entangled with BUG-228 (`--release` does not
    currently pass an optimize flag), so run it after that lands or the result describes
    a mode that is about to change.
  - [ ] **`zebra run` vs a built exe** — not implemented. A different branch of
    `zbrToZig` (temp dir, not `--output-dir`), so it is genuinely a separate path.
- [~] **A3 — boundary-value suite, written from INTENT not recorded. FIRST PASS DONE
  2026-07-30 — four dimensions, and it found three real bugs on its first run.**
  `tools/boundary_check.sh` (QUICK tier, ~30 s, falsified in `gate_selfcheck.sh`), probes
  in `test/boundary/`, full triage in `docs/boundary_triage.md`.

  **The one property that makes it not another golden baseline** is that every expectation
  was authored from QUICKSTART *before* the compiler was ever run, and that ordering is
  protected structurally: the probes and their intended output were committed in one
  commit (`603a580`) and the first run's findings in the next. If a future change authors
  an `.expected` by pasting observed output, this has become `output_sweep` with extra
  steps and should be deleted rather than kept.

  **Found (~140 assertions authored, ~130 matched intent first try):**
  - **BUG-230** (high) — `var nums: List(int) = [1, 2, 3]` does not compile. An
    annotated, non-empty list literal is emitted as Zig `const`, because the const-vs-var
    analysis does not count the literal's own GENERATED appends as mutations, so its
    initialisation then fails. Invisible to every heavy gate at once: both compilers do
    the identical wrong thing (divergence cannot see it by construction) and the
    `test/*.zbr` corpus does not use the form. **`examples/widget_smoke.zbr` DOES, and is
    shipping broken** — which surfaced a bigger hole than the bug: **no gate sweeps
    `examples/`**, the first thing a new user reads.
  - **BUG-232** (high) — argument-count checking is **skipped entirely** inside `${...}`.
    `print("${add(1)}")` is silent where `var r = add(1)` warns; the missing argument is
    zero-padded and the program prints a plausible wrong answer. This is the language's
    most common shape.
  - **BUG-231** (medium) — named arguments do not parse inside `${...}`.
  - Plus a **documentation defect**: the four `is…` predicates are ASCII-only, not
    Unicode as documented (`"é".isAlpha()` is false). QUICKSTART corrected.

  **Deliberately NOT covered, printed by the runner on every run so it cannot pass for
  coverage:** min/max int and float extremes (build-mode dependent — blocked on BUG-228,
  or the expectations pin a mode that is about to change), `s[i]` on non-ASCII (BUG-225 is
  a known wrong behaviour deferred to 1.x by §28e), `charAt` (BUG-223 is an open decision
  awaiting Sean). **Open tail CLOSED 2026-07-31** (`cf35d85` + follow-up): deep nesting and long
  identifiers both **matched intent on every row first try**; non-ASCII string
  operations found **BUG-234** — `reverse()` byte-reverses, so `"世界".reverse()` is
  invalid UTF-8 rather than `"界世"` (every multi-byte codepoint; ASCII unaffected,
  which is why nothing noticed). Suite is now **19 probes, 6 pending tripwires**. A third pass (2026-07-31) also
  reclaimed most of the integer dimension from the BUG-228 deferral — only *overflow*
  is genuinely mode-dependent — and found **BUG-236**: `/` emits `@divTrunc` while `%`
  emits `@mod`, so `(a/b)*b + (a%b) == a` is FALSE for negatives. Max/min literals,
  parsing and base conversion all matched intent first try.
  **BUG-234, BUG-236 and BUG-223 all FIXED 2026-07-31** on Sean's decisions —
  codepoint-aware `reverse()`, `%` emitting `@rem` so the division identity holds, and
  `charAt` retyped to `byte`. Both pending tripwires fired on their own when the fixes
  landed and were rewritten to assert intent; pending count 6 → 4.
  Remaining uncovered: float extremes + integer OVERFLOW only (blocked on BUG-228), and
  `s[i]` on non-ASCII (BUG-225, deferred to 1.x by §28e).
- [x] **A5 — gate `examples/`. DONE 2026-07-30.** `bash tools/full_sweep.sh --examples`, in the FULL tier, falsified in `gate_selfcheck.sh`. **First run: 18 examples — 14 pass, 2 genuinely broken, 1 harness-limited, 1 library.** It found **BUG-233** (a lambda parameter shadowing an enclosing one emits invalid Zig — `panel_smoke`) and confirmed `plugin_host` is broken by a Zig 0.16 `DynLib` stdlib change. `widget_smoke` was fixed by the BUG-230 fix and is baselined. Implemented by extending `full_sweep.sh` with a `--examples` corpus rather than adding a sixth near-identical script, so the emit → build-exe → baseline → regress-only-gate logic cannot drift from its sibling. A `DEPMISS` bucket was added because `lsystem` **runs correctly** but its search-path dependency is not emitted by `--output-dir` — a gate that libels a working file is one people learn to disbelieve. Original entry: Every heavy
  gate globs `test/*.zbr`: `compile_check`, `full_sweep`, `divergence`, `output_sweep`. The
  `examples/` directory — the first thing a person evaluating the language opens — has
  **zero coverage**, and it is already shipping something broken:
  `examples/widget_smoke.zbr` uses `var items: List(str) = ["Apple", ...]` and does not
  compile (BUG-230). Verified by emitting it and running `zig build-exe` on the result.

  **Why it went unnoticed is worth keeping:** `zebra -c examples/widget_smoke.zbr` exits
  **0**, correctly — `-c` is front-end-only by design (#4 above). So the obvious way to
  spot-check an example cannot see this class at all, and the directory is otherwise
  unswept. Both halves had to be true.

  Cheap fix: point `full_sweep`/`compile_check` at `examples/*.zbr` as a second corpus, or
  add an `examples_check.sh` on the same shape. The GUI examples need care (they scaffold
  their own build), so the honest first version may be "every non-GUI example must emit and
  compile", with the GUI ones listed as excluded rather than silently skipped. **For a 0.9
  whose whole claim is ready-for-others, this ranks near A2/A3 rather than below them.**

- [ ] **B2 spike (1 day) — is branch coverage feasible on Windows/Zig at all?** Decide
  B1-vs-B2 on evidence. One option worth the look: teaching Zebra itself to emit coverage
  counters, which would serve users too.
- [ ] **B1 — mutation testing of the compiler. HARNESS BUILT; NO VALID FULL RUN YET**
  (`tools/mutation_check.py`). Two runs published and both partly retracted on 2026-08-01:
  a 300-mutant run whose 241 "regen detections" were a CRLF bug in the harness's own
  restore path, and a 60-mutant run whose `emit_fingerprint()` searched for the
  *bootstrap's* header while running the *selfhost*, hashed a sentinel when it did not
  find it, and so returned a **constant** — filing all 47 non-detections as NO-EFFECT and
  never running `smoke` on any mutant; and a third, stopped at 43/60, whose mutation
  coordinates came from `REPO/rel` while the edits went to `wt/rel` — **two different
  files**, 18 lines apart — so it corrupted the source and scored the bootstrap's correct
  refusal as a detection. **What stands: 13 real detections** (10 A3 boundary, 3
  hello-world). **What is withdrawn: "0 survivors"** — and note the SURVIVED path has
  never executed in any run. Postmortems in `docs/testing_strategy.md` §B1 and §3b.
  Harness now refuses to start on a blind fingerprint AND verifies per-mutant that the
  text at the coordinates is what the site claimed.
  **FIRST VALID RUN 2026-08-01** (5 mutants, seed 7): 2 detected by smoke, **3 SURVIVORS**,
  0 no-effect — the SURVIVED path and `smoke` both reached for the first time, after the
  fingerprint was widened to include `selfhost/CodeGen.zbr`. Cost rose to ~370 s/mutant
  (60 mutants ≈ 6 h). Survivors and their corroboration are in
  `docs/testing_strategy.md` §B1; follow-ups are the two items directly below.
  **"Gates caught 40%" is not a coverage figure — do not quote it.** `--site FILE:LINE`
  re-runs one mutation, which is how a new test is PROVEN to kill a survivor.
- [ ] **→ SEE [`docs/INSTRUMENT_PASS_PLAN.md`](docs/INSTRUMENT_PASS_PLAN.md) — the ordered
  plan for "passing all the instruments" (next week's focus, agreed 2026-08-01).** It
  frames the bar correctly: green is achievable by re-baselining, so the target is that a
  NEWLY BUILT instrument finds nothing new. Highest-value item is not the survivor list —
  it is the **57 corpus files in no known category** (84 of 421 are not emit+compile
  clean; 27 are registered negatives). BUG-241 and BUG-242 were both found in exactly that
  blind spot. Order: run FULL first (cheap, may change everything), then triage the 57.
- [ ] **B1 SURVIVOR WORK — 12 named places the compiler can change with no gate noticing**
  (25 mutants over two runs, 2026-08-01). Full inventory + reasoning in
  `docs/testing_strategy.md` §B1. **Every survivor is in `CodeGen.zbr`; TypeChecker had
  five live mutations and caught all five** (four by the A3 boundary suite). Ranked:
  - [x] **(a) DONE 2026-08-01 — stdlib run coverage 11/30 → 26/30, almost entirely by
    REGISTRATION.** `tools/stdlib_run_coverage.py` is the meter. The tests already
    existed; nobody had wired them to `smoke_run`, the helper that reads what a program
    printed. smoke 267 → 281. Two tests were found broken in the process — **BUG-241**
    (`progress_test.zbr`, uncompilable since the Zig 0.16 migration) and **BUG-242**
    (`csv_test.zbr`, undeclared `CsvWriter`) — both invisible because they carried no
    smoke registration at all, and the baseline-driven sweeps cannot tell "never worked"
    from "intentionally negative".
    Four remain uncovered, each for a stated reason rather than an oversight:
    `Csv` (BUG-242), `Progress` (BUG-241), `Ws` (a server; `ws_smoke_test` does not
    terminate, so it needs a client+server fixture with a bounded wait), and `Shell`
    (the only user is `test/zebra_ide.zbr`, an IDE harness that is not a unit test).
  - [ ] **(a2) The four remaining namespaces**, in the order the blockers clear: fix
    BUG-241 and BUG-242 (then registration is a one-liner each), write a bounded
    client+server fixture for `Ws`, and a `Shell` test that does not depend on which
    utilities the host happens to have.
  - [ ] **(a3) The coverage figure is an UPPER BOUND** and should not be read as done.
    "Covered" means one run-fixture *mentions* the namespace, not that it exercises the
    emitter's branches — `genSqliteCall` has many branches and one `Sqlite.` mention. The
    honest next measurement is per-BRANCH, not per-namespace.
  - [ ] **(a-old) Original framing, kept for the reasoning:** Four survivors, each in a `gen<Thing>Call` emitter with nothing checking
    its output. Line numbers as `worktree → main`:
    - `15348 → 15366` `genWsCall` — `if mname == "serve"`; `Ws.serve` stops being
      recognised. Partial excuse: server fixtures never terminate and are excluded by
      `output_sweep`'s nondeterminism detector — a deliberate exclusion is still one.
    - `15635 → 15653` `genTerminalCall` — `var is_println = mname == "writeln"`. Mutating
      it **SWAPS `Term.write` and `Term.writeln`**, so the newline goes to the wrong one.
      The sharpest illustration in the set of why compile-checking is not enough: the
      result is perfectly valid Zig that prints on the wrong lines.
    - `15893 → ~15889` `genUriCall` — `genExpr(args.at(0).value)` → `at(1)`; `Uri.parse`
      binds the **wrong argument**.
    - `16013 → 16031` `genSqliteParams` — `et is Type_.int_ or elem is Expr.int_lit`;
      **SQLite integer parameter binding** takes the wrong branch.

    A compile check cannot see any of these — they need `smoke_run`-style fixtures with
    expected output. Worth enumerating the stdlib emitters and covering the set rather
    than just these four, since these four are only the ones randomly sampled.
  - [ ] **(b) The bare-constructor special cases are probably REDUNDANT, not untested —
    two independent witnesses now.** `11166 → 11184` (bare `HashMap()`) and `6075`
    (`isStrSetCtor`, same line in both trees) both survive `args.len == 0` → `== 1`, and **twelve corpus files use
    bare `HashMap()` without breaking**. Something downstream already handles the shape.
    **Do NOT just add a test** — that pins behaviour that may be duplicated. Find what
    handles it, then delete the branch or document why both exist.
  - [ ] **(c) Three real semantic boundaries, one fixture each.**
    `12608 → 12626` — a call whose arity EXACTLY matches a defaulted parameter list
    (`um_needs_fill = args.len < um_params!.len` → `<=` runs the fill when it should not).
    `733` (both trees) — `TypeRef.generic` rendering: `if i > 0` → `>=` makes a **generic
    type with arguments** render a leading comma, `Name(, T, U)`.
    `7524` (both trees) — the VALUE position of a string-keyed HashMap parameter
    (`if i == 1 and direct_val_str` → `i == 0` counts the key position twice).
  - [ ] **(d) `330` / `341` (same in both trees) — AstBuilder-only predicates the corpus
    never compiles.**
    Lowest priority; check whether they are dead before writing anything.
  - [x] **CLOSED: `9714 → 9720`**, the one-element inferred list literal —
    `test/boundary/bv_list_literal_inferred.zbr`, and `--site` verified it turns the
    mutant from SURVIVED to DETECTED.
- [ ] **B1 v2 — a design change, not more samples.** The cost that matters is **per LIVE
  mutant (~310 s)**, not per mutant. Two fixes: (a) sample until N *live* mutants rather
  than N total; (b) bias site selection toward code the corpus demonstrably executes, or
  toward rarely-taken branches (error paths, fallbacks) — uniform selection over
  CodeGen's ~3,559 sites spends four fifths of its budget on dead code; and (c) **widen
  the emit fingerprint** — it covers 3 canaries today, which is too narrow to support the
  word "unreachable"; regenerating `selfhost/*.zig` with the mutated compiler (22 s)
  would fingerprint the largest Zebra program we have. ~100 live mutants
  ≈ 8.6 h at today's hit rate; the fixes should cut that substantially.
- [ ] **C tier, post-0.9** — mutation fuzzing of valid programs (dbsqlfuzz's actual
  trick; gramgen *generates*, nothing *mutates*), periodic sanitizer sweeps, a release
  checklist. **C2 (contracts) PILOTED 2026-07-30 (`2f377c0`)** — feasibility proven
  (compiler rebuilt itself with contracts live on its own parser; they survive regen;
  QUICK 9/9), **zero bugs found**, cost ~15–20% on smoke with contracts on. The null
  result is the finding: I chose clauses I was *certain* held, which guaranteed it.
  **A contract you are certain holds is documentation; one you are only fairly sure holds
  is a test.** Next aim is TypeChecker (129 defs, zero contracts, and the phase whose
  wrong beliefs produced BUG-215/218/222/223), not more of the Parser. Detail in
  `docs/testing_strategy.md`.

**Known and not addressed by any of this: no gate clicks a GUI.** Doing it properly needs
per-target-OS build and test infrastructure Sean does not have available (his call,
2026-07-30). Six green gates once sat on top of three real GUI crashes; that remains a
human job and should not be papered over by how thorough the rest looks.

**Supporting infrastructure landed 2026-07-29/30 (see `docs/testing_strategy.md` §2):**
`tools/output_sweep.sh` — THE BEHAVIOUR GATE. Every other heavy gate asks "does the
emitted Zig compile?"; none of them ran anything, so valid Zig producing WRONG OUTPUT was
invisible to all of them (BUG-226). 327 corpus programs golden-baselined; nondeterminism
is DERIVED (3 samples + volatile-field normalisation), never hand-listed.

---

- [ ] **§28a step 4 — inference-or-error language flip (selfhost).** Phase 1 (measure)
  DONE 2026-07-15: instrumented the 3 selfhost guess sites; 80 unique sites but ~0 genuine
  ambiguity — the gap is selfhost *inference strength*, not a flip. **Step 2 open: close the
  ~5–8 inference root causes** (`.len`→int, arith-of-prims→prim, call-return propagation,
  user-class field typing; overlaps §24e), re-measure toward 0, THEN flip. Bootstrap corpus
  stays at 0 (`check_inference_guess.sh`), so the user-facing guarantee already holds. Gated,
  supervised. Also surfaced BUG-181 (selfhost can't self-compile `main.zbr`). → *Open detail §28a.*
  **Framing (Sean 2026-07-23): NOT a 1.0/1.5 gate — an INCREMENTAL thread.** Each inference
  root cause is independent and shippable, so §28a rides as a series of post-1.0 point
  releases (1.0.x), each gated. Doesn't block anything; the bootstrap witness holds the line
  meanwhile. A thread to pull on for a while, not a milestone.
- [x] **SIMD data bridge (BUG-197) — `f32x8` usable on real data. Tiers 1+2 DONE 2026-07-18.**
  Found by the 2026-07-17 Greek-NT dogfood. **Tier 1 `.toFloat32()`** (commit `ac48cbe`) and
  **Tier 2 `List(float32)`/`List(f32)`** (commit `015e8c3`) landed, gated. Payoff delivered: the
  SIMD-vs-scalar all-pairs cosine on the Greek vectors runs at **~7.8×** (f32x8 0.39 ms vs scalar
  3.03 ms, ReleaseFast), identical results, exact clustering. **Tier 2 was a selfhost-lags-bootstrap
  convergence** (the bootstrap already accepted `List(float32)`).
  - [x] **Ergonomic follow-ups DONE 2026-07-18** (commits `ee69570`, `ce12e9f`, all gated):
    un-annotated `var v = f32x8(…)` now dispatches `.sum()`/`.dot()` (SIMD-ctor inference — another
    selfhost→bootstrap convergence); `f32.toFloat()` widens via `@floatCast` instead of
    `@floatFromInt`; short type names `f32`/`i32`/`u8`/… map in `typeFromName` so `List(f32)` is
    inference-consistent with `List(float32)`.
  - [x] **Tier 3 DONE 2026-07-18** (commit `736a7d6`) — `f32x8.load(list, offset)` on Sean's
    approved API: `f32x8.load(WF, o)` → `(WF).items[@as(usize,@intCast(o))..][0..8].*`; 1-arg
    `.load(slice)` (offset 0) unchanged. Benchmark rewritten to it — byte-identical, four one-line
    loads for four eight-arg constructors. **All three SIMD-data-bridge tiers complete; BUG-197
    fully resolved.**
- [ ] **§28e — STRING LAYER COHERENCE (scope expanded 2026-07-29; parts 1 and 3 DONE,
  part 2 awaiting one API call).** Was "a borrows-vs-owns doc table"; now the one pass
  that makes Zebra's string layer tell the truth, so strings are touched once before 0.9
  rather than three times. Three parts:

  1. **The ownership table** — **DONE 2026-07-29** (`a0a8664`). `docs/str_ownership.md`,
     28 operations, **derived from real compiler emit** by
     `tools/str_ownership_extract.py` rather than read off `genStdlibMethod`; every row
     carries the emitted Zig it was classified from. Gated via `--check` in the QUICK
     tier plus `gate_selfcheck.sh`, so it cannot drift from the compiler silently.
     The classifier asserts six known-opposite CONTROLS before printing and refuses to
     emit a table it cannot vouch for — which caught three defects in itself during
     development.

     **The substantive finding, which grounds the 1.5 `str_view` design better than a
     plain table would have:** ownership is not one property but two.
     `split`/`lines`/`tokenize` return an **owned container of borrowed elements** — a
     `List(str)` the caller owns whose elements are subslices of the receiver. Under the
     program arena that is invisible; inside an `allocate` scope that owns the receiver
     it is a use-after-free wearing an owned wrapper. Holding the container is not
     enough; the receiver's lifetime is what governs. Documented in QUICKSTART with the
     wrong/right pair.

     Also surfaced and fixed en route: **BUG-224**, `format()` with 2+ arguments emitted
     invalid Zig (one `.{ }` tuple per argument instead of one tuple). Every existing
     call in the corpus passes exactly one argument, which is why no gate caught it.
  2. **Byte-vs-codepoint honesty.** `char` STAYS — Sean's call after review, and the
     data backs it: 559 `c'x'` literals, and the compiler's own lexer is built on
     `branch c on c'a'..c'z'` range matching, so it is the opposite of islanded.
     Removing it would be a 559-site rewrite to buy one fewer type. What is wrong is
     the PRETENSE that byte indexing yields codepoints:

     | | actually is | typed as |
     |---|---|---|
     | `s[i]` / `Lexer.peek()` | byte, widened to u21 | `char` |
     | `charAt(i)` | `u8` | `str` ← BUG-223 |
     | `chars()` | real UTF-8 decode | `char` ✓ |

     Only the third is honest. Adopt Go's model explicitly — `str` is bytes, `char`
     is the decoded codepoint — and make the byte-oriented accessors SAY byte.

     **Measured 2026-07-29, and the two rows have wildly different costs — they should
     be decided separately, not as one "fix the string types" item:**

     * `charAt(i)` → **BUG-223, free.** It is not merely mistyped, it is *unusable*:
       every way of consuming the result is a compile error (`print` → "expected type
       'str', found 'u8'"; `.concat` → "no field or member function named 'concat' in
       'u8'"). `grep -rn '\.charAt(' --include='*.zbr'` over the whole repo returns
       **zero callers**, and it is absent from QUICKSTART. Retyping to `byte` cannot
       regress a caller because no caller can compile, and `byte` already exists.
     * `s[i]` → **BUG-225, expensive.** Typed `char`, holds a raw byte, so it is
       *silently wrong* for non-ASCII: `"eéx"[1].toString()` prints `Ã`. The selfhost
       lexer is built on it (`Lexer.zbr:116` `def peek(): char` → `src[pos]`; ~60
       subscript sites in that file, ~104 across `selfhost/`), and the 559 `c'x'`
       literals compare against the result — so retyping requires deciding `byte`/`char`
       comparison rules. That is language design competing directly with the pre-0.9
       churn freeze.

     **Recommended split: fix BUG-223 now, document BUG-225 for 0.9 and retype in 1.x.**
     Go and Rust both expose a byte layer and neither pretends an index yields a
     character; documenting the limit is most of the value and none of the churn.
     BUG-223 is worth doing regardless of BUG-225, because it leaves users an *honest*
     byte accessor, which `s[i]` currently is not.
  3. **State the ceiling in QUICKSTART** — **DONE 2026-07-29.** A codepoint is not a
     user-perceived character: `é` can be two codepoints, emoji families are many. Swift
     made `Character` a grapheme cluster for exactly this reason; Rust and Go chose
     codepoint and documented the limit. Zebra chooses codepoint, so the limit belongs in
     the docs rather than being discovered by whoever first calls `.chars()` on an emoji.
     QUICKSTART now has a "Bytes, codepoints, and graphemes" section stating the Go
     model, the grapheme ceiling, and that grapheme segmentation is *not* provided —
     plus the BUG-225 gap with the "index for bytes, iterate for characters" guidance.

  **BUG-223 (`charAt` → `byte`) is the one open decision in §28e** — a user-facing API
  change, so it waits on Sean rather than being slid in. Everything else in the pass is
  landed. → *Open detail §28e.*
- [x] **§28f — generic `Set(T)` DONE (2026-07-24).** Distinct `Type_.set_` variant
  emitting `AutoHashMap(T, void)` / `StringHashMap(void)` (str). API: `add`/`contains`/
  `remove`/`len`/`count`/`items`→`List(T)`/`clear`, `for x in set`, `x in set`. Works as
  local/param(by-ptr)/field/return/nested `List(Set(int))`. **Selfhost-only** (bootstrap
  sunsets; the compiler's own source never uses Set, so round-trip holds). Decisions taken:
  str specialized (content-hash), `items()`→`List(T)`, StrSet stays internal. Limits (=HashMap):
  T must be auto-hashable; no `==`/`print(set)`. **Collection literals also DONE** —
  `{a, b, c}`→`Set(T)` (new `Expr.set_lit`) and `{k: v, ...}`→`HashMap(K,V)`
  (`Expr.dict_lit`, disambiguated by `:`); `{}`→empty dict (annotate or error). (Set
  literals root-caused a nasty TCO fall-through hang — see [[project_tco_fallthrough_hazard]];
  dict literals went smoothly since that plumbing was already safe.) Tests: `set_basic_test`,
  `set_advanced_test`, `set_literal_test`, `dict_literal_test` (all smoke-gated). → detail §28f.
- [x] **BUG-174 — `str.indexOf` signature design call. CLOSED 2026-07-28 — it was
  already resolved, just never closed.** Both compilers and the docs now agree on a
  mixed convention: `indexOf`/`lastIndexOf` return `int` with a `-1` sentinel (so
  arithmetic like `indexOf(x) + 1` stays natural — the reason BUG-181 moved the
  selfhost off `int?`), while `indexOfFrom`/`indexOfIgnoreCase` return `int?`.
  Verified by running the same program through both compilers: identical output on
  all four methods, hit and miss. **Was sitting in the pre-1.0 blocker list as an
  open decision that no longer needed deciding.**
- [x] **BUG-221 — module init is not TRANSITIVE. CLOSED 2026-07-29, both emission
  paths.** A three-module program whose deepest module touched a file segfaulted at
  `0xffffffffffffffff` (Zig's `0xaaaa…` poison in the trace) because the entry point
  initialised DIRECT deps only. Fixed on the runtime-module path when that became the
  default (`ade34cf`), then on the inline path — still reached by `--no-runtime-module`
  and the fallback for `--single-file`/node-addon/GUI — the next day (`7e5fb72`), where
  it was still live rather than latent. Same cause both times, same fix: sweep the
  TRANSITIVE dep list instead of direct `use` decls. Gated in both shapes by
  `tools/runtime_module_check.sh`.

  **This was "the one genuine technical blocker left on this list" per the 2026-07-28
  audit. With it closed, nothing on this list is a technical blocker:** §28a is
  explicitly not a 1.0 gate (Sean, 2026-07-23), §28e is documentation that grounds a
  *1.5* design, §19.5d had a stale premise and is an optimisation. **What remains
  between here and 1.0 is §15 — the freeze itself.** That is a decision to make, not
  work to do, and it is Sean's.
- [ ] **§15 — 1.0 stability lock + final CHANGELOG pass. SEQUENCE DECIDED 2026-07-29:
  §28e + docs polish → ship 0.9 public → freeze 1.0 on evidence.** Not a straight freeze:
  the public release is 0.9 (ready-for-others), and it should read as finished when it
  lands, so the `str` ownership table (§28e) and a documentation pass come FIRST.
  Freezing 1.0 before anyone outside has compiled a line would spend the stability
  commitment against a corpus of 335 files instead of against real use. The milestone
  act itself:
  everything below the line is delivered; 1.0 is the promise to freeze it. → *Open
  detail §15.*
- [ ] **§19.5d — `bootstrap_check.sh` latency. NOT A BLOCKER; premise was stale.**
  The §19.5d note says "5–10 min observed". Measured 2026-07-28 via the new per-gate
  timing in `tools/gates.sh`: **163–180 s** (~3 min), roughly half the recorded figure.
  It is an optimisation, not a correctness gate, and nothing about 1.0 depends on it.
  Moved off the blocker list in spirit — left here only until someone re-files it under
  tooling.

## Compiler hardening (gated; unattended-safe — deterministic, round-trip-checked)

- [x] **BUG-220 — user function names could collide with preamble internals. FIXED 2026-07-28.**
  Zig forbids a parameter shadowing a file-scope declaration, and top-level `def`s emit at file
  scope, so a user function collided with any of the preamble's 423 non-underscore identifiers:
  `count`, `data`, `total`, `buf`, `body`, `color` — 15 of 16 everyday names tested — failed to
  compile, with the error pointing into preamble source the user never wrote. Top-level defs now
  take the reserved `_zbr_fn_` prefix, finishing the half of BUG-137 (`_zbr_mv_` for module vars)
  that was never done. Selfhost-only; gate `test/toplevel_name_collision_test.zbr`. Residual:
  `@export`/`@node_export` keep their names (the ABI symbol IS the name) — closed only by the
  namespaced-emission design (§ docs/single_file_emit_design.md 1a).
- [x] **BUG-219 — `sys.run` deadlock. FIXED 2026-07-28.** Sequential pipe drain (stdout to EOF,
  then stderr) deadlocked whenever a child filled its stderr buffer — which made `zebra -c` hang
  precisely when a program had errors to report, and that is what the IDE's Check button runs.
  Now delegates to `std.process.run` (concurrent drain via `Io.File.MultiReader`). 4 min → 1.09 s,
  verified against 29.5 KB of child stderr. Same family as BUG-208's noted follow-ups.

- [ ] **Selfhost↔bootstrap divergence burn-down** (`tools/divergence_check.sh`,
  `docs/divergence_audit.md`). New harness (2026-07-18) catches drift the other gates
  can't (they all emit with one compiler). First run: 272 agree-pass, **19 → 17 selfhost
  gaps** after the Build fix (`e5f34d8`). Every remaining gap has a known-good bootstrap
  emit to diff against — a `diff bootstrap-emit vs selfhost-emit → converge` workflow.
  - [x] **All selfhost gaps closed (2026-07-22).** 17 emit-compile D-clusters + the final 3
    post-BUG-181 (string_methods/expressiveness_test/throws_autoprop_test). Every fix diffed
    against the known-good bootstrap emit and gated.
  - [x] **Root fix — unify the stdlib-namespace list (DONE 2026-07-23, `0b11d83`).**
    Extracted `CgHelpers.isStdlibNs` as the single source both `Resolver.isBuiltin` and
    `CodeGen.isStdlibNamespace` consult — the Build-bug drift class can no longer recur.
    Behavior-preserving; all 5 gates green.
  - [x] **GATED (2026-07-22).** `bash tools/divergence_check.sh --gate` exits 1 on any selfhost
    gap; baselined 0. Documented in CLAUDE.md verification-gates. Per-session/pre-release (heavy).
  - Note: **14 BOOTSTRAP gaps** = selfhost LEADS; no fix needed (bootstrap sunsets).
    Full 5-family root-cause triage under "Bootstrap-lags-selfhost convergence" below
    (2026-07-22): pointer/value, `.items`-on-non-list, inference, parser/SIMD, sqlite-binding.
- [x] **GUI builds via selfhost emission (TUI) — DONE 2026-07-26.** `--gui-backend=tui`
  now emits the tui backend and scaffolds/builds the `zig build` project via the
  **selfhost itself** (commits `61a3ffa` Phase 1, `bbc7845` Phase 2, `3ef1e8e` example
  cleanup) — no more bootstrap delegation. Dissolves BUG-204 + BUG-206 for the tui path
  (proven: `examples/tears_of_the_tuon.zbr` builds via `--gui-backend=tui` with all
  workarounds removed). Mechanism: `selfhost/gui_tui_section.zig` (tui backend, read at
  runtime) + `CodeGen.guiSelectPreamble` (substitutes it for the stub section) +
  `main.compileGuiTui` (scaffold + `zig build --build-file` w/ inherited stdio). Gated:
  stub emit byte-identical, bootstrap_check byte-identical, smoke 254/254.
  **libui_ng also ported (2026-07-26, commit `af4d0f3`) AND now works end-to-end
  (2026-07-27).** Same generalized path (`compileGuiProject(zig_path, mode_run, backend)`
  + `gui_libui_ng_section.zig` + `luiBuildZig/Zon`). The former blocker — the upstream
  `zig-libui-ng` dep not compiling under Zig 0.16 (`ui.h` `uiRect` undefined) — is
  resolved by pointing the binding at Sean's consolidated forks:
  `torial/zig-libui-ng@main` (wp base + zig-0.16's sci/scintilla, Zig-0.16 fixes:
  `@intFromBool` on c_int setters, `Separator` alias, 5-arg `OnToggled`) which in turn
  pins `torial/libui-ng@main` (carries the vendored `uiRect` struct from petabyt/libui-dev).
  Both forks consolidated to a single `main` (stale branches deleted, defaults set).
  **Proven portable:** `examples/tears_of_the_tuon.zbr` compiles + links `app.exe` via
  `--gui-backend=libui_ng` from a **cold global cache** (both deps fetched fresh from
  GitHub). The *proven* part is compile + link (the emitted `app.exe` is produced); only
  the `run` step fails — the exe won't launch in this non-interactive shell (exit 57 under
  `zig build run`, 127 when invoked directly from git-bash). Not diagnosed to a root cause;
  most plausibly the lack of an interactive Windows display/session, NOT a build problem.
  Needs a manual interactive run to confirm the window actually shows. Also fixed a latent
  `compileGuiProject` bug: it wrote `build.zig`/`build.zig.zon` only when absent, so a
  stale scaffold silently kept an old dependency pin — now rewritten unconditionally.
  **RUNTIME-VERIFIED 2026-07-27:** counter (`+`/`−`/reset work), the game
  (difficulty screen renders), and — after porting the `CodeEditor` builtin to the
  selfhost — a single Scintilla editor (`examples/editor_min.zbr`: renders + displays
  its `setText` content, Sean-confirmed). See `docs/libui_ng_audit.md` for the full
  claims-vs-verified ledger.
  **IDE: BUG-214 FIXED 2026-07-27 — next step is ONE INTERACTIVE RUN (Sean).**
  The IDE compiles + links + **renders** via `--gui-backend=libui_ng` (all compile gaps
  closed: CodeEditor port `b42074a`, BUG-211 `using`-usage `33571e5`, BUG-213 `SysProcess`
  dispatch `1895d79`), and the click-crash is fixed: BUG-214 emitted a no-payload
  `union(enum)` `Msg` variant as a bare **tag** (`Msg.list_targets`, 1 byte) instead of
  `Msg{ .variant = {} }` (the full union), so the type-erased MVU `g.send(anytype)` copy
  size-mismatched. Fixed selfhost-side, narrowly (only the `send`-on-`Gui` argument
  position — a blanket rewrite is illegal Zig for `==` and would force a bootstrap-parity
  diff; see BUGS.md). All 11 bare IDE sends now convert; new runtime gate
  `test/mvu_mixed_union_test.zbr` (reproduces under the **stub** backend, no display
  needed) is in the smoke suite. Gates green: round-trip byte-identical, smoke 255/255,
  compile_check 215/0/1, divergence 0 selfhost gaps.
  **INTERACTIVE RESULT (Sean, 2026-07-27): THE IDE IS NOW CLICK-STABLE.** Final word after
  the second pass: *"All crashing behavior w/ those buttons is gone."* BUG-214 confirmed
  (buttons dispatch), and the two crashes it had been masking — BUG-215 and BUG-217 —
  are fixed and confirmed in the same session. Nothing ever dispatched before BUG-214, so
  neither downstream crash could have been seen until it was fixed:
  - **BUG-215 (FIXED + confirmed)** — `Check` and `List Targets` aborted: the IDE called
    `str.indexOf(sub, from)`, which is not a real signature (`indexOfFrom` is), and both
    compilers silently dropped the offset → `substring(start > end)` panic. Fixed in the
    IDE *and* guarded in codegen so it cannot recur silently.
  - **BUG-217 (FIXED + confirmed)** — `Build` segfaulted: `SCI_SETTEXT`
    **ignores** the length it is given and calls `strlen()` on the pointer
    (`scintilla/src/Editor.cxx:6190`), but `_code_editor_set_text` used
    `_allocator.dupe`, which produces no terminator. `setText("")` — the first thing
    `Msg.build_start` does — passes a zero-length slice whose `.ptr` is not readable at
    all, hence `Segmentation fault at address 0xffffffffffffffff`. `_CodeEditor` now
    maintains `buf[len] == 0` as an invariant; also fixed a latent one-byte overflow on
    the `SCI_GETTEXTRANGE` read path. **Method note:** the stack trace settled this in
    one round after three hypotheses died guessing — including this one, dismissed
    because the *binding* takes an explicit length (it does, then discards it at the C
    boundary). For any future GUI crash, get `… > log 2>&1` + the top 40 lines FIRST.
  **ALL IDE UNKNOWNS NOW CLOSED (2026-07-27).** The four Scintilla editors **do**
  coexist in one window, and editability behaves exactly as authored: typing works in
  `m.editor`, while the three panes given `setReadOnly(true)` in `ideInit`
  (diag/output/buildOutput) correctly reject input — Sean confirmed the one-editable-
  pane behavior and correctly attributed it to read-only mode. `examples/editor_min.zbr`
  was also re-run post-BUG-217, re-earning the marker it held under the buggy code.
  **The IDE is END-TO-END RUN-VERIFIED**: builds, links, renders, dispatches, survives
  every toolbar button, and hosts four coexisting Scintilla controls.
  **What remains is UNBUILT, not broken** — syntax highlighting (`forZebra` falls back
  to plain; no lexer wired), `setErrorMarkers` (no-op stub), the column half of
  `setCursorPosition`, and any Table/Tree widget for a file explorer. Those are the
  next IDE features whenever the IDE comes back up the queue.
  NOTE: use `bash tools/bootstrap_check.sh --update` DIRECTLY to
  regen after `.zbr` edits — `zig build update-selfhost` silently skips (BUG-210).
  **Housekeeping surfaced by BUG-214:** the checked-in `examples/*.zig` artifacts are
  stale — regenerating `examples/counter.zig` produced ~1400 lines of pre-existing
  preamble drift on top of the 3 lines BUG-214 actually changed, so it was left alone
  rather than burying the fix. Regenerate the `examples/` artifacts as a standalone
  cleanup commit (or decide they should be gitignored like `selfhost/*.zig` is not).
  **Remaining (follow-ups, not blocking):** (a) `compileGuiProject` copies only the root
  emitted `.zig` — multi-module GUI apps still need dep `.zig` files copied into the
  scaffold (single-file / no-dep GUI apps like the game work now; residual "GUI
  module-resolution" limit). (b) **only glfw** still delegates to the bootstrap (same recipe
  to port when wanted: extract its arm from `src/CodeGen.zig`, add a section file +
  build template + backend name to `gui_selfhost`). (c) `--gui-backend=stub` explicit still
  delegates (plain `zebra run` already emits stub via the selfhost).
- [ ] ~~**GUI builds via selfhost emission — phase the bootstrap out of the GUI path**~~
  (epic; scoped 2026-07-25, scoped TUI-only). Today
  `--gui-backend=*` delegates the WHOLE build to `zebra-bootstrap.exe`, so bootstrap-lags-
  selfhost gaps BLOCK GUI/TUI apps even though the primary/selfhost compiler accepts the code —
  found porting `examples/tears_of_the_tuon.zbr` (BUG-204 return-position `except`, BUG-206
  `.toInt()`-on-float, GUI module-resolution all bite here). **Payoff: dissolves BUG-204 +
  BUG-206 + GUI module-resolution at once**, phases the bootstrap out of the GUI path (endgame).
  **Decision (Sean 2026-07-25): the right fix; do NOT do bootstrap grammar surgery for BUG-204.
  Scope TUI-only (defer imgui/libui_ng). Mechanical copy into the selfhost — do NOT refactor the
  sunsetting bootstrap (its GUI copy dies with it). Do it as a fresh, gated, phased effort.**
  - **Corrected scope (was mis-estimated as ~160 lines / "focused session"):** ~500 lines
    TUI-only, ~2000 all-backends. The scaffold driver was only half. **The real work + risk:**
    the selfhost gets its GUI backend from the preamble file UNCONDITIONALLY (always **stub** —
    `selfhost/stdlib_preamble.zig`, `_gui_active_backend` between the STDLIB_PREAMBLE_GUI markers;
    the selfhost reads the whole file, the bootstrap keeps the section inline in CodeGen with a
    `switch(gui_backend)`). To emit tui *instead*, stub must become codegen-**selected** — split
    the stub block out of the shared preamble, gate on `gui_backend`. This restructures a path
    every GUI-stub test depends on: it **MUST stay byte-identical for the stub case** or
    `bootstrap_check` breaks + every GUI stub test shifts. That gate-holding restructure is the
    crux, NOT the tui glue (static strings — mechanical copy, watch CRLF/escaping in `.zbr`).
  - **Reference map (bootstrap side, to copy/mirror):** backend `switch(g.gui_backend)` =
    `src/CodeGen.zig:3061-4683` (stub 3062-3234, imgui ~3234-3835, **tui 3841-4114**, libui
    4124-4683; each arm ends `const _gui_active_backend = _gui_<x>_backend`). Scaffold =
    `compileGuiProject` `src/main.zig:1348-1417`; build.zig/.zon templates `1188-1300`
    (tui template `1254-1300`). Selfhost currently: parses `gui_backend` (`selfhost/main.zbr:2094`)
    only to delegate (`~2320`); CodeGen emits `_gui_active_backend.*` CALLS but has NO
    `gui_backend` field/param (never threaded).
  - [x] **Phase 1 DONE 2026-07-25 (commit `61a3ffa`, gated).** Threaded `gui_backend` through
    the pipeline (`main` → `setGuiBackend` → `_gui_backend` var in CodeGen, mirroring
    `setSingleFile`) and routed every preamble-append site through `guiSelectPreamble`, which
    splits on the STDLIB_PREAMBLE_GUI markers so codegen picks the backend. **Refinement vs the
    original plan:** stub stays SOURCED FROM the preamble file (split-then-reassemble = verbatim),
    NOT extracted into codegen strings — so stub is byte-identical by construction (lower risk).
    Verified: counter (GUI stub) + a plain program emit byte-identical to pre-change;
    bootstrap_check byte-identical; smoke 254/254.
  - [~] **Phase 2 — core mechanism VALIDATED 2026-07-25; delivery+scaffold+routing remain.**
    **Validated (the make-or-break unknown):** grafting the bootstrap's tui GUI section into a
    *selfhost* emit (selfhost preGui + bootstrap tui-section + selfhost postGui) COMPILES + links
    with zigzag (`zig build` exit 0). So the selfhost preamble is compatible with the bootstrap's
    tui glue; the ~20-line stub-vs-preamble divergence is confined to the GUI section (replaced
    wholesale for tui) and is irrelevant. **tui section extraction (reproducible):** emit any GUI
    program with the bootstrap twice — `zebra-bootstrap.exe --emit-zig g.zbr` (stub) and
    `--gui-backend=tui --emit-zig g.zbr` (tui); the tui GUI section = the tui emit's text from
    `// ─── GUI: backend isolation` through `const _gui_active_backend: _GuiBackend =
    _gui_tui_backend;` (~508 lines / 26 KB; contains the sole `@import("zigzag")`; no `"""`).
    **`guiSelectPreamble` tui branch (validated shape):** for `_gui_backend=="tui"`, return
    `preamble[0..siEnd] + "\n" + <tui-section> + preamble[aeEnd..]` where `si`=STDLIB_PREAMBLE_GUI_START
    marker, `ae`=`const _gui_active_backend … = _gui_stub_backend;` (ASCII-stable anchors). **NOT
    byte-identical to the bootstrap is fine** — tui isn't in the divergence corpus; it only needs
    to build+run. **Remaining:** (a) deliver the tui section — file `selfhost/gui_tui_section.zig`
    read at runtime (resolve like `preamble_path`, install next to exe in build.zig) is cleaner
    than a 508-line embed [triple-quoted `"""` works but bloats CodeGen]; (b) port the
    scaffold+zig-build driver (`compileGuiProject` `src/main.zig:1348-1417`, uses `.stdout=.inherit`
    already) + the tui build.zig/.zon templates (`src/main.zig:1254-1300`) into `selfhost/main.zbr`;
    (c) route `--gui-backend=tui` through emit-then-scaffold instead of delegating (`selfhost/main.zbr`
    ~2320). **Acceptance: `zebra --gui-backend=tui examples/tears_of_the_tuon.zbr` builds + runs the
    game WITHOUT the BUG-204/206 workarounds (revert those in the example to prove it);
    bootstrap_check + smoke green.**
- [ ] **Grow the fuzzer's `DEFAULT_CAPS`** (`fuzz/gen.py`) — highest-leverage
  correctness lever (risk surface is combinatorial; see `docs/COVERAGE_MAP.md`).
  Remaining caps need class-relationship generation: (4) `^T` boxing,
  (5) interfaces + `is`, (6) generics / backed-enums / chained-cmp. → *Open detail,
  Fuzzer.*
- [ ] Grow fuzzer grammar surfaces (generics, error/throws, branch/enum); run
  `fuzz/run.py --run` batches when free RAM allows (small batches under memory
  pressure).
- [~] **Bootstrap-lags-selfhost convergence** (bootstrap is the regen authority;
  selfhost is ahead — converge only where the round-trip needs it):
  - **RECOMMENDATION (2026-07-22): do NOT chase these as a batch.** Full triage below shows
    the 14 span 5 codegen surfaces (not one bug), most triggered by escape-hatch/niche
    constructs (`zig"…"` raw literals, `f32x8`, generic-fn syntax), and all require porting
    selfhost codegen *back into the sunsetting bootstrap* — against the roadmap's "don't do
    sizable ports into the phasing-out bootstrap." Witness value is real but bounded: for all
    14 the selfhost output is already known-correct (compiles + smoke-passes), so there is no
    silent blind spot today — only a degraded reference for *future* changes in those (stable)
    areas. Fix opportunistically if one blocks the round-trip; otherwise leave until/unless
    the bootstrap's Phase-2 (single-file witness) work reopens it.
  - **Triage map — 14 bootstrap gaps → 5 root-cause families (divergence_check, 2026-07-22):**
    - **(A) pointer/value confusion (~6, dominant):** `greet`/`with_test`/`features`/
      `selfhost_probe5` emit `*T = T{}` (declared `*T`, init value); `pratt_calc`/`lambda_calc`
      the inverse (`T` vs `*T`). Trigger: explicit class-type local + `zig"T{}"` raw-literal
      init. Bootstrap's pointer-vs-value / `^T`-box decision is diffuse (no single guard) —
      this is the `^T`-boxing class the fuzzer notes flag as hard. Sizable.
    - **(B) spurious `.items` on non-list (~3):** `list_iter` (`.items` on `[]i64` slice),
      `hashmap_init_patterns_test` (`.items` on HashMap), `bug177_178_index_tostring_test`
      (nested `g.items[0][1]` — inner needs `.items`). Container-shape tracking lag.
    - **(C) inference/TC lag (~2):** `lisp` (`expected float, got Value`), `sort_test`
      (indexing empty slice).
    - **(D) parser/feature gaps — EMITFAIL (~2, deepest):** `generic_fn_test` (bootstrap
      parser: `syntax error near '('` on generic-fn syntax), `simd_test` (`f32x8` not
      defined — known niche).
    - **(E) stdlib-binding lag (~1):** `sqlite_test` (`asInt` missing on `_SqliteRow`).
  - [ ] **BUG-180 (new 2026-07-14)** — bootstrap drops omitted ctor defaults on emit
    (`Vector3()` → `Vector3.init()`); selfhost fills them. Workaround: spell ctor
    args out. → `BUGS.md`.
  - [ ] `for x in <as-bound List>` → `.items` (low value now — bootstrap phasing out; family B).
  - [ ] `zig"…"` ref-analysis (count idents used inside zig-literals; no spurious `_ = v;`).
  - [ ] Reconcile explicit `: void` parse divergence (bootstrap `.named "void"` vs
    selfhost `.void_`).
  - [ ] BUG-147 (3 bootstrap lisp-emit divergences); BUG-149 (`.len` on a local-map `fetch`).
- [ ] Audit/regenerate stale engine-style `.zig` with the converged bootstrap
  (`pathfinding.zig` was stale; others likely are); add a numeric-conversion
  compiler test; correct QUICKSTART §21.
- [x] Run full `compile_check.sh` corpus (JOBS-paced) + triage regressions. **DONE
  2026-07-16: 198 passed / 0 FAILED / 3 skipped (selfhost, JOBS=3)** — the §28a step-2
  changes introduced no emitted-Zig regressions. `compile_check` is the *independent
  witness* the round-trip lacks (round-trip diffs the selfhost against itself → blind to
  wrong-but-compiling output AND to programs it never compiles; `compile_check` runs
  `zig build-exe` on emitted corpus programs). **Recommend gating it** (per-commit or at
  least per-session) — it is currently a manual tool, so the coverage-blindness it closes
  is only closed on the days someone remembers to run it. Cost: a few min at JOBS=3.
- [ ] **⚠️ 1.0 BLOCKER — emit-compile triage campaign** → **`docs/emit_compile_triage.md`**.
  > **RE-SWEPT + GATED 2026-07-24** (`docs/full_sweep_triage.md`, `tools/full_sweep.sh`).
  > Full 403-file re-sweep: **328 PASS, 0 regressions, 0 NEW bugs** — every remaining
  > CFAIL/EMITFAIL is a negative test, library module, interop-needs-libs, multi-module,
  > or a KNOWN item in this campaign's backlog. Fixed 3 stale tests (removed syntax) en
  > route. The corpus is now gate-able: `full_sweep.sh --gate` fails on regression vs a
  > 328-test baseline (no skip-list needed). The codegen backlog below is unchanged — the
  > sweep confirmed the state rather than finding new work.
  A full-corpus independent-witness sweep (all 399 `test/`+`examples/` `.zbr`, not just the
  ~201 smoke-registered) found **52 standalone-compile FAILs**: ~11 negative/harness, and
  **~30 genuine codegen/type miscompiles on current constructs**, clustered into ~15–20 root
  causes (undeclared-type-not-emitted `Http`/`CsvWriter`; syntax errors in emitted Zig `json`;
  `.len`-on-ArrayList `dns`; `^T`-box `*T`-vs-`T`; BUG-182-class mis-typed-receiver dispatch;
  one GUI `param shadows 'init'` bug covering ~6 files). BUG-182 was the tip. Campaign: verify
  real-vs-stale per cluster, fix by root cause (~15–20 fixes clear ~30 files), gate
  `compile_check` over the triaged-clean corpus so it can't regrow, prune stale tests. Found
  2026-07-16 by casting the witness wider than the curated smoke set.
  - [ ] **Follow-up (D7 residual) — closure local over-marked `var`.** BUG-191 (2026-07-17, two
    rounds) made the `var`/`const` scan type-driven for value + by-value-handle receivers
    (immutable str/primitives → never `var`; json/tcp/ws/udp/sqlite/regex → `const` unless an
    explicit mutator; optional/`^T` unwrapped), killing the `never mutated` class corpus-wide.
    The ONE remaining `never mutated` (in `gui_test`) is NOT a scanMutations case: `frame` is a
    **closure** (`var frame = def(g)…`) passed by value to `Gui.run`, marked `var` by closure
    lowering because the closure body mutates a captured var — yet `frame` itself is copied into a
    heap slot and never mutated locally. Fix lives in the closure/lambda codegen (emit the closure
    temp `const` when it is only passed by value and never locally re-invoked with mutation), not
    in `scanMutations`. Low priority: 1 file, which also fails on an unrelated
    `GuiContext has no member 'run'`. NOTE: a measured corpus scan found **no** named-struct-getter
    `never mutated` case, so the earlier "per-method struct mutation map" idea is unnecessary —
    structs correctly stay on the name-based fallback.
- [ ] **§24e — single method-descriptor table** (stdlib method registration touches
  4 places). Deferred post-1.0, but §28a raised its priority (it converts four
  heuristic dispatch surfaces into one spec). → *Post-1.0 §24e.*
- [ ] **Single-file emission — codegen architecture** [Phase 1 (single-module, both compilers)
  + §7b Phase 2 (multi-module merge, **selfhost**) + Phase 4 (edge-case parity + node-addon
  hardening) LANDED 2026-07-21, behind default-off `--single-file`. **F5 closed**;
  `compile_check.sh --single-file` = 200/0/1 == multi-file baseline; round-trip byte-identical;
  smoke 236/236. **BUG-181 RESOLVED 2026-07-22 → Phase 5 UNBLOCKED** (the combined selfhost/main.zig
  now COMPILES). **Phase 5/6 DE-SCOPED (2026-07-22, `docs/regen_authority_decision.md`):** keep
  the bootstrap as the independent multi-file regen authority (the trusting-trust witness that
  caught BUG-181); do NOT make the selfhost sole authority, do NOT add single-file to the
  bootstrap now. Single-file stays a shipped feature (default-off), gated by
  `tools/selfcompile_check.sh`. Revisit post-1.0 (freeze bootstrap) or if the 9-file burden bites
  (then bootstrap Phase 2 is the correct route). **Feature complete for now.**]

- [x] **Convergence sweep: 3 selfhost gaps — ALL CLOSED (2026-07-22).** The post-BUG-181
  `divergence_check.sh` found 3 selfhost-lags-bootstrap gaps; all fixed + gated (200/0/1 +
  round-trip each): `string_methods` (indexOf→int, `37873e8`); `expressiveness_test`
  (named-args/defaults in user-method calls + string-repeat codegen + inference, `3fe5630`);
  `throws_autoprop_test` (try-block catch-wiring in the user-method early-exit). **Two of the three
  shared ONE root:** genMemberCall's "general user-method early-exit" (~11620) emitted args
  positionally and returned before the default path's named-arg/default AND try-block-catch handling
  — so both named-args/defaults and throws-in-try were silently wrong for user-method calls (a
  high-impact class: any program using default params, named args, or throws-in-try on a user
  method). Confirmed: `divergence_check.sh` now reports **0 selfhost gaps** (292 agree-pass · 46
  agree-fail negatives · 18 no-main libraries; 14 bootstrap-lags-selfhost gaps remain — secondary
  witness-quality item, tracked separately). Original triage below (kept):

  <details><summary>Original 2-gap triage (2026-07-22)</summary>
  - **`expressiveness_test` — named args + default params in METHOD calls.** `g.greet(name: "Alice")`
    (default `greeting`) emits `g.greet("Alice")` (1 arg, no default); reordered
    `g.greet(greeting: "Hi", name: "Carol")` emits source-order `g.greet("Hi", "Carol")`. Root: in
    genMemberCall, `mc_params` is nil because `inferExpr(g)` doesn't resolve an EXPLICITLY-typed local
    (`var g: Greeter = Greeter()`) to `named("Greeter")` (or `lookupFnParams("Greeter.greet")` is
    empty) — so neither the legacy reorder path NOR a `genArgListFull` delegation can fire. FIX =
    make the receiver's class resolve (bind explicitly-typed locals in infer_ctx / register method
    params) THEN delegate the has-named/needs-fill case to `genArgListFull` (the correct algo the
    constructor path already uses; a guarded delegation was drafted + reverted pending the inference
    fix). The bootstrap handles all of this. Connects to §28a inference.
  - **`throws_autoprop_test` — a bare `throws` call in a try-block.** `.outer()` (throws, no `?`) inside
    a method-level `catch` emits bare `self.outer();` → "error union is ignored". `.inner()?` (explicit)
    works, so throws DETECTION is fine; the try-block CATCH-wiring at genMemberCall ~12950
    (`callee_throws2 and try_block_label != nil`) doesn't fire for `.outer()` despite both conditions
    appearing set — a context bug (couldn't pin statically; needs instrumentation). The bootstrap does
    this at the STATEMENT level (src/CodeGen.zig genStmt ~6843: `e is call and try_block_label and
    exprCallIsThrows`) — mirroring that (statement-level catch) is the likely clean convergence, but
    verify it doesn't double-emit with the existing 12950 path.
  </details>
  (Resolution note: fixed instead in the user-method early-exit, which was the real path both
  gaps flowed through — see the closed entry above.)

- [x] **Grammar fuzzer (generative)** [idea Sean 2026-07-22 → BUILT 2026-07-23]. `fuzz/gramgen.py`:
  coverage-guided CFG derivation from `grammar.txt` (production choice weighted 1/(1+times_used) →
  94% production coverage over 200 programs), stateful indent/dedent renderer, plugs into the
  existing `harness.check(zig_check=False)` oracle. Complements `gen.py` (semantic) by attacking the
  front-end accept/reject space directly. **First runs paid off immediately:** found **BUG-199** (an
  18-byte selfhost parser INFINITE LOOP, `readonly struct b` — now FIXED + gated), plus lower-signal
  divergences (G2 empty-body decl leniency, G3 size-type alias resolution, G4 misc) and a dead
  grammar rule (`ValueArg*`). Findings in `fuzz/FINDINGS.md` (G-series). Note on "Earley": generation
  is CFG *derivation* (no parsing algorithm needed); Earley matters only for the inverse.
  - [ ] **Follow-ups (optional):** address G2 (selfhost accepts body-less `struct`/`extend`);
    dead-rule cleanup in `grammar.txt`; add a front-end-only oracle mode (parse/`--check` rather
    than full `--emit-zig`) so resolver/TC divergences aren't swamped by legit "undefined name"
    rejections; ~~consider gating a fixed-seed gramgen batch (assert no crashes/hangs) per
    session~~ — **DONE 2026-08-19**: `gramgen --gate` is registered in the new `--daily` tier
    of `gates.sh` (960 deterministic programs, gated on hangs and crashes only, since
    accept/reject divergences are expected). "Per session" was the right cadence to ask for
    and the wrong thing to encode: a cadence nobody can run is a paragraph. It is now a tier
    with a name.

- [ ] **`indexOf` nil-safe API (principled `int?`)** [deferred 2026-07-22, Sean's call: revisit
  during hands-on language testing]. `str.indexOf`/`lastIndexOf` currently return `int` with a `-1`
  sentinel (matches the reference bootstrap + `main.zbr` usage; the documented `int?` was never
  implemented — the codegen always emitted `i64`). The nil-safe `int?` (nil-not-found) fits the
  language's Eiffel-style **nil-tracking** pillar and is the preferred long-term shape. Doing it is
  a deliberate cross-compiler change: type `int?` + emit `?i64` in BOTH compilers, and fix
  `main.zbr`'s `indexOf(" ") + 1` (→ `!`/guard). `indexOfFrom`/`indexOfIgnoreCase` already return
  `int?` (do them too for consistency). Not incidental convergence work — its own small task.
  Emit all Zebra modules into **one** `.zig` file, each wrapped in a namespace `struct`, with
  **one** shared runtime preamble at file scope (today: one file *per module*, each inlining the
  full ~3712-line preamble). Wins: dissolves the **F5** name-collision class for free (namespaced
  user decls leave file scope, so preamble internals can't shadow them), emits the preamble once
  (the ~9-module selfhost compiles ~9 copies today), and **deletes** the cross-module
  `_initAllocator`/`_initIo`/`_zbr_error_msg` fan-out (`main.zig` hand-wires it for 8 modules).
  **Justification is architecture + F5-closure + simplification, NOT speed** — the spike measured
  the compile-time win as modest (~12 ms/preamble-copy frontend; Sema win real but unmeasurable in
  noise). Prototype compiled + ran; cross-module `use`, bare outward preamble resolution, and F5
  dissolution all verified. Real project: both emitters kept equivalent, round-trip goes
  single-artifact, phased behind a temporary `--single-file` flag. **Supervised, careful, gated.**
  → *Design + phased plan: `docs/single_file_emit_design.md`.* Supersedes the bespoke F5 fix.

## Dogfood programs (IO + net + threads — surface stdlib/runtime gaps; each self-verifies)

BUG-153 (module-global shared state) is fixed, so shared-state servers are
unblocked. The two-tier allocator wiring (§28j) is the remaining concurrency
foundation and needs a supervised session.

- [x] **§28j — thread-safe program allocator DONE (2026-07-24, `b5d1726`).** Shipped the
  ThreadSafeAllocator-wrapper approach (NOT per-thread arenas — that over-scoped it): a
  mutex around the shared arena (`_TsAlloc`/`_prog_alloc` in the preamble + bootstrap),
  `--single-threaded` flag → `-fsingle-threaded` (compiles the wrapper out; thread-spawn
  becomes a compile error). Validated by `thread_alloc_stress_test`. **Residual (post-1.0):**
  `allocate Arena()` scopes swap the global `_allocator` and race with workers (77% crash,
  captured by `arena_concurrency_hazard_test`) → rule: allocate-scopes are single-threaded-
  only. See `docs/concurrency_allocation_design.md`. Below = the ORIGINAL (superseded) plan.
- [ ] **§28j step b — two-tier allocator wiring** (per-thread arenas + a shared
  `Smp()` handle). Race is confirmed-in-code but latent-at-runtime; the fix is
  subtle with concurrency-lifetime failure modes the gates can't catch → supervised
  session, decide the shared-handle API first. → *Open detail §28j.*
- [ ] Concurrent web fetcher / link checker (worker threads pull URLs from a `Chan`,
  HTTP GET, aggregate).
- [ ] Parallel log-processing pipeline (`Dir`/`File` walk → workers → merged histogram).
- [ ] Multithreaded Mandelbrot / ray tracer → PPM (compute fan-out + binary IO).
- [ ] Pub/sub or LAN chat broker (TCP + client threads + `Chan` broadcast).
- [ ] MapReduce word-count over the Greek NT / a large corpus (threads + IO + Unicode).
- [ ] Tiny HTTP JSON API persisted to SQLite + a concurrent client smoke test.
- [ ] **§9 — Greek NT n-gram port** (SIMD landed, the deferred-wait is over): file
  I/O, Unicode `HashMap` keys, sort, sliding n-gram window, TF-IDF / cosine via
  `f32x8`. → *Open detail §9.*

## Tooling & LSP polish (mostly post-1.0 ergonomics)

- [ ] **LSP follow-ups** (epic is Phases 1–4h done; see Completed-recent): scope-aware
  locals / shadowing / cross-file resolution; per-document-VERSION parse cache
  (blocked only by AST/arena lifetime, not concurrency); member-completion dedup;
  VS Code click-test + `.vsix` package/publish.
- [ ] **Formatter re-indent** to canonical 4-space nesting (needs INDENT/DEDENT +
  continuation handling; natural follow-on now the string-safe scanner exists).
- [ ] **IDE** — advance one stalled ZebraIDE experiment (tree widget / Debug button
  DAP client via `zebra debug --listen PORT`); install LLDB on Windows to test the
  debugger end-to-end.
- [ ] **N-API follow-ups** — cross-platform `.node` (Linux undefined-symbol default;
  macOS `-undefined dynamic_lookup`) + doc; richer `test/node_addon` matrix.

## Environment / repo cleanup (safe, unattended)

- [ ] Prune the stale session task list to the genuinely-open few.
- [ ] **Wiki sync** — N-API, First Horseman, bootstrap convergence, the GameEngine
  boss-move layer → `project_zebra.md`; lint dates.
- [ ] Tidy scratchpad repros into `examples/` or delete.

---

# Open — detail

## §15 — 1.0: language stability + CHANGELOG (cumulative commitment)

1.0 is the **full API surface delivered through all prior 0.x milestones, locked
with a stability promise.** Everything in the checklist below is delivered; the
open act is the *freeze* + a final CHANGELOG pass.

**Stability commitment — 1.0 must have all of (all ✅ delivered):**
- ✅ Generics (0.8); Contracts (`require`/`ensure`/`invariant`/`old`/`result`/`--turbo`, 0.12)
- ✅ All stdlib through 0.4–0.15 (Math, Json, DateTime, CSV, Hash, Random, Arg,
  Terminal, Log, Uri, Compress, Mime, Timer, Regex, Http, Tcp, Udp, Net, File, sys,
  Gui, Reflect, Path, Profile, SIMD, SQLite, WebSocket, ThreadPool, Atomic, …)
- ✅ Self-hosting + bootstrap round-trip (Phase 22); source-mapped errors (0.5)
- ✅ 0.11 (REPL, JSON auto-inference, gzip, debugger/DAP, build system); 0.13
  (BUG-115, `^T` fixes); 0.14 (full `<-` deep-copy, `Chan(T)`, allocator context);
  0.15 (syntax cleanup, stdlib completeness, libui-ng); `--target node-addon`
- ~~regex per-quantifier~~ → post-1.0 (§7)

**Open:** the stability freeze itself + a final CHANGELOG reconciliation pass over
the 0.1 → 1.0 surface (CHANGELOG.md exists as of 2026-05-26; re-verify it covers
everything since).

## §28a — inference-or-error rule (step 4 open) [ADOPTED — Sean 2026-07-03]

No typed-dispatch site may guess: if inference is empty, emit a diagnostic, not a
guessed emit. Steps 1–3 done (instrumentation → closed every corpus inference gap →
`check_inference_guess.sh` gate, corpus at 0). **Step 4 open:** the language-level
flip — a residual guess becomes a "cannot infer type of X; annotate" compile error.
Systemic fix for the F7/BUG-162/BUG-168 class. Raises the priority of §24e.

**Spike findings (2026-07-15) — scope decided [Sean: "flip the selfhost if it guesses"]:**
The guess INSTRUMENTATION + gate are **bootstrap-only** (bootstrap sites:
`src/CodeGen.zig` ~7503 list_dispatch, ~7562 len_count, ~16196 add; `noteInferenceGuess`
+ `warn_inference_guess`). But the **selfhost guesses too** — `genBinary` add
(`selfhost/CodeGen.zbr:8818`) does `if isStringBoth(l/r) → _str_concat; else → numeric +`,
so an un-inferable operand silently defaults to numeric `+` (the same F7/BUG-168
fallback). `isPrimType` (just below `isStringBoth`) is the "proven-prim" check the gate
needs. The other two selfhost sites (len/count, List-method routing) share the shape.
On the corpus the guess is always *correct* (smoke 236/236, round-trip byte-identical)
but **ungated** — so the flip = add the `isPrimType` gate and turn "neither string nor
proven-prim" into an error.

**This is the §28a campaign re-run on the selfhost (not a one-shot). Measure-first,
per §28a's own discipline.**

**Phase 1 (measure) — DONE 2026-07-15.** Instrumented the 3 selfhost guess sites
(`selfhost/CodeGen.zbr`: `add` ~8874, `len_count` ~8315, `list_dispatch` ~10950),
recording unconditionally via the §28b `_implicit_try_sites` mechanism; reported under
`--warn-inference-guess` (behavior-neutral, no exit). Tool: `tools/measure_selfhost_guess.sh`.

**Result: 80 unique sites** in `selfhost/*.zbr` (add 6, len_count 30, list_dispatch 44;
60 in `CodeGen.zbr`) — **NOT 0**, so not "flip freely". BUT triage found **~zero genuine
ambiguity** — every sampled site emits CORRECT code. Two causes:
1. *Non-guesses the instrumentation over-flags* — user-class field/method on an un-inferred
   receiver: `StrSet.len` (a real `var len: int` field), `args.contains()` (`args = Arg.parse()`,
   a user `Arg` method). ~15 of 44 list_dispatch are `args.contains` alone.
2. *Benign under-inference* — e.g. `(l.len - t.len) + kw.len` is int arithmetic flagged only
   because `inferExpr` doesn't type `.len` → int; `x = c.items(); x.at(i)` routes right by name
   because the `.items()` return type isn't propagated.

**Why ≠ bootstrap (which reached 0 standalone):** the bootstrap consults a global per-expr
type map (`tc.expr_types.get(e)`); the selfhost `InferCtx` has only `scope: HashMap(str,Type_)`
+ on-demand `inferExpr`, which returns `unknown_` for `.len`, call-returns, user-class fields.
No per-expr map exists → precision = strengthening inference, not a lookup.

**Decision (Sean 2026-07-15): land Phase 1 record-only, then step 2, then flip.** NOT the
scope-down (bootstrap gate already provides the user-facing guarantee at 0) and NOT a rush to
flip (would convert ~80 benign under-inferences into false errors).

**Step 2 (in progress) — close the inference root causes**, re-measuring toward 0.
Measurable selfhost/* count (excl. main.zbr/pipeline_test, BUG-181): started **add 6 /
len_count 30 / list_dispatch 27**.

Done (2026-07-15/16):
- ✅ **`inferExpr(.len / .count())` → int** (commit 5c78c17) — `add` bucket 6 → 0. Also
  covers `inferExpr(arith of prims)` since the existing binary handler already propagated
  numeric; the only gap was `.len` not being numeric.
- ✅ **`len_count` guard → `typeIsUnknown`** (commit 9204a0b) — 30 → 18. Dropped proven-receiver
  false positives (StrSet-param `.len` field reads were never ambiguous). Emit-neutral.
- ✅ **StrSet method returns on param/field receivers** (commit 04231dc) — **a real latent
  selfhost MISCOMPILE**, not a benign guess. `StrSet` has a dedicated `Type_.str_set` variant,
  so a param/field typed `StrSet` infers to `str_set` (a `StrSet()` ctor infers to
  `named("StrSet")` and worked); the call handler had no `str_set` arm, so `strset.items()`
  was unresolved and the result local emitted `.len` (string-shaped) — WRONG on an ArrayList
  (`no field named 'len'`). Hidden because the committed `.zig` is bootstrap-generated and the
  round-trip shares the same (wrong) inference on both sides. Added a `str_set` arm
  (`items()`→List(str), `contains_()`→bool). A probe that miscompiled now compiles+runs.
  Cleared the whole CodeGen cluster: len_count 18 → 9, list_dispatch 27 → 18.
  **Precision caveat (2026-07-16, not overclaiming severity):** `StrSet` is *compiler-internal*
  (not user-facing), so this miscompile's blast radius is narrow — it can only appear in
  selfhost code, and the compiler-source usages that would trigger it are mostly guarded by
  `localIsList`-style tracking (which is why the round-trip's A/B builds passed with the bug
  present — the pattern wasn't hit in a breaking form in the compiled path). It is a REAL
  latent miscompile (the probe proves it) and the fix is correct, but it is not a user-facing
  crisis. **The generalizable thread was hunted (2026-07-16) and the class is now BOUNDED:** of
  the 4 dedicated-`Type_` variants with no `inferExpr` call-handler arm (`str_slice`,
  `allocator_ctx`, `sqlite_row_list`, `gui_context`), only **`sqlite_row_list` was a real
  user-facing bug** → **BUG-182** (`db.query(...).at(i)` result untyped → `.asInt`/`.asStr`
  miscompile), fixed in the selfhost. `gui_context` is safe (its value-returners are primitives,
  no struct-dispatch hazard), `str_slice` is a handled sentinel, `allocator_ctx` is internal.
  The hazard requires a *struct-returning* method whose result loses its type; primitive-returners
  don't trip it. Found via the independent witness (`compile_check`), not the corpus.

**This overturns the Phase-1 "~0 genuine ambiguity / emit always correct" read:** for the
selfhost's OWN emit the guesses were producing wrong code; only bootstrap regen masked it.
§28a is fixing real latent miscompiles on the road to selfhost-as-regen-authority, not just
tidying benign guesses.

**⚠️ SCOPE CORRECTION (2026-07-16 full-corpus measure).** The per-file iteration above measured
only NON-`main` selfhost source. The authoritative full-corpus measure (420 files, per-file
timeout) was **143 unique sites: add 40 / len_count 30 / list_dispatch 73** → now **140 (add 37 /
len_count 30 / list_dispatch 73)** after the typed-lambda fix. So "add bucket → 0" holds ONLY for
the non-`main` compiler files; corpus-wide much remains. Distribution: lexer_test 33,
test/csv_test 24, `main.zbr` 19, test/list_functional 10, Parser 9, AstBuilder 5, +~30 other test/
files, examples/life 4. Root-cause patterns still open:
- ✅ **Typed lambda params** (commit c9c85f9) — `genLambdaEx` now seeds a fresh InferCtx with
  the lambda's DECLARED param types (mirroring genMethod), used for BOTH the `@TypeOf(body)`
  return-type inference and the body. `def(x: int) = x + x` / `def(acc: int, x: int) = acc + x`
  no longer guess. Round-trip byte-identical, smoke 236/236. **Corpus delta: 143 → 140 (add 40 →
  37) — only 3 sites, because the corpus lambda-`add` guesses are dominated by UNTYPED functional-
  trio lambdas (below).** Value is the seeding INFRASTRUCTURE the untyped work builds on, not the
  raw count.
- **Untyped functional-trio lambda params** (the remaining `add` driver): `def(acc, x) = acc + x`,
  `def(x) = x * 2` — params carry no declared type, so they bind unknown and still guess. Their
  types must be DERIVED from the higher-order fn's signature: for `nums.reduce(0, def(acc,x)=…)`
  with `nums: List(E)`, `acc` = init's type, `x` = `E`; for `map`/`filter`, `x` = `E`. Needs
  call-site→lambda param-type plumbing (the reduce/map/filter codegen passes derived types into
  `genLambdaEx`), method-specific — moderate risk, a supervised session. Affects list_functional /
  csv / many tests.
- **Cross-module STATIC returns** (`toks = Lexer.tokenize()` on a module name → unknown) —
  lexer_test cluster (~23). Module-static method-return resolution across deps; helps user
  `Module.staticFn()` too.
- **`main.zbr`'s own 19 sites** (2 add: 755/1113; 17 list_dispatch: the `args.contains` /
  `Arg.parse()` cluster — `Arg.parse()` return type not propagated). Never measured pre-fix
  (main.zbr didn't finish compiling; see BUG-181, now ~6s).
- 2 known-hard singletons (flow-sensitive `var a2=a` reassignment; cur_line noise).

NON-main compiler source IS essentially cleared (0/9/18 on those files) and a real miscompile
was fixed — but the flip (step 3) is NOT close corpus-wide; the lambda-param feature is the
largest remaining lever. Re-assess scope with Sean.

**BUG-181 RESOLVED (2026-07-22):** `main.zbr` now self-compiles cleanly (emit rc=0, emitted Zig
builds; proven end-to-end — the self-made 2.3MB compiler compiles a program that runs). 8 emit
divergences fixed, gated by `tools/selfcompile_check.sh`. The §28a-step-4 CONSTRAINT below (main.zbr
can't be in the both-compilers-reject probe) is now LIFTED. See BUGS.md BUG-181.

**Step 3 (the flip) — only once the selfhost standalone count is ~0.** Error + `--allow-inference-guess`
hatch + promote the measure to an enforcing gate. Follow the §28b template (commit 0a591ce):
module-global sites list, driver-level reject in `main.zbr` (NOT `@compileError` — malforms
expression-position sites), `cur_line` on the shared Writer for the location. **The round-trip
won't catch selfhost-vs-bootstrap divergence** — the flip acts as a differential probe (§28b
caught `Parser.zbr:3164`). CONSTRAINT: `main.zbr` can't be part of the both-compilers-reject
validation — the selfhost can't compile it (BUG-181).

Also consider (Sean, if bootstrap kept longer): flip the bootstrap's 3 sites too
(mirror §28b's `rejectImplicitTry`) for user-code parity — low-risk, marginal value
(bootstrap phasing out; divergence is bootstrap-conservative = safe direction).

## §28b — unify error propagation on always-explicit `?` ✅ DONE (step 5 flipped 2026-07-15)

All five steps complete. Steps 1–4 (2026-07-02): instrumentation → swept `?` into
441 auto-try sites → inventory 0 → `check_explicit_try.sh` gate. **Step 5 (the flip,
2026-07-15):** an omitted `?` on a throws call is now a **compile error in both
compilers**, via a **driver-level diagnostic** (NOT `@compileError` — 4 of 5 sites
are expression-position and would malform the emit). A valid `try` is still emitted;
the driver collects the sites and rejects with `file:line: throws call needs '?'`
after codegen. `--allow-implicit-try` is the one-release migration hatch. Bootstrap:
a `pub var implicit_try_sites` global + `rejectImplicitTry` in `main.zig`. Selfhost:
a file-scope `_implicit_try_sites` (mirroring `boss_director`'s registry) + `cur_line`
on the shared Writer + the check in `main.zbr`. Gates: smoke 236/236, round-trip
byte-identical, corpus 0. QUICKSTART §12 + CHANGELOG updated. Regression:
`test/fail_fixtures/implicit_try_rejected_test.zbr` (smoke_tc_fail).

**Surfaced + fixed:** the flip caught `selfhost/Parser.zbr:3164` (`return
p.parseModule()`) — a genuine implicit-try the bootstrap's instrumentation never
flagged because the bootstrap emits an **error-union passthrough** (`return X`, no
`try`) there while the selfhost auto-`try`s it. Adding `?` converged both emitters
(→ `return try …`) and completed the sweep.

**Residual divergence (acceptable, documented):** the selfhost flip rejects
return-position throws calls on a local (`return x.method()` without `?`); the
bootstrap uses passthrough there, so it does *not* reject them. Selfhost-stricter is
the acceptable direction (bootstrap phasing out); a user hitting the selfhost
rejection just adds `?` (the intended fix). Close by extending the bootstrap's
return-path detection if the bootstrap is kept longer.

## §28e — spec `str` ownership per stdlib call

`str` is sometimes borrowed (`s[a..b]`), sometimes freshly allocated (`concat`,
`File.read`) — invisible under the program arena, load-bearing inside `allocate`
scopes and threads. Pre-1.0 task = a per-call borrows-vs-owns table in the
spec/QUICKSTART, so the 1.5 `str_view` design has defined ground.

**Landed 2026-07-29.** `docs/str_ownership.md` (generated, gated) + QUICKSTART rules.
The table is DERIVED from emit, not read off codegen, because ~28 near-identical
classification judgements is precisely the work that drifts — and the derivation found
two things a reading would have flattened: the owned-container-of-borrowed-elements
split for `split`/`lines`/`tokenize`, and that `charAt` is a byte VALUE that belongs in
neither class. Regenerate with `--write` after any string codegen change; `--check` is
gated so a flip cannot ship silently.

**Ground this hands to the 1.5 `str_view` design:** a view type needs to express *two*
lifetimes, not one — the container's and the elements'. A `str_view` that only models
"points into something else" still cannot type `split`'s result correctly.

## §28f — generic `Set(T)` [DONE — 2026-07-24], from scratch

**Shipped selfhost-only.** `Type_.set_` variant emitting `AutoHashMap(T, void)` /
`StringHashMap(void)`; `add`/`contains`/`remove`/`len`/`count`/`items`→`List(T)`/`clear`,
`for x in set`, `x in set`; local/param(by-ptr)/field/return/nested. Decisions taken:
str specialized, `items()`→`List(T)`, StrSet stays internal. `add()` interns str keys;
`items()` and `for-in` reuse `_zebra_map_keys`; `in` reuses `_zebra_in` (`@hasDecl
"contains"`). Limits (=HashMap keys): T auto-hashable; no `==`/`print(set)`. The
bootstrap does NOT implement Set (sunsetting) — it shows as an informational
divergence bootstrap-gap; round-trip holds because the compiler's own source never
uses Set. Historical scoping notes below.


The "mirror the existing StrSet API" premise is **invalid**: `StrSet` is a
selfhost-internal Zig type, not user-facing. So `Set(T)` is a HashMap-sized new
builtin: special-case the void value (`AutoHashMap(T, void)` / `StringHashMap(void)`
for str), set methods (add→put(x,{}), contains, remove, count, items→List), for-in,
TC, both compilers. **Decisions to confirm:** str-key specialization; does `items()`
return `List(T)`; expose a `Set(str)` alias or leave StrSet retired. Own gated pass.
Related: the functional trio (`map/filter/reduce/sort/sortBy`), `HashMap.keys/values/
entries` all shipped (see Completed-recent). Broader follow-up: a fuzz surface for
lambda-taking list methods (none fuzzed today — would come as one lambda-generation
capability).

## §28j — `_allocator` under threads → two-tier model (step b open) [DIRECTION SET — Sean 2026-07-03]

> **Design research (2026-07-23): `docs/concurrency_allocation_design.md`.** Comparing
> Zig (`ThreadSafeAllocator`, `SmpAllocator` — a GC-free per-thread-cache with
> thread-exit reclamation, both in std) and Go (per-P `mcache` tiers + GC-owned
> lifetime) reframes §28j and **shrinks it**: lead with SHARE-NOTHING (per-thread arenas
> + copy-on-`Chan`/`<<-`, which Zebra already does) so the cross-thread use-after-free
> class is avoided by construction; provide a thread-safe FALLBACK tier for genuine
> shared state by *adopting* a std allocator (`ThreadSafeAllocator` → `SmpAllocator`),
> not inventing one. Residual real work: per-thread arena wiring + audit that
> cross-thread paths copy + a threaded-lifetime gate + a thin opt-in shared annotation.
> Still supervised. See the note for the full comparison + recommendation.


Arena allocators aren't thread-safe; workers sharing the program arena is a latent
race. **Measurement done (step a, 2026-07-04):** race CONFIRMED in code (`_allocator`
is one global non-thread-safe arena; ThreadPool/`sys.go` workers don't swap it) but
did NOT manifest at runtime (200 tasks × 4000 allocs × 16 threads, ~15 runs, zero
corruption — narrow window; UB and latent, not frequently-firing). **Step b open —
WIRING, supervised session (design + risk):** making `_allocator` `threadlocal` fixes
the temporary race but then worker-allocated data a later thread reads → use-after-
free, and that's invisible to single-threaded gates. Correct model = both tiers wired
+ a clean Zebra handle for "allocate in the shared pool" (`Smp()`) — an API design
call (keyword? `shared` block? `sys.sharedAlloc()`?). Add a threaded *lifetime* test
to the gate set, not just the alloc-race probe. Unblocks correct shared-state servers
(the BUG-153/154 territory). **Not for unsupervised work.**

**Prior art — xsync.zig** (assessed 2026-07-21; MIT, single-file, Zig 0.16+master):
cross-`std.Io` **cancellation-safe** sync primitives (Mutex/Condition/Event/Semaphore/
RwLock/`Queue(T)` w/ timeout+close). Strong fit for Zebra's concurrency layer:
reimplement `Chan(T)` on `xsync.Queue`, close **BUG-154** (Tcp.serve no-lock) with
`xsync.Mutex`. **VENDOR** it (not a live dep — binary-size/control) and **read its 3
stdlib-Condition bug reports** (Zebra may share those latent bugs). Value scales with
one decision: **near-essential IF Zebra adds an evented `std.Io` runtime** (green
threads, no OS-thread-per-connection — servers are thread-per-conn today, won't reach
C10k); nice-to-have if threaded-only. Full assessment: memory `project_xsync_concurrency`.
github.com/lalinsky/xsync.zig

## §19.5d — bootstrap-check feedback latency

`tools/bootstrap_check.sh` is the integration safety net but slow under CPU throttle
(5–10 min observed). Profile + optimize where cheap (parallel build steps, cache-
invalidation tightening). Gated on a profiling pass.

## §9 — Greek NT n-gram port

SIMD types shipped 2026-05-08 — the deferral reason is gone. Scope: file I/O,
`HashMap` with Unicode keys, sort, sliding n-gram window, TF-IDF / cosine similarity
via `f32x8` dot-product. `--cpu=native`/`--cpu=x86_64+avx2` passthrough shipped
(QUICKSTART §32, SIGILL hazard noted). See `concept_zebra-simd-design.md`. (Runtime
CPU dispatch — oma-style — is post-1.0.)

## Fuzzer (`fuzz/`) — remaining coverage

Found + fixed 12 real equivalence bugs (F1–F12 → BUG-159…167, 161/162, 173).
Post-fix sweeps clean (seeds 0–99 run-oracle 100/100). **Open:** grow `DEFAULT_CAPS`
into high-bug-history combinations — remaining caps need class-relationship
generation: (4) `^T` boxing, (5) interfaces + `is`, (6) generics / backed-enums /
chained-cmp. Grow grammar surfaces (generics, error/throws, branch/enum). Caution:
`stmtMentionsThis` must stay EXACT. Generic *functions* are intentionally selfhost-
only — do NOT fuzz them as an equivalence surface. Sized numerics (`List(int32)`)
fail at the parser (BUG-172 follow-on). See `fuzz/README.md` + `FINDINGS.md`.

## Open Bugs (not tied to an open milestone slot)

- **Selfhost `_initIo` propagation gap** — selfhost-emitted dep modules get a simple
  `_initIo` (local `_io` only); bootstrap-emitted ones propagate to transitive deps.
  Harmless now (`Ast`/`CgHelpers`/`TypeChecker` don't call `_io` ops directly); would
  silently use undefined `_io` if a transitive dep gains file I/O. Fix: emit a
  propagating `_initIo` in `generateModuleWith`. **Track for 1.0 pre-flight.**
- **BUG-180** — bootstrap ctor-default fill (see Compiler hardening). Bootstrap-only.
- **BUG-026** — `instance_method_return_types` gaps for exposed-type method chains.
  Not manifesting (`scanMutationsInExpr` conservatively marks cross-module calls
  mutated). Defer unless a concrete failing case appears.
- **BUG-014** — regex lazy match is global, not per-quantifier (`<.*?>STUFF.*>`
  misbehaves). Architectural (priority-first NFA / backtracking). **Deferred
  post-1.0 (§7);** workaround = split/restructure the pattern.
- **SQLite feature defines not passed to the vendored `sqlite3.c`** — the
  compiler adds `sqlite3.c` to the zig build (`selfhost/main.zbr` ~2703) with no
  `-DSQLITE_ENABLE_*` defines, so every feature the amalgamation fences behind
  `#ifdef` (FTS5, RTREE, JSON1 config, etc.) silently compiles out. Surfaced via
  the Graze docs-browser: FTS5 search returned "no such module: fts5" in-app but
  17 hits in `testfixture` — the tell that the *flag*, not the query, was
  missing. **Interim fix (zebra-sprocket `cfc91e1`):** `apply_sprocket_patch.py`
  prepends `#define SQLITE_ENABLE_FTS5 1` to the vendored file, seam-side.
  **Upstream fix:** the compiler should pass the feature-define set (at minimum
  FTS5) when it adds `sqlite3.c` — ideally a small `sqlite_features` knob rather
  than a hardcoded list, so a program can ask for RTREE/JSON without another
  seam patch. Interim workaround is a silent-failure trap if the define is ever
  dropped; make it a build flag, not a prepend. Filed for Opus.

---

# Post-1.0

- **§7 — Regex per-quantifier lazy/greedy** (BUG-014). Per-node shortest/longest
  flags; architectural. Workaround: split the pattern.
- **§6 — REPL resident compiler.** Measured: `zig run` cold 4s / warm 119ms; every
  REPL entry is a cold compile (session file changes each entry); `-fincremental`
  doesn't help on Zig 0.16 Windows (linker state not saved). Options: Zig 0.17+
  incremental linker, or a native Zebra interpreter (~2–3 wk). Deferred.
- **§24e — single method-descriptor table.** One spec driving both TC inference and
  codegen dispatch (replaces the 4-place pattern). Priority raised by §28a.
- **SIMD runtime CPU dispatch** — oma-style startup detection (SSE2→AVX2→AVX-512 /
  NEON→SVE2) without separate builds. Design spike.
- **§13 — VCS in Zebra** (capstone). Pijul-shaped patch algebra + typecheck-as-merge.
  Daily-useful pieces already shipped (§19.5). Research/teaching artifact.
  `concept_zebra-vcs-architecture.md`.
- **§14 — IDE (self-hosted), MVU redesign.** ZigZag TUI canonical backend shipped
  (`--gui-backend=tui`, 2026-05-21). Remaining: libui-ng adapter (~200–300 lines
  widget-cache reconciliation + two Zig 0.16 `build.zig` fixes). `concept_zebra-gui-redesign.md`.
- **§17 — 1.5: WASM target + web frontend SDK.** `--target wasm32-freestanding`/`-wasi`,
  `export def`→`export fn`, JS shim, module blacklist, AlpineJS. Shares `@freestanding`
  + blacklist infra with §22. ~2–3 wk. Key decisions: `throws` at boundary; class/struct
  passing; `print()` buffering. `concept_zebra-wasm-frontend.md`.
- **§17b — 1.5: Http server ergonomics** (swerver-inspired): (a) arena-per-request
  handler model; (b) **`str_view` borrowed slice** — the biggest structural gap
  between Zebra's owned `str` and high-perf servers (needs a lifetime-annotation
  design spike); (c) `BoundedPool(T, N)` with LIFO free-stack + double-release bitmap.
  `concept_zebra-http-design.md`.
- **§26 — 1.5: Zig `@builtin` access** (three tiers): T1 native promotions
  (`sizeof`/`alignof`/`typeof`/`bitcast`); T2 semantic namespaces (`Atomic.*`/`Ptr.*`/
  `Int.*`/`Simd.*`); T3 transparent `@name(args)` pass-through for ~60 more. ~1 wk.
  Removes a primary impediment to writing engine/systems code in Zebra.
- **§22 — 2.0: Kernel track.** `.zbr`/`.zeb` split; `@freestanding` mode; `core`
  stdlib; naked/interrupt callconv, inline asm, `@section`, `@embed_file`, `volatile`,
  `Cpu.*`. Plus the 2.0 WASM additions (multi-file, source maps, wasm-opt,
  serialization). `concept_zebra-os-additions.md`. Reference: BamOS.
- **§16 — Intertextual support.** LXX/MT divergence tool; provenance typing.
  RESERVED for post-1.0. `project_intertextual.md`.

---

# Completed — recent (full detail)

## EPIC: Language Server (LSP) — Phases 1 → 4h ✅ (2026-07-09 → 07-10)

Written **in Zebra** (flagship dogfood + reuses the front-end directly). An LSP is
the biggest daily-ergonomics lever for any language. Open follow-ups are in the
Tooling section above.

- **Phase 1 ✅** — diagnostics *seam*: `zebra diagnostics <file> [--out <json>]` runs
  parse→resolve→typecheck → JSON `{line,col,severity,message}`. Reuses `tcCheckSide`;
  line/col are the trailing numeric fields (robust to the Windows drive-colon).
  `tools/lsp_diagnostics_smoke.sh` + `test/lsp/*.zbr`. NOTE: `print` lands on stderr
  on the Windows fast-backend (so does `--emit-zig`) → `--out <file>` is the clean
  consumer interface.
- **Phase 2 ✅** — `zebra lsp`: a stdio Language Server (JSON-RPC, Content-Length) IN
  `main.zbr`, front-end in-process. `initialize`/`shutdown`/`exit`, `didOpen`/`didChange`/
  `didClose` → `publishDiagnostics`. Transport: `Terminal.write` (real stdout, pipe-
  capable — NOT `print`); stdin via `sys.readLine` + new `sys.readBytes(n)`. Dynamic
  JSON via `Json.parse`. `tools/lsp_server_smoke.py`.
- **Phase 3 ✅** — VS Code extension `editors/vscode/`: thin `vscode-languageclient`
  (9.0.1) over stdio + TextMate grammar + language config. Verified headless (server
  5/5); not yet click-tested inside VS Code.
- **Phase 4a ✅** — formatting (`fmtNormalize`, full-document TextEdit) + documentSymbol
  (module decls → LSP symbols, members nested). Buffers stored in a `docs` map. 8/8.
- **Phase 4b ✅** — hover (markdown code-fence signature via `typeRefStr`) + go-to-
  definition (per-buffer decl index; `lspWordAt`). Constraint found: selfhost
  AstBuilder used `zspan()` = all-zero, so definition fell back to a text search
  (later retired by 4d). Worked around a `List(char)`-ctor round-trip divergence
  (BUG-172). 10/10.
- **Phase 4c ✅** — completion (keywords + declared symbols with kinds/detail). 11/11.
- **Phase 4d ✅** — real source spans on declarations. Parser records the name-token
  position on every decl PNode; AstBuilder threads it via `nameSpan()`. documentSymbol
  ranges now real + name-precise; definition uses the AST span (text search only a
  mid-edit fallback). Internal only — emitted Zig unchanged (round-trip byte-identical).
  Commit f0d9111. Retires the 4b `zspan()` limitation.
- **Phase 4e ✅** — member completion after `.`: `self.`/`this.`/leading-dot → enclosing
  type; type name → members/enum variants; annotated/constructed local → its type's
  members. `.` as trigger. Text-based receiver resolution; unresolved → empty, not
  noisy globals. Commit 78ada96. 12/12.
- **Phase 4f ✅** — formatter v2: inter-token space collapse with byte-for-byte string/
  comment preservation (string/comment-aware line scanner; every mis-read errs toward
  staying *inside* a string). Gated by `tools/fmt_safety.py` (11 fixtures + idempotence
  on 413 files + emit-equivalence: 123 files reformatted, all emit byte-identical Zig).
  Open: canonical re-indent (Tooling section).
- **Phase 4g ✅** — signatureHelp (`(`/`,`; innermost enclosing call, depth-aware comma
  split so `HashMap(str,int)` stays one param; `activeParameter`). Robustness: unknown
  **requests** → `MethodNotFound` (-32601). Functions/methods, single-line. 14/14.
- **Phase 4h ✅** — diagnostics debounce: a `sys.go` reader forwards stdin to a
  `Chan(str)`; main loop `recvTimeout(0.2)` flushes on a ~200ms lull. `didChange` marks
  dirty; a burst coalesces to ONE analysis. Detached reader (so `exit` doesn't hang on
  the stdin-blocked thread); EOF via `Atomic(bool)` + `Chan.close()`. Built on
  `Chan.recvTimeout`. Round-trip byte-identical.
- **Channel timed/non-blocking receive ✅** — `ch.tryRecv(): T?` + `ch.recvTimeout(secs): T?`
  (poll-based, ~2ms granularity; upgradeable to futex timed-wait). Verified under BOTH
  compilers, round-trip byte-identical. *Not done:* a true multi-channel Go-style
  `select` (own project; Zig gives nothing to borrow) — the single-channel-merge +
  `recvTimeout` idiom covers most needs.

## §28 — pre-1.0 design-review campaign (Fable/Opus/Sonnet, 2026-07-02 → 07-04) — mostly ✅

Open tails (§28a step 4, §28e, §28f, §28j step b) are in Open-detail (§28b flipped
2026-07-15 — see the §28b section above, now DONE)
above. Completed pieces:

- **§28c ✅ (07-04)** — exhaustiveness default-on (`--no-warn-non-exhaustive` to opt
  out; legacy `--warn-non-exhaustive` a no-op). Warnings stderr-only → round-trip
  unaffected. Feared "108 legacy `else` arms" a non-issue (selfhost's own sources: 0
  warnings). Error-by-default deferred to 2.0.
- **§28d ✅ (07-02)** — copy-out is `<<-`; `<-` is channel-only. `left_arrow_deep`
  token both compilers; one StmtCopyOut with a `deep` flag; `genCopyOut` enforces the
  pairing via `@compileError` into the emitted Zig (identical behavior both compilers).
  QUICKSTART §28/§35 swept.
- **§28f partial ✅** — functional trio + map utilities: `List.map/filter/reduce`
  (07-03), `HashMap.keys()/values()` (07-04, replaced a broken selfhost emit that
  called ArrayHashMap-only methods), `sort` optional comparator (07-04),
  `HashMap.entries()` → sortable `List((K,V))` (07-06). Higher-order lambda params now
  typed from the receiver's element type (fixes any/all/find/sortBy too). (`Set(T)`
  still open — §28f above.)
- **§28g ✅ (07-03/04)** — grammar cleanups: `to!` alias retired (`x!` won;
  `to_bang_removed_test` must-fail); `yield` removed completely (Zig has no coroutine
  to lower to; old codegen only emitted a `// yield` comment — clean deletion, 0
  migration); optional-FIELD `as`-unwrap confirmed working both compilers.
- **§28h ✅ (07-04)** — `ObjectPool(T)` stdlib: `pool.take()` → `^T?`, `give()`
  (contract-guarded double-release/foreign-object), `inUse()`. Modelled on `Chan(T)`.
  `ObjectPool(int)` intentionally fails (pooling primitives is pointless).
- **§28i ✅ (07-04)** — `sys.memStats()` → `MemStats{ arenaBytes }`
  (`_arena.queryCapacity()`, the high-water mark). Struct shape (not a bare int) so
  fields can be added later.
- **NOT recommended for change** (design-affirmed): `var`-only mutability (BUG-161 was
  an implementation bug, not a design flaw); contracts as identity feature; no
  inheritance; `cue init` (keep, document the Cobra etymology).
- **Synthesis → `docs/walker_discipline.md`:** the ten fixed bugs cluster into four
  structural causes. Standing rule: **new syntax lands with a fuzz generator surface +
  smoke fixture in the same commit.**

## Node.js addon target (`--target node-addon`) ✅ (2026-06-29 → 06-30)

`@node_export def add(a,b): int` + `zebra --target node-addon math.zbr` → `math.node` +
`math.js` shim + `math.d.ts`. Verified end-to-end in Node (int/float/bool/str). Both
compilers build a working `.node`; round-trip + smoke green. Selfhost emit parity,
per-call child arena for string marshaling (Phase 7), cross-platform symbol resolution
(Windows `node.lib` verified; Linux/macOS correct-by-construction), test harness
`test/node_addon/` via `tools/node_addon_test.sh` (Node + node-gyp; not in `zig build
test`). QUICKSTART §45. Follow-ups (cross-platform `.node`, richer matrix) in Tooling.

## Backlog dogfood + hygiene — recent ✅

- **TCP KV store + ThreadPool ✅ (2026-06-30)** — found 7 gaps; fixed BUG-150
  (`sys.sleep`→`std.Io.sleep`, Zig 0.16), 151 (`var _=` discard), 152 (`ThreadPool.submit`
  comptime-fn); filed 153 (module-global Atomic/HashMap — since FIXED), 154 (`Tcp.serve`
  per-conn concurrency, no lock — open, see §28j territory), 155/156 (since resolved).
- **Generated-Zig hygiene ✅ (2026-06-29)** — selfhost routes emit to a temp dir when
  no `--output-dir`; the 300 generated `test/*.zig` are gitignored (8 hand-written
  `.zig` `!`-excepted); `selfhost/*.zig` + `examples/*.zig` stay tracked. `git status`
  clean after regen.
- **Mosaic POC dogfood ✅ (2026-07-14)** — a differential Greek-NT port re-verified
  8 findings against HEAD; live ones filed BUG-175 (fixed: cwd-preamble panic),
  176/177/178 (all fixed), 179 (resolved-as-documented, drop-parity). Numeric
  conversions (`toString`/`toFloat`/`toInt`) confirmed correct & documented.

---

# Completed — archive (one-liners)

Detail in git / `BUGS.md` / `SELFHOST_JOURNAL.md` / `CHANGELOG.md` / wiki.

| Item | Done |
|------|------|
| §27 cross-module type resolution (27a free-fn return, 27b default-fill, 27c optional-return) | 2026-06-17 |
| §24 compiler ergonomics: exhaustive-match warning, cross-module `^T?` bindings, `?.` optional chaining, `genMemberCall` user-method early-exit, type-first dispatch | 2026-05-16/17 |
| §25 block comments `/# #/` (nested) | 2026-06-03 |
| §23 memory model: `allocate` Slices 1–6, `<-` copy-out deep-copy, `Chan(T)`, `sys.go` | 2026-05-12/18 |
| §19 / §19a error recovery: boundary-restart multi-error parse (both compilers), enum TC via `hasEnumAny`, `typecheck-merge`, source-mapped errors | 2026-05-27 |
| §12 syntax cleanup 0.13: BUG-115 visibility keywords, `this.field→.field` (1,141 sites), `def name:T→def name():T` (38 sites), `^T` auto-boxing | 2026-05-05/14 |
| §21 0.11: REPL, JSON auto-inference, gzip, debugger/DAP, `--module-path`, build system, `--cpu` passthrough, debug-run fast path (`-fno-llvm -fno-lld`) | 2026-05-12/06-20 |
| selfhost artifact refresh — committed = bootstrap-canonical, idempotent (BUG-135 path markers; PascalCase rename) | 2026-06-18 |
| 1.0 gap checklist — all `[x]` (REPL, ImGui LowLevel, tuples, generics, Zig 0.16, `<-`, `Chan`, refinement types, WebSocket, IANA tz, `using`, for-destructuring, CHANGELOG, node-addon, libui-ng widgets/dialogs/consolidation, visibility keywords) | 2026-05/06 |
| 0.15 stdlib completeness: Http.serve, ThreadPool, Path.*, gzip, Tcp.serve, Atomic, Log json/file, Crypto AES/SHA, SQLite, UDP | 2026-05-25 |
| Named `cue init` construction (`Point(y:5)`, reorder + default-fill; cross-module selfhost fill deferred) | 2026-05-19 |
| `x!` force-unwrap; `with` bare-method desugar; remove `try` prefix; inline `if x: y`; `Scope` interface; `is not` precedence | 2026-05-23/24 |
| Nested namespaces; DynLib producer (`@export`); plugin vtable demo | 2026-05-16/26 |
| Contracts (`require`/`ensure`/`invariant`/`old`/`result`/`--turbo`) — 0.12 | 2026-04-24/27 |
| Chained comparisons `a<b<c`; `unless`/`until`; `for-else`; `branch` struct-field patterns; `@[...]` array literals | 2026-04-23/26 |
| SIMD types (`f32x8`/etc.); guarded for-in + `List.find`; `@profile`; `Profile` module | 2026-05-06/08 |
| `Json.parseStrict` + `@reflectable`; `interface` fat-pointer vtable codegen | 2026-04-24/27 |
| String interning; optional-unwrap `as`; named/default param parity (selfhost); Phase 22 selfhost cutover | 2026-04-21/23 |
| User-defined generics (`class Stack(T)`) — 0.8; batteries-included stdlib | 2026-04-10 |
| `@once` + `sys.readLine`; TC Phase 5 generic→interface conformance; `typecheck-merge` + git hook; BUG-099 `.unknown` split; per-commit zip snapshot; style guide | 2026-05-04/10 |
| Self-hosting bootstrap round-trip (5/5); `pro`/`get`/`set`/`body`/`post` keyword removal; source-mapped errors (Phase 19); ImGui backend (stub + GLFW) | 2026-04-06/21 |

---

*Full milestone plan: `wiki/pages/projects/project_zebra.md`*
*Open bug details: `BUGS.md`*
*Self-hosting history: `SELFHOST_JOURNAL.md`*

**Last reorganized:** 2026-07-15 (open work curated at top; completed clumped at
bottom — LSP epic + §28 campaign + node-addon kept in full, older work archived to
one-liners). Prior detail preserved in git history.
