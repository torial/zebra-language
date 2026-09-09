<!-- doc-status: historical -->
# Zebra Compiler — Fixed / Closed Bugs

Bugs that have been resolved, implemented, or closed as "not reproduced".
Open bugs live in `BUGS.md`.

---

### BUG-359: a user local/param/field named like a runtime mutable global (`_allocator`, `_args`, `_tui_env`, …) is rewritten by the qualify pass — FIXED 2026-09-09

**Symptom.** `var _allocator: int = 7` in `main` emitted `const _zbr_rt._allocator: i64 = 7;`
— a Zig parse error reported against the user's program. An ASSIGNMENT to such a name
would instead have silently overwritten the runtime's global. Same for a class or struct
field (declared bare in the emitted struct) and for a parameter.

**Mechanism.** Runtime-module emission (2026-07-28) rewrites every bare reference to one of
zebra_rt.zig's `pub var`s as `_zbr_rt.<name>` TEXTUALLY (`CodeGen.rtQualify`), with no
notion of scope: it skips strings, comments and `.field` accesses and nothing else. The
set is 23 names in the plain runtime and ~25 more with a GUI section (BUG-355/357 widened
it: `_tui_env`, `_lui_*`, …). Pre-existing since runtime modules; named by the refuter on
the BUG-355/357 review (2026-09-08).

**Fix.** The checker refuses the declaration: `'<name>' is reserved by the Zebra runtime (a
zebra_rt.zig global); rename it`. The reserved set is DERIVED from the loaded preamble
(`CodeGen.rtReservedNames` → `InferCtx.withReservedRuntimeNames`), so it tracks the
runtime and the selected GUI section rather than a second list. Scope is exactly what the
qualify pass can reach: locals (`Stmt.var_`), params, and class/struct fields. NOT module
vars — those emit mangled (`_zbr_mv_<name>`), and the first draft that included them
refused `selfhost/CodeGen.zbr` itself (`var _list_targets_mode`) and bricked the regen
until the generated `.zig` was hand-patched. Fixtures: `test/bug359_reserved_local_fail`,
`bug359_reserved_field_fail` (smoke_tc_fail), `bug359_underscore_names_test` (a module var
named `_args`, a param `_tmp` and a local `_mine` all stay legal — the control).

**Not done, on purpose.** Mangling user names instead of refusing them would be friendlier
but touches every local-emit site (BUG-280's receipt: reading found 4 sites, the probe found
10). A refusal with the fix in the message is the honest smaller change.

### BUG-358: `g.panel(label, closure)` inside an MVU `view()` dies on the 65th frame — "closure-via-sig pool exhausted (>64 live connections at one call site)" — FIXED 2026-09-09

**Symptom.** `examples/panel_smoke.zbr` on `--gui-backend=tui` drew 64 frames and panicked.
Headless on Linux that is a few milliseconds; on a real terminal it is the 65th redraw.
The IDE (`zebra-ide/src/ide.zbr`) happens to use no closure-taking builder in its view, so
it never hit this; any view with a `panel`/`window`/`childWindow` would.

**Mechanism.** A closure argument is normally lowered through the closure-via-sig thunk pool
(BUG-126: 64 slots per call site, `_zbr_next_N`), because the callee may STORE it
(`Signal.connect`). The pool never frees a slot, which is correct for a connection that
lives as long as the widget. But the GUI section's `panel`/`window`/`childWindow` take
`callback: anytype` and call `callback.call(self)` synchronously before returning — the
same shape as `sys.go` / `ThreadPool.submit`, which `isStdlibClosureStructConsumer` already
exempts. `view()` re-runs per frame, so each frame burned a slot.

**Fix.** `isStdlibClosureStructConsumer` also answers true for `.panel/.window/.childWindow`
on a receiver whose inferred type is `Type_.gui_context`; the closure struct is passed
directly and the pool is not touched (`_zbr_next_` no longer appears in panel_smoke's emit).
Gate: `gui-scaffold-panel` (DAILY) runs `gui_scaffold_check.sh examples/panel_smoke.zbr`;
its leg 2 now classifies a post-startup `thread N panic:` as a FAILURE (it was
"inconclusive" — rc=1 with an unknown marker — so the crash could not have failed the
gate). Red-checked by mutating the exemption out: FAIL "app PANICKED after starting";
restored: clean. The same run fixed the gate's scaffold discovery on Linux (it was finding
a stale `counter_gui_tui` in the repo root — the BUG-298 hazard one level up).

**Still open in the same family.** A USER function that takes a closure and calls it
synchronously still goes through the pool and still burns a slot per call; the exemption
is for the known section builders only. A general fix needs the callee's signature to say
whether it stores the closure (a `sig` param vs a `fn` param), which is the Gap-1 question
BUG-126 left.

### BUG-357: a GUI-backend build embeds the runtime preamble PER MODULE, so `sys.args()` (and every preamble global) in a `use`d module is uninitialised — FIXED 2026-09-08

`--gui-backend=tui|libui_ng` emits a project where main.zig and each dependency .zig carry
their own copy of the preamble (`pub var _args`, `_allocator`, …); only the root's main()
sets its copy. zebra-ide's `ideInit()` (in ide.zbr, imported by model_test) called
`sys.args()` and panicked "sys.args OOM" reading garbage. Same family as BUG-355 (the GUI
section's types are per-module too). Fix direction: one runtime module per GUI project,
as the non-GUI build already does with zebra_rt.zig. Workaround: read `sys.args()` only
in the root module (zebra-ide moved it into main()).

Fix: same change as BUG-355 — one `zebra_rt.zig` per GUI project. Witness: zebra-ide
`model_test` calls `keys.argCount()` (sys.args() in a `use`d module) from a tui build.
`tools/gui_scaffold_check.sh` learned the new shape (globals declared in the runtime's
section, assigned as `_zbr_rt.x` from main) and refuses to go vacuous if it changes again;
it also no longer RUNS the app in its build step (a Linux tui app just runs, it does not
refuse a non-tty, and the gate hung for ten minutes).

### BUG-356: the shared-library round trip (QUICKSTART §44) does not work in the selfhost — FIXED 2026-09-09 (five legs)

QUICKSTART promises `zebra --shared lib.zbr` + `DynLib.open` + `lib.lookup(IFace, "sym")`.
Walking it end to end for the IDE plugin design found, in order:
1. **No `--shared` flag** in the selfhost CLI (the doc is stale; `@export class` does emit
   the factory, and `zig build-lib -dynamic` on the `--emit-zig` output produces a library).
   OPEN — the flag should exist and do exactly that.
2. `DynLib.open` lowered to a bare `try` — "expected type 'void', found 'anyerror'" from a
   plain `def main()`. FIXED: panics outside `throws`, as documented.
3. `lib.lookup` yielded `?*IFace` (null on a missing symbol), so `g.greet(..)` on the result
   was a Zig error about `?*IGreeter`; and the factory pointer type lacked `callconv(.c)`
   although the factory is `export fn`. FIXED: value is the fat pointer, missing symbol
   panics naming it, C calling convention.
4. **The fat pointer read from the host is garbage** (`ptr`/`vtable` words like
   `0xd00020001e639`, `0x20f9a0` — neither relocated addresses nor the library's symbols),
   even from a pure Zig host built the same way, so it is not the Zebra host's reading of
   it. Suspects: relocation/initialisation of the emitted module built as a `-dynamic`
   library (the runtime's globals, `_io` undefined, the optional-payload pointer). OPEN.
   Gate: tools/dynlib_roundtrip_check.sh (pinned `dynlib-roundtrip`, FULL tier); fixture
   test/dynlib_roundtrip/{greeter,host}.zbr. The IDE's plugin design treats in-process
   plugins as blocked on this and starts with process plugins.

**Resolution 2026-09-09.** Leg 4 was not corruption. Instrumenting both sides showed the
library handing back correct addresses and a pure-Zig host built with `zig build-exe -lc`
printing "Hello, World v7" — the difference was the ZEBRA host's build: the fast
`-fno-llvm -fno-lld` path passes no `-lc`, and without libc `std.DynLib` is Zig's own
`ElfDynLib`, which maps the .so itself and does not apply its RELATIVE relocations. The
"garbage" (`0x20f9a0`) was an unrelocated vtable entry, i.e. a file offset. Fix: a program
that calls `DynLib.open` sets `emittedDynLib()` and is routed to the libc (dlopen) path,
as programs with extern declarations already are. Leg 1: `zebra --shared lib.zbr` exists —
emit, then `zig build-lib -dynamic -lc` into `lib<stem>.so` / `<stem>.dll` / `.dylib` next
to the source (`--release` honoured). **Leg 5**, found on the way: a library has no `main()`,
so `_io` was `undefined` and the first `print`/`sys.sleep`/`File` inside library code
faulted; the `@export` factory now calls `_libInit()` (one `std.Io.Threaded` owned by the
library, created on first use) and `_initModuleVars()`. Gate unpinned; fixture exercises
print + sleep + a module var; red-checked by mutating `_libInit` out (GP fault in
`Io.operate`). Design limits recorded in QUICKSTART §44: no host args/environ inside the
library; each side owns its allocator, so a returned `str` lives until `lib.close()`.
The IDE's in-process (DLL) plugin route is unblocked.

### BUG-355: a GUI-section type (`CodeEditor`, `Gui`) cannot cross a module boundary — `expected type '*keys._CodeEditor', found '*main._CodeEditor'` — FIXED 2026-09-08

Every module's emitted Zig carries its OWN copy of the GUI section, so `_CodeEditor` in
`main.zig` and `_CodeEditor` in `keys.zig` are different types, and `def
registerShortcuts(ed: CodeEditor)` in a `use`d module cannot take the root module's
editor. Fix direction: emit the section once (root) and have dependents reference the
root's types (`@import("root")._CodeEditor`), or lower section types to a shared
runtime module. Workaround: keep functions that take a CodeEditor in the root module
(zebra-ide keys.zbr is pure data for this reason).

Fix: the second direction. GUI projects now use runtime-module emission like every
other program: the GUI section is pub-marked (`rtPubMarkSection`) into `zebra_rt.zig`,
`copyGuiDeps` carries it into the scaffold, and every module aliases/qualifies the ONE
runtime. Witness: zebra-ide `model_test` hands the IDE's editor to `keys.registerShortcuts`
in a third module. `--no-runtime-module` still gives the inline shape.

### BUG-353: `File.write(p, f(File.read(p)))` read an EMPTY file — the file was created (truncated) BEFORE the content argument was evaluated — FIXED 2026-09-08

The lowering opened `createFile` first and evaluated the content expression inside
`writeStreamingAll(...)`. Rewrite-in-place is the most natural way to write a rename's
on-disk half, and it wrote `f("")`. Fix: the content is bound to `_fw_data` before the
file is created (arguments left to right, as everywhere else). `File.append` and
`File.writeLines` are plain calls and were already in order. Control:
test/bug353_file_write_order_test.zbr. Found by zebra-ide's rename_workspace_test — the
IDE's "unopened files rewritten on disk" path had never executed until then.

### BUG-352: a for-loop variable named like a FIELD of the enclosing class was emitted as `self.field` — FIXED 2026-09-08

`class LspClient: var name` + `for name in File.listDir(d)` inside a method emitted
`self.name` for every use in the body (and Zig then said "unused capture" about the loop
variable, which points nowhere near the cause). `isFieldName` excluded PARAMETERS but not
loop variables; infer_ctx locals cannot carry it because they are never popped, so a
post-loop bare `name` would have stopped meaning the field. Fix: `active_loop_vars`, a
StrSet shared through `indented()`, pushed/popped by genForIn/genForNum; `isFieldName` is
false while the name is on it. Control: test/bug352_loop_var_shadows_field_test.zbr
(field-typed list AND a parameter list; the post-loop `.name` still reads the field).
Found by zebra-ide's rename_workspace_test.

### BUG-350: `return s.split(sep)` from a `List(str)` function emitted the raw SplitIterator — FIXED 2026-09-08

Only the ANNOTATED-VAR site (`var xs: List(str) = s.split(..)`, BUG-092) collected the
iterator into a list; the return position emitted `std.mem.splitSequence(..)` verbatim and
Zig said "expected 'array_list...', found 'mem.SplitIterator'". Found writing the BUG-346
fixture. Fix: the collector is one helper (`genSplitCollect`, a labeled block expression)
used by both sites; genReturn uses it when the declared return type is `List(..)` and the
value is `.split/.lines` on a non-class receiver. Control: test/bug350_return_split_test.zbr.

### BUG-349: the DAP relay lost every session to `MissingContentLength` — a fresh `readerStreaming` per byte discarded its read-ahead — FIXED 2026-09-07 (branch dap; src/Debugger.zig, bootstrap-only code)

`FileReadCtx.readFn` created a `readerStreaming` with a 1-byte storage for EVERY
byte; in Zig 0.16 that reader still reads ahead from the pipe and the read-ahead died
with it, so the relay saw "C","n","e","t","L" of "Content-Length" (replicated in a
10-line Zig program) and failed before the first request — on both directions, on
every platform. The same class as BUG-334 (selfhost stdin, fixed 09-06). Fix: one
persistent reader with a 4 KB storage per FileReadCtx. Control:
zebra-ide/src/dap_client_test.zbr (breakpoint hit, stack remapped to the .zbr line,
next, continue, disconnect, against the real lldb-dap).
NOTE: this was the last bootstrap-only subcommand; the fix is in src/ because that is
where `debug` lived. CLOSED OUT the same day: `zebra debug <file>` is native in
selfhost/main.zbr (`dbgRunSession`: single-threaded, both pipes polled without
blocking, so this defect class cannot recur there); zebra-ide's dap_client_test passes
against it. Only `--listen PORT` still delegates to the bootstrap.

### BUG-348: `zebra debug` could never find the bootstrap on Linux — `.exe` suffix unconditional — FIXED 2026-09-07 (branch dap)

`bootstrapExePath()` returned `zig-out/bin/zebra-bootstrap.exe` whether or not it
existed, so on Linux `zebra debug` printed "could not launch the bootstrap compiler".
Now tries the suffixed name, then the bare one (repo-relative, then beside the exe).

### BUG-347: compile-and-run forwarded NO arguments to the program — FIXED 2026-09-07 (branch gates)

`zebra prog.zbr a b` ran the program with argv = [exe]; there was no passthrough at
all, so a CLI written in Zebra could only be run from its built exe. Now everything
after a literal `--` is forwarded (`zebra src/gates.zbr -- manifest.json smoke`), on
both the fast and the LLVM run paths, and `ArgResult.unknownFlag` stops at `--` so
program flags are not reported as unknown compiler flags. Control:
test/prog_args_passthrough_test.zbr (registered inline in selfhost_smoke).

### BUG-346: a method call on an IMPORTED function's result is untyped — `joinPath(a, b).replace(..)` leaks Zig `no field or member function named 'replace'` — FIXED 2026-09-08

Same-module calls infer their return type; a `use`d module's function does not, so
the method dispatches as a generic member. Workaround: bind to a typed local first
(zebra-ide/src/ide.zbr `markBuildDiags`).

Found while fixing: the SAME-module case was broken too (the entry above was wrong about
that) — `isStringExpr` decided from a NAME LIST and never asked the checker. Fix: it now
falls back to `inferExpr` for any call, so a `def f(..): str` result is a string wherever
the by-value string forms are chosen. Control: test/bug346_imported_call_method_test.zbr
(str / List(str) / class results from a `use`d module) + bug350 below.

### BUG-345: `Timer` cannot be a field or annotated type — `var t: Timer? = nil` leaks Zig `use of undeclared identifier 'Timer'` — FIXED 2026-09-08

`Timer.start()` infers to `timer_handle`, but `Timer` is not in `typeFromName`, so it
cannot be written as a field/param/annotation. Workaround (zebra-ide/src/gates.zbr):
`DateTime.now().epoch_ms` arithmetic.

Fix: `Type_.timer_handle` added to the selfhost (the bootstrap always had it): `typeFromName`,
`Timer.start()` inference, method returns (`elapsed` float ms / `elapsedMicros` int / `reset`),
genType `Timer` → `TimerHandle`. Control: test/bug345_timer_field_test.zbr (field, `Timer?`
field, annotated local, parameter). The gates.zbr workaround is removed.

### BUG-344: a user field named `items` was emitted as the raw Zig slice accessor in `for` — FIXED 2026-09-07 (branch p2-buffers)

`class BufferSet: var items: List(Buffer)` then `for b in .items` emitted
`for (self.items) |b|` (no `.items`) and leaked "type 'array_list...' is not indexable".
`isItemsMemberAccess` matched the NAME only. Now it asks the inferred receiver type:
a named (class/struct) receiver means a user field. Control:
test/bug344_items_field_iter_test.zbr (class-element and struct-element lists).

### BUG-343: a user module named `sci` (or `ui`) collides with the libui_ng section's private imports — Zig `duplicate struct member name 'sci'` — FIXED 2026-09-07 (branch ide-slice)

`selfhost/gui_libui_ng_section.zig` declared `const sci = @import("sci")` and
`const ui = @import("ui")` at file scope of the emitted program; a Zebra `use sci`
emits `const sci = @import("sci.zig")` into the same scope. Section-private names now
carry the `_` prefix like every other emitted helper (`_sci`, `_ui`). General rule
worth a checker pass later: nothing a section declares may be a plausible user
identifier.

### BUG-342: a `StringBuilder` PARAMETER cannot be appended to — leaks Zig `expected '*T', found '*const T'` — FIXED 2026-09-08

`def f(sink: StringBuilder)` then `sink.append(..)`: parameters are const, the emitted
`appendSlice` needs `*T`. `List(T)` parameters DO accept `.add` (they lower to a
pointer), so the two container types disagree about what a parameter is, and the
diagnostic is Zig's. Either lower StringBuilder params like List params, or refuse at
the checker with "cannot mutate parameter `sink`; return a str instead". Workaround
(zebra-ide/src/ide.zbr `symbolLines`): build locally and return `sb.build()`.

Fix: `isContainerTypeRef` (CgHelpers) now includes `StringBuilder`, so it takes the BUG-091
addr-of convention exactly like `List(T)`: param emitted as `*std.ArrayList(u8)`, `&arg` at the
call site, pointer forwarded unchanged. Control: test/bug342_sb_param_append_test.zbr (free fn +
method, forwarding through a class). ide.zbr's `symbolLines` keeps returning a str — that
is the cleaner contract, so the workaround became a design choice rather than being reverted.

### BUG-341: unknown method on `StringBuilder` (`sb.add(s)`) is not rejected — leaks Zig `expected type 'u8', found '[]const u8'` — FIXED 2026-09-08

`StringBuilder` lowers to `ArrayList(u8)`, so `.add` fell through to the generic List
lowering (`append`) and Zig complained about the element type. The checker knows the
receiver type is StringBuilder and its method set (`append`, `build`, `toString`,
`len`); "unknown method `add` on StringBuilder (did you mean `append`?)" is the
diagnostic. Workaround: `.append`.

Fix: TypeChecker's `string_builder` arm now returns void for `append/appendChar/clear` and
REFUSES any other name with the closed method list (`add` gets "did you mean 'append'?").
Control: test/bug341_sb_unknown_method_fail.zbr (smoke_tc_fail).

### BUG-340: `--gui-backend=tui|libui_ng` + `use` deps → `@import("lsp.zig")` FileNotFound — FIXED 2026-09-07 (branch ide-slice)

The GUI path copies the emitted main into `<proj>/src/main.zig` but the emitted
dependency modules (`lsp.zig`, `sci.zig`) stayed beside the source, so the project's
build failed inside Zig with `unable to load 'lsp.zig'`. Every GUI example was
single-file, so no gate saw it; `zebra-ide/src/ide.zbr` (three modules) found it on its
first build. Fix: `copyGuiDeps` in selfhost/main.zbr walks `@import("X.zig")` lines
transitively and copies each module into the project. Control: ide.zbr builds on tui.

> **BUG-341 … BUG-353 are SELFHOST-ONLY fixes** (the standing rule since 2026-09: compiler
> changes land in `selfhost/*.zbr`; the bootstrap `src/*.zig` is phasing out and is NOT
> updated — cleanroom (sonnet) verified 2026-09-08 that 341/342/346/350/353 still leak Zig
> when compiled with `zebra-bootstrap`). Nothing ships through the bootstrap.

### BUG-335: JSON query on a local inside a CLASS METHOD emitted `var`; Zig's "never mutated" leaked — FIXED 2026-09-07

`var rng = d.getObj("range")` then `rng.getObj("start")` in a class method → Zig error
`local variable is never mutated`; the identical code in a free function compiled.
Mechanism (from `CgHelpers.receiverNeedsVar`): when the receiver's type is not inferable
the decision falls to the name-based `isReadOnlyMethod`, which did not list the JSON
queries, so the receiver was marked mutated. Fix: getObj/getStr/getInt/getFloat/getBool/
getList/isNull/isObject/isArray/stringify are read-only by name. Control:
`test/bug335_json_query_in_method_test.zbr`. Found writing zebra-ide's `lsp.zbr`.
Open question left: WHY the receiver type is not inferable in the method body — the
name-based fix is correct but the inference gap is still there for any other method.

### BUG-334: `sys.readLine` / `sys.readBytes` created a NEW buffered stdin reader per call, discarding read-ahead — `zebra lsp` answered nothing on a pipe — FIXED 2026-09-06 (branch lsp-references)

**Symptom.** On Linux, `zebra lsp` fed a normal LSP request over a pipe replied with
nothing and exited 0 when stdin closed. `tools/lsp_diagnostics_smoke.sh` (which uses the
`zebra diagnostics --out` seam, not the server) stayed green throughout — the server's
stdio path had no control.

**Mechanism (verified by fix, not reasoned).** `_sys_readline` and `_sys_read_bytes` each
did `var buf: [256]u8; var rdr = stdin.readerStreaming(_io, &buf)` — a fresh reader with a
fresh buffer per call. `readSliceShort(1 byte)` fills that buffer from the fd with up to
256 bytes; the function returns one line and the rest of the buffer dies with the frame.
On a Windows console this is invisible (console reads hand back one line per read), which
is why the comment above `_sys_read_bytes` could say "no read-ahead" and be believed. On a
POSIX pipe the first `readLine` swallowed the whole `Content-Length…{body}` request, the
second saw EOF, and the loop exited cleanly.

**Fix.** One process-wide reader (`_stdin_rdr`, 4 KB buffer) shared by both functions, so
read-ahead is retained across calls and consecutive reads stay aligned. Control:
`tools/lsp_protocol_smoke.py` writes several frames in ONE pipe write and requires both
`initialize` and `shutdown` to be answered — seen red before the fix, green after.

**Class.** Same shape as concept_vacuous-instruments in the wiki: the property the comment
asserted ("no read-ahead") was true of the platform it was written on and false of the
API. Any other per-call `readerStreaming` on a shared fd has the same defect; grep found
none besides these two.


### BUG-320: index assignment `xs[i] = v` regressed by BUG-313 — plain AND compound — FIXED (plain 2026-08-29, compound 2026-09-05)

**A regression I introduced, found the next day by Sean asking why `xs[i]` was not
writeable.** It was writeable. BUG-313's bounds-checking change broke it.

```
before BUG-313:  xs.items[@intCast(0)] = 77      a valid Zig lvalue
after:           _zbr_at(xs.items, 0) = 77       a function call -> Zig refuses
```

The read path was converted to the checked accessor `_zbr_at`, and the assignment path
emits its target with the same `genExpr`, so the LHS became a call. Reads kept working,
which is why it was invisible.

**BOTH FORMS ARE AFFECTED, measured:**

| | result |
|---|---|
| `xs[0] = 77` | `error: invalid left-hand side to assignment` |
| `xs[0] += 3` | same |

The compound forms in `genAssign` (`//=`, `<<=`, `>>=`, `**=`) all emit
`genExpr(a.target)` on the left, so every one of them has the same defect for an index
target.

**THE ERROR IS ZIG'S, LEAKED.** *"invalid left-hand side to assignment"* names nothing a
Zebra programmer wrote. Whatever the fix, the diagnostic should be Zebra's.

**BUG-181 ALREADY ESTABLISHED THIS EXACT CLASS** and its comment is still in `genAssign`
three lines above the defect: *"a `.len` member used as an assignment TARGET ... Emit
`obj.len = v`, NOT the read-form ... which is an invalid assignment LHS in Zig."* The
lesson was recorded, the special case was written, and BUG-313 reintroduced the same shape
for indexes anyway -- because the work was about the READ path and nobody asked what else
used the same emitter.

**WHY NO GATE CAUGHT IT, and this is the part worth keeping.**
`examples/lsystem.zbr` uses `cell[y * w + x] = glyph` and **stopped compiling**.
`examples_sweep` would have caught it -- but it is a FULL-tier gate, and after landing
BUG-313 only static, fast and quick were run. The regression sat about 24 hours in a
shipped example. This repo's own convention -- *"`--daily` is the last thing run when
overnight work stops"* -- exists precisely for this, and skipping it is what cost the
example.

**THE FIX, specified rather than rushed** (Sean's standing "careful > fast on selfhost"):

`genAssign` must special-case an `Expr.index` target instead of emitting it via `genExpr`:

- plain `=` -> `_zbr_set(<recv>, <idx>, <value>)`
- compound -> `_zbr_set(<recv>, <idx>, <op>(_zbr_at(<recv>, <idx>), <rhs>))`

`_zbr_set` already exists (added by BUG-313) and keeps the bounds check, so the fix does
not reopen what BUG-313 closed.

**Do NOT duplicate the receiver logic.** Deciding whether the receiver needs `.items`
takes ~15 lines in the read path (`getMemberFieldName` -> `fieldAwareIsHashMap` /
`fieldAwareIsList`, with an `inferExpr` fallback for non-name bases per BUG-177). Copying
that into `genAssign` creates exactly the two-copies-of-one-decision shape that keeps
producing bugs here. Extract it once and call it from both.

HashMap index assignment is already handled separately by `genHashMapAssign` and must stay
on that path.

**Control when fixing:** `test/boundary/bug320_index_assign_probe.zbr` pins the failure
today and FAILS when this is fixed -- rewrite it into a positive test of `xs[i] = v` at
that point. Add the compound form too, and re-run `examples_sweep`, which is the gate that
should have caught this.

**DECIDED (Sean, 2026-08-29): `[i]` getter/setter is the way forward, and `.at()` comes
OUT of the stdlib.** "This is one of those things that I think will cause confusion to have
the non square bracket being a required solution anywhere." He accepts the code churn and
prefers to go slower.

**THE REMOVAL IS BLOCKED ON THE BOOTSTRAP SUNSET, and the constraint is not obvious --
measured 2026-08-29 before starting, precisely because it would have walled out mid-rewrite:**

| | |
|---|---|
| `.at(` sites in `selfhost/*.zbr` (the compiler itself) | **893** |
| in `test/*.zbr` | 174 |
| in `examples/*.zbr` | 206 |
| files touched | 81 |

Converting the compiler's own 893 sites produces NESTED bracket forms, and
**`m[0][0]` compiles under the selfhost and FAILS under the bootstrap** -- *"Expected
pointer, slice, array or vector"*, the BUG-177 selfhost-ahead gap. The bootstrap is still
the regeneration authority and the standing hard limit is that it must be able to COMPILE
the selfhost source. So a bracket rewrite of `selfhost/*.zbr` would leave a tree that
cannot be regenerated, discovered somewhere inside a 893-site change.

**ORDER, therefore:**

1. **BUG-320's fix** -- make `xs[i] = v` and the compound forms work. No dependency; do it
   first, because everything else assumes brackets can write.
2. **Bootstrap sunset criterion 2** -- move the regeneration authority to the selfhost
   (`NEXT_STEPS_to_0.9.md`). That lifts the bootstrap-must-compile-selfhost constraint,
   because the bootstrap stops being the authority.
3. **`.at()` / `.set()` removal** -- 1,273 sites, mechanical, and only safe after (2).

`test/` and `examples/` could technically convert earlier, but splitting the pass buys
nothing and doubles the review.

**One thing to preserve in step 3:** a user class may define its own `.at()` method --
codegen has an `at_is_user_method` branch. A blind textual rewrite would break those.



---

**DESIGN FOR THE COMPOUND HALF, worked out 2026-09-05 but NOT YET IMPLEMENTED.** Recorded
because the obvious two designs are both WRONG, and each looks right until a specific
question is asked of it.

The shape is settled: `xs[i] op= v` must become
`_zbr_set(<recv>, <idx>, <recv[idx] op v>)`, since the read form has been `_zbr_at(recv, i)`
-- a function CALL -- since BUG-313.

**Design 1, REJECTED: a helper that re-emits each operator's lowering.** Write
`emitCompoundRhs(op, ...)` owning the four special lowerings (`@divTrunc`, `std.math.pow`,
`_zbr_shl`, `_zbr_shr`) and DERIVE the rest from `assignOpStr` by dropping the trailing `=`.
This is wrong for `/=` and `%=`. Zig accepts the compound `a /= b` and `a %= b` on signed
integers -- `test/bug304_305_compound_hex_test.zbr` exercises both and passes -- but REJECTS
the same operators in EXPRESSION position, which is what the derivation produces. So
`xs[i] /= v` would emit `_zbr_at(r,i) / v` and fail to compile, while the identical
operation on a plain variable compiles today. The lesson is narrow and worth keeping: an
operator's compound-assignment form and its binary-expression form are NOT the same Zig
question, and a table that maps between them by string surgery cannot know that.

**Design 2, REJECTED: bind temporaries and inject the read as a `zig_lit`.** Emit
`{ const _r = <recv>; const _i = <idx>; _zbr_set(_r, _i, <binary(op, zig_lit("_zbr_at(_r,_i)"), v)>); }`
and let `genExpr` handle every lowering, so nothing is duplicated at all. It evaluates the
receiver and index exactly once, which is the property design 3 gives up. But `BinaryOp.div`
discriminates float from int by calling `inferExpr(b.left)`, and a `zig_lit` carries no
type -- so `xs[i] /= 2.0` on a `List(float)` would take the integer branch and emit
`@divTrunc` on floats. A silent wrong lowering caused by making the operand opaque to
inference.

**Design 3, ACCEPTED (not yet built).** Synthesize `binary(binOpOfAssign(a.op), a.target,
a.value)` -- the ORIGINAL index expression as the left operand, so inference sees a real
typed node -- and emit `_zbr_set(recv, idx, <that>)`. Every lowering is reused rather than
restated, and the float/int discrimination works because the operand is exactly what it
was. The cost is that `recv` and `idx` are MENTIONED TWICE, so it is only correct when
neither contains a call.

Guard it on that, and take the path only when the receiver and index are call-free
(`ident` / `member` / `index` / literal are all fine -- they are reads). When a call IS
present, fall through to today's behaviour, which is a LOUD zig error rather than a silent
double evaluation: `xs[next()] += 1` advancing an iterator twice would be valid Zig
computing the wrong answer -- the BUG-226 class, invisible to every compile-only gate. Left
loud on purpose, and narrower than the bug it replaces.

Needs `binOpOfAssign(AssignOp): BinaryOp` (every variant already exists in `BinaryOp`:
add/sub/mul/div/int_div/mod/pow/bit_and/bit_or/bit_xor/shl/shr) and a call-free predicate.
Verify with a fixture covering all twelve operators on BOTH `List(int)` and `List(float)` --
the float leg is what discriminates designs 2 and 3, so an int-only fixture would pass
against the wrong one. FULL tier before committing: this is `genAssign`, which every
assignment in every program goes through.


---

**COMPOUND HALF FIXED 2026-09-05.** All twelve operators work on an index target:

| | | | |
|---|---|---|---|
| `+=` 17 | `-=` 7 | `*=` 60 | `/=` 6 |
| `//=` 6 | `%=` 2 | `**=` 144 | `&=` 4 |
| `\|=` 15 | `^=` 9 | `<<=` 48 | `>>=` 3 |

(from 12, measured; every one of these except `/=` and `%=` was `invalid left-hand side to
assignment` the hour before.)

**THE DESIGN RECORDED ABOVE WAS SUPERSEDED, and the better one was already in the tree.**
Designs 1-3 all tried to fix this inside `genAssign`. Reading `AstBuilder` first would have
been quicker: it ALREADY desugars `/=` and `%=` into `x = x / y`, with a comment giving
exactly the reason design 1 later foundered on -- the correct lowering is TYPE-DEPENDENT and
`genBinary` already knows how to decide -- and ending "worth fixing for all of them together,
not here."

So the fix is that sentence, carried out: an INDEX target desugars EVERY compound operator
into `xs[i] = xs[i] op v`. `genBinary` picks each lowering, and `genAssign` sees only a plain
`=` to an index, which has worked since the plain half landed. `genAssign` is not touched at
all.

**IT WAS MEASURED BEFORE IT WAS WRITTEN, and that measurement chose the design.** On an index
target `/=` and `%=` ALREADY worked -- because of that existing desugar -- and the other ten
did not. The mechanism was proven for 2 of 12 before a line changed. That is also the cleanest
statement of why the three genAssign designs were wrong: the working precedent was sitting
one file away, passing its own tests.

**THE HASHMAP LEG WAS A SECOND, DISTINCT BUG.** `m[k] += v` failed with `cannot assign to
constant`, not `invalid left-hand side` -- a different emitter (`genHashMapAssign`, reached
only for a plain `=`). The desugar fixes it for the same reason, but it had to be probed
separately to know that, and it is pinned separately.

**Verification.** `test/bug320_compound_index_assign_test.zbr` (`smoke_run`) covers all twelve
on `List(int)`, four on `List(float)`, a nested `g[0][0] += 3`, and the HashMap pair; watched
RED first, where the List and HashMap legs failed with DIFFERENT errors. The float leg is not
decoration: `/` lowers to `@divTrunc` on ints and `/` on floats, chosen by inferring the LEFT
operand, so a design that makes that operand opaque to inference passes every integer
assertion and silently truncates floats. An int-only fixture cannot separate the designs.

`test/boundary/bug320b_compound_index_assign_probe.zbr` was a `@boundary-pending` refusal-pin
and is now a positive probe -- which is what the pin asked for: "FAILS when compound
assignment is fixed -- the signal to rewrite it as a positive test, not to re-baseline." Its
expected values were authored from the language before running and matched exactly, `2.5`
included.

**WHY NO GATE EVER CAUGHT THIS, and it is not that the gates are weak.** After the fix,
`grep` for a compound assignment to an index across `test/` and `examples/` returns exactly
ONE file: the fixture written for this bug. The construct is absent from a 536-file corpus
because it did not work -- people who tried it once wrote `xs.set(i, xs.at(i) + v)` instead
and moved on. A feature nobody can use leaves no trace to regress, so every corpus-driven
gate is blind to it BY CONSTRUCTION, no matter how large the corpus grows.

That is the same shape `lint_keyword_coverage` was built for: on the day it first ran, the two
modifiers with zero corpus uses were `protected` and `internal`, and BOTH were defective. Zero
usage is not evidence a feature is unimportant; it is a reason to go and check the feature.
The equivalent instrument for OPERATORS does not exist, and this bug is the argument that one
would earn its keep.

**KNOWN LIMIT, unchanged and pre-existing.** The desugar mentions the target TWICE, so
`xs[next()] += 1` would call `next()` twice. `/=`, `%=`, `//=` and `**=` have always had this;
it now applies to all twelve on index targets. Plain targets keep their native single-mention
emit, which is why the desugar is restricted to index targets. Fixing it needs a temp-binding
form, and that IS a `genAssign` change -- worth doing on its own, for all of them together,
exactly as this bug's own history recommends.

---

### BUG-225: `s[i]` is typed `char` but yields a byte — FIXED 2026-09-05 (retype pulled forward from 1.x)

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

**FIXED 2026-09-05.** `s[i]` is typed `byte` (`uint_n(8)`). Sean pulled the retype forward
from 1.x -- "for 225 let's mirror Go" -- so the type finally matches the value and the two
byte spellings agree: before this, `s[0]` printed `h` and `s.charAt(0)` printed `104` for
the same byte of the same string. `"héllo"[1].toString()` printed `Ã` and now prints `195`.

**THE REASON THIS WAS DEFERRED TO 1.x WAS WRONG, AND THAT IS THE FINDING.** The entry above
argues the retype "requires deciding how `byte` and `char` compare", because the selfhost
lexer is built on it -- ~104 subscript sites, 559 `c'x'` literals, 61 of them the shape
`src[pos] == c'\n'`. **No comparison rule had to be defined.** Zig resolves a `u8` against a
`u21` char literal by peer type resolution, so every one of those sites survives the retype
untouched; Go's untyped-constant rule arrives for free rather than being built. The fix is
ONE LINE plus its rationale, and what proved it was the compiler's own round-trip, not an
argument. Option (b) from the list above, at roughly the cost that was assigned to (a).

Verified: full rebuild OK (the compiler self-compiles), QUICK **30/30**, smoke **398/398**,
round-trip byte-identical, and a Zebra-level `s[0] == c'h'` compiles and holds.

**THE FIXTURE'S FIRST DRAFT WOULD HAVE PASSED AGAINST THE BUG, and it is worth knowing why,
because the trap is specific to this class.** It asserted `s[1] == 195`. The VALUE was
always the correct byte -- a u21 holding 195 still equals 195 -- so only the TYPE was ever
wrong, and a type is observable exactly where it drives formatting. Every assertion in
`test/bug225_str_index_byte_test.zbr` therefore goes through `.toString()`. Comparing the
value is a cooperative attacker; comparing the RENDERING is the real one. It was then
watched genuinely RED against a compiler with the retype mutated out (fails at
`assert s[1].toString() == "195"`) and green with it restored.

The fixture's oracle is deliberately NON-ASCII. An ASCII-only fixture passes identically
before and after, since byte 104 and codepoint U+0068 are the same character -- it would
pin nothing. It also asserts `.len` and `.codePointCount()` DISAGREE, so that if the string
ever loses its multi-byte character every assertion below does not quietly go vacuous.

---

### BUG-319: indexing has TWO partial spellings — `.at()` dies on `str`, `[i]` cannot be assigned — FIXED 2026-09-05

**Found by Sean asking "should we get rid of `.at()`? What value does it add?" — a question
about redundancy that turned out to expose incoherence instead.**

Measured:

| | `.at(i)` | `[i]` read | write |
|---|---|---|---|
| `List(T)` | works | works | `.set(i, v)` only — `xs[i] = v` is refused, *"invalid left-hand side to assignment"* |
| `str` | **FAILS** — leaked Zig error: *"no member named 'items' in 'str'"* | works | — |

**They are not two spellings of one thing. They are two INCOMPLETE spellings with different
coverage**, which is worse than redundancy: a user cannot learn one form and rely on it.
`.at()` is the list accessor and dies on strings; `[i]` reads both and writes neither.

**Three separate defects here, and they should not be conflated:**

1. **`s.at(i)` leaks a Zig error.** *"no member named 'items' in 'str'"* names an
   implementation detail of the emitted ArrayList and is meaningless to someone writing
   Zebra. Whatever the design answer, this must be a Zebra diagnostic -- UNGIT "nothing
   fabricated" on the surface a user meets first.
2. **The read/write asymmetry is unexplained.** `xs[i]` reads but `xs[i] = v` is refused,
   while `.at()`/`.set()` is a symmetric pair. Nothing documents why.
3. **QUICKSTART documents `s[i]` as THE byte-indexing form** (see BUG-225, where `s[i]` is
   decided to be a byte, matching Go), so `[i]` is load-bearing for strings and cannot
   simply be retired.

**WHY `.at()` CANNOT SIMPLY GO, which was the original question:** `.set()` is the only
write path. Removing `.at()` leaves a pair with no reader, and `[i] = v` does not exist to
replace it. The redundancy is in the READ direction only.

**The coherent options, for a language decision rather than a fix:**

- **(a) Complete both.** `.at()`/`.set()` gain `str` support; `[i]`/`[i] = v` gain
  assignment. Most convenient, most surface -- and surface is axis 3, near-irreversible
  once frozen.
- **(b) Methods only.** Retire `[i]` for lists, keep it for `str` where it is the documented
  form. **Note the freeze argument: `[i]` is GRAMMAR and `.at()` is STDLIB.** Under the
  planned grammar freeze, grammar is the near-permanent surface and the stdlib stays
  extensible, so a capability that lives in a method costs less forever than one that lives
  in the syntax.
- **(c) Brackets only**, with assignment added. Fewest concepts for a reader, but it moves a
  capability INTO the frozen grammar, which is the expensive direction.

**Recommendation: (b)**, on the freeze argument alone -- but this is a language call.
Whichever is chosen, defect 1 (the leaked Zig error) should be fixed regardless, because it
is wrong under every option.

**Also observed, filed here rather than separately because it is one line of evidence:** the
diagnostic for `print(s.at(1))` reported **line 2** for an error on line 3 -- the same
diagnostic-position family as BUG-288, which had cleared `diag-columns` to zero. Worth a
check that the *line* is right and not only the column.

**FIXED 2026-09-05 (defects 1 and 2). Defect 3 is now a decided language change, tracked
separately -- see below.**

Defect 1, `s.at(i)` leaking `no member named 'items' in 'str'`, is a Zebra diagnostic now:

```
t.zbr:3:13: error: 'str' has no 'at' -- use s[i] for the byte at i, or s.chars() to iterate codepoints
```

It names both halves of the byte/codepoint split deliberately, because WHICH ONE the user
wanted is exactly what `.at()` left ambiguous.

Defect 2, the unexplained read/write asymmetry, is resolved in both directions. `s[i] = x`
used to reach codegen unchecked and surface as Zig's `local variable is never mutated` -- a
message that contradicts the line the user just wrote, which is the worst shape a diagnostic
can take. It now says what is true and permanent:

```
t.zbr:3:5: error: strings are immutable -- 's[i] = ...' is not allowed; build a new string
with StringBuilder (sb.append(...) then sb.build())
```

The StringBuilder idiom was RUN end to end before being named.

**TWO CLAIMS IN THE ORIGINAL ENTRY WERE MEASURED AND ARE FALSE -- recorded because both
argued against the fix that was eventually right.**

- *"`.at()` is the safe/checked accessor"* was never stated outright but was the reason to
  keep it. Both spellings lower to the SAME `_zbr_at`, which bounds-checks and panics. They
  are genuinely redundant, not checked-vs-unchecked.
- *"`.at()` CANNOT simply go: `.set()` is the only write path, and `[i] = v` does not exist
  to replace it"* went STALE when BUG-320's plain form landed. `xs[0] = 77` works today.

**WHAT REMAINS, and it is a decision rather than a defect.** Sean's call 2026-09-05: the
indexer IS the accessor, so `.at()`/`.set()` should retire. That is 1,676 call sites, 915 of
them in the compiler's own `.zbr` sources (`CodeGen.zbr` alone: 558) -- mechanical, but it
must wait on **BUG-320's COMPOUND half**: `xs[i] += v` is still `invalid left-hand side to
assignment`, and `.set()` is currently the only way to spell a compound update
(`xs.set(i, xs.at(i) + v)`). Retiring the pair first would delete the only working form.

A DUPLICATE-DIAGNOSTIC BUG WAS FOUND EN ROUTE and fixed with it: `print(s.at(0))` reported
one mistake TWICE while `var b = s.at(0)` reported it once, because `print` infers its
arguments a second time to choose a format specifier. Deduped at the sink (`addErr`, exact
file+line+col+message match) rather than at the print site: `quiet_errors` already guards one
such double-visit and this was the second, so the pattern is the rule and a per-call-site
guard is a list that rots.

Fixtures `test/bug319_str_at_refusal_test.zbr` and
`test/bug319_str_assign_refusal_test.zbr`, both `smoke_tc_fail` with pinned coordinates, both
watched failing with their old leaked Zig errors first.

---

### BUG-330: `for ch in <str>` is accepted by the front end and emits Zig that cannot compile — FIXED 2026-09-05

**Status:** FIXED 2026-09-05. Found 2026-09-04 while porting `zebra debug`.

Iterating a bare `str` is not a supported form -- QUICKSTART documents `for c in s.chars()`
for codepoints and `charAt(i)` for bytes. But the front end ACCEPTS `for ch in s`, and
codegen then emits `for (s.items) |ch|`, which zig rejects with
`no member named 'items' in '[]const u8'`.

So the failure surfaces as an error in GENERATED code, naming a field the user never
wrote, at a location in a file they did not author. UNGIT "nothing ambient": the compiler
accepted a construct it cannot lower and let the consequence land somewhere the user
cannot act on.

**Repro**

```zebra
def main()
    var s: str = "abc"
    for ch in s
        print("x")
```

`zebra -c` reports `parsed OK / resolved OK` and exits 0. A full compile fails inside the
emitted Zig.

**Why no gate saw it.** `full_sweep` and `compile_check` catch exactly this class -- emitted
Zig that will not compile -- but only over `test/*.zbr`, and no corpus file uses the form.
`doc_example_check` only reads `live` docs, and the docs correctly show `.chars()`, so there
is nothing there to trip on either. The construct is reachable by any user and exercised by
no file we own.

**Fix direction.** Either refuse it in the type checker with a diagnostic naming `.chars()`
as the fix, or lower it as `.chars()` does. Refusing is the smaller change and matches how
the language already treats byte-vs-codepoint as a decision the author must make -- silently
picking one would be the "nothing fabricated" violation in the other direction.

**Control when fixing.** A `smoke_tc_fail` fixture asserting the refusal (with a position),
plus -- if it is lowered instead -- a `smoke_run` fixture asserting what it iterates. Watch
the fixture fail against today's compiler first: today it does not error, it produces bad
Zig, so a fixture that merely expects "compilation fails" would pass for the wrong reason.

**FIXED 2026-09-05.** The front end now REFUSES it, so the failure surfaces where the user
is standing instead of inside generated Zig:

```
t.zbr:3:5: error: cannot iterate a 'str' directly -- use s.chars() for codepoints, or index s[i] over its bytes
```

The refusal names BOTH loops because the language genuinely has two and the choice is the
user's -- bytes or codepoints. `s.chars()` was RUN standalone before being named here
(BUG-269: a refusal whose suggested fix does not work is advice pointing nowhere).

It cannot false-positive a legitimate iteration: `for c in s.chars()` / `.split()` /
`.lines()` all iterate a CALL, whose type is not `str`, so they never reach the guard.
Verified against all three plus `List(str)` iteration.

Fixture `test/bug330_str_forin_refusal_test.zbr`, registered `smoke_tc_fail` with the FULL
COORDINATE pinned (BUG-249's precedent), and watched failing with the old leaked Zig error
before the fix.

---

### BUG-332: the selfhost rejects source the bootstrap accepts — three spurious "expected str, got int" in main.zbr, with fabricated positions

**Status:** FIXED 2026-09-04, same day. **ROOT CAUSE: the checking pass never bound
for-in loop variables.** Only the seeding walk did, and the scope is not cleared between
functions — so inside a loop body a variable resolved to whatever a name of the same
spelling had been bound to in a PREVIOUSLY CHECKED function. In `selfhost/main.zbr`,
`for k in obj.keys()` picked up `var k: int` from a function 2,500 lines earlier.

**The fix is one derivation with two consumers.** The seed pass's element-type logic is
extracted as `forInElemType(fi, ctx)` and called from BOTH passes; the checking pass now
binds each loop variable to it. Binding `unknown_` is the safe floor — it carries no
information, so a wrong type can never be asserted against it, which is the property that
was missing.

A `JsonValue`'s `keys()` also gained its own arm. The §28f `keys()`/`values()` case reads
`key_t` off a `hashmap_` receiver and a JsonValue is not one, so it fell through to the
floor and was then exposed to the stale binding.

**This was general, not specific to my code.** Any name reused as a loop variable anywhere
in a large module was exposed — `k` and `i` above all. It only surfaced now because the
failure needs the loop variable to be PASSED somewhere typed: `out + k` is accepted for an
int, so concatenation hides it. That is why the corpus never tripped it.

**Fixture:** `test/bug332_loopvar_scope_test.zbr`, registered `smoke_run`, covering three
iterator shapes (a `List(str)` parameter, `split()`, and `JsonValue.keys()`). Watched RED
against a mutant with the check-pass binding removed — three errors, one per shape — and
green after. Note the fixture's own error positions are ACCURATE; the fabricated ones
appear only in the large module, so position quality is not part of this bug's repro.

Adding ~155 lines of JSON-rewriting helpers to `selfhost/main.zbr` makes the SELFHOST
report three `type mismatch: expected str, got int` errors. The BOOTSTRAP compiles the
identical file with `rc=0` and no diagnostics. The code is therefore not the problem, and
the selfhost is refusing valid source.

**The positions are fabricated, which is most of why this took so long to characterise.**
Every one of the three points somewhere the error cannot be:

| reported | what is actually on that line |
|---|---|
| `main.zbr:2816:32` | `while i < v.len` — the line is 20 characters, so column 32 does not exist |
| `main.zbr:2863:42` | `return body` — returning a `str` param from a `str` function |
| `main.zbr:2902:52` | a COMMENT line |

Chasing the carets is a dead end; they should be disbelieved outright. Related to the
BUG-288 family (statements carrying no real position), but this is worse: these are not
zeroes, they are plausible-looking coordinates that are wrong.

**Reproduction, which is the useful part.** It is CUMULATIVE and does not reduce:

```
committed main.zbr                          -> 0 errors
  + dbgJsonStr        (str escaper)         -> 0 errors
  + dbgWithKey        (calls dbgJsonStr)    -> 1 error
  + dbgRemapSetBreakpoints                  -> 2 errors
  + dbgRemapStackTrace                      -> 3 errors
```

One error per function, and each of the three calls `dbgJsonStr`. But **every smaller form
compiles clean**, so none of these is the trigger on its own:

- `dbgJsonStr` alone in main.zbr — clean
- `dbgWithKey` alone in main.zbr, with the loop variable used directly instead of passed to
  `dbgJsonStr` — clean
- `dbgJsonStr` + `dbgWithKey` **extracted to a standalone file** — clean
- the same pair extracted **with a `use` statement** (multi-module path) — clean
- three near-identical copies of the pattern appended to committed main.zbr — clean

Ruled out by experiment, so nobody repeats them: name collision (renaming the helper
changes nothing), module-level shadowing (main.zbr has ZERO module-level vars), a
for-header inference fault of the BUG-226 kind (hoisting `obj.keys()` into a typed local
changes nothing), the nested `Json.stringify(obj.at(k))` call (replacing it with a literal
changes nothing), and a per-module count limit (three copies are fine).

What remains is an interaction between a cross-function call and something about
`main.zbr` specifically — 3,800 lines and ~200 top-level defs.

**Why it hid.** `zebra -c` DOES report it, so this is not the front-end/codegen split that
hides other bugs. What hid it is that the selfhost is the only compiler anyone runs on
this file, and nothing compares the two on `selfhost/*.zbr`. `divergence_check` sweeps
`test/` and `examples/`, not the compiler's own sources — so a selfhost-rejects /
bootstrap-accepts divergence on the compiler itself is invisible to every gate.

**Control when fixing.** The recipe above, driven from the committed tree. The saved WIP
patch (264 diff lines) is what triggers it. A gate worth considering separately: compile
`selfhost/*.zbr` with BOTH compilers and require agreement — that is the check whose
absence let this exist, and it is cheap now that the bootstrap is otherwise unused.

### BUG-329: `print` statements carry no source position, so `zebra debug` cannot breakpoint them (SELFHOST REGRESSION)

**Status:** FIXED 2026-09-04 (same session it was found). `AstBuilder.zbr` now derives
the print statement's span from its first argument via `spanOf`, the helper BUG-288 batch 2
added for compound expressions. Markers on the gate fixture went 8 -> 15, and
`tools/debug_map_check.sh` was watched going RED on the six missing lines BEFORE the fix
and green after.

NOT fixed: `pass` and `break` still carry no position, in BOTH compilers. Their parse
nodes have no sub-expression to derive from, so they need a real position captured in the
parser rather than a derivation. Lower value -- nobody breakpoints a `pass` -- and left
open deliberately rather than silently.

Codegen stamps `// zbr:<file>:<line>` above each statement it emits; those comments are
the entire basis of the debugger's source map. `genStmt` emits one only when
`stmtLine(s) > 0`, and `AstBuilder.zbr:782` builds a print statement with `zspan()` --
`Span(0, 0, 0, 0)`. So a print statement emits no marker, and a breakpoint set on a
print line silently slides to the next line that does have one.

**The bootstrap gets this right, which makes it a regression rather than a gap.**
Measured on the same 12-line probe:

| line | statement | bootstrap | selfhost |
|---|---|---|---|
| 3 | `a = a + 1` | marker | marker |
| 4 | `print("p")` | **marker** | **NONE** |
| 9 | `pass` | NONE | NONE |
| 11 | `break` | NONE | NONE |
| 12 | `print(a.toString())` | **marker** | **NONE** |

`pass` and `break` are missing in BOTH compilers -- a smaller, shared gap, filed here
rather than separately because the fix is the same one line each.

**Repro**

```zebra
def main()
    print("p")
    var a: int = 1
```

`zebra debug --dump-map <file>` lists no marker for the print line.

**Cause.** `selfhost/AstBuilder.zbr:782`:

```
return Stmt.print_(StmtPrint(zspan(), args, true))
```

Six statement constructors take `zspan()` there: `assign`, `break_`, `continue_`,
`contract`, `pass_`, `print_`. `assign` has other construction sites that do carry a
real span, and measures breakpointable, so the live damage is `print` (both compilers
for `pass`/`break`).

**Why no gate saw it.** Three stop just short, and the gap between them is structural:

- `diag-columns` asserts a *diagnostic* can say where. Its candidates are the smoke
  suite's must-FAIL fixtures, and a `print` statement does not produce a diagnostic --
  so a statement whose position is only ever consumed by the SOURCE MAP is invisible
  to it. Same data, different consumer, no coverage.
- `divergence_check` compares whether both compilers *compile* a file. Both do; the
  emitted Zig differs only in comments. A marker regression cannot make it red.
- `output_sweep` compares what programs *print*. Markers are comments; behaviour is
  identical.

**Control when fixing.** `tools/debug_map_check.sh` leg 2 is the witness: the fixture's
prints name their own line numbers, and the gate requires each to appear in the map.
It is RED on those lines today. Do not "fix" it by re-baselining -- the whole point of
that leg is that the round-trip leg beside it is GREEN while this is broken, because
two lookups agreeing with each other says nothing about whether the map is complete.

### BUG-321: `--version` and `--help` write to STDERR, so `zebra --help | less` shows nothing — FIXED 2026-09-01

**The last living residue of the print-stream myth.** Found in free time by pointing
yesterday's `stream-sep` instrument at the COMPILER rather than at programs it produces.

```
$ zebra --help | less          # nothing
$ zebra --version > v.txt      # 0 bytes
$ zebra --version 2>&1 >/dev/null
zebra 0.1.0 (Phase 22 cutover — selfhost pipeline primary)
```

Measured on BOTH `zebra.exe` and `zebra-selfhost-B.exe` (5 observables each: `--version`,
`--help`, a type error, `-c` on a good file, `--emit-zig`). The two compilers agree on
four of the five and put **0 bytes on stdout** for every one of those four.

**NOT A LOWERING BUG — the source asks for stderr and correctly gets it.**
`selfhost/main.zbr:2409` is `sys.errln("zebra 0.1.0 …")`, and the usage block is the same.
`sys.errln` is behaving exactly as specified. The defect is in the ask, which is why
BUG-318's fix did not touch it: that fixed where `print` GOES, and this code never called
`print`.

**Why the ask is wrong, and it is a dated artifact.** For months `print` appeared not to
work — BUG-318 sent it to stderr, and the repo recorded that as a Windows
"stdout-to-PIPE writes nothing" platform quirk (see `project_print_stream_myth`). Anyone
writing user-facing output in `main.zbr` would have found `print` silently useless and
`sys.errln` visibly working. **The workaround outlived the myth that caused it.**
`main.zbr` carries **80 `sys.errln` against 6 `print`**.

**SCOPE — most of those 80 are CORRECT and must not be touched.** Diagnostics, errors,
warnings and `note:` advisories belong on stderr; so does progress (`compiling: x.zbr`),
which is precisely what lets `zebra --emit-zig f.zbr > out.zig` work at all. gcc does the
same. The defect is the two that violate universal convention:

| call site | today | should be |
|---|---|---|
| `--version` banner | stderr | **stdout** |
| `--help` / usage block | stderr | **stdout** |
| errors, warnings, `note:` | stderr | stderr — correct, leave alone |
| progress (`compiling: …`) | stderr | stderr — correct, and load-bearing for `--emit-zig >` |

A usage block printed in response to a BAD invocation is a different case and correctly
stays on stderr (with a non-zero exit). Only the case where the user ASKED for it moves.

**NO GATE CAN SEE THIS, and the gap is one level up from where we just armored.**
`tools/stream_check.sh` (built 2026-08-29 for BUG-318) asserts that a compiled Zebra
program's `print` lands on stdout. It says nothing about the compiler's own output. Same
blind spot, one storey higher: we checked the programs the tool makes, not the tool.

**Control when fixing.** Extend `stream_check.sh` with a leg that runs the COMPILER:
`zebra --help` must put bytes on stdout and `zebra --version > file` must be non-empty —
and the leg must be watched going RED first, since it passes vacuously if the compiler
prints nothing at all. Keep a NEGATIVE leg asserting a type error still goes to stderr,
or a fix that redirects everything to stdout passes.

**0.9 relevance.** 0.9 means ready-for-others. `--help | less` is among the first three
things a stranger does with an unfamiliar compiler.

**BLOCKED ON CRITERION 2 — AND THE OBVIOUS FIX WILL LOOK LIKE IT FAILED.** Verified
2026-08-30, not inferred. The fix is `sys.errln` -> `print` in `main.zbr`. But the
committed `selfhost/main.zig` is emitted by the **bootstrap**, and the bootstrap still
lowers a Zebra `print` to `std.debug.print` — stderr. Measured on a two-line program:

```
bootstrap emit:   std.debug.print("{s}\n", .{"orbit"});      -> stderr
selfhost  emit:   _zbr_print("{s}\n", .{"orbit"});           -> stdout
```

The bootstrap's inlined preamble even *contains* `_zbr_print` (it is in the shared
`stdlib_preamble.zig`, edited for BUG-318) and never calls it: the runtime helper shipped,
the lowering did not. BUG-318 was landed selfhost-only, which the standing
drop-bootstrap-parity rule permits — this is that decision's bill arriving.

So making the two-line source change today, rebuilding, and testing `zebra --version`
yields **no observable difference**, and the natural reading is "my fix did not work"
rather than "the compiler that compiled my compiler does not have it yet." Same family as
the documented preamble/regen ordering trap, new instance.

Order: land criterion 2 (regeneration authority moves to the selfhost), THEN this. Or land
the source change now and expect it to be inert until then — but say so in the commit, or
it reads as a fix that did not take.

**FIXED 2026-09-01, both halves, once criterion 2 unblocked it.**

`--help` and `-h` are now RECOGNISED flags -- they were consulted nowhere, and `--help`
only "worked" by falling through to the no-source-file path -- and they and `--version`
write to STDOUT and exit 0.

**THE ASYMMETRY IS THE ACTUAL FIX, and it is now asserted rather than assumed.** One usage
text serves two situations: a REQUEST (`--help`), whose answer belongs on stdout with exit
0, and a DIAGNOSTIC (the invocation was wrong), which belongs on stderr with a non-zero
exit. Conflating them is what made `--help | less` print nothing. A single
`usageLine(s, to_stdout)` helper now carries all 28 lines to whichever destination the
situation calls for.

| | exit | stdout | stderr |
|---|---|---|---|
| `zebra --help` | 0 | 2227 | 0 |
| `zebra -h` | 0 | 2227 | 0 |
| `zebra --version` | 0 | 61 | 0 |
| `zebra` (no args) | **1** | **0** | **2227** |

**The gate caught its own pin coming good.** `tools/cli_check.sh` held two BUG-321 pins
asserting the WRONG behaviour; the moment the bug was fixed they failed with "is FIXED --
promote this pin to a real assertion", which is precisely what a pin exists to do. Both
became real assertions, plus a third that did not exist before: **usage shown for a BAD
invocation must stay on stderr with a non-zero exit.** Without it, a "fix" that simply
moved everything to stdout would pass the other checks while re-breaking this bug.

---

### BUG-323: unknown command-line flags are SILENTLY IGNORED, so a typo'd `--turbo` gives you a build you did not ask for — FIXED 2026-09-01

**The user's stated intent is discarded without a word.** `zebra --no-such-flag f.zbr`
exits **0** and simply compiles and runs the file. There is no unknown-argument branch in
`selfhost/main.zbr` at all (grepped: no `unknown`, no `unrecognised`, no
`startsWith("--")` fallthrough), and `--help` documents no pass-through behaviour. This is
an omission, not a design.

**Demonstration, on a program whose behaviour DEPENDS on the flag.** `half(7)` violates a
`require` precondition, so the contract firing is observable in the exit code and the
stdout:

| invocation | exit | stdout | what the user got |
|---|---|---|---|
| (no flag) | 1 | — | contract fires — correct |
| `--turbo` | **0** | **`3`** | contract stripped — correct |
| `--trubo` | 1 | — | **typo ignored: contracts still in** |
| `-turbo` | 1 | — | **single dash ignored: contracts still in** |
| `--TURBO` | 1 | — | **case ignored: contracts still in** |

Three of the five spellings a person plausibly types produce the *opposite* of the
requested build, silently, with a successful-looking run.

**THE PRECEDENT IS IN THIS FILE.** BUG-228: `--release` shipped **Debug** for four days
under 19 green gates, because the branch that emitted the executable passed no optimize
flag and Zig defaulted. "Everyone shipping with the flag shipped Debug believing
otherwise — the flag's whole purpose." That was a flag that reached the compiler and was
dropped internally; this is a flag that never reaches it at all. Same harm, one step
earlier in the pipeline.

**UNGIT, "nothing ambient": commands take intent explicitly, and refusals name the reason
and the fix.** A misspelled flag is a refusal the tool declines to make. The cost is
asymmetric and always in the same direction: the user believes they got the thing they
asked for, and the evidence that they did not is a behaviour difference they were not
looking for.

**SCOPE.** Measured on the top-level compile path. `zebra build` forwards arguments to a
sub-invocation and a deliberate pass-through may be correct *there* — that case is not
covered by this report and should be decided separately rather than swept in.

**Control when fixing.** An unknown top-level flag must exit non-zero and NAME the
offending argument. Suggest-the-nearest-match is a nicety, not the requirement; the
requirement is that it stops. A gate leg belongs with it, and must be watched RED first:
assert `zebra --no-such-flag f.zbr` exits non-zero AND mentions `--no-such-flag` on
stderr. Keep a positive leg (a REAL flag still works) or a fix that rejects everything
passes.

**Found how.** Probing the CLI surface deliberately, because the day's theory predicted
defects would cluster there: the round-trip gate is a fixed-point test on the compiler's
EMIT function, so everything the compiler does other than successfully compile its own
source is invisible to it — which is the entire argument-handling surface and every
failure path. Three of three bugs found today (BUG-321, BUG-322, this) are in that
region. See `pages/claude/fieldnotes_compiler-orbit_2026-08-30.md`.

**FIXED 2026-09-01.** An unrecognised flag is now a named refusal with the usage
attached, and exits 2:

```
$ zebra --trubo prog.zbr
zebra: unrecognized flag: --trubo

usage:
  ...
```

Measured, both directions -- because "refuses unknown flags" is satisfied trivially by a
build that refuses everything:

| invocation | exit |
|---|---|
| `-c`, `--turbo`, `--release`, `--emit-zig`, `--help`, `--version` | 0 -- unaffected |
| `--TURBO` | 2 -- `unrecognized flag: --TURBO` |
| `-turbo` | 2 |
| `--trubo` | 2 |

**CASE IS NOT FOLDED (Sean, 2026-09-01), and that lands better than the alternative.**
Making flags case-insensitive would have made `--TURBO` silently START working; leaving it
case-sensitive with unknown flags refused makes it a NAMED ERROR. The user is told, instead
of receiving a build they did not ask for -- which is the harm BUG-228 is the receipt for.

**Implementation, smaller than expected.** `ArgResult` deliberately exposes no raw argv, so
`contains` can only answer about flags you already know -- the wrong shape for finding one
you do not. One `unknownFlag(known)` method was added to the runtime; `args.contains(...)`
turns out to emit as a direct passthrough to the Zig method, so **no CodeGen and no
TypeChecker change were needed**, verified with `-c` before relying on it.

The 28 usage lines now live in one `emitUsage(to_stdout)` reachable from both the `--help`
request and the refusal, so the two cannot drift. The help documents the conventions: whole
words take two dashes, single letters take one, flags are case-sensitive, and an
unrecognised flag is an error rather than ignored.

---

### BUG-327: `zebra build` cannot work — TWO defects, and fixing the outer one exposes an INFINITE LOOP — FIXED 2026-09-01

**A documented subcommand that has never worked, with a second bug hiding underneath the
first.** Surfaced when BUG-322's delegation crash stopped masking it. Investigated to root
cause; **deliberately NOT fixed**, and the partial fix was REVERTED — see why below.

**LAYER 1 — stale Zig APIs in the runtime preamble.** The generated `build.zig` could not
compile at all:

```
build.zig:1039:28: error: root source file struct 'fs' has no member named 'selfExePathAlloc'
build.zig:1046:21: error: member function expected 2 argument(s), found 3
    std.Io.Dir.cwd().createDirPath(_io, ".zig-cache/zbr", .{}) catch {};
```

`std.fs.selfExePathAlloc` has **zero definitions** in Zig 0.16.0 (grepped the installed
toolchain), and `createDirPath` lost its options parameter. Both are in the `_build_*`
region of `selfhost/stdlib_preamble.zig`. The correct API was already in the same file
forty lines away -- `_sys_self_exe()`, which backs the working `sys.selfExe()`, uses
`std.process.executablePathAlloc(_io, _allocator)`. One call site drifted across a version
bump while its sibling did not.

**LAYER 2 — and this is why the fix was reverted. THE BUILD RE-INVOKES ITSELF FOREVER.**
With both APIs corrected, `zebra build` compiles its `build.zig` and then loops:

```
build declarative: ok
build: smoke_app: emit-zig test/toplevel_main_test.zbr
build declarative: ok
build: smoke_app: emit-zig test/toplevel_main_test.zbr        (forever, until timeout)
```

The generated build program does

```zig
const self_exe = <executable path of the running program>;
const argv = [_][]const u8{ self_exe, "--emit-zig", t.entry, "--output-dir", ... };
```

but the running program is **`build.zig.fast.exe`**, not `zebra.exe`. It asks *"where am
I?"* when it needs *"where is the compiler?"*, so it re-runs the build, which re-runs the
build. **The removed API had the same semantics**, so this loop was always present -- the
compile error was the only thing preventing it.

**WHY THE PARTIAL FIX WAS BACKED OUT.** Before: a fast, clear compile error, exit 1. After
the API fix: an infinite loop until timeout, with no useful output. **A hang is worse than
an error** -- it is unbounded, it produces nothing to act on, and it burns the machine.
Shipping that unattended was not a trade worth making, so `selfhost/stdlib_preamble.zig`
was restored to its committed state. The API corrections are RIGHT and should land -- but
only together with a fix for layer 2, or `zebra build` gets worse rather than better.

**WHAT LAYER 2 NEEDS IS A DESIGN DECISION, which is why it is not made here.** The
generated build program must locate the Zebra compiler. Candidates, none obviously right:
pass the compiler path in as a generated constant at emit time; read it from an
environment variable the driver sets; take it as an argument; or have the build program
not shell out to a compiler at all. That is a call about how `zebra build` is architected,
not a bug fix.

**WHY IT SURVIVED, and it is the same seam as the others found this week.** No gate
invokes `zebra build` -- verified by grep across every script in `tools/`. The Build API is
covered three times in the smoke suite and sits in both heavy baselines, but as a
**library**, by running `build_declarative_test.zbr` as an ordinary program. The
**subcommand that drives it** is a different code path with no coverage, so a hard compile
error inside it survived 37 green gates. See
`wiki/pages/concepts/concept_self-verification-blind-spot.md`.

**Control when fixing.** A gate leg that scaffolds a small project OUTSIDE the repo and
asserts `zebra build` exits 0 and produces the named binary. It must be run from a user
directory, or it re-passes for the BUG-322 reason. And it must have a TIMEOUT, or layer 2
turns the gate into a hang instead of a failure.

**MEASURED 2026-09-01 WITH A BUILD THAT ACTUALLY RUNS: BOTH COMPILERS FAIL, IDENTICALLY.**
The earlier entry left open whether this was a delegation problem. It is not.

`b.run()` appears in the entire corpus **only inside comments saying it is deliberately not
called** -- both committed build fixtures are declarative by explicit intent. So no test
had ever executed a build. Scaffolding one:

```zebra
def main()
    var b = Build.new()
    var app = b.exe("demo", "app.zbr")
    b.run()
```

`zebra build.zbr` run by the SELFHOST, directly, no delegation:

```
zebra_rt.zig:1083:28: error: root source file struct 'fs' has no member named 'selfExePathAlloc'
```

Same line, same cause as the delegated path. **The stale API is not a bootstrap problem
and removing the delegation would not fix it.**

**AND IT EXPLAINS WHY THE DECLARATIVE FIXTURES LOOKED FINE.** The bootstrap splices the
preamble INLINE into the root file, where Zig analyses eagerly; the selfhost IMPORTS
`zebra_rt.zig`, where analysis is lazy. An uncalled stale function is never analysed. So
`zebra build.zbr` on a declarative fixture exits 0 and prints `build declarative: ok`
while being one `b.run()` away from the same failure. A green result there means the code
was not reached, not that it works.

**NOW PINNED** in `tools/cli_check.sh`, which scaffolds this project and asserts the
failure, so it cannot hide again -- and the pin fails the gate the day BUG-327 is fixed.
A second leg asserts, unpinned, that it fails FAST rather than hanging: layer 2's infinite
self-invocation is the regression that leg exists to catch.

**COVERAGE STATEMENT, since it is the useful part:** the Build API's DECLARATION half is
covered three times over (smoke x3, both heavy baselines); its EXECUTION half was covered
zero times until today. That asymmetry is the whole reason a hard compile error lived
inside a shipped subcommand through 37 green gates.

**FIXED 2026-09-01 -- BOTH LAYERS, TOGETHER, which is the point.** `zebra build`
now works; it never had on Zig 0.16.

```
$ zebra build
build: demo: emit-zig app.zbr
build: demo: zig build-exe .zig-cache/zbr/app.zig
build: demo -> zig-out/bin/demo
$ ./zig-out/bin/demo
app ran
```

**Layer 1** was the stale APIs (`std.fs.selfExePathAlloc`, removed in 0.16;
`createDirPath`'s dropped options argument).

**Layer 2** was the real defect: the generated build program asked for ITS OWN executable
path, which answers "where am I?" when the question is "where is the compiler?" -- so it
re-invoked itself forever. `zebra build` now exports **ZEBRA_COMPILER** and the build
program reads it; an installer can set the same variable.

**FIXING LAYER 1 ALONE MADE THINGS WORSE, and that attempt was reverted 2026-09-01**: a
fast, clear compile error became an unbounded hang. The two had to land together, and the
entry above records why shipping the partial fix would have been a bad trade.

**IF THE VARIABLE IS MISSING IT REFUSES, naming the reason and the fix** -- it does not
fall back to a guess. A silent fallback there is precisely what produced the infinite
self-invocation, so re-introducing one would recreate the bug.

**Now covered by three assertions in `tools/cli_check.sh`**: the build SUCCEEDS, it
produces the named binary, and running the build FILE directly (which gets no
ZEBRA_COMPILER) refuses by name rather than hanging -- exit 124 is called out explicitly,
because a hang would mean layer 2 had returned.

**The coverage gap that let it live: `b.run()` appeared in the entire corpus only inside
comments saying it was deliberately not called.** The Build API's DECLARATION half was
covered three times over; its EXECUTION half zero times. That is how a hard compile error
sat inside a shipped subcommand through 37 green gates.

---

### BUG-326: `sys.exit(N)` SEGFAULTS for N outside 0..255 and loses buffered stdout — FIXED 2026-09-01

**`sys.exit(-1)` is an ordinary thing to write, and it crashed the program.** Found while
tracing BUG-322, whose panic turned out to be this bug one level down.

Measured with controls, before the fix:

| `sys.exit(N)` | exit | stdout |
|---|---|---|
| 0, 1, 2, 255 | correct | `ran` — preserved |
| **256** | **139 (SEGV)** | **empty — lost** |
| **-1** | **139 (SEGV)** | **empty — lost** |

The `print("ran")` that preceded the call did not appear, so the failure destroys evidence
as well as the exit code.

**MECHANISM.** `selfhost/CodeGen.zbr` emitted `std.process.exit(@intCast(<expr>))`, and
`std.process.exit` takes a **u8**. `@intCast` of a negative or >255 `i64` is not a
compile error and does not trap cleanly in the shipped build — it takes the program down.

**FIX — truncate the way C's `exit()` does, rather than refuse.** A caller who writes -1
already expects 255 on POSIX:

```zig
std.process.exit(@truncate(@as(u64, @bitCast(@as(i64, <expr>)))))
```

-1 -> 255, 256 -> 0, 0..255 unchanged. The inner `@as(i64, ...)` is load-bearing:
`@bitCast` will not accept a `comptime_int`, so a literal argument needs a runtime type
first. Verified across all six values above; stdout preserved in every case.

**Deliberately a CodeGen-only change.** The alternative was a runtime helper in
`stdlib_preamble.zig`, which would have required the build -> regen -> build ordering and
its documented footguns. Nothing about this fix needs the runtime.

**Fixture:** `test/bug326_sys_exit_range_test.zbr`, which exits **0** by way of
`sys.exit(256)` — exercising the crashing path while staying a well-behaved `smoke_run`.

**Not covered:** the -1 -> 255 direction is not pinned by a fixture, because a non-zero
exit is failure to the smoke harness. If a gate leg is added later, assert it there.

---

### BUG-318: `print` writes to STDERR, so every Zebra program's output vanishes under `>` or `|` — FIXED 2026-08-29

**Found while trying to switch the regeneration authority to the selfhost (bootstrap
sunset, criterion 2), which needs `--emit-zig > file` to work. It does not, and the
reason turned out to have nothing to do with `--emit-zig`.**

**Zebra's `print()` lowers to `std.debug.print`, and `std.debug.print` writes to
STDERR.** Both compilers do it -- this is language-wide, not a selfhost defect:

```zebra
def main()
    print("hello from zebra")
```
```zig
std.debug.print("{s}\n", .{"hello from zebra"});   // emitted by BOTH compilers
```

Measured on the built executable, streams separated: **stdout 0 bytes, stderr 17
bytes, exit code 0.**

**WHAT THIS COSTS A USER.** Every ordinary composition silently produces nothing,
and nothing reports a problem:

| | |
|---|---|
| `prog > out.txt` | empty file, exit 0 |
| `prog \| grep x` | no matches, exit 0 |
| `prog \| head` | nothing |
| capture in any harness that reads stdout | empty |

That is not a wrong answer, so it is not literally G1 -- it is the **total silent loss
of a program's entire output under its most ordinary use**, with a success exit code.
For a 0.9 that means "ready for others", this may be the most user-visible defect in
the ledger: it is the first thing a stranger does after `print`.

**IT IS A DEFECT, NOT A DESIGN, and two things prove that rather than assert it:**

1. **`sys.errln(msg)` exists and is documented as "Write to stderr + newline".** That
   API is *redundant* if `print` already writes to stderr. Its existence is the
   language's own statement that `print` is meant to be stdout.
2. **QUICKSTART documents `--emit-zig` as "Zig source to stdout"** (twice: the CLI
   table and the command list). The documented behaviour and the actual behaviour
   disagree, and the docs are the side that describes the intent.

**BUG-317 IS A SYMPTOM OF THIS, not a separate defect.** It was filed as "`--emit-zig`
writes the generated Zig to stderr in the selfhost and stdout in the bootstrap". The
real story: the selfhost's emit path ends in `print(zig_src)` (selfhost/main.zbr) and
`print` is stderr, while the bootstrap writes that path's output directly. Fixing this
fixes 317; 317 should be closed as a duplicate when this lands, not fixed separately.

**IT ALSO RE-EXPLAINS A DOCUMENTED HAZARD.** This repo records "Windows stdout-to-PIPE
writes nothing (redirect/file fine)" as a platform quirk, and several tools are shaped
around it. That diagnosis looks wrong: stdout gets nothing under a FILE redirect too.
The runs that appeared to work were capturing `2>&1`. **Before shaping any more tooling
around the Windows-pipe theory, re-test it against this.**

**Why nothing caught it:** `output_sweep` -- the only gate that reads what programs
PRINT -- captures combined output, so a stream mix-up is invisible to it by
construction. Every other gate asks whether things compile. The one gate that could
have seen this cannot distinguish the streams it merges.

**Control when fixing:** a fixture whose stdout is captured *separately from stderr*
must contain the printed text, and its stderr must not. Watch it fail first -- today
stdout is empty. And assert the OTHER direction in the same run: `sys.errln` output
must still be on stderr, or the fix has merely swapped which stream is wrong.

**Scope caution:** ~15 tools invoke the compiler and several capture combined output
or rely on the current behaviour. `output_sweep`'s golden baseline was recorded with
`print` on stderr; if it captures `2>&1` the baseline is unaffected, but that must be
checked rather than assumed before the fix lands.


---

**FIXED 2026-08-29.** `_zbr_print` added to `selfhost/stdlib_preamble.zig` -- it formats into
a 4 KB stack buffer (falling back to an allocation rather than TRUNCATING, since truncation
would be the same fabrication this bug is about) and writes to
`std.Io.File.stdout()`. The selfhost's `genPrint` emits it at both sites.

**Verified, both directions and the usage that was broken:** stdout 17 bytes / stderr 0
(was 0 / 17); `sys.errln` STILL on stderr; `prog > file` captures the output; `prog | grep`
matches. A new gate, `tools/stream_check.sh` (`stream-sep`, FAST tier), asserts all six.

**Verified with the REAL ATTACKER rather than a mutation:** reverting the emitted calls to
`std.debug.print` gives stdout 0 / stderr 57 and fails the gate's first leg.

**SELFHOST ONLY, by the freeze policy.** The bootstrap still emits `std.debug.print`. It is
frozen -- fixes only for what breaks regeneration -- and this does not break regeneration,
it REPAIRS it: the regen needs `--emit-zig > file`, and the selfhost's emit path ends in
`print`. That unblocks the bootstrap sunset's criterion 2.

**A FALSE BELIEF RETIRED WITH IT.** This repo recorded "Windows stdout-to-PIPE writes
nothing (redirect/file fine)" as a platform quirk and shaped tooling around it. It was this
bug: a FILE redirect got nothing either, and the runs that appeared to work captured `2>&1`.
The theory survived because it PREDICTED the symptom and its workaround made the symptom
disappear -- a wrong explanation with a working workaround is nearly unfalsifiable, since
nobody re-tests a problem they have stopped having.

**Errors are still swallowed** (`catch {}`), matching `_term_print` and `std.debug.print`
before it. Recorded in the code as a deliberate match to convention and NOT an endorsement:
a print that silently does nothing on a full disk is this bug one level down. Making `print`
fallible is a language change, not a codegen one.

**Unmeasured:** one syscall per print, where `std.debug.print` was also unbuffered. If a
print-heavy program regresses, buffering belongs in `_zbr_print` -- but measure first.

### BUG-316: `internal` means something different in each compiler, and the selfhost's diagnostic misreports what the user wrote — OPEN (found 2026-08-29)

Found by auditing the modifier next to `protected` (BUG-315), which is why that entry
left a note saying nobody had checked this one. Nothing found it earlier because
**zero corpus files use the modifier**, so no gate — `divergence_check` included, since
it compiles the corpus — could ever have seen it.

**Documented meaning** (QUICKSTART): `internal` excludes the member from cross-module
interface tables. It does NOT restrict access within the module; that is `private`.

**The bootstrap implements exactly that.** `internal` is skipped when building the
cross-module tables (`src/TypeChecker.zig:770` and `:804`) and is absent from the
access check, which reads `if (mods.private)` at `:2491`.

**The selfhost has no `internal` concept at all.** `selfhost/Parser.zbr:1916` folds it
into `pending_private`, and no separate flag for it exists anywhere under `selfhost/`.
So the modifier is silently promoted to `private`.

**Measured, with a control that proves the probe discriminates:**

| probe | bootstrap | selfhost |
|---|---|---|
| `internal` field read from a sibling class in the SAME module | **rc=0, accepts** | **rc=1, refuses** |
| `private` field read from a sibling class (control) | rc=1 | rc=1 |

The control matters: with `private` both compilers refuse, so the divergence is
specific to `internal` rather than the probe being malformed.

**TWO DEFECTS, and the second is the worse one.**

1. The selfhost is **stricter than the reference**, violating the standing rule that the
   two compilers must be functionally equivalent. A program that compiles under the
   bootstrap is refused by the shipping compiler.
2. The message reads **`error: 'secret' is private`** for a field the user declared
   `internal`. That is UNGIT "nothing fabricated" at the diagnostic surface: it reports a
   modifier the source does not contain, so the author's first move is to search their own
   code for a `private` that is not there.

**Which one is right:** the bootstrap. It matches the documentation, and the
documented behaviour is coherent (module-scoped visibility, C#-like). The selfhost is
the side to change.

**Shape of the fix:** thread a distinct `is_internal` through
`parseMemberDecl` -> `parseDeclField` / `parseMethodDecl` -> the PNode -> AstBuilder ->
the Decl modifiers -> TypeChecker, where it must be excluded from the cross-module
tables but must NOT be added to `private_member_keys`
(`selfhost/TypeChecker.zbr:402`). Five layers; the parser signatures at
`Parser.zbr:1986` and `:2041` already carry `is_private`/`is_public` and would gain a
third.

**Control when fixing:** `test/zz_internal_probe.zbr` is the probe as run (rename it
into a real fixture). It must compile and RUN under BOTH compilers, and the `private`
variant must still be refused by both — a fix that made `internal` universally
permissive would pass a one-sided test. Also assert the cross-module half, which
neither probe covers: an `internal` member must be invisible from ANOTHER module, or
the fix has made it a no-op.

**THE GENERAL GAP THIS EXPOSES, worth more than the bug.** A language feature with zero
corpus uses is unverified by construction, and nothing currently reports that.
`registration_check` asks whether every tracked test is asserted by something; the
mirror question — whether every keyword and modifier is EXERCISED by something — is
equally derivable (`Token.zbr`'s keyword table intersected with corpus usage) and has
no instrument. `protected` and `internal` were the two modifiers nobody used, and both
turned out to be defective.

### BUG-315: `protected` is a synonym for `private`, and its documented meaning needs inheritance the language does not have — CLOSED 2026-08-29

**Filed 2026-08-29. DECIDED THE SAME DAY (Sean): remove the keyword.**

Found while drafting the system concept, not by a gate.

`protected` is a reserved word, so it costs every Zebra user the right to name a
field, parameter or column with it. What it buys:

- **Behaviourally identical to `private`.** `src/TypeChecker.zig:2491` reads
  `if (mods.private or mods.protected)` — one branch, no distinction. The selfhost
  comment at `selfhost/TypeChecker.zbr:339` says the same: the key set holds
  members "marked private/protected", together.
- **Documented with semantics the grammar cannot express.** QUICKSTART: "`protected`
  limits to the class and subclasses." There are no subclasses. The class header
  rule is `ClassHeader -> ImplementsClauseOpt AddsClauseOpt` — conformance via
  `implements`, reuse via `adds`, and **no class-from-class inheritance anywhere in
  the grammar**. A corpus sweep finds zero uses of the keyword.

So the surface offers a distinction the system does not make — UNGIT "nothing
fabricated", at the language level rather than the tooling level.

**WHY NO GATE SAW IT, which is the transferable part.** `lint_reserved_words`
classifies a keyword as R1 UNREACHABLE (no rule in either compiler mentions the
token) or R2 PARSED-THEN-REFUSED (accepted, then "not yet implemented").
`protected` is neither: it parses, it reaches the type checker, and it *does
something*. It is a third class — **reachable, implemented, and semantically
vacuous** — and the gate is looking for absence, so a word that is fully present
sails through it. Same shape as `doc_lint` D4 being *more* satisfied by a duplicate
bug number: the instrument that would notice is checking for presence.

**Options considered:**

1. **Free the word**, as `aspect`/`weaves`/`lock`/`from`/`trace` were under U4a and
   `error`/`try` were on 2026-08-13. Costs nothing — zero corpus uses — and returns
   a common identifier to users. **This is the decision.**
2. Keep it as an alias for `private`. Rejected: two spellings of one meaning is
   precisely the "one idea written two ways" that the concision rule rejects.
3. Give it real semantics. Requires implementation inheritance, deliberately absent.

The QUICKSTART sentence is wrong today regardless of the keyword's fate and must not
survive: it describes a hierarchy that cannot be written.

**Control, as run.** `test/bug315_protected_freed_test.zbr` names a local, field,
method, parameter, enum member and union variant `protected`. Watched FAILING against
the pre-change compiler (`expected identifier, got 'protected'`), and it now prints all
nine expected values. Registered `smoke_run`.

**And the log could not confirm it ran.** Grepping the QUICK log for `bug315` returns
zero — but so does grepping for `bug280`, a sibling that certainly passed, because the
runner prints nothing for passing tests. The check that actually settles it is
`positive_set.sh`, the derivation the suite itself uses: `bug315` is in it. Without the
`bug280` control, the zero would have read as a skipped test.

**Two things the fixture taught, both now recorded in it.** A parameter may not shadow a
sibling declaration, so `Guard.check`'s parameter is `n` — the same reason bug280's
static parameter is `n`. And union matching is `on Slot.protected as n`, not the
payload-destructuring form guessed first.

**Sites:** 8 bootstrap (`Token`, `Ast`, `AstBuilder`, `AstPrinter`, `Parser`,
`TypeChecker`, 2 in `ZebraGrammar`), 5 selfhost (`Token.zbr` ×2, `Parser.zbr` ×2,
`TypeChecker.zbr` comment), plus `grammar.txt` and QUICKSTART. `reserved-words` 81 → 80.
QUICK 25/25, smoke 388/388, round-trip byte-identical.

**Not audited in this pass, and it should be:** `internal` is the neighbouring
modifier and got no scrutiny here. It at least has a stated meaning the language can
express ("excludes the member from cross-module interface tables"), but nobody has
checked that it does that.

### BUG-308: `File.delete` panics on every failure except `FileNotFound`, so a retry loop around it is unreachable code — CLOSED 2026-08-26

**A retry loop was written to survive a failure the primitive cannot report.**

`deleteScratch` in `selfhost/main.zbr` retries `File.delete` ten times with exponential
backoff, because "Windows releases the image of a just-executed process asynchronously, and
under load that lag exceeds 300 ms" — i.e. it exists to survive a **locked file**. But the
emitted delete is:

```zig
deleteFile(_io, path) catch |_fd_err| { if (_fd_err != error.FileNotFound) @panic("File.delete error"); }
```

A lock is not `FileNotFound`, so the first attempt **panics** and the loop never reaches its
second try. `deleteScratch` also calls `File.exists` first and returns if absent, so the
one error it tolerates is the one that cannot occur on that path. The backoff is dead code
for the only failure it was written for.

**Verified directly, without needing load.** A directory is also not `FileNotFound`:
`File.delete("some_dir")` compiled with the *tolerant* (bootstrap) emit panics —
`thread 27476 panic: File.delete error`. So the mechanism is proven; what remains inferred
is only that the daily's specific panic was a lock (it is load-dependent and did not
reproduce on an idle re-run, 374 files behaviour-identical).

**The panic also says nothing.** No path, no underlying error — `@panic("File.delete
error")` is the whole message. UNGIT "nothing withheld": the runtime knows which file and
which errno and reports neither.

**API decision (Sean, 2026-08-26): option 1.** Options considered:
1. `File.tryDelete(path): bool` — a non-panicking primitive a retry loop can actually use.
   Cleanest, but it is new surface area.
2. Make `File.delete` `throws` so a program can `catch` it. Most consistent with Zebra's
   error model, but it changes an existing signature.
3. Widen the tolerated set to include lock/sharing errors. **Rejected** — that hides real
   failures and is the fabrication direction.

Recommendation: (1), and give the panic a message naming the path and the error regardless
of which is chosen.

**Related:** BUG-307 (the parity half of the same emit) is fixed.

**Fixed 2026-08-26 in BOTH compilers** — `deleteScratch` cannot use a builtin the bootstrap does not know, because the bootstrap regenerates `selfhost/main.zbr`. Verified in the EMIT: both compilers now emit `File.delete failed on '{s}': {s}` and **zero** occurrences of the old bare string, and the regenerated `selfhost/main.zig` carries the `blk_ftd` form. Fixture `test/bug308_try_delete_test.zbr` (`smoke_run`), whose leg 3 is the control: `tryDelete` on a directory must report **false**, without which legs 1 and 2 are satisfied by a function that returns true unconditionally. Quick tier 25/25, smoke 384/384.

**It also exposed a gap in `rebuild.sh`.** Its stale-bootstrap guard listed only the two preamble files; everything in `src/` is compiled into the bootstrap with the same staleness. The regen ran an older bootstrap and failed with `expected 'bool', got 'void'` — a type error naming the very feature being added, which reads as "your new code is wrong". List widened; falsified by `tools/rebuild_guard_check.sh`, because the successful rebuild could not prove it (the loop breaks on its first match, and the preamble happened to be newest).

### BUG-313: `List.at()` is NOT bounds-checked in `--release`, and the docs recommend it BECAUSE it is — CLOSED 2026-08-26

**A documented safety guarantee that does not hold in the builds users ship, and which
fabricates a value rather than trapping.**

`QUICKSTART.md` says:

```
var x = items.at(0)                  # index (bounds-checked) — preferred
```

`.at(i)` lowers to `list.items[@intCast(i)]` — raw slice indexing. Zig bounds-checks that
in Debug and ReleaseSafe and **not** in ReleaseFast, and `zebra --release` passes
`-OReleaseFast` (`src/main.zig:1520`).

Measured, both modes, same program (a 2-element list read at index 2, index derived at
runtime from `xs.len` so it cannot be folded):

| build | result |
|---|---|
| debug | `thread panic: index out of bounds: index 2, len 2` |
| `--release` | `read: 0` then `SURVIVED an out-of-range read` |

So the release build reads out of bounds, **invents a value**, and continues. That is
memory-unsafety and UNGIT "nothing fabricated" in one line, at the language level rather
than in a tool.

**A SECOND DOOR, AND IT IS THE EASIER ONE TO WALK THROUGH: a NEGATIVE index.** `.at(i)`
also inserts `@intCast(i)` to convert Zebra's `int` (i64) to `usize` -- 131 of them in one
469-line dogfood file. Measured the same way (`var i = xs.len - 3`, i.e. -1, computed at
runtime):

| build | result |
|---|---|
| debug | `thread panic: integer does not fit in destination type` |
| `--release` | `read: 0` then `SURVIVED a negative index` |

The negative value wraps to a huge `usize` and reads out of bounds. This door matters more
than the first because `xs.at(-1)` is a reflex for anyone arriving from Python, where it
means "the last element". Here it silently returns a fabricated value in shipped builds.
Any fix must close BOTH: a length check alone still lets a negative index through the cast.

**THE DOC IS NOT MERELY STALE — IT STEERS USERS TOWARD THE UNSAFE THING.** `.at()` is
recommended *over* alternatives on the strength of a guarantee it does not provide. A
second instance sits in BUGS_FIXED.md: "use `list.at(i)` (bounds-checked, emits
`.items[i]`)" — a sentence whose two halves contradict each other under ReleaseFast. The
mechanism was stated correctly and the guarantee inferred from it wrongly.

**HOW IT WAS FOUND, because the route is reusable.** Not by a sweep — no gate can see it,
since every gate builds Debug (the same blind spot BUG-228 lived in for four days). It came
out of dogfooding plus Hoare's criterion:

1. `construct_histogram` on real numeric code (`C:/Projects/tinylm`) showed `.at()` at 342
   uses in 1116 lines, and float+`.at()`+`while` together in 6 of 6 files vs **0 of 522**
   corpus files.
2. Asking Hoare's question — *what did the compiler DO to this code?* — showed `.at()`
   lowering to unchecked `items[...]`.
3. Testing both optimisation modes made it a finding rather than a suspicion.

**BLAST RADIUS.** Any program doing index arithmetic. Sean's neural-network code makes 342
`.at()` calls with hand-computed indices; an off-by-one there reads arbitrary memory in
release instead of trapping, and silently produces wrong numbers — which in a training loop
looks like a bad model, not a compiler bug.

**Fix options (needs a decision):**
1. **Emit an explicit check inside `.at()`**, independent of optimisation mode, so the
   documented guarantee holds in every build. Costs a compare-and-branch per index — real,
   but this is the accessor the docs call "preferred", and the alternative is a promise we
   do not keep. Pair it with an explicitly-unchecked accessor for hot loops, so the fast
   path is something a user CHOOSES rather than something they get by surprise.
2. Make `--release` use `-OReleaseSafe`. Cheapest change, keeps Zig's own checks, but
   silently reprices every program's performance and is a much broader decision than this
   bug.
3. Document the truth and keep the behaviour. **Rejected** unless paired with (1) or (2):
   the current text does not merely fail to warn, it actively recommends `.at()` on safety
   grounds.

Recommendation: (1), with the doc corrected either way and **not** waiting on the fix — a
wrong safety claim is worse than a missing one.

**Control when fixing:** the probe above must panic in BOTH modes, and a positive control
(an in-range read) must still work in both. `tools/release_mode_check.sh` is the only gate
that builds with `--release` and is the natural home for it.

**FIXED 2026-08-26, both compilers.** `.at(i)` and every sibling indexing path now lower
through two preamble helpers:

```zig
pub inline fn _zbr_at(xs: anytype, i: i64) std.meta.Elem(@TypeOf(xs))
pub inline fn _zbr_set(xs: anytype, i: i64, v: std.meta.Elem(@TypeOf(xs))) void
```

| build | `xs.at(2)` on a 2-element list | `xs.at(-1)` |
|---|---|---|
| debug | `index out of range: 2 (length 2)` | `index out of range: -1 (length 2)` |
| **`--release`** | **`index out of range: 2 (length 2)`** | **`index out of range: -1 (length 2)`** |

**FOUR EMITTERS PER COMPILER, not one.** Mapping by method name found two; the actual set
is `.at()` (two receiver branches in the selfhost), `.set()`, postfix `list[i]`, and string
indexing. The first fix converted one of them, rebuilt clean, and *looked* right -- the
panic message was still Zig's `index out of bounds`, not ours, which is the only reason it
was caught. **Enumerate by emit SHAPE, not by method name.**

Two design points worth keeping:

- **The container is a parameter, not re-emitted at the use site.** The obvious form
  `xs.items[chk(i, xs.items.len)]` evaluates the receiver TWICE, so `foo().at(i)` would call
  `foo()` twice. Verified single-evaluation with a side-effect counter before touching the
  compiler.
- **The sign test comes first, and the ordering is load-bearing.** `@intCast` of a negative
  i64 traps in debug and WRAPS in ReleaseFast -- that wrap is the second door. Zig's `or`
  short-circuits, so the cast is only reached once the sign is known good. A check written
  the other way closes one door and holds the other open.

Routing both branches of the bootstrap's postfix handler through one helper **collapsed 21
lines to 10**: the per-branch index casting disappeared because the helper's signature does
it. That shape -- two branches doing the same thing differently -- is where one gets fixed
and the other does not.

**VERIFICATION.** Positive fixture `test/bug313_checked_index_test.zbr` (`smoke_run`)
exercises all four emitters IN RANGE, including first and last element so an off-by-one in
the check itself shows up, and a nested `m.at(0).at(1)`. The refusal half cannot live in a
smoke fixture -- it panics, and only under `--release` -- so it is three legs in
`tools/release_mode_check.sh`, the only gate that passes the flag:

- index past the end must be refused
- negative index must be refused
- **CONTROL: in-range indexing must still work.** Without it a compiler that refused EVERY
  index passes both refusal probes; "it panics" and "it panics when it should" are
  different claims.

Falsified against the REAL attacker -- a compiler rebuilt with the check stripped out of
`_zbr_at` -- not a mutated test: both doors FAILED, the control PASSED, and all three went
green on restore.

**The compiler self-hosts through its own checked `.at()` calls**, which is a substantial
correctness signal on its own.

**STILL OPEN, deliberately, and NOT part of this fix:**
1. **Cost unmeasured.** Every index now pays a compare-and-branch. Knuth's "far more often
   than it currently is" is the default this implements; whether it is affordable is a
   separate, unasked question.
2. **No unchecked accessor.** Knuth's "but not everywhere" has no escape hatch yet. Whether
   it is urgent depends on (1).
3. **No elision.** `for i in 0..xs.len` emits the same checked call as a hand-managed index,
   though it is the one case where the bound is provable. That is the half that makes the
   safe form the FAST form (Wirth and Hoare via Knuth, p.271); until it lands the range-`for`
   is safer but not cheaper.

### BUG-310: `File.append` SILENTLY TRUNCATES the file when the read fails for any reason other than absence — CLOSED 2026-08-26

**A transient read error destroys the file's existing contents.**

```zig
pub fn _file_append(path: []const u8, content: []const u8) void {
    const existing: []const u8 = ...readFileAlloc(_io, p, ...) catch "";   // <-- any error
    const combined = _str_concat(existing, content, _allocator);
    const wf = ...createFile(_io, p, .{}) catch @panic("File.append error"); // <-- TRUNCATES
    wf.writeStreamingAll(_io, combined) catch @panic("File.append write error");
}
```

Zig 0.16 removed `File.seekFromEnd`, so append is read + concat + rewrite. The `catch ""`
is deliberate for the "file does not exist yet" case, and the comment says so — but
`readFileAlloc` also returns `AccessDenied`, `SharingViolation` and transient I/O errors,
and the catch does not discriminate. On any of those, `existing` becomes empty, `createFile`
truncates, and the file is left holding **only the appended fragment**.

Same shape as BUG-302 and BUG-307: one signal standing for two causes, and the code assumes
the benign one. Here the cost is data loss rather than a misleading label.

**GAP, NOT WOUND.** No incident is known; this was found by reading, not by a failure. It is
recorded as an unstruck gap per the armor-at-the-seams distinction — cheap to armor, and
the blast radius is a user's data.

**Fix:** discriminate, exactly as BUG-307 did for delete —
`catch |e| if (e == error.FileNotFound) "" else @panic(...)`. Lines 823 and 825 already
panic on failure, so refusing an unexpected READ error is consistent with the function's
own existing contract rather than a new policy.

**Verified 2026-08-26.** Fix confirmed present in the EMITTED runtime, not just in the source: `zebra_rt.zig` from a fresh emit carries the new form and **zero** occurrences of the old one (a preamble edit is invisible until regen, and the build order matters -- see CLAUDE.md). Quick tier 25/25, smoke 383/383, round-trip byte-identical.

### BUG-309: a regex OOM is reported as "NO MATCH", so a failed check reads as a passed one — CLOSED 2026-08-26

**The three core regex entry points turn an allocation failure into a negative verdict.**

`matchAt` is typed `error{OutOfMemory}!?usize` — OOM is its *only* failure. All three
callers discard it into `null`:

| line | function | on OOM |
|---|---|---|
| 2580 | `_regex_find` | reports **no match** |
| 2589 | `_regex_findAll` | silently returns **fewer** matches |
| 2600 | `_regex_replace` | silently leaves the text **unreplaced** |

```zig
if (re.matchAt(input, i, re.flags.lazy_match) catch null) |e| return input[i..e];
```

**The inconsistency is two lines away in the same functions.** `out.append(...) catch
@panic("OOM")` — so the file's own convention is already to panic on OOM for the *output
buffer*, and only the *match itself* fails quiet. A detector that cannot see reporting no
findings is this repository's signature failure mode; here it is in the shipped runtime,
and if Zebra's regex is ever used to validate or sanitise input, an OOM means the check
**passes**.

**Found by measurement, not by eye.** Of 34 `FABRICATE`-class catch sites in the preamble
(a failure yielding a value indistinguishable from a real one), exactly **3** sit inside an
`if`/`while` CONDITION — these three. The other 31 are in statement position where the
fabricated value is cosmetic. Tooling: `C:/Projects/hearsay/tools/survey_zig.py` and
`flows_probe.py`.

**Fix:** `catch @panic("OOM")`, matching the adjacent line. This aligns with existing local
policy rather than setting new policy; propagating instead would change the user-visible
signatures of `find`/`findAll`/`replace`, which return plain values today.

**Verified 2026-08-26.** Fix confirmed present in the EMITTED runtime, not just in the source: `zebra_rt.zig` from a fresh emit carries the new form and **zero** occurrences of the old one (a preamble edit is invisible until regen, and the build order matters -- see CLAUDE.md). Quick tier 25/25, smoke 383/383, round-trip byte-identical.

### BUG-307: selfhost-compiled `File.delete` PANICS on a file that is already gone — CLOSED 2026-08-26

**The shipping compiler crashed where the reference compiler carried on.**

| compiler | emitted for `File.delete(p)` | `File.delete("not_there.txt")` |
|---|---|---|
| `src/CodeGen.zig:7857` (bootstrap) | `catch \|_fd_err\| { if (_fd_err != error.FileNotFound) @panic(…) }` | prints `survived` |
| `selfhost/CodeGen.zbr` (**shipped**) | `catch @panic("File.delete error")` | `thread N panic: File.delete error` |

`src/` gained the tolerance in `2e74c67`; this side never did — `git log -S'_fd_err' --
selfhost/CodeGen.zbr` returns **nothing at all**. A plain selfhost-parity gap of exactly
the kind the equivalence rule in CLAUDE.md exists to prevent.

**INVISIBLE TO EVERY COMPILE-ONLY GATE BY CONSTRUCTION.** Both forms are valid Zig, so
`divergence --gate` reported **0 selfhost gaps** with the defect live, and `full_sweep` /
`compile_check` were equally blind. This is the BUG-226 class — correct-compiling code that
behaves wrongly — and only a gate that RUNS things can see it. `output_sweep` did, during
the 2026-08-26 `--daily`, as an unexplained `File.delete error` panic appended to
`try_outer_vars`.

**How it was found is worth keeping, because the first two readings were both wrong.** The
daily's pipeline exit code was `tail`'s, not `gates.sh`'s, so a FAILED daily reported
success — the two-terminal-lines hazard this file already documents, striking anyway. Then
`gates.sh:175` (`out="$(cat "$log")"; rm -f "$log"`) was read as having destroyed the
evidence; it had not — lines 233-234 print the failing lines and a tail, and the diff was
in the log the whole time.

**Fixture: `test/bug307_delete_missing_test.zbr`** (`smoke_run`, marker `bug307: OK`).
Watched RED against the pre-fix compiler with the real attacker — the emitted binary
panicking — not a mutation. **Leg 2 is a control**: tolerating a missing file is trivially
satisfiable by making delete do nothing, and leg 1 cannot tell the difference, so the
fixture also proves a delete still deletes.

**Left open as BUG-308:** the tolerance is *only* for `FileNotFound`. Every other
failure — a Windows lock included — still panics, which makes any retry loop around
`File.delete` unreachable code.

### BUG-103: TC `extractFromDecls`/`extractFromMembers` silently skip unknown declaration variants — CLOSED 2026-08-26

> **CLOSED 2026-08-26 — the FIX landed 2026-05-06; what was missing was something that
> could FAIL.** This entry's own triage said so: *"KEPT OPEN pending a pin, not because it
> is believed broken … the natural pin is a check that every `Ast.Decl` variant is handled,
> in the shape of `lint_expr_walkers`."* That is now `tools/lint_decl_exhaustive.py`,
> registered as the STATIC gate `decl-exhaustive`.
>
> **It guards the PROPERTY, not the fix.** The compile-error guarantee holds only while the
> switches stay exhaustive; a single `else => {}` restores the original silent-skip AND
> stops Zig complaining. That reintroduction is invisible to every other gate — the code
> compiles, every test passes, and a future `Ast.Decl` variant is quietly dropped, which is
> the exact defect this ticket describes.
>
> Oracle is `src/Ast.zig`'s own `Decl` union (14 variants), never a hand-written list — a
> second copy being the very thing the bug is about.
>
> **NESTED SWITCHES ARE NOT THE SUBJECT, and checking that mattered:** `extractFromDecls`
> legitimately contains two `else =>` arms on inner `TypeRef` switches. A proximity-based
> check would have called the fix regressed on sight. Arms are matched at the `Decl`
> switch's own brace depth.
>
> **Verified RED both ways** before being trusted: reintroducing a catch-all reports
> *"BUG-103 regressed"*, and deleting one variant's arm reports *"missing Decl variant(s):
> enum_"*. Clean on restore.
> **Triaged 2026-08-17 — KEPT OPEN pending a pin, not because it is believed broken.**
> The body below says *Closed — fixed 2026-05-06*, and `lint_stale_bugs` flagged it. The
> defect only triggers on adding a NEW `Ast.Decl` variant, so it cannot be expressed as a
> Zebra program at all — no fixture can exist in the current harness, and the evidence is
> the annotation plus the source, never a run. **Close it only alongside something that
> can fail**: the natural pin is a check that every `Ast.Decl` variant is handled, in the
> shape of `lint_expr_walkers` (whose oracle is `Ast.zbr` itself).
- **Severity:** Low (only triggers on adding a new `Ast.Decl` variant; latent reliability hazard)
- **Status:** Closed — fixed 2026-05-06
- **Resolution:** All 4 `else => {}` catch-alls in the metadata-collection passes replaced with fully exhaustive arms listing every `Ast.Decl` variant explicitly. Adding a new `Ast.Decl` variant now causes a Zig compile error at all 4 sites (same guarantee `checkTopDecl` already had). Behavioral change: none — all new arms are `{}`. Bootstrap 5/5, smoke 44/44, full test suite.
  - `extractFromDecls` (4 new arms: `.use`, `.interface`, `.mixin`, `.extend`, `.sig_`, `.var_`, `.init`)
  - `extractFromMembers` (10 new arms: everything except `.method`, `.var_`, `.init`)
  - `collectExtMethodsInDecls` inner switch (extend members: 12 new arms)
  - `collectExtMethodsInDecls` outer switch (top-level decls: 11 new arms)
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-1]).

---

### BUG-212: selfhost emits `var` (not `const`) for a builtin-pointer local used only as a method receiver — CLOSED 2026-08-26

> **CLOSED 2026-08-26 — it was TWO defects, and the second was unreachable until the
> first was fixed.**
>
> **Half 1, the reported one.** `code_editor` is now classified by `isByValueHandleType`,
> alongside the build handles whose comment already states the rule: an opaque handle whose
> methods emit `_code_editor_*(e, ...)` passes the POINTER by value, so the local is never
> reassigned and must be `const`. This ticket's diagnosis was correct.
>
> Safe in the by-value tier rather than needing a never-var one, and CHECKED rather than
> assumed: that tier still returns `var` for an explicit in-place mutator, and CodeEditor's
> entire surface (`get_text`, `set_text`, `set_readonly`, `set_cursor_position`,
> `set_error_markers`, `get_cursor_line`, `get_cursor_col`, `render`) collides with NONE of
> the names `isMutatingMethod` recognises. A type here with a `set` or `add` would land in
> the wrong answer.
>
> **Half 2, found by fixing half 1.** The program then compiled and printed `{ 104, 105 }`
> — the BYTES of "hi". `_code_editor_get_text` returns `[]const u8`, but the TypeChecker had
> no return type for the call, so the interpolator chose `{any}`. Valid Zig, wrong output:
> the BUG-226 class, invisible to every compile-only gate. It could not have been seen
> before, because the program did not compile at all.
>
> **This ticket is only fixed when its OWN EXAMPLE WORKS**, not when it stops erroring —
> the example is `var e = CodeEditor()` with `setText`/`getText`. Closing on "compiles now"
> would have shipped a ticket whose repro prints garbage.
>
> **THE FIRST FIXTURE WAS HALF-FAKE and the falsification caught it.** Its half-2 leg read
> `e.getText() <> "hi"` — a string COMPARISON, which passes against the broken compiler
> because the defect is in the FORMATTER. With the TypeChecker fix reverted it still
> reported OK. Rewritten as `"${e.getText()}" <> "hi"`, it reddens with
> *FAIL getText renders as bytes, not a str*. The fixture was corrected BEFORE the compiler
> fix was restored, so it was watched failing.
>
> Third instance of that shape in these sessions, after BUG-304's shift amounts and
> BUG-301's `:c` — each time the obvious way to write the test bypasses the exact machinery
> that was broken.
>
> **NOTED, NOT FILED: the CodeEditor CURSOR API IS A STUB.**
> `_code_editor_set_cursor_position` discards all three arguments and both getters
> `return 1` unconditionally. The fixture therefore asserts the cursor accessors are INTS
> and deliberately does NOT assert their values — pinning `1` would pin the stub, and a
> fixture named for BUG-212 would then fail the day somebody implements cursors. A stub
> returning a plausible number rather than refusing is arguably its own UNGIT
> "nothing fabricated" defect; raised for Sean rather than filed unilaterally.
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

---

### BUG-246: an UNANNOTATED `Atomic(T)(v)` local mis-resolves `.add()` to `.append()` — CLOSED 2026-08-26

> **CLOSED 2026-08-26 — generic stdlib constructors are now tracked from the INIT
> EXPRESSION, not only from a type annotation.**
>
> The local-tracking block in `CodeGen.zbr` is gated on `if n.type_ != nil`, so
> `var t = Atomic(int)(0)` was never registered in `atomic_locals` and `.add` fell through
> to the List rewrite. The re-diagnosis in this entry was right: the capture block is a red
> herring, and the real discriminator is the ANNOTATION.
>
> **Why the existing `isStrSetCtor` did not already cover it.** That helper is a
> single-level check for a zero-arg `StrSet()`. `Atomic(int)(0)` parses as a call whose
> CALLEE IS ITSELF A CALL — the inner `Atomic(int)` names the type, the outer `(0)`
> constructs. The new `genericStdlibCtorName` reads that second level and answers for any
> generic stdlib ctor.
>
> **SCOPE MEASURED, NOT ASSUMED — and my first claim was WRONG.** I described this as one
> fix closing the gap for `Atomic`, `Chan` and `ThreadPool` alike, since all three are
> registered by the same annotation-gated block. Tested against the UNFIXED compiler:
>
> | type | without the fix |
> |---|---|
> | `Atomic` | **breaks** — `no field or member function named 'append'` |
> | `Chan` | works (prints 7) |
> | `ThreadPool` | works |
>
> Only `Atomic` manifests, because the hazard is the `.add` -> `.append` rewrite and only
> `Atomic` has an `.add`. The other two share the registration gap and cannot express it.
> They are registered anyway — defensive, and covered in the fixture as REGRESSION
> coverage — but this fix is demonstrated for one type, not three.
>
> **BUG-306 STAYS OPEN.** That ticket asks for `inferExpr` to see module-scope
> declarations, which would let the bespoke `isModuleGlobalAtomic` / `isModuleGlobalStrSet`
> oracles be deleted. This change did something narrower: it fixed the LOCAL tracking path.
> Closing 306 on it would be exactly the overclaim corrected two paragraphs up.
>
> Pinned by `test/bug246_unannotated_generic_ctor_test.zbr` (`smoke_run`), which tests BOTH
> declaration forms — the annotated one always worked, so a fixture using only that shape
> passes against the broken compiler.
> **RE-DIAGNOSED 2026-08-20. The heading changed because the original one names the wrong
> cause, and following it costs the next person the same hour it cost me.**
>
> **The capture block has nothing to do with it.** Measured, three shapes:
>
> | shape | result |
> |---|---|
> | `var t = Atomic(int)(0)` then `t.add(5)` — no lambda at all | **FAILS**, `no field or member function named 'append'` |
> | `var t: Atomic(int) = Atomic(int)(0)` then `t.add(5)` | passes |
> | the ticket's capture block, with the OUTER declaration annotated | passes |
>
> So the defect is that an **unannotated generic stdlib constructor is not typed**: with no
> type for `t`, the member call falls through to the stdlib heuristics and `.add` matches
> List's `.append`. The original repro simply had an unannotated outer `var`.
>
> **Same class as BUG-250** (a builtin constructor call the TypeChecker does not type),
> which is worth knowing because that one was fixed by typing the call.
>
> **THE CLASS WAS SWEPT 2026-08-20 AND IT IS BOUNDED — three untyped, one reachable.**
> Codegen emits bare constructors for seven generic stdlib types; the TypeChecker types
> four. The gap is `Atomic`, `ThreadPool`, `ObjectPool` — and only `Atomic` actually
> breaks:
>
> | untyped constructor | reachable defect? |
> |---|---|
> | `Atomic(int)(0)` | **YES** — `.add` falls through to List's heuristic and emits `.append` |
> | `ThreadPool(2)` | no — `submit`/`wait` collide with nothing (probed: runs) |
> | `ObjectPool(T)(n)` | no — `take`/`give`/`inUse` collide with nothing (probed: runs) |
>
> **So the trigger is not "untyped" alone — it is untyped AND a method name that COLLIDES
> with a stdlib heuristic.** `.add` is the collider because List has one. That predicts the
> next occurrence: any new stdlib type with an `add`-shaped method inherits this the day it
> is added, whether or not anyone touches Atomic. Typing the three constructors removes the
> class rather than the instance.
>
> **WHERE THE NEXT ATTEMPT SHOULD NOT START.** `TypeChecker.zbr`'s
> `typeFromExpr`/`typeFromRef` arms handle `List`, `HashMap`, `Chan` and `Set` and return
> `Type_.unknown_` for `Atomic` — in BOTH arms. Adding an `Atomic` case there looks like
> the fix and is not sufficient on its own: the ANNOTATED form already works while its
> `typeFromRef` arm also returns `unknown_`, so the annotated path is getting its dispatch
> from somewhere else. Find that mechanism first; the fix is to make the unannotated path
> reach the same place.
>
> A capture-binding change (binding a capture's declared type into the lambda's
> InferCtx, which `genLambdaEx` does for params and not for captures) was written, built
> and then REVERTED: it is defensible on its own terms but it did not fix this ticket, and
> shipping an inference change with no case that proves it load-bearing is how a
> regression arrives with nothing to blame. Recorded here as a real gap someone may still
> want to close, with a fixture, deliberately.


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

### BUG-297: `--target node-addon` emits an undeclared reference to the owning class for a STATIC-block export — CLOSED 2026-08-25

> **CLOSED 2026-08-25 — one line, and it is the BUG-281 family's EIGHTH site.**
>
> The N-API wrapper emitted the owning class by its BARE Zebra name:
>
> ```zig
> const _ret = Calc.square(_a0);        // ...against a decl named _zbr_ty_Calc
> ```
>
> A user type emits as `_zbr_ty_<name>` (BUG-281 B). `napiWrapperStr` appended `owner`
> unchanged, so the call referenced a symbol that is never declared — and because the zig
> error is remapped to `.zbr` coordinates, it read like a front-end complaint about the
> user's own source. Now `zbrTypeSymbol(owner)`; emit is `_zbr_ty_Calc.square(_a0)` and no
> bare class reference survives anywhere in the output.
>
> **`zbrTypeSymbol`, NOT the fuller `typeZigName`**, and the reason is worth recording:
> `typeZigName` is a CLASS METHOD while `napiWrapperStr` is a TOP-LEVEL def, so a
> contextual-self call there is `'this' used outside a class/struct method` — the same
> blocker that stopped BUG-253. It is not a blocker here because an owner in this position
> is always a user class, which is exactly what the plain symbol builder covers. **If a
> node-addon export ever needs a NAMESPACE-qualified owner, that is where it will bite.**
>
> **WHY IT NEEDED TWO CONDITIONS TO HIDE.** The node-addon target was in NO tier until it
> was wired on 2026-08-19, AND the defect is class-specific — the sibling fixture
> `strings.zbr`, which has no class, passed throughout. Either condition alone surfaces it.
> Same two-lock shape as `examples/widget_smoke.zbr` shipping broken: no gate swept
> `examples/`, and `zebra -c` exits 0 on it because check mode is front-end only.
>
> **RETIRING THE PIN EXPOSED A SECOND, HIDDEN DEFECT.** The registration read
> `pin_daily "node-addon" "BUG-297" "node-addon tests: ok"` — and the gate has never
> printed that string; it prints `node-addon tests: PASS`. The XFAIL was masking a stale
> match expectation, so a naive `pin_daily` -> `run_daily` swap would have turned the gate
> red on the EXPECTATION rather than on the code. Both fixed together. That is the pin
> mechanism earning its keep twice: it kept the bug visible, and retiring it surfaced
> something nobody had looked at.
>
> Falsified: reverting the single call reproduces this entry's error verbatim —
> `test/node_addon/math.zbr:31: error: use of undeclared identifier 'Calc'`. Gate green
> with all three legs, including the negative fixture that must still be rejected.
`zebra --target node-addon` on a `@node_export` inside a class `static` block emits a
reference to the class that is never declared, and the build fails on the compiler's own
diagnostic:

```
test/node_addon/math.zbr:31: error: use of undeclared identifier 'Calc'
```

**Isolated to the node-addon target, and to the class path specifically.** Three probes:

| probe | result |
|---|---|
| `zebra -c test/node_addon/math.zbr` | clean — the front end is fine |
| `zebra --target node-addon test/node_addon/math.zbr` | **fails as above** |
| the sibling fixture `strings.zbr` (no class) | passes |

The failing shape is the last block of `test/node_addon/math.zbr`, which exists to
exercise the `Owner.method` call path:

```zebra
class Calc
    static
        @node_export
        def square(n: int): int
            return n * n
```

**HOW IT WAS FOUND, which is the part worth keeping.** It was not found by a gate — it was
found by *wiring a gate*. `tools/node_addon_test.sh` was in NO tier: it sat under
CLAUDE.md's "run these deliberately" list, where its last recorded sweep is **2026-08-04,
PASS**. Nothing has run it since, so the regression's window is those two weeks and
nothing narrows it further. This is the same shape as BUG-279 (`zig build test` red, in
neither a tier nor the uncovered table) two days earlier, and the second instance is what
motivated the `--daily` tier rather than another reminder.

**It is PINNED, not excluded.** `gates.sh` registers it as
`pin_daily "node-addon" "BUG-297"`: it RUNS on every `--daily`, prints `XFAIL` with this
ticket, and does not fail the tier — but it **fails the tier the day it starts passing**,
so the pin cannot outlive the bug. Excluding it is what let it rot in the first place.

**Control when fixing.** `bash tools/node_addon_test.sh` must report every fixture ok
(`math` is the one to watch; `strings` and the negative `bad` already pass), and the
`pin_daily` registration must then become `run_daily` — the tier will say so loudly if it
is forgotten. Worth adding a class-static fixture to the node-addon set at the same time:
`math.zbr` is currently the only file covering that path, which is why one regression took
the whole gate red.

---

### BUG-264: the selfhost lowers a module-scope `StrSet.add` as `List.append`, so it cannot re-emit its own source — CLOSED 2026-08-23

> **CLOSED 2026-08-23 — and the workaround it forced is GONE, which is how it was
> verified.**
>
> **Root cause was not new: it is BUG-153's gap, ten lines above the fix.** `inferExpr`
> sees only locals and params, so a module-scope var is invisible to the `Type_.named` test
> that would otherwise stop `.add` being rewritten as a `List` append. BUG-153 patched that
> for `Atomic`; `StrSet` is the identical case. Filed as **BUG-306** so the third type does
> not get a third one-off oracle.
>
> `isModuleGlobalStrSet` covers **both declaration forms** — annotated
> (`var s: StrSet = StrSet()`) and bare (`var s = StrSet()`, which carries no annotation at
> all). The `Atomic` twin handles only the annotated form, so a bare ctor would have
> slipped straight through.
>
> **VERIFIED BY DELETING THE WORKAROUND.** This ticket recorded `List(str)` in
> `selfhost/CodeGen.zbr` as *forced rather than chosen*, with `_hasNativeUse` doing a
> linear scan in place of set membership. Both collections are `StrSet` again and
> `_hasNativeUse` is replaced by `.contains_`, so the compiler's own source now carries the
> exact construct that used to break it. The proof and the cleanup are the same act.
>
> Emit is now `pub var _zbr_mv__c_no_header_uses: *StrSet` — matching what this ticket
> records the BOOTSTRAP as producing — and the round-trip is byte-identical.
>
> **Falsified against the documented error, not merely against a red gate.** Removing the
> guard while leaving the `StrSet` declarations in place reproduces this entry's message
> verbatim:
>
> ```
> error: no field or member function named 'append' in 'CgHelpers._zbr_ty_StrSet'
>     _zbr_mv__c_with_header_uses.append(_zbr_rt._allocator, path) catch @panic("OOM");
> note: method invocation only supports up to one level of implicit pointer dereferencing
> ```
>
> **NO `test/*.zbr` FIXTURE IS POSSIBLE**, and that is worth stating: `StrSet` is not a
> user-facing type — a bare `StrSet()` in user code is `undefined name: 'StrSet'`. It
> reaches the compiler through `CgHelpers`, so the compiler's own source IS the fixture and
> the round-trip is the only gate that can see this. Exactly as this ticket predicted:
> `zig build` passes (it builds from the bootstrap's correct emit), the compiler runs, and
> every smoke fixture is green.
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

---

### BUG-301: `${expr:c}` works for a literal and fails for a RUNTIME int — no way to build a byte from a computed value — CLOSED 2026-08-23

> **SEMANTICS CONFIRMED BY SEAN, 2026-08-25:** truncate. The ticket left the call to him;
> this is that call, so `${n:c}` wrapping rather than trapping is settled, not provisional.
>
> **CLOSED 2026-08-23 — `_zbr_byte` in the preamble, wired in BOTH compilers.**
>
> **Semantics: TRUNCATING, per this ticket's own recommendation — flagged for Sean, since
> the entry left the call to him.** `@intCast` is undefined behaviour in ReleaseFast, which
> is what `zebra --release` ships, and keeping UB out of the shipping configuration is what
> `tools/lint_oom_unreachable.py` exists for. Truncation is always defined and matches Go's
> `byte(n)` and Rust's `as u8`: `462` renders as `0xCE`, and `-50` as `206`. The front-end
> refusal for a statically-known out-of-range literal is NOT implemented — a follow-up, not
> a blocker, since the runtime dead end is what made the capability unreachable.
>
> **THREE ZIG CONSTRAINTS DECIDED THE LOWERING, and none of them was guessable:**
>
> | attempt | zig says |
> |---|---|
> | `@truncate(x)` on an i64 | *expected unsigned integer type, found 'i64'* |
> | `@bitCast` i64 -> u8 | refuses a WIDTH change |
> | `@bitCast` on a literal | *cannot @bitCast from 'comptime_int'* |
>
> So the lowering is bitcast-to-same-width-unsigned, then truncate — and it lives in a
> HELPER rather than inline because of the third row. **The first fix emitted the cast
> inline and broke the LITERAL case that already worked**, which the fixture caught
> immediately because it tests both paths. `@as(i64, x)` inside the helper coerces a
> literal and passes a runtime `i64` through unchanged, so both shapes share one form.
>
> **THE FIXTURE IS A REAL PERCENT-DECODER**, building `θ` from `%CE%B8` with the hex digits
> parsed at RUNTIME — the control this ticket asked for. Every byte comes from arithmetic
> on purpose: **a fixture written with `${206:c}` PASSES AGAINST THE BROKEN COMPILER**,
> because a literal coerces at comptime. That is precisely why this went unnoticed, and it
> is the same cooperative-attacker shape as BUG-304's shift amounts.
>
> Falsified: removing the `c` case reproduces this ticket's error verbatim —
> `expected type 'u8', found 'i64'`, pointing into `std/Io/Writer.zig` at
> `printAsciiChar`, in Zig's vocabulary about code the user never wrote.
>
> **BOTH COMPILERS.** The bootstrap had the identical defect and matters here: `--gui-backend`
> and `--target node-addon` both route through it. Its emit now compiles AND RUNS. One note
> from wiring it — the emit must dispatch on the SPEC, not on the cast type string:
> `castTypeForBitSpec` also answers `"u8"` for `:x` on an `int8`, so a type-string test
> would have quietly routed a hex argument through the byte helper. Same value, wrong
> reason.
```zebra
var b = "${206:c}"              # fine -- emits one byte, 0xCE
var n = hi * 16 + lo
var c = "${n:c}"                # error: expected type 'u8', found 'i64'
```

The `:c` spec on an `int` emits Zig's `{c}` (`printAsciiChar`, which takes a **u8**), and
codegen passes the Zebra `int` (`i64`) through unnarrowed. A literal coerces at comptime;
a runtime value does not, and the user sees a raw Zig type error against generated code.

**WHY IT MATTERS BEYOND THE ERROR MESSAGE.** `${n:c}` is the ONLY way to put an arbitrary
byte into a string, and byte assembly is what UTF-8-correct decoding needs — `%CE%B8` is
two bytes that together form one codepoint, so a percent-decoder must build bytes, not
codepoints. With this broken, a decoder can only handle values it can name as literals: in
practice a table over printable ASCII, leaving every `%XX` ≥ 128 undecodable. That is
exactly where the Graze decoder stopped (correspondence Entry 24), and it is why that
entry reads as "no int→char in reach" — the capability is there and unreachable from a
computed value.

**Where:** `bitCastType` (`selfhost/CodeGen.zbr`, and the bootstrap's twin) narrows the
argument for `x`/`X`/`o`/`b` and has no case for `c`. The existing cast emits
`@as(T, @bitCast(x))`, which is **invalid** i64→u8 — Zig requires equal bit widths — so
this needs a different cast kind, not just another entry in that table.

**AND THAT CARRIES A SEMANTIC DECISION, which is why this is filed rather than fixed:**
what should a runtime value outside 0..255 do?

| option | behaviour | precedent |
|---|---|---|
| `@truncate` | always defined, silently wraps | Go `byte(n)`, Rust `as u8` |
| `@intCast` | panics in Debug/ReleaseSafe — **UB in ReleaseFast**, which is what `zebra --release` ships | — |
| front-end refusal | rejects a statically-known bad literal; still needs one of the above at runtime | Python `bytes([n])` raises |

`@intCast` alone is the one to avoid: it puts undefined behaviour in the shipping
configuration, which is the hazard `tools/lint_oom_unreachable.py` exists to keep out.
Recommendation is `@truncate` plus a front-end refusal for a known-out-of-range literal —
but the semantics are Sean's call.

**Control when fixing:** a decoder that builds `θ` from `%CE%B8` with hex digits parsed at
runtime must round-trip, and `${300:c}` must do whatever the decision says rather than
whatever Zig happens to do. Note `:c` on a `char` value is a DIFFERENT path (it emits
Zig's `{u}`, the codepoint form) and must keep working — see QUICKSTART's note.

---

### BUG-298: `gui_scaffold_check` reports "startup path clean" when the scaffold build produced NO app — leg 2 skips instead of failing — CLOSED 2026-08-23

> **CLOSED 2026-08-23 — the root defect was not the skip, it was that `build_rc` was
> captured and NEVER USED AS A GATE CONDITION.**
>
> `build_rc=$?` sat one line under the build and was read only inside a message. So a dead
> build reached a green summary in three steps: leg 1 reads the scaffolded `main.zig`, and
> a PREVIOUS run leaves one on disk; leg 2 skips for want of an `app.exe`; the summary
> prints "startup path clean". Every step is individually reasonable and the composition
> is a lie.
>
> **Two fixes.** A failed build is now fatal, checked BEFORE anything reads an artifact —
> the entire failure mode is a stale artifact making a dead run look alive, so the order
> matters. And a skipped runtime leg no longer prints "clean"; it prints
> `leg 1 clean; RUNTIME leg did NOT run`. Half a GUI gate reporting as a whole one takes
> the repo's only automated GUI coverage back to zero without anyone noticing, which is
> precisely what happened on 2026-08-19.
>
> **THE FIRST VERSION OF THIS FIX WAS WRONG, AND ONLY THE NEGATIVE CONTROL CAUGHT IT.**
> `if [ "$build_rc" -ne 0 ]; then fail` looks obviously right and turns the gate
> PERMANENTLY RED: `--gui-backend=tui` scaffolds, builds **and runs** the app, and the
> documented healthy outcome is the app refusing a non-tty console with rc=3, which
> `zig build run` reports as its own exit 1. So `build_rc` is non-zero on the HEALTHY
> path.
>
> That is the same error class as the bug being fixed — one signal, two causes — and the
> ATTACKER PASSED CLEANLY against it. A broken build failed exactly as intended; only
> running the healthy example exposed that everything else failed too. **An attacker alone
> cannot show that a guard is too broad.**
>
> The real discriminator is whether the app RAN, in the build tool's own vocabulary:
> `process exited with error code` is present on the healthy run and absent on a genuine
> compile failure. Verified against both captured logs (1 vs 0) before being relied on,
> rather than assumed.
>
> **Both directions now hold**: healthy example -> `exit 0, startup path clean`; an example
> that cannot compile -> `exit 1, build failed`, with the build log attached.
Leg 2 of `tools/gui_scaffold_check.sh` runs the built app and classifies the startup
fault. When it cannot find an `app.exe` it prints

```
  --    leg 2: skipped (no built app.exe — leg 1 still gates the regression)
```

and the gate still exits 0 with `gui scaffold check: startup path clean`. **But "no
app.exe" has two very different causes and the gate cannot tell them apart:** the harness
genuinely not building one, and the build having FAILED. In the second case the gate
reports clean about a scaffold that does not exist.

**Observed, not hypothesised.** On 2026-08-19 the check reported `startup path clean`
while `zebra --gui-backend=tui examples/counter.zbr` was exiting 1 on

```
error: unable to read results of configure phase from
'…\Temp\counter_gui_tui\.zig-cache\tmp\16ce6e37c914cf04': FileNotFound
```

— a corrupted scratch cache in the temp scaffold root. Moving that directory aside made
the build work and produce `app.exe`, after which the app ran and refused a non-tty
console (rc=3), which is the documented healthy outcome. So the underlying tui path was
fine; what was broken was the gate's ability to say that it had not checked it.

**Leg 1 kept working throughout, and that is what made it look green** — it reads the
scaffolded `main.zig`, which a previous run had left on disk. A gate asserting against a
stale artifact from an earlier date is the shape this repo keeps re-finding.

**Why this matters more than one skipped leg.** `gui_scaffold_check` is the ONLY automated
GUI coverage in the repo — four GUI crashes have sat under fully green gates and all four
were at startup. Half of it silently not running returns that number to "no gate touches a
GUI".

**Suggested fix.** Distinguish the two causes: if the build exited non-zero for a reason
OTHER than the app's own non-tty refusal, that is a FAILURE, not a skip. The refusal is
already identified by leg 2's own classifier, so the information exists — it is just
consulted after the point where the skip has already been taken. A gate that cannot run
its runtime leg should say `INCONCLUSIVE` and exit non-zero, not `clean`.

**Control when fixing.** Corrupt or remove the scaffold's `.zig-cache` and confirm the
gate goes RED rather than printing `startup path clean`; then restore and confirm it goes
green with leg 2 actually running (rc=3, non-tty refusal). It is registered in the
`--daily` tier, so both states are observable there.

---

### BUG-300: BUG-244 HAS REGRESSED — every `zebra <file>.zbr` run leaks a ~20 MB executable into TMPDIR again — CLOSED 2026-08-23

> **POLICY CONFIRMED BY SEAN, 2026-08-25:** keep the emitted `.zig` (it helps with
> diagnostics), do not keep the binaries. The change of decision recorded below stands;
> recorded here so it is not re-litigated from the old comment.
>
> **CLOSED 2026-08-23 — it was FOUR leaks, and the one this ticket is named after was the
> smallest.** Measured on a clean `%TEMP%`, before and after, using a full smoke run
> (377/377) as the load:
>
> | leak | before | cause |
> |---|---|---|
> | `.pdb` sibling | **435 files / 1.4 GB** | **no delete call ever existed** |
> | binary kept on a FAILING run | 20 MB x every failure | deliberate policy (see below) |
> | binary orphaned at the COMPILE-FAILURE exit | 20 MB x every compile error | that exit cleaned up **nothing** |
> | `.exe` transient under load | ~2 per smoke, 9 per `--daily` | the filed bug |
>
> **After: 0 executables, 0 `.pdb`, from a full smoke run.** Including the transients.
>
> **THE TICKET'S OWN LEAD WAS RIGHT AND IS NOW CONFIRMED.** It said this and BUG-302 were
> "plausibly one phenomenon: file operations against `%TEMP%` failing at a low rate under
> sustained load". BUG-302 was closed the day before as exactly that — zig failing to read
> its own stdlib with `Unexpected`, an unmapped Windows OS error, under concurrent builds.
> Same class, different syscall. The fix here is the same shape too: the flat 12 x 25 ms
> retry became exponential (5-10-20-...-640, ~1.3 s over ten tries), which absorbed the
> residual 2-per-smoke that 300 ms did not. It still costs NOTHING on the common path —
> the first delete works and the loop exits before it ever sleeps.
>
> **THE `.pdb` HALF WAS NEVER A RACE.** 435 files at a 100% rate, because `deleteScratch`
> was wired for `fast_exe`, `zig_path` and `llvm_exe` and never for the debug-info sibling
> the LLVM path emits beside every executable. Bigger than the leak the ticket is named
> after, and nobody had measured it.
>
> **THE COMPILE-FAILURE EXIT is the one a user meets most.** `if r2.exit_code != 0 ->
> sys.exit(1)` had no cleanup at all, so the most ordinary failure there is — a plain
> compile error — orphaned a full 20 MB binary.
>
> **A DELIBERATE DECISION WAS CHANGED, and it is flagged rather than buried.** The old
> comment read *"the emitted .zig and the binary ARE the debugging evidence"* and kept
> both. The policy is now: **the `.zig` survives a failure; executables and `.pdb` never
> do.** Reasons: `zig build-exe <the .zig>` reproduces the binary in one command, so
> keeping it buys a rebuild and costs 20 MB every time; and the old policy became
> incoherent once the `.pdb` was removed, since a binary without debug info is poor
> evidence anyway. **Sean's call to reverse if he wants post-mortem binaries.**
>
> **THE GATE ONLY EVER EXERCISED SUCCESS**, which is why three of the four survived it.
> `runtime_module_check` now covers the compile-failure and runtime-failure shapes, and
> each leg asserts BOTH halves — no binary AND the `.zig` still present — so a fix that
> simply deleted everything would fail the evidence half rather than pass the leak half.
>
> Falsified independently: reverting the compile-failure cleanup reddens only the compile
> leg; reverting the failure policy reddens only the runtime leg.
`tools/runtime_module_check.sh` is RED on the committed tree:

```
FAIL  a successful run left 1 scratch file(s) in C:\Users\Sean\AppData\Local\Temp
```

**This is the exact bug `60fa160` closed on 2026-08-15** ("BUG-244: stop leaking a ~20 MB
executable into TMPDIR on every run"). The gate that pins it is in the QUICK tier and is
now failing, which is the system working — but the fix itself has stopped taking effect.

**What survives a clean run:** `hw.zig.fast.exe` (19,988,480 bytes) and `hw.zig.run.pdb`.
**What does not:** `hw.zig`. Both deletes sit in the SAME conditional
(`if rc == 0 and not keep_temp and output_dir == ""` — `selfhost/main.zbr`, the BUG-244
block), so the block RAN and `File.delete(zig_path)` succeeded while
`File.delete(fast_exe)` silently did not. `File.delete` cannot report failure, which is
why this is invisible without the gate.

**Measured, so the next person does not repeat it:**

| probe | result |
|---|---|
| 5 consecutive runs | leaked 5/5 — **deterministic, not a race** |
| the same 5 runs against a compiler built from **HEAD** with all local changes reverted | leaked 3/3 — **not caused by any uncommitted work** |
| `rm` from the shell immediately after the run | **succeeds** — the handle IS released by then |
| the same gate in the two `--daily` runs earlier the SAME DAY | **PASSED** |

**The last two rows are the whole puzzle and neither is explained.** The file is not
locked a moment later, so the compiler's `File.delete` is running while Windows still
holds the just-executed image — the classic delete-a-running-exe shape. But that would be
a race, and it reproduces 5/5; and the identical committed code passed twice within hours.
Something in the environment moved, and nothing here establishes what.

**UPDATE 2026-08-21 — THE LEAK IS LOAD-CONDITIONAL, and that is new information.** After
a `--daily` run, **47 scratch executables totalling 747 MB** were sitting in `%TEMP%`,
including several written during the run itself. An isolated repeat of the same test
immediately afterwards leaked **nothing** (3/3 clean, and again after the retry
workaround landed). So the bounded-retry workaround holds in isolation and does not hold
under sustained load.

That is the same conditionality as **BUG-302** (heavy gates failing an arbitrary file and
never reproducing), and the two are plausibly one phenomenon: file operations against
`%TEMP%` failing at a low rate under sustained load — a delete here, a build there. See
BUG-302 for the four mechanisms already eliminated by measurement (shared workdir, a stale
`.pdb`, disk pressure, and Defender real-time scanning, which is switched OFF on this
machine).

**Fix direction (untested):** deleting an executable immediately after `sys.exec_inherit`
returns is not reliable on Windows. A short retry with backoff, or deferring the unlink,
would make the existing BUG-244 logic robust instead of timing-dependent — and would hold
whether or not the environmental trigger is ever identified.

**Control when fixing:** `bash tools/runtime_module_check.sh` must pass, and the fix must
be watched going RED with the retry removed. Note the `.pdb` alongside: it is named for
the LLVM path (`.run.pdb`) although only the fast path ran, which nothing here explains
either and may be a thread to pull.

---

### BUG-305: a hex literal's SIZE SUFFIX silently emits a DIFFERENT NUMBER — CLOSED 2026-08-22

> **CLOSED 2026-08-22 — hex suffixes translate to `@as(T, value)` in BOTH compilers.**
>
> | written | emitted | value |
> |---|---|---|
> | `0xFF` | `0xFF` | 255 — Zig understands it, passed through |
> | `0xFF_u` | `@as(u64, 0xFF)` | 255 — was `invalid digit 'u' for hex base` |
> | `0xFF_u32` | `@as(u32, 0xFF)` | 255 |
> | `0xFF_32` | `@as(i32, 0xFF)` | **255 — was 65330** |
>
> Same shape as the float suffixes (`1.5_f32` -> `@as(f32, 1.5)`), which already worked.
>
> **THE `_32` LEG IS THE ONE THAT MATTERED, and it is the one a compile gate cannot see.**
> Reverting the fix makes `0xFF_u` fail LOUDLY, which masks the silent case — so it was
> falsified SEPARATELY: against the mutated compiler `0xFF_32` compiles cleanly, prints
> **65330**, and is caught only by comparing the value. BUG-226 class.
>
> **Selfhost hex support landed with it.** `isIntLit` now accepts `hex_lit`,
> `hex_lit_unsign` and `hex_lit_explicit` — the lexer had emitted all three since forever
> and `ExprIntLit` had carried an `IntBase` field to receive them, but no parser rule
> consumed one, so `0xFF` was `unexpected expression token` in the selfhost while the
> bootstrap grammar had `Atom -> hex_lit` all along. `AstBuilder` also hardcoded
> `IntBase.decimal`; it now derives the base from the text.
>
> **KNOWN LIMIT, deliberately not fixed here:** the suffix sets the LITERAL's type, not the
> variable's. `var b = 0xFF_u` emits `const b: i64 = @as(u64, 0xFF)`, which is fine while
> the value fits in i64 and overflows above it. For a constant like
> `0x9E3779B97F4A7C15`, annotate: `var golden: uint = 0x9E3779B97F4A7C15`. Making
> inference honour the suffix means teaching the TypeChecker to read it, which is a
> separate change; see NEXT_STEPS.
`0xFF_32` means "255 as a 32-bit int" in Zebra. The bootstrap emits the token VERBATIM,
and Zig reads `_` as a digit separator — so the program gets `0xFF32` = **65330**, not
255. Off by a factor of 256, no error, no warning.

```zebra
def main()
    var c = 0xFF_32
    print(c)          # prints 65330; should be 255
```

Emitted Zig, and it compiles cleanly:

```zig
const c = 0xFF_32;    // Zig: 0xFF32 == 65330
```

**This is the BUG-226 class — valid Zig computing the wrong number — so it is invisible to
`compile_check`, `full_sweep` and `divergence`, all of which only ask whether the emit
compiles.** `output_sweep` would catch it, but no corpus file uses a hex literal, which is
also why `divergence` never reported the selfhost's total lack of hex support.

The sibling form fails LOUDLY instead, which is the lesser problem:

```
error: invalid digit 'u' for hex base    <-  0xFF_u
```

**The fix has a precedent in this repo.** Float suffix literals (`1.5_f32`, `3.0f64`)
already emit `@as(fNN, val)`. Hex should do the same: `0xFF_u` -> `@as(u64, 0xFF)`,
`0xFF_32` -> `@as(i32, 0xFF)`. Plain `0xFF` needs no wrapper — Zig understands it.

**Control when fixing:** a RUN fixture, not a compile check. `0xFF_32` must print 255.
A compile-only gate passes today with the wrong value.

---

### BUG-304: `x <<= <runtime>` emits invalid Zig — CLOSED 2026-08-22

> **CLOSED 2026-08-22 — lowered to `x = _zbr_shl(x, n)` in BOTH compilers.**
>
> Mirrors how `//=` already emits `x = @divTrunc(x, y)` and `**=` emits `std.math.pow`.
>
> **THE FIXTURE'S SHIFT AMOUNTS ALL COME FROM A FUNCTION CALL, and that is the whole
> point.** Measured against the mutated compiler: `x <<= 2` prints **12 — correct** — while
> `x <<= amt()` fails with `expected type 'u6', found 'i64'`. Zig const-folds a literal
> amount, and a comptime value coerces to `u6`. A fixture written with `<<= 2` would have
> passed against the broken compiler and proved nothing: a cooperative attacker.
>
> That is also how the bug nearly escaped. The first probe used a literal and came back
> green, which is the probe-direction rule with a receipt — **probe a success and you
> underestimate the damage.**
>
> Pinned by `test/bug304_305_compound_hex_test.zbr` (`smoke_run`), watched failing at the
> `h <<= amt()` leg with the fix mutated out, and restored.
The bootstrap emits a bare `x <<= n;`. Zig requires a shift amount to coerce to
`Log2Int(T)` — `u6` for a 64-bit operand — so this is:

```
error: expected type 'u6', found 'i64'
```

Same defect the binary `<<` had (fixed 2026-08-22 via `_zbr_shl`/`_zbr_shr`); the compound
form goes through a different emit path and was not covered.

**IT LOOKS FINE WITH A LITERAL SHIFT AMOUNT, which is how it was nearly missed.**
`x <<= 2` compiles, because Zig const-folds the 2 and a comptime value coerces to `u6`.
Only a genuinely runtime amount reproduces it:

```zebra
def shiftBy(): int
    return 2

def main()
    var x: int = 12
    x <<= shiftBy()      # error: expected type 'u6', found 'i64'
    print(x)
```

That is the probe-direction rule with receipts: **probe a success and you underestimate
the damage.** The first probe used a literal and came back green.

**Fix:** lower to `x = _zbr_shl(x, n)`, mirroring how `//=` already emits
`x = @divTrunc(x, n)` and `**=` emits `x = std.math.pow(...)`.

**Control when fixing:** the shift amount must come from a function call, or the fixture
proves nothing.

---

### BUG-302: heavy gates fail files that pass in isolation — SEVEN occurrences, five gates; MEASURED at 2 of 3 `full_sweep` runs, so "low rate" is wrong — CLOSED 2026-08-22

> **CLOSED 2026-08-22 — zig could not read ITS OWN STDLIB, and three gates called that
> "your emitted Zig is bad".**
>
> **The error, which no one had ever seen:**
>
> ```
> .../.zvm/0.16.0/lib/std/debug.zig:1:1: error: unable to load 'debug.zig': Unexpected
> .../.zvm/0.16.0/lib/std/std.zig:71:27: note: file imported here
> ```
>
> `Unexpected` is zig's catch-all for an unmapped OS error; on Windows it appears under
> concurrent builds sharing the stdlib. **The failing path is inside the ZIG
> INSTALLATION** — our program was never compiled at all. Reporting `CFAIL` ("emitted bad
> Zig") is a claim about code zig never read.
>
> **WHY IT SURVIVED SEVEN OCCURRENCES: every gate destroyed the evidence.**
> `full_sweep.check_one` ends `rm -rf "$wdir"`, taking `build.err` with it for every file,
> pass or fail. `divergence_check.sh:54` was worse — `>/dev/null 2>&1`, so the error was
> never written down at all. The bug was **undiagnosable by construction**; no amount of
> re-running could have produced the message above. What finally worked was not another
> hypothesis, it was preserving one file.
>
> **THE MEASUREMENT THAT SETTLED IT.** One instrumented `full_sweep` run, 20 `CFAIL`s:
>
> | | |
> |---|---|
> | genuine compile errors in our output | **19** — the stable, baselined, expected set |
> | zig could not read its own stdlib | **1** — `allocate_copyout_deep_test` |
>
> and the single infra error was **precisely the file reported as a REGRESSION** against
> the baseline. It compiles cleanly in isolation, on the same binary.
>
> **THE FIX** is one predicate in `tools/zig_build_lib.sh`, shared by `full_sweep`,
> `divergence_check` and `compile_check` rather than pasted into each — the argument
> `corpus_ls.sh` makes for the corpus, and the lesson `isZigKeyword` paid for with a
> hand-maintained list guarding against a bug caused by a hand-maintained list. It retries
> ONLY this failure (three tries), buckets a persistent one as `INFRA`/`CINFRA` instead of
> `CFAIL`, and **prints the retry count every run including zero**. Divergence excludes
> `CINFRA` from gap accounting the way it already excludes `NOMAIN`, and names it.
>
> `FileNotFound` is deliberately NOT retried: that means a dep of ours was never emitted,
> it is deterministic, and `DEPMISS` already covers it.
>
> **CONTROLLED WITH THE REAL ATTACKER, NOT A MUTATION** (`tools/zz_bug302_control`): a
> stub `zig` that emits the verbatim error, fails on its first invocation and succeeds
> after. Four legs — infra-once retries to PASS; **a genuine compile error is NOT retried**
> (CFAIL, 0 retries); a persistent infra error becomes INFRA; and the predicate is run
> against the 20 REAL captured errors and must split them 1/19. The control sources the
> SHIPPED predicate, so it cannot pass against logic the gates do not have. Leg 2 is the
> load-bearing one: a retry that fired on real errors would mask breakage and triple
> runtime.
>
> **RECEIPT.** The verification run hit the failure **three times** and absorbed all three:
> `INFRA: 0`, `zig-infra retries: 3`, `PASS: 404 / CFAIL: 19`, gate **PASS — 0 regressions
> vs 390, positive set 288/288**. Before the fix that run would have been red. Prior rate
> was 2 of 3 `full_sweep` runs producing a false regression.
>
> **What it cost before being found:** seven occurrences across five gates, a failed
> `--daily` whose whole purpose is to leave a trustworthy tree, one occurrence
> investigated as a suspected compiler regression, and a standing instruction to re-check
> failures by hand — which is indistinguishable from re-running until green.
>
> **The transferable half, and it is not about zig.** A gate that classifies a failure
> must keep the failure's own account of itself. All three of these threw the error away
> and then asserted a cause — and the cause they asserted was always the alarming one,
> about our code, never about their own environment. This is the same shape already
> recorded for `output_sweep`, which auto-excluded deterministic crashers because a panic's
> thread ID made them look nondeterministic: **a slow or unreadable build is not a broken
> program, and a crash is not a flake.** When a checker cannot say WHY, it will eventually
> say something false about WHO.
CLAUDE.md has said since 2026-08-19 that a third occurrence "stops being a transient and
becomes the finding". This is the third.

| # | when | gate | file | verdict in-tier | verdict alone |
|---|---|---|---|---|---|
| 1 | 2026-08-19, `--daily` | `compile_check-inline` | `iter_collision_test` | 275 passed / 1 skipped | 1/1, then 276/0/0 on a full re-run |
| 2 | 2026-08-20, first `--daily` | `compile_check-inline` | `iter_collision_test` | 275/1 | 276/0/0 |
| 3 | 2026-08-20, `--full` | `divergence` | `contract_old_test` | `self=CFAIL`, 1 selfhost gap | 0 gaps via the harness's OWN `--only` path; emit+`build-exe` by hand also clean |

**THE SHAPE IS CONSISTENT AND THE FILES ARE NOT.** One file, one gate, inside a heavy
sweep at `JOBS=2`; passes immediately afterwards by every route including the gate's own.
Two different gates and two different fixtures, so it is not a property of either.

**WHY IT MATTERS MORE THAN ONE RED LINE.** These are the two gates whose whole job is to
be believed about the corpus. A gate that fails one file per run at a low rate teaches
people to re-run it, and re-running until green is precisely how a real regression gets
waved through. It also cost real time here: occurrence 3 was investigated as a suspected
regression from a same-day compiler change before it was shown to be nothing.

**OCCURRENCES 4 AND 5, from the `--daily` of 2026-08-21** (32/33 otherwise green, all
heavy sweeps clean including `divergence` at 0 selfhost gaps and `output_sweep` 374
identical):

| # | gate | file(s) | verdict in-tier | verdict alone |
|---|---|---|---|---|
| 4 | `compile_check-inline` | `type_alias_test` AND `with_call_test` | 280 passed / 2 FAILED | both clean |
| 5 | **`smoke`** | `field_order_test` | non-zero exit, 368/369 | **8/8 clean** |

**OCCURRENCE 6, 2026-08-22 `--daily` — THE LARGEST BY AN ORDER OF MAGNITUDE, AND THE
FIRST TO FAIL THE TIER.** Every prior occurrence cost one file in one gate and the tier
still passed or failed on other grounds. This one failed **three gates on four files**:

| gate | file | verdict in-tier | verdict alone |
|---|---|---|---|
| `full_sweep` | `bug260_bindlist_param_test` | REGRESSION vs baseline | emits clean; **runs**, prints `bug260: OK` |
| `examples_sweep` | `lisp` | `CFAIL`, REGRESSION | emits clean; **runs**, prints its Scheme output |
| `divergence` | `dispatch_diag` | `self=CFAIL`, selfhost gap | emits clean |
| `divergence` | `generic_tostring_test` | `self=CFAIL`, selfhost gap | emits clean |

Verified against the SAME binary the tier used — `zig-out/bin/zebra.exe` mtime `08-21
20:26`, unchanged throughout the run (checked, because source in `src/` and `selfhost/`
was edited mid-run for the bitwise work and the first question had to be whether that
reached a compiler; it did not, nothing rebuilt).

**WHAT THIS ADDS TO THE PICTURE:**

- **It is not confined to compile-only gates.** `examples_sweep` and `full_sweep` join
  `compile_check-inline`, `divergence` and `smoke`. That is FIVE distinct gates now.
- **The failures are CONCURRENT, not independent.** Four files failed inside one tier
  after five runs of at most one each. If each file failed independently at a low rate,
  four in one run is wildly improbable — so the events are correlated, which points at a
  MACHINE STATE that persists across a stretch of the run rather than at a per-file dice
  roll. That is a genuinely new constraint and it is INCONSISTENT WITH the "low-rate
  independent flake" reading the earlier entries assumed.

  **Deliberately not stated more strongly than that**, because a shared external cause is
  exactly what the confound below would also look like — correlated failures argue for a
  common cause, and they do not by themselves say whether that cause is the machine or the
  person working on it. The timeline weighs against the latter but rests on durations
  reconstructed by subtraction, not on timestamps.
- **It reached the ONE gate whose baseline makes a false red expensive.** `full_sweep`
  reported a REGRESSION against its baseline. Someone reading only the summary line would
  go looking for a compiler bug in `bug260_bindlist_param_test`, which is exactly the cost
  occurrence 3 already demonstrated, now with a name that implicates a recent fix.

**A CONFOUND I INTRODUCED, recorded because omitting it would make this occurrence look
cleaner than it is.** I was working in the tree while the tier ran: a standalone
`zig build-exe` at ~23:12 (which touches the SHARED zig cache) and several one-file
`zebra.exe` invocations at ~23:00–23:19. That is exactly the kind of parallel load
CLAUDE.md warns about, and it has to be weighed before blaming the machine.

**The timeline does not support it as the cause.** Reconstructing from the recorded
durations, my activity overlapped `compile_check-inline` (993 s, ~23:10–23:26) — which
**passed 285/0** — and stopped by ~23:19. `output_sweep` then ran ~23:27–23:58 and passed.
The three gates that failed ran AFTER I had stopped: `full_sweep` ~23:58–00:10,
`examples_sweep`, then `divergence` ~00:12–00:38. So the interference and the failures do
not overlap, and the gate that DID overlap is the one that came back clean.

Worth stating plainly anyway: this is weaker evidence than a run nobody touched. **The
memory experiment below must be run on an otherwise-idle machine**, or it will measure me
instead of the phenomenon.

**THE UNTESTED CANDIDATE IS STILL MEMORY, and this occurrence sharpens it.** The tier
opened at **6.0 GB free of 31.8 GB (81% used)** and the machine sat at **5.0 GB free (84%
used) while completely idle afterwards** — so the run began with roughly a sixth of RAM
available and the heavy gates ran two compilers in parallel inside that. Correlated
failures across a stretch of the run fit a resource that is exhausted for a period and
then recovers; they do not fit a per-file dice roll.

**THE DISCRIMINATING EXPERIMENT, still unrun and still cheap:** sample free RAM on a fixed
interval THROUGH a heavy gate and align the samples against the per-file failures the gate
reports. If failures cluster in the low-RAM troughs, that is the answer; if they are
uniform across the trace, memory is dead and the next candidate is needed. Either outcome
is worth having, and neither requires reasoning about it in the meantime. Run it before
any more speculation — four mechanisms have already been killed by measurement here
(shared workdir, stale `.pdb`, disk pressure, Defender) and a fifth by occurrence 5
(parallelism), every one of them plausible in prose.

**OCCURRENCE 7 — AND THE FIRST MEASURED RATE, 2026-08-22.** `full_sweep` was run three
times in ~90 minutes on the same tree (once in the tier, twice by hand). The counts move
in lockstep and identify the shape exactly:

| run | PASS | CFAIL | regressions |
|---|---|---|---|
| in `--daily` | 401 | 20 | 1 — `bug260_bindlist_param_test` |
| re-run #1 | 403 | 20 | 1 |
| re-run #2 | **404** | **19** | **0** — `positive set 288/288 pass` |

(PASS rises by 2 after run 1 because two new fixtures were added between; the meaningful
figure is CFAIL, which fell by exactly 1 as the regression cleared — ONE file flips per
run, never a cluster within `full_sweep` itself.)

**TWO OF THREE RUNS PRODUCED A FALSE REGRESSION.** Every earlier entry here describes "a
low rate"; at 2-in-3 in one gate that description is simply wrong, and the ticket's
priority should follow. A gate that cries regression on two runs in three is not
occasionally annoying — it cannot be used for the decision it exists to support, which is
"did my change break the corpus?".

**This also detaches the rate from tier load.** Runs 2 and 3 were single-gate invocations
with nothing else executing, so the earlier "heavy tier at JOBS=2" framing does not
survive either. What is left is a gate that at JOBS=2 loses one arbitrary file per run,
roughly two runs in three, in isolation.

**IT IS NOT MY BITWISE CHANGE.** All four files the tier named emit clean against BOTH the
binary the tier used (`08-21 20:26`) and the rebuilt one carrying the new operators
(`08-22 00:50`), checked separately.

**REVISED NEXT STEP — cheaper and better targeted than the RAM trace:** `full_sweep` now
reproduces at ~2/3 per run in ~12 minutes with no tier around it. Run it N times at JOBS=2
recording which file flips, then N times at **JOBS=1**. If the flip vanishes at JOBS=1 the
cause is concurrency inside this one harness and the RAM hypothesis is dead; if it
survives, it is per-process and the trace is worth taking. Either way it needs no
114-minute tier and no idle-machine window — which is what has kept this bug unmeasured.

**Cost so far:** this tier was the CLOSING MOVE of a night's work, whose entire purpose is
to leave a tree the morning can trust. It left three red gates that mean nothing, which is
the precise opposite. Until this is fixed, a `--daily` failure on a heavy sweep must be
re-checked file-by-file before it is believed — and that instruction is itself the damage,
because it is indistinguishable from "re-run until green".

**OCCURRENCE 5 FALSIFIES THE PARALLELISM ASSUMPTION IN THIS TICKET'S ORIGINAL TEXT.**
`selfhost_smoke.sh` runs SEQUENTIALLY. So "parallel workers sharing one Zig cache" cannot
be the mechanism, and the shared-`ZIG_GLOBAL_CACHE_DIR` experiment proposed below would
not have settled anything. What the five occurrences actually share is not parallelism —
it is a LONG, HEAVY run. Occurrence 4 is also the first with TWO files in one gate.

**FOUR MECHANISMS TESTED AND DEAD.** Recorded so nobody re-proposes them:

| hypothesis | how it died |
|---|---|
| a shared workdir | `divergence_check.sh` gives each worker its own `$OUT/ws-<name>`; no collision possible |
| a stale `.run.pdb` blocking the linker's rewrite | all three of the day's failing files had one. Ran them WITH the stale pdb present and again after deleting it: **rc=0 both ways** |
| disk pressure | 351 GB free on C: |
| Defender real-time scanning holding just-written files | `Get-MpComputerStatus` → **RealTimeProtectionEnabled: False** |

**AND IT IS PROBABLY THE SAME PHENOMENON AS BUG-300.** That ticket is a *delete* against
the temp dir failing; this one is a *build* against the temp dir failing. Both are
load-conditional, both involve file operations in `%TEMP%`, and neither reproduces in
isolation — 47 leaked executables (747 MB) were sitting in TEMP after the same run in
which an isolated repeat of the leak test leaked nothing. Treating them as one
"file operations in TEMP fail at a low rate under sustained load" is a better frame than
two independent flakes, and it predicts that fixing either mechanism fixes both.

**THE REMAINING UNTESTED CANDIDATE is memory pressure.** The run started with 6.1 GB free
and `full_sweep` is documented RAM-bound at `JOBS=2`. The discriminator is cheap and has
not been run: sample free RAM through a heavy gate, or run the same gate at `JOBS=1` and
compare the failure rate over several runs. File-handle exhaustion is the other candidate
and would need a handle count sampled the same way.

**THE UNTESTED HYPOTHESIS, named so a later run can discriminate rather than re-argue.**
Both affected gates invoke `zig build-exe` from parallel workers, and every worker shares
ONE global Zig cache (`%LocalAppData%\zig`). The QUICK gates that never do this have never
shown the symptom. Contention on that cache — a lock timeout, or a partially-written entry
being read — would produce exactly this: a single arbitrary file failing, with no defect in
the file and nothing reproducible afterwards.

**The discriminating experiment, cheap and not yet run:** re-run one of these gates with a
per-worker `ZIG_GLOBAL_CACHE_DIR`. If the rate goes to zero, the cause is cache contention
and the fix is to give each worker its own; if it does not, the hypothesis is dead and the
next suspect is the emit step rather than the build step. Running at `JOBS=1` is the
cruder version of the same test.

**Do NOT "fix" this by adding a retry.** A gate that retries until green is the thing this
ledger exists to prevent. If the cause turns out to be cache contention, isolate the
caches; the failure should stay loud.

---

### BUG-303: a `Gui.panel` callback that is a PLAIN function fails to compile — `callback.call(self)` on a `fn` — ✅ CLOSED 2026-08-21

> **✅ CLOSED 2026-08-21 — a pointer-vs-value mismatch, swept across all 12 sites.**
>
> **The cause.** Every dual-dispatch site asked *"plain fn, or closure struct with
> `.call`?"* by comparing `@typeInfo(@TypeOf(cb))` against the fn tag. That is true for a
> function VALUE and **false for a POINTER to one**, so a pointer fell through to the
> `.call` branch. The error naming the POINTEE (`fn (GuiContext) void`) rather than a
> pointer type is the tell, and it is what made this look like a comptime-branch-analysis
> problem at first — it is not; the predicate was simply answering the wrong question.
>
> **Why only this example.** Zebra emits a function POINTER for a lambda WITH A CAPTURE
> BLOCK: the capture goes through a thunk table (`_zbr_thunks_N`) whose elements are
> `*const fn(...)`. A capture-free lambda emits a closure struct; a top-level `def` emits a
> function value. Both of those already worked, which is exactly why `examples/counter.zbr`
> was fine and `panel_smoke` was not — and why the ticket's own "sweep the class first"
> instruction mattered.
>
> **Swept, not patched.** The predicate is now one `_zbr_is_fnlike` helper applied at all
> **12** occurrences, not just the three GUI callbacks — the MVU dispatch and the
> functional-trio sites had the identical latent defect. It is a strict SUPERSET of the old
> test, so it can only turn a compile error into a working call, never the reverse.
>
> Watched RED with the pointer arm disabled (the exact `.call` error), restored, and
> `examples/counter.zbr` re-checked as the control — the shapes that already worked still
> compile.
>
> **Pinned by `examples_sweep`:** `panel_smoke` moved from broken to a new pass and is
> locked into `tools/examples_sweep_baseline.txt`. That is the right pin here — the failure
> was a GUI-path emit, and `examples/` is the only corpus that carries one.
>
> **`examples/panel_smoke.zbr` compiles for the first time**, after three independent
> defects stacked in it were cleared in one sitting: BUG-233's lambda-parameter shadowing,
> an implicit capture that was the EXAMPLE's own error rather than a compiler bug, and this.
```
zebra_rt.zig:2968:94: error: no field or member function named 'call' in 'fn (zebra_rt.GuiContext) void'
    if (comptime @typeInfo(@TypeOf(callback)) == .@"fn") callback(self) else callback.call(self);
```

The runtime dispatches a panel callback two ways — call it directly when it is a plain
`fn`, otherwise call `.call` on it (the closure-struct shape). The `comptime` guard picks
the right one, but the `.call` branch is still analysed for a plain `fn` and fails.

**NEWLY REACHABLE, NOT NEWLY BROKEN.** `examples/panel_smoke.zbr` never got this far: it
failed earlier on BUG-233's lambda-parameter shadowing, twice (the lambda's `call` method
and then the GUI thunk's `dispatch`). With both fixed and the example's own implicit-capture
error corrected, this is the third defect in the stack. Nothing here changed the runtime.

**Severity:** medium-high for 0.9 — it is on the GUI path, and `examples/panel_smoke.zbr`
still does not compile because of it. `examples/counter.zbr` uses the closure shape and is
unaffected, which is why this has never been seen.

**Fix direction (untested):** the guard needs to keep the wrong branch out of ANALYSIS, not
merely out of execution — an `if (comptime …)` still semantically analyses both arms here.
A `switch` on `@typeInfo`, or hoisting the two cases into separate comptime-selected
functions, is the usual shape. Whether the same pattern appears in the other widget
callbacks is NOT yet swept and should be, before fixing this one site.

**Control when fixing:** `examples/panel_smoke.zbr` must emit and `zig build-exe` clean
under the selfhost, and `examples/counter.zbr` (the closure shape, which works today) must
keep working — one of each dispatch kind.

---

### BUG-251: `conn.read()` reads to EOF, which silently deadlocks a request/response server — ✅ CLOSED 2026-08-21

> **✅ CLOSED 2026-08-21 — `read` is the next chunk, `readAll` drains. Sean's call.**
>
> The semantics now match Go's split (`Conn.Read` vs `io.ReadAll`), which is what he
> recalled wanting from an earlier conversation:
>
> | call | behaviour |
> |---|---|
> | `conn.read()` | next available chunk; blocks until ≥1 byte, `""` at EOF |
> | `conn.readAll()` | drain until the peer closes (the previous `read`) |
> | `conn.readLine()` / `readBytes(n)` | unchanged framing primitives |
>
> **THE POINT IS WHICH SPELLING IS SAFE BY DEFAULT.** `read` is what a newcomer reaches
> for first, and it was the one that hung — silently, with no error on either side. Now the
> obvious way to write a server is the working way, and the drain has to be asked for by
> name. No in-repo caller had to change, because Tcp had no run coverage at all until the
> same day.
>
> **Falsified as a HANG, which is the honest shape for this defect.**
> `test/tcp_echo_roundtrip_test.zbr` covers all four calls across three servers — the
> natural `read()` request/response, the `readLine`/`readBytes` framed exchange, and a
> `readAll()` drain. With `_tcp_read` reverted to `streamRemaining` the fixture **times
> out (rc=124)**; restored, it passes. A fix that collapsed the two calls into one would
> fail the drain assertion.
>
> `""` at end-of-stream rather than an error: a closed peer is an ordinary outcome for a
> chunk read, and the caller distinguishes it by the empty result.
>
> **Both compilers.** `readAll` dispatches in the selfhost and the bootstrap, and the
> selfhost TypeChecker types it as `str` alongside the other three.
>
> Two things from the road here are worth keeping. The entry's original conclusion —
> *"Tcp cannot express request/response at all … a design gap"* — was **wrong**: framing
> already worked, and the reason it looked like a design gap is that QUICKSTART documented
> **no `TcpConn` method at all**, so `read()` was the only one a reader could find. And the
> preamble is read from DISK by the selfhost at emit time, so this whole change could be
> tested and falsified without a rebuild; the bootstrap embeds it at build time, which is
> what the rebuild guard correctly refused over.
> **RE-DIAGNOSED 2026-08-21. Two of this entry's conclusions do not survive measurement,
> and one half of it is now fixed.**
>
> **CONFIRMED:** `_tcp_read` is `streamRemaining` — it reads to EOF, exactly as the entry
> deduced from behaviour. A server that reads before replying waits for the client to
> close while the client waits for the reply. Neither side errors.
>
> **WRONG:** *"Tcp cannot express request/response at all without a framing or half-close
> mechanism … that is a design gap."* The framing already exists and works. Measured:
>
> ```
> handler: var line = conn.readLine();  conn.write("ECHO:" + line + "\n")
> client:  conn.write("ping\n");        var reply = conn.readLine()
> -> reply=[ECHO:ping], rc=0
> ```
>
> `readBytes(n)` works for length-framed protocols too. So this is not a design gap; it is
> a FOOTGUN plus a documentation hole.
>
> **AND THE DOCUMENTATION HOLE IS MOST OF WHY IT LOOKED LIKE A DESIGN GAP.** QUICKSTART's
> Tcp table documented `Tcp.connect` and `Tcp.serve` and **not a single `TcpConn` method** —
> so a reader had no way to discover `readLine`/`readBytes` at all, and `read()` was the
> only visible option. The table now lists all five with the deadlock warning and the
> framed idiom beside it.
>
> **FIXED HALF — Tcp has run coverage for the first time.**
> `test/tcp_echo_roundtrip_test.zbr` (`smoke_run_bounded`, 120 s) does a real
> client/server round trip: line-framed request/reply plus an exact-width `readBytes`
> frame. Before it, Tcp had never opened a socket in a test while
> `stdlib_run_coverage` counted it as covered, on the strength of a `Tcp.serve` call inside
> a function nothing calls.
>
> **WHAT REMAINS IS A DECISION, not an implementation.** `read()`-to-EOF is a legitimate
> primitive and also the one a newcomer reaches for first. Options:
>
> | option | cost |
> |---|---|
> | document only (**done**) | the footgun stays; a first-time user still hangs once |
> | add `readSome()` returning the first available chunk | additive, no breakage; two similar names to explain |
> | redefine `read()` as first-chunk, add `readAll()` for the current behaviour | matches most socket APIs; a semantic change to a shipped call |
>
> There is no in-repo caller to break — Tcp had no run coverage until today — so the third
> is cheaper here than it looks. Sean's call; the entry stays open on that question.

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

### BUG-233: a lambda parameter that shadows an enclosing one emits invalid Zig — ✅ CLOSED (selfhost) 2026-08-21

> **✅ CLOSED 2026-08-21 in the SELFHOST — and the class had TWO emit sites, not one.**
> `test/bug233_lambda_param_shadow_test.zbr` (`smoke_run`).
>
> **Site 1 — the lambda's `fn call`.** Renamed on a DETECTED collision only, via
> `isLocalOrParamName` evaluated on the ENCLOSING generator, with the rename threaded to
> every read through `genIdentRaw`. The prefix carries the lambda's uid so two NESTED
> lambdas both taking `g` do not rename to the same thing and re-create the shadowing one
> level down. Watched going RED with the rename disabled: the ticket's error verbatim.
>
> **Site 2 — the GUI closure thunk's `fn dispatch`.** Found by fixing site 1: with the
> call-method shadowing gone, `examples/panel_smoke.zbr` hit
> `fn dispatch(ctx: *anyopaque, g: Gui)` shadowing the same outer `g`. **The fix there is
> different and simpler, and the difference is the interesting part:** the thunk's
> parameters are never referenced by user code — the body forwards them straight to
> `cc.call(...)` — so the names are entirely the compiler's to choose. They are now
> GENERATED (`_zbr_ta0`, `_zbr_ta1`, …), which removes the class rather than detecting an
> instance of it. Collision detection is only needed where the name is user-visible.
>
> **Collision-only was the right call and is pinned.** The fixture's `noCollision` case
> asserts an untouched emit; verified directly in the generated Zig — the colliding params
> became `_zbr_lp1_x` / `_zbr_lp2_y` / `_zbr_lp3_y` while the non-colliding one stayed a
> bare `b`. Renaming unconditionally would have rewritten every lambda in the corpus and
> churned `output_sweep`'s baseline and the round-trip's byte-identity.
>
> **STILL OPEN IN THE BOOTSTRAP, which matters for the reported case.** `--gui-backend=*`
> delegates to `zebra-bootstrap`, so a GUI build still hits site 1 there. The bootstrap
> needs the same treatment (`Generator.capture_fields` at `src/CodeGen.zig:2328` is the
> shape to copy for the rename state; the collision predicate is the piece it does not
> already have). Left selfhost-only deliberately under the standing allowance, and
> recorded rather than assumed.
>
> **`examples/panel_smoke.zbr` is NOT fixed by this alone, and the reason is worth
> knowing.** It had three independent defects stacked: this one; an IMPLICIT CAPTURE of
> `model` in a lambda, which is not a compiler bug at all (Zebra requires an explicit
> `capture` block — a bare read emits `'model' not accessible from inner function`) and is
> fixed in the example here; and a third, newly REACHABLE once the first two cleared —
> filed as **BUG-303**. Each was hidden behind the one before it.
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

---

**INVESTIGATED 2026-08-20 — not fixed; here is what the next attempt should start from.**

**A minimal NON-GUI repro, which this entry did not have.** The only recorded case was
`examples/panel_smoke.zbr`, which needs the GUI path to reproduce. It is seven lines:

```zebra
def runWith(n: int, f: def(int): int): int
    return f(n)

def outer(x: int): int
    return runWith(x, def(x: int): int      # lambda param shadows the enclosing one
        return x * 2
    )

def main()
    assert outer(21) == 42
```

```
error: function parameter 'x' shadows function parameter from outer scope
```

**BOTH COMPILERS, verified.** The selfhost and the bootstrap produce the identical error
on that file. That matters for scoping the fix rather than being a detail: the reported
case is a GUI example, `--gui-backend=*` delegates to **zebra-bootstrap**, so a
selfhost-only fix would leave `examples/panel_smoke.zbr` exactly as broken as it is now.
This is one of the cases where the standing "ship selfhost-only when parity is a tax"
allowance does not apply — parity IS the fix here.

**"Give it a reserved prefix" is the WRONG half of the ticket's suggestion.** Renaming
every lambda parameter changes the emitted Zig for every lambda in the corpus, which
churns both heavy golden baselines (`output_sweep`, and the round-trip's byte-identity)
for a defect that occurs only on collision. Rename ONLY on detected collision and no
existing program's emit moves at all.

**Detection is already available.** `isLocalOrParamName(name)` on the ENCLOSING generator
answers exactly the question — it consults `param_names` plus `infer_ctx.hasLocal` — and
in `genLambdaEx` the enclosing generator is still `self` at the point the parameter list
is emitted (`lg` is derived a few lines later).

**The actual work is the SUBSTITUTION, not the detection.** The parameter is emitted once
via `zigSafeName(p.name)`, but every reference in the body resolves through
`genIdentRaw`, which has no notion of a renamed local. So the fix needs a per-lambda
rename MAP threaded onto the lambda's generator — the `capture_fields` pattern
(`asMethod().withCaptureFields(cf).withInferCtx(lam_ctx)`) is the shape to copy — plus an
early arm in `genIdentRaw` ahead of the capture-field arm.

**The obvious shortcut does not work, and it is worth writing down so nobody re-derives
it:** emit the parameter renamed and immediately re-bind it (`const x = _zbr_lp_x;`) so
the body can keep using the bare name. Zig forbids a *local* shadowing an outer-scope
parameter too, so the re-binding is the same error one line lower.

**Nested lambdas need the renamed name to be UNIQUE, not merely prefixed** — two nested
lambdas both taking `g` would otherwise collide with each other under one fixed prefix.
The lambda's uid is already in hand for the struct label.

**Why it was not landed in the session that found all this:** it is a codegen change in
two compilers, one of them the regen authority, whose reported symptom is only fully
verifiable by a human running a GUI app. That is a poor thing to land unattended
overnight. The repro above turns it into a bounded, gate-verifiable task for whoever
picks it up: the fixture can be an ordinary `smoke_run`, no GUI required.

**Why nothing caught it:** it is not in `test/*.zbr`, and every heavy gate globs
that. `examples/` had no gate until A5 (`tools/full_sweep.sh --examples`), which is
now in the FULL tier. Not baselined — it is one of the two named non-passing entries
the sweep prints on every run.

---

### BUG-240: `var s: Set(T) = {}` — annotated EMPTY set literal does not compile — ✅ CLOSED 2026-08-21

> **✅ CLOSED 2026-08-21 — the suggested fix was right, and the fixture covers one thing
> the suggestion did not mention.**
> `test/bug240_empty_set_annotated_test.zbr` (`smoke_run`). `Set` joins `HashMap` on the
> annotated-empty-literal branch in `genLocalVar`, emitting the ANNOTATED type's
> `.init(_allocator)`.
>
> **BOTH BACKING SHAPES ARE PINNED.** `Set(str)` lowers to `StringHashMap(void)` and
> `Set(int)` to `AutoHashMap(i64, void)` — different `genType` branches. A fix reaching
> only the string one would have looked complete and left half the type space broken, so
> the fixture asserts both, and both were confirmed working after the change.
>
> Watched going RED with `or gtll.name == "Set"` removed:
> `expected type 'hash_map.HashMap(str,void,StringContext,80)', found
> 'hash_map.HashMap(str,str,AutoContext(str),80)'` — the ticket's error verbatim.
>
> The controls stayed green and are in the fixture for that reason: `{"a","b"}` parses as
> `set_lit` and never reaches this branch, and `HashMap(str,int) = {}` is the sibling that
> already worked. If either breaks, the fix went too wide.
>
> **SELFHOST-ONLY, and not a parity gap.** `Set(T)` is a selfhost feature; the bootstrap
> does not parse this file at all (`syntax error near '{'`), which is the documented §28f
> bootstrap gap rather than a regression.
>
> *Process note:* the restore after falsification put back a backup taken BEFORE the fix,
> so the "restored" tree was the unfixed one — caught only because the fixture was re-run
> afterwards instead of assumed. Re-running the case after a restore is not ceremony.
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

### BUG-262: the selfhost never materializes a native `.zig` dep, so `use SomeZigModule` fails — ✅ CLOSED 2026-08-21

> **✅ CLOSED 2026-08-21 — landed on the SECOND attempt, and the difference is one line's
> position.**
> `test/bug262_native_zig_dep_test.zbr` + `test/bug262_native_zig_dep.zig` (`smoke_run`).
>
> **The fix:** `.zig` deps are collected during the dep walk and copied beside the emitted
> output in `writeNativeZigDeps`, called immediately after `writeRuntimeModule` — the one
> point every emit route (`--emit-zig`, `--output-dir`, run-mode temp dir, `-c`, the fast
> backend) passes through.
>
> **THE ORDERING IS THE FIX, not a detail.** The branch sits AFTER the prebuilt-library
> scan. Attempt one put it beside the `.c` case, where it reads more naturally, and turned
> `ffi_lib_check` red — `undefined symbol: zebra_lib_answer` — because that gate builds
> `zzlib.lib` FROM `zzlib.zig` and then asserts the emit does not `@import` it. A `.zig`
> may be the SOURCE OF a library rather than a module, so a prebuilt library WINS over a
> same-named `.zig`. That is the OPPOSITE of the `.c` rule, and the constraint was already
> written down — in a gate — before anyone knew to look for it.
>
> Verified this time: the fix is present in the GENERATED `selfhost/main.zig` and not just
> the `.zbr` (2 occurrences each), `zig_interop_test` runs under the shipping compiler, and
> `ffi_lib_check` is 3/3 including its negative control.
>
> **COVERAGE GAINED, which is the reason this was worth finishing.** `zig_interop_test`
> sat in `tools/positive_set.sh`'s SKIP list described as a HARNESS LIMIT — *"needs
> external source the standalone emit never materializes"*. True, and its cause was this
> bug. The file has left the skip list and is registered `smoke_run`. **A "harness limit"
> that turns out to be a compiler defect is worth re-reading the other skips for.**
>
> Selfhost-only, deliberately: the bootstrap emits beside the SOURCE, where the dep already
> is, so it never had the bug. The shipping compiler was the broken one.
>
> The fixture's dep needed a `.gitignore` exception (`test/**/*.zig` is ignored because
> per-fixture `.zig` files are generated artifacts; hand-written ones are listed as
> exceptions). Note `.gitignore` has no INLINE comments — a trailing `# ...` becomes part
> of the pattern and silently fails to match.
> **THE DIAGNOSIS IS CONFIRMED AND THE FIRST FIX WAS WRONG IN ONE SPECIFIC WAY. Anyone
> picking this up should start from here rather than from the original entry below.**
>
> **Confirmed:** `zebra.exe test/zig_interop_test.zbr` fails
> `unable to load 'ZigMath.zig': FileNotFound` while `zebra-bootstrap.exe` runs it. The
> bootstrap emits BESIDE THE SOURCE, where the dep already sits; the selfhost emits to a
> temp directory and copies nothing there. There is no `.zig` branch in the selfhost's dep
> resolution at all.
>
> **The fix that worked:** collect `.zig` deps during the dep walk, then copy each one
> beside the emitted output in `writeNativeZigDeps`, called immediately after
> `writeRuntimeModule` — the single point every emit route (`--emit-zig`, `--output-dir`,
> run-mode temp dir, `-c`, the fast backend) passes through. Verified: `zig_interop_test`
> ran, and the standalone `--output-dir` emit produced `ZigMath.zig` beside the output and
> `zig build-exe` on it returned 0.
>
> **WHY IT WAS REVERTED — the ordering, and it is not a detail.** The new branch `return`ed
> as soon as it found a `<dep>.zig`, which put it AHEAD of the prebuilt-library scan. That
> broke `ffi_lib_check`:
>
> ```
> error: lld-link: undefined symbol: zebra_lib_answer
> ```
>
> because that gate writes `zzlib.zig` as **the source it builds `zzlib.lib` from**, and
> then compiles a Zebra program that must LINK the library. With the new branch, `use
> zzlib` found the `.zig`, treated it as an importable module, and never linked. The gate
> even carries a leg asserting the emit must NOT `@import("zzlib.zig")` for a prebuilt
> library — the constraint was already written down, in a gate, and the fix walked into it.
>
> **So the rule the next attempt must encode:** a prebuilt library WINS over a `.zig` of
> the same name; only a bare `.zig` with no library beside it is an importable dep. That is
> the OPPOSITE of the `.c` rule ("a `foo.c` beside a stale `foo.lib` keeps compiling the
> source"), and the reason is that a `.zig` may be the SOURCE OF the library rather than a
> module. Put the branch after the library scan.
>
> **A COVERAGE PRIZE IS ATTACHED, which is why this is worth finishing.**
> `zig_interop_test` sits in `tools/positive_set.sh`'s SKIP list described as a HARNESS
> LIMIT — *"needs external source the standalone emit never materializes"*. That
> description is true and its cause is THIS BUG, not the harness. With the fix in place the
> file left the skip list, `registration_check`'s unasserted debt went 19 → 18, and
> `full_sweep`'s absolute leg gained a file. A "harness limit" that turns out to be a
> compiler defect is worth re-reading the other two skips for.
>
> **Fixture shape that worked:** a trivial `test/bug262_*.zig` exporting one function plus
> a `.zbr` that `use`s it — with QUALIFIED calls, not `exposing`. An `exposing` list on a
> native dep aliases the Zebra-MANGLED name (`_zbr_fn_triple`), which a hand-written Zig
> module does not have; that is **BUG-263** and it is still open, so pinning it here makes
> the fixture fail for the wrong reason.

---

### BUG-250: `HttpResponse(status, body)` — the 2-arg constructor fails a full compile — ✅ CLOSED 2026-08-20

> **✅ CLOSED 2026-08-20 — TWO defects, both fixed in both compilers, both falsified.**
> `test/bug250_httpresponse_ctor_test.zbr`, registered `smoke_run` AND
> `smoke_run_bootstrap`.
>
> **1. Codegen (both compilers).** A bare `HttpResponse(...)` call was emitted verbatim,
> which Zig reads as a CALL ON A TYPE. It now routes to the SAME emit as the documented
> `HttpResponse.new(status, text)` factory, so the two spellings cannot drift. Watched
> going RED with both routes reverted: `error: type 'type' not a function` at the
> constructor line, on both compilers.
>
> **2. The BOOTSTRAP TypeChecker (found only because the fixture PRINTS).** With codegen
> fixed, the bootstrap compiled and then printed `{ 109, 97, 100, 101 }` for `${a.text}`
> instead of `made` — the call typed as unknown, so interpolation took the `{any}`
> fallback. Valid Zig, wrong output: BUG-226's class. **An `assert a.text == "made"` does
> NOT catch it** — the comparison is on the string and only the FORMATTING is wrong, which
> is why the fixture's expected output carries the interpolated text.
>
> **THE ENTRY'S CLAIM ABOUT `test/http_serve_test.zbr` WAS RIGHT AND ITS INFERENCE WAS
> WRONG.** That file does use the broken form — and it PASSES, and always did. Its
> `handleRequest` is never called, Zig analyses functions lazily, so the constructor was
> never compiled. The same lazy-analysis trap recorded for BUG-269's probe. It was not
> "shipping broken"; it was shipping VACUOUS, which is worse in the way this repo cares
> about: it looked like coverage.
>
> Also corrected: the failure was never position-dependent. var-init, annotated var-init
> and return position all failed identically; the vacuous test is what made it look like
> only some positions were affected.
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

---

### BUG-124: Bootstrap codegen — `^T?` constructor arg boxes as `*?T` instead of `?*T` for value-typed T — ✅ CLOSED 2026-08-20

> **✅ CLOSED 2026-08-20 — verified by RUNNING the case on the bootstrap, and PINNED.**
> `test/bug124_boxed_nilable_ctor_test.zbr` + `test/bug124_boxed_ctor_lib.zbr`, registered
> `smoke_run_bootstrap` — the first fixture in the suite aimed at this bug's compiler.
>
> **Watched going RED against a bootstrap rebuilt with the fix reverted**
> (`genType(payload)` → `genType(inner)` in `genBoxedArgExpr`):
>
> ```
> error: expected type '?*T', found '*?T'
> note: pointer type child '?Val' cannot cast into pointer type child 'Val'
> ```
>
> which is the symptom in this entry, verbatim.
>
> **The 2026-08-17 triage was right to hold it open.** The evidence then was that the fix
> is VISIBLE IN THE SOURCE, and code-presence is not a run: `selfhost_smoke` executes the
> SELFHOST, which was never wrong here, so nothing in the harness could have failed. What
> closes it is `smoke_run_bootstrap`, which existed and had two users.
>
> **Two things the fixture had to work around, both recorded in its header:** it is a
> CROSS-MODULE pair, because reading back through a same-module `^Val?` is an unrelated
> bootstrap gap; and its payload is a union rather than a struct, because the struct form
> does not compile on either compiler — now filed as **BUG-299**, found by writing this pin.
> **Triaged 2026-08-17 — KEPT OPEN pending a pin, not because it is believed broken.**
> The body below says *Fixed (2026-05-26)* and the named mechanism is present in the
> source (`genBoxedArgExpr` uses `payload`). That is code-PRESENCE evidence, which is
> weaker than running the case, and `lint_stale_bugs` flagged it. It is bootstrap-only,
> and `selfhost_smoke` runs the SELFHOST — so there is no existing harness that would
> execute a fixture for it. **The remaining work is the pin, and that is real work**;
> closing it without one would move it into `bug_fixture_check`'s debt column, which is
> the ledger telling the truth about exactly this.

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

---

### BUG-027: Method chaining on struct temporaries requires manual intermediate vars — ✅ CLOSED 2026-08-20

> **✅ CLOSED 2026-08-20 — verified by running the case, and PINNED.**
> `test/bug027_chain_expression_position_test.zbr` (`smoke_run`). The fixture was watched
> going RED against a compiler with the labeled block disabled (`if m.object is Expr.call`
> → `if false`): `error: expected type '*T', found '*const T'`, the ticket's symptom.
>
> **The first draft of that fixture pinned nothing, and the reason is worth keeping.** It
> chained `withVal`-style methods that do not mutate — those lower to a BY-VALUE receiver
> (`fn m(self: Builder)`), which Zig accepts on a temporary — so it passed with the fix
> removed. Only a method that ASSIGNS TO A FIELD forces `fn m(self: *Builder)` and makes
> the temporary illegal. Measured, not reasoned: the mutated compiler emitted
> `_zbr_fn_makeBuilder(5).withVal(10)` and printed the right answers.
>
> The known remaining sub-issue below (a throws chain in call-arg position inside a
> labeled `try` block) is NOT pinned, deliberately — it is still broken.
- **Severity:** Low (ergonomic / language design)
- **Status:** Fixed — expression-position call-arg chains now emit a labeled block `(blk_N: { var _mc_N = f(); break :blk_N _mc_N.method(args); })` in both Zig backend (`src/CodeGen.zig`) and selfhost (`selfhost/codegen.zbr`). Bootstrap 5/5. Throws sub-issue also fixed: `exprCallIsThrows` now handles call-expression receivers (looks up TC type, scans class/struct members); labeled block emits `break :blk_N try _mc_N.method(args)` when the chained method `throws`. Selfhost mirrors this via `inferExpr`+`isClassMethodThrows`.
- **Remaining sub-issue (deferred):** Expression-position chain `foo(f().throws_method())` inside a `try { }` block (`try_block_label != null`) — the labeled block emits the `try` prefix on `break`, but there is no catch redirect into the try-block's error variable. This path is rare (requires both a labeled try block and a throws chain in call-arg position) and not hit by current tests. Workaround: extract to a named variable before the call-arg site.
- **Symptom A (method-chain-on-temporary):** `display(makeBuilder(5).withVal(10))` fails: the struct temporary `makeBuilder(5)` becomes `*const Builder`, but `.withVal(10)` requires `*Builder`.
  **Fixed positions:** `var r = f().method()` (var-init), `return f().method()` (return), `x = f().method()` (assign) — hoisted via `hoistCallChain` in selfhost / statement-position fix in Zig backend. `foo(f().method(args))` (call-arg / expression) — now fixed via labeled block in both backends. `foo(f().throws_method())` — now emits `try` in both backends.
- **Symptom B (TC auto-deref annotation gap):** When a local variable is assigned from a `throws`-returning function via `?` propagation (`var x = foo()?`), the TypeChecker doesn't record the inferred type in `expr_types`. Downstream `^T` field accesses on `x` then silently omit the required `.*` deref because TC type is `.unknown`. Workaround: annotate explicitly — `var x as T = foo()?`. Fix tracked separately as BUG-077.
- **Root cause (A):** Zig temporary value semantics — caller's stack slot for a struct returned by value is `const`.
- **Root cause (B):** `inferCall` for `?`-propagated throws calls doesn't write back to `expr_types` for the receiving variable.

---

### BUG-079: Method chaining on struct-returning calls silently mis-compiles or is unnecessarily banned — ✅ CLOSED 2026-08-20

> **✅ CLOSED 2026-08-20 — verified by running the case, and PINNED.**
> `test/bug079_chain_statement_positions_test.zbr` (`smoke_run`) covers the three
> statement positions the fix hoists: var-init, return and assign. Watched going RED with
> all three `hoistCallChain` guards disabled — `error: expected type '*T', found
> '*const T'` at the var-init chain.
>
> Same fixture-design trap as BUG-027: the chained method must MUTATE, or it lowers to a
> by-value receiver and the fixture passes with the fix removed. See that entry.
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

### BUG-083: `genGenericClass` skips `implements` conformance checks — ✅ CLOSED 2026-08-20

> **✅ CLOSED 2026-08-20 — verified, and PINNED ON THE EMIT.**
> `test/bug083_generic_implements_test.zbr`, registered twice: `smoke_run` (it runs) and
> `smoke_emit_contains … "Printable.check(@This())"` (the mechanism). Watched going RED
> with `genGenericClass`'s `if n.ifaces.len > 0` disabled: the string disappears.
>
> **Why not a behaviour pin.** The check exists to make a NON-conforming generic class
> fail to BUILD, so the only fixture that could catch the regression by running is one
> that must not compile — and the smoke suite's `*_fail` helpers are front-end and
> runtime, with no zig-level must-fail harness. Asserting the emitted comptime block is
> the direct test and cannot pass vacuously.
>
> This is `smoke_emit_contains`'s first use; the helper had been defined and never called.
- **Severity:** Low (conformance gap, not correctness gap — the class still compiles)
- **Status:** Fixed — `src/CodeGen.zig` and `selfhost/codegen.zbr` both emit `comptime { IFoo.check(@This()); }` in `genGenericClass`; `test/generic_iface_test.zbr` covers this; bootstrap 5/5.
- **Symptom:** A generic class declared `class Stack(T) implements IFoo` does not emit a `comptime { IFoo.check(@This()); }` block inside the generated Zig struct. The missing check means the compiler won't catch at compile time that `Stack(T)` is missing a required method — the error will only surface when a caller tries to use a `Stack(T)` value through the interface (if ever).
- **Root cause:** `genGenericClass` in both `src/CodeGen.zig` and `selfhost/codegen.zbr` handles `invariants` but has no `implements`/`ifaces` block. `genClass` delegates to `genGenericClass` early and never runs its own `implements` block. This was a pre-existing gap before interface vtable codegen was added.
- **Fix:** Added `implements.len > 0 → comptime { IFoo.check(@This()); }` block in `genGenericClass` (both backends), parallel to `genClass` and `genStruct`.

---

### BUG-084: Selfhost `Lexer.zbr` tracks `[`/`]` in `parenDepth`; Zig `Tokenizer.zig` does not — ✅ CLOSED 2026-08-20

> **✅ CLOSED 2026-08-20 — verified against BOTH compilers, and PINNED.**
> `test/bug084_bracket_paren_depth_fail.zbr` (`smoke_tc_fail`) is a MUST-FAIL fixture,
> which is the only shape that can see this regression: reverting the fix makes the
> selfhost ACCEPT a multi-line `[...]`, and everything that compiles today would still
> compile with the bug back.
>
> Both front ends reject it at 23:17 (selfhost "unexpected expression token", bootstrap
> "syntax error near") — the messages differ, the ACCEPT/REJECT verdict agrees, and that
> verdict is what the parity claim is about. Carries a control: the SAME literal on ONE
> line is accepted, so the rejection is caused by the line break rather than by the
> literal.
- **Severity:** Low — root divergence fixed; both backends now behave identically
- **Status:** Fixed — removed `[`/`]` and `@[` from `parenDepth` tracking in `selfhost/Lexer.zbr`; aligned with `src/Tokenizer.zig` (only `(`/`)` tracked); 26/26 smoke tests pass; bootstrap 5/5
- **Root cause:** Selfhost `Lexer.zbr` tracked both `[`/`]` and `(`/`)` in `parenDepth`. Zig `Tokenizer.zig` only tracks `(`/`)`. The divergence was accidental — the original selfhost port added `[`/`]` tracking without a design reason, and the `@[` emit path (added for array literals) was patched to compensate rather than root-cause fixed.
- **Fix:** Removed `parenDepth = parenDepth ± 1` from the `[`/`]` handling and the `@[` `scanAt` path in `selfhost/Lexer.zbr`. Both backends now only suppress EOL inside `(`...`)`. Multi-line `@[...]` is consistently unsupported in both backends (same behavior).

---

### BUG-085: `static def` methods — bare static field names incorrectly emit `self.field` — ✅ CLOSED 2026-08-20

> **✅ CLOSED 2026-08-20 — verified by running the case, and PINNED.**
> `test/bug085_static_field_bare_test.zbr` (`smoke_run`) exercises BOTH halves the fix
> claimed: a bare static field inside a `static def`, and a bare static field alongside a
> bare instance field inside an INSTANCE method — the second is what distinguishes this
> fix from the `in_static_method` flag that was rejected.
>
> Watched going RED with the guard disabled (`if isSharedField(id.name)` → `if false`):
> `error: use of undeclared identifier 'self'`, the ticket's symptom verbatim.
>
> **Naming drift, recorded rather than silently fixed:** the body below says the selfhost
> helper is `isStaticField` in `selfhost/codegen.zbr`. It is `isSharedField` in
> `selfhost/CodeGen.zbr` today (the module was renamed to PascalCase, and the helper
> renamed at some point after this entry was written). The mechanism is the one described.
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

### BUG-272: a parameter used only inside `ensure … old p` is discarded — ✅ CLOSED UNREACHABLE (2026-08-18)

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

#### CLOSED 2026-08-18 — UNREACHABLE, not repaired. Read the distinction.

**The walker gap still exists.** `nameUsedInExpr` still has no `on Expr.old_` case, and
the `# expr-walker-ok: old_` waiver is still in place. Nothing about the analysis was
fixed.

**What changed is that nothing can steer into it any more.** The dilemma needs a name
that is BOTH usable inside `old` AND subject to a `_ = x;` discard. Measured:

| candidate | usable inside `old`? | discardable? | verdict |
|---|---|---|---|
| parameter | **no** — BUG-292 refuses `old <parameter>` in the front end | yes | unreachable |
| local | **no** — the snapshot hoists to function ENTRY, so a body-declared local is `use of undeclared identifier` there | yes | unreachable |
| field | yes | no — fields are not discarded | harmless |

The exact repro in the body above now stops at:

```
zz_272.zbr:5:22: error: 'old p' is always equal to 'p' — a parameter cannot change
between entry and exit. Use 'old' on state the method mutates (a field), or drop it
```

**And identically under `--turbo`**, which is the half that matters here: the refusal is
a front-end check on what the user WROTE, not on what gets emitted, so it does not
inherit the flag-dependence that made this bug hard. Verified both ways.

**IT COMES BACK** if `old` is ever made usable on a discardable name — relaxing the
BUG-292 refusal, or supporting `old <local>`. Whoever does that owns the waived branch.
The guard in the meantime is `test/bug292_old_param_test.zbr`, which asserts the
refusal's message.

**A stale citation fixed on the way:** the waiver in `CgHelpers.zbr` said "BUG-269",
which is a different bug (`extern` returning `str`). It now cites BUG-272.

---

### BUG-292: `old <parameter>` was inert and undocumented-as-such; now REFUSED — ✅ FIXED (closed 2026-08-17)

**Found 2026-08-17** writing `test/boundary/bv_contract_boundary.zbr`. The compiler is
correct; §24 is not. Found by authoring a probe from the document and noticing the row
could not fail.

§24 introduces `old` with this example and this rationale:

```zebra
def increment(n: int): int
    ensure
        result == old n + 1          # snapshot pre-call value of `n`
    return n + 1
```

> `old expr` snapshots `expr` at function entry … Useful when the caller-supplied value
> is later **mutated or shadowed** inside the function.

**Both named cases are impossible for a parameter**, measured:

| the doc's case | what the compiler says |
|---|---|
| `n = 999` — "later mutated" | `error: cannot assign to constant` |
| `var n = 999` — "or shadowed" | `error: local constant 'n' shadows function parameter from outer scope` |

A parameter cannot change between entry and exit, so in the example above `old n` is
**exactly equivalent to `n`**. The canonical demonstration of the feature is the one
place it provably makes no difference, and the sentence explaining when to reach for it
describes two things the language refuses.

**`old` is real and works** — on mutable state. `test/contract_old_test.zbr` is the
honest shape and it discriminates: `ensure balance == old balance + amount` with
`balance = balance + amount`, where reading at exit would give `100 == 200` and panic.

**Why this matters beyond tidiness.** A reader copying the documented form gets an
`ensure` that passes under any implementation of `old`, including a broken one. That is
how a feature ends up with test coverage that cannot fail — `contract_old_compound_test`
has the same inertness (`val in @[old val, n]` where `val = n`, so correct gives
`3 in [0,3]` and exit-reading gives `3 in [3,3]`; both true), and so did the first draft
of the boundary probe, which copied the doc.

**Fix:** make §24's example use a field, as `contract_old_test` does, and correct the
rationale — `old` earns its keep on state the METHOD mutates, not on caller-supplied
arguments, which Zebra makes immutable.

**Control when fixing:** the replacement example must be one where reading the value at
exit gives a DIFFERENT answer — otherwise the doc has been edited without the defect
being removed.

---

#### IMPLEMENTATION NOTES — `old <parameter>` is to be REFUSED (Sean's call, 2026-08-17)

Sean approved turning the inert form into a refusal: *"refusal helps us to UNGIT"*, and
*"the message is critical"*. Recorded in full so this does not have to be re-derived.

**PHASE DECISION: the FRONT END, not CodeGen.** A CodeGen-phase error would be invisible
to `zebra -c` (front-end only), i.e. a 55th entry in `frontend_gap.py`'s 23-of-54 — the
gap NEXT_STEPS' organizing goal exists to shrink. A refusal that only fires on a full
compile is a weaker version of the feature, and for a DIAGNOSTIC where the user meets it
is most of its value.

**INSERTION POINT: `checkDecl`, `selfhost/TypeChecker.zbr:4012` (`on Decl.method as dm`).**
This is the whole reason the change is small: `dm.params` AND `dm.ensure_` are both in
scope there (`Ast.zbr:308-311` puts them on the same node). So the check needs NO
`InferCtx` change and no param-vs-local distinction — which matters, because a LOCAL can
be mutated, so `old <local>` is legitimate and refusing it would be a false accusation.
An earlier plan to add a param-name set to `InferCtx` was unnecessary; `inferExpr` was
the wrong altitude.

Note `dm.ensure_` is NOT currently walked by the TypeChecker at all — contracts are
type-checked nowhere in the selfhost front end. Walking them wholesale for the first time
has an UNMEASURED blast radius (new errors across the corpus); the check must therefore
scan for `old` nodes specifically rather than type-check the clause.

**TRAVERSAL: shared, already extracted.** `CgHelpers.collectOldNodes(expr, out)` — moved
there 2026-08-17 from `CodeGen.collectAndEmitOldSnapshots`, whose own comment recorded
that it *"had drifted from its own twin below"*. Both phases want "the old nodes, in
order" and differ only in the action, so the walk is shared and the action stays with each
caller. The `# expr-walker: exhaustive` marker moved with it, so `lint_expr_walkers` still
covers it — in one place instead of two. `Resolver.zbr:26` already imports from
`CgHelpers`, so a front-end phase doing this is established, not novel.

**TWO TRAPS ALREADY PAID FOR:**

1. **THE OUT-PARAM SHAPE CANNOT CROSS A MODULE BOUNDARY — RESOLVED 2026-08-17, and
   the cause is BUG-293.** Two attempts failed the same way and both hypotheses
   recorded here were wrong; the cause is that a mutated `List(T)` parameter lowers to
   `*std.ArrayList(T)` while the caller never emits the `&`, because it decides
   addr-of from the CALLEE'S BODY and the body lookup stops at the module boundary.
   See BUG-293 for the mechanism, the discriminating experiment, and the fix sketch.

   **What was wrong with the diagnosis, since the pattern repeats.** Both hypotheses
   (BUG-201, then the payload-type rewrite) were formed **without ever reading the
   error text**, because `rebuild.sh` filters it out of its log and leaves only the
   "referenced by" trace. The text was sitting in `/tmp/bs-rebuildA.err` the entire
   time and names the fault outright:
   `expected type '*T', found 'T'` at `collectOldNodes(e, _old_nodes)`. Three tool
   calls, not a third hypothesis. **Read the error before theorising about it.**

   **THE EXTRACTION HAS LANDED**, routed around BUG-293 rather than blocked on it: the
   out-param recursion (`collectOldNodesInto`) stays PRIVATE to `CgHelpers`, where
   same-module analysis already emits the `&` correctly, and the exported entry point
   `collectOldNodes(expr): List(ExprOld)` **returns** the list. Cross-module `List(T)`
   return was probed first and is clean, including the empty case. The split is
   documented at the traversal with a pointer to BUG-293, so it can be collapsed back
   into one function when that is fixed — and not before.
2. **Order is preserved but NOT because it names anything.** The `_old_N` uid is assigned
   by AstBuilder and is stable, so re-ordering would not rename snapshots — it would
   change the SEQUENCE of emitted `const` lines, i.e. a byte diff for no behavioural
   reason. Keep the order; do not sort.

**VERIFY THE EXTRACTION IS OUTPUT-NEUTRAL BEFORE ADDING THE CHECK.** Emit the four
contract fixtures (`contract_old_test`, `contract_old_compound_test`, `turbo_test`,
`contract_ident_test`) before and after and diff. **AND CONFIRM THE REBUILD ACTUALLY
SUCCEEDED FIRST** — on 2026-08-17 the diff read "identical" for all four because
`rebuild.sh` had FAILED and restored `selfhost/*.zig` from its pre-run snapshot, so the
emit was produced by the unchanged binary and compared against itself.

**LANDED 2026-08-17.** `zebra -c` now refuses it, with a real source position and a
caret, in the ~62 ms front-end class:

```
bug292_old_param_test.zbr:24:23: error: 'old n' is always equal to 'n' — a parameter
cannot change between entry and exit. Use 'old' on state the method mutates (a field),
or drop it
```

Everything owed was delivered with it:
- `test/bug292_old_param_test.zbr`, `smoke_tc_fail` asserting the MESSAGE, not merely
  that it errored — the refusal exists to teach the fix, so the text is the deliverable;
- `test/bug292_old_field_test.zbr`, the POSITIVE CONTROL: `old` on a field still
  compiles and RUNS, and it discriminates (reading at exit gives `20 == 30` and panics),
  so the refusal cannot be passing because `old` broke generally;
- **QUICKSTART §24 rewritten in the same change** — its example was the inert form and
  became a compile error the moment this landed. It now demonstrates `old` on a FIELD
  and documents the refusal, with the counterexample marked `# error:` so
  `doc_example_check` reads it as a counterexample rather than breakage.

One more inert assertion fixed on the way: `contract_old_test` was registered emit-only
(`smoke`), so nothing asserted what its contract EVALUATED. Now `smoke_run "100"`.
**A contract can be inert and still emit perfectly** — which is the whole shape of this
bug, one level up.

**THE DEFECT WAS IN TWO DOCUMENTS, AND THE GATE FOUND THE SECOND.** `STYLE_GUIDE.md`
§16.3 carried the identical example *and the identical wrong rationale* — "use `old` in
`ensure` when the parameter is mutated or shadowed inside the function" — which names
two things the language refuses. I did not look for it; `doc_example_check` failed with
`1 NEW` the moment the refusal landed and named the file.

That is the gate's whole thesis paying out. The 224 fenced blocks were unverified until
2026-08-03 precisely because nobody reads every doc when they change a rule, and a
prose claim about behaviour has no other witness. **Landing a refusal is the cheapest
time to find every document that taught the thing you just refused** — the compiler
does the search for you. Worth doing deliberately next time rather than by luck: after
any new refusal, run `doc_example_check` before assuming the doc work is one file.

**WHERE THE TRAVERSAL LIVES, and why it is not where this note originally said.** The
plan above says `CgHelpers`. That is wrong, and the note's own precedent argument is
what misled: `Resolver.zbr:26` imports `CgHelpers` safely because nothing imports the
Resolver back — but **`CgHelpers` imports `TypeChecker`**, so the same move from the
TypeChecker closes a cycle. A two-module cycle compiles and runs, so this looked
survivable; in the real compiler the bare `use` line, with no call sites at all,
produced a `zebra.exe` that stack-overflows on hello-world (**BUG-295**). `Ast.zbr` was
tried next and changed the EMIT (BUG-294's second manifestation). It lives in
**`selfhost/AstWalk.zbr`** — imports `Ast`, imported by CodeGen and TypeChecker, closes
no loop.

---

### BUG-293: a MUTATED container parameter could not be called across a module boundary — ✅ FIXED (closed 2026-08-18)

- **Severity:** Medium — loud (the generated Zig does not compile), so nothing is
  silently corrupted; but it makes a normal out-param shape unusable across
  modules, and the diagnostic points at a Zig type error rather than naming the
  cause.
- **Both compilers.** Reproduced in the selfhost and in the bootstrap.
- **Status:** OPEN. Pinned by `test/bug293_xmod_container_test.zbr` (+ its lib and
  a same-module positive control).

**Found 2026-08-17**, striking a gap rather than finding a wound: it is what blocked
BUG-292's `collectOldNodes` extraction through two attempts. Both hypotheses recorded
at the time were wrong, and for one reason — they were formed without the error text,
which `rebuild.sh` filters out of its log. The text was on disk in `/tmp/bs-rebuildA.err`
the whole time.

#### Repro (6 lines, two files)

```zebra
# lib.zbr
def fill(out: List(int))
    out.add(1)
    out.add(2)
```

```zebra
# main.zbr
use lib exposing fill

def main()
    var xs: List(int) = List()
    fill(xs)
    print("cross=${xs.len}")
```

```
error: expected type '*T', found 'T'
```

The **same call in the same file compiles and prints 2**. That control is the whole
finding: one thing varied, and it is the module boundary.

#### Root cause — two sides of one convention consulting different oracles

BUG-091's convention: a container parameter the callee MUTATES lowers to
`*std.ArrayList(T)`, and every call site must pass `&arg`.

- The **callee's** emit (`genMethod`) sees its own body, finds the mutation, and
  writes `out: *std.ArrayList(i64)`.
- The **caller's** emit asks `paramNeedsAddrOf(p, body)` — and that predicate needs
  the *callee's* body:

  ```zebra
  if body as b
      var ms: StrSet = scanMutations(b, nil)
      return ms.contains_(p.name)
  return false          # body unavailable ⇒ "no addr-of"
  ```

- §27b gave `lookupFnParams` a cross-module fallback
  (`dep_types.classOf(...).fnParamList(...)`). **`lookupFnBody` never got one.**

The selfhost mechanism above is read from the source AND confirmed by the defaulted-arg
experiment below. For the **bootstrap** what is MEASURED is the symptom — it emits the
same bare call — plus the fact that its `paramNeedsAddrOf` has the identical
`body orelse return false`. Its body lookup is `lookupCalleeBody`, which goes through
`g.resolve.exprs`; that it yields nothing for an imported symbol is *inferred from
reading*, not separately probed. Confirm before fixing that half.

So across a boundary the body is `nil`, the predicate answers `false`, and no `&` is
emitted against a pointer parameter.

**The two failure paths were discriminated, not assumed.** "params not found" and
"body not found" emit identical text for a positional call. A defaulted parameter
separates them: `def fill2(out: List(int), n: int = 7)` called cross-module as
`fill2(xs)` emits `_zbr_fn_fill2(xs, 7)` — the default *was* filled, so the parameter
list was found and only the body was missing.

Note the direction of the fallback, which is the reason this is worth writing down:
the unavailable-body case returns **false**, the answer that means "do nothing". A
silent fallback on a predicate feeding a decision biases toward "nothing changed" —
here it happened to fail loudly at `zig`, which is luck rather than design.

#### Why no gate could see it

This is an **unstruck gap**, not a wound — no corpus file passes a mutated container
across a module boundary. That is an INFERENCE rather than a survey, but a sound one:
the shape is a hard compile failure, so a corpus file carrying it would already be red
in `compile_check` (266/0/2) and `full_sweep` (0 regressions).

`divergence_check` could not have found it either, and for the OPPOSITE reason to
BUG-294's: both compilers do the identical wrong thing here. Measured classification —
the cross-module fixture is scored **multi-module (bootstrap N/A)** and excluded from
the comparison outright, and the same-module control is **agree-pass**. Neither is a
gap. BUG-294's fixture *is* a selfhost gap and turned that gate red; this one cannot.
The two bugs sit on opposite sides of that gate, which is a quick way to tell them
apart.

**A naming trap paid for here, worth one line.** The fixtures originally called their
helper `fill`, and the BOOTSTRAP scored the control as a gap — not for any reason
related to this bug, but because its INLINED preamble contains
`_pad_fill(fill: anytype)`, so a top-level `fill` shadows it (BUG-220, which the
selfhost fixed via the `_zbr_fn_` prefix). Renamed to `addTwo`. **A fixture that fails
for an unrelated reason is not a fixture** — and on the bootstrap path any common word
can collide with the 186 KB of preamble spliced in beside it.

#### Fix sketch (not implemented)

Do **not** ship whole dep bodies to the call site to re-run `scanMutations` there. The
answer is already known by the side that owns the body — the callee's own emit
computed it. The seam-correct shape is to let the decision travel with the
declaration: the type-info node already carries `fn_param_lists: HashMap(str, List(Param))`
across modules (`TypeChecker.zbr:214`), so a sibling entry recording *which parameters
need addr-of*, populated where the body is in scope, closes it without duplicating the
analysis. Must land in `src/CodeGen.zig` as well as the selfhost — the bootstrap is
the regen authority and has to compile the selfhost source.

#### Control when fixing

The paired fixtures are the control. `bug293_samemod_container_test` must still print
`bug293-same=2` (otherwise the boundary is no longer what is being measured), and
`bug293_xmod_container_test` — registered `smoke_run_fail` today — **will go red when
the bug is fixed**. That is the signal to rewrite it as a `smoke_run` asserting
`bug293-cross=2`, not to re-baseline around it.

Also verify the fix does not over-apply: a container parameter the callee does **not**
mutate must still be passed by value cross-module, or every read-only container
argument acquires a spurious `&`.


#### THE FIX (2026-08-18) — give the body the same route the param list already had

Exactly the sketch above, and it turned out to be a mirror rather than a design: the
type-info node already carried `fn_param_lists` across the boundary for §27b's
defaulted-argument fill. It now carries `fn_bodies` beside it, registered at the same
three sites (`topfn.stmts` is in scope precisely where `topfn.params` is recorded), and
`lookupFnBody` gained the cross-module fallback `lookupFnParams` has had all along.

**The alternative was rejected for a reason worth keeping.** The obvious "seam-correct"
move is to have the callee's side compute a `needs_addr_of` flag and export *that*
rather than the body. It is cheaper and it does not ship bodies around — but computing
it requires `scanMutations`, which lives in `CgHelpers`, which imports `TypeChecker`;
so the TypeChecker cannot call it without closing the cycle that **BUG-295** documents.
Shipping the body lets the decision stay where the analysis already lives (CodeGen,
which imports CgHelpers) and costs nothing at runtime: the dep AST is arena-allocated
and alive for the whole compilation, so the map holds a reference, not a copy.

**THE OVER-APPLICATION CONTROL IS THE FIXTURE THAT MATTERS.** A fix that degraded into
"any container param crossing a module boundary gets `&`" would pass the bug's own
fixture and be wrong. `test/bug293_xmod_readonly_test.zbr` calls a NON-mutating
cross-module function in the same program, and the emit discriminates exactly:

```zig
_zbr_fn_addTwo(&xs);      // mutated  -> &
_zbr_fn_sumList(xs)       // read-only -> by value
```

**SELFHOST-ONLY.** The bootstrap has the identical defect (its `paramNeedsAddrOf` has
the same `body orelse return false`, and `lookupCalleeBody` resolves through
`g.resolve.exprs`), and it is NOT fixed. The standing rule only requires the bootstrap
to COMPILE the selfhost source, which it does — round-trip byte-identical.

**A prediction I made here was WRONG, corrected by measuring.** I wrote that
`bug293_xmod_container_test` would now appear as a **bootstrap gap** in `divergence`
(selfhost leads). It does not, and cannot: `divergence` classifies both cross-module
fixtures as **multi-module (bootstrap N/A)** and excludes them from the comparison
outright, because the bootstrap's `--emit-zig` writes ONE file and cannot emit a
dependency at all. Measured: `1 agree-pass · 1 library(no-main) · 2 multi-module`,
0 gaps in either direction.

The general point, since this is the second time in two days a divergence prediction
of mine missed: **a fixture's classification is a property of the HARNESS, not only of
the bug.** BUG-294's probe was a selfhost gap and turned the gate red; BUG-293's is
invisible to the same gate — not because the bugs differ in kind, but because one
shape is single-module and the other is not. Check the classification; do not infer
it.

**The fixture pair fired as designed:** `bug293_xmod_container_test` was
`smoke_run_fail`, passing by failing to compile; it went red on the fix and now asserts
`bug293-cross=2`. Verified: round-trip byte-identical.

---

### BUG-296: a PARAMETER used only inside require/ensure is discarded and then read — ✅ FIXED (closed 2026-08-18)

- **Severity:** Medium — loud (the generated Zig does not compile), but it makes a
  perfectly reasonable contract unwritable: validating an argument you do not otherwise
  use is the *point* of `require`.
- **Status:** FIXED. Pinned by `test/bug296_param_in_contract_test.zbr` plus a
  `smoke_turbo` registration for the opposite direction.

**Found 2026-08-18** while fixing BUG-274, by a probe that was aimed at something else
and failed for a different reason than predicted — worth reading the error rather than
assuming which discard it was.

```zebra
class Counter
    var v: int = 0
    def bump(n: int)
        require
            n > 0
        v = 1
```

```
error: pointless discard of function parameter
        _ = n;
```

**Cause — the same seam as BUG-274's second gap, one over.**
`nameUsedInStmts(p.name, mstmts)` walks the method's BODY STATEMENTS, and a contract
clause is not one of them. So a parameter whose only use is in `require`/`ensure` looks
unused, gets `_ = n;`, and the emitted check then reads it.

**DISTINCT FROM BUG-272**, which is the first thing to check given how similar they
look. That one was specifically `old <parameter>` and is closed UNREACHABLE because
BUG-292 refuses it. This needs no `old` anywhere — `n > 0` in a plain `require` is
enough — so it was live and reachable the whole time.

**Fix:** at the call site, treat a name appearing in `m.require_` / `m.ensure_` as used
— **but only when `not strip_contracts`**. That guard is the whole difficulty and it is
BUG-272's lesson spent: under `--turbo` the contract is not emitted, the parameter
really IS unused, and the discard is REQUIRED. A fix that counted contracts
unconditionally would repair the default build and break turbo, which is exactly why
BUG-272 said the decision had to move to the call site rather than into the walker —
`strip_contracts` is visible there and not inside a pure helper.

**Control when fixing:** both directions, or the fix is half-tested. The fixture runs
plain (prints `bug296=1`) and is registered with `smoke_turbo` so the stripped path
stays pinned. Residual, recorded rather than hidden: the check uses
`mightUseNameInExpr`, which has no `old_` arm, so a parameter used ONLY inside an
`old(...)` sub-expression would still be missed. `old <parameter>` is refused outright,
so the reachable remainder is narrow (e.g. `old arr[n]`); it was not probed.


---

### BUG-274: broad Expr walkers default to FALSE and have gaps — `exprMentionsThis` ✅ FIXED (2026-08-18); the survey stands for the rest

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

#### exprMentionsThis FIXED 2026-08-18 — ten gaps, every one REPRODUCED first

This entry warns against working the table by counting, so none of it was. The walker
was opted into `lint_expr_walkers` to get its ACTUAL gap list, then each candidate got
a probe that was RUN:

| variant | probe result before the fix |
|---|---|
| `list_lit` `array_lit` `set_lit` `tuple_lit` `dict_lit` | `pointless discard of function parameter` |
| `slice` `type_check` `opt_chain` `lambda` `old_` | same |
| `ident` | **artifact** — `this` is its own variant (`Expr.this_`) and can never BE an ident; implicit field access is caught by the separate `bodyUsesAnyField` check. Waived with that reason. |
| `zig_lit` | **artifact** — identifiers live in a STRING (the BUG-267 shape). Waived. |

So the inflation this entry predicted was exactly 2 of 12, and the other ten were real.

**AN INSTRUMENT LIED FIRST, AND A CONTROL CAUGHT IT.** The first pass probed with
`zebra -c` and reported **0 for every variant** — including the one already known
broken. `-c` is front-end only and never invokes `zig`, so it structurally cannot see a
discard error. Re-run through a compiling path: ten of ten fired. *A probe for a
BACK-END error cannot be run through the front-end-only check mode.*

**A SECOND GAP, one level up from the walker:** `this` used ONLY inside the method's own
`require`/`ensure` was invisible, because all three checks that decide `_ = self;` walk
the BODY STATEMENTS and a contract clause is not one of them. Fixed at the call site
under `not strip_contracts` — see BUG-296, which is the same defect for a PARAMETER and
was found by a probe here failing for a different reason than predicted.

**Also fixed in passing:** the `except_` arm walked only `.base`, so
`this except v = this.n` missed the field VALUES.

**Pinned by** `bug274_this_in_expr_variants_test` (all ten shapes, each isolated so the
`bodyUsesAnyField`/`bodyUsesAnyMethod` checks cannot mask it) and
`bug274_this_in_contract_test` (+ `smoke_turbo`).

#### THE REST OF THE SURVEY, CLOSED 2026-08-18 — and its numbers had ROTTED

`exprHasTry` and `exprHasSelfCall` are now opted in too, and the outcome is **no new
arms**, which is a legitimate result and not a shrug:

| walker | survey said | actually, today | resolution |
|---|---|---|---|
| `exprHasTry` | 10 gaps | **3** | all waived with receipts |
| `exprHasSelfCall` | 2 gaps | **0** | already exhaustive (15 arms) |

**THE SURVEY'S COUNTS WERE STALE**, and re-deriving them from the lint instead of
trusting the table is what showed it — the walkers were extended between 2026-08-07 and
now. Working from the recorded numbers would have meant adding arms for variants
already handled, and this entry's own warning against working it by counting turns out
to apply to its own table.

**`exprHasTry`'s lambda gap is a DELIBERATE non-fix, and the counterfactual was RUN.**
A `?` inside a lambda body belongs to the LAMBDA's error context: the lambda is emitted
as its own error-returning function, and the enclosing body becomes throws only if it
CALLS it with `?`, which is an `Expr.try_` the existing arm already catches. Adding the
arm marks the enclosing method throws spuriously — measured by adding it and rebuilding:

```
def build(): int
    var f = def(x: int): int = mayFail(x)?
    return 7
```

went from printing `7` to `error: cannot print error union without a specifier`,
because `build()` had acquired an error union it never produces. Arm reverted, waiver
written with that receipt.

`ident` and `zig_lit` are waived on both walkers for the same reasons as
`exprMentionsThis`: these hunt a node KIND, and a bare identifier cannot BE a `try` or
a call; a raw `zig"…"` literal is opaque text.

**BUG-274 IS NOW COMPLETE.** Four broad walkers surveyed, one fixed with ten arms, two
waived-with-receipts, one already clean. Opted-in walkers 2 → 10.

Verified: round-trip byte-identical, smoke 354/354 at the time of the exprMentionsThis
fix.

---

### BUG-294: `^T` field reads lost their deref — name-keyed registries, seeded by emission order — ✅ FIXED (closed 2026-08-18)

- **Severity:** Medium — loud (the generated Zig does not compile), and **selfhost
  only**: the bootstrap emits the deref correctly, so this is a divergence in which
  the shipping compiler is the wrong one.
- **Status:** OPEN. Pinned by `test/boundary/bv_hat_deref_loopvar.zbr` plus a
  four-receiver control fixture.

**Found 2026-08-17** by the **round-trip**, and how it was found is most of its value.

#### Symptom, measured

For one line — `sumOf(o.p)` where `o` is a `for`-loop variable and `Node.p: ^Point`:

| compiler | emitted |
|---|---|
| bootstrap | `_zbr_fn_sumOf(o.p.*)` |
| **selfhost** | `_zbr_fn_sumOf(o.p)` |

`zig` then rejects it: `expected type 'T', found '*T'`.

#### It is the LOOP VARIABLE, not `^T` reads generally

Four receiver shapes deref correctly and are pinned as controls:

| receiver | emitted | |
|---|---|---|
| parameter | `o.p.*` | ✓ |
| plain local | `first.p.*` | ✓ |
| loop variable copied into a local | `copied.p.*` | ✓ |
| loop variable passed whole to a method | `viaParam(o)` | ✓ |
| **`for`-loop variable, field read** | `o.p` | ✗ |

This also explains why the construct has worked forever elsewhere in the compiler:
`^T` payloads are normally reached through a `branch … as o` binding, where QUICKSTART
documents `^T` as *transparent*. A plain `for` over a `List` of payload structs is a
shape the compiler's own source had never used.

#### SECOND MANIFESTATION — the same read, same source, different MODULE

Found later the same day, moving this traversal around for BUG-292. Identical source
text emits differently depending on whether the `^T` payload type is IMPORTED or
declared in the SAME module:

| where `collectOldNodesInto` lived | `Expr` is | emitted |
|---|---|---|
| `CgHelpers.zbr` (`use Ast exposing Expr, …`) | imported | `collectOldNodesInto(u.operand.*, out)` ✓ |
| `Ast.zbr` (declares `Expr`) | same-module | `collectOldNodesInto(u.operand, out)` ✗ |

Here `u` is a `branch … as u` binding — the shape QUICKSTART documents as transparent
and the shape the compiler relies on everywhere — so the loop-variable framing above
is too narrow. **What the two cases share is that the deref decision consults type
information that resolves differently for a same-module type than an imported one.**
Whatever the fix is, it should be verified against BOTH shapes; a fix aimed only at
the loop variable will leave this one live.

This is also why the BUG-292 traversal does NOT live in `Ast.zbr`, which was otherwise
the natural home (a leaf everyone imports, and `src/Ast.zig` hosts free helpers beside
its declarations). It lives in `selfhost/AstWalk.zbr`, which imports `Ast` — keeping
the payload types IMPORTED, i.e. the shape that emits correctly.

#### Why no gate could see it, which is the transferable part

The compiler that smoke runs is built from the **bootstrap's** emit, and the bootstrap
is correct — so the binary behaves perfectly and **smoke stayed green (343/343)** with
this defect live in the source. Only `bootstrap_check` builds selfhost-B from
**selfhost-A's own emit**, i.e. only the round-trip ever hands the selfhost's output to
`zig`. It went red immediately.

That is the round-trip's documented purpose stated in the negative, and worth keeping:
*a green smoke suite says nothing about what the selfhost emits for the selfhost.*

#### A note on the fixture, because the first draft was wrong

The controls initially failed too, which would have made the negative fixture
meaningless. Two ways this fixture can silently stop controlling:

- `o.p.x` does **not** discriminate — Zig auto-derefs field access through a
  single-item pointer, so it compiles either way. The `^T` value has to land where a
  `T` is required.
- The holder must be a **struct** with a `^Struct` payload boxed by assignment. A
  `^int` payload does not box on assignment at all, and a **class** holder brings in
  the class auto-box rule (`concept_zebra-class-auto-box-rule`) — either makes the
  controls fail for an unrelated reason.

#### Control when fixing

The four control receivers must keep printing 7 (a fix that over-applies would break
them by double-dereferencing), and `test/boundary/bv_hat_deref_loopvar.zbr` — an
`@boundary-pending BUG-294` tripwire — **goes red when fixed**, which is the signal to
rewrite it as `@boundary runs` asserting `bug294-loop=7`. Verify with the round-trip,
not with smoke: smoke runs a compiler built from the BOOTSTRAP's emit, which is
correct, so it cannot see this class at all.

**The fix is SELFHOST-ONLY.** The bootstrap already emits `o.p.*` for every receiver
shape, verified directly — so there is no bootstrap half to mirror, and the standing
rule (the bootstrap need only still COMPILE the selfhost source) is unaffected.

**Where the pin lives, and why it is not in `test/`.** As a tracked `test/*.zbr` this
probe is a SELFHOST GAP by construction, which is exactly what `divergence_check
--gate` fails on — and it turned that gate red against its 0-gap baseline. Registering
it `smoke_tc_fail` would have silenced divergence through its derived `MUST_REJECT`
list, but that list asserts *"the selfhost is SUPPOSED to reject this"*, which is the
opposite of the truth here. `test/boundary/` is outside the main corpus (0 of 482
files) and is the suite whose stated purpose is pinning known-broken behaviour as a
tripwire. **Nothing was weakened to make a gate green** — and note that BUG-293's
fixture needs none of this, because the bootstrap fails it too, so it lands as an
agree-fail rather than a gap.


#### THE FIX (2026-08-18) — one root, both manifestations

The deref decision is driven by name-keyed side tables (`ref_fields` /
`opt_ref_fields` -> `for_loop_deref` / `ptr_field_bindings`) rather than by asking the
type. Both manifestations were holes in how those tables get SEEDED, and each hole had
its own flavour of the same mistake:

1. **The loop-variable half was a hardcoded special case.** The `^T?` derivation existed
   (infer the iterable's element type, get the struct name, scan `opt_ref_fields`); the
   non-optional half did not. In its place:

   ```zebra
   if iter_member! == "entries"        # List(DictEntry)
       for_loop_deref.add(... "key")
       for_loop_deref.add(... "value")
   ```

   One field name, two hardcoded members, correct for exactly the one call site it was
   written for. Replaced by the derivation, sitting beside its `^T?` twin.

2. **The current module's fields were registered as a side effect of EMITTING the
   struct** (`genStruct`), so the answer depended on whether a function was generated
   before or after the struct it reads. Dependencies were already pre-registered via
   `populateRefFields`; the local module now is too, from `buildModuleTypes` — which
   additionally distinguishes `^T` from `^T?`, where `genStruct` put both in the
   non-optional bucket and left `opt_ref_fields` empty for local structs entirely.

**The removed special case was verified subsumed, not merely deleted.** `DictEntry.key`
and `.value` are `^Expr`, so the derivation covers them — and the compiler's own source
is full of `for entry in dl.entries`, so the ROUND-TRIP is the witness that inference
really does resolve that iterable to `List(DictEntry)`. It passes byte-identical.

**Pinned by three fixtures and a boundary probe**, and the probe is the interesting one:
`test/boundary/bv_hat_deref_loopvar.zbr` was an `@boundary-pending BUG-294` tripwire and
**fired on its own** when the fix landed ("expected the compiler to REJECT this, but it
built and ran"), which is exactly what a pending probe is for. It now asserts the intent.
Fourth pending tripwire to fire on a real fix.

`test/bug294_hat_deref_declorder_test.zbr` pins manifestation 2 — **its declaration
order IS the assertion**; tidying the structs above the functions makes it stop testing
anything.

**Verified:** round-trip byte-identical (the load-bearing one, since the compiler's own
source depends on the removed special case), boundary 29/0, controls unchanged.

---

### BUG-088: def-level `try/catch` in non-void return function falls off the end — ✅ FIXED (closed 2026-08-17)
- **Severity:** Medium (correctness — Zig refuses to compile the generated code)
- **Status:** Fixed
- **Symptom:** A method using the `def...catch` form (catch clause attached to the def itself, not a nested try/catch block) with a non-void return type fails to compile. The generated Zig has a `return` inside the success path, an unreachable `break`, then an `if (_try_err_1 != null) return ...;` afterwards — but no return on the path through both blocks where neither error occurred and the success block didn't already return. Zig errors with "function with non-void return type implicitly returns" + "unreachable code" at the orphan `break`.
- **Reproducer:** A `def f(): str` with `var v = try X()` followed by `return "ok"` and a `catch` clause returning `"err"` — see `test/bug088_try_return_test.zbr`.
- **Root cause:** `body_ends_in_break` in `genTryCatch` didn't handle `.return_` as a terminal statement; the orphan `break :_try_blk` was always emitted.
- **Fix:** `genTryCatch` now checks if the last stmt is `.return_`; if so, skips the `break :_try_blk` and emits `unreachable;` after the catch block. Both `src/CodeGen.zig` and `selfhost/codegen.zbr` updated. Also fixed `genBranch` to emit `=> |_| {` for `as _` discard on boxed union variants (was generating invalid `const _ = …`).
- **Discovered:** While writing `contract_result_throws_test.zbr` for the BUG-087 fix.

---

### BUG-231: named arguments do not parse inside `${...}` interpolation ⚠ OPEN — ✅ FIXED (closed 2026-08-17)

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

### BUG-203: explicit `@derive(Eq)` `.eql(value)` call doesn't address the value argument — ✅ FIXED (closed 2026-08-17)
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

### BUG-202: user top-level function name collides with preamble-internal parameter names — ✅ FIXED (closed 2026-08-17)
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

### BUG-123: Generated `pub fn main(init: std.process.Init)` shadows user-defined `init` function — ✅ FIXED (closed 2026-08-17)

- **Status:** Fixed (2026-05-21)
- **Symptom:** An MVU program with `def init(): Model` would fail to compile. Inside the generated `main`, the parameter `init: std.process.Init` shadowed the user's top-level `init` function.
- **Fix:** Renamed the parameter from `init` to `_zinit` in `genMain` in `src/CodeGen.zig` (4 sites) and matching locations in `selfhost/codegen.zbr` (4 sites). Both compilers regenerated. Bootstrap 5/5.

---

### BUG-122: Selfhost codegen — `opt_ptr_field_bindings` not seeded for local variables with inferred types — ✅ FIXED (closed 2026-08-17)

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

### BUG-104: Unknown `@directive` silently ignored by AstBuilder — ✅ FIXED (closed 2026-08-17)
- **Severity:** Low (typical case is benign; impacts merge-oracle and forward-compat)
- **Status:** Closed — fixed 2026-05-06
- **Resolution:** `src/AstBuilder.zig` now emits `warning: unknown @-directive '@foo'; ignored` via `std.debug.print` to stderr when an unrecognized `@name` directive is encountered. `selfhost/parser.zbr` emits the same message via `sys.errln`. Compilation continues normally; only the unknown directive is ignored. Bootstrap 5/5, smoke 44/44.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-2]).

---

### BUG-230: an ANNOTATED, NON-EMPTY list literal does not compile — ✅ FIXED 2026-07-30 (closed 2026-08-17)

> **Closed 2026-08-17, seventeen days late.** Fixed by `ccb728a` and left sitting in the
> OPEN ledger — the fourth closed-but-open entry after BUG-283, BUG-270 and BUG-271.
> `lint_stale_bugs` had it flagged (score 2, two commits claiming a fix); nobody had acted
> on the report.
>
> **Verified by RUNNING, not by reading the commit**, which is that tool's own standing
> instruction. `var nums: List(int) = [1, 2, 3]` now prints `3` under the selfhost and
> emits rc=0 under the bootstrap — both compilers, since the entry below records that both
> failed identically. Covered by `test/boundary/bv_list_literal_annotated.zbr`.
>
> Found while probing whether BUG-230 and BUG-240 were one family. They are not: of the
> seven annotated collection-literal forms, only `var s: Set(T) = {}` (BUG-240) is still
> broken. The hypothesis was wrong and the probe was still worth running.

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

### BUG-291: `<<-` copy-out of a STRING falls back to the arena-owned slice on OOM — a silent use-after-free — ✅ FIXED 2026-08-17

**Found 2026-08-17** by surveying for BUG-290's *class* (a `catch` that yields a fallback
VALUE on an error path) rather than stopping at the instance.

The whole purpose of `<<-` is to copy a value **out** of an arena into the parent
allocator so it outlives the arena's teardown. The string branch does not do that when
the allocation fails:

```zig
// src/CodeGen.zig:13664   (and selfhost/CodeGen.zbr:9836)
target = _parent_alloc_N.dupe(u8, _co_X) catch _co_X;
```

On failure it assigns `_co_X` — the **arena-owned** slice — to a target that outlives the
arena. After teardown, that target points at freed memory. Silent, and in every build
mode (unlike `unreachable`, which at least traps in Debug — the hazard
`lint_oom_unreachable` exists for).

**The evidence that this is an oversight and not a decision is six lines away, in the
same function.** The non-string branch of the same `if` already does the right thing:

```zig
target = _zbr_deep_copy(@TypeOf(_co_X), _parent_alloc_N, _co_X, 0) catch @panic("OOM copy-out");
```

Same operator, adjacent branches, opposite error handling. Both compilers carry both.

**Fix:** make the string branch match its own sibling — `catch @panic("OOM copy-out")`.

**Control when fixing:** the emitted Zig for a `str` `<<-` must contain no `catch _co_`,
and the non-string branch must be unchanged. Note the honest limit: this is an
**OOM-only** path, so no gate here can exercise it without allocation-failure injection —
verification is by emit diff and by symmetry with the sibling branch, not by a run. Say
so rather than implying it was executed.

**Class note.** A survey of emitted error paths across both compilers found 157
`catch @panic`, 31 `catch unreachable`, 53 `catch return`, 15 `catch null` — and only
**three** sites yielding a fallback VALUE: this one, BUG-290's `catch _pp` (fixed), and
`src/CodeGen.zig:3952` (`bufPrint(...) catch _s` in TUI highlight rendering, which
degrades to unhighlighted text and is a reasonable graceful-degradation, not this bug).
`hazard_lint`'s H3 covers this shape in **our tooling** but not in **emitted code**, which
is why three instances survived. A lint over emit strings would close it.

### BUG-290: `Path.absolute()` never makes a relative path absolute — it is an identity function for exactly the input it exists to handle — ✅ FIXED 2026-08-17

**Found 2026-08-17.** Measured on Windows with Zig **0.16.0**; one platform, so the
platform scope is not established.

```zebra
var dot = "."
var abs = Path.absolute(dot)
print("absolute = ${abs}")      # prints:  .
print("len = ${abs.len}")       # prints:  1
```

Both compilers emit the same thing (`src/CodeGen.zig:8136`, `selfhost/CodeGen.zbr:17170`):

```zig
(blk: { const _pp = <arg>;
        break :blk std.fs.path.resolve(_allocator, &[_][]const u8{_pp}) catch _pp; })
```

**Root cause: `std.fs.path.resolve` normalises but does not absolutise.** It does *not*
error, so nothing is being swallowed. Measured directly against 0.16.0:

| input | result | |
|---|---|---|
| `.` | `.` | **unchanged** |
| `..` | `..` | **unchanged** |
| `foo` | `foo` | **unchanged** |
| `a/../b` | `b` | normalised |
| `C:/foo` | `C:\foo` | normalised |
| `C:\foo\..\bar` | `C:\bar` | normalised |
| `C:\Windows` | `C:\Windows` | unchanged (already canonical) |

So the function works on absolute input and is an identity on relative input — which is
the only case a caller would use it for. `BUGS_FIXED.md:5169` records
`realpath (sys.cwd/Path.absolute → 0.16 API)` as closed; the API swap landed and the
**semantics change came with it, unnoticed**.

**A second, latent defect in the same expression.** `catch _pp` returns the input
unchanged on error. It is not firing here — but it means a genuine failure would be
indistinguishable from "already absolute". That is `hazard_lint`'s H3 shape (a silent
fallback on a path feeding a comparison, biased toward "nothing changed") living in
emitted code, where H3 does not look. Fix it in the same pass; do not leave a
value-returning error path behind.

**Control when fixing:** `Path.absolute(".")` must return a rooted path (`abs.len > 1`
and not starting with `.`), an already-absolute path must come back unchanged-or-
normalised, and a genuinely failing resolve must NOT return its input. All three, or the
easy wrong fix (prepend cwd unconditionally) breaks the second.

**Why nothing caught it, which is the part worth keeping.**
`test/stdlib_misc_test.zbr:33` asserts exactly this (`assert not abs.startsWith(".")`)
and has been **failing at runtime**, unseen, because the file sits in
`tools/output_baseline_excluded.txt` — the set `output_sweep` drops as nondeterministic.
It qualified for exclusion because its panic message embeds a **thread ID**, so its output
genuinely differs across the three samples. The derivation rule "output differs across
samples ⇒ nondeterministic ⇒ exclude" is satisfied perfectly by a crash, so the one gate
that runs programs automatically discards a class of the failures it exists to catch.

Nothing else covers it: the file is registered with the bare `smoke` helper (emit-only —
it does not compile or run) and sits in `full_sweep_baseline.txt` (compiles). Its panic
text even *changed* while excluded — `reached unreachable code` (2026-07-31) →
`assert failed at …:33` (2026-08-16) — with no gate reporting anything.

`arena_concurrency_hazard_test` also panics and is also excluded, but it is **not** the
same case and should not be read as one: its own header declares it a §28j HAZARD DEMO,
deliberately unregistered because it "intentionally crashes ~77% of runs", documenting the
rule that `allocate Arena()` scopes are single-threaded-only
(`docs/concurrency_allocation_design.md`). It stays excluded on its own merits — the
NUMBER of panicking threads varies run to run (measured 1, 1, 4), which is real
nondeterminism rather than a volatile field. Related to **BUG-289**, the other open
question about that same excluded set.

**FIXED 2026-08-17** in `tools/output_sweep.sh`: the thread ID is normalised like any
other volatile field (`thread <TID> panic`), so a deterministic crash stops being
mistaken for a flake. Behaviour coverage 356 -> 358; `stdlib_misc_test` and
`bug259_runtime_exit_code_test` moved into the baseline, `arena_concurrency_hazard_test`
correctly stayed out.

*(No regression fixture yet. `bug_fixture_check` does not flag that — it scopes to
FIXED bugs, so an open ticket without a fixture is invisible to it. The fixture is owed
when this is fixed, not now.)*

### BUG-271: unknown method on a builtin type is deferred to Zig but stamped `void`, so it can never return a value — ✅ FIXED 2026-08-06 (closed 2026-08-17)

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

**FIXED in `85df014`** at `tcTypeAnnotation`, which now returns `""` for `void` and lets
Zig infer. That function exists to stop Zig defaulting an untyped local to
`comptime_int` / `*const [N:0]u8` (BUG-159, BUG-173); `void` is never one of those, so the
annotation bought nothing there and could only be wrong.

**Closed 2026-08-17, nine days late, and the lateness is the point.** The fix landed with a
detailed commit and a gated fixture, and the entry stayed at the top of the OPEN ledger the
whole time — the third instance of this after BUG-283 and BUG-270. `lint_bug_numbers`'
resolved-entry leg is heading-only by design (bodies say FIXED about *other* bugs, which
scored 30 of 53 and got the check ignored), so an entry whose heading never gains a marker
is invisible to it.

**Verified before closing rather than taken on the commit's word**: emitting
`test/bug271_deferred_method_type_test.zbr` today produces **zero** occurrences of
`: void =`, and the fixture carries a `smoke_run` registration asserting `bug271: OK`, so
it has been re-checked on every smoke run since it landed.


### BUG-288: AstBuilder constructs 96 of ~146 node kinds with a ZERO span, so most diagnostics cannot say where — FIXED 2026-08-16

**FIXED 2026-08-16 across three batches. `diag_column_baseline.txt` is 18 → 0**, so the
gate has changed from a ratchet into an absolute assertion: every front-end diagnostic the
smoke suite declares must-fail can now say where. A new entry is a regression, not debt.

| batch | what | baseline |
|---|---|---|
| 1 | 7 scalar literal payloads → `^PLit` / `^PBoolLit` | 18 → 14 |
| 2 | 25 compound-expression spans **derived** in AstBuilder | 14 → 14 (+2 new fixtures, see below) |
| 3 | statement diagnostics re-anchored on their sub-expression; 3 structs given a column | 14 → 1 |
| — | `PUnionVariant` position (the last entry, a TypeRef diagnostic) | 1 → **0** |

**The scope table below was WRONG TWICE and both corrections are instructive.** It first
said "37 already carry a position" — 21 of those had a line and no column. Then batch 3
predicted adding `col` to 19 structs across 28 sites; **three needed it**. For everything
else the better anchor already existed: the sub-expression the diagnostic is *about*,
which batches 1 and 2 had just given a real position. So the fix got smaller as it went,
and the diagnostics got *more useful* rather than merely more precise — `var x: int = true`
now points at `true`, not at `x`.

**Verified by caret, not by non-zero.** The gate's own "CANNOT SEE" note says it asserts a
position was computed, not that it points at the right token — so the coordinates were
checked against the source by hand: `var x: int = true` → caret under `true`; a bare
`return` → under `return`; `var (a, b) = x` → under `x`; `item: ^Payload` → under `item`.

**And batch 2 is the method lesson.** None of the 14 entries was expression-anchored, so
it would have landed with the gate reading the same number — indistinguishable from doing
nothing. Two fixtures were written and registered BEFORE the fix, their broken coordinates
recorded, and the gate was watched going RED first. When a change's witness cannot see it,
extend the witness first and watch it fail.



**Found 2026-08-15** while trying to shrink `tools/diag_column_baseline.txt` (18
diagnostics that report column 0). The debt is not 18 problems and it is not in
the diagnostic code — it is one root cause in AST construction.

`selfhost/AstBuilder.zbr` builds nodes with `zspan()`, which is literally
`Span(0, 0, 0, 0)`, at **96 sites**, against **50** that pass a real `Span(...)`.
Every literal kind is in the zero group:

```
Expr.string_lit(ExprStringLit(zspan(), StringKind.plain, ...))
Expr.bool_lit(ExprBoolLit(zspan(), true))
Expr.if_expr(ExprIf(zspan(), cond_e, then_e, else_e))
```

So `return "hello"` in an `int` method reports `file:2:0` — a plausible-looking
coordinate that is simply wrong. It defeats caret rendering and sends an editor
to the wrong column. UNGIT "nothing fabricated".

**The blocker is one level deeper than AstBuilder, and "thread the PNode down"
is the WRONG fix — there is nothing to thread.** The parser never recorded the
position in the first place:

```
expr_int: str      expr_str: str      expr_bool: bool     expr_char: str
expr_nil: ^PPos    expr_this: ^PPos   expr_zig_lit: ^PZigLit    <- BUG-249 / BUG-284
```

A literal parse node's whole payload is its text. `buildStringLit(text: str)`
cannot pass a position on because it was never given one.

**Measured scope, derived from the union rather than counted by hand** (76 PNode
variants; the scanner asserts `PPos` positions, a scalar does not, and a bogus
name is unresolved, before reporting):

| group | count | state |
|---|---|---|
| line **and** column | 23 | fine |
| **LINE ONLY** — every `stmt_*` kind | **21** | reports `file:LINE:0` — **batch 3, where ALL 14 remaining entries live** |
| struct payload, no position at all | 25 | **BATCH 2, DONE 2026-08-16** |
| **scalar payload** — every literal | **7** | **BATCH 1, DONE 2026-08-16** |

**READ THIS BEFORE PICKING UP BATCH 3 — it holds every remaining entry.** The 14
in `diag_column_baseline.txt` break down as: **6 × `bug253_*`** (bare return,
compound assign, three destructuring forms, uninit collection — all statement
checks); **6 anchored on `dv.span`, the DECLARED VARIABLE** (`tc_mismatch_var`,
the four `tc_iface_*_mismatch`, `diag_type_mismatch`); **1 × `in_scope_tc_fail`**
(a `using` statement); and **1 × `bug078_double_box`**, which is a **TypeRef**
diagnostic and belongs to none of these groups — it needs its own look.

So batch 3 is not the leftovers, it is the remainder of the value. Batches 1 and
2 were still worth doing (see each below for what they fixed and how it was
measured), but a session picking this up for baseline movement should start at 3.

**CORRECTION, 2026-08-16.** An earlier version of this table said "37 already
carry a position" and called the work two batches. That was wrong, and wrong in
the direction that would have misled whoever picked it up: the scan asked
whether a payload has a `line` field, and 21 of those 37 have a line and **no
column**. Every statement kind is in that group, which is the actual reason the
six BUG-253 entries report `line:0` rather than `0:0` — and why
`var x: str = 42` still reports `2:0` after batch 1, since that diagnostic
anchors on `dv.span`, the declared variable, not on the expression. Isolated with
a direct probe: `return 42` gives `2:12`, `var x: str = 42` gives `2:0`.

Land each batch with the `diag-columns` baseline shrunk by the entries it clears;
that gate is the witness and it fails on growth. **A batch that lands without
moving that number has not worked**, whatever else is green.

**BATCH 2 LANDED 2026-08-16** — a COMPOUND expression carries a position, derived
in AstBuilder rather than recorded in the parser.

`return a + b` in a `str` method reported `10:0` — pointing at the indentation.
25 `zspan()` calls in AstBuilder became real spans (85 → 58 calls remaining).

**WHY DERIVE, NOT RECORD.** For every infix and postfix form the leftmost
sub-expression's start IS the expression's start, so derivation is EXACT:
`a + b` starts where `a` does, `g()` where `g` does, `xs[0]` where `xs` does.
Recording in the parser would mean capturing a position BEFORE parsing the left
operand at each precedence level — seven sites for `PBinary` alone, threaded
through control flow rather than appended to. The helper is `spanOf(e: Expr)`,
generated from the Ast union and marked `# expr-walker: exhaustive`, plus
`spanOfFirst(es)` which returns `zspan()` for an empty collection because an
empty `[]` genuinely has no sub-expression to derive from.

**THE KNOWN IMPRECISION, stated rather than hidden.** For PREFIX and BRACKETED
forms the derived span points at the first sub-expression, not the opening token:
`-x` reports `x`, `[1, 2]` reports `1`. That is off by a token. It is not a
fabrication — it points inside the expression the diagnostic is about, where
`10:0` pointed at the indentation. Exact opening-token spans are a later pass and
nothing in the baseline needs them.

**THE WITNESS HAD TO BE BUILT FIRST, and that is the transferable part.** None of
the 14 baseline entries is expression-anchored, so this batch would have landed
with the gate reading exactly the same number — indistinguishable from having
done nothing. Two fixtures were therefore written and registered BEFORE the fix,
with their broken coordinates recorded (`bug288_binary_span_fail` 10:0,
`bug288_call_span_fail` 11:0); the gate correctly went RED on 2 new position-less
entries; the fix took them to **10:12 and 11:12** and the gate back to 14 with
**51 candidates instead of 49**. Coverage grew, debt did not. Two fixtures rather
than one because binary derives from an operand and a call from its callee — a
fix to either does not imply the other.

Verified: QUICK **22/22 in one invocation**, smoke **337/337**, round-trip
byte-identical.

**BATCH 1 LANDED 2026-08-16** — the seven literal variants now carry `^PLit`
(text) or `^PBoolLit` (value), each with line and col. `diag-columns`
**18 → 14**, baseline diff 4 deletions / 0 insertions. Cleared:
`bug106_heterogeneous_list_test` (which reported `0:0` — no position at all),
`tc_mismatch_guard_test`, `tc_mismatch_return_test`, `tc_mismatch_with_test`.
Verified QUICK 22/22 in one invocation, `output_sweep` 356 files behaviour
identical, `compile_check` 260/0/2, round-trip byte-identical.

Two decisions worth keeping. The synthesized `true` in the `for`-in desugaring
keeps `Span(0,0,0,0)` on purpose — the user never wrote it, so "no position" is
the true statement, and minting a `(line, 0)` there would add a fresh instance of
the invented coordinate the batch exists to remove. And the arithmetic check
caught its own instrument: `zspan()` **calls** in AstBuilder went 92 → 85, the 7
predicted, while a raw `grep -c 'zspan()'` said 96 → 90 because it counts lines
and the new comments quote the word. Count calls, not mentions.

**Groundwork already landed** (`selfhost/TypeChecker.zbr`, this session):
`exprSpanLine`/`exprSpanCol` read only 7 of 35 Expr variants and fell through to
0 for the rest. They now name all 35 and carry `# expr-walker: exhaustive`, so
the gate holds them complete. That change is **inert today by itself** — it
reads spans that are still zero — and was landed as the interface this fix needs
rather than as a fix. Do not read the widened walkers as having moved any
baseline entry; they did not.

**Measuring it.** `python tools/lint_diag_columns.py` is the witness; 18 entries
baselined. The three families there are 9 × `type mismatch: expected X, …`,
6 × the BUG-253 statement checks, and 2 reporting `0:0` (no position at all).
The first family alone is over half the debt and all four of its emit sites are
in `TypeChecker.zbr` around lines 3398–3680.

### BUG-282: `--output-dir` at a path that does not exist PANICS instead of refusing — ✅ FIXED 2026-08-14

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

**FIXED 2026-08-14 — created and ANNOUNCED, which is a third answer the ticket did not
list.** It framed this as create-or-refuse. Both beat a panic and each alone fails one
half of UNGIT: refusing is pure friction when the fix is a `mkdir` the tool could have
done (a refusal that can be worked around must price the workaround), and creating
silently means a typo'd `--output-dir /tmp/oputput` quietly builds a junk tree and says
nothing. Creating **and saying so** costs nothing and hides nothing — a mistyped path is
visible on the line that reports it.

Checked at ARGUMENT-PARSING time rather than at first write, which is the "declarations
are checked when declared" clause the ticket cited: the flag is known at startup, so the
failure no longer arrives three phases later behind `parsed OK` / `resolved OK`.

**SELFHOST-ONLY BY CONSTRUCTION, so the ticket's "both compilers need whichever answer
wins" is resolved rather than deferred:** `zebra-bootstrap --output-dir` answers
`unknown flag '--output-dir'`. The bootstrap has no such flag to fix.

**Control:** two legs in `tools/runtime_module_check.sh`, the gate that already drives
this flag — a CLI behaviour no `test/*.zbr` can carry, so smoke cannot see it. Leg 1: a
missing path is created, the creation is announced, `hw.zig` lands in it, and no `panic`
appears. Leg 2: an existing path stays SILENT — a fix that announced on every run would
be its own regression. Both assert on the PRINTED MESSAGE, never the exit code, as the
ticket instructed (the old panic exited 3, and 3 is produced by unrelated failures too).
The two legs run the same grep with opposite expectations on real data, which is a
stronger discrimination proof than a synthetic red.

### BUG-286: a class inside a `namespace` cannot be CONSTRUCTED through the namespace — ✅ FIXED 2026-08-14

**Found 2026-08-12** while widening `tools/fixtures/bug281_typename_sites_probe.zbr` for
BUG-281 B — i.e. by a probe, not by reading, which is the third time in this ticket
family that the probe found what reading did not.

```zebra
namespace ZqNs
    class ZqInner
        var k: int = 0

def main()
    var ni = ZqNs.ZqInner()      # error: type 'type' not a function
```

**Pre-existing, and it is NOT a BUG-281 B regression** — established with the control
rather than assumed: the same probe was run against the unmodified codegen (stash the
CodeGen change, `rebuild.sh --module CodeGen`, emit) and it failed there too, with
`error: type 'type' not a function` instead of the prefixed-name error the changed
compiler gives. Two different messages, one shape: the construction never worked.

The DECLARATION side is fine — the namespace emits `pub const ZqNs = struct { pub const
ZqInner = struct {…} }` and BUG-281 B correctly prefixes the inner class inside it. What
is missing is the call path: `genCall`'s class-constructor branch matches a bare
`Expr.ident` callee, and `ZqNs.ZqInner` arrives as an `Expr.member`, so it never reaches
the `.init()` rewrite and the emitted Zig tries to call the type.

**Also unprefixed, and deliberately so for now: the namespace NAME itself.** A
`namespace opaque` still emits `pub const opaque = struct`, so the BUG-281 family-B
hazard survives for that one declaration kind. It was left out because a namespace's
qualified reference path is the very thing broken here — fixing the name without the
path would be untestable.

**Control when fixing:** the probe's `ZqNs.ZqInner()` line (commented out, with a
pointer to this ticket) must compile AND run, and `namespace opaque` containing a class
must build — the second is what makes it a BUG-281 fix rather than only a dispatch fix.

**FIXED 2026-08-14, BOTH halves.** The ticket named a construction defect and, separately,
that the namespace NAME was still unprefixed — deferring the second because "a namespace's
qualified reference path is the very thing broken here, so fixing the name without the
path would be untestable." Landing the path made the name testable, so both went together.

**Half 1 — construction.** `genCall` now has a namespace arm ahead of its bare-ident
constructor branch, guarded on a new `namespace_names` set. A class emits
`Ns._zbr_ty_Cls.init(args)`; a plain struct with no cue init takes the LITERAL path
instead, which is the same split the top-level constructor branch already makes and would
have been easy to miss with only a class in the probe.

`namespace_names` is populated in the PREPOPULATION loop, not at emit time, along with
the classes and structs declared inside — registering at emit time would have made the
answer depend on whether a namespace happens to precede its first use in the file.

**Half 2 — the name.** ESCAPED, not prefixed, and the asymmetry with BUG-281 B is the
point: a namespace is a SCOPE whose name reaches a handful of emit sites, and `@"opaque"`
is the same identifier to Zig as `opaque`, so every non-keyword namespace emits
byte-identically to before. A TYPE name is at file scope with references throughout
codegen, which is what made a prefix worth its wider cost there. Sites: the declaration in
`genNamespace`, the two emits on the new constructor arm, and `typeZigName`'s dotted HEAD.

**One trap worth recording.** `tns.name.split(".")` emits a Zig `SplitIterator`, which
does not index — `.at(0)` fails to compile. `genNamespace` two screens away already
annotates `var parts: List(str) = ns.name.split(".")` for exactly this reason.

**Control:** `test/bug286_namespace_ctor_test.zbr` (registered `smoke_run`) — a namespaced
class constructed through the namespace (90), a namespaced STRUCT (10), and the same
through a namespace named `opaque` (6). `tools/fixtures/bug281_typename_sites_probe.zbr`
also had its `ZqNs.ZqInner()` line commented out with a pointer to this ticket; it is
live again and runs.

**Cost:** the fixture is a BOOTSTRAP GAP by design — half 2 is selfhost-only, and
`divergence_check` gates on selfhost gaps.

### BUG-283: a `zig"..."` literal has no way to NAME a Zebra type except by guessing the emitted spelling — ✅ FIXED 2026-08-12

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
`union_names`), so resolution is available; what is missing is the substitution and a
refusal for a name that does not resolve.

**MEASURED 2026-08-12 — the syntax space is FREE, and this is a smaller change than it
looks.** `${...}` inside a `zig"..."` is **not** interpolated and **not** rejected: it is
raw passthrough. `zig"@as(i64, ${v})"` parses, resolves, and emits `@as(i64, ${v})`
verbatim, which then fails in `zig` as `expected expression, found 'invalid token'` —
reported against the *Zebra* line via the `// zbr:` markers. So:

- **No lexer or parser change is needed.** The text already arrives intact at
  `CodeGen`'s `on Expr.zig_lit` arm, which is a single `w.emit(zl.text)`.
- **Nothing existing can break**, because any current `${...}` in a zig literal is
  already a hard error downstream.
- **`zebra -c` accepts it and writes a `.zig` anyway** — another instance of check-mode
  being front-end-only, so `-c` cannot be the control here.

**And it makes the refusal load-bearing rather than a nicety.** Today a typo'd
`zig"${Countr}{}"` emits `${Countr}` and dies inside Zig. If the substitution ships
*without* the refusal, a typo produces **exactly the same failure as today** — so the
feature would look implemented while the case it exists to fix is untouched.

**BOTH HOOK POINTS ARE CONFIRMED TO EXIST, with the data already in scope:**

| | where | what is there |
|---|---|---|
| substitution | `selfhost/CodeGen.zbr`, `on Expr.zig_lit as zl` | one line, `w.emit(zl.text)` |
| refusal | `selfhost/TypeChecker.zbr`, `inferExpr` | **has no `zig_lit` arm at all**, so the case is additive; `InferCtx` carries `module_types` (type knowledge) *and* `errors` (`Diagnostic(file, line, col, msg)`), and `ExprZigLit` carries a `span` |

So the refusal can be a real located Zebra diagnostic rather than an `@compileError`
emitted into the output — which matters, because `@compileError` fires at *Zig* time and
would be indistinguishable from the untouched status quo.

**FIX THIS BEFORE BUG-281 B, not after.** They look coupled and are not. Landing the
substitution first means the three corpus literals migrate while the old spelling still
works, so the prefix commit that follows breaks nothing at all and needs no deprecation
story. Landing the prefix first breaks every `zig"Type{}"` in existence with nothing to
migrate *to*. Same two commits, opposite user experience.

**Control when fixing:** the three corpus literals migrated to the new form must still
produce a working program, AND an unknown name must be REFUSED with a Zebra diagnostic
naming it. A substitution that silently passes through an unrecognised name would restore
exactly the ambient guess this exists to remove — and it would do it invisibly, since
`zig"..."` contents are what no lint here can read.

**Verify the refusal by MAKING IT FIRE, not by reading the code.** `zig"${Countr}{}"`
must fail at Zebra compile time naming `Countr`; if it instead emits `${Countr}` as text
and dies inside `zig`, the check is not doing its job even though the build is red.

**FIXED 2026-08-12 (`9d2beb1`), and MOVED HERE 2026-08-14 — it sat in the OPEN ledger for
two days after it shipped.** Recorded because of WHY no gate noticed:
`lint_bug_numbers`' resolved-entry leg is HEADING-ONLY by design (bodies routinely say
FIXED about other bugs, which scored 30 of 53 and is a noise ratio that gets a gate
ignored), and this heading never gained a FIXED marker. So a fixed entry whose heading is
never stamped is invisible to that check. The cost is real but bounded: BUGS.md answers
"what is left to work on", and for two days it over-reported by one.

**A GATE FOR THIS WAS CONSIDERED AND MEASURED AWAY — do not re-litigate without new
data.** The obvious oracle is "an OPEN bug that already has a REGISTERED, passing fixture
is suspicious", which describes BUG-283 exactly. Run against the ledger on 2026-08-14 it
flags **six** open bugs, and all six are legitimately open: fixtures that pin
known-BROKEN behaviour, the BUG-106 role conflict, and umbrella entries. That is zero
true positives and six waivers — a gate that would be entirely baseline on the day it
shipped, which is the ratio `doc_example_check`'s header warns gets a gate suppressed
wholesale. The existing "NOT checked" line on `lint_bug_numbers` already discloses the
limit, which is the honest alternative to a noisy check.

**What shipped:** `zig"${Name}"` inside a zig literal resolves to that type's current
emitted spelling, so an escape hatch ASKS instead of guessing. `emitTypeRefName` in
`selfhost/CodeGen.zbr` is the single place the spelling is decided — which is what let
BUG-281 B rename every type to `_zbr_ty_<name>` a day later at zero cost to users.

An unknown name is REFUSED by the TypeChecker with a located Zebra diagnostic rather than
passed through to die inside `zig` — the load-bearing half, since passing it through
would have failed identically to the pre-feature behaviour and every test would still
have passed.

Selfhost-only: the bootstrap passes `${...}` through verbatim.

**Pinned by** `test/bug283_zig_lit_typeref_test.zbr` (`smoke_run`) and
`test/bug283_zig_lit_unknown_type_fail.zbr` (`smoke_run_fail`), both registered and
passing since the day it landed.

### BUG-249: `Expr.this_` (and friends) carry a PLACEHOLDER span, so diagnostics report 0:0 — ✅ FIXED 2026-08-14

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

**FIXED 2026-08-14, and it was much smaller than this entry feared.** The ticket called it
"structural, not local — touches every construction and match site for that variant." The
actual count is **three construction sites and three match sites**, because `nil`, `this`
and `result` are single tokens that appear in exactly one parser arm each. Reading the
ticket would have deterred the work; counting the sites took one grep.

All three now carry a shared `PPos { line, col }` payload, captured from the token BEFORE
`.advance()` and read by `AstBuilder` in place of `zspan()`. One struct rather than three
near-identical ones: they carry the same thing for the same reason.

**Control — the reference implementation's own answer.** The selfhost now reports
`bug108_this_outside_class_test.zbr:6:13`, which is byte-identical to what
`zebra-bootstrap` reports for the same file, and line 6 is `    var x = this` with `this`
at column 13. The existing `smoke_tc_fail` expectation was tightened from the message
alone to the full `file:6:13: error: …` string, so a regression to `0:0` fails the gate;
that also pins selfhost/bootstrap agreement on the LOCATION, not just the wording.

`result` verified the same way: `var y = result` outside an ensure reports `2:13`.

**HONEST LIMIT — two of three are verified by observation, not three.** No diagnostic
anywhere in the front end anchors on `Expr.nil_` (checked: no `addErr` in TypeChecker or
Resolver references it), so its span has no observable consumer today. It carries the same
payload by the same code path, but that is reasoning rather than measurement, and the
first check anchored on a `nil` node is what will actually confirm it.

**Related and still open: BUG-121** (TC diagnostics report col 0) — a different cause,
in span resolution rather than in the parser.

### BUG-269: `extern def` returning `str` lowers to `[]const u8`, which is not a legal C-ABI return type — ✅ FIXED 2026-08-15

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

**FIXED 2026-08-15 — REFUSED at the declaration, not remapped.** Zebra's `str` is a slice
(pointer + length) and C has no such type, so the parser now rejects it in an extern
return or parameter, naming the reason and the fix:

```
error: `str` is not a C-ABI type in an `extern` signature (return type of `c_version`):
       Zebra's `str` is a slice (pointer + length) and C has no such type. Write `^byte`
       for a C `char*`, then `zig"std.mem.span(...)"` to read it back as a str.
```

Same family, same place and same shape as BUG-270's `int` check — at the DECLARATION, in
the parser, because that is where the author wrote it.

**Not silently remapped to `[*:0]const u8`, and that was the real decision.** A remap
would make the declaration legal and then hand the caller a null-terminated pointer while
the type system still called it a `str` — the silent-corruption shape BUG-270 exists to
prevent, and strictly worse than the compile error it replaces.

**THE PROBE LIED FIRST, and the reason is worth keeping.** The obvious reproducer —
declare `extern def cfn(): str` and compile — reported that `zig` ACCEPTED it, for the
broken form AND the working one. `zig` analyses an `extern fn` LAZILY, so a declaration
that is never CALLED never reaches the calling-convention check. Adding a call reproduced
the ticket's error verbatim. A probe that does not reach the failing path answers with
the reassuring result.

**Control is a PAIR, and the second half is the one that makes the refusal honest:**
`bug269_extern_str_fail.zbr` pins the refusal (return AND parameter), and
`bug269_extern_cstr_test.zbr` pins that `^byte` — the fix the message names — really
lowers to `*u8`, is accepted by `zig` in a C-ABI signature, and that ordinary `int32`
externs still compile and run. A refusal whose suggested fix does not work is advice
pointing nowhere, and only the positive fixture catches that.

### BUG-270: `extern def` returning `int` lowers to `i64` against C's `c_int` -- negative returns silently corrupt — ✅ FIXED 2026-08-06 (`e8c68e7`), ledger corrected 2026-08-15

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

**THIS ENTRY WAS ALREADY FIXED AND SAT IN THE OPEN LEDGER FOR NINE DAYS.** `e8c68e7`
landed the refusal — `int`/`uint` in an extern signature are rejected with a message
naming `int32` for C `int` and `int64` for C `long long` — with two registered fixtures
(`bug270_extern_int_fail.zbr`, `bug270_extern_int_ambiguity_test.zbr`) passing ever since.
Found 2026-08-15 by picking BUG-270 up to work on it and discovering the compiler already
refused the case.

**Second instance of the same ledger failure in two days** (BUG-283 was the first), and
the same cause: `lint_bug_numbers`' resolved-entry leg is HEADING-ONLY by design, so an
entry whose heading never gains a FIXED marker is invisible to it. The measured cost is
now concrete rather than theoretical — BUGS.md over-reported the open set, and someone
picked a fixed bug to work on.

A gate for this was measured and declined on 2026-08-14 (see BUG-283): the obvious oracle
flags six legitimately-open bugs and zero real ones. That verdict stands, but the tally is
now two misses, which is worth re-weighing if it happens again.

### BUG-244: `zebra <file>` leaks a ~20 MB executable into TMPDIR on every run — ✅ FIXED 2026-08-15

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

**FIXED 2026-08-15, taking BOTH decisions this entry said to make first.**

1. **Kept on failure.** The scratch `.zig` and binary are removed only after a CLEAN
   exit. If the program dies, those two files ARE the debugging evidence and deleting
   them would take away the one thing worth looking at.
2. **`--keep-temp`** opts out entirely, and is listed in `--help` rather than being a
   flag you have to know about.

**BOTH run paths, not one.** The fast (`-fno-llvm`) path and the LLVM path each build and
run their own executable; the LLVM branch is taken by any program with a C dependency,
sqlite, an `extern`, or `--release`, so fixing only the fast path would have left half the
leak in place and looked fixed on a hello-world.

**Control — three legs, and two of them are the ones that stop this becoming a fix that
eats evidence:** a successful run leaves 0 files; a FAILING program leaves 2; `--keep-temp`
leaves 2 even on success. Gated in `tools/runtime_module_check.sh`, which already hosts
BUG-282 for the same reason — this is CLI behaviour that no `test/*.zbr` can carry.

**The gate asks the compiler WHERE it wrote instead of assuming.** This entry already
records the trap that cost a first attempt: `zebra.exe` is a Windows binary reading
`TMP`/`TEMP`, while Git Bash sets `TMPDIR` to the MSYS mount `/tmp`, so a check reading
`$TMPDIR` watches the wrong directory and reports a clean ~20 MB while 120 GB sits
elsewhere. The leg derives the directory from a `--keep-temp` run and refuses if it cannot
find it, rather than reporting a pass it did not earn.

**THE FIRST VERSION OF THIS FIX WAS WRONG, and `contract-mode` caught it.** It deleted
the scratch build after any clean run — including when the user passed `--output-dir`,
which is not scratch at all but the output they explicitly asked for.
`contract_mode_check.sh` runs `--turbo --output-dir DIR` and then READS the emitted
`.zig`, and its two `--turbo` legs went blind with "emit produced no .zig".

**Which legs failed is the instructive part.** Only the ones where the program EXITS 0 —
because `--turbo` strips the contracts, so nothing fires. The `default` and `--release`
legs passed *only* because their contracts failed and the non-zero exit happened to take
the keep-on-failure branch. A gate can be green for a reason unrelated to what it asserts.

Cleanup is now guarded on `output_dir == ""`, and `runtime_module_check.sh` carries a
third leg pinning that `--output-dir` output survives a successful run.

**AND `release-mode` was silently living off the leak.** It runs `zebra --release rel.zbr`
and then measures the resulting binary's SIZE — evidence the compiler now removes. It
failed honestly ("the size check could not run, so this gate knows NOTHING about the
optimize flag"), which is exactly the refusal its header promises instead of a vacuous
pass. Fixed by passing `--keep-temp`: the gate deliberately inspects a scratch artifact,
so asking for it is the honest version of the dependency it already had.

**Two gates broke on this fix, and both were RIGHT to.** They were the only consumers of
an artifact nobody had decided should persist. That is the real cost of a leak nobody
measured: things quietly come to depend on it.

**Not retroactive:** the ~28 GB already on disk at fix time stays until
`bash tools/tidy.sh --clean` removes it. This stops the bleeding; it does not clean the
wound.

### BUG-121: TC diagnostics always report col 0 — span resolution needed — ✅ FIXED 2026-08-15 (checkExpr); the wider class is now GATED

- **Severity:** Low (correct file:line, wrong column — usable but imprecise)
- **Status:** Open — deferred; noted in `checkExpr` with a TODO comment
- **Symptom:** All type-mismatch diagnostics emitted by `checkExpr` and `checkVarDecl` report column 0. The format `file:line:0: error: type mismatch: ...` is technically valid but unhelpful for editors and users.
- **Root cause:** Statement spans record the keyword position (e.g., the `return` token or `var` token), not the expression start. Column within the line is stored as 0 in most spans because the parser does not yet thread byte-offset-within-line into `Span.col`.
- **Proper fix:** Thread a true column (byte offset from start of line) into `Span` during tokenization. The tokenizer tracks `col` via `_col` already in `Lexer.zbr`; it needs to be passed through `PExprId` → `Span` in the ASTBuilder rather than defaulting to 0.
- **Where noted:** `selfhost/typechecker.zbr` `checkExpr` — `TODO BUG-121` comment.
- **Filed:** 2026-05-09


---

**FIXED for `checkExpr` 2026-08-15, and it needed NO tokenizer work** — contrary to this
entry's "proper fix" note, which predates the spans that now exist. The EXPRESSION already
knew where it was: `exprSpanLine`/`exprSpanCol` were built for BUG-218 and cover
ident/member/call, and BUG-249/284 added `this`/`nil`/`result`/zig-literals (all four are
now wired into those accessors too). `checkExpr` prefers the expression's own position and
falls back to the statement's, so an expression kind with no span is no worse off.

    before   zz.zbr:3:0:  error: type mismatch: expected int, got str
    after    zz.zbr:3:12: error: type mismatch: expected int, got str   (`return s`)

**Controls:** a call-argument mismatch that ALREADY reported a real column (`5:20`) is
unmoved, and BUG-249's pinned `6:13` still holds. Parameters emit as Zig `const`, so the
derived position goes in locals rather than reassigning `line`/`col` — the first attempt
failed to build on exactly that.

**THE CLASS IS WIDER THAN THIS TICKET AND IS NOW MEASURED RATHER THAN GUESSED.** A census
over the corpus found **18 more fixtures** whose front-end diagnostic still reports column
0, from other reporting sites: branch exhaustiveness, bare `return`, compound assignment,
destructuring arity, heterogeneous list literals, interface mismatches. Two report `0:0`
with no line at all.

Rather than chase them one at a time, `tools/lint_diag_columns.py` (QUICK tier) now
BASELINES the 18 and fails on NEW ones. Its candidate set is DERIVED from the smoke
suite's own must-fail registrations, it prints its denominator on every path, and it
refuses if no must-fail fixture produces a parseable diagnostic. **Three bugs of this
shape were fixed in two days and nothing here could have caught any of them** — a
golden-output gate does not assert positions and a compile gate cannot see them. Shrink
the baseline; do not grow it.

### BUG-287: a bare sibling-method call resolves to a same-named CLASS instead of the method — ✅ FIXED 2026-08-14

**FIXED 2026-08-14.** `genCall`'s class-constructor branch is now guarded by
`ctor_shadowed` — true only when the callee names BOTH a visible type and a method of the
current owner. Inside a method a bare name is a sibling member before it is a global
type, which is the rule every other bare-name path already follows (a field beats a
module var; a local beats a top-level fn).

**Written as a guard rather than a reordering, deliberately.** The guard can only fire
when a type and a sibling method share one name, so every ordinary constructor call takes
exactly the path it did before. Reordering the branches would have passed the obvious
test and broken every constructor call in the corpus — which is what the ticket's second
control leg exists to catch, and `test/bug287_sibling_method_shadow_test.zbr` carries
both: 113 (the sibling method wins) and 42 (a class with no same-named method still
constructs).

**Found 2026-08-13** writing the fixture for the `error`/`try` freeing, by a shape that
had never existed before: a class named `error` in the same file as a method named
`error`.

```zebra
class Widget
    var n: int = 1

class User
    var base: int = 3
    def Widget(): int
        return .base + 10
    def callsIt(): int
        return Widget() + 100        # emits `_zbr_ty_Widget.init() + 100`
```

The bare call inside a method resolves to the **class constructor**, not to the sibling
method, and the program fails to compile with `unused function parameter` — because
`self` is then never read. The message points at the wrong thing entirely.

**Keyword-independent and pre-existing, established with the control rather than
assumed.** The reproducer above uses ordinary names; it was reduced from the keyword
version specifically to check whether freeing `error` had caused it. It had not — in
`genCall`, the class-constructor branch (`class_names.contains_(id.name)`) is tested
*before* the owner-method branch (`isOwnerMethod(id.name)`), so the collision predates
both this work and BUG-281.

**Which should win is not in doubt.** Inside a method, a bare name is a sibling method
before it is a global type — that is ordinary lexical scoping, and it is what every
other bare-name path in `genIdentRaw` already does (a field wins over a module var; a
local wins over a top-level fn). The constructor branch is simply tested too early.

**Why nothing found it before:** it needs a class and a method sharing one name in one
file, which no corpus program does. Note it is NOT the same as a field and a method
sharing a name — that one is caught cleanly at the Zebra level (`duplicate struct member
name 'error'`) because they collide inside a single struct.

**Control when fixing:** the reproducer above must print 113, AND a program with a class
but no same-named method must still construct it — reordering the branches without that
second leg would break every constructor call in the corpus.

### BUG-285: `inferExpr` visits an expression twice, so its diagnostics print twice — ✅ FIXED 2026-08-14

**FIXED 2026-08-14 — and the ticket's hypothesis was WRONG, which is the useful part.**
It guessed this was "almost certainly not specific to zig literals" and that *any*
inferExpr diagnostic would double, with a wide blast radius. Measured instead of
assumed: `'x' is private` and `tuple index out of bounds` — both raised from inferExpr —
print **once**. So the wide hypothesis is refuted.

**The real rule is narrower and stranger: it doubles in the VAR-INIT POSITION only.**
`var v = b.secret` printed the private diagnostic twice; `print(b.secret)` printed it
once. Statements are walked twice — `walkStmt` binds, `checkStmts` checks — and BOTH
call `inferExpr` on an un-annotated `var`'s init purely to compute a type to bind.

Fixed **at the visit, not at the message**, exactly as the ticket required: `checkStmts`'
bind-inference now runs with `InferCtx.quiet_errors` set, because `walkStmt` has already
reported on that same expression. The error list is NOT deduplicated by value — two
identical typos on one line are two real problems, and collapsing them would hide the
second.

**Control, with the leg that matters being the one that must NOT change:** the two
doubling cases drop to 1, and `print(b.secret)` and the tuple case stay at 1 rather than
falling to 0. Pinned by `test/bug284_zig_lit_span_fail.zbr` via a new
`smoke_run_fail_once` helper — plain `smoke_run_fail` uses `grep -qF`, which is true for
one occurrence and for two, and is why this survived so long unnoticed by any gate.

**Found 2026-08-12** by BUG-283's refusal appearing verbatim two times for one typo:

```
bad.zbr:0:0: error: no Zebra type named 'Countr' — ...
bad.zbr:0:0: error: no Zebra type named 'Countr' — ...
```

Harmless for a `grep -qF` gate, which is why `smoke_run_fail` passes on it, and ugly for
a person, who has to decide whether they have one problem or two.

**This is almost certainly not specific to zig literals** — it is the type checker
inferring and then checking the same node, and *any* diagnostic raised from `inferExpr`
would double. BUG-283's is simply the newest one, and possibly the first raised from that
function on a path that runs twice. **Before fixing, check whether existing `inferExpr`
diagnostics already double**; if they do, this is a long-standing wart with a wider blast
radius than one message, and the fix belongs at the visit, not at the message.

**Do not fix it by deduplicating the error list.** Two genuinely distinct problems can
share a file, line, column and message — two identical typos on one line, for instance —
and collapsing them would hide a real second defect to tidy a cosmetic one.

### BUG-284: a `zig"..."` literal has NO source position, so its diagnostics say `0:0` — ✅ FIXED 2026-08-14

**FIXED 2026-08-14.** `PNode.expr_zig_lit` went from a bare `str` to a `^PZigLit`
carrying `text`/`line`/`col`, set at the parser's token and read by `AstBuilder` in place
of `zspan()` — the same treatment `PExprId` already had, which is the precedent the
ticket named.

**Control, both legs:** `bug283_zig_lit_unknown_type_fail.zbr` now reports `14:13`
instead of `0:0`, and a file with TWO bad literals reports **5 and 7** — different lines,
which a hardcoded constant cannot produce. That second leg is why the regression fixture
carries two literals; the ticket's own warning was that a single-literal test passes just
as well against a hardcoded value.

**Found 2026-08-12** implementing BUG-283, whose refusal is the first diagnostic ever
attached to a zig literal — which is how nobody noticed.

```
bad.zbr:0:0: error: no Zebra type named 'Countr' — ...
```

`AstBuilder` builds every zig literal with `zspan()`, and `zspan()` is literally
`Span(0, 0, 0, 0)`. The parser *has* the position — it is holding the token at
`Parser.zbr:3044` — but `PNode.expr_zig_lit` is declared as a bare `str`, so the line and
column are dropped on the floor between the two.

**Why it matters beyond tidiness.** A diagnostic that cannot say *where* fails the UNGIT
"nothing fabricated" test twice over: `0:0` is not unknown-spelled-as-unknown, it is a
**plausible-looking coordinate that is simply wrong**, and it defeats caret rendering,
which reads line/col to quote the source. In a file with several zig literals the reader
is told only that one of them is bad.

**The fix has precedent in the same file.** `PNode.expr_id` already carries `name`,
`line` and `col`, and the Resolver uses them (`fmtErrAt(id.line, id.col, …)`). So the
change is to give `expr_zig_lit` the same treatment: a payload with `text`, `line`, `col`,
set at `Parser.zbr:3044` from the token, and read in `AstBuilder.zbr:840` in place of
`zspan()`. Two construction sites, one declaration.

**Control when fixing:** `bug283_zig_lit_unknown_type_fail.zbr` must report the real line
of its `zig"${Countr}…"`, and a file with TWO bad literals must report two DIFFERENT
lines — a single-literal test passes just as well with a hardcoded constant.

### BUG-278: `result` nested in a slice / `?.` / `except` inside an ensure emitted an undeclared `_result` — ✅ FIXED 2026-08-08

**Found 2026-08-08** working BUG-274's list the way that ticket prescribes: find the
consumer, work out what a wrong FALSE would produce, and try to produce it.

`containsResultRef` decides whether `genEnsureBlock` emits `var _result: T = undefined;`.
`genExpr` emits `_result` for every `Expr.result_` it reaches, unconditionally. So a
variant the walker did not model produced a reference to a local that was never declared:

```
def head(s: str): str
    ensure
        result[0..1] == "a"
    return s
```
```
error: use of undeclared identifier '_result'
```

Three of the four candidate variants reproduced — `slice`, `opt_chain` (`result?.n`) and
`except_` (`(result except n = 1).n`). The fourth, `lambda`, is now handled without a
reproducer, because the AST says the variant holds an expression and that is the entire
standard the lint applies; its statement body is waived in place with a reason rather
than silently defaulted.

**THE FAILURE MODE IS LOUD, which grades this differently from BUG-260.** An undeclared
identifier is a hard Zig error, so no program silently did the wrong thing — but the user
sees it against *generated* code, with no Zebra source location, for a contract they wrote
in three legal tokens. That is the right severity to record: real, not silent.

**The twin had already drifted.** `collectAndEmitOldSnapshots` walks the same shape for
`old()`, with the same consumer pattern (`_old_N` emitted unconditionally, declared only
where the walker looks). It handled `slice` and `except_`; `containsResultRef` did not.
Two hand-maintained parallel walkers, diverged, exactly as rule 1 predicts. Fixing one and
shipping would have been this session's second-`@import`-site mistake a second time — the
sibling was found by diffing the two arm sets before editing either, not by luck.

Both now carry `# expr-walker: exhaustive`, so `lint_expr_walkers` keeps them in step.
Opted-in coverage 2 → 4 walkers. Pinned by `test/bug278_ensure_result_walker_test.zbr`.

### BUG-277: a class field named `path`/`name`/`text`/`message` printed as a string inside `"${...}"` — ✅ FIXED 2026-08-08

**Filed 2026-08-08 while REJECTING a proposed fix of exactly this shape** (see BUG-276),
then fixed the next day.

**THE REPRO AS ORIGINALLY FILED WAS WRONG AND IS CORRECTED HERE.** It claimed
`r.path = 7` on a class with `var path: int` failed with `expected type 'str', found
'i64'`. It does not — that program compiles and runs. The error string was recorded from
a different probe and never re-run. An unverified repro in a ledger is precisely the
hazard class this repo is built around, so it is called out rather than quietly replaced.
Verified trigger:

```
class Route
    var path: int = 0
def main()
    var r = Route()
    print("p=${r.path}")
```
```
error: invalid format string 's' for type 'i64'
```

**Interpolation specifically** — `print(r.path)` was always fine. That asymmetry is the
whole bug. `printFmtSpec` consults the name heuristic ONLY after inference falls through
to unknown/unresolved, which is the correct order; the interpolation path
(`genStringInterp`) asks `isStringBoth` **first** and never reaches it. `isStringBoth` was
an unconditional OR of a precise walker and an imprecise heuristic, so the heuristic could
overrule a type the walker had already resolved.

The heuristic is `isStringExpr`, which force-types eight member names —
`text`/`name`/`message`/`path`/`stdout`/`stderr`/`src`/`member` — regardless of
declaration. Four of those are among the most common field names there are.

**Fixed by inverting the precedence, not by shortening the list.** When the walker
resolves a definite non-string scalar, the heuristic is not consulted. It keeps its
original job unchanged: it is still the only answer available for a type nothing can
resolve, which is the `Shell.Result.stdout` case it was written for. Both directions are
pinned by `test/bug277_member_name_forced_str_test.zbr` — `path: int` prints as a number
AND `name: str` still prints as a string.

The predicate is deliberately NOT the `isPrimType` sitting directly below it, which looks
identical: that one exists for the numeric-emit decision and includes `void_`. Sharing it
would make this fix change silently the next time someone extends it for its own purpose,
and would import an inference artifact (a `void` here is far more often the walker failing
than a real type — BUG-271).

One line of BUG-276's entry below overstates this bug and is left standing as written with
this correction attached: it says an `int` field named `path` "does not compile today".
Only the interpolated form fails. The argument it was making — that widening a
member-name whitelist is the wrong shape of fix — is unaffected.

### BUG-276: HttpRequest's fields were untyped in the selfhost, so `req.method == x` did not compile — ✅ FIXED 2026-08-08

**Reported from the Graze web-framework spike.** `req.method == route.method` failed with
"operator == not allowed for []const u8". Every router, handler and comparison hit it.

**The BOOTSTRAP had this right the whole time** — `src/TypeChecker.zig:73` declares
`.http_request`, `:2540` types `method`/`path`/`content` as `.string`. The selfhost never
ported the type, so a request inferred as a generic named class, `fieldTypeAny` returned
nil, the field came back `unknown`, and codegen emitted a raw Zig `==` on two
`[]const u8`. A pure selfhost-equivalence gap, same family as BUG-261/265/266.

**FIXED by naming the type, not by widening a whitelist — and the control proved that
mattered.** The proposed minimal fix was to add `method`/`path`/`content` to the
member-name fallback that rescues `stdout`/`stderr` when an object's type is unresolved.
That fallback fires on ANY unresolved object, so it would have typed every unresolved
`.method` as a string. `stdout`/`stderr` are rare enough to survive it; `method`, `path`
and `content` are not. **BUG-277 is what that mechanism already does to `path`** — a user
class with an `int` field named `path` does not compile today. The one-line fix would have
added two more instances of a live bug.

Now: `Type_.http_request` in the union, `typeFromName("HttpRequest")` wired, and the three
fields typed at the member-access site. Emits `std.mem.eql(u8, req.method, "GET")`.

Adding the variant cost nothing in exhaustiveness — measured 0 errors across 252 `Type_`
switch arms before committing to the approach.

Pinned by `test/bug276_http_request_str_test.zbr`. gates.sh --full 26/26.

*(`HttpResponse.new(status, body)` — the reporter's other blocker — turned out to already
exist and work, merely undocumented behind an "etc." in QUICKSTART's capability table. He
shipped a 404 in place of a 405 for want of that line. Now documented; the table's "etc."
was a small instance of the same hand-list hazard.)*


### BUG-275: a `?` inside a container expression did not mark the function `throws` — ✅ FIXED 2026-08-08

**Found 2026-08-08** by probing BUG-274's survey — the first CONFIRMED instance from it,
and the only real one in roughly thirty gaps probed.

```
def risky(): int throws
    raise "boom"

def idx(): int
    var arr: List(int) = List(int)()
    arr.add(9)
    return arr[risky()?]        # the `?` is inside an INDEX

def main()
    print(idx())
```

`exprHasTry` has no `Expr.index` case, so `bodyHasRaise` answers false, so `auto_throws`
is not set (`selfhost/CodeGen.zbr:4514`) — while codegen still emits the `try`:

```zig
pub fn _zbr_fn_idx() i64 {          // <- NOT anyerror!i64
    return arr.items[@as(usize, @intCast((try _zbr_fn_risky())))];
}
```
```
error: expected type 'i64', found 'anyerror'
note: function cannot return an error
```

**The control is what makes this a finding rather than a guess.** The same `?` in a
HANDLED position emits `anyerror!i64`; in the index position it emits `i64`, with a `try`
in the body either way. One variable, opposite results.

**Two probe traps hit on the way, both worth knowing:**

1. **Zig only analyses REFERENCED functions.** The first probe never called `idx()`, so
   `zig` never looked at it and the program "compiled". A dead function proves nothing —
   the call site is part of the test.
2. **`zebra -c` reports rc=0 on this**, because check mode is front-end-only by design
   (CLAUDE.md documents "exits 0 on non-compiling emit"). Not a second bug — but it means
   `-c` cannot be the oracle for this class, and the emitted Zig must be compiled directly.

**Fix:** add the `index` case to `exprHasTry` (both `.object` and `.index`). The other
gaps in that walker — `array_lit`, `list_lit`, `slice`, `opt_chain`, `except_`, `old_`,
`lambda` — are the same shape and probably the same bug; each needs its own probe rather
than a bulk edit.

**Control when fixing:** `?` inside an index must mark the function throws AND the emitted
Zig must compile (compile it directly — `-c` will not tell you); a function with NO `?`
must still NOT be marked throws, or every function in the corpus becomes an error union.

---

**FIXED 2026-08-08.** `exprHasTry` gained `index`, `list_lit`, `array_lit`, `slice`,
`opt_chain`, `except_` and `old_`. All three probed forms now emit `anyerror!i64` and the
previously-invalid Zig compiles.

**`lambda` deliberately EXCLUDED.** A `try` inside a lambda body belongs to the LAMBDA's
error surface, not the enclosing function's; recursing would mark the outer function
throws for an error it never sees — wrong in the opposite direction. Completing the set
mechanically would have introduced that bug while fixing three.

**Fixed comprehensively rather than one probed variant at a time, contradicting BUG-274's
advice ON PURPOSE.** This walker asks "does this subtree contain a try?", which has the
SAME answer shape for every container — yes if any child says yes — so a container that
does not recurse is wrong by construction. `exprMentionsThis` is the opposite case: its
right answer genuinely varies per variant, which is why it was probed and left alone. The
rule is **probe when the answer varies, derive when it does not**.

**A failed regen on the way, worth recording.** The first attempt used `if sl.start as
sst` to unwrap a `^Expr?`; that binding hands you the POINTER and the bootstrap rejected
the emit (`expected type 'Ast.Expr', found '*Ast.Expr'`). `zebra -c` passed it — only the
regen, where the BOOTSTRAP compiles selfhost source, caught it. Both sibling walkers
already used `!= nil` + `!`, which emits `sl.start.?.*`.

Note `TypeChecker.zbr:3388` documents this hazard and says it does NOT bite in a
condition. That is true for `on X as y` and FALSE for `if opt as y`. The distinction is
now written at the site, since the existing note points the wrong way.

**Pinned by `test/bug275_try_in_container_test.zbr`**, both directions: the three
container forms must come back throws (their `catch` call sites only compile if they do),
and `noTry()` must NOT become an error union — an over-applied fix would turn every
function in the corpus into one and still pass a detection-only fixture.

gates.sh --full 26/26.


### BUG-273: a failed `assert` named nothing — and was UNDEFINED BEHAVIOUR in release — ✅ FIXED 2026-08-07

**Found 2026-08-07** while building the BUG-259 control. `assert` is what the entire
`test/*.zbr` corpus is built on, and when one fails it tells you nothing you can act on:

```
def main()
    assert 1 == 2
```
```
thread 12240 panic: reached unreachable code
(empty stack trace)
```

No file, no line, no expression, no assert identity — and the stack trace is empty, so
there is nothing to recover it from either. In a corpus fixture with twenty asserts, a
failure gives the maintainer no way to tell WHICH one went red short of bisecting by
hand.

**The compiler already knows all of it.** The same machinery does far better one layer
over: a contract failure prints `ensure failed in 'bump'`, naming the clause and the
method. `assert` lowers to a bare `unreachable` instead of to a check that reports.

This is the UNGIT "nothing withheld" test (`wiki/pages/concepts/concept_ungit-principle.md`):
the system holds the information and drops it at the surface where the user is standing.

**Suggested shape:** lower `assert X` the way `ensure` is lowered — a runtime check
that panics with the source line and the asserted expression text, e.g.
`assert failed at foo.zbr:12: 1 == 2`. The expression text is available at codegen; the
line is already tracked (`w.cur_line`, used for the implicit-try diagnostic).

**Control when fixing:** a failing assert must name its file, line and expression; a
PASSING assert must still cost nothing at runtime beyond the check; and `--turbo` must
still keep asserts (BUG-257 established that `--turbo` strips contracts but NOT
asserts, so the two lowerings must stay distinct).

---

**FIXED 2026-08-07. Filed as a diagnostics complaint; measurement made it a correctness
bug, and the release half is the serious one.**

`assert` lowered to `std.debug.assert`, which is `unreachable`:

| build | before | after |
|---|---|---|
| Debug | `reached unreachable code`, empty trace | `assert failed at foo.zbr:3` |
| `--release` | **nothing at all** | `assert failed at foo.zbr:3` |
| `--turbo` | kept, same silence | `assert failed at foo.zbr:3` |
| passing assert | transparent | transparent |

`unreachable` under ReleaseFast is **undefined behaviour**. It trapped, but nothing said
it would keep trapping — so `assert` was not reliably a check in the builds users ship.
That quietly contradicted a contract already gated here: `contract_mode_check` asserts
that `--turbo` strips contracts but KEEPS asserts, *"because an assert is a check the
author wrote to RUN"*. It only ran in Debug. (Same ReleaseFast-UB hazard
`tools/lint_oom_unreachable.py` exists for elsewhere.)

**Fix:** lower it the way `ensure` always was — `std.debug.panic` carrying `file:line`.
The location must live in the MESSAGE because the self-hosted backend emits no stack
trace, which is why the old diagnostic was useless even in Debug. `fwdSlashes` on the
path, or a Windows `C:\...` becomes an invalid escape and the emitted Zig will not
compile.

**Verified:** all four rows above, by hand, plus `gates.sh --full` 26/26. The number that
mattered is **output_sweep: 322 files, behaviour identical** — this rewrites what every
`assert` in 456 corpus files emits, so a behaviour witness over the whole corpus is the
only thing that could have caught a regression. divergence held at 0 selfhost gaps.

**Fixture limit, stated rather than papered over:** `test/bug273_assert_diagnostic_test.zbr`
pins the PASSING direction only — a fixture cannot assert on its own panic text without
failing. The failing direction is covered by `test/bug259_runtime_exit_code_test.zbr`
(`smoke_run_fail`, which requires non-zero exit AND the panic text) and by the by-hand
`--release` / `--turbo` runs recorded above.


### BUG-259: `zebra.exe run` exits 0 after failure — ✅ NOT REPRODUCED 2026-08-07 (a cmd.exe artifact)

> **Any build gate hung on `errorlevel` reads a failed compile as success.** Filed
> ahead of BUG-258 because it is the smaller fix and the larger consequence.
>
> ```
> > zebra.exe run probe_extern.zbr & echo EXIT=%ERRORLEVEL%
> probe_extern.zbr:5:1: error: unexpected top-level token: 'extern'
> EXIT=0
> ```
>
> The diagnostic is correct, well-formed and pointed at the right line. The process
> then returns success. A caller that checks the exit code — a gate script, CI, a
> `Makefile`, another tool driving the compiler — is told the build worked.
>
> **ESCALATED, same day: it is not only compile errors. A RUNTIME ASSERTION
> FAILURE also returns 0.**
>
> ```
> thread 22192 panic: expected 2 parents, got 2
> EXIT=0
> ```
>
> The program panicked, printed the assertion message, and `zebra.exe run`
> returned success. **This matters far more than the compile-error case**, because
> `test/*.zbr` is built on `assert` — a corpus of tests whose failures are
> invisible to any caller reading the exit code.
>
> `tools/gates.sh:97` does capture it (`timeout ... "$@"; rc=$?`). Whether any
> gate leg's `rc` comes from `zebra.exe run` rather than from a separately
> compiled binary is for someone with the tree to check — I am reporting the
> mechanism, not the blast radius.
>
> **Suggested control when fixing:** a `.zbr` that asserts something false, run
> through whatever path the gates use, must produce non-zero. Watch it go red
> before trusting it green — a fix to an exit code is exactly the kind that
> reports success while changing nothing.
>
> **Repro:** any `.zbr` that fails to parse. `zebra-sprocket/probe_extern.zbr` is one.
>
> **Expected:** non-zero on any diagnostic that prevented a run.
>
> **Why this is worth the interruption.** It is the third instance this week of one
> failure shape, in three unrelated toolchains: `nmake` printing `BUILD_OK` after a
> failed compile, a missing `compiler_rt.dll` exiting 0 having printed nothing, and
> now this. Two of those were caught only because the *count* of what should have
> reported was wrong, not because anything went red. A gate that cannot distinguish
> "compiled" from "failed to compile" is not a gate, and gates are being built right
> now. See `wiki/pages/concepts/concept_false-green-taxonomy.md`.
>
> *(Filed by Fable, 2026-08-05, from outside the tree — found while probing whether
> Zebra could reach the sprocket SQLite fork.)*
> ---
>
> **VERIFICATION 2026-08-05 (Opus 5, in the tree): DOES NOT REPRODUCE. The compiler's
> exit codes are correct; the probe was misreading them.**
>
> In `cmd.exe`, `%ERRORLEVEL%` on a single command line is expanded **before the line
> executes**, so `A & echo EXIT=%ERRORLEVEL%` prints the errorlevel from *before* `A`
> ran — always `0` in a fresh shell. It is the delayed-expansion trap, not a compiler
> behaviour.
>
> | probe | result |
> |---|---|
> | bash, compile error (`extern` at top level) | `rc=1` |
> | bash, runtime `assert` failure | `rc=1` |
> | cmd, the filed form `& echo EXIT=%ERRORLEVEL%` | `EXIT=0` ← the artifact |
> | cmd, `& if errorlevel 1` (evaluated at RUNTIME, not expanded) | `COMPILER_REALLY_FAILED` |
> | control: `cmd /c "echo BEFORE_ANY_COMMAND=%ERRORLEVEL%"` | `0` — confirms early expansion |
>
> Run with the reported file shape (`extern` at top level, the exact diagnostic quoted
> above) and with a failing `assert`, through both `zebra.exe run` and plain
> `zebra.exe`. All four return 1.
>
> **No fix should be attempted.** A change to these exit codes would alter behaviour that
> is already correct — and per this ticket's own warning, an exit-code fix is exactly the
> kind that reports success while changing nothing. The suggested control (a `.zbr` that
> asserts something false must produce non-zero) **already passes today**.
>
> The report's wider point stands and is worth keeping: this was the third instance that
> week of a caller reading a failure as success. It is simply that on this occasion the
> instrument was the one at fault, which is the same lesson pointed at the observer —
> see `concept_false-green-taxonomy` Part 4, where a zero that is the *expected* answer is
> the hardest kind to doubt.
>
> **STATUS: closed, not-reproducible.** Filed in good faith from outside the tree; the
> reporter explicitly flagged the blast radius as unverified and asked someone with the
> tree to check. This is that check.

---

**NOT REPRODUCED — verified 2026-08-07 from inside the tree. The compiler was never
wrong; the measurement was.**

`cmd.exe` expands `%VAR%` when it PARSES a line, so in `prog & echo %ERRORLEVEL%` the
value is substituted BEFORE `prog` runs — the reported 0 is the *previous* command's
status. Demonstrated on one binary in one session, same command both ways:

    cmd /c   "... zebra.exe parsefail.zbr & echo EXIT=%ERRORLEVEL%"   -> EXIT=0
    cmd /v:on /c "... zebra.exe parsefail.zbr & echo EXIT=!ERRORLEVEL!" -> EXIT=1

**It was not a silent fix either**, which is the other thing "does not reproduce" could
mean. Exit propagation (`if rc != 0 -> sys.exit(1)`) landed in `12fda11` on 2026-07-25,
**eleven days before this was filed**, and the only two commits touching
`selfhost/main.zbr` since are the BUG-261/265/266 FFI work, neither of which goes near
exit handling. The code was already correct at filing time.

Every path measured, on both a parse failure and a runtime assert failure — plain,
`run`, `--turbo`, `--release`, and the extern/LLVM route: **all return 1**.

**THE REPORTER WAS RIGHT ABOUT THE RISK, and checking it found a real gap.** All three
existing `smoke_run_fail` registrations are BUILD-time failures (method-not-found,
field-not-found, non-ASCII byte). Nothing asserted that a program failing at RUNTIME
exits non-zero — exactly the case escalated as mattering more, since `test/*.zbr` is
built on `assert`. Closed with `test/bug259_runtime_exit_code_test.zbr` registered as
`smoke_run_fail`, which requires BOTH a non-zero exit and the panic text.

*(Filed by Fable from outside the tree and flagged unverified, which is the norm that
made this cheap to resolve rather than expensive to chase.)*


### BUG-268: `branch` on an INTEGER with no guarded arm emits enum-variant syntax and does not compile — ✅ FIXED

**Found 2026-08-06** while probing an unrelated `zig"…"` question. A basic construct;
it does not compile in any context.

```
def main()
    var x = 2
    branch x
        on 2
            print("hit")
        else
            print("miss")
```

```
error: expected '}', found '.'
```

**The emit shows it immediately** — an enum tag where an integer literal belongs:

```zig
switch (x) {
    .2 => {          // <- should be `2 =>`
```

**A GUARD ON ANY ARM HIDES IT, and that is why it has never been seen.** A guarded arm
routes the whole `branch` to an if-chain instead of a `switch`, and that path is correct:

| arm | emitted | result |
|---|---|---|
| `on 2 if x > 1` | `if (!_bd_1 and (_bv_1 == 2))` | works |
| `on 2` | `switch (x) { .2 => {` | **broken** |

`branch` on a `char` also works (`test/branch_range_test.zbr` passes) — it takes the
range/char path. So the break is specific to an integer scrutinee with plain literal arms.

**Why no gate caught it.** Exactly one tracked file has integer arms —
`test/branch_guard_test.zbr` — and every one of its arms is guarded, because guards are
what it exists to test. So the corpus contains the construct only in the form that works.
This is the `full_sweep`-baseline gap in miniature: not a file that fails unnoticed, but a
*form* that is absent from the corpus entirely.

**Control when fixing:** an unguarded integer arm must compile and select correctly; a
guarded one must keep working (do not "fix" it by routing everything to the if-chain — that
would drop the switch and its exhaustiveness behaviour); `char` and range arms must be
unaffected. A fixture with NO guard anywhere is the one that matters — adding a guard to it
would silently restore the passing path and the regression test would stop testing.

**FIXED 2026-08-06** (`fe6cab5`). The emit was innocent: `genSwitchTag` prefixes `.`
for an ident because for a union that is right. The AST was wrong — the parser
stores on-clause patterns as STRINGS, and `AstBuilder.patternToExpr` recognised only
char and string literals before falling through to `Expr.ident`, so `on 2` became
`ident("2")`. Fixed at `patternToExpr`; the bootstrap already emitted `2 =>`, so this
converged the selfhost onto the working reference.

Pinned by `test/bug268_branch_int_test.zbr`, whose arms must stay UNGUARDED: a guard
routes the whole branch to the if-chain path that was never broken, which is exactly
how this survived (the one corpus file with integer arms guards all of them).


### BUG-260: a parameter used only inside a query's param-list literal is emitted as unused, producing uncompilable Zig — ✅ FIXED

> A `def` parameter referenced *only* inside the `[...]` bind list of
> `d.query(sql, [...])` is not counted as used. Zebra emits the unused-parameter
> discard **and** the use, and Zig rejects the pair.
>
> **Source:**
> ```
> def pwc(d: SqliteDb, pid: int): List(PwcRow)
>     var out: List(PwcRow) = []
>     var rows = d.query("CALL pwc(?)", [pid])
> ```
>
> **Emitted:**
> ```zig
> pub fn _zbr_fn_pwc(d: SqliteDb, pid: i64) std.ArrayList(PwcRow) {
>     _ = pid;                                     // <- treated as unused
>     const rows = d.query_p_("CALL pwc(?)",
>         &[_]_SqliteParam{.{ .int = @as(i64, @intCast(pid)) }});   // <- used
> ```
>
> **Result:**
> ```
> error: pointless discard of function parameter
>     _ = pid;
> ```
>
> **Repro:** `zebra-sprocket/gen_check.zbr`.
>
> **Why it matters beyond the one case:** this is the shape *generated* code
> takes. A generator emits a function per procedure whose parameters exist
> solely to be bound, so every generated binding with a parameter hits this.
> Hand-written code tends to use a parameter somewhere else too, which is
> probably why it has not been seen.
>
> **The analysis, not the discard, is the bug.** Suppressing `_ = x;` when a
> param-list literal mentions the name would fix the symptom; the underlying
> issue is that the usage walk does not descend into that literal, and anything
> else asking "is this used?" will be wrong in the same place.
>
> **Control when fixing:** a `def` whose parameter appears *only* inside a query
> bind list must compile; and one whose parameter is genuinely unused must still
> emit the discard. Both directions, or it is not a fix — the easy wrong fix is
> to stop emitting the discard entirely.
>
> *(Filed by Fable, 2026-08-05, from `zebra-sprocket`. The generated Zebra is
> correct; the compiler mistranslates it.)*

**FIXED 2026-08-06** (`ea4ff07`). `nameUsedInExpr` — the walker the PARAMETER discard
consults — had no `list_lit`/`array_lit` case, so `[pid]` fell into its `else`, which
returns FALSE for anything unmodelled. Two lines each, mirroring what the sibling
walker already did.

The filer's prediction ("anything else asking 'is this used?' will be wrong in the
same place") was right, and structurally guaranteed: the two usage walkers have
OPPOSITE defaults, so an omission in this one is silent while the same omission in
the other is merely conservative. `tools/lint_expr_walkers.py` now derives the
answer from `Ast.zbr` so the class cannot recur unnoticed.

Pinned by `test/bug260_bindlist_param_test.zbr`, which also carries a genuinely
unused parameter that must STILL be discarded — a fix that simply stopped
discarding would pass a one-sided fixture and break every function with a
legitimately unused parameter.


### BUG-258: `extern` is in the grammar and rejected by the parser — second instance of a known class — ✅ FIXED

> `grammar.txt` lists `extern` as a modifier (lines 41 and 51). Nothing under `test/`
> or `examples/` uses it. The parser rejects it:
>
> ```
> probe_extern.zbr:5:1: error: unexpected top-level token: 'extern'
>   — expected a declaration (def, class, struct, enum, union, use, var, const)
> ```
>
> **This is the same shape as the `~` operator (2026-08-04):** present in grammar,
> lexer, AST and codegen, missing only from the parser. Two specimens of one class
> suggests the grammar and the parser have drifted in **more than one place**, and
> that the useful work is a *sweep* — enumerate every production `grammar.txt`
> declares, attempt each, and record which ones the parser will not take — rather
> than fixing whichever one somebody trips over next.
>
> That sweep is also the thing that makes the grammar trustworthy as a reference,
> which is what let the `~` discovery land at all: without a grammar you believe,
> a parse error reads as your own mistake and gets silently discarded. Being wrong
> about the system leaves a bug report; being wrong about yourself leaves nothing.
>
> **Decide before fixing:** whether `extern` is *meant* to exist. If Zebra has no
> FFI story yet, the honest fix may be removing it from `grammar.txt` rather than
> implementing it — a grammar that promises what the language does not have is the
> same defect pointed the other way.
>
> **Consequence noted, not urgent:** with no FFI escape hatch, `zebra-sprocket`
> cannot reach `sqlite3_proc_next_resultset()` from outside the tree, so the
> multi-set-proc (S4) path stays blocked until Zebra takes the change. The folded
> JSON path works today and is unaffected.
>
> *(Filed by Fable, 2026-08-05.)*
> ---
>
> **VERIFICATION 2026-08-05 (Opus 5, in the tree): confirmed, but the diagnosis is the
> wrong way round — and the state is worse than "rejected".**
>
> It is not grammar-vs-parser drift, and it is not the selfhost-lags-bootstrap class:
>
> | | `extern def foo(): int` |
> |---|---|
> | **selfhost** (`zebra.exe`) | rejects with the quoted error — **correct behaviour** |
> | **bootstrap** (`zebra-bootstrap.exe`) | **accepts it**, drops the modifier, emits `unreachable; // abstract` |
>
> The bootstrap's output **compiles**; it was built to an `.exe` to confirm. So today an
> `extern` declaration silently becomes an abstract method that traps in Debug and is
> **undefined behaviour under `zebra --release`** (ReleaseFast), which is the hazard
> `tools/lint_oom_unreachable.py` exists for. An accepted declaration compiling to UB is
> worse than a clean rejection, so **on this one the selfhost is right and the bootstrap
> is wrong** — the same inversion as BUG-254.
>
> Consequence for the suggested fix: porting the bootstrap's handling into the selfhost
> would replace a correct error with a silent trap. Do not do that.
>
> Two corrections to details, both minor and neither affecting the conclusion:
> - `export` is **not** affected. It works in both compilers (emits `pub export fn`) and is
>   exercised by `test/dynlib_export_def_test.zbr` and `examples/hello_plugin.zbr`.
> - `grammar.txt` is **generated** from the Earley rule table as of 2026-08-04, so it cannot
>   be edited directly; the declarations live at `src/ZebraGrammar.zig:348,351,370`.
>
> **DECIDED 2026-08-05 (Sean): `extern` is meant to exist, to enable the FFI work.** So the
> resolution is to implement it, not to remove it from the grammar. Reclassified from a
> parser gap to an unimplemented feature; see the implementation notes below.
>
> **Design written 2026-08-05: `docs/extern_ffi_design.md`.** Two of the three pieces
> already exist — C-ABI-sized types (`int32` → `i32`, so the ABI is expressible without new
> syntax) and `BuildTarget.linkLib` for linking. What is missing is the declaration itself.
> The plan is the minimal form: `extern def name(params): ret` with no body emits
> `extern fn name(params) ret;`, no symbol renaming and no C-type aliases, because neither
> is needed to unblock the sprocket work. **The bootstrap must be fixed in the same change**
> (`src/CodeGen.zig:6141`): if the selfhost starts accepting `extern` while the bootstrap
> still emits `unreachable`, the regen authority and the `--gui-backend` path silently
> miscompile a supported keyword, which is strictly worse than today.
>
> Also recorded there: there is **no** top-level `zig"…"` escape hatch — both compilers
> reject it — so the reported sprocket blockage is real and has no workaround.
>
> The report's central recommendation — *sweep the grammar rather than fix whatever
> someone trips over next* — is accepted and is now tracked separately. `~` and `extern`
> are two specimens; the sweep is what says whether there is a third.

---

**FIXED 2026-08-05.** `extern def` is implemented in BOTH compilers and emits a real
`extern fn` declaration. The follow-on work is in BUGS_FIXED as BUG-261 (C source
deps), BUG-265 (the fast backend miscompiling a foreign call) and BUG-266 (nothing
could name a library). Gated by `smoke_run test/extern_c_call_test.zbr` and
`tools/ffi_lib_check.sh`. See `docs/extern_ffi_design.md` §7-9.


### BUG-257: contracts are not stripped in `--release` — RESOLVED 2026-08-05, it was the docs

> **Resolved: the compiler was right and every document was wrong.** Sean's ruling
> (2026-08-05): contracts should strip **only** with `--turbo`, Cobra-style, so a shipping
> build is `--release --turbo` — no contracts, optimised. Measured against the compiler,
> **that is already exactly what it does.** No code change was required.
>
> | | `require`/`ensure`/`invariant` | `assert` | binary |
> |---|---|---|---|
> | *(default)* | fire | fires | 19.99 MB |
> | `--release` | **fire** | fires | 830 KB |
> | `--turbo` | stripped **at emit** | **fires** | 19.99 MB |
> | `--release --turbo` | stripped **at emit** | **fires** | 831 KB |
>
> Stripping is removal at **emit** time, not an optimiser dropping a branch — the string
> `require failed` appears in the emitted Zig without `--turbo` and is absent with it. That
> distinction matters: an optimiser-dependent guarantee could come back at any Zig release.
>
> `assert` surviving `--turbo` is correct and is now pinned as a gate leg. A contract is a
> proof obligation on the caller; an `assert` is a check the author wrote to run. Stripping
> the second along with the first removes checks nobody asked to have removed.
>
> **What was actually broken was every description of it.** `docs/testing_strategy.md` said
> release builds were unaffected by contracts (fixed earlier the same day); `QUICKSTART.md`
> called `--turbo` *"equivalent to release mode"*, which invites exactly the conflation that
> produced this ticket. Both now carry the matrix.
>
> **Gated so it cannot drift back:** `tools/contract_mode_check.sh`, FULL tier. It is the
> only gate that passes `--turbo`, and `--turbo` had been named in our own testing-strategy
> doc as "a genuinely under-tested path" while no tier touched it. Verified red against both
> realistic regressions before being registered.
>
> **The general lesson, and it is the third instance this week.** Nobody had measured this.
> The ticket, the architecture note Fable read, and two shipped documents all described
> behaviour that no test asserted — and they agreed with each other, which is what made it
> feel settled. Cross-document agreement is not evidence; it is often just one unchecked
> claim with copies. The measurement took four builds.

<details><summary>Original ticket, kept for the reasoning</summary>

**Found 2026-08-04**, answering a question from Fable about whether a SQLite hazard
reproduces in Zebra. Measured, not inferred:

| construct | debug | `--release` |
|---|---|---|
| `assert cond, "msg"` | fires | **fires** |
| `require` / `ensure` contracts | fires | **fires** |

**The repo's own rationale says the opposite.** From BUG-228's fix note, recording Sean's
2026-07-30 direction verbatim: *"contracts are checked in development and stripped for
release BECAUSE they established the property, so a release build should not re-check at
runtime what the contracts already proved."* That is the Design-by-Contract position and it
is the stated reason ReleaseFast was chosen over ReleaseSafe. **It is not what the compiler
does.**

**This was not observable until today.** `zebra --release` produced an *unoptimized Debug*
binary until BUG-228 was fixed this morning — the flag switched the backend to LLVM but
passed no `-O` at all. So no one had ever run a genuine release build, and "are contracts
stripped in release?" had no answerable form. Fixing BUG-228 is what made this measurable.

**Three ways to resolve, and it is a decision rather than a defect:**

1. **Strip contracts in release, keep `assert`.** Matches the stated rationale and the
   DbC argument. `assert` is a user-written runtime check, not a proof obligation, so
   conflating them is probably wrong.
2. **Strip both.** Maximum ReleaseFast performance; means a release build silently
   continues past a violated precondition, which is the hazard class Fable's phase 3
   removes structurally on the SQLite side.
3. **Strip neither, and correct the documentation.** Cheapest, and defensible: contracts
   that survive are a safety net, and the performance argument for stripping is unmeasured.

**Recommend (3) until (1) is measured.** The stated reason for stripping is performance, and
nobody has measured what contracts actually cost. Stripping a working safety net on an
unmeasured assumption is the wrong direction for a language whose current bar is "no
surprises". But the documentation must stop claiming behaviour the compiler does not have.

**2026-08-05 — one instance of that documentation found and fixed.**
`docs/testing_strategy.md` (a `live` doc) asserted *"`--turbo` strips them, so release
builds are unaffected"*. The premise is true and the conclusion does not follow:
`--release` and `--turbo` are independent flags — `selfhost/main.zbr` sets
`strip_contracts = turbo` and nothing else assigns it — so a plain `--release` build pays
the full contract cost. Corrected in place with a pointer here.

Worth noting *how* it was found, because it is not how this ticket was written. The claim
surfaced while checking a sentence I had just written to Fable, asserting from memory that
the repo states the stripping intent. It does — but the doc I reached for while verifying
said something stronger and false. **The check was on my own claim; the bug was in the
thing I checked it against.** Verifying a statement you are confident in is how you find
the ones nobody was suspicious of.

</details>

**Cross-project note:** Tack (Zebra's ORM) has an S2 path whose ordering convention is
guarded by an assertion, and POC 2 reportedly measured ~98% child-row loss in release
builds. Given the above, that guard is currently **live** in release — so either the loss
had a different cause, or it was measured on a build that was not actually a release build
(everything before 2026-08-04 was Debug). Worth re-deriving before designing against it.

### BUG-256: `~` (bitwise NOT) was unparseable by the SHIPPING compiler — FIXED 2026-08-04

**Not a missing diagnostic — a missing language feature.** Everything except the parser
already supported it:

| layer | state |
|---|---|
| grammar (`ZebraGrammar.zig`) | `Expr8 → tilde Expr9` — valid syntax |
| lexer | produced the token (the error NAMED it: `unexpected expression token: '~'`) |
| `UnaryOp.bit_not` in the AST | present, **unreachable** — nothing could construct one |
| `CodeGen.zbr:10537` | already emitted `(~expr)` |
| bootstrap | accepted `~a`, emitted valid Zig (rc=0, 3778 lines) |
| **selfhost parser** | **no `~` case in `parseUnary`** |

**How it was found, which is the part worth keeping.** BUG-255 made `grammar.txt` generated
from the parser's rule table. The habit that came out of it — *check the grammar before
writing a probe* — was adopted after three probes in one session were written in syntax
Zebra does not have. Here the habit inverted: **the grammar said the syntax was real and the
compiler disagreed.** Without a trustworthy grammar the `~` parse error would have looked
like one more invented-syntax mistake and been dropped.

**Fix:** a `~` case in `Parser.parseUnary` mirroring `-`, and `"~" → UnaryOp.bit_not` in
`AstBuilder.toUnaryOp`. Two places; every other layer was already waiting.

**Verified:** `~12 == -13`, `~0 == -1`, `~~x == x`, and `~a + 1 == -12` (precedence — unary
binds tighter than `+`). full_sweep 0 regressions vs 337.

### BUG-255: `grammar.txt` had drifted from the parser, so the FUZZER was exploring a language that partly does not exist — FIXED 2026-08-04

**Sean's idea:** *"Can we have the grammar exported (I think it is possible to have the
Earley parser generate an updated one)."* It was, and the drift it exposed was substantial.

`grammar.txt` was 520 lines of hand-maintained BNF. The Earley parser's real grammar is
`src/ZebraGrammar.zig` — **474 comptime rule literals**, compiled. Two copies of one thing,
one of which is checked by the compiler and one of which is prose.

| | |
|---|---|
| nonterminals in the **parser**, absent from the document | **40** |
| in the **document**, absent from the parser | **9** |
| nonterminals whose productions differed | **36** |

**This was not a documentation nicety.** `fuzz/gramgen.py` reads `grammar.txt` as its source
of truth (line 42). So the parser-robustness gate — 960 derived programs, run per session —
was:

* **generating 9 constructs the parser does not have** — `ProDecl`, `PropDecl`, `StmtUsing`,
  `AllAnyExpr`, `MemberBlockOpt`, `StmtPostWhile`, `PropBody*`; and
* **never once reaching 40 that it does** — `LambdaExpr`, `LambdaBlockExpr`, `CaptureBlock`,
  `CaptureVar`, `CaptureVarList`, `ExceptField*`, `GenericConstruct`, `ForElseOpt`,
  `DeclUnion`, `IdListNE`…

**Lambdas and capture blocks had never been fuzzed.** Those are not corners; `sys.go(def() …
capture …)` is the documented concurrency idiom.

It also recasts the fuzzer's own standing caveat. Its docs say *"accept/reject divergences
are expected, don't fail it"* — attributed to overgeneration. A grammar containing nine
constructs the parser cannot parse is a much less innocent explanation, and it means that
caveat was absorbing a real signal.

**Fixed:** `tools/grammar_export.py` generates `grammar.txt` from the rule table, and
`--check` is now a QUICK-tier gate so the two cannot drift again. Regenerated: 474 rules,
149 nonterminals, and `gramgen` loads it with **0 undefined nonterminal references** (the
old file had dangling ones).

**Re-run after the fix: `gramgen --gate` still PASSES** — 960 programs, 0 hangs, 0 crashes.
So the parser is robust against the *real* language too, which was not previously known. The
coverage change was verified rather than assumed: the 40/9 sets above are computed by
loading both the old and new files through `gramgen.load_grammar` and diffing.

**What the gate cannot say:** that the grammar is CORRECT — only that the document matches
the table. Precedence encoded via nonterminal layering, and anything the parser does outside
the Earley table (notably the tokenizer's `indent`/`dedent` synthesis), remain invisible.

**Follow-up worth doing:** now that the fuzzer can reach lambdas, captures and generics,
a longer run than the 960-program gate is likely to be productive. The gate's seeds are
fixed for determinism; an exploratory run with fresh seeds is a different instrument.

### BUG-266: no way to link an external library — ✅ FIXED 2026-08-06

**Found 2026-08-05** probing Python 3.11's MSVC-built DLL. **This is the actual blocker
for third-party FFI**, and it was masked until now.

The ABI works (BUG-265 §9: a bare `extern def` calls MSVC-built code correctly). What does
not exist is any way to tell Zebra which library to link:

- `BuildTarget.linkLib(other: BuildTarget)` takes **another Zebra build target**, not a
  library name or path. It records a dependency edge between things `build.zbr` defines,
  and `b.lib()` targets are themselves stubs printing "not yet implemented".
- The CLI has no passthrough — no `-l`, no library path, no linker-argument escape.

`docs/extern_ffi_design.md` §1 and §2 both assumed `linkLib` covered this ("linking the
library from `build.zbr` via `BuildTarget.linkLib`"), and §5 recorded it as "assumed
sufficient and **unverified**". It is now verified as insufficient.

**Why it stayed hidden:** the kernel32 probes appeared to work end-to-end, but `-lc` drags
kernel32 in for free — the one case that looked linked was the one case needing no linking
mechanism. Every other successful foreign call so far was linked by hand with
`zig build-exe`.

**Fix direction:** extend the dep walk's candidate list (`.zbr`, `.c`) with `.lib`/`.dll`,
reusing the native-use registry from BUG-261 — such a dep takes the same "emit a comment,
bind nothing" genUse arm as `c_no_header`, and its path is appended to the zig argv beside
`c_sources`. That reuses machinery that already exists rather than adding a build-system
feature.

**Control when fixing:** a program declaring `extern def Py_IsInitialized(): int32` beside
a `python311.lib` must print `before=0 / after=1` across `Py_Initialize()` with NO manual
zig invocation — the transition is the assertion, since an unlinked call cannot produce it.

**FIXED 2026-08-06 (BUG-266).** `use foo` now resolves `foo.lib` / `foo.a` / `foo.so` /
`foo.dylib` beside the source or on `--module-path`, registers it in the native-use
registry added for BUG-261, and appends it to the zig command line as a positional link
input. The genUse arm is the same "emit a comment, bind nothing" shape as `c_no_header` --
a prebuilt library and a headerless `.c` differ only in whether zig COMPILES the input or
merely LINKS it. A source dep wins: the `.c` branch now returns rather than falling
through, so `foo.c` beside a stale `foo.lib` keeps compiling the source.

**End-to-end, one command, against real MSVC-built code:**

    use python311                        # python311.lib beside the source
    extern def Py_IsInitialized(): int32
    extern def Py_Initialize()
    -> before=0
       after=1

**Gated by `tools/ffi_lib_check.sh`** (QUICK tier). It BUILDS its own library at check
time rather than committing a binary to the corpus, uses an expected value that appears
nowhere in the Zebra source, and carries a NEGATIVE CONTROL -- leg 2 removes the library
and requires the value to stop appearing, so leg 1 cannot pass for an unrelated reason.
No compile-only gate could have covered this: they build with `-fno-emit-bin` and never
link, so an `extern fn` resolving to no symbol at all passes them cleanly.


---

### BUG-265: the fast backend silently produced a CRASHING binary for an `extern` DLL symbol — ✅ FIXED 2026-08-06

**Found 2026-08-05** while scoping DLL support. The headline finding is that **DLL symbols
already work** — just not on the default build path.

    extern def GetCurrentProcessId(): uint32
    def main()
        if GetCurrentProcessId() > 0
            print("dll-ok")

| invocation | result |
|---|---|
| `zebra.exe p.zbr` (default) | **segfault** |
| `zebra.exe --release p.zbr` | `dll-ok` |
| `zebra.exe p.zbr` with any `.c` dep present | `dll-ok` |

The last two both force the LLVM path. `selfhost/main.zbr:2550` takes the self-hosted
backend when `not release and c_sources.len == 0 and not uses_sqlite`, so a program whose
only foreign dependency is a DLL symbol is exactly the case that gets the fast backend.

**Not Zebra's emit, and not `-lc`.** The emitted declaration is byte-identical to a
hand-written Zig file that works, and LLVM **without** `-lc` also works. Isolated to the
backend flags alone:

| `zig build-exe a.zig …` | result |
|---|---|
| (default LLVM), no `-lc` | works |
| `-fno-llvm -fno-lld`, no `-lc` | **segfault** |

**The dangerous part is the silence.** The comment at `selfhost/main.zbr:2536-2544`
justifies the fast path with *"A pure-Zig backend gap is a real compile error, so falling
through to the LLVM path below stays safe."* That assumption is false here: the fast
backend **compiles successfully** and emits a binary that faults at the call, so the
fallback never triggers. Any other backend gap of this shape — builds clean, wrong at
runtime — is equally invisible. The bootstrap has the same path (`src/main.zig:1458`).

**Fix direction:** mirror `uses_sqlite` with a `declares_extern` flag set during the walk
and add it to the condition at `selfhost/main.zbr:2550`, so an `extern`-declaring program
takes LLVM. Both compilers.

**Control when fixing:** the probe above must print `dll-ok` with NO flags; and a program
with no `extern` must still take the fast path (otherwise the fix silently costs every
program the ~6x build-time win).

**Note for the DLL feature generally:** no new syntax is needed. `extern "kernel32"` and
`callconv(.winapi)` are both unnecessary on x86-64 (measured — bare, library-named, and
callconv variants all work), and an arbitrary third-party DLL links with a bare
`extern fn` plus its import lib on the command line. See `docs/extern_ffi_design.md` §8.

**FIXED 2026-08-06 (BUG-265).** `emittedExtern()` and a non-empty `lib_sources` now join
`c_sources` and `uses_sqlite` in the fast-path exclusions at `selfhost/main.zbr`, so any
program declaring a foreign symbol takes the authoritative LLVM path.

**The detection is set AT THE EMIT SITE, deliberately.** The cheap version -- scan the
generated Zig for `extern fn`, mirroring how `uses_sqlite` scans for `_sqlite_open` -- is
wrong here: a hello-world's INLINE preamble carries **16** `extern fn` declarations of its
own (measured), so every `--no-runtime-module` build would have matched. That is precisely
the false positive BUG-209 hit for sqlite, and its comment is the warning that caught this
one before it shipped.

**Both control directions verified:** a program with `extern` no longer produces
`<file>.zig.fast.exe` (LLVM taken, prints `dll-ok` with no flags, previously a segfault),
and a plain program still does (the ~6x faster backend is preserved -- the fix costs
nothing to programs that do not use FFI).


---

### BUG-261: the selfhost could not link C dependencies — ✅ FIXED 2026-08-05

*(Filed as "BUG-260" in commit `fcd9c7c`; renumbered to 261 because BUG-260 was
already taken by a bug filed earlier the same day in `5717d80`. See the numbering
note at the top of `BUGS.md`.)*

**Symptom.** A `use` resolving to a sibling `.c` failed in the shipping compiler
while working in the bootstrap:

    use cprobe_add3                                  # cprobe_add3.c, no header
    extern def zebra_probe_add3(a: int32, b: int32, c: int32): int32
    def main()
        print(zebra_probe_add3(20, 20, 2))

| | before |
|---|---|
| `zebra-bootstrap.exe` | **42** |
| `zebra.exe` | `unable to load 'cprobe_add3.zig': FileNotFound` |

**The original report said the selfhost had "no C-dependency handling whatsoever."
That was not accurate, and the inaccuracy mattered** — it made the fix look like a
missing subsystem when it was a missing *hand-off*. `selfhost/main.zbr`'s dep walk
already discovered the `.c`, already routed it into `c_sources`, already recorded
the header's directory in `c_i_dirs`, and already passed both to `zig build-exe`.
Every part of the pipeline worked except that **nothing told the codegen**, so
`genUse` fell through to its default and emitted `@import("cprobe_add3.zig")` for
a file that is not Zig and does not exist.

The two compilers' emitted declarations were already byte-identical. The entire
defect was one line of the emit.

**Fix.** Mirror `CodeGen.native_uses` from `src/CodeGen.zig`:

- `selfhost/CodeGen.zbr` — two file-scope `StrSet`s (`_c_no_header_uses`,
  `_c_with_header_uses`) plus `addNativeCUse`/`isNativeCUse`, following the
  existing `setSingleFile`/`setGuiBackend` file-scope-flag pattern.
- `selfhost/CodeGen.zbr` `genUse` — branch before the default `@import`:
  a header dep emits `@cImport(@cInclude("X.h"))`, a headerless one emits a
  comment and no binding. Both mirror `src/CodeGen.zig:4907-4916` exactly.
- `selfhost/main.zbr` — call `addNativeCUse(u.path, <has .h>)` at the point that
  already tests for the sibling header. Registered on the path **as written in
  the `use`**, since that is the key `genUse` looks up.

**Two things deliberately NOT changed**, both recorded in comments because each
looks like an oversight:

1. The default `@import` arm stays unconditional. That is also how a native
   `.zig` dep works — the dep walk has no `.zig` candidate, so such a dep falls
   through to `genUse` where the plain `@import` is accidentally correct.
2. Neither native arm emits the exposed-name aliases. The bootstrap does not
   either (BUG-263). Fixing one side alone would open a `divergence_check`
   selfhost gap.

**Verification — the fixture had to RUN, and the controls had to go red.**

- `test/extern_c_call_test.zbr` + `test/cprobe_add3.c`, registered as
  `smoke_run … "42"`. Asserted on **printed output**, never exit code: BUG-259
  is open, and the selfhost returned `rc=0` on the very FileNotFound this pins.
- Compile-only gates cannot witness this at all. `compile_check` and
  `full_sweep` build with `-fno-emit-bin`, so they never link; an `extern fn`
  resolving to no symbol passes their check cleanly.
- Controls run before believing the pass: perturbing the C body to `a+b+c+1`
  moved the output to **43** (proving the value comes from that translation unit
  and is not a constant from somewhere else), and removing the `.c` restored the
  original FileNotFound rather than silently printing 42.
- Both invocation shapes checked — absolute path and repo-relative — because the
  `.c` path is built from the source dir while the emit lands in a temp dir.

**Side effect: `test/c_interop_test.zbr` came back from the dead.** It, plus
`CUtils.c`/`CUtils.h`, had been tracked in the repo all along, exercised the
`c_with_header` branch, and were registered in *nothing* — one of
`registration_check`'s known-debt files. It could not have passed while this bug
existed. It now runs on both compilers and is registered, shrinking that debt
from 20 to 19.

---

### BUG-239: empty list literal `[]` in expression position — ✅ FIXED 2026-08-01

**Symptom.** Any `[]` used as a call argument, struct-field initialiser, or return
value failed to compile with a Zig-level error that named the *callee's* definition
line rather than the literal:

```
def take(xs: List(str)): int
    return xs.len          # <- error reported HERE
def main()
    print(take([]).toString())
```
```
error: local variable is never mutated
```

**Cause.** The selfhost lowers a list literal to a labeled block —
`(blk_ll_N: { var _ll_N: std.ArrayList(T) = .empty; _ll_N.append(...); break :blk_ll_N _ll_N; })`
— with the keyword hardcoded to `var`. With zero elements no `.append` is emitted,
so the binding is never mutated and Zig hard-errors. The misleading line number is
why this survived: it reads as a fault in the function being called.

**Fix.** `selfhost/CodeGen.zbr`, `Expr.list_lit` — choose the keyword from
`ll.elems.len`, emitting `const` for an empty literal. This matches the house idiom
already documented in the bootstrap (`src/CodeGen.zig:1645`: "a sort-only list must
stay `const`, else Zig rejects it as never mutated"). The same guard was applied to
`Expr.dict_lit`, which a bare `{}` actually reaches.

**Scope notes for whoever touches this next:**

- `var x: List(T) = []` was **never** affected — annotated locals are handled in
  `genLocalVar`, which never reaches the literal lowering. Only expression position
  was broken, which is why the corpus did not catch it.
- A bare `{}` parses as a **dict** literal, not a set. The set-literal branch has no
  zero-element guard because no source syntax can reach it; a comment there records
  what to do if an empty-set syntax is ever added.
- The **bootstrap does not have this bug** — `src/CodeGen.zig:14341` emits a bare
  `std.ArrayList([]const u8).empty` for the empty case with no block at all. Checked
  because BUG-238 turned on exactly this bootstrap/selfhost distinction.

**Regression:** `test/bug239_empty_list_literal_test.zbr`, registered `smoke_run` in
`tools/selfhost_smoke.sh`. Found by dogfooding — writing a village demo for
`examples/tears_of_the_tuon.zbr` and passing `log: []`.

---

### BUG-238: import-parser rejects `except` inside enum-dotted `branch` arms — NOT A COMPILER BUG; reporter error, 2026-08-01

**RESOLVED 2026-08-01. TWO reporter errors, not one compiler bug.**

**Cause 2, found after the rebuild and the more important of the pair:** every
failing invocation in the original report passed **`--gui-backend=stub`**, and that
flag routes the build through the **bootstrap** compiler, whose older parser rejects
return-position `except` — the known BUG-204 family, already documented in
`examples/tears_of_the_tuon.md`. Drop the flag and the same file compiles clean on the
selfhost. Opus's observation that the error text appeared *only in `src/`* was pointing
straight at this and I did not follow it. Policy going forward (Sean, 2026-08-01): use
the selfhost, which is far more current than the bootstrap.

**Cause 1, real but secondary: Opus's explanation 2, the stale tree.** Running `tools/doctor.sh` in my tree — which I did not do before
filing — reports exactly what he suspected:

```
WRONG stale generated Zig — you would be testing the OLD compiler:
        CodeGen.zbr is newer than its .zig
WRONG bootstrap predates a preamble it embeds — a regen now emits the OLD runtime
```

So every measurement in the dossier below was taken against a compiler built from a
half-updated tree, including the delta-debugged "minimal repro", which reduced 1,400
lines to 6 and produced a confident and worthless result. The reduction was sound; the
oracle it was reducing against was not.

The dossier is kept rather than deleted because the failure is instructive: the
original report *states* that the compiler had been rebuilt from a tree with unresolved
merge conflicts, and proceeds anyway. The lesson is not "check the tree" in the
abstract — it is that `tools/doctor.sh` existed, took four seconds, and would have
stopped the whole hunt before it started. Run it before believing any compiler result.

The two secondary observations in the dossier still stand on their own and are worth
keeping: the emit-cache keyed by module basename can serve stale artifacts, and
`spawn failed` outside the repo root deserves a real error message.

**Original report follows, uncorrected.**


**DOES NOT REPRODUCE as of 2026-07-31 ~20:30, and the fixture is the response.**

The ticket's own minimal repro prints **8**. Built fresh from the text above and
deliberately NOT from the game files — the parallel session has
`examples/tears_of_the_tuon.zbr` and `tears_combat_test.zbr` modified in the working
tree, so anything derived from them would confound their edits with a compiler change.
The minimal case is independent of that.

`zebra run examples/tears_combat_test.zbr` now yields **zero** `except` errors. It fails
later, at `tears_combat_test.zbr:205`, on a GAME assertion:
`assert cm.phase == 15 and cm.story == 0, "the token seeks its reader"` — in-flight work
by whoever is editing those files, not a compiler fault, and not mine to touch.

**WHAT FIXED IT IS NOT ESTABLISHED, and I am not claiming it.** Two explanations fit and
neither is proven:

1. One of the seven compiler changes that landed the same day (BUG-230, 234, 236, 223,
   232, 142, 231). Nothing in that list obviously touches cross-module parsing, which
   makes this the weaker candidate.
2. **A transient tree state, which I would own.** The report cites a `zebra.exe` of
   07-31 14:47, and that window contains two of my regenerations that FAILED and
   restored `selfhost/*.zig` from a pre-run snapshot. A compiler built from a
   partially-updated tree can produce exactly this shape of confusing cross-module
   parse error, and `doctor.sh` exists precisely because that state makes results lie.
   Note the symptom fits it: the error text `syntax error near` appears **only in
   `src/`** — the bootstrap — so the failing parse was the bootstrap's, which is
   consistent with a mismatched selfhost/bootstrap pair mid-rebuild.

Explanation 2 is the one I would bet on, and it is a caution worth keeping: while a
rebuild cycle is in flight, this tree can hand another session a compiler that is not
what either of us thinks it is.

**GUARDED rather than closed.** `test/bug238_import_except_test.zbr` +
`test/bug238_except_lib.zbr`, registered `smoke_run` (not `smoke` — the failure was a
parse error in the DEP, which only a real import exercises). Smoke 262 → 263. Left OPEN
rather than marked FIXED, because a regression that stops reproducing without a known
cause has not been fixed; it has stopped being visible, and those are different.

**Symptom.** A module that parses and runs clean STANDALONE fails when loaded
via `use`: every `except` from the first enum-dotted arm onward reports
`syntax error near 'except'`. This re-broke the committed-green tears game
(last green at 1fa2b21): `zebra run examples/tears_combat_test.zbr` now emits
19 such errors from `tears_of_the_tuon.zbr`, first at the update() dispatcher.

**Minimal repro** (two files in examples/):

```
# lib_b238.zbr
struct P
    var a: int

enum Msg
    go
    stay

def update(m: P, msg: Msg): P
    branch msg
        on Msg.go    return m except a = 8
        on Msg.stay  return m except a = 9
    return m
```
```
# main_b238.zbr
use lib_b238 exposing P, Msg, update

def main()
    print(update(P(a: 1), Msg.go).a.toString())
```
`zebra run main_b238.zbr` → `lib_b238.zbr:11:31: syntax error near 'except'`.

**Controls (all verified 2026-07-31, zebra.exe of 07-31 14:47):**
- Same lib code with `def main()` appended, run STANDALONE → prints 8. PASS.
- Same shape with INTEGER arms (`branch k / on 0 ...`) under import → parses
  fine (fails later only if emit-cache is cold-deleted mid-run; unrelated).
- Multi-field vs single-field except: irrelevant — both fail on enum arms.
- Return-position except, forward-declared struct types, list-field except,
  top-level multi-field except: all PASS under import. The trigger is
  exactly: `on Enum.value    return expr except ...` in an imported module.

**Suspicion.** The import path retains (or falls back to) an arm-grammar
older than the main parser's — the dotted-value `on` arm seems to consume
the trailing return-expression with a reduced expression grammar that lacks
postfix `except` (BUG-204's old shape, resurrected inside `use`-loading).
Likely a second parse entry-point for imported modules that didn't get the
B12-era except productions, or a divergent copy of the arm parser in the
selfhost import loader touched by the recent TypeChecker/CodeGen merge.

**Two secondary observations from the same hunt (not filed separately):**
1. **Emit-cache staleness masks errors**: artifacts in `%TMP%` keyed by
   module basename (`<name>.zig`, `<name>.zig.fast.exe`) can serve stale
   results after the source changes — during diagnosis the same compile
   alternated pass/fail depending on leftover artifacts (cousin of
   BUG-235's stale-corpus lesson). A content-hash in the cache key would
   end the class.
2. **`spawn failed` when run outside the repo root**: zebra.exe appears to
   locate its zig/helper relative to CWD; from any other directory every
   compile dies with the bare message `spawn failed`. Worth an explicit
   error ("cannot find zig at <path>") and an exe-relative lookup.

**Assigned: Opus — with Fable's compliments; the tears game is the live
victim and its working tree (scribe-mission changes, uncommitted) is
waiting on this to go green.**

---

### BUG-236: signed `/` and `%` use MISMATCHED conventions; the division identity fails ✅ FIXED 2026-07-31

**FIXED 2026-07-31** (Sean took the recommendation). `%` now emits `@rem` instead of
`@mod`, in both compilers. One builtin: `/` is untouched, so no existing division
changes behaviour, and the pair now matches the language we compile to.

Verified: `(0-7) % 2` is `-1`, `7 % (0-2)` is `1`, and **`(a/b)*b + (a%b) == a` is
TRUE**. The gcd/lcm helpers keep `@mod` deliberately — they run Euclid's algorithm over
already-positive values, where the two agree. Guarded by
`test/boundary/bv_signed_division.zbr`, rewritten from pending to intent.

**Severity:** high (silent wrong arithmetic on negative operands, no diagnostic).
**Found:** 2026-07-31 by the A3 integer dimension. Confirmed at the emit level.

```zebra
(0 - 7) / 2      #  -3   (truncates toward zero)
(0 - 7) % 2      #   1   (floors -- sign of the DIVISOR)
7 % (0 - 2)      #  -1

var a = 0 - 7
var b = 2
(a / b) * b + (a % b) == a     # -> FALSE.  (-3)*2 + 1 = -5, not -7
```

**The division identity `(a/b)*b + (a%b) == a` does not hold.** That identity is not a
nicety; it is the definition of integer division and remainder, and essentially every
algorithm that mixes `/` and `%` on possibly-negative values silently assumes it.

**Root cause, straight from the emitted Zig** — codegen picks one convention for each
operator and they are not the same one:

```
6  @divTrunc     # `/`  -> truncate toward zero   (sign of the DIVIDEND)
5  @mod          # `%`  -> floor                  (sign of the DIVISOR)
```

Only two pairings are coherent, and Zebra is using neither:

| `/` | `%` | `-7/2` | `-7%2` | identity |
|---|---|---|---|---|
| `@divTrunc` | `@rem` | -3 | -1 | holds (C, Zig, Java, Go) |
| `@divFloor` | `@mod` | -4 | 1 | holds (Python) |
| **`@divTrunc`** | **`@mod`** | **-3** | **1** | **BROKEN — current** |

**Recommended fix: change `%` to emit `@rem`.** It is a one-builtin change, it keeps
`/` as it is (so no existing division changes behaviour), and it matches the language
Zebra compiles to. Switching `/` to `@divFloor` instead would also be coherent but
changes far more code and diverges from Zig for no stated reason.

Positive operands are unaffected — `7/2` and `7%2` agree under every convention — which
is why the whole corpus is silent on it. `output_sweep` could not have caught this
either: no corpus program takes a modulo of a negative, so there is nothing recorded to
regress from. Same shape as BUG-234, found by the same method for the same reason.

**QUICKSTART says nothing about either convention**, which is its own defect: the docs
mention `%` only as "use `%` for modulo". Whichever way this is resolved, the rounding
behaviour of both operators on negatives should be written down.

Pinned by `test/boundary/bv_signed_division.zbr`, a `@boundary-pending` probe recording
today's broken output — including `identity=false`, which is the row that should never
have been false and is the one to watch.

---

### BUG-235: the Luau-translated corpus went 1482 -> 849 compiling ✅ RESOLVED 2026-07-31 — STALE CORPUS

**RESOLVED — the corpus on disk was five weeks stale. Nothing was broken.**

Regenerated with the CURRENT translator (`--all --write-zbr`):

```
before (2026-06-16 corpus, measured today):   849 / 1780   47.7%
after  (regenerated today):                  1446 / 1581   91%
recorded in June for reference:              1482 / 1780   83%
```

The compile RATE is now well above June's, though the absolute count is slightly lower:
dedup removed 199 duplicate scripts, so the corpus is 1581 unique files, not 1780.

*(A 250-script sample of that run reported 100% and I briefly believed it. The sample
was the head of a sorted list and the easy scripts sort early — sampling a sorted corpus
by prefix is not sampling. The full-corpus number is the one above.)*

135 files still fail, dominated by 477 `resolver:undefined_ident` — Roblox APIs the shim
does not cover yet. Ongoing translator work, not a regression.

**Against 47.7% for the files that were sitting in `ported_scripts/`.** The regression was
never in the compiler and never in the translator — it was that `ported_scripts/` was
generated **2026-06-16** and the translator learned to emit `exposing` on **2026-06-20**,
with the robloxglobals shim injection following on **2026-06-30**. The corpus predates
its own fix by five weeks.

So the chain is: Zebra correctly tightened `use` to match its documented behaviour;
the June corpus depended on the old leniency; the translator was fixed four days later;
nobody regenerated. Every link is individually reasonable, which is exactly how a
633-file regression sits unnoticed for five weeks.

Corpus regenerated 2026-07-31 (`--all --write-zbr`). Sean's standing note: *"The corpus
is not intended to be locked in yet (as we are iterating toward a solution)."*

**THE LESSON IS THE ONE THAT SURVIVES, and it is not about `use`.** A generated artefact
was checked in, its generator improved four days later, and nothing connected the two.
There was no gate on the corpus and no staleness check on the generator — so a directory
of 1,780 files silently stopped representing what the toolchain produces.

That is the same shape as A5 (`examples/` ungated, shipping a broken file) and as the
`str_ownership.md` gate (a DERIVED doc that goes stale when codegen changes — and which
caught exactly that, twice, this week). The pattern worth generalising: **every generated
artefact under version control needs either a regeneration gate or a staleness check.**
`ported_scripts/` had neither; `str_ownership.md` has one and it works.

**Severity:** high if it is a compiler regression, none if it is deliberate — which is
exactly why it needs answering rather than filing away.
**Found:** 2026-07-31, incidentally, while trying to measure BUG-142's blast radius.
**Needs Sean**, because the resolution depends on project intent, not on code reading.

**The measurement, made with GameEngine's OWN harness so it is comparable to the
number on record** (`python tools/measure_corpus_compile.py 2000`):

| when | compiling | source |
|---|---|---|
| 2026-06-23 | **1482** / 1780 | recorded in BUG-142 above |
| **2026-07-31** | **849** / 1780 (47.7%) | measured today |

**~633 files that used to compile no longer do.**

**What has been ruled out, so this is not a guess about where to look:**

* **Corpus drift** — no. `git diff` of `ported_scripts/` between the June commit and
  HEAD is **empty**; the last regeneration was 2026-06-16, a week BEFORE the 1482
  reading. Same bytes in, different result out.
* **Corpus size** — no. 1780 files in June, 1780 now.
* **A different harness** — no. Same script, same `--emit-zig`, same cwd. Three
  independent instruments (that harness, a `-c` sweep, an `--emit-zig` sweep) all
  agree on **849** today.
* **Module resolution** — no, and this is the one worth recording because it was the
  obvious suspect. The dominant failure is `undefined name: 'RunService'` and friends,
  which looks exactly like a missing search path. It is not: copying **all 69**
  `zbra/*.zbr` modules next to the script reproduces the identical error. The scripts
  reference Roblox service globals **without importing the `robloxglobals` shim** —
  the translator commit that injects it (`401e0b3`) postdates the corpus regeneration.

**IDENTIFIED 2026-07-31 (Sean's question about the `RunSvc` shim led straight to it).**
The cause is **`use` no longer bringing a module's names into scope without `exposing`**.

```zebra
use run_service                      # what the translator emits
RunService.Heartbeat.Connect(cb)     # -> error: undefined name: 'RunService'

use run_service exposing RunService  # add ONE clause
RunService.Heartbeat.Connect(cb)     # -> compiles clean
```

Verified on a real failing corpus file: `0145_Script_Dancing_Shelly.zbr` goes from
`undefined name: 'RunService'` to **rc=0** with nothing changed but that clause.
Qualifying instead (`run_service.RunService()`) works too.

**The numbers line up.** **983** corpus files use a bare `use` with no `exposing`,
against **931** failures today. In June, 1780-1482 = 298 failed — so roughly 685 of
those bare-`use` files compiled *then* and do not *now*. Bare `use` used to expose
names and no longer does.

**RESOLVED IN ZEBRA'S FAVOUR — the compiler is behaving as DOCUMENTED.** QUICKSTART
§ module system spells out both forms, and has all along:

> `use math_utils exposing square, Vec2` → `square(5)` directly
> **"Without exposing — qualified access:"** `use math_utils` → `math_utils.square(5)`

So a bare `use` never *promised* to bind names, the June behaviour was leniency rather
than contract, and tightening it was correct. **The translator is the thing to fix**, and
this is not a Zebra bug so much as a Zebra bug-fix that nothing warned the corpus about.

Remaining decision is only about sequencing and blast radius:

* **(a) The translator is wrong.** `zbra/signal.zbr` — hand-written, not generated —
  already uses `use signal exposing SignalF, Signal`, so `exposing` is evidently the
  intended idiom and the translator was relying on leniency. Fix: emit `exposing`
  (or qualify). One place in `luau2zebra_ast.py`; likely recovers most of the 633.
* **(b) The change still shipped silently.** Even though the new behaviour is the
  documented one, a tightening that invalidates ~685 files in a sibling repo deserved a
  CHANGELOG line and a heads-up. That is the process gap worth keeping, separate from
  the code: **we hardened a semantic and had no way to see who was relying on the old
  one**, because that corpus is ungated. A5's shape (baselined, regress-only) applied to
  `ported_scripts` would have said so the same week.

Either way the corpus is the victim, and **nothing gates it**, which is why five weeks
passed. QUICKSTART should state the rule explicitly whichever way it is resolved — it
currently documents `use module_name` only in terms of module *resolution*, never
scoping.

**On the `RunSvc` shim in `robloxglobals.zbr` specifically** (Sean asked whether it
would help): the *shape* is right — a signal-with-connect — but it is not the useful
one, and renaming it would not have fixed this. `zbra/run_service.zbr` already defines
`class RunService` with PascalCase `Heartbeat`/`Stepped`/`RenderStepped`, matching the
corpus exactly, and the scripts already import it. `RunSvc` duplicates that with
lowercase fields and `connect`, so it matches the corpus *less* well than what is
already there. The missing piece was never the class shape; it was the import clause.

~~**Leading hypothesis, NOT established:** the Resolver became stricter about undefined~~
names sometime after 2026-06-23, turning a previously-tolerated condition into a hard
error. If so it is probably *correct* hardening — but with a 633-file blast radius that
nobody measured, because nothing gates this corpus.

**Confirming it means bisecting the Zebra compiler across ~5 weeks against this corpus.**
That is a real job and it was not started tonight; the point of this entry is that the
number on record is stale and must not be used as a baseline until it is explained.

**Immediate consequence — BUG-142 is blocked on this.** The 1482 figure is the baseline
the too-many/too-few promotion was to be judged against, and it no longer describes
reality. See BUG-142 for what was and was not measurable in the meantime.

**The structural point, which is the third instance of it in two days:** this is another
corpus that **no gate watches**. `examples/` was the first (A5, and it was already
shipping a broken file); this is the same shape at 100x the size and in a different repo.
The A5 pattern applies directly — a baselined, regress-only gate — and would have caught
this the week it happened instead of five weeks later.

---

### BUG-234: `str.reverse()` byte-reverses, turning valid UTF-8 into invalid ✅ FIXED 2026-07-31

**FIXED 2026-07-31** (Sean took the recommendation — option (a), codepoint-aware).
New preamble helper `_str_reverse` walks the string codepoint by codepoint and copies
each one's bytes intact into descending slots, so byte order WITHIN a codepoint is
preserved while codepoint order reverses. Invalid UTF-8 input falls back to a byte
reverse instead of panicking: `reverse()` has no way to report an error, and
garbage-in-garbage-out beats aborting a user's program over a string we were only asked
to turn around. Both compilers call the same helper — one helper, not the old inline
blob duplicated at two emit sites each.

Verified: `"世界".reverse()` is now `"界世"`, valid, 2 codepoints; `"aé中b"` reverses to
`"b中éa"`; ASCII unchanged. Guarded by `test/boundary/bv_reverse_nonascii.zbr`, which
was rewritten from its pending form to assert the intent it was authored with.

**Severity:** high (a stdlib call silently converts valid text into non-text).
**Found:** 2026-07-31 by the A3 non-ASCII dimension, from a row written specifically
because a byte reverse and a codepoint reverse differ exactly here.

```zebra
var c = "世界"                 # valid UTF-8, 2 codepoints, 6 bytes
var rev = c.reverse()          # expected "界世"
rev.isValidUtf8()              # -> false
rev.codePointCount()           # -> 0      (from input that had 2)
rev.len                        # -> 6      (bytes preserved, order shredded)
```

Not a CJK-only or 3-byte-only edge — `"é".reverse()` is invalid too, so it is
**every multi-byte codepoint**. ASCII is unaffected (`"abc".reverse()` is `"cba"`,
valid), which is exactly why nothing noticed: the corpus reverses ASCII.

**Why no gate saw it.** `output_sweep` compares what programs PRINT against a golden
baseline, and no corpus program reverses non-ASCII — so there was nothing to record
and nothing to regress from. This is the golden-baseline limitation in its purest
form: it can only ever tell you behaviour CHANGED, never that it was wrong on day
one. Only an expectation written from the reference could find it, which is the
argument A3 exists to make.

**TWO LEGITIMATE RESOLUTIONS, and they are different decisions — Sean's call:**

* **(a) Make `reverse()` codepoint-aware**, so it cannot produce invalid UTF-8.
* **(b) Declare it a BYTE operation and say so**, as was done for the ASCII-only
  `is…` predicates (also found this week, also a doc-vs-implementation gap).

What is **not** defensible is the current state: documented as "Reverse the string",
implemented as a byte operation, and silently manufacturing invalid UTF-8. Note that
(b) still leaves a stdlib call that turns valid text into invalid text with no
warning, which sits badly in a language whose headline feature is contracts. My
recommendation is (a), with (b) acceptable if reverse() is meant to be a
byte-layer primitive — in which case it should arguably be named for that.

**IS THE CODEPOINT LAYER LOAD-BEARING? Measured 2026-07-31, because Sean asked the
right question — whether anything needs codepoints, or whether the code merely takes
what the API hands it. It is the second, and that decides how risky a fix is.**

| layer | uses across `*.zbr` (boundary probes excluded) |
|---|---|
| codepoint: `.chars()` | 27 — and several are *codegen implementing* it, not consuming it |
| codepoint: `.codePointCount()` | 15 |
| byte: `c'x'` literals | **559** |
| byte: `.len` in `selfhost/` alone | **1056** |

And every consumer that was read is doing **ASCII** work:

* `main.zbr:682` — `diagAllDigits`: compares against `'0'`..`'9'`
* `main.zbr:950` — counts `'\n'` to size an LSP edit range
* `AstBuilder.zbr:1125` — matches `c'('` / `c')'` to track paren depth

None of those need decoding; each would behave identically over bytes, and decoding
UTF-8 to count newlines is strictly slower for no gain. **The compiler reaches for
`.chars()` because it is the API for "walk the characters", not because the task is
Unicode.**

**Two consequences, and they point the same way:**

1. **Fixing `reverse()` is nearly risk-free for us.** Nothing in the compiler reverses
   non-ASCII — nothing in the compiler reverses much of anything — so a codepoint-aware
   `reverse()` cannot regress the codebase that would have to live with it. The usual
   argument against touching string semantics (a 559-site rewrite, per §28e's reasoning
   about `char`) **does not apply here**: that argument is about the `char` TYPE, which
   this does not touch.
2. **The beneficiaries are downstream, not us.** The people a correct `reverse()`
   protects are those processing real text — names with accents, the Greek NT stylometry
   work, game dialogue. Zebra's own corpus is the *least* representative sample of that,
   which is exactly why an intent-written probe found this and 335 corpus files did not.

So the recommendation above (make `reverse()` codepoint-aware) is not merely the tidier
option; it is the one whose cost falls almost entirely on a code path nobody uses, and
whose benefit falls on the users 0.9 is meant to be ready for.

Pinned by `test/boundary/bv_reverse_nonascii.zbr`, a `@boundary-pending` probe that
records today's broken output and will FAIL when this is fixed — the signal to
rewrite it to assert `cjkRevValid=true` / `cjkRevCps=2` / `cjkRev=[界世]`.

**It also caught a bug in the boundary harness itself:** a probe whose output is
invalid UTF-8 made `grep` treat the stream as binary, print `Binary file ... matches`
and DROP the row — which read as "that line was never printed" rather than "the
harness ate it". Fixed with `grep -a`. A suite whose whole job is odd inputs must not
be blinded by an odd input.

---

### BUG-232: argument-count checking is SKIPPED inside containers ✅ FIXED 2026-07-31

**PARTIAL FIX 2026-07-31 — and the bug turned out to be much larger than reported.**

It was filed as "arity checking is skipped inside `${...}`". Enumerating `Expr`'s **34
variants** against `checkCallsInExpr`'s arms showed it handled **eight**. Interpolation
was the visible symptom of a walker that was missing nearly every container: list, set,
array and tuple literals, dict literals, `orelse`, `catch`, slices, optional chains,
chained comparisons, `except` updates, `is` checks, and `old()` were ALL unchecked.
Verified before fixing rather than assumed — `add(1)` warned as a statement and was
silent in a list literal, an orelse and a tuple.

**Fixed for all of those** (15 new arms). Confirmed: list literal, tuple literal,
`orelse`, dict literal and slice all now warn where they were silent.

**FULLY FIXED, including `${...}`.** The interpolation arm resisted six spellings until
the cause turned out to be an **import list**: `StringPart` was missing from this
module's `use Ast exposing ...`. See BUG-237 — without it, codegen never registers the
union's boxed variants, so the `^Expr` payload emits as a raw pointer. Adding
`StringPart` to the exposing list produced the deref immediately.

*(Original note, kept because the hunt is the useful part:)* it was not fixed for
`${...}`, the case originally reported and the one `StringPart.expr_` carries a `^Expr`, and a `^T` bound from a union
payload does not auto-deref when passed — six spellings tried, all emitting a pointer
Zig rejects. Filed as **BUG-237**; that blocks the last arm. The pending probe stays.

**Severity:** high (silent wrong behaviour, in the language's most common idiom).
**Found:** 2026-07-30 by the A3 boundary suite (`test/boundary/`), from the
argument-arity dimension. **Both compilers behave identically.**

```zebra
def add(a: int, b: int): int
    return a + b

var r = add(1)              # warning: too few arguments to 'add': expected 2, found 1
print("${add(1)}")          # NO diagnostic at all — prints 1
```

The same asymmetry holds for too MANY arguments: extras are warned about in a
statement and silently discarded inside an interpolation. The missing argument is
padded with a deterministic zero (BUG-142's partial fix), so the program runs and
prints a plausible wrong answer rather than failing.

**Why this one matters more than its siblings:** `print("${f(...)}")` is the most
common shape in Zebra, so this is the context where a user is *most* likely to make
an arity mistake and *least* likely to be told about it.

**Scope check, so this is not over-claimed** — not everything is skipped in an
interpolation. Unknown-method resolution still fires normally, and type mismatches
are still caught, but *degrade* from a Zebra diagnostic with a caret to a raw Zig
error pointing at the wrong line. Arity is the only check found to be absent
outright.

Pinned by `test/boundary/bv_arity_interp_unchecked.zbr` (a `@boundary-pending`
probe: it asserts today's wrong output and will FAIL when this is fixed, which is
the signal to rewrite it as an assertion of the intended warning). Control:
`bv_arity_too_few.zbr` proves the check exists outside interpolation.

---

### BUG-229: TUI apps SEGFAULT at startup — selfhost emit never assigns `_tui_env` ✅ FIXED 2026-07-30

**Fixed** in `selfhost/CodeGen.zbr` (root-`main` injection block): added the
`if _gui_backend == "tui"` → `_tui_env = _zinit.environ_map;` emit, placed in the
**bootstrap's position** — after the arena defer, before dep propagation — so the two
injection blocks stay diffable. This bug existed *because* they drifted; keeping them
alignable is most of the defence against a fifth instance.

Verified end to end: the scaffolded `main.zig` now assigns `_tui_env` (line ~3934) before
`Terminal.init` dereferences it, and the built app gets **past** the crash site — it now
reaches `enableRawMode` and fails cleanly with `GetConsoleFailed` when run with no
console, which is correct behaviour rather than a segfault.

**Regression guard: `tools/gui_scaffold_check.sh`** — the first check in this repo that
looks at a GUI path at all. Deliberately aimed at the *class*, not the symbol:

* **Leg 1 (static, and the one that gates):** every global the scaffold declares as
  `= undefined` must be assigned somewhere in the same file. Naming only `_tui_env` would
  let the next sibling through silently. Falsified on a doctored scaffold.
* **Leg 2 (runtime, best-effort):** classify by the FAULT, not the exit code and not the
  word "panic". A healthy headless tui app panics with `gui init failed` and exits 3 —
  correct. The BUG-229 signature is a *memory* fault (`memcpy` at `0x0`). The first
  version of this leg called the healthy case a crash and would have reported this very
  fix as still broken.

Still uncovered, and printed in the tool's own output so it cannot be forgotten:
rendering, input, layout, resize, colours. Those need a human. What changed is the line —
from "no gate touches a GUI" to "no gate touches a GUI **beyond startup**", and all four
GUI crashes to date lived at startup.

**RE-CONFIRMED BY SEAN 2026-08-01, and this one covers the whole week.** After eight
compiler changes landed (BUG-230/234/236/223/232/142/231 + the walker completion), Sean
ran BOTH selfhost GUI backends and reported they "looked good and behaved like I'd
expect": `--gui-backend=tui`, and `--gui-backend=libui_ng` on `counter.zbr` and
`widget_smoke.zbr`.

`widget_smoke` is the one that mattered: it is the file BUG-230 was silently breaking
(`var items: List(str) = ["Apple", ...]` feeding a combobox), so this is the fix
verified on a RENDERED CONTROL rather than merely compiling. Three of the week's changes
touch what GUI code leans on — annotated list literals, string-interpolation lexing, and
arity severity — and none of them is provable by any gate at the pixel level.

**CONFIRMED BY SEAN 2026-07-30**: `--gui-backend=tui examples/counter.zbr` runs and
renders correctly. That is the only verification that can close a GUI bug — the gate
proves it starts, a human proves it works.

*Diagnosis by Fable (dossier, root cause, and fix sketch); implementation and guard by
Opus. The dossier was accurate in every particular.*

---

<details><summary>Original report (Fable)</summary>
Found 2026-07-30 by Sean running `--gui-backend=tui examples/tears_of_the_tuon.zbr`
(the fourth GUI crash to sit under green gates, per house prophecy: no gate runs a GUI).

**Symptom:** immediate `Segmentation fault at address 0x0` in `memcpy`, reached from
zigzag `terminal.zig:1801 envVarExists` → `environ_map.get(name)` during
`Terminal.init` → `setup()` → `detectUnicodeWidthCapabilities()` →
`looksLikeKittyTerminal(self.environ_map)`. Reproduces headlessly too (the earlier
"run exe app failure" in scripted runs was THIS, misread as no-console).

**Root cause (diagnosed, high confidence):** the scaffolded app's `main.zig` declares
`var _tui_env: *std.process.Environ.Map = undefined;` (template line — scaffold
main.zig:3038) and passes it to `zz.Terminal.init(_io, _tui_env, …)` (:3046) but
**never assigns it**. The bootstrap's CodeGen has the assignment — `src/CodeGen.zig`
~:6431, inside the root-`main` injection block:

```zig
if (g.gui_backend == .tui) {
    … writeAll("_tui_env = _zinit.environ_map;
");
}
```

— but the **selfhost** mirror of that injection block (`selfhost/CodeGen.zbr` ~:4346,
"Root entry point (Zig 0.16): inject _io/_args/_allocator init", which emits
`_io = _zinit.io;` / `_args = _zinit.minimal.args;` / `_allocator = _prog_alloc();`)
is MISSING the tui-conditional line. Since GUI scaffolding moved to selfhost emission
(NEXT_STEPS "GUI builds via selfhost emission"), every tui app gets the undefined
pointer. A selfhost-lags-bootstrap gap — same family as BUG-204/205/206, opposite era.

**Fix sketch (four lines):** in `selfhost/CodeGen.zbr` inside the `owner == "" and
m.name == "main"` injection block (~:4346), after the `_allocator` emit, add the
equivalent of:

```
if <gui_backend is tui>          # selfhost carries it as `_gui_backend: str` (~:1299)
    ei.writeIndent()
    ei.w.emit("_tui_env = _zinit.environ_map;
")
```

Check how `_gui_backend` reaches CodeGen (module var, set ~:1303) — the condition
should match however the tui section-inclusion already branches. Then the full drill:
`bash tools/rebuild.sh` (this is a selfhost/*.zbr edit → regen matters), re-scaffold a
tui example, and RUN the app (`doctor.sh` first per house law). A `smoke_run`-style
check that the scaffolded app at least *starts* headlessly (init past Terminal.init,
then immediate q) would be the regression guard this class has never had.

**Assigned:** Opus — with Fable's compliments: diagnosis complete, fix located,
one four-line edit + the rebuild drill, and the honor of closing the fourth
GUI crash. (Repro: any `--gui-backend=tui` run of any example.)

</details>

---

### BUG-224: `format()` with 2+ arguments emitted invalid Zig ✅ FIXED 2026-07-29
Found while deriving the §28e ownership table. Both `format` dispatch sites emitted a
**separate** `.{ x }` tuple per argument, but `std.fmt.allocPrint` takes exactly three
arguments — `(allocator, fmt, args_tuple)`:

```zebra
var r = "{} and {}".format(1, 2)
```
```zig
// before — 4 arguments, does not compile
(std.fmt.allocPrint(_zbr_rt._allocator, "{} and {}", .{ 1 }, .{ 2 }) catch unreachable)
```
```
f1.zbr:2: error: expected 3 argument(s), found 4
```

The 1-argument case emitted `.{ 1 }` and worked by coincidence, which is why nothing
caught this: **every existing call in the corpus passes exactly one argument.** A
0-argument call emitted no tuple at all and passed only 2, so it was equally broken at
the other end.

Fixed in `selfhost/CodeGen.zbr` at both dispatch sites (~12420 and ~13697): one tuple,
comma-separated, always emitted — which also fixes the 0-arg case (`.{ }` is a valid
empty tuple). Regression fixture: `test/bug224_format_multiarg_test.zbr`, which
deliberately keeps 2-, 3-, mixed-type and computed-argument calls, since a regression
here is a compile failure rather than a wrong value.

---

### BUG-223: `str.charAt` is typed `str` but emits `u8` ✅ FIXED 2026-07-31

**FIXED** — `charAt` now types as `byte` (`Type_.uint_n(8)`), which is what it has always
emitted. Sean delegated the call ("I'm not sure what to suggest") and took the
recommendation: retype rather than remove, because it leaves users an **honest byte
accessor**, which `s[i]` currently is not.

It was free, and provably so: the old typing made every consumer a compile error, so
`grep -rn '\.charAt('` returned **zero callers** repo-wide and it was absent from
QUICKSTART. Nothing could regress because nothing could compile.

This is the CHEAP half of §28e's byte/codepoint split. **BUG-225** (`s[i]` typed `char`
while holding a byte) is the expensive half — ~104 subscript sites in `selfhost/` and
559 `c'x'` literals comparing against the result — and stays deferred to 1.x.

Guarded by `test/boundary/bv_char_at.zbr`, which asserts the byte values and that
arithmetic on the result works, since being a number is the point of the retype.

Found 2026-07-29 while closing #5a's doc gaps. The TypeChecker and codegen disagree:

* `TypeChecker.stringMethodReturn` (~1340) groups `charAt` with `substring` and returns
  `Type_.string_`.
* codegen (`CodeGen.zbr` ~13560) emits `s[@intCast(i)]`, and indexing a `[]const u8`
  yields **`u8`**.

```zebra
def main()
    var s: str = "abc"
    var c = s.charAt(0)
```
```
c2.zbr:3: error: expected type 'str', found 'u8'
```

Note the missing COLUMN: the diagnostic comes from Zig via the remapper, not from the
front end, which is the BUG-215/BUG-218 shape — the type checker believed something
untrue, so it had no complaint of its own to make. Printing it directly is worse
(`invalid format string 's' for type 'u8'`, pointing into std).

**Also unguarded:** the emit site is `if mname == "charAt" and args.len > 0`, so
`s.charAt()` with no argument falls through to another path entirely — the BUG-222
family. `charAt` is absent from QUICKSTART's method tables, so #5a's arity table does
not cover it and cannot catch that yet.

**Needs a design call before a fix, because it is user-facing API.** The name says
char, the implementation says byte, and Zebra has distinct `char` (u21) and `byte` (u8)
types plus a `bytes()` iterator. Recommendation: make it `byte` — that matches the
implementation and `bytes()`, costs no codegen change, and `s[i..j]`/`chars()` already
cover the other two intents. Whichever is chosen, it then belongs in the QUICKSTART
table so the arity checker picks it up.

**Blast radius measured 2026-07-29 (§28e): ZERO, and the method is not merely mistyped
— it is unusable.** Every way of consuming the result is a compile error today, so no
working program can contain a call:

```
print(s.charAt(0))          -> error: expected type 'str', found 'u8'
s.charAt(0).concat("!")     -> error: no field or member function named 'concat' in 'u8'
```

`grep -rn '\.charAt(' --include='*.zbr'` across the whole repo — `test/`, `selfhost/`,
`examples/`, `IDE/` — returns **no callers**, and it is absent from QUICKSTART. There is
therefore nothing to break: retyping it to `byte` cannot regress a caller, because a
caller cannot currently compile. `byte` already exists as a documented type (`u8`,
QUICKSTART line 242), so this needs no new type either.

Note the asymmetry with BUG-225, which is the *same* byte-vs-codepoint incoherence in
`s[i]`: that one is silently WRONG (it compiles and prints a character not in the
string) and expensive to fix, while this one is loudly broken and free to fix. Fixing
BUG-223 also leaves users an honest byte accessor, which `s[i]` is not.

**The exact change, ready to apply on approval.** `selfhost/TypeChecker.zbr` ~1340 —
`byte` resolves to `Type_.uint_n(8)` (see the same file ~593), so no new type is needed
and codegen is already correct:

```diff
-    if name == "substring" or name == "charAt"
+    if name == "substring"
         return Type_.string_
+    # BUG-223: charAt emits `s[i]`, and indexing a []const u8 yields u8 — a BYTE, not a
+    # str. Grouping it with substring typed it `str`, which made every use of the result
+    # a compile error and left the method with zero callers repo-wide.
+    if name == "charAt"
+        return Type_.uint_n(8)
```

Four things ship with it, or the fix is half-done:
1. Guard the emit site. It is `if mname == "charAt" and args.len > 0`, so a 0-arg
   `s.charAt()` still falls through to an unrelated path — the BUG-222 family.
2. Add it to QUICKSTART's method tables (it is absent today). There is no "Returns
   `byte`" table yet, so one is needed — which is also the honest place to say that
   `bytes()` and `charAt()` are the byte-level pair.
3. Regenerate `tools/stdlib_signatures.tsv` from QUICKSTART, which then gives arity
   checking for free and closes item 1 from the other side.
4. A fixture asserting the result is usable as a byte (arithmetic, comparison to a
   `byte`), since "it compiles at all" is the entire regression risk here.

---

### BUG-222: stdlib calls accept TOO FEW arguments — `s.count()` compiles and panics ✅ FIXED 2026-07-29
Found 2026-07-29 by the #5a signature tooling, which probes each documented method at
reduced arity to learn which trailing arguments default. Seven `str`/`List` rows accept
zero arguments. Three are genuine defaults; **four are silently-dropped arguments**, the
mirror image of BUG-215 (which was about too MANY).

```zebra
def main()
    var s: str = "ab"
    print(s.count().toString())     # compiles clean
```
```
thread 4680 panic: reached unreachable code
```

`s.count("ab")` correctly returns 2. Dropping the argument type-checks, emits, links,
and dies at runtime with no diagnostic — the same "typo becomes a runtime panic three
frames away" shape that made BUG-215 worth fixing.

| call | accepted? | actual behaviour |
|---|---|---|
| `s.padLeft(5)` / `padRight` / `center` | yes | **genuine default** — pads with spaces |
| `s.count()` | yes | **PANIC**, reached unreachable code |
| `s.split()` | yes | returns 1 element (silently wrong) |
| `s.concat()` | yes | identity — harmless but meaningless |
| `List(str).join()` | yes | joins with no separator |

**FIXED 2026-07-29 by #5a (`9d713bc`).** `s.count()` is now
`error: str.count expects 1 argument, got 0` at the user's own line and column.
Verified in both directions by `tools/stdlib_sig_check.py`: the run that originally
reported "7 rows accept FEWER args than required" now reports none, and every row is
also checked at max+1 to prove the check is actually firing rather than the gate
merely agreeing with itself.

**Original analysis:** this is what #5a is for. The verified arity table (`tools/stdlib_arity.tsv`,
min..max per receiver kind) already records that `count` requires 1; once the
TypeChecker consults it, `s.count()` becomes a Zebra diagnostic with a caret instead of
a panic. Tracked there rather than fixed separately — a one-off guard on `count` would
leave the other three, which is exactly how BUG-215 ended up as a single `@compileError`
on `indexOf` while the rest of the surface stayed unguarded.

**Note on method:** the probe that found this originally *encoded* these as legal
minima, because probing measures what the compiler tolerates and what it tolerates is
the bug. Separating real defaults from dropped arguments required RUNNING them. A tool
that learns a specification from a defective implementation will faithfully record the
defect as the specification.

---

### BUG-221: module init is not TRANSITIVE — a 3-module program crashes if the deepest dep does I/O ✅ FIXED 2026-07-28
The entry point initialises **direct dependencies only**. A module that is itself only
reached through another module never receives `_initAllocator`/`_initIo`, so its `_io` and
`_allocator` stay `undefined` and the first use segfaults.

**Reproduced 2026-07-28** — three files, nothing exotic:

```zebra
# leaf.zbr
def readIt(p: str): str
    if File.exists(p)
        return File.read(p)
    return "missing"

# mid.zbr
use leaf exposing readIt
def viaMid(p: str): str
    return readIt(p)

# top.zbr
use mid exposing viaMid
def main()
    print(viaMid("nope.txt"))
```

| depth | result |
|---|---|
| `main` → `leaf` (direct dep does the I/O) | works — prints `missing` |
| `main` → `mid` → `leaf` (transitive) | **`Segmentation fault at address 0xffffffffffffffff`** |

The stack carries `0xaaaaaaaaaaaaaaa9` — Zig's poison pattern for `undefined`, confirming
the pointer was never initialised rather than corrupted.

**Mechanism, confirmed in the emit:** `top.zig` emits
`@import("mid.zig")._initAllocator(_allocator);` for each `use` in the ENTRY module only.
`mid.zig` *defines* `_initAllocator`/`_initIo` but never calls them on `leaf.zig`. So init
reaches depth 1 and stops.

**This was previously tracked as "Selfhost `_initIo` propagation gap — harmless today;
would bite if a transitive dep gains file I/O. Track for 1.0 pre-flight."** It is not
harmless and it does not need a future trigger: any three-module program whose deepest
module touches a file crashes today. Re-filed as a bug with a repro and promoted out of
the "track for later" list.

**Fix direction:** make init transitive. Either (a) emit a propagating `_initIo`/
`_initAllocator` in `generateModuleWith` so each module initialises its own `use` deps
(watch for cycles — needs a visited set), or (b) let the single-file emission
(`docs/single_file_emit_design.md`) dissolve it: one preamble, one `_allocator`/`_io`, no
fan-out at all. That design note already lists **deleting this fan-out** as one of its
wins, so BUG-221 is a third independent argument for it (alongside BUG-220's `@export`
residual and error-location legibility).

**RESOLVED under `--runtime-module` (2026-07-28).** Route (b) was taken, via the runtime
module rather than single-file emission: the runtime holds ONE `_allocator`/`_io` that
every module shares at any depth, so there is nothing to propagate, and the entry point
drives `_initModuleVars()` over the **transitive** dep list instead of direct `use` decls.
The repro above now prints `missing` where it segfaulted. Gated by
`tools/runtime_module_check.sh` (QUICK tier) — the only gate that runs anything emitted
in this mode, and therefore the only one that can see this bug.

Note the fix is smaller than "delete the fan-out": `_allocator`/`_io` genuinely stop
needing propagation, but each module's own `_initModuleVars` still has to be REACHED —
which is precisely the transitivity that was missing.

**CLOSED on the default path 2026-07-28 (`ade34cf`)**: runtime-module emission is now the
default, so this needs no flag. The repro prints `missing`.

**The inline path was fixed separately, 2026-07-29.** Closing this on the default path
left the bug LIVE wherever the inline runtime is still emitted — `--no-runtime-module`,
and as the fallback for `--single-file`, `--target node-addon` and every `--gui-backend`.
Verified rather than assumed: the fixture segfaulted there exactly as before, and the
emitted entry point initialised `mid` but never `leaf`. The cause was the same in both
shapes — the fan-out walked DIRECT `use` decls — so the fix is the same: sweep the
TRANSITIVE dep list the driver already computes. With an inline runtime each module owns
its `_allocator`/`_io`, so both still have to be propagated; only the reach was wrong.

Both shapes are now gated by `tools/runtime_module_check.sh`, which runs the fixture with
and without `--no-runtime-module`. Fixing one path and documenting the other as "latent"
was the wrong call: a multi-module GUI app touching a file from depth 2 would have hit a
segfault that was already understood and already fixed twenty feet away.

---

### BUG-220: ANY top-level `def` whose name matches a preamble identifier fails to compile ✅ FIXED 2026-07-28
A user function named `f` emits Zig that will not compile:

```
t.zig:255:35: error: function parameter shadows declaration of 'f'
        pub fn map(self: @This(), f: anytype) _Result(
                                  ^
```

The stdlib preamble's `map` takes a parameter named `f`, and a top-level user `def f` becomes a
file-scope declaration that it shadows. The user never mentions `map`; merely *naming a function
`f`* breaks the build, with an error pointing into preamble code they did not write.

Found while reproducing BUG-219 (the 5,952 bytes of stderr that deadlocks `sys.run` are this
error and its reference trace).

**MEASURED SCOPE 2026-07-28 — far larger than one name.** Zig makes it an error for a function
parameter or local to shadow a file-scope declaration, and user top-level `def`s emit as
file-scope declarations. So a user function collides with *any* preamble parameter or local
anywhere in the 186 KB preamble. Tested by emitting `def NAME(a: int)` + `main` and running
`zig build-exe`:

| Name | Result | | Name | Result |
|---|---|---|---|---|
| `f` | FAIL | | `count` | **FAIL** |
| `g` | FAIL | | `data` | **FAIL** |
| `x` | FAIL | | `body` | **FAIL** |
| `s` | FAIL | | `buf` | **FAIL** |
| `self` | FAIL | | `color` | **FAIL** |
| `item` | FAIL | | `total` | **FAIL** |
| `acc`, `key`, `val` | FAIL | | `parse` | OK |

**15 of 16 tested names fail.** Extracting every non-`_`-prefixed identifier from the preamble
gives **423 names, 293 of them ≤6 characters** — including `count`, `data`, `body`, `buf`,
`ctx`, `conn`, `depth`, `chunk`, `color`, `copy`, `cur`, `child`. These are not exotic; they
are the names a person reaches for first. The error they get points into preamble source they
did not write.

**Class, not instance** — same shape as the CherryCobbler finding where an identifier named
`fn` emitted a Zig keyword: **user identifiers share a file-scope namespace with compiler
internals.** Two candidate fixes:
1. **Prefix every preamble parameter/local** with `_` so collision is impossible by
   construction. Mechanical but touches 423 identifiers.
2. **Emit user declarations inside a namespace/struct instead of at file scope.** This is
   *already designed* — `docs/single_file_emit_design.md` specifies exactly that ("all modules
   → one .zig, namespaced structs"). BUG-220 is an independent argument for that work: it was
   justified on architecture grounds, and it would dissolve this whole bug class as a
   side-effect. Worth adding to that design note's motivation.

**FIXED — by (1), on Sean's call: prefix unconditionally.** Top-level `def`s now emit under
the reserved `_zbr_fn_` prefix, exactly mirroring `_zbr_mv_` for module vars. Prefixing is
unconditional rather than only-on-collision by explicit decision: a conditional form needs a
hand-maintained list of preamble identifiers, and a parallel list that drifts is the bug class
the Build failure came from. Selfhost-only — round-trip compares selfhost-A against selfhost-B
and *both* prefix, so byte-identity holds without touching the bootstrap, which continues to
emit `selfhost/*.zig` unprefixed and only has to compile it.

**Reference sites covered** (each of the last five was found by a gate, not by reading):
| Site | Where |
|---|---|
| declaration | `genMethod`, gated `owner == "" and not in_namespace` |
| direct call + by-value reference | `genIdentRaw`, with BUG-137's shadow guard |
| fn-ref **var binding** (`var p = isDigit`) | writes the name directly, `&`-prefixed |
| fn-ref **reassignment** (`p = isDigit`) | same, separate path — caught by full_sweep |
| cross-module alias | `genUse`, prefixed on **both** sides |
| `zebra test` harness | `generateTestEntryPoint` calls tests by name — 10 smoke failures |
| generic call `identity(int)(42)` | `genCall` writes the callee directly |

Not prefixed, correctly: class methods and `namespace` members (already namespaced inside a
struct — `genNamespace` needed an explicit `in_namespace` flag because it emits through a
Generator copy that still has `owner == ""`).

The naming rule lives in **one** module-level function, `zbrFnSymbol(name, is_export)`; the
Generator method and the test-harness emitter both route through it, so the two copies cannot
drift.

**Residual limitation:** `@export` and `@node_export` functions keep their source names,
because for those the ABI symbol *is* the name. So `@node_export def count(...)` remains
exposed to the original collision. Narrow, and the tradeoff is right, but real. (For
`@node_export` specifically it would be fixable — the JS export name comes from a string, not
the Zig symbol — but the napi wrappers call the underlying function by name and it is not worth
the risk for a niche case.)

Note (2) — namespaced emission — remains the deeper fix and would also cover the export cases;
this does not remove the argument for it, it just stops the bleeding now.

---

### BUG-219: `sys.run` DEADLOCKS when a child writes more than a pipe buffer to stderr → `zebra -c` hangs on any program with errors ✅ FIXED 2026-07-28
`_sys_run` (`selfhost/stdlib_preamble.zig:459`) drains the child's pipes **sequentially**:

```zig
if (child.stdout) |f| { ... allocRemaining(...) }   // reads stdout to EOF FIRST
if (child.stderr) |f| { ... allocRemaining(...) }   // only then reads stderr
const term = child.wait(_io) ...
```

If the child fills its **stderr** pipe buffer, it blocks writing. Blocked, it never exits, so
its **stdout** never reaches EOF, so the parent never finishes its first read and never starts
draining stderr. Deadlock — both sides waiting on the other, forever.

**Reproduced 2026-07-28.** A five-line program:

```zebra
def f(a: int)
    print(a.toString())

def main()
    print("hi")
```

`zebra -c` on it runs for **>180 s with 0.25 s of CPU** — blocked, not spinning — and never
returns. The emitted Zig makes `zig build-exe` produce **5,952 bytes** of stderr (see BUG-220
for *why* that program fails to compile), comfortably past a 4 KB pipe buffer.

**Why this one matters more than it looks:** `-c` is *check* mode. It exists to report errors,
and it deadlocks precisely when there are enough errors to report — clean programs pass, broken
ones hang. It is also what `IDE/ZebraIDE.zbr`'s **Check** button runs (`CompilerBridge.check`
→ `zebra -c <file>`), so checking a file with a handful of errors hangs the IDE.

This is the **same family as BUG-208** (`zebra run` blocking on a ~4 KB pipe), which was fixed
for the run path via `exec_inherit` — and whose note explicitly said *"other `sys.run` callers
still limited (follow-ups)."* This is that follow-up, now with a concrete repro.

**Fix direction:** the parent must not serialise the two reads. Options, cheapest first:
**FIXED — by delegating to `std.process.run`.** The Zig standard library already solves this:
its `run()` drains both streams concurrently through `Io.File.MultiReader`. `_sys_run` now calls
it instead of hand-rolling the reads. That preserves the contract (both streams + exit code),
deletes the read-ordering bug rather than reordering it, and puts the tricky part upstream where
it is maintained. (The temp-file redirect I had planned would also have worked, but re-deriving
a solution the stdlib ships is the wrong trade.)

**Verified:** the 4-minute deadlock now completes in **1.09 s** and reports its error; stress-
tested against an emit producing **29,593 bytes** of child stderr — 7× a pipe buffer, previously
a guaranteed hang — 1.2 s, captured correctly. Gates: smoke 257/257, round-trip byte-identical,
compile_check 215/0/1 (load-bearing here, since the preamble is inlined into every emitted
program). Fixes the class, not just `-c`: `sys.run` is also used by `CompilerBridge` and the
build tooling.

---

### BUG-218: `str + int` is diagnosed in an annotated context but LEAKS to Zig in a call argument ✅ FIXED 2026-07-28
Found 2026-07-27 while auditing the book: chapter 1 promises *"When you make a mistake,
Zebra tells you clearly"* and shows a clean Zebra-level diagnostic for `"Hello " + 5`.
The compiler only delivers that when there is a type to check against:

| Written as | Diagnosed by |
|---|---|
| `var s: str = "Hello " + 5` | **Zebra** — `error: expected type 'str', found 'comptime_int'` ✅ |
| `var n: int = 5` … `var s = "Hello " + n` | **Zebra** — `error: expected type 'str', found 'i64'` ✅ |
| `print("Hello " + 5)` | **Zig** — `e.zig:3779:54: error: expected type '[]const u8', found 'comptime_int'` ❌ |

In argument position there is no annotation to drive the check, so the bad concat reaches
codegen and the user gets an error pointing at *generated Zig* (`_str_concat`, a line
number in a 3,800-line emitted file) for a plain type mistake in their own source. This is
the `docs/error_experience_audit.md` class, and it is the single most likely first error a
newcomer hits — string-plus-number in a `print` is the canonical beginner slip.

**Fix direction:** type the operands of `+` when either side is known to be `str` and reject
a non-`str` operand at the Zebra level, independent of whether an expected type is in play.
The TypeChecker already reaches the right answer with a target type; it needs to run the
same check bottom-up. Related to the arity gap noted under BUG-215 — both are "the front
end declines to check something it has enough information to check."

**FIXED 2026-07-28.** `inferExpr`'s `BinaryOp.add` arm now checks bottom-up: when one
operand is `str` and the other is a KNOWN numeric or bool, it raises a Zebra error naming
both fixes. Deliberately narrow — `unknown_` never fires (selfhost inference is weaker than
the bootstrap's; erroring on unknown would convert every inference gap into a false compile
error), and `char_` is excluded, so `"a" + c` is untouched. Gated by
`test/fail_fixtures/str_plus_number_rejected_test.zbr`. Full sweep: 0 regressions across 331.

**Known limitation — no source location when BOTH operands are literals.** `AstBuilder`
constructs binary expressions, string literals and int literals all with `zspan()` (a zero
span; 95 of its node kinds do this), so there is no position to report. The diagnostic
borrows the nearest operand's span from an ident, member or call — which covers the realistic
cases (`"n=" + n`) — but `print("Hello " + 5)`, two literals, still reports `0:0`. Fixing it
properly means populating spans in `AstBuilder` from the parser's tokens.

**Measured 2026-07-28 — and my first claim here was wrong.** I originally wrote that "many
expression-level diagnostics inherit this same weakness." They do not. Probing the corpus'
negative tests: 17 produce a located diagnostic, **0 land at `0:0`**. Probing expression-level
errors directly — undefined name `2:11`, var type mismatch `2:0`, wrong argument type `4:5`,
`str + int` with an ident operand `3:17` — all carry locations. The only reproducible `0:0` is
the two-literal concat (`print("a" + 5)`). So this is a narrow wart, not a systemic one, and
the AstBuilder span work it seemed to justify is **not** worth prioritising. Recording the
correction rather than the tidy version: the generalisation was speculation, and one probe
refuted it.

**Book impact (done):** `01-Getting-Started.md` now shows `print("Hello " + count)` with the
real transcript, captured verbatim from the compiler. It uses a variable rather than a literal
precisely because of the limitation above — with two literals the transcript would have had no
line number, and putting a fabricated one in the book was not an option.

### BUG-217: `CodeEditor.setText` handed Scintilla a non-NUL-terminated buffer → segfault ✅ FIXED + RUN-VERIFIED 2026-07-27
`IDE/ZebraIDE.zbr` aborted (exit 3) on the **Build** button. Sean's stack trace was decisive:

```
Segmentation fault at address 0xffffffffffffffff
  ... in strlen (compiler_rt.lib)
  scintilla/src/Editor.cxx:6190  pdoc->InsertString(0, text, strlen(text));
  ... Editor::WndProc → ScintillaBase::WndProc → ScintillaWin::WndProc
  libui_scintilla/win.cxx:60  SendMessage(s->hwnd, SCI_SETTEXT, len, (LPARAM)text);
  src/sci.zig:9  uiScintillaSetText(self, text.ptr, @intCast(text.len));
  main.zig  _code_editor_set_text → if (_ed.scint) |_s| _s.setText(_ed.text);
```

**Root cause:** `SCI_SETTEXT` **ignores** the length in `wParam` and calls `strlen()` on
the pointer — even though the libui-scintilla binding's Zig signature accepts an explicit
length, which is exactly what makes this trap convincing. `_code_editor_set_text` used
`_allocator.dupe`, which produces **no terminator**, so Scintilla read off the end of the
allocation. The empty case is worse than a stray read: `dupe` of an empty slice returns a
zero-length slice whose `.ptr` is not a readable address at all, so **`setText("")`
segfaults immediately** — and `Msg.build_start` opens with
`m.buildOutputEditor!.setText("")`. Address `0xffffffffffffffff` is that pointer.

**Why it wasn't found earlier:** `examples/editor_min.zbr` (the run-verified single-editor
proof) only ever calls `setText` with a non-empty string literal, where `strlen` usually
finds a zero somewhere in fresh arena memory before faulting. It is a latent
read-past-the-end there too — it just survived.

**Fix (`selfhost/gui_libui_ng_section.zig`):** `_CodeEditor` now keeps `buf` + `len` with
the invariant `buf[len] == 0` and `buf.len >= len + 1`, established in `_code_editor_new`
so no path needs a "never set" special case. Also fixes a second latent defect on the read
path: `SCI_GETTEXTRANGE` writes `n + 1` bytes (it NUL-terminates), but the old code
reallocated only when `n > buf.len`, letting an exactly-full buffer overflow by one byte.
`_code_editor_render` can now call `setText` unconditionally.

**Scope:** libui_ng backend only — the stub/tui `_code_editor_*` store plain slices and
never cross a C boundary. **Not gate-provable** (no headless GUI) — closed instead by
interactive confirmation: Sean clicked Build/Check/List Targets post-fix, "all crashing
behavior w/ those buttons is gone" (2026-07-27).

### BUG-216: `\"` inside an INTERPOLATED string is double-escaped by the bootstrap ✅ VICTIMS FIXED 2026-07-27 (bootstrap root cause left open by choice)
A string that is both interpolated and contains an escaped double quote is compiled
differently by the two compilers:
```zebra
var s = "say \"hi\" n=${n}"
```
- **selfhost** emits `allocPrint(_allocator, "say \"hi\" n={}", …)` — **correct**.
- **bootstrap** emits `allocPrint(_allocator, "say \\\"hi\\\" n={}", …)` — **wrong**.

Root cause (`src/CodeGen.zig` `genStringInterp`, the `if (c == '"') … if (c == '\\')`
escape pass around 16686): the literal parts of an interpolated string carry the **raw
source text**, which is then escaped *again* on the way out, so `\"` → `\\\"`. A plain
non-interpolated string is unescaped correctly by both compilers.

**Why a bootstrap-only bug mattered here.** Normally the rule is "don't chase, the
bootstrap sunsets". But the bootstrap is the **regen authority** for `selfhost/*.zig`, so
this corruption is baked into the *shipping* compiler wherever the pattern appears in the
compiler's own source. It did, in exactly three places: all three `genCopyOut` `<<-`/`<-`
diagnostics emitted `@compileError(\"…` — a Zig **parse** error rather than the message
they were written to give — from the day they were added until 2026-07-27. Nobody noticed
because those diagnostics only appear when you make that specific mistake.

**Fixed:** the three victims now emit the line number as its own piece so every string
stays plain (`w.emit("@compileError(\"line ")` / `w.emit(co.span.line.toString())` / …).
**Gated:** `python tools/lint_interp_escape.py` — static, instant, no build; flags any
`${`-bearing literal containing `\"` in `selfhost/*.zbr` and `IDE/*.zbr`. 0 = clean.
**Left open:** the bootstrap root cause. Fixing it would make the two compilers agree, but
the pattern is now greppable and gated, and the bootstrap is being phased out. Retire the
lint when the bootstrap is fixed or removed.

### BUG-215: two-argument `str.indexOf(sub, from)` silently dropped the offset ✅ FIXED 2026-07-27
`indexOf` takes **one** argument; the offset form is a separately named method,
`indexOfFrom(sub, from)`, returning `int?`. Both compilers accepted `indexOf(sub, from)`
and **silently discarded** the second argument — every search restarted at 0.

**How it presented:** `IDE/ZebraIDE.zbr` used the two-argument form in five places. In
`parseLine` that made `colon1 == colon2 == colon3`, and the very next line does
`ln.substring(colon1 + 1, colon2)` — start > end → Zig slice panic, three frames from the
typo. `parseBuildTargetNames` had the same shape. Those are the **Check** and **List
Targets** toolbar buttons; the IDE aborted (exit 3) on both. Found immediately after
BUG-214 stopped masking it (before that, no button ever dispatched at all).

**Fixed, two parts:**
1. `IDE/ZebraIDE.zbr` — all five sites moved to `indexOfFrom` with `int?` handling.
   Verified against realistic input: `foo.zbr:12:5: error: …` → `12|5|error: bad thing`,
   the Windows `C:/…` drive-letter form parses, non-matching lines return nil, and target
   parsing yields `app`/`lib`.
2. **Codegen guard** (`selfhost/CodeGen.zbr`, both string-method dispatch sites) — an
   `indexOf` call with more than one argument now emits `@compileError("line N:
   str.indexOf takes 1 argument; for an offset search use indexOfFrom(sub, from)
   (returns int?)")` instead of miscompiling. Silently dropping an argument is the worst
   available behavior: it converts a typo into a runtime panic far from its cause.

**Gated:** `smoke_emit_contains test/fail_fixtures/indexof_arity_rejected_test.zbr`.
**Note on the guard's presentation:** Zig reports it as `error: unreachable code` with the
`@compileError` text visible on the offending line, rather than as the compileError itself
(the guard sits in a `const` initializer). The message reaches the user either way; this
matches the pre-existing `genCopyOut` guard pattern.
**Not addressed — the wider class:** arity is unchecked for stdlib methods generally
(`if args.len > 0 genExpr(args[0])` is the pervasive shape, extra arguments ignored).
A real fix is a stdlib signature/arity table in the front end so this becomes a proper
Zebra-level error with a source location. Worth doing before 1.0; `indexOf` is only the
instance that drew blood.

---

### BUG-214: no-payload `union(enum)` variant in value position emitted as tag, not union value → MVU send abort ✅ FIXED + RUN-VERIFIED 2026-07-27
`IDE/ZebraIDE.zbr` now **compiles + links** via `--gui-backend=libui_ng` (all compile gaps
closed: CodeEditor port `b42074a`, BUG-211, BUG-213), and **the window RENDERS and runs**
(Sean-confirmed 2026-07-27: "I did see the IDE"). It **aborts at runtime (exit code 3) on
the first no-payload-variant send** — i.e. clicking any toolbar button (`Open`/`Save`/
`List Targets`/… all send no-payload `Msg` variants) — NOT on startup. The abort is in the
type-erased MVU `send` queue-copy (`_gui_mvu_run` `_sfn`, emitted main.zig:3003), reached
from `view → g.send` (the button-click handler runs inside `view`). **Root cause (well-supported by the emit):** the IDE's `Msg`
is a `union(enum)` with mixed variants — no-payload (`list_targets`, `open_file`, …) and
payload (`filepath_changed: []const u8`, …). A no-payload variant in **value position** is
emitted as bare **`Msg.list_targets`** (the tag), whereas payload variants correctly emit a
full union value `Msg{ .buildfile_changed = bfVal }`. When `Msg.list_targets` is passed to
`g.send(msg: anytype)`, the argument's inferred type is the tag, not the full `Msg` union;
the send queue then reinterprets `&msg` as `*const MsgType` (= full `Msg`) and copies
`@sizeOf(Msg)` bytes from a tag-sized source → size/type mismatch → abort. The crash stack
points exactly at the `g.send(Msg.list_targets)` call site (view:4812). **counter.zbr is
unaffected** — its `Msg` is a *pure enum* (all no-payload), so `Msg.inc` is already a valid
full value and `MsgType` sizes match; the bug needs a `union(enum)` Msg with ≥1 payload
variant AND a no-payload variant sent.

**CONFIRMED at the language level 2026-07-27**, twice over:
1. Zig probe — for `union(enum) { a, b: []const u8, c }`, `@TypeOf(Msg.a)` is
   `@typeInfo(Msg).@"union".tag_type.?` with `@sizeOf == 1`, while `Msg{ .a = {} }` is `Msg`
   with `@sizeOf == 24`. `examples/counter.zbr` survives only because an all-no-payload
   union and its tag are both 1 byte, so the memcpy is accidentally correct.
2. Minimal repro — `test/mvu_mixed_union_test.zbr` (mixed `union Msg { bump, set_label: str }`,
   `view` sends both forms). It aborts under the **plain stub backend** — no GUI, no display
   needed: `thread N panic: incorrect alignment`, from the `@alignCast` in the send queue
   applied to a 1-byte-aligned tag. This makes BUG-214 a runnable regression gate.

**Fix direction — NARROW, not "value/argument position" (the original note was wrong).**
A blanket rewrite of bare `Union.variant` is both unnecessary and actively harmful:
- Every **typed** position (assignment, typed parameter, return, `==` against the union)
  coerces the tag to the union for free, so the bare form is correct there.
- `x == Union{ .v = {} }` is **not legal Zig** (`error: operator == not allowed for type`),
  so a blanket rewrite would introduce a new compile error class.
- `Type_.string_` and friends appear in hundreds of the compiler's own emitted sites, so a
  blanket rewrite would force a matching change in the sunsetting bootstrap to keep
  `bootstrap_check` byte-identical.
The only position with no type to coerce to is the type-**erased** `anytype` parameter of the
MVU `Gui.send`. So: rewrite bare no-payload variants to `Msg{ .variant = {} }` **only** as the
single argument of `send` on a `Gui` receiver, and only for unions declared in the same module
(`novalue_variants`, populated alongside `boxed_variants`). Selfhost-only by construction —
the compiler's own source has no `Gui.send`, so the round-trip stays byte-identical.
**Known limitations — measured, not guessed** (probe: `viewM` as a class method, a send
nested inside `using g.vbox(...)`, a local `var g2: Gui = gg`, and an UNANNOTATED `def
view(g, m)`; emit inspected for each):
- Receiver inference is wide enough for every idiomatic shape — annotated parameter, class
  method, inside a `using` block, and an annotated local all convert. The **only** shape that
  falls back to the bare tag is an **unannotated** receiver parameter (`def view(g, m)`),
  where `inferExpr` cannot reach `Type_.gui_context`. That is a silent miscompile if anyone
  writes it; §28a is moving the language away from unannotated params, and no corpus program
  has that shape. Widening the rewrite to fire on an unknown receiver was considered and
  rejected: it would have to bypass the generic member-call tail, which is where `throws`
  propagation is emitted — trading a documented narrow gap for an undocumented one.
- The rewrite is depth-1: `g.send(if c then Msg.a else Msg.b)` is not covered.

**Landed:** `selfhost/CodeGen.zbr` — `novalue_variants` (populated alongside `boxed_variants`
in both the pre-pass and `genUnion`), `isNoPayloadUnionValue` / `genNoPayloadUnionValue`, and
an `on Type_.gui_context` arm in `genMemberCall` that falls through unchanged for every other
Gui method and every non-matching `send` argument. Verified: all 11 bare sends in
`IDE/ZebraIDE.zbr` convert; repro runs clean; `bootstrap_check` byte-identical; smoke 255/255;
`compile_check` 215/0/1; `divergence_check --gate` 0 selfhost gaps.
**RUN-VERIFIED 2026-07-27:** the gates proved emit shape and no-regression only; the
IDE surviving a real toolbar click was confirmed by Sean clicking through the toolbar.
Buttons dispatch. Doing so immediately unmasked BUG-215 and BUG-217 — two crashes that
were unreachable while nothing dispatched at all; both fixed and confirmed in the same
session.

### BUG-213: selfhost `typeFromName` missing `SysProcess` → `proc.isRunning()` mis-dispatched ✅ FIXED 2026-07-27
Verified post-rebuild: both call forms the IDE uses — `m.proc!.isRunning()` (force-unwrap)
and `if m.proc as p` → `p.isRunning()` (binding) — now emit `_sys_process_is_running(...)`
(probe: 2 call sites converted, 0 residual `.isRunning()`).
The selfhost already dispatches `sys_process` instance methods (`CodeGen.zbr:10981` →
`_sys_process_is_running` / `_sys_process_kill`) and infers `sys.spawn` → `sys_process`.
But `typeFromName` had no `SysProcess` → `sys_process` arm (the bootstrap does, at
`src/TypeChecker.zig:4696`). So a field/var **annotated** `SysProcess?` was not typed as
`sys_process`; a receiver bound from it (`m.debugProc as proc` or `m.debugProc!`) inferred
as unknown, and `proc.isRunning()` fell through to generic method dispatch — emitting a
literal `proc.isRunning()` that Zig rejects (`_SysProcess` has no such member). Blocked the
libui_ng build of `IDE/ZebraIDE.zbr` (its `debugProc`/`buildProc: SysProcess?` fields drive
process polling), *after* the program compiled cleanly through all the CodeEditor code.
**Fix:** one line — `if n == "SysProcess" return Type_.sys_process`, alongside the sibling
builtin-type mappings (Gui, CodeEditor, SqliteDb, …). Same class as the CodeEditor
name→type gap. Note `SysProcess` already resolves (it's not the resolver that was missing
it) — only the type-inference mapping.

### BUG-211: selfhost `nameUsedInStmt` ignored `using` blocks → spurious param discard ✅ FIXED 2026-07-27
`CgHelpers.nameUsedInStmt` (the name-presence scan behind param/local unused-discard
emission) handled 16 statement kinds but had **no `Stmt.in_scope` arm** (the node the
`using` keyword parses to — NOT `Stmt.with_`, which is the `with` contextual-self keyword;
`nameUsedInStmt` was missing both). So a `using EXPR` block fell to `else → false`: any
parameter or local used *only* inside a `using` block was seen as unused, and codegen
emitted a `_ = name;` discard — which Zig then rejects: `error: pointless discard of
function parameter … used here`. This bit **every idiomatic MVU `view`** whose `g`/model
are touched only inside `using g.vbox(...)` (the canonical libui/tui layout form).
`counter.zbr` dodged it (uses `g` at top level); the minimal `examples/editor_min.zbr` and
any params-only-in-`using` program hit it. Found building a minimal CodeEditor program via
`--gui-backend=libui_ng`. **Fix:** add both the `Stmt.in_scope` and `Stmt.with_` arms
(check the header expr + recurse into body `stmts`), mirroring the sibling passes
(`mightUseNameStmt`, `scanMutationsInto`, escape helpers) that already recurse into both.
Verified: `scanMutationsInto` already had both arms and `collectAllIdents` is expr-level,
so `nameUsedInStmt` was the sole gap. Strictly widens the "used" set → can only remove
false discards, never add one (the one exception — a param shadowed by a same-named local
inside the block — is not present in the corpus).

### BUG-210: `zig build update-selfhost` can skip regeneration after a `.zbr`-only edit ✅ FIXED 2026-07-25
`update_run` (`build.zig`) is `b.addSystemCommand({"bash","tools/bootstrap_check.sh",
"--update"})` with a fixed argv, `dependOn(bootstrap_exe)`, and **no declared
`.zbr` inputs**. So Zig's build cache can treat it as up-to-date and **skip the
regeneration** when only `selfhost/*.zbr` changed (bootstrap exe unchanged) —
`zig build update-selfhost` silently no-ops and `selfhost/*.zig` stays stale,
drifting from its `.zbr` source. Observed repeatedly 2026-07-25: edits to
`selfhost/main.zbr` did not reach `main.zig` until forced. **Workaround:**
regenerate directly — `zig-out/bin/zebra-bootstrap.exe --emit-zig selfhost/foo.zbr
> selfhost/foo.zig` — or invalidate the cache. **Fix direction:** mark the step
`has_side_effects = true` (always run) or declare the `.zbr` files as inputs so
the cache key tracks them. Small build.zig change; do it carefully (build system).
`bootstrap_check.sh` itself (the gate) is unaffected — it regenerates into /tmp
fresh each run.
**Fixed (`build.zig`):** `update_run.has_side_effects = true` — the regeneration
step now always runs when `zig build update-selfhost` is invoked. Verified: two
back-to-back invocations both fully regenerate (Step 1/2/3 + PASS each time);
before, the second was a cache no-op.

### BUG-209: `uses_sqlite` false-positive disabled the fast run path + linked sqlite3.c into every compile ✅ FIXED 2026-07-25
The selfhost detected SQLite usage with `zig_src.contains("_sqlite_open")` — but
the preamble **inlines** the `fn _sqlite_open` *definition* into every emitted
program, so the check was true for **every** program. Two costs compounded:
1. The `-fno-llvm -fno-lld` self-hosted-backend **fast run path** (gated on
   `not uses_sqlite`) was never taken → every `zebra run` used the slow LLVM route.
2. The LLVM path linked `vendor/sqlite/sqlite3.c` into **every** compile.
Net: a trivial program took ~14 s to `zebra run` instead of ~1 s. Found while
investigating why the fast path (added `f9a05d1`, verified ~3× then) had gone
dormant. The bootstrap was never affected — it sets `uses_sqlite` structurally in
codegen (`src/CodeGen.zig`), only when a real Sqlite call is emitted.
**Fix (`selfhost/main.zbr`):** detect by **occurrence count**, not presence — the
preamble contributes exactly one `_sqlite_open` (the definition), so a real
`Sqlite.open/query` call adds a second. Bind the split to a `List(str)` first
(`var p: List(str) = zig_src.split("_sqlite_open")`; `p.len > 2`) — a chained
`.split(x).len` emits a Zig split *iterator*, which has no `.len`.
**Verified:** `zebra run` on a plain program dropped ~14 s → ~1 s (fast path now
taken, `.fast.exe` produced); a `Sqlite.open` program still routes to LLVM and
runs; `bootstrap_check` byte-identical; smoke 254/254.

### BUG-208: `zebra run` hangs when the program prints more than ~4 KB ✅ FIXED 2026-07-25
`zebra run <file>` ran the compiled program via `sys.run()`, which **captures**
the child's stdout/stderr through OS pipes. The reader blocks once the pipe
buffer (~4 KB on Windows) fills, so any program that prints more than a few KB
**hangs forever** (CPU 0%, blocked on the write). Found dogfooding
`examples/lsystem.zbr` (ASCII output ~9.5 KB): every run hung at ~4275 bytes
regardless of line length or count — the tell-tale fixed pipe-buffer cutoff.
**Not a codegen bug:** the *standalone* compiled exe prints 64 KB instantly under
both backends, and the bootstrap (`zebra-bootstrap.exe file.zbr > out`) prints
64 KB fine through the identical harness — because it **inherits** stdio for the
program run (`src/main.zig`, `.stdout = .inherit`) instead of capturing it.
**Fix (`selfhost/main.zbr`):** run the compiled program with inherited stdio
(`sys.exec_inherit`), never captured. The LLVM run path was switched from
`zig run` (which captured the program's output via `sys.run`) to
`zig build-exe -femit-bin=<exe>` (capture only the small compile output, where
`remapZigErrors` belongs) followed by `sys.exec_inherit(<exe>)`. Mirrors the
bootstrap. Verified: `zebra run` on a 64 KB-output program now completes
(64005 bytes, exit 0); the L-system renders; small output unaffected.
*(Honest note: the first attempt put `exec_inherit` in the fast `-fno-llvm` path,
which — see the follow-up below — isn't currently taken, so it was correct but
dormant; the operative path was the LLVM branch. Both now inherit.)*
**Follow-ups (separate, lower priority):**
- The fast `-fno-llvm` run path isn't being taken (no `.fast.exe` is produced for
  a plain program), so every `zebra run` currently uses the slower LLVM route.
  Worth a one-line trace to find why the `2213` condition or fast build falls
  through — restoring it is a ~3× dev-loop speedup. Its run step already inherits.
- `sys.run()`'s ~4 KB capture block still affects its *other* callers (node-addon
  build, `Shell.run`, and the compile-error stream itself if a build ever emits
  >4 KB). The program-run case is fixed by not capturing; those capture sites
  retain the latent limit. Fix if they ever handle >4 KB output.

### BUG-204/205/206: bootstrap (LLVM) lags the selfhost on `except` — blocks GUI/TUI apps
All three found 2026-07-25 dogfooding `examples/tears_of_the_tuon.zbr` (a game
port). They share a theme: the **selfhost compiles these fine**, but the
**bootstrap does not** — and GUI backends (`--gui-backend=stub|tui|glfw`) are
hard-wired to *delegate to the bootstrap* (it carries the GUI/zigzag runtime),
so these gaps block any GUI/TUI program even though the primary compiler accepts
it. This is the normally-"don't-chase" bootstrap-lags-selfhost category, but the
GUI-delegation makes it user-visible. Closing them is a scoped parser+codegen
job on `src/` (the selfhost already has the correct behavior to mirror).

**BUG-204 — parser: `except` only parses in var-init position.**
`return p except x = 1` and even `return (p except x = 1)` → `syntax error near
'except'` in the bootstrap; `var q = p except x = 1` is fine. The selfhost
parses `except` as a general (postfix) expression. Repro:
```
struct P { var x: int }
def f(p: P): P
    return p except x = 1     # bootstrap: syntax error; selfhost: OK
```
**Workaround (used in the example):** bind first, then return —
`var q = p except x = 1` / `return q`.
🚫 **WON'T-FIX in the bootstrap (Sean 2026-07-25).** A real fix needs a new
expr-level AST node + Expr9 postfix grammar production + AstBuilder + CodeGen,
with Earley ambiguity to manage — a sizable change to the *sunsetting* bootstrap.
✅ **DISSOLVED for the GUI/tui path (2026-07-26).** `--gui-backend=tui` now builds
through the **selfhost** (no bootstrap delegation), where return-position `except`
already parses — so GUI/tui apps use the natural form. Proven: `examples/tears_of_the_tuon.zbr`
builds via `--gui-backend=tui` with the workaround removed. Still latent for the
bootstrap itself + non-tui GUI backends that still delegate; the bind-then-return
workaround remains valid there. See NEXT_STEPS "GUI builds via selfhost emission".

**BUG-205 — codegen: a var *initialized with* `except` is emitted `const`.**
✅ **FIXED 2026-07-25** (`src/CodeGen.zig` `genVarExcept`). The bootstrap
hardcoded `const` for except-initialized vars; it now picks `const`/`var` from
the mutation set exactly like `genLocalVar` (a reassigned except-init var → `var`,
a never-reassigned one → `const`, preserving const-correctness). The selfhost was
already correct because it lowers `except` to an expression initializer through
the normal local-var path. Was:
```
def g(p: P): P
    var m = p except x = 1    # emitted `const m`
    m = m except x = 2        # error: cannot assign to constant
    return m
```
**Historical workaround (no longer needed):** plain-init then reassign.

**BUG-206 — codegen: `.toInt()` on a float loses float-inference across
reassignments.** In `resolveAttack`, `(attackRoll - defenseRoll).toInt()` (both
operands provably `f64`) emitted a passthrough `.toInt()` (invalid Zig:
`no field or member function named 'toInt' in 'f64'`) after the operands were
conditionally reassigned in intervening blocks. The bootstrap has correct
float→int (`@intFromFloat`) but its float detection at the call site didn't
survive the reassignment history. **Workaround:** bind an explicitly-typed float
first — `var delta: float = attackRoll - defenseRoll` / `var rollDelta =
delta.toInt()`.
⏸ **DEFERRED 2026-07-25 — minimal repro not found (time-boxed).** Reconstructing
`resolveAttack`'s exact shape in isolation (var-instance `rng.nextFloat()`,
nested-if operand reassignment, an early `return` before the `.toInt()`, and the
intervening `var isCrit`/`var base` block) all emit `@intFromFloat` correctly.
The passthrough only manifests inside the full multi-function game module, so a
fix cannot be verified against a minimal case — deferred rather than shipped
blind. The workaround is in place and documented; reopen with a full-module repro.
✅ **DISSOLVED for the GUI/tui path (2026-07-26)** — `--gui-backend=tui` builds
through the selfhost now, whose `.toInt()`-on-float emission is correct; the game
builds via `--gui-backend=tui` with the `var delta: float` workaround removed.
Still latent for the bootstrap itself.

### BUG-200: deeply-nested expressions stack-overflow ✅ FIXED for recursive nesting (2026-07-23); flat-chain residual documented
A deeply-nested expression crashed the compiler with a **stack overflow** instead of a
clean diagnostic — the AST tree-walk (parse → resolve → typecheck; `zebra --check`
alone crashes, so it's the front-end) recurses on expression-tree depth. Measured
selfhost crash thresholds: deep **parens/calls** segfault at ~450 (the worst and most
realistic case — parens re-enter `parseExpr`); flat single-operator **chains**
(`1+1+…`) overflow the downstream walk at ~1000 (built iteratively, don't re-enter
parseExpr).
**FIXED (recursive nesting):** `selfhost/Parser.zbr::parseExpr` now guards recursion
depth (`expr_depth > 200` → clean `error: expression nested too deeply (max nesting
depth 200)`), cleared per-top-level-decl in `tryParseTopDeclInto` to survive error
recovery. 200 is ~4x above any realistic nesting and leaves ~250 stack frames below the
~450 crash. Deep parens/calls/nested-data (the realistic + lowest-threshold crash) now
diagnose cleanly. Regression: `test/bug200_deep_nesting_test.zbr` (250 parens →
smoke_tc_fail). Gates all green.
**Residual (⛔ open, low priority):** extreme single-operator FLAT chains (~1000+ terms,
e.g. `1+1+…+1`) build depth via the iterative binary loops without re-entering parseExpr,
so the guard doesn't catch them — they still crash the tree-walk. A pure fuzzer artifact
(no hand-written code is a 1000-term flat sum; not gramgen-gate-reachable at depths 7/11).
Fix would add per-iteration caps to the ~7 binary-operator loops (parseOr/And/Comparison/
AddSub/MulDiv/pipeline). Deferred — very low value. The Zig bootstrap keeps the whole
crash (sunsetting; not fixed there).

---

### BUG-199: selfhost parser INFINITE LOOP on a leading non-`static` modifier ✅ FIXED (2026-07-23, gramgen fuzzer find)
**18-byte hang.** `readonly struct b` (or any bad top-level decl led by `readonly`/
`abstract` — a non-`static` `ModList` modifier) sent the selfhost parser into an
infinite loop: `zebra.exe` hung >40s (killed) while `zebra-bootstrap.exe` rejects it
in 80ms. **Root:** `Parser.zbr::skipToTopLevelBoundary` returned *without advancing*
when re-entered already sitting on a col-1 recovery-starter — so `parseModule`'s
`while not isEof(): tryParseTopDeclInto()` retry loop re-parsed the same failing token
forever. The bootstrap has no such bug: `parseWithRecovery` resumes at
`findRecoveryBoundary(pos + error_pos + 1)` — the `+1` guarantees forward progress.
**Fix (convergent, selfhost-only, error-recovery path only):** if recovery re-enters
on a col-1 recovery-starter, step past it once before scanning — mirroring the
bootstrap's `+1`. Cannot affect valid parses (only the post-error path changes).
Now rejects in <100ms with a clean `unexpected top-level token: 'readonly'`. Gates:
smoke 236+1, round-trip byte-identical, compile_check, divergence `--gate` (0 selfhost
gaps). Regression: `test/bug199_recovery_hang_test.zbr`. **Found by the new grammar
fuzzer `fuzz/gramgen.py` on its first runs** (a 551-char generated program timed out;
minimized to 18 bytes). Same super-linear-cost family the BUG-181 notes flagged, but
an actual infinite loop, not just slow.

---

## Dogfood findings — Greek NT n-gram program (2026-07-17)

Surfaced by writing a real text-analytics program in Zebra (SBLGNT n-gram +
TF-IDF cosine). Full context: wiki `concept_greek-nt-ngram-stylometry`; repro
programs in that session's scratchpad (`gng/`). Recurring theme across several:
**nested generics + non-`str` element types are under-supported in the selfhost's
container-method dispatch and pointer-mutation analysis.**

### BUG-198: assigning a union value to an OPTIONAL field drops the box type arg ✅ CANNOT REPRODUCE — likely resolved (2026-07-24)
**Could not reproduce** with four faithful shapes (all run correctly): the exact reported
`.field = t` setter pattern (non-optional union param → `Type_?`-style optional union
field), a recursive union (`node: ^Tree`), and an explicit `^Tree?` field. Emits a
correct box, no bare `create()`. Appears resolved by intervening codegen (the divergence
burn-down / BUG-187/188 nil-narrowing era), same as BUG-196's filed face (b). NOT
definitively closed: the original trigger was the specific extend_test
`InferCtx.self_type_override: Type_?` context with the param-as-optional workaround NOT
applied, which wasn't reconstructed here. Added a regression GUARD for the now-working
behavior: `test/bug198_union_optional_field_test.zbr` (smoke_run "bug198: OK"). If it ever
resurfaces, reconstruct the extend self-typing context. Original report retained below.


Direct assignment of a non-optional union value to an optional heap-boxed field —
e.g. `def withSelfType(t: Type_): .self_type_override = t` where the field is
`Type_?` — emits `_allocator.create()` with **no type argument** (`create()` needs
`create(T)`): `{ const _rp = _allocator.create() catch @panic("OOM"); _rp.* = t; self.f = _rp; }`
→ "member function expected 1 argument(s), found 0". The auto-box path for
`union → optional-field` omits `@TypeOf(t)`/the concrete type. Workaround used at the
call site (extend self-typing): declare the setter param as the OPTIONAL type
(`t: Type_?`) so the optional wrap happens at the call boundary (which boxes
correctly), not in the setter body. Real fix: emit `_allocator.create(@TypeOf(t))`
(or the field's element type) in the union→optional-field boxing codegen. Surfaced
during the extend_test divergence fix (2026-07-20).

### BUG-197: SIMD `f32x8` islanded — cannot ingest computed / collection data ✅ FIXED (all 3 tiers, 2026-07-18)
**RESOLVED for real use** — the data bridge is in (commits `ac48cbe`, `015e8c3`):
- **Tier 1 — `.toFloat32()`** (`float`/int/`str` → `f32`): `@floatCast`/`@floatFromInt`/
  `parseFloat(f32)`. Both compilers. Lets computed f64 feed `f32x8` lanes.
- **Tier 2 — `List(float32)`/`List(f32)`**: the selfhost had *diverged* from the
  bootstrap (which already accepted them) — its parser rejected sized-numeric type
  names in value position and its resolver didn't know them. Converged both.
- **Payoff:** the SIMD-vs-scalar all-pairs cosine on the Greek book vectors (the
  comparison the dogfood left blocked) now runs — **~7.8× faster** (f32x8 ~0.39 ms
  vs scalar ~3.03 ms, ReleaseFast), numerically identical (checksum matches), and
  reproduces the exact authorship clustering. Near-perfect 8-lane utilization.
- **Tier 3 (DONE, commit `736a7d6`)** — `f32x8.load(list, offset)` loads N lanes from
  a `List(f32)` at an offset, so hot loops don't hand-write eight `.at()` calls. Plus
  ergonomic follow-ups (`ee69570`, `ce12e9f`): un-annotated `f32x8` reductions,
  `f32.toFloat()` widening, `List(f32)`≡`List(float32)`. **All three tiers complete.**

Original report (for context):
`f32x8` requires `f32` lanes, but there is no bridge from computed data:
- `List(f32)` → resolver "undefined name 'f32'"; `List(float32)` → parser
  "unexpected expression token" (the value-position `List(T)()` ctor-call path
  parses `T` as an expression and rejects sized-numeric names, though the type-
  *annotation* path `var c: float32` accepts them via `isSizedTypeName`).
- No runtime `f64 → f32` conversion: `float32(x)` doesn't parse, no `as` cast,
  `var a: float32 = <runtime f64>` is rejected. Only comptime float literals coerce.
So `f32x8` works only with inline literals (`simd_test.zbr`); it cannot take a
computed vector, a `List`, or loop-varying data — blocking the TF-IDF/cosine and
embedding workloads that motivated SIMD. **Fix is tiered and mostly localized —
see NEXT_STEPS "SIMD data bridge".** Not a redesign.

**Also surfaced — two concrete minimal repros of the OPEN D4 `*T`-vs-`*const T`
cluster:** sorting `List((int,int))` with a lambda comparator, and passing a
`List(List(int))` to a fn parameter, both fail — while the `str`-element versions
(`List((str,int))` sort, `List(List(str))` param) work. The **element-type
dependence is a strong root-cause clue** for the D4 fix. See NEXT_STEPS.

---

## BUG-192: `^T` field assigned a value in `cue init` not auto-boxed (D4 `*T`-vs-`T`) ✅ FIXED same-module (2026-07-17)

A `^T` (heap-indirection) field initialised from a value inside a constructor emitted the value
straight into the `*T` slot — `expected '*Expr', found 'Expr'`. Two causes, both in
`selfhost/CodeGen.zbr`:

1. **Bare-ident field target not recognised.** Inside `cue init`, `left = l` has target
   `Expr.ident("left")` (a bare field name), not `self.left`. `getAssignFieldType` only handled
   *member* targets, so the ref-box path never saw the field type. Extended it to resolve a
   bare-ident target that is a field of the current owner (a local var shadows a field, so a known
   local is excluded).
2. **Union payloads not boxed.** The ref-box path only boxed `struct_names`, but `^T` fields also
   hold **unions** (`^Expr`, `^TcExpr` where `Expr`/`TcExpr` are `union`s). Extended the box
   condition to `.module_types.hasUnion(tn)` as well. (`^Class` is a hard error, so `^T` is always
   a struct or a union — never a class.)

**Regression caught + fixed by the gate:** the union extension boxed `cue init(opt_val: ^Val?)
{ .opt_val = opt_val }` — but `opt_val` is *already* a `?*Val` pointer, so boxing tried to store a
`*Val` into a `Val` slot (broke `val_test`). Auto-box converts a *value* to a heap pointer, so it
must not fire when the RHS is already a ref. Added `rhsIsAlreadyRef` (inferExpr → `^T`/`^T?`) as a
guard on the box path — which also hardens the pre-existing struct case against the same shape.

Result: `selfhost_probe5` compiles end-to-end; `tc_infer_test`'s `^T`-box error is cleared (it now
fails on an unrelated D3 `.len`-on-struct). Gates: round-trip byte-identical, smoke 236/236,
compile_check 198/0/3.

**Follow-up (cross-module unions):** `tc_check_test` assigns a `^tc_infer.TcExpr` field
cross-module; the box condition checks `.module_types.hasUnion` (same-module only) and the create
type name would need the qualified `tc_infer.TcExpr`. The dotted name is already correct for
`create(...)`; only the union *check* needs a `dep_types.hasUnion(bareName)` arm. Deferred — the
box path has proven regression-prone (see above), and `tc_check_test` won't pass regardless (other
errors + its `tc_infer` dep's D3 bug). See [[project_emit_compile_campaign]].

---

## BUG-191: `var`/`const` mutation scan guessed from the method NAME → spurious "never mutated" (D7 cluster) ✅ FIXED (2026-07-17)

The self-hosted mutation scan (`CgHelpers.scanMutations`) decided whether a local must be
emitted `var` by asking whether the *called method's name* was on `isReadOnlyMethod`'s
allow-list. Any method not on the list marked its receiver `var`. That is a name-based
over-approximation with no type information, and it rotted continuously: every read-only
stdlib method that was missing (`isDigit`/`isUpper`/`toLower` on `char`, `isObject`/`isArray`/
`isNull` on a JSON value, `before`/`after`/`equals` on `DateTime` — BUG-190) produced a
`var` on a value that is never mutated, which Zig 0.16 rejects with
`local variable is never mutated`. This was the D7 cluster in `docs/emit_compile_triage.md`
(`unicode_test`, `json_test`, `typechecker_test`, `file_io_test`, `gui_test`).

**The fix (type-driven, the real one — not another name added to the list):** thread the
`InferCtx` through `scanMutations`/`scanMutationsInto`/`scanMutationsInExpr` (mirroring the
`tc_opt` the Zig reference `src/CodeGen.zig` already threads) and, for a method-call receiver,
consult the receiver's **inferred type**. When the type is a value category that is passed by
value — primitives, `char`, `str`, `str_slice`, `json_value` — only an explicit in-place
mutator (`add`/`set`/`put*`/`append*`/`writeRow`/`clear`/`reverse`) forces `var`; every query,
predicate, or new-value builder leaves the receiver `const`, regardless of its name. Structs,
containers, cross-module and unknown receivers stay on the conservative name-based path, so the
change cannot introduce a spurious `var` (or, worse, a `const` on something actually mutated).
`isReadOnlyMethod` survives only as the no-type-info fallback (unit tests, pre-seed emission
paths); it no longer drives the primary decision and can shrink over time.

Result: `unicode_test` now compiles end-to-end (0 errors, was all `never mutated`); the
`never mutated` errors are eliminated for value-type receivers across `json_test`,
`typechecker_test`, and `file_io_test` (their remaining failures are other clusters).
Gates: round-trip byte-identical, smoke 236/236, compile_check 198/0/3 (no regression).

**Round 2 (2026-07-17, same commit series):** a corpus-wide `never mutated` scan found the
initial value-type bucket was both too coarse and too narrow:
- **`str` is fully immutable, not "small-mutating-list".** `greeting.reverse()` returns a *new*
  string, but `reverse` is on `isMutatingMethod`'s list (for List's in-place reverse), so a
  string receiver was wrongly marked `var` (`string_methods_test`). Split the value bucket into
  `isImmutableValueType` (primitives/char/str/str_slice → **never** `var`, mirroring the Zig
  reference's `obj_type == .string → false` special-case) and `isByValueHandleType`
  (json + network/db handles → small-mutating-list).
- **Stdlib handle types were missing.** `tcp_conn`/`ws_conn`/`udp_socket`/`sqlite_*`/`regex` are
  by-value handles whose methods emit `_xxx(handle, …)`; added them to `isByValueHandleType`.
- **Optional receivers weren't unwrapped.** `var conn = Tcp.connect(…)` infers as
  `optional(tcp_conn)`; the decision must peel `optional`/`ref_to` first (`unwrapForMutation`),
  the same unwrap `genMemberCall` does (BUG-188). `tcp_advanced_test` now compiles end-to-end.

After round 2, the `never mutated` class is gone corpus-wide for every value/handle receiver.

**Known residual (documented, not a struct-getter after all):** the only remaining `never mutated`
is `gui_test`, and it is NOT a struct receiver — `frame` is a **closure** (`var frame = def(g)…`)
passed by value to `Gui.run`; its `var` comes from closure lowering (the closure mutates a
captured var), not from `scanMutations` (`frame` is never a method-call receiver). A separate
closure-codegen fix, tracked in NEXT_STEPS; `gui_test` also fails on an unrelated
`GuiContext has no member 'run'`. No named-struct-getter `never mutated` case exists in the
corpus, so the per-method struct-mutation map is not currently needed. See
[[project_emit_compile_campaign]].

---

## BUG-190: DateTime completion round 2 — comparisons over-marked `var`, `toIso8601`/`format` shadowed, chains ✅ FIXED (2026-07-17)

Follow-on to BUG-189; together these make `datetime_test` fully compile AND run correctly.
Four distinct issues:

1. **Const/var (D7):** `var a = DateTime.of(…); a.before(b)` marked `a` as `var` → Zig
   "local variable is never mutated" (the comparison emits `a.epoch_ms < b.epoch_ms`, a read).
   `before`/`after`/`equals` were missing from `isReadOnlyMethod` (`selfhost/CgHelpers.zbr`) —
   added. (The mutation scan conservatively marks every method-call receiver `var` unless the
   method is on the read-only allow-list.)
2. **`toIso8601` not dispatched** (missed in BUG-189) → raw `.toIso8601()`. Added
   `_dt_to_iso8601(dt)` + registered it as string-returning in `isStringExpr` (so `print` uses
   `{s}`, not `{any}` — it was printing the ISO string as a byte array).
3. **`dt.format(fmt)` shadowed** by the string `.format` heuristic (emitted
   `std.fmt.allocPrint(_allocator, dt, …)` → "unable to resolve comptime value"). Added a
   DateTime-gated `format` → `_dt_format(dt, fmt)` handler that runs before the string heuristic.
4. **DateTime method chains** (`DateTime.of(…).addDays(10)`) mis-materialized to raw
   `_mc.addDays(…)` — the same BUG-079/185 misfire. Extended the BUG-185 guard to skip
   materialization for DateTime receivers too (`not isDateTimeExpr(chain.recv)`).

Verified: datetime_test compiles and runs with correct output (dates, ISO strings, formats,
comparisons). Gates: round-trip byte-identical, smoke 236/236, compile_check 198/0.

---

## BUG-189: DateTime instance methods not dispatched — `dt.toEpoch()/addDays()/before()/…` emit raw ✅ FIXED (2026-07-17)

**User-facing.** A batch of `DateTime` instance methods emitted a raw `.method()` call on the
`_DateTime` struct (which has only `epoch_ms`), so they failed to compile:
`toEpoch`, `addDays`/`addHours`/`addMinutes`/`addSeconds`/`addMonths`/`addYears`, `before`/`after`/
`equals`, `daysBetween`/`secondsBetween`, `inCalendar`. All are documented (QUICKSTART) and handled
by the bootstrap; the selfhost's `genMemberCall` simply lacked the dispatch — even though **all the
preamble helpers already existed** (`_dt_add_*`, `_dt_days_between`, `_dt_seconds_between`,
`_dt_in_calendar`). A pure dispatch gap.

**Fix (`selfhost/CodeGen.zbr`).** Added an `isDateTimeExpr(m.object)`-gated block (bootstrap parity,
src/CodeGen.zig ~8420-8520): arith → `_dt_add_X(obj, n)`; comparison → `obj.epoch_ms </>/== other.epoch_ms`
(other defaults to `_dt_now()`); interval → `_dt_{days,seconds}_between(obj, other)`; `inCalendar` →
`_dt_in_calendar(obj, cal)` (defaults to `Calendar.Gregorian`); `toEpoch` → `obj.epoch_ms` (ms, distinct
from `timestamp` = seconds). Gated on a DateTime receiver so common names (`before`/`equals`) don't
intercept user methods.

**Found via** the emit-compile sweep (D5). Cleared every DateTime-method error in `datetime_test`,
which now surfaces a separate **D7 `never mutated`** bug (const/var analysis — shared with
tcp_advanced). Gates: round-trip byte-identical, smoke 236/236.

---

## BUG-188: method on an optional/narrowed receiver doesn't dispatch — `conn.write()` on `?TcpConn` ✅ FIXED (2026-07-17)

**User-facing.** A method call on an optional-typed receiver (even after nil-narrowing) fell
through to a raw `.method()` instead of the type-specific dispatch:

```
var conn = Tcp.connect(host, port)   # ?TcpConn
if conn != nil
    conn.write(data)                 # → error: no member named 'write' in 'TcpConn'
```

`genMemberCall`'s main receiver-type branch computed `recv_t = inferExpr(m.object)` but did NOT
unwrap `optional`/`^T` before matching. `conn` infers to `optional(tcp_conn)` (Tcp.connect returns
`?TcpConn`), and nil-narrowing is codegen-only — it emits `conn.?` but doesn't change `inferExpr`.
So `on Type_.tcp_conn` never matched and the call emitted a raw `.write()`.

**Fix (`selfhost/CodeGen.zbr`).** Unwrap `optional`/`ref_to` from `recv_t` before the type branch,
so a method on a narrowed/checked optional (or a `^T`) dispatches on the underlying type. Narrowing
/ `!` already emits `conn.?`, so `_tcp_write(conn.?, …)` is value-correct. General fix for the D5
"method on optional receiver" sub-family. Cleared the `write`/`readLine`/`readBytes` dispatch in
`tcp_advanced_test` (which now surfaces a separate D7 `never mutated` bug).

Gates: round-trip byte-identical, smoke 236/236, compile_check 198/0 (broad dispatch change — no
regressions). Found via the emit-compile sweep (D5).

---

## BUG-186: `Http.get(url)` emits undeclared `Http` — HashMap `.get` heuristic shadows the namespace ✅ FIXED (2026-07-16)

**User-facing.** `Http.get(url)` / `Http.post(url, body)` emitted a raw `Http.get(...)` →
`error: use of undeclared identifier 'Http'`. The Http *client* API was implemented
(`genHttpCall` → `_http_get`/`_http_post`, both in the preamble) and dispatched at
`genMemberCall`'s namespace block — but the container **method-name heuristic** `if mname
== "get"` (for `HashMap.get`) runs *earlier* and caught `Http.get`, emitting it raw and
returning before the namespace dispatch. (`Http.post`/`serve` have no colliding heuristic.)

**Fix (`selfhost/CodeGen.zbr`).** Guard the `.get` heuristic with `not isNamespaceReceiver(m)`
so a stdlib-namespace receiver (`Http`, `Sqlite`, `Csv`, … — see `isStdlibNamespace`, 33 names)
falls through to the namespace dispatch. Verified: `Http.get`/`Http.post` now emit
`_http_get`/`_http_post` and compile clean.

**Principle:** a call on a stdlib-namespace ident must dispatch by namespace, not by a
container method-name heuristic. `.get` was the only current collision; the helper makes future
ones easy to guard (or move the namespace block ahead of the heuristics — a cleaner refactor).

**Found by** the full-corpus emit-compile sweep (`docs/emit_compile_triage.md`, D1). `http_test`/
`https_test` now surface a separate **nil-narrowing** bug (see BUG-187). Gates: round-trip
byte-identical, smoke 236/236.

---

## BUG-187: `if x != nil` now AUTO-NARROWS `x` (feature implemented) ✅ FIXED (2026-07-16, Sean chose to implement)

**Resolution: implemented auto-narrowing** (option 1). Inside `if x != nil`, a plain local `x`
that is not reassigned in the block is treated as non-optional — every value use emits `x.?`, so
`x.field` / `x.method()` / `x + 1` work directly (matching Kotlin/TS/Swift smart-casts, Eiffel
attachment patterns, and the `nil_narrowed` stub's original intent).

**Implementation (`selfhost/CodeGen.zbr`):** `genIf` narrows the then-block via an
`except`-derived Generator (scope-safe — never leaks out) when the condition is `<ident> != nil`
and the ident isn't reassigned in the block (the reassignment guard also makes it safe: a
narrowed var is never an assignment target). `genIdent` emits `x.?` for a narrowed local; the
`x!` (to_non_nil) emit is guarded so an explicit `x!` on an already-narrowed `x` stays single
(`x.?`, not `x.?.?`). QUICKSTART §11 updated. Cleared `http_test`, `https_test`.

**Deferred (fall back to explicit `x!`, documented):** `and`-chains, `== nil` else-branch,
non-local receivers (`if obj.field != nil`), reassignment invalidation. `tcp_advanced_test`
narrows correctly (`?TcpConn` → `TcpConn`) but then hits a SEPARATE bug — `TcpConn.write` isn't
dispatched on a proven `TcpConn` receiver (the BUG-182/sqlite family); see triage D5.

Gates: round-trip byte-identical, smoke 236/236, compile_check 198/0, runtime verified.

---

## (superseded) BUG-187 original characterization — DESIGN DECISION

**Finding (2026-07-16).** Several tests write `if x != nil` then access `x.field` / `x.method()`
directly:

```
var response = Http.get(url)      # ?HttpResponse
if response != nil
    print(response.status)         # → error: optional type '?HttpResponse' does not support field access
```

This is **not implemented in EITHER compiler** (verified: both emit raw `response.status`). And
**QUICKSTART §11 documents the current idiom as EXPLICIT unwrap:** `if x != nil: print(x!)`, or the
unwrap-binding `if x as n: …`. So by the current documented design, the failing tests are simply
written wrong — `response!.status` compiles clean (verified).

**But** it is likely an *intended-yet-unfinished* feature: `CodeGen.zbr` has a `nil_narrowed:
StrSet?` field ("variables narrowed to non-nil in current scope") that is **declared and
initialized but never populated or consumed** — a scaffold for auto-narrowing that was never
wired. Auto-narrowing (Kotlin/TS/Swift smart-casts; Eiffel Certified-Attachment-Patterns) fits
Zebra's "safe by default" + Eiffel lineage, and several tests assume it.

**Two resolutions — Sean's call (language design):**
1. **Implement auto-narrowing** — finish the stub: in `if x != nil` (and `x == nil` else-branch,
   `and`-chains, etc.) narrow `x` to non-optional within the guarded scope; invalidate on
   reassignment. A real feature in BOTH compilers, with real edge cases (scoping, reassignment,
   nested/`orelse`). Ergonomic + safety win; matches the stub's intent.
2. **Keep explicit `!`** (current documented design) — fix the tests to use `x!` (`response!.status`).
   Small; clears the emit-triage cluster (`http_test`, `https_test`, `tcp_advanced_test`) as
   test-code corrections. Optionally remove the dead `nil_narrowed` stub.

Affects `http_test`, `https_test`, `tcp_advanced_test` (the "nil-narrowing" cluster in
`docs/emit_compile_triage.md`). These are TEST bugs under design (2), or feature-blocked under (1).

---

## BUG-185: chained string methods miscompile — `s.concat(a).concat(b)` emits `_mc.concat(...)` ✅ FIXED (2026-07-16)

**User-facing.** A chained string method (e.g. `clist.at(i).concat(a).concat(b)`) miscompiled:
the BUG-079 auto-hoist (which materializes a method chain's receiver into a `var _mc_N = …`
temp for struct temporaries needing a stable address) misfired on the string chain, emitting:

```
var _mc_1 = (std.mem.concat(...) catch unreachable);          // _mc_1 : []u8
const tri: []const u8 = _mc_1.concat(clist.items[i+2]);        // → error: no field or member function named 'concat' in '[]u8'
```

String methods emit a **by-value special form** (`std.mem.concat(recv, …)`), never
`recv.method()`, so a materialized `_mc_N.concat(…)` is invalid Zig.

**Fix (`selfhost/CodeGen.zbr`).** Skip materialization when the chain's receiver is a string
(`not isStringExpr(chain.recv)`) — `genExpr` handles the nested string chain directly, emitting
`std.mem.concat(std.mem.concat(a, b), c)`. Applied to the var-init and assignment paths; the
return path already guarded on `recv_t is Type_.named` (structs only), so it was safe. Materialization
(BUG-079) is only needed for struct temporaries; string slices pass by value.

**Found by** the full-corpus emit-compile sweep (`docs/emit_compile_triage.md`, cluster D5). Cleared
`fuzzy_match` outright; `fuzzy_selfhost`'s concat error is gone (it now surfaces a separate D3
HashMap `.len` bug). Gates: round-trip byte-identical, smoke 236/236.

---

## BUG-184: preamble `_zebra_list_reduce` parameter `init` shadows a user top-level `init` ✅ FIXED (2026-07-16)

**User-facing.** The runtime preamble helper `_zebra_list_reduce` (emitted into every program
that uses `List.reduce`) had a parameter named `init`. Any program that ALSO emits a top-level
`pub fn init` — e.g. an MVU/GUI model's `init()` returning the Model — hit a Zig error:

```
selfhost/stdlib_preamble.zig-derived line: fn _zebra_list_reduce(comptime T: type, init: anytype, ...)
→ error: function parameter shadows declaration of 'init'
```

Zig forbids a function parameter shadowing a file-scope declaration. `reduce` + a top-level
`init` is a natural combination (the functional trio is common; `init` is the canonical MVU
model constructor), so this bit the GUI examples.

**Fix (`selfhost/stdlib_preamble.zig`).** Renamed the parameter `init` → `init_val` (signature,
return-type `@TypeOf`, and body). Cleared 3 GUI examples outright (`counter`, `hbox_smoke`,
`file_dialog_smoke`); the class is fixed for any `reduce` + top-level-`init` program.

**Found by** the full-corpus emit-compile sweep (`docs/emit_compile_triage.md`, cluster C).
Gates: round-trip byte-identical, smoke 236/236. The other 3 GUI files in cluster C were failing
on this shadow FIRST and now surface distinct next-layer bugs (nested `g` param shadow;
`^T`-box `*T`-vs-`*const T`; a `frame` const-shadow) — reclassified in the triage.

---

## BUG-183: single-quoted string literals with embedded `"` emit unescaped Zig (syntax error) ✅ FIXED in selfhost (2026-07-16); selfhost-only (bootstrap was correct)

**User-facing.** A single-quoted Zebra string containing a literal `"` (natural for JSON,
HTML, etc.) emitted an unescaped `"` into the Zig double-quoted string, producing a **syntax
error** in the generated Zig:

```
var json = '{"name": "Alice"}'
```
→ emitted `const json: []const u8 = "{"name": "Alice"}";`  (the Zig string ends at `"{"` → `error: expected ';' after statement`)

**Root cause.** `StringKind` collapses single- and double-quoted literals to `plain`, and the
selfhost AST drops the quote delimiter — so `genStringLit`'s plain path could not tell them
apart and emitted `sl.text` raw. Double-quoted strings store `"` pre-escaped as `\"` (fine);
single-quoted strings carry a literal `"` (broken). The **bootstrap was correct** — it preserves
the delimiter (`src/CodeGen.zig` ~16418) and escapes single-quoted content; this was a selfhost
divergence.

**Fix (`selfhost/CodeGen.zbr`, `escapePlainStr`).** Escape IDEMPOTENTLY without the delimiter:
split on the already-escaped `\"` (protecting them), escape any bare `"` in each segment, rejoin.
Double-quoted text (all `\"`) passes through unchanged; single-quoted literal `"` gets escaped.
Verified: `'{"name": "Alice"}'` now emits `"{\"name\": \"Alice\"}"`, compiles, and runs correctly;
`"normal with \"escaped\""` is unchanged.

**Found by** the full-corpus emit-compile sweep (`docs/emit_compile_triage.md`, cluster D2).
`json_test` still fails on a *separate* bug (D7 `local variable is never mutated` — const/var
mutation analysis), tracked in the triage.

---

## BUG-182: random access into a query result miscompiles — `db.query(...).at(i)` yields an untyped row ✅ FIXED in selfhost (2026-07-16); bootstrap divergence documented

**User-facing.** `db.query(sql)` returns a materialized, random-accessible row list, but
indexing it with `.at(i)` produced a result whose type was **not** inferred as `sqlite_row`,
so a method on that result miscompiled:

```
var rows = d.query("SELECT id, name FROM t")
var r = rows.at(1)          # skip row 0, read row 1 — a real use case
print(r.asInt("id"))        # ERROR: no field or member function named 'asInt' in '_SqliteRow'
```

`asInt`/`asStr`/`asFloat` are special codegen dispatch (emit `_SqliteRow.int_`/`.str_`),
triggered only when the receiver is *typed* `sqlite_row`. Only `for row in rows` worked,
because that path seeds the row type into `infer_ctx`; random access did not. The StrSet-class
bug (a method whose result loses its type → downstream dispatch breaks), found by sweeping the
dedicated-`Type_`-variant call-handler arms rather than the test corpus.

**Why no gate caught it:** round-trip diffs the selfhost against itself (self-consistency,
blind to this); smoke only `--emit-zig`s (blind to compile-failures); no test exercised `.at()`
on a query result. `compile_check.sh` (the independent witness) is what confirmed it.

**Fix (selfhost, `selfhost/TypeChecker.zbr`):** added a `Type_.sqlite_row_list` arm to the
`inferExpr` call handler — `at` → `sqlite_row`, `count`/`len` → int. Verified: a probe that
miscompiled now compiles + emits `rows.items[i]` → `r.int_(...)`. Regression guard added to
`test/sqlite_test.zbr` (random-access section, so `compile_check` covers it).

**Bootstrap divergence (documented, acceptable):** the bootstrap (`src/TypeChecker.zig`) has no
`sqlite_row_list` type — it types `query` as `.unknown` (line ~4072) and relies entirely on
for-in's separate element inference, so it still miscompiles `rows.at(i).asInt(...)`. Fixing it
means adding a type variant or threading query-provenance into method-return inference — a
larger change to a phasing-out compiler. Selfhost-ahead is the acceptable direction (the primary
`zebra.exe` is fixed; the bootstrap is `--zig-backend` escape-hatch only; regen authority is
untouched — the selfhost compiler source uses no sqlite). Close by adding a `sqlite_row_list`
type to the bootstrap if it is kept longer.

---

## BUG-181: selfhost `zebra.exe` cannot self-compile `selfhost/main.zbr` — RESOLVED 2026-07-22

**RESOLVED.** `zebra.exe` cleanly self-compiles its own driver: `--emit-zig` returns 0 and
the emitted `main.zig` passes `zig build-exe` (semantic analysis) with zero errors. Gated by
`tools/selfcompile_check.sh`. Eight emit divergences fixed across commits `43673d6`,
`fc9d322`, `eee950e`, `e8a0652`, `7cfeb84`.

**Dominant pattern (most of the 8): name-based type detection ignoring the proven type.** The
selfhost guessed List/HashMap/StrSet from an identifier NAME via reverse-index heuristics
(`fieldIsList`/`isKnownListField`/`fieldIsStrSet`) that false-positive when a param/local NAME
shadows such a field elsewhere; the bootstrap uses the TypeChecker type and gates its List
fallback on `obj_tc == .unknown`. Convergent fix: trust inference when it proves a type; fall
to the name heuristics only when the type is genuinely unknown.
- `StrSet.len`→`.items.len`: gated on `typeIsUnknown(receiver)`, restricted to BARE IDENT
  receivers (a member access `obj.field` keeps the heuristic — `fieldIsList("values")` on
  `c.values` is authoritative; a first cut regressed that, fixed in `fc9d322`).
- `StrSet.contains_`→`.contains`: nil-narrowed `StrSet?` via `if x as nn`. ROOT: the `if x as
  n` optional-unwrap never bound the capture's type into infer_ctx; fixed by binding it.
- `.len`/`.count` assignment TARGET emitted the read-form `@as(i64,@intCast(x.len)) = …`;
  genAssign now emits a plain `obj.len = v` field store.
- `int.toString()`/`Value.getObj()` on a method-chain temp emitted the terminal call RAW; new
  `isValueTypeExpr` skips BUG-079 materialization for value/json receivers.
- `str.indexOf` emitted `?i64`; converged to the bootstrap's `i64` with `-1` not-found.
- `stripStringQuotes` (AstBuilder) dropped an interp start-segment's trailing content when it
  had an escaped quote (`"a\"b`→`a\`, `\{` invalid escape); rewrote to strip without splitting.

Each fix gated (`compile_check` 200/0/1 + byte-identical round-trip). Historical detail below.

<details><summary>Original 2026-07-21 progress note (2-of-6 snapshot)</summary>

**Progress (2026-07-21, commit `43673d6`): 2 emit divergences fixed.** Both were
name-based container detection ignoring the receiver's proven type (the general pattern:
the selfhost guesses List/HashMap/StrSet from an identifier NAME via reverse-index
heuristics that false-positive; the bootstrap uses the TypeChecker type and gates its
List fallback on `obj_tc == .unknown`). The convergent fix is to trust inference when it
proves a type and only fall to the name heuristics when the type is genuinely unknown.
- ✅ `StrSet.len` → `.items.len`: `out.len` on a `StrSet` param (name `out` collided with
  a List field elsewhere). Gated the name heuristics on `typeIsUnknown(receiver)`.
- ✅ `StrSet.contains_` → `.contains`: a nil-narrowed `StrSet?` via `if x as nn` dropped
  the `_`. Root cause: the `if x as n` optional-unwrap never bound the capture's type into
  infer_ctx (so `nn` was `unknown`). Fixed by binding the unwrapped capture to the
  optional's inner type — a broad fix (every `if x as n`), verified 200/0 + round-trip.

**Cross-check with single-file (Phase 2):** the combined `selfhost/main.zig` produced by
`zebra.exe --single-file selfhost/main.zbr` has the EXACT SAME emit-bug set as the
multi-file self-build (zero single-file-specific errors), so single-file emission is ready
for the endgame the moment BUG-181 clears — it is not itself a blocker.

**Remaining divergences (from a fresh self-compile, before Zig's early-stop hides more):**
- `int.toString()` on a method-chain temp: `var _mc = self.w.nextUid(); _mc.toString()` —
  the materialization temp's int type isn't tracked, so `.toString()` isn't lowered to the
  int→string helper. (2 sites.) Likely fix: bind the chain-temp's type (the call's return
  type) into infer_ctx at materialization.
- `invalid escape character: '{'` (an emitted string literal — genString/interp escaping).
- `Value.getObj` on `json.dynamic.Value` (stdlib API name mismatch).
- `invalid left-hand side to assignment` (a `.len` **lvalue** — an assignment TARGET
  wrapped in the read-side `@as(i64,@intCast(x.len))` form; see the older note below).

Fix the remaining, re-emit (more errors likely surface behind Zig's early-stop), then add a
gate that self-compiles `main.zbr`. Historical detail below.

### Earlier analysis (2026-07-16) — slowness fixed, original 3-bug snapshot

The self-hosted `zebra.exe` cannot compile its own entry file `selfhost/main.zbr`.
Smaller selfhost modules (`CodeGen.zbr`, `TypeChecker.zbr`, `CgHelpers.zbr`, …)
compile fine.

**History / correction (2026-07-16).** Originally filed as a >300s *timeout*. That
slowness was real (confirmed on the pre-session tree: >120s), NOT contention — an
earlier in-session doubt about contention was itself mistaken. **§28a step-2 inference
fixes (commits 5c78c17 / 9204a0b / 04231dc) incidentally cut it from >120s to ~6s** —
the pre-session compiler's weak inference (unresolved `.len`/`.items()`/dep types)
caused pathological repeated-inference cost; resolving those types made the compile
fast. So the timing symptom is fixed as a side effect.

**Current blocker: pre-existing selfhost EMIT bugs**, previously hidden behind the
slowness (the compile never reached emit). Now `main.zbr` self-compiles in ~6s and
fails Zig compilation with (at least):
1. `TypeChecker.zbr:64` (`TupleType_` ctor `len = elems.items.len`) → emits
   `@as(i64, @intCast(_self.len)) = …` — a `.len` **lvalue** wrongly wrapped in the
   read-side `@intCast`. The len-member codegen (`CodeGen.zbr` ~8309) applies the
   `@as(i64,@intCast(x.len))` read form even when `x.len` is an assignment TARGET.
2. `CodeGen.zig:17173` → `invalid escape character: '{'` (an emitted string literal).
3. `main.zbr:1464` → `local variable is never mutated` (const/var mutation analysis).
None are §28a inference-guesses; all are in the emit path (untouched by §28a). They
are latent selfhost codegen gaps, not regressions.

**Why unnoticed.** No gate self-compiles `main.zbr`. The `.zbr → .zig` regen
(`tools/bootstrap_check.sh`, `zig build update-selfhost`) is performed by the
**bootstrap** (`zebra-bootstrap.exe` — regen authority), which compiles `main.zbr` in
seconds. `tools/selfhost_smoke.sh` runs `zebra.exe --emit-zig` only on small fixtures.

**Impact.** (a) The selfhost cannot yet compile its own driver — a gap on the road to
Zig-only-in-special-cases. (b) §28a validation on `main.zbr` requires clearing these
emit bugs first.

**Next.** Fix the three emit bugs (start with the `.len`-lvalue: the assignment
codegen should emit a plain field store for a `.len` TARGET, not the `@intCast` read
form). Then add a gate that self-compiles `main.zbr` so it stays working.

---

## BUG-180: bootstrap does not fill omitted constructor defaults on emit ⚠️ OPEN (bootstrap-only; selfhost correct)

`zebra-bootstrap.exe --emit-zig` drops omitted defaulted constructor arguments
instead of substituting their defaults, producing an under-argumented Zig call.
The self-hosted `zebra.exe` handles it correctly, so this is a bootstrap-only
emit gap (selfhost-ahead).

**Repro.** A struct with defaulted ctor params:

```
struct Vector3
    cue init(x: float = 0.0, y: float = 0.0, z: float = 0.0)
        ...
```

- `Vector3()`            → bootstrap emits `Vector3.init()`            (0 args)
- `Vector3(x: 0.0, z: 3.0)` → bootstrap emits `Vector3.init(0.0, 3.0)` (2 args)

Both fail Zig 0.16 with `error: expected 3 argument(s), found N`. Selfhost emits
`Vector3.init(0.0, 0.0, 0.0)` / `Vector3.init(0.0, 0.0, 3.0)` — correct.

**Impact.** Surfaced building the GameEngine boss-move layer (`zbra/boss_move.zbr`),
which constructs `Vector3` with omitted defaults. Because the committed engine
`.zig` are regenerated by the bootstrap (regen authority), the round-trip breaks
for any `.zbr` that relies on ctor defaults. Worked around in that repo by
spelling every ctor argument out; the fix belongs in bootstrap's call-emit
(fill omitted params from the callee's declared defaults, as selfhost does).

**Where to look.** Bootstrap call-argument emit (positional/named lowering in
`src/CodeGen.zig` / arg resolution) — the default-substitution step selfhost
already performs and bootstrap skips.

---

## Mosaic POC dogfood (2026-07-14)

A separate Claude session port-tested Zebra on a real differential task (a Greek-NT
intertextual/statistical computation, Python oracle vs Zebra product, byte-identical
output). Its ledger: `C:\Projects\mosaic\docs\ZEBRA_FINDINGS.md` (8 findings, logged
against "0.1.0 Phase 22"). Re-verified against HEAD on 2026-07-14:

- **Already fixed since Phase 22:** escape sequences in interpolation (`\t`);
  indexed `List(str)`/`List(float)` corruption for locals **and** struct fields
  (both emit correct `.items[i]` with `{s}`/`{d}`); the ternary-truncation symptom.
- **Not bugs:** numeric conversions (`toString`/`toFloat`/`toInt` all work and are
  correctly documented — the POC guessed `toStr`, which isn't the API); tolerant-zero
  `toInt` on CRLF (data hygiene); print→stderr (known fast-backend quirk).
- **Live → filed below:** BUG-175 (fixed here), BUG-176, BUG-177, BUG-178.

---

## BUG-175: `zebra.exe` panics `File.read error` when run outside the repo dir ✅ FIXED (2026-07-14)

**Severity:** high — a shipped compiler that only runs inside its own source tree
is a 0.9 ("ready for others") adoption blocker. Surfaced by the Mosaic POC (finding
#1).

**Symptom:** the selfhost `zebra.exe` panics `File.read error` (after "resolved OK")
on ANY program — hello world included — when the cwd is not the repo root. The
**bootstrap** works anywhere.

**Root:** the selfhost reads the stdlib preamble at codegen time via
`File.read("selfhost/stdlib_preamble.zig")` — a **cwd-relative** path
(`main.zbr`). The bootstrap **embeds** the preamble at build time
(`build_options.stdlib_preamble_pre_gui/post_gui`), so it needs no runtime file.
This was both a usability bug and a self-hosting equivalence gap (the bootstrap ran
anywhere; the selfhost did not).

**Fix:** resolve the preamble repo-relative first (keeps every gate — all run from
the repo root — byte-identical), then fall back to a copy installed alongside the
exe. Mirrors the existing sqlite3.c exe-dir pattern (`sys.selfExe()` +
`Path.dirname()`, `main.zbr:2189`). `build.zig` now installs
`selfhost/stdlib_preamble.zig` → `bin/stdlib_preamble.zig` next to `zebra.exe`.
Verified: runs from the repo root, from `scratchpad/`, and from `C:\tmp`; full
round-trip byte-identical; smoke 233/233. Selfhost-only convergence (bootstrap
already embeds).

---

## BUG-176: inferred `split()`/`lines()` now materializes to an indexable `List(str)` ✅ FIXED (2026-07-14)

**Severity:** medium — documented as `List(str)` (QUICKSTART) but not indexable in
the common inferred form. Surfaced by the Mosaic POC (finding #2).

**Symptom (was):** `s.split(sep)` lowers to `std.mem.splitSequence` (a lazy
iterator). `for x in s.split(sep)` worked; `var cols = s.split(sep)` then `cols[0]`
failed to compile (`SplitIterator does not support indexing`). Materialization into
a `List(str)` happened **only** when the target was explicitly annotated
`var cols: List(str) = s.split(sep)` (the BUG-092 path).

**Fix (both compilers):** when a var's init is a `split`/`lines` call with **no
annotation**, materialize the iterator into a `List(str)` — the inferred/indexed
case now behaves like the annotated one. `for x in s.split()` stays lazy (it's an
inline split, not a var initializer, and is intercepted in the for-loop codegen).
- **Selfhost** (`CodeGen.zbr` genLocalVar): a self-contained branch emits the
  `std.ArrayList([]const u8)` materialization and binds the local as `list_(string_)`.
- **Bootstrap** (`src/CodeGen.zig` genLocalVar): synthesizes a `List(str)` `type_` so
  the existing annotated materialization + `objIsList` (→ `.items`) treat it as a
  List. Idempotent, codegen-last-pass.

**Also fixed the POC's #6 on the bootstrap side (prerequisite):** indexing a
`List(str)` in interpolation emitted `{any}` (byte-array output) — and `.lines()`
elements emitted `{u}` (char, a compile error) — because the bootstrap TC didn't type
`str_slice[i]` as string and miscategorised `lines` as returning `.string`. Fixed in
`src/TypeChecker.zig`: `index` typing gained a `.str_slice → .string` arm, and
`split`/`lines` now consistently type as `.str_slice` (moved `lines` out of the
returns-`.string` set). (`#6` was only ever verified fixed on the selfhost before.)

**Verified:** the full split/lines battery (index / `.len` / `.at` / for-in /
annotated) produces **byte-identical output on both compilers**; `tools/dogfood`
`split_inferred` flipped SHARED-GAP → clean with no new divergences; full round-trip
byte-identical; smoke 233/233; fuzzer 0-99 clean. Regression:
`test/bug176_split_list_test.zbr`.

**Not covered (rare, documented):** `s.split(sep)[i]` indexed *directly* without an
intermediate var (a call-result index) — the BUG-177 family; bind to a var first.

---

## BUG-177: bracket-index on a non-name base omits `.items` ✅ FIXED on the selfhost (2026-07-14); bootstrap selfhost-ahead for `x[i][j]`

**Severity:** low — narrow; trivial workaround (bind the call to a var first).
Surfaced while reducing Mosaic finding #6.

**Symptom:** indexing the direct result of a `List`-returning call —
`makeFloats()[1]` — emits `makeFloats()[i]` instead of `makeFloats().items[i]`, so
Zig rejects it (`array_list.Aligned does not support indexing`). Local-var and
struct-field list indexing both correctly emit `.items[i]`. The index-lowering only
inserts `.items` for a base it recognizes as a list local/field (name-keyed via
`fieldAwareIsList(name)`), not for a raw call expression.

**Related manifestation — nested bracket index `x[i][j]` (SHARED, both fail).**
The dogfood sweep (2026-07-14) found that chaining bracket indexes — `grid[0][1]`
where `grid: List(List(int))` — misses `.items` on the *inner* result and is
rejected by **both** compilers (`array_list.Aligned does not support indexing`).
`grid.at(0).at(1)` works on both. Same root as the call-result case: the index-read
`.items` insertion is name-keyed (`fieldAwareIsList(name)`), so any non-name base —
a call result *or* an index result — is missed. The two cases differ only in
bootstrap coverage: it handles the call-result base but not the nested-index base.

**FIXED for `f()[i]` (2026-07-14, selfhost convergence):** the call-result case was a
**selfhost-only divergence** (the bootstrap already emitted
`makeFloats().items[@intCast(1)]`). Fixed in `selfhost/CodeGen.zbr`'s index-read: when
the base is a non-name expression, if it's an `Expr.call` whose inferred type is
`list_`, emit `.items`. Now byte-identical on both compilers (verified via
`tools/dogfood/`). Regression `test/bug177_178_index_tostring_test.zbr`.

**`x[i][j]` (nested index base) — FIXED on the selfhost (2026-07-14); bootstrap is
selfhost-ahead.** The selfhost index-read now emits `.items` for *any* non-name base
whose inferred type is a list (via `inferExpr`), so `x[i][j]` — and arbitrary depth
`x[i][j][k]` — work on the **primary** compiler. The **bootstrap still fails** it: its
TC lacks a real typed-List representation (it limps via `{any}` + `str_slice`
special-cases and has no general `List(T)[i]→T` element typing), so bringing it to
parity would be a major TC refactor of a phasing-out compiler. Per the drop-bootstrap
policy ([[feedback_drop_bootstrap_parity_ok]]) this is left **selfhost-ahead** and
tracked under BUG-179; `.at(i).at(j)` remains the bootstrap-compatible idiom. The
selfhost source uses `.at()`, so the round-trip / `--update` are unaffected.

---

## BUG-178: `str.toString()` emitted `{}` (no specifier) — now identity ✅ FIXED (2026-07-14)

**Severity:** low — an identity call you'd rarely write directly, but a hazard for
generic `@derive`/interface code that calls `.toString()` on a value that happens to
be a `str`. Surfaced verifying the numeric-conversion matrix (Mosaic finding #3).

**Symptom (was):** `var s = "hi"; s.toString()` emitted `std.fmt.allocPrint("{}", .{s})`
— a bare `{}` on a `[]const u8`, which Zig rejects (`cannot format slice without a
specifier`). `toString()` on int/float/bool worked. Failed identically on **both**
compilers (shared bug, no reference to converge to).

**Fix:** `str.toString()` is an **identity** — the receiver is already a string — so
emit the receiver directly (no `allocPrint`). Both compilers: `src/CodeGen.zig` (a
`.string` arm in the toString method codegen) and `selfhost/CodeGen.zbr` (the
str-method dispatch's toString arm). Verified byte-identical (`s.toString()`,
`(5).toString()`, `true.toString()` all agree); regression
`test/bug177_178_index_tostring_test.zbr`.

---

## BUG-179: selfhost-ahead constructs the bootstrap rejects — WON'T-FIX on bootstrap (drop-parity), latent `--update` traps ✅ RESOLVED-AS-DOCUMENTED (2026-07-14)

**Severity:** low — harmless for users (the selfhost is the primary compiler), but a
latent trap for **compiler source**: `--update` regenerates `selfhost/*.zig` via the
**bootstrap**, so any selfhost `.zbr` that uses a selfhost-only construct would fail
to regen. Surfaced by the differential dogfood sweep (`tools/dogfood/`, 2026-07-14).

**Decision (2026-07-14): these are deliberately left selfhost-ahead — the bootstrap
will NOT be brought to parity.** They all trace to the bootstrap TC lacking a real
typed-List representation (it limps via `{any}` + `str_slice` special-cases), so
fixing them is a major TC refactor of a phasing-out compiler. Per the drop-bootstrap
policy ([[feedback_drop_bootstrap_parity_ok]]), that investment isn't warranted; the
selfhost (primary) handles all of them. The hard constraint holds: none appear in
`selfhost/*.zbr`, so the round-trip / `--update` stay green.

**Known selfhost-ahead constructs (bootstrap rejects, selfhost accepts):**
- **`expr.len.toFloat()`** — the bootstrap TC types `List.len` as unknown (not
  `.int`), so `.toFloat()` doesn't dispatch to the numeric lowering and `zig` rejects
  the literal `.toFloat()` call. NB `expr.len.toString()` works on **both** (used in
  selfhost source) — the gap is `toFloat` specifically.
- **`var (a, b) = call()`** — positional destructure of a tuple-returning call; the
  bootstrap TC rejects it (`expected 'tuple'`).
- **`x[i][j]` / deeper nested bracket index** — the selfhost emits `.items` for any
  list-typed non-name base; the bootstrap lacks general `List(T)[i]→T` typing. See
  BUG-177.

**Standing caution for compiler source:** if you add any of these to `selfhost/*.zbr`,
`--update` will break with a bootstrap emit/compile error. Hoist to a plain `int`
local (`var n = x.len; var f = n.toFloat()`), use `.0`/`.1` tuple field access, and
`.at(i).at(j)` for nested indexing.

**Also observed (by design, not a bug):** `int * float` mixed arithmetic is rejected
(no implicit promotion — use `.toFloat()`), but the two compilers fail *differently*
— the bootstrap rejects cleanly at TC, the selfhost emits invalid Zig. Minor
selfhost robustness gap: it should reject mixed-numeric arithmetic at TC like the
bootstrap rather than emit un-compilable output.

---

## BUG-174: `str.indexOf` signature divergence ✅ RESOLVED (verified closed 2026-07-28)

**RESOLVED — verified 2026-07-28.** The three-way inconsistency below is gone; the
design call was effectively made (BUG-181 aligned the selfhost) and the docs were
updated, but the ticket was never closed. It has been sitting in the pre-1.0
blocker list as an open decision that no longer needs deciding.

The convention that actually shipped is **mixed, and consistent everywhere**:

| method | returns | not-found |
|---|---|---|
| `indexOf(sub)` | `int` | `-1` |
| `lastIndexOf(sub)` | `int` | `-1` |
| `indexOfFrom(sub, from)` | `int?` | `nil` |
| `indexOfIgnoreCase(sub)` | `int?` | `nil` |

That split is defensible rather than accidental: the plain forms are used in
arithmetic (`indexOf(x) + 1`), which an optional makes painful — the note at
`CodeGen.zbr` records exactly that as the reason BUG-181 moved the selfhost to the
sentinel. The offset/case-insensitive forms are not used that way and keep `int?`.

Verified by running the same program through BOTH compilers:

    indexOf hit=1  miss=-1  (negative-on-miss branch taken)   — identical
    lastIndexOf 4                                              — identical
    indexOfFrom("b", 2) -> 4 via `f!`                           — identical
    indexOfIgnoreCase("B") -> 1 via `ic!`                       — identical

QUICKSTART:1085 now documents `(str): int` / "`-1` if not found", matching. The
`test/stdlib_str_test.zbr` comment that once contradicted the docs is now correct.

Historical detail below is kept for the record.

**Severity:** medium (equivalence divergence on a documented stdlib method; the
selfhost additionally emits invalid Zig). Surfaced 2026-07-12 hand-testing the
string-method surface before adding it to the fuzzer.

**Three-way inconsistency:**
- **QUICKSTART** (lines 972, 1038-1041) documents `indexOf`/`lastIndexOf`/
  `indexOfFrom`/`indexOfIgnoreCase` as returning **`int?`** ("nil if not found").
- **Selfhost** TC agrees (`TypeChecker.zbr:1275` → `optional(int_)`), BUT its
  codegen is **broken**: `CodeGen.zbr:10345` (and `:11259`) emits
  `blk: { … break :blk if (_idx) |_i| @as(i64, @intCast(_i)) else null; }` — Zig
  fixes the block type to `i64` from the first branch, so `else null` fails with
  `expected type 'i64', found '@TypeOf(null)'`. So even the *documented* usage
  (`var x: int? = s.indexOf(y)`) doesn't compile on the selfhost.
- **Bootstrap** contradicts the docs: types it as **`int`** and emits
  `(if (std.mem.indexOf(...)) |_i| @as(i64, @intCast(_i)) else @as(i64, -1))`
  (−1 sentinel) — self-consistent, compiles, runs.
- A **test comment** (`test/stdlib_str_test.zbr:19`) says "returns -1 when not
  found", contradicting QUICKSTART — so the spec itself is ambiguous.

**Resolution is a DESIGN CALL (deferred to Sean).** Two clean options:
1. **Commit to `int?` per QUICKSTART** (recommended — matches the docs + the
   language's nil-tracking ethos): fix selfhost codegen to emit a valid `?i64`
   (`@as(?i64, @as(i64, @intCast(_i)))` in the found branch, `null` else); change
   bootstrap TC (indexOf/lastIndexOf → optional int) + codegen (`else null`);
   update the stdlib_str_test comment + any `== -1` assertions. Covers the whole
   indexOf family.
2. **Change to `int` (−1)**: update QUICKSTART + selfhost TC/codegen to match the
   bootstrap. Simpler but less idiomatic.

Until resolved, the `indexOf` family is **excluded from the fuzzer's string-method
cap** (it would generate divergent programs). Other string methods (upper/lower/
trim/trimLeft/trimRight/replace/contains/startsWith/len) verified equivalent.

---

## BUG-173: selfhost string-literal-vs-slice coercion — emit divergence ✅ FIXED (2026-07-13)

**Severity:** medium (selfhost emitted invalid Zig where bootstrap was correct — a
real equivalence bug). Surfaced 2026-07-12 by the fuzzer (fuzz finding **F12**).

**Symptom:** on some programs, the **selfhost** emitted Zig that `zig` rejected with
`expected type '*const [N:0]u8', found '[]const u8'` (or the reverse `[1:0]u8`
cannot cast into `[2:0]u8`) — a fixed-size string-literal array type where a slice
was needed. The **bootstrap** emitted code `zig` accepts. Verdict `zig-diverge-B`
(selfhost side). Reproducers: `fuzz/findings/seed{80,83,89}_zig-diverge-B.zbr`.

**Root (confirmed, NOT the suspected union/struct path):** `genLocalVar` in the
selfhost annotated an untyped local from its initializer *only for INT/FLOAT
literal shapes* (`int_lit`/`float_lit`/neg-unary). Its non-literal fallback
covered only `int_`/`float_` from the TC-inferred type. A **string-typed
non-literal init** — a ternary (`var v7 = if(c, "ggbb", " d")`), a concat, or a
`str`-returning call — therefore fell through with **no annotation**, so Zig
inferred `*const [N:0]u8` from the initializer literal. A later assignment of a
different-length string literal (`v7 = "f"`) then failed to unify. The bootstrap
annotates `var v7: []const u8 = …` via `tcTypeAnnotation` (src/CodeGen.zig
`genLocalVar`).

**Fix:** ported the bootstrap's `tcTypeAnnotation` helper into
`selfhost/CodeGen.zbr` (maps a `Type_` → Zig annotation: int/uint/float/bool/
char/**string**/str_slice/void/sized-numerics/optional-recurse; `""` for
named/generic/stdlib where Zig infers correctly) and replaced the `int_`/`float_`-
only fallback in `genLocalVar` with a call to it. This closes the `string_` gap
that was BUG-173 and pre-emptively the sibling gaps (`uint_`/`char_`/`str_slice`/
`optional`). Verified: all three reproducers compile; fuzzer oracle `ok` on seeds
80/83/89; smoke 233/233; full round-trip byte-identical. Regression:
`test/bug173_string_coerce_test.zbr` (ternary / concat / call string inits +
reassignment).

**Why the earlier hypotheses missed it:** F12's ruled-out probes (string `==`
ternary; string var-lit → reassign) both happen to take literal-shape paths or
same-length reassignment, so neither hit the non-literal-init + different-length
combination that is the real trigger.

---

## BUG-172: `char`/`uint` as a generic type argument — resolver gap ✅ FIXED (2026-07-12)

**Severity:** low-medium (bootstrap/selfhost divergence; narrow trigger).
Surfaced 2026-07-10 building the LSP hover/definition (`var chars: List(char) =
List(char)()` in main.zbr).

**Symptom:** `List(char)()` (constructing a `List` of `char`) fails the level-2
selfhost (`selfhost-A`, built from the running compiler's own emit) with
`error: undefined name: 'char'` at the constructor's type argument — while the
running `zebra.exe` compiles and runs the same code fine. So it breaks the
round-trip (selfhost-A can't re-emit a source that uses it), even though the
feature works at runtime. `char` as a param/return type (`def peek(): char`) and
in comparisons works everywhere; only `char` as a **generic type argument in a
constructor** trips it.

**Root (suspected):** the selfhost resolver/codegen doesn't register `char`
(kw_char) as a resolvable type name in the generic-constructor argument position,
so a compiler built from the selfhost's own emit rejects it. Likely a missing
builtin-type case in the generic-arg resolution path (parallels how `int`/`str`
are handled). Needs a minimal repro + a resolver/codegen arm for `char` (and
probably `bool`/`float`) as generic args.

**Fix (2026-07-12):** the real root was narrower and the *opposite* asymmetry from
the note above — the **selfhost** resolver rejected it while the **bootstrap**
accepted it. `selfhost/Resolver.zbr` `isBuiltin()` whitelisted only
`int/str/bool/float` as builtin type names; `char` and `uint` (both keyword
primitives, both already handled by `typeFromName` → `Type_.char_`/`uint_` and by
codegen → `u21`/`u…`) were missing, so in type position (e.g. the generic arg of
`List(char)`) they resolved as "undefined name". Added `char`/`uint` to `isBuiltin`.
Verified: `List(char)`/`List(uint)` now emit `std.ArrayList(u21)`/`…` and run on
BOTH compilers. Regression test: `test/bug172_list_char_test.zbr` (smoke).

**Related gap (lower priority, NOT fixed):** the sized numeric types (`int32`,
`uint64`, `float64`, `byte`, `usize`, …) are *non-keyword* identifiers, so as a
generic arg (`List(int32)`) they fail earlier — at the **parser**
(`unexpected expression token: 'int32'`) — not the resolver. `typeFromName` +
codegen already handle them; a parser arm to accept them in type-arg position
would close it. Discovered while fixing BUG-172.

**Old workaround (no longer needed):** string slicing (`s[a..b]`) + a char-at
helper. `main.zbr` `lspWordAt` still uses this but could now use `List(char)`.

---

## BUG-171: selfhost lexed a bare `'Z'` char literal as a string ✅ FIXED (2026-07-09)

**Severity:** medium (bootstrap/selfhost parity gap; selfhost rejected valid code).
Surfaced 2026-07-08 while building a char-based discriminator for fn-type
inference — unrelated to fn-types.

**Symptom:** a bare single-quoted char literal (`'Z'`, no `c'` prefix) in a
`char`-typed context failed on the selfhost:
```
def getCh(): char
    return 'Z'
```
→ `error: type mismatch: expected char, got str`. The bootstrap accepts it.

**Root:** the selfhost lexer dispatched a bare `'` straight to `scanString`
(always emitting a string token) — it had no char-vs-string disambiguation. The
selfhost's OWN sources only use the `c'…'` prefix form, so this path never bit
self-compilation. The bootstrap's `scanSingleQuote` emits a char literal for
single-char / single-escape content.

**Fix (2026-07-09):** added `scanSingleQuote` to `selfhost/Lexer.zbr` (mirrors
the bootstrap: `'X'` / `'\X'` → char literal, else string) + a codegen arm in
`selfhost/CodeGen.zbr` to emit an already-quoted bare char token as-is (the
`c'…'` path strips the `c`; the bare path was double-wrapping → `''Z''`). Fixture
`test/char_literal_test.zbr`. Gates green (smoke 228, round-trip byte-identical,
inference 0/414, fuzz 25).

---

## BUG-170: selfhost does not box a value struct assigned to a `^T` field ✅ FIXED (2026-07-09)

**Fix (2026-07-09):** `selfhost/CodeGen.zbr` `genAssign` now heap-boxes a value
struct assigned into a `^T`/`^T?` field. It resolves the target field's TypeRef
(`getAssignFieldType`, which handles both `field = x` and `self.field = x`); if it
is `ref_to` with an inner type in `struct_names`, it emits
`{ const _rp = _allocator.create(T) catch @panic("OOM"); _rp.* = value; target = _rp; }`
— identical to the bootstrap. Keying on `struct_names` (not "RHS is a value")
sidesteps the inferExpr-from-codegen problem: since `^Class` is rejected (BUG-078),
`^T` fields are struct or union, and only structs (value types) need the box; union
payloads are already pointers. `test/ref_struct_test.zbr` now registered in smoke
(passes both compilers, round-trip byte-identical, inference 0/414, fuzz 25).

---

### Original report (pre-existing, selfhost-only)

**Severity:** medium (bootstrap/selfhost parity gap; selfhost emits invalid Zig
for a narrow struct pattern). Surfaced 2026-07-05 while making `^ClassName` a
hard error — `test/ref_struct_test.zbr` (a struct `^Point` field test, never
registered in the smoke suite) fails on the selfhost compiler while bootstrap
passes.

**Symptom:** `holder.p = pt` where `p: ^Point` (a `^`-indirected **struct**
field) and `pt` is a value `Point`. Selfhost emits `self.p = pt;` — assigning a
`Point` value to a `*Point` field — which Zig rejects with
`error: expected type '*Point', found 'Point'`.

**Expected (bootstrap emits):**
`{ const _rp = _allocator.create(Point) catch @panic("OOM"); _rp.* = pt; self.p = _rp; }`
— heap-box the value and assign the pointer.

**Root:** `selfhost/CodeGen.zbr` `genAssign` has no boxing path for `^T` fields.
It knows which fields are `^T`/`^T?` (`ref_fields`/`opt_ref_fields` StrSets +
`getAssignFieldType`), but never emits the create-and-copy box when the RHS is a
value. The hard part (why it isn't a trivial fix) is deciding *when* to box:
only when the field is `^T` **and** the RHS is a value (not already a pointer,
e.g. another `^T` field read or a class instance). Making that call precisely
needs `inferExpr` on the RHS from within codegen — the same "least confident"
struct-field-boxing area flagged in `test/recursive_type_test.zbr`.

**Scope note:** This is NOT about classes — after BUG-078's `^ClassName`
rejection, `^` only ever wraps structs/unions, and only structs are value types
needing the box. The only in-repo trigger is `ref_struct_test.zbr`, which is why
it went unnoticed (not in the smoke suite). `test/val_lib.zbr` (union `^Val?`)
is a *field type* only, not an assignment, so it doesn't hit the gap.

**Status:** documented, deferred — not introduced by the `^ClassName` work (the
class boxing it replaced was identity/no-op). Fix = add a `^T`-field boxing arm
to selfhost `genAssign` gated on an `inferExpr`-based value-vs-pointer check,
then register `ref_struct_test` in the smoke suite.

## BUG-169: unused capture/local discard skipped when body holds an unmodeled expr (ternary) ✅ FIXED

**Severity:** medium (shared robustness gap — both compilers emit the same
invalid Zig; `error: unused capture` / `unused local constant`). Found
2026-07-03 by the fuzzer's enum/union/branch batch = fuzz finding **F11**.

**Symptom:** `if x as y` (or for-in / unused local) where the binding is never
read AND the body contains a **ternary** (`if(c,t,e)`) — or any of `try_`,
`catch_`, `to_non_nil`, `is_nil`, `cast`, `type_check`, `opt_chain`, `slice` —
emits the capture without the `_ = y;` discard, which Zig rejects.

**Root (confirmed by reading the walker, no build):** the discard fires only
when `mightUseName(cap, body)` is FALSE; `mightUseNameInExpr` doesn't model
those expr forms, so they hit `else => true`, the discard is skipped, and a
genuinely-unused binding errors. Same family as BUG-161 (that fix added
string_interp/orelse/this to the same walker). Deeper defect: `mightUseName`
is *conservative* ("true when unsure"), but the discard decision needs an
*exact* walker — both error directions are compile errors. `mightUseNameStmt`
has the analogous gap for unmodeled statement forms.

**FIXED 2026-07-03:** added the missing arms to `mightUseNameInExpr`
(if_expr/try_/catch_/to_non_nil/is_nil/cast/type_check/slice/opt_chain/dict_lit;
+except_ on the selfhost) and `mightUseNameStmt` (branch/try_catch/raise/
assert/defer) in both compilers, mirroring the complete `nameUsedInExpr`/
`nameUsedInStmt`; conservative `else => true` kept for the rare remainder
(lambda/with/allocate/copy_out/except-stmt — over-approx there is the safe
direction). Seed 39 → ok; both 80-seed `both-zig-fail` closed; smoke +
round-trip green. Regression `test/fuzz_f11_unused_capture_ternary_test.zbr`
(registered in smoke). **Residual (documented):** an unused binding whose sole
use sits inside a still-unmodeled form would over-conservatively skip its
discard; long-term robust retirement = switch the discard decision to an exact
`collectAllIdents(body)` membership check. Full analysis in `fuzz/FINDINGS.md`
F11; cross-ref `docs/walker_discipline.md` (exact-vs-conservative walker lesson).

---

## BUG-168: cross-module PRIMITIVE-returning free fns untyped at bootstrap call sites ✅ FIXED

**Severity:** medium (bootstrap-lags-selfhost class; `greet(x) + "!"` on a
cross-module `greet(): str` emitted raw Zig `+` on slices — 'pointer' and
'pointer').  Hit twice from inside the compiler's own sources during the
BUG-162 work (worked around with `var z: str = call(...)` hoists), tracked
informally since, minimal repro + fix 2026-07-02.

**Root cause (two layers, both bootstrap-only — the selfhost stores full
`Type_` in dep_types and was always correct):**
1. `extractFromDecls` recorded a free fn's return in `fn_return_types` only
   via `namedTypeStr`, which deliberately skips builtins — so a `: str`
   return was never recorded, and `inferCall` typed the call `.unknown`.
2. `genBinary .add` consulted only the LEFT operand's type (the selfhost's
   helper is literally named `isStringBoth`).

**FIXED (2026-07-02):**
- `primTypeName` records `str/int/float/bool/char` returns in
  `fn_return_types`; the consultation site maps those names back to
  primitive `Type`s instead of wrapping them `.cross_module`.
- `genBinary .add` checks both operands (either side string ⇒ concat;
  `str + non-str` is a TC error upstream, so the OR cannot misfire).
- Validation bonus: regenerating the selfhost with the fixed TC changed
  exactly ONE emitted line — `var lv_used = mightUseName(...)` gained its
  `: bool` annotation, i.e. the compiler's own emission got more precise.

Regression: `test/bug168_crossmod_prim_return_test.zbr` (+`_lib`; call+lit,
lit+call, call+call, int/float arithmetic), registered in smoke.  The
BUG-162 `zigSafeName` hoist workarounds in `selfhost/CodeGen.zbr` are now
unnecessary but harmless — left in place (cosmetic revert, low value).

---

## BUG-167: parsers accepted different ternary syntaxes; literal arms uncompilable ✅ FIXED

**Severity:** medium (front-end equivalence divergence + a feature that was
unusable with literal arms in runtime contexts).
**= fuzz finding F8**, found while writing the F7 fixture (2026-07-02).

The bootstrap parsed the ternary as call-form `if(cond, then, else)`; the
selfhost parsed a colon-form `if c: t else: e`. Each rejected the other's
syntax. Zero corpus usage, no QUICKSTART documentation — invisible until a
fixture tried to use one. Separately, literal arms emitted bare
`comptime_int`/`comptime_float`, which Zig rejects under a runtime
condition.

**FIXED (2026-07-02):** converged on the **call-form** (bootstrap's):
selfhost `parseAtom` now parses `if(c, t, e)`; the colon arm is removed.
(The FINDINGS note initially recommended the colon form; reversed on
implementation grounds — see FINDINGS.md F8.) Both emitters wrap the
ternary in `@as(i64/f64, …)` when the TC types it numeric, fixing the
literal-arms case. Documented in QUICKSTART §13; the fuzz generator now
produces ternaries. Regression: `test/fuzz_f8_ternary_test.zbr`.

---

## BUG-166: selfhost `stmtMentionsThis` blind to else/else-if branches ✅ FIXED

**Severity:** medium (selfhost-only equivalence bug — a method whose ONLY
self-use sits in an `else` branch emitted `_ = self;`, which Zig rejects as
a pointless discard once the else-branch use compiles).
**Found by the differential fuzzer** (seed 51, verdict `zig-diverge-B`) in
the first 60-seed batch after the BUG-164 work — fuzz finding **F10**.

**Root cause:** `selfhost/CodeGen.zbr stmtMentionsThis`'s `Stmt.if_` arm
scanned `then_stmts` + `cond` but skipped `else_ifs` and `else_stmts`
entirely, so `.field = x` in an else branch was invisible to the
`_ = self;` suppression. The bootstrap (`collectRefs`) has no such gap.
Sibling walkers audited clean: `nameUsedInStmt` and `methodMutatesSelf`
if-arms already cover else/else-if.

**FIXED (2026-07-02):** the arm now scans else-if conds/bodies and the else
body. Regression: the else-only-self-use method shape added to
`test/fuzz_f6_unused_capture_test.zbr`; fuzz seed 51 → `ok`.

**Second face (same day, seeds 61/63/69/75/76/83/89/91):** as soon as the
generator gained range loops, the same walker failed one arm over —
`stmtMentionsThis` had NO `Stmt.for_num` arm (its `else` returns false), so
a self-use only inside a range loop emitted a pointless `_ = self;`. Fixed
(for_num arm: start/stop/step + body); Gauge.fill regression shape added.
Design caution: unlike the conservative mightUseName family, this walker
must be EXACT — both error directions are Zig compile errors (pointless
discard vs unused parameter) — so any new Stmt form must be added here.

**Adjacent hardening in the same session:** the BUG-164 if-as discard sites
gained a `cap != "_"` guard — `if x as _` (Zebra's explicit discard
binding) previously made the new code emit `_ = _;`, invalid Zig; caught by
`crypto_test` in the smoke suite before commit.

---

## BUG-164: unused `if-as` / for-in captures emit payloads Zig rejects ✅ FIXED

**Severity:** medium (any legal Zebra program that binds without reading —
`if x as y` for a presence check, a loop over a list just for its count —
failed to compile in both compilers with "unused capture").
**Found by the differential fuzzer** (`fuzz/` finding **F6**, seeds 3/27).

Probing showed no unused-binding suppression existed for `if x as y` at all
(the suppression in the codebase belongs to `branch` codegen), and for-in
arms were a patchwork: hashmap/tuple/range handled it (tuple with two latent
flaws — under-approximating `nameUsedInStmts` risking *pointless* discards,
and ignored where-clause uses), list/chars/split/bytes/sqlite leaked.

**FIXED (2026-07-02), both compilers:** if-as capture arms (union-variant,
`is T as`, plain `as`) and a shared `discardUnusedLoopVars` helper in every
capture-style for-in arm now emit `_ = v;` when neither body nor
where-clause provably reads the binding (`mightUseName` — conservative, so
no pointless-discard risk; precise enough thanks to the BUG-161 modeling).
Tuple arm switched to the same analyzer. Generator's for-in usage mask
removed so this stays differentially tested.
Regression: `test/fuzz_f6_unused_capture_test.zbr`. See FINDINGS.md F6.

---

## BUG-165: range for-in — docs said `to`, bootstrap had usize `..`, selfhost had neither ✅ FIXED (= fuzz F9)

**Status:** FIXED 2026-07-02 (found the same day while probing BUG-164).
Three-way inconsistency: QUICKSTART §13's documented `for i in 0 to 10` (+
`step`) is rejected by BOTH compilers; the bootstrap parses `for i in 0..3`
(and QUICKSTART §33/§35 use that form); the selfhost parser rejects `..` in
for-in entirely ("expected indent, got '..'" — its `..` is slice-context
only). `0.to(n)` method form works in both, and probing revealed the colon
for_num form (`for i in a : b [: step]`) worked in BOTH compilers all along
— the real canonical range.

**FIXED:** `..` is now an alias of the `:` for_num form in both compilers:
the selfhost parses `a..b` into the same for_num node (no step after `..`,
matching the bootstrap); the bootstrap routes binary-dotdot iterables to
the shared i64 counter lowering instead of Zig's native `for (a..b)` —
whose usize counter rejected negative bounds and underflow-panicked on
`i - 1` at zero (a silent semantic split from `:`/`.to()`). Also fixed en
route: bootstrap `genForNum` now brace-scopes its counter like the selfhost
(two same-named colon loops in one scope previously collided). QUICKSTART
§13 corrected to the real forms. Regression: `test/fuzz_f9_range_test.zbr`.
See FINDINGS.md F9.

---

## BUG-163: orelse/catch/if-expr/try re-emitted without parens → precedence miscompile ✅ FIXED

**Severity:** high-medium (silent semantics class: valid Zebra can emit Zig
that re-associates differently; the fuzz hit failed loudly, but shapes like
`(a - b) orelse c` vs `a - (b orelse c)` could compile AND misbehave).
**Found by the differential fuzzer** (`fuzz/` finding **F7**, seed 7,
2026-07-02) — first finding from the post-BUG-162 unmasked batches.

**Symptom:** `C5((1 - (v26 orelse 8)))` emitted `C5.init((1 - v26 orelse 8))`;
Zig parses that as `(1 - v26) orelse 8` → invalid operands (or, worse,
different runtime semantics where both parses type-check).

**Root cause:** the Zebra parser drops redundant source parens (no paren AST
node), so codegen must re-establish precedence — but the `orelse_`, `catch_`,
`if_expr`, and `try_` emission arms printed bare. All four bind looser than
every Zig operator, so ANY nesting inside a binary/call-arg/tighter context
broke. (`1 + try f()` is also invalid Zig — the `try` arm had the same gap.)

**FIXED (2026-07-02), both compilers** (`src/CodeGen.zig` genExpr +
`selfhost/CodeGen.zbr` genExpr): those four arms now always self-parenthesize
(`(x orelse y)`, `(x catch |e| f)`, `(if (c) a else b)`, `(try x)` — including
the try-block-label catch form). Redundant parens are harmless.
Regression: `test/fuzz_f7_precedence_test.zbr`. Smoke + round-trip green;
seed 7 → `ok`.

**Surfaced en route (filed as fuzz F8, OPEN):** the two parsers accept
*different* ternary syntaxes — bootstrap `if(c, t, e)` call-form vs selfhost
`if c: t else: e` colon-form — with zero corpus usage and no QUICKSTART
documentation; plus literal ternary arms emit bare `comptime_int` in runtime
contexts. Reconcile as its own task (see FINDINGS.md F8).

---

## BUG-162: identifiers shadowing Zig primitives emitted bare → invalid Zig ✅ FIXED

**Severity:** medium (shared robustness gap; any user program naming a var or
param `i8`/`u32`/`f64`/`usize`/`c_int`/… failed to compile in both compilers
with Zig's "name shadows primitive").
**Found by the differential fuzzer** (`fuzz/` finding **F1**, 2026-07-01);
compiler-side fix landed 2026-07-02 (was deferred to a gated session).

**FIXED (2026-07-02), both compilers:**
- `isZigPrimitiveName` predicate (iN/uN digit-run int types, f16–f128,
  bool/void/type/anyerror/anyopaque/anyframe/noreturn/comptime_*/isize/usize,
  the `c_*` ABI types, and the primitive values `null`/`undefined`).
- Bootstrap: `Generator.emitName` (writer-level, no allocation) applied at
  identifier-position emissions — genIdent, genLocalVar (all decl paths),
  genStmts unused-discard, genParamList-equivalents (method/init/ext/lambda
  sigs), unused-param discards, TCO shadows (`var X = _p_X` — bare `_p_X`
  side kept), interface shim/vtable/wrapper glue, closure-thunk glue,
  `export fn` shims, constraint-check `const value = X`.
- Selfhost: `zigSafeName` (returning form, for concat-style emission) +
  `emitName` mirror at the same logical sites.
- **Safety property:** `@"name"` is the SAME identifier as `name` in Zig
  (escaped spelling), so partial coverage degrades gracefully — an escaped
  reference to a bare-declared legal name stays consistent. Prefix-
  concatenated names (`_p_`, `_zbr_mv_`, `_ttag_`) must stay bare and do.
- **Residual (rare, deliberate scope bound):** for-in/`if-as` binding names,
  destructuring names, and struct/class *field* names that shadow a
  primitive still emit bare and still fail. Extend `emitName` coverage if a
  real program hits one.
- Selfhost-source trap discovered en route: `zigSafeName(x) + "lit"`
  (cross-module call result in a string concat) emitted raw Zig `+`;
  worked around by hoisting into annotated `var z: str = zigSafeName(x)`
  locals. Same class now tracked as fuzz finding **F7** (open).

Regression: `test/fuzz_f1_primitive_names_test.zbr`; generator now names
~10% of locals from a primitive pool so the escape stays differentially
tested. Smoke 192/192, round-trip byte-identical. See `fuzz/FINDINGS.md` F1.

---

## BUG-161: unused-local auto-discard missed by annotation / `this` / interp / orelse ✅ FIXED

**Severity:** medium (shared robustness gap — programs both compilers accept
emit Zig that `zig` rejects with `error: unused local constant`).
**Found by the differential fuzzer** (`fuzz/` finding **F2**), diagnosed
2026-07-02 by scope-shape probing after the trivial repro failed to reproduce.

**Symptom:** an unused local sometimes emits `const x = <expr>;` with no
`_ = x;` discard. One root cause, three faces, in `genStmts`' auto-discard
(both compilers):
1. the discard skip for explicitly-typed locals — needed only for
   *constrained-alias* types, whose inline contract check reads the local —
   covered **every** annotation (`var zz: int = 5` in any scope);
2. `Expr.this` was unmodelled in `mightUseNameInExpr` (conservative
   `else => true`), so any later `.field` statement in a method/`cue init`
   body suppressed the discard for **every** local in that body;
3. `string_interp` / `orelse_` were likewise unmodelled, so a later
   `print("${other}")` or `(other orelse 0)` suppressed all discards.

**FIXED (2026-07-02), both compilers** (`src/CodeGen.zig` +
`selfhost/CodeGen.zbr`/`CgHelpers.zbr`):
- `genStmts` skip narrowed to a new `varDeclEmitsConstraintCheck` predicate
  (named/`alias_applied` type resolving to a `where`-constrained alias, and
  contracts not stripped) — mirrors the constraint-check emission condition
  exactly, so the discard now fires for plain annotations and, under
  `--turbo`, for constrained-alias locals too (whose check isn't emitted).
- `mightUseNameInExpr` gained exact arms: `this` → false (keyword, never a
  user name), `string_interp` (recurse expr parts), `orelse_` (both sides).

Regression: `test/fuzz_f2_unused_local_test.zbr`. Gates: smoke 192/192,
round-trip byte-identical. See `fuzz/FINDINGS.md` F2.

---

## BUG-160: selfhost string-interpolation used `{}` for non-strings ✅ FIXED

**Severity:** medium (self-hosting equivalence + a real user-facing failure).
**Found by the differential fuzzer** (`fuzz/`), 2026-07-01 — its second divergence
(verdict `zig-diverge-B`, surfaced as a `zig` build timeout on the selfhost emit).

**Symptom:** interpolating a non-string value with no explicit format spec
(`print("${x}")`) diverged. The bootstrap emits the type-appropriate spec via
`printFmt` (`{d}` for float, `{any}` for List/struct/unknown); the selfhost's
`genStringInterp` hardcoded `{}` in the implicit case. Consequences:
- **float** → `{}` vs `{d}`: Zig 0.16 rejects `{}` on a float, or formats it
  differently → divergent output.
- **List/struct** → `{}` vs `{any}`: a `{}` on a `std.ArrayList` sends Zig's
  comptime default-struct formatter into a blow-up → **build timeout** (the
  selfhost emit was uncompilable where the bootstrap's compiled in ~6s).

**FIXED (2026-07-01):** the selfhost `genStringInterp` implicit case now routes
through `printFmtSpec(e)` (the existing mirror of the bootstrap's `printFmt`,
falling back to `{any}`) instead of a hardcoded `{}`. Selfhost-only (the bootstrap
was already correct). Round-trip byte-identical; smoke 192/192. Regression:
`test/fuzz_f4_interp_fmt_test.zbr` (float + List interpolation). See
`fuzz/FINDINGS.md` F4.

---

## BUG-159: selfhost omits numeric annotation on a mutated comptime-init local ✅ FIXED

**Severity:** medium (self-hosting equivalence). **Found by the differential
fuzzer** (`fuzz/`) on its first real run, 2026-07-01 — the first divergence it
caught (verdict `zig-diverge-B`: the selfhost emit is rejected by `zig`, the
bootstrap emit compiles).

**Symptom:** a mutated local whose init is a comptime-numeric *binary op* diverged:
```zebra
def main()
    var v = (8 * 2)   # bootstrap: `var v: i64 = (8 * 2);`   selfhost: `var v = (8 * 2);`
    v = v + 1         # → Zig: variable of type 'comptime_int' must be const or comptime
```
`v` is mutated → a Zig `var`; the init stays `comptime_int` unless annotated. The
bootstrap annotates untyped `var`s from the **TC-inferred type**
(`tcTypeAnnotation`); the selfhost's `genLocalVar` only special-cased literal
*syntax* (`int_lit`/`float_lit`/neg-lit), so a binary-op comptime init got no
annotation. (A plain `var v = 5` did not diverge — both annotate the literal.) The
round-trip gate never caught it: it compares selfhost-vs-selfhost, and the selfhost
is internally consistent.

**FIXED (2026-07-01):** `selfhost/CodeGen.zbr genLocalVar` now hoists the inferred
init type (`lv_infer_t = inferExpr(init)`) and, for a non-literal numeric init,
falls back to `: i64`/`: f64` — matching the bootstrap. Both compilers;
round-trip byte-identical; smoke 191/191. Regression:
`test/fuzz_f3_comptime_local_test.zbr` (int + float). See `fuzz/FINDINGS.md` F3.

---

## BUG-158: a module-global `var` is not accessible cross-module ✅ FIXED

**Severity:** medium. Found 2026-06-30 building the BBAT Roblox-globals shim.
Blocked the natural cross-module singleton pattern (`use robloxglobals exposing
game`) and cross-module data-module access.

**FIXED (2026-07-01):** implemented as designed below, both compilers. A new
`ModuleInterface.module_vars` (selfhost: `ModuleTypes.module_vars`) records the
dep's top-level `var`/`const` names; `genUse` skips the `const g = …` binding for
an exposed module var and records `g → alias` in `exposed_module_vars`; `genIdent`
rewrites each reference to the live `alias._zbr_mv_g`, shadow-safe (a local/param of
the same name keeps its bare name — an exposed cross-module var is unresolved, so
the guard checks the reference doesn't resolve to a local). Verified: scalar +
class-instance singleton work cross-module (`test/crossmod_modvar_test.zbr`, both
compilers, in smoke 190/190); round-trip byte-identical.

**Two limitations found (open):**
- **stdlib-container module vars.** An exposed `HashMap`/`List`/`Atomic` var
  dispatches a *throwing* method (`.put`) with no `catch` wrapper, because the
  consumer doesn't know the exposed var's type → `error: error union is ignored`.
  Class-instance singletons (the shim's use case) and scalars are unaffected;
  `_G` is a class with HashMap *fields*, so BBAT is covered. Fixing needs the
  interface to also carry exposed-var *types*.
- **explicit-receiver field `HashMap.put` misses the auto-`catch`.** Surfaced by
  the fix itself: `g.someField.put(k, v)` (a HashMap `.put` on a `localvar.field`
  receiver) does not get the error-catch the codegen adds for implicit-self
  `.field.put`. Worked around by wrapping in a method (implicit self); the
  underlying codegen gap remains.

---
### Original design (as implemented)

**Severity:** medium. Found 2026-06-30 building the BBAT Roblox-globals shim.
Blocks the natural cross-module singleton pattern (`use robloxglobals exposing
game`) and cross-module data-module access; the shim works around it by declaring
singletons in the *consuming* module and importing only the service *types*.

**Symptom:** `use m exposing g`, where `g` is a module-global `var` in `m`, emits
`const g = m.g;` — but the emitted Zig symbol is `m._zbr_mv_g` (the `module_var_prefix`
that keeps module vars from colliding with locals). Result:
`error: root source file struct 'm' has no member named 'g'`. (A `def`/`class`
exposed from `m` resolves fine — only module `var`s hit this.)

**Why the naive fix is wrong:** emitting `const g = m._zbr_mv_g;` binds the value
at import time (Zig container/global-init = comptime). That works for a
*non-deferred* module var (scalar/`List` — initialized at global scope), but a
*deferred* one (HashMap/Set/Atomic per BUG-153, or a class instance per BUG-157)
is `= undefined` until `_initModuleVars()` runs, so the `const` would capture
`undefined`.

**Fix direction (both compilers):** exposed cross-module module-var references must
resolve to `m._zbr_mv_g` **at each use site** (live), not a one-time `const` binding:
  1. `genUse`: when an exposed name is a module `var` in the dep (consult the dep's
     interface / `imported_modules`), do NOT emit `const g = …`; instead record
     `{g → alias m}` in a new `exposed_module_vars` map.
  2. `genIdent`: when emitting a reference to a name in `exposed_module_vars`, emit
     `m._zbr_mv_g` instead of the bare name.
  3. The dep's var is already `pub var _zbr_mv_g` — no dep-side change needed.
Mirror to `selfhost/CodeGen.zbr`; gate with the full round-trip + smoke. A regression
fixture should cover both a non-deferred (scalar/List) and a deferred (HashMap/class)
exposed module var, same-file and cross-module.

**Payoff:** lets `robloxglobals` expose real singleton `var`s (retire the per-script
injection in `luau2zebra_ast._emit_roblox_globals`), and lets a translated data
module expose its built table directly instead of a `def <mod>Data()` builder.

---

## BUG-150: `sys.sleep` emitted removed `std.Thread.sleep` (Zig 0.16) ✅ FIXED

**Severity:** high (every timing/poll path was uncompilable on Zig 0.16). Found
2026-06-30 dogfooding a multithreaded TCP server (`scratchpad/kv_dogfood.zbr`).

**Cause:** `sys.sleep(ms)` emitted `std.Thread.sleep(ns)`, which Zig 0.16 removed
(`error: root source file struct 'Thread' has no member named 'sleep'`). Sleeping
now goes through the Io interface: `std.Io.sleep(io, duration, clock)`.

**Fix:** new preamble helper `_sysSleep(ms)` → `std.Io.sleep(_io,
std.Io.Duration.fromMilliseconds(ms), .awake) catch {}` (`.awake` is 0.16's
monotonic clock; cancellation is benign for a pacing sleep so it's swallowed).
Both codegens now emit `_sysSleep(@as(i64, @intCast(<ms>)))`. One site in
`src/CodeGen.zig`, one in `selfhost/CodeGen.zbr`, helper in
`selfhost/stdlib_preamble.zig` (shared by both compilers).

## BUG-151: `var _ = expr` discard emitted invalid `const _ = expr` ✅ FIXED

**Severity:** medium. The QUICKSTART discard idiom `var _ = total.add(1)` emitted
`const _ = …;`, which Zig rejects: `error: '_' used as an identifier without @"_"
syntax`. (Zig only accepts the bare discard-assignment `_ = expr;`, never a
`const`/`var` binding literally named `_`.)

**Fix:** `genLocalVar` now special-cases name `==` `_` and emits `_ = <expr>;`
(or `_ = undefined;` when there's no init). One site each in `src/CodeGen.zig`
and `selfhost/CodeGen.zbr`.

## BUG-152: `ThreadPool.submit(def() …)` stored a comptime-only fn type ✅ FIXED

**Severity:** medium (the documented `pool.submit(def() doWork())` form did not
compile). `_ThreadPool.submit` boxed a by-value `fn() void` in a heap `FnBox`,
but a by-value function type is comptime-only: `error: cannot store
comptime-only type 'fn () void' at runtime`.

**Fix:** coerce to the fn-*pointer* type first — `const FnPtr = *const T; const
fp: FnPtr = f;` then box `fp` — exactly the pattern `_ws_serve`/`_http_serve`/
`_tcp_serve` already use (cf. caf477c). `selfhost/stdlib_preamble.zig`, `submit`'s
`.@"fn"` branch. `sys.go` was already fine (Thread.spawn takes a comptime fn).
Validated by `scratchpad/pool_dogfood.zbr` (4 workers run, `pool.wait()` joins).

## BUG-153: module-global var with an allocating initializer is uncompilable ✅ FIXED

**Severity:** high for concurrent/stateful programs (blocks the natural shape of
a shared store, global ECS/world, counters). Found 2026-06-30 dogfooding.

**FIXED (2026-06-30):** deferred init implemented in both compilers. A module-global
`var m: HashMap(K,V) = …` / `var a: Atomic(int) = …` (and `Set`/`Map`) is now emitted
`pub var _zbr_mv_m: T = undefined;` at container scope; the real assignment runs in a
generated `pub fn _initModuleVars()`, called from `_initIo` (so each dep module
self-initialises) and explicitly from the root entry thunk (whose `_initIo` is never
invoked). Requires an explicit type annotation (gives the `: T` and keeps the two
compilers symmetric). Bootstrap emits `_initModuleVars` in the file header; selfhost
emits it as a module footer (in `generateModuleWith`) with the call wired through the
`_initIo` preamble + entry thunks. A selfhost-only follow-on: a module-global `Atomic`
isn't tracked by `inferExpr` (locals/params only), so its `.add` was mis-rewritten to
`List.append` — the rewrite now consults `isModuleGlobalAtomic(name)` (scans
`module_decls`). Verified: `scratchpad/repro153.zbr` (bootstrap) +
`test/module_global_container_test.zbr` (selfhost, smoke 187/187).

**Remaining edge:** an *unannotated* module global (`var m = HashMap(K,V)()`) is not
deferred; module globals in a *non-root* module rely on the dep's `_initIo` path
(covered) but transitive-only deps aren't reached (matches the pre-existing
`_initAllocator`/`_initIo` propagation limitation).

---
### Original report

**Symptom:** a module-level `var m: HashMap(str,str) = HashMap(str,str)()` emits
`pub var _zbr_mv_m: … = std.StringHashMap(…).init(_allocator);` at container
scope → `error: unable to resolve comptime value … initializer of container-level
variable must be comptime-known`. Same for `var a: Atomic(int) = Atomic(int)(0)`
(emits `_atomic_create(…)`, which calls the page allocator at comptime →
`error: comptime call of extern function`). **Plain scalars and `List` globals
DO work** (`= 0`, `= .empty` are comptime-known) — only *allocating* inits fail.

**Symptom:** a module-level `var m: HashMap(str,str) = HashMap(str,str)()` emits
`pub var _zbr_mv_m: … = std.StringHashMap(…).init(_allocator);` at container
scope → `error: unable to resolve comptime value … initializer of container-level
variable must be comptime-known`. Same for `var a: Atomic(int) = Atomic(int)(0)`
(emits `_atomic_create(…)`, which calls the page allocator at comptime →
`error: comptime call of extern function`). **Plain scalars and `List` globals
DO work** (`= 0`, `= .empty` are comptime-known) — only *allocating* inits fail.

**Why it matters:** a `Tcp.serve` handler is a non-capturing fn (BUG-154), so the
only state it can reach is module-global. With allocating globals uncompilable,
you cannot write a correct shared-state TCP server (no global map, no global
atomic/lock). `kv_dogfood` works around it by keeping all shared state in plain-
int + `List` globals and serializing access on a single client.

**Fix direction:** deferred init. Emit `pub var _zbr_mv_X: T = undefined;` at
container scope and run the real `_zbr_mv_X = <init>;` from a generated
`_initModuleVars()` called once at startup — from the root entry thunk (after
`_io`/`_allocator` are live) AND from `_initAllocator` (so dep modules init too;
note the root never receives an `_initAllocator` call, so it needs the entry-thunk
path). Detect "non-comptime init" by collection/Atomic type. Touches both
codegens + entry/`_initAllocator` emission; gate carefully (round-trip risk).

## BUG-154: `Tcp.serve` spawns a thread per connection, but no synchronization is expressible

**Severity:** medium (design/ergonomics). `_tcp_serve` spawns a new
`std.Thread` per accepted connection, so handlers run **concurrently**. A handler
is coerced to `*const fn(TcpConn) void`, so it cannot capture — its only reachable
mutable state is module-global, which (BUG-153) cannot hold an `Atomic`/`Mutex`.
Net effect: **a concurrent TCP server cannot today protect shared state in
Zebra.** Observed as nondeterministic `panic: integer overflow` / `reached
unreachable code` under concurrent clients racing on `List.add`/counters.

**Fix direction:** depends on BUG-153 (global atomics/locks) and/or a capturing-
handler path for `Tcp.serve` (store the handler in a per-connection ctx that also
carries a user state pointer). Until then, document that handlers must be
stateless or access only single-writer state (one client at a time).

## BUG-155: `List` has no element setter / index assignment ✅ FIXED

**Severity:** low. `list.set(i, v)` → `error: no field or member function named
'set'`; in-place element update was impossible.

**FIXED (2026-06-30):** added `List.set(i, x)` to `genListMethod` in both compilers
— emits `list.items[@intCast(i)] = x` (the inverse of `at`), interning a `str`
element / boxing a `^T` element to match `add`'s ownership.  (Chose a `.set(i,x)`
method over new `list[i]=x` syntax — symmetric with the `.at(i)` getter, no parser
change.)  Regression: `test/list_setter_parse_test.zbr`.

## BUG-156: `str.toInt()` doesn't dispatch on a `List.at()` result ✅ FIXED

**Severity:** low (inference gap). `sp.at(0).toInt()` where `sp: List(str)`
emitted `…toInt()` raw → `error: no field or member function named 'toInt' in
'[]const u8'`.

**FIXED (2026-06-30):** two compiler-specific causes.
- Bootstrap (TypeChecker): generic-method inference (`List(T).at(i): T`) only fired
  when the receiver var had an explicit annotation. Added `listCtorTypeRef` so an
  unannotated `var sp = List(str)()` recovers `List(str)` from its init ctor, and
  `sp.at(0)` infers `str` → the `.toInt()` parse helper dispatches.
- Selfhost (CodeGen): the method-chain materializer hoisted `sp.at(0)` into
  `var _mc_N = …`, erasing the element type so `_mc_N.toInt()` mis-dispatched.
  `tryChain` now skips List index accessors (`at`/`first`/`last`) — they lower to
  `list.items[i]` (an lvalue, no temp needed), so the chain dispatches inline and
  sees the `str` element type.
Regression: `test/list_setter_parse_test.zbr`.

## BUG-157: module-global var holding a user class instance is uncompilable ✅ FIXED

**Severity:** high for the Roblox-globals shim + any singleton pattern. Found
2026-06-30 while building the BBAT service-global shim (`game`, `Players`, `_G`,
… as module-global singletons).

**Symptom:** `var g: Foo = Foo()` at module scope emits
`pub var _zbr_mv_g: *Foo = Foo.init();` at container scope; `Foo.init()` allocates
via `_allocator.create`, which Zig can't evaluate at global comptime →
`error: unable to resolve comptime value`. (Same class of failure as BUG-153, which
only deferred *containers* — HashMap/Set/Atomic.) Same-file cases masked it when the
global was unused, because Zig dead-strips the unreferenced decl.

**FIXED (2026-06-30):** extended the BUG-153 deferral to named user class instances.
`deferredModuleVarType`/`isDeferredModuleVar` now also defers a module-global `var`
whose annotated type is `.named` and whose initializer is a constructor/factory
*call* — emitted `= undefined`, assigned in `_initModuleVars()` (source order, so a
global may be constructed from an earlier-declared one). A second fix was required:
`genModule` now pre-registers cross-module *exposed* classes into `class_names`
before the `_initModuleVars` body is emitted, so a deferred init `Foo()` lowers to
`Foo.init()` (not `Foo()` → `type 'type' not a function`). Both compilers; round-trip
byte-identical; selfhost smoke 188/188. Regression:
`test/module_global_class_instance_test.zbr` (same-module + inter-global-dependency
ordering). Deferring is always safe — the assignment runs before any use, and
`const`/comptime-value globals are excluded.

**Remaining edges (separate gaps, not fixed here):**
- A module-global `var` is **not** cross-module accessible: `use m exposing g`
  emits `const g = m.g;` but the symbol is `m._zbr_mv_g` → `has no member named 'g'`.
  The shim works around this by declaring singletons in the *consuming* module and
  importing only the service *types* (types are cross-module fine).
- A module-global `var` may not share a name with an in-scope type
  (`var Players: Players` → resolver `'Players' is already defined`); use a distinct
  type name (`var Players: PlayersSvc`).

---

## BUG-148: method chained on a HashMap `.fetch(k)` result miscompiled ✅ FIXED

**Severity:** medium. Found 2026-06-29 building GameEngine's `MessagingBroker`
(`zbra/services_stub.zbr`): `topics.fetch(topic).len` failed to compile.

**Cause:** `.fetch(k)` emitted `(map.get(k) orelse undefined)`. The `orelse
undefined` leaves an `@TypeOf(undefined)` peer in the null branch — fine when
assigned to a typed local, but when a member is chained on the result
(`m.fetch(k).at(0)`), Zig can't peer-resolve `*const T` vs `@TypeOf(undefined)`:
`error: incompatible types: '*const …' and '*const @TypeOf(undefined)'`.

**Fix:** emit `(map.get(k).?)` — a clean unwrap to the value type (and a *defined*
panic on a missing key, vs the previous UB). One site in `src/CodeGen.zig`, two in
`selfhost/CodeGen.zbr` (24- and 12-space indented — the 12-space one was easy to
miss).

`.?` made `fetch`-on-an-absent-key a hard panic, which on the first attempt broke
the round-trip (`panic: attempt to use null value`) by exposing an **unguarded
`scope.fetch` in the selfhost TypeChecker's `localType`**. Fixed by guarding it
(returns `unknown_` for an untracked name — the TC convention), and defensively
guarded one more cross-map fetch in `Checker.zbr`. So the contract is now explicit:
**`fetch` asserts presence; guard with `.contains(k)` where a key may be absent.**

Regression test `test/hashmap_fetch_chain_test.zbr`; gates: round-trip
byte-identical, smoke 182/182, compile-check 147/0.

**Residual → BUG-149.** Chained *method* calls (`.fetch(k).at(i)`) now work; the
`.len` *property* on a fetch result still needs a local.

## BUG-149: `.len` property on a HashMap `.fetch(k)` result (local-inited map) not lowered

**Severity:** low (workaround: bind to a local — but see the field/local quirk).
Found 2026-06-29 alongside BUG-148.

**Symptom:** `m.fetch(k).len` (or even `var q = m.fetch(k)`; `q.len`) where `m` is
a **local-inited** `HashMap(K, List(T))` emits `.len` literally rather than
`.items.len` → `error: no field named 'len' in struct 'array_list…'`. The
`.len`-property lowering (#219) doesn't infer that `fetch` returns the map's
List value type from a local-inited HashMap. **It works when the HashMap is a
class field** (`this.field.fetch(k)` resolves the value type via the field
decl), so `zbra/services_stub.zbr`'s `pending()` compiles. Method calls
(`.at`/`.add`) are unaffected.

**Fix direction:** teach the `.len`-property path (and `getExprDeclaredType`) to
derive a `.fetch(k)` result's element/value type from a local-inited HashMap, the
same way it already does for class fields — same family as BUG-147 (call-result
type inference). Deferred (touches broadly-consulted inference; round-trip risk).

---

## BUG-144: a forwarded List/HashMap param emitted `*const` and failed to compile ✅ FIXED

**Severity:** medium (a common cursor/accumulator pattern did not compile).
Found 2026-06-28 dogfooding `examples/lisp.zbr` (its parser threads a one-element
`pos` cursor `List(int)` through `parseForm`/`parseList` → `advance(pos)`).

**Symptom:** a `List(T)`/`HashMap` parameter that is **forwarded by bare ident**
to a mutating callee — but not mutated directly in the body — was emitted by
value (`*const std.ArrayList`), so the `&` at the forwarding site failed with
`error: expected type '*T', found '*const T'`.

Minimal repro:
```
def bump(xs: List(int))
    xs.add(99)
def forward(xs: List(int))   # never mutates xs directly — only forwards it
    bump(xs)
```

**Root cause:** `paramNeedsAddrOf` only checked *direct* mutation (a mutating
method called on the param in this body); it ignored forwarding to a callee that
mutates its matching positional param.

**Fix:** split the predicate into a direct-only core (`paramDirectlyNeedsAddrOf`)
plus a transitive wrapper (`paramNeedsAddrOf` / selfhost `paramNeedsAddrOfTx`)
that reuses the existing forwarding-detector `addAddrOfMutationsInStmts` — the
same one the local var/const decision uses. That detector checks callees with the
direct-only predicate, so there is no recursion. Coverage is **one forwarding
hop** (the common cursor case); deeper pure-forwarding chains (A→B→C where only C
mutates) are not yet flagged. Mirrored in `src/CodeGen.zig` + `selfhost/CodeGen.zbr`;
round-trip byte-identical, smoke 178/178, compile-check 143/0. Regression test:
`test/transitive_list_param_test.zbr`.

---

## BUG-145: `for x in <throws-call>?` (for-in directly over a throws call) ✅ FIXED (selfhost)

**Severity:** low. Found 2026-06-28 in `examples/lisp.zbr` (`for a in listToVec(p)?`).

**Symptom:** iterating directly over a `?`-propagated throws-returning `List(T)`
emitted Zig that does field access on the error union before the `try` unwrap:
`error: error union type 'anyerror!array_list.Aligned(...)' does not support
field access` — because in Zig `.items` binds tighter than `try`, so
`try f().items` reads `.items` off the error union.

**Fix:** `genForInList` (and the selfhost str-list / plain-list for-in arms)
parenthesize the iterable when it is a `try`-expr: `(try f()).items`. Mirrored in
`src/CodeGen.zig` + `selfhost/CodeGen.zbr`. The Lisp now uses `for x in f()?`
directly at all four sites. Regression test: `test/forin_throws_test.zbr`.

**Bootstrap residual — ✅ RESOLVED 2026-06-29.** The `--zig-backend` bootstrap
previously couldn't reach `genForInList` for `for x in userFn()?` — its
`getExprDeclaredType` had no `.call`/`.try_` arm, so the iterable's type wasn't
resolved to `List` and the loop fell through to a native Zig for-loop
("type ... is not indexable and not a range"). Fixed by adding a `.try_`
passthrough and a `.call`→declared-return-type arm (ident callees → fn/method
return type) to `src/CodeGen.zig`'s `getExprDeclaredType`. `--zig-backend run`
of a `for a in makeNums()?` repro now compiles + runs. The change is additive
(returns the actual return type where it previously returned null) and produced
**zero** change to the regenerated `selfhost/*.zig` (the compiler's own source
has no such pattern), so it's contained to user-program emit. Gates: bootstrap
emit-check 140/0, round-trip byte-identical, selfhost compile-check 147/0
(unchanged).

---

## BUG-146: `str.toFloat()` / `str.toInt()` return 0 on parse failure ✅ FIXED (added tryFloat/tryInt)

**Severity:** medium (silent wrong-data footgun for any tokenizer/validator).
Found 2026-06-28 in `examples/lisp.zbr` — `parseAtom` relied on a failing
`toFloat()` to fall through to "symbol", but every symbol (`+`, `car`, `<=`)
parsed as the number `0`.

**Cause:** `toFloat`/`toInt` are emitted with a `catch 0.0` / `catch 0` fallback
and typed as plain `float`/`int` — a non-numeric string yields `0` indistinguishable
from the literal `"0"`, with no failure channel.

**Fix (non-breaking, additive):** added `str.tryFloat(): float?` and
`str.tryInt(): int?`, emitted as `(std.fmt.parse… catch null)` (an optional
`?f64`/`?i64`) and typed as optional in both type checkers. The existing
0-fallback `toFloat`/`toInt` are unchanged. `examples/lisp.zbr` now classifies
tokens with `tok.tryFloat()` (the `looksNumeric` workaround is removed).
QUICKSTART updated (and the stale "toInt panics on bad input" note corrected to
"0 on bad input"). Mirrored in `src/{CodeGen,TypeChecker}.zig` +
`selfhost/{CodeGen,TypeChecker}.zbr`. Regression test: `test/try_parse_test.zbr`.

---

## BUG-147: bootstrap (`src/`) miscompiles `examples/lisp.zbr` (3 emit divergences) — BUG-143 family

**Severity:** medium (equivalence violation; selfhost is correct, bootstrap lags).
Found 2026-06-28 — `zebra --zig-backend run examples/lisp.zbr` fails to compile
while the default selfhost compiler runs it correctly end-to-end.

**Symptoms (src/ emit only):**
- `incompatible types: '*lisp.Value' and '@EnumLiteral()'` (a `^Value` field /
  union-literal site in `makeLambda`).
- `expected type 'lisp.Value', found '*lisp.Value'` passing a `^Value` to a
  by-value `showValue(v: Value)`.
- `no field or member function named 'toInt' in 'f64'` — `float.toInt()` not
  lowered the way the selfhost lowers it.

**Status:** OPEN. Same "bootstrap lags selfhost" class as BUG-143; the lisp is a
good multi-pattern repro for a future src/→selfhost convergence pass.

---

## BUG-143: bootstrap (`src/`) codegen lags the selfhost — 14 user-program emit divergences

**Severity:** medium (equivalence violation; the bootstrap is no longer the
primary compiler, but is still reachable via `zebra --zig-backend` and is the
authority that regenerates `selfhost/*.zig`). Found 2026-06-27 by a bootstrap-emit
parity sweep run after compile-check reached 141/0 on the selfhost.

**Status:** IN PROGRESS (task #231) — **12 of 14 closed, parity 120→132 / 14→2**.
Round-trip byte-identical after every fix; selfhost steady at 141/0. The bootstrap is
the **non-primary** compiler, so this is equivalence-restoration, not active-feature work.

**Closed (12):** realpath (sys.cwd/Path.absolute → 0.16 API); Dir.walk `.next(_io)`;
the **ArrayList `.items` cluster** (list_index, for_else, module_var_shadow,
list_ref_autobox, bug119) via a positive-only `objIsList(expr)` helper (list_lit |
`List()` ctor | declared/inferred `List(T)`) wired into the `.index` arm + genForIn, plus
`getExprDeclaredType` generalised to `localVar.field` (module-decls field lookup) and a
list-lit-init `.empty` fix; the **HashMap cluster** (remove, set, field_collision,
param_field) via a `HashMap(K,V)()` ctor → `genStdlibInit` intercept, an `objIsHashMap`
helper lowering `m[k]`→`m.get(k).?`, and inferred-HashMap-var type derivation; and
**tc_iface_transitive** (concrete→interface var-init fat-pointer coercion).

Key design point: all list/hashmap detection is **positive-only** (matches only
definitely-List/HashMap exprs), so strings never match and the compiler's own `spec[i]`
string subscripts / `.at()` list access are untouched → the round-trip stays byte-identical.

### Remaining 2 — kitchen-sink tests, each with further stacked layers
- **dir_walk_test** (parity not yet flipped): walker.next + for-over-Dir.walk-list are
  fixed, but the loop var `f` (element of `List(str)`) isn't typed `str`, so
  `f.endsWith(".zbr")` emits a literal `.endsWith` instead of `std.mem.endsWith`. Needs a
  **TypeChecker** change: infer the for-loop element type for a `Dir.walk`-initialised
  list var (the bootstrap relies on TC element inference for str-method dispatch). Likely
  more layers after (`files.count()`).
- **ws_smoke_test** (parity not yet flipped): the spurious closure capture is **fixed**
  (capture free-var analysis now excludes `if as` bindings — collectFreeVarsStmt +
  checkCaptureBoundaryStmt). Next layer: `ws.recv()` inside the closure doesn't dispatch
  as a `WsConn` method (`_WsConn` has no `recv`; needs `_ws_recv(ws)` — the closure body
  loses the param's `WsConn` type for stdlib-method dispatch).

### What it is
`tools/compile_check.sh` type-checks the Zig the **selfhost** emits (141/0/1 green).
Running the same check against the **bootstrap** emit (`--bootstrap`) yields
**120 passed / 14 FAILED / 8 skipped**: 14 positive-smoke tests where the bootstrap
emits Zig that does **not** type-check, while the selfhost emits correct Zig for the
same source. The selfhost is *ahead* of the bootstrap — this session's (and earlier)
stdlib/0.16 codegen fixes were applied to `selfhost/CodeGen.zbr` and never mirrored
to `src/CodeGen.zig`. It stayed invisible because no gate exercised the bootstrap's
**user-program** emit (`bootstrap_check.sh` only exercises the bootstrap emitting the
*compiler*, which happens not to hit these paths in a breaking way; the
compiler sources use e.g. `sys.cwd` only once and not the broken `.items`/HashMap
shapes).

**Proof of direction (sys.cwd):**
- `src/CodeGen.zig:6969,7314` → `std.Io.Dir.cwd().realpathAlloc(_io, …)` — the
  **0.16-removed** API (`error: no field … 'realpathAlloc' in 'Io.Dir'`).
- `selfhost/CodeGen.zbr:11620` → `std.process.currentPathAlloc(_io, _allocator)` — fixed.

### The 14, by root-cause cluster
- **ArrayList `.items` indexing (5):** `for_else_test`, `list_index_test`,
  `module_var_shadow_test`, `list_ref_autobox_test`, `bug119_list_field_param_test`.
  Bootstrap emits `xs[i]` / `xs` where the selfhost emits `xs.items[@as(usize, …)]`
  (`error: array_list … is not indexable` / `missing struct field: items`).
- **HashMap emission (4):** `hashmap_remove_test`, `hashmap_set_test`,
  `hashmap_field_collision_test`, `hashmap_param_field_test`. Bootstrap emits a
  bogus `HashMap(K,V).init()` (undeclared identifier; no allocator) where the
  selfhost emits `std.StringHashMap(V).init(_allocator)` + `_intern`/`catch`.
- **0.16 stdlib API (2):** `stdlib_additions_test`, `stdlib_misc_test` — `realpathAlloc`
  (above); likely other 0.16 renames in the same region.
- **Concrete→interface coercion (1):** `tc_iface_transitive_match_test` — known gap
  (see COMPILE_CHECK_STATUS.md): `var b: IBase = d` for concrete `d` is selfhost-only.
- **Individual (2):** `dir_walk_test` (`member function expected 1 argument(s), found 0`);
  `ws_smoke_test` (`use of undeclared identifier 'm'`).

### Repeatable gate (landed)
`compile_check.sh --bootstrap` was **non-functional** before this (it passed
`--output-dir` to the bootstrap, whose CLI emits to stdout and rejects the flag, so
every emit silently `continue`d → `0 passed, 0 FAILED`). Fixed 2026-06-27: bootstrap
mode now emits each root file to stdout, and skips multi-file dep tests (the bootstrap
stdout path can't materialize separate-module deps — those pass under the selfhost
whose `--output-dir` emits the deps too). The gate now reports the real 120/14/8.

### Fix plan (scoped — for a gated session)
Mirror each cluster's fix from `selfhost/CodeGen.zbr` into `src/CodeGen.zig`, one
cluster at a time, re-running `bootstrap_check.sh` (round-trip must stay byte-identical)
+ `compile_check.sh --bootstrap` after each. Start with the lowest round-trip risk
(realpath: the compiler uses `sys.cwd` once; ArrayList/HashMap shapes need checking
against compiler-internal usage first). Target: `--bootstrap` reaches the same
141/0 as the selfhost, restoring full equivalence. Then wire `--bootstrap` into the
parity gate so this can't silently regress again.

## BUG-142: missing required argument compiles + runs with garbage ✅ CLOSED 2026-07-31

**CLOSED 2026-07-31 — both directions are now hard ERRORS.** Sean's decision, taken
after the measurement below finally produced a trustworthy number.

**The measurement that unblocked it, and why it took three attempts.** The promotion was
gated on not regressing the Luau corpus, and the recorded baseline (1482) turned out to
be five weeks stale — see BUG-235. Two earlier scans returned "0 too-few", which looked
like good news and was actually a broken instrument: this entry documents ~28 too-few
sites, so **zero was the tell**. After the corpus was regenerated, a third scan with a
built-in control produced:

```
files scanned:   1581      (regenerated corpus, deduped)
files EMITTING:  1446
TOO FEW:         28 lines / 19 distinct files   <-- control PASSES, matches the ~28 on record
TOO MANY:         1 line  /  1 distinct file
```

The control passing is what made the rest believable. An instrument that cannot find a
thing you know is there has not told you the thing is absent.

**The two directions were never one decision, and the numbers prove it.** Luau lets you
omit trailing arguments (they become nil), so the translator emitted too-few calls
pervasively — 19 files. **Nothing in Luau needs EXTRA arguments**, and the whole corpus
held exactly ONE too-many site. Splitting the promotion by direction turned a 19-file
decision into a 1-file one for half the value; that split is what Sean approved.

**Both landed together anyway**, because the corpus is explicitly not frozen (Sean:
*"The corpus is not intended to be locked in yet"*) and because the too-few calls are
genuinely unsafe rather than merely untidy: codegen pads the missing argument with
`std.mem.zeroes`, so the callee reads a silent zero. The old warning left a program that
compiled, ran, and gave a wrong answer — which is the exact failure mode this tracker
exists for.

**Known cost, stated rather than discovered:** 19 of the 1,446 compiling corpus files
(1.3%) now fail. Each has a real bug. The proper fix is the translator emitting `= nil`
defaults for under-supplied trailing params — step 2 below, which already has a
prototype — not the compiler tolerating them. The 19 are listed in the session log.

**Fixtures moved in the same commit**, because a fixture asserting the old severity
fails the instant the promotion lands: `test/arg_count_test.zbr` `smoke_warn` →
`smoke_tc_fail`, and three boundary probes `warns` → `rejects`. Two of those had been
carrying `@boundary-pending BUG-142` since 2026-07-30 and had been authored asserting
this very rejection — they went red, and were rewritten back to the assertion they
started with. Pending count 3 → 1.

**Severity:** high (correctness/safety — silent wrong behavior).
**Status:** PARTIAL ✅ 2026-06-23 — (a) emits a non-fatal **warning**
(`too few arguments to 'X': expected N, found M`); (b) the **undefined-behavior is
gone**: codegen now pads an omitted no-default argument with `std.mem.zeroes(T)`
(a deterministic zero) instead of `undefined`, so a too-few-args call can no
longer read uninitialized memory. What remains for a full close: promoting the
warning to a hard **error** (gated on the translator follow-up below, so valid
Luau-nil-default calls aren't broken). Found 2026-06-22 via the error-experience
audit (`docs/error_experience_audit.md`).

### What shipped (warning)
A `checkArgCount` + `checkArgCountsInExpr` walker in `selfhost/TypeChecker.zbr`
runs in `checkStmts` over every statement's expressions (var-init, return,
assign, expr-stmt, `print`, and if/while/for/guard conditions). It compares the
provided arg count against the callee's declared params (via new
`fnParamList`/`fnParamListAny` accessors over the already-stored `fn_param_lists`),
counting **required = params without a default**. Conservative: only fires when
the callee's full Param list is known (resolved user free fn / method); builtins,
stdlib, closures-in-locals, and unresolved receivers are skipped. Reaches nested
calls like `print(add(1))`. Regression tests: `test/arg_count_test.zbr` (warns),
`test/arg_count_ok_test.zbr` (defaults + correct arity compile clean).
Round-trip byte-identical; smoke green.

### Why warning, not error (the corpus finding)
Making it a hard error regressed the translator corpus by 28 (1482→1454). The
failures were almost all **off-by-exactly-one** (`expected 4, found 3`) on
translated Luau functions (`playAnimation`, `Scale`, `CreateSubClass`, …): **Luau
permits calling with fewer args** (missing become `nil`), so the translator
pervasively emits too-few-arg calls relying on nil-defaulting. In Zebra those
calls are genuinely unsafe (they hit the `undefined`-padding), but flagging 28
pervasive translator outputs as errors is too aggressive. As a warning, the
corpus is unaffected (warnings are non-fatal → 0 arg-count failures, baseline
restored) while the issue is surfaced.

### DECISION (Sean, 2026-07-30): promote to a hard ERROR — both directions

Asked directly during the A3 boundary work, which had pinned the warning behaviour
and flagged the promotion as the one open question it refused to legislate. Sean's
answer: *"I think too few / too many should be an error and not a warning."*

**This unblocks the follow-up below, but does not make it free — the blocker is
cross-repo and still real.** The cost, restated against today's tree:

* The constraint is `GameEngine/tools/luau2zebra_ast.py` and its translated corpus,
  both of which still exist (translator last touched 2026-07-01). Luau permits
  calling with fewer arguments (missing become `nil`), so the translator pervasively
  emits too-few-arg calls. Promotion alone regressed that corpus 1482 → 1454.
* The severity split proposed below (error same-module, warn cross-module) does
  **not** dodge this: BUG-142's own investigation confirmed **all ~28 cases are
  same-module**, so the split still regresses by the full 28.

**MEASUREMENT ATTEMPT 2026-07-30 — INCONCLUSIVE, AND THE WAY IT FAILED IS THE
USEFUL PART. Do not treat its numbers as evidence.**

I scanned all 1,780 files in `GameEngine/ported_scripts` with the warning-era
compiler using `-c` (front-end-only, so arity is visible without invoking Zig —
~1.2 s/file). Raw result:

```
files scanned:            1780
TOO FEW  warning lines:   0
TOO MANY warning lines:   0
files that did NOT check cleanly (arity NOT measurable): 931   <-- 52%
```

**Zero too-few is the tell that the instrument was wrong, not that the corpus is
clean.** This very bug documents ~28 known too-few sites, and the translator fix
that would have removed them never landed — verified: `_collect_call_arity` and
`optional_from` do not exist in `tools/luau2zebra_ast.py`, so the prototype is
still reverted. Finding 0 where 28 are known to exist means the measurement
under-counted; had I only looked at the too-many row I would have read a broken
instrument as a green light.

**Why it under-counted:** 52% of the corpus never reaches the TypeChecker. The
scripts `use workspace / math / players / instance / ...`, which live in
`GameEngine/zbra/`, and module resolution searches the input file's directory then
Zebra's own `selfhost/`, `test/` and stdlib paths — never `zbra/`. So they fail at
resolution with `cannot find module` or `undefined name: 'RunService'`, and a
front end that stops there cannot report an arity diagnostic. `measure_corpus_
compile.py` has a dedicated `missing module import` bucket for exactly this.

**The tempting argument, and why it is not sufficient:** *a file that already fails
cannot be regressed by adding a new error, so the at-risk population is only the
~849 that check cleanly, where too-many is 0.* That is probably right, but it does
not reconcile with this bug's own figure of **1482** compiling files — 849 and 1482
cannot both describe the same success set, so at least one of the two instruments is
measuring something other than what it is being read as. Landing a promotion on an
argument with an unexplained factor-of-two in it would be exactly the mistake this
entry already warns about.

**The measurement that WOULD settle it** is an A/B with the project's own harness,
which is the instrument that produced 1482 in the first place: run
`GameEngine/tools/measure_corpus_compile.py` before the change, rebuild with the
promotion, run it again, diff the buckets. Same tool, same corpus, same cwd — so the
number is comparable to the one on record instead of a new number of my own.

**The compiler change itself is written and lint-clean** (`ctx.addWarn` →
`ctx.addErr` on the too-many arm of `checkArgCount`, selfhost only — the bootstrap
never had this check). It is deliberately NOT landed pending that A/B.

**Recommended landing order, given the decision is now made:**

1. **`too many` first, on its own.** The Luau rationale is entirely about too FEW
   (nil-defaulting). Nothing about the translator requires passing *extra*
   arguments, so this half should be promotable at zero corpus risk — **measure
   before assuming**, but it is the obvious clean split and delivers half the
   decision immediately.
2. **`too few` with the translator change**, per steps 1+2 below. That prototype
   already exists and took the corpus 1454 → 1458; two known gaps remain (the
   capture-extraction path reusing the param string as call arguments, and method
   `Invoke` forms the walk skips).

**Fixture consequences when this lands** (they are tripwires, not regressions):
`test/arg_count_test.zbr` moves `smoke_warn` → `smoke_tc_fail`, and the two A3
probes `test/boundary/bv_arity_too_few.zbr` / `bv_arity_too_many.zbr` flip from
`# @boundary warns` to `# @boundary rejects` and drop their
`@boundary-pending BUG-142` line. They are *designed* to fail at that moment.

### Follow-up to fully close (promote warning → error) — de-risked 2026-06-23

Investigated in depth (prototyped both sides, then reverted to the clean warning
state). Key findings for whoever finishes it:

- **All ~28 corpus too-few-args cases are SAME-MODULE** (the function is defined
  *and* called with fewer args in the same script). So the translator analysis is
  **per-script**, not cross-module — much more tractable. (Confirmed: a
  current-module-error vs dep-warn split in `checkArgCount` left the count at 28,
  proving none are cross-module.)
- **Lambda param defaults parse fine** (`var f = def(a, b = nil) = …` works), so
  that is not a blocker.

Remaining work, in order:
1. **Compiler — severity split** (ready, gate-clean in prototype): in
   `checkArgCount`, error when the callee is in `ctx.module_types` (same module —
   the signature is right there, almost certainly a real bug), warn when it
   resolves only via `dep_types`. On its own this regresses the corpus by the full
   28 (all same-module), so it must land *with* the translator change below.
2. **Translator** (`GameEngine/tools/luau2zebra_ast.py`): a per-script pre-pass
   (`_collect_call_arity`, walk the luaparser AST — **use a visited-id set**, nodes
   carry cyclic parent refs) records each bare-name callee's min observed arg
   count; `_emit_params(args, optional_from)` then emits the under-supplied trailing
   params with `= nil`. Prototype took the corpus 1454→1458 (fixed ~15 of 28) but
   surfaced two gaps to finish: (a) the **capture-extraction path** in
   `_emit_func_as_assignment` reuses the `params` string as *call arguments* to the
   hoisted `_lambda_N`, where `= nil` is invalid — separate the param **decl**
   string (with defaults) from the param **names** string (for the call); (b) the
   remaining ~13 are **method** calls (luaparser `Invoke`) and other non-bare-name
   forms the walk skips — extend the walk + match method defs (offset by the
   prepended `self`).
3. **Codegen** (already done): a missing no-default arg is padded with
   `std.mem.zeroes` not `undefined`, so the UB is gone regardless.
4. Land 1+2 together, confirm corpus stays ~1482, then gate + smoke; update the
   `arg_count_test` smoke fixture from `smoke_warn` → `smoke_tc_fail` (same-file).
~~Also: arg-count diagnostics currently report `0:0` in `print`/expr-stmt
positions because expression spans are `zspan()` placeholders.~~ ✅ RESOLVED
2026-06-23 — identifier and member expressions now carry real spans (the parser
captured them; the AST builder was discarding them), so the arg-count /
forgot-parens / arg-type diagnostics render precise carets. Only literal
arguments still fall back to the callee position.

### Original report (for context)

**What happens:** calling a function with fewer arguments than it has parameters
is not caught. Codegen pads the missing positional arg with `undefined`:
```
def add(a: int, b: int): int
    return a + b
def main()
    print(add(1).toString())   # → emits `add(1, undefined)` → prints garbage
```
`add(1)` runs and prints an uninitialized value (e.g. `140701535361921`) instead
of reporting "expected 2 arguments, found 1". A Zig compile would normally reject
the arity, but the `undefined` padding makes it type-check and execute.

**Root cause(s):**
1. Codegen pads omitted positional args with `undefined` (the same mechanism that
   should fill **defaults** — see BUG-139). For a param **without** a default,
   `undefined` is never correct.
2. The TypeChecker does not validate argument **count**. `checkCallExpr` checks
   arg *types* but (a) doesn't count args vs params, and (b) only runs on
   `Stmt.var_` init exprs, so a nested call like `print(add(1)…)` is never
   checked.
3. `ModuleTypes` stores `method_params` as a CSV of param **types** only — it does
   **not** record which params have defaults, so "required arg count" can't be
   computed yet.

**Fix approach (pairs with BUG-139):**
- Thread per-param default info into `ModuleTypes` (mirror of the bootstrap's
  BUG-182 Param-list-with-defaults storage), so `required = params without a
  default`.
- Add an arg-count check at the `Expr.call` arm of `inferExpr` (the universal
  expression walker — fires in every position, fixing reach issue 2b) with a
  caret diagnostic: too few args (< required) and too many (> total, modulo
  varargs/builtins).
- Be conservative to avoid corpus false-positives: only fire when the callee's
  full param list is known (resolved free fn / method in module or dep types);
  skip builtins/stdlib and unknown callees. **Verify against the full translator
  corpus** (`tools/corpus_probe.py`) before committing — a false "too few args"
  would break valid programs.

**Workaround today:** none at the language level; pass all arguments explicitly.

---

## Name-based container-dispatch audit (2026-06-22) — COMPLETE

After fixing the field-name-collision class of bug (BUG-138 List `.len`/`.count`,
BUG-140 HashMap index/`.count`/`.remove`/`.set`, BUG-141 List `[i]` read), the
remaining name-based container dispatches were swept for the same vulnerability.
Findings:
- **List index-write** (`list[i] = v`): already correct — emits `list.items[i] = v`.
- **StrSet `.count()` collision** (`fieldIsStrSet` is global name-based, and
  `enum_names`/`union_names` are StrSet in CodeGen but HashMap in TypeChecker):
  **benign** — the count emit is identical (`@as(i64, @intCast(obj.count()))`)
  whether classified as StrSet or HashMap, and both Zig types have `.count()`.
  Not "benign by luck": there is no observable difference, so no fix is warranted
  (a class-scoped `fieldIsStrSet` would be pure churn).
- **StrSet at the HashMap dispatch sites** (`.remove()`/`.set()`/index): already
  protected by BUG-140's class-scoping — `fieldAwareIsHashMap` returns false for
  a StrSet field (it isn't a `HashMap` generic), so StrSet ops don't mis-route.

Conclusion: the class is closed. The only name-based predicate left
(`fieldIsStrSet`) is provably harmless. New same-named container-field collisions
are now structurally safe at every read/count/remove/set/index site.

---

## BUG-141: indexing a List with `[i]` miscompiles (needs `.items[i]`) ✅ FIXED

**Severity:** medium (reachable, cryptic failure; non-idiomatic syntax so likely
rare in practice — `.at(i)` is the documented accessor).
**Status:** ✅ FIXED 2026-06-22 (selfhost-only). Index-read of a List receiver
(local or current-class/module-type field) now emits `obj.items[i]` instead of
`obj[i]`.

**Why selfhost-only:** the index-read dispatch already differs between the two
compilers and the selfhost is the richer (correct) one — the bootstrap's
`.index =>` arm does NO container dispatch (it emits `self.bag[k]` even for a
HashMap field, which is also invalid Zig), while the selfhost already turns a
HashMap `bag[k]` into `.get(k).?`. Adding List handling extends the selfhost's
existing dispatch and matches the dual-version policy (user-facing-only feature ⇒
selfhost-only; the bootstrap is the trusted regenerator and the selfhost source
indexes Lists via `.at()`, so the round-trip is unaffected). Bringing the
bootstrap index path up to full parity is a separate, larger cleanup if ever
needed.

**Fix** (`selfhost/CodeGen.zbr`, the `Expr.index` read arm): added
`fieldAwareIsList` (parallel to `fieldAwareIsHashMap`) and emit `.items` before
the `[` when the receiver is a List and not a HashMap. Regression test
`test/list_index_test.zbr` (local + field List index, runs end-to-end). Strings
/slices unaffected (still plain `[i]`). The index-**write** path (`obj[i] = v`)
and `.at(i)` were already correct.

### Original report (for context)
**Discovered** 2026-06-22 while building the BUG-140 repro.

**What happens:** indexing a `List` receiver with the `[i]` postfix operator
emits raw `obj[i]` instead of `obj.items[i]`. A `std.ArrayList` does not support
direct indexing, so the generated Zig fails to build:
```
error: type 'array_list.Aligned(i64,null)' does not support indexing
```
Reproduction (both a local and a field List trigger it; strings are fine):
```
def main()
    var nums = List(int)()
    nums.add(10)
    print(nums[1].toString())   # emits nums[@intCast(1)] — invalid; needs nums.items[...]
    var s = "hello"
    print(s[1].toString())      # OK — string is []const u8, slice indexing works
```
`nums[1]` is a natural thing to write, and the grammar lists `[i]` as a valid
postfix (QUICKSTART §ops table) even though `.at(i)` is the documented, working
List accessor (QUICKSTART line ~643). So the operator silently miscompiles rather
than working or giving a clean Zebra error.

**Scope:** the index-**read** path. Receivers that are a List *local* or a List
*field* both miscompile; string/slice/array indexing is correct as-is. The
write/assign path (`obj[i] = v`) and `.at(i)` are unaffected.

**Present in BOTH compilers** (so a fix must touch both, for functional
equivalence):
- bootstrap `src/CodeGen.zig` — the `.index =>` arm (~line 12137) emits
  `genExpr(object)` + `[ … ]` with no List special-case. NOTE: the `Type` union
  (`src/TypeChecker.zig:44`) has **no dedicated `.list` variant** — Lists are
  recognised at the `TypeRef` level (`tr.generic.name == "List"`), not as an
  inferred `Type`, so `tc.expr_types.get(e.object)` won't simply return "list".
  Detecting a List receiver here needs the declared TypeRef / resolve symbol of
  the object (field decl type, or the local's declared `List(T)`), not the
  inferred `Type`. There are also two index-emit paths (~8665 with
  `[@as(usize, @intCast(`, ~12137 with `[@intCast(`) — confirm which one(s)
  handle field/local List index reads before editing.
- selfhost `selfhost/CodeGen.zbr` — the `Expr.index` arm (~line 6824). Add a
  `fieldAwareIsList` (parallel to the new `fieldAwareIsHashMap`): local List
  wins, else class-scoped `isListField`, else `isKnownListField`/`fieldIsList`.
  Emit `.items` before the `[` when the receiver is a List.

**Equivalence note / verification plan:** while building the BUG-140 repro I also
noticed a *latent* cast-style divergence at this site — post-BUG-140 selfhost
emits `[@as(usize, @intCast(0))]` while bootstrap emits `[@intCast(0)]` for the
same `bag[0]`. It never manifests in the round-trip because the selfhost source
indexes Lists via `.at()`, not `[i]`. Any fix here should reconcile that too, and
must be verified by: implement both sides → `bootstrap_check.sh --update`
(bootstrap regen) → plain `bootstrap_check.sh` (selfhost regen) → confirm
`selfhost/*.zig` is unchanged between the two (proves bootstrap emit == selfhost
emit on the actual source). Plus a runnable regression fixture (`nums[1]` on a
local + a field List).

**Workaround today:** use `list.at(i)` (bounds-checked, emits `.items[i]`).

---

## BUG-140: selfhost HashMap dispatch was field-name-based, not class-qualified ✅ FIXED

**Severity:** medium (selfhost-codegen gap; the bootstrap was already correct).
**Status:** ✅ FIXED 2026-06-22. The sibling of BUG-138, for HashMaps: the
selfhost's HashMap member dispatch (indexing `obj[k]`, `.count()`, `.remove()`,
`.set()`, and index-assignment) decided "is field `X` a HashMap?" by **field
name across all classes** (`fieldIsHashMap`), so when two classes had a
same-named field of different container-ness, the dispatch mis-fired.

**Reproduction** (a `List(int)` field colliding with a same-named `HashMap`
field of another class, indexed):
```
class MapHolder
    var bag: HashMap(str, int)
class ListHolder
    var bag: List(int)
    def at0(): int
        return bag[0]
```
- **Selfhost** emitted `return self.bag.get(0).?;` — treating the `List` as a
  HashMap because `fieldIsHashMap("bag")` was globally true (from `MapHolder`).
- **Bootstrap** emitted `return self.bag[@intCast(0)];` — correct (class-scoped).

The selfhost emit is invalid Zig (`List` has no `.get`), so it was build-caught,
but it silently blocked any future selfhost code with a same-named List/HashMap
field pair. The selfhost source already has three such collisions one edge away
from biting: `enum_names` (StrSet vs HashMap), `union_names` (StrSet vs HashMap),
`module_fns` (HashMap vs a class type).

**Fix** (`selfhost/CodeGen.zbr`): added a class-scoped `isHashMapField`
(parallel to `isListField`, via `lookupFieldType` over the current class's
members) and a `fieldAwareIsHashMap` helper — a local var shadows any same-named
field (its type wins), then a field of the **current** class is authoritative
(do NOT fall through to the global name-based `fieldIsHashMap`). Replaced all
five `localIsHashMap(X) or fieldIsHashMap(…)` dispatch sites with
`fieldAwareIsHashMap(X)`. Selfhost-only (the bootstrap's symbol-table resolution
was already right). Round-trip byte-identical; smoke green; regression test
`test/hashmap_field_collision_test.zbr`.

---

## BUG-139: selfhost doesn't fill default `cue init` params at omitting call sites

**Severity:** low (easy workaround: pass the arg explicitly).
**Status:** OPEN, discovered 2026-06-22 while threading `source` into the Resolver
for the undefined-name caret.

**What happened:** a `cue init` with a trailing default param —
`cue init(file_name: str, source: str = "")` — does **not** get the default
filled in at call sites that omit it. `Resolver.Resolver(path)` emitted a 1-arg
Zig `init(path)` against a 2-param `init`, failing:

```
expected 2 argument(s), found 1
```

Every Resolver construction now passes the arg explicitly (`Resolver.Resolver(path, "")`
at the error-ignoring site, `…(path, src)` elsewhere), which is why the caret
shipped. The Parser's identical `source: str = ""` default never tripped this
only because every Parser construction already passed all args.

**Scope / open questions:**
- Default-fill clearly works *somewhere* (default params have been used before) —
  characterize precisely when it does/doesn't. Suspect it's **constructor**
  (`Type.Type(...)` cue-init) call sites specifically, vs. ordinary method calls.
- Bootstrap parity unknown: the bootstrap (Zig `src/`) likely fills defaults
  correctly (this surfaced only on the selfhost round-trip path). Confirm whether
  this is a genuine bootstrap-vs-selfhost divergence or a shared gap.

**Where to look:** selfhost call-emission for cue-init / constructor calls — the
arg-count/default-fill logic in `selfhost/CodeGen.zbr` (genCall / ctor path).
Compare against how the bootstrap fills missing trailing defaults.

**Payoff when fixed:** removes a latent foot-gun (silent "expected N args, found
M" on any defaulted cue init) and lets selfhost compiler code rely on init
defaults the way user programs can.

---

## BUG-138: selfhost `.len` dispatch was field-name-based, not class-qualified ✅ FIXED

**Severity:** medium (selfhost-codegen gap; the bootstrap was already correct).
**Status:** ✅ FIXED 2026-06-22. Root cause was narrower than first thought (not
`.split`): the selfhost's `.len`/`.count` member dispatch looked up "is this a
List field?" by **field name across all classes**, so when two classes had a
same-named field of different types (`source: str` on `Parser` vs `source:
List(PNode)` on `PInScope`), `self.source.len` on the str field wrongly emitted
`self.source.items.len` (`.items` on a `[]const u8`).

**Fix** (`selfhost/CodeGen.zbr`, the `.len`/`.count` member path): when the
member object is a field of the **current** class (`isFieldName`), trust the
class-scoped `isListField` answer and do NOT fall through to the name-based
`fieldIsList(.module_types, …)`, which false-positives on a same-named List field
of another class. Selfhost-only (the bootstrap's symbol-table resolution was
already right). Round-trip byte-identical; smoke 161/161; regression test
`test/field_name_collision_test.zbr` (`text=5 list=3`).

**Payoff:** unblocked the **caret/source-line** parser diagnostic — the Parser
now carries the source text and renders a `^` under the offending column
(committed alongside the fix), which previously hit this divergence.

### Original report (for context)
Discovered while adding a caret/source-line to parser diagnostics. The diagnostic
*message* improvement shipped first (d9b4ec3); the caret was reverted until the
codegen fix landed.

**What happened:** I added a field to `selfhost/Parser.zbr` to hold the source
text for caret rendering and used it with `split`:
- First as `var source_lines: List(str)` populated via `for ln in source.split("\n"): .source_lines.add(ln)`.
- Then reformulated as `var source: str` with a `sourceLine(li)` helper doing
  `for ln in .source.split("\n")`.

Both compile + run correctly when **zebra-bootstrap.exe** (the Zig compiler)
emits `Parser.zbr` — `zig build`, smoke 159/159 all pass. But the round-trip
gate fails at **selfhost-B build**: the **selfhost** compiler (selfhost-A)
re-emits `Parser.zbr` into Zig that references `.items` on a `[]const u8`:

```
selfhost/Parser.zig:4516:45: error: no member named 'items' in '[]const u8'
```

i.e. the selfhost codegen treats the `str` field (or the `split` result, or the
field's element/whole type) as a `List`/`ArrayList` at a use site while its Zig
type is a string slice — a type-inference inconsistency that only the **selfhost**
codegen has (the bootstrap gets it right), so it's a genuine bootstrap-vs-selfhost
divergence.

**Why it matters:** it means a `str`/`List(str)` field interacting with `.split`
can't currently be added to any of the `selfhost/*.zbr` compiler files (they
must round-trip). User programs are unaffected (they compile via zebra.exe,
which is fine — the bug is in *re-emitting* such code).

**To investigate / fix:**
- Build selfhost-A, have it `--emit-zig selfhost/Parser.zbr` with the reverted
  caret code re-applied, and inspect the emission around the `.items` site to
  see which expression's inferred type is wrong.
- Likely in `selfhost/CodeGen.zbr` / the InferCtx field-type or `split`-result
  handling — the selfhost infers the field (or the loop var, or `.len`) as a
  List where it's a str (or vice-versa).
- The reverted caret code (small) is the reproduction; re-apply from the
  d9b4ec3 parent's working-tree notes or re-derive (a `var source: str` field +
  `for ln in .source.split("\n")` + `.source.len`).

**Payoff when fixed:** unblocks the caret/source-line diagnostic (and any future
selfhost code that wants a split-derived string field) — a clean self-hosting-
duality fix.

---

## BUG-137: module-level `var`/`const` names can collide with file-scope decls

**Severity:** medium (correctness/usability for hand-written module vars).
**Status:** ✅ FIXED 2026-06-21 (commit pending). Module vars now emit with a
reserved `_zbr_mv_` prefix in both compilers; references are prefixed
identically, and a shadowing local/param keeps its bare name. The
translator-side mitigation discussed below is no longer required.

### Resolution

Both compilers emit a module-level `var`/`const` as `pub var`/`pub const
_zbr_mv_<name>` (constant `module_var_prefix` in `src/CodeGen.zig`; literal in
`selfhost/CodeGen.zbr` `genFieldDecl`). A reference that resolves to a module
var is emitted with the same prefix:

- **Bootstrap** (`src/CodeGen.zig` `genIdent`): keyed on the resolved symbol
  (`sym.decl.var_.is_top_level`) — sound per-reference, since a shadowing local
  resolves to its own symbol and keeps its bare name.
- **Selfhost** (`selfhost/CodeGen.zbr` `genIdent`): name-based via
  `isModuleVarName` (`module_types.fieldType("", name)`) guarded by
  `isLocalOrParamName` (`param_names` + `infer_ctx.hasLocal`). `genLocalVar` now
  binds every local (incl. unknown-typed) into `infer_ctx`; `noteShadowLocal`
  registers the other binding forms — for-in loop vars (`genForIn`), numeric
  loop vars (`genForNum`), `if … as` captures (`genIsCaptureThen`), and
  `branch … on V as r` captures (`genBranchTagged`) — so all shadow a same-named
  module var instead of being mis-prefixed.

Known minor limitation (selfhost only; the bootstrap is sound per-reference): a
binding's local-name entry in `infer_ctx` is not scope-popped, so within ONE
method a module-var reference that appears *after* a block/loop binding the same
name would be treated as the local. Pathological (a method using both a module
var and a same-named local in disjoint scopes); not seen in the corpus.

Verified: `test/module_var_collision_test.zbr` (preamble-name collision +
plain-local shadow) and `test/module_var_shadow_test.zbr` (for-in / for-num /
if-capture shadows, module vars untouched). Round-trip byte-identical; smoke
158/158.

### Original report (for context)

Module-level `var`/`const` (shipped 2026-06-21, commit 08802f6) emit as bare
file-scope `pub var`/`pub const NAME`. Zig **forbids any function-local or
parameter from shadowing a file-scope declaration**, so a module var whose name
matches *any* identifier used as a local/param anywhere in the emitted file
fails to compile with `local … shadows declaration of 'NAME'`. Two collision
sources:

1. **Runtime preamble** — uses many short/common local & param names. Observed:
   a module `var total` collides with a datetime helper's `const total`, the
   `_progress_bar(total: i64, …)` parameter, *and* a `var total` local — three
   hits from one name. `g`, `s`, `c`, `i`, `node`, `out`, `count`, `label`,
   `config`, `enabled`, `player` … are all landmines.
2. **User's own locals** — a user function declaring `var count` when a module
   `var count` exists is also rejected (same Zig shadow rule).

**Why not fixed in-compiler now:** the sound fix is to move user module vars out
of bare file scope — emit them inside a container struct
(`const _M = struct { pub var total: i64 = 0; };`) and rewrite references to
`_M.total`. The **bootstrap** (`src/`) can do this soundly because the resolver
binds each ident to its declaration (`DeclVar.is_top_level`), so `genIdent`
knows per-reference whether a `total` is the module var or a shadowing local.
The **selfhost** codegen has **no general local-name set** (only typed-local
sets: `strset_locals`, `chan_locals`, …), so it cannot disambiguate a module-var
reference from a same-named local without new local-name tracking on the hot
`genIdent` path. That makes the guard a medium, two-compiler change with several
round-trip gate cycles — deferred while the parallel Zig-0.17 work is in flight.

**Interim mitigation (in use):** the GameEngine Luau→Zebra translator
(`tools/luau2zebra_ast.py`) emits module vars with a reserved prefix
(`_mod_<name>`) for both the declaration and every reference it generates, and
never emits a shadowing local — fully sound for generated code, zero compiler
risk.

**Fix when picked up:**
- `src/CodeGen.zig` — emit module vars in a `_M` container struct (or a reserved
  prefix); `genIdent` already has `is_top_level`, so reference rewriting is local.
- `selfhost/CodeGen.zbr` — same container/prefix emit in `genFieldDecl`
  (owner == "" path) and `genIdent`, **plus** a `method_local_names: StrSet`
  threaded through the generator (reset per method, populated by
  `genLocalVar`/params/for-binds/captures) so `genIdent` only prefixes a name
  that is a module var **and not** a shadowing local.
- Add a smoke fixture: a module var named after a known preamble local (e.g.
  `total`) that compiles and runs.

**Discovered:** 2026-06-21, immediately after shipping module-level var/const
(Stage 1). Probe: `var total = 0` at module scope + any function → shadow error.

---

## BUG-136: `zebra file.zbr` run path captures child stdout instead of streaming

**Severity:** low (UX / capability — affects interactive programs, not
correctness of batch programs)
**Status:** OPEN — known limitation, decision pending (fix vs. leave as-is).

When `zebra file.zbr` runs a program, the selfhost driver
(`selfhost/main.zbr`) invokes the child via `sys.run(argv)`, which **captures**
the child's stdout/stderr into strings and prints them *after* the child exits
(`Terminal.write(rr.stdout, "")` / `sys.err(rr.stderr)`). The Zig-side
bootstrap (`src/main.zig`) does the same on its non-fast path (`runChildRemapped`
captures stderr for source-map remapping). Consequences:

- **No streaming** — output appears all at once when the program finishes, not
  as it is produced. A long-running program looks hung until it exits.
- **No interactivity** — a program that reads stdin or expects a live TTY
  (prompts, REPL-like loops, progress bars) won't work, because the child's
  stdio is piped, not inherited.

This is **pre-existing**, not introduced by the debug-run fast path (2026-06-20,
commit f9a05d1): the fast path's exec step (`sys.run([fast_exe])`) merely follows
the same capture convention the LLVM `zig run` path already used, so behavior is
unchanged either way. The fast path's *build* step legitimately needs capture
(to inspect exit code for fallback); only the *exec* step is the candidate to
change.

**Why it's not obviously a bug:** capture is *required* on the Zig backend's
LLVM path so stderr can be run through `remapZigErrors` (rewrites generated-`.zig`
line numbers back to `.zbr` source lines). Streaming would lose that remapping
for compile-time errors — though for the **fast-path exec** step the child is a
user program (its stderr is the program's own output / panic trace, not Zig
compiler errors), so inheriting stdio there is safe and would restore both
streaming and interactivity for the common debug-run case.

**Possible fixes (decide later):**
1. Fast-path exec only: spawn `fast_exe` with inherited stdio (needs a
   `sys.runInherit`-style API in the selfhost runtime; the bootstrap already has
   `runChild` with inherited stdio — `src/main.zig`). Scoped, low-risk; fixes the
   common case without touching the error-remapping path.
2. General: detect "is this a run (not compile-error) context" and inherit stdio
   for the program while still capturing the compiler's own diagnostics
   separately. More invasive.

Repro: a `.zbr` that prints in a loop with a sleep between lines — under
`zebra file.zbr` nothing appears until it exits.

## BUG-135: non-deterministic source-path markers in emitted .zig

**Severity:** low (cosmetic — affects only the `// Source:` / `// zbr:file:line`
comment markers — but it makes regenerated artifacts differ run-to-run, which
is what makes `update-selfhost` show a spurious diff)
**Status:** FIXED. Slash axis: source-fixed 2026-06-17 (`writePathFwd` /
`fwdSlashes`). Case axis: eliminated 2026-06-18 by the PascalCase file rename —
every `.zbr`/`.zig` pair now matches case, so there is no mismatch for MSYS to
mangle. Artifacts refreshed to the bootstrap canonical; regen is idempotent.

Emitted markers echoed the *verbatim* input path. On Windows + Git Bash, MSYS
argument mangling rewrites the `.zbr` path passed to the compiler
**non-deterministically** — sometimes `selfhost/codegen.zbr`, sometimes
`selfhost\codegen.zbr` (slash), and for the `parser`/`resolver` files whose
`.zig` artifact is capitalized but `.zbr` source is lowercase, sometimes
`parser.zbr` vs `Parser.zbr` (case). So two regen runs of the *same* file could
differ in hundreds–thousands of marker lines with no semantic change.

Fix (slash axis, both compilers): `src/CodeGen.zig` `writePathFwd` + `selfhost/
codegen.zbr` `fwdSlashes` normalize the marker path to forward slashes at emit
time, so the slash is deterministic and portable regardless of how the shell
passes the path. The **case** axis (parser/resolver) is *not* addressed — it is
rooted in the intentional `parser.zbr` → `Parser.zig` naming (the `.zig` mirrors
the hand-written `src/Parser.zig`, and is cross-imported by that capital name in
`build.zig` and many emitted files). Eliminating it would require a coordinated
rename, so it is left for the artifact-refresh pass, which is best run on a
case/slash-stable environment (Linux/CI) where neither axis is mangled.

Note: a single `selfhost/X.zig` cannot be regenerated in isolation — emit shape
(root vs dep, e.g. the aggregated `_zbr_error_msg`) differs and mixing shapes
crashes at runtime (see `tools/bootstrap_check.sh` header). The whole set must
be regenerated together (`update-selfhost`).

---

## BUG-134: bootstrap rejects re-exported cross-module type identity

**Severity:** medium (a type defined in module C, surfaced through module B's
method return, and re-imported in module A, fails A's return/assign check with
`type mismatch: expected 'T', got 'T'`; selfhost accepts it, so the compilers
diverge)
**Status:** FIXED 2026-06-17. `src/TypeChecker.zig` `isAssignable` now treats two
`cross_module` types as assignable when their `type_name` matches, regardless of
the `.module` label — cross-module type identity is by name (the type is the same
re-exported Zig declaration at every hop), with Zig as the backstop. This mirrors
the selfhost's `typesCompatible`, which returns `true` for any non-primitive pair.
`Type.eql` is left unchanged (it still requires module+name for cross_module
identity, so generic-arg/identity comparisons elsewhere keep their strictness);
only the assignment/return-check path is loosened.

Surfaced by GameEngine `instance.zbr`: `World.getSize(): Vector3?` (World in the
`ecs` module, `Vector3` re-exported there from `math`) returns a value the
bootstrap labeled `ecs.Vector3`, while `instance.zbr`'s declared return `Vector3`
resolved to `math.Vector3` — same Zig type, different `.module` label, so
`Type.eql` rejected `return s`. This was only *reachable* after BUG-133 stopped
stripping the optional. Regression: `test/crossmod_optret_*` is a 3-module
re-export chain (geom defines Vec3 → lib's `World.getSize(): Vec3?` → test
re-imports Vec3 and returns the unwrapped binding). With both fixes,
`instance.zbr` compiles under the bootstrap and the selfhost.

---

## BUG-132: bootstrap `genIf` panics on `else if <call> as <bind>`

**Severity:** low (codegen crash on a specific else-if shape; workaround =
nested `else { if … as … }`)
**Status:** FIXED 2026-06-17 — `src/CodeGen.zig` `genIf` now routes every clause
(head + each else-if, in both the capture-headed and plain-headed paths) through
a new `genIfCaptureClause` helper that decides the clause form (union-variant
check / optional unwrap / plain) from *its own* condition. Clauses in one chain
may now mix forms freely. This brings the bootstrap up to the **selfhost**, which
already factored this into `genIsCaptureThen` (so this was a bootstrap-only
divergence — no selfhost change needed). Regression: `test/if_unwrap_test.zbr`
extended with three mixed-chain cases (union-head+optional-elseif,
optional-head+union-elseif, plain-head+optional-elseif).

`src/CodeGen.zig` `genIf` (~9640) read `ei.cond.type_check` for an `else if`
condition, assuming the `is X as y` form — but an else-if whose condition is an
**optional-unwrap on a call** (`else if structNameFromType(et) as snm`) has an
active `.call` union field, so it panicked: `access of union field 'type_check'
while field 'call' is active`. The first `if … as …` (non-else) handled this
correctly; only the `else if` path assumed type_check.

---

## BUG-133: bootstrap strips `?T` from cross-module method returns

**Severity:** medium (a cross-module method declared `: T?` is inferred as `T`
by the bootstrap TC, so `if x as n` on its result errors; selfhost handles it,
so the two compilers diverge — this is §27c)
**Status:** FIXED 2026-06-17 (§27c). `src/TypeChecker.zig` now records an
`optional_method_returns` set on `ModuleInterface` (parallel to the existing
`optional_ref_fields`): when a public method's declared return is `T?` for a
user-defined `T`, its `"Type.method"` key is recorded. The three cross-module
method-return consumption sites build the result via a new
`crossModuleMethodReturnType` helper that re-wraps the `cross_module` type in
`.optional` when the key is present. `src/main.zig`'s `cloneInterface` and the
empty/cycle interface mirror the new field. Regression:
`test/crossmod_optret_test.zbr` (+`_lib`) exercises `if w.getSize() as s` across
a module boundary.

Root cause: `simpleTypeFromRef` collapses `nilable(<user-type>)` to `.unknown`
(since user types don't cross the arena boundary), and `instance_method_return_types`
only stored the bare type *name* (`namedTypeStr` unwraps the nilable), so the
optionality was lost. The **selfhost** stores the full `Type_` (via `typeFromRef`,
which maps `nilable → optional`), so it never had the bug — this was bootstrap
catch-up. GameEngine `instance.zbr` (cross-module `World.getSize(): Vector3?`,
`getTransform(): CFrame?`) now compiles under both compilers.

---

## BUG-131: inline capture-lambda to a `sig` param triple-emits the anon struct

**Severity:** medium (blocked the natural inline `signal.connect(def() capture
… )` idiom — the common Roblox `:Connect(function() … end)` shape)
**Status:** FIXED 2026-06-16 — both compilers now emit the closure value ONCE
into `_zbr_val_N` and derive the create's `@TypeOf` + the assignment from that
local, so they share one type.  (The dispatcher still re-derives its type — it's
a nested fn that can't see the local — but it only reinterprets a type-erased
pointer between layout-identical structs, which is sound.)  Round-trip
byte-identical, smoke 152/152.  Verified: inline `signal.connect(def() capture
…)` compiles and runs.  Discovered 2026-06-16 (GameEngine TweenService.Completed).

`emitCallWithClosureThunks` (the Gap-1 closure-via-sig path) emits the closure
value `genExpr(a.value)` **three times** — inside `@TypeOf(...)` for the
`_allocator.create`, in the `_zbr_cls_N.* = …` assignment, and inside the
dispatcher's `@TypeOf(...)`.  For an **inline** capture-lambda each emission is
a distinct anonymous `(struct {…}{…})` literal, and Zig gives each its own
type, so:

```
const _zbr_cls_1 = _allocator.create(@TypeOf((struct {…}))) …;  // *T1
_zbr_cls_1.* = (struct {…});                                    // T2 != T1  ← error
```

→ `error: expected type 'main__struct_60370', found 'main__struct_60375'`.

**Why it's been latent:** the **ident-bound** form
(`var f = def() capture …; sig.connect(f)`) works, because all three emissions
are the same named variable `f` (one type).  Gap-1 / BuildingTest used that
form, so the inline form was never exercised.  (thread_pool's earlier
anon-struct error was the *same* root cause, masked once BUG-128 stopped it
thunking `submit` at all.)

**Repro:** `signal.connect(def() capture { var x = x }; …)` — any inline
capture-lambda passed to a `sig`-typed parameter.

**Fix applied:** bind the closure value to a local `const _zbr_val_N = <closure>`
once, then `create(@TypeOf(_zbr_val_N))` + `_zbr_cls_N.* = _zbr_val_N`.  This is
the minimal change that fixes the create-vs-assignment type clash (the two
checked, same-scope emissions).  The dispatcher keeps its independent
`@TypeOf(<re-emit>)` — it can't see the local — but it only `@ptrCast`s the
type-erased pool pointer and the structs are layout-identical, so the round-trip
is sound.  A fuller fix (a container-scope named type shared by all three) was
considered but not needed for correctness; the stability-minimal change was
chosen.

---

## BUG-130: ~~methodMutatesSelf marks some non-mutating methods `*self`~~ NOT-A-BUG

**Status:** CLOSED — NOT-A-BUG 2026-06-16.  Misfiled.  The compiler does **not**
auto-analyze mutation; `genMethod` gates `self: *const Owner` purely on the
explicit `@pure` modifier (`src/CodeGen.zig` ~5018: `if (n.mods.pure) "*const "
else "*"`).  The observed inconsistency was a **source** gap: GameEngine's
`Vector3.lerp` was marked `@pure` while the identical `Color3.lerp` /
`Vector2.lerp` were not.  Resolved by adding `@pure` to those methods in the
GameEngine `zbra/math.zbr` (engine commit 935f0de); the `lerpProperty`
mutable-local workaround was dropped.  No compiler change.

(Original misfiling retained below for context.)

**Severity:** low — discovered 2026-06-16 (GameEngine property-reflection work).

`Color3.lerp` and `Vector2.lerp` emit `pub fn lerp(self: *Color3, ...)` while
`Vector3.lerp` — with a structurally **identical**, non-mutating body (returns a
fresh struct built from `self`'s fields, no field writes) — correctly emits
`pub fn lerp(self: *const Vector3, ...)`.  The Gap-2 `@pure`/methodMutatesSelf
analysis (commit 1757706) is therefore inconsistent: it proves Vector3.lerp pure
but not the identical Color3/Vector2 versions.

**Symptom:** calling the method on a value bound from a union variant (`if x is
U.col as c` → `c` is `*const`) fails to compile: `expected type '*math.Color3',
found '*const math.Color3'`.

**Repro:** GameEngine `zbra/math.zbr` Color3.lerp vs Vector3.lerp; see
`zbra/instance.zbr::lerpProperty`, which works around it by copying the receiver
to a `var` local.

**Likely cause:** the analyzer's mutation walk over the method body is
order/shape-sensitive (e.g. treats the `Color3(...)` constructor-from-`.r/.g/.b`
differently than `Vector3(...)` from `.x/.y/.z`), or short-circuits on the first
type and doesn't re-run identically per type.  Fix: make the purity walk
structural so identical bodies yield identical `*const` decisions.

---

## BUG-125: selfhost --emit-zig user-script mode emits cross-module union ctors as tag-calls

**Severity:** medium (blocks user scripts from constructing ECS Components directly)
**Status:** FIXED 2026-06-09 — selfhost now honors `--module-path`; deps found
there are parsed for types only (not emitted), so exposed cross-module unions
classify correctly.  Root cause: `compileDep_use` only searched the source's
own directory, so `use ecs` from `game/scripts/` never parsed `zbra/ecs.zbr`
and `dep_types` never learned `Component` is a union.  Fix: `MultiCompiler`
gained a `module_path` field + `scanDepForTypes` (parse + `populateModuleTypes`,
no emit), wired through `--module-path`.  The bootstrap already handled this;
this brought the selfhost to parity.  `tools/wire_script.py` now passes
`--module-path <engine>/zbra`.  Verified: `Component.anchored(true)` →
`Component{ .anchored = true }`.

**Follow-up 2026-06-09:** `scanDepForTypes` also now registers the dep's
class names in `dep_class_names`, so a script that stores a cross-module
class instance in a field or capture (e.g. `var t: Vector3Tween`) emits the
field/param as `*T` (reference type) instead of by-value — without this,
storing the constructor result (`*Vector3Tween`) into a value-typed field is
a `*T`-vs-`T` mismatch.  Consequence: scripts compiled with `--module-path`
now take their class-typed `main(...)` params by pointer (`*Instance`,
`*RunService`), so the host dispatch passes `inst`/`run` directly rather than
`inst.*`/`run.*`.  Pre-`--module-path` scripts (value params) are unaffected.

**Symptom:** In a `.zbr` file under `game/scripts/` compiled via `zebra.exe --emit-zig`, calls of the form `Component.transform(cf)` (where `Component` is a cross-module union imported via `use ecs exposing Component`) emit literally as `Component.transform(cf)` in Zig — which the Zig compiler rejects with:

```
error: type '@typeInfo(ecs.Component).@"union".tag_type.?' not a function
```

The correct emit, observed for the SAME pattern in stdlib `.zbr` files (`zbra/physics.zbr`, `zbra/humanoid.zbr` — both `use ecs exposing World, Component`), is `Component{ .transform = cf }`.

**Repro (in `C:\Projects\GameEngine`):**
```zebra
# game/scripts/repro.zbr
use ecs exposing Component, World

def main(world: World)
    var cf = ...
    world.addComponent(eid, Component.transform(cf))   # → broken Zig in --emit-zig
```

Failure persists across: nested call args, ident-bound vars, staged locals, and helper-wrapped return statements. The discriminator is *where the .zbr lives* (script vs stdlib), not the syntactic shape.

**Workaround:** Hide the union ctor behind a stdlib method. See `zbra/workspace.zbr`'s `spawnBox` / `setEntityPosition` (and `zbra/workspace.zig` hand-impl) for the pattern used by `game/scripts/orbit_follower.zbr`.

**Discovered:** OrbitFollower case study (4th hand-ported script), 2026-06-09.

---

## BUG-126: Gap 1 closure-via-sig thunk uses per-call-site state slot (last-wins)

**Severity:** medium (blocks two scene instances of the same script that share a `connect()` call site)
**Status:** FIXED 2026-06-09 — replaced the single module-level state slot per
call site with a **trampoline pool** of K=64 (state slot, thunk fn) pairs.
Each connection reached at a call site grabs the next free slot via a
monotonic `_zbr_next_N` counter and is handed a distinct `_zbr_thunks_N[slot]`
fn-pointer bound to its own `_zbr_state_N[slot]`.  A bare Zig fn-pointer
carries no context, so K distinct code addresses are fundamentally required;
the pool bounds concurrent connections at one call site.  Overflow (>K live
connections through one source line) panics with a clear message rather than
silently dropping earlier connections (the old last-wins behaviour).  Fixed in
both `src/CodeGen.zig` (flushPendingThunks + emitCallWithClosureThunks) and
`selfhost/codegen.zbr`; round-trip clean.  Verified: the OrbitFollower
two-instance scene now ticks Follower1 AND Follower2 independently (was
Follower2 only).  **Remaining limitation:** `_zbr_next_N` is monotonic, so
connect/disconnect churn leaks slots; and K is a hard ceiling.  A truly
unbounded fix needs the `sig` ABI to carry a context pointer (fat pointer) —
deferred until a use case needs >64 live connections or dynamic disconnect.

**Symptom:** Each call site that connects a closure to a `sig`-typed signal handler synthesizes a single module-level state cell (`_zbr_state_N: ?*anyopaque`). When the same `connect()` call is reached twice in one program execution (e.g. two scene instances of the same script), the second call overwrites the cell. The first closure is orphaned — its `Heartbeat`/`RenderStepped` handler never fires again, even though the connection appears successful.

**Repro (in `C:\Projects\GameEngine`):** `game/scripts/orbit_follower.zbr` loaded twice as `Follower1` and `Follower2` in `demo_scripts.zbr-scene`. Both `[orbit_follower:FollowerN] connected` messages print; only Follower2's tick lines appear thereafter. Confirmed visually: Follower1's spawned cube sits stationary at its initial position; Follower2's cube orbits.

**Fix direction:** Have `signal.connect(handler)` return a connection ID and have the thunk store a *map* of state cells keyed by ID, rather than a single slot per call site. Existing single-subscriber Roblox-style code stays correct; multi-subscriber works.

**Discovered:** OrbitFollower case study, 2026-06-09. Flagged as unverified concern in the TimerTest case study (`docs/TIMER_TEST_CASE_STUDY.md`); empirically falsified by the OrbitFollower two-instance scene.

---

## BUG-127: selfhost emits negative-literal `var` initializer without type annotation

**Severity:** low (annotation workaround is trivial)
**Status:** FIXED 2026-06-09 — `genLocalVar`'s literal-shape annotation branch
now handles `Expr.unary` (neg of int/float literal), emitting `: i64`/`: f64`
like the bare-literal case.  Used `branch un.operand` (not `is`) so the `^Expr`
deref round-trips identically under bootstrap and selfhost.  Verified:
`var a = -6.0` → `var a: f64 = (-6.0);`.

**Symptom:**
```zebra
var x = -6.0   # emits: var x = (-6.0);  → Zig: comptime_float not const/comptime
var y = 0.0    # emits: var y: f64 = 0.0; (correct)
```

Positive literal initializers widen to `f64`; negative literals (unary minus) emit as a bare comptime expression that Zig rejects when the binding is `var` rather than `const`.

**Workaround:** Annotate explicitly: `var x: float = -6.0`.

**Discovered:** OrbitFollower case study, 2026-06-09.

---

## BUG-128: Gap 1 thunk path over-applies to `sys.go` / `ThreadPool.submit`

**Severity:** high (broke two shipped 1.0 concurrency features — `Chan`+`sys.go`, `ThreadPool` — for closure arguments, in *both* compilers)
**Status:** FIXED 2026-06-16 — `genCall`'s Gap-1 gate routed *any* call with a
closure argument into `emitCallWithClosureThunks`, before the `sys.go`
(`_sys_go`) and `ThreadPool.submit` handlers could run.  Those consumers take
the closure *struct* directly via `anytype` dispatch, but the thunk path handed
them a bare fn-pointer and emitted the callee verbatim (`sys.go(...)` →
undeclared `sys`; `pool.submit(thunk)` → anon-struct type-identity mismatch).

**Root cause:** introduced by BUG-126 (commit 48a3aad).  The Gap-1 thunk exists
only to satisfy bare `sig` fn-pointer parameters, but the gate never checked
that — it fired on the mere presence of a closure arg.

**Fix:** a *negative* gate (`callNeedsClosureThunks` /
`isStdlibClosureStructConsumer` in both `src/CodeGen.zig` and
`selfhost/codegen.zbr`): thunk every closure arg EXCEPT those passed to the two
stdlib closure-struct consumers (`sys.go`, `<pool: ThreadPool>.submit`).  In
Zebra *user* code a closure value can only be typed through a `sig` param (no
user-writable `anytype`), so this never un-thunks the cross-module `sig` case
(`Signal.connect`) that Gap 1 exists for — verified with an isolated
cross-module repro (`evt.connect(closure)` → `evt.connect(_zbr_thunks_1[...])`).

**Discovered:** WIP-branch merge gate (`chan_thread_test` + `thread_pool_test`
smoke failures), 2026-06-16.

---

## BUG-129: bare `Atomic.add(...)` statement misses the `_ =` discard (bootstrap TC)

**Severity:** medium (any `Atomic(int).add/sub/swap/load` used as a bare
statement fails to compile under the bootstrap compiler — Zig "value of type
i64 ignored")
**Status:** FIXED 2026-06-16 — pre-existing, independent of BUG-128 (fails even
at top level, not just in closures).  `src/TypeChecker.zig` had no `Atomic`
inference, so `counter.add(1)` typed as `.unknown`, and the CodeGen discard rule
(`t != .void_ and t != .unknown`) skipped the `_ =`.  `atomic_test` only passes
because it captures every non-void return (`var old: int = counter.add(3)`).

**Fix:** `atomicElemType` + an Atomic arm in `inferCall` (`add/sub/swap/load` →
element type `T`, `cas` → bool, `store` → void).  The selfhost already handled
this in codegen via `atomic_locals` (the `inferExpr`-can't-see-Atomic
workaround); its method set was widened to `{add,sub,swap,load,cas}` to match
the bootstrap so both compilers emit the discard identically.

**Discovered:** unmasked by the BUG-128 fix while greening `thread_pool_test`,
2026-06-16.

---

> BUG-029 and BUG-030 were resolved incidentally in the selfhost implementation — see `BUGS_FIXED.md`.

Fixed / closed bugs have been moved to `BUGS_FIXED.md`.

---

## BUG-086: struct pattern — cross-module type names not supported

**Severity:** low (pre-1.0 gap)  
**Status:** closed — fixed in commit 343ddac

`on Mod.Point(x: 0)` is now recognized as a struct pattern. Three fix sites:
- `src/AstBuilder.zig` `liftStructPattern`: accepts `.member` callee (Mod.TypeName) alongside plain `.ident`
- `selfhost/parser.zbr`: `isOpenCallAt(offset)` helper + `id "." open_call` detection in `parseBranchStmt`
- `selfhost/astbuilder.zbr` `tryBuildStructPat`: handles `Expr.member` callee

---

## Library Files with No Entry Point (Expected "Failures")

These are not bugs — they're library files that can't run standalone:
- `MathUtils.zbr` — utility class, imported by `crossmod_*`, `use_test`, `transitive_test`
- `StringHelper.zbr` — utility class, imported by `transitive_test`

---

## Intentional Error Tests (Correct Behavior)

These fail WITH A COMPILER ERROR — that IS the test passing:
- `branch_infer_miss_test.zbr` — expects error for non-exhaustive branch
- `branch_missing_test.zbr` — expects error for missing variant
- `capture_error.zbr` — expects error for undeclared capture

---

## Open Bugs

### BUG-196: container-method dispatch broken on `List(List(T))` ✅ RESOLVED (2026-07-23)
Two filed faces: (a) `.len`/`.at` on a `for` binding over `List(List(T))` → "no field
'len' in ArrayList(...)"; (b) `.add` on a `List(List(float))` local → "no member 'add'".
**Root of (a):** `genForIn`'s general List-iteration path registered the loop var in
`for_loop_vars` and special-cased `List(str)`/JSON elements, but never bound the loop
var's TYPE in `infer_ctx` for a general element — so for a nested `List(List(T))` the
inner-List loop var was untyped, and `.len` fell through to the string-shaped `.len`
instead of `.items.len` (and `.at` similarly). **Fix:** in `genForIn`, when the
iterable's element type is itself a container (`Type_.list_`/`Type_.hashmap_`), bind the
loop var to that element type (`ic_for.bind(vname, for_elem_t)`), so container-method
dispatch resolves on the binding. Scoped to container elements so struct/str/primitive
loops are unchanged (they had no working behavior to regress). Face (b) as filed no
longer reproduces (`.add` on the outer `List(List(float))` runs). Verified typed AND
untyped iterables. Regression: `test/bug196_nested_list_test.zbr` (smoke_run "bug196: 43").
Deeper nested-container facets found while probing are filed separately as BUG-201.

### BUG-195: `.entries()`/`.keys()`/`.values()` on a HashMap *parameter* ✅ RESOLVED (2026-07-24)
The `_zebra_map_keys`/`_values`/`_entries` preamble helpers did `@TypeOf(map).KV`; a
HashMap passed as a fn parameter is a `*HashMap`, and `.KV` is not a decl on the pointer
(worked on a local). Fixed in the shared `selfhost/stdlib_preamble.zig` (read by BOTH
compilers at emit time — one fix covers both): added `_MapKV(comptime T)` that derefs a
pointer (`@typeInfo(T) == .pointer`) before reading `.KV`, used in all three helpers. All
three methods now work on a map param. Verified selfhost (entries=30/keys=2/vals=30) and
the bootstrap emit compiles. Regression: `test/bug195_map_param_test.zbr` (smoke_run
"bug195: 62"). Gates all green. No compiler rebuild needed for the fix (preamble is read
at emit time), but regen confirmed clean.

### BUG-194: `Math.log` missing in the selfhost ✅ FIXED (2026-07-18, divergence burn-down)
Was: in the bootstrap (`src/CodeGen.zig:8055`) but not selfhost `genMathCall` —
`Math.log(x)` fell through to `std.math.log` (a 3-arg fn) → "expected 3 argument(s),
found 1". Added the natural-log handler `std.math.log(f64, std.math.e, @as(f64, x))`
(+ `isNaN`→`isNan`, `isInf`, `atan2` while converging `math_test`). Surfaced again by
the selfhost↔bootstrap divergence audit.

### BUG-193: `File.listDir` missing in the selfhost ✅ RESOLVED (2026-07-24)
Was: implemented in the bootstrap but the selfhost emitted `@compileError(...)`. Ported
from the bootstrap (`src/CodeGen.zig:7855`): added `listDir` to the selfhost's
`genFileCall` (a `blk:` expr opening the dir with `.iterate`, duping each entry name into
a `List(str)` — names are slices into the iterator's reused buffer, so the dupe is
required) and its `List(str)` return type to `TypeChecker` File-method inference (beside
`readLines`). Verified: lists a real dir (3 names, sorted, `.len`/iteration dispatch).
Regression: `test/bug193_listdir_test.zbr` (smoke_run "bug193: OK"). Gates all green.
Note: like the bootstrap, `listDir` does NOT path-normalize — pass a native path.

### BUG-119: ✅ FIXED 2026-05-18 — `list_field_names` reverse index in ModuleTypes

`List` fields accessed through function parameters now emit `.items.len` correctly.

**Fix:**
- `selfhost/typechecker.zbr ModuleTypes`: added `list_field_names: HashMap(str, bool)` field (parallel to `hashmap_field_names`), `addListField(name)` + `hasListField(name)` methods; initialized in `cue init()`.
- `selfhost/typechecker.zbr`: added `isListTypeRef(tr: TypeRef): bool` helper (mirrors `isHashMapTypeRef`).
- `selfhost/typechecker.zbr addClassMembers`: after the `isHashMapTypeRef` check, added `if isListTypeRef(v.type_ to!)` → `mt.addListField(v.name)`.
- `selfhost/codegen.zbr`: added `fieldIsList(mt, dep_mt, field_name): bool` helper (parallel to `fieldIsHashMap`); `.len` handler now includes `fieldIsList(.module_types, .dep_types, fn2)` in the `is_list_obj` check.

Test: `test/bug119_list_field_param_test.zbr` (smoke_run: "bug119_list_field_param: OK").
Bootstrap verified: `zig build update-selfhost` + smoke 117/117 passing + bootstrap 5/5.
- **Discovered:** 2026-05-06 while compiling `IDE/ZebraIDE.zbr`.

---

### BUG-115: ✅ FIXED 2026-05-14 — `private` / `internal` visibility keywords shipped

`private` and `internal` keywords implemented and enforced by both compilers:
- **Zig backend (`src/TypeChecker.zig`):** `checkMemberVisibility` at line 2185 checks `mods.private` / `mods.protected`; error if accessed outside the owning class. `extractModuleInterface` already skips `private`/`internal` members from cross-module export.
- **Selfhost (`selfhost/typechecker.zbr`):** `ModuleTypes.private_member_keys: HashMap(str, bool)` reverse index populated by `addClassMembers`; `inferExpr Expr.member` checks `isPrivateMember` and emits `"'X' is private"`.

Original open question (resolved by implementing):
- **Status (2026-05-04):** Design question — add keywords, or drop the `_` convention?
- **Decision (2026-05-14):** Implement keywords. Both backends enforce `private` (per-class) and `internal` (treated as protected/module-scoped). Sweep: `_` convention retained only for compiler-emitted internals (`_allocator`, `_arena`, etc.).
- **Evidence:** NEXT_STEPS.md `[x] BUG-115` entry marked complete 2026-05-14.
- **Source:** `STYLE_GUIDE.md` §1 Q3.

---

### BUG-114: `0 - x` / `0.0 - x` instead of `-x` — ✅ SWEPT 2026-05-06
- **Severity:** N/A
- **Status:** Closed — sweep complete; no `0 - x` / `0.0 - x` occurrences remain in any `.zbr` file.
- **Source:** `STYLE_GUIDE.md` §13.3.

---

### BUG-110: ✅ FIXED 2026-05-05 — bind error prints clean message instead of panic
- **Severity:** Low (only triggers on bind failure; rare in practice)
- **Status:** Fixed — `selfhost/stdlib_preamble.zig`: `catch |e| @panic(...)` replaced with `std.debug.print` + `return`. Http.serve remains non-throws (making it throws would ripple into TC/codegen — deferred).
- **Original description:**
- **Symptom:** The runtime `_http_serve` handles bind failure with `... .listen(.{ .reuse_address = true }) catch |e| @panic(@errorName(e))`. On any bind failure (port busy with `reuse_address = false`, permission denied for low ports, address-not-available), the program dies with a Zig panic and stack trace rather than a clean error. Counterpart of BUG-107 (TC halt-on-diagnostics audit) but at runtime: the failure is communicated by panic rather than by the language's structured error path.
- **Reproducer:** With BUG-109 fixed (`reuse_address = false`), running `server_test.exe` twice produces a panic on the second run instead of a clean error message.
- **Root cause:** `src/CodeGen.zig` emits the `catch |e| @panic(@errorName(e))` pattern in `_http_serve`. The right shape is to make `Http.serve` `throws` so callers can `catch |err| { print "Could not bind: ${err}" }`.
- **Fix sketch:** Change `Http.serve`'s declared signature to `throws` (in the typechecker's stdlib bindings); update the emit so the bind error propagates as `anyerror!void` rather than panicking. Callers that don't care can still `Http.serve(...) catch unreachable`. Pairs naturally with BUG-109 — both are policy decisions about how the runtime communicates bind problems.
- **Discovered:** 2026-05-04, alongside BUG-109.
- **Source:** Side-finding from `test/server_test.zbr` port-busy fix.

---

### BUG-109: ✅ FIXED 2026-05-05 — `.reuse_address` flipped to `false`
- **Severity:** Medium (footgun for test apps; not a crash, but a "wait, why are four copies running?" surprise)
- **Status:** Fixed — `selfhost/stdlib_preamble.zig` line 525: `reuse_address = true` → `false`.
- **Original description:**
- **Symptom:** The runtime `_http_serve` (emitted by `src/CodeGen.zig`) calls `std.net.Address.initIp4(.{0,0,0,0}, port).listen(.{ .reuse_address = true })`. The `reuse_address = true` setting allows multiple processes to successfully `listen()` on the same port; the OS load-balances incoming connections across them. Concrete observed consequence: 2026-04-21 → 2026-05-04 the box accumulated 4 stray `server_test.exe` processes all coexisting on 8080, undetected until manual `netstat` inspection.
- **Reproducer:** Run `server_test.exe` (built from `test/server_test.zbr`) twice in succession in separate terminals — both bind successfully and both serve traffic. No error from the second bind.
- **Root cause:** `src/CodeGen.zig` emits `.reuse_address = true` unconditionally in the `_http_serve` preamble (line ~459 in current emitted output). The flag is appropriate for fast-restart-after-crash workflows (avoids TIME_WAIT delay) but inappropriate for "did I accidentally start two of these?" detection.
- **Fix sketches (pick one):**
  1. **Flip to `.reuse_address = false`** — simplest; OS rejects duplicate binds. Cost: TIME_WAIT delay if the same port is rebound within ~60s after a clean shutdown. For test apps this is fine; for production restart loops it's friction.
  2. **Make it configurable:** `Http.serve(port, handler, reuse: false)` with a default that we pick. Cost: tiny API change, ripples through codegen.
  3. **Probe-bind hybrid:** keep `reuse_address = true` but also attempt a `Tcp.connect` probe first and refuse if it succeeds. Cost: small race window between probe and bind; doubles the syscall surface.
- **Workaround in use:** `test/server_test.zbr` now does the probe-then-bind dance manually at the user level (see commit 7fe29ae). Every other `Http.serve` caller would have to do the same until this is fixed centrally.
- **Discovered:** 2026-05-04 cleanup of the 4 stray instances.
- **Source:** Side-finding from `test/server_test.zbr` port-busy fix.

---

### BUG-107: ✅ VERIFIED 2026-05-18 — codegen never runs on a diagnosed tree

Verified all three entry points halt before codegen when diagnostics are present:

1. **`src/main.zig:396`:** `if (had_error) return 1;` — after collecting `bind.diags`, `resolve.diags`, `tc.diags`. CodeGen is invoked only on the `else` path.
2. **`selfhost/main.zbr:130-132`:** `if tc_ctx.hasErrors()` → `sys.errln(tc_ctx.errorMessages())` → `sys.exit(1)`. Explicit process exit before Step 5 (Zig emit).
3. **`src/Repl.zig:439-443`:** `had_error` checked after `bind.diags`, `resolve.diags`, `tc.diags`; `if (had_error) return null;` before `CodeGen.generate`.

Property holds. No code change needed.
- **Source:** Robustness audit 2026-05-01 (`C:/tmp/zebra-tc-audit.md` entry [P1-5]).

---

### BUG-100: ✅ FIXED (side-effect of BUG-099, 2026-05-05)
- **Symptom was:** `else => unreachable` panic when `for k, v in <non-var ident>`.
- **Fix:** The BUG-099 three-way Type split rewrote the surrounding TC block; the
  `is_hashmap_two_var` switch now uses `else => null` (line ~1321 current), so
  a method/class/namespace ident simply yields `hm_dt = null` and the loop falls
  through to normal for-in handling — no panic.
- **Verified 2026-05-05:** `for k, v in getMap()` + HashMap two-var smoke pass.

---

### BUG-097: ✅ FIXED 2026-05-08 — `*ArrayList` chain call three-case logic
- **Severity:** Medium (any function that takes a List/HashMap as a mutating out-param can't itself call helpers that take that container by value)
- **Status:** Fixed:
  - `src/CodeGen.zig`: added `caller_ptr_params: ?*const std.StringHashMap(void)` field to `Generator`; populated in `genMethod` for non-TCO methods; `argIdentInCpp` helper; three-case logic in both positional and named paths of `genArgs`.
  - `selfhost/codegen.zbr`: `caller_ptr_params: StrSet` field added + initialized; `withMethodCtx` creates fresh StrSet; `genMethod` populates it after `withInferCtx`; `argIdentInCpp` method on `Generator`; three-case logic in `genArgListNamed`, method dispatch named-reorder path, and method dispatch positional path.
  - Test: `test/bug097_ptr_param_chain_test.zbr`; added to `selfhost_smoke.sh`.
  - Bootstrap 5/5.
- **Original description:**
- **Symptom:** With BUG-091's mutation-driven `*ArrayList` conversion, a function signature like `def freeVars(t: Term, out: List(str))` emits `out: *std.ArrayList(...)`. Two follow-on issues then surface in the same body:
  1. **Recursive call:** `freeVars(child, out)` — the call site still emits `&out` (because the formal param is mutating-container), producing `**ArrayList` for an arg expected as `*ArrayList`.
  2. **Helper call:** `hasName(out, name)` where `hasName` takes `out: List(str)` non-mutating (so its sig stays `ArrayList`). The call site emits `hasName(out, name)` with no `.*` deref, producing `*ArrayList` for an arg expected as `ArrayList`.
- **Reproducer:** see `examples/lambda_calc.zbr`'s commit history — the original `freeVars(t: Term, out: List(str))` shape ran into both above; the file was rewritten to return-by-value instead.
- **Root cause:** the `&` insertion in `genArgs`/`genArgListNamed` didn't account for the caller's param already being `*ArrayList`. The decision rule now distinguishes:
  - arg is value, formal is `*Self` → emit `&arg` (original BUG-091 behavior)
  - arg is already `*Self`, formal is `*Self` → emit `arg` (Case 1: no double `&`)
  - arg is already `*Self`, formal is value → emit `arg.*` (Case 2: deref)
- **Workaround (obsolete):** restructure to return-by-value, or thread the container through a class field.
- **Discovered:** 2026-04-30 while writing `examples/lambda_calc.zbr`.

---

### BUG-096: ✅ FIXED 2026-05-07 — `List(SomeClass)()` constructor now pointer-wraps class type args
- **Severity:** Low (only triggers when storing class instances in Lists declared as fields)
- **Status:** Fixed:
  - `selfhost/codegen.zbr genTypeFromExpr`: added `if class_names.contains_(id.name)` check before `zigPrimitive`; emits `"*" + id.name` for class types, matching `genType`'s behaviour.
  - Zig backend (`src/CodeGen.zig genType`) was already correct; this was a selfhost-only gap.
  - Test: `test/bug096_list_class_ctor_test.zbr`; added to `selfhost_smoke.sh`.
- **Original status:** Open
- **Symptom:** `class Holder { var results: List(Result) = ... }` where `Result` is a class. The field type emits as `std.ArrayList(*Result)` (correct — classes are reference-typed), but the constructor expression `List(Result)()` emits `std.ArrayList(Result){}` (without the pointer). Zig rejects the assignment with a type mismatch.
- **Reproducer:**
  ```zebra
  class Result
      var msg: str = ""
      cue init(m: str)
          this.msg = m

  class Holder
      var results: List(Result)
      cue init()
          this.results = List(Result)()      # ✗ field is List(*Result), ctor builds List(Result)
  ```
- **Workaround:** make the element type a `struct` rather than a `class` (the workaround used by `book_run.zbr`'s `Result` type), or assign via `[]` empty-list literal once that path supports class element types.
- **Discovered:** 2026-04-30 while writing `book_run.zbr`.

---

### BUG-094: ✅ FIXED 2026-05-05 — HashMap two-var for-in works in both backends
- **Severity:** Medium (the QUICKSTART-canonical iteration form is unusable; the rest of the book has examples that won't compile)
- **Status:** Fixed:
  - `selfhost/codegen.zbr`: `_ = kname;` discard is now guarded by `nameUsedInStmts`; same guard added for `vname`.
  - `src/CodeGen.zig genForIn`: early dispatch `if (s.vars.len == 2) return genForInHashMap(s)` added before the type-inference path (Zig backend was falling through to native for-loop syntax, causing "extra capture" error).
  - Test: `test/bug094_hashmap_kv_test.zbr` (all 4 k/v used/unused permutations); added to selfhost_smoke.sh.
- **Original description:**
- **Symptom:** Both backends fail on `for k, v in some_hashmap`:
  - **Selfhost (`zebra.exe`):** emits `const name = ...; _ = name;` immediately followed by usage in the loop body — Zig rejects with "pointless discard of local constant ... used here". Even when the discard is suppressed, `print "${name}: ${age}"` falls back to `{any}` for `name` because the formatter doesn't see the `[]const u8` type for the for-binding.
  - **Zig backend (`zebra-bootstrap.exe`):** rejects the syntax outright with "extra capture in for loop" — the multi-binding form was never wired up here.
- **Reproducer:**
  ```zebra
  def main()
      var ages = HashMap(str, int)()
      ages.put("Alice", 30)
      for name, age in ages
          print "${name}: ${age}"
  ```
- **Workaround:** Read values back via `.get(known_key)` for spot lookups; iterate with a parallel `List(str)` of keys when you genuinely need to walk the whole map.
- **Doc claim:** QUICKSTART §10 documents `for k, v in m` as the canonical iteration. Either fix both backends to support it, or amend the doc to point at the working pattern.
- **Discovered:** 2026-04-30 while sweeping the book's Chapter 3 examples for the verbosity rewrite.

---

### BUG-093: ✅ FIXED 2026-05-05 — `s.len` now emits `@as(i64, @intCast(...))` — returns `int`
- **Severity:** Low (was forcing awkward workarounds; comparisons still worked)
- **Status:** Fixed:
  - `src/CodeGen.zig`: `isStringTypeName(n.name) and prop == "len"` path emits `@as(i64, @intCast(s.len))`.
  - `selfhost/codegen.zbr`: same `@as(i64, @intCast(...))` wrapper in the genMember string path.
  - Test: `test/bug093_strlen_test.zbr` (commit `dbd6fda`); added to `selfhost_smoke.sh`.
- **Original symptom:** `s.len` codegenned as `.len` on `[]const u8` (usize), causing `var n: int = s.len` and `s.len - 3` arithmetic to fail with type mismatch.
- **Discovered:** 2026-04-29 while writing `book_extract.zbr`.

---

### BUG-090: ✅ FIXED 2026-05-08 — `for n in Reflect.fieldNames(obj)` element type is now `str`
- **Severity:** Low (cosmetic; iteration itself is correct)
- **Status:** Fixed:
  - `src/TypeChecker.zig inferForInElemType`: added `Reflect.fieldNames` / `Reflect.fieldTypes` arm alongside `Net.resolve` — returns `.string`.
  - `selfhost/typechecker.zbr isStrListCallExpr`: added `fieldNames` / `fieldTypes` to the member-name check.
  - Test: `test/bug090_reflect_fieldnames_test.zbr`; added to `selfhost_smoke.sh`.
  - Bootstrap 5/5.
- **Original description:**
- **Symptom:** Iterating a `Reflect.fieldNames(obj)` result (or any other `[]str`-returning stdlib call) loses the element type, so `print n` inside the loop emits the byte-array fallback instead of the string.
- **Reproducer:**
  ```zebra
  class User
      var name: str = ""
      var age: int = 0

  class Main
      static
          def main
              var u = User()
              u.name = "Alice"
              for n in Reflect.fieldNames(u)
                  print n               # prints `{ 110, 97, 109, 101 }` then `{ 97, 103, 101 }`
              print u.name              # prints `Alice` correctly — direct field access is fine
  ```
- **Generated Zig:** `for (_reflect_User_fields[0..]) |n| { std.debug.print("{any}\n", .{n}); }` — `n` is `[]const u8` but the print emits `{any}`.
- **Root cause:** for-loop variable element-type propagation gap.  TC infers the iter source as `[]str` / `str_slice` but doesn't record `n`'s element type into the per-statement `expr_types` map that the print-emission path consults.  Same bug class as BUG-089 (TC propagation gap surfaces as wrong print format), different code path.
- **Workaround:** Assign through a `: str`-annotated temp inside the loop before printing.
- **Related:** BUG-017 (legacy `len`-on-unknown-type fallback).
- **Discovered:** 2026-04-28 while spot-verifying QUICKSTART.md §25 reflection example.

---

### BUG-089: ✅ FIXED 2026-05-08 — mixin method return type correctly inferred; methods emitted into class
- **Severity:** Low (cosmetic — wrong output format; does not affect type-annotated locals)
- **Status:** Fixed:
  - `src/TypeChecker.zig inferMember`: after `own_scope.lookupLocal` misses, iterate `sym.decl.class.adds` and look up each mixin's `own_scope` (resolver populates these). Returns `tc.symbolType(member_sym)`.
  - `selfhost/typechecker.zbr populateModuleTypes`: two-pass fix — pass 1 registers mixins as their own `ClassTypes`; pass 2 merges mixin methods into each class that `adds` them via `addClassMembers`.
  - `selfhost/codegen.zbr genClass`: after own members, iterate `n.mixins`, find matching `Decl.mixin_` in `module_decls`, and call `ig.genMethod` for each mixin method.
  - `selfhost/codegen.zbr count dispatch`: before `.items.len` fallback, check via `inferExpr` if receiver is a class with a user-defined `count()` method — if so, pass through as a normal call.
  - `selfhost/parser.zbr`: added `mixin_: ^PClass` to `PNode` union; `parseMixinDecl()`; `adds` clause parsing in `parseClassDecl`; `mixins: List(str)` field to `PClass`.
  - `selfhost/astbuilder.zbr`: added `buildMixin()`, `PNode.mixin_` dispatch arm, and mixin TypeRef population in `buildClass`.
  - `selfhost/main.zbr`: updated `PClass(...)` constructor call to pass `mixins` field.
  - Test: `test/bug089_mixin_method_test.zbr`; added to `selfhost_smoke.sh`. Bootstrap 5/5.
- **Original description:**
- **Symptom:** Calling a mixin method that returns `str` directly inside `print` emits the bytes as a `[]const u8` integer-array fallback instead of as text.
- **Generated Zig:** `std.debug.print("{any}\n", .{f.hi()});` — wrong format specifier; should be `"{s}\n"`.
- **Root cause:** TC `inferMember` didn't search `adds Mixin` scopes for methods — returned `.unknown`. Also, selfhost didn't parse `mixin` declarations or `adds` clauses at all.
- **Discovered:** 2026-04-28 while spot-verifying QUICKSTART.md examples.

---

### BUG-228: `--release` produced an UNOPTIMIZED binary — FIXED 2026-08-03
- **Status:** Fixed. Gated by `tools/release_mode_check.sh` (FULL tier).
- **Was:** `zebra --release` switched the backend to LLVM — a real, visible change (20 MB
  to 2 MB) — but the branch that actually emits an executable passed **no optimize flag**,
  so Zig defaulted to **Debug**. `release` was consumed in three places; the other two (the
  node-addon build, and a `mode_c` branch carrying `-fno-emit-bin`) were fine. The ordinary
  exe path was not among them. **Anyone shipping with the flag shipped Debug believing
  otherwise** — the flag's entire purpose.
- **Fix:** `-OReleaseFast` on that branch. **ReleaseFast, not ReleaseSafe**, per Sean's
  2026-07-30 direction: make ReleaseFast good enough that ReleaseSafe does not buy much,
  and settle it by A/B testing with users rather than by argument. That is the
  Design-by-Contract position — contracts are checked in development and stripped for
  release *because* they established the property, so a release build should not re-check
  at runtime what the contracts already proved.
- **ORDERING WAS LOAD-BEARING and the ticket said so.** The flag also enables
  `unreachable`-is-UB, which A4 removed on 2026-07-30. Adding it earlier would have turned
  an unoptimised-but-safe build directly into an optimised one with UB on OOM.
  `tools/lint_oom_unreachable.py` was confirmed clean (0 hazards) **before** the line was
  written.
- **Verified by SIZE, not timing** (a shared machine makes timings worthless): the same
  emitted `.zig` built three ways — `zebra --release` **813 KB**, reference Debug
  **1872 KB**, reference `-OReleaseFast` **800 KB**. `--release` lands on the ReleaseFast
  figure.
- **Gated, because nothing else in any tier uses the flag.** `release_mode_check.sh`
  asserts the release build RUNS and prints the right answer, and that its binary is
  materially smaller than the same program built without. The size check is
  **self-calibrating** — two binaries built in the same run, not a recorded number, since a
  hardcoded size rots on the next Zig release. Verified RED against the exact regression it
  guards (compare release against itself → `812 KB vs 812 KB → FAIL`).
- **A skipped size check counts as a FAILURE.** The first version of the gate could not
  locate either binary and printed "all checks pass" with its only real assertion never
  having run — caught before it shipped.

---

### BUG-106: heterogeneous list literals silently typechecked in the SELFHOST — FIXED 2026-08-04
- **Status:** Fixed in the selfhost (the bootstrap has had it since 2026-05-05). The
  regression fixture now runs — as a **negative** test, which it never was before.
- **Was:** `var xs = [1, "two", 3]` passed the selfhost front end entirely and failed inside
  emitted Zig with `expected type 'i64', found '*const [3:0]u8'` — a message about generated
  code. `zebra.exe` **is** the selfhost, so the shipping compiler had no check.
- **How it was found:** BUG-243 flagged that `bug106_heterogeneous_list_test.zbr` had never
  run. It had not merely gone unverified — **the fix was absent**.
- **Fix:** `checkLiteralHomogeneity`, ported from `src/TypeChecker.zig`. First non-abstract
  element is the anchor; every later non-abstract element must be compatible in either
  direction. **Numeric mixes still pass** (`[1, 2.0, 3]` — the untyped-numeric principle),
  verified as a false-positive guard. One error per literal, matching the bootstrap's
  `break`: a five-element mixed literal is one mistake, not four.
- **Scope limit, stated rather than implied:** LIST literals only. The bootstrap applies the
  same rule to `array_lit`; the selfhost's `inferExpr` has **no array_lit branch at all**, so
  covering it means adding inference for that node — a behaviour change beyond restoring a
  missing check. Written as a helper so the array case is one call once that branch exists.
- **The fixture stopped being an asymmetry witness, which was the real tangle.** It served
  two contradictory roles: the regression test needs it REJECTED, the witness needs it to
  PASS `-c`. Resolved per Sean's criterion — a witness must demonstrate a genuine limit of
  front-end checking, not a missing check — by adding
  `test/witness_zig_backend_literal.zbr`, whose asymmetry is permanent by construction.

---

### BUG-248: BUG-108's check was ABSENT from the selfhost, not merely unverified — FIXED 2026-08-04
- **Status:** Fixed. Pinned by `smoke_tc_fail test/bug108_this_outside_class_test.zbr`.
- **How it was found:** BUG-243 recorded that `bug108_this_outside_class_test.zbr` had
  **never run**. Running it showed the fix was not just unverified — it **was not there**.
- **Was:** the selfhost's `Expr.this_` branch returned `Type_.unknown_` in silence when
  `current_class` was empty. That is exactly the pre-BUG-108 behaviour the bootstrap fixed
  in May 2026. Since `zebra.exe` **is** the selfhost, the shipping compiler had no check:
  `var x = this` at top level passed `-c` cleanly and then failed inside emitted Zig with
  `use of undeclared identifier 'self'` — a Zig error, about generated code, for a mistake
  the front end could name exactly.
- **Fix:** emit the diagnostic, message copied **verbatim** from `src/TypeChecker.zig` so
  both compilers report identically (selfhost-equivalence rule).
- **Known shortfall, filed not hidden:** the span is `0:0` where the bootstrap says `6:13`.
  `Expr.this_` carries `zspan()`, the placeholder `Span(0,0,0,0)`, because
  `PNode.expr_this` is payload-less. Structural to fix — **BUG-249**.
- **The general lesson:** "regression fixture exists" and "regression fixture runs" are
  different claims, and only the second is worth anything. This one existed for three
  months while the thing it guarded was missing.

---

### BUG-247: a non-ASCII byte was reported as a character that is not in the source — FIXED 2026-08-03
- **Status:** Fixed. Pinned by `test/bug247_nonascii_diag_test.zbr` (`smoke_run_fail`).
- **Found by Sean**, 2026-08-03, reasoning from BUG-225: *"`Lexer.zbr:116` is `def peek():
  char` returning `src[pos]` — if we had unicode source files, we'd run into a risk here."*
  The hypothesis was right; the shape was not what either of us expected.
- **What was NOT wrong** (established first, by experiment):

  | case | result |
  |---|---|
  | non-ASCII in a **string literal** | ✅ `"café naïve"` round-trips, 12 bytes |
  | non-ASCII in a **comment** | ✅ works |
  | non-ASCII **char literal** `c'é'` | ✅ works, prints `é` |
  | non-ASCII **identifier** | ❌ rejected — correct, Zebra identifiers are ASCII |

  **There is no silent corruption of Unicode source.** The lexer copies bytes through
  strings and comments transparently, and every classification is an ASCII range
  comparison, so a high byte simply matches nothing and is rejected.
- **Was:** the rejection MESSAGE. `lexErr` renders `src[pos]` — a raw byte typed `char`
  (BUG-225's pathology) — with `.toString()`, widening lead byte `0xC3` to U+00C3. A user
  who typed `café` was told:

      2:12: unexpected character 'Ã'

  The column was right and **the character was fiction** — there is no `Ã` in the file.
  A reader then hunts for a character they never typed.
- **The bootstrap already had this right** (`unexpected character (byte 0xC3)`), despite
  the selfhost's comment claiming it "Mirrors src/Tokenizer.zig's diag handling". A
  selfhost-lags-bootstrap divergence in diagnostic quality.
- **Fix:** bytes above 0x7F get a message that is honest AND actionable —
  `unexpected non-ASCII byte — identifiers and operators must be ASCII (non-ASCII text is
  fine inside a string literal or a comment)`. No char→int conversion was introduced:
  none exists anywhere in the selfhost (every classification is a range comparison), and
  adding one for a diagnostic would be the wrong trade. Compared against `0x7F` rather
  than `0x80` because **`c''` is not a writable char literal** — a UTF-8 continuation
  byte is not a valid Unicode scalar.
- **Relationship to BUG-225:** this is that bug surfacing in the compiler's own UX. Fixing
  it does not fix BUG-225, which remains a language design decision (§5c of the quality
  audit) — but it removes the one place where the incoherence actively misleads a user.

---

### BUG-227: `str.tokenize(seps)` split on the SEQUENCE, not on any character — FIXED 2026-08-03
- **Status:** Fixed. Pinned by `test/bug227_tokenize_any_test.zbr`.
- **Was:** codegen emitted `std.mem.tokenizeSequence`, so `"a,b;c".tokenize(",;")` returned
  **one** token — the entire string — with no error at any stage. QUICKSTART documents
  "split on ANY character in `seps`".
- **Fix:** `tokenizeAny` at both selfhost dispatch sites. The implementation was changed to
  match the documentation rather than the reverse, because the documented behaviour is what
  makes `tokenize` distinct from `split` — `split` already covers the whole-sequence case
  and **deliberately keeps `splitSequence`** (verified unchanged: `"a<>b<>c".split("<>")`
  → 3, `"a,b;c".split(",;")` → 1).
- **Blast radius zero, as the ticket predicted:** no `.zbr` in the repo calls `str.tokenize`
  (the only `.tokenize(` hits are `Lexer.tokenize(src)`, an unrelated user method).
- **Bootstrap deliberately left on the old emit** — no selfhost source calls `str.tokenize`,
  so the selfhost-leads policy applies (same call as `Shell` earlier today).
- **The fixture uses MULTI-CHARACTER separators throughout**, which is the only input that
  distinguishes the two implementations: with a single-char `seps` they agree, so a test
  using `","` would have passed under the bug. Confirmed to FAIL against the unfixed
  compiler before being registered.

---

### BUG-245: QUICKSTART's `sys.go` examples never compiled, and `Shell.run` was unmigrated — FIXED 2026-08-03
- **Status:** Fixed. Smoke 288/288. Pinned by `test/bug245_shell_process_run_test.zbr`.

**Found 2026-08-03** while writing the §1b fixtures — by trying to follow the doc.

`QUICKSTART.md` is the **authoritative agent-facing reference**, and its entire
concurrency section wrote thread spawning as `sys.go(lambda …)`. Five code blocks, plus a
prose claim that "the lambda can capture variables from the enclosing scope". **None of it
compiled.**

| form, verbatim from the doc | result |
|---|---|
| `sys.go(lambda  var _ = total.add(1) )` | `'var' is a statement keyword and can't be used as an expression here` |
| `sys.go(lambda` + block | parse error **at `lambda`** |
| `sys.go(lambda t.add(1))` | parse error at `lambda` |
| implicit capture of an outer var | `'t' not accessible from inner function` |

`lambda` is **not a Zebra keyword at all**. Every occurrence of the word in the corpus is
in a *comment* describing lambdas conceptually; the syntax is `def(params)`, and captures
need an explicit `capture` block. `test/chan_thread_test.zbr` has always had it right.

**Why no gate could see it.** `doc_lint` checks that referenced *paths* and *tools* exist,
and prints its own uncovered list — the first entry of which is "prose claims about
BEHAVIOUR … needs an experiment". A code block that does not compile is exactly that. The
only instrument that finds this is someone running the examples.

**Fixed**: the concurrency sections now show `def()` + `capture`, each form verified by
running it. The shared-counter example was removed rather than translated, because it hits
**BUG-246**.

**Also fixed, same investigation — a real code defect** (`Shell.run`, gated by
`test/shell_test.zbr`): the selfhost emitted `std.process.Child.run(.{...})`, which does
not exist in Zig 0.16 — the allocator and `Io` are positional
(`std.process.run(_allocator, _io, .{...})`) and `max_output_bytes` is gone. Additionally
`Shell.run` had no TypeChecker arm, so its result typed as unresolved and no `str` method
would dispatch on it. **Third instance of the same pattern as BUG-241/242**: a namespace
with no run coverage was never exercised, so its Zig 0.16 migration never happened and
nothing could find out. The bootstrap still emits the stale form; not fixed there, per the
selfhost-may-lead policy — `Shell` is not used by any selfhost source.

---

### BUG-242: the entire `Csv` namespace was dead in the selfhost — FIXED 2026-08-03
- **Status:** Fixed. `csv_test` passes end to end; registered with `smoke_run`.
- **The ticket understated it.** It read "`Csv.` reading appears to work; it is the writer
  half that has no implementation". Reading did **not** work. `csv_test` failed at line
  **6** — `rowCount` — before it ever reached the writer at line 95. Nothing in the
  namespace worked; the two symptoms had different causes and had to be peeled in order:

  | # | fault | where |
  |---|---|---|
  | 1 | `CsvWriter()` emitted **verbatim** into Zig — no constructor | `CodeGen` bare-stdlib-ctor branch |
  | 2 | `_csv_writer_init` returned `.{ .buf = .{} }` — missing `capacity` | preamble, Zig 0.16 migration |
  | 3 | `Csv.parse` result had **no type**, so no method dispatched | `TypeChecker` namespace arm |
  | 4 | `build()` printed a **byte array** (`{ 97, 44, 98 }`) not a string | `TypeChecker` return type |
  | 5 | table local emitted `var`, never mutated → Zig error | `CgHelpers.isByValueHandleType` |
  | 6 | `_csv_parse` reassigned `.{}` to unmanaged ArrayLists (5 sites) | preamble, Zig 0.16 migration |
  | 7 | `HttpResponse.withHeader` missing entirely (csv_test uses it) | `TypeChecker` + `CodeGen` |

- **Fault 4 is the one worth remembering.** It produced *valid Zig that compiled cleanly*
  and printed the wrong thing — the BUG-226 class. `compile_check`, `full_sweep` and
  `divergence` would all have passed it at any corpus size. Only running the program shows
  it, which is why this landed with a `smoke_run` rather than a registration alone.
- **Faults 2 and 6 are the same missed migration**, and they explain the ticket's wrong
  reading: the Csv parser's *declarations* were updated to `.empty` but its in-loop
  *reassignments* were left as `.{}`. Nothing could reach the code to discover it, so a
  half-finished migration sat there looking complete. A scan of the rest of the preamble
  found no other instance.
- **The two halves have DIFFERENT histories** — established from `git log -S`, not inferred:

  | half | status | evidence |
  |---|---|---|
  | reader | **regression**, 2026-05-19 | `aef05d1 wip: partial Zig 0.16 upgrade (incomplete — 6 errors remain)` |
  | writer | **never worked in the selfhost** | `git log -S "_csv_writer_init" -- selfhost/CodeGen.zbr` returns NOTHING; the bootstrap has had it since `0e71d45` |

  Before `aef05d1`, `.{}` was correct and used *consistently* — declarations and
  reassignments alike. The migration converted the declarations and missed the
  assignments, and the reason is mechanical rather than careless: **`var x: T = .{}`
  carries its type and `x = .{}` does not**, so a migration keyed on the type annotation
  cannot see the assignment. Worth remembering the next time a Zig upgrade is done by
  pattern.

  The commit *announced* itself as unfinished. What was missing was not honesty but any
  instrument that would later ask whether the remaining errors ever got closed —
  `csv_test` would have answered on day one, and nothing ran it. Same root as BUG-243,
  reached from the other direction: the work was unfinished **in the open**.
- **The writer half is a class, not a one-off — and the class is now enumerated**, by
  `tools/unreachable_runtime.sh`. A runtime helper present in the preamble and emitted by
  `src/CodeGen.zig`, but emitted by *no* selfhost source, is unreachable from
  selfhost-compiled programs — which is also why its migration never happened. Validated
  non-circularly: run against the commit before this fix it lists exactly
  `_csv_writer_init` / `_csv_write_row` / `_csv_build`; run after, zero.

  **Result: 73 helpers, 72 of them `_stub_*`/`_gui_*`** — expected, not a finding, since
  `--gui-backend=*` delegates to the bootstrap by design. **Exactly one real entry
  remains: `_build_auto_run`**, which the bootstrap appends to the end of top-level `main`
  in build-script mode (`src/CodeGen.zig:4775`, `:6549`) and no selfhost source emits.
  Narrow, but the same shape — recorded here rather than fixed, since it needs its own
  look at whether the selfhost has a `build_mode` at all.
- **Design note — no new `Type_` variant.** The bootstrap has `.csv_table` / `.csv_row` /
  `.csv_writer`. The selfhost has none, and `Type_` is referenced 950+ times, so adding
  variants means auditing every exhaustive `branch`. Instead these dispatch on
  `Type_.named("CsvTable")` / `named("CsvWriter")`, which the type system already produces
  for unknown names. **CsvRow needed nothing at all**: `_csv_header`/`_csv_row` return
  `std.ArrayList([]const u8)`, which is exactly how `List(str)` is represented, so rows are
  typed `List(str)` and inherit `.at()`/`.len` from the existing list arm.
- **Test:** `smoke_run test/csv_test.zbr "csv_test: all assertions passed"` — a behaviour
  check, not a compile check: it writes a comma-bearing field, re-parses the output and
  compares, so RFC 4180 quoting is exercised round-trip.

---

### BUG-241: `Progress.` has not compiled since Zig 0.16, and nothing noticed — FIXED 2026-08-03
- **Status:** Fixed. Smoke 282/282 (adds `progress_test_run`).
- **Was:** `selfhost/stdlib_preamble.zig` called `std.Progress.start(.{})`, but Zig 0.16's
  signature is `pub fn start(io: Io, options: Options) Node` — verified against
  `lib/std/Progress.zig:588`, not inferred. Every program touching `Progress.` failed to
  build with `member function expected 1 argument(s), found 0`.
- **Fix:** `std.Progress.start(_io, .{})`. `_io` is already a preamble global used
  throughout (`std.Io.Timestamp.now(_io, .awake)`), so this is a one-argument change with
  no plumbing. `Node.start(name, estimated_total_items)` was unchanged, so
  `_progress_root.start(label, _total_u)` needed no edit.
- **Why nothing caught it:** `test/progress_test.zbr` carried **no** smoke registration of
  any kind, so no gate ever touched it. The heavy sweeps gate against a **baseline**, and a
  file that has never passed is not in the pass set — so it could not go red however broken
  it was. This is the BUG-243 class; `tools/registration_check.py` now makes it a gate
  failure rather than a silence.
- **Test:** `smoke_run test/progress_test.zbr "done"` — asserts the deterministic **print**,
  not bar rendering: `std.Progress` detects a non-tty and renders nothing under the gate
  runner, so an expectation written against bar output would never match.
- **Verification:** the fix was confirmed in the **emitted artifact** (`zebra_rt.zig:3621`
  contains `std.Progress.start(_io, .{})`), not from `rebuild.sh` reporting OK — the
  preamble is embedded into the bootstrap at *build* time, so a regen that runs before the
  rebuild emits the old runtime and every gate downstream measures it.

---

### BUG-120: selfhost — `.add()` → `.append()` rewrite fires on user class method calls via lowercase vars — FIXED 2026-05-07
- **Status:** Fixed. Bootstrap 5/5, smoke 64/64.
- **Was:** `selfhost/codegen.zbr` `.add()` heuristic only guarded on `isUpperCase(receiver_name)` (BUG-061). Lowercase instance variables (`c: Calc`) passed the guard, so `c.add(2, 3)` was incorrectly emitted as `c.append(_allocator, 2)`.
- **Fix:** Consult `InferCtx` at the call site before rewriting. If `inferExpr(m.object, infer_ctx)` returns `Type_.named(nc)` with `nc.len > 0`, the receiver is a class instance — skip the rewrite. The InferCtx pre-walk in `genMethod` already seeds all local variable types (params + inferred vars), so this works for annotated params, unannotated vars initialised with class ctors/method returns, and chained calls.
- **Test:** `test/profile_attr_test.zbr` — calls `c.add(2, 3)` where `c: Calc`; workaround method rename (`addValues`) reverted back to `add`.

---

### BUG-118: selfhost — struct construction emits `Struct.init()` with no init method — FIXED 2026-05-05; synthetic init 2026-05-06
- **Status:** Fixed. Bootstrap 5/5, smoke 52/52.
- **Was:** `Point(x: 1, y: 2)` emitted `Point.init(1, 2)`. Plain structs have no `pub fn init`; only classes (and structs with `cue init`) do.
- **Fix (2026-05-05):** `genCall` in `selfhost/codegen.zbr` now tracks two separate StrSets: `struct_names` (all structs) and `struct_with_init` (structs with `cue init`, including all cross-module exposed structs). Plain structs (in `struct_names` but not `struct_with_init`) emit `Struct{ .field = val }` literal syntax. Added `declMembersHaveInit` helper to avoid unused-binding Zig error.
- **Enhancement (2026-05-06):** Both backends now emit a synthetic `pub fn init(fields...) StructName { return .{ ... }; }` in `genStruct` for every plain struct (no explicit `cue init`). This normalises all struct definitions — `StructName.init(...)` is now always callable. The call site continues to use struct literal syntax (order-independent) for construction; the synthetic init is available for Zig interop and future uniform-construction refactors.
- **Test:** `test/bug118_struct_ctor_test.zbr` — constructs `Point(x: 3, y: 4)` and `RGB(r: 255, g: 128, b: 0)`.

---

### BUG-117: `List.join(sep)` — inverted args in selfhost + TC return type gap in bootstrap — FIXED 2026-05-05 (selfhost) + 2026-05-12 (bootstrap)
- **Status:** Fixed in both compilers. Bootstrap 5/5, smoke 92/92.
- **Was (selfhost):** `items.join(sep)` emitted `std.mem.join(_allocator, items, sep.items)` — separator and slices swapped, `.items` on separator.
- **Fix (selfhost, 2026-05-05):** `genMemberCall` `join` arm now emits separator first: `std.mem.join(_allocator, sep, items.items)`.
- **Was (bootstrap):** `inferInstanceMethodReturn` didn't handle `join`, so `var x = list.join(sep)` inferred `x` as `.unknown`. Consequently, calling `.split()` on the join result used literal pass-through, emitting `x.split(...)` which doesn't exist on `[]const u8`.
- **Fix (bootstrap, 2026-05-12):** Added `if (std.mem.eql(u8, method, "join")) return .string;` in `TypeChecker.inferInstanceMethodReturn` so join result is typed `.string`, enabling downstream `.split()` dispatch.
- **Test:** `test/bug117_list_join_test.zbr` — joins `["alpha", "beta", "gamma"]` with `", "`, then splits newline-joined result.

---

### BUG-116: `char.isAlpha()` / `char.isDigit()` / `char.isWhitespace()` + `StringBuilder.appendChar` not dispatched — FIXED 2026-05-05 (selfhost) + 2026-05-12 (bootstrap)
- **Status:** Fixed in both compilers. Bootstrap 5/5, smoke 92/92.
- **Was (selfhost):** Char methods fell through to pass-through path, emitting invalid `u21.isAlpha()` Zig.
- **Fix (selfhost, 2026-05-05):** Added char dispatch block before the string methods section in `genMemberCall`. Detects `Type_.char_` receiver via `inferExpr` and emits `std.ascii.isAlphabetic(@as(u8, @truncate(c)))` etc. Covers: `isAlpha`, `isDigit`, `isWhitespace`, `isUpper`, `isLower`, `toUpper`, `toLower`. Mirrors `genCharMethod` in `src/CodeGen.zig`.
- **Was (bootstrap):** `StringBuilder()` constructor call returned `.unknown` from `TypeChecker.inferCall` (no special case). So `var sb = StringBuilder()` had inferred type `.unknown`, and `sb.appendChar(...)` fell through to a literal method call — generating `sb.appendChar(...)` which doesn't exist on `std.ArrayList(u8)`. Additionally, the TC-inferred fallback switch in `genExprCall` was missing `.string_builder`.
- **Fix (bootstrap, 2026-05-12):** Added `StringBuilder()` special case in `TypeChecker.inferCall` (mirrors `CsvWriter`, `CodeEditor`). Added `.string_builder` arm to TC-inferred fallback switch in `src/CodeGen.zig` (line ~10971).
- **Test:** `test/bug116_char_methods_test.zbr` — counts alpha/digit/space chars, tests isUpper/isLower, verifies toUpper via StringBuilder.

---

### §19: Selfhost TC diagnostics — SHIPPED 2026-05-05
- **Status:** Shipped in `selfhost/typechecker.zbr` + `selfhost/main.zbr`. Compat test 2/2 PASS, bootstrap 5/5.
- **Was:** `selfhost/typechecker.zbr` had inference-only infrastructure (no `errors` list, no `addErr`, no print path). Type mismatches in the selfhost pipeline were only caught after codegen by the downstream Zig compiler, producing `path:LINE:` (no col) format errors.
- **Fix:** Added `Diagnostic{file,line,col,message}` struct, `InferCtx.errors: List(Diagnostic)` + `addErr/hasErrors/errorMessages`, `isPrimitive/typesCompatible` predicates, and `checkVarDecl/checkStmts/checkDecl/checkModule` walk. Wired into `main.zbr` step 4.5 (after ASTBuilder, before codegen). Selfhost now emits `path:LINE:COL: error: type mismatch: expected int, found str` at TC time.
- **Scope:** Concrete primitive mismatches only (int/bool/char/float/str). Named/enum types deferred — enum not tracked in ModuleTypes; would false-positive without full registry.
- **Test:** `test/selfhost_compat/run_compat.sh` updated to PASS when selfhost catches an error with col but bootstrap backend doesn't (known gap: bootstrap error comes from Zig compiler post-codegen).

---

### BUG-102: Selfhost typechecker `to!` force-unwrap audit — FIXED 2026-05-06
- **Status:** Fixed. All 41 `to!` sites in `selfhost/typechecker.zbr` are now guarded. Bootstrap 5/5, smoke 44/44.
- **Was:** `selfhost/typechecker.zbr` had ~41 `to!` force-unwrap operations in various states of guardedness. Several appeared unguarded. A nil at any unguarded `to!` is a hard panic with no diagnostic.
- **Fix:** Full audit of all 41 sites:
  - 20 converted to `if x as v` (idiomatic) — applies to `String?`, `List(Stmt)?`, `Type_?` same-file locals and cross-module fields where the bootstrap TC tracks optionality correctly
  - 21 kept as `if x != nil: ... to!` with `# safe:` annotation — required for cross-module `TypeRef?` and `^Expr?` fields, which the bootstrap TC does not track as optional (pre-existing gap)
- **Note:** The TC gap where `TypeRef?`/`^Expr?` cross-module fields aren't inferred as optional is a separate issue from BUG-102. The guarded `to!` pattern is the correct workaround for those 21 sites.

---

### BUG-099: Type `.unknown` three-way split — FIXED 2026-05-05 (Zig) + 2026-05-06 (selfhost)
- **Status:** Fixed in `src/TypeChecker.zig` (2026-05-05) and `selfhost/typechecker.zbr` (2026-05-06). Bootstrap 5/5, smoke 44/44, full test suite.
- **Was:** `Type.unknown` / `Type_.unknown_` overloaded three semantically distinct cases: context-dependent (nil, result), opaque-by-design (zig_lit, generics), and unresolved (TC gave up). Downstream checks couldn't distinguish them, so `var x: int = undefined_call()` silently typechecked.
- **Fix (Zig):** Three-way split into `.context_dependent`, `.unknown`, `.unresolved: Ast.Span`. Alarm bell fires at `checkVarDecl`. See commits `429ff98` → `fe61ebe`.
- **Fix (selfhost):** `Type_` union gains `context_dependent` and `unresolved`. Twelve `inferExpr`/`walkStmt` sites reclassified: nil inner + result outside return + if-capture defaults → `context_dependent`; ident/member/call/index/slice/expr fallbacks → `unresolved`; intentional opaque cases unchanged (`unknown_`). `isAbstractType()` helper mirrors `isAbstract()`. Alarm bell added to `checkVarDecl` behind `InferCtx.strict` (enabled by `typecheck-merge` only; off for normal compilation to avoid false alarms on TC gaps not yet closed). `codegen.zbr` format-spec falls through for all three abstract variants.
- **Closed as side effects:** BUG-105 (enum_member/union_variant → parent type), BUG-106 (literal element-type homogeneity), BUG-108 (partial — `this` outside class defensive emitError).

---

### BUG-105: `Color.red` infers to `.unknown` instead of `.named(Color)` — FIXED 2026-05-05
- **Status:** Fixed in `src/TypeChecker.zig:inferMember`. Test: `test/bug105_enum_member_test.zbr`, `test/bug105_union_variant_test.zbr`. See commit `f254b75`.
- **Was:** `inferMember` returned `.unknown` for enum-member and union-variant access (`Color.red`, `Result.ok(...)`). Downstream `var c: int = Color.red` silently typechecked.
- **Fix:** `inferMember` now returns `Type{ .named = parent_sym }` when the member resolves to an enum member or union variant. `var c: Color = Color.red` typechecks; `var c: int = Color.red` correctly errors.

---

### BUG-106: Heterogeneous list literals `[1, "two"]` silently typecheck — FIXED (partial) 2026-05-05
- **Status:** Literal homogeneity check shipped. Cast-validity check deferred. Test: `test/bug106_heterogeneous_list_test.zbr`. See commit `fe61ebe`.
- **Was:** `list_lit`, `array_lit`, `dict_lit` inferred to `.unknown` without checking element type consistency. `[1, "two", 3]` was silently accepted.
- **Fix:** Element-type walk now requires mutual `isAssignable` for non-abstract element types. Heterogeneous literals error at the offending element's span. Numeric mixes `[1, 2.0, 3]` still pass (untyped-numeric semantic). Cast-validity check (line 1693 — `42 as ClassType` still typechecks) deferred — separate scope, lower priority.

---

### BUG-108: Silent `.unknown` at `this` outside class — FIXED (partial) 2026-05-05
- **Status:** `this`-outside-class diagnostic shipped. Other sites deferred. Test: `test/bug108_this_outside_class_test.zbr`. See commit `01296db`.
- **Was:** `this` used outside a class/struct method or `with` block silently returned `.unknown` with no diagnostic.
- **Fix:** `this` outside valid context now emits "'this' used outside a class/struct method or 'with' block" at the `this` token span.
- **Remaining (deferred):** `inferMember` cross-module miss softened to `.unknown` (false-positive risk on legitimate patterns); index/slice on non-indexable; `expr_types.get` fallbacks with legitimate non-error cases.

---

### BUG-111: Compound assign `.field += 1` — NOT-A-BUG 2026-05-05
- **Status:** Closed as not-reproduced. Verified 2026-05-05 in both backends.
- **Was (reported):** `this.count += 1` / `.count += 1` suspected to fail; zero occurrences in repo suggesting users avoided the form.
- **Verified:** `.count += 1`, `this.count += 1`, `obj.count += 5` all parse, codegen, and run correctly. The zero-occurrence data was stylistic legacy (authors wrote `this.X = this.X + 1` before `.field` shorthand was canonical), not a compiler limitation.

---

### BUG-112: `def name: T` no-paren shorthand removed from grammar — FIXED 2026-05-05
- **Status:** Fixed 2026-05-05. Grammar rule removed from both backends. 38-site sweep done. Bootstrap 5/5. See commits `2f7e767` (grammar removal) + `598a533` (38-site sweep).
- **Was:** `def name: T` and `def name(): T` were both legal. The no-paren form was a vestige of the removed `prop`/`get`/`set` machinery — visually contradicted call-site syntax (callers always write `obj.name()`).
- **Fix:** No-paren rule removed from `src/Parser.zig` and `selfhost/parser.zbr`. All 38 occurrences across 17 files swept to `def name(): T`. Style guide §1 Q2 updated to reflect canonical form.

---

### BUG-113: Slice TC loses `str` type through `var` binding — NOT-REPRODUCED 2026-05-05
- **Status:** Closed as not-reproduced. Verified 2026-05-05.
- **Was (reported):** `var text = src[0..3]` suspected to infer something other than `str`, requiring explicit `: str` annotation for `.toFloat()` to dispatch. Author comment in `pratt_calc.zbr:132–134` documented this workaround.
- **Verified:** Both the annotated and unannotated forms produce identical output. The TC improvement (likely via BUG-099 work) resolved the underlying inference gap. The `pratt_calc.zbr` annotation is now redundant but harmless — left in place.

---

### BUG-087: `ensure` defer fires on the error path of throws functions — FIXED
- **Status:** Fixed 2026-04-27 in both backends. `_ensure_armed` flag set only on the success path; defer check gated on the flag. Tests: `contract_result_throws_test.zbr`, `contract_ensure_falloff_test.zbr`.
- **Was:** A throws function with an `ensure` clause that raised mid-body caused the ensure check to fire on the error path. Result: program panicked with "ensure failed in '<fn>'" and the user's `try/catch` never saw the original exception. Zig `defer` runs on both success and error returns, but `genEnsureBlock` emitted a plain `defer { if (!(expr)) panic; }` with no success-vs-error discrimination.
- **Fix:** `var _ensure_armed = false;` local at function entry. Set `true` on the success path (right before normal `return _result;` in functions with `result`-capable ensure, or right before any normal return otherwise). Defer check wrapped in `if (_ensure_armed and !(expr)) panic;`.
- **Discovered:** while implementing `result` capture (NEXT_STEPS item #11). Closed as a side effect of the `result`-keyword work — same flag mechanism delivers both features.

---

### BUG-019: `fn_ref` assignment missing `&` prefix in selfhost codegen — FIXED
- **Status:** Fixed 2026-04-23 in `selfhost/codegen.zbr`. `isTopLevelMethod` + `&` prefix paths in `genLocalVar`/`genAssign`. Test: `test/fn_ref_test.zbr`.
- **Was:** `selfhost/codegen.zbr` lacked the fn-ref detection that `src/CodeGen.zig` has. Mutable local vars initialised from a bare top-level function name (e.g. `var pred = isAlpha`) emitted Zig `var pred = isAlpha;` which Zig rejects: *"variable of type 'fn(u21) bool' must be const or comptime"*. The Zig backend had this via `tc_init_type == .fn_ref`; the selfhost lacked parity.
- **Fix:** added `isTopLevelMethod()` scanner over the current module's `module_decls`. Mutable fn-ref locals emit `var pred: @TypeOf(&isAlpha) = &isAlpha;`; reassignment emits `pred = &isDigit;`.
- **Known limitation (deferred):** `isTopLevelMethod()` only scans the current module. Cross-module fn-ref (`var cb = OtherModule.func`) still emits without `&` in selfhost. Not yet seen in practice; refile if it lands.

---

### BUG-002: `guard` + `try_postfix` runtime error propagation — CLOSED (test quality)
- **Status:** Closed 2026-04-23. Tests fixed by adding explicit `try/catch` wrapping. Per memory log + NEXT_STEPS reference table.
- **Was:** Two tests (`guard_test`, `try_postfix_test`) panicked at top level rather than catching propagated errors. Symptom A: `checkPositive` raised inside a guard `else` block; top-level `try Main.main()` panicked with `error: ZebraError`. Symptom B: `safeDiv(10,0)?` propagated through `main throws`; test exited non-zero.
- **Resolution:** Behaviour was correct per Zebra's error semantics — propagation up to `main` does panic if uncaught. The tests were testing propagation without explicit `try/catch` boundaries; adding the wrapping made them validate the propagation path without panicking. No compiler change needed.

---

### BUG-098: `name in some_list` always routed to `std.mem.indexOf(u8, …)` — FIXED
- **Status:** Fixed in `selfhost/codegen.zbr`. Bootstrap 5/5, smoke 43/43.
- **Was:** The `in` operator only specialised for `@[…]` tuple literals on the right; List(T) / HashMap(K,V) variables fell through to the substring path, which emitted `std.mem.indexOf(u8, container, needle)` — Zig rejected because `indexOf` takes a `[]const T` slice, not an `ArrayList`.
- **Fix:** `BinaryOp.in_` now routes to the existing `_zebra_in` runtime helper (which handles ArrayList + HashMap + tuple via comptime dispatch) when the right operand is:
  - `Expr.array_lit` (the existing case)
  - `Expr.list_lit` (newly recognised — `[a, b, c]` literals)
  - `Expr.ident` whose name is in `list_locals` / `hashmap_locals`
  - or any expression whose TC type is a `.named` symbol named `"List"` / `"HashMap"` (covers field accesses)
- **Companion fix:** `genLocalVar` now adds `n.name` to `list_locals` (and `list_str_locals` when the first element is str-typed) for `var x = [a, b, …]` declarations — without that, downstream `.count()`, `.at()`, and `in` dispatches missed list-locals that came from a `[…]` literal rather than a `List(T)()` ctor.
- **Regression test:** `["alice", "bob"]` etc. round-trip through `examples/lambda_calc.zbr` (which uses `name in list` pervasively after this fix).
- **Discovered:** 2026-04-30 while writing `examples/lambda_calc.zbr`.

---

### BUG-095: class field defaults aren't auto-applied — `cue init` left fields as Zig `undefined` — FIXED
- **Status:** Fixed in `selfhost/codegen.zbr` `genInit`. Bootstrap 5/5, smoke 43/43.
- **Was:** When a `cue init` body didn't explicitly assign a class field that had a declared default (`var hits: int = 0`), the un-assigned field was emitted as Zig `undefined` — producing the poison value `0xAAAA…AAAA` which silently overflowed in subsequent arithmetic. The synthetic-default-init path (used when a class has no user-written `cue init`) already pre-filled defaults; the explicit-init path didn't.
- **Fix:** `genInit` now walks `owner_members` for `Decl.var_` entries with a non-nil `init_expr` and emits `_self.field = <default>;` *before* running the user's `cue init` body. The user's body may overwrite those defaults — that's fine and matches the bare-class semantics. Same pre-fill is also added for body-less `cue init` declarations.
- **Reproducer:** `class Counter { var hits: int = 0; var misses: int = 0; cue init(): pass }` — `c.hits + c.misses` now prints `0` instead of `-6148914691236517206`.
- **Discovered:** 2026-04-30 while writing `zebra-tools/book_run.zbr`'s pass/fail counters.

---

### BUG-091: `List(T)` / `HashMap(K,V)` parameter receiver is `*const` — `.add()` rejected by Zig — FIXED
- **Status:** Fixed in **both** `src/CodeGen.zig` (Zig backend) and `selfhost/codegen.zbr` + `selfhost/cg_helpers.zbr` (selfhost). Per-equivalence rule. Bootstrap 5/5; smoke 43/43.
- **Was:** Passing a `List(T)` as a function parameter and calling `.add()` on it emitted `*const ArrayList(...)` (Zig parameters are always const), and `append` (which takes `*Self`) was rejected with "cast discards const qualifier".
- **Fix:** Mutation-driven param-pointering. New helper `paramNeedsAddrOf` returns true when the param's type is `List(T)` / `HashMap(K,V)` AND the body's `scanMutations` set contains the param name. `genMethod` emits the param as `*std.ArrayList(...)` in that case; the call-site emit (`genArgs` in src; `genArgListNamed` + the class-method member-call path in selfhost) emits `&` for the corresponding arg. `addAddrOfMutationsInStmts` (a parallel pass alongside `scanMutations` in `genStmts`) marks the caller's local as `var` so `&items` is `*ArrayList`, not `*const ArrayList`.
- **Why mutation-driven (not blanket):** Existing selfhost code (441 `: List(...)` param sites) is reads-only; flipping the calling convention everywhere would have a large blast radius. The mutation predicate isolates the change to sites that actually need it.
- **Selfhost port:** added `paramNeedsAddrOf` + `isContainerTypeRef` to `cg_helpers.zbr`; added `lookupFnBody`, `addAddrOfMutationsInStmts/Expr`, `*` prefix in `genParamList`, `&` prefix in `genArgListNamed` and `genMemberCall` member-method path; small TypeRef.named "StrSet" → `strset_locals` registration so a typed `var ms: StrSet = scanMutations(...)` round-trips. Both the call-site `&` emit and the addr-of mutation-marking pass cover three dispatch shapes: static (`Class.method`), self (`this.method`), and instance (`var.method` resolved via `inferExpr` against the per-method `InferCtx`).
- **Regression tests:** `test/bug091_list_param_test.zbr` (static `Main.fillX(items)`) and `test/bug091_dispatch_test.zbr` (`this.helper(items)` and `f.helper(items)` instance shapes with assertions). Both pass through `zebra-bootstrap.exe` (Zig backend) and `zebra.exe` (selfhost).
- **Discovered:** 2026-04-29 while writing `book_lint.zbr` (Phase 3 dogfooding tools).

---

### BUG-092: `var lines: List(str) = s.split("\n")` didn't auto-collect SplitIterator — FIXED
- **Status:** Fixed in **both** `src/CodeGen.zig` `genLocalVar` and `selfhost/codegen.zbr` `genLocalVar`. Bootstrap 5/5.
- **Was:** Assigning `content.split("\n")` to a `List(str)`-annotated local annotated the slot as `std.ArrayList([]const u8)` but the RHS emitted `std.mem.splitSequence(...)` — a Zig type mismatch.
- **Fix:**
  - **Zig backend** (`src/CodeGen.zig`): New branch in `genLocalVar` emits the iterator + while-loop drainer alongside the const/var declaration.
  - **Selfhost** (`selfhost/codegen.zbr`): same pattern but emitted as a single labeled-block initializer (`blk_N: { var _ll_N = …; while (…) |…| _ll_N.append(…); break :blk_N _ll_N; }`) so the form works regardless of the outer const/var decision. Also added "lines" to `isReadOnlyMethod` in `cg_helpers.zbr` so a downstream `s.lines()` call doesn't spuriously mark `s` as mutated.
- **Coverage:** Both `split(sep)` and `lines()` are handled via the same path (both return iterators in Zig). Untyped `var x = s.split(...)` for-loop iteration is unchanged (still drives the iterator directly).
- **Regression test:** `test/bug092_split_to_list_test.zbr`, passes through both backends.
- **Discovered:** 2026-04-29 while writing `book_lint.zbr`.

---

### BUG-082: Selfhost `inferExpr` returns `unknown_` for cross-module constructor calls — FIXED
- **Status:** Fixed — `selfhost/typechecker.zbr` `inferExpr` Expr.call/Expr.member branch; `test/bug082_test.zbr` + `test/bug082_lib.zbr`. Bootstrap 5/5.
- **Was:** `var b = SomeMod.SomeClass(args)` gave `b` type `unknown_` in selfhost TC; downstream method-return format strings emitted `{any}` instead of `{s}`, printing raw bytes.
- **Fix:** In `inferExpr`, when receiver resolves to `unknown_` and the member name is a known dep class, return `Type_.named(mem.member)`.

---

### BUG-029: Class field init with non-int-valued HashMap defaults to i64 — FIXED
- **Status:** Fixed in selfhost — resolved incidentally during selfhost implementation
- **Was:** `this.field = HashMap()` on a field declared `HashMap(str, T)` for non-int `T` emitted `std.StringHashMap(i64).init(_allocator)` in the Zig-backend compiler. Root cause: Zig-backend `genAssign` resolved field types only for `.ident` targets or `.member` with `.ident{name="self"}`, bailing out for `this.` which parses as `.member { object: .this }`.
- **Fix:** Selfhost `getAssignFieldType` uses `getMemberFieldName` which handles `Expr.member` generically (returns `m.member` for any member expression). Combined with `genCallWithTypeHint`, emits the correct Zig type.
- **Regression test:** `test/hashmap_this_field_test.zbr`

---

### BUG-030: `.contains()` on param-of-class HashMap field emits List.contains — FIXED
- **Status:** Fixed in selfhost — resolved incidentally during selfhost implementation
- **Was:** `param.field.contains(key)` where `param` is a local of a class type and `field` is `HashMap(K,V)` generated incorrect contains dispatch in the Zig-backend compiler.
- **Fix:** Selfhost `genCall` dispatches `.contains()` on all non-string receivers via `.contains(key)` — correct for Zig HashMap. The `getMemberFieldName`-based path handles chained member access.
- **Regression test:** `test/hashmap_param_field_test.zbr`

---

### BUG-001: Static method calling static method emits `self.` prefix — FIXED
- **Status:** Fixed (prior session — TCO work fixed bare static method calls)
- Was: `testHelper()` inside a static method generated `self.testHelper()`.
- Now: emits `ClassName.methodName()` correctly for static→static calls.

---

### BUG-003: HTTP `serve` fails on Windows with "comptime call of extern function" — FIXED
- **Status:** Fixed 2026-04-09
- Was: `_Ctx` struct stored `handler: Handler` where `Handler = @TypeOf(handler)` is a bare function type (comptime-only in Zig). Made the entire struct comptime-only, so `page_allocator.create(_Ctx)` triggered the `NtAllocateVirtualMemory` comptime path.
- Fix: Declare `const _HFn = *const fn(HttpRequest) HttpResponse` and coerce `const _fn: _HFn = handler` before `_Ctx`. Store `handler_fn: _HFn` in `_Ctx` (fn-pointer = runtime type). Call `ctx.handler_fn(_req)` directly. All three HTTP routes verified working on Windows.

---

### BUG-004: `padLeft/padRight/center` — fill char `'*'` passed as string to `u8` param — FIXED
- **Status:** Fixed 2026-04-08
- Was: `_pad_left(s, n, "*", alloc)` failed — `"*"` is `*const [1:0]u8`, not `u8`.
- Fix: Changed pad helpers to accept `anytype` fill; added `_pad_fill` normaliser that handles both char literals (comptime_int) and 1-char strings (pointer).

---

### BUG-005: `{d:0>N}` format adds `+` prefix to positive `i64` in Zig 0.15 — FIXED
- **Status:** Fixed 2026-04-09
- **Context:** DateTime preamble `_dt_to_iso8601` and `_dt_format` used `i64` fields with `{d:0>N}` format spec. Zig 0.15.2 adds a `+` sign to positive signed integers when using fill-aligned format (e.g. `{d:0>4}` for `i64 = 1970` → `+1970`).
- **Fix:** Cast all date fields to unsigned types (`@as(u32, ...)`, `@as(u8, ...)`) before passing to `bufPrint`/`allocPrint`. Unsigned integers never receive a sign prefix.
- **Broader note:** This is a Zig 0.15 breaking change from 0.14. Any future preamble code that formats `i64` values with fill-aligned specs should cast to unsigned first.

---

### BUG-007: `String + String` string concatenation not handled — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `+` operator on strings fell through to the numeric `else` branch in `genBinary`, emitting `(a + b)` which Zig rejects for `[]const u8`. TypeChecker also rejected `String + String` as arithmetic.
- **Fix:**
  - TypeChecker `inferBinary`: added `if (e.op == .add and lt == .string) break :blk .string` before the numeric guard.
  - CodeGen `genBinary`: added dedicated `.add` case — if left operand is string, emits `_str_concat(a, b, _allocator)`.
  - Preamble: added `_str_concat(a, b, alloc)` using `std.mem.concat`.

---

### BUG-008: Mutation scanner — `.unknown` TC type caused spurious `var` — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** When `tc.resolve.exprs` had no entry for an ident used as a method receiver, `inferIdent` returned `.unknown`, which the scanner conservatively treated as always-mutating.
- **Fix:** Removed the `if (obj_type == .unknown) break :blk true` conservative path. Added `if (obj_type == .string) break :blk false` guard. These fixes together fix `string_methods_test` and `sys_test`.

---

### BUG-009 (a): Escape analysis — field writes not propagated — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `propagateEscapesOnce` only traced `var y = <expr>` alias chains. Storing into a returned struct's field (`result.items = list`) didn't escape `list`.
- **Fix:** Added `.assign` handling in `propagateEscapesOnce`: if target is `obj.field` and `obj` is escaped, all idents in RHS are added to the escaped set.

---

### BUG-009 (b): `opt?.field` emits `try opt.?.field` inside `if opt != nil` guard — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `opt?.x` inside an `if opt != nil` block generated `try opt.?.x` instead of `opt.?.x`.
- **Fix:** TypeChecker now populates `optional_unwraps`. `exprHasTry` and `genExpr` both consult `optional_unwraps` instead of `expr_types`.

---

### BUG-010: Partial class — duplicate method silently appended — FIXED
- **Status:** Fixed 2026-04-09
- **Was:** `mergePartialInto` concatenated all members from a partial without checking for name conflicts.
- **Fix:** `mergePartialInto` now scans for duplicate method names before merging. Duplicates emit a clear warning and the partial definition is skipped.

---

### BUG-011: `tcTypeAnnotation` — comprehensive type annotation for `var` locals
- **Status:** Fixed 2026-04-09
- **Fix:** Replaced ad-hoc 6-case inline switch with `tcTypeAnnotation(t, alloc)` — a dedicated module-level function mapping all `TypeChecker.Type` variants to Zig annotation strings.

---

### BUG-012: `_type_id` uninitialized for classes without explicit `cue init` — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** Classes with no explicit `cue init` were constructed via `ClassName{}` (struct literal), leaving `_type_id` uninitialized.
- **Fix:** `genClass` now emits a synthetic default `pub fn init() ClassName` that explicitly stamps `self._type_id = _tid_ClassName`. Constructor call site updated to emit `ClassName.init()`.

---

### BUG-013: `collectEnumMembers` — blank-line leaf detection used structural comparison — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `if (kids[1] != .leaf)` relied on an implementation detail of blank-line productions.
- **Fix:** Replaced with the named helper `isMeaningfulNode(tn: TN) bool`.

---

### BUG-015: `scanMutationsInto` missing `.assert` case — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** Method calls inside `assert` conditions were never scanned, causing the receiver to be emitted `const`.
- **Fix:** Added `.assert => |s| try scanMutationsInExpr(s.cond, set, tc_opt)` to `scanMutationsInto`.

---

### BUG-016: `inferMember` didn't unwrap optional type before member lookup — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `inferMember` only looked up fields/methods when `obj_type == .named`. For `n?.next` (where `n: ?Node`), TC type was `.optional(.named(Node))` — lookup silently returned `.unknown`.
- **Fix:** Added `resolved_obj_type = if (obj_type == .optional) obj_type.optional.* else obj_type` before the `.named` member lookup.

---

### BUG-018: Top-level `def` referenced inside class method set `uses_self = true` — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `refsInExpr` set `uses_self = true` for ANY `.method` symbol, including top-level `def` functions.
- **Fix:** `refsInExpr` now checks `sym.decl.method.is_top_level`; top-level methods do NOT set `uses_self`.

---

### BUG-020: `branch/on` call-expr pattern emitted wrong Zig — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `on SomeUnion.variant() as x` in a `branch` on-clause fell through to `genExpr(v)` which emitted the union constructor form, not a valid Zig switch pattern.
- **Fix:** Added `else if (v.* == .call and v.call.callee.* == .member)` branch in `genBranch`'s union pattern path.

---

### BUG-021: Struct `cue init` stamped `_type_tag` (class-only field) — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `genInit` always emitted `self._type_tag = _ttag_StructName` for any `cue init` body.
- **Fix:** Added `is_struct_owner: bool = false` to Generator. `genInit` wraps the stamp in `if (!g.is_struct_owner)`.

---

### BUG-022: `boxed_variants` not cloned in `cloneInterface` — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `cloneInterface` didn't clone the `boxed_variants` map. Re-imported modules received empty `boxed_variants`, silently skipping boxing expressions.
- **Fix:** Added full key/value clone loop for `boxed_variants` in `cloneInterface`.

---

### BUG-023: Multi-line `cue init` blocked by indentation validator — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** `processIndentation` checked indentation on EVERY line including continuation lines inside open parentheses.
- **Fix:** Added `paren_depth: u32 = 0` tracking to Tokenizer. `processIndentation` returns early when `paren_depth > 0`.

---

### BUG-024: `throws` auto-propagation missing — FIXED
- **Status:** Fixed 2026-04-10
- **Was:** Calling a `throws` method from inside a `throws` method required explicit `?` suffix on every call.
- **Fix:** Added `current_method_throws: bool = false` to Generator. Auto-emits `try ` prefix for three call paths (bare-name, self-method, cross-module). Added `suppress_auto_try` flag to prevent double `try try`.

---

### BUG-025: `scanMutationsInExpr` didn't recurse into `.try_` nodes — FIXED
- **Status:** Fixed 2026-04-11
- **Was:** `localVar.method()?` — the `?` wraps the call in a `.try_` node which wasn't recursed into, so `localVar` was never added to the mutated set.
- **Fix:** Added `.try_ => |e| try scanMutationsInExpr(e.expr, set, tc_opt)` to `scanMutationsInExpr`.

---

### BUG-028: Zebra (Zig-backend) emits pointer addresses into identifier names — FIXED
- **Status:** Fixed 2026-04-17 (commit 8debe0a)
- **Was:** Generated `.zig` contained identifiers like `_box_2376b6287c0` — live pointer addresses. Every run produced different names, so output was non-deterministic.
- **Fix:** Generator carries a monotonic `box_counter_ptr`; all 27 `@intFromPtr(node)`-based name sites route through `Generator.nextUid()`.

---

### BUG-031: Selfhost `except` codegen emits `.*` on value-typed subject — FIXED
- **Status:** Fixed 2026-04-17
- **Was:** `x except { f = v }` where `x` is a local value (not a pointer) emitted `var _except_tmp = x.*;` — `.*` is only legal on a pointer.
- **Fix:** `selfhost/codegen.zbr` gen path for `Expr.except_` now emits `.*` only when the base is `Expr.this_` in a method body.

---

### BUG-032: Selfhost codegen.zbr emits `.remove` unconditionally as `.orderedRemove` (List form) — FIXED
- **Status:** Fixed 2026-04-17 (commit ff87add)
- **Fix:** `.remove` dispatch now discriminates HashMap vs List receiver via new `hashmap_locals` + `fieldIsHashMap` infrastructure. HashMap emits `_ = obj.remove(key)`; List keeps `_ = obj.orderedRemove(@intCast(idx))`.

---

### BUG-033: Selfhost `.contains()` on class-field HashMap emits `List.contains` form — NOT REPRODUCED
- **Status:** Not Reproduced 2026-04-17
- **Investigation:** Built reproducer with `class Reg` holding `HashMap(str,int)` field, called via `self.by_name.contains(k)`. Selfhost emits correctly (HashMap `.contains` path). BUG-032's walker work evidently already covers this receiver shape.

---

### BUG-034: Selfhost emits cross-module union construction as struct call — FIXED
- **Status:** Fixed 2026-04-17 (commit ff87add)
- **Fix:** `generateModuleWith` now consults `deps_mt.hasUnion(exposed_name)` before the hard-coded heuristics. The allow-list stays as a fallback for the single-file emit path.

---

### BUG-036: Selfhost HashMap field `[key]` subscript emits array-index with bogus `@intCast` — FIXED
- **Status:** Fixed 2026-04-18 (commit 242394a)
- **Fix:** `genExpr` for `Expr.index` and new `genHashMapAssign` method detect HashMap receivers via `hashmap_locals`/`fieldIsHashMap`: reads emit `.get(k).?`, writes emit `.put(k, v) catch @panic("OOM")`. `scanMutationsInto` updated to mark index-assign base as mutated. `genHashMapAssign` extracted as a method to avoid a nested-branch `.*`-deref bug in the Zig backend. Bootstrap A/B byte-identical.

---

### BUG-038: Selfhost emits `int.toString()` as codepoint-to-UTF8 encode, not integer-to-decimal — FIXED
- **Status:** Fixed 2026-04-18 (commit 443886d)
- **Fix:** `genMemberCall` in `codegen.zbr` now calls `inferExpr(m.object, infer_ctx)` before choosing the toString emit path. `Type_.char_` receivers → utf8Encode; all others → `std.fmt.allocPrint`. Enabled by typechecker fix: `walkStmt` for_in pre-pass detects `for c in s.chars()` via `isCharsCallExpr()` and binds the loop var as `Type_.char_`, preserving that binding after the body walk.

---

### BUG-039: Selfhost mutation scanner marks string-method receiver as `var` — FIXED
- **Status:** Fixed 2026-04-18 (commit 443886d)
- **Fix:** Added missing string methods to `isReadOnlyMethod()` in `cg_helpers.zbr`: `reverse`, `padLeft`, `padRight`, `center`, `toHex`, `fromHex`, `repeat`, `replace`, `isAlpha`, `isNumeric`, `isValidUtf8`.

---

### BUG-041: `^ClassType?` emits `?**T` instead of `?*T` (root cause) — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** `src/CodeGen.zig::genType .ref_to` arm: when `^T`'s inner payload is a class, emit `*ClassName` / `?*ClassName` directly and skip the recursive `genType` call. Class auto-boxing already provides the pointer; `^` is a representation no-op for classes.

---

### BUG-045: Ctor-arg boxing wraps `^Class?` args in extra `*` — FIXED
- **Status:** Fixed 2026-04-17 (`a5e082b`) — Zig backend only; selfhost was already correct via Phase 17c walker.
- **Fix:** `genBoxedArgExpr` in `src/CodeGen.zig` short-circuits when the payload is a class and falls through to plain `genArgExpr`.

---

### BUG-047: Field-read + field-assign on `^Class?` emitted stale boxing after BUG-041 fix — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** Three parallel class-payload short-circuits in `src/CodeGen.zig` — `.member` field-read, `StmtAssign` self-ref boxing, `StmtAssign` `ref_box_type_name` path — each now checks class vs non-class payload before applying boxing.

---

### BUG-048: Selfhost resolver does not register enum names — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** Added `on PNode.enum_ as e` arm to `bindTopDecl` in `selfhost/resolver.zbr`, mirroring the existing `union_decl` arm.

---

### BUG-049: Selfhost parser drops field initializers — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** `PField` struct gained `init_expr as List(PNode)`; `parseDeclField` parses optional `= .parseExpr()`; `astbuilder.zbr::buildMember` threads `f.init_expr` into the `DeclVar` init slot.

---

### BUG-050: Selfhost branch-on drops multi-pattern lists and inline-else — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** `PBranchOn.patterns` (was `pattern`); `parseBranchStmt` loops collecting comma-separated patterns; else arm handles inline `else, stmt` form; `buildBranch` iterates all patterns.

---

### BUG-051: Selfhost genRaise drops the 2-arg `raise msg, details` form — FIXED (primitive + string paths)
- **Status:** Fixed 2026-04-17 (object path emits `@compileError` fail-loud, pending future port)
- **Fix:** `parseRaiseStmt` collects optional `, expr` details; `genRaise` ported primitive + string emission paths from `src/CodeGen.zig`. Added `nextUid()` to `Writer` class.

---

### BUG-052: Selfhost parseUnary drops the `try expr` prefix form — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** `parseUnary` gained a `try` branch — consume `try`, recurse with `parseUnary()`, wrap in `PNode.expr_try(operand)`.

---

### BUG-053: Selfhost parseAtom rejects the `zig"..."` / `zig'...'` backend literal — FIXED
- **Status:** Fixed 2026-04-17
- **Fix:** Added `expr_zig_lit as str` PNode variant; `isZigLit()` helper; `parseAtom` arm; `astbuilder.zbr::stripZigQuotes` + `on PNode.expr_zig_lit` arm.

---

### BUG-055: Selfhost parsePostfix drops `expr.get(args)` / `expr.post(args)` method calls — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New branch in `parsePostfix` after the `isOpenCall` check: when peek text is `"get"` or `"post"` and `peekAt(1).text == "("`, treat it as a method call — consume the keyword, consume `(`, reuse `parseCallArgs()`.

---

### BUG-056: Selfhost parser rejects `r"..."` / `r'...'` raw string literals — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** Added `isRawString()` helper, new `PNode.expr_raw_str as str` variant, new `parseAtom` arm. `astbuilder.zbr` new `stripRawAndEscape(text)` helper + arm.

---

### BUG-057: Selfhost parseStmt rejects `arena` scope blocks — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PArenaScope` holder struct, `PNode.stmt_arena_scope as ^PArenaScope` variant, `parseArenaScopeStmt`, astbuilder arm.

---

### BUG-058: Selfhost parseStmt rejects `with target` contextual-self blocks — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PWith {target, stmts}` struct, `PNode.stmt_with`, `parseWithStmt`, astbuilder arm with `rewriteWithStmt` desugaring bare assigns to member accesses on target.

---

### BUG-059: Selfhost parseStmt rejects `guard ... else` blocks — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PGuard {cond, else_stmts}`, `PNode.stmt_guard`, `parseGuardStmt` (supports both block and inline `, stmt` forms), astbuilder arm.

---

### BUG-060a: Selfhost parseOr drops the `orelse` binary op — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `POrelse {expr, fallback}`, `PNode.expr_orelse`, extended `parseOr` loop with `orelse` check, astbuilder arm.

---

### BUG-060b: Selfhost parseExpr drops the `->` pipeline operator — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PPipeline {lhs, rhs}`, `PNode.expr_pipeline`, `parsePipeline` wrapper (left-associative while-loop on `->`), astbuilder arm desugars `lhs -> f(args)` → `f(lhs, args...)`.

---

### BUG-061: Selfhost `genMemberCall` rewrites `ClassName.add(...)` to List.append — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** Added `is_class_ref = isUpperCase(add_nm)` guard alongside existing `is_strset` check. `.add → .append` rewrite skips uppercase class-style identifiers.

---

### BUG-062: Selfhost parseTopDecl rejects the `namespace` keyword — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PNamespace {name, decls}`, `parseNamespaceDecl`, astbuilder arm, `generateEntryPoint` extended to find `main` inside namespaced classes.

---

### BUG-063: Selfhost parseWhileStmt rejects `while var id = init, cond` bind-and-guard — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** Parse-side desugar — `while true { var id = Init; if not Cond: break; ...body }`. Zero AST/codegen changes.

---

### BUG-064: Selfhost parseTopDecl rejects the `interface` keyword — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PNode.interface_ as ^PClass`, `parseInterfaceDecl`, astbuilder arm, `bv.add("PNode.interface_")` in `addCrossModuleBoxedVariants`.

---

### BUG-065: Selfhost parseTopDecl rejects the `extend Type` keyword — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PExtend {target_name, members}`, `parseExtendDecl`, astbuilder arm, `bv.add("PNode.extend_")`, `genExtMethod` updated for `"String"` alias.

---

### BUG-066: Selfhost eatTypeName rejects sized numeric type names (int32/uint8/float32/byte/uint) — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** Added `isSizedTypeName()` helper; extended `eatTypeName`; added `"byte" → "u8"` to `zigTypeForName`.

---

### BUG-067: Selfhost parseMemberDecl rejects the `get name as T` computed-property form — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PProperty {name, type_name, getter_stmts}`, `parsePropertyDecl`, `buildProperty`, `bv.add("PNode.property_")`.

---

### BUG-068: Selfhost parser rejects generic-arg `?` suffix and `name:` labeled call args — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** (a) Generic-args loop in `eatTypeName` now peeks for `?` after each arg and folds it in. (b) `parseCallArgs` consumes `name:` label before the expression.

---

### BUG-069: Selfhost parser missing `expr is TypeName` type-check — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** `parseComparison` gained `else if this.textIs("is")` arm; `astbuilder.zbr` intercepts `pb.op == "is"` and emits `Expr.type_check`; `bv.add("Expr.type_check")`.

---

### BUG-070: Selfhost parser missing `var {x, y} = expr` struct/tuple destructuring — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `PDestruct {names, init_expr, is_struct}`, `parseDestructStmt`, `ast.zbr` gained `is_struct as bool` on `StmtDestruct`, astbuilder arm, `bv.add("PNode.stmt_destruct")`, `genDestruct` uses `nextUid()` + branches on `is_struct`, `resolveStmt` arm added.

---

### BUG-071: Selfhost TypeChecker misses string-method return types; str.count(substr) unimplemented — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** New `stringMethodReturn(name)` function in `typechecker.zbr`; `inferExpr` for `ExprMember` switched to recursive `inferExpr(mem.object)` + `Type_.string_` dispatch arm; `codegen.zbr` gained `str.count(substr)` emit path; `blk_box` typed via `std.meta.Child(@FieldType(...))`.

---

### BUG-072: Tokenizer suppresses EOL/INDENT/DEDENT inside parens — statement-body lambdas fail — FIXED
- **Status:** Fixed 2026-04-18
- **Fix:** 5-field state machine in `src/Tokenizer.zig` and `selfhost/Lexer.zbr` (`in_lambda_params`, `lambda_param_depth`, `after_lambda_params`, `lambda_body_active`, `lambda_indent_level`). `parseLambdaExpr` extended to handle both expression-body (`= expr`) and statement-body (eol + indent block) forms.

---

### LANG-001: Top-level `def` not supported — FIXED 2026-04-10
- **Status:** Fixed
- `TopDecl → MethodDecl` production added; `AstBuilder.zig` handles `MethodDecl` case setting `is_top_level = true`; `CodeGen.zig` skips `self.`/`ClassName.` prefix for top-level methods.

---

### LANG-002: `on X return Y` inline form and blank-line sensitivity — FIXED 2026-04-10
- **Status:** Fixed
- Added `BranchOnClause → kw_on Expr kw_return Expr eol` production; `BranchOnList → BranchOnList eol` production to handle blank lines.

---

### LANG-003: `^T` heap-indirection type for recursive structs — ADDED 2026-04-10
- **Status:** Implemented
- `var next as ^Node?` declares heap-allocated pointer. `^T` emits `*T` in Zig; `^T?` emits `?*T`. Auto-boxed on assignment.

---

### LANG-004: Cross-module TypeRef resolution — ADDED 2026-04-10
- **Status:** Implemented (extended from MVP to full TC inference)
- `ModuleInterface` tracks exported type names; `Resolver` handles dotted names; TypeChecker added `.cross_module` Type variant.

---

### LANG-005: `^T` auto-boxing for cross-class field assignments — FIXED 2026-04-10
- **Status:** Fixed
- `genClass` now uses `withClass(n)` for ALL concrete classes. `ref_box_type_name` extended for `localVar.field = x` targets.

---

### BUG-040: Selfhost `print` emits `{}` instead of `{s}` for strings — FIXED 2026-04-19
- **Status:** Fixed in selfhost `genPrint` and `genStringInterp`
- `genPrint` now calls `isStringBoth(expr, "print")` to emit `{s}` for string expressions. `genStringInterp` similarly uses `isStringBoth(e, "interp_fmt")` for interpolated parts. Also fixed: `genStringInterp` now emits `catch @panic("OOM")` instead of `try` (correct for Zebra non-throws context).

---

### BUG-042: Selfhost cross-module struct ctor missing `.init` — FIXED 2026-04-19
- **Status:** Fixed in `selfhost/codegen.zbr::genCall`
- Added `dep_types.hasClass(cm_mem)` check alongside `isCrossModuleCtorCall`. Now detects `Mod.ClassName(args)` as a cross-module struct constructor for any class in the dependency module types, emitting `Mod.ClassName.init(args)`.

---

### BUG-043: Selfhost `Mod.Union.variant(v)` emits fn-call not struct-init — FIXED 2026-04-19
- **Status:** Fixed in `selfhost/codegen.zbr::genCall` via `getXmUnionParts` helper
- Added `getXmUnionParts(callee)` top-level helper that detects 3-part `Mod.Union.variant` callee shapes. `genCall` calls it and emits `Mod.Union{ .variant = value }` with boxed-payload support.
- **Implementation note:** A nested `branch outer_m.object on Expr.member` was attempted but the Zig backend doesn't auto-deref `^Expr` fields in nested branch subjects (TC annotation not consulted for switch subject in method context). Workaround: standalone helper function where TC correctly annotates direct branch bindings.

---

### BUG-044: Selfhost cross-module branch pattern collapses variant tag to union type name — FIXED 2026-04-19
- **Status:** Fixed in `selfhost/astbuilder.zbr::buildBranch`
- `buildBranch` now handles 3-part dotted patterns (e.g. `test_lib.Value.num`) by building a nested member chain: `Expr.member(Expr.member(Expr.ident("test_lib"), "Value"), "num")`. Previously, only 2-part patterns were handled, causing `Mod.Union.variant` to collapse to `.Union`.

---

### BUG-074: `Result.ok` / `Result.err` constructor syntax — REMOVED 2026-04-19
- **Status:** Removed from language and compiler
- `Result(T, E)` as a language-level generic type is removed. Both the Zig compiler (`src/CodeGen.zig`, `src/TypeChecker.zig`) and the selfhost port (`selfhost/codegen.zbr`, `selfhost/resolver.zbr`) had their Result-specific handling excised. The `_Result` preamble helper, `genResultMethod`, and `genResultCall` are all deleted. Test files `result_test.zbr` and `result_methods_test.zbr` (which exercised the constructor syntax) are deleted. Bootstrap: 5/5 steps pass, byte-identical round-trip.

---

### BUG-006: `zig"..."` expression statement emits double semicolon — FIXED both sides
- **Status:** Fixed — Zig backend 2026-04-17; selfhost fixed 2026-04-20 (Phase 20)
- `zig"some_stmt;"` inside a method body emitted `some_stmt;;` — the zig literal already ends with `;`, and `genStmt` for `.expr` always appended another `;`.
- Zig-side fix: `src/CodeGen.zig::genStmt` `.expr` case detects trailing `;` on `zig_lit` content and skips the appended `;`.
- Selfhost fix: `selfhost/codegen.zbr::genStmt` `on Stmt.expr` now checks `if e is Expr.zig_lit`: emits content, adds `;` only if content doesn't already end with `;`.

---

### BUG-035: Selfhost parser has no atom handler for `doc_string_line` (`"""..."""` multi-line strings) — FIXED
- **Status:** Fixed Phase 20 (2026-04-20)
- `selfhost/parser.zbr:1885` handles `isDocString()` → `PNode.expr_str(text)`.

---

### BUG-037: Selfhost corpus-failure triage — RESOLVED 2026-04-19
- **Status:** Closed — corpus reached 100% (149/149) via BUG-048 through BUG-073 grammar wave.

---

### BUG-046: Selfhost partial-class sibling file merge — FIXED 2026-04-19
- **Status:** Fixed — committed 2026-04-19
- Added `mergePartials_pmodule` in `selfhost/main.zbr`. Key detail: `"" + psrc_raw` copies the read buffer into permanent arena storage before parsing (Zig 0.15 `File.read` defer can rewind arena).

---

### BUG-075: `String + str` concat not routed through `_str_concat` in selfhost TypeChecker — FIXED
- **Status:** Fixed Phase 20 (2026-04-20)
- Extended `isString(t)` in `selfhost/typechecker.zbr` to accept `Type_.cross_module` where `cm.type_name == "String"`.

---

### BUG-076: `if x is Union.variant |r|` capture binding not in TypeChecker `narrowed_types` — FIXED
- **Status:** Fixed — `isCaptureLookup` 3-way payload lookup in TypeChecker.zig; selfhost walker narrowing in typechecker.zbr; `genIsCaptureThen` ptr_field_bindings seeding in codegen.zbr; bootstrap 5/5.

---

### BUG-077: TC doesn't record inferred type for `?`-propagated throws-call assignments — RESOLVED
- **Status:** Not reproducing — resolved indirectly by BUG-076 + Phase 20 typeFromRef fix (2026-04-21). Verified both `src/TypeChecker.zig` and `selfhost/typechecker.zbr` correctly propagate through `.try_` nodes.

---

### BUG-078: `^ClassName` in union variant double-boxes (`**T`) — FIXED
- **Status:** Fixed — `src/Resolver.zig::walkUnion` emits a hard error when payload is a class type. Test: `test/bug078_double_box_test.zbr` (intentional-error fixture).

---

### BUG-080: `^T?` field assignment — CLOSED NOT REPRODUCING
- **Status:** Closed 2026-04-21. Verified: `n.next = n2` where `next: ^Node?` generates correct `n.next = n2;` — BUG-047 class short-circuit in `genAssign` and `field_needs_deref` both correctly suppress the `.*` for class-typed optional ref fields.

---

### BUG-280: field names were not escaped for Zig keywords — FIXED 2026-08-11 (both compilers)

**Found 2026-08-09** freeing reserved words under U4a. Bootstrap fixed earlier the same
day as the selfhost (`bda5090`); selfhost half and the gate registration completed
2026-08-11.

```
class C
    var align: int = 0
```
```
error: expected type expression, found 'align'     # in the EMITTED Zig
```

`align`, `packed`, `opaque`, `volatile`, `threadlocal`, `anyframe` and `noalias` are Zig
keywords that **Zebra never reserved**. All seven are legal Zebra identifiers, and all
seven failed as class fields — live for code a user could write at the time.

**TWO DEFECTS, and only one was the live bug.**

1. **The field paths never called `emitName`.** `emitName`/`zigSafeName` has always
   escaped correctly — which is why `var align = 1` as a *local* worked all along. The
   field, constructor, struct-literal and member-access paths simply did not call it.
   **This was the whole live bug, and it is what was fixed.**
2. `isZigKeyword` is a hand-maintained 37-entry list against Zig's own 46, missing
   `try`, `catch`, `orelse`, `if`, `else`, `while`, `for`, `return`, `break`,
   `continue`, `and`, `or`. **All twelve are ALSO Zebra keywords**, so the gap bites
   nothing today — it matters only because `try` cannot be freed until it is closed.
   **STILL OPEN.** (`std.zig.Token.keywords` is the derivable oracle, but do NOT reach
   for it from the selfhost through a `zig"..."` literal — that couples codegen to a
   stdlib internal inside the one construct the lints are structurally blind to. Hand-
   list both, and gate the comparison.)

**THE SITE MAP WAS DERIVED, AND THAT IS THE POINT.** Reading the source found **four**
sites. Emitting a probe that uses a keyword field in every position, and grepping the
output, found **nine**:

| site | found by |
|---|---|
| instance field declaration (class, struct, generic — three class-emit paths) | reading |
| constructor init `self.x = ...` | reading |
| member access `c.x`, read and write — the keystone, one site covers many symptoms | reading |
| reflection strings `&.{"align"}` — **must stay bare**, it is data | reading |
| **synthesised constructor parameter** `pub fn init(align: i64)` | **the probe** |
| **struct-literal designator** `.{ .align = align }` — designator *and* parameter | **the probe** |
| **static field declaration** `pub var align: i64` and `C.align` | **the probe** |
| **`except` temp-copy** `_tmp.align = 11` | **the probe** |
| **named-arg struct literal** `Point{ .align = 7 }` | **the probe** |

A tenth surfaced during the bootstrap fix: five interface-typed locals were missing the
escaping too — a latent instance of the same bug nobody had reported.

**THE TWO COMPILERS NEEDED DIFFERENT SITE COUNTS, which is why "scope by function" was
the rule rather than a blanket replace.** 18 sites in `src/CodeGen.zig`, 18 in
`selfhost/CodeGen.zbr`, but not the same 18 — they differ by structure at four places:

| function | bootstrap | selfhost | why |
|---|---|---|---|
| `genFieldDecl` | 3 | 2 | the bootstrap has two `pub <kw> <name>` branches |
| `genStruct` | 2 | 3 | the selfhost writes designator and parameter separately |
| `genType` | 4 | 6 | the selfhost carries extra nilable-of-nilable branches |
| capture fields | 4 (`genCaptureClosureStructMode` + `genLambda`) | 2 (`genLambdaEx` only) | one emit path, not two |
| `except` temp-copy | 2 (`genVarExcept` + `genAssignExcept`) | 1 (`genExpr` `except_`) | folded into the expression |
| synthesised class-init field default | 0 | 1 | selfhost-only emit: `self.align = 0;` |

**The one trap worth remembering** is in `genFieldDecl`. A module-scope var gets the
`_zbr_mv_` prefix (BUG-137), and `emitName`'s own contract forbids
prefix-concatenation — `_zbr_mv_@"align"` is invalid Zig, and the prefix already makes
the name collision-free. So the escape applies to the un-prefixed branch only. A
blanket replace would have emitted the broken form; in the bootstrap a broad replace
matched **seven** sites where three were expected, and checking each is what made it
safe.

**Verification.** `bash tools/keyword_ident_check.sh` — now a QUICK-tier gate — and
`test/bug280_keyword_idents.zbr`, registered with `smoke_run`, which RUNS the program
rather than only emitting it (`6 v / 9 / 7 8 / 11 / 3n`, identical from both compilers;
an escaping bug that swapped two fields would still compile). Over-escaping was checked
separately by diffing a pre-fix against a post-fix emit: every changed line is a keyword
acquiring `@"…"` and nothing else, and the reflection strings `&.{"align", "volatile"}`
are absent from that diff — they must stay bare, and no gate can see it if they don't.

**What this fix does NOT cover: see BUG-281.** Three further emit families — `@derive`
bodies, the type name itself, and a capture read inside a lambda body — still emit bare
keywords **in both compilers**. `keyword_ident_check.sh` reported the bootstrap clean
throughout, which is its declared limit ("the fixture is the coverage") arriving with a
receipt. The claim in `bda5090` that the bootstrap emits "zero bare keywords" was true
of the fixture, not of the compiler.

**Freeing `error`/`try` is still blocked** on defect 2 above, and requires flipping the
Parser tests that currently assert those words are rejected.
