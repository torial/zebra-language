<!-- doc-status: historical -->
# Zebra — Changelog

All notable changes to Zebra. Most-recent entries first.

**TWO NUMBERINGS, deliberately kept apart (2026-09-14).** The `[0.1]` … `[0.15]` sections
below are the feature MILESTONES the language was built in (April–May 2026): each named a
batch of work, and none was a downloadable release. The first tagged, downloadable release
is **0.9.0** (`v0.9.0-rc1_zig0.16`, 2026-09-11) — numbered for where the language stands
against its 1.0 stability promise, not for where the milestone count had reached. So a
stranger reading "0.9.0-rc2" next to a "[0.15]" heading is looking at two different
scales, and this note is here so that the first issue filed against the release is not
that one. Release sections are headed `## Release X.Y.Z`; milestone sections keep their
original `## [0.N]` headings because this file is append-only history and rewriting them
would falsify it. Everything under a milestone heading is IN every release.

Zebra is a compiled language: changes land in the bootstrap compiler
(`src/`) and the self-hosted compiler (`selfhost/`) together. "Both
compilers" means both are updated and round-trip identical output is
confirmed via `tools/bootstrap_check.sh`.

---

## Release 0.9.0 — rc1 2026-09-11 (`e9b7ef2`), rc2 2026-09-12 (`62b4387`)

The first release meant for someone other than its authors: one folder per platform
(Windows, Linux; macOS experimental) with the compiler, the Zig 0.16 it was built with,
`QUICKSTART.md` and `examples/`, plus `install.ps1` / `install.sh` and `SHA256SUMS.txt`.
`zebra --version` names both versions. Cut by the `release` workflow on a tag matching
`_zbr_version`; the FULL gate tier ran green in CI on the rc2 tree once the Windows CRLF
checkout hazards were pinned (`.gitattributes` `* text=auto eol=lf`).

Contains every milestone below plus the 2026-06 → 2026-09 work that had no milestone
heading: the self-hosted compiler as the shipping compiler (the bootstrap frozen as regen
authority), the N-1 anchor regression witness, the LSP and `zebra debug` DAP relay, the
`tui` and `libui_ng` GUI backends, `zebra test`, `zebra fmt`, `--shared` libraries and
`DynLib`, bitwise operators, `Set(T)`, dict/set literals, the pipeline `->` into
leading-dot methods (BUG-417), always-explicit `?` on throws calls (§28b), refined
diagnostics with positions (BUG-288), and ~180 fixed bugs (BUG-230 … BUG-426; the
ledger is `BUGS_FIXED.md`). rc2 differs from rc1 only in the release/CI fixes.

Post-rc2, on main and headed for 0.9.1 or 1.0: `StringBuilder.build()` non-consuming
(BUG-351); `Math.abs(int)` signed (BUG-424); `extend str` resolves (BUG-425); a
typed-param expression lambda is passable as a `sig` (BUG-426); the derived stable
surface `docs/SURFACE.md` and its `surface-freeze` gate; `test/boundary/trip.zbr`;
**`zebra up`** (`--check`, `--to VER`) — the installed release updates itself: checksum
verified, previous version kept once (surface: +`zebra up`, +`--to`); **`defer` and
`errdefer` freed** as identifiers (surface: −2 keywords; they were reserved, implemented
only in the bootstrap, and refused by the shipping compiler); a parameter named like a
top-level def no longer takes the function's address (BUG-427); macOS builds are no
longer marked experimental (the rc2 smoke ran green on `macos-latest`); **the `String`
alias of `str` is removed** (2026-09-15, Sean: "nuke String") — one type, one spelling;
the parser refuses `String` wherever a type is read and names `str` (rewrite is the one
token; `extend String` → `extend str`); **`b.requires("^1.0")`** — a build.zbr states the
compiler range it was tested against and is refused by name, in the front end, outside it
(surface: +1 Build method); **the runtime object receivers are closed tables** (Timer,
StringBuilder, SysProcess, Build/BuildTarget, Ws/Tcp/Udp conns, Sqlite*, CodeEditor, Gui,
HttpRequest, Chan, Regex): an unknown method is a Zebra refusal naming the set, not a Zig
error (surface: +16 receivers / +133 methods, all derived); it found QUICKSTART's
`t.elapsedMs()` naming a method that never existed (`elapsed()`).
**Bootstrap sunset Step 1** (2026-09-15, `docs/design/bootstrap_sunset.md`): the last three
delegations to `zebra-bootstrap` are retired — `--zig-backend`, `--gui-backend=glfw`
(refused by name; `tui`, `libui_ng` and the default `stub` remain) and `zebra debug --listen` (the DAP relay
is stdio-only) — so the compiler has one pipeline (surface: −2 flags, −2 command forms).
**`guard`, `arena`, `readonly`, `abstract`, `vari` freed as identifiers** (2026-09-15, Sean,
reading the book: guard "feels like it doesn't belong"): `guard` was `if not cond` with a
second spelling and an `else,` comma form; `arena`'s construct had been removed long ago;
`readonly` was parsed into a flag nothing read; `abstract` and `vari` were reserved for
features never built (surface: −5 keywords, 74 now). Rewrite: `guard c else` → `if not c`.
**`assert_eq`, `assert_ne`, `assert_true`, `assert_false` freed** (2026-09-15): one `assert`.
A plain `assert a == b` (any of `== != < <= > >=`) now names both operands on failure —
`assert failed at f.zbr:12: left == right -- left: 3, right: 4` — for every primitive
kind, and for two sides the checker cannot type it decides by type at runtime (so
`assert x == y` on untyped strings compares contents, as `assert_eq` did). Rewrite:
`assert_eq a, b` → `assert a == b`; `assert_true e` → `assert e`; `assert_false e` →
`assert not (e)` (surface: −4 keywords, 70 now).
**`same` freed** (2026-09-16): the undocumented self-typed interface parameter; an interface
names itself (`other: Comparable`) and a class names itself (surface: −1 keyword, 69).
**Generic interfaces** (2026-09-16, Sean: "let's prioritize for 1.0"): `interface Comparable(T)`
/ `class Score implements Comparable(Score)` / `var c: Comparable(Score)`. Emitted as a comptime
type function, one vtable per instantiation with the parameters substituted; the wrong
argument count is refused in the front end. Not yet: a generic class implementing a generic
interface, an interface extending a generic one. QUICKSTART §17.
**Interface values refuse unknown members; `where` constraints enforced** (2026-09-16):
a call through an interface-typed value -- plain or generic, `Comparable(Score)` is now
typed as the interface -- to a method the interface (or one it extends) does not declare
is a front-end error naming the methods; until now it reached zig. `class Sorted(T where
T implements Comparable(T))` is enforced at `Sorted(X)()` and at a `Sorted(X)` annotation
with T substituted; a primitive argument is refused by name. The clause had been parsed
and ignored since it was written.
**Generic classes implement interfaces, and their types are references** (2026-09-16):
`class Box(T) implements Show, Comparable(Box(T))` works, and a `Box(int)` instance
coerces to the interface from an identifier, an argument or a return -- until now only
the inline constructor form did (an identifier reached zig as an undeclared `_vtable_`
symbol). `Box(int)` spelled as a parameter or annotation is now `*Box(i64)` in Zig,
matching what the constructor returns; `def show(b: Box(int))` had refused its own
instances.
**Unused `as` bindings are a front-end error** (2026-09-16): a branch arm that binds a
payload it never reads is refused at the arm, with a position (`unused binding 'r' in
this arm`); it used to surface as Zig's "unused capture" with a line and no column. A
guarded arm and `as _` are exempt. Two emit defects in the if-chain branch form went
with it: a used binding discarded ("pointless discard") and `as _` emitted as `const _`.
**Bootstrap sunset Step 2**: the comparison tooling is retired to `tools/attic/` —
`selfhost-div` and `interp-escape` leave the gate tiers (49 daily / 41 full), `compile_check
--bootstrap` and the parity/scaling probes go, `mutation_check` regenerates via the
selfhost. `zig-test` stays until Step 3 deletes `src/`.
**Bootstrap sunset Step 3** (2026-09-16): `src/` -- the Zig-implemented compiler Zebra was
first written in, 16 files, 37,549 lines -- and the `zebra-bootstrap` build target are
deleted; `build.zig.zon` declares no dependencies (the Earley parser went with it), so a
clean clone builds offline. One compiler, `zebra`, which regenerates itself from its
committed emit (`tools/regen_recover.sh` is the recovery path for any commit in history).
The three gates whose oracle was `src/` retire with it (`zig-test`, `grammar-export` --
`grammar.txt` is frozen at the last export -- and `decl-exhaustive`; 46 daily / 38 full),
and `fuzz/harness.py` and `tools/dogfood` become validity sweeps rather than differential
ones. **`has` freed** as an identifier: only the bootstrap's grammar ever accepted the word
(a Cobra-era class attribute list); the selfhost never parsed it (surface: −1 keyword, 68).
The next release archive no longer contains `zebra-bootstrap`.
**Bootstrap sunset Step 4** (2026-09-16): the dead machinery behind every freed keyword is
gone -- the `defer`/`guard`/`assert_eq..false` statement forms and the `same` type in the
AST, their parser nodes, builder and codegen paths, 13 dead token variants, and two runtime
helpers (`_zebra_assert_cmp`, `_zebra_assert_bool`) that no program has emitted since
2026-09-15. No user-visible change; the sunset is complete.
**Cues** (2026-09-16, Sean: "the intention is for it to be the equivalent of the dunder
methods for python"): `cue` was only ever `init`. It now marks every method the compiler
calls for you -- `cue toString(): str` (print, `${}`), `cue equals(other: T): bool`
(`==`/`!=`, value not identity), `cue hash(): int` (`HashMap`/`Set` keys, through a hash
context that confirms by `equals`; requires `equals`), `cue compare(other: T): int`
(`<`..`>=` and `sort()`), and `cue iter(): I` / `cue next(): E?` (`for x in obj`, on the
object itself or on what `iter()` returns). The set is closed (Parser `CUE_NAMES`; an unknown
cue is refused naming the seven), shapes are checked at the declaration, and writing a cue
name as `def` is refused with the `cue` spelling. `@derive(Eq)` now generates `equals` by
value (was `eql(*const Self)`); the one corpus use of `.eql(` became `.equals(`. Rewrite:
`def toString` → `cue toString`. `cue deinit` is deliberately absent -- end-of-scope
teardown is an open 1.0 decision (NEXT_STEPS_to_1.0). QUICKSTART §5 "Cues"; surface: +1
section, `docs/SURFACE.md` "Cues (7)".
**Generators** (2026-09-16, Sean: "let's do the yield"): a top-level `def f(...): Iter(T)`
whose body uses `yield` is lowered to a class with `cue next` -- a resumable state machine
over the body's control flow (`if`/`while`/`for`, with `break`, `continue`, early `return`
and `for`/`else`), locals kept as fields. `for x in f()`, `f().next()`, and a generator
consuming another generator all go through the cue protocol; nothing is materialised.
`Iter(T)` is a return type only; `yield` outside a generator, a `return` with a value
inside one, and a yield under `branch`/`try`/`with`/`using`/`allocate` or `if x as y` are
refused by name. This is the producer half of the iterators gap (the .NET lazy-splitter
receipt in NEXT_STEPS_to_1.0). QUICKSTART §5 "Generators"; surface: +1 keyword (`yield`,
69).
**BUG-428** (2026-09-16): a backslash source path (`zebra src\app.zbr` from PowerShell)
resolved every `use` nowhere and compiled on silently against stale dependency output;
paths are normalised and an unresolvable `use` is now refused by name. `def next` /
`def iter` are ordinary methods again (only `cue next` makes a type iterable; zebra-ide's
DAP client has a `next()` command). Same day: `ZEBRA_LIBUI_PATH` emitted an absolute
`.path` into the scaffold's `build.zig.zon`, which zig refuses ("expected path relative to
build root"); it is now written relative to the scaffold directory -- the override's first
run on Windows.

## [0.15] — 2026-05 (in progress)

### Collection literal syntax `{…}` (§28f)

- **`{a, b, c}` is a set literal** → `Set(T)`, and **`{k: v, ...}` is a dict literal**
  → `HashMap(K, V)`, disambiguated by a `:` after the first element. Element/key/value
  types are inferred (or taken from a `var x: Set(int) =` / `HashMap(str,int) =`
  annotation). **`{}` is an empty dict** — a bare `{}` with no type context is an error,
  so annotate it (`var m: HashMap(str,int) = {}`). Both work in every position their
  collection value does (var-init, return, call arg, nested). See QUICKSTART §10.

### `Set(T)` — generic hash set (§28f)

- **New builtin collection `Set(T)`** — a set of unique, hashable elements, backed
  by a void-valued hash map (`std.StringHashMap(void)` for `str`, `std.AutoHashMap(T,
  void)` otherwise). API: `add(x)`, `contains(x)`, `remove(x)`, `len` / `count()`,
  `items()` → `List(T)`, `clear()`, plus `for x in set` iteration and the `x in set`
  membership operator. Works as a local, a by-pointer mutable parameter, a class
  field, a return value, and nested (`List(Set(int))`). Element type must be
  auto-hashable (same constraint as `HashMap` keys); `==` and `print(set)` are not
  supported. See QUICKSTART §10.

### Error propagation is now always explicit (`?`) — BREAKING

- **An omitted `?` on a `throws` call is a compile error** (§28b step 5). The
  legacy auto-propagation for same-file statement-position calls — the last place
  error propagation was implicit — is removed. Both compilers reject it with a
  source-located `throws call needs '?'` diagnostic (driver-level, after codegen,
  so a valid `try` is still emitted and the message is clean rather than a broken
  Zig compile). This closes the "invisible rule keyed to file boundaries" where
  moving a function between files silently changed call-site semantics.
- **Migration hatch:** `--allow-implicit-try` accepts the old implicit form for
  one release — a bridge for un-updated external code (e.g. a GameEngine build or
  ported scripts). The repository corpus was already fully explicit (441 sites
  swept 2026-07-02; `tools/check_explicit_try.sh` holds it at 0), so nothing
  internal changed. Biggest breaking change since the `arena` keyword removal.

### GUI: libui-ng backend (native OS widgets)

- **File dialogs** — `g.openFile()→str?`, `g.saveFile()→str?`,
  `g.openFolder()→str?`, `g.msgBox(title, msg)`, `g.msgBoxError(title,
  msg)`. The path-returning methods are typed as `str?`; use
  `if g.openFile() as path` to bind. All five backends wired; libui-ng
  uses `ui.Window.OpenFile/SaveFile/OpenFolder/MsgBox/MsgBoxError`.

- **`progressBar(label, f64)`** — 0–100% display widget; retained-mode
  correct via `_LuiMut.pb` cache entry. All five backends.

- **`combobox(label, List(str), int) → int`** — drop-down selector;
  `OnSelected` callback writes `sval`; frame-0 creation with item
  list. All five backends.

- **`spinbox(label, int, int, int) → int`** — integer spinner with
  min/max bounds; `OnChanged` callback. All five backends.

- **`beginPanel(id) / endPanel(id)`** — `uiGroup` titled border with
  inner VBox; retained-mode cached in `_lui_grp_cache`; `using g.hbox()`
  / `g.vbox()` factory methods work inside panels.

- **`beginHBox / endHBox` / `beginVBox / endVBox`** — horizontal and
  vertical layout boxes; `_GuiBackend` fn-ptr slots; stub, TUI, and
  libui-ng backends; `g.hbox(id, stretch)` / `g.vbox(id, stretch)`
  factory methods + `using` desugaring.

- **libui-ng ecosystem** — `torial/libui-ng` rebased onto kojix2 (111 bug
  fixes) + 46 C additions (float spinbox, file dialogs, placeholder text,
  `DrawBitmap` decl); `torial/zig-libui-ng` Zig 0.16 compat (`.c`
  callconv, `comptime` callback fixes); 9 new bindings (Tab.selected,
  Grid.delete/numChildren, Draw.Transform/Clip/Save/Restore,
  Entry/Combobox placeholder).

- **`--gui-backend=libui_ng`** — emits + scaffolds a native libui-ng `zig
  build` project. (Runtime was not actually achievable at this point — the
  upstream dependency did not compile under Zig 0.16. End-to-end runtime —
  `counter.zbr` opens a native Win32 window and its buttons work — was first
  reached 2026-07-27 after the Common-Controls manifest fix; see
  `docs/libui_ng_audit.md`.)

### GUI: MVU architecture

- **`Gui.run(title, w, h, init, update, view)`** — 6-arg MVU form
  replaces the 4-arg frame-callback form. `init()` → initial model,
  `update(model, msg)` → next model, `view(g, model)` → renders and
  calls `g.send(Msg)`. The runtime queues messages, calls `update`, and
  re-renders.

- **`g.send(msg: anytype)`** — type-erased send via `_send_fn`/`_send_ptr`
  fields in `GuiContext`. Can be called from `view()`.

- **ZebraIDE MVU rewrite** — `IDE/ZebraIDE.zbr` rewritten from 454-line
  frame-callback to 365-line MVU; 14-variant `Msg` union; background
  process polling in `view()` via `g.send()`.

### Language syntax cleanup (0.15)

- **`x!` postfix force-unwrap** — `x!` is equivalent to the existing
  `x to!`; supports chaining `x!.method()`. `to!` retained as alias.

- **`with OBJ` contextual self** — `with g` makes bare method calls like
  `text("hello")` desugar to `g.text("hello")`.

- **Removed `try expr` prefix** — this was a Zig syntax leak. Use `expr?`
  error-propagation instead; `try EXPR` still works inside `zig` blocks.

- **Inline single-line `if/else`** — `if x: y` and `if x: y else: z`.
  Colon required; `else if` chaining and next-line `else:` supported.

- **`Scope` interface check for `using`** — TC verifies the object passed
  to `using EXPR` has `def begin()` and `def end()`; structural typing;
  error names the missing method(s).

- **`is not` operator** — precedence documented and tested; `Expr4 > not >
  or` ordering confirmed for both compilers.

- **`using EXPR` scope blocks** — renamed from `in EXPR`; any object with
  `begin()`/`end()` works. Desugars to `{ const _t = EXPR; _t.begin();
  defer _t.end(); body }`. `kw_in` retained for `for`-in loops.

### Stdlib completeness (0.15)

- **`Http.serve(port, handler)`** — `std.http.Server` wrapper; exposes
  response writes; both backends.

- **`ThreadPool(n)`** — erased fn-ptr worker pool; `pool.submit(lambda)` +
  `pool.wait()`; bounded concurrency. Plain named type (not generic).

- **`Atomic(T)`** — wraps `std.atomic.Value(T)`; `add/sub/load/store/swap`
  operations; `Atomic(int)` / `Atomic(bool)`; both backends.

- **`SQLite`** — sqlite3.c amalgamation bundled at build time; `Sqlite.open
  / exec / query / begin / commit / rollback / close`; `row.asInt /
  asStr / asFloat / asBool`; `sqlite_row_list` iterable type.

- **`UDP`** — `Udp.bind(port)` / `Udp.socket()`; `sock.send / recv /
  close`; complement to `Tcp.connect`.

- **`Log` improvements** — `Log.json(level, msg, data)` JSON-lines format;
  `Log.setFile(path)` file sink.

- **`Crypto` additions** — AES-256-GCM `Crypto.encrypt / decrypt`; SHA-256
  key derivation (`Crypto.deriveKey`).

- **`Path.*`** — `join / dirname / basename / ext / extension / stem /
  isAbsolute / absolute`; wraps `std.fs.path`; `extension` is an alias
  for `ext`.

- **`Compress.gzip / gunzip`** — round-trip gzip compression via
  `std.compress.flate`.

- **`Tcp.serve(port, handler)`** — complement to `Tcp.connect`; per-connection
  handler.

### Zig 0.16 migration

- Core APIs: `ArrayList.empty`, `init: std.process.Init`, `_initIo` chain,
  selfhost `genMethod` fix.
- Net migration: TCP / WebSocket / HTTP serve ported from removed
  `std.net` / `std.posix` to `std.Io.net`.
- `_Chan(T)` updated to `std.Io.Mutex` / `Condition`; `_build_new` uses
  `.targets = .empty`.

---

## [0.14] — 2026-05

- **`<-` deep copy-out** — `_zbr_deep_copy` preamble helper; `List` and
  classes inside `allocate` blocks deep-copy on `<-` assignment;
  `HashMap` blocked by design.

- **`allocate` Slice 5** — `is_scoped` flag in copy-out; `allocate_depth`
  counter replaces `arena_depth`; scoped `Arena / Debug / FixedBuffer`
  copy correctly across scope boundaries.

- **`allocate` Slice 6** — `arena` keyword removed (soft deprecation with
  helpful diagnostic); `kw_arena` kept in lexer so the error message can
  guide migration to `allocate Arena()`.

- **`Chan(T)`** — `ch <- val` send, `var v <- ch` receive, `ch.close()`;
  `sys.go(lambda)` fire-and-forget goroutine-style threads; TC inference
  for `recv→?T`, `send/close→void`; QUICKSTART §35.

---

## [0.13] — 2026-05

- **Visibility enforcement** — `private / public / internal / protected`
  parsed and enforced; TC error when a private member is accessed outside
  its owning class; `internal` excluded from cross-module interface
  tables.

- **`^T` boxing edge cases** — `List(^T).add(val)` heap-boxes struct
  values in both compilers; `for item in List(^T)` via Zig auto-deref;
  method-chain temporaries fixed (BUG-027/079).

---

## [0.12] — 2026-05

- **ZebraIDE self-hosted** — `IDE/ZebraIDE.zbr`; Build panel, Debug/Stop
  buttons, background process management via `SysProcess`.

- **Debugger / DAP** — `zebra debug file.zbr` launches LLDB-DAP proxy;
  VS Code and ZebraIDE integration; `--listen PORT` mode for custom
  IDEs.

- **`zebra check` dead-code tool** — reports unused union arms and
  unreachable functions; selfhost has 3 deref workarounds.

- **REPL** — `zebra repl`; accumulate-and-rerun model; sentinel output
  isolation; `:help / :clear / :history / :load / :save`.

---

## [0.11] — 2026-04 / 2026-05

- **JSON auto-inference** — `Json.parse(T, src)` typed overload routes to
  `parseStrict` machinery; `@reflectable` required on the target struct.

- **Tuple / multi-return** — `(T1, T2)` type, `(a, b)` literal, `var (x,
  y) = f()` destructure; `.0` / `.1` index; TC element-type registration.

- **Generic functions** — `def identity(T)(x: T): T`; `comptime T: type`
  Zig emission; call-site flattening `identity(int)(42)` → `identity(i64,
  42)`; TC type-variable inference.

- **ImGui `LowLevel` sub-API** — `g.lowLevel.addLine / addRect /
  addRectFilled / addCircle / addCircleFilled / addText` (DrawList);
  `getWindowPos / Size / getCursorPos / getMousePos` → `(float, float)`
  tuple; `beginGroup / endGroup`.

- **Build system** — `zebra build` + `Build` stdlib module; `--build-file
  / --list-targets / b.target()`; selfhost TC / codegen parity.

---

## [0.10] — 2026-04

- **Self-hosting complete** — `zig-out/bin/zebra.exe` is now the selfhost
  binary compiled from `selfhost/main.zig`; `zig-out/bin/zebra-bootstrap.exe`
  is the Zig reference compiler. `tools/bootstrap_check.sh` verifies
  byte-identical round-trip (5 steps).

- **`@derive(Debug, Eq, Hash)`** — auto-generates `toString / eql / hash`
  on structs; both compilers.

- **WebSocket** — `Ws.connect / serve / send / recv / close` + `wss://`
  TLS; blocking `recv`; graceful close; both backends.

- **`DynLib`** — vtable shims; fat-pointer coercion; `DynLib.open / close /
  lookup`; plugin demo; both backends.

- **Optional chaining `?.`** — `x?.field`, `x?.method()` — short-circuits
  to `null` if `x` is null; both compilers.

- **Type aliases with constraints** — `type Name = BaseType where value > 0`;
  transparent emit; constraint injected after `var` init; `--turbo` strips
  checks.

- **Refinement types (parametric aliases)** — `type Bounded(lo, hi) = int
  where value >= lo and value <= hi`; value params bound into constraint;
  `Bounded(0, 100)` in type position.

- **`Chan(T)` / `sys.go()`** — see 0.14 entry (this was phased across
  0.10 and 0.14).

---

## [0.9] — 2026-04

- **Self-hosting Phase 22** (cutover-ready) — parity runner; error-compat
  fixtures; `zig build selfhost`; MISMATCH 13 → 0, PASS 67 → 86.

- **Named / default parameters** — `def f(x: int, y: int = 0)` and
  call-site `f(x: 1, y: 2)`; selfhost codegen parity.

- **Optional-unwrap `as` binding** — `if x as n`, `if x is T as n`; both
  compilers.

- **String intern pool** — `_str_pool` + `_intern`; auto-intern at
  `List / HashMap / str-field` sinks; eliminates `"" +` workaround in
  selfhost.

- **`for...else`** — list/.items / Zig-native `for…else` (Path 1);
  `while`-based loops use labeled block `_fels_N` (Path 2); both
  compilers.

- **`ensure` + `old` postconditions** — `defer`-based post-conditions;
  `old_` snapshot in selfhost `UnaryOp`; both compilers.

- **`static def / static var`** — renamed from `shared def / shared var`;
  208 files updated; top-level `def main()` + postfix `catch` also
  added.

---

## [0.8] — 2026-04

- **Self-hosting Phase 14–21** — `codegen.zbr` (1,879 lines); round-trip
  zero errors; cross-module struct patterns; `if-is-capture`; source-map
  line threading; Phase 22 parity sprint.

- **`IANA timezone`** — `DateTime.inZone("America/New_York")`; ~75 built-in
  zones; 4 DST rule families (US/EU/AU/NZ); dead-stripped if unused.

- **`allocate` Slices 1–4** — `Allocator` type; `allocate` block; scoped
  arenas; `<-` copy-out (Slice 4).

- **`zebra debug`** — initial DAP integration (see 0.12 for full notes).

---

## [0.7] — 2026-04

- **Self-hosting Phase 7–13** — `codegen.zbr`, `cg_helpers.zbr`,
  `main.zbr`, `astbuilder.zbr`, full multi-file pipeline; corpus 50% →
  100%.

- **`@derive`** — see 0.10 (first landed here, stabilized at 0.10).

- **Generic functions** — first landed here (see 0.11 for final form).

- **`for-loop` destructuring** — `for a, b in list_of_pairs`; arity error;
  `where` clause; both compilers.

- **Optional chaining** — first landed (see 0.10 for final form).

- **DynLib plugin** — first landed (see 0.10 for final form).

---

## [0.6] — 2026-04

- **Self-hosting Phases 1–6** — Token, Lexer, AST, Parser, Resolver,
  TypeChecker in Zebra; `selfhost/*.zbr` sources; ~41 compiler bugs fixed
  along the way.

- **`zebra check`** — dead-code detection; see 0.12.

- **`sys.spawn()` / `SysProcess`** — process launch + I/O capture;
  ZebraIDE Debug/Stop buttons.

- **`remove pro / get / set / body` keywords** — replaced by exposed fields
  and computed properties (commit 1990682).

---

## [0.5] — 2026-04

- **Zebra renamed** — language renamed from Cobra to Zebra (Zig + Cobra
  portmanteau); `.zbr` extension; repo extracted from `cobra-language`
  on 2026-04-16.

- **Visibility keywords** — `private / public / internal / protected`
  parsing added (enforcement in 0.13).

- **`static` keyword** — `static def / static var` class-level declarations.

- **`^T` heap indirection** — `^T` on struct fields auto-boxes on
  assignment, auto-derefs in `branch` arms.

- **`except` struct update** — `this except field = value, ...` immutable
  update idiom.

- **`@reflectable`** — opt-in reflection metadata; required for
  `Json.parse(T, src)`.

- **`Progress` stdlib** — `Progress.bar / tick / done` wraps
  `std.Progress`.

- **`Test` stdlib + `zebra test`** — test subcommand; `Test.pass / fail /
  assert / eq`.

---

## [0.4] — early 2026

- **`zebra repl`** — interactive REPL (first version; see 0.12 for
  polished form).

- **`Http.get / post`** — HTTP client; `HttpResponse.body / status /
  headers`.

- **`WebSocket`** — `Ws.connect / send / recv / close`; first version.

- **`Tcp`** — `Tcp.connect / send / recv / close`.

- **`Hash`** — SHA-256/512, MD5, Blake3, HMAC-SHA256.

- **`Random`** — `randInt / randFloat / randBool / choice / shuffle`;
  secure seed.

- **`DateTime`** — parse, format, `now()`, arithmetic; ISO 8601.

- **String interpolation** — `"Hello, {name}!"` syntax; `{expr:.2f}`
  format specs; `{/` escape.

- **`Arg`** — CLI argument parsing; `flag / option / positional / usage`.

---

## [0.3] — early 2026

- **Regex** — Thompson NFA + Laurikari TNFA; `r"pattern"` raw strings;
  `^/$` anchors; `{n,m}` quantifiers; `(?:...)` non-capturing groups;
  `\b` word boundary; named captures; flags `i/s/m`.

- **HTTP server** — `Http.serve(port, handler)` first version.

- **`Path`** — `join / dirname / basename / ext / isAbsolute`.

- **`File`** — `read / write / append / exists / delete / lines`.

- **`Json`** — `Json.parse / stringify / get / set / object / array`;
  first version.

---

## [0.2] — early 2026

- **JSON stdlib** — see 0.3 (first landed here).

- **`UDP` hostname fix** — DNS resolution for `Udp.send`.

- **String methods** — `padLeft / padRight / center` with fill-char.

---

## [0.1] — early 2026

Initial public language. Compiles `.zbr` source to native executables via
Zig. Features present at 0.1:

- **Core syntax** — `def`, `var`, `if/else`, `for`, `while`, `return`,
  `class`, `struct`, `union`, `branch`, `interface`, `extend`, `namespace`.

- **Type system** — `int / float / bool / str / byte`; `List(T)`;
  `HashMap(K, V)`; optional `T?`; `throws` / `anyerror!T`; `nil`
  tracking.

- **Error model** — `throws / raise / try / catch` exceptions;
  `_error_ctx` message; richer than Zig error enums.

- **`print`** — built-in statement; `println`.

- **`Math`** — trig, `pow / log / exp`, rounding, `abs / min / max /
  clamp`.

- **`Gui` stub backend** — `Gui.run(title, w, h, cb)` 4-arg frame-callback
  form; ImGui backend for native rendering.

- **CLI parsing** — `Arg.parse()`.

- **`sys.run(cmd)`** — shell-out; `SysRunResult.output / exit_code`.
