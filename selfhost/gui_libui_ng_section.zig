// ─── GUI: backend isolation ──────────────────────────────────────────────────
// _GuiBackend is an fn-ptr struct.  Swap `_gui_active_backend` to change
// the renderer without touching user code or GuiContext.
const _GuiVec2 = struct { f64, f64 };
const _GuiBackend = struct {
    initFn:        *const fn (title: []const u8, width: i64, height: i64) anyerror!void,
    deinitFn:      *const fn () void,
    newFrameFn:    *const fn () bool,
    endFrameFn:    *const fn () void,
    textFn:        *const fn (s: []const u8) void,
    separatorFn:   *const fn () void,
    sameLineFn:    *const fn () void,
    spacingFn:     *const fn () void,
    indentFn:      *const fn () void,
    unindentFn:    *const fn () void,
    buttonFn:      *const fn (label: []const u8) bool,
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
    tableNextColumnFn:  *const fn () bool,
    endTableFn:         *const fn () void,
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
    _send_fn: ?*const fn(*anyopaque, *const anyopaque) void = null,
    _send_ptr: ?*anyopaque = null,
    pub fn send(self: GuiContext, msg: anytype) void {
        if (self._send_fn) |f| f(self._send_ptr.?, @ptrCast(&msg));
    }
    pub fn text(self: GuiContext, s: []const u8) void { self._b.textFn(s); }
    pub fn separator(self: GuiContext) void { self._b.separatorFn(); }
    pub fn sameLine(self: GuiContext) void { self._b.sameLineFn(); }
    pub fn spacing(self: GuiContext) void { self._b.spacingFn(); }
    pub fn indent(self: GuiContext) void { self._b.indentFn(); }
    pub fn unindent(self: GuiContext) void { self._b.unindentFn(); }
    pub fn button(self: GuiContext, label: []const u8) bool { return self._b.buttonFn(label); }
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
    pub fn tableNextColumn(self: GuiContext) bool { return self._b.tableNextColumnFn(); }
    pub fn endTable(self: GuiContext) void { self._b.endTableFn(); }
    pub fn childWindow(self: GuiContext, id: []const u8, w: f64, h: f64, callback: anytype) void {
        const _vis = self._b.beginChildFn(id, w, h);
        if (_vis) {
            if (comptime @typeInfo(@TypeOf(callback)) == .@"fn") callback(self) else callback.call(self);
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
            if (comptime @typeInfo(@TypeOf(callback)) == .@"fn") callback(self) else callback.call(self);
            self._b.endPanelFn();
        }
    }
    pub fn window(self: GuiContext, label: []const u8, callback: anytype) void {
        if (self._b.beginWindowFn(label)) {
            if (comptime @typeInfo(@TypeOf(callback)) == .@"fn") callback(self) else callback.call(self);
            self._b.endWindowFn();
        }
    }
    pub fn beginHBox(self: GuiContext, id: []const u8, stretch: bool) void { self._b.beginHBoxFn(id, stretch); }
    pub fn endHBox(self: GuiContext) void { self._b.endHBoxFn(); }
    pub fn beginVBox(self: GuiContext, id: []const u8, stretch: bool) void { self._b.beginVBoxFn(id, stretch); }
    pub fn endVBox(self: GuiContext) void { self._b.endVBoxFn(); }
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
    if (comptime @typeInfo(@TypeOf(frame)) == .@"fn") {
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
fn _gui_mvu_run(title: []const u8, width: i64, height: i64, _mvu_init: anytype, _mvu_update: anytype, _mvu_view: anytype) void {
    _gui_active_backend.initFn(title, width, height) catch @panic("gui init failed");
    defer _gui_active_backend.deinitFn();
    const MsgType = comptime blk: {
        if (@typeInfo(@TypeOf(_mvu_update)) == .@"fn")
            break :blk @typeInfo(@TypeOf(_mvu_update)).@"fn".params[1].type.?
        else
            break :blk @typeInfo(@TypeOf(@TypeOf(_mvu_update).call)).@"fn".params[2].type.?;
    };
    const _MvuQueue = struct { buf: [32]MsgType = undefined, len: usize = 0 };
    var _pq = _MvuQueue{};
    const _sfn = struct {
        fn send(ctx: *anyopaque, mp: *const anyopaque) void {
            const q: *_MvuQueue = @ptrCast(@alignCast(ctx));
            if (q.len < 32) { q.buf[q.len] = (@as(*const MsgType, @ptrCast(@alignCast(mp)))).* ; q.len += 1; }
        }
    }.send;
    var _model = if (comptime @typeInfo(@TypeOf(_mvu_init)) == .@"fn") _mvu_init() else blk: { var _m = _mvu_init; break :blk _m.call(); };
    const _g = GuiContext{ ._b = &_gui_active_backend, .lowLevel = .{ ._b = &_gui_active_backend }, ._send_fn = _sfn, ._send_ptr = &_pq };
    while (_gui_active_backend.newFrameFn()) {
        if (comptime @typeInfo(@TypeOf(_mvu_view)) == .@"fn") _mvu_view(_g, _model) else { var _mv = _mvu_view; _mv.call(_g, _model); }
        for (_pq.buf[0.._pq.len]) |msg| {
            if (comptime @typeInfo(@TypeOf(_mvu_update)) == .@"fn")
                _model = _mvu_update(_model, msg)
            else { var _mu = _mvu_update; _model = _mu.call(_model, msg); }
        }
        _pq.len = 0;
        _gui_active_backend.endFrameFn();
    }
}
// ─── CodeEditor widget — Scintilla via libui-scintilla ───────────────────────
const sci = @import("sci");
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
const _CodeEditor = struct {
    scint: ?*sci.Scintilla = null,
    read_only: bool = false,
    buf: []u8 = &.{},
    len: usize = 0,
};
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
fn _code_editor_set_text(_ed: *_CodeEditor, text: []const u8) void {
    if (!_ce_reserve(_ed, text.len)) return;
    @memcpy(_ed.buf[0..text.len], text);
    _ed.buf[text.len] = 0;
    _ed.len = text.len;
    if (_ed.scint) |_s| _s.setText(_ed.buf[0.._ed.len]);
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
        _ed.scint = sci.Scintilla.new() catch return;
        // Safe unconditionally now: `buf[len] == 0` holds even when len == 0
        // (the old code had to skip the empty case to avoid the strlen crash).
        if (_ed.buf.len > 0) _ed.scint.?.setText(_ed.buf[0.._ed.len]);
        if (_ed.read_only) _ = _ed.scint.?.sendMessage(2171, 1, 0);
        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _ed.scint.?.as_control(), .stretch);
    }
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
// ─── libui-ng retained-mode adapter ──────────────────────────────────────────
const ui = @import("ui");
const _LuiMut = struct {
    ctrl: ?*ui.Control = null,
    lbl: ?*ui.Label = null,
    clicked: bool = false,
    checked: bool = false,
    text_buf: [1024]u8 = undefined,
    text_len: usize = 0,
    sval: c_int = 0,
    smin: f64 = 0,
    smax: f64 = 1,
    pb: ?*ui.ProgressBar = null,
};
const _LuiPanel = struct { inner: *ui.Box };
var _lui_icache: std.StringHashMap(*_LuiMut) = undefined;
var _lui_dcache: std.ArrayList(*_LuiMut) = undefined;
var _lui_didx: usize = 0;
var _lui_frame: u32 = 0;
var _lui_quit: bool = false;
var _lui_win_w: i64 = 800;
var _lui_win_h: i64 = 600;
var _lui_window: ?*ui.Window = null;
var _lui_root_box: ?*ui.Box = null;
var _lui_box_stack: [32]?*ui.Box = [_]?*ui.Box{null} ** 32;
var _lui_box_depth: usize = 0;
var _lui_box_icache: std.StringHashMap(*ui.Box) = undefined;
var _lui_grp_cache: std.StringHashMap(_LuiPanel) = undefined;
fn _lui_cur_box() ?*ui.Box {
    if (_lui_box_depth == 0) return null;
    return _lui_box_stack[_lui_box_depth - 1];
}
fn _lui_push_box(_b: *ui.Box) void {
    if (_lui_box_depth < 32) { _lui_box_stack[_lui_box_depth] = _b; _lui_box_depth += 1; }
}
fn _lui_pop_box() void { if (_lui_box_depth > 1) _lui_box_depth -= 1; }
fn _lui_on_close(_w: *ui.Window, _q: ?*bool) anyerror!ui.Window.ClosingAction {
    _ = _w;
    if (_q) |p| p.* = true;
    ui.Quit();
    return .should_close;
}
fn _lui_btn_cb(_btn: *ui.Button, _m: ?*_LuiMut) anyerror!void {
    _ = _btn;
    if (_m) |p| p.clicked = true;
}
fn _lui_chk_cb(_chk: *ui.Checkbox, _m: ?*_LuiMut) anyerror!void {
    if (_m) |p| p.checked = _chk.Checked();
}
fn _lui_entry_cb(_ent: *ui.Entry, _m: ?*_LuiMut) anyerror!void {
    if (_m) |p| {
        const _s = std.mem.span(_ent.Text());
        const _n = @min(_s.len, 1023);
        @memcpy(p.text_buf[0.._n], _s[0.._n]);
        p.text_len = _n;
    }
}
fn _lui_mle_cb(_mle: *ui.MultilineEntry, _m: ?*_LuiMut) anyerror!void {
    if (_m) |p| {
        const _s = std.mem.span(_mle.Text());
        const _n = @min(_s.len, 1023);
        @memcpy(p.text_buf[0.._n], _s[0.._n]);
        p.text_len = _n;
    }
}
fn _lui_slider_cb(_sld: *ui.Slider, _m: ?*_LuiMut) anyerror!void {
    if (_m) |p| p.sval = _sld.Value();
}
fn _lui_cmb_cb(_c: *ui.Combobox, _m: ?*_LuiMut) anyerror!void {
    if (_m) |p| p.sval = _c.Selected();
}
fn _lui_spn_cb(_s: *ui.Spinbox, _m: ?*_LuiMut) anyerror!void {
    if (_m) |p| p.sval = _s.Value();
}
fn _lui_init(_title: []const u8, _width: i64, _height: i64) anyerror!void {
    _lui_win_w = _width; _lui_win_h = _height;
    var _d = ui.InitData{ .options = .{ .Size = @sizeOf(ui.InitOptions) } };
    try ui.Init(&_d);
    _lui_icache = std.StringHashMap(*_LuiMut).init(_allocator);
    _lui_dcache = .empty;
    _lui_box_icache = std.StringHashMap(*ui.Box).init(_allocator);
    _lui_grp_cache = std.StringHashMap(_LuiPanel).init(_allocator);
    _lui_box_depth = 0;
    var _tbuf: [256]u8 = undefined;
    const _tz: [:0]u8 = try std.fmt.bufPrintZ(&_tbuf, "{s}", .{_title});
    _lui_window = try ui.Window.New(_tz, @intCast(_width), @intCast(_height), .hide_menubar);
    ui.Window.OnClosing(_lui_window.?, bool, anyerror, _lui_on_close, &_lui_quit);
    _lui_root_box = try ui.Box.New(.Vertical);
    _lui_root_box.?.SetPadded(true);
    _lui_push_box(_lui_root_box.?);
    ui.Timer(anyopaque, anyerror, 100, _lui_poll_tick, null);
    _lui_frame = 0; _lui_quit = false;
}
fn _lui_poll_tick(_: ?*anyopaque) anyerror!ui.TimerAction { return .rearm; }
fn _lui_deinit() void {
    _lui_icache.deinit();
    _lui_dcache.deinit(_allocator);
    _lui_box_icache.deinit();
    _lui_grp_cache.deinit();
    ui.Uninit();
}
fn _lui_newframe() bool {
    _lui_didx = 0;
    if (_lui_frame == 0) return true;
    if (_lui_quit) return false;
    return ui.MainStep(.blocking) == .running and !_lui_quit;
}
fn _lui_endframe() void {
    _lui_box_depth = 1; // reset to root box only
    if (_lui_frame == 0) {
        _lui_frame = 1;
        if (_lui_window) |_w| {
            if (_lui_root_box) |_vb| _w.SetChild(_vb.as_control());
            _w.SetMargined(true);
            _w.as_control().Show();
        }
    }
}
const _LuiIR = struct { m: *_LuiMut, fresh: bool };
fn _lui_iget(_label: []const u8) _LuiIR {
    if (_lui_icache.get(_label)) |_m| return .{ .m = _m, .fresh = false };
    const _m = _allocator.create(_LuiMut) catch unreachable;
    _m.* = .{};
    _lui_icache.put(_label, _m) catch unreachable;
    return .{ .m = _m, .fresh = true };
}
fn _lui_dget() _LuiIR {
    if (_lui_didx < _lui_dcache.items.len) {
        const _m = _lui_dcache.items[_lui_didx];
        _lui_didx += 1;
        return .{ .m = _m, .fresh = false };
    }
    const _m = _allocator.create(_LuiMut) catch unreachable;
    _m.* = .{};
    _lui_dcache.append(_allocator, _m) catch unreachable;
    _lui_didx += 1;
    return .{ .m = _m, .fresh = true };
}
fn _lui_text(_s: []const u8) void {
    const _r = _lui_dget();
    const _n = @min(_s.len, 510);
    var _tb: [512]u8 = undefined;
    @memcpy(_tb[0.._n], _s[0.._n]);
    _tb[_n] = 0;
    const _tz: [:0]u8 = _tb[0.._n :0];
    if (_r.fresh) {
        const _lbl = ui.Label.New(_tz) catch return;
        _r.m.lbl = _lbl;
        _r.m.ctrl = _lbl.as_control();
        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _lbl.as_control(), .dont_stretch);
    } else {
        if (_r.m.lbl) |_lb| _lb.SetText(_tz);
    }
}
fn _lui_sep() void {
    const _r = _lui_dget();
    if (_r.fresh) {
        const _sep = ui.Separator.New(.Horizontal) catch return;
        _r.m.ctrl = _sep.as_control();
        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _sep.as_control(), .dont_stretch);
    }
}
fn _lui_noop_void() void {}
fn _lui_noop_bool(_l: []const u8) bool { _ = _l; return true; }
fn _lui_selectable(_l: []const u8) bool { _ = _l; return false; }
fn _lui_text_colored(_rv: f32, _gv: f32, _bv: f32, _av: f32, _s: []const u8) void {
    _ = _rv; _ = _gv; _ = _bv; _ = _av; _lui_text(_s);
}
fn _lui_begin_table(_id: []const u8, _cols: i64) bool { _ = _id; _ = _cols; return true; }
fn _lui_table_setup_col(_l: []const u8) void { _ = _l; }
fn _lui_table_next_col() bool { return true; }
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
fn _lui_button(_label: []const u8) bool {
    const _r = _lui_iget(_label);
    if (_r.fresh) {
        const _n = @min(_label.len, 255);
        var _lb: [256]u8 = undefined;
        @memcpy(_lb[0.._n], _label[0.._n]);
        _lb[_n] = 0;
        const _lz: [:0]u8 = _lb[0.._n :0];
        const _btn = ui.Button.New(_lz) catch return false;
        ui.Button.OnClicked(_btn, _LuiMut, anyerror, _lui_btn_cb, _r.m);
        _r.m.ctrl = _btn.as_control();
        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _btn.as_control(), .dont_stretch);
    }
    const _clicked = _r.m.clicked;
    _r.m.clicked = false;
    return _clicked;
}
fn _lui_checkbox(_label: []const u8, _value: bool) bool {
    const _r = _lui_iget(_label);
    if (_r.fresh) {
        const _n = @min(_label.len, 255);
        var _lb: [256]u8 = undefined;
        @memcpy(_lb[0.._n], _label[0.._n]);
        _lb[_n] = 0;
        const _lz: [:0]u8 = _lb[0.._n :0];
        const _chk = ui.Checkbox.New(_lz) catch return _value;
        _chk.SetChecked(_value);
        _r.m.checked = _value;
        ui.Checkbox.OnToggled(_chk, _LuiMut, anyerror, _lui_chk_cb, _r.m);
        _r.m.ctrl = _chk.as_control();
        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _chk.as_control(), .dont_stretch);
    }
    return _r.m.checked;
}
fn _lui_slider(_label: []const u8, _value: f64, _min: f64, _max: f64) f64 {
    const _r = _lui_iget(_label);
    if (_r.fresh) {
        const _n = @min(_label.len, 255);
        var _lb: [256]u8 = undefined;
        @memcpy(_lb[0.._n], _label[0.._n]);
        _lb[_n] = 0;
        const _lz: [:0]u8 = _lb[0.._n :0];
        const _sllbl = ui.Label.New(_lz) catch return _value;
        const _sld = ui.Slider.New(0, 1000) catch return _value;
        const _raw: c_int = @intFromFloat((_value - _min) / (_max - _min) * 1000.0);
        const _init: c_int = if (_raw < 0) 0 else if (_raw > 1000) 1000 else _raw;
        _sld.SetValue(_init);
        _r.m.sval = _init; _r.m.smin = _min; _r.m.smax = _max;
        ui.Slider.OnChanged(_sld, _LuiMut, anyerror, _lui_slider_cb, _r.m);
        _r.m.ctrl = _sld.as_control();
        _r.m.lbl = _sllbl;
        if (_lui_cur_box()) |_vb| {
            ui.Box.Append(_vb, _sllbl.as_control(), .dont_stretch);
            ui.Box.Append(_vb, _sld.as_control(), .dont_stretch);
        }
    }
    const _t = @as(f64, @floatFromInt(_r.m.sval)) / 1000.0;
    return _r.m.smin + _t * (_r.m.smax - _r.m.smin);
}
fn _lui_input(_label: []const u8, _value: []const u8) []const u8 {
    const _r = _lui_iget(_label);
    if (_r.fresh) {
        const _n = @min(_label.len, 255);
        var _lb: [256]u8 = undefined;
        @memcpy(_lb[0.._n], _label[0.._n]);
        _lb[_n] = 0;
        const _lz: [:0]u8 = _lb[0.._n :0];
        const _enlbl = ui.Label.New(_lz) catch return _value;
        const _ent = ui.Entry.New(.Entry) catch return _value;
        const _vn = @min(_value.len, 1022);
        var _vtb: [1024]u8 = undefined;
        @memcpy(_vtb[0.._vn], _value[0.._vn]);
        _vtb[_vn] = 0;
        _ent.SetText(_vtb[0.._vn :0]);
        @memcpy(_r.m.text_buf[0.._vn], _value[0.._vn]);
        _r.m.text_len = _vn;
        ui.Entry.OnChanged(_ent, _LuiMut, anyerror, _lui_entry_cb, _r.m);
        _r.m.ctrl = _ent.as_control();
        _r.m.lbl = _enlbl;
        if (_lui_cur_box()) |_vb| {
            ui.Box.Append(_vb, _enlbl.as_control(), .dont_stretch);
            ui.Box.Append(_vb, _ent.as_control(), .dont_stretch);
        }
    }
    return _r.m.text_buf[0.._r.m.text_len];
}
fn _lui_input_ml(_label: []const u8, _value: []const u8, _mw: f64, _mh: f64) []const u8 {
    _ = _mw; _ = _mh;
    const _r = _lui_iget(_label);
    if (_r.fresh) {
        const _n = @min(_label.len, 255);
        var _lb: [256]u8 = undefined;
        @memcpy(_lb[0.._n], _label[0.._n]);
        _lb[_n] = 0;
        const _lz: [:0]u8 = _lb[0.._n :0];
        const _mllbl = ui.Label.New(_lz) catch return _value;
        const _mle = ui.MultilineEntry.New(.Wrapping) catch return _value;
        const _vn = @min(_value.len, 1022);
        var _vtb: [1024]u8 = undefined;
        @memcpy(_vtb[0.._vn], _value[0.._vn]);
        _vtb[_vn] = 0;
        _mle.SetText(_vtb[0.._vn :0]);
        @memcpy(_r.m.text_buf[0.._vn], _value[0.._vn]);
        _r.m.text_len = _vn;
        ui.MultilineEntry.OnChanged(_mle, _LuiMut, anyerror, _lui_mle_cb, _r.m);
        _r.m.ctrl = _mle.as_control();
        _r.m.lbl = _mllbl;
        if (_lui_cur_box()) |_vb| {
            ui.Box.Append(_vb, _mllbl.as_control(), .dont_stretch);
            ui.Box.Append(_vb, _mle.as_control(), .stretch);
        }
    }
    return _r.m.text_buf[0.._r.m.text_len];
}
fn _lui_begin_hbox(_id: []const u8, _stretch: bool) void {
    const _e = _lui_box_icache.getOrPut(_id) catch return;
    if (!_e.found_existing) {
        const _hb = ui.Box.New(.Horizontal) catch return;
        _hb.SetPadded(true);
        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _hb.as_control(), if (_stretch) ui.Stretchy.stretch else ui.Stretchy.dont_stretch);
        _e.value_ptr.* = _hb;
    }
    _lui_push_box(_e.value_ptr.*);
}
fn _lui_end_hbox() void { if (_lui_box_depth > 1) _lui_box_depth -= 1; }
fn _lui_begin_vbox(_id: []const u8, _stretch: bool) void {
    const _e = _lui_box_icache.getOrPut(_id) catch return;
    if (!_e.found_existing) {
        const _vb2 = ui.Box.New(.Vertical) catch return;
        _vb2.SetPadded(false);
        if (_lui_cur_box()) |_pvb| ui.Box.Append(_pvb, _vb2.as_control(), if (_stretch) ui.Stretchy.stretch else ui.Stretchy.dont_stretch);
        _e.value_ptr.* = _vb2;
    }
    _lui_push_box(_e.value_ptr.*);
}
fn _lui_end_vbox() void { if (_lui_box_depth > 1) _lui_box_depth -= 1; }
fn _lui_begin_panel(_label: []const u8) bool {
    if (_lui_grp_cache.get(_label)) |_p| {
        _lui_push_box(_p.inner);
        return true;
    }
    const _n = @min(_label.len, 255);
    var _lb: [256]u8 = undefined;
    @memcpy(_lb[0.._n], _label[0.._n]);
    _lb[_n] = 0;
    const _lz: [:0]u8 = _lb[0.._n :0];
    const _grp = ui.Group.New(_lz) catch return true;
    const _inner = ui.Box.New(.Vertical) catch return true;
    _inner.SetPadded(true);
    _grp.SetChild(_inner.as_control());
    _grp.SetMargined(true);
    if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _grp.as_control(), .dont_stretch);
    _lui_grp_cache.put(_label, .{ .inner = _inner }) catch {};
    _lui_push_box(_inner);
    return true;
}
fn _lui_end_panel() void { if (_lui_box_depth > 1) _lui_box_depth -= 1; }
fn _lui_progressbar(_label: []const u8, _value: f64) void {
    _ = _label;
    const _r = _lui_dget();
    const _pct: c_int = @intFromFloat(_value * 100.0);
    const _clamped: c_int = if (_pct < 0) 0 else if (_pct > 100) 100 else _pct;
    if (_r.fresh) {
        const _pb = ui.ProgressBar.New() catch return;
        _pb.SetValue(_clamped);
        _r.m.pb = _pb;
        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _pb.as_control(), .dont_stretch);
    } else {
        if (_r.m.pb) |_pb| _pb.SetValue(_clamped);
    }
}
fn _lui_combobox(_label: []const u8, _items: []const []const u8, _sel: i64) i64 {
    const _r = _lui_iget(_label);
    if (_r.fresh) {
        const _cmb = ui.Combobox.New() catch return _sel;
        for (_items) |_it| {
            const _n = @min(_it.len, 255);
            var _lb: [256]u8 = undefined;
            @memcpy(_lb[0.._n], _it[0.._n]);
            _lb[_n] = 0;
            const _lz: [:0]u8 = _lb[0.._n :0];
            ui.Combobox.Append(_cmb, _lz);
        }
        const _init: c_int = @intCast(_sel);
        _cmb.SetSelected(_init);
        _r.m.sval = _init;
        ui.Combobox.OnSelected(_cmb, _LuiMut, anyerror, _lui_cmb_cb, _r.m);
        _r.m.ctrl = _cmb.as_control();
        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _cmb.as_control(), .dont_stretch);
    }
    return @as(i64, @intCast(_r.m.sval));
}
fn _lui_spinbox(_label: []const u8, _value: i64, _min: i64, _max: i64) i64 {
    const _r = _lui_iget(_label);
    if (_r.fresh) {
        const _spn = ui.Spinbox.New(.{ .Integer = .{ .min = @intCast(_min), .max = @intCast(_max) } }) catch return _value;
        _spn.SetValue(@intCast(_value));
        _r.m.sval = @intCast(_value);
        ui.Spinbox.OnChanged(_spn, _LuiMut, anyerror, _lui_spn_cb, _r.m);
        _r.m.ctrl = _spn.as_control();
        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _spn.as_control(), .dont_stretch);
    }
    return @as(i64, @intCast(_r.m.sval));
}
fn _lui_open_file() ?[]const u8 {
    const _cpath = ui.Window.OpenFile(_lui_window.?) orelse return null;
    defer ui.FreeText(_cpath);
    const _s = std.mem.span(_cpath);
    return _allocator.dupe(u8, _s) catch null;
}
fn _lui_save_file() ?[]const u8 {
    const _cpath = ui.Window.SaveFile(_lui_window.?) orelse return null;
    defer ui.FreeText(_cpath);
    const _s = std.mem.span(_cpath);
    return _allocator.dupe(u8, _s) catch null;
}
fn _lui_open_folder() ?[]const u8 {
    const _cpath = ui.Window.OpenFolder(_lui_window.?) orelse return null;
    defer ui.FreeText(_cpath);
    const _s = std.mem.span(_cpath);
    return _allocator.dupe(u8, _s) catch null;
}
fn _lui_msg_box(_title: []const u8, _desc: []const u8) void {
    const _tz = _allocator.dupeZ(u8, _title) catch return;
    const _mz = _allocator.dupeZ(u8, _desc) catch return;
    ui.Window.MsgBox(_lui_window.?, _tz, _mz);
}
fn _lui_msg_box_error(_title: []const u8, _desc: []const u8) void {
    const _tz = _allocator.dupeZ(u8, _title) catch return;
    const _mz = _allocator.dupeZ(u8, _desc) catch return;
    ui.Window.MsgBoxError(_lui_window.?, _tz, _mz);
}
const _gui_lui_backend = _GuiBackend{
    .initFn             = _lui_init,
    .deinitFn           = _lui_deinit,
    .newFrameFn         = _lui_newframe,
    .endFrameFn         = _lui_endframe,
    .textFn             = _lui_text,
    .separatorFn        = _lui_sep,
    .sameLineFn         = _lui_noop_void,
    .spacingFn          = _lui_noop_void,
    .indentFn           = _lui_noop_void,
    .unindentFn         = _lui_noop_void,
    .buttonFn           = _lui_button,
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
    .tableHeadersRowFn  = _lui_noop_void,
    .tableNextRowFn     = _lui_noop_void,
    .tableNextColumnFn  = _lui_table_next_col,
    .endTableFn         = _lui_noop_void,
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