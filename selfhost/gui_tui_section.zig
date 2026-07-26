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
// ─── CodeEditor widget — text buffer stub (no native editor) ─────────────────
const _CodeEditor = struct { text: []const u8, read_only: bool };
fn _code_editor_new() *_CodeEditor {
    const _ed = _allocator.create(_CodeEditor) catch unreachable;
    _ed.* = .{ .text = "", .read_only = false };
    return _ed;
}
fn _code_editor_set_text(_ed: *_CodeEditor, text: []const u8) void { _ed.text = text; }
fn _code_editor_get_text(_ed: *_CodeEditor) []const u8 { return _ed.text; }
fn _code_editor_set_readonly(_ed: *_CodeEditor, v: bool) void { _ed.read_only = v; }
fn _code_editor_render(_ed: *_CodeEditor, _g: GuiContext, id: []const u8, w: f64, h: f64) void {
    const _r = _g.inputMultiline(id, _ed.text, w, h);
    if (!_ed.read_only) { _ed.text = _r; }
}
fn _code_editor_set_error_markers(_ed: *_CodeEditor, _m: anytype) void { _ = _ed; _ = _m; }
fn _code_editor_get_cursor_line(_ed: *_CodeEditor) i64 { _ = _ed; return 1; }
fn _code_editor_get_cursor_col(_ed: *_CodeEditor) i64 { _ = _ed; return 1; }
fn _code_editor_set_cursor_position(_ed: *_CodeEditor, line: i64, col: i64) void { _ = _ed; _ = line; _ = col; }
// ─── ZigZag TUI backend ──────────────────────────────────────────────────────
const zz = @import("zigzag");
var _tui_env: *std.process.Environ.Map = undefined;
var _tui_terminal: ?zz.Terminal = null;
var _tui_current_row: u16 = 0;
var _tui_click_y: i32 = -1;
var _tui_quit: bool = false;
var _tui_indent_level: u16 = 0;
fn _tui_init(title: []const u8, width: i64, height: i64) anyerror!void {
    _ = width; _ = height;
    var _t = try zz.Terminal.init(_io, _tui_env, .{
        .alt_screen = true,
        .mouse = true,
        .hide_cursor = true,
        .bracketed_paste = false,
    });
    try _t.setTitle(title);
    _tui_terminal = _t;
}
fn _tui_deinit() void {
    if (_tui_terminal) |*_t| _t.deinit();
    _tui_terminal = null;
}
fn _tui_new_frame() bool {
    if (_tui_quit) return false;
    const _t = &(_tui_terminal orelse return false);
    _tui_click_y = -1;
    _tui_indent_level = 0;
    var _buf: [256]u8 = undefined;
    const _n = _t.readInput(&_buf, 16) catch 0;
    if (_n > 0) {
        const _evs = zz.input.keyboard.parseAll(_allocator, _buf[0.._n]) catch &.{};
        for (_evs) |_ev| {
            switch (_ev) {
                .key => |_k| switch (_k.key) {
                    .char => |_c| { if (_c == 'q' or _c == 'Q') _tui_quit = true; },
                    .escape => { _tui_quit = true; },
                    else => {},
                },
                .mouse => |_m| {
                    if (_m.event_type == .press and _m.button == .left)
                        _tui_click_y = @as(i32, _m.y);
                },
                .none => {},
            }
        }
    }
    _t.clear() catch return false;
    _tui_current_row = 0;
    return !_tui_quit;
}
fn _tui_end_frame() void {
    if (_tui_terminal) |*_t| _t.flush() catch {};
}
fn _tui_text(s: []const u8) void {
    if (_tui_terminal) |*_t| {
        _t.writeAt(_tui_current_row, _tui_indent_level * 2, s) catch {};
        _tui_current_row += 1;
    }
}
fn _tui_separator() void {
    if (_tui_terminal) |*_t| {
        _t.writeAt(_tui_current_row, 0, "──────────────────────────────") catch {};
        _tui_current_row += 1;
    }
}
fn _tui_same_line() void {}
fn _tui_spacing() void { _tui_current_row += 1; }
fn _tui_indent() void { _tui_indent_level += 1; }
fn _tui_unindent() void { if (_tui_indent_level > 0) _tui_indent_level -= 1; }
fn _tui_button(label: []const u8) bool {
    const _row = _tui_current_row;
    _tui_current_row += 1;
    if (_tui_terminal) |*_t| {
        const _col = _tui_indent_level * 2;
        const _clicked = (_tui_click_y == @as(i32, _row));
        var _buf: [256]u8 = undefined;
        const _s = std.fmt.bufPrint(&_buf, "[ {s} ]", .{label}) catch label;
        if (_clicked) {
            var _sb: [320]u8 = undefined;
            const _rs = std.fmt.bufPrint(&_sb, "\x1b[7m{s}\x1b[27m", .{_s}) catch _s;
            _t.writeAt(_row, _col, _rs) catch {};
        } else {
            _t.writeAt(_row, _col, _s) catch {};
        }
        return _clicked;
    }
    return false;
}
fn _tui_checkbox(label: []const u8, value: bool) bool {
    const _row = _tui_current_row;
    _tui_current_row += 1;
    if (_tui_terminal) |*_t| {
        const _col = _tui_indent_level * 2;
        var _buf: [256]u8 = undefined;
        const _s = std.fmt.bufPrint(&_buf, "[{s}] {s}", .{ if (value) "x" else " ", label }) catch label;
        _t.writeAt(_row, _col, _s) catch {};
        if (_tui_click_y == @as(i32, _row)) return !value;
    }
    return value;
}
fn _tui_slider(label: []const u8, value: f64, min: f64, max: f64) f64 {
    _ = min; _ = max;
    if (_tui_terminal) |*_t| {
        const _col = _tui_indent_level * 2;
        var _buf: [256]u8 = undefined;
        const _s = std.fmt.bufPrint(&_buf, "{s}: {d:.2}", .{ label, value }) catch label;
        _t.writeAt(_tui_current_row, _col, _s) catch {};
        _tui_current_row += 1;
    }
    return value;
}
fn _tui_input(label: []const u8, value: []const u8) []const u8 {
    if (_tui_terminal) |*_t| {
        const _col = _tui_indent_level * 2;
        var _buf: [256]u8 = undefined;
        const _s = std.fmt.bufPrint(&_buf, "{s}: {s}", .{ label, value }) catch label;
        _t.writeAt(_tui_current_row, _col, _s) catch {};
        _tui_current_row += 1;
    }
    return value;
}
fn _tui_input_multiline(label: []const u8, value: []const u8, w: f64, h: f64) []const u8 {
    _ = w; _ = h;
    return _tui_input(label, value);
}
fn _tui_begin_panel(label: []const u8) bool {
    if (_tui_terminal) |*_t| {
        const _col = _tui_indent_level * 2;
        var _buf: [256]u8 = undefined;
        const _s = std.fmt.bufPrint(&_buf, "\x1b[1m\u{25b6} {s}\x1b[22m", .{label}) catch label;
        _t.writeAt(_tui_current_row, _col, _s) catch {};
        _tui_current_row += 1;
        _tui_indent_level += 1;
    }
    return true;
}
fn _tui_end_panel() void { if (_tui_indent_level > 0) _tui_indent_level -= 1; }
fn _tui_begin_window(label: []const u8) bool { return _tui_begin_panel(label); }
fn _tui_end_window() void { _tui_end_panel(); }
fn _tui_selectable(label: []const u8) bool {
    const _row = _tui_current_row;
    _tui_text(label);
    return _tui_click_y == @as(i32, _row);
}
fn _tui_text_colored(r: f32, gv: f32, b_: f32, a: f32, s: []const u8) void {
    _ = r; _ = gv; _ = b_; _ = a;
    _tui_text(s);
}
fn _tui_begin_table(id: []const u8, cols: i64) bool { _ = id; _ = cols; return true; }
fn _tui_table_setup_column(label: []const u8) void { _ = label; }
fn _tui_table_headers_row() void {}
fn _tui_table_next_row() void { _tui_current_row += 1; }
fn _tui_table_next_column() bool { return true; }
fn _tui_end_table() void {}
fn _tui_begin_child(id: []const u8, w: f64, h: f64) bool { _ = id; _ = w; _ = h; return true; }
fn _tui_end_child() void {}
fn _tui_tree_node(label: []const u8) bool { return _tui_begin_panel(label); }
fn _tui_tree_pop() void { _tui_end_panel(); }
fn _tui_set_color(role: []const u8, r: f32, g: f32, b: f32, a: f32) void { _ = role; _ = r; _ = g; _ = b; _ = a; }
fn _tui_set_colors_dark() void {}
fn _tui_set_style_float(name: []const u8, value: f32) void { _ = name; _ = value; }
fn _tui_set_vec2(name: []const u8, x: f32, y: f32) void { _ = name; _ = x; _ = y; }
fn _tui_scale_all_sizes(scale: f32) void { _ = scale; }
fn _tui_get_dpi() f32 { return 1.0; }
fn _tui_ll_add_line(x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void { _ = x1; _ = y1; _ = x2; _ = y2; _ = col; _ = thickness; }
fn _tui_ll_add_rect(x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void { _ = x1; _ = y1; _ = x2; _ = y2; _ = col; _ = thickness; }
fn _tui_ll_add_rect_filled(x1: f64, y1: f64, x2: f64, y2: f64, col: i64) void { _ = x1; _ = y1; _ = x2; _ = y2; _ = col; }
fn _tui_ll_add_circle(cx: f64, cy: f64, r: f64, col: i64, thickness: f64) void { _ = cx; _ = cy; _ = r; _ = col; _ = thickness; }
fn _tui_ll_add_circle_filled(cx: f64, cy: f64, r: f64, col: i64) void { _ = cx; _ = cy; _ = r; _ = col; }
fn _tui_ll_add_text(x: f64, y: f64, col: i64, text: []const u8) void { _ = x; _ = y; _ = col; _ = text; }
fn _tui_ll_get_window_pos() _GuiVec2 { return .{ 0, 0 }; }
fn _tui_ll_get_window_size() _GuiVec2 { return .{ 80, 24 }; }
fn _tui_ll_get_cursor_pos() _GuiVec2 { return .{ 0, @floatFromInt(_tui_current_row) }; }
fn _tui_ll_get_mouse_pos() _GuiVec2 {
    return .{ 0, if (_tui_click_y >= 0) @floatFromInt(_tui_click_y) else -1 };
}
fn _tui_ll_begin_group() void {}
fn _tui_ll_end_group() void {}
fn _tui_begin_hbox(id: []const u8, stretch: bool) void { _ = id; _ = stretch; }
fn _tui_end_hbox() void {}
fn _tui_begin_vbox(id: []const u8, stretch: bool) void { _ = id; _ = stretch; }
fn _tui_end_vbox() void {}
fn _tui_progressbar(_l: []const u8, _v: f64) void { _ = _l; _ = _v; }
fn _tui_combobox(_l: []const u8, _items: []const []const u8, _sel: i64) i64 { _ = _l; _ = _items; return _sel; }
fn _tui_spinbox(_l: []const u8, _v: i64, _min: i64, _max: i64) i64 { _ = _l; _ = _min; _ = _max; return _v; }
fn _tui_open_file() ?[]const u8 { return null; }
fn _tui_save_file() ?[]const u8 { return null; }
fn _tui_open_folder() ?[]const u8 { return null; }
fn _tui_msg_box(_t: []const u8, _m: []const u8) void { _ = _t; _ = _m; }
fn _tui_msg_box_error(_t: []const u8, _m: []const u8) void { _ = _t; _ = _m; }
const _gui_tui_backend = _GuiBackend{
    .initFn             = _tui_init,
    .deinitFn           = _tui_deinit,
    .newFrameFn         = _tui_new_frame,
    .endFrameFn         = _tui_end_frame,
    .textFn             = _tui_text,
    .separatorFn        = _tui_separator,
    .sameLineFn         = _tui_same_line,
    .spacingFn          = _tui_spacing,
    .indentFn           = _tui_indent,
    .unindentFn         = _tui_unindent,
    .buttonFn           = _tui_button,
    .checkboxFn         = _tui_checkbox,
    .sliderFn           = _tui_slider,
    .inputFn            = _tui_input,
    .inputMultilineFn   = _tui_input_multiline,
    .beginPanelFn       = _tui_begin_panel,
    .endPanelFn         = _tui_end_panel,
    .beginWindowFn      = _tui_begin_window,
    .endWindowFn        = _tui_end_window,
    .selectableFn       = _tui_selectable,
    .textColoredFn      = _tui_text_colored,
    .beginTableFn       = _tui_begin_table,
    .tableSetupColumnFn = _tui_table_setup_column,
    .tableHeadersRowFn  = _tui_table_headers_row,
    .tableNextRowFn     = _tui_table_next_row,
    .tableNextColumnFn  = _tui_table_next_column,
    .endTableFn         = _tui_end_table,
    .beginChildFn       = _tui_begin_child,
    .endChildFn         = _tui_end_child,
    .treeNodeFn         = _tui_tree_node,
    .treePopFn          = _tui_tree_pop,
    .setColorFn         = _tui_set_color,
    .setColorsDarkFn    = _tui_set_colors_dark,
    .setStyleFloatFn    = _tui_set_style_float,
    .setVec2Fn          = _tui_set_vec2,
    .scaleAllSizesFn    = _tui_scale_all_sizes,
    .getDpiFn           = _tui_get_dpi,
    .ll_addLineFn         = _tui_ll_add_line,
    .ll_addRectFn         = _tui_ll_add_rect,
    .ll_addRectFilledFn   = _tui_ll_add_rect_filled,
    .ll_addCircleFn       = _tui_ll_add_circle,
    .ll_addCircleFilledFn = _tui_ll_add_circle_filled,
    .ll_addTextFn         = _tui_ll_add_text,
    .ll_getWindowPosFn    = _tui_ll_get_window_pos,
    .ll_getWindowSizeFn   = _tui_ll_get_window_size,
    .ll_getCursorPosFn    = _tui_ll_get_cursor_pos,
    .ll_getMousePosFn     = _tui_ll_get_mouse_pos,
    .ll_beginGroupFn      = _tui_ll_begin_group,
    .ll_endGroupFn        = _tui_ll_end_group,
    .beginHBoxFn   = _tui_begin_hbox,
    .endHBoxFn     = _tui_end_hbox,
    .beginVBoxFn   = _tui_begin_vbox,
    .endVBoxFn     = _tui_end_vbox,
    .progressBarFn = _tui_progressbar,
    .comboboxFn    = _tui_combobox,
    .spinboxFn     = _tui_spinbox,
    .openFileFn    = _tui_open_file,
    .saveFileFn    = _tui_save_file,
    .openFolderFn  = _tui_open_folder,
    .msgBoxFn      = _tui_msg_box,
    .msgBoxErrorFn = _tui_msg_box_error,
};
const _gui_active_backend: _GuiBackend = _gui_tui_backend;