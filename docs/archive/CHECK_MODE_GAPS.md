<!-- doc-status: live -->
# What `zebra -c` cannot see, and what it would cost to teach it

**Started 2026-08-08** at Sean's request, after two occurrences in one session where
`-c` reported success on something a real compile rejected. This is a running log with a
difficulty triage, not a bug list — most entries are by design and the question is which
are worth changing.

## The mechanism, stated once

`selfhost/main.zbr:2560`:

```zebra
if mode_c and not check_full
    sys.exit(0)
```

**`-c` never invokes `zig` at all.** It runs parse → resolve → typecheck → codegen, emits
the Zig, and exits. So the framing "`-c` misses backend errors" is wrong: it never asks a
backend anything. `--check-full` is the mode that runs `zig`.

That is deliberate and it is the entire value of `-c`: measured this session, `-c` does
~458 ms of work against `--check-full`'s ~6314 ms — a 14× difference, on the command the
IDE Check button calls. Any proposal to "add X to `-c`" is a proposal to spend some of
that.

**Emission stays inside `-c` on purpose** (same comment): it is cheap next to zig and it
is what catches a codegen crash. So `-c` covers *"did the compiler fall over"* but not
*"is what it produced valid Zig."*

## The two distinct classes

Worth separating, because they have very different fixes:

| class | who it bites | can the front end know? |
|---|---|---|
| **A — user code whose EMIT is invalid** | anyone | sometimes; depends on the class |
| **B — selfhost source the BOOTSTRAP cannot compile** | compiler devs only | no; only a regen exercises it |

Class B is not a `-c` gap at all. `-c` runs the *selfhost* front end; the bootstrap is a
different compiler, and only `tools/rebuild.sh` (regen) puts it in front of selfhost
source. Nothing added to `-c` would cover it. **The correct instrument for class B already
exists and is the round-trip gate** — the lesson is procedural: after editing
`selfhost/*.zbr`, a green `-c` means nothing until the regen runs.

## Occurrences

### 1. Calling an auto-`throws` function without `?` — CLASS A
*Found 2026-08-08 while fixing BUG-275.*

```zebra
def risky(): int throws
    raise "boom"
def f(): int
    return risky()?          # f is auto-marked throws by inference
def main()
    print(f())               # no `?` — f throws, so this is wrong
```

`-c` → **rc=0**. `zig build-exe -fno-emit-bin` on the emitted file → `error: cannot print
error union without a specifier`.

**Difficulty: MEDIUM, and worth it.** The front end genuinely could know. `throws` is
inferred by `bodyHasRaise` at *codegen* time (`CodeGen.zbr:4514`), so the TypeChecker —
which is where a call-site check would live — has no idea `f` throws. Mirroring that
inference into the checker would let `-c` reject the call site directly, with a Zebra-term
diagnostic, and would ALSO fix a real asymmetry: §28b made implicit-try a compile error
for *declared* `throws`, but an *inferred* one slips through. So this is not only a
check-mode gap; it is a hole in a language rule that is supposed to be closed.

*Not attempted yet — filed here rather than acted on, because it is a TypeChecker change
and wants its own probe + both-directions fixture.*

### 2. `if opt as binding` on a `^Expr?` yields the pointer — CLASS B
*Found 2026-08-08, first attempt at BUG-275.*

`if sl.start as sst` then `exprHasTry(sst)` emitted `exprHasTry(sst)` with `sst:
*Ast.Expr`; the bootstrap rejected it (`expected type 'Ast.Expr', found '*Ast.Expr'`).
`zebra -c` passed. The safe form is `!= nil` + `!`, which emits `sl.start.?.*`.

**Difficulty: HARD, and probably not worth it via `-c`.** Catching this in the front end
means modelling Zig's pointer/value rules for `^T` bindings across every emit position —
which is most of a second type system. Cheaper fixes exist at the source: make the two
binding forms emit identically, or lint the `if opt as x` + free-function-call shape
specifically (`hazard_lint` territory, static, instant).

Note `TypeChecker.zbr:3388` documents this hazard but says it does not bite in a
condition — true for `on X as y`, false for `if opt as y`. **A better comment would have
saved this one**, which puts it in rule 1b's family rather than the type system's.

### 3. Module-scope `StrSet.add` lowered as `List.append` — CLASS B
*Found 2026-08-06, BUG-264.*

The selfhost typed a module-scope var as `StrSet` and lowered `.add` as if it were a List.
`zig build` was fine (it builds from the *bootstrap's* correct emit) and all 313 smoke
fixtures passed, while the compiler could not re-emit its own source. Only
`bootstrap_check` step 3 sees that state.

**Difficulty: N/A for `-c`.** Same reasoning as #2 — this is the selfhost's *own* emit
being wrong, which no amount of front-end checking on the input can reveal.

## Standing conclusion

**Adding a backend to `-c` is not the move.** `--check-full` already is that, and `-c`'s
14× speed advantage is the reason it exists.

What is worth doing is narrower: **find the specific error classes the front end could
know about but doesn't, and close those in the TypeChecker** — where the diagnostic is
better anyway (Zebra terms, source location, no generated-`.zig` leak). Occurrence #1 is
the live candidate and is really a language-rule hole wearing a check-mode costume.

For class B the answer is procedural and already written down: after a `selfhost/*.zbr`
edit, `-c` green means nothing. Run the regen.
