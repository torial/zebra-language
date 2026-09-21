// ─── GUI: backend isolation ──────────────────────────────────────────────────
// _GuiBackend is an fn-ptr struct.  Swap `_gui_active_backend` to change
// the renderer without touching user code or GuiContext.
const _GuiVec2 = struct { f64, f64 };
const _GuiBackend = struct {
    initFn:        *const fn (title: []const u8, width: i64, height: i64) anyerror!void,
    deinitFn:      *const fn () void,
    newFrameFn:    *const fn () bool,
    endFrameFn:    *const fn () void,
    // g.every(ms, msg): a timer SUBSCRIPTION. The view declares the timers it wants
    // each frame; one that stops being declared is disarmed. The message bytes are
    // copied (the Msg type is only known to the run loop) and sent with send_fn.
    everyFn:       *const fn (ms: i64, msg: *const anyopaque, len: usize, send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, send_ptr: *anyopaque) void,
    textFn:        *const fn (s: []const u8) void,
    separatorFn:   *const fn () void,
    sameLineFn:    *const fn () void,
    spacingFn:     *const fn () void,
    indentFn:      *const fn () void,
    unindentFn:    *const fn () void,
    buttonFn:      *const fn (label: []const u8) bool,
    buttonIdFn:    *const fn (id: []const u8, label: []const u8) bool,
    checkboxFn:    *const fn (label: []const u8, value: bool) bool,
    sliderFn:      *const fn (label: []const u8, value: f64, min: f64, max: f64) f64,
    inputFn:       *const fn (label: []const u8, value: []const u8) []const u8,
    inputMultilineFn: *const fn (label: []const u8, value: []const u8, width: f64, height: f64) []const u8,
    beginPanelFn:       *const fn (label: []const u8) bool,
    endPanelFn:         *const fn () void,
    beginWindowFn:      *const fn (label: []const u8) bool,
    endWindowFn:        *const fn () void,
    selectableFn:       *const fn (label: []const u8) bool,
    textColoredFn:      *const fn (r: f32, gv: f32, b_: f32, a: f32, s: []const u8) void,
    beginTableFn:       *const fn (id: []const u8, cols: i64) bool,
    tableSetupColumnFn: *const fn (label: []const u8) void,
    tableHeadersRowFn:  *const fn () void,
    tableNextRowFn:     *const fn () void,
    tableNextColumnFn:  *const fn () void,
    endTableFn:         *const fn () void,
    tableSelectedRowFn:  *const fn (id: []const u8) i64,
    tableActivatedRowFn: *const fn (id: []const u8) i64,
    beginChildFn:       *const fn (id: []const u8, w: f64, h: f64) bool,
    endChildFn:         *const fn () void,
    treeNodeFn:         *const fn (label: []const u8) bool,
    treePopFn:          *const fn () void,
    setColorFn:         *const fn (role: []const u8, r: f32, g: f32, b: f32, a: f32) void,
    setColorsDarkFn:    *const fn () void,
    setStyleFloatFn:    *const fn (name: []const u8, value: f32) void,
    setVec2Fn:          *const fn (name: []const u8, x: f32, y: f32) void,
    scaleAllSizesFn:      *const fn (scale: f32) void,
    getDpiFn:             *const fn () f32,
    ll_addLineFn:         *const fn (x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void,
    ll_addRectFn:         *const fn (x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void,
    ll_addRectFilledFn:   *const fn (x1: f64, y1: f64, x2: f64, y2: f64, col: i64) void,
    ll_addCircleFn:       *const fn (cx: f64, cy: f64, r: f64, col: i64, thickness: f64) void,
    ll_addCircleFilledFn: *const fn (cx: f64, cy: f64, r: f64, col: i64) void,
    ll_addTextFn:         *const fn (x: f64, y: f64, col: i64, text: []const u8) void,
    ll_getWindowPosFn:    *const fn () _GuiVec2,
    ll_getWindowSizeFn:   *const fn () _GuiVec2,
    ll_getCursorPosFn:    *const fn () _GuiVec2,
    ll_getMousePosFn:     *const fn () _GuiVec2,
    ll_beginGroupFn:      *const fn () void,
    ll_endGroupFn:        *const fn () void,
    beginHBoxFn: *const fn (id: []const u8, stretch: bool) void,
    endHBoxFn:   *const fn () void,
    beginVBoxFn: *const fn (id: []const u8, stretch: bool) void,
    endVBoxFn:   *const fn () void,
    beginTabsFn:   *const fn (id: []const u8, stretch: bool) void,
    beginTabPageFn: *const fn (id: []const u8, label: []const u8) void,
    endTabPageFn:  *const fn () void,
    endTabsFn:     *const fn () void,
    tabSelectedFn: *const fn (id: []const u8) i64,
    selectTabFn:   *const fn (id: []const u8, index: i64) void,
    minSizeFn:     *const fn (id: []const u8, width: i64, height: i64) void,
    hotkeyFn:      *const fn (vk: i64, mods: i64) void,
    // §6b (2026-09-17): message-carrying forms and menus. `msg` is the Msg's bytes
    // (copied; the Msg type is only known to the run loop) sent with send_fn; `cap`
    // is a Zebra closure's bytes and `thunk` the comptime-generated call that turns
    // the widget's value into a Msg and sends it.
    actionFn:      *const fn (label: []const u8, msg: *const anyopaque, len: usize, send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, send_ptr: *anyopaque) void,
    toggleFn:      *const fn (label: []const u8, checked: bool, cap: *const anyopaque, cap_len: usize, thunk: *const fn (*const anyopaque, bool, *const fn (*anyopaque, *const anyopaque, usize) void, *anyopaque) void, send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, send_ptr: *anyopaque) void,
    fieldFn:       *const fn (label: []const u8, text: []const u8, cap: *const anyopaque, cap_len: usize, thunk: *const fn (*const anyopaque, []const u8, *const fn (*anyopaque, *const anyopaque, usize) void, *anyopaque) void, send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, send_ptr: *anyopaque) void,
    beginMenuFn:   *const fn (name: []const u8) void,
    menuItemFn:    *const fn (label: []const u8, msg: *const anyopaque, len: usize, send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, send_ptr: *anyopaque) void,
    menuSeparatorFn: *const fn () void,
    menuQuitFn:    *const fn () void,
    endMenuFn:     *const fn () void,
    takeKeyFn:     *const fn () i64,
    progressBarFn: *const fn (label: []const u8, value: f64) void,
    comboboxFn:    *const fn (label: []const u8, items: []const []const u8, selected: i64) i64,
    spinboxFn:     *const fn (label: []const u8, value: i64, min: i64, max: i64) i64,
    openFileFn:    *const fn () ?[]const u8,
    saveFileFn:    *const fn () ?[]const u8,
    openFolderFn:  *const fn () ?[]const u8,
    msgBoxFn:      *const fn (title: []const u8, description: []const u8) void,
    msgBoxErrorFn: *const fn (title: []const u8, description: []const u8) void,
};
const _LowLevel = struct {
    _b: *const _GuiBackend,
    pub fn addLine(ll: _LowLevel, x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void {
        ll._b.ll_addLineFn(x1, y1, x2, y2, col, thickness);
    }
    pub fn addRect(ll: _LowLevel, x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void {
        ll._b.ll_addRectFn(x1, y1, x2, y2, col, thickness);
    }
    pub fn addRectFilled(ll: _LowLevel, x1: f64, y1: f64, x2: f64, y2: f64, col: i64) void {
        ll._b.ll_addRectFilledFn(x1, y1, x2, y2, col);
    }
    pub fn addCircle(ll: _LowLevel, cx: f64, cy: f64, r: f64, col: i64, thickness: f64) void {
        ll._b.ll_addCircleFn(cx, cy, r, col, thickness);
    }
    pub fn addCircleFilled(ll: _LowLevel, cx: f64, cy: f64, r: f64, col: i64) void {
        ll._b.ll_addCircleFilledFn(cx, cy, r, col);
    }
    pub fn addText(ll: _LowLevel, x: f64, y: f64, col: i64, text: []const u8) void {
        ll._b.ll_addTextFn(x, y, col, text);
    }
    pub fn getWindowPos(ll: _LowLevel) _GuiVec2 { return ll._b.ll_getWindowPosFn(); }
    pub fn getWindowSize(ll: _LowLevel) _GuiVec2 { return ll._b.ll_getWindowSizeFn(); }
    pub fn getCursorPos(ll: _LowLevel) _GuiVec2 { return ll._b.ll_getCursorPosFn(); }
    pub fn getMousePos(ll: _LowLevel) _GuiVec2 { return ll._b.ll_getMousePosFn(); }
    pub fn beginGroup(ll: _LowLevel) void { ll._b.ll_beginGroupFn(); }
    pub fn endGroup(ll: _LowLevel) void { ll._b.ll_endGroupFn(); }
    pub fn sameLine(ll: _LowLevel) void { ll._b.sameLineFn(); }
};
const GuiContext = struct {
    _b: *const _GuiBackend,
    lowLevel: _LowLevel,
    _send_fn: ?*const fn (*anyopaque, *const anyopaque, usize) void = null,
    _send_ptr: ?*anyopaque = null,
    pub fn send(self: GuiContext, msg: anytype) void {
        // A literal (`g.send(2)` with an int Msg) is a comptime_int: taking its address
        // and reading it back as the Msg type panicked "incorrect alignment" (found
        // 2026-09-17 by examples/table_strip_smoke.zbr). Land it in a runtime value first.
        const _T = switch (@TypeOf(msg)) { comptime_int => i64, comptime_float => f64, else => @TypeOf(msg) };
        const _v: _T = msg;
        if (self._send_fn) |f| f(self._send_ptr.?, @ptrCast(&_v), @sizeOf(_T));
    }
    // Subscribe to time: `msg` is sent every `ms` milliseconds for as long as the view
    // keeps declaring it. The only way a program gets a frame without an event.
    pub fn every(self: GuiContext, ms: i64, msg: anytype) void {
        const _T = switch (@TypeOf(msg)) { comptime_int => i64, comptime_float => f64, else => @TypeOf(msg) };
        const _v: _T = msg;
        if (self._send_fn) |f| self._b.everyFn(ms, @ptrCast(&_v), @sizeOf(_T), f, self._send_ptr.?);
    }
    // MVU HIERARCHY (2026-09-18, QUICKSTART §30 "Components"): render a child component's
    // `view(g, model)` under a message MAP. Every message the child sends through this `g`
    // -- send, action, toggle, field, every, menuItem -- is passed through `map`
    // (ChildMsg -> Msg) before it reaches the parent's queue, so the child never knows the
    // parent's Msg type and the parent's update sees `Msg.child(cm)`. Elm's Html.map.
    // Three VALUES, no closure: a `def map(cm: ChildMsg): Msg`, a `def view(g: Gui, m:
    // ChildModel)`, and the child model -- the shape Gui.run already takes, and not the
    // closure-per-frame shape that exhausted the sig pool (BUG-358). Scopes nest.
    pub fn scope(self: GuiContext, map: anytype, view: anytype, model: anytype) void {
        const _W = _ScopeWrap(@TypeOf(map));
        var cg = GuiContext{ ._b = self._b, .lowLevel = self.lowLevel };
        if (self._send_fn) |pf| {
            cg._send_fn = _W.send;
            cg._send_ptr = @ptrCast(_W.get(pf, self._send_ptr.?, map));
        }
        if (comptime _zbr_is_fnlike(@TypeOf(view))) view(cg, model) else { var _v = view; _v.call(cg, model); }
    }
    pub fn text(self: GuiContext, s: []const u8) void { self._b.textFn(s); }
    pub fn separator(self: GuiContext) void { self._b.separatorFn(); }
    pub fn sameLine(self: GuiContext) void { self._b.sameLineFn(); }
    pub fn spacing(self: GuiContext) void { self._b.spacingFn(); }
    pub fn indent(self: GuiContext) void { self._b.indentFn(); }
    pub fn unindent(self: GuiContext) void { self._b.unindentFn(); }
    pub fn button(self: GuiContext, label: []const u8) bool { return self._b.buttonFn(label); }
    pub fn buttonId(self: GuiContext, id: []const u8, label: []const u8) bool { return self._b.buttonIdFn(id, label); }
    pub fn checkbox(self: GuiContext, label: []const u8, value: bool) bool { return self._b.checkboxFn(label, value); }
    pub fn slider(self: GuiContext, label: []const u8, value: f64, min: f64, max: f64) f64 { return self._b.sliderFn(label, value, min, max); }
    pub fn input(self: GuiContext, label: []const u8, value: []const u8) []const u8 { return self._b.inputFn(label, value); }
    pub fn inputMultiline(self: GuiContext, label: []const u8, value: []const u8, width: f64, height: f64) []const u8 { return self._b.inputMultilineFn(label, value, width, height); }
    pub fn selectable(self: GuiContext, label: []const u8) bool { return self._b.selectableFn(label); }
    pub fn textColored(self: GuiContext, r: f64, gv: f64, b_: f64, a: f64, s: []const u8) void {
        self._b.textColoredFn(@floatCast(r), @floatCast(gv), @floatCast(b_), @floatCast(a), s);
    }
    pub fn beginTable(self: GuiContext, id: []const u8, cols: i64) bool { return self._b.beginTableFn(id, cols); }
    pub fn tableSetupColumn(self: GuiContext, label: []const u8) void { self._b.tableSetupColumnFn(label); }
    pub fn tableHeadersRow(self: GuiContext) void { self._b.tableHeadersRowFn(); }
    pub fn tableNextRow(self: GuiContext) void { self._b.tableNextRowFn(); }
    pub fn tableNextColumn(self: GuiContext) void { self._b.tableNextColumnFn(); }
    pub fn endTable(self: GuiContext) void { self._b.endTableFn(); }
    // Row the user has selected in the table (-1: none) / row double-clicked since
    // the last call (-1: none). libui-ng backend only; tui returns -1.
    pub fn tableSelectedRow(self: GuiContext, id: []const u8) i64 { return self._b.tableSelectedRowFn(id); }
    pub fn tableActivatedRow(self: GuiContext, id: []const u8) i64 { return self._b.tableActivatedRowFn(id); }
    pub fn childWindow(self: GuiContext, id: []const u8, w: f64, h: f64, callback: anytype) void {
        const _vis = self._b.beginChildFn(id, w, h);
        if (_vis) {
            if (comptime _zbr_is_fnlike(@TypeOf(callback))) callback(self) else callback.call(self);  // fn OR fn pointer (matches the preamble; the section had drifted — 09-08)
        }
        self._b.endChildFn();
    }
    pub fn treeNode(self: GuiContext, label: []const u8) bool { return self._b.treeNodeFn(label); }
    pub fn treePop(self: GuiContext) void { self._b.treePopFn(); }
    pub fn setColor(self: GuiContext, role: []const u8, r: f64, g: f64, b: f64, a: f64) void {
        self._b.setColorFn(role, @floatCast(r), @floatCast(g), @floatCast(b), @floatCast(a));
    }
    pub fn setColorsDark(self: GuiContext) void { self._b.setColorsDarkFn(); }
    pub fn setStyleFloat(self: GuiContext, name: []const u8, value: f64) void {
        self._b.setStyleFloatFn(name, @floatCast(value));
    }
    pub fn setVec2(self: GuiContext, name: []const u8, x: f64, y: f64) void {
        self._b.setVec2Fn(name, @floatCast(x), @floatCast(y));
    }
    pub fn scaleAllSizes(self: GuiContext, scale: f64) void {
        self._b.scaleAllSizesFn(@floatCast(scale));
    }
    pub fn getDpi(self: GuiContext) f64 { return @floatCast(self._b.getDpiFn()); }
    pub fn panel(self: GuiContext, label: []const u8, callback: anytype) void {
        if (self._b.beginPanelFn(label)) {
            if (comptime _zbr_is_fnlike(@TypeOf(callback))) callback(self) else callback.call(self);  // fn OR fn pointer (matches the preamble; the section had drifted — 09-08)
            self._b.endPanelFn();
        }
    }
    // The open/close pair QUICKSTART documents (a titled group box); until 2026-09-17
    // only the callback form existed and the doc example could not compile.
    pub fn beginPanel(self: GuiContext, label: []const u8) bool { return self._b.beginPanelFn(label); }
    pub fn endPanel(self: GuiContext, label: []const u8) void { _ = label; self._b.endPanelFn(); }
    pub fn window(self: GuiContext, label: []const u8, callback: anytype) void {
        if (self._b.beginWindowFn(label)) {
            if (comptime _zbr_is_fnlike(@TypeOf(callback))) callback(self) else callback.call(self);  // fn OR fn pointer (matches the preamble; the section had drifted — 09-08)
            self._b.endWindowFn();
        }
    }
    pub fn beginHBox(self: GuiContext, id: []const u8, stretch: bool) void { self._b.beginHBoxFn(id, stretch); }
    pub fn endHBox(self: GuiContext) void { self._b.endHBoxFn(); }
    pub fn beginVBox(self: GuiContext, id: []const u8, stretch: bool) void { self._b.beginVBoxFn(id, stretch); }
    pub fn endVBox(self: GuiContext) void { self._b.endVBoxFn(); }
    // Tabs (libui uiTab). A page is inserted at its emission ordinal the first frame
    // the view emits it, removed the frame the view stops, and re-inserted when it
    // comes back -- so page order follows the view's order. A page's label follows
    // the view too (uiTabSetName, torial's libui-ng fork; upstream fixes a label at
    // Append). tabSelected reads the user's choice (-1 with no pages); selectTab sets
    // it. Both index pages in emission order.
    pub fn beginTabs(self: GuiContext, id: []const u8, stretch: bool) void { self._b.beginTabsFn(id, stretch); }
    pub fn beginTabPage(self: GuiContext, id: []const u8, label: []const u8) void { self._b.beginTabPageFn(id, label); }
    pub fn endTabPage(self: GuiContext) void { self._b.endTabPageFn(); }
    pub fn endTabs(self: GuiContext) void { self._b.endTabsFn(); }
    pub fn tabSelected(self: GuiContext, id: []const u8) i64 { return self._b.tabSelectedFn(id); }
    pub fn selectTab(self: GuiContext, id: []const u8, index: i64) void { self._b.selectTabFn(id, index); }
    // Minimum-size hint for an id-keyed widget (box, tab strip, panel, editor,
    // button, input): 0 = none. libui had no size hints; uiControlSetMinSize is the
    // torial fork's. The tui backend ignores it.
    pub fn minSize(self: GuiContext, id: []const u8, width: i64, height: i64) void { self._b.minSizeFn(id, width, height); }
    // Window-wide key chords, the CodeEditor's hotkey/takeKey convention lifted to
    // the window (uiWindowOnKey, torial libui-ng fork): a registered chord is
    // consumed wherever the focus is and queued; takeKey pops (mods << 16) | vk, or 0.
    pub fn hotkey(self: GuiContext, vk: i64, mods: i64) void { self._b.hotkeyFn(vk, mods); }
    pub fn takeKey(self: GuiContext) i64 { return self._b.takeKeyFn(); }
    // ── message-carrying forms (§6b): the widget carries the Msg it sends ──
    // A button that sends `msg` when clicked. (`button(label)` -> bool is the bridge
    // form and goes away in §6c, when this becomes `button`.)
    pub fn action(self: GuiContext, label: []const u8, msg: anytype) void {
        const _T = switch (@TypeOf(msg)) { comptime_int => i64, comptime_float => f64, else => @TypeOf(msg) };
        const _v: _T = msg;
        if (self._send_fn) |f| self._b.actionFn(label, @ptrCast(&_v), @sizeOf(_T), f, self._send_ptr.?);
    }
    // A checkbox; `on` is a Zebra closure `def(checked: bool): Msg` called when it flips.
    pub fn toggle(self: GuiContext, label: []const u8, checked: bool, on: anytype) void {
        // a bare fn (a non-capturing lambda) has no size: store its POINTER; a
        // closure struct is stored by value (fn-twins: the fn-or-pointer test is _zbr_is_fnlike's)
        const bare = comptime (_zbr_is_fnlike(@TypeOf(on)) and @typeInfo(@TypeOf(on)) != .pointer);
        const On = if (bare) *const @TypeOf(on) else @TypeOf(on);
        const payload: On = if (bare) &on else on;
        const Thunk = struct {
            fn call(cap: *const anyopaque, value: bool, send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, send_ptr: *anyopaque) void {
                const f: *const On = @ptrCast(@alignCast(cap));
                const msg = if (comptime _zbr_is_fnlike(On)) f.*(value) else blk: { var c = f.*; break :blk c.call(value); };
                const _v: @TypeOf(msg) = msg;
                send_fn(send_ptr, @ptrCast(&_v), @sizeOf(@TypeOf(_v)));
            }
        };
        if (self._send_fn) |f| self._b.toggleFn(label, checked, @ptrCast(&payload), @sizeOf(On), Thunk.call, f, self._send_ptr.?);
    }
    // A text entry; `on` is `def(text: str): Msg`, called on every change.
    pub fn field(self: GuiContext, label: []const u8, initial: []const u8, on: anytype) void {
        // a bare fn (a non-capturing lambda) has no size: store its POINTER; a
        // closure struct is stored by value (fn-twins: the fn-or-pointer test is _zbr_is_fnlike's)
        const bare = comptime (_zbr_is_fnlike(@TypeOf(on)) and @typeInfo(@TypeOf(on)) != .pointer);
        const On = if (bare) *const @TypeOf(on) else @TypeOf(on);
        const payload: On = if (bare) &on else on;
        const Thunk = struct {
            fn call(cap: *const anyopaque, value: []const u8, send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, send_ptr: *anyopaque) void {
                const f: *const On = @ptrCast(@alignCast(cap));
                const msg = if (comptime _zbr_is_fnlike(On)) f.*(value) else blk: { var c = f.*; break :blk c.call(value); };
                const _v: @TypeOf(msg) = msg;
                send_fn(send_ptr, @ptrCast(&_v), @sizeOf(@TypeOf(_v)));
            }
        };
        if (self._send_fn) |f| self._b.fieldFn(label, initial, @ptrCast(&payload), @sizeOf(On), Thunk.call, f, self._send_ptr.?);
    }
    // ── menus (§6b): declared in the first render, before the window exists ──
    pub fn beginMenu(self: GuiContext, name: []const u8) void { self._b.beginMenuFn(name); }
    pub fn menuItem(self: GuiContext, label: []const u8, msg: anytype) void {
        const _T = switch (@TypeOf(msg)) { comptime_int => i64, comptime_float => f64, else => @TypeOf(msg) };
        const _v: _T = msg;
        if (self._send_fn) |f| self._b.menuItemFn(label, @ptrCast(&_v), @sizeOf(_T), f, self._send_ptr.?);
    }
    pub fn menuSeparator(self: GuiContext) void { self._b.menuSeparatorFn(); }
    pub fn menuQuit(self: GuiContext) void { self._b.menuQuitFn(); }
    pub fn endMenu(self: GuiContext) void { self._b.endMenuFn(); }
    pub fn vbox(self: GuiContext, id: []const u8, stretch: bool) _GuiVBox { return .{ ._b = self._b, ._id = id, ._stretch = stretch }; }
    pub fn hbox(self: GuiContext, id: []const u8, stretch: bool) _GuiHBox { return .{ ._b = self._b, ._id = id, ._stretch = stretch }; }
    pub fn progressBar(self: GuiContext, label: []const u8, value: f64) void { self._b.progressBarFn(label, value); }
    pub fn combobox(self: GuiContext, label: []const u8, items: std.ArrayList([]const u8), selected: i64) i64 { return self._b.comboboxFn(label, items.items, selected); }
    pub fn spinbox(self: GuiContext, label: []const u8, value: i64, min: i64, max: i64) i64 { return self._b.spinboxFn(label, value, min, max); }
    pub fn openFile(self: GuiContext) ?[]const u8 { return self._b.openFileFn(); }
    pub fn saveFile(self: GuiContext) ?[]const u8 { return self._b.saveFileFn(); }
    pub fn openFolder(self: GuiContext) ?[]const u8 { return self._b.openFolderFn(); }
    pub fn msgBox(self: GuiContext, title: []const u8, description: []const u8) void { self._b.msgBoxFn(title, description); }
    pub fn msgBoxError(self: GuiContext, title: []const u8, description: []const u8) void { self._b.msgBoxErrorFn(title, description); }
};
const _GuiVBox = struct {
    _b: *const _GuiBackend,
    _id: []const u8,
    _stretch: bool,
    pub fn begin(self: _GuiVBox) void { self._b.beginVBoxFn(self._id, self._stretch); }
    pub fn end(self: _GuiVBox) void { self._b.endVBoxFn(); }
};
const _GuiHBox = struct {
    _b: *const _GuiBackend,
    _id: []const u8,
    _stretch: bool,
    pub fn begin(self: _GuiHBox) void { self._b.beginHBoxFn(self._id, self._stretch); }
    pub fn end(self: _GuiHBox) void { self._b.endHBoxFn(); }
};
const Gui = GuiContext;
fn _gui_run(title: []const u8, width: i64, height: i64, frame: anytype) void {
    _gui_active_backend.initFn(title, width, height) catch @panic("gui init failed");
    defer _gui_active_backend.deinitFn();
    const _g = GuiContext{ ._b = &_gui_active_backend, .lowLevel = .{ ._b = &_gui_active_backend } };
    if (comptime _zbr_is_fnlike(@TypeOf(frame))) {
        while (_gui_active_backend.newFrameFn()) {
            frame(_g);
            _gui_active_backend.endFrameFn();
        }
    } else {
        var _mframe = frame;
        while (_gui_active_backend.newFrameFn()) {
            _mframe.call(_g);
            _gui_active_backend.endFrameFn();
        }
    }
}
// The send-function a scoped child's `g` carries (see GuiContext.scope). One instance per
// (parent send, parent queue, map) triple, allocated ONCE and kept for the life of the
// program: a retained-mode callback registered inside the child (`g.action`) stores this
// pointer and fires it from a later event, long after scope() has returned, so it cannot
// live on scope()'s stack. Two mounts of one child under different maps (`Msg.left`,
// `Msg.right`) are two instances; the same mount re-rendered finds its instance again.
fn _ScopeWrap(comptime MapT: type) type {
    const is_fn = _zbr_is_fnlike(MapT);
    const ChildMsg = if (is_fn) @typeInfo(MapT).@"fn".params[0].type.? else @typeInfo(@TypeOf(MapT.call)).@"fn".params[1].type.?;
    const SendFn = *const fn (*anyopaque, *const anyopaque, usize) void;
    const MapStore = if (is_fn) *const MapT else MapT;
    return struct {
        parent_fn: SendFn,
        parent_ptr: *anyopaque,
        map: MapStore,
        next: ?*@This(),
        var head: ?*@This() = null;
        fn get(pf: SendFn, pp: *anyopaque, map: MapT) *@This() {
            const ms: MapStore = map;
            var it = head;
            while (it) |w| : (it = w.next) {
                if (w.parent_fn == pf and w.parent_ptr == pp and (!is_fn or w.map == ms)) {
                    if (!is_fn) w.map = ms; // a closure: same code, latest captures
                    return w;
                }
            }
            const w = _allocator.create(@This()) catch @panic("OOM");
            w.* = .{ .parent_fn = pf, .parent_ptr = pp, .map = ms, .next = head };
            head = w;
            return w;
        }
        fn send(ctx: *anyopaque, mp: *const anyopaque, len: usize) void {
            const w: *@This() = @ptrCast(@alignCast(ctx));
            var cm: ChildMsg = undefined;
            if (len == @sizeOf(ChildMsg)) {
                cm = (@as(*const ChildMsg, @ptrCast(@alignCast(mp)))).*;
            } else if (comptime @typeInfo(ChildMsg) == .@"union" and @typeInfo(ChildMsg).@"union".tag_type != null) {
                // `ChildMsg.tick` on a union(enum) is the TAG (same accident the root queue handles).
                const Tag = @typeInfo(ChildMsg).@"union".tag_type.?;
                if (len != @sizeOf(Tag)) {
                    std.debug.print("gui: a scoped message of {d} bytes does not match the child Msg type ({d} bytes); dropped\n", .{ len, @sizeOf(ChildMsg) });
                    return;
                }
                const t: *const Tag = @ptrCast(@alignCast(mp));
                switch (t.*) {
                    inline else => |tv| {
                        if (comptime @FieldType(ChildMsg, @tagName(tv)) == void) {
                            cm = @unionInit(ChildMsg, @tagName(tv), {});
                        } else return;
                    },
                }
            } else {
                std.debug.print("gui: a scoped message of {d} bytes does not match the child Msg type ({d} bytes); dropped\n", .{ len, @sizeOf(ChildMsg) });
                return;
            }
            const pm = if (comptime is_fn) w.map(cm) else blk: { var m = w.map; break :blk m.call(cm); };
            const PM = @TypeOf(pm);
            w.parent_fn(w.parent_ptr, @ptrCast(&pm), @sizeOf(PM));
        }
    };
}
fn _gui_mvu_run(title: []const u8, width: i64, height: i64, _mvu_init: anytype, _mvu_update: anytype, _mvu_view: anytype) void {
    _gui_active_backend.initFn(title, width, height) catch @panic("gui init failed");
    defer _gui_active_backend.deinitFn();
    const MsgType = comptime blk: {
        if (_zbr_is_fnlike(@TypeOf(_mvu_update)))
            break :blk @typeInfo(@TypeOf(_mvu_update)).@"fn".params[1].type.?
        else
            break :blk @typeInfo(@TypeOf(@TypeOf(_mvu_update).call)).@"fn".params[2].type.?;
    };
    const _MvuQueue = struct { buf: [32]MsgType = undefined, len: usize = 0 };
    var _pq = _MvuQueue{};
    const _sfn = struct {
        fn send(ctx: *anyopaque, mp: *const anyopaque, len: usize) void {
            const q: *_MvuQueue = @ptrCast(@alignCast(ctx));
            if (q.len >= 32) return;
            if (len == @sizeOf(MsgType)) {
                q.buf[q.len] = (@as(*const MsgType, @ptrCast(@alignCast(mp)))).*;
                q.len += 1;
                return;
            }
            // `Msg.tick` on a union(enum) is the TAG, not the union; build the
            // (payload-less) union from it. Found 2026-09-17: the old queue read the
            // union's size off a one-byte tag and worked by the accident of layout.
            if (comptime @typeInfo(MsgType) == .@"union") {
                if (comptime @typeInfo(MsgType).@"union".tag_type) |Tag| {
                    if (len == @sizeOf(Tag)) {
                        const t: *const Tag = @ptrCast(@alignCast(mp));
                        switch (t.*) {
                            inline else => |tv| {
                                if (comptime @FieldType(MsgType, @tagName(tv)) == void) {
                                    q.buf[q.len] = @unionInit(MsgType, @tagName(tv), {});
                                    q.len += 1;
                                }
                            },
                        }
                        return;
                    }
                }
            }
            std.debug.print("gui: a message of {d} bytes does not match the Msg type ({d} bytes); dropped\n", .{ len, @sizeOf(MsgType) });
        }
    }.send;
    var _model = if (comptime _zbr_is_fnlike(@TypeOf(_mvu_init))) _mvu_init() else blk: { var _m = _mvu_init; break :blk _m.call(); };
    const _g = GuiContext{ ._b = &_gui_active_backend, .lowLevel = .{ ._b = &_gui_active_backend }, ._send_fn = _sfn, ._send_ptr = &_pq };
    // THE FRAME IS AN EVENT (2026-09-17, concept_zebra-gui-declarative). newFrameFn
    // blocks until the toolkit has an event (a click, a change, a subscribed timer).
    // Then: render; while the render sent messages, update for each and render again,
    // so the model change is on screen before the loop blocks. A view that sends on
    // every pass never settles -- that was a heartbeat under the old 100 ms timer and
    // is a livelock here -- so passes are capped and the leftover dropped, once, loudly.
    var _warned_livelock = false;
    while (_gui_active_backend.newFrameFn()) {
        var _passes: usize = 0;
        while (true) {
            // messages first (a subscribed timer or a widget callback may have queued
            // one before this frame started), then render; a render that sends loops.
            if (_pq.len > 0) {
                if (_passes >= 8) {
                    if (!_warned_livelock) {
                        _warned_livelock = true;
                        std.debug.print("gui: the view sent messages on 8 consecutive passes after one event; a heartbeat belongs in g.every(ms, msg), not g.send from view. Dropping the rest.\n", .{});
                    }
                    _pq.len = 0;
                    break;
                }
                const _n = _pq.len;
                var _i: usize = 0;
                while (_i < _n) : (_i += 1) {
                    const msg = _pq.buf[_i];
                    if (comptime _zbr_is_fnlike(@TypeOf(_mvu_update)))
                        _model = _mvu_update(_model, msg)
                    else { var _mu = _mvu_update; _model = _mu.call(_model, msg); }
                }
                if (_pq.len > _n) { std.mem.copyForwards(MsgType, _pq.buf[0 .. _pq.len - _n], _pq.buf[_n.._pq.len]); _pq.len -= _n; } else _pq.len = 0;
                _passes += 1;
            }
            if (comptime _zbr_is_fnlike(@TypeOf(_mvu_view))) _mvu_view(_g, _model) else { var _mv = _mvu_view; _mv.call(_g, _model); }
            _gui_active_backend.endFrameFn();
            if (_pq.len == 0) break;
        }
    }
}
// ─── CodeEditor widget — Scintilla via libui-scintilla ───────────────────────
const _sci = @import("sci");
// BUG-217: the text buffer is kept NUL-TERMINATED — `buf[len] == 0` is an
// invariant, and `buf.len >= len + 1` always holds.
//
// Scintilla's SCI_SETTEXT IGNORES the length it is handed and calls strlen() on
// the pointer (scintilla/src/Editor.cxx: `pdoc->InsertString(0, text, strlen(text))`),
// even though the libui-scintilla binding's signature takes an explicit length.
// So an ordinary `dupe` — which produces no terminator — makes Scintilla read off
// the end of the allocation. The empty case is worse than a stray read: `dupe` of
// an empty slice returns a zero-length slice whose `.ptr` is not a readable
// address at all, so `setText("")` segfaulted immediately (address
// 0xffffffffffffffff). That is what crashed the IDE's Build button, which opens
// with `buildOutputEditor.setText("")`.
//
// SCI_GETTEXTRANGE likewise writes n+1 bytes (it NUL-terminates), so the same
// +1 reservation is what makes the read path safe; the old code reallocated only
// when `n > buf.len`, which let an exactly-full buffer overflow by one byte.
// ─── Zebra syntax styling ──────────────────────────────────────────────────────
// NO LEXER IS USED, and that is forced rather than chosen: the vendored Scintilla
// is version 5, which moved every lexer out of the core into Lexilla, and Lexilla
// is not vendored here (the header has SCI_SETILEXER and no SCI_SETLEXER/SCLEX_*).
// So `SCI_SETLEXER, SCLEX_PYTHON` — the obvious approach — would silently do
// nothing: a wrong message id is not an error in Scintilla, the text just stays
// unstyled, which is indistinguishable from a styler that ran and found nothing.
//
// Instead the text is styled DIRECTLY with SCI_STARTSTYLING / SCI_SETSTYLING from
// a small Zebra tokenizer below. That is a real Zebra tokenizer rather than another
// language's lexer wearing Zebra's keyword list, so the highlighting is honest about
// what it is. Every message id here was read out of the vendored Scintilla.h, not
// recalled.
// ─── STYLER BEGIN (pure: std only; extracted verbatim by tools/styler_test.sh) ───
const _CE_KW_ZEBRA = [_][]const u8{
    "abstract", "adds", "allocate", "and", "arena", "as", "assert", "assert_eq",
    "assert_false", "assert_ne", "assert_true", "bool", "branch", "break", "capture", "catch",
    "char", "class", "const", "continue", "cue", "def", "defer", "else", "ensure", "enum",
    "errdefer", "except", "export", "exposing", "extend", "extern", "false", "float", "for",
    "guard", "has", "if", "implements", "implies", "in", "int", "interface", "invariant", "is",
    "mixin", "namespace", "nil", "not", "on", "or", "orelse", "pass", "print", "private",
    "public", "raise", "readonly", "require", "return", "same", "sig", "static", "struct",
    "test", "this", "throws", "to", "true", "type", "uint", "union", "use", "using", "var",
    "vari", "where", "while", "with"
};
const _CE_KW_C = [_][]const u8{
    "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
    "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register",
    "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
    "union", "unsigned", "void", "volatile", "while", "_Bool", "_Static_assert", "bool", "true",
    "false", "NULL", "size_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t",
    "int16_t", "int32_t", "int64_t", "uintptr_t", "intptr_t", "ptrdiff_t", "ssize_t"
};
const _CE_KW_ZIG = [_][]const u8{
    "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await",
    "break", "callconv", "catch", "comptime", "const", "continue", "defer", "else", "enum",
    "errdefer", "error", "export", "extern", "fn", "for", "if", "inline", "linksection",
    "noalias", "noinline", "nosuspend", "opaque", "or", "orelse", "packed", "pub", "resume",
    "return", "struct", "suspend", "switch", "test", "threadlocal", "try", "union", "unreachable",
    "usingnamespace", "var", "volatile", "while", "true", "false", "null", "undefined",
    "void", "bool", "u8", "i8", "u16", "i16", "u32", "i32", "u64", "i64", "u128", "i128",
    "usize", "isize", "f16", "f32", "f64", "f128", "c_int", "c_uint", "c_long", "c_ulong",
    "c_char", "c_void", "anyerror", "anyopaque", "noreturn", "comptime_int", "comptime_float", "type"
};
// A language is DATA: which comment/string forms exist and which words are keywords.
// The one tokenizer below (`_ce_style`) reads a spec; adding a language is adding a
// row here, not a tokenizer. Controls in examples/styler_smoke.zbr + zebra-ide.
const _CeLangSpec = struct {
    name: []const u8,
    keywords: []const []const u8,
    line_comment: []const u8,      // "#" or "//"; "" = none
    block_comment: bool,           // C-style /* ... */
    preproc: bool,                 // '#' at line start (after blanks) is a preprocessor line
    char_lit: bool,                // 'x' is a char literal (C, Zig), else ' is an operator
    zig_multiline: bool,           // `\\` starts a multiline-string line (Zig)
    builtin_at: bool,              // `@name` is a builtin call (Zig)
    caps_are_types: bool,          // Capitalised identifier = type (Zebra, Zig); C uses typedef style
};
const _CE_LANG_ZEBRA = _CeLangSpec{ .name = "zebra", .keywords = &_CE_KW_ZEBRA, .line_comment = "#", .block_comment = false, .preproc = false, .char_lit = false, .zig_multiline = false, .builtin_at = false, .caps_are_types = true };
const _CE_LANG_C     = _CeLangSpec{ .name = "c",     .keywords = &_CE_KW_C,     .line_comment = "//", .block_comment = true, .preproc = true, .char_lit = true, .zig_multiline = false, .builtin_at = false, .caps_are_types = false };
const _CE_LANG_ZIG   = _CeLangSpec{ .name = "zig",   .keywords = &_CE_KW_ZIG,   .line_comment = "//", .block_comment = false, .preproc = false, .char_lit = true, .zig_multiline = true, .builtin_at = true, .caps_are_types = true };
const _CE_LANG_PLAIN = _CeLangSpec{ .name = "text",  .keywords = &[_][]const u8{}, .line_comment = "", .block_comment = false, .preproc = false, .char_lit = false, .zig_multiline = false, .builtin_at = false, .caps_are_types = false };
fn _ce_spec_by_name(n: []const u8) *const _CeLangSpec {
    if (std.mem.eql(u8, n, "zebra") or std.mem.eql(u8, n, "zbr")) return &_CE_LANG_ZEBRA;
    if (std.mem.eql(u8, n, "c") or std.mem.eql(u8, n, "h") or std.mem.eql(u8, n, "cpp") or std.mem.eql(u8, n, "cxx") or std.mem.eql(u8, n, "cc") or std.mem.eql(u8, n, "hpp")) return &_CE_LANG_C;
    if (std.mem.eql(u8, n, "zig") or std.mem.eql(u8, n, "zon")) return &_CE_LANG_ZIG;
    return &_CE_LANG_PLAIN;
}
// Extension → spec. Unknown extension = plain (nothing styled), never a guess.
fn _ce_spec_for_file(path: []const u8) *const _CeLangSpec {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        const c = path[i - 1];
        if (c == '.') return _ce_spec_by_name(path[i..]);
        if (c == '/' or c == '\\') break;
    }
    return &_CE_LANG_PLAIN;
}

// Style slots. 32 and 33 are Scintilla's own (STYLE_DEFAULT, STYLE_LINENUMBER).
const _CE_S_DEFAULT: usize = 0;
const _CE_S_KEYWORD: usize = 1;
const _CE_S_COMMENT: usize = 2;
const _CE_S_STRING:  usize = 3;
const _CE_S_NUMBER:  usize = 4;
const _CE_S_TYPE:    usize = 5;
const _CE_S_FUNC:    usize = 6;
const _CE_S_OP:      usize = 7;
const _CE_S_PREPROC: usize = 8;

// Scintilla colours are 0xBBGGRR, not RGB — the byte order is the single easiest
// thing to get wrong here, and getting it wrong produces a plausible-looking but
// wrong palette rather than an error.
const _CE_C_BG:      usize = 0x342c28; // #282c34
const _CE_C_FG:      usize = 0xbfb2ab; // #abb2bf
const _CE_C_KEYWORD: usize = 0xdd78c6; // #c678dd
const _CE_C_COMMENT: usize = 0x70635c; // #5c6370
const _CE_C_STRING:  usize = 0x79c398; // #98c379
const _CE_C_NUMBER:  usize = 0x669ad1; // #d19a66
const _CE_C_TYPE:    usize = 0x7bc0e5; // #e5c07b
const _CE_C_FUNC:    usize = 0xefaf61; // #61afef
const _CE_C_OP:      usize = 0xc2b656; // #56b6c2
const _CE_C_PREPROC: usize = 0x9a7de0; // #e07d9a
const _CE_C_LNFG:    usize = 0x63524b; // #4b5263
const _CE_C_LNBG:    usize = 0x2f2823;
const _CE_C_CARETLN: usize = 0x3e3630;
const _CE_C_SEL:     usize = 0x584c3f;

fn _ce_is_kw(spec: *const _CeLangSpec, w: []const u8) bool {
    for (spec.keywords) |k| if (std.mem.eql(u8, k, w)) return true;
    return false;
}
fn _ce_starts(src: []const u8, i: usize, pat: []const u8) bool {
    return pat.len > 0 and i + pat.len <= src.len and std.mem.eql(u8, src[i .. i + pat.len], pat);
}
fn _ce_alpha(c: u8) bool { return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'; }
fn _ce_digit(c: u8) bool { return c >= '0' and c <= '9'; }
fn _ce_opch(c: u8) bool {
    return switch (c) { '+', '-', '*', '/', '=', '<', '>', '!', '&', '|', '^', '~', '?', ':', '.', ',', '(', ')', '[', ']', '{', '}' => true, else => false };
}
// The tokenizer proper. Pure: writes one style byte per source byte into `out`
// (out.len == src.len). Tested headless by tools/styler_test.sh with the three
// controls from the IDE plan (C `#` in a string, Zig `\\\\`, Zebra `${}`).
fn _ce_tokenize(spec: *const _CeLangSpec, src: []const u8, out: []u8) void {
    var i: usize = 0;
    var line_start = true;   // only blanks seen since the last newline
    while (i < src.len) {
        const start = i;
        const c = src[i];
        var sty: u8 = @intCast(_CE_S_DEFAULT);
        if (c == '\n') {
            i += 1; line_start = true;
        } else if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
        } else if (spec.preproc and line_start and c == '#') {
            while (i < src.len and src[i] != '\n') i += 1;
            sty = @intCast(_CE_S_PREPROC); line_start = false;
        } else if (_ce_starts(src, i, spec.line_comment)) {
            while (i < src.len and src[i] != '\n') i += 1;
            sty = @intCast(_CE_S_COMMENT); line_start = false;
        } else if (spec.block_comment and _ce_starts(src, i, "/*")) {
            i += 2;
            while (i < src.len and !_ce_starts(src, i, "*/")) i += 1;
            if (i < src.len) i += 2;
            sty = @intCast(_CE_S_COMMENT); line_start = false;
        } else if (spec.zig_multiline and _ce_starts(src, i, "\\\\")) {
            while (i < src.len and src[i] != '\n') i += 1;
            sty = @intCast(_CE_S_STRING); line_start = false;
        } else if (c == '"' or (spec.char_lit and c == '\'')) {
            const q = c;
            i += 1;
            while (i < src.len and src[i] != q and src[i] != '\n') {
                if (src[i] == '\\' and i + 1 < src.len) i += 1;
                i += 1;
            }
            if (i < src.len and src[i] == q) i += 1;
            sty = @intCast(_CE_S_STRING); line_start = false;
        } else if (_ce_digit(c)) {
            while (i < src.len and (_ce_digit(src[i]) or _ce_alpha(src[i]) or src[i] == '.')) i += 1;
            sty = @intCast(_CE_S_NUMBER); line_start = false;
        } else if (spec.builtin_at and c == '@' and i + 1 < src.len and _ce_alpha(src[i + 1])) {
            i += 1;
            while (i < src.len and (_ce_alpha(src[i]) or _ce_digit(src[i]))) i += 1;
            sty = @intCast(_CE_S_FUNC); line_start = false;
        } else if (_ce_alpha(c)) {
            while (i < src.len and (_ce_alpha(src[i]) or _ce_digit(src[i]))) i += 1;
            const w = src[start..i];
            if (_ce_is_kw(spec, w)) {
                sty = @intCast(_CE_S_KEYWORD);
            } else if (spec.caps_are_types and w[0] >= 'A' and w[0] <= 'Z') {
                sty = @intCast(_CE_S_TYPE);
            } else {
                var j = i;
                while (j < src.len and src[j] == ' ') j += 1;
                sty = if (j < src.len and src[j] == '(') @intCast(_CE_S_FUNC) else @intCast(_CE_S_DEFAULT);
            }
            line_start = false;
        } else if (_ce_opch(c)) {
            i += 1; sty = @intCast(_CE_S_OP); line_start = false;
        } else {
            i += 1; line_start = false;
        }
        @memset(out[start..i], sty);
    }
}
// ─── STYLER END ───

// One-time visual setup: margin, font, palette, caret line. Everything here is
// core Scintilla and needs no lexer.
fn _ce_configure(_s: *_sci.Scintilla) void {
    _ = _s.sendMessage(2037, 65001, 0);                                  // SCI_SETCODEPAGE utf-8
    _ = _s.sendMessage(2056, 32, @intFromPtr("Consolas".ptr));           // STYLE_DEFAULT font
    _ = _s.sendMessage(2055, 32, 11);                                    // ...size
    _ = _s.sendMessage(2051, 32, _CE_C_FG);                              // ...fore
    _ = _s.sendMessage(2052, 32, _CE_C_BG);                              // ...back
    _ = _s.sendMessage(2050, 0, 0);                                      // SCI_STYLECLEARALL -> all styles
    _ = _s.sendMessage(2051, _CE_S_KEYWORD, _CE_C_KEYWORD);
    _ = _s.sendMessage(2053, _CE_S_KEYWORD, 1);                          // SCI_STYLESETBOLD
    _ = _s.sendMessage(2051, _CE_S_COMMENT, _CE_C_COMMENT);
    _ = _s.sendMessage(2054, _CE_S_COMMENT, 1);                          // SCI_STYLESETITALIC
    _ = _s.sendMessage(2051, _CE_S_STRING,  _CE_C_STRING);
    _ = _s.sendMessage(2051, _CE_S_NUMBER,  _CE_C_NUMBER);
    _ = _s.sendMessage(2051, _CE_S_TYPE,    _CE_C_TYPE);
    _ = _s.sendMessage(2051, _CE_S_FUNC,    _CE_C_FUNC);
    _ = _s.sendMessage(2051, _CE_S_OP,      _CE_C_OP);
    _ = _s.sendMessage(2051, _CE_S_PREPROC, _CE_C_PREPROC);
    _ = _s.sendMessage(2051, 33, _CE_C_LNFG);                            // STYLE_LINENUMBER fore
    _ = _s.sendMessage(2052, 33, _CE_C_LNBG);                            // ...back
    _ = _s.sendMessage(2240, 0, 1);                                      // margin 0 = SC_MARGIN_NUMBER
    _ = _s.sendMessage(2242, 0, 56);                                     // ...width px
    _ = _s.sendMessage(2096, 1, 0);                                      // SCI_SETCARETLINEVISIBLE
    _ = _s.sendMessage(2098, _CE_C_CARETLN, 0);                          // SCI_SETCARETLINEBACK
    _ = _s.sendMessage(2068, 1, _CE_C_SEL);                              // SCI_SETSELBACK
    _ = _s.sendMessage(2036, 4, 0);                                      // SCI_SETTABWIDTH
}

// Style the whole buffer in one pass, driven by the editor's language spec.
// Styles are accumulated into a scratch byte array and handed to Scintilla in ONE
// SCI_SETSTYLINGEX call (measured: one message instead of one per token — the
// per-token form is what made a whole-file restyle visible on the laptop).
//
// Re-style trigger: the pinned zig-libui-ng routes no Scintilla WM_NOTIFY (the
// notify shim exists locally, unpushed, and is @hasDecl-guarded below), so a poll
// is the baseline. `_code_editor_render` (called every frame) asks
// SCI_GETENDSTYLED: Scintilla moves that watermark back to the edit position on
// every insert/delete, so `endStyled < length` is an exact "text changed since
// last styling" test that needs no event. Whole-buffer restyle keeps block
// comments and multi-line strings honest without a state-per-line table.
var _ce_style_scratch: []u8 = &.{};
fn _ce_style(_ed: *_CodeEditor) void {
    const _s = _ed.scint orelse return;
    if (_ed.len == 0) return;
    const src = _ed.buf[0.._ed.len];
    if (_ce_style_scratch.len < src.len) {
        const nb = _allocator.alloc(u8, src.len + 4096) catch return;
        if (_ce_style_scratch.len != 0) _allocator.free(_ce_style_scratch);
        _ce_style_scratch = nb;
    }
    const out = _ce_style_scratch[0..src.len];
    _ce_tokenize(_ed.spec, src, out);
    _ = _s.sendMessage(2032, 0, 0);                                      // SCI_STARTSTYLING at 0
    _ = _s.sendMessage(2073, src.len, @intFromPtr(out.ptr));             // SCI_SETSTYLINGEX len, styles
}
// Pull the live text back from Scintilla and restyle it, but only if the
// end-styled watermark says something changed. Cheap when nothing did: two messages.
fn _ce_restyle_if_dirty(_ed: *_CodeEditor) void {
    const _s = _ed.scint orelse return;
    const n = _s.getLength();
    if (n == 0) return;
    if (_s.sendMessage(2028, 0, 0) >= n) return;                         // SCI_GETENDSTYLED
    _ = _code_editor_get_text(_ed);
    _ce_style(_ed);
}
fn _code_editor_restyle(_ed: *_CodeEditor) void {
    if (_ed.scint == null) return;
    _ = _code_editor_get_text(_ed);
    _ce_style(_ed);
}
fn _code_editor_set_language(_ed: *_CodeEditor, name: []const u8) void {
    _ed.spec = _ce_spec_by_name(name);
    _code_editor_restyle(_ed);
}
fn _code_editor_get_language(_ed: *_CodeEditor) []const u8 { return _ed.spec.name; }

const _CodeEditor = struct {
    scint: ?*_sci.Scintilla = null,
    read_only: bool = false,
    buf: []u8 = &.{},
    len: usize = 0,
    spec: *const _CeLangSpec = &_CE_LANG_ZEBRA,
    // Event bridge. libui delivers Scintilla's WM_NOTIFY through uiScintillaOnNotify
    // (zig-libui-ng libui_scintilla/win.cxx); the callback below only records, and
    // the Zebra program takes the records from its tick: takeModified(),
    // takeCharAdded(), takeMarginClick(). Recording rather than calling back into
    // Zebra keeps MVU's rule that the model changes only inside update().
    ev_modified: bool = false,
    ev_char: i64 = 0,
    ev_margin_line: i64 = -1,
    ev_margin: i64 = -1,
    // Keys (09-08). `hotkey(vk, mods)` registers a chord the program wants; the
    // shim asks _ce_on_key before Scintilla sees any key-down, registered chords
    // are CONSUMED and queued, everything else passes through untouched (so
    // Scintilla's own Ctrl+C/V/Z/… keep working unless the program claims them).
    // `takeKey()` pops one queued chord as (mods << 16) | vk, or 0.
    hot: [32]u32 = [_]u32{0} ** 32,
    hot_n: usize = 0,
    keys: [16]u32 = [_]u32{0} ** 16,
    key_n: usize = 0,
};
const _CeNotification = if (@hasDecl(_sci.Scintilla, "Notification")) _sci.Scintilla.Notification else struct { code: c_uint = 0, modificationType: c_int = 0, ch: c_int = 0, margin: c_int = 0, position: isize = 0 };
fn _ce_on_notify(_s: *_sci.Scintilla, n: *const _CeNotification, _edp: ?*_CodeEditor) anyerror!void {
    _ = _s;
    const _ed = _edp orelse return;
    switch (n.code) {
        2008 => { if ((n.modificationType & 0x3) != 0) _ed.ev_modified = true; },     // SCN_MODIFIED, insert|delete
        2001 => { _ed.ev_char = n.ch; },                                              // SCN_CHARADDED
        2010 => {                                                                     // SCN_MARGINCLICK
            _ed.ev_margin = n.margin;
            _ed.ev_margin_line = @intCast(_ed.scint.?.sendMessage(2166, @intCast(@max(0, n.position)), 0)); // SCI_LINEFROMPOSITION
        },
        else => {},
    }
}
fn _ce_on_key(_s: *_sci.Scintilla, vk: c_int, mods: c_int, _edp: ?*_CodeEditor) bool {
    _ = _s;
    const _ed = _edp orelse return false;
    const _chord: u32 = (@as(u32, @intCast(mods & 0xffff)) << 16) | @as(u32, @intCast(vk & 0xffff));
    var i: usize = 0;
    while (i < _ed.hot_n) : (i += 1) {
        if (_ed.hot[i] == _chord) {
            if (_ed.key_n < _ed.keys.len) { _ed.keys[_ed.key_n] = _chord; _ed.key_n += 1; }
            return true;
        }
    }
    return false;
}
fn _code_editor_hotkey(_ed: *_CodeEditor, vk: i64, mods: i64) void {
    if (_ed.hot_n >= _ed.hot.len) return;
    const _chord: u32 = (@as(u32, @intCast(mods & 0xffff)) << 16) | @as(u32, @intCast(vk & 0xffff));
    var i: usize = 0;
    while (i < _ed.hot_n) : (i += 1) if (_ed.hot[i] == _chord) return;
    _ed.hot[_ed.hot_n] = _chord;
    _ed.hot_n += 1;
}
fn _code_editor_take_key(_ed: *_CodeEditor) i64 {
    if (_ed.key_n == 0) return 0;
    const v = _ed.keys[0];
    var i: usize = 1;
    while (i < _ed.key_n) : (i += 1) _ed.keys[i - 1] = _ed.keys[i];
    _ed.key_n -= 1;
    return @intCast(v);
}
fn _code_editor_take_modified(_ed: *_CodeEditor) bool { const v = _ed.ev_modified; _ed.ev_modified = false; return v; }
fn _code_editor_take_char_added(_ed: *_CodeEditor) i64 { const v = _ed.ev_char; _ed.ev_char = 0; return v; }
fn _code_editor_take_margin_click(_ed: *_CodeEditor) i64 { const v = _ed.ev_margin_line; _ed.ev_margin_line = -1; return v; }
// Ensure room for `need` bytes of text PLUS the terminator. Returns false only on OOM.
fn _ce_reserve(_ed: *_CodeEditor, need: usize) bool {
    if (_ed.buf.len >= need + 1) return true;
    const _nb = _allocator.alloc(u8, need + 1) catch return false;
    if (_ed.buf.len != 0) _allocator.free(_ed.buf);
    _ed.buf = _nb;
    return true;
}
fn _code_editor_new() *_CodeEditor {
    const _ed = _allocator.create(_CodeEditor) catch unreachable;
    _ed.* = .{};
    // Establish the invariant up front so every later path can hand Scintilla a
    // terminated pointer without a special case for "never set".
    if (_ce_reserve(_ed, 0)) _ed.buf[0] = 0;
    return _ed;
}
fn _code_editor_new_lang(name: []const u8) *_CodeEditor {
    const _ed = _code_editor_new();
    _ed.spec = _ce_spec_by_name(name);
    return _ed;
}
fn _code_editor_new_for_file(path: []const u8) *_CodeEditor {
    const _ed = _code_editor_new();
    _ed.spec = _ce_spec_for_file(path);
    return _ed;
}
fn _code_editor_set_text(_ed: *_CodeEditor, text: []const u8) void {
    if (!_ce_reserve(_ed, text.len)) return;
    @memcpy(_ed.buf[0..text.len], text);
    _ed.buf[text.len] = 0;
    _ed.len = text.len;
    if (_ed.scint) |_s| {
        _s.setText(_ed.buf[0.._ed.len]);
        _ce_style(_ed);
    }
}
fn _code_editor_get_text(_ed: *_CodeEditor) []const u8 {
    if (_ed.scint) |_s| {
        const _n = _s.getLength();
        if (!_ce_reserve(_ed, _n)) return _ed.buf[0.._ed.len];
        if (_n > 0) _s.getRange(0, _n, _ed.buf.ptr) else _ed.buf[0] = 0;
        _ed.len = _n;
    }
    if (_ed.buf.len == 0) return "";
    return _ed.buf[0.._ed.len];
}
fn _code_editor_set_readonly(_ed: *_CodeEditor, v: bool) void {
    _ed.read_only = v;
    if (_ed.scint) |_s| _ = _s.sendMessage(2171, @intFromBool(v), 0);
}
fn _code_editor_render(_ed: *_CodeEditor, _g: GuiContext, id: []const u8, _w: f64, _h: f64) void {
    _ = id; _ = _w; _ = _h; _ = _g;
    if (_ed.scint == null) {
        _ed.scint = _sci.Scintilla.new() catch return;
        // Safe unconditionally now: `buf[len] == 0` holds even when len == 0
        // (the old code had to skip the empty case to avoid the strlen crash).
        _ce_configure(_ed.scint.?);
        // Bindings older than zig-libui-ng's notify shim have no OnNotify; the
        // guard keeps the section compiling against the currently pinned package
        // (events simply never fire, and the IDE's fallback polling carries on).
        if (comptime @hasDecl(_sci.Scintilla, "OnNotify")) _ed.scint.?.OnNotify(_CodeEditor, anyerror, _ce_on_notify, _ed);
        if (comptime @hasDecl(_sci.Scintilla, "OnKey")) _ed.scint.?.OnKey(_CodeEditor, _ce_on_key, _ed);
        if (_ed.buf.len > 0) {
            _ed.scint.?.setText(_ed.buf[0.._ed.len]);
            _ce_style(_ed);
        }
        if (_ed.read_only) _ = _ed.scint.?.sendMessage(2171, 1, 0);
    } else {
        _ce_restyle_if_dirty(_ed);
    }
    // the editor is a node keyed by its own address (one _CodeEditor, one control,
    // whatever id the view passes); the tree inserts it where the view emits it
    _lui_editor_node(_ed);
}
fn _code_editor_set_error_markers(_ed: *_CodeEditor, _m: anytype) void { _ = _ed; _ = _m; }
fn _code_editor_get_cursor_line(_ed: *_CodeEditor) i64 {
    const _s = _ed.scint orelse return 1;
    const _pos = _s.sendMessage(2008, 0, 0);
    return @intCast(_s.sendMessage(2166, _pos, 0) + 1);
}
fn _code_editor_get_cursor_col(_ed: *_CodeEditor) i64 {
    const _s = _ed.scint orelse return 1;
    const _pos = _s.sendMessage(2008, 0, 0);
    return @intCast(_s.sendMessage(2129, _pos, 0) + 1);
}
fn _code_editor_set_cursor_position(_ed: *_CodeEditor, line: i64, col: i64) void {
    _ = col;
    const _s = _ed.scint orelse return;
    _ = _s.sendMessage(2024, @intCast(@max(0, line - 1)), 0);
}
// ─── The hatch: raw Scintilla messages from Zebra (zebra-ide plan §2) ───────
// Every editor feature Scintilla already has (markers, folding, indicators,
// document pointers, find, zoom, ...) is a message + constants; exposing ONE
// generic send lets the IDE be a Zebra program instead of two more compiler
// builtins per feature. Unknown message ids are silently ignored by Scintilla
// (returns 0), so callers that can read a value back should — see Sci.zbr.
fn _code_editor_sci(_ed: *_CodeEditor, msg: i64, wparam: i64, lparam: i64) i64 {
    const _s = _ed.scint orelse return 0;
    return @bitCast(_s.sendMessage(@intCast(msg), @bitCast(wparam), @bitCast(lparam)));
}
// String lParam form: the text is copied to a NUL-terminated buffer that outlives
// the call (Scintilla reads lParam as `const char*` for SETTEXT/INSERTTEXT/
// SEARCHINTARGET/MARKERDEFINE etc.). wparam is passed through unchanged.
fn _code_editor_sci_str(_ed: *_CodeEditor, msg: i64, wparam: i64, text: []const u8) i64 {
    const _s = _ed.scint orelse return 0;
    const _z = _allocator.dupeZ(u8, text) catch return 0;
    defer _allocator.free(_z);
    return @bitCast(_s.sendMessage(@intCast(msg), @bitCast(wparam), @intFromPtr(_z.ptr)));
}
// ─── libui-ng retained-mode adapter: THE TREE (2026-09-17) ───────────────────
// concept_zebra-gui-declarative §3. Every g.* call adds a NODE under the open
// container; a node matches the retained node of the same kind at the same key (an
// `##id`, a label) or, without a key, at the same position among its siblings. A
// match updates only what differs (a label's text, an entry's text if the widget
// does not already show it); a miss creates the control and inserts it at the
// node's position (uiBoxInsertAt, uiTabInsertAt -- both the fork's); a retained
// node the view did not revisit is removed when its container closes. There is no
// hiding, no frame-0 rule, no positional counter: a box that appears is a child
// inserted where it appears. The seven caches this replaced are gone.
const _ui = @import("ui");
const _LuiKind = enum { root, hbox, vbox, panel, tabs, page, text, sep, button, checkbox, slider, input, input_ml, combobox, spinbox, progress, editor, table };
const _LuiNode = struct {
    kind: _LuiKind,
    key: []const u8 = "",
    ctrl: ?*_ui.Control = null,     // what sits in the parent (box child / tab page)
    box: ?*_ui.Box = null,          // containers: where the children go
    tab: ?*_ui.Tab = null,
    children: std.ArrayList(*_LuiNode) = .empty,
    seen: u32 = 0,
    stretch: bool = false,
    // per-kind state; the bridge (§2) reads these in the frame an event caused
    clicked: bool = false,
    checked: bool = false,
    sval: c_int = 0,
    smin: f64 = 0,
    smax: f64 = 1,
    text_buf: [1024]u8 = undefined,  // entry text; a button's / page's label
    text_len: usize = 0,
    lbl: ?*_ui.Label = null,
    btn: ?*_ui.Button = null,
    chk: ?*_ui.Checkbox = null,
    sld: ?*_ui.Slider = null,
    ent: ?*_ui.Entry = null,
    mle: ?*_ui.MultilineEntry = null,
    cmb: ?*_ui.Combobox = null,
    spn: ?*_ui.Spinbox = null,
    pb: ?*_ui.ProgressBar = null,
    grp: ?*_ui.Group = null,
    ed: ?*_CodeEditor = null,
    table: ?*_LuiTable = null,
    // message-carrying forms: the Msg bytes / the closure bytes + its thunk
    msg: [64]u8 align(16) = undefined,
    msg_len: usize = 0,
    cap: [128]u8 align(16) = undefined,
    cap_len: usize = 0,
    thunk_b: ?*const fn (*const anyopaque, bool, *const fn (*anyopaque, *const anyopaque, usize) void, *anyopaque) void = null,
    thunk_s: ?*const fn (*const anyopaque, []const u8, *const fn (*anyopaque, *const anyopaque, usize) void, *anyopaque) void = null,
    send_fn: ?*const fn (*anyopaque, *const anyopaque, usize) void = null,
    send_ptr: ?*anyopaque = null,
};
var _lui_root: *_LuiNode = undefined;
var _lui_stack: [32]*_LuiNode = undefined;
var _lui_cursor: [32]usize = [_]usize{0} ** 32;
var _lui_depth: usize = 0;
var _lui_keyed: std.StringHashMap(*_LuiNode) = undefined;   // id -> node, for the by-id reads
var _lui_frame: u32 = 0;
var _lui_frame_n: u32 = 1;   // the render being built; a node's `seen` == this means "in it"
var _lui_quit: bool = false;
var _lui_win_w: i64 = 800;
var _lui_win_h: i64 = 600;
var _lui_window: ?*_ui.Window = null;
var _lui_root_box: ?*_ui.Box = null;
var _lui_title: [256]u8 = undefined;
var _lui_title_len: usize = 0;
fn _lui_top() *_LuiNode { return _lui_stack[_lui_depth - 1]; }
fn _lui_cur_box() ?*_ui.Box { return _lui_top().box; }
fn _lui_push(_n: *_LuiNode) void {
    if (_lui_depth < 32) { _lui_stack[_lui_depth] = _n; _lui_cursor[_lui_depth] = 0; _lui_depth += 1; }
}
fn _lui_pop() void {
    if (_lui_depth <= 1) return;
    _lui_depth -= 1;
    _lui_close(_lui_stack[_lui_depth]);
}
fn _lui_reset_stack() void {
    _lui_depth = 0;
    _lui_push(_lui_root);
}
fn _lui_z(_buf: []u8, _s: []const u8) [:0]u8 {
    const _n = @min(_s.len, _buf.len - 1);
    @memcpy(_buf[0.._n], _s[0.._n]);
    _buf[_n] = 0;
    return _buf[0.._n :0];
}
fn _lui_set_text(_n: *_LuiNode, _s: []const u8) void {
    const _k = @min(_s.len, _n.text_buf.len);
    @memcpy(_n.text_buf[0.._k], _s[0.._k]);
    _n.text_len = _k;
}
fn _lui_text_same(_n: *_LuiNode, _s: []const u8) bool {
    return std.mem.eql(u8, _n.text_buf[0.._n.text_len], _s[0..@min(_s.len, _n.text_buf.len)]);
}
// Position of a child among the parent's ATTACHED children == its index in the box
// (every node has a control from the moment it is a child). Pages likewise in a tab.
fn _lui_index_of(_p: *_LuiNode, _n: *_LuiNode) c_int {
    var _bi: c_int = 0;
    for (_p.children.items) |_s| { if (_s == _n) return _bi; _bi += 1; }
    return _bi;
}
const _LuiGet = struct { n: *_LuiNode, fresh: bool };
// The match. Keyed: the retained sibling with that kind and key, moved to this
// position if it drifted (a closed tab shifts its neighbours). Positional: whatever
// sits at this position if it is the same kind and not already claimed this frame.
fn _lui_child(_kind: _LuiKind, _key: []const u8) _LuiGet {
    const _p = _lui_top();
    const _i = _lui_cursor[_lui_depth - 1];
    _lui_cursor[_lui_depth - 1] += 1;
    if (_key.len > 0) {
        var _j: usize = 0;
        while (_j < _p.children.items.len) : (_j += 1) {
            const _c = _p.children.items[_j];
            if (_c.kind == _kind and _c.seen != _lui_frame_n and std.mem.eql(u8, _c.key, _key)) {
                if (_j != _i) _lui_move(_p, _j, _i);
                _c.seen = _lui_frame_n;
                return .{ .n = _c, .fresh = false };
            }
        }
    } else if (_i < _p.children.items.len) {
        const _c = _p.children.items[_i];
        if (_c.kind == _kind and _c.key.len == 0 and _c.seen != _lui_frame_n) {
            _c.seen = _lui_frame_n;
            return .{ .n = _c, .fresh = false };
        }
    }
    const _n = _allocator.create(_LuiNode) catch unreachable;
    _n.* = .{ .kind = _kind, .seen = _lui_frame_n };
    if (_key.len > 0) {
        _n.key = _allocator.dupe(u8, _key) catch "";
        _lui_keyed.put(_n.key, _n) catch {};
    }
    _p.children.insert(_allocator, @min(_i, _p.children.items.len), _n) catch unreachable;
    return .{ .n = _n, .fresh = true };
}
// A fresh node has just made its control: put it into the parent at its position.
fn _lui_attach(_n: *_LuiNode, _stretch: bool) void {
    const _p = _lui_top();
    const _c = _n.ctrl orelse return;
    _n.stretch = _stretch;
    const _bi = _lui_index_of(_p, _n);
    if (_p.kind == .tabs) {
        if (_p.tab) |_t| {
            var _lb: [256]u8 = undefined;
            _ui.Tab.InsertAt(_t, _lui_z(&_lb, _n.text_buf[0.._n.text_len]), _bi, _c);
            _ui.Tab.SetMargined(_t, _bi, false);   // the page box is padded itself; no band under a strip
        }
    } else if (_p.box) |_b| {
        _ui.Box.InsertAt(_b, _c, _bi, if (_stretch) .stretch else .dont_stretch);
    }
}
fn _lui_move(_p: *_LuiNode, _from: usize, _to: usize) void {
    const _n = _p.children.orderedRemove(_from);
    const _at = @min(_to, _p.children.items.len);
    _p.children.insert(_allocator, _at, _n) catch unreachable;
    const _c = _n.ctrl orelse return;
    if (_p.kind == .tabs) {
        if (_p.tab) |_t| {
            _ui.Tab.Delete(_t, @intCast(_from));
            var _lb: [256]u8 = undefined;
            _ui.Tab.InsertAt(_t, _lui_z(&_lb, _n.text_buf[0.._n.text_len]), @intCast(_at), _c);
            _ui.Tab.SetMargined(_t, @intCast(_at), false);
        }
    } else if (_p.box) |_b| {
        _ui.Box.Delete(_b, @intCast(_from));
        _ui.Box.InsertAt(_b, _c, @intCast(_at), if (_n.stretch) .stretch else .dont_stretch);
    }
}
// Container closed: children the view did not revisit leave. Their controls are
// destroyed -- except an editor's Scintilla, which belongs to its _CodeEditor and
// is only detached, so a pane the view brings back keeps its document.
fn _lui_close(_p: *_LuiNode) void {
    var _j: usize = 0;
    while (_j < _p.children.items.len) {
        const _c = _p.children.items[_j];
        if (_c.seen != _lui_frame_n) {
            _lui_detach(_p, _c, @intCast(_j));
            _lui_free_node(_c);
            _ = _p.children.orderedRemove(_j);
            continue;
        }
        _j += 1;
    }
}
fn _lui_detach(_p: *_LuiNode, _c: *_LuiNode, _bi: c_int) void {
    if (_c.ctrl == null) return;
    if (_p.kind == .tabs) { if (_p.tab) |_t| _ui.Tab.Delete(_t, _bi); }
    else if (_p.box) |_b| _ui.Box.Delete(_b, _bi);
}
fn _lui_free_node(_n: *_LuiNode) void {
    // children first, from the back, so editors inside are detached before their box dies
    var _j: usize = _n.children.items.len;
    while (_j > 0) {
        _j -= 1;
        const _c = _n.children.items[_j];
        _lui_detach(_n, _c, @intCast(_j));
        _lui_free_node(_c);
    }
    _n.children.deinit(_allocator);
    if (_n.key.len > 0) {
        if (_lui_keyed.get(_n.key)) |_k| { if (_k == _n) _ = _lui_keyed.remove(_n.key); }
    }
    if (_n.kind != .editor) {
        if (_n.ctrl) |_c| _ui.Control.Destroy(_c);   // a table's uiTable dies with its host box
    }
    if (_n.kind == .table) {
        if (_n.table) |_t| _lui_table_free(_t);      // rows and model, after the control
    }
    if (_n.key.len > 0) _allocator.free(_n.key);
    _allocator.destroy(_n);
}
// Window-level chords (uiWindowOnKey). Same shape as the CodeEditor's: registered
// chords are consumed and queued, everything else passes to the focused control.
var _lui_hot: [32]u32 = [_]u32{0} ** 32;
var _lui_hot_n: usize = 0;
var _lui_keys: [16]u32 = [_]u32{0} ** 16;
var _lui_key_n: usize = 0;
fn _lui_on_key(_w: *_ui.Window, vk: c_int, mods: c_int, _d: ?*anyopaque) bool {
    _ = _w;
    _ = _d;
    const _chord: u32 = (@as(u32, @intCast(mods & 0xffff)) << 16) | @as(u32, @intCast(vk & 0xffff));
    var i: usize = 0;
    while (i < _lui_hot_n) : (i += 1) {
        if (_lui_hot[i] == _chord) {
            if (_lui_key_n < _lui_keys.len) { _lui_keys[_lui_key_n] = _chord; _lui_key_n += 1; }
            return true;
        }
    }
    return false;
}
fn _lui_hotkey(vk: i64, mods: i64) void {
    if (_lui_hot_n >= _lui_hot.len) return;
    const _chord: u32 = (@as(u32, @intCast(mods & 0xffff)) << 16) | @as(u32, @intCast(vk & 0xffff));
    var i: usize = 0;
    while (i < _lui_hot_n) : (i += 1) if (_lui_hot[i] == _chord) return;
    _lui_hot[_lui_hot_n] = _chord;
    _lui_hot_n += 1;
}
fn _lui_take_key() i64 {
    if (_lui_key_n == 0) return 0;
    const v = _lui_keys[0];
    var i: usize = 1;
    while (i < _lui_key_n) : (i += 1) _lui_keys[i - 1] = _lui_keys[i];
    _lui_key_n -= 1;
    return @intCast(v);
}
// The window is OURS to destroy (deinit), so the close request only ends the loop:
// returning should_close would make libui destroy the window while the frame that
// carried the request still renders into it (GTK: "unexpectedly destroyed").
fn _lui_on_close(_w: *_ui.Window, _q: ?*bool) anyerror!_ui.Window.ClosingAction {
    _ = _w;
    if (_q) |p| p.* = true;
    _ui.Quit();
    return .should_not_close;
}
// Widget callbacks: record on the node; the next render reads it (the bridge).
fn _lui_btn_cb(_btn: *_ui.Button, _m: ?*_LuiNode) anyerror!void { _ = _btn; if (_m) |p| p.clicked = true; }
fn _lui_chk_cb(_chk: *_ui.Checkbox, _m: ?*_LuiNode) anyerror!void { if (_m) |p| p.checked = _chk.Checked(); }
fn _lui_entry_cb(_ent: *_ui.Entry, _m: ?*_LuiNode) anyerror!void { if (_m) |p| _lui_set_text(p, std.mem.span(_ent.Text())); }
fn _lui_mle_cb(_mle: *_ui.MultilineEntry, _m: ?*_LuiNode) anyerror!void { if (_m) |p| _lui_set_text(p, std.mem.span(_mle.Text())); }
fn _lui_slider_cb(_sld: *_ui.Slider, _m: ?*_LuiNode) anyerror!void { if (_m) |p| p.sval = _sld.Value(); }
fn _lui_cmb_cb(_c: *_ui.Combobox, _m: ?*_LuiNode) anyerror!void { if (_m) |p| p.sval = _c.Selected(); }
fn _lui_spn_cb(_s: *_ui.Spinbox, _m: ?*_LuiNode) anyerror!void { if (_m) |p| p.sval = _s.Value(); }
fn _lui_init(_title: []const u8, _width: i64, _height: i64) anyerror!void {
    _lui_win_w = _width; _lui_win_h = _height;
    var _d = _ui.InitData{ .options = .{ .Size = @sizeOf(_ui.InitOptions) } };
    try _ui.Init(&_d);
    _lui_keyed = std.StringHashMap(*_LuiNode).init(_allocator);
    _lui_title_len = @min(_title.len, 255);
    @memcpy(_lui_title[0.._lui_title_len], _title[0.._lui_title_len]);
    // The window is created at the end of the FIRST render (see _lui_endframe):
    // libui wants every menu declared before uiNewWindow, and the first render is
    // where the view declares them.
    _lui_root_box = try _ui.Box.New(.Vertical);
    _lui_root_box.?.SetPadded(true);
    _lui_root = try _allocator.create(_LuiNode);
    _lui_root.* = .{ .kind = .root, .box = _lui_root_box, .ctrl = _lui_root_box.?.as_control() };
    _lui_reset_stack();
    _lui_everys = .empty;
    _lui_frame = 0; _lui_quit = false;
}
// g.every(ms, msg) subscriptions. A record lives while the view keeps declaring it
// (seen == the frame it was last declared in); the sweep marks the rest stale and the
// next tick disarms them. Redeclaring a stale one re-arms it. Until 2026-09-17 a fixed
// 100 ms timer drove EVERY frame; now a program that never subscribes idles at zero.
const _LuiEvery = struct { ms: i64, bytes: [64]u8 align(16) = undefined, len: usize = 0, send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, send_ptr: *anyopaque, seen: u32 = 0, stale: bool = false, armed: bool = false };
var _lui_everys: std.ArrayList(*_LuiEvery) = .empty;
fn _lui_every_tick(_rp: ?*_LuiEvery) anyerror!_ui.TimerAction {
    const _r = _rp orelse return .disarm;
    if (_r.stale) { _r.armed = false; return .disarm; }
    _r.send_fn(_r.send_ptr, @ptrCast(&_r.bytes), _r.len);
    return .rearm;
}
fn _lui_every(_ms: i64, _msg: *const anyopaque, _len: usize, _send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, _send_ptr: *anyopaque) void {
    if (_len > 64) return;
    const _src: [*]const u8 = @ptrCast(_msg);
    for (_lui_everys.items) |_r| {
        if (_r.ms == _ms and _r.len == _len and std.mem.eql(u8, _r.bytes[0.._len], _src[0.._len])) {
            _r.seen = _lui_frame_n;
            if (!_r.armed) { _r.stale = false; _r.armed = true; _ui.Timer(_LuiEvery, anyerror, @intCast(@max(_ms, 1)), _lui_every_tick, _r); }
            return;
        }
    }
    const _r = _allocator.create(_LuiEvery) catch return;
    _r.* = .{ .ms = _ms, .send_fn = _send_fn, .send_ptr = _send_ptr, .seen = _lui_frame_n, .armed = true, .len = _len };
    @memcpy(_r.bytes[0.._len], _src[0.._len]);
    _lui_everys.append(_allocator, _r) catch { _allocator.destroy(_r); return; };
    _ui.Timer(_LuiEvery, anyerror, @intCast(@max(_ms, 1)), _lui_every_tick, _r);
}
fn _lui_sweep_everys() void {
    for (_lui_everys.items) |_r| _r.stale = _r.seen != _lui_frame_n;
}
// Exit: destroy the window (which destroys every control in the tree, the uiTables
// included), THEN free what the tree owned outside the controls -- table models,
// which libui's leak check at uiUninit names by address if they are still alive.
fn _lui_free_models(_n: *_LuiNode) void {
    for (_n.children.items) |_c| _lui_free_models(_c);
    if (_n.table) |_t| { _lui_table_free(_t); _n.table = null; }
}
fn _lui_deinit() void {
    if (_lui_window) |_w| { _ui.Control.Destroy(_w.as_control()); _lui_window = null; }
    _lui_free_models(_lui_root);
    _lui_keyed.deinit();
    _ui.Uninit();
}
fn _lui_newframe() bool {
    _lui_reset_stack();
    if (_lui_frame == 0) return true;
    if (_lui_quit) return false;
    return _ui.MainStep(.blocking) == .running and !_lui_quit;
}
// Render done: close every container the view left open (the root last, which
// removes what the view dropped at top level), sweep timers, advance the frame,
// and on the very first render put the tree in the window and show it.
fn _lui_endframe() void {
    while (_lui_depth > 1) _lui_pop();
    _lui_close(_lui_root);
    _lui_sweep_everys();
    _lui_frame_n +%= 1;
    if (_lui_frame_n == 0) _lui_frame_n = 1;
    _lui_reset_stack();
    if (_lui_frame == 0) {
        _lui_frame = 1;
        // menus are complete now; create the window (with a menubar if any), fill, show
        var _tbuf: [256]u8 = undefined;
        const _tz: [:0]u8 = _lui_z(&_tbuf, _lui_title[0.._lui_title_len]);
        const _w = _ui.Window.New(_tz, @intCast(_lui_win_w), @intCast(_lui_win_h), if (_lui_menus.items.len > 0) .show_menubar else .hide_menubar) catch @panic("gui: window");
        _lui_window = _w;
        _lui_menus_frozen = true;
        _ui.Window.OnClosing(_w, bool, anyerror, _lui_on_close, &_lui_quit);
        if (comptime @hasDecl(_ui.Window, "OnKey")) _ui.Window.OnKey(_w, anyopaque, _lui_on_key, null);
        if (_lui_root_box) |_vb| _w.SetChild(_vb.as_control());
        _w.SetMargined(true);
        _w.as_control().Show();
    }
}
// ── menus (§6b) ──
// Not part of the box tree: a menubar is fixed by libui once the window exists, so
// the set of menus and items is whatever the FIRST render declared. Later renders
// match items by position and only re-send bytes; a menu or item that first appears
// after the window exists is refused by name, once. Items send their Msg bytes.
const _LuiMenuItem = struct { kind: enum { item, sep, quit }, label: [256]u8 = undefined, label_len: usize = 0, item: ?*_ui.MenuItem = null, msg: [64]u8 align(16) = undefined, msg_len: usize = 0, send_fn: ?*const fn (*anyopaque, *const anyopaque, usize) void = null, send_ptr: ?*anyopaque = null };
const _LuiMenu = struct { name: [256]u8 = undefined, name_len: usize = 0, menu: ?*_ui.Menu = null, items: std.ArrayList(*_LuiMenuItem) = .empty, cursor: usize = 0 };
var _lui_menus: std.ArrayList(*_LuiMenu) = .empty;
var _lui_cur_menu: ?*_LuiMenu = null;
var _lui_menus_frozen: bool = false;
var _lui_menu_warned: bool = false;
fn _lui_menu_late(_what: []const u8, _name: []const u8) void {
    if (_lui_menu_warned) return;
    _lui_menu_warned = true;
    std.debug.print("gui: {s} \"{s}\" declared after the first render; libui fixes the menubar when the window is created, so it is ignored. Declare every menu and item in every render.\n", .{ _what, _name });
}
fn _lui_menu_cb(_it: *_ui.MenuItem, _w: *_ui.Window, _rp: ?*_LuiMenuItem) anyerror!void {
    _ = _it; _ = _w;
    const _r = _rp orelse return;
    if (_r.send_fn) |f| f(_r.send_ptr.?, @ptrCast(&_r.msg), _r.msg_len);
}
fn _lui_should_quit(_: ?*anyopaque) anyerror!_ui.QuitAction {
    _lui_quit = true;
    _ui.Quit();
    return .should_quit;
}
fn _lui_begin_menu(_name: []const u8) void {
    for (_lui_menus.items) |_m| {
        if (std.mem.eql(u8, _m.name[0.._m.name_len], _name)) { _m.cursor = 0; _lui_cur_menu = _m; return; }
    }
    if (_lui_menus_frozen) { _lui_menu_late("menu", _name); _lui_cur_menu = null; return; }
    var _nb: [256]u8 = undefined;
    const _menu = _ui.Menu.New(_lui_z(&_nb, _name)) catch return;
    const _m = _allocator.create(_LuiMenu) catch return;
    _m.* = .{ .menu = _menu };
    _m.name_len = @min(_name.len, 255);
    @memcpy(_m.name[0.._m.name_len], _name[0.._m.name_len]);
    _lui_menus.append(_allocator, _m) catch return;
    _lui_cur_menu = _m;
}
fn _lui_menu_slot(_m: *_LuiMenu, _kind: @TypeOf(@as(_LuiMenuItem, undefined).kind), _label: []const u8) ?*_LuiMenuItem {
    const _i = _m.cursor;
    _m.cursor += 1;
    if (_i < _m.items.items.len) {
        const _r = _m.items.items[_i];
        if (_r.kind == _kind and std.mem.eql(u8, _r.label[0.._r.label_len], _label)) return _r;
        _lui_menu_late("menu item", _label);
        return null;
    }
    if (_lui_menus_frozen) { _lui_menu_late("menu item", _label); return null; }
    const _r = _allocator.create(_LuiMenuItem) catch return null;
    _r.* = .{ .kind = _kind };
    _r.label_len = @min(_label.len, 255);
    @memcpy(_r.label[0.._r.label_len], _label[0.._r.label_len]);
    const _menu = _m.menu orelse return null;
    var _lb: [256]u8 = undefined;
    switch (_kind) {
        .item => { _r.item = _ui.Menu.AppendItem(_menu, _lui_z(&_lb, _label)) catch null; },
        .sep => _ui.Menu.AppendSeparator(_menu),
        .quit => {
            _r.item = _ui.Menu.AppendQuitItem(_menu) catch null;
            _ui.OnShouldQuit(anyopaque, anyerror, _lui_should_quit, null);
        },
    }
    if (_r.item) |_it| { if (_kind == .item) _ui.MenuItem.OnClicked(_it, _LuiMenuItem, anyerror, _lui_menu_cb, _r); }
    _m.items.append(_allocator, _r) catch {};
    return _r;
}
fn _lui_menu_item(_label: []const u8, _msg: *const anyopaque, _len: usize, _send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, _send_ptr: *anyopaque) void {
    const _m = _lui_cur_menu orelse return;
    const _r = _lui_menu_slot(_m, .item, _label) orelse return;
    if (_len <= 64) {
        const _src: [*]const u8 = @ptrCast(_msg);
        @memcpy(_r.msg[0.._len], _src[0.._len]);
        _r.msg_len = _len;
    }
    _r.send_fn = _send_fn;
    _r.send_ptr = _send_ptr;
}
fn _lui_menu_separator() void {
    const _m = _lui_cur_menu orelse return;
    _ = _lui_menu_slot(_m, .sep, "");
}
fn _lui_menu_quit() void {
    const _m = _lui_cur_menu orelse return;
    _ = _lui_menu_slot(_m, .quit, "");
}
fn _lui_end_menu() void { _lui_cur_menu = null; }
// ── message-carrying widgets (§6b) ──
fn _lui_action_cb(_btn: *_ui.Button, _m: ?*_LuiNode) anyerror!void {
    _ = _btn;
    const _n = _m orelse return;
    if (_n.send_fn) |f| f(_n.send_ptr.?, @ptrCast(&_n.msg), _n.msg_len);
}
fn _lui_action(_label: []const u8, _msg: *const anyopaque, _len: usize, _send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, _send_ptr: *anyopaque) void {
    const _r = _lui_child(.button, _label);
    var _lb: [256]u8 = undefined;
    if (_r.fresh) {
        const _btn = _ui.Button.New(_lui_z(&_lb, _label)) catch return;
        _ui.Button.OnClicked(_btn, _LuiNode, anyerror, _lui_action_cb, _r.n);
        _r.n.btn = _btn;
        _r.n.ctrl = _btn.as_control();
        _lui_set_text(_r.n, _label);
        _lui_attach(_r.n, false);
    }
    if (_len <= 64) {
        const _src: [*]const u8 = @ptrCast(_msg);
        @memcpy(_r.n.msg[0.._len], _src[0.._len]);
        _r.n.msg_len = _len;
    }
    _r.n.send_fn = _send_fn;
    _r.n.send_ptr = _send_ptr;
}
fn _lui_toggle_cb(_chk: *_ui.Checkbox, _m: ?*_LuiNode) anyerror!void {
    const _n = _m orelse return;
    _n.checked = _chk.Checked();
    if (_n.thunk_b) |t| t(@ptrCast(&_n.cap), _n.checked, _n.send_fn.?, _n.send_ptr.?);
}
fn _lui_toggle(_label: []const u8, _checked: bool, _cap: *const anyopaque, _cap_len: usize, _thunk: *const fn (*const anyopaque, bool, *const fn (*anyopaque, *const anyopaque, usize) void, *anyopaque) void, _send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, _send_ptr: *anyopaque) void {
    if (_cap_len > 128) return;
    const _r = _lui_child(.checkbox, _label);
    if (_r.fresh) {
        var _lb: [256]u8 = undefined;
        const _chk = _ui.Checkbox.New(_lui_z(&_lb, _label)) catch return;
        _chk.SetChecked(_checked);
        _r.n.checked = _checked;
        _ui.Checkbox.OnToggled(_chk, _LuiNode, anyerror, _lui_toggle_cb, _r.n);
        _r.n.chk = _chk;
        _r.n.ctrl = _chk.as_control();
        _lui_attach(_r.n, false);
    } else if (_r.n.checked != _checked) {
        // the model moved (a message flipped it): follow the model
        if (_r.n.chk) |_c| _c.SetChecked(_checked);
        _r.n.checked = _checked;
    }
    const _src: [*]const u8 = @ptrCast(_cap);
    @memcpy(_r.n.cap[0.._cap_len], _src[0.._cap_len]);
    _r.n.cap_len = _cap_len;
    _r.n.thunk_b = _thunk;
    _r.n.send_fn = _send_fn;
    _r.n.send_ptr = _send_ptr;
}
fn _lui_field_cb(_ent: *_ui.Entry, _m: ?*_LuiNode) anyerror!void {
    const _n = _m orelse return;
    _lui_set_text(_n, std.mem.span(_ent.Text()));
    if (_n.thunk_s) |t| t(@ptrCast(&_n.cap), _n.text_buf[0.._n.text_len], _n.send_fn.?, _n.send_ptr.?);
}
fn _lui_field(_label: []const u8, _text: []const u8, _cap: *const anyopaque, _cap_len: usize, _thunk: *const fn (*const anyopaque, []const u8, *const fn (*anyopaque, *const anyopaque, usize) void, *anyopaque) void, _send_fn: *const fn (*anyopaque, *const anyopaque, usize) void, _send_ptr: *anyopaque) void {
    if (_cap_len > 128) return;
    const _r = _lui_child(.input, _label);
    var _vtb: [1024]u8 = undefined;
    if (_r.fresh) {
        const _ent = _ui.Entry.New(.Entry) catch return;
        _ent.SetText(_lui_z(&_vtb, _text));
        _lui_set_text(_r.n, _text);
        _ui.Entry.OnChanged(_ent, _LuiNode, anyerror, _lui_field_cb, _r.n);
        _r.n.ent = _ent;
        _lui_labelled(_r.n, _label, _ent.as_control(), false);
        _lui_attach(_r.n, false);
    } else if (!_lui_text_same(_r.n, _text)) {
        // the model's text differs from what the widget shows (a message set it):
        // push it; a plain keystroke never reaches here because OnChanged already
        // recorded it, so the caret is not disturbed while typing
        if (_r.n.ent) |_e| _e.SetText(_lui_z(&_vtb, _text));
        _lui_set_text(_r.n, _text);
    }
    const _src: [*]const u8 = @ptrCast(_cap);
    @memcpy(_r.n.cap[0.._cap_len], _src[0.._cap_len]);
    _r.n.cap_len = _cap_len;
    _r.n.thunk_s = _thunk;
    _r.n.send_fn = _send_fn;
    _r.n.send_ptr = _send_ptr;
}
// ── leaves ──
fn _lui_text(_s: []const u8) void {
    if (_lui_cur_table != null and _lui_table_cell_text(_s)) return;
    const _r = _lui_child(.text, "");
    var _tb: [512]u8 = undefined;
    if (_r.fresh) {
        const _lbl = _ui.Label.New(_lui_z(&_tb, _s)) catch return;
        _r.n.lbl = _lbl;
        _r.n.ctrl = _lbl.as_control();
        _lui_set_text(_r.n, _s);
        _lui_attach(_r.n, false);
    } else if (!_lui_text_same(_r.n, _s)) {
        if (_r.n.lbl) |_l| _l.SetText(_lui_z(&_tb, _s));
        _lui_set_text(_r.n, _s);
    }
}
fn _lui_sep() void {
    const _r = _lui_child(.sep, "");
    if (_r.fresh) {
        const _sep = _ui.Separator.New(.Horizontal) catch return;
        _r.n.ctrl = _sep.as_control();
        _lui_attach(_r.n, false);
    }
}
fn _lui_noop_void() void {}
fn _lui_noop_bool(_l: []const u8) bool { _ = _l; return true; }
fn _lui_selectable(_l: []const u8) bool { _ = _l; return false; }
fn _lui_text_colored(_rv: f32, _gv: f32, _bv: f32, _av: f32, _s: []const u8) void {
    _ = _rv; _ = _gv; _ = _bv; _ = _av; _lui_text(_s);
}
fn _lui_button_id(_id: []const u8, _label: []const u8) bool {
    const _r = _lui_child(.button, _id);
    var _lb: [256]u8 = undefined;
    if (_r.fresh) {
        const _btn = _ui.Button.New(_lui_z(&_lb, _label)) catch return false;
        _ui.Button.OnClicked(_btn, _LuiNode, anyerror, _lui_btn_cb, _r.n);
        _r.n.btn = _btn;
        _r.n.ctrl = _btn.as_control();
        _lui_set_text(_r.n, _label);
        _lui_attach(_r.n, false);
    } else if (!_lui_text_same(_r.n, _label)) {
        if (_r.n.btn) |_b| _ui.Button.SetText(_b, _lui_z(&_lb, _label));
        _lui_set_text(_r.n, _label);
    }
    const _clicked = _r.n.clicked;
    _r.n.clicked = false;
    return _clicked;
}
fn _lui_button(_label: []const u8) bool { return _lui_button_id(_label, _label); }
fn _lui_checkbox(_label: []const u8, _value: bool) bool {
    const _r = _lui_child(.checkbox, _label);
    if (_r.fresh) {
        var _lb: [256]u8 = undefined;
        const _chk = _ui.Checkbox.New(_lui_z(&_lb, _label)) catch return _value;
        _chk.SetChecked(_value);
        _r.n.checked = _value;
        _ui.Checkbox.OnToggled(_chk, _LuiNode, anyerror, _lui_chk_cb, _r.n);
        _r.n.chk = _chk;
        _r.n.ctrl = _chk.as_control();
        _lui_attach(_r.n, false);
    }
    return _r.n.checked;
}
// A labelled widget is ONE node: an unpadded vbox holding the label and the control.
fn _lui_labelled(_n: *_LuiNode, _label: []const u8, _c: *_ui.Control, _stretch_inner: bool) void {
    var _lb: [256]u8 = undefined;
    const _vb = _ui.Box.New(.Vertical) catch return;
    _vb.SetPadded(false);
    const _l = _ui.Label.New(_lui_z(&_lb, _label)) catch return;
    _ui.Box.Append(_vb, _l.as_control(), .dont_stretch);
    _ui.Box.Append(_vb, _c, if (_stretch_inner) .stretch else .dont_stretch);
    _n.lbl = _l;
    _n.ctrl = _vb.as_control();
}
fn _lui_slider(_label: []const u8, _value: f64, _min: f64, _max: f64) f64 {
    const _r = _lui_child(.slider, _label);
    if (_r.fresh) {
        const _sld = _ui.Slider.New(0, 1000) catch return _value;
        const _raw: c_int = @intFromFloat((_value - _min) / (_max - _min) * 1000.0);
        const _init: c_int = if (_raw < 0) 0 else if (_raw > 1000) 1000 else _raw;
        _sld.SetValue(_init);
        _r.n.sval = _init; _r.n.smin = _min; _r.n.smax = _max;
        _ui.Slider.OnChanged(_sld, _LuiNode, anyerror, _lui_slider_cb, _r.n);
        _r.n.sld = _sld;
        _lui_labelled(_r.n, _label, _sld.as_control(), false);
        _lui_attach(_r.n, false);
    }
    const _t = @as(f64, @floatFromInt(_r.n.sval)) / 1000.0;
    return _r.n.smin + _t * (_r.n.smax - _r.n.smin);
}
fn _lui_input(_label: []const u8, _value: []const u8) []const u8 {
    const _r = _lui_child(.input, _label);
    if (_r.fresh) {
        const _ent = _ui.Entry.New(.Entry) catch return _value;
        var _vtb: [1024]u8 = undefined;
        _ent.SetText(_lui_z(&_vtb, _value));
        _lui_set_text(_r.n, _value);
        _ui.Entry.OnChanged(_ent, _LuiNode, anyerror, _lui_entry_cb, _r.n);
        _r.n.ent = _ent;
        _lui_labelled(_r.n, _label, _ent.as_control(), false);
        _lui_attach(_r.n, false);
    }
    return _r.n.text_buf[0.._r.n.text_len];
}
fn _lui_input_ml(_label: []const u8, _value: []const u8, _mw: f64, _mh: f64) []const u8 {
    _ = _mw; _ = _mh;
    const _r = _lui_child(.input_ml, _label);
    if (_r.fresh) {
        const _mle = _ui.MultilineEntry.New(.Wrapping) catch return _value;
        var _vtb: [1024]u8 = undefined;
        _mle.SetText(_lui_z(&_vtb, _value));
        _lui_set_text(_r.n, _value);
        _ui.MultilineEntry.OnChanged(_mle, _LuiNode, anyerror, _lui_mle_cb, _r.n);
        _r.n.mle = _mle;
        _lui_labelled(_r.n, _label, _mle.as_control(), true);
        _lui_attach(_r.n, true);
    }
    return _r.n.text_buf[0.._r.n.text_len];
}
fn _lui_combobox(_label: []const u8, _items: []const []const u8, _sel: i64) i64 {
    const _r = _lui_child(.combobox, _label);
    if (_r.fresh) {
        const _cmb = _ui.Combobox.New() catch return _sel;
        for (_items) |_it| {
            var _lb: [256]u8 = undefined;
            _ui.Combobox.Append(_cmb, _lui_z(&_lb, _it));
        }
        const _init: c_int = @intCast(_sel);
        _cmb.SetSelected(_init);
        _r.n.sval = _init;
        _ui.Combobox.OnSelected(_cmb, _LuiNode, anyerror, _lui_cmb_cb, _r.n);
        _r.n.cmb = _cmb;
        _r.n.ctrl = _cmb.as_control();
        _lui_attach(_r.n, false);
    }
    return @as(i64, @intCast(_r.n.sval));
}
fn _lui_spinbox(_label: []const u8, _value: i64, _min: i64, _max: i64) i64 {
    const _r = _lui_child(.spinbox, _label);
    if (_r.fresh) {
        const _spn = _ui.Spinbox.New(.{ .Integer = .{ .min = @intCast(_min), .max = @intCast(_max) } }) catch return _value;
        _spn.SetValue(@intCast(_value));
        _r.n.sval = @intCast(_value);
        _ui.Spinbox.OnChanged(_spn, _LuiNode, anyerror, _lui_spn_cb, _r.n);
        _r.n.spn = _spn;
        _r.n.ctrl = _spn.as_control();
        _lui_attach(_r.n, false);
    }
    return @as(i64, @intCast(_r.n.sval));
}
fn _lui_progressbar(_label: []const u8, _value: f64) void {
    const _r = _lui_child(.progress, _label);
    const _pct: c_int = @intFromFloat(_value * 100.0);
    const _clamped: c_int = if (_pct < 0) 0 else if (_pct > 100) 100 else _pct;
    if (_r.fresh) {
        const _pb = _ui.ProgressBar.New() catch return;
        _pb.SetValue(_clamped);
        _r.n.pb = _pb;
        _r.n.sval = _clamped;
        _r.n.ctrl = _pb.as_control();
        _lui_attach(_r.n, false);
    } else if (_r.n.sval != _clamped) {
        if (_r.n.pb) |_pb| _pb.SetValue(_clamped);
        _r.n.sval = _clamped;
    }
}
// ── containers ──
fn _lui_begin_box(_kind: _LuiKind, _id: []const u8, _stretch: bool, _padded: bool) void {
    const _r = _lui_child(_kind, _id);
    if (_r.fresh) {
        const _b = _ui.Box.New(if (_kind == .hbox) .Horizontal else .Vertical) catch return;
        _b.SetPadded(_padded);
        _r.n.box = _b;
        _r.n.ctrl = _b.as_control();
        _lui_attach(_r.n, _stretch);
    }
    _lui_push(_r.n);
}
fn _lui_begin_hbox(_id: []const u8, _stretch: bool) void { _lui_begin_box(.hbox, _id, _stretch, true); }
fn _lui_end_hbox() void { _lui_pop(); }
fn _lui_begin_vbox(_id: []const u8, _stretch: bool) void { _lui_begin_box(.vbox, _id, _stretch, false); }
fn _lui_end_vbox() void { _lui_pop(); }
fn _lui_begin_panel(_label: []const u8) bool {
    const _r = _lui_child(.panel, _label);
    if (_r.fresh) {
        var _lb: [256]u8 = undefined;
        const _grp = _ui.Group.New(_lui_z(&_lb, _label)) catch return true;
        const _inner = _ui.Box.New(.Vertical) catch return true;
        _inner.SetPadded(true);
        _grp.SetChild(_inner.as_control());
        _grp.SetMargined(true);
        _r.n.grp = _grp;
        _r.n.box = _inner;
        _r.n.ctrl = _grp.as_control();
        _lui_attach(_r.n, false);
    }
    _lui_push(_r.n);
    return true;
}
fn _lui_end_panel() void { _lui_pop(); }
// Tabs: the strip is a container whose children are pages; a page is a box that
// is inserted into the uiTab at its position, renamed when its label changes
// (uiTabSetName -- the fork's), and deleted when the view drops it.
fn _lui_begin_tabs(_id: []const u8, _stretch: bool) void {
    const _r = _lui_child(.tabs, _id);
    if (_r.fresh) {
        const _t = _ui.Tab.New() catch return;
        _r.n.tab = _t;
        _r.n.ctrl = _t.as_control();
        _lui_attach(_r.n, _stretch);
    }
    _lui_push(_r.n);
}
fn _lui_begin_tab_page(_id: []const u8, _label: []const u8) void {
    const _p = _lui_top();
    if (_p.kind != .tabs) { _lui_begin_box(.vbox, _id, true, true); return; }
    const _r = _lui_child(.page, _id);
    if (_r.fresh) {
        const _pg = _ui.Box.New(.Vertical) catch return;
        _pg.SetPadded(true);
        _r.n.box = _pg;
        _r.n.ctrl = _pg.as_control();
        _lui_set_text(_r.n, _label);
        _lui_attach(_r.n, true);
    } else if (!_lui_text_same(_r.n, _label)) {
        var _lb: [256]u8 = undefined;
        if (_p.tab) |_t| _ui.Tab.SetName(_t, _lui_index_of(_p, _r.n), _lui_z(&_lb, _label));
        _lui_set_text(_r.n, _label);
    }
    _lui_push(_r.n);
}
fn _lui_end_tab_page() void { _lui_pop(); }
fn _lui_end_tabs() void { _lui_pop(); }
fn _lui_tab_selected(_id: []const u8) i64 {
    const _n = _lui_keyed.get(_id) orelse return -1;
    const _t = _n.tab orelse return -1;
    if (_ui.Tab.NumPages(_t) == 0) return -1;
    return @as(i64, @intCast(_ui.Tab.Selected(_t)));
}
fn _lui_select_tab(_id: []const u8, _index: i64) void {
    const _n = _lui_keyed.get(_id) orelse return;
    const _t = _n.tab orelse return;
    const _np = _ui.Tab.NumPages(_t);
    if (_index < 0 or _index >= @as(i64, @intCast(_np))) return;
    const _want: c_int = @intCast(_index);
    if (_ui.Tab.Selected(_t) != _want) _ui.Tab.SetSelected(_t, _want);
}
// Minimum-size hint by id. Only calls into libui when the hint changes --
// uiControlSetMinSize relayouts, and the view repeats the call every render.
fn _lui_min_size(_id: []const u8, _w: i64, _h: i64) void {
    const _n = _lui_keyed.get(_id) orelse return;
    const _c = _n.ctrl orelse return;
    const _cw: c_int = @intCast(@max(_w, 0));
    const _ch: c_int = @intCast(@max(_h, 0));
    if (_c.MinWidth == _cw and _c.MinHeight == _ch) return;
    _ui.Control.SetMinSize(_c, _cw, _ch);
}
// A code editor is a node keyed by the editor's address: one _CodeEditor is one
// Scintilla control whatever id the view passes. Its control is never destroyed
// with the node (see _lui_free_node), so a pane that comes back keeps its document.
fn _lui_editor_node(_ed: *_CodeEditor) void {
    var _kb: [32]u8 = undefined;
    const _kz = std.fmt.bufPrint(&_kb, "ce:{x}", .{@intFromPtr(_ed)}) catch return;
    const _r = _lui_child(.editor, _kz);
    if (_r.fresh) {
        _r.n.ed = _ed;
        _r.n.ctrl = _ed.scint.?.as_control();
        _lui_attach(_r.n, true);
    }
}
// Tables (2026-09-17): libui-ng's uiTable is model-based; Zebra's g.beginTable /
// tableNextRow / tableNextColumn / g.text is immediate-mode. The adapter keeps a
// committed grid of owned, terminated strings per table id (what the uiTableModel
// reads), builds this frame's grid from the calls, and at endTable diffs the two:
// changed cells -> RowChanged, extra rows -> RowInserted, missing rows -> RowDeleted.
// The uiTable itself is created at the first endTable, when the column names are
// known (libui fixes them at append). Selection is ZeroOrOne; a double-click is
// queued as the "activated" row for g.tableActivatedRow.
const _LuiRow = std.ArrayList([:0]u8);
const _LuiTable = struct {
    handler: _ui.Table.Model.Handler = undefined,
    model: ?*_ui.Table.Model = null,
    table: ?*_ui.Table = null,
    ncols: usize = 0,
    names: std.ArrayList([:0]u8) = .empty,
    header: bool = false,
    rows: std.ArrayList(_LuiRow) = .empty,
    build: std.ArrayList(_LuiRow) = .empty,
    host: ?*_ui.Box = null,         // the node's placeholder box; the uiTable goes in it
    cur_col: usize = 0,
    activated: i64 = -1,
    seen: u32 = 0,
};
var _lui_cur_table: ?*_LuiTable = null;
fn _lui_tbl_num_columns(_h: *_ui.Table.Model.Handler, _m: *_ui.Table.Model) callconv(.c) c_int {
    _ = _m;
    const _t: *_LuiTable = @fieldParentPtr("handler", _h);
    return @intCast(_t.ncols);
}
fn _lui_tbl_column_type(_h: *_ui.Table.Model.Handler, _m: *_ui.Table.Model, _c: c_int) callconv(.c) _ui.Table.Value.Type {
    _ = _h; _ = _m; _ = _c;
    return .String;
}
fn _lui_tbl_num_rows(_h: *_ui.Table.Model.Handler, _m: *_ui.Table.Model) callconv(.c) c_int {
    _ = _m;
    const _t: *_LuiTable = @fieldParentPtr("handler", _h);
    return @intCast(_t.rows.items.len);
}
fn _lui_tbl_cell_value(_h: *_ui.Table.Model.Handler, _m: *_ui.Table.Model, _r: c_int, _c: c_int) callconv(.c) ?*_ui.Table.Value {
    _ = _m;
    const _t: *_LuiTable = @fieldParentPtr("handler", _h);
    const _ri: usize = @intCast(@max(_r, 0));
    const _ci: usize = @intCast(@max(_c, 0));
    var _s: [:0]const u8 = "";
    if (_ri < _t.rows.items.len and _ci < _t.rows.items[_ri].items.len) _s = _t.rows.items[_ri].items[_ci];
    return _ui.Table.Value.uiNewTableValueString(_s.ptr);
}
fn _lui_tbl_set_cell_value(_h: *_ui.Table.Model.Handler, _m: *_ui.Table.Model, _r: c_int, _c: c_int, _v: ?*const _ui.Table.Value) callconv(.c) void {
    _ = _h; _ = _m; _ = _r; _ = _c; _ = _v;
}
fn _lui_tbl_dbl(_tb: *_ui.Table, _row: c_int, _tp: ?*_LuiTable) anyerror!void {
    _ = _tb;
    if (_tp) |_t| _t.activated = @intCast(_row);
}
fn _lui_row_free(_r: *_LuiRow) void {
    for (_r.items) |_c| _allocator.free(_c);
    _r.deinit(_allocator);
}
fn _lui_begin_table(_id: []const u8, _cols: i64) bool {
    const _r = _lui_child(.table, _id);
    if (_r.fresh) {
        const _host = _ui.Box.New(.Vertical) catch return false;
        _host.SetPadded(false);
        const _t = _allocator.create(_LuiTable) catch return false;
        _t.* = .{};
        _t.ncols = @intCast(@max(_cols, 1));
        _t.host = _host;
        _t.handler = .{
            .NumColumns = _lui_tbl_num_columns,
            .ColumnType = _lui_tbl_column_type,
            .NumRows = _lui_tbl_num_rows,
            .CellValue = _lui_tbl_cell_value,
            .SetCellValue = _lui_tbl_set_cell_value,
        };
        _t.model = _ui.Table.Model.New(&_t.handler) catch null;
        _r.n.table = _t;
        _r.n.box = _host;
        _r.n.ctrl = _host.as_control();
        _lui_attach(_r.n, true);
    }
    const _t = _r.n.table orelse return false;
    for (_t.build.items) |*_row| _lui_row_free(_row);
    _t.build.clearRetainingCapacity();
    _t.cur_col = 0;
    _lui_cur_table = _t;
    return true;
}
fn _lui_table_free(_t: *_LuiTable) void {
    for (_t.rows.items) |*_row| _lui_row_free(_row);
    _t.rows.deinit(_allocator);
    for (_t.build.items) |*_row| _lui_row_free(_row);
    _t.build.deinit(_allocator);
    for (_t.names.items) |_nm| _allocator.free(_nm);
    _t.names.deinit(_allocator);
    if (_t.model) |_m| _ui.Table.Model.Free(_m);
    _allocator.destroy(_t);
}
fn _lui_table_setup_col(_l: []const u8) void {
    const _t = _lui_cur_table orelse return;
    if (_t.table != null or _t.names.items.len >= _t.ncols) return;
    const _z = _allocator.dupeZ(u8, _l) catch return;
    _t.names.append(_allocator, _z) catch {};
}
fn _lui_table_headers_row() void {
    const _t = _lui_cur_table orelse return;
    _t.header = true;
}
fn _lui_table_next_row() void {
    const _t = _lui_cur_table orelse return;
    _t.build.append(_allocator, .empty) catch return;
    _t.cur_col = 0;
}
fn _lui_table_next_col() void {
    const _t = _lui_cur_table orelse return;
    if (_t.build.items.len == 0) return;
    const _row = &_t.build.items[_t.build.items.len - 1];
    if (_row.items.len > _t.cur_col) _t.cur_col += 1;
}
// g.text inside a table writes the current cell (called from _lui_text).
fn _lui_table_cell_text(_s: []const u8) bool {
    const _t = _lui_cur_table orelse return false;
    if (_t.build.items.len == 0) _t.build.append(_allocator, .empty) catch return true;
    const _row = &_t.build.items[_t.build.items.len - 1];
    while (_row.items.len < _t.cur_col) _row.append(_allocator, _allocator.dupeZ(u8, "") catch return true) catch return true;
    const _z = _allocator.dupeZ(u8, _s) catch return true;
    if (_row.items.len == _t.cur_col) {
        _row.append(_allocator, _z) catch { _allocator.free(_z); return true; };
    } else {
        // two texts in one cell: join with a space, ImGui-style wrapping is not a thing here
        const _old = _row.items[_t.cur_col];
        const _j = std.fmt.allocPrintSentinel(_allocator, "{s} {s}", .{ _old, _z }, 0) catch { _allocator.free(_z); return true; };
        _allocator.free(_old);
        _allocator.free(_z);
        _row.items[_t.cur_col] = _j;
    }
    _t.cur_col += 1;
    return true;
}
fn _lui_end_table() void {
    const _t = _lui_cur_table orelse return;
    _lui_cur_table = null;
    if (_t.table == null) {
        const _m = _t.model orelse return;
        var _params: _ui.Table.Params = .{ .Model = _m, .RowBackgroundColorModelColumn = -1 };
        const _tb = _ui.Table.New(&_params) catch return;
        var _c: usize = 0;
        while (_c < _t.ncols) : (_c += 1) {
            const _nm: [:0]const u8 = if (_c < _t.names.items.len) _t.names.items[_c] else "";
            _ui.Table.AppendColumn(_tb, _nm, .{ .Text = .{ .text_column = @intCast(_c), .editable = .Never } });
        }
        _ui.Table.HeaderSetVisible(_tb, _t.header);
        _ui.Table.SetSelectionMode(_tb, .ZeroOrOne);
        _ui.Table.OnRowDoubleClicked(_tb, _LuiTable, anyerror, _lui_tbl_dbl, _t);
        if (_t.host) |_hb| _ui.Box.Append(_hb, _tb.as_control(), .stretch);
        _t.table = _tb;
    }
    // diff build -> rows, notifying the model per row
    const _m = _t.model;
    const _common = @min(_t.rows.items.len, _t.build.items.len);
    var _i: usize = 0;
    while (_i < _common) : (_i += 1) {
        const _old = &_t.rows.items[_i];
        const _new = &_t.build.items[_i];
        var _same = _old.items.len == _new.items.len;
        if (_same) {
            var _k: usize = 0;
            while (_k < _old.items.len) : (_k += 1) {
                if (!std.mem.eql(u8, _old.items[_k], _new.items[_k])) { _same = false; break; }
            }
        }
        if (!_same) {
            _lui_row_free(_old);
            _t.rows.items[_i] = _new.*;
            _new.* = .empty;
            _ui.Table.Model.RowChanged(_m, @intCast(_i));
        }
    }
    while (_t.rows.items.len > _t.build.items.len) {
        var _last = _t.rows.pop() orelse break;
        _lui_row_free(&_last);
        _ui.Table.Model.RowDeleted(_m, @intCast(_t.rows.items.len));
    }
    while (_i < _t.build.items.len) : (_i += 1) {
        _t.rows.append(_allocator, _t.build.items[_i]) catch break;
        _t.build.items[_i] = .empty;
        _ui.Table.Model.RowInserted(_m, @intCast(_t.rows.items.len - 1));
    }
    for (_t.build.items) |*_r| _lui_row_free(_r);
    _t.build.clearRetainingCapacity();
}
fn _lui_table_selected_row(_id: []const u8) i64 {
    const _n = _lui_keyed.get(_id) orelse return -1;
    const _t = _n.table orelse return -1;
    const _tb = _t.table orelse return -1;
    const _sel = _ui.Table.GetSelection(_tb) orelse return -1;
    defer _ui.Table.uiFreeTableSelection(_sel);
    if (_sel.NumRows < 1) return -1;
    return @intCast(_sel.Rows[0]);
}
fn _lui_table_activated_row(_id: []const u8) i64 {
    const _n = _lui_keyed.get(_id) orelse return -1;
    const _t = _n.table orelse return -1;
    const _v = _t.activated;
    _t.activated = -1;
    return _v;
}
fn _lui_begin_child(_id: []const u8, _cw: f64, _ch: f64) bool {
    _ = _id; _ = _cw; _ = _ch; return true;
}
fn _lui_set_color(_role: []const u8, _rv: f32, _gv: f32, _bv: f32, _av: f32) void {
    _ = _role; _ = _rv; _ = _gv; _ = _bv; _ = _av;
}
fn _lui_set_style_float(_name: []const u8, _v: f32) void { _ = _name; _ = _v; }
fn _lui_set_vec2(_name: []const u8, _xv: f32, _yv: f32) void { _ = _name; _ = _xv; _ = _yv; }
fn _lui_scale_all(_sc: f32) void { _ = _sc; }
fn _lui_get_dpi() f32 { return 1.0; }
fn _lui_ll_noop_line(_x1: f64, _y1: f64, _x2: f64, _y2: f64, _c: i64, _t: f64) void {
    _ = _x1; _ = _y1; _ = _x2; _ = _y2; _ = _c; _ = _t;
}
fn _lui_ll_noop_rect(_x1: f64, _y1: f64, _x2: f64, _y2: f64, _c: i64, _t: f64) void {
    _ = _x1; _ = _y1; _ = _x2; _ = _y2; _ = _c; _ = _t;
}
fn _lui_ll_noop_rectfill(_x1: f64, _y1: f64, _x2: f64, _y2: f64, _c: i64) void {
    _ = _x1; _ = _y1; _ = _x2; _ = _y2; _ = _c;
}
fn _lui_ll_noop_circle(_cx: f64, _cy: f64, _r: f64, _c: i64, _t: f64) void {
    _ = _cx; _ = _cy; _ = _r; _ = _c; _ = _t;
}
fn _lui_ll_noop_circlefill(_cx: f64, _cy: f64, _r: f64, _c: i64) void {
    _ = _cx; _ = _cy; _ = _r; _ = _c;
}
fn _lui_ll_noop_text(_x: f64, _y: f64, _c: i64, _s: []const u8) void {
    _ = _x; _ = _y; _ = _c; _ = _s;
}
fn _lui_ll_get_win_pos() _GuiVec2 { return .{ 0, 0 }; }
fn _lui_ll_get_win_size() _GuiVec2 {
    return .{ @floatFromInt(_lui_win_w), @floatFromInt(_lui_win_h) };
}
fn _lui_ll_get_cursor_pos() _GuiVec2 { return .{ 0, 0 }; }
fn _lui_ll_get_mouse_pos() _GuiVec2 { return .{ -1, -1 }; }
// Button keyed by a stable id, so its LABEL may change frame to frame (a tab row
// whose captions are file names, a Play/Pause toggle). `g.button(label)` keys on
// the label itself, which is right for fixed captions and wrong for these.
fn _lui_open_file() ?[]const u8 {
    const _cpath = _ui.Window.OpenFile(_lui_window orelse return null) orelse return null;
    defer _ui.FreeText(_cpath);
    const _s = std.mem.span(_cpath);
    return _allocator.dupe(u8, _s) catch null;
}
fn _lui_save_file() ?[]const u8 {
    const _cpath = _ui.Window.SaveFile(_lui_window orelse return null) orelse return null;
    defer _ui.FreeText(_cpath);
    const _s = std.mem.span(_cpath);
    return _allocator.dupe(u8, _s) catch null;
}
fn _lui_open_folder() ?[]const u8 {
    const _cpath = _ui.Window.OpenFolder(_lui_window orelse return null) orelse return null;
    defer _ui.FreeText(_cpath);
    const _s = std.mem.span(_cpath);
    return _allocator.dupe(u8, _s) catch null;
}
fn _lui_msg_box(_title: []const u8, _desc: []const u8) void {
    const _tz = _allocator.dupeZ(u8, _title) catch return;
    const _mz = _allocator.dupeZ(u8, _desc) catch return;
    _ui.Window.MsgBox(_lui_window orelse return, _tz, _mz);
}
fn _lui_msg_box_error(_title: []const u8, _desc: []const u8) void {
    const _tz = _allocator.dupeZ(u8, _title) catch return;
    const _mz = _allocator.dupeZ(u8, _desc) catch return;
    _ui.Window.MsgBoxError(_lui_window orelse return, _tz, _mz);
}
const _gui_lui_backend = _GuiBackend{
    .initFn             = _lui_init,
    .deinitFn           = _lui_deinit,
    .newFrameFn         = _lui_newframe,
    .everyFn       = _lui_every,
    .endFrameFn         = _lui_endframe,
    .textFn             = _lui_text,
    .separatorFn        = _lui_sep,
    .sameLineFn         = _lui_noop_void,
    .spacingFn          = _lui_noop_void,
    .indentFn           = _lui_noop_void,
    .unindentFn         = _lui_noop_void,
    .buttonFn           = _lui_button,
    .buttonIdFn         = _lui_button_id,
    .checkboxFn         = _lui_checkbox,
    .sliderFn           = _lui_slider,
    .inputFn            = _lui_input,
    .inputMultilineFn   = _lui_input_ml,
    .beginPanelFn       = _lui_begin_panel,
    .endPanelFn         = _lui_end_panel,
    .beginWindowFn      = _lui_noop_bool,
    .endWindowFn        = _lui_noop_void,
    .selectableFn       = _lui_selectable,
    .textColoredFn      = _lui_text_colored,
    .beginTableFn       = _lui_begin_table,
    .tableSetupColumnFn = _lui_table_setup_col,
    .tableHeadersRowFn  = _lui_table_headers_row,
    .tableNextRowFn     = _lui_table_next_row,
    .tableNextColumnFn  = _lui_table_next_col,
    .endTableFn         = _lui_end_table,
    .tableSelectedRowFn  = _lui_table_selected_row,
    .tableActivatedRowFn = _lui_table_activated_row,
    .beginChildFn       = _lui_begin_child,
    .endChildFn         = _lui_noop_void,
    .treeNodeFn         = _lui_noop_bool,
    .treePopFn          = _lui_noop_void,
    .setColorFn         = _lui_set_color,
    .setColorsDarkFn    = _lui_noop_void,
    .setStyleFloatFn    = _lui_set_style_float,
    .setVec2Fn          = _lui_set_vec2,
    .scaleAllSizesFn    = _lui_scale_all,
    .getDpiFn           = _lui_get_dpi,
    .ll_addLineFn         = _lui_ll_noop_line,
    .ll_addRectFn         = _lui_ll_noop_rect,
    .ll_addRectFilledFn   = _lui_ll_noop_rectfill,
    .ll_addCircleFn       = _lui_ll_noop_circle,
    .ll_addCircleFilledFn = _lui_ll_noop_circlefill,
    .ll_addTextFn         = _lui_ll_noop_text,
    .ll_getWindowPosFn    = _lui_ll_get_win_pos,
    .ll_getWindowSizeFn   = _lui_ll_get_win_size,
    .ll_getCursorPosFn    = _lui_ll_get_cursor_pos,
    .ll_getMousePosFn     = _lui_ll_get_mouse_pos,
    .ll_beginGroupFn      = _lui_noop_void,
    .ll_endGroupFn        = _lui_noop_void,
    .beginHBoxFn = _lui_begin_hbox,
    .endHBoxFn   = _lui_end_hbox,
    .beginVBoxFn   = _lui_begin_vbox,
    .endVBoxFn     = _lui_end_vbox,
    .beginTabsFn    = _lui_begin_tabs,
    .beginTabPageFn = _lui_begin_tab_page,
    .endTabPageFn   = _lui_end_tab_page,
    .endTabsFn      = _lui_end_tabs,
    .tabSelectedFn  = _lui_tab_selected,
    .selectTabFn    = _lui_select_tab,
    .minSizeFn      = _lui_min_size,
    .hotkeyFn       = _lui_hotkey,
    .actionFn       = _lui_action,
    .toggleFn       = _lui_toggle,
    .fieldFn        = _lui_field,
    .beginMenuFn    = _lui_begin_menu,
    .menuItemFn     = _lui_menu_item,
    .menuSeparatorFn = _lui_menu_separator,
    .menuQuitFn     = _lui_menu_quit,
    .endMenuFn      = _lui_end_menu,
    .takeKeyFn      = _lui_take_key,
    .progressBarFn = _lui_progressbar,
    .comboboxFn    = _lui_combobox,
    .spinboxFn     = _lui_spinbox,
    .openFileFn    = _lui_open_file,
    .saveFileFn    = _lui_save_file,
    .openFolderFn  = _lui_open_folder,
    .msgBoxFn      = _lui_msg_box,
    .msgBoxErrorFn = _lui_msg_box_error,
};
const _gui_active_backend: _GuiBackend = _gui_lui_backend;