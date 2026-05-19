//! Zebra DAP (Debug Adapter Protocol) proxy.
//!
//! Sits between an IDE (VS Code, JetBrains, etc.) and lldb-dap,
//! intercepting and remapping source locations between .zbr Zebra files
//! and the generated .zig intermediaries.
//!
//! Entry point: runDebugSession(zbr_path, zig_path, c_sources, alloc)
//!
//! Architecture:
//!
//!   IDE ─ stdin/stdout ─→ zebra debug ─ child stdin/stdout ─→ lldb-dap
//!                              │                                    │
//!                         [ide→lldb]                         [lldb→ide]
//!                         remap zbr→zig                    remap zig→zbr
//!                         in setBreakpoints                in stackTrace
//!
//! Source map:
//!   Built from `// zbr:file:line` comments emitted by CodeGen.
//!   Each comment appears on its own line immediately before the
//!   generated Zig statement it annotates.  Example:
//!     // zbr:selfhost\main.zbr:60
//!     self.visited = std.ArrayList([]const u8){};
//!
//! Prerequisites: lldb-dap (or lldb-vscode) must be on PATH.
//!   Windows: winget install LLVM.LLVM (then add llvm/bin to PATH)
//!   Ubuntu:  apt install lldb
//!   macOS:   brew install llvm  /  xcode-select --install

const std     = @import("std");
const builtin = @import("builtin");

// ── Source map ────────────────────────────────────────────────────────────────

pub const ZbrLoc = struct { file: []const u8, line: u32 };

pub const SourceMap = struct {
    alloc: std.mem.Allocator,

    /// zig_line (1-based, the COMMENT line) → ZbrLoc
    /// Walk backward from a code zig_line to find the nearest preceding marker.
    zig_to_zbr: std.AutoHashMap(u32, ZbrLoc),

    /// zbr_file (normalized forward-slash) → sorted list of {zbr_line, zig_line}
    /// zig_line is the CODE line (comment + 1) so breakpoints land on executable lines.
    zbr_to_zig: std.StringHashMap(std.ArrayListUnmanaged(LineEntry)),

    pub const LineEntry = struct { zbr_line: u32, zig_line: u32 };

    pub fn init(alloc: std.mem.Allocator) SourceMap {
        return .{
            .alloc      = alloc,
            .zig_to_zbr = std.AutoHashMap(u32, ZbrLoc).init(alloc),
            .zbr_to_zig = std.StringHashMap(std.ArrayListUnmanaged(LineEntry)).init(alloc),
        };
    }

    pub fn deinit(self: *SourceMap) void {
        var rit = self.zig_to_zbr.valueIterator();
        while (rit.next()) |loc| self.alloc.free(loc.file);
        self.zig_to_zbr.deinit();

        var fit = self.zbr_to_zig.iterator();
        while (fit.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.alloc);
        }
        self.zbr_to_zig.deinit();
    }

    /// Parse `// zbr:file:line` comments from the generated Zig source.
    pub fn loadFromZigSrc(self: *SourceMap, zig_src: []const u8) !void {
        var zig_line: u32 = 1;
        var lines = std.mem.splitScalar(u8, zig_src, '\n');
        while (lines.next()) |line| : (zig_line += 1) {
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "// zbr:")) continue;
            const payload = trimmed["// zbr:".len..];
            // Use LAST colon to split — Windows paths contain colons: C:\foo.zbr:10
            const last_colon = std.mem.lastIndexOfScalar(u8, payload, ':') orelse continue;
            const zbr_file_raw = payload[0..last_colon];
            const zbr_line_num = std.fmt.parseInt(u32, payload[last_colon + 1 ..], 10) catch continue;

            // Reverse map: comment zig_line → ZbrLoc (owns file string).
            const zbr_file_owned = try self.alloc.dupe(u8, zbr_file_raw);
            errdefer self.alloc.free(zbr_file_owned);
            try self.zig_to_zbr.put(zig_line, .{ .file = zbr_file_owned, .line = zbr_line_num });

            // Forward map: normalize separators for cross-platform matching.
            const key_norm = try normalizeSep(self.alloc, zbr_file_raw);
            errdefer self.alloc.free(key_norm);
            const gop = try self.zbr_to_zig.getOrPut(key_norm);
            if (gop.found_existing) {
                self.alloc.free(key_norm); // key already owned by map
            } else {
                gop.key_ptr.* = key_norm;
                gop.value_ptr.* = .{};
            }
            // Store zig_line + 1: the code line after the comment, so the
            // breakpoint lands on an executable line, not a comment.
            try gop.value_ptr.append(self.alloc, .{
                .zbr_line = zbr_line_num,
                .zig_line = zig_line + 1,
            });
        }

        // Sort each list by zbr_line for binary search.
        var sit = self.zbr_to_zig.valueIterator();
        while (sit.next()) |list| {
            std.mem.sort(LineEntry, list.items, {}, struct {
                fn lt(_: void, a: LineEntry, b: LineEntry) bool {
                    return a.zbr_line < b.zbr_line;
                }
            }.lt);
        }
    }

    /// Forward lookup: zbr_file (any separator) × zbr_line → zig line (1-based).
    pub fn zbrToZig(self: *const SourceMap, zbr_file_raw: []const u8, zbr_line: u32) ?u32 {
        var buf: [4096]u8 = undefined;
        const key = normalizeSepBuf(&buf, zbr_file_raw);

        const list = self.zbr_to_zig.get(key) orelse return null;
        if (list.items.len == 0) return null;

        // Binary search: first entry with zbr_line >= zbr_line.
        var lo: usize = 0;
        var hi: usize = list.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (list.items[mid].zbr_line < zbr_line) lo = mid + 1 else hi = mid;
        }
        if (lo >= list.items.len) lo = list.items.len - 1;
        return list.items[lo].zig_line;
    }

    /// Reverse lookup: zig line (1-based) → ZbrLoc (backward walk).
    pub fn zigToZbr(self: *const SourceMap, zig_line: u32) ?ZbrLoc {
        var l = zig_line;
        while (l > 0) : (l -= 1) {
            if (self.zig_to_zbr.get(l)) |loc| return loc;
        }
        return null;
    }

    /// Find the canonical forward-slash key in zbr_to_zig that best
    /// suffix-matches the IDE-provided absolute path (any separator).
    pub fn findCanonicalZbr(self: *const SourceMap, abs_path: []const u8) ?[]const u8 {
        var buf: [4096]u8 = undefined;
        const norm_abs = normalizeSepBuf(&buf, abs_path);

        var best: ?[]const u8 = null;
        var best_len: usize = 0;
        var kit = self.zbr_to_zig.keyIterator();
        while (kit.next()) |key| {
            if (std.mem.endsWith(u8, norm_abs, key.*) and key.*.len > best_len) {
                best = key.*;
                best_len = key.*.len;
            }
        }
        return best;
    }
};

fn normalizeSep(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const buf = try alloc.dupe(u8, path);
    for (buf) |*c| { if (c.* == '\\') c.* = '/'; }
    return buf;
}

fn normalizeSepBuf(buf: []u8, path: []const u8) []const u8 {
    const len = @min(path.len, buf.len);
    @memcpy(buf[0..len], path[0..len]);
    for (buf[0..len]) |*c| { if (c.* == '\\') c.* = '/'; }
    return buf[0..len];
}

// ── DAP transport ─────────────────────────────────────────────────────────────

const DapTransport = struct {
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
    mu:     std.Thread.Mutex,

    fn init(r: std.io.AnyReader, w: std.io.AnyWriter) DapTransport {
        return .{ .reader = r, .writer = w, .mu = .{} };
    }

    /// Read one DAP message body.  Caller owns the returned slice.
    fn readMessage(self: *DapTransport, alloc: std.mem.Allocator) ![]u8 {
        var content_length: usize = 0;
        var line_buf: std.ArrayListUnmanaged(u8) = .{};
        defer line_buf.deinit(alloc);

        while (true) {
            line_buf.clearRetainingCapacity();
            while (true) {
                const b = try self.reader.readByte();
                if (b == '\n') break;
                if (b != '\r') try line_buf.append(alloc, b);
            }
            if (line_buf.items.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(line_buf.items, "Content-Length:")) {
                const val = std.mem.trimLeft(u8, line_buf.items["Content-Length:".len..], " \t");
                content_length = std.fmt.parseInt(usize, val, 10) catch return error.BadContentLength;
            }
        }

        if (content_length == 0) return error.MissingContentLength;
        const body = try alloc.alloc(u8, content_length);
        errdefer alloc.free(body);
        try self.reader.readNoEof(body);
        return body;
    }

    /// Write one DAP message body, thread-safe.
    fn writeMessage(self: *DapTransport, body: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
        try self.writer.writeAll(body);
    }
};

// ── TCP stream wrapper ────────────────────────────────────────────────────────

// Wraps std.net.Stream to provide std.io.AnyReader / AnyWriter.
// Must be stored at a stable address — do not move it after creating
// readers/writers from it (the AnyReader/AnyWriter hold a pointer to self).
const NetStreamWrapper = struct {
    stream: std.net.Stream,

    fn anyReader(self: *NetStreamWrapper) std.io.AnyReader {
        return .{ .context = self, .readFn = readFn };
    }

    fn anyWriter(self: *NetStreamWrapper) std.io.AnyWriter {
        return .{ .context = self, .writeFn = writeFn };
    }

    fn readFn(context: *const anyopaque, buffer: []u8) anyerror!usize {
        const self: *const NetStreamWrapper = @alignCast(@ptrCast(context));
        return self.stream.read(buffer);
    }

    fn writeFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
        const self: *const NetStreamWrapper = @alignCast(@ptrCast(context));
        return self.stream.write(bytes);
    }
};

// ── Relay thread ──────────────────────────────────────────────────────────────

// Each relay thread reads from ctx.reader and writes to ctx.writer.
//
// Stdio mode (runDebugSession):
//   ide_xport  : reader=IDE stdin,   writer=lldb stdin   → ctx_fwd: reader=writer=ide_xport
//   lldb_xport : reader=lldb stdout, writer=IDE stdout   → ctx_rev: reader=writer=lldb_xport
//
// Listen mode (runDebugSessionListen):
//   client_xport : reader=IDE TCP,  writer=IDE TCP
//   lldb_xport   : reader=lldb TCP, writer=lldb TCP
//   ctx_fwd: reader=client_xport, writer=lldb_xport   (IDE → lldb)
//   ctx_rev: reader=lldb_xport,   writer=client_xport (lldb → IDE)
const RelayCtx = struct {
    reader:    *DapTransport,
    writer:    *DapTransport,
    smap:      *const SourceMap,
    direction: Direction,
    alloc:     std.mem.Allocator,

    const Direction = enum { ide_to_lldb, lldb_to_ide };
};

fn relayThread(ctx: RelayCtx) void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();

        const body = ctx.reader.readMessage(a) catch |err| {
            switch (err) {
                error.EndOfStream,
                error.BrokenPipe,
                error.ConnectionResetByPeer,
                error.NotOpenForReading,
                => return,
                else => {
                    std.debug.print("zebra debug: relay read: {}\n", .{err});
                    return;
                },
            }
        };

        const out = transform(ctx, body, a) catch body;
        ctx.writer.writeMessage(out) catch return;
    }
}

// ── Message transformation ────────────────────────────────────────────────────

fn transform(ctx: RelayCtx, body: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{
        .duplicate_field_behavior = .use_last,
        .ignore_unknown_fields    = true,
    });

    const root = switch (parsed.value) {
        .object => |m| m,
        else    => return body,
    };

    return switch (ctx.direction) {
        .ide_to_lldb => blk: {
            const cmd = root.get("command") orelse break :blk body;
            if (cmd != .string) break :blk body;
            if (std.mem.eql(u8, cmd.string, "setBreakpoints"))
                break :blk remapSetBreakpoints(ctx, root, body, alloc) catch body
            else
                break :blk body;
        },
        .lldb_to_ide => blk: {
            const typ = root.get("type") orelse break :blk body;
            if (typ != .string or !std.mem.eql(u8, typ.string, "response")) break :blk body;
            const cmd = root.get("command") orelse break :blk body;
            if (cmd != .string) break :blk body;
            if (std.mem.eql(u8, cmd.string, "stackTrace"))
                break :blk remapStackTrace(ctx, root, body, alloc) catch body
            else
                break :blk body;
        },
    };
}

// ── setBreakpoints remapping (ide→lldb: zbr → zig) ───────────────────────────

fn remapSetBreakpoints(
    ctx:   RelayCtx,
    root:  std.json.ObjectMap,
    orig:  []const u8,
    alloc: std.mem.Allocator,
) ![]const u8 {
    const args_val = root.get("arguments") orelse return orig;
    if (args_val != .object) return orig;
    const args = args_val.object;

    const source_val = args.get("source") orelse return orig;
    if (source_val != .object) return orig;
    const source = source_val.object;

    const path_val = source.get("path") orelse return orig;
    if (path_val != .string) return orig;
    const zbr_abs = path_val.string;

    if (!std.mem.endsWith(u8, zbr_abs, ".zbr") and
        !std.mem.endsWith(u8, zbr_abs, ".ZBR")) return orig;

    const stem = pathStem(zbr_abs);
    const zig_abs = try std.fmt.allocPrint(alloc, "{s}.zig", .{stem});

    const zbr_canonical = ctx.smap.findCanonicalZbr(zbr_abs);

    const bps_val = args.get("breakpoints") orelse return orig;
    if (bps_val != .array) return orig;

    var out = std.io.Writer.Allocating.init(alloc);
    const w = &out.writer;

    try w.writeByte('{');
    var first = true;
    var it = root.iterator();
    while (it.next()) |entry| {
        if (!first) try w.writeByte(',');
        first = false;

        if (!std.mem.eql(u8, entry.key_ptr.*, "arguments")) {
            try jsonKey(w, entry.key_ptr.*);
            try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
            continue;
        }

        // "arguments": rebuilt with remapped source + breakpoints
        try w.writeAll("\"arguments\":{");
        var afirst = true;
        var ait = args.iterator();
        while (ait.next()) |ae| {
            const k = ae.key_ptr.*;
            if (std.mem.eql(u8, k, "source") or std.mem.eql(u8, k, "breakpoints")) continue;
            if (!afirst) try w.writeByte(',');
            afirst = false;
            try jsonKey(w, k);
            try std.json.Stringify.value(ae.value_ptr.*, .{}, w);
        }

        if (!afirst) try w.writeByte(',');
        try w.writeAll("\"source\":{");
        var sfirst = true;
        var sit2 = source.iterator();
        while (sit2.next()) |se| {
            if (!sfirst) try w.writeByte(',');
            sfirst = false;
            try jsonKey(w, se.key_ptr.*);
            if (std.mem.eql(u8, se.key_ptr.*, "path")) {
                try std.json.Stringify.value(zig_abs, .{}, w);
            } else {
                try std.json.Stringify.value(se.value_ptr.*, .{}, w);
            }
        }
        try w.writeByte('}');

        try w.writeAll(",\"breakpoints\":[");
        for (bps_val.array.items, 0..) |bp, bpi| {
            if (bpi > 0) try w.writeByte(',');
            if (bp != .object) {
                try std.json.Stringify.value(bp, .{}, w);
                continue;
            }
            const bp_obj = bp.object;
            try w.writeByte('{');
            var bfirst = true;
            var bit = bp_obj.iterator();
            while (bit.next()) |be| {
                if (!bfirst) try w.writeByte(',');
                bfirst = false;
                try jsonKey(w, be.key_ptr.*);
                if (std.mem.eql(u8, be.key_ptr.*, "line") and be.value_ptr.* == .integer) {
                    const zbr_line: u32 = @intCast(@max(0, be.value_ptr.*.integer));
                    const zig_line = if (zbr_canonical) |zc|
                        ctx.smap.zbrToZig(zc, zbr_line) orelse zbr_line
                    else
                        zbr_line;
                    try w.print("{d}", .{zig_line});
                } else {
                    try std.json.Stringify.value(be.value_ptr.*, .{}, w);
                }
            }
            try w.writeByte('}');
        }
        try w.writeByte(']');
        try w.writeByte('}');
    }
    try w.writeByte('}');

    return out.toOwnedSlice();
}

// ── stackTrace response remapping (lldb→ide: zig → zbr) ──────────────────────

fn remapStackTrace(
    ctx:   RelayCtx,
    root:  std.json.ObjectMap,
    orig:  []const u8,
    alloc: std.mem.Allocator,
) ![]const u8 {
    const body_val = root.get("body") orelse return orig;
    if (body_val != .object) return orig;
    const body_obj = body_val.object;
    const frames_val = body_obj.get("stackFrames") orelse return orig;
    if (frames_val != .array) return orig;

    var out = std.io.Writer.Allocating.init(alloc);
    const w = &out.writer;

    try w.writeByte('{');
    var first = true;
    var it = root.iterator();
    while (it.next()) |entry| {
        if (!first) try w.writeByte(',');
        first = false;
        try jsonKey(w, entry.key_ptr.*);

        if (!std.mem.eql(u8, entry.key_ptr.*, "body")) {
            try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
            continue;
        }

        try w.writeByte('{');
        var bfirst = true;
        var bit = body_obj.iterator();
        while (bit.next()) |be| {
            if (!bfirst) try w.writeByte(',');
            bfirst = false;
            try jsonKey(w, be.key_ptr.*);

            if (!std.mem.eql(u8, be.key_ptr.*, "stackFrames")) {
                try std.json.Stringify.value(be.value_ptr.*, .{}, w);
                continue;
            }

            try w.writeByte('[');
            for (frames_val.array.items, 0..) |frame, fi| {
                if (fi > 0) try w.writeByte(',');
                if (frame != .object) {
                    try std.json.Stringify.value(frame, .{}, w);
                    continue;
                }
                try remapFrame(ctx, frame.object, w);
            }
            try w.writeByte(']');
        }
        try w.writeByte('}');
    }
    try w.writeByte('}');

    return out.toOwnedSlice();
}

fn remapFrame(ctx: RelayCtx, frame: std.json.ObjectMap, w: *std.io.Writer) !void {
    const zig_line: u32 = blk: {
        const lv = frame.get("line") orelse break :blk 0;
        if (lv != .integer) break :blk 0;
        break :blk @intCast(@max(0, lv.integer));
    };

    const zbr_loc = if (zig_line > 0) ctx.smap.zigToZbr(zig_line) else null;

    const is_zig_src = blk: {
        const sv = frame.get("source") orelse break :blk false;
        if (sv != .object) break :blk false;
        const pv = sv.object.get("path") orelse break :blk false;
        if (pv != .string) break :blk false;
        break :blk std.mem.endsWith(u8, pv.string, ".zig");
    };

    try w.writeByte('{');
    var first = true;
    var it = frame.iterator();
    while (it.next()) |entry| {
        if (!first) try w.writeByte(',');
        first = false;
        try jsonKey(w, entry.key_ptr.*);

        if (std.mem.eql(u8, entry.key_ptr.*, "line") and zbr_loc != null and is_zig_src) {
            try w.print("{d}", .{zbr_loc.?.line});
        } else if (std.mem.eql(u8, entry.key_ptr.*, "source") and is_zig_src and zbr_loc != null) {
            const src_obj = entry.value_ptr.*.object;
            try w.writeByte('{');
            var sfirst = true;
            var sit = src_obj.iterator();
            while (sit.next()) |se| {
                if (!sfirst) try w.writeByte(',');
                sfirst = false;
                try jsonKey(w, se.key_ptr.*);
                if (std.mem.eql(u8, se.key_ptr.*, "path")) {
                    try std.json.Stringify.value(zbr_loc.?.file, .{}, w);
                } else if (std.mem.eql(u8, se.key_ptr.*, "name")) {
                    try std.json.Stringify.value(std.fs.path.basename(zbr_loc.?.file), .{}, w);
                } else {
                    try std.json.Stringify.value(se.value_ptr.*, .{}, w);
                }
            }
            try w.writeByte('}');
        } else {
            try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
        }
    }
    try w.writeByte('}');
}

fn jsonKey(w: *std.io.Writer, key: []const u8) !void {
    try std.json.Stringify.value(key, .{}, w);
    try w.writeByte(':');
}

fn pathStem(path: []const u8) []const u8 {
    const last_sep = std.mem.lastIndexOfAny(u8, path, "/\\") orelse 0;
    if (std.mem.lastIndexOf(u8, path, ".")) |dot| {
        if (dot > last_sep) return path[0..dot];
    }
    return path;
}

// ── Debug compile: .zig → binary with debug info ──────────────────────────────

fn compileDebug(zig_path: []const u8, c_sources: []const []u8, alloc: std.mem.Allocator) !u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(alloc);
    var i_flags: std.ArrayListUnmanaged([]u8) = .{};
    defer { for (i_flags.items) |f| alloc.free(f); i_flags.deinit(alloc); }

    try argv.appendSlice(alloc, &.{ "zig", "build-exe", zig_path });

    var seen_dirs = std.StringHashMap(void).init(alloc);
    defer seen_dirs.deinit();
    for (c_sources) |cs| {
        try argv.append(alloc, cs);
        const dir = std.fs.path.dirname(cs) orelse ".";
        const gop = try seen_dirs.getOrPut(dir);
        if (!gop.found_existing) {
            const flag = try std.fmt.allocPrint(alloc, "-I{s}", .{dir});
            try i_flags.append(alloc, flag);
            try argv.append(alloc, flag);
        }
    }
    try argv.append(alloc, "-lc");

    var child = std.process.Child.init(argv.items, alloc);
    child.stdin_behavior  = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited  => |c| c,
        .Signal  => 1,
        .Stopped => 1,
        .Unknown => 1,
    };
}

// ── lldb-dap discovery ────────────────────────────────────────────────────────

fn findLldbDap(alloc: std.mem.Allocator) ?[]u8 {
    const is_windows = builtin.os.tag == .windows;
    const candidates = if (is_windows)
        [_][]const u8{ "lldb-dap.exe", "lldb-vscode.exe" }
    else
        [_][]const u8{ "lldb-dap", "lldb-vscode" };

    for (candidates) |name| {
        if (findOnPath(name, alloc)) |p| return p;
    }

    // Fallback: check common install locations not always on PATH.
    if (is_windows) {
        const win_dirs = [_][]const u8{
            "C:\\Program Files\\LLVM\\bin",
            "C:\\Program Files (x86)\\LLVM\\bin",
        };
        for (win_dirs) |dir| {
            for (candidates) |name| {
                const full = std.fs.path.join(alloc, &.{ dir, name }) catch continue;
                defer alloc.free(full);
                std.fs.cwd().access(full, .{}) catch continue;
                return alloc.dupe(u8, full) catch null;
            }
        }
    } else {
        const unix_dirs = [_][]const u8{
            "/usr/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
        };
        for (unix_dirs) |dir| {
            for (candidates) |name| {
                const full = std.fs.path.join(alloc, &.{ dir, name }) catch continue;
                defer alloc.free(full);
                std.fs.cwd().access(full, .{}) catch continue;
                return alloc.dupe(u8, full) catch null;
            }
        }
    }
    return null;
}

fn findOnPath(name: []const u8, alloc: std.mem.Allocator) ?[]u8 {
    const path_env = std.process.getEnvVarOwned(alloc, "PATH") catch return null;
    defer alloc.free(path_env);

    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, path_env, sep);
    while (it.next()) |dir| {
        const candidate = std.fs.path.join(alloc, &.{ dir, name }) catch continue;
        defer alloc.free(candidate);
        std.fs.cwd().access(candidate, .{}) catch continue;
        return alloc.dupe(u8, candidate) catch null;
    }
    return null;
}

/// Find the directory containing python311.dll for LLDB's scripting support.
/// Returns an owned slice the caller must free, or null if not needed / not found.
fn findPythonDir(alloc: std.mem.Allocator) ?[]u8 {
    if (builtin.os.tag != .windows) return null;

    // Already on PATH — no extra dir needed.
    if (findOnPath("python311.dll", alloc)) |p| { alloc.free(p); return null; }

    // Common per-user and system install locations from winget / python.org installer.
    const local_app_data = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch null;
    defer if (local_app_data) |d| alloc.free(d);

    const program_files = std.process.getEnvVarOwned(alloc, "ProgramFiles") catch null;
    defer if (program_files) |d| alloc.free(d);

    var candidates = std.ArrayListUnmanaged([]u8){};
    defer { for (candidates.items) |c| alloc.free(c); candidates.deinit(alloc); }

    if (local_app_data) |lad| {
        for ([_][]const u8{ "Python311", "Python3.11" }) |sub| {
            const p = std.fs.path.join(alloc, &.{ lad, "Programs", "Python", sub }) catch continue;
            candidates.append(alloc, p) catch { alloc.free(p); };
        }
    }
    if (program_files) |pf| {
        for ([_][]const u8{ "Python311", "Python3.11" }) |sub| {
            const p = std.fs.path.join(alloc, &.{ pf, sub }) catch continue;
            candidates.append(alloc, p) catch { alloc.free(p); };
        }
    }
    for ([_][]const u8{ "C:\\Python311", "C:\\Python3.11" }) |dir| {
        const p = alloc.dupe(u8, dir) catch continue;
        candidates.append(alloc, p) catch { alloc.free(p); };
    }

    for (candidates.items) |dir| {
        const dll = std.fs.path.join(alloc, &.{ dir, "python311.dll" }) catch continue;
        defer alloc.free(dll);
        std.fs.cwd().access(dll, .{}) catch continue;
        return alloc.dupe(u8, dir) catch null;
    }
    return null;
}

// ── Entry point ───────────────────────────────────────────────────────────────

/// Run a DAP proxy debug session.
///
/// Precondition: `zig_path` has already been written to disk by CodeGen.
pub fn runDebugSession(
    zbr_path:  []const u8,
    zig_path:  []const u8,
    c_sources: []const []u8,
    alloc:     std.mem.Allocator,
) !u8 {
    // 1. Build source map.
    const zig_src = std.fs.cwd().readFileAlloc(alloc, zig_path, 64 * 1024 * 1024) catch |err| {
        std.debug.print("zebra debug: cannot read '{s}': {}\n", .{ zig_path, err });
        return 1;
    };
    defer alloc.free(zig_src);

    var smap = SourceMap.init(alloc);
    defer smap.deinit();
    try smap.loadFromZigSrc(zig_src);
    std.debug.print("zebra debug: source map built ({d} zbr files)\n",
        .{smap.zbr_to_zig.count()});

    // 2. Compile to debug binary (Debug optimization = full DWARF info).
    std.debug.print("zebra debug: compiling '{s}'...\n", .{zbr_path});
    const cc = try compileDebug(zig_path, c_sources, alloc);
    if (cc != 0) return cc;

    // 3. Find lldb-dap.
    const lldb_path = findLldbDap(alloc) orelse {
        std.debug.print(
            \\zebra debug: lldb-dap not found on PATH.
            \\
            \\Install LLDB:
            \\  Windows : winget install LLVM.LLVM  (then add <LLVM>\bin to PATH)
            \\  Ubuntu  : sudo apt install lldb
            \\  macOS   : brew install llvm  OR  xcode-select --install
            \\
            \\After installing, ensure 'lldb-dap' (or 'lldb-vscode') is on PATH.
            \\
        , .{});
        return 1;
    };
    defer alloc.free(lldb_path);
    std.debug.print("zebra debug: using {s}\n", .{lldb_path});

    // 4. Spawn lldb-dap.
    // Build a PATH for the child that includes:
    //   a) lldb-dap's own directory (so liblldb.dll is found)
    //   b) Python 3.11 directory if installed but not on PATH (so python311.dll is found)
    const lldb_dir = std.fs.path.dirname(lldb_path) orelse ".";
    var env_map = try std.process.getEnvMap(alloc);
    defer env_map.deinit();
    const old_path = env_map.get("PATH") orelse env_map.get("Path") orelse "";
    const path_sep: u8 = if (builtin.os.tag == .windows) ';' else ':';

    const py_dir: ?[]u8 = findPythonDir(alloc);
    defer if (py_dir) |d| alloc.free(d);

    var extra_dirs = std.ArrayListUnmanaged([]const u8){};
    defer extra_dirs.deinit(alloc);
    try extra_dirs.append(alloc, lldb_dir);
    if (py_dir) |d| try extra_dirs.append(alloc, d);

    const sep_str: []const u8 = if (builtin.os.tag == .windows) ";" else ":";
    const extra = try std.mem.join(alloc, sep_str, extra_dirs.items);
    defer alloc.free(extra);
    const new_path = try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{ extra, path_sep, old_path });
    defer alloc.free(new_path);
    try env_map.put("PATH", new_path);
    // Disable Python scripting in LLDB — avoids a crash on Windows when the
    // LLVM package's embedded Python ABI doesn't match the installed Python.
    // None of the source-map remapping or DAP relay logic needs Python.
    if (builtin.os.tag == .windows and env_map.get("LLDB_DISABLE_PYTHON") == null) {
        try env_map.put("LLDB_DISABLE_PYTHON", "1");
    }

    const lldb_argv = [_][]const u8{lldb_path};
    var lldb_child = std.process.Child.init(&lldb_argv, alloc);
    lldb_child.stdin_behavior  = .Pipe;
    lldb_child.stdout_behavior = .Pipe;
    lldb_child.stderr_behavior = .Inherit;
    lldb_child.env_map = &env_map;
    try lldb_child.spawn();

    var ide_xport = DapTransport.init(
        std.fs.File.stdin().deprecatedReader().any(),
        lldb_child.stdin.?.deprecatedWriter().any(),
    );
    var lldb_xport = DapTransport.init(
        lldb_child.stdout.?.deprecatedReader().any(),
        std.fs.File.stdout().deprecatedWriter().any(),
    );

    const ctx_fwd = RelayCtx{
        .reader    = &ide_xport,
        .writer    = &ide_xport,
        .smap      = &smap,
        .direction = .ide_to_lldb,
        .alloc     = alloc,
    };
    const ctx_rev = RelayCtx{
        .reader    = &lldb_xport,
        .writer    = &lldb_xport,
        .smap      = &smap,
        .direction = .lldb_to_ide,
        .alloc     = alloc,
    };

    // 5. Relay threads + wait.
    const t1 = try std.Thread.spawn(.{}, relayThread, .{ctx_fwd});
    const t2 = try std.Thread.spawn(.{}, relayThread, .{ctx_rev});
    t1.join();
    t2.join();

    const term = try lldb_child.wait();
    return switch (term) {
        .Exited  => |c| c,
        .Signal  => 1,
        .Stopped => 1,
        .Unknown => 1,
    };
}

// ── Listen mode entry point ───────────────────────────────────────────────────

/// Run a DAP TCP relay debug session.
///
/// Instead of piping stdio to lldb-dap, this function:
///   - Spawns lldb-dap with `--connection listen://127.0.0.1:<internal>`.
///   - Binds `ide_port` for the custom IDE to connect to.
///   - Relays DAP messages between the IDE TCP stream and lldb-dap TCP stream
///     with the same source remapping as `runDebugSession`.
///
/// Usage: zebra debug --listen PORT file.zbr
pub fn runDebugSessionListen(
    zbr_path:  []const u8,
    zig_path:  []const u8,
    c_sources: []const []u8,
    ide_port:  u16,
    alloc:     std.mem.Allocator,
) !u8 {
    // 1. Build source map.
    const zig_src = std.fs.cwd().readFileAlloc(alloc, zig_path, 64 * 1024 * 1024) catch |err| {
        std.debug.print("zebra debug: cannot read '{s}': {}\n", .{ zig_path, err });
        return 1;
    };
    defer alloc.free(zig_src);

    var smap = SourceMap.init(alloc);
    defer smap.deinit();
    try smap.loadFromZigSrc(zig_src);
    std.debug.print("zebra debug: source map built ({d} zbr files)\n",
        .{smap.zbr_to_zig.count()});

    // 2. Compile to debug binary.
    std.debug.print("zebra debug: compiling '{s}'...\n", .{zbr_path});
    const cc = try compileDebug(zig_path, c_sources, alloc);
    if (cc != 0) return cc;

    // 3. Find lldb-dap.
    const lldb_path = findLldbDap(alloc) orelse {
        std.debug.print(
            \\zebra debug: lldb-dap not found on PATH.
            \\
            \\Install LLDB:
            \\  Windows : winget install LLVM.LLVM  (then add <LLVM>\bin to PATH)
            \\  Ubuntu  : sudo apt install lldb
            \\  macOS   : brew install llvm  OR  xcode-select --install
            \\
        , .{});
        return 1;
    };
    defer alloc.free(lldb_path);
    std.debug.print("zebra debug: using {s}\n", .{lldb_path});

    // 4. Build child env (PATH + LLDB_DISABLE_PYTHON, same as stdio mode).
    const lldb_dir = std.fs.path.dirname(lldb_path) orelse ".";
    var env_map = try std.process.getEnvMap(alloc);
    defer env_map.deinit();
    const old_path = env_map.get("PATH") orelse env_map.get("Path") orelse "";
    const path_sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const sep_str: []const u8 = if (builtin.os.tag == .windows) ";" else ":";

    const py_dir: ?[]u8 = findPythonDir(alloc);
    defer if (py_dir) |d| alloc.free(d);

    var extra_dirs = std.ArrayListUnmanaged([]const u8){};
    defer extra_dirs.deinit(alloc);
    try extra_dirs.append(alloc, lldb_dir);
    if (py_dir) |d| try extra_dirs.append(alloc, d);

    const extra = try std.mem.join(alloc, sep_str, extra_dirs.items);
    defer alloc.free(extra);
    const new_path = try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{ extra, path_sep, old_path });
    defer alloc.free(new_path);
    try env_map.put("PATH", new_path);
    if (builtin.os.tag == .windows and env_map.get("LLDB_DISABLE_PYTHON") == null) {
        try env_map.put("LLDB_DISABLE_PYTHON", "1");
    }

    // 5. Pick an OS-assigned internal port for lldb-dap's TCP listener,
    //    then release it (small race window — acceptable for a local tool).
    const internal_port: u16 = blk: {
        var probe = try (try std.net.Address.parseIp4("127.0.0.1", 0)).listen(.{});
        defer probe.deinit();
        break :blk probe.listen_address.getPort();
    };

    // 6. Bind the IDE-facing server so the IDE can connect immediately after
    //    we print the "listening" message (connections queue in the kernel).
    var ide_server = try (try std.net.Address.parseIp4("127.0.0.1", ide_port)).listen(.{ .reuse_address = true });
    defer ide_server.deinit();
    std.debug.print("zebra debug: listening for IDE on 127.0.0.1:{d}...\n", .{ide_port});

    // 7. Spawn lldb-dap in listen mode.
    const conn_str = try std.fmt.allocPrint(alloc, "listen://127.0.0.1:{d}", .{internal_port});
    defer alloc.free(conn_str);
    const lldb_argv = [_][]const u8{ lldb_path, "--connection", conn_str };
    var lldb_child = std.process.Child.init(&lldb_argv, alloc);
    lldb_child.stdin_behavior  = .Ignore;
    lldb_child.stdout_behavior = .Ignore;
    lldb_child.stderr_behavior = .Inherit;
    lldb_child.env_map = &env_map;
    try lldb_child.spawn();

    // 8. Connect to lldb-dap (retry up to 3 s to allow startup time).
    const lldb_addr = try std.net.Address.parseIp4("127.0.0.1", internal_port);
    var lldb_stream: std.net.Stream = blk: {
        var retries: u32 = 30;
        while (retries > 0) : (retries -= 1) {
            const s = std.net.tcpConnectToAddress(lldb_addr) catch |err| {
                if (retries == 1) return err;
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            };
            break :blk s;
        }
        unreachable;
    };
    defer lldb_stream.close();
    std.debug.print("zebra debug: connected to lldb-dap on internal port {d}\n", .{internal_port});

    // 9. Accept the IDE connection.
    const client_conn = try ide_server.accept();
    defer client_conn.stream.close();
    std.debug.print("zebra debug: IDE connected\n", .{});

    // 10. Create stream wrappers at stable addresses (pointers held by AnyReader/AnyWriter).
    var client_wrapper: NetStreamWrapper = .{ .stream = client_conn.stream };
    var lldb_wrapper:   NetStreamWrapper = .{ .stream = lldb_stream };

    // 11. Cross-linked transports: each transport reads/writes one side.
    //     ctx_fwd: read IDE  → write lldb  (ide→lldb direction)
    //     ctx_rev: read lldb → write IDE   (lldb→ide direction)
    var client_xport = DapTransport.init(
        client_wrapper.anyReader(),
        client_wrapper.anyWriter(),
    );
    var lldb_xport = DapTransport.init(
        lldb_wrapper.anyReader(),
        lldb_wrapper.anyWriter(),
    );

    const ctx_fwd = RelayCtx{
        .reader    = &client_xport,
        .writer    = &lldb_xport,
        .smap      = &smap,
        .direction = .ide_to_lldb,
        .alloc     = alloc,
    };
    const ctx_rev = RelayCtx{
        .reader    = &lldb_xport,
        .writer    = &client_xport,
        .smap      = &smap,
        .direction = .lldb_to_ide,
        .alloc     = alloc,
    };

    // 12. Relay threads + wait.
    const t1 = try std.Thread.spawn(.{}, relayThread, .{ctx_fwd});
    const t2 = try std.Thread.spawn(.{}, relayThread, .{ctx_rev});
    t1.join();
    t2.join();

    const term = try lldb_child.wait();
    return switch (term) {
        .Exited  => |c| c,
        .Signal  => 1,
        .Stopped => 1,
        .Unknown => 1,
    };
}
