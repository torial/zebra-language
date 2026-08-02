<!-- doc-status: historical -->
# libui_ng GUI backend — verified-state audit

**Date:** 2026-07-27  **Auditor:** Opus 4.8 (Claude Code)
**Supersedes:** `docs/archive/libui_ng_audit_2026-05-25.md` (kept for its upstream
C-fork bug inventory; its capability matrix is stale — see §6).

## Why this audit exists

The libui_ng backend accreted a month of enthusiastic documentation while, until
**2026-07-27**, *no libui_ng executable had ever run* — the upstream dependency
did not compile under Zig 0.16, so every "works"/"complete"/"end-to-end tested"
claim was written against a program that had only ever been *emitted*, never
built-and-run. This audit separates what is **proven** from what is **asserted**.

### Verification tiers (used throughout)

Two independent axes. A widget can be fully WIRED yet NEVER-RUN.

**Implementation status** (what the code does):
- **WIRED** — real body that calls the `ui.*`/`sci.*` binding to do the thing.
- **PARTIAL** — does part; visibly drops or fakes some inputs.
- **STUB** — body is a no-op (`_ = arg;`) or returns a constant default.
- **ABSENT** — claimed somewhere, but no such function exists.

**Evidence status** (how far it's been proven):
- **RUN-VERIFIED** — observed working at runtime (states who/when/how).
- **COMPILE-VERIFIED** — the emitted Zig compiles + links under `zig` (the
  independent witness), but has never been executed.
- **NEVER-RUN** — no program has exercised this path at runtime.

The whole glue is at least **COMPILE-VERIFIED** as of 2026-07-27: `counter.zbr`
and `tears_of_the_tuon.zbr` both emit Zig that `zig build-exe` links to an
`app.exe` (the game proven from a *cold* cache — deps fetched fresh from GitHub).

---

## 1. Runtime verification ledger (the part that was missing)

| Program | Implementation exercised | Evidence | Status |
|---|---|---|---|
| `examples/counter.zbr` | window, root VBox, `text`(Label), `separator`, `button`×3, `sameLine` | Window renders **and `+`/`−`/`Reset` all change the count** — Sean-confirmed 2026-07-27; exits **0** | **RUN-VERIFIED (render + interaction)** |
| `examples/tears_of_the_tuon.zbr` | game view (difficulty-select: easy/medium/hard buttons) | **Window renders on screen** — Sean-confirmed 2026-07-27 | **RUN-VERIFIED (render)** |
| `examples/editor_min.zbr` | window, VBox, `text`, **one CodeEditor** (`forZebra` + `setText` + `render`) | A Scintilla control renders and displays its setText content — Sean-confirmed 2026-07-27, **re-confirmed post-BUG-217** (the first pass was made under the read-past-the-end bug) | **RUN-VERIFIED (single-editor display)** |
| `IDE/ZebraIDE.zbr` | full IDE: **four** CodeEditors, toolbar buttons, MVU dispatch, subprocess spawn/poll | Renders; **all toolbar buttons click without crashing** (Build/Check/List Targets); **four Scintilla controls coexist**; typing works in the one editable editor, the three `setReadOnly(true)` panes correctly reject input — Sean-confirmed 2026-07-27 | **RUN-VERIFIED (render + interaction + multi-editor)** |
| Everything else (checkbox, slider, entry, combobox, spinbox, progressbar, panel, all dialogs) | — | Links into the exe; never instantiated at runtime | **NEVER-RUN** |

**CodeEditor scope, precisely:** what's proven is that **one** Scintilla control
instantiates, renders, and shows the text set via `setText`. **Not** yet
exercised: editability (typing into it — Sean saw it, didn't type), syntax
highlighting (`forZebra` falls back to plain — no lexer wired, by design),
`setErrorMarkers` (a no-op stub). **The multi-editor question is CLOSED
(2026-07-27):** the IDE's four Scintilla controls coexist in one window, all
render, and editability behaves as authored — typing works in `m.editor` and the
three panes given `setReadOnly(true)` in `ideInit` (diag/output/buildOutput)
correctly reject it. Typing into a Scintilla control is therefore also
RUN-VERIFIED, which `editor_min` never established. Getting here required porting the `CodeEditor` builtin to the selfhost
front-end + codegen (commit `b42074a`) and fixing BUG-211 (commit `33571e5`) —
before which no CodeEditor program could even name-resolve through the selfhost.
**CodeEditor is NEVER-gate-covered** (no corpus test uses it — it needs a GUI
backend + manifest); the only witness is a manual libui_ng build + on-screen check.

**What the runtime proof now covers:** counter's `+`/`−`/`Reset` buttons all
change the count (Sean, 2026-07-27), so the **full MVU round-trip is
RUN-VERIFIED** — button-click latch → `update` → model change → `Label.SetText`
re-render, driven by `uiMainStep`. The game's difficulty-select screen also
renders. This exercises: window, root VBox, Label(dynamic), Separator, Button +
its click callback, and the MVU loop. Button interaction proven via counter
applies to the game's buttons (same code path); the game's *own* flow past the
first screen (does clicking "easy" start play?) is not separately confirmed.

**Still true — "renders" ≠ "renders as authored":** `counter.zbr` calls
`g.sameLine()` between its buttons, and `sameLine` is a **no-op stub** in libui
(§3), so the three buttons stack **vertically** instead of inline. The behavior
is correct; the layout is not what the source asks for.

---

## 2. The root-cause fix that unblocked runtime (2026-07-27)

**Symptom:** counter + game both exited **57** under `zig build run` with no
window (Sean: "nothing happened").

**Cause:** libui is linked **statically**. libui-ng embeds the Common-Controls
v6 application manifest only in a **shared** build — `windows/resources.rc`
guards it behind `#ifndef _UI_STATIC` and the source comments *"static builds
have to include the appropriate parts of the manifest in the output
executable."* The emitted consumer exe supplied none, so comctl6 was inactive
and window/control creation failed at init.

**Fix (commit `596e9d1`):** `luiBuildZig` now sets
`.win32_manifest = b.path("app.manifest")`, and `compileGuiProject` writes
`app.manifest` (comctl6 dependency, taken from libui-ng's own
`test/test.static.manifest`) into the scaffold unconditionally.

**Result:** counter runs exit 0 and the window appears (Sean-verified). Clean
before/after — the exit code went 57 → 0 with only the manifest added.

---

## 3. Glue inventory — `selfhost/gui_libui_ng_section.zig`

This file is the **active** libui_ng path: since the 2026-07-26 selfhost-GUI
epic, `--gui-backend=libui_ng` routes through the selfhost (`gui_selfhost =
tui | libui_ng`, `main.zbr:2267`) and this section is substituted into the
emitted Zig at runtime. (The bootstrap's `src/CodeGen.zig` libui arm still
exists but is **no longer the path taken** — docs describing "the ~300-line
preamble in CodeGen.zig" describe the retired route.)

Every `ui.*`/`sci.*` call the glue makes **exists in the binding** (cross-checked
against `zig-libui-ng/src/*.zig`) — no phantom calls, consistent with it linking.

### WIRED (real implementation)

| Feature | Notes |
|---|---|
| Window + close handler + 100 ms poll timer | `_lui_init`/`_lui_deinit` |
| MVU run loop (`_gui_run`, `_gui_mvu_run`) | 32-slot msg queue, view→drain→update/frame |
| VBox / HBox | id-cached, stretch append |
| Group / **Panel** (`beginPanel`/`endPanel`) | `uiGroup` + inner VBox |
| Button, Checkbox, Slider, Entry, Combobox, Spinbox | real widget + change/click callback |
| Label (`text`), Separator (horizontal) | dynamic `SetText` each frame |
| **File dialogs**: openFile, saveFile, openFolder, msgBox, msgBoxError | native modals via `ui.Window.*` |
| CodeEditor: new, setText, getText, setReadonly, render, getCursorLine, getCursorCol | via `sci` (Scintilla) |
| All event callbacks (`_lui_*_cb`) | button/checkbox/slider/entry/mle/combobox/spinbox |

### PARTIAL (works but drops inputs)

| Feature | What's dropped |
|---|---|
| MultilineEntry | width/height args ignored; 1 KB text cap |
| ProgressBar | label arg discarded; value clamped 0–100 |
| textColored | **color faked** — renders a plain Label |
| CodeEditor.render | `id`, width, height, context all discarded |
| CodeEditor.setCursorPosition | **column ignored** — only line honored |
| lowLevel.getWindowSize | returns stored init size, not live window size |

### STUB (no-op — present in API, does nothing)

`sameLine`, `spacing`, `indent`/`unindent`; `selectable` (always false);
`beginWindow`/`endWindow` (nested windows); **entire Table API** (beginTable,
setupColumn, headersRow, nextRow, nextColumn, endTable — no `ui.Table` binding
used at all); `treeNode`/`treePop`; `beginChild`/`endChild` (scroll regions);
all theming (`setColor`, `setColorsDark`, `setStyleFloat`, `setVec2`,
`scaleAllSizes`); `getDpi` (hardcoded `1.0`); **entire low-level immediate draw
API** (addLine/Rect/RectFilled/Circle/CircleFilled/Text + cursor/mouse pos);
**`CodeEditor.setErrorMarkers` (pure no-op)**.

### ABSENT

`Grid` — no glue function or backend slot exists (the binding has `ui.Grid`, but
the Zebra glue never wires it).

---

## 4. The binding — `torial/zig-libui-ng@main` (commit `8677b01`)

Consolidated 2026-07-27 (wp base + zig-0.16's sci/scintilla + Zig-0.16 fixes),
single `main` branch, **public**. API surface is essentially **complete libui
coverage**: Window (+ all file dialogs), all layout (Form/Box/Grid/Group/
Separator/Tab), all buttons (Button/Color/Font), all inputs (DateTimePicker/
Checkbox/Combobox/RadioButtons/Slider/Spinbox), text (Entry/Label/MultilineEntry/
EditableCombobox), menu, table, draw. **The binding is not the limiting factor —
the Zebra glue (§3) wires only a subset.**

**`sci` module (Scintilla):** thin, real, 33 lines — `new`, `setText`,
`getLength`, `getRange`, `sendMessage`, `as_control` over libui-scintilla's C
API. `luiBuildZig` always links it, so Scintilla **compiles + links into every
libui_ng exe** — but no program has created a Scintilla control at runtime, so
the CodeEditor is **NEVER-RUN**. No lexer/highlighting is wired
(`CodeEditor.forZebra` falls back to plain; `setErrorMarkers` is a no-op).

## 5. The C fork — `torial/libui-ng@main` (commit `85976bc`)

Single `main` branch, **public**, carries the vendored `uiRect` struct (from
petabyt/libui-dev) that the whole GitHub chain depends on. Its unique work over
upstream: a **Haiku backend** (5 commits — irrelevant on Windows), libui-dev
extras (placeholder text, `DrawBitmap` decl, `ui_safe.h`, Issue #308 fix), Zig
0.16 build compat, float spinbox + file-dialog params, and a Windows
`InitCommonControlsEx` robustness fix. Remotes retained for six upstreams
(kojix2, petabyt/libui-dev, libui-ng master, nicowillis, origin) — useful for
future rebases; not a build concern.

---

## 6. Claims-vs-facts corrections (the punch list)

Adjudicated from the doc catalog against the verified glue. **The recurring
pattern: capability was wired in later than the audit/design docs, and separately
"runtime" was claimed before anything ran.** Two failure directions:

### 6a. Stale-PESSIMISTIC — docs say STUB/absent; reality is WIRED

The May-25 audit and `gui_mvu_design.md` predate the ProgressBar/Combobox/
Spinbox/Panel/file-dialog wiring:

| Feature | Stale claim | Verified fact |
|---|---|---|
| beginPanel/endPanel | "stub" (archived audit A27–A28; gui_mvu_design G10) | **WIRED** (`uiGroup`, glue 636–656) |
| ProgressBar | preamble "–" absent (archived A41) | **WIRED/PARTIAL** (label dropped) |
| Combobox, Spinbox | preamble "–" absent (archived A41) | **WIRED** |
| File dialogs | preamble "–" absent (archived A44) | **WIRED** (all five) |

`gui_mvu_design.md` header "**both backends complete**" / "libui-ng status ✅
Complete (2026-05-22)" describes emit-completeness, not a running program.

### 6b. Stale-OPTIMISTIC — docs assert runtime; nothing had run

| Source | Claim | Verdict |
|---|---|---|
| `CHANGELOG.md:84` | "`--gui-backend=libui_ng` — **end-to-end tested**; `counter.zbr` opens a native Win32 window." | **FALSE when written** (libui_ng could not build). **Now TRUE** for the render, post-manifest (2026-07-27). Reword to date the evidence. |
| `NEXT_STEPS.md:107` | "works end-to-end 2026-07-27" | TRUE for counter render; the same block correctly narrows it to compile+link elsewhere — tighten to one story. |

### 6c. Contradictory dependency pins (three docs, three commits)

| Doc | Pin named as "the" pin |
|---|---|
| `docs/UI_QUICKSTART.md:233` | `zig-libui-ng` `d99a49c` |
| `docs/gui_mvu_design.md:74` | `zig-libui-ng` `39665dc`, libui-ng `5c24fd66` |
| **Actual (2026-07-27)** | **`zig-libui-ng@main 8677b01` → `libui-ng@main 85976bc`** |

Both older pins are stale; `luiBuildZon` in `selfhost/main.zbr` is the single
source of truth now.

### 6d. Correct-as-written (no change)

`QUICKSTART.md` §30 and `docs/UI_QUICKSTART.md` are accurate on the STUBs
(sameLine/table/tree/color/low-level no-ops; selectable false; CodeEditor col
ignored / setErrorMarkers no-op / no highlighting). `project_zebra.md` wiki line
was refreshed 2026-07-27 and matches.

---

## 7. IDE readiness (Sean's question: "recover/merge Scintilla for an IDE")

Scintilla was never lost — but "already wired" hid that it had **never once run**,
plus three real gaps. `IDE/ZebraIDE.zbr` uses `codeEditor` throughout.

Status as of 2026-07-27 (what "already wired" hid):

- **RUN-VERIFIED (single editor):** a Scintilla control renders and displays its
  text via `editor_min.zbr` (§1). Getting here needed work "already wired" masked:
  (1) CodeEditor was **never ported to the selfhost front-end** — every CodeEditor
  program failed at name resolution through the selfhost until commit `b42074a`;
  (2) a **latent Zig-0.16 bug in the binding's `sci.zig`** (`as_control` missing
  `@alignCast`), compiled only when a program first *referenced* an editor — fixed
  in `torial/zig-libui-ng` `93c7f54`; (3) **BUG-211** (`using`-block usage
  analysis) blocked the minimal program — fixed in `33571e5`.
- **The full IDE now COMPILES + LINKS and its window RENDERS** (as of `1895d79`):
  past the CodeEditor code and the `isRunning` gap (BUG-213). Sean saw the IDE
  window on screen (2026-07-27). It **aborted (exit 3) on the first button click**,
  not on startup — **BUG-214**: a no-payload `union(enum)` `Msg` variant is emitted
  as a bare tag (`Msg.list_targets`) rather than a full union value, so the
  type-erased `g.send(anytype)` copy hits a size/type mismatch; every toolbar
  button sends a no-payload variant. counter dodges it (its all-no-payload `Msg`
  and its tag are both 1 byte, so the copy is accidentally correct).
  **BUG-214 fix LANDED 2026-07-27, AWAITING INTERACTIVE VERIFICATION.** All 11 bare
  `g.send(Msg.…)` sites in `IDE/ZebraIDE.zbr` now emit `Msg{ .variant = {} }`, and
  the minimal repro (`test/mvu_mixed_union_test.zbr`, which reproduced the abort
  under the *stub* backend — no display needed) runs clean. The gates cannot close
  this one: they prove the emit shape and that nothing regressed, **not** that the
  IDE stops aborting on a click. That needs Sean clicking a toolbar button in an
  interactive session. The four-coexisting-Scintilla question is *likely* answered
  by the render (Sean saw "the IDE") but the specific "four editor panes visible"
  detail is unconfirmed, as is typing into them.
- **Genuinely missing for an IDE (unbuilt, not lost):** syntax highlighting /
  lexer (`forZebra` falls back to plain), error markers (`setErrorMarkers` no-op),
  fixed column in `setCursorPosition`, and any Table/Tree (file-explorer) widget.

- **Interactive session 2026-07-27 (Sean clicking):** BUG-214 **confirmed fixed** —
  buttons dispatch, "many worked". Two crashes it had been masking surfaced and are
  fixed: **BUG-215** (`Check` / `List Targets` — `indexOf(sub, from)` is not a real
  signature and both compilers silently dropped the offset) and **BUG-217** (`Build` —
  `SCI_SETTEXT` ignores its length argument and `strlen()`s the pointer, so the
  non-terminated `dupe` buffer segfaulted; `setText("")` faulted on an unreadable
  `.ptr`). **Both CONFIRMED on a second interactive pass** — Sean: *"All crashing
  behavior w/ those buttons is gone."* Build, Check and List Targets all clean.
  **Correction to this document's earlier claim:** `examples/editor_min.zbr` was listed
  as run-verified, and it does render — but it was reading past the end of its buffer
  the whole time (BUG-217). It survived only because `strlen` found a zero in fresh
  arena memory. "Renders correctly" is not evidence of memory safety at a C boundary.
  Its RUN-VERIFIED marker was **earned under the buggy code** and has not been re-earned;
  treat it as unverified until someone runs it again post-fix.

- **Class audit after BUG-217 (negative result, 2026-07-27):** swept
  `gui_libui_ng_section.zig` for every other value crossing into C. All clean — the
  per-frame label/button/checkbox/slider/entry paths each copy into a stack buffer with
  an explicit `[:0]` sentinel (12 sites, every one clamped with `@min` against its buffer
  size), the window title uses `bufPrintZ`, and the msgBox title/description use `dupeZ`.
  `_CodeEditor` was the sole outlier precisely *because* its buffer is long-lived and
  heap-managed rather than a per-frame stack copy — the one place the established idiom
  was not reachable. No BUG-218.

- **Transferable rule, paid for the hard way:** when a C API is involved, read the C
  implementation, not the Zig wrapper's signature. BUG-217 was dismissed mid-session on
  the grounds that `uiScintillaSetText(self, text.ptr, text.len)` takes an explicit
  length — it does, and then hands it to `SendMessage(…, SCI_SETTEXT, len, text)`, where
  Scintilla ignores `wParam` and calls `strlen(text)` two frames deeper. A wrapper that
  accepts a length is not a promise that anything downstream uses it. ("Get the stack
  trace first" is the weaker version of this lesson — the trace helped, but the reasoning
  error was stopping at the wrapper, and a future reader will have a trace and still stop
  there.)

**Bottom line:** the full IDE builds, links, renders, and is **click-stable** —
RUN-VERIFIED 2026-07-27 across two interactive passes. Every known compile,
dispatch, and memory-safety gap is closed (BUG-211, BUG-213, BUG-214, BUG-215,
BUG-217). One unknown remains: whether the four Scintilla editors coexist and
accept typing. The editor-quality features (syntax highlighting, error markers,
a file tree) are unbuilt rather than broken.

---

## Appendix — verification commands

```bash
# emit + build + run a libui_ng program (window appears on an interactive session)
zig-out/bin/zebra.exe --gui-backend=libui_ng examples/counter.zbr

# prove portability cold (both deps fetched fresh from GitHub)
ZIG_GLOBAL_CACHE_DIR=/c/tmp/cold zebra.exe --gui-backend=libui_ng examples/counter.zbr
```
