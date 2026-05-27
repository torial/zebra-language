//! Zebra REPL — interactive read-eval-print loop.
//!
//! Accumulate-and-rerun model: each committed cell is appended to a growing
//! _repl_session.zbr; the full session is re-compiled on every evaluation.
//!
//! Output isolation: a sentinel string is injected as a debug.print() call
//! into the generated .zig immediately before the new cell's code.  Only
//! output that appears AFTER the sentinel is shown to the user.

const std         = @import("std");
const Tokenizer   = @import("Tokenizer.zig");
const Parser      = @import("Parser.zig");
const AstBuilder  = @import("AstBuilder.zig");
const Binder      = @import("Binder.zig");
const Resolver    = @import("Resolver.zig");
const TypeChecker = @import("TypeChecker.zig");
const CodeGen     = @import("CodeGen.zig");

// ── Constants ─────────────────────────────────────────────────────────────────

/// Sentinel emitted to stderr just before the new cell's code runs.
const SENTINEL    = "\x01ZREPL\x01\n";
const SESSION_ZBR = "_repl_session.zbr";
const SESSION_ZIG = "_repl_session.zig";
const MAX_INPUT   = 8 * 1024;
const MAX_OUTPUT  = 16 * 1024 * 1024;

// ── Session state ─────────────────────────────────────────────────────────────

const Session = struct {
    /// Top-level declarations committed so far (class, def, struct, …).
    decls:   std.ArrayListUnmanaged([]u8),
    /// Body statements committed so far (go inside def main()).
    stmts:   std.ArrayListUnmanaged([]u8),
    /// History of all raw inputs (for :history).
    history: std.ArrayListUnmanaged([]u8),
    alloc:   std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) Session {
        return .{ .decls = .empty, .stmts = .empty, .history = .empty, .alloc = alloc };
    }

    fn deinit(self: *Session) void {
        for (self.decls.items)   |d| self.alloc.free(d);
        for (self.stmts.items)   |s| self.alloc.free(s);
        for (self.history.items) |h| self.alloc.free(h);
        self.decls.deinit(self.alloc);
        self.stmts.deinit(self.alloc);
        self.history.deinit(self.alloc);
    }

    fn addDecl(self: *Session, cell: []const u8) !void {
        try self.decls.append(self.alloc, try self.alloc.dupe(u8, cell));
    }

    fn addStmt(self: *Session, cell: []const u8) !void {
        try self.stmts.append(self.alloc, try self.alloc.dupe(u8, cell));
    }

    fn addHistory(self: *Session, cell: []const u8) !void {
        try self.history.append(self.alloc, try self.alloc.dupe(u8, cell));
    }

    /// Build the complete session .zbr source with `new_cell` appended.
    /// Returns the 1-based line number where `new_cell` begins in the output.
    fn buildZbr(self: *Session, new_cell: []const u8, is_decl: bool, buf: *std.ArrayList(u8)) !usize {
        var line: usize = 1;

        for (self.decls.items) |d| {
            try buf.appendSlice(self.alloc, d);
            try buf.append(self.alloc, '\n');
            line += std.mem.count(u8, d, "\n") + 1;
        }

        if (is_decl) {
            if (self.decls.items.len > 0) { try buf.append(self.alloc, '\n'); line += 1; }
            const boundary = line;
            try buf.appendSlice(self.alloc, new_cell);
            try buf.append(self.alloc, '\n');
            line += std.mem.count(u8, new_cell, "\n") + 1;
            // Write existing stmts inside def main() for type-check context.
            if (self.stmts.items.len > 0) {
                try buf.append(self.alloc, '\n'); line += 1;
                try buf.appendSlice(self.alloc, "def main()\n"); line += 1;
                for (self.stmts.items) |s| {
                    try buf.appendSlice(self.alloc, "    ");
                    try buf.appendSlice(self.alloc, s);
                    try buf.append(self.alloc, '\n');
                    line += std.mem.count(u8, s, "\n") + 1;
                }
            }
            return boundary;
        }

        // Stmt cell: emit def main() with all prior stmts + new cell.
        if (self.decls.items.len > 0) { try buf.append(self.alloc, '\n'); line += 1; }
        try buf.appendSlice(self.alloc, "def main()\n"); line += 1;
        for (self.stmts.items) |s| {
            try buf.appendSlice(self.alloc, "    ");
            try buf.appendSlice(self.alloc, s);
            try buf.append(self.alloc, '\n');
            line += std.mem.count(u8, s, "\n") + 1;
        }
        const boundary = line;
        try buf.appendSlice(self.alloc, "    ");
        try buf.appendSlice(self.alloc, new_cell);
        try buf.append(self.alloc, '\n');
        return boundary;
    }
};

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn runRepl(io: std.Io, alloc: std.mem.Allocator) !void {
    std.debug.print(
        \\Zebra REPL  (:help for commands, Ctrl-D to exit)
        \\
    , .{});

    var session = Session.init(alloc);
    defer session.deinit();

    var accum = std.ArrayList(u8).empty;
    defer accum.deinit(alloc);

    const stdin_file = std.Io.File.stdin();

    while (true) {
        // Prompt
        if (accum.items.len == 0) {
            std.debug.print(">>> ", .{});
        } else {
            std.debug.print("... ", .{});
        }

        // Read a line byte-by-byte until '\n' or EOF.
        const line_raw = readLine(io, stdin_file, alloc) catch |err| {
            std.debug.print("read error: {}\n", .{err});
            return err;
        } orelse {
            std.debug.print("\n", .{});
            break;
        };
        defer alloc.free(line_raw);
        const line = std.mem.trimEnd(u8, line_raw, "\r\n");

        // Accumulate lines.
        if (accum.items.len > 0) try accum.append(alloc, '\n');
        try accum.appendSlice(alloc, line);

        const cell_raw  = accum.items;
        const cell_trim = std.mem.trim(u8, cell_raw, " \t\r\n");

        // Blank line: flush accumulated multi-line cell.
        if (cell_trim.len == 0) {
            accum.clearRetainingCapacity();
            continue;
        }
        if (line.len == 0 and std.mem.count(u8, cell_raw, "\n") > 0) {
            const cell = std.mem.trimEnd(u8, cell_raw, " \t\r\n");
            if (cell.len > 0) {
                try session.addHistory(cell);
                evalCell(&session, cell, io, alloc) catch |err| {
                    std.debug.print("internal error: {}\n", .{err});
                };
            }
            accum.clearRetainingCapacity();
            continue;
        }

        // Handle commands (only when starting a fresh cell).
        if (accum.items.len == line.len) {
            if (std.mem.eql(u8, cell_trim, ":quit") or std.mem.eql(u8, cell_trim, ":q")) break;
            if (std.mem.eql(u8, cell_trim, ":help") or std.mem.eql(u8, cell_trim, ":h")) {
                std.debug.print(
                    \\  :help  :h              show this message
                    \\  :clear                 clear session (reset all definitions and variables)
                    \\  :history               show all inputs in this session
                    \\  :load <file.zbr>       load and replay a .zbr file into the session
                    \\  :save <file.zbr>       save the session to a .zbr file
                    \\  :quit  :q  Ctrl-D      exit
                    \\
                    \\Multi-line: indent continuation lines, then press Enter twice to submit.
                    \\
                , .{});
                accum.clearRetainingCapacity();
                continue;
            }
            if (std.mem.eql(u8, cell_trim, ":clear")) {
                session.deinit();
                session = Session.init(alloc);
                std.debug.print("session cleared\n", .{});
                accum.clearRetainingCapacity();
                continue;
            }
            if (std.mem.eql(u8, cell_trim, ":history")) {
                for (session.history.items, 0..) |h, idx| {
                    std.debug.print("[{d}] {s}\n", .{ idx + 1, h });
                }
                accum.clearRetainingCapacity();
                continue;
            }
            if (std.mem.startsWith(u8, cell_trim, ":load ")) {
                const fname = std.mem.trim(u8, cell_trim[":load ".len..], " \t");
                cmdLoad(&session, fname, io, alloc) catch |err| {
                    std.debug.print("load error: {}\n", .{err});
                };
                accum.clearRetainingCapacity();
                continue;
            }
            if (std.mem.startsWith(u8, cell_trim, ":save ")) {
                const fname = std.mem.trim(u8, cell_trim[":save ".len..], " \t");
                cmdSave(&session, fname, io, alloc) catch |err| {
                    std.debug.print("save error: {}\n", .{err});
                };
                accum.clearRetainingCapacity();
                continue;
            }
        }

        // Multi-line detection: if the input so far is incomplete, keep accumulating.
        if (isIncomplete(accum.items, alloc)) continue;

        // Submit cell.
        try session.addHistory(cell_trim);
        evalCell(&session, cell_trim, io, alloc) catch |err| {
            std.debug.print("internal error: {}\n", .{err});
        };
        accum.clearRetainingCapacity();
    }
}

// ── Line reader ───────────────────────────────────────────────────────────────

/// Read one line from `file`, including the '\n'.  Returns null on EOF.
/// Caller must free the returned slice.
fn readLine(io: std.Io, file: std.Io.File, alloc: std.mem.Allocator) !?[]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    var storage: [64]u8 = undefined;
    var reader = file.readerStreaming(io, &storage);
    var byte_buf: [1]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&byte_buf) catch return error.Unexpected;
        if (n == 0) {
            if (buf.items.len == 0) return null;
            break;
        }
        try buf.append(alloc, byte_buf[0]);
        if (byte_buf[0] == '\n') break;
    }
    return try buf.toOwnedSlice(alloc);
}

// ── Multi-line detection ──────────────────────────────────────────────────────

/// True if `src` looks like an incomplete expression that needs more input.
fn isIncomplete(src: []const u8, alloc: std.mem.Allocator) bool {
    // Syntactic pre-check: a decl header (def/class/struct/interface) with no
    // indented body yet is always incomplete.
    if (hasDeclHeaderOnly(src)) return true;

    const tokens = Tokenizer.tokenize(src, alloc) catch return false;
    defer alloc.free(tokens);
    if (tokens.len == 0) return false;

    var pr = Parser.parse(tokens, alloc) catch return false;
    defer pr.deinit();

    // An error at or near the last token means the parser ran out of input.
    return switch (pr) {
        .ok  => false,
        .err => |e| e.error_pos >= tokens.len -| 2,
    };
}

/// True if `src` starts with a decl keyword but has no indented body line yet.
fn hasDeclHeaderOnly(src: []const u8) bool {
    const decl_starters = [_][]const u8{ "def ", "class ", "struct ", "interface ", "extend " };
    var starts_with_decl = false;
    for (decl_starters) |kw| {
        if (std.mem.startsWith(u8, src, kw)) { starts_with_decl = true; break; }
    }
    if (!starts_with_decl) return false;
    // Consider it complete only if there is at least one indented line after the header.
    return std.mem.indexOf(u8, src, "\n    ") == null and
           std.mem.indexOf(u8, src, "\n\t")   == null;
}

// ── Cell evaluation ───────────────────────────────────────────────────────────

fn evalCell(session: *Session, cell: []const u8, io: std.Io, alloc: std.mem.Allocator) !void {
    const is_decl = isDeclCell(cell);

    // Build the complete session .zbr with new cell appended.
    var zbr_buf = std.ArrayList(u8).empty;
    defer zbr_buf.deinit(alloc);
    const boundary = try session.buildZbr(cell, is_decl, &zbr_buf);

    // Run Zebra pipeline.  null = user error (already printed).
    const zig_src = runPipeline(zbr_buf.items, SESSION_ZBR, alloc) catch |err| {
        std.debug.print("internal pipeline error: {}\n", .{err});
        return;
    } orelse return;

    if (is_decl) {
        // Decl cells: type-check only; no execution needed.
        alloc.free(zig_src);
        try session.addDecl(cell);
        return;
    }

    // Stmt cell: inject sentinel, write .zig, run.
    defer alloc.free(zig_src);

    const zig_modified = injectSentinel(zig_src, SESSION_ZBR, boundary, alloc) catch |err| {
        std.debug.print("sentinel injection error: {}\n", .{err});
        return;
    };
    defer alloc.free(zig_modified);

    {
        const f = try std.Io.Dir.cwd().createFile(io, SESSION_ZIG, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, zig_modified);
    }

    const output = runZig(io, SESSION_ZIG, alloc) catch |err| {
        std.debug.print("zig run error: {}\n", .{err});
        return;
    };
    defer alloc.free(output);

    // Show only the output produced after the sentinel.
    if (std.mem.lastIndexOf(u8, output, SENTINEL)) |pos| {
        const after = output[pos + SENTINEL.len ..];
        if (after.len > 0) std.debug.print("{s}", .{after});
    } else if (output.len > 0) {
        // No sentinel: compile error or crash before sentinel.
        // Strip "unused local" noise — expected when declaring a variable
        // that will be used in a later REPL cell.
        const filtered = filterUnusedErrors(output, alloc) catch output;
        defer if (filtered.ptr != output.ptr) alloc.free(filtered);
        const trimmed_out = std.mem.trim(u8, filtered, " \t\r\n");
        if (trimmed_out.len > 0) std.debug.print("{s}\n", .{trimmed_out});
        // Even if there were compile errors, commit the stmt so the user can
        // reference any declared names in subsequent cells (the full session
        // will compile cleanly once those names are used).
    }

    try session.addStmt(cell);
}

// ── Sentinel injection ────────────────────────────────────────────────────────

/// Scan the generated Zig source for `// zbr:<zbr_name>:N` where N >= boundary,
/// and insert a sentinel debug.print before the first such line.
fn injectSentinel(zig_src: []const u8, zbr_name: []const u8, boundary: usize, alloc: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var injected = false;
    var it = std.mem.splitScalar(u8, zig_src, '\n');

    while (it.next()) |line| {
        if (!injected) {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "// zbr:")) {
                const payload = trimmed["// zbr:".len..];
                // payload = "filename:N"  (last colon splits file from line)
                if (std.mem.lastIndexOfScalar(u8, payload, ':')) |colon| {
                    const file  = payload[0..colon];
                    const n_str = std.mem.trim(u8, payload[colon + 1 ..], " \r\t");
                    if (std.mem.eql(u8, file, zbr_name)) {
                        if (std.fmt.parseInt(usize, n_str, 10) catch null) |n| {
                            if (n >= boundary) {
                                // Inject with same indentation as the marker line.
                                const indent_len = line.len - trimmed.len;
                                try out.appendSlice(alloc, line[0..indent_len]);
                                try out.appendSlice(alloc, "std.debug.print(\"\\x01ZREPL\\x01\\n\", .{});\n");
                                injected = true;
                            }
                        }
                    }
                }
            }
        }
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }

    return out.toOwnedSlice(alloc);
}

// ── Zebra pipeline ────────────────────────────────────────────────────────────

/// Run the full Zebra pipeline on `src`.  Returns the generated Zig source
/// (caller must free), null on user-visible error (already printed), or
/// propagates an internal Zig error.
fn runPipeline(src: []const u8, path: []const u8, alloc: std.mem.Allocator) !?[]u8 {
    // Tokenize
    const tokens = Tokenizer.tokenize(src, alloc) catch |err| {
        std.debug.print("tokenize error: {}\n", .{err});
        return null;
    };
    defer alloc.free(tokens);

    // Parse (recovery mode — show all syntax errors in a cell, not just the first)
    var parse_result = try Parser.parseWithRecovery(tokens, alloc);
    defer parse_result.deinit();
    for (parse_result.errors) |e| {
        const ep  = if (e.error_pos < tokens.len) e.error_pos else @as(u32, @intCast(tokens.len - 1));
        const bad = tokens[ep];
        std.debug.print("{s}:{}:{}: syntax error near '{s}'\n", .{
            path, bad.line, bad.col, bad.text,
        });
    }
    if (parse_result.hasErrors()) return null;
    const ok = &parse_result.trees[0];

    // Build AST
    var sym_arena = std.heap.ArenaAllocator.init(alloc);
    defer sym_arena.deinit();
    var module = try AstBuilder.build(ok, sym_arena.allocator());
    module.file = path;

    // Semantic passes (the session file has no cross-module imports)
    var empty_imports = std.StringHashMap(TypeChecker.ModuleInterface).init(alloc);
    defer empty_imports.deinit();

    var bind = try Binder.bindPass1(module, sym_arena.allocator(), alloc);
    defer bind.deinit();

    var resolve = try Resolver.resolvePass2(module, &bind.table, alloc, alloc, &empty_imports);
    defer resolve.deinit();

    var tc = try TypeChecker.typeCheckPass3(module, &resolve, alloc, alloc, &empty_imports);
    defer tc.deinit();

    var had_error = false;
    for (bind.diags)    |d| { printDiag(path, d); if (d.kind == .err) had_error = true; }
    for (resolve.diags) |d| { printDiag(path, d); if (d.kind == .err) had_error = true; }
    for (tc.diags)      |d| { printDiag(path, d); if (d.kind == .err) had_error = true; }
    if (had_error) return null;

    // CodeGen
    var native_uses = std.StringHashMap(CodeGen.NativeUse).init(alloc);
    defer native_uses.deinit();

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    var aw = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    _ = try CodeGen.generate(
        module, &resolve, &tc, alloc, &aw.writer,
        .stub, &native_uses, false, &empty_imports, false, false, false, false, null,
    );
    buf = aw.toArrayList();
    return try buf.toOwnedSlice(alloc);
}

fn printDiag(path: []const u8, d: Binder.Diagnostic) void {
    const label: []const u8 = if (d.kind == .err) "error" else "warning";
    std.debug.print("{s}:{}:{}: {s}: {s}\n", .{
        path, d.span.line, d.span.col, label, d.message,
    });
}

// ── Zig runner ────────────────────────────────────────────────────────────────

/// Spawn `zig run <zig_file> -lc`, capture stderr (where Zebra print writes).
/// Returns the captured output; caller must free.
fn runZig(io: std.Io, zig_file: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const argv = [_][]const u8{ "zig", "run", zig_file, "-lc" };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin  = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    var read_buf: [4096]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &read_buf);
    const captured = try reader.interface.allocRemaining(alloc, .limited(MAX_OUTPUT));
    _ = try child.wait(io);
    return captured;
}

// ── Output filtering ─────────────────────────────────────────────────────────

/// Strip "unused local constant/variable" Zig diagnostics from REPL output.
/// These are expected when a REPL cell declares a variable that hasn't been
/// used yet — later cells will reference it.
fn filterUnusedErrors(output: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, output, '\n');
    var skip_context = false;
    while (it.next()) |line| {
        const is_unused = std.mem.indexOf(u8, line, "error: unused local") != null or
                          std.mem.indexOf(u8, line, "error: unused variable") != null;
        if (is_unused) { skip_context = true; continue; }
        if (skip_context) {
            // Context lines following a suppressed diagnostic are indented.
            if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) continue;
            skip_context = false;
        }
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// True if `cell` starts a top-level declaration (not a statement).
fn isDeclCell(cell: []const u8) bool {
    const kws = [_][]const u8{
        "class ", "def ", "struct ", "interface ", "extend ", "namespace ",
        "static def ", "static var ", "use ",
    };
    for (kws) |kw| if (std.mem.startsWith(u8, cell, kw)) return true;
    return false;
}

// ── Commands ──────────────────────────────────────────────────────────────────

/// :load <file.zbr> — replay each non-empty non-comment line of the file.
fn cmdLoad(session: *Session, path: []const u8, io: std.Io, alloc: std.mem.Allocator) !void {
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch |err| {
        std.debug.print("cannot read '{s}': {}\n", .{ path, err });
        return;
    };
    defer alloc.free(src);

    var it = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r\n ");
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;
        n += 1;
        std.debug.print(">>> {s}\n", .{line});
        try session.addHistory(line);
        evalCell(session, line, io, alloc) catch |err| {
            std.debug.print("internal error: {}\n", .{err});
        };
    }
    std.debug.print("loaded {d} cell(s) from '{s}'\n", .{ n, path });
}

/// :save <file.zbr> — write committed decls + stmts to a file.
fn cmdSave(session: *Session, path: []const u8, io: std.Io, alloc: std.mem.Allocator) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    for (session.decls.items) |d| {
        try buf.appendSlice(alloc, d);
        try buf.append(alloc, '\n');
    }
    if (session.decls.items.len > 0 and session.stmts.items.len > 0) {
        try buf.append(alloc, '\n');
    }
    if (session.stmts.items.len > 0) {
        try buf.appendSlice(alloc, "def main()\n");
        for (session.stmts.items) |s| {
            try buf.appendSlice(alloc, "    ");
            try buf.appendSlice(alloc, s);
            try buf.append(alloc, '\n');
        }
    }

    const f = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        std.debug.print("cannot create '{s}': {}\n", .{ path, err });
        return;
    };
    defer f.close(io);
    try f.writeStreamingAll(io, buf.items);
    std.debug.print("saved {d} decl(s) + {d} stmt(s) to '{s}'\n", .{
        session.decls.items.len, session.stmts.items.len, path,
    });
}
