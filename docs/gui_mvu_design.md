# GUI MVU Design Document

Status: open for review — written 2026-05-21, decisions pending before implementation.

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

### zig-libui-ng native backend

**Zig 0.16 compatibility status: BROKEN.** As of 2026-05-21:

```
build.zig:31:14: error: no field named 'root_source_file' in Build.ExecutableOptions
zig-pkg/libui/build.zig:23:8: error: no field or member function named 'linkLibC' in Compile
```

Two API breaks in `build.zig` files (one in zig-libui-ng, one in the libui-ng package it fetches).
Both are fixable (~10 line patches) but the second is in an upstream dependency.

The native backend also has a retained-mode vs immediate-mode mismatch:
- libui-ng creates widgets once and attaches click callbacks
- Our `buttonFn(label)` API assumes widgets are "recreated" each frame
- A **widget cache adapter** is needed: keyed by label, create on first call, reuse on subsequent

Estimated work: 400+ lines for the widget cache adapter + build.zig fixes.

**Verdict:** Feasible but non-trivial. Best addressed as a separate sprint with the user present.

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

## Proposed implementation order (morning sprint)

1. **Open question decisions** (user answers 1-3 above, ~5 min)
2. **Fix zig-libui-ng Zig 0.16 compatibility** (~30 min — patch two `build.zig` files)
3. **Add ZigZag dependency** to `build.zig.zon` + write ZigZag TUI `_GuiBackend` adapter (~3 hrs)
4. **Add `_gui_mvu_run` preamble + update `genGuiCall`** in both compilers (~1 hr)
5. **Counter example** + smoke test (~30 min)
6. **ZebraIDE TODO comment** (~5 min)
7. **Bootstrap + full smoke** (~30 min)
8. **QUICKSTART.md §30 update** + wiki update (~30 min)

## zig-libui-ng Zig 0.16 fix notes

In `/tmp/zig-libui-ng-check/build.zig`, the `root_source_file` field needs to move
to a module definition. The upstream libui-ng package's `build.zig` needs `lib.*.linkLibC()`
(pointer dereference). Alternatively, bump the libui-ng `url` reference to a fork with the fix.

The libui examples have a `counter` app which is a useful reference implementation.
