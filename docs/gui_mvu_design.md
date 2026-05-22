# GUI MVU Design Document

Status: **both backends complete** — ZigZag TUI (2026-05-21) + libui-ng native (2026-05-22).

## Background

The existing `Gui.run(title, w, h, frame_fn)` is immediate-mode: `frame_fn(g)` is called every frame,
with mutable state kept in a `capture` block. This works but doesn't separate state from rendering.

The goal is to adopt an MVU (Model-View-Update) architecture, motivated by:
1. Clean separation of state (Model), rendering (view), and transitions (update)
2. Testable pure `update(model, msg): model` function
3. Natural compatibility with ZigZag (TUI) and libui-ng (native GUI) backends

## Compatibility strategy

The key insight: the existing `_GuiBackend` fn-ptr architecture is compatible with both ZigZag and libui-ng.
Neither backend requires changing the Zebra user-facing API.

### ZigZag TUI backend

ZigZag's `view(state): []const u8` (ANSI string output) is bridged like this:

- Our `_GuiBackend.newFrameFn` → ZigZag processes key events, sets "button X was activated this frame" flags
- Our `_GuiBackend.buttonFn(label)` → appends ANSI button string to an internal buffer AND reads the pre-set flag
- Our `_GuiBackend.endFrameFn` → ZigZag renders the accumulated ANSI buffer string

ZigZag handles raw terminal I/O, cursor positioning, screen diffing, and the event loop.
The `_GuiBackend` implementation is ~250-300 lines sitting on top of ZigZag's primitives.

**Verdict:** Compatible. ZigZag's `view() returns string` model IS reconcilable with our imperative
`g.button(): bool` API — the bool comes from pre-processed input (set by ZigZag's update cycle),
not from view(). This is the standard "immediate mode over reactive loop" pattern.

### zig-libui-ng native backend — COMPLETE (2026-05-22)

**Zig 0.16 compatibility fixed** via two GitHub forks (4 patches total):

`torial/libui-ng` (wp-2025 branch):
- `de1b1305`: Build.Step.Compile.Xxx → Build.Module.Xxx (addIncludePath, addCSourceFiles, linkFramework, linkSystemLibrary, link_libcpp, addWin32ResourceFile)
- `5c24fd66`: `InitCommonControlsEx` FALSE+GetLastError==0 is non-fatal on Vista+ (Windows 11 runtime fix)

`torial/zig-libui-ng` (zig-0.16 branch):
- `fe1d7fa`: `callconv(.C)` → `callconv(.c)` across all 72 sites in ui.zig (Zig 0.16 CallingConvention union renamed tags)
- `95d01af`: `Checkbox.OnToggled` — add `comptime f`, remove erroneous `void catch` (Zig 0.16 inner-function closure capture restriction)
- `39665dc`: update libui-ng dep to InitCommonControls-fixed commit

**Widget cache adapter — COMPLETE** (~300 lines in `src/CodeGen.zig`):

Retained-mode mismatch solved by two parallel caches:

1. **Interactive widgets** (button, checkbox, slider, entry, multiline entry): `_lui_icache: std.StringHashMap(*_LuiMut)`, keyed by the label string. On first call (frame 0) the widget is created and added to the vbox. On frame 1+, the callback-maintained `_LuiMut` state is read.

2. **Display widgets** (text, separator): `_lui_dcache: std.ArrayList(*_LuiMut)` + `_lui_didx` counter. Widget order must be stable frame-to-frame. Text labels are updated via `ui.Label.SetText` each frame (dynamic content supported).

**Creation frame trick**: `newFrameFn()` on frame 0 returns `true` immediately (no `uiMainStep` call). The view function runs, creating all widgets in order. `endFrameFn()` on frame 0 sets the vbox as window child, shows the window, and increments the frame counter. Frame 1+ call `uiMainStep(.blocking)` to wait for OS events.

**`_LuiMut` struct** (heap-allocated per widget for stable callback pointers):
```zig
const _LuiMut = struct {
    ctrl: ?*ui.Control = null,    // main control
    lbl:  ?*ui.Label  = null,     // companion label (slider/entry/text)
    clicked: bool = false,         // button
    checked: bool = false,         // checkbox
    text_buf: [1024]u8 = undefined, // entry/mle text buffer
    text_len: usize = 0,
    sval: c_int = 0,               // slider: raw 0-1000 value
    smin: f64 = 0, smax: f64 = 1, // slider: user range
};
```

**Activate:** `--gui-backend=libui_ng` (or `libui-ng`). Generates a `build.zig.zon` that fetches `torial/zig-libui-ng`. Project directory: `<stem>_gui_libui_ng/` (TUI uses `<stem>_gui_tui/`, others use `<stem>_gui/`).

**Package hashes (pinned, 2026-05-22):**
- zig-libui-ng: `bindings_libui_ng-0.1.0-p2CY9WKMAgCOLTUoD8b1NK1eplwP9TucFhKQV_iE6c-B` (commit `39665dc`)
- libui-ng: `N-V-__8AAEujJQCHCZIDKlQ1fg9j03MUEN1w3FPRW4g0HojW` (commit `5c24fd66`)

**MVP limitations:**
- `beginPanel`/`beginWindow`/table/tree/color/style calls are no-ops (all widgets render in one flat vbox)
- Low-level draw API is no-op
- Display widget order must be stable (frame-counter cache)

**Verdict:** Complete. ~300 lines of adapter code.

## Open question 1: MVU dispatch mechanism

The previous session locked in `g.send(msg)` as the dispatch mechanism:
> `g.send(msg)` queues messages for update() — the MVU dispatch mechanism

An alternative emerged during analysis: **view returns `?Msg`**

### Option A: `g.send(msg)` (queued)

```zebra
def view(g: Gui, model: Model)
    g.text("Count: {model.count}")
    if g.button("+")
        g.send(Msg.increment)
    if g.button("-")
        g.send(Msg.decrement)
```

**Pros:** Supports multiple messages per frame; view() returns void (pure rendering).
**Cons:** Requires type erasure to store the message in GuiContext; complex Zig preamble.
GuiContext must carry a `_send_fn: *const fn(*anyopaque, *const anyopaque) void` and a
`_send_ptr: *anyopaque` — uglier generated Zig.

### Option B: `view returns ?Msg` (one-per-frame)

```zebra
def view(g: Gui, model: Model): Msg?
    g.text("Count: {model.count}")
    if g.button("+")
        return Msg.increment
    if g.button("-")
        return Msg.decrement
    return nil
```

**Pros:** Simple Zig preamble (`const _msg = view(_g, _model); if (_msg) |m| ...`);
no type erasure; clean Zebra syntax; one-message-per-frame is fine for TUI.
**Cons:** Can't queue multiple messages in one frame; not quite ZigZag's model (ZigZag
sends messages via the update function, not view). Requires `Msg?` return type annotation on view.

**Recommendation:** Option B for a first implementation, with a note that Option A is the path
forward if multi-message-per-frame turns out to be needed.

## Open question 2: Replace or keep old `Gui.run`?

User stated preference (answered via AskUserQuestion): **"Replace entirely (Recommended)"**

Implications:
- `test/gui_test.zbr` and `test/test_gui_simple.zbr` use the old 4-arg form → must be rewritten
- `IDE/ZebraIDE.zbr` uses the old form → needs migration or temporary shim
- `test/lowlevel_smoke_test.zbr` uses the old form

Options:
1. **Hard replace**: Remove 4-arg form, update all callers now. ~4 files to migrate.
   ZebraIDE migration to MVU is non-trivial (uses `capture` block state) but doable.
2. **Soft deprecate**: Keep 4-arg form working but don't document it; add new 6-arg form.
   Clean separation; old tests keep passing; ZebraIDE migrates when the real backend lands.
3. **Shim**: 4-arg `Gui.run(t, w, h, frame)` becomes sugar for 6-arg with `init={}`, `update=passthrough`, `view=frame`.
   Backward compat with zero migration cost; slightly hacky.

**Decision needed from user.**

## Open question 3: ZebraIDE migration

ZebraIDE (`IDE/ZebraIDE.zbr`) is 460+ lines using the old frame-callback model with `capture` state.
It's the primary stress test for the GUI API.

Options:
1. **Migrate to MVU now**: Extract Model struct, write update/view. ~1-2 hours of work.
   Blocks on having a real backend to test against (stub would not exercise the IDE usefully).
2. **TODO comment now, migrate when real backend lands**: Low risk, defers complexity.
3. **Delete and rewrite fresh** once MVU + ZigZag backend are stable.

**Recommendation:** Option 2 — add a TODO comment, migrate when a real backend is ready.

## Implementation outcome

**ZigZag TUI backend — shipped 2026-05-21:**

- `--gui-backend=tui` flag added to both bootstrap (`src/main.zig`) and selfhost (`selfhost/main.zbr`).
- Selfhost delegates `--gui-backend=XXX` to bootstrap (GUI compilation requires `zig build` + package deps, not `zig run`).
- `src/CodeGen.zig`: `.tui` enum variant; full `_tui_*` function suite injected into the generated Zig preamble.
- `src/main.zig`: `gui_tui_project_build_zig` + `gui_tui_project_build_zig_zon` templates; `compileGuiProject` parameterized on backend.
- ZigZag dep: `git+https://github.com/meszmate/zigzag#v0.1.5`, hash `zigzag-0.1.2-YXwYS17aEQBlpxPETTrhY5leFh7vV0DpnXJbHogs4Lsv`.
- Counter example compiles and links against ZigZag successfully.

**Open questions resolved:**
- Q1 (dispatch): **Option A — `g.send(msg)`** chosen. Type erasure handled by fn-ptr in GuiContext.
- Q2 (keep/replace): **Replace entirely** — 6-arg `Gui.run(title, w, h, init, update, view)` is the only form.
- Q3 (ZebraIDE): Deferred — add TODO comment when IDE gets a real backend sprint.

**libui-scintilla note:** The Scintilla code editor was extracted into a separate project (`petabyt/libui-scintilla`) from libui-dev. When the libui-ng sprint happens, start from the main libui-ng repo and add libui-scintilla separately if code editing is needed.

**libui-ng status:** ✅ Complete (2026-05-22).

## Remaining work

1. **ZebraIDE migration to MVU** (when a real backend sprint happens)
2. **Selfhost `--gui-backend` native codegen** (generate TUI/libui-ng block in codegen.zbr, scaffold `zig build` project in Zebra)
3. **QUICKSTART.md §30 update** + wiki update
