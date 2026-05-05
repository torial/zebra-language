//! CodeGen: emit Zig source from a Zebra AST.
//!
//! Pass 4 of the compiler: consumes the AST and Resolver's name-resolution
//! tables, and emits a Zig source file to `writer`.
//!
//! ## Mapping rules
//!
//! | Zebra              | Zig                                              |
//! |--------------------|--------------------------------------------------|
//! | `class Foo`        | `pub const Foo = struct { ... };`                |
//! | `interface IFoo`   | `pub const IFoo = struct { ptr, vtable, check }` |
//! | `mixin M`          | inlined at `adds M` sites; no standalone output  |
//! | `struct Foo`       | `pub const Foo = struct { ... };`                |
//! | `enum Color`       | `pub const Color = enum { ... };`                |
//! | `namespace Ns`     | `pub const Ns = struct { ... };`                 |
//! | `int`              | `i64`                                            |
//! | `float`            | `f64`                                            |
//! | `bool`             | `bool`                                           |
//! | `char`             | `u21`                                            |
//! | `String`           | `[]const u8`                                     |
//! | `T?`               | `?T`                                             |
//! | `!T`               | `anyerror!T`                                     |
//! | `zig"..."`, `zig'...'` | inner content (inline Zig literal)           |
//!
//! ## Self-prefix injection
//!
//! Inside method bodies, `ExprIdent` nodes that resolve to `.var_` (field)
//! symbols are emitted as `self.name`.  All other identifiers are emitted as
//! `name`.  This uses the `exprs` map from the Resolver.
//!
//! ## Mixins
//!
//! Mixin members are inlined directly into every class that names them in an
//! `adds` clause.  Mixins are not emitted as standalone types.
//!
//! ## Interfaces
//!
//! Interfaces emit a fat-pointer vtable struct:
//! ```zig
//! pub const IFoo = struct {
//!     ptr: *anyopaque, vtable: *const VTable,
//!     pub const VTable = struct { method: *const fn (*anyopaque, ...) ret };
//!     pub fn method(self: @This(), ...) ret { return self.vtable.method(self.ptr, ...); }
//!     pub fn check(comptime T: type) void { comptime { if (!@hasDecl(T, "method")) @compileError(...); } }
//! };
//! ```
//! Every class that `implements IFoo` gets a `comptime { IFoo.check(@This()); }` block.
//!
//! ## Inheritance
//!
//! Zebra inheritance is intentionally **not** mapped to Zig.  Classes that
//! extend other classes require manual rewrite to use composition.

const std         = @import("std");
const Ast         = @import("Ast.zig");
const Resolver    = @import("Resolver.zig");
const ST          = @import("SymbolTable.zig");
const TypeChecker = @import("TypeChecker.zig");
const Builtins    = @import("Builtins.zig");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;

// ── Compile-time hash (FNV-1a 32-bit) ────────────────────────────────────────
// Used internally by CodeGen to compute class-name hash components for
// `_ttag_ClassName` constants.  The algorithm must stay bitwise-identical to
// the `_zbr_hash` function emitted into the preamble so that generic type-arg
// hashes agree (Phase 3: `is Stack(int)` checks).
//
// Type-tag layout (u64):
//   bits [31: 0] = FNV-1a 32-bit hash of the class name
//   bits [63:32] = combined FNV-1a 32-bit hash of type args (0 for non-generics)
//
// This means:
//   - `expr is Dog`        → expr._type_tag == _ttag_Dog     (upper bits 0)
//   - `expr is Stack`      → (expr._type_tag & 0xFFFFFFFF) == _ttag_Stack
//   - `expr is Stack(int)` → expr._type_tag == <combined u64 literal>

fn zbr_hash_str(s: []const u8) u32 {
    var h: u32 = 2166136261;
    for (s) |c| {
        h ^= @as(u32, c);
        h = h *% 16777619;
    }
    return h;
}

// ── Public entry point ────────────────────────────────────────────────────────

/// Which GUI backend to embed in the generated Zig preamble.
pub const GuiBackend = enum { stub, glfw, sdl2, dx12 };

/// How a native (non-Zebra) `use` dependency is backed.
/// Used by `genUse` to emit the correct import statement.
pub const NativeUse = enum {
    /// A plain `.zig` file — emit `const Alias = @import("path.zig");`
    zig,
    /// A `.c` file with a matching `.h` header — emit `@cImport(@cInclude(...))`.
    c_with_header,
    /// A `.c` file with no header — compiled as a translation unit only;
    /// emit a comment and let the user declare symbols via `zig"extern fn..."`.
    c_no_header,
};

/// Result returned by `generate()`.  Currently carries only `uses_gui`; more
/// fields may be added without breaking callers that ignore or destructure.
pub const GenerateResult = struct {
    /// True when the generated code references any GUI API (`Gui.run`, widget
    /// calls, etc.).  Callers may use this to decide whether to wire up an
    /// external GUI dependency (e.g. zgui + zglfw for the glfw backend).
    uses_gui: bool,
    /// True when at least one `export fn` wrapper was emitted (lib mode only).
    /// Callers may use this to decide whether to write a `.h` header file.
    has_exports: bool,
};

/// Emit Zig source for `module` to `writer`.
///
/// - `resolve`      — Pass-2 name-resolution tables (needed for `self.` injection).
/// - `tc`           — Pass-3 type information.  Pass `null` to skip typed format
///                    specifiers (all `print` args fall back to `{any}`).
/// - `alloc`        — Used for the mixin index and per-method mutation analysis.
/// - `writer`       — Destination for the generated Zig source.
/// - `gui_backend`  — Which GUI backend preamble to embed (default: `.stub`).
/// - `native_uses`  — Map from dotted `use` path → `NativeUse` kind for deps that
///                    are native `.zig` or `.c` files (not compiled from Zebra).
///                    Pass `null` when all deps are Zebra-compiled.
pub fn generate(
    module:           Ast.Module,
    resolve:          *const Resolver.ResolveResult,
    tc:               ?*const TypeChecker.TypeCheckResult,
    alloc:            Allocator,
    writer:           std.io.AnyWriter,
    gui_backend:      GuiBackend,
    native_uses:      ?*const std.StringHashMap(NativeUse),
    emit_exports:     bool,
    imported_modules: ?*const std.StringHashMap(TypeChecker.ModuleInterface),
    strip_contracts:  bool,
) anyerror!GenerateResult {
    var mixins = try collectMixins(module, alloc);
    defer mixins.deinit();
    var union_names = try collectUnionNames(module, alloc);
    defer union_names.deinit();
    var union_decls = try collectUnionDecls(module, alloc);
    defer union_decls.deinit();
    var exposed_unions = std.StringHashMap([]const u8).init(alloc); // maps exposed name → module alias
    defer exposed_unions.deinit();
    var exposed_classes = std.StringHashMap(void).init(alloc);
    defer exposed_classes.deinit();
    var class_names = std.StringHashMap(void).init(alloc);
    defer class_names.deinit();
    // Pre-populate class_names from local class declarations so genType can emit
    // `*ClassName` before genClass is called (e.g. for forward-reference fields).
    for (module.decls) |decl| if (decl == .class) try class_names.put(decl.class.name, {});

    var uses_gui    = false;
    var has_exports = false;
    var box_counter: u32 = 0;
    const g = Generator{
        .resolve     = resolve,
        .tc          = tc,
        .w           = writer,
        .indent      = 0,
        .owner       = "",
        .in_method   = false,
        .mixins      = &mixins,
        .alloc       = alloc,
        .mutated          = null,
        .closure_vars     = null,
        .capture_fields   = &.{},
        .union_names      = &union_names,
        .union_decls      = &union_decls,
        .exposed_unions   = &exposed_unions,
        .exposed_classes  = &exposed_classes,
        .class_names      = &class_names,
        .gui_backend      = gui_backend,
        .uses_gui_ptr     = &uses_gui,
        .native_uses      = native_uses,
        .emit_exports     = emit_exports,
        .has_exports_ptr  = &has_exports,
        .source_file      = module.file,
        .imported_modules = imported_modules,
        .box_counter_ptr  = &box_counter,
        .strip_contracts  = strip_contracts,
    };
    try g.genModule(module);
    return GenerateResult{ .uses_gui = uses_gui, .has_exports = has_exports };
}

// ── Mixin pre-pass ────────────────────────────────────────────────────────────

fn collectMixins(
    module: Ast.Module,
    alloc:  Allocator,
) !std.StringHashMap(*const Ast.DeclMixin) {
    var map = std.StringHashMap(*const Ast.DeclMixin).init(alloc);
    errdefer map.deinit();
    for (module.decls) |decl| {
        switch (decl) {
            .mixin => |m| try map.put(m.name, m),
            else   => {},
        }
    }
    return map;
}

// ── Union pre-pass ────────────────────────────────────────────────────────────

fn collectUnionNames(module: Ast.Module, alloc: Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(alloc);
    errdefer set.deinit();
    collectUnionNamesInDecls(module.decls, &set) catch {};
    return set;
}

fn collectUnionNamesInDecls(decls: []const Ast.Decl, set: *std.StringHashMap(void)) !void {
    for (decls) |decl| switch (decl) {
        .union_    => |u| try set.put(u.name, {}),
        .namespace => |n| try collectUnionNamesInDecls(n.decls, set),
        .class     => |c| try collectUnionNamesInDecls(c.members, set),
        else       => {},
    };
}

/// Collect a map from union-type name → DeclUnion pointer for same-module
/// union variant construction.  Used by CodeGen to detect `^T` payloads and
/// emit the labeled-block boxing expression instead of a bare value.
fn collectUnionDecls(module: Ast.Module, alloc: Allocator) !std.StringHashMap(*const Ast.DeclUnion) {
    var map = std.StringHashMap(*const Ast.DeclUnion).init(alloc);
    errdefer map.deinit();
    collectUnionDeclsInDecls(module.decls, &map) catch {};
    return map;
}

fn collectUnionDeclsInDecls(decls: []const Ast.Decl, map: *std.StringHashMap(*const Ast.DeclUnion)) !void {
    for (decls) |*decl| switch (decl.*) {
        .union_    => try map.put(decl.union_.name, decl.union_),
        .namespace => |n|  try collectUnionDeclsInDecls(n.decls, map),
        .class     => |c|  try collectUnionDeclsInDecls(c.members, map),
        else       => {},
    };
}

// ── Free helper functions ─────────────────────────────────────────────────────

/// Extract the simple name from a TypeRef, or null for compound forms.
/// Convert a TypeRef to a human-readable string for reflection metadata.
/// Caller owns the returned slice (allocated with `alloc`).
fn typeRefStr(tr: Ast.TypeRef, alloc: Allocator) ![]const u8 {
    return switch (tr) {
        .named       => |n| try alloc.dupe(u8, n.name),
        .nilable     => |inner| blk: {
            const s = try typeRefStr(inner.*, alloc);
            defer alloc.free(s);
            break :blk try std.fmt.allocPrint(alloc, "?{s}", .{s});
        },
        .stream      => |inner| blk: {
            const s = try typeRefStr(inner.*, alloc);
            defer alloc.free(s);
            break :blk try std.fmt.allocPrint(alloc, "{s}*", .{s});
        },
        .error_union => |inner| blk: {
            const s = try typeRefStr(inner.*, alloc);
            defer alloc.free(s);
            break :blk try std.fmt.allocPrint(alloc, "!{s}", .{s});
        },
        .ref_to      => |inner| blk: {
            const s = try typeRefStr(inner.*, alloc);
            defer alloc.free(s);
            break :blk try std.fmt.allocPrint(alloc, "^{s}", .{s});
        },
        .generic     => |g| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .{};
            try buf.appendSlice(alloc, g.name);
            try buf.append(alloc, '(');
            for (g.args, 0..) |arg, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                const s = try typeRefStr(arg, alloc);
                defer alloc.free(s);
                try buf.appendSlice(alloc, s);
            }
            try buf.append(alloc, ')');
            break :blk try buf.toOwnedSlice(alloc);
        },
        .void_       => try alloc.dupe(u8, "void"),
        .same        => try alloc.dupe(u8, "same"),
        .tuple       => try alloc.dupe(u8, "tuple"),
    };
}

fn typeRefSimpleName(tr: Ast.TypeRef) ?[]const u8 {
    return switch (tr) {
        .named   => |n| n.name,
        .generic => |g| g.name,
        else     => null,
    };
}

/// Map a Zebra primitive / built-in type name to the Zig equivalent.
/// User-defined type names are returned unchanged.
// Delegate to Builtins — single source of truth for type name mappings.
const zigTypeName     = Builtins.zigTypeName;
const isStringTypeName = Builtins.isStringTypeName;
const zigGenericName  = Builtins.zigGenericName;

fn isStringTypeRef(tr: Ast.TypeRef) bool {
    return tr == .named and isStringTypeName(tr.named.name);
}

fn assignOpStr(op: Ast.AssignOp) []const u8 {
    return switch (op) {
        .assign          => "=",
        .plus_eq         => "+=",
        .minus_eq        => "-=",
        .star_eq         => "*=",
        .slash_eq        => "/=",
        .percent_eq      => "%=",
        .ampersand_eq    => "&=",
        .vertical_bar_eq => "|=",
        .caret_eq        => "^=",
        .double_lt_eq    => "<<=",
        .double_gt_eq    => ">>=",
        // slashslash_eq, starstar_eq, question_eq are handled specially.
        .slashslash_eq, .starstar_eq, .question_eq => "=",
    };
}

fn binaryOpStr(op: Ast.BinaryOp) []const u8 {
    return switch (op) {
        .add     => "+",
        .sub     => "-",
        .mul     => "*",
        .div     => "/",
        .mod     => "%",
        .bit_and => "&",
        .bit_or  => "|",
        .bit_xor => "^",
        .shl     => "<<",
        .shr     => ">>",
        .eq      => "==",
        .ne      => "!=",
        .lt      => "<",
        .le      => "<=",
        .gt      => ">",
        .ge      => ">=",
        .and_    => "and",
        .or_     => "or",
        // int_div, pow, dotdot, in_ handled specially in genBinary.
        .int_div, .pow, .dotdot, .in_ => unreachable,
    };
}

// ── Body reference analysis ───────────────────────────────────────────────────
//
// Three pre-scans are run on each method body before emitting code:
//
//  1. collectRefs    — which params / self are actually referenced?
//                     Used to emit `_ = param;` only when a param is unused.
//
//  2. scanMutations  — which local names appear as assignment targets?
//                     Used to emit `const` vs `var` for local declarations.
//
//  3. analyzeEscapes — which local string variables escape the function (i.e.
//                     reach a `return` statement)?  Used to suppress
//                     `defer _allocator.free(name)` for strings whose ownership
//                     transfers to the caller.  List/HashMap variables do NOT
//                     get individual deinit calls (arena owns all memory), so
//                     this analysis is string-only.  Uses fixed-point propagation
//                     through the alias/depends-on graph.

const Refs = struct {
    /// True if any `ExprIdent` in the body resolves to a `.var_` (field) symbol,
    /// meaning `self` is actually needed.
    uses_self:    bool,
    /// Names of parameters that are actually referenced in the body.
    param_names: std.StringHashMap(void),

    fn deinit(r: *Refs) void { r.param_names.deinit(); }
};

fn collectRefs(
    stmts:   []const Ast.Stmt,
    resolve: *const Resolver.ResolveResult,
    alloc:   Allocator,
) !Refs {
    var out = Refs{ .uses_self = false, .param_names = std.StringHashMap(void).init(alloc) };
    errdefer out.param_names.deinit();
    try refsInStmts(stmts, resolve, &out);
    return out;
}

fn refsInStmts(stmts: []const Ast.Stmt, r: *const Resolver.ResolveResult, o: *Refs) anyerror!void {
    for (stmts) |s| try refsInStmt(s, r, o);
}

fn refsInStmt(stmt: Ast.Stmt, r: *const Resolver.ResolveResult, o: *Refs) anyerror!void {
    switch (stmt) {
        .var_      => |n| { if (n.init) |e| try refsInExpr(e, r, o); },
        .assign    => |s| { try refsInExpr(s.target, r, o); try refsInExpr(s.value, r, o); },
        .return_   => |s| { if (s.value) |v| try refsInExpr(v, r, o); },
        .if_       => |s| {
            try refsInExpr(s.cond, r, o);
            try refsInStmts(s.then_body, r, o);
            for (s.else_ifs) |ei| { try refsInExpr(ei.cond, r, o); try refsInStmts(ei.body, r, o); }
            if (s.else_body) |eb| try refsInStmts(eb, r, o);
        },
        .while_    => |s| {
            if (s.bind) |bind| try refsInExpr(bind.init, r, o);
            try refsInExpr(s.cond, r, o);
            try refsInStmts(s.body, r, o);
            if (s.post_body) |pb| try refsInStmts(pb, r, o);
        },
        .for_in    => |s| { try refsInExpr(s.iter, r, o); if (s.where) |w| try refsInExpr(w, r, o); try refsInStmts(s.body, r, o); },
        .for_num   => |s| { try refsInExpr(s.start, r, o); try refsInExpr(s.stop, r, o); if (s.step) |st| try refsInExpr(st, r, o); try refsInStmts(s.body, r, o); },
        .branch    => |s| {
            try refsInExpr(s.expr, r, o);
            for (s.on) |on| { for (on.values) |v| try refsInExpr(v, r, o); try refsInStmts(on.body, r, o); }
            if (s.else_) |eb| try refsInStmts(eb, r, o);
        },
        .print     => |s| { for (s.args) |a|    try refsInExpr(a, r, o); },
        .assert    => |s| { try refsInExpr(s.cond, r, o); if (s.message) |m| try refsInExpr(m, r, o); },
        .yield     => |s| try refsInExpr(s.value, r, o),
        .expr      => |e| try refsInExpr(e, r, o),
        .defer_    => |s| try refsInStmt(s.body, r, o),
        .contract  => |s| { for (s.exprs) |e| try refsInExpr(e, r, o); },
        .with        => |s| { try refsInExpr(s.target, r, o); try refsInStmts(s.body, r, o); },
        .arena_scope => |s| try refsInStmts(s.body, r, o),
        .var_except    => |s| { try refsInExpr(s.base, r, o); for (s.fields) |f| try refsInExpr(f.value, r, o); },
        .assign_except => |s| { try refsInExpr(s.target, r, o); try refsInExpr(s.base, r, o); for (s.fields) |f| try refsInExpr(f.value, r, o); },
        .raise    => |s| { if (s.message) |m| try refsInExpr(m, r, o); if (s.details) |d| try refsInExpr(d, r, o); },
        .try_catch => |s| { try refsInStmts(s.body, r, o); for (s.clauses) |cl| try refsInStmts(cl.body, r, o); },
        .guard => |s| { try refsInExpr(s.cond, r, o); try refsInStmts(s.else_body, r, o); },
        .destruct => |s| try refsInExpr(s.init, r, o),
        .pass, .break_, .continue_ => {},
    }
}

/// Returns true if the method body contains a `raise` statement or a bare
/// `try expr` (i.e., one not wrapped in a `try/catch` block).  Used to
/// auto-emit `anyerror!` for methods that lack a `throws` annotation.
/// Best-effort type name for `raise` details expression.
/// Used to generate the per-type heap-alloc and shim.
/// Falls back to "anyopaque" if the expression is too complex to name.
fn detailsTypeName(expr: *const Ast.Expr) []const u8 {
    return switch (expr.*) {
        .ident  => |e| e.name,
        .call   => |e| switch (e.callee.*) {
            .ident  => |i| i.name,
            .member => |m| switch (m.object.*) {
                .ident => |i| i.name,   // ClassName.init(...) → "ClassName"
                else   => "anyopaque",
            },
            else    => "anyopaque",
        },
        else    => "anyopaque",
    };
}

fn bodyHasRaise(stmts: []const Ast.Stmt, tc_opt: ?*const TypeChecker.TypeCheckResult) bool {
    for (stmts) |stmt| {
        switch (stmt) {
            .raise   => return true,
            .var_    => |n| { if (n.init) |e| if (exprHasTry(e, tc_opt)) return true; },
            .assign  => |s| { if (exprHasTry(s.value, tc_opt)) return true; },
            .return_ => |s| { if (s.value) |v| if (exprHasTry(v, tc_opt)) return true; },
            .expr    => |e| if (exprHasTry(e, tc_opt)) return true,
            .print   => |s| { for (s.args) |a| if (exprHasTry(a, tc_opt)) return true; },
            .if_     => |s| {
                if (exprHasTry(s.cond, tc_opt)) return true;
                if (bodyHasRaise(s.then_body, tc_opt)) return true;
                for (s.else_ifs) |ei| {
                    if (exprHasTry(ei.cond, tc_opt)) return true;
                    if (bodyHasRaise(ei.body, tc_opt)) return true;
                }
                if (s.else_body) |eb| if (bodyHasRaise(eb, tc_opt)) return true;
            },
            .while_  => |s| {
                if (s.bind) |bind| if (exprHasTry(bind.init, tc_opt)) return true;
                if (exprHasTry(s.cond, tc_opt)) return true;
                if (bodyHasRaise(s.body, tc_opt)) return true;
            },
            .for_in  => |s| if (bodyHasRaise(s.body, tc_opt)) return true,
            .for_num => |s| if (bodyHasRaise(s.body, tc_opt)) return true,
            .branch  => |s| {
                for (s.on) |on| if (bodyHasRaise(on.body, tc_opt)) return true;
                if (s.else_) |eb| if (bodyHasRaise(eb, tc_opt)) return true;
            },
            .with        => |s| if (bodyHasRaise(s.body, tc_opt)) return true,
            .arena_scope => |s| if (bodyHasRaise(s.body, tc_opt)) return true,
            .defer_  => |s| return bodyHasRaise(&.{s.body}, tc_opt),
            .guard   => |s| { if (exprHasTry(s.cond, tc_opt)) return true; if (bodyHasRaise(s.else_body, tc_opt)) return true; },
            .try_catch => {}, // try/catch absorbs raises — don't propagate
            .destruct => {},
            else => {},
        }
    }
    return false;
}

/// Returns true if the try block needs a mutable `_try_err` variable — i.e., when
/// the body contains either a `raise` statement or a `try expr` expression (both of
/// which route errors through the tracking variable).
/// Does not recurse into nested try/catch — inner blocks have their own variables.
fn bodyNeedsErrVar(stmts: []const Ast.Stmt, tc_opt: ?*const TypeChecker.TypeCheckResult) bool {
    for (stmts) |stmt| {
        switch (stmt) {
            .raise   => return true,
            .var_    => |n| { if (n.init) |e| if (exprHasTry(e, tc_opt)) return true; },
            .assign  => |s| { if (exprHasTry(s.value, tc_opt)) return true; },
            .return_ => |s| { if (s.value) |v| if (exprHasTry(v, tc_opt)) return true; },
            .expr    => |e| if (exprHasTry(e, tc_opt)) return true,
            .print   => |s| { for (s.args) |a| if (exprHasTry(a, tc_opt)) return true; },
            .if_     => |s| {
                if (exprHasTry(s.cond, tc_opt)) return true;
                if (bodyNeedsErrVar(s.then_body, tc_opt)) return true;
                for (s.else_ifs) |ei| {
                    if (exprHasTry(ei.cond, tc_opt)) return true;
                    if (bodyNeedsErrVar(ei.body, tc_opt)) return true;
                }
                if (s.else_body) |eb| if (bodyNeedsErrVar(eb, tc_opt)) return true;
            },
            .while_  => |s| {
                if (s.bind) |bind| if (exprHasTry(bind.init, tc_opt)) return true;
                if (exprHasTry(s.cond, tc_opt)) return true;
                if (bodyNeedsErrVar(s.body, tc_opt)) return true;
            },
            .for_in  => |s| if (bodyNeedsErrVar(s.body, tc_opt)) return true,
            .for_num => |s| if (bodyNeedsErrVar(s.body, tc_opt)) return true,
            .branch  => |s| {
                for (s.on) |on| if (bodyNeedsErrVar(on.body, tc_opt)) return true;
                if (s.else_) |eb| if (bodyNeedsErrVar(eb, tc_opt)) return true;
            },
            .with        => |s| if (bodyNeedsErrVar(s.body, tc_opt)) return true,
            .arena_scope => |s| if (bodyNeedsErrVar(s.body, tc_opt)) return true,
            .defer_  => |s| return bodyNeedsErrVar(&.{s.body}, tc_opt),
            .guard   => |s| { if (exprHasTry(s.cond, tc_opt)) return true; if (bodyNeedsErrVar(s.else_body, tc_opt)) return true; },
            .try_catch => {}, // inner try has its own err variable
            .destruct => {},
            else => {},
        }
    }
    return false;
}

/// Returns true if `e` is a call to a `throws`-annotated method
/// (ClassName.methodName(args) form only, including cross-module Module.method calls).
fn exprCallIsThrows(
    e:                *const Ast.ExprCall,
    resolve:          *const Resolver.ResolveResult,
    imported_modules: ?*const std.StringHashMap(TypeChecker.ModuleInterface),
    owner_members:    []const Ast.Decl,
    tc:               ?*const TypeChecker.TypeCheckResult,
) bool {
    // Bare function call (callee is a plain ident, not a member expression).
    // e.g. `someFunc()` where `someFunc` is a top-level or same-class function.
    if (e.callee.* == .ident) {
        const sym = resolve.exprs.get(&e.callee.ident) orelse return false;
        if (sym.decl == .method) return sym.decl.method.throws;
        return false;
    }
    if (e.callee.* != .member) return false;
    const mem = e.callee.member;
    // `.method()` syntax: callee is `this.method_name` — walk owner members.
    if (mem.object.* == .this) {
        for (owner_members) |decl| {
            if (decl == .method) {
                const m = decl.method;
                if (std.mem.eql(u8, m.name, mem.member)) return m.throws;
            }
        }
        return false;
    }
    // Call-expression receiver: `f().method()` — look up the TC type of the receiver call
    // to determine which class owns `method`, then check if that method throws.
    if (mem.object.* == .call) {
        const tc_res = tc orelse return false;
        const t = tc_res.expr_types.get(mem.object) orelse return false;
        switch (t) {
            .named => |sym| {
                const members: []const Ast.Decl = switch (sym.decl) {
                    .class   => |c| c.members,
                    .struct_ => |s| s.members,
                    else     => return false,
                };
                for (members) |m| {
                    switch (m) {
                        .method => |md| if (std.mem.eql(u8, md.name, mem.member)) return md.throws,
                        else    => {},
                    }
                }
                return false;
            },
            .cross_module => |cm| {
                if (imported_modules) |imp| {
                    if (imp.get(cm.module)) |iface| {
                        if (iface.throws_methods.contains(mem.member)) return true;
                        var buf: [512]u8 = undefined;
                        const k1 = std.fmt.bufPrint(&buf, "{s}.{s}", .{ cm.type_name, mem.member }) catch return false;
                        if (iface.throws_methods.contains(k1)) return true;
                    }
                }
                return false;
            },
            else => return false,
        }
    }
    if (mem.object.* != .ident) return false;
    const sym = resolve.exprs.get(&mem.object.ident) orelse return false;
    // Cross-module call: receiver is a `.module` symbol (from `use ModuleName`).
    if (sym.kind == .module) {
        if (imported_modules) |imp| {
            if (imp.get(sym.name)) |iface| {
                // Key format: "ClassName.methodName" — for a sole-class module the
                // class name equals the module alias.
                // Try both "Alias.method" and "Alias.Alias.method" forms.
                if (iface.throws_methods.contains(mem.member)) return true;
                const key_buf: [256]u8 = undefined;
                _ = key_buf;
                // Build "ModAlias.method" key.
                var buf: [512]u8 = undefined;
                const k1 = std.fmt.bufPrint(&buf, "{s}.{s}", .{ sym.name, mem.member }) catch return false;
                if (iface.throws_methods.contains(k1)) return true;
            }
        }
        return false;
    }
    // Same-file class/struct call.
    const members: []const Ast.Decl = switch (sym.decl) {
        .class   => |c| c.members,
        .struct_ => |s| s.members,
        else     => return false,
    };
    for (members) |m| {
        switch (m) {
            .method => |md| if (std.mem.eql(u8, md.name, mem.member)) return md.throws,
            else    => {},
        }
    }
    return false;
}

/// Returns true if any statement in `stmts` is a direct call to a `throws` method.
fn bodyHasThrowsCall(
    stmts:            []const Ast.Stmt,
    resolve:          *const Resolver.ResolveResult,
    imported_modules: ?*const std.StringHashMap(TypeChecker.ModuleInterface),
    owner_members:    []const Ast.Decl,
    tc:               ?*const TypeChecker.TypeCheckResult,
) bool {
    for (stmts) |stmt| {
        if (stmt == .expr and stmt.expr.* == .call) {
            if (exprCallIsThrows(stmt.expr.call, resolve, imported_modules, owner_members, tc)) return true;
        }
        // Var init that's a throws call also counts (affects try-block var tracking).
        if (stmt == .var_ and stmt.var_.init != null and stmt.var_.init.?.* == .call) {
            if (exprCallIsThrows(stmt.var_.init.?.call, resolve, imported_modules, owner_members, tc)) return true;
        }
    }
    return false;
}

fn exprHasTry(expr: *const Ast.Expr, tc_opt: ?*const TypeChecker.TypeCheckResult) bool {
    return switch (expr.*) {
        .try_ => |_| blk: {
            // TC records optional-unwrap `.try_` nodes in `optional_unwraps` by
            // checking the inner ident's DECLARED type (pre nil-narrowing).
            // Only count this as a real error propagation if it's NOT an opt-unwrap.
            if (tc_opt) |tc| {
                if (tc.optional_unwraps.contains(expr)) break :blk false;
            }
            break :blk true;
        },
        .binary => |e| exprHasTry(e.left, tc_opt) or exprHasTry(e.right, tc_opt),
        .unary  => |e| exprHasTry(e.operand, tc_opt),
        .call   => |e| blk: {
            if (exprHasTry(e.callee, tc_opt)) break :blk true;
            for (e.args) |a| if (exprHasTry(a.value, tc_opt)) break :blk true;
            break :blk false;
        },
        .member    => |e| exprHasTry(e.object, tc_opt),
        .orelse_   => |e| exprHasTry(e.expr, tc_opt) or exprHasTry(e.fallback, tc_opt),
        .catch_    => |e| exprHasTry(e.expr, tc_opt) or exprHasTry(e.fallback, tc_opt),
        .to_non_nil => |e| exprHasTry(e.expr, tc_opt),
        .to_nilable => |e| exprHasTry(e.expr, tc_opt),
        .is_nil    => |e| exprHasTry(e.expr, tc_opt),
        else => false,
    };
}

fn refsInExpr(expr: *const Ast.Expr, r: *const Resolver.ResolveResult, o: *Refs) anyerror!void {
    switch (expr.*) {
        .ident => |*e| {
            if (r.exprs.get(e)) |sym| switch (sym.kind) {
                .var_    => o.uses_self = true,
                // Unqualified instance method call within the same class → emitted as
                // self.method() in Zig, so self IS needed.
                // Exception: top-level `def` (LANG-001) are called without self, so
                // referencing them does NOT imply self is used.
                .method  => {
                    const is_top = switch (sym.decl) {
                        .method => |m| m.is_top_level,
                        else    => false,
                    };
                    if (!is_top) o.uses_self = true;
                },
                .param   => try o.param_names.put(e.name, {}),
                else     => {},
            };
        },
        .binary      => |e| { try refsInExpr(e.left, r, o);    try refsInExpr(e.right, r, o); },
        .unary       => |e| try refsInExpr(e.operand, r, o),
        .call        => |e| { try refsInExpr(e.callee, r, o);  for (e.args) |a| try refsInExpr(a.value, r, o); },
        .member      => |e| try refsInExpr(e.object, r, o),
        .index       => |e| { try refsInExpr(e.object, r, o);  try refsInExpr(e.index, r, o); },
        .slice       => |e| { try refsInExpr(e.object, r, o);  if (e.start) |s| try refsInExpr(s, r, o); if (e.stop) |s| try refsInExpr(s, r, o); },
        .if_expr     => |e| { try refsInExpr(e.cond, r, o);    try refsInExpr(e.then_expr, r, o); try refsInExpr(e.else_expr, r, o); },
        .orelse_     => |e| { try refsInExpr(e.expr, r, o);    try refsInExpr(e.fallback, r, o); },
        .catch_      => |e| { try refsInExpr(e.expr, r, o);    try refsInExpr(e.fallback, r, o); },
        .to_nilable  => |e| try refsInExpr(e.expr, r, o),
        .to_non_nil  => |e| try refsInExpr(e.expr, r, o),
        .is_nil      => |e| try refsInExpr(e.expr, r, o),
        .cast        => |e| try refsInExpr(e.expr, r, o),
        .old         => |e| try refsInExpr(e.expr, r, o),
        .result_     => {},
        .list_lit    => |e| { for (e.elems) |el| try refsInExpr(el, r, o); },
        .array_lit   => |e| { for (e.elems) |el| try refsInExpr(el, r, o); },
        .dict_lit    => |e| { for (e.entries) |en| { try refsInExpr(en.key, r, o); try refsInExpr(en.value, r, o); } },
        .string_interp => |e| { for (e.parts) |p| switch (p) { .expr => |ex| try refsInExpr(ex, r, o), else => {} }; },
        .lambda      => |e| switch (e.body) {
            .expr  => |ex| try refsInExpr(ex, r, o),
            .stmts => |ss| try refsInStmts(ss, r, o),
        },
        .try_        => |e| try refsInExpr(e.expr, r, o),
        .tuple_lit   => |e| { for (e.elems) |el| try refsInExpr(el, r, o); },
        .type_check  => |e| try refsInExpr(e.expr, r, o),
        .this        => o.uses_self = true,  // extension methods: `this` means self is used
        .int_lit, .float_lit, .bool_lit, .char_lit,
        .string_lit, .nil, .zig_lit => {},
    }
}

/// True if any sub-expression is `result` (the contract return-value reference).
fn containsResultRef(expr: *const Ast.Expr) bool {
    return switch (expr.*) {
        .result_       => true,
        .binary        => |e| containsResultRef(e.left) or containsResultRef(e.right),
        .unary         => |e| containsResultRef(e.operand),
        .call          => |e| blk: {
            if (containsResultRef(e.callee)) break :blk true;
            for (e.args) |a| if (containsResultRef(a.value)) break :blk true;
            break :blk false;
        },
        .member        => |e| containsResultRef(e.object),
        .index         => |e| containsResultRef(e.object) or containsResultRef(e.index),
        .slice         => |e| containsResultRef(e.object)
                              or (e.start != null and containsResultRef(e.start.?))
                              or (e.stop  != null and containsResultRef(e.stop.?)),
        .if_expr       => |e| containsResultRef(e.cond) or containsResultRef(e.then_expr) or containsResultRef(e.else_expr),
        .orelse_       => |e| containsResultRef(e.expr) or containsResultRef(e.fallback),
        .catch_        => |e| containsResultRef(e.expr) or containsResultRef(e.fallback),
        .to_nilable    => |e| containsResultRef(e.expr),
        .to_non_nil    => |e| containsResultRef(e.expr),
        .is_nil        => |e| containsResultRef(e.expr),
        .cast          => |e| containsResultRef(e.expr),
        .old           => |e| containsResultRef(e.expr),
        .try_          => |e| containsResultRef(e.expr),
        .tuple_lit     => |e| blk: { for (e.elems) |el| if (containsResultRef(el)) break :blk true; break :blk false; },
        .list_lit      => |e| blk: { for (e.elems) |el| if (containsResultRef(el)) break :blk true; break :blk false; },
        .array_lit     => |e| blk: { for (e.elems) |el| if (containsResultRef(el)) break :blk true; break :blk false; },
        .dict_lit      => |e| blk: { for (e.entries) |en| if (containsResultRef(en.key) or containsResultRef(en.value)) break :blk true; break :blk false; },
        .string_interp => |e| blk: { for (e.parts) |p| switch (p) { .expr => |ex| if (containsResultRef(ex)) break :blk true, else => {} }; break :blk false; },
        .type_check    => |e| containsResultRef(e.expr),
        .lambda        => false, // result inside a lambda body refers to the lambda's own ensure (n/a today)
        .ident, .this, .int_lit, .float_lit, .bool_lit, .char_lit,
        .string_lit, .nil, .zig_lit => false,
    };
}

/// Walk an expression depth-first and collect all `old` nodes (in traversal order).
/// Used by genEnsureBlock to emit pre-call snapshots for `ensure`/`old` contracts.
fn collectOldExprs(expr: *const Ast.Expr, alloc: Allocator, out: *std.ArrayListUnmanaged(*Ast.ExprOld)) anyerror!void {
    switch (expr.*) {
        .old         => |e| try out.append(alloc, e),
        .binary      => |e| { try collectOldExprs(e.left, alloc, out);   try collectOldExprs(e.right, alloc, out); },
        .unary       => |e| try collectOldExprs(e.operand, alloc, out),
        .call        => |e| { try collectOldExprs(e.callee, alloc, out); for (e.args) |a| try collectOldExprs(a.value, alloc, out); },
        .member      => |e| try collectOldExprs(e.object, alloc, out),
        .index       => |e| { try collectOldExprs(e.object, alloc, out); try collectOldExprs(e.index, alloc, out); },
        .slice       => |e| { try collectOldExprs(e.object, alloc, out); if (e.start) |s| try collectOldExprs(s, alloc, out); if (e.stop) |s| try collectOldExprs(s, alloc, out); },
        .if_expr     => |e| { try collectOldExprs(e.cond, alloc, out);   try collectOldExprs(e.then_expr, alloc, out); try collectOldExprs(e.else_expr, alloc, out); },
        .orelse_     => |e| { try collectOldExprs(e.expr, alloc, out);   try collectOldExprs(e.fallback, alloc, out); },
        .catch_      => |e| { try collectOldExprs(e.expr, alloc, out);   try collectOldExprs(e.fallback, alloc, out); },
        .to_nilable  => |e| try collectOldExprs(e.expr, alloc, out),
        .to_non_nil  => |e| try collectOldExprs(e.expr, alloc, out),
        .is_nil      => |e| try collectOldExprs(e.expr, alloc, out),
        .cast        => |e| try collectOldExprs(e.expr, alloc, out),
        .try_        => |e| try collectOldExprs(e.expr, alloc, out),
        .tuple_lit   => |e| { for (e.elems) |el| try collectOldExprs(el, alloc, out); },
        .list_lit    => |e| { for (e.elems) |el| try collectOldExprs(el, alloc, out); },
        .array_lit   => |e| { for (e.elems) |el| try collectOldExprs(el, alloc, out); },
        .dict_lit    => |e| { for (e.entries) |en| { try collectOldExprs(en.key, alloc, out); try collectOldExprs(en.value, alloc, out); } },
        .string_interp => |e| { for (e.parts) |p| switch (p) { .expr => |ex| try collectOldExprs(ex, alloc, out), else => {} }; },
        .type_check  => |e| try collectOldExprs(e.expr, alloc, out),
        .lambda      => {},  // old doesn't make sense inside a lambda body
        .ident, .this, .int_lit, .float_lit, .bool_lit, .char_lit,
        .string_lit, .nil, .zig_lit, .result_ => {},
    }
}

// ── Mutation analysis ─────────────────────────────────────────────────────────

/// Return a set of every identifier name that appears as the direct target of
/// an assignment (`ident = value`, as opposed to `obj.member = value`) inside
/// `stmts` or any nested control-flow body.
///
/// Used by the CodeGen to emit `const` for locals that are never reassigned,
/// avoiding Zig's "local variable is never mutated" compile error.
/// Collect the names of every local variable that is directly returned (either as
/// the sole return value or as an argument to a call in a return expression).
/// These variables must NOT receive a `defer _allocator.free` because the caller
/// takes ownership of the allocation.
// ── Escape analysis ───────────────────────────────────────────────────────────

/// Exhaustively collect all ExprIdent names reachable within `expr` into `set`.
/// Used both to seed the initial escape set from return expressions and to compute
/// the "depends-on" set for each var initialiser.
fn collectAllIdents(expr: *const Ast.Expr, set: *std.StringHashMap(void)) anyerror!void {
    switch (expr.*) {
        .ident         => |e|  try set.put(e.name, {}),
        .call          => |e|  {
            if (e.callee.* == .member)     try collectAllIdents(e.callee.member.object, set)
            else if (e.callee.* == .ident) try set.put(e.callee.ident.name, {});
            for (e.args) |a| try collectAllIdents(a.value, set);
        },
        .member        => |m|  try collectAllIdents(m.object, set),
        .binary        => |b|  { try collectAllIdents(b.left, set); try collectAllIdents(b.right, set); },
        .unary         => |u|  try collectAllIdents(u.operand, set),
        .to_nilable    => |u|  try collectAllIdents(u.expr, set),
        .to_non_nil    => |u|  try collectAllIdents(u.expr, set),
        .is_nil        => |u|  try collectAllIdents(u.expr, set),
        .orelse_       => |o|  { try collectAllIdents(o.expr, set); try collectAllIdents(o.fallback, set); },
        .catch_        => |c|  { try collectAllIdents(c.expr, set); try collectAllIdents(c.fallback, set); },
        .if_expr       => |i|  { try collectAllIdents(i.cond, set); try collectAllIdents(i.then_expr, set); try collectAllIdents(i.else_expr, set); },
        .cast          => |c|  try collectAllIdents(c.expr, set),
        .old           => |o|  try collectAllIdents(o.expr, set),
        .try_          => |t|  try collectAllIdents(t.expr, set),
        .index         => |i|  { try collectAllIdents(i.object, set); try collectAllIdents(i.index, set); },
        .slice         => |s|  { try collectAllIdents(s.object, set);
                                  if (s.start) |b| try collectAllIdents(b, set);
                                  if (s.stop)  |b| try collectAllIdents(b, set); },
        .tuple_lit     => |t|  { for (t.elems)    |e| try collectAllIdents(e, set); },
        .type_check    => |t|  try collectAllIdents(t.expr, set),
        .list_lit      => |l|  { for (l.elems)    |e| try collectAllIdents(e, set); },
        .array_lit     => |a|  { for (a.elems)    |e| try collectAllIdents(e, set); },
        .dict_lit      => |d|  { for (d.entries) |e| { try collectAllIdents(e.key, set); try collectAllIdents(e.value, set); } },
        .string_interp => |si| { for (si.parts) |p| { switch (p) { .expr => |e| try collectAllIdents(e, set), else => {} } } },
        else           => {},  // literals, nil, this, zig_lit — no idents
    }
}

/// Recursively add all ExprIdent names appearing in any `return` expression to `set`.
fn seedEscapedFromReturns(stmts: []const Ast.Stmt, set: *std.StringHashMap(void)) anyerror!void {
    for (stmts) |stmt| {
        switch (stmt) {
            .return_   => |s| if (s.value) |v| try collectAllIdents(v, set),
            .if_       => |s| {
                try seedEscapedFromReturns(s.then_body, set);
                for (s.else_ifs) |ei| try seedEscapedFromReturns(ei.body, set);
                if (s.else_body) |eb| try seedEscapedFromReturns(eb, set);
            },
            .while_    => |s| { try seedEscapedFromReturns(s.body, set); if (s.post_body) |pb| try seedEscapedFromReturns(pb, set); },
            .for_in    => |s| try seedEscapedFromReturns(s.body, set),
            .for_num   => |s| try seedEscapedFromReturns(s.body, set),
            .branch    => |s| {
                for (s.on) |on| try seedEscapedFromReturns(on.body, set);
                if (s.else_) |eb| try seedEscapedFromReturns(eb, set);
            },
            .with        => |s| try seedEscapedFromReturns(s.body, set),
            .arena_scope => |s| try seedEscapedFromReturns(s.body, set),
            .try_catch => |s| {
                try seedEscapedFromReturns(s.body, set);
                for (s.clauses) |cl| try seedEscapedFromReturns(cl.body, set);
            },
            .guard     => |s| try seedEscapedFromReturns(s.else_body, set),
            else       => {},
        }
    }
}

/// One propagation pass over var decls and field-write assigns:
///
///   • `var y = <expr>` — if `y` is escaped, add all idents in <expr> to the
///     escaped set (y's string buffer may have come from those idents).
///   • `obj.field = <expr>` — if `obj` is escaped, add all idents in <expr> to
///     the escaped set.  Without this, code like:
///       var s = str.format(x); result.msg = s; return result
///     would incorrectly emit `defer _allocator.free(s)` while `result.msg`
///     still references the freed slice.
///
/// Returns true if the set grew (caller loops until stable).
fn propagateEscapesOnce(stmts: []const Ast.Stmt, set: *std.StringHashMap(void)) anyerror!bool {
    var grew = false;
    for (stmts) |stmt| {
        switch (stmt) {
            .var_ => |n| if (n.init) |e| {
                if (set.contains(n.name)) {
                    const before = set.count();
                    try collectAllIdents(e, set);
                    if (set.count() > before) grew = true;
                }
            },
            // Field write: `escaped_obj.field = rhs` — rhs values may embed
            // into escaped_obj so they should not be freed before the caller.
            .assign => |s| if (s.target.* == .member) {
                const m = s.target.member;
                if (m.object.* == .ident and set.contains(m.object.ident.name)) {
                    const before = set.count();
                    try collectAllIdents(s.value, set);
                    if (set.count() > before) grew = true;
                }
            },
            .if_ => |s| {
                if (try propagateEscapesOnce(s.then_body, set)) grew = true;
                for (s.else_ifs) |ei| { if (try propagateEscapesOnce(ei.body, set)) grew = true; }
                if (s.else_body) |eb| { if (try propagateEscapesOnce(eb, set)) grew = true; }
            },
            .while_    => |s| {
                if (try propagateEscapesOnce(s.body, set)) grew = true;
                if (s.post_body) |pb| { if (try propagateEscapesOnce(pb, set)) grew = true; }
            },
            .for_in    => |s| { if (try propagateEscapesOnce(s.body, set)) grew = true; },
            .for_num   => |s| { if (try propagateEscapesOnce(s.body, set)) grew = true; },
            .branch    => |s| {
                for (s.on) |on| { if (try propagateEscapesOnce(on.body, set)) grew = true; }
                if (s.else_) |eb| { if (try propagateEscapesOnce(eb, set)) grew = true; }
            },
            .with        => |s| { if (try propagateEscapesOnce(s.body, set)) grew = true; },
            .arena_scope => |s| { if (try propagateEscapesOnce(s.body, set)) grew = true; },
            .try_catch => |s| {
                if (try propagateEscapesOnce(s.body, set)) grew = true;
                for (s.clauses) |cl| { if (try propagateEscapesOnce(cl.body, set)) grew = true; }
            },
            .guard     => |s| { if (try propagateEscapesOnce(s.else_body, set)) grew = true; },
            else       => {},
        }
    }
    return grew;
}

/// Compute the set of local *string* variable names whose heap-owned values
/// escape this function body.  A variable escapes if its value (or the value of
/// any variable initialised from it) reaches a `return` statement.
///
/// Purpose: suppresses `defer _allocator.free(name)` for strings whose slice
/// ownership transfers to the caller.  List/HashMap variables are NOT covered
/// here — they no longer receive individual deinit calls at all (the arena
/// allocator owns all collection memory and frees it at program exit).
///
/// Conservative: over-escaping (marking a variable escaped when it isn't)
/// causes a memory leak, never a use-after-free.  Under-escaping causes UAF.
fn analyzeEscapes(stmts: []const Ast.Stmt, alloc: Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(alloc);
    errdefer set.deinit();
    // Phase 1 — seed from all return expressions.
    try seedEscapedFromReturns(stmts, &set);
    // Phase 2 — fixed-point propagation through the depends-on graph.
    while (try propagateEscapesOnce(stmts, &set)) {}
    return set;
}

fn scanMutations(
    stmts:  []const Ast.Stmt,
    alloc:  Allocator,
    tc_opt: ?*const TypeChecker.TypeCheckResult,
) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(alloc);
    errdefer set.deinit();
    try scanMutationsInto(stmts, &set, tc_opt);
    return set;
}

fn scanMutationsInto(
    stmts:  []const Ast.Stmt,
    set:    *std.StringHashMap(void),
    tc_opt: ?*const TypeChecker.TypeCheckResult,
) !void {
    for (stmts) |stmt| {
        switch (stmt) {
            .assign  => |s| switch (s.target.*) {
                // Bare `name = value` — marks `name` as mutated.
                .ident => |e| try set.put(e.name, {}),
                // `obj.member = value` — the object needs to be `var` in Zig.
                .member => |m| if (m.object.* == .ident) try set.put(m.object.ident.name, {}),
                else   => {},
            },
            .if_     => |s| {
                try scanMutationsInto(s.then_body, set, tc_opt);
                for (s.else_ifs) |ei| try scanMutationsInto(ei.body, set, tc_opt);
                if (s.else_body) |eb| try scanMutationsInto(eb, set, tc_opt);
            },
            .while_  => |s| {
                if (s.bind) |bind| try scanMutationsInExpr(bind.init, set, tc_opt);
                try scanMutationsInto(s.body, set, tc_opt);
                if (s.post_body) |pb| try scanMutationsInto(pb, set, tc_opt);
            },
            .for_in  => |s| try scanMutationsInto(s.body, set, tc_opt),
            .for_num => |s| try scanMutationsInto(s.body, set, tc_opt),
            .branch  => |s| {
                for (s.on) |on| try scanMutationsInto(on.body, set, tc_opt);
                if (s.else_) |eb| try scanMutationsInto(eb, set, tc_opt);
            },
            // Scan expressions in remaining statement kinds for call-receivers.
            .var_    => |n| { if (n.init) |e| try scanMutationsInExpr(e, set, tc_opt); },
            .return_ => |s| { if (s.value) |v| try scanMutationsInExpr(v, set, tc_opt); },
            .expr    => |e| try scanMutationsInExpr(e, set, tc_opt),
            .print   => |s| { for (s.args) |a| try scanMutationsInExpr(a, set, tc_opt); },
            // `with target` — the target variable is mutated (fields are assigned).
            .with    => |s| {
                if (s.target.* == .ident) try set.put(s.target.ident.name, {});
                try scanMutationsInto(s.body, set, tc_opt);
            },
            .arena_scope => |s| try scanMutationsInto(s.body, set, tc_opt),
            .try_catch => |s| {
                try scanMutationsInto(s.body, set, tc_opt);
                for (s.clauses) |cl| try scanMutationsInto(cl.body, set, tc_opt);
            },
            .guard    => |s| try scanMutationsInto(s.else_body, set, tc_opt),
            .destruct => |s| try scanMutationsInExpr(s.init, set, tc_opt),
            .assert   => |s| try scanMutationsInExpr(s.cond, set, tc_opt),
            else      => {},
        }
    }
}

/// Mark local variables whose values are modified in-place as "mutated" (→ emit
/// `var` rather than `const`).
///
/// Previous approach: a large `non_mutating` *deny-list* — any method not on the
/// list was assumed mutating.  Problem: every new stdlib method defaulted to
/// "mutating" until manually added, causing spurious `var` declarations and Zig
/// "local variable is never mutated" errors.
///
/// New approach: a small `mutating_methods` *allow-list* — only methods that
/// actually modify the receiver's internal state are listed.  Default is
/// non-mutating.  For user-defined types (TC type `.named`) we conservatively
/// always mark as mutating because we cannot inspect the method body.
fn scanMutationsInExpr(
    expr:   *const Ast.Expr,
    set:    *std.StringHashMap(void),
    tc_opt: ?*const TypeChecker.TypeCheckResult,
) anyerror!void {
    switch (expr.*) {
        .call => |e| {
            if (e.callee.* == .member) {
                const obj    = e.callee.member.object;
                const method = e.callee.member.member;

                // Methods that modify the receiver's internal state in-place.
                // Everything else defaults to non-mutating.
                const mutating_methods = std.StaticStringMap(void).initComptime(&.{
                    // List — in-place mutations
                    .{ "add",            {} }, .{ "remove",        {} },
                    .{ "clear",          {} }, .{ "sort",          {} },
                    .{ "sortBy",         {} }, .{ "reverse",       {} },
                    // HashMap — in-place mutations
                    .{ "set",            {} },
                    // StringBuilder — all write methods
                    .{ "append",         {} }, .{ "appendLine",    {} },
                    .{ "appendChar",     {} }, .{ "appendInt",     {} },
                    .{ "appendFloat",    {} }, .{ "appendBool",    {} },
                    // JsonValue — mutating builders
                    .{ "put",            {} }, .{ "putInt",        {} },
                    .{ "putFloat",       {} }, .{ "putBool",       {} },
                    // CsvWriter — write
                    .{ "writeRow",       {} },
                });

                if (obj.* == .ident) {
                    // Extension methods are pass-by-value — never mutate the receiver.
                    const is_ext = blk: {
                        if (tc_opt) |tc| {
                            const obj_type = tc.expr_types.get(obj) orelse .unknown;
                            const tname: ?[]const u8 = switch (obj_type) {
                                .string         => "String",
                                .int            => "int",
                                .uint           => "uint",
                                .float          => "float",
                                .bool           => "bool",
                                .char           => "char",
                                .string_builder => "StringBuilder",
                                .named          => |sym| switch (sym.decl) {
                                    .class     => |c| c.name,
                                    .struct_   => |s| s.name,
                                    .interface => |i| i.name,
                                    else       => null,
                                },
                                else => null,
                            };
                            if (tname) |tn| {
                                var buf: [256]u8 = undefined;
                                if (std.fmt.bufPrint(&buf, "{s}.{s}", .{tn, method})) |key| {
                                    if (tc.ext_methods.get(key) != null) break :blk true;
                                } else |_| {}
                            }
                        }
                        break :blk false;
                    };

                    if (!is_ext) {
                        // Determine if this call needs the receiver to be `var`.
                        const needs_var: bool = blk: {
                            if (tc_opt) |tc| {
                                const obj_type = tc.expr_types.get(obj) orelse .unknown;
                                // User-defined structs are value types — methods take *Self
                                // so the receiver variable must be `var` (mutable address).
                                // Classes and cross-module types are reference types (pointer):
                                // a `const ptr: *ClassName` can call `*Self` methods without
                                // `var` since the pointer itself is already the `*Self`.
                                if (obj_type == .named) {
                                    const sym = obj_type.named;
                                    // Structs need var; classes do not.
                                    if (sym.kind == .struct_ or sym.kind == .interface) break :blk true;
                                    // Exposed cross-module symbols (from `use Mod exposing TypeName`)
                                    // have kind=.module and could be structs (value types needing *Self).
                                    // Conservatively require var — harmless for class pointers.
                                    if (sym.kind == .module) break :blk true;
                                    break :blk false;
                                }
                                if (obj_type == .generic_named) break :blk true; // conservative
                                // cross_module: look up the module interface to distinguish
                                // structs (need var — value type with *Self methods) from
                                // classes (don't need var — already a pointer).  Fall back
                                // to conservative (needs var) when the interface is absent.
                                if (obj_type == .cross_module) {
                                    // TODO: thread imported_modules through here for exact lookup.
                                    // For now, conservatively require var so that cross-module
                                    // struct method calls compile (extra var on classes is harmless).
                                    break :blk true;
                                }
                                // Strings are immutable values in Zebra — no method
                                // mutates a string in-place.  `reverse` is in the
                                // allow-list for List (which is in-place), but
                                // str.reverse() always returns a new allocation.
                                if (obj_type == .string) break :blk false;
                                // `.unknown` falls through to the allow-list below.
                                // Previously we treated unknown as always-mutating, which
                                // caused spurious `var` for stdlib builtins (sys.args(),
                                // str methods, etc.) whose idents aren't registered in
                                // resolve.exprs, making TC return .unknown for them.
                                // User-class instances resolve as .named, so the
                                // conservative path above still fires for them.
                            }
                            // Stdlib / unknown type: only explicitly-listed mutating methods.
                            break :blk mutating_methods.get(method) != null;
                        };
                        if (needs_var) try set.put(obj.ident.name, {});
                    }
                }
            }
            for (e.args) |a| try scanMutationsInExpr(a.value, set, tc_opt);
        },
        .binary    => |e| { try scanMutationsInExpr(e.left, set, tc_opt); try scanMutationsInExpr(e.right, set, tc_opt); },
        .unary     => |e| try scanMutationsInExpr(e.operand, set, tc_opt),
        .member    => |e| try scanMutationsInExpr(e.object, set, tc_opt),
        .index     => |e| { try scanMutationsInExpr(e.object, set, tc_opt); try scanMutationsInExpr(e.index, set, tc_opt); },
        .if_expr   => |e| { try scanMutationsInExpr(e.cond, set, tc_opt); try scanMutationsInExpr(e.then_expr, set, tc_opt); try scanMutationsInExpr(e.else_expr, set, tc_opt); },
        .orelse_   => |e| { try scanMutationsInExpr(e.expr, set, tc_opt); try scanMutationsInExpr(e.fallback, set, tc_opt); },
        .catch_    => |e| { try scanMutationsInExpr(e.expr, set, tc_opt); try scanMutationsInExpr(e.fallback, set, tc_opt); },
        .tuple_lit  => |e| { for (e.elems) |el| try scanMutationsInExpr(el, set, tc_opt); },
        .type_check => |e| try scanMutationsInExpr(e.expr, set, tc_opt),
        // `expr?` — recurse so that `localVar.method()?` marks `localVar` as mutated.
        .try_       => |e| try scanMutationsInExpr(e.expr, set, tc_opt),
        else        => {},
    }
}

// ── BUG-091: List(T)/HashMap(K,V) param mutation → addr-of param convention ─
//
// When a function-parameter of type `List(T)` or `HashMap(K,V)` is mutated
// inside the body (via `.add`/`.append`/`.put`/`.remove`/`.clear`/`.sort`),
// the caller expects the underlying container to be modified in place.
// Zig's `std.ArrayList` is value-typed (struct of items + capacity), so a
// plain pass-by-value parameter is `*const ArrayList` from the body's view —
// `.append` (which takes `*Self`) is rejected.  The fix is to emit the
// parameter as `*std.ArrayList(T)` and take `&arg` at every call site.
//
// `paramNeedsAddrOf` is the canonical predicate.  Both `genMethod` (param
// emission) and `genArgs` (call-site emission) consult it, so the two sides
// stay in lock-step.

fn isContainerType(t: Ast.TypeRef) bool {
    return switch (t) {
        .generic => |g| std.mem.eql(u8, g.name, "List") or std.mem.eql(u8, g.name, "HashMap"),
        else     => false,
    };
}

// Cost: each call runs scanMutations over `body` -- O(|body|).  Because the
// predicate is consulted at every param-emit and every arg-emit (potentially
// per-arg at one call site), worst case is O(N * M) for N calls to a method
// of body size M.  Acceptable for the current corpus (<100ms total impact in
// bootstrap).  Memoise per-method (HashMap from *Ast.DeclMethod -> StringHashMap)
// if profiling ever shows this matters.
fn paramNeedsAddrOf(
    param:  Ast.Param,
    body:   ?[]const Ast.Stmt,
    alloc:  Allocator,
    tc_opt: ?*const TypeChecker.TypeCheckResult,
) bool {
    const t = param.type_ orelse return false;
    if (!isContainerType(t)) return false;
    const b = body orelse return false;
    var mut_set = scanMutations(b, alloc, tc_opt) catch return false;
    defer mut_set.deinit();
    return mut_set.contains(param.name);
}

/// Walk `stmts` for any call whose ident-arg is passed as `&` to a mutating
/// container param, and add those ident names to `mut_set` so the caller-side
/// `var`/`const` decision treats them as mutated.  `&items` requires `items`
/// to be `var`, otherwise Zig sees `*const ArrayList` which doesn't coerce
/// to `*ArrayList`.
fn addAddrOfMutationsInStmts(
    stmts:    []const Ast.Stmt,
    set:      *std.StringHashMap(void),
    alloc:    Allocator,
    tc_opt:   ?*const TypeChecker.TypeCheckResult,
    resolve:  *const Resolver.ResolveResult,
) anyerror!void {
    for (stmts) |stmt| {
        switch (stmt) {
            .if_ => |s| {
                try addAddrOfMutationsInStmts(s.then_body, set, alloc, tc_opt, resolve);
                for (s.else_ifs) |ei| try addAddrOfMutationsInStmts(ei.body, set, alloc, tc_opt, resolve);
                if (s.else_body) |eb| try addAddrOfMutationsInStmts(eb, set, alloc, tc_opt, resolve);
            },
            .while_ => |s| try addAddrOfMutationsInStmts(s.body, set, alloc, tc_opt, resolve),
            .for_in => |s| try addAddrOfMutationsInStmts(s.body, set, alloc, tc_opt, resolve),
            .for_num => |s| try addAddrOfMutationsInStmts(s.body, set, alloc, tc_opt, resolve),
            .branch => |s| {
                for (s.on) |on| try addAddrOfMutationsInStmts(on.body, set, alloc, tc_opt, resolve);
                if (s.else_) |eb| try addAddrOfMutationsInStmts(eb, set, alloc, tc_opt, resolve);
            },
            .try_catch => |s| {
                try addAddrOfMutationsInStmts(s.body, set, alloc, tc_opt, resolve);
                for (s.clauses) |cl| try addAddrOfMutationsInStmts(cl.body, set, alloc, tc_opt, resolve);
            },
            .arena_scope => |s| try addAddrOfMutationsInStmts(s.body, set, alloc, tc_opt, resolve),
            .with => |s| try addAddrOfMutationsInStmts(s.body, set, alloc, tc_opt, resolve),
            .guard => |s| try addAddrOfMutationsInStmts(s.else_body, set, alloc, tc_opt, resolve),
            .var_  => |n| { if (n.init) |e| try addAddrOfMutationsInExpr(e, set, alloc, tc_opt, resolve); },
            .return_ => |s| { if (s.value) |v| try addAddrOfMutationsInExpr(v, set, alloc, tc_opt, resolve); },
            .expr  => |e| try addAddrOfMutationsInExpr(e, set, alloc, tc_opt, resolve),
            .assign => |s| {
                try addAddrOfMutationsInExpr(s.target, set, alloc, tc_opt, resolve);
                try addAddrOfMutationsInExpr(s.value, set, alloc, tc_opt, resolve);
            },
            .print => |s| { for (s.args) |a| try addAddrOfMutationsInExpr(a, set, alloc, tc_opt, resolve); },
            .assert => |s| try addAddrOfMutationsInExpr(s.cond, set, alloc, tc_opt, resolve),
            else   => {},
        }
    }
}

fn addAddrOfMutationsInExpr(
    expr:     *const Ast.Expr,
    set:      *std.StringHashMap(void),
    alloc:    Allocator,
    tc_opt:   ?*const TypeChecker.TypeCheckResult,
    resolve:  *const Resolver.ResolveResult,
) anyerror!void {
    if (expr.* == .call) {
        const e = expr.call;
        // Recurse first so nested calls are handled.
        try addAddrOfMutationsInExpr(e.callee, set, alloc, tc_opt, resolve);
        for (e.args) |a| try addAddrOfMutationsInExpr(a.value, set, alloc, tc_opt, resolve);

        // Resolve the callee to a method/init declaration so we can check
        // whether any container param is mutated by the body.
        const params_and_body: ?struct { params: []const Ast.Param, body: ?[]const Ast.Stmt } = blk: {
            if (e.callee.* == .ident) {
                if (resolve.exprs.get(&e.callee.ident)) |sym| switch (sym.decl) {
                    .method => |m| break :blk .{ .params = m.params, .body = m.body },
                    .class  => |c| {
                        for (c.members) |mem| if (mem == .init) break :blk .{ .params = mem.init.params, .body = mem.init.body };
                        break :blk null;
                    },
                    .struct_ => |s| {
                        for (s.members) |mem| if (mem == .init) break :blk .{ .params = mem.init.params, .body = mem.init.body };
                        break :blk null;
                    },
                    else => break :blk null,
                };
            }
            if (e.callee.* == .member) {
                const mem = e.callee.member;
                const obj_type = if (tc_opt) |tc| tc.expr_types.get(mem.object) orelse .unknown else .unknown;
                if (obj_type == .named) {
                    const class_sym = obj_type.named;
                    if (class_sym.own_scope) |scope| {
                        if (scope.lookupLocal(mem.member)) |method_sym| {
                            if (method_sym.kind == .method) break :blk .{ .params = method_sym.decl.method.params, .body = method_sym.decl.method.body };
                        }
                    }
                }
            }
            break :blk null;
        };

        if (params_and_body) |pb| {
            for (e.args, 0..) |a, i| {
                if (i >= pb.params.len) break;
                if (a.value.* != .ident) continue;
                if (!paramNeedsAddrOf(pb.params[i], pb.body, alloc, tc_opt)) continue;
                try set.put(a.value.ident.name, {});
            }
        }
        return;
    }
    switch (expr.*) {
        .binary    => |e| { try addAddrOfMutationsInExpr(e.left, set, alloc, tc_opt, resolve); try addAddrOfMutationsInExpr(e.right, set, alloc, tc_opt, resolve); },
        .unary     => |e| try addAddrOfMutationsInExpr(e.operand, set, alloc, tc_opt, resolve),
        .member    => |e| try addAddrOfMutationsInExpr(e.object, set, alloc, tc_opt, resolve),
        .index     => |e| { try addAddrOfMutationsInExpr(e.object, set, alloc, tc_opt, resolve); try addAddrOfMutationsInExpr(e.index, set, alloc, tc_opt, resolve); },
        .if_expr   => |e| { try addAddrOfMutationsInExpr(e.cond, set, alloc, tc_opt, resolve); try addAddrOfMutationsInExpr(e.then_expr, set, alloc, tc_opt, resolve); try addAddrOfMutationsInExpr(e.else_expr, set, alloc, tc_opt, resolve); },
        .orelse_   => |e| { try addAddrOfMutationsInExpr(e.expr, set, alloc, tc_opt, resolve); try addAddrOfMutationsInExpr(e.fallback, set, alloc, tc_opt, resolve); },
        .catch_    => |e| { try addAddrOfMutationsInExpr(e.expr, set, alloc, tc_opt, resolve); try addAddrOfMutationsInExpr(e.fallback, set, alloc, tc_opt, resolve); },
        .tuple_lit  => |e| { for (e.elems) |el| try addAddrOfMutationsInExpr(el, set, alloc, tc_opt, resolve); },
        .type_check => |e| try addAddrOfMutationsInExpr(e.expr, set, alloc, tc_opt, resolve),
        .try_       => |e| try addAddrOfMutationsInExpr(e.expr, set, alloc, tc_opt, resolve),
        else        => {},
    }
}

/// True if `name` appears as an identifier anywhere in `stmts`.
/// Returns the variable name being nil-checked in `x != nil` (for_then=true) or `x == nil` (for_then=false).
fn nilNarrowVar(cond: *const Ast.Expr, for_then: bool) ?[]const u8 {
    if (cond.* != .binary) return null;
    const b = cond.binary;
    const want: Ast.BinaryOp = if (for_then) .ne else .eq;
    if (b.op != want) return null;
    if (b.left.* == .ident and b.right.* == .nil) return b.left.ident.name;
    if (b.right.* == .ident and b.left.* == .nil) return b.right.ident.name;
    return null;
}

fn nameUsedInStmts(name: []const u8, stmts: []const Ast.Stmt) bool {
    for (stmts) |s| if (nameUsedInStmt(name, s)) return true;
    return false;
}
fn nameUsedInStmt(name: []const u8, stmt: Ast.Stmt) bool {
    return switch (stmt) {
        .var_    => |n| { if (n.init) |e| return nameUsedInExpr(name, e); return false; },
        .assign  => |s| nameUsedInExpr(name, s.target) or nameUsedInExpr(name, s.value),
        .return_ => |s| if (s.value) |v| nameUsedInExpr(name, v) else false,
        .print   => |s| blk: { for (s.args) |a| if (nameUsedInExpr(name, a)) break :blk true; break :blk false; },
        .expr    => |e| nameUsedInExpr(name, e),
        .if_     => |s| blk: {
            if (nameUsedInExpr(name, s.cond)) break :blk true;
            if (nameUsedInStmts(name, s.then_body)) break :blk true;
            for (s.else_ifs) |ei| if (nameUsedInExpr(name, ei.cond) or nameUsedInStmts(name, ei.body)) break :blk true;
            if (s.else_body) |eb| if (nameUsedInStmts(name, eb)) break :blk true;
            break :blk false;
        },
        .while_  => |s| blk: {
            if (s.bind) |bind| if (nameUsedInExpr(name, bind.init)) break :blk true;
            break :blk nameUsedInExpr(name, s.cond) or nameUsedInStmts(name, s.body);
        },
        .for_in  => |s| nameUsedInExpr(name, s.iter) or nameUsedInStmts(name, s.body),
        .for_num => |s| nameUsedInExpr(name, s.start) or nameUsedInExpr(name, s.stop) or nameUsedInStmts(name, s.body),
        .guard       => |s| nameUsedInExpr(name, s.cond) or nameUsedInStmts(name, s.else_body),
        .destruct    => |s| nameUsedInExpr(name, s.init),
        .arena_scope => |s| nameUsedInStmts(name, s.body),
        else         => false,
    };
}
fn nameUsedInExpr(name: []const u8, expr: *const Ast.Expr) bool {
    return switch (expr.*) {
        .ident     => |e| std.mem.eql(u8, e.name, name),
        .call      => |e| nameUsedInExpr(name, e.callee) or blk: {
            for (e.args) |a| if (nameUsedInExpr(name, a.value)) break :blk true;
            break :blk false;
        },
        .member    => |e| nameUsedInExpr(name, e.object),
        .binary    => |e| nameUsedInExpr(name, e.left) or nameUsedInExpr(name, e.right),
        .unary     => |e| nameUsedInExpr(name, e.operand),
        .index     => |e| nameUsedInExpr(name, e.object) or nameUsedInExpr(name, e.index),
        .tuple_lit => |e| blk: {
            for (e.elems) |el| if (nameUsedInExpr(name, el)) break :blk true;
            break :blk false;
        },
        else       => false,
    };
}

// ── Generator ─────────────────────────────────────────────────────────────────

const Generator = struct {
    resolve:   *const Resolver.ResolveResult,
    /// Pass-3 type map.  Null when called from tests that don't run TypeChecker.
    tc:        ?*const TypeChecker.TypeCheckResult,
    /// Output writer.  `AnyWriter` is a fat pointer; copying it is cheap and
    /// both copies still target the same underlying output stream.
    w:         std.io.AnyWriter,
    /// Current indentation depth (4 spaces per level).
    indent:    u32,
    /// Name of the enclosing type (class / struct / enum / mixin).
    /// Empty string when at module scope.
    owner:     []const u8,
    /// True when generating the body of a method, property accessor, or
    /// constructor.  Enables `self.` prefix injection for field identifiers.
    in_method: bool,
    /// All mixin declarations in the module, keyed by name.
    mixins:    *const std.StringHashMap(*const Ast.DeclMixin),
    /// Allocator used for per-method mutation analysis.
    alloc:     Allocator,
    /// Names of local variables that are assigned to somewhere in the current
    /// block.  Null means "no mutation data" → all locals emitted as `const`.
    /// Set by `genStmts` from a per-block scan; not set at method or module scope.
    mutated:   ?*const std.StringHashMap(void),
    /// Names of locals that are lambdas with capture blocks (struct-instance
    /// closures).  Call sites emit `name.call(args)` instead of `name(args)`.
    /// Populated lazily as `genLocalVar` processes capture-lambda var decls.
    closure_vars: ?*std.StringHashMap(void),
    /// Variable names that are known to be std.ArrayList at runtime, introduced
    /// by `for k, v in HashMap(K, List(T))` loops.  `genForIn` checks this so
    /// that `for elem in v` emits `for (v.items)` instead of `for (v)`.
    list_loop_vars: ?*const std.StringHashMap(void) = null,
    /// Capture field names in scope when generating a lambda body that has a
    /// `capture` block.  Ident refs to these names become `self.name`.
    capture_fields: []const []const u8,
    /// Names of all union types declared in the current module.
    /// Used to detect union construction calls: `Type.variant(value)`.
    union_names: *const std.StringHashMap(void),
    /// DeclUnion pointers for all union types declared in the current module.
    /// Used to check whether a variant's payload is `^T` so the construction
    /// expression can emit a labeled-block boxing expression.
    union_decls: *const std.StringHashMap(*const Ast.DeclUnion),
    /// Union type names introduced by selective imports (`use Mod exposing UnionName`).
    /// Maps exposed name → module alias so boxing info can be fetched from ModuleInterface.
    /// Populated lazily by `genUse`; allows `UnionName.variant(v)` → `UnionName{ .variant = v }`.
    exposed_unions: *std.StringHashMap([]const u8),
    /// Class/struct names introduced by selective imports (`use Mod exposing ClassName`).
    /// Populated lazily by `genUse` when the exposed name is a class (non-union) type.
    /// Allows `ClassName(args)` → `ClassName.init(args)` without a class symbol lookup.
    exposed_classes: *std.StringHashMap(void),
    /// All class names visible in the current compilation unit — local classes
    /// (populated in genClass) plus exposed cross-module classes (populated in genUse).
    /// Used by genType to emit `*ClassName` (reference semantics) instead of `ClassName`.
    /// Structs, enums, and unions are NOT in this set.
    class_names: *std.StringHashMap(void),
    /// When non-null, we are inside a `try` block.  `raise` breaks the labeled
    /// block (name = try_block_label) and records the error into this variable
    /// instead of returning from the enclosing method.
    try_block_label: ?[]const u8 = null,
    /// Name of the `?anyerror` variable that records the error in the current
    /// try block.  Always set together with `try_block_label`.
    try_err_var: ?[]const u8 = null,
    /// Name of the catch clause binding variable (e.g. "e" in `catch e`).
    /// Non-empty only when generating a catch clause body.
    /// `e.message` → `_error_ctx.message`, `e.details` → fat-pointer dispatch.
    catch_var: []const u8 = "",
    /// Names of local variables that appear directly in `return` expressions
    /// (or as arguments to calls in return expressions) in the current body.
    /// When a name is in this set, we skip emitting `defer _allocator.free(name)`
    /// because the caller takes ownership of the allocated string.
    returned_names: ?*const std.StringHashMap(void) = null,
    /// Which GUI backend preamble to embed.
    gui_backend: GuiBackend = .stub,
    /// Set to true the first time any GUI API call is encountered.
    /// Allows `generate()` to return a `GenerateResult` with `uses_gui`.
    uses_gui_ptr: ?*bool = null,
    /// When true, emit `export fn Owner_method(...)` wrappers after each
    /// class/struct for eligible `shared` methods (lib mode only).
    emit_exports: bool = false,
    /// Points to the `has_exports` bool in `generate()`.  Set to true the
    /// first time an export wrapper is emitted.
    has_exports_ptr: ?*bool = null,
    /// Variable names that are nil-narrowed in the current if-then scope.
    /// These idents should be accessed with `.?` in Zig to unwrap the optional.
    nil_narrowed: ?*const std.StringHashMap(void) = null,
    /// Non-null inside `extend T` method bodies: the Zebra type of `self`/`this`.
    /// Used so stdlib method calls on `self` dispatch correctly.
    ext_self_type: ?TypeChecker.Type = null,
    /// When set, genExpr substitutes the named expression pointer with this
    /// variable name.  Used to hoist allocating receivers in `genReturn`.
    expr_subst: ?struct { orig: *const Ast.Expr, name: []const u8 } = null,
    /// Native (non-Zebra) `use` dep kinds.  Keyed by dotted Zebra path.
    /// Null = all deps are Zebra-compiled; missing key = Zebra dep.
    native_uses: ?*const std.StringHashMap(NativeUse) = null,
    /// Non-empty when generating a TCO-transformed method: the current method
    /// name.  `genReturn` checks tail-recursive calls against this name.
    tco_method_name: []const u8 = "",
    /// Parameter names of the TCO method (declaration order).
    /// `genReturn` uses these to emit assignments before `continue`.
    tco_params: []const []const u8 = &.{},
    /// True when the TCO method is `shared` (class-level static).
    tco_static_: bool = false,
    /// Source file path (e.g. "test/hello.zbr").  Set from module.file.
    /// Used to emit `// zbr:file:line` markers before each statement so
    /// that Zig compiler errors can be remapped to Zebra source locations.
    source_file: []const u8 = "",
    /// True when generating the body of a generic class (emitted as a comptime
    /// function `pub fn Name(comptime T: type) type { return struct { … }; }`).
    /// Enables `@This()` instead of `owner` for self-type references in init/methods.
    is_generic: bool = false,
    /// When `is_generic`, points to the class declaration so that `genAssign` can
    /// resolve field types for explicit `std.ArrayList(T){}` emission.
    owner_class: ?*const Ast.DeclClass = null,
    /// True when generating the body of a `struct` (not a `class`).
    /// Structs have no `_type_tag` field, so `cue init` bodies must skip the
    /// `self._type_tag = _ttag_*` stamp that classes require.
    is_struct_owner: bool = false,
    /// True when the enclosing method is `throws` (returns `anyerror!T`).
    /// Enables automatic `try` prefix for calls to other `throws` methods,
    /// avoiding Zig's "error union is ignored" error at call sites.
    current_method_throws: bool = false,
    /// Set to true by the `.try_` codegen path before calling genExpr on the inner
    /// expression, so that genCall does not also emit a `try` prefix.  Prevents
    /// `try try self.foo()` when the Zebra source has `foo()?`.
    suppress_auto_try: bool = false,
    /// Member declarations of the current class or struct.  Used in genCall to
    /// look up whether a self-method called via `.method()` syntax is `throws`.
    /// Empty slice at module scope or when owner is a namespace.
    owner_members: []const Ast.Decl = &.{},
    /// Invariant expressions for the current class or struct.
    /// Empty when the owner has no `invariant` block.
    owner_invariants: []const *Ast.Expr = &.{},
    /// Incremented each time we enter an `arena` block so nested scopes get
    /// unique variable names (_arena_scope_1, _arena_scope_2, …).
    arena_depth: u32 = 0,
    /// Module interfaces of `use`d deps — used in `genUse` to decide whether to
    /// import the whole module or unwrap a same-named class.
    imported_modules: ?*const std.StringHashMap(TypeChecker.ModuleInterface) = null,
    /// Monotonic counter used by `nextUid` for deterministic unique identifier
    /// suffixes in emitted Zig (e.g. `_box_3`, `_bp_3`).  Replaces pointer-address
    /// based names which varied across runs.
    box_counter_ptr: *u32,
    /// Non-null when inside a while-based for-else body.  `break` emits
    /// `break :label false` instead of `break;` to suppress the else clause.
    /// Nested loops clear this to null so their own breaks stay plain.
    for_else_label: ?[]const u8 = null,
    /// Pre-call value snapshot map for `ensure`/`old` contracts.
    /// Null outside an ensure defer block.  Maps ExprOld pointer → snapshot index (_old_N).
    old_map: ?*const std.AutoHashMap(*Ast.ExprOld, usize) = null,
    /// When true, all `require`/`ensure`/invariant emit is suppressed (--turbo mode).
    strip_contracts: bool = false,
    /// True while emitting a function body whose `ensure` block emitted a
    /// `var _ensure_armed = false;` flag.  genReturn must `_ensure_armed = true;`
    /// before returning so the deferred ensure check fires only on the success path
    /// (and is skipped on the throws/error path — see BUG-087).
    /// Cleared inside lambda bodies (lambda returns are not the outer fn's returns).
    ensure_armed_active: bool = false,
    /// True while emitting a function body whose `ensure` references `result`.
    /// Implies ensure_armed_active.  genReturn rewrites `return EXPR;` to
    /// `_result = EXPR; _ensure_armed = true; return _result;`.
    ensure_uses_result: bool = false,

    // ── Context-adjustment helpers ────────────────────────────────────────────

    /// Return the next unique identifier suffix.  Called at least once per
    /// emit site that previously used `@intFromPtr(node)`.
    fn nextUid(g: Generator) u32 {
        g.box_counter_ptr.* += 1;
        return g.box_counter_ptr.*;
    }

    fn withOwner(g: Generator, new_owner: []const u8) Generator {
        var c = g; c.owner = new_owner; return c;
    }
    /// Set owner name + owner_class pointer for a non-generic concrete class.
    /// This enables `resolveFieldTypeRef` for `^T` boxing in the class body.
    fn withClass(g: Generator, cls: *const Ast.DeclClass) Generator {
        var c = g; c.owner = cls.name; c.owner_class = cls; c.owner_members = cls.members; c.owner_invariants = cls.invariants; return c;
    }
    /// Set owner name + owner_members for a struct body.
    /// Mirrors `withClass` so that `exprCallIsThrows` and `genCall`'s auto-try
    /// logic can look up throws status for `self.method()` calls inside struct methods.
    fn withStruct(g: Generator, s: *const Ast.DeclStruct) Generator {
        var c = g; c.owner = s.name; c.owner_members = s.members; c.is_struct_owner = true; c.owner_invariants = s.invariants; return c;
    }
    fn withGeneric(g: Generator, cls: *const Ast.DeclClass) Generator {
        var c = g; c.is_generic = true; c.owner_class = cls; c.owner_members = cls.members; c.owner_invariants = cls.invariants; return c;
    }
    fn withExtSelf(g: Generator, t: TypeChecker.Type) Generator {
        var c = g; c.ext_self_type = t; return c;
    }
    fn withOldMap(g: Generator, m: *const std.AutoHashMap(*Ast.ExprOld, usize)) Generator {
        var c = g; c.old_map = m; return c;
    }

    fn withEnsureCtx(g: Generator, armed: bool, uses_result: bool) Generator {
        var c = g;
        c.ensure_armed_active = armed;
        c.ensure_uses_result = uses_result;
        return c;
    }

    /// Clear the ensure context — used when entering a lambda body so that
    /// `return` inside the lambda does NOT trigger the outer-function rewrite.
    fn withInLambda(g: Generator) Generator {
        var c = g;
        c.ensure_armed_active = false;
        c.ensure_uses_result = false;
        return c;
    }

    /// When inside a generic class body, resolve the Zig element-type string for a
    /// `List(X)` field named `field_name`.  Returns null if the field isn't a List.
    ///
    /// Examples:
    ///   `items as List(T)` with type_params=["T"] → "T"   (comptime param name)
    ///   `items as List(str)`                       → "[]const u8"
    /// Return the declared TypeRef for a field of the current class, or null.
    fn resolveFieldTypeRef(g: Generator, field_name: []const u8) ?Ast.TypeRef {
        // Use owner_class.members when in a class body; fall back to owner_members
        // (which is set for structs via withStruct) so that struct field ^T boxing works.
        const members: []const Ast.Decl = if (g.owner_class) |cls|
            cls.members
        else
            g.owner_members;
        for (members) |m| {
            const vd: *const Ast.DeclVar = switch (m) {
                .var_ => |v| v,
                else  => continue,
            };
            if (!std.mem.eql(u8, vd.name, field_name)) continue;
            return vd.type_;
        }
        return null;
    }

    /// Return the `GenericTypeRef` for a class field named `field_name`, or null
    /// if the field doesn't exist, has no type annotation, or isn't a generic type.
    /// Works for any `List(T)`, `HashMap(K,V)`, or user-defined generic `Stack(T)`.
    fn resolveFieldGenericTypeRef(g: Generator, field_name: []const u8) ?Ast.GenericTypeRef {
        const tr = g.resolveFieldTypeRef(field_name) orelse return null;
        if (tr != .generic) return null;
        return tr.generic;
    }
    fn asMethod(g: Generator) Generator {
        var c = g; c.in_method = true; return c;
    }
    fn indented(g: Generator) Generator {
        var c = g; c.indent += 1; return c;
    }
    fn withMutated(g: Generator, m: *const std.StringHashMap(void)) Generator {
        var c = g; c.mutated = m; return c;
    }
    fn withClosureVars(g: Generator, cv: *std.StringHashMap(void)) Generator {
        var c = g; c.closure_vars = cv; return c;
    }
    fn withCatchVar(g: Generator, name: []const u8) Generator {
        var c = g; c.catch_var = name; return c;
    }
    fn withCaptureFields(g: Generator, fields: []const []const u8) Generator {
        var c = g; c.capture_fields = fields; return c;
    }
    fn withTryLabel(g: Generator, label: []const u8, err_var: []const u8) Generator {
        var c = g; c.try_block_label = label; c.try_err_var = err_var; return c;
    }
    fn withReturnedNames(g: Generator, rn: *const std.StringHashMap(void)) Generator {
        var c = g; c.returned_names = rn; return c;
    }
    fn withNilNarrowed(g: Generator, nn: *const std.StringHashMap(void)) Generator {
        var c = g; c.nil_narrowed = nn; return c;
    }
    fn withTco(g: Generator, method_name: []const u8, params: []const []const u8, shared: bool) Generator {
        var c = g; c.tco_method_name = method_name; c.tco_params = params; c.tco_static_ = shared; return c;
    }

    // ── Low-level output ──────────────────────────────────────────────────────

    fn writeIndent(g: Generator) anyerror!void {
        var i: u32 = 0;
        while (i < g.indent) : (i += 1) try g.w.writeAll("    ");
    }

    /// Write an indented line (adds trailing newline).
    fn line(g: Generator, s: []const u8) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll(s);
        try g.w.writeAll("\n");
    }

    // ── Module ────────────────────────────────────────────────────────────────

    fn genModule(g: Generator, module: Ast.Module) anyerror!void {
        try g.w.writeAll("// Generated by the Zebra compiler.\n// Source: ");
        try g.w.writeAll(module.file);
        try g.w.writeAll("\n\nconst std     = @import(\"std\");\nconst builtin = @import(\"builtin\");\n\n");
        // Global allocator — used by List, HashMap, and allocating string ops.
        // ArenaAllocator: individual free() calls are no-ops; everything released
        // at program exit via _arena.deinit().  Much faster than GPA for programs
        // that do many small allocations (string ops, trigram maps, etc.).
        // For leak detection during development, swap to GeneralPurposeAllocator.
        try g.w.writeAll("var _arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);\n");
        // `var` (not `const`) so that `arena` blocks can save/restore it.
        // Pre-initialised from `_arena` so modules are usable without an explicit
        // `_initAllocator` call — safe because each module owns its own arena.
        // `_initAllocator` overrides this with a shared allocator when needed.
        try g.w.writeAll("var _allocator: std.mem.Allocator = _arena.allocator();\n");
        // String intern pool — backed by page_allocator so interned strings
        // survive arena_scope rewinds.  _intern() is the only public entry point.
        // Initialized eagerly at declaration so main modules (which never receive
        // an _initAllocator call) can use _intern before any explicit init.
        try g.w.writeAll("var _str_pool = std.StringHashMap([]const u8).init(std.heap.page_allocator);\n");
        // `_initAllocator` sets this module's allocator AND propagates to every
        // directly-imported Zebra module, so transitive deps are always initialised
        // even when the root `main` only calls it for direct imports.
        try g.w.writeAll("pub fn _initAllocator(a: std.mem.Allocator) void {\n    _allocator = a;\n");
        for (module.decls) |decl| {
            const u = switch (decl) { .use => |u| u, else => continue };
            if (g.native_uses) |nu| if (nu.get(u.path) != null) continue;
            const imp_path = try std.mem.replaceOwned(u8, g.alloc, u.path, ".", "/");
            defer g.alloc.free(imp_path);
            try g.w.print("    @import(\"{s}.zig\")._initAllocator(a);\n", .{imp_path});
        }
        try g.w.writeAll("}\n");
        try g.w.writeAll(build_options.stdlib_preamble_pre_gui);
        // Recursive error-message walker: each module checks its own
        // `_error_ctx`, then falls through to every direct import's helper.
        // Chain traverses transitive modules so a raise deep in a dep is
        // visible from any catch that reads `e.message`.
        try g.w.writeAll("pub fn _zbr_error_msg() []const u8 {\n");
        try g.w.writeAll("    if (_error_ctx.message.len > 0) return _error_ctx.message;\n");
        for (module.decls) |decl| {
            const u = switch (decl) { .use => |u| u, else => continue };
            if (g.native_uses) |nu| if (nu.get(u.path) != null) continue;
            const imp_path = try std.mem.replaceOwned(u8, g.alloc, u.path, ".", "/");
            defer g.alloc.free(imp_path);
            try g.w.print("    if (@import(\"{s}.zig\")._zbr_error_msg().len > 0) return @import(\"{s}.zig\")._zbr_error_msg();\n", .{ imp_path, imp_path });
        }
        try g.w.writeAll("    return \"\";\n");
        try g.w.writeAll("}\n");

        // ── GUI: _GuiBackend fn-ptr isolation + GuiContext stable surface ──────
        try g.w.writeAll(
            \\// ─── GUI: backend isolation ──────────────────────────────────────────────────
            \\// _GuiBackend is an fn-ptr struct.  Swap `_gui_active_backend` to change
            \\// the renderer without touching user code or GuiContext.
            \\const _GuiBackend = struct {
            \\    initFn:        *const fn (title: []const u8, width: i64, height: i64) anyerror!void,
            \\    deinitFn:      *const fn () void,
            \\    newFrameFn:    *const fn () bool,
            \\    endFrameFn:    *const fn () void,
            \\    textFn:        *const fn (s: []const u8) void,
            \\    separatorFn:   *const fn () void,
            \\    sameLineFn:    *const fn () void,
            \\    spacingFn:     *const fn () void,
            \\    indentFn:      *const fn () void,
            \\    unindentFn:    *const fn () void,
            \\    buttonFn:      *const fn (label: []const u8) bool,
            \\    checkboxFn:    *const fn (label: []const u8, value: bool) bool,
            \\    sliderFn:      *const fn (label: []const u8, value: f64, min: f64, max: f64) f64,
            \\    inputFn:       *const fn (label: []const u8, value: []const u8) []const u8,
            \\    inputMultilineFn: *const fn (label: []const u8, value: []const u8, width: f64, height: f64) []const u8,
            \\    codeEditorFn:  *const fn (label: []const u8, value: []const u8, width: f64, height: f64) []const u8,
            \\    beginPanelFn:  *const fn (label: []const u8) bool,
            \\    endPanelFn:    *const fn () void,
            \\    beginWindowFn: *const fn (label: []const u8) bool,
            \\    endWindowFn:   *const fn () void,
            \\};
            \\const GuiContext = struct {
            \\    _b: *const _GuiBackend,
            \\    pub fn text(self: GuiContext, s: []const u8) void { self._b.textFn(s); }
            \\    pub fn separator(self: GuiContext) void { self._b.separatorFn(); }
            \\    pub fn sameLine(self: GuiContext) void { self._b.sameLineFn(); }
            \\    pub fn spacing(self: GuiContext) void { self._b.spacingFn(); }
            \\    pub fn indent(self: GuiContext) void { self._b.indentFn(); }
            \\    pub fn unindent(self: GuiContext) void { self._b.unindentFn(); }
            \\    pub fn button(self: GuiContext, label: []const u8) bool { return self._b.buttonFn(label); }
            \\    pub fn checkbox(self: GuiContext, label: []const u8, value: bool) bool { return self._b.checkboxFn(label, value); }
            \\    pub fn slider(self: GuiContext, label: []const u8, value: f64, min: f64, max: f64) f64 { return self._b.sliderFn(label, value, min, max); }
            \\    pub fn input(self: GuiContext, label: []const u8, value: []const u8) []const u8 { return self._b.inputFn(label, value); }
            \\    pub fn inputMultiline(self: GuiContext, label: []const u8, value: []const u8, width: f64, height: f64) []const u8 { return self._b.inputMultilineFn(label, value, width, height); }
            \\    pub fn panel(self: GuiContext, label: []const u8, callback: anytype) void {
            \\        if (self._b.beginPanelFn(label)) {
            \\            if (comptime @typeInfo(@TypeOf(callback)) == .@"fn") callback(self) else callback.call(self);
            \\            self._b.endPanelFn();
            \\        }
            \\    }
            \\    pub fn window(self: GuiContext, label: []const u8, callback: anytype) void {
            \\        if (self._b.beginWindowFn(label)) {
            \\            if (comptime @typeInfo(@TypeOf(callback)) == .@"fn") callback(self) else callback.call(self);
            \\            self._b.endWindowFn();
            \\        }
            \\    }
            \\};
            \\fn _gui_run(title: []const u8, width: i64, height: i64, frame: anytype) void {
            \\    _gui_active_backend.initFn(title, width, height) catch @panic("gui init failed");
            \\    defer _gui_active_backend.deinitFn();
            \\    const _g = GuiContext{ ._b = &_gui_active_backend };
            \\    if (comptime @typeInfo(@TypeOf(frame)) == .@"fn") {
            \\        while (_gui_active_backend.newFrameFn()) {
            \\            frame(_g);
            \\            _gui_active_backend.endFrameFn();
            \\        }
            \\    } else {
            \\        var _mframe = frame;
            \\        while (_gui_active_backend.newFrameFn()) {
            \\            _mframe.call(_g);
            \\            _gui_active_backend.endFrameFn();
            \\        }
            \\    }
            \\}
            \\
        );
        // ── CodeEditor widget — Phase A: backed by GuiContext.inputMultiline ──
        try g.w.writeAll(
            \\const _CodeEditor = struct { text: []const u8, read_only: bool };
            \\fn _code_editor_new() *_CodeEditor {
            \\    const _ed = _allocator.create(_CodeEditor) catch unreachable;
            \\    _ed.* = .{ .text = "", .read_only = false };
            \\    return _ed;
            \\}
            \\fn _code_editor_set_text(_ed: *_CodeEditor, text: []const u8) void { _ed.text = text; }
            \\fn _code_editor_get_text(_ed: *_CodeEditor) []const u8 { return _ed.text; }
            \\fn _code_editor_set_readonly(_ed: *_CodeEditor, v: bool) void { _ed.read_only = v; }
            \\fn _code_editor_render(_ed: *_CodeEditor, _g: GuiContext, id: []const u8, w: f64, h: f64) void {
            \\    const _r = _g._b.codeEditorFn(id, _ed.text, w, h);
            \\    if (!_ed.read_only) { _ed.text = _r; }
            \\}
            \\fn _code_editor_set_error_markers(_ed: *_CodeEditor, _m: anytype) void { _ = _ed; _ = _m; }
            \\
        );
        // ── Backend-specific implementation ────────────────────────────────────
        switch (g.gui_backend) {
            .stub => try g.w.writeAll(
                \\// ─── Stub backend (single frame, prints to stderr) ───────────────────────────
                \\fn _stub_init(title: []const u8, width: i64, height: i64) anyerror!void {
                \\    _ = title; _ = width; _ = height;
                \\}
                \\fn _stub_deinit() void {}
                \\var _stub_frame_count: u8 = 0;
                \\fn _stub_new_frame() bool {
                \\    if (_stub_frame_count >= 1) return false;
                \\    _stub_frame_count += 1;
                \\    return true;
                \\}
                \\fn _stub_end_frame() void {}
                \\fn _stub_text(s: []const u8) void { std.debug.print("[gui] text: {s}\n", .{s}); }
                \\fn _stub_separator() void { std.debug.print("[gui] ---\n", .{}); }
                \\fn _stub_same_line() void { std.debug.print("[gui] sameLine\n", .{}); }
                \\fn _stub_spacing() void { std.debug.print("[gui] spacing\n", .{}); }
                \\fn _stub_indent() void { std.debug.print("[gui] indent\n", .{}); }
                \\fn _stub_unindent() void { std.debug.print("[gui] unindent\n", .{}); }
                \\fn _stub_button(label: []const u8) bool {
                \\    std.debug.print("[gui] button: {s}\n", .{label});
                \\    return false;
                \\}
                \\fn _stub_checkbox(label: []const u8, value: bool) bool {
                \\    std.debug.print("[gui] checkbox: {s} = {}\n", .{ label, value });
                \\    return value;
                \\}
                \\fn _stub_slider(label: []const u8, value: f64, min: f64, max: f64) f64 {
                \\    std.debug.print("[gui] slider: {s} = {d} [{d}, {d}]\n", .{ label, value, min, max });
                \\    return value;
                \\}
                \\fn _stub_input(label: []const u8, value: []const u8) []const u8 {
                \\    std.debug.print("[gui] input: {s} = {s}\n", .{ label, value });
                \\    return value;
                \\}
                \\fn _stub_input_multiline(label: []const u8, value: []const u8, width: f64, height: f64) []const u8 {
                \\    std.debug.print("[gui] inputMultiline: {s} ({d}x{d})\n", .{ label, width, height });
                \\    return value;
                \\}
                \\fn _stub_begin_panel(label: []const u8) bool {
                \\    std.debug.print("[gui] panel: {s}\n", .{label});
                \\    return true;
                \\}
                \\fn _stub_end_panel() void {}
                \\fn _stub_begin_window(label: []const u8) bool {
                \\    std.debug.print("[gui] window: {s}\n", .{label});
                \\    return true;
                \\}
                \\fn _stub_end_window() void {}
                \\const _gui_stub_backend = _GuiBackend{
                \\    .initFn        = _stub_init,
                \\    .deinitFn      = _stub_deinit,
                \\    .newFrameFn    = _stub_new_frame,
                \\    .endFrameFn    = _stub_end_frame,
                \\    .textFn        = _stub_text,
                \\    .separatorFn   = _stub_separator,
                \\    .sameLineFn    = _stub_same_line,
                \\    .spacingFn     = _stub_spacing,
                \\    .indentFn      = _stub_indent,
                \\    .unindentFn    = _stub_unindent,
                \\    .buttonFn      = _stub_button,
                \\    .checkboxFn    = _stub_checkbox,
                \\    .sliderFn      = _stub_slider,
                \\    .inputFn       = _stub_input,
                \\    .inputMultilineFn = _stub_input_multiline,
                \\    .codeEditorFn  = _stub_input_multiline,
                \\    .beginPanelFn  = _stub_begin_panel,
                \\    .endPanelFn    = _stub_end_panel,
                \\    .beginWindowFn = _stub_begin_window,
                \\    .endWindowFn   = _stub_end_window,
                \\};
                \\const _gui_active_backend: _GuiBackend = _gui_stub_backend;
                \\
            ),
            // ── zgui GLFW+OpenGL3 backend ──────────────────────────────────────
            // Requires a `zig build` project (not bare `zig run`).
            // main.zig wires up a generated project dir when uses_gui is true.
            .glfw => try g.w.writeAll(
                \\// ─── zgui GLFW+OpenGL3 backend ──────────────────────────────────────────────
                \\const zgui    = @import("zgui");
                \\const zglfw   = @import("zglfw");
                \\const zopengl = @import("zopengl");
                \\var _gl_window: *zglfw.Window = undefined;
                \\fn _imgui_init(title: []const u8, width: i64, height: i64) anyerror!void {
                \\    try zglfw.init();
                \\    errdefer zglfw.terminate();
                \\    zglfw.windowHint(.context_version_major, 3);
                \\    zglfw.windowHint(.context_version_minor, 3);
                \\    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
                \\    const _title_z = try _allocator.dupeZ(u8, title);
                \\    defer _allocator.free(_title_z);
                \\    _gl_window = try zglfw.createWindow(
                \\        @intCast(width), @intCast(height), _title_z, null, null,
                \\    );
                \\    errdefer _gl_window.destroy();
                \\    zglfw.makeContextCurrent(_gl_window);
                \\    zglfw.swapInterval(1);
                \\    try zopengl.loadCoreProfile(zglfw.getProcAddress, 3, 3);
                \\    zgui.init(_allocator);
                \\    zgui.backend.init(_gl_window);
                \\}
                \\fn _imgui_deinit() void {
                \\    zgui.backend.deinit();
                \\    zgui.deinit();
                \\    _gl_window.destroy();
                \\    zglfw.terminate();
                \\}
                \\fn _imgui_new_frame() bool {
                \\    zglfw.pollEvents();
                \\    if (_gl_window.shouldClose()) return false;
                \\    const _fb = _gl_window.getFramebufferSize();
                \\    zgui.backend.newFrame(@intCast(_fb[0]), @intCast(_fb[1]));
                \\    // Auto-wrap all frame widgets in a fullscreen borderless window.
                \\    zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
                \\    zgui.setNextWindowSize(.{ .w = @floatFromInt(_fb[0]), .h = @floatFromInt(_fb[1]) });
                \\    _ = zgui.begin("##_main", .{ .flags = .{
                \\        .no_title_bar = true, .no_resize = true,
                \\        .no_move = true,      .no_collapse = true,
                \\    }});
                \\    return true;
                \\}
                \\fn _imgui_end_frame() void {
                \\    zgui.end();
                \\    const _fb = _gl_window.getFramebufferSize();
                \\    zopengl.bindings.viewport(0, 0, _fb[0], _fb[1]);
                \\    zopengl.bindings.clearColor(0.1, 0.1, 0.1, 1.0);
                \\    zopengl.bindings.clear(zopengl.bindings.COLOR_BUFFER_BIT);
                \\    zgui.backend.draw();
                \\    _gl_window.swapBuffers();
                \\}
                \\fn _imgui_text(s: []const u8) void { zgui.textUnformatted(s); }
                \\fn _imgui_separator() void { zgui.separator(); }
                \\fn _imgui_same_line() void { zgui.sameLine(.{}); }
                \\fn _imgui_spacing() void { zgui.spacing(); }
                \\fn _imgui_indent() void { zgui.indent(.{}); }
                \\fn _imgui_unindent() void { zgui.unindent(.{}); }
                \\fn _imgui_button(label: []const u8) bool {
                \\    const _z = _allocator.dupeZ(u8, label) catch return false;
                \\    defer _allocator.free(_z);
                \\    return zgui.button(_z, .{});
                \\}
                \\fn _imgui_checkbox(label: []const u8, value: bool) bool {
                \\    const _z = _allocator.dupeZ(u8, label) catch return value;
                \\    defer _allocator.free(_z);
                \\    var _v = value;
                \\    _ = zgui.checkbox(_z, .{ .v = &_v });
                \\    return _v;
                \\}
                \\fn _imgui_slider(label: []const u8, value: f64, min: f64, max: f64) f64 {
                \\    const _z = _allocator.dupeZ(u8, label) catch return value;
                \\    defer _allocator.free(_z);
                \\    var _v: f32 = @floatCast(value);
                \\    _ = zgui.sliderFloat(_z, .{ .v = &_v, .min = @floatCast(min), .max = @floatCast(max) });
                \\    return @floatCast(_v);
                \\}
                \\fn _imgui_input(label: []const u8, value: []const u8) []const u8 {
                \\    const _z = _allocator.dupeZ(u8, label) catch return value;
                \\    defer _allocator.free(_z);
                \\    var _buf: [256:0]u8 = @splat(0);
                \\    const _n = @min(value.len, _buf.len - 1);
                \\    @memcpy(_buf[0.._n], value[0.._n]);
                \\    if (zgui.inputText(_z, .{ .buf = &_buf })) {
                \\        const _len = std.mem.indexOfScalar(u8, &_buf, 0) orelse _buf.len;
                \\        return _allocator.dupe(u8, _buf[0.._len]) catch value;
                \\    }
                \\    return value;
                \\}
                \\fn _imgui_input_multiline(label: []const u8, value: []const u8, width: f64, height: f64) []const u8 {
                \\    const _z = _allocator.dupeZ(u8, label) catch return value;
                \\    defer _allocator.free(_z);
                \\    var _buf: [65536:0]u8 = @splat(0);
                \\    const _n = @min(value.len, _buf.len - 1);
                \\    @memcpy(_buf[0.._n], value[0.._n]);
                \\    if (zgui.inputTextMultiline(_z, .{ .buf = &_buf, .w = @floatCast(width), .h = @floatCast(height) })) {
                \\        const _len = std.mem.indexOfScalar(u8, &_buf, 0) orelse _buf.len;
                \\        return _allocator.dupe(u8, _buf[0.._len]) catch value;
                \\    }
                \\    return value;
                \\}
                \\fn _imgui_begin_panel(label: []const u8) bool {
                \\    const _z = _allocator.dupeZ(u8, label) catch return true;
                \\    defer _allocator.free(_z);
                \\    return zgui.collapsingHeader(_z, .{});
                \\}
                \\fn _imgui_end_panel() void {}
                \\fn _imgui_begin_window(label: []const u8) bool {
                \\    const _z = _allocator.dupeZ(u8, label) catch return true;
                \\    defer _allocator.free(_z);
                \\    return zgui.begin(_z, .{});
                \\}
                \\fn _imgui_end_window() void { zgui.end(); }
                \\const _gui_imgui_backend = _GuiBackend{
                \\    .initFn        = _imgui_init,
                \\    .deinitFn      = _imgui_deinit,
                \\    .newFrameFn    = _imgui_new_frame,
                \\    .endFrameFn    = _imgui_end_frame,
                \\    .textFn        = _imgui_text,
                \\    .separatorFn   = _imgui_separator,
                \\    .sameLineFn    = _imgui_same_line,
                \\    .spacingFn     = _imgui_spacing,
                \\    .indentFn      = _imgui_indent,
                \\    .unindentFn    = _imgui_unindent,
                \\    .buttonFn      = _imgui_button,
                \\    .checkboxFn    = _imgui_checkbox,
                \\    .sliderFn      = _imgui_slider,
                \\    .inputFn       = _imgui_input,
                \\    .inputMultilineFn = _imgui_input_multiline,
                \\    .codeEditorFn  = _imgui_input_multiline,
                \\    .beginPanelFn  = _imgui_begin_panel,
                \\    .endPanelFn    = _imgui_end_panel,
                \\    .beginWindowFn = _imgui_begin_window,
                \\    .endWindowFn   = _imgui_end_window,
                \\};
                \\const _gui_active_backend: _GuiBackend = _gui_imgui_backend;
                \\
            ),
            // sdl2 / dx12 not yet implemented — fall through to stub.
            .sdl2, .dx12 => try g.w.writeAll(
                \\// TODO: sdl2/dx12 GUI backend not yet implemented; using stub.
                \\fn _stub_init(title: []const u8, width: i64, height: i64) anyerror!void {
                \\    _ = title; _ = width; _ = height;
                \\}
                \\fn _stub_deinit() void {}
                \\var _stub_frame_count: u8 = 0;
                \\fn _stub_new_frame() bool {
                \\    if (_stub_frame_count >= 1) return false;
                \\    _stub_frame_count += 1;
                \\    return true;
                \\}
                \\fn _stub_end_frame() void {}
                \\fn _stub_text(s: []const u8) void { std.debug.print("[gui] text: {s}\n", .{s}); }
                \\fn _stub_separator() void { std.debug.print("[gui] ---\n", .{}); }
                \\fn _stub_same_line() void { std.debug.print("[gui] sameLine\n", .{}); }
                \\fn _stub_spacing() void { std.debug.print("[gui] spacing\n", .{}); }
                \\fn _stub_indent() void { std.debug.print("[gui] indent\n", .{}); }
                \\fn _stub_unindent() void { std.debug.print("[gui] unindent\n", .{}); }
                \\fn _stub_button(label: []const u8) bool {
                \\    std.debug.print("[gui] button: {s}\n", .{label});
                \\    return false;
                \\}
                \\fn _stub_checkbox(label: []const u8, value: bool) bool {
                \\    std.debug.print("[gui] checkbox: {s} = {}\n", .{ label, value });
                \\    return value;
                \\}
                \\fn _stub_slider(label: []const u8, value: f64, min: f64, max: f64) f64 {
                \\    std.debug.print("[gui] slider: {s} = {d} [{d}, {d}]\n", .{ label, value, min, max });
                \\    return value;
                \\}
                \\fn _stub_input(label: []const u8, value: []const u8) []const u8 {
                \\    std.debug.print("[gui] input: {s} = {s}\n", .{ label, value });
                \\    return value;
                \\}
                \\fn _stub_input_multiline(label: []const u8, value: []const u8, width: f64, height: f64) []const u8 {
                \\    std.debug.print("[gui] inputMultiline: {s} ({d}x{d})\n", .{ label, width, height });
                \\    return value;
                \\}
                \\fn _stub_begin_panel(label: []const u8) bool {
                \\    std.debug.print("[gui] panel: {s}\n", .{label});
                \\    return true;
                \\}
                \\fn _stub_end_panel() void {}
                \\fn _stub_begin_window(label: []const u8) bool {
                \\    std.debug.print("[gui] window: {s}\n", .{label});
                \\    return true;
                \\}
                \\fn _stub_end_window() void {}
                \\const _gui_stub_backend = _GuiBackend{
                \\    .initFn        = _stub_init,
                \\    .deinitFn      = _stub_deinit,
                \\    .newFrameFn    = _stub_new_frame,
                \\    .endFrameFn    = _stub_end_frame,
                \\    .textFn        = _stub_text,
                \\    .separatorFn   = _stub_separator,
                \\    .sameLineFn    = _stub_same_line,
                \\    .spacingFn     = _stub_spacing,
                \\    .indentFn      = _stub_indent,
                \\    .unindentFn    = _stub_unindent,
                \\    .buttonFn      = _stub_button,
                \\    .checkboxFn    = _stub_checkbox,
                \\    .sliderFn      = _stub_slider,
                \\    .inputFn       = _stub_input,
                \\    .inputMultilineFn = _stub_input_multiline,
                \\    .codeEditorFn  = _stub_input_multiline,
                \\    .beginPanelFn  = _stub_begin_panel,
                \\    .endPanelFn    = _stub_end_panel,
                \\    .beginWindowFn = _stub_begin_window,
                \\    .endWindowFn   = _stub_end_window,
                \\};
                \\const _gui_active_backend: _GuiBackend = _gui_stub_backend;
                \\
            ),
        }

        try g.w.writeAll(build_options.stdlib_preamble_post_gui);
        for (module.decls) |decl| try g.genTopDecl(decl);

        // Emit a top-level `pub fn main()` thunk if any class has a
        // `shared def main`.  Zig's startup code looks for `root.main`.
        if (try findMainClass(module.decls, g.alloc, "")) |class_name| {
            defer g.alloc.free(class_name);
            // If the main method throws, wrap in a catch block so ZebraError
            // is displayed as a clean user-facing message rather than Zig's
            // "error: ZebraError" with a backtrace.
            const main_throws = findMainMethod(module.decls) != null and blk: {
                const m = findMainMethod(module.decls).?;
                break :blk m.throws or (m.body != null and bodyHasRaise(m.body.?, g.tc));
            };
            // Build allocator-init calls for all Zebra-dep `use` modules so that
            // library code that calls allocating functions (string interp, etc.)
            // shares the root module's arena allocator.
            var alloc_init_buf: std.ArrayListUnmanaged(u8) = .{};
            defer alloc_init_buf.deinit(g.alloc);
            for (module.decls) |decl| {
                const u = switch (decl) { .use => |u| u, else => continue };
                // Skip native (Zig/C) imports — they don't have `_initAllocator`.
                if (g.native_uses) |nu| if (nu.get(u.path) != null) continue;
                // Compute import path (dots → slashes).
                const imp_path = try std.mem.replaceOwned(u8, g.alloc, u.path, ".", "/");
                defer g.alloc.free(imp_path);
                try alloc_init_buf.writer(g.alloc).print(
                    "    @import(\"{s}.zig\")._initAllocator(_allocator);\n", .{imp_path});
            }
            const alloc_init = alloc_init_buf.items;

            if (main_throws) {
                try g.w.print(
                    "pub fn main() void {{\n" ++
                    "    _allocator = _arena.allocator();\n" ++
                    "    defer _arena.deinit();\n" ++
                    "{s}" ++
                    "    {s}.main() catch |_err| {{\n" ++
                    "        if (_err == error.ZebraError) {{\n" ++
                    "            std.debug.print(\"Error: {{s}}\\n\", .{{_zbr_error_msg()}});\n" ++
                    "        }} else {{\n" ++
                    "            std.debug.print(\"Error: {{}}\\n\", .{{_err}});\n" ++
                    "        }}\n" ++
                    "        std.process.exit(1);\n" ++
                    "    }};\n" ++
                    "}}\n",
                    .{ alloc_init, class_name },
                );
            } else {
                try g.w.print(
                    "pub fn main() void {{\n" ++
                    "    _allocator = _arena.allocator();\n" ++
                    "    defer _arena.deinit();\n" ++
                    "{s}" ++
                    "    {s}.main();\n" ++
                    "}}\n",
                    .{ alloc_init, class_name },
                );
            }
        }
    }

    fn genTopDecl(g: Generator, decl: Ast.Decl) anyerror!void {
        switch (decl) {
            .use       => |n| try g.genUse(n),
            .namespace => |n| try g.genNamespace(n),
            .class     => |n| try g.genClass(n),
            .interface => |n| try g.genInterface(n),
            .struct_   => |n| try g.genStruct(n),
            .mixin     => {},   // never emitted standalone; inlined at `adds` sites
            .enum_     => |n| try g.genEnum(n),
            .extend    => |n| try g.genExtend(n),
            .method    => |n| try g.genMethod(n),
            .var_      => |n| try g.genTopVar(n),
            .init      => {},   // top-level constructor makes no sense
            .union_    => |n| try g.genUnion(n),
            .sig_      => |n| try g.genSig(n),
        }
    }

    // ── sig ───────────────────────────────────────────────────────────────────

    fn genSig(g: Generator, n: *Ast.DeclSig) anyerror!void {
        // Emit: `const Name = *const fn(T1, T2) R;`
        // This makes `Name` a usable Zig type alias for the function pointer type.
        try g.writeIndent();
        try g.w.print("const {s} = *const fn(", .{n.name});
        for (n.params, 0..) |p, i| {
            if (i > 0) try g.w.writeAll(", ");
            if (p.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
        }
        try g.w.writeAll(") ");
        if (n.return_type) |rt| try g.genType(rt) else try g.w.writeAll("void");
        try g.w.writeAll(";\n");
    }

    // ── use ───────────────────────────────────────────────────────────────────

    fn genUse(g: Generator, n: *Ast.DeclUse) anyerror!void {
        try g.writeIndent();
        // Alias = last segment of dotted path:  "Math.Utils" → "Utils"
        const last_dot = std.mem.lastIndexOf(u8, n.path, ".");
        const alias = if (last_dot) |d| n.path[d + 1..] else n.path;
        // Import path: replace '.' with '/' and use forward slashes throughout.
        // Zig @import accepts forward slashes on all platforms.
        const import_rel = try std.mem.replaceOwned(u8, g.alloc, n.path, ".", "/");
        defer g.alloc.free(import_rel);

        // Check if this dep is a native Zig or C file.
        const native_kind: ?NativeUse = if (g.native_uses) |nu| nu.get(n.path) else null;

        if (native_kind) |kind| switch (kind) {
            .zig => {
                // Native Zig file: import the whole module without unwrapping a
                // single class.  The user accesses its exports as `Alias.Foo`.
                try g.w.print("const {s} = @import(\"{s}.zig\");\n", .{ alias, import_rel });
            },
            .c_with_header => {
                // C file + matching header: expose via cImport so Zebra code
                // can call C functions as `Alias.some_fn(...)`.
                try g.w.print("const {s} = @cImport(@cInclude(\"{s}.h\"));\n", .{ alias, import_rel });
            },
            .c_no_header => {
                // C file without a header: compiled as a translation unit.
                // Declare needed symbols via zig"extern fn ..." in Zebra source.
                try g.w.print("// {s}: C source compiled inline (use zig\"extern fn...\" for declarations)\n", .{alias});
            },
        } else {
            // Zebra dep: if the module exports EXACTLY ONE non-union type whose name
            // matches the alias, unwrap it so `Alias.method()` works without double
            // qualification.  Union types (discriminated-union variants) are excluded
            // from the count because they are always accessed as `Module.UnionName.variant`.
            // Multi-type modules (e.g. Token: TokenKind(union) + Token + Keywords) must
            // be imported whole so qualified refs like `Token.TokenKind` resolve correctly.
            const has_sole_same_named_type = blk: {
                const imp = g.imported_modules orelse break :blk false;
                const iface = imp.get(alias) orelse break :blk false;
                // Count only non-union types.
                var non_union_count: usize = 0;
                var it = iface.types.valueIterator();
                while (it.next()) |kind| { if (kind.* != .union_) non_union_count += 1; }
                if (non_union_count != 1) break :blk false;
                // The sole non-union type must be named after the alias.
                const kind_ptr = iface.types.getPtr(alias) orelse break :blk false;
                break :blk kind_ptr.* != .union_;
            };
            if (has_sole_same_named_type) {
                try g.w.print("const {s} = @import(\"{s}.zig\").{s};\n", .{ alias, import_rel, alias });
            } else {
                // Multi-type module or module whose primary type has a different name —
                // import the whole file so `Alias.TypeName.method()` works.
                try g.w.print("const {s} = @import(\"{s}.zig\");\n", .{ alias, import_rel });
            }
            // Selective imports: `use Mod exposing Name1, Name2`
            // Emit `const Name = Alias.Name;` for each exposed name that doesn't
            // conflict with the module alias.  Track exposed union names so that
            // `Name.variant(v)` → `Name{ .variant = v }` works in genCall.
            if (n.exposing.len > 0) {
                const iface_opt = if (g.imported_modules) |im| im.get(alias) else null;
                for (n.exposing) |exp_name| {
                    if (!std.mem.eql(u8, exp_name, alias)) {
                        try g.writeIndent();
                        try g.w.print("const {s} = {s}.{s};\n", .{ exp_name, alias, exp_name });
                    }
                    // Track exposed union/class names for correct construction emit.
                    if (iface_opt) |iface| {
                        if (iface.types.getPtr(exp_name)) |kind_ptr| {
                            switch (kind_ptr.*) {
                                .union_  => try g.exposed_unions.put(exp_name, alias),
                                .class   => {
                                    try g.exposed_classes.put(exp_name, {});
                                    try g.class_names.put(exp_name, {});  // reference type
                                },
                                .struct_, .enum_ => try g.exposed_classes.put(exp_name, {}),
                            }
                        }
                    }
                }
            }
        }
    }

    // ── namespace ─────────────────────────────────────────────────────────────

    fn genNamespace(g: Generator, n: *Ast.DeclNamespace) anyerror!void {
        try g.writeIndent();
        try g.w.print("pub const {s} = struct {{\n", .{n.name});
        const ig = g.indented();
        for (n.decls) |decl| try ig.genTopDecl(decl);
        try g.writeIndent();
        try g.w.writeAll("};\n\n");
    }

    // ── class ─────────────────────────────────────────────────────────────────

    // ── C export helpers ──────────────────────────────────────────────────────

    /// True if `tr` maps to a plain C primitive (no slices, generics, optionals).
    fn isCExportable(tr: Ast.TypeRef) bool {
        return switch (tr) {
            .void_  => true,
            .named  => |n| std.StaticStringMap(void).initComptime(&.{
                .{ "int",     {} }, .{ "uint",    {} }, .{ "float",   {} },
                .{ "bool",    {} }, .{ "char",    {} },
                .{ "int8",    {} }, .{ "int16",   {} }, .{ "int32",   {} }, .{ "int64",   {} },
                .{ "uint8",   {} }, .{ "uint16",  {} }, .{ "uint32",  {} }, .{ "uint64",  {} },
                .{ "float32", {} }, .{ "float64", {} },
            }).has(n.name),
            else    => false,
        };
    }

    /// True if a `shared def` method can be exported with C linkage.
    /// Requirements: shared, no throws, body present, all param/return types
    /// are C-compatible primitives.
    fn isMethodCExportable(n: *const Ast.DeclMethod) bool {
        if (!n.mods.static_) return false;
        if (n.throws) return false;
        if (n.body == null) return false;
        for (n.params) |p| {
            const tr = p.type_ orelse return false;
            if (!isCExportable(tr)) return false;
        }
        if (n.return_type) |rt| if (!isCExportable(rt)) return false;
        return true;
    }

    /// Emit file-scope `export fn OwnerName_methodName(...)` wrappers for all
    /// eligible shared methods in `members`.  Updates `has_exports_ptr` when any
    /// wrapper is emitted.
    fn genExportWrappers(g: Generator, owner_name: []const u8, members: []const Ast.Decl) anyerror!void {
        if (!g.emit_exports) return;
        for (members) |decl| {
            const n = switch (decl) { .method => |m| m, else => continue };
            if (!isMethodCExportable(n)) continue;

            const returns_void = n.return_type == null or n.return_type.? == .void_;
            try g.w.print("export fn {s}_{s}(", .{ owner_name, n.name });
            for (n.params, 0..) |p, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.w.print("{s}: ", .{p.name});
                try g.genType(p.type_.?);
            }
            try g.w.writeAll(") ");
            if (n.return_type) |rt| try g.genType(rt) else try g.w.writeAll("void");
            try g.w.print(" {{ {s}{s}.{s}(", .{
                if (returns_void) "" else "return ",
                owner_name,
                n.name,
            });
            for (n.params, 0..) |p, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.w.writeAll(p.name);
            }
            try g.w.writeAll("); }\n");
            if (g.has_exports_ptr) |p| p.* = true;
        }
    }

    /// Emit a generic class as a Zig comptime function.
    ///
    /// `class Stack(T)` →
    ///   pub fn Stack(comptime T: type) type { return struct { … }; }
    ///   const _ttag_Stack: u64 = <hash>;
    ///
    /// Inside the returned struct:
    ///   - `init(…)` returns `@This()` and uses `var self: @This() = undefined`
    ///   - instance methods use `self: *@This()`
    ///   - `_type_tag` defaults to `_ttag_Stack` (module-scope const, always accessible)
    fn genGenericClass(g: Generator, n: *Ast.DeclClass) anyerror!void {
        try g.writeIndent();
        // Emit comptime function signature: pub fn Stack(comptime T: type, ...) type {
        try g.w.print("pub fn {s}(", .{n.name});
        for (n.type_params, 0..) |tp, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.w.print("comptime {s}: type", .{tp.name});
        }
        try g.w.writeAll(") type {\n");

        const fg = g.indented();
        try fg.writeIndent();
        try fg.w.writeAll("return struct {\n");

        // Inner generator: owner = class name, is_generic = true
        const ig = fg.indented().withOwner(n.name).withGeneric(n);

        // ① Type-tag field (references module-scope _ttag_ClassName constant).
        try ig.writeIndent();
        try ig.w.print("_type_tag: u64 = _ttag_{s},\n", .{n.name});

        // ② Regular members (fields, methods, init).
        for (n.members) |decl| try ig.genMember(decl);

        // ③ Synthetic default init if no explicit cue init.
        {
            var has_init = false;
            for (n.members) |m| { if (m == .init) { has_init = true; break; } }
            if (!has_init) {
                try ig.writeIndent();
                try ig.w.writeAll("pub fn init() @This() {\n");
                const dig = ig.indented();
                try dig.writeIndent();
                try dig.w.writeAll("var self: @This() = undefined;\n");
                try dig.writeIndent();
                try dig.w.print("self._type_tag = _ttag_{s};\n", .{n.name});
                try dig.writeIndent();
                try dig.w.writeAll("return self;\n");
                try ig.writeIndent();
                try ig.w.writeAll("}\n\n");
            }
        }

        // ④ Invariant checker — same as non-generic path.
        if (n.invariants.len > 0 and !g.strip_contracts) try ig.genInvariantCheckFn();

        // ⑤ Interface conformance checks — same as non-generic path.
        if (n.implements.len > 0) {
            try ig.w.writeAll("\n");
            try ig.writeIndent();
            try ig.w.writeAll("comptime {\n");
            const cig = ig.indented();
            for (n.implements) |tr| {
                const iname = typeRefSimpleName(tr) orelse continue;
                try cig.writeIndent();
                try cig.w.print("{s}.check(@This());\n", .{iname});
            }
            try ig.writeIndent();
            try ig.w.writeAll("}\n");
        }

        try fg.writeIndent();
        try fg.w.writeAll("};\n");
        try g.writeIndent();
        try g.w.writeAll("}\n\n");

        // Type-tag constant — same as for non-generic classes: low 32 bits = class hash.
        // High 32 bits stay 0 until Phase 3 (is Stack(int) checks).
        try g.w.print("const _ttag_{s}: u64 = {d};\n\n", .{ n.name, @as(u64, zbr_hash_str(n.name)) });
    }

    fn genClass(g: Generator, n: *Ast.DeclClass) anyerror!void {
        if (n.type_params.len > 0) return g.genGenericClass(n);
        const cg = g.withClass(n);

        try g.writeIndent();
        try g.w.print("pub const {s} = struct {{\n", .{n.name});

        const ig = cg.indented();

        // ① Runtime type-tag field — enables `expr is TypeName` and
        //    `expr is TypeName(T)` checks.  Layout: bits[31:0] = class hash,
        //    bits[63:32] = type-arg combined hash (0 for non-generic classes).
        //    The constant `_ttag_ClassName` is emitted after the struct.
        try ig.writeIndent();
        try ig.w.print("_type_tag: u64 = _ttag_{s},\n", .{n.name});

        // ② Inline mixin members before class members (fields first in Zig
        //    struct layout).
        for (n.adds) |tr| {
            const mname = typeRefSimpleName(tr) orelse continue;
            if (g.mixins.get(mname)) |mx| {
                try ig.writeIndent();
                try ig.w.print("// mixin: {s}\n", .{mname});
                for (mx.members) |decl| try ig.genMember(decl);
            }
        }

        // ② Regular class members.
        for (n.members) |decl| try ig.genMember(decl);

        // ③ Synthetic default init — emitted when no explicit `cue init` is present.
        //    Without this, a class constructed via `ClassName{}` relies on the field
        //    default for `_type_tag`, which is fragile.  With this, every class
        //    always has a clearly-defined `init()` path that explicitly stamps the
        //    type-tag field regardless of how the struct was allocated.
        {
            var has_init = false;
            for (n.members) |m| {
                if (m == .init) { has_init = true; break; }
            }
            if (!has_init) {
                outer: for (n.adds) |tr| {
                    const mname = typeRefSimpleName(tr) orelse continue;
                    if (g.mixins.get(mname)) |mx| {
                        for (mx.members) |m| {
                            if (m == .init) { has_init = true; break :outer; }
                        }
                    }
                }
            }
            if (!has_init) {
                try ig.writeIndent();
                try ig.w.print("pub fn init() *{s} {{\n", .{n.name});
                const dig = ig.indented();
                try dig.writeIndent();
                try dig.w.print("const self = _allocator.create({s}) catch @panic(\"OOM\");\n", .{n.name});
                try dig.writeIndent();
                try dig.w.writeAll("self.* = .{};\n");
                try dig.writeIndent();
                try dig.w.print("self._type_tag = _ttag_{s};\n", .{n.name});
                try dig.writeIndent();
                try dig.w.writeAll("return self;\n");
                try ig.writeIndent();
                try ig.w.writeAll("}\n\n");
            }
        }

        // ⑤ Invariant checker — private fn called at end of init and exit of instance methods.
        if (n.invariants.len > 0 and !g.strip_contracts) try ig.genInvariantCheckFn();

        // ④ Interface conformance checks.
        //    `class Foo implements IBar` → `comptime { IBar.check(@This()); }`
        if (n.implements.len > 0) {
            try ig.w.writeAll("\n");
            try ig.writeIndent();
            try ig.w.writeAll("comptime {\n");
            const cig = ig.indented();
            for (n.implements) |tr| {
                const iname = typeRefSimpleName(tr) orelse continue;
                try cig.writeIndent();
                try cig.w.print("{s}.check(@This());\n", .{iname});
            }
            try ig.writeIndent();
            try ig.w.writeAll("}\n");
        }

        try g.writeIndent();
        try g.w.writeAll("};\n\n");

        // ④ Tier-1 reflection: emit per-class const arrays for field names and types.
        //    Linker dead-strips these if nothing references them (zero cost when unused).
        {
            var field_names = std.ArrayListUnmanaged([]const u8){};
            defer field_names.deinit(g.alloc);
            var field_types = std.ArrayListUnmanaged([]const u8){};

            for (n.members) |decl| {
                const v = switch (decl) { .var_ => |v| v, else => continue };
                if (v.mods.static_) continue;
                try field_names.append(g.alloc, v.name);
                const ts: []const u8 = if (v.type_) |tr|
                    try typeRefStr(tr, g.alloc)
                else
                    try g.alloc.dupe(u8, "unknown");
                try field_types.append(g.alloc, ts);
            }
            defer { for (field_types.items) |s| g.alloc.free(s); field_types.deinit(g.alloc); }

            // Type-tag constant — class hash in the low 32 bits, type-arg hash
            // in the high 32 bits (always 0 for non-generic classes).
            // The u64 layout means `is Dog` checks `._type_tag == _ttag_Dog`
            // with no masking needed for non-generic types.
            try g.w.print("const _ttag_{s}: u64 = {d};\n", .{ n.name, @as(u64, zbr_hash_str(n.name)) });
            try g.w.print("const _reflect_{s}_name: []const u8 = \"{s}\";\n", .{ n.name, n.name });

            try g.w.print("const _reflect_{s}_fields: []const []const u8 = &.{{", .{n.name});
            for (field_names.items, 0..) |nm, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.w.print("\"{s}\"", .{nm});
            }
            try g.w.writeAll("};\n");

            try g.w.print("const _reflect_{s}_field_types: []const []const u8 = &.{{", .{n.name});
            for (field_types.items, 0..) |ts, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.w.print("\"{s}\"", .{ts});
            }
            try g.w.writeAll("};\n\n");
        }

        // Tier-3 reflection: `@reflectable class T` opts into Json.parseStrict.
        // Emit a per-class strict parser that returns `?*T`.
        if (n.mods.reflectable) {
            try g.genJsonParseStrictFn(n);
        }

        try g.genExportWrappers(n.name, n.members);
    }

    // ── Member dispatch ───────────────────────────────────────────────────────

    fn genMember(g: Generator, decl: Ast.Decl) anyerror!void {
        switch (decl) {
            .var_     => |n| try g.genFieldDecl(n),
            .method   => |n| try g.genMethod(n),
            .init     => |n| try g.genInit(n),
            else      => {},
        }
    }

    // ── Field declaration ─────────────────────────────────────────────────────

    fn genFieldDecl(g: Generator, n: *Ast.DeclVar) anyerror!void {
        try g.writeIndent();
        if (n.mods.static_) {
            // `shared var` → Zig namespace-level declaration inside the struct.
            // Accessed as StructName.field, not instance.field.
            const kw: []const u8 = if (n.mods.readonly or n.is_const) "const" else "var";
            // Stdlib constructor shorthand: `shared var x as List(T) = List()` or HashMap variant.
            // Must emit `std.ArrayList(T){}` / `std.StringHashMap(T).init(_allocator)`, not `List()`.
            if (n.init) |e| {
                if (n.type_) |tr| {
                    if (tr == .generic) {
                        const gtr = tr.generic;
                        if (e.* == .call and e.call.args.len == 0 and
                            e.call.callee.* == .ident and
                            std.mem.eql(u8, e.call.callee.ident.name, gtr.name))
                        {
                            try g.w.writeAll("pub ");
                            try g.w.writeAll(kw);
                            try g.w.writeAll(" ");
                            try g.w.writeAll(n.name);
                            try g.w.writeAll(": ");
                            try g.genType(tr);
                            try g.w.writeAll(" = ");
                            try g.genStdlibInit(gtr);
                            try g.w.writeAll(";\n");
                            return;
                        }
                    }
                }
            }
            try g.w.writeAll("pub ");
            try g.w.writeAll(kw);
            try g.w.writeAll(" ");
            try g.w.writeAll(n.name);
            if (n.type_) |tr| { try g.w.writeAll(": "); try g.genType(tr); }
            if (n.init) |e| { try g.w.writeAll(" = "); try g.genExpr(e); }
            else try g.w.writeAll(" = undefined");
            try g.w.writeAll(";\n");
        } else {
            try g.w.writeAll(n.name);
            try g.w.writeAll(": ");
            // StringBuilder as struct field: emit the concrete type and default to empty.
            if (n.type_) |tr| {
                if (tr == .named and std.mem.eql(u8, tr.named.name, "StringBuilder")) {
                    try g.w.writeAll("std.ArrayList(u8) = .{}");
                    try g.w.writeAll(",\n");
                    return;
                }
                try g.genType(tr);
            } else try g.w.writeAll("anytype");
            if (n.init) |e| { try g.w.writeAll(" = "); try g.genExpr(e); }
            else try g.w.writeAll(" = undefined");
            try g.w.writeAll(",\n");
        }
    }

    // ── interface ─────────────────────────────────────────────────────────────
    //
    // Emits a fat-pointer vtable struct:
    //
    //   pub const IFoo = struct {
    //       ptr:    *anyopaque,
    //       vtable: *const VTable,
    //
    //       pub const VTable = struct {
    //           method: *const fn (ptr: *anyopaque, <params>) <ret>,
    //       };
    //
    //       pub fn method(self: @This(), <params>) <ret> {
    //           return self.vtable.method(self.ptr, <args>);
    //       }
    //
    //       pub fn check(comptime T: type) void {
    //           comptime { if (!@hasDecl(T, "method")) @compileError(...); }
    //       }
    //   };
    //
    // `class Foo implements IFoo` sites call `IFoo.check(@This())` inside
    // a `comptime` block for compile-time conformance verification.

    fn genInterface(g: Generator, n: *Ast.DeclInterface) anyerror!void {
        const ig = g.indented();
        const vtig = ig.indented();
        const mig = ig.indented();  // method body indent

        // ── struct header ──────────────────────────────────────────────────
        try g.writeIndent();
        try g.w.print("pub const {s} = struct {{\n", .{n.name});

        // ── fat-pointer fields ─────────────────────────────────────────────
        try ig.writeIndent();
        try ig.w.writeAll("ptr:    *anyopaque,\n");
        try ig.writeIndent();
        try ig.w.writeAll("vtable: *const VTable,\n\n");

        // ── VTable inner struct ────────────────────────────────────────────
        try ig.writeIndent();
        try ig.w.writeAll("pub const VTable = struct {\n");
        for (n.members) |m| {
            const meth = switch (m) { .method => |x| x, else => continue };
            try vtig.writeIndent();
            try vtig.w.print("{s}: *const fn (ptr: *anyopaque", .{meth.name});
            for (meth.params) |p| {
                try vtig.w.writeAll(", ");
                try vtig.w.print("{s}: ", .{p.name});
                if (p.type_) |tr| try g.genType(tr) else try vtig.w.writeAll("anytype");
            }
            try vtig.w.writeAll(") ");
            if (meth.throws) try vtig.w.writeAll("anyerror!");
            if (meth.return_type) |rt| try g.genType(rt) else try vtig.w.writeAll("void");
            try vtig.w.writeAll(",\n");
        }
        try ig.writeIndent();
        try ig.w.writeAll("};\n");

        // ── forwarding methods ─────────────────────────────────────────────
        for (n.members) |m| {
            const meth = switch (m) { .method => |x| x, else => continue };
            try ig.w.writeAll("\n");
            try ig.writeIndent();
            try ig.w.print("pub fn {s}(self: @This()", .{meth.name});
            for (meth.params) |p| {
                try ig.w.print(", {s}: ", .{p.name});
                if (p.type_) |tr| try g.genType(tr) else try ig.w.writeAll("anytype");
            }
            try ig.w.writeAll(") ");
            if (meth.throws) try ig.w.writeAll("anyerror!");
            if (meth.return_type) |rt| try g.genType(rt) else try ig.w.writeAll("void");
            try ig.w.writeAll(" {\n");
            try mig.writeIndent();
            if (meth.throws) try mig.w.writeAll("return try self.vtable.")
            else             try mig.w.writeAll("return self.vtable.");
            try mig.w.print("{s}(self.ptr", .{meth.name});
            for (meth.params) |p| try mig.w.print(", {s}", .{p.name});
            try mig.w.writeAll(");\n");
            try ig.writeIndent();
            try ig.w.writeAll("}\n");
        }

        // ── check() — comptime conformance verifier ────────────────────────
        try ig.w.writeAll("\n");
        try ig.writeIndent();
        try ig.w.writeAll("pub fn check(comptime T: type) void {\n");
        const cig = ig.indented();
        try cig.writeIndent();
        try cig.w.writeAll("comptime {\n");
        const ccig = cig.indented();
        for (n.members) |m| {
            const mname: []const u8 = switch (m) { .method => |x| x.name, else => continue };
            try ccig.writeIndent();
            try ccig.w.print(
                "if (!@hasDecl(T, \"{s}\")) @compileError(" ++
                "\"type \" ++ @typeName(T) ++ \" does not implement {s}.{s}\");\n",
                .{ mname, n.name, mname },
            );
        }
        try cig.writeIndent();
        try cig.w.writeAll("}\n");
        try ig.writeIndent();
        try ig.w.writeAll("}\n");

        // ── struct footer ──────────────────────────────────────────────────
        try g.writeIndent();
        try g.w.writeAll("};\n\n");
    }

    // ── struct ────────────────────────────────────────────────────────────────

    fn genStruct(g: Generator, n: *Ast.DeclStruct) anyerror!void {
        const sg = g.withStruct(n);
        try g.writeIndent();
        try g.w.print("pub const {s} = struct {{\n", .{n.name});
        const ig = sg.indented();
        for (n.members) |decl| try ig.genMember(decl);
        if (n.invariants.len > 0 and !g.strip_contracts) try ig.genInvariantCheckFn();
        if (n.implements.len > 0) {
            try ig.w.writeAll("\n");
            try ig.writeIndent();
            try ig.w.writeAll("comptime {\n");
            const cig = ig.indented();
            for (n.implements) |tr| {
                const iname = typeRefSimpleName(tr) orelse continue;
                try cig.writeIndent();
                try cig.w.print("{s}.check(@This());\n", .{iname});
            }
            try ig.writeIndent();
            try ig.w.writeAll("}\n");
        }
        try g.writeIndent();
        try g.w.writeAll("};\n\n");
        try g.genExportWrappers(n.name, n.members);
    }

    // ── enum ──────────────────────────────────────────────────────────────────

    fn genEnum(g: Generator, n: *Ast.DeclEnum) anyerror!void {
        try g.writeIndent();
        try g.w.print("pub const {s} = enum", .{n.name});
        if (n.base) |base| {
            try g.w.writeAll("(");
            try g.genType(base);
            try g.w.writeAll(")");
        }
        try g.w.writeAll(" {\n");
        const ig = g.indented();
        for (n.members) |m| {
            try ig.writeIndent();
            try ig.w.writeAll(m.name);
            if (m.value) |v| {
                try ig.w.writeAll(" = ");
                try ig.genExpr(v);
            }
            try ig.w.writeAll(",\n");
        }
        try g.writeIndent();
        try g.w.writeAll("};\n\n");
    }

    // ── union ─────────────────────────────────────────────────────────────────

    fn genUnion(g: Generator, n: *Ast.DeclUnion) anyerror!void {
        // Emit a Zig tagged union: pub const Name = union(enum) { ... };
        // Top-level unions are always pub so cross-module users (via `use Module`) can
        // reference them as `Module.UnionName`.
        try g.writeIndent();
        try g.w.print("pub const {s} = union(enum) {{\n", .{n.name});
        const ig = g.indented();
        for (n.variants) |v| {
            try ig.writeIndent();
            if (v.payload) |pl| {
                try ig.w.print("{s}: ", .{v.name});
                try ig.genType(pl);
                try ig.w.writeAll(",\n");
            } else {
                try ig.w.print("{s},\n", .{v.name});
            }
        }
        try g.writeIndent();
        try g.w.writeAll("};\n\n");
    }

    // ── extend ────────────────────────────────────────────────────────────────

    fn genExtend(g: Generator, n: *Ast.DeclExtend) anyerror!void {
        const tname = typeRefSimpleName(n.target) orelse "Unknown";
        try g.writeIndent();
        try g.w.print("// extend {s}\n", .{tname});
        for (n.members) |decl| switch (decl) {
            .method => |m| try g.genExtMethod(tname, m),
            else    => {},
        };
        try g.w.writeAll("\n");
    }

    /// Emit a standalone Zig function for an extension method.
    ///
    /// `extend String\n    def words as List(str)` →
    /// `fn _ext_String_words(self: []const u8) !std.ArrayList([]const u8) { ... }`
    fn genExtMethod(g: Generator, tname: []const u8, m: *Ast.DeclMethod) anyerror!void {
        const mg = g.asMethod();
        // Compute the Zebra type of `self` so stdlib method calls on `this` dispatch correctly.
        const self_kind: TypeChecker.Type = blk: {
            const sk = Builtins.scalarKind(tname);
            break :blk switch (sk) {
                .int, .int_n  => .int,
                .uint, .uint_n => .uint,
                .float, .float_n => .float,
                .bool         => .bool,
                .char         => .char,
                .string       => .string,
                .void_        => .void_,
                .unknown      => .unknown,
            };
        };
        // The owner for `self.field` injection inside the body is still `tname`.
        const eg = mg.withOwner(tname).withExtSelf(self_kind);

        try g.writeIndent();
        try g.w.print("fn _ext_{s}_{s}(self: ", .{tname, m.name});
        // Self type: Zig value type for builtins, struct name for user types.
        const zig_self = Builtins.zigTypeName(tname);
        if (std.mem.eql(u8, zig_self, tname)) {
            // User-defined type — pass by value so we don't need & at call site.
            try g.w.writeAll(tname);
        } else {
            try g.w.writeAll(zig_self);
        }
        if (m.params.len > 0) try g.w.writeAll(", ");
        for (m.params, 0..) |p, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.w.writeAll(p.name);
            try g.w.writeAll(": ");
            if (p.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
        }
        try g.w.writeAll(") ");

        const needs_error = m.throws or (m.body != null and bodyHasRaise(m.body.?, g.tc));
        if (needs_error) try g.w.writeAll("anyerror!");
        if (m.return_type) |rt| try g.genType(rt) else try g.w.writeAll("void");

        if (m.body) |body| {
            var refs = try collectRefs(body, g.resolve, g.alloc);
            defer refs.deinit();
            var ret_set = try analyzeEscapes(body, g.alloc);
            defer ret_set.deinit();
            var cv_map = std.StringHashMap(void).init(g.alloc);
            defer cv_map.deinit();
            const bg = eg.indented().withClosureVars(&cv_map).withReturnedNames(&ret_set);
            try g.w.writeAll(" {\n");
            if (!refs.uses_self) try bg.line("_ = self;");
            for (m.params) |p| {
                if (!refs.param_names.contains(p.name)) {
                    try bg.writeIndent();
                    try bg.w.print("_ = {s};\n", .{p.name});
                }
            }
            try bg.genStmts(body);
            try g.writeIndent();
            try g.w.writeAll("}\n\n");
        } else {
            try g.w.writeAll(" { unreachable; // abstract\n}\n\n");
        }
    }

    // ── Top-level var / const ─────────────────────────────────────────────────

    fn genTopVar(g: Generator, n: *Ast.DeclVar) anyerror!void {
        try g.writeIndent();
        const kw: []const u8 = if (n.is_const) "const" else "var";
        try g.w.print("pub {s} {s}", .{ kw, n.name });
        if (n.type_) |tr| {
            try g.w.writeAll(": ");
            try g.genType(tr);
        }
        if (n.init) |e| {
            try g.w.writeAll(" = ");
            try g.genExpr(e);
        }
        try g.w.writeAll(";\n\n");
    }

    // ── method ────────────────────────────────────────────────────────────────

    // ── TCO detection ─────────────────────────────────────────────────────────

    /// Returns true if `v` is a tail-recursive call to `method_name`.
    ///
    /// Accepted patterns:
    ///   Instance methods: `method(args)` (bare call — Zebra natural style)
    ///   Shared methods:   `Owner.method(args)` (explicit class prefix)
    fn isTcoExpr(v: *const Ast.Expr, method_name: []const u8, owner: []const u8, shared: bool) bool {
        if (v.* != .call) return false;
        const callee = v.call.callee;
        if (shared) {
            // `Owner.method(args)` — explicit class-qualified call for shared methods.
            if (callee.* != .member) return false;
            const mem = callee.member;
            if (!std.mem.eql(u8, mem.member, method_name)) return false;
            if (mem.object.* != .ident) return false;
            return std.mem.eql(u8, mem.object.ident.name, owner);
        } else {
            // Bare `method(args)` — instance method calling itself.
            if (callee.* != .ident) return false;
            return std.mem.eql(u8, callee.ident.name, method_name);
        }
    }

    /// Recursively scans `stmts` for any `return` whose value is a direct tail
    /// call to `method_name` (see `isTcoExpr`).  Returns true on first match.
    /// Does NOT recurse into loop bodies — a `return` inside a loop breaks the
    /// loop, not the function, so it is never a function-level tail call.
    fn scanTco(stmts: []const Ast.Stmt, method_name: []const u8, owner: []const u8, shared: bool) bool {
        for (stmts) |stmt| switch (stmt) {
            .return_ => |s| {
                if (s.value) |v| if (isTcoExpr(v, method_name, owner, shared)) return true;
            },
            .if_ => |s| {
                if (scanTco(s.then_body, method_name, owner, shared)) return true;
                if (s.else_body) |eb| if (scanTco(eb, method_name, owner, shared)) return true;
            },
            .branch => |s| {
                for (s.on) |on| if (scanTco(on.body, method_name, owner, shared)) return true;
                if (s.else_) |eb| if (scanTco(eb, method_name, owner, shared)) return true;
            },
            else => {},
        };
        return false;
    }

    fn genMethod(g: Generator, n: *Ast.DeclMethod) anyerror!void {
        var mg = g.asMethod();

        try g.writeIndent();
        try g.w.print("pub fn {s}(", .{n.name});

        // Instance methods inside a type get `self: *Owner`.
        // `shared` methods (type-level, not instance) omit self.
        const has_self = g.owner.len > 0 and !n.mods.static_;

        // Pre-check: does this method have any tail-recursive calls?
        // If so, we use the loop-transformation (TCO) path.
        const is_tco = if (n.body) |body| n.params.len > 0 and
            scanTco(body, n.name, g.owner, n.mods.static_) else false;

        if (has_self) {
            // Generic class methods use *@This() (the struct is anonymous inside the comptime fn).
            if (g.is_generic) {
                try g.w.writeAll("self: *@This()");
            } else {
                try g.w.print("self: *{s}", .{g.owner});
            }
            if (n.params.len > 0) try g.w.writeAll(", ");
        }

        // In TCO mode params are renamed to `_p_<name>` so we can shadow them
        // with mutable `var <name> = _p_<name>;` locals inside the while loop.
        for (n.params, 0..) |p, i| {
            if (i > 0) try g.w.writeAll(", ");
            if (is_tco) try g.w.print("_p_{s}", .{p.name}) else try g.w.writeAll(p.name);
            try g.w.writeAll(": ");
            // BUG-091: List(T)/HashMap(K,V) params that are mutated in the body
            // emit as `*std.ArrayList(T)` so `.append` (which takes *Self) works
            // and the caller sees the changes.  TCO is excluded because the
            // params are shadowed by mutable locals there.
            const needs_addr_of = !is_tco and paramNeedsAddrOf(p, n.body, g.alloc, g.tc);
            if (needs_addr_of) try g.w.writeAll("*");
            if (p.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
        }
        try g.w.writeAll(") ");

        // Emit anyerror! if explicitly annotated OR if the body contains raise/try.
        const needs_error = n.throws or
            (n.body != null and bodyHasRaise(n.body.?, g.tc));
        mg.current_method_throws = needs_error;
        if (needs_error) try g.w.writeAll("anyerror!");
        if (n.return_type) |rt| try g.genType(rt) else try g.w.writeAll("void");

        if (n.body) |body| {
            // Pre-scan 1: which params / self are actually referenced?
            var refs = try collectRefs(body, g.resolve, g.alloc);
            defer refs.deinit();
            // Pre-scan 2: escape analysis — which string locals are returned?
            // Suppresses `defer _allocator.free` for strings whose ownership
            // transfers to the caller. Does NOT affect List/HashMap (no deinit emitted).
            var ret_set = try analyzeEscapes(body, g.alloc);
            defer ret_set.deinit();
            // Mutable map of closure-var names (populated lazily during genStmts)
            var cv_map = std.StringHashMap(void).init(g.alloc);
            defer cv_map.deinit();

            try g.w.writeAll(" {\n");

            // Invariant deferred exit check — public instance methods only.
            // Private helpers may temporarily break invariants; shared methods have no `self`.
            // Note: `defer` also runs on error exit paths — callers see the panic before
            // the original error.  Acceptable for v1; document for future errdefer refinement.
            if (has_self and !n.mods.static_ and !n.mods.private and g.owner_invariants.len > 0 and !g.strip_contracts) {
                try mg.indented().writeIndent();
                try mg.indented().w.writeAll("defer self._check_invariant();\n");
            }

            if (is_tco) {
                // TCO preamble: mutable shadow copies of params + `while (true)`.
                // The body generator uses one extra indent level for the loop body.
                const ig = mg.indented();
                for (n.params) |p| {
                    try ig.writeIndent();
                    try ig.w.print("var {s} = _p_{s};\n", .{ p.name, p.name });
                }
                try ig.writeIndent();
                try ig.w.writeAll("while (true) {\n");

                // Collect param names slice (lifetime: until end of this block).
                var tco_pnames: std.ArrayListUnmanaged([]const u8) = .{};
                defer tco_pnames.deinit(g.alloc);
                for (n.params) |p| try tco_pnames.append(g.alloc, p.name);

                const bg = ig.indented()
                    .withClosureVars(&cv_map).withReturnedNames(&ret_set)
                    .withTco(n.name, tco_pnames.items, n.mods.static_);
                // No param suppression needed — all params are used via `var p = _p_p;`.
                // Skip `_ = self` when invariant defer already references self.
                if (has_self and !refs.uses_self and (n.mods.private or g.owner_invariants.len == 0 or g.strip_contracts)) try bg.line("_ = self;");
                try bg.genRequireChecks(n.require, n.name);
                const ec_tco = try bg.genEnsureBlock(n.ensure, n.name, n.return_type);
                try bg.withEnsureCtx(ec_tco.armed, ec_tco.uses_result).genStmts(body);
                // Arm the ensure check for fall-off-the-end paths (void functions
                // with no explicit return).  Inside the TCO loop, this is reached
                // when the loop body completes without re-recursing.
                if (ec_tco.armed) {
                    try bg.indented().writeIndent();
                    try bg.indented().w.writeAll("_ensure_armed = true;\n");
                }

                // Close the while loop.
                try ig.writeIndent();
                try ig.w.writeAll("}\n");
            } else {
                const bg = mg.indented().withClosureVars(&cv_map).withReturnedNames(&ret_set);
                // Emit `_ = x;` only for params that are NOT referenced in the body.
                // Skip when invariant defer already references self (avoids "pointless discard" in Zig 0.15).
                if (has_self and !refs.uses_self and (n.mods.private or g.owner_invariants.len == 0 or g.strip_contracts)) try bg.line("_ = self;");
                for (n.params) |p| {
                    if (!refs.param_names.contains(p.name)) {
                        try bg.writeIndent();
                        try bg.w.print("_ = {s};\n", .{p.name});
                    }
                }
                try bg.genRequireChecks(n.require, n.name);
                const ec = try bg.genEnsureBlock(n.ensure, n.name, n.return_type);
                try bg.withEnsureCtx(ec.armed, ec.uses_result).genStmts(body);
                // Arm the ensure check for fall-off-the-end paths (void functions
                // with no explicit return).  Idempotent for paths that already
                // armed via genReturn.
                if (ec.armed) {
                    try bg.writeIndent();
                    try bg.w.writeAll("_ensure_armed = true;\n");
                }
            }

            try g.writeIndent();
            try g.w.writeAll("}\n\n");
        } else {
            // Abstract method — emit a stub body.
            try g.w.writeAll(" {\n");
            try mg.indented().line("unreachable; // abstract");
            try g.writeIndent();
            try g.w.writeAll("}\n\n");
        }
    }

    // ── constructor ───────────────────────────────────────────────────────────

    fn genInit(g: Generator, n: *Ast.DeclInit) anyerror!void {
        const mg = g.asMethod();
        try g.writeIndent();
        try g.w.writeAll("pub fn init(");
        for (n.params, 0..) |p, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.w.writeAll(p.name);
            try g.w.writeAll(": ");
            if (p.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
        }
        // Generic class init returns @This() (the anonymous struct from the comptime fn).
        // Non-generic init returns the named owner type.
        // Classes (reference types) return a pointer (*ClassName); structs return by value.
        const self_type_name = if (g.is_generic) "@This()" else g.owner;
        if (g.is_struct_owner) {
            try g.w.print(") {s} {{\n", .{self_type_name});
        } else {
            try g.w.print(") *{s} {{\n", .{self_type_name});
        }
        const body = n.body orelse &[_]Ast.Stmt{};
        var refs = try collectRefs(body, g.resolve, g.alloc);
        defer refs.deinit();
        var cv_map = std.StringHashMap(void).init(g.alloc);
        defer cv_map.deinit();
        const bg = mg.indented().withClosureVars(&cv_map);
        try bg.writeIndent();
        if (g.is_struct_owner) {
            try bg.w.print("var self: {s} = undefined;\n", .{self_type_name});
        } else {
            // Classes: heap-allocate on the arena so every instance is accessed
            // through a pointer.  Assignment copies the pointer (aliasing), not the
            // struct value — this is the standard OO reference-semantics model.
            try bg.w.print("const self = _allocator.create({s}) catch @panic(\"OOM\");\n", .{self_type_name});
        }
        // Initialise the type-ID field so `expr is TypeName` works correctly.
        // Structs do NOT have a _type_tag field — skip for those.
        if (!g.is_struct_owner) {
            try bg.writeIndent();
            try bg.w.print("self._type_tag = _ttag_{s};\n", .{g.owner});
        }
        for (n.params) |p| {
            if (!refs.param_names.contains(p.name)) {
                try bg.writeIndent();
                try bg.w.print("_ = {s};\n", .{p.name});
            }
        }
        try bg.genRequireChecks(n.require, "init");
        // init has no user-visible `return EXPR` — the trailing `return self;` is implicit.
        // Pass null return_type so any `result` reference is statically rejected.
        const ec_init = try bg.genEnsureBlock(n.ensure, "init", null);
        try bg.genStmts(body);
        if (g.owner_invariants.len > 0 and !g.strip_contracts) {
            try bg.writeIndent();
            try bg.w.writeAll("self._check_invariant();\n");
        }
        if (ec_init.armed) {
            try bg.writeIndent();
            try bg.w.writeAll("_ensure_armed = true;\n");
        }
        try bg.writeIndent();
        try bg.w.writeAll("return self;\n");
        try g.writeIndent();
        try g.w.writeAll("}\n\n");
    }

    // ── Statements ────────────────────────────────────────────────────────────

    fn genStmts(g: Generator, stmts: []const Ast.Stmt) anyerror!void {
        var block_mut = try scanMutations(stmts, g.alloc, g.tc);
        defer block_mut.deinit();
        // BUG-091: idents passed as `&` to mutating-container params must be
        // declared `var`, otherwise `&items` is `*const ArrayList`.
        try addAddrOfMutationsInStmts(stmts, &block_mut, g.alloc, g.tc, g.resolve);
        const bg = g.withMutated(&block_mut);
        for (stmts) |stmt| try bg.genStmt(stmt);
    }

    /// Extract the source span from any Stmt variant.
    /// Returns null for void-payload variants (pass, break_, continue_, contract).
    fn stmtSpan(stmt: Ast.Stmt) ?Ast.Span {
        return switch (stmt) {
            .var_          => |n| n.span,
            .assign        => |s| s.span,
            .return_       => |s| s.span,
            .if_           => |s| s.span,
            .while_        => |s| s.span,
            .for_in        => |s| s.span,
            .for_num       => |s| s.span,
            .branch        => |s| s.span,
            .print         => |s| s.span,
            .assert        => |s| s.span,
            .yield         => |s| s.span,
            .expr          => |e| exprSpan(e),
            .defer_        => |s| s.span,
            .with          => |s| s.span,
            .var_except    => |s| s.span,
            .assign_except => |s| s.span,
            .raise         => |s| s.span,
            .try_catch     => |s| s.span,
            .guard         => |s| s.span,
            .destruct      => |s| s.span,
            .arena_scope   => |s| s.span,
            .pass, .break_, .continue_, .contract => null,
        };
    }

    /// Extract the source span from any Expr variant.
    fn exprSpan(e: *const Ast.Expr) ?Ast.Span {
        return switch (e.*) {
            .int_lit       => |x| x.span,
            .float_lit     => |x| x.span,
            .bool_lit      => |x| x.span,
            .char_lit      => |x| x.span,
            .string_lit    => |x| x.span,
            .string_interp => |x| x.span,
            .nil           => |s| s,
            .this          => |s| s,
            .ident         => |x| x.span,
            .zig_lit       => |x| x.span,
            .member        => |x| x.span,
            .call          => |x| x.span,
            .index         => |x| x.span,
            .slice         => |x| x.span,
            .binary        => |x| x.span,
            .unary         => |x| x.span,
            .cast          => |x| x.span,
            .to_nilable    => |x| x.span,
            .to_non_nil    => |x| x.span,
            .is_nil        => |x| x.span,
            .orelse_       => |x| x.span,
            .catch_        => |x| x.span,
            .if_expr       => |x| x.span,
            .lambda        => |x| x.span,
            .list_lit      => |x| x.span,
            .dict_lit      => |x| x.span,
            .array_lit     => |x| x.span,
            .old           => |x| x.span,
            .result_       => |x| x.span,
            .try_          => |x| x.span,
            .tuple_lit     => |x| x.span,
            .type_check    => |x| x.span,
        };
    }

    fn genStmt(g: Generator, stmt: Ast.Stmt) anyerror!void {
        // Emit source-map marker so Zig compiler errors can be remapped
        // to the originating Zebra file and line by main.zig.
        if (g.source_file.len > 0) {
            if (stmtSpan(stmt)) |sp| {
                try g.w.print("// zbr:{s}:{d}\n", .{ g.source_file, sp.line });
            }
        }
        switch (stmt) {
            .var_      => |n| try g.genLocalVar(n),
            .assign    => |s| try g.genAssign(s),
            .return_   => |s| try g.genReturn(s),
            .if_       => |s| try g.genIf(s),
            .while_    => |s| try g.genWhile(s),
            .for_in    => |s| try g.genForIn(s),
            .for_num   => |s| try g.genForNum(s),
            .branch    => |s| try g.genBranch(s),
            .print     => |s| try g.genPrint(s),
            .assert    => |s| try g.genAssert(s),
            .yield     => |s| {
                try g.writeIndent();
                try g.w.writeAll("// yield ");
                try g.genExpr(s.value);
                try g.w.writeAll(";\n");
            },
            .expr      => |e| {
                // GUI widget calls with allocating string args need block-scoped temps.
                if (try g.genGuiWidgetStmt(e)) return;
                // BUG-027 fix (statement-position): hoist `f().method(args)` to avoid
                // Zig's *const temporary slot. `var _mc_N = f(); _mc_N.method(args);`
                if (e.* == .call) {
                    const call = e.call;
                    if (call.callee.* == .member) {
                        const mem = call.callee.member;
                        if (mem.object.* == .call) {
                            const uid = g.nextUid();
                            const is_throws = exprCallIsThrows(call, g.resolve, g.imported_modules, g.owner_members, g.tc);
                            try g.writeIndent();
                            try g.w.print("var _mc_{x} = ", .{uid});
                            try g.genExpr(mem.object);
                            try g.w.writeAll(";\n");
                            try g.writeIndent();
                            if (is_throws and g.current_method_throws and g.try_block_label == null and !g.suppress_auto_try) {
                                try g.w.writeAll("try ");
                            }
                            try g.w.print("_mc_{x}.{s}(", .{ uid, mem.member });
                            try g.genArgs(g.lookupParams(call), g.lookupCalleeBody(call), call.args);
                            try g.w.writeAll(")");
                            if (g.try_block_label) |lbl| {
                                if (is_throws) {
                                    const ev = g.try_err_var.?;
                                    try g.w.print(" catch |_e| {{ {s} = _e; break :{s}; }}", .{ ev, lbl });
                                }
                            }
                            try g.w.writeAll(";\n");
                            return;
                        }
                    }
                }
                try g.writeIndent();
                try g.genExpr(e);
                // Inside a try block, a call to a `throws` method must have its
                // error captured and redirected to the block's tracking variable.
                if (e.* == .call and g.try_block_label != null and
                    exprCallIsThrows(e.call, g.resolve, g.imported_modules, g.owner_members, g.tc))
                {
                    const ev  = g.try_err_var.?;
                    const lbl = g.try_block_label.?;
                    try g.w.print(" catch |_e| {{ {s} = _e; break :{s}; }}", .{ev, lbl});
                }
                // zig"stmt;" already ends with ';' — don't append another one.
                // genZigLit emits text[4..len-1] (strips zig"..."), so check that slice.
                const already_semi = blk: {
                    if (e.* != .zig_lit) break :blk false;
                    const raw = e.zig_lit.text;
                    if (raw.len < 5) break :blk false;
                    const content = std.mem.trimRight(u8, raw[4 .. raw.len - 1], " \t\r\n");
                    break :blk content.len > 0 and content[content.len - 1] == ';';
                };
                if (!already_semi) try g.w.writeAll(";");
                try g.w.writeAll("\n");
            },
            .pass      => try g.line("// pass"),
            .break_    => if (g.for_else_label) |lbl| {
                try g.writeIndent();
                try g.w.print("break :{s} false;\n", .{lbl});
            } else try g.line("break;"),
            .continue_ => try g.line("continue;"),
            .defer_    => |s| try g.genDefer(s),
            .contract  => {}, // contracts not emitted (runtime verification out of scope)
            .with        => |s| try g.genWith(s),
            .arena_scope => |s| try g.genArenaScope(s),
            .var_except    => |s| try g.genVarExcept(s),
            .assign_except => |s| try g.genAssignExcept(s),
            .raise         => |s| try g.genRaise(s),
            .try_catch     => |s| try g.genTryCatch(s),
            .guard         => |s| try g.genGuard(s),
            .destruct      => |s| try g.genDestruct(s),
        }
    }

    fn genDestruct(g: Generator, s: *Ast.StmtDestruct) anyerror!void {
        // Monotonic counter — avoids name collisions when multiple destructurings
        // appear in the same scope, and keeps emitted Zig deterministic.
        const uid = g.nextUid();
        try g.writeIndent();
        try g.w.print("const _dt_{x} = ", .{uid});
        try g.genExpr(s.init);
        try g.w.writeAll(";\n");
        switch (s.kind) {
            .tuple => {
                // var (x, y) = expr  →  const x = _dt_N.@"0"; const y = _dt_N.@"1";
                for (s.names, 0..) |name, i| {
                    try g.writeIndent();
                    try g.w.print("const {s} = _dt_{x}.@\"{d}\";\n", .{ name, uid, i });
                }
            },
            .struct_ => {
                // var {name, age} = expr  →  const name = _dt_N.name; const age = _dt_N.age;
                for (s.names) |name| {
                    try g.writeIndent();
                    try g.w.print("const {s} = _dt_{x}.{s};\n", .{ name, uid, name });
                }
            },
        }
    }

    fn genLocalVar(g: Generator, n: *Ast.DeclVar) anyerror!void {
        try g.writeIndent();
        // Use `const` unless the variable is actually reassigned somewhere in
        // the body (Zig treats `var` that is never mutated as a compile error).
        const is_mutated = if (g.mutated) |m| m.contains(n.name) else false;
        // User-defined type instances and cross-module instances must be `var`
        // even when not reassigned, because their methods take `*Self` receivers.
        // Zig rejects calling a `*Self` method on a `*const Self`.
        const tc_init_type: TypeChecker.Type = blk: {
            if (n.init) |init| if (g.tc) |tc| break :blk tc.expr_types.get(init) orelse .unknown;
            break :blk .unknown;
        };
        // Cross-module instances are handled by scanMutationsInExpr (which conservatively
        // marks any receiver of a method call as mutated when TC type is .cross_module).
        // timer_handle is opaque with always-mutable state — force var unconditionally.
        const needs_var_for_methods = (tc_init_type == .timer_handle);
        const kw: []const u8 = if (n.is_const or (!is_mutated and !needs_var_for_methods)) "const" else "var";

        // StringBuilder constructor:
        //   annotated form: `var sb as StringBuilder = StringBuilder()`
        //   inferred form:  `var sb = StringBuilder()`  (no type annotation)
        if (n.init) |e| {
            const is_sb_ctor = e.* == .call and e.call.args.len == 0 and
                e.call.callee.* == .ident and
                std.mem.eql(u8, e.call.callee.ident.name, "StringBuilder");
            const has_sb_type = if (n.type_) |tr|
                tr == .named and std.mem.eql(u8, tr.named.name, "StringBuilder")
            else
                is_sb_ctor; // infer StringBuilder type from the constructor call alone
            if (has_sb_type and is_sb_ctor) {
                // Always var: ArrayList.appendSlice takes *Self.
                try g.w.print("var {s} = std.ArrayList(u8){{}};\n", .{n.name});
                try g.writeIndent();
                try g.w.print("defer {s}.deinit(_allocator);\n", .{n.name});
                return;
            }
        }
        // Stdlib constructor: `var x as List(T) = List()` or `HashMap(K,V) = HashMap()`
        if (n.init) |e| {
            if (n.type_) |tr| {
                if (tr == .generic) {
                    const gtr = tr.generic;
                    // Check if init is a zero-arg call to the same type name
                    if (e.* == .call and e.call.args.len == 0 and
                        e.call.callee.* == .ident and
                        std.mem.eql(u8, e.call.callee.ident.name, gtr.name))
                    {
                        try g.w.writeAll(kw);
                        try g.w.writeAll(" ");
                        try g.w.writeAll(n.name);
                        try g.w.writeAll(" = ");
                        try g.genStdlibInit(gtr);
                        try g.w.writeAll(";\n");
                        // No defer deinit: all Zebra programs use an arena allocator.
                        // Individual deinit calls are unnecessary (the arena frees everything
                        // at once) and harmful: Allocator.free poisons the buffer with 0xAA
                        // before rawFree, corrupting any struct that still holds a pointer to
                        // the same buffer (e.g. a List passed into a PBinary constructor).
                        return;
                    }
                }
            }
        }
        // `var x: List(T) = []` (or `var x: List(T) = [a, b, c]`) — the LHS
        // annotation provides the element type that the literal's expression-
        // position emit can't see on its own.
        if (n.init) |e| {
            if (n.type_) |tr| {
                if (tr == .generic and std.mem.eql(u8, tr.generic.name, "List") and e.* == .list_lit) {
                    try g.w.writeAll(kw);
                    try g.w.writeAll(" ");
                    try g.w.writeAll(n.name);
                    try g.w.writeAll(": ");
                    try g.genType(tr);
                    try g.w.writeAll(" = ");
                    try g.genType(tr);
                    try g.w.writeAll("{};\n");
                    for (e.list_lit.elems) |el| {
                        try g.writeIndent();
                        try g.w.print("{s}.append(_allocator, ", .{n.name});
                        try g.genExpr(el);
                        try g.w.writeAll(") catch @panic(\"OOM\");\n");
                    }
                    return;
                }
            }
        }
        // BUG-092: `var lines: List(str) = s.split(sep)` / `s.lines()` —
        // materialise the SplitIterator into a fresh ArrayList.  Without
        // this, the LHS is annotated `std.ArrayList([]const u8)` but the
        // RHS is `splitSequence(...)`, producing a Zig type mismatch.
        if (n.init) |e| {
            if (n.type_) |tr| {
                if (tr == .generic and std.mem.eql(u8, tr.generic.name, "List") and
                    e.* == .call and e.call.callee.* == .member)
                {
                    const meth = e.call.callee.member.member;
                    if (std.mem.eql(u8, meth, "split") or std.mem.eql(u8, meth, "lines")) {
                        const uid = g.nextUid();
                        try g.w.print("var {s}: ", .{n.name});
                        try g.genType(tr);
                        try g.w.writeAll(" = ");
                        try g.genStdlibInit(tr.generic);
                        try g.w.writeAll(";\n");
                        try g.writeIndent();
                        try g.w.print("{{ var _split_iter_{x} = ", .{uid});
                        try g.genExpr(e);
                        try g.w.print("; while (_split_iter_{x}.next()) |_se_{x}| {{ {s}.append(_allocator, _se_{x}) catch @panic(\"OOM\"); }} }}\n", .{ uid, uid, n.name, uid });
                        return;
                    }
                }
            }
        }

        // Lambda with a capture block — emit as a struct instance, not a fn ptr.
        // Register the name so call sites use `name.call(args)`.
        if (n.init) |e| {
            if (e.* == .lambda and e.lambda.capture.len > 0) {
                if (g.closure_vars) |cv| try cv.put(n.name, {});
                // The struct variable itself uses the normal const/var analysis.
                // Mutable captures are handled via `self: *@This()` in the call method,
                // and _gui_run/_http_serve make a `var _mframe = frame` copy internally.
                try g.w.writeAll(kw);
                try g.w.writeAll(" ");
                try g.w.writeAll(n.name);
                try g.w.writeAll(" = ");
                try g.genCaptureClosureStruct(e.lambda);
                try g.w.writeAll(";\n");
                return;
            }
        }

        // Mutable fn-ref vars: Zig requires `*const fn(P) R` type — you cannot have
        // a `var` of bare function type.  Emit `var name: @TypeOf(&func) = &func;`.
        if (std.mem.eql(u8, kw, "var") and tc_init_type == .fn_ref) {
            if (n.init) |e| {
                if (e.* == .ident) {
                    const fname = e.ident.name;
                    try g.w.print("var {s}: @TypeOf(&{s}) = &{s};\n", .{ n.name, fname, fname });
                    return;
                }
            }
        }

        try g.w.writeAll(kw);
        try g.w.writeAll(" ");
        try g.w.writeAll(n.name);
        if (n.type_) |tr| {
            try g.w.writeAll(": ");
            try g.genType(tr);
        } else if (std.mem.eql(u8, kw, "var")) {
            // Mutable var without explicit type: emit TC-inferred type annotation
            // to avoid "comptime_int / *const [N:0]u8 / comptime_float must be
            // const" errors in Zig and to prevent slice-vs-array type mismatches.
            if (n.init) |e| {
                if (g.tc) |tc| {
                    const t = tc.expr_types.get(e) orelse .unknown;
                    if (try tcTypeAnnotation(t, g.alloc)) |ann| {
                        defer g.alloc.free(ann);
                        try g.w.writeAll(": ");
                        try g.w.writeAll(ann);
                    }
                }
            }
        }
        if (n.init) |e| {
            try g.w.writeAll(" = ");
            // fn_ref init into a sig-typed var: `var pred as CharPred = isAlpha`
            // → emit `&isAlpha` so Zig gets a function pointer.
            if (tc_init_type == .fn_ref and n.type_ != null) {
                try g.w.writeAll("&");
            }
            try g.genExpr(e);
            // Inside a try/catch block, if the initializer is a call to a `throws` method
            // (including cross-module calls like `Lexer.tokenize(...)`), redirect the error
            // to the block's tracking variable so the catch clause fires.
            if (e.* == .call and g.try_block_label != null and
                exprCallIsThrows(e.call, g.resolve, g.imported_modules, g.owner_members, g.tc))
            {
                const ev  = g.try_err_var.?;
                const lbl = g.try_block_label.?;
                try g.w.print(" catch |_e| {{ {s} = _e; break :{s}; }}", .{ ev, lbl });
            }
        } else {
            // For List(T) / HashMap(K,V) declared with no init expression, emit an
            // empty initializer instead of `undefined`.  `undefined` produces a
            // crash on the first `add`/`put` call because the ArrayList backing
            // pointer is garbage.  This is the "var decls as List(PNode)" pattern
            // used throughout the self-hosting parser.
            const is_empty_list_or_map: bool = blk: {
                if (n.type_) |tr| {
                    if (tr == .generic) {
                        const gn = tr.generic.name;
                        break :blk std.mem.eql(u8, gn, "List") or std.mem.eql(u8, gn, "HashMap");
                    }
                }
                break :blk false;
            };
            if (is_empty_list_or_map) {
                try g.w.writeAll(" = ");
                try g.genStdlibInit(n.type_.?.generic);
            } else {
                try g.w.writeAll(" = undefined");
            }
        }
        try g.w.writeAll(";\n");
        // No defer free for local string variables: Zebra uses ArenaAllocator, where
        // individual frees are either a no-op (middle allocation) or dangerous (last
        // allocation — Zig 0.15 rewinds end_index, corrupting any sub-slice still in use).
        // The arena frees all memory at program exit. For bounded-scope reclaim, use an
        // `arena` block, which creates a sub-arena that genuinely reclaims on exit.
    }

    /// True when `expr` is a call that allocates a heap-owned string.
    fn isAllocatingStringInit(e: *const Ast.Expr, tc_opt: ?*const TypeChecker.TypeCheckResult) bool {
        // String interpolation allocates via allocPrint.
        if (e.* == .string_interp) return true;
        if (e.* != .call) return false;
        const callee = e.call.callee;
        if (callee.* != .member) return false;
        const obj = callee.member.object;
        const m   = callee.member.member;
        // Methods that allocate a new string via _allocator.
        const str_allocating = std.StaticStringMap(void).initComptime(&.{
            .{ "concat",   {} }, .{ "format",   {} }, .{ "upper",    {} },
            .{ "lower",    {} }, .{ "replace",  {} }, .{ "repeat",   {} },
            .{ "toString", {} }, .{ "padLeft",  {} }, .{ "padRight", {} },
            .{ "center",   {} }, .{ "join",     {} }, .{ "reverse",  {} },
            .{ "toHex",    {} }, .{ "fromHex",  {} },
        });
        if (str_allocating.get(m) != null) {
            // Exclude regex/network method calls — they use page_allocator, not _allocator.
            if (tc_opt) |tc| {
                const recv = tc.expr_types.get(obj) orelse .unknown;
                if (recv == .regex or recv == .tcp_conn or recv == .udp_socket) return false;
            }
            return true;
        }
        // File.read allocates a string. File.readLines/listDir return a List — handled separately.
        if (obj.* == .ident and std.mem.eql(u8, obj.ident.name, "File")) {
            if (std.mem.eql(u8, m, "read")) return true;
        }
        // Shell.run allocates stdout+stderr via concat.
        if (obj.* == .ident and std.mem.eql(u8, obj.ident.name, "Shell")) {
            if (std.mem.eql(u8, m, "run")) return true;
        }
        // Extension method calls that return a string allocate via _allocator.
        if (tc_opt) |tc| {
            const obj_type = tc.expr_types.get(obj) orelse .unknown;
            const tname: ?[]const u8 = switch (obj_type) {
                .string => "String",
                .int    => "int",
                .uint   => "uint",
                .float  => "float",
                .bool   => "bool",
                .char   => "char",
                .named  => |sym| switch (sym.decl) {
                    .class     => |c| c.name,
                    .struct_   => |s| s.name,
                    .interface => |i| i.name,
                    else       => null,
                },
                else => null,
            };
            if (tname) |tn| {
                var buf: [256]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{s}.{s}", .{tn, m})) |key| {
                    if (tc.ext_methods.get(key)) |ext_meth| {
                        if (ext_meth.return_type) |*rt| {
                            const rname = switch (rt.*) {
                                .named => |n| n.name,
                                else   => "",
                            };
                            if (Builtins.isStringTypeName(rname)) return true;
                        }
                    }
                } else |_| {}
            }
        }
        return false;
    }

    // ── Stdlib type initialisation ────────────────────────────────────────────

    /// Emit the Zig init expression for a stdlib generic type.
    ///   List(int)       → std.ArrayList(i64){}   (Zig 0.15: unmanaged, alloc per-op)
    ///   HashMap(str, T) → std.StringHashMap(T).init(_allocator)
    ///   HashMap(K, V)   → std.AutoHashMap(K, V).init(_allocator)
    fn genStdlibInit(g: Generator, gtr: Ast.GenericTypeRef) anyerror!void {
        if (std.mem.eql(u8, gtr.name, "List")) {
            // Zig 0.15 ArrayList is unmanaged: initialise with {}
            try g.genType(.{ .generic = gtr });
            try g.w.writeAll("{}");
        } else {
            try g.genType(.{ .generic = gtr });
            try g.w.writeAll(".init(_allocator)");
        }
    }

    // ── Stdlib method / property dispatch ────────────────────────────────────
    //
    // Returns true and emits code if `method` on a value of type `tr` is a
    // known stdlib operation.  Returns false and emits nothing otherwise.

    /// Emit `@as(i64, @intCast(<object>.items.len))`.
    /// Single canonical site for all List.len / List.count emissions so
    /// the usize→i64 cast is never forgotten.
    fn writeListLen(g: Generator, object: *const Ast.Expr) anyerror!void {
        try g.w.writeAll("@as(i64, @intCast(");
        try g.genExpr(object);
        try g.w.writeAll(".items.len))");
    }

    fn genStdlibMethod(
        g:      Generator,
        object: *const Ast.Expr,
        tr:     Ast.TypeRef,
        method: []const u8,
        args:   []const Ast.Arg,
    ) anyerror!bool {
        switch (tr) {
            .generic => |gtr| {
                if (std.mem.eql(u8, gtr.name, "List")) {
                    const item_is_str = gtr.args.len >= 1 and isStringTypeRef(gtr.args[0]);
                    return g.genListMethod(object, item_is_str, method, args);
                }
                if (std.mem.eql(u8, gtr.name, "HashMap")) {
                    const key_is_str = gtr.args.len >= 1 and isStringTypeRef(gtr.args[0]);
                    const val_is_str = gtr.args.len >= 2 and isStringTypeRef(gtr.args[1]);
                    return g.genHashMapMethod(object, key_is_str, val_is_str, method, args);
                }
            },
            .named => |n| {
                if (isStringTypeName(n.name)) return g.genStringMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "StringBuilder")) return g.genStringBuilderMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "char")) return g.genCharMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "TcpConn"))    return g.genTcpMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "UdpSocket"))  return g.genUdpMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "Regex"))      return g.genRegexMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "Gui"))        return g.genGuiWidgetMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "CodeEditor")) return g.genCodeEditorMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "JsonValue"))  return g.genJsonMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "DateTime"))   return g.genDateTimeMethod(object, method, args);
                // toString() on int/float/bool — format as string.
                if (std.mem.eql(u8, method, "toString")) {
                    const fmt = if (std.mem.eql(u8, n.name, "float") or
                                    std.mem.eql(u8, n.name, "num")   or
                                    std.mem.eql(u8, n.name, "decimal")) "{d}" else "{}";
                    try g.w.print("(std.fmt.allocPrint(_allocator, \"{s}\", .{{", .{fmt});
                    try g.genExpr(object);
                    try g.w.writeAll("}) catch unreachable)");
                    return true;
                }
            },
            else => {
                // Unknown type — try toString via TC inferred type.
                if (std.mem.eql(u8, method, "toString")) {
                    const tc_type = if (g.tc) |tc| tc.expr_types.get(object) orelse .unknown else .unknown;
                    const fmt: []const u8 = switch (tc_type) {
                        .float => "{d}",
                        else   => "{}",
                    };
                    try g.w.print("(std.fmt.allocPrint(_allocator, \"{s}\", .{{", .{fmt});
                    try g.genExpr(object);
                    try g.w.writeAll("}) catch unreachable)");
                    return true;
                }
                // Unknown type — try List dispatch for known list method names.
                // This handles e.g. sys.args() which is inferred as .unknown but
                // holds a std.ArrayList at runtime.
                const list_methods = std.StaticStringMap(void).initComptime(&.{
                    .{ "add", {} }, .{ "at", {} }, .{ "remove", {} },
                    .{ "clear", {} }, .{ "contains", {} }, .{ "count", {} },
                    .{ "sort", {} }, .{ "sortBy", {} },
                    .{ "any", {} }, .{ "all", {} },
                });
                if (list_methods.get(method) != null) {
                    return g.genListMethod(object, false, method, args);
                }
            },
        }
        return false;
    }

    fn genStdlibProp(
        g:      Generator,
        object: *const Ast.Expr,
        tr:     Ast.TypeRef,
        prop:   []const u8,
    ) anyerror!bool {
        switch (tr) {
            .generic => |gtr| {
                if (std.mem.eql(u8, gtr.name, "List")) {
                    if (std.mem.eql(u8, prop, "len") or std.mem.eql(u8, prop, "count")) {
                        try g.writeListLen(object);
                        return true;
                    }
                }
                if (std.mem.eql(u8, gtr.name, "HashMap")) {
                    if (std.mem.eql(u8, prop, "len") or std.mem.eql(u8, prop, "count")) {
                        try g.genExpr(object);
                        try g.w.writeAll(".count()");
                        return true;
                    }
                }
            },
            .named => |n| {
                if (isStringTypeName(n.name) and std.mem.eql(u8, prop, "len")) {
                    try g.genExpr(object);
                    try g.w.writeAll(".len");
                    return true;
                }
                if (std.mem.eql(u8, n.name, "DateTime")) {
                    const dt_fields = std.StaticStringMap([]const u8).initComptime(&.{
                        .{ "year", "year" }, .{ "month", "month" }, .{ "day", "day" },
                        .{ "hour", "hour" }, .{ "minute", "minute" }, .{ "second", "second" },
                    });
                    if (dt_fields.get(prop)) |field| {
                        try g.w.writeAll("_dt_to_gregorian(");
                        try g.genExpr(object);
                        try g.w.print(".epoch_ms).{s}", .{field});
                        return true;
                    }
                    if (std.mem.eql(u8, prop, "weekday")) {
                        try g.w.writeAll("_dt_weekday(");
                        try g.genExpr(object);
                        try g.w.writeAll(")");
                        return true;
                    }
                }
            },
            else => {
                // Unknown type — treat len/count as ArrayList .items.len fallback.
                if (std.mem.eql(u8, prop, "len") or std.mem.eql(u8, prop, "count")) {
                    try g.genExpr(object);
                    try g.w.writeAll(".items.len");
                    return true;
                }
            },
        }
        return false;
    }

    // ── File I/O static methods ───────────────────────────────────────────────

    /// Emit a static `File.*` call.
    ///
    ///   File.read(path)            → []u8  (allocates; call in throws context)
    ///   File.write(path, content)  → void
    ///   File.exists(path)          → bool  (no allocation, no error)
    ///   File.readLines(path)       → List(str) — convenience wrapper
    fn genFileCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "read")) {
            // File.read(path) → std.fs.cwd().readFileAlloc(_allocator, path, max)
            try g.w.writeAll("(std.fs.cwd().readFileAlloc(_allocator, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", std.math.maxInt(usize)) catch @panic(\"File.read error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "write")) {
            // File.write(path, content) → std.fs.cwd().writeFile(...)
            try g.w.writeAll("(std.fs.cwd().writeFile(.{ .sub_path = ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", .data = ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(" }) catch @panic(\"File.write error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "exists")) {
            // File.exists(path) → labelled block: access → true, else false
            try g.w.writeAll("(blk: { std.fs.cwd().access(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", .{}) catch break :blk false; break :blk true; })");
            return true;
        }
        if (std.mem.eql(u8, method, "readLines")) {
            // File.readLines(path) → read whole file and split on newlines into ArrayList
            // Emits a block that builds an ArrayList([]const u8).
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _fl_content = std.fs.cwd().readFileAlloc(_allocator, ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(", std.math.maxInt(usize)) catch @panic(\"File.readLines error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _fl_list = std.ArrayList([]const u8){};\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _fl_it = std.mem.splitScalar(u8, _fl_content, '\\n');\n");
            try bg.writeIndent();
            try bg.w.writeAll("while (_fl_it.next()) |_fl_line| {\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("_fl_list.append(_allocator, _fl_line) catch unreachable;\n");
            try bg.writeIndent();
            try bg.w.writeAll("}\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk _fl_list;\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "append")) {
            // File.append(path, content) → append content; creates file if absent.
            // openFile with read_write; fall back to createFile if not found.
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _fa_path = ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(";\n");
            try bg.writeIndent();
            try bg.w.writeAll("const _fa_file = std.fs.cwd().openFile(_fa_path, .{ .mode = .read_write })\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("catch std.fs.cwd().createFile(_fa_path, .{}) catch @panic(\"File.append error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _fa_file.close();\n");
            try bg.writeIndent();
            try bg.w.writeAll("_ = _fa_file.seekFromEnd(0) catch @panic(\"File.append seek error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("_fa_file.writeAll(");
            if (args.len >= 2) try bg.genExpr(args[1].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(") catch @panic(\"File.append write error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk {};\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "delete")) {
            // File.delete(path) → delete file (ignores not-found)
            try g.w.writeAll("(std.fs.cwd().deleteFile(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch |_fd_err| { if (_fd_err != error.FileNotFound) @panic(\"File.delete error\"); })");
            return true;
        }
        if (std.mem.eql(u8, method, "rename")) {
            // File.rename(oldPath, newPath) → rename/move within cwd.
            // std.fs.Dir.rename(old, new) — both relative to the same Dir.
            try g.w.writeAll("(std.fs.cwd().rename(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch @panic(\"File.rename error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "copy")) {
            // File.copy(src, dst) → copy file contents
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _fc_data = std.fs.cwd().readFileAlloc(_allocator, ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(", std.math.maxInt(usize)) catch @panic(\"File.copy read error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("std.fs.cwd().writeFile(.{ .sub_path = ");
            if (args.len >= 2) try bg.genExpr(args[1].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(", .data = _fc_data }) catch @panic(\"File.copy write error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk {};\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "modtime")) {
            // File.modtime(path: str) → int  — mtime in milliseconds since epoch, or -1 if missing
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _mt_stat = std.fs.cwd().statFile(");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(") catch break :blk @as(i64, -1);\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk @as(i64, @intCast(@divTrunc(_mt_stat.mtime, std.time.ns_per_ms)));\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "listDir")) {
            // File.listDir(path) → ArrayList([]const u8) of entry names in directory.
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("var _ld_dir = std.fs.cwd().openDir(");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\".\"\n");
            try bg.w.writeAll(", .{ .iterate = true }) catch @panic(\"File.listDir error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _ld_dir.close();\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _ld_list = std.ArrayList([]const u8){};\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _ld_iter = _ld_dir.iterate();\n");
            try bg.writeIndent();
            try bg.w.writeAll("while (_ld_iter.next() catch null) |_ld_entry| {\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("_ld_list.append(_allocator, _allocator.dupe(u8, _ld_entry.name) catch @panic(\"OOM\")) catch @panic(\"OOM\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("}\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk _ld_list;\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        return false;
    }

    // ── Dir static methods ────────────────────────────────────────────────────
    //
    //   Dir.create(path)        → void (creates; no-op if exists)
    //   Dir.createAll(path)     → void (creates all intermediate dirs)
    //   Dir.delete(path)        → void (removes empty dir; ignores not-found)
    //   Dir.deleteAll(path)     → void (removes dir tree recursively)
    //   Dir.exists(path)        → bool
    //   Dir.list(path)          → List(str)  (entry names)
    fn genDirCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "create")) {
            try g.w.writeAll("(std.fs.cwd().makeDir(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch |_dc_err| { if (_dc_err != error.PathAlreadyExists) @panic(\"Dir.create error\"); })");
            return true;
        }
        if (std.mem.eql(u8, method, "createAll")) {
            try g.w.writeAll("(std.fs.cwd().makePath(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch @panic(\"Dir.createAll error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "delete")) {
            try g.w.writeAll("(std.fs.cwd().deleteDir(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch |_dd_err| { if (_dd_err != error.FileNotFound) @panic(\"Dir.delete error\"); })");
            return true;
        }
        if (std.mem.eql(u8, method, "deleteAll")) {
            try g.w.writeAll("(std.fs.cwd().deleteTree(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch @panic(\"Dir.deleteAll error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "exists")) {
            // Open the directory to check; access() only works for files.
            try g.w.writeAll("(blk: { var _de_d = std.fs.cwd().openDir(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", .{}) catch break :blk false; _de_d.close(); break :blk true; })");
            return true;
        }
        if (std.mem.eql(u8, method, "list")) {
            // Dir.list(path) → ArrayList([]const u8) of entry names
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("var _dl_dir = std.fs.cwd().openDir(");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\".\"\n");
            try bg.w.writeAll(", .{ .iterate = true }) catch @panic(\"Dir.list error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _dl_dir.close();\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _dl_list = std.ArrayList([]const u8){};\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _dl_iter = _dl_dir.iterate();\n");
            try bg.writeIndent();
            try bg.w.writeAll("while (_dl_iter.next() catch null) |_dl_entry| {\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("_dl_list.append(_allocator, _allocator.dupe(u8, _dl_entry.name) catch @panic(\"OOM\")) catch @panic(\"OOM\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("}\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk _dl_list;\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        return false;
    }

    // ── Path static methods ───────────────────────────────────────────────────
    //
    //   Path.join(a, b)     → str   (join two path segments)
    //   Path.basename(path) → str   (last component, no trailing separator)
    //   Path.dirname(path)  → str   (parent directory)
    //   Path.ext(path)      → str   (file extension including dot, or "" if none)
    //   Path.stem(path)     → str   (basename without extension)
    //   Path.isAbsolute(path) → bool
    fn genPathCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "join")) {
            // Path.join(a, b) — use std.fs.path.join
            try g.w.writeAll("(std.fs.path.join(_allocator, &.{");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            if (args.len >= 2) { try g.w.writeAll(", "); try g.genExpr(args[1].value); }
            if (args.len >= 3) { try g.w.writeAll(", "); try g.genExpr(args[2].value); }
            try g.w.writeAll("}) catch @panic(\"Path.join error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "basename")) {
            try g.w.writeAll("(std.fs.path.basename(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll("))");
            return true;
        }
        if (std.mem.eql(u8, method, "dirname")) {
            // dirname returns ?[]const u8; unwrap to "" if root.
            try g.w.writeAll("(std.fs.path.dirname(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") orelse \"\")");
            return true;
        }
        if (std.mem.eql(u8, method, "ext")) {
            try g.w.writeAll("(std.fs.path.extension(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll("))");
            return true;
        }
        if (std.mem.eql(u8, method, "stem")) {
            // stem = basename without extension
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _ps_base = std.fs.path.basename(");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(");\n");
            try bg.writeIndent();
            try bg.w.writeAll("const _ps_ext = std.fs.path.extension(_ps_base);\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk _ps_base[0 .. _ps_base.len - _ps_ext.len];\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "isAbsolute")) {
            try g.w.writeAll("(std.fs.path.isAbsolute(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll("))");
            return true;
        }
        return false;
    }

    // ── sys static methods ────────────────────────────────────────────────────

    /// Emit a static `sys.*` call.
    ///
    ///   sys.args()          → ArrayList([]const u8) of command-line args (alloc'd)
    ///   sys.exit(code)      → std.process.exit(code)  — noreturn
    // ── Math static methods ───────────────────────────────────────────────────
    //
    // All trig/exp/log/rounding functions coerce to f64 via @as(f64, arg).
    // abs/min/max/clamp use Zig builtins and work on any numeric type.
    // Constants (Math.PI etc.) are handled in genExpr .member, not here.
    fn genMathCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        // Helper: emit a single-arg f64 std.math call
        const one = struct {
            fn emit(gg: Generator, fname: []const u8, as_: []const Ast.Arg) anyerror!void {
                try gg.w.writeAll("std.math.");
                try gg.w.writeAll(fname);
                try gg.w.writeAll("(@as(f64, ");
                if (as_.len >= 1) try gg.genExpr(as_[0].value) else try gg.w.writeAll("0");
                try gg.w.writeAll("))");
            }
        }.emit;

        if (std.mem.eql(u8, method, "sin"))   { try one(g, "sin",   args); return true; }
        if (std.mem.eql(u8, method, "cos"))   { try one(g, "cos",   args); return true; }
        if (std.mem.eql(u8, method, "tan"))   { try one(g, "tan",   args); return true; }
        if (std.mem.eql(u8, method, "asin"))  { try one(g, "asin",  args); return true; }
        if (std.mem.eql(u8, method, "acos"))  { try one(g, "acos",  args); return true; }
        if (std.mem.eql(u8, method, "atan"))  { try one(g, "atan",  args); return true; }
        if (std.mem.eql(u8, method, "sqrt"))  { try one(g, "sqrt",  args); return true; }
        if (std.mem.eql(u8, method, "exp"))   { try one(g, "exp",   args); return true; }
        if (std.mem.eql(u8, method, "floor")) { try one(g, "floor", args); return true; }
        if (std.mem.eql(u8, method, "ceil"))  { try one(g, "ceil",  args); return true; }
        if (std.mem.eql(u8, method, "round")) { try one(g, "round", args); return true; }
        if (std.mem.eql(u8, method, "trunc")) { try one(g, "trunc", args); return true; }
        if (std.mem.eql(u8, method, "log2"))  { try one(g, "log2",  args); return true; }
        if (std.mem.eql(u8, method, "log10")) { try one(g, "log10", args); return true; }
        if (std.mem.eql(u8, method, "isNaN")) { try one(g, "isNan", args); return true; }
        if (std.mem.eql(u8, method, "isInf")) { try one(g, "isInf", args); return true; }
        if (std.mem.eql(u8, method, "log")) {
            // natural log: std.math.log(f64, e, x)
            try g.w.writeAll("std.math.log(f64, std.math.e, @as(f64, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("))");
            return true;
        }
        if (std.mem.eql(u8, method, "atan2")) {
            try g.w.writeAll("std.math.atan2(@as(f64, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("), @as(f64, ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll("))");
            return true;
        }
        if (std.mem.eql(u8, method, "pow")) {
            try g.w.writeAll("std.math.pow(f64, @as(f64, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("), @as(f64, ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll("))");
            return true;
        }
        // abs / min / max / clamp use builtins (work on int and float)
        if (std.mem.eql(u8, method, "abs")) {
            try g.w.writeAll("@abs(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeByte(')');
            return true;
        }
        if (std.mem.eql(u8, method, "min")) {
            try g.w.writeAll("@min(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeByte(')');
            return true;
        }
        if (std.mem.eql(u8, method, "max")) {
            try g.w.writeAll("@max(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeByte(')');
            return true;
        }
        if (std.mem.eql(u8, method, "clamp")) {
            try g.w.writeAll("std.math.clamp(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 3) try g.genExpr(args[2].value) else try g.w.writeAll("0");
            try g.w.writeByte(')');
            return true;
        }
        return false;
    }

    ///   sys.err(msg)        → write msg to stderr (no newline)
    ///   sys.errln(msg)      → write msg + newline to stderr
    ///   sys.getenv(name)    → ?[]const u8 via std.posix.getenv
    fn genSysCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "args")) {
            // sys.args() → build an ArrayList from argsAlloc result
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _sa_raw = std.process.argsAlloc(_allocator) catch @panic(\"sys.args OOM\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _sa_list = std.ArrayList([]const u8){};\n");
            try bg.writeIndent();
            try bg.w.writeAll("for (_sa_raw) |_sa_arg| _sa_list.append(_allocator, _sa_arg) catch unreachable;\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk _sa_list;\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "exit")) {
            try g.w.writeAll("std.process.exit(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "err")) {
            try g.w.writeAll("std.debug.print(\"{s}\", .{");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "errln")) {
            try g.w.writeAll("std.debug.print(\"{s}\\n\", .{");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "getenv")) {
            try g.w.writeAll("std.posix.getenv(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "run")) {
            // sys.run(argv as List(str)) → _SysRunResult
            try g.w.writeAll("_sys_run(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "sleep")) {
            // sys.sleep(ms: int) — sleep for the given number of milliseconds
            try g.w.writeAll("std.Thread.sleep(@as(u64, @intCast(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")) * std.time.ns_per_ms)");
            return true;
        }
        return false;
    }

    // ── Shell static methods ──────────────────────────────────────────────────

    /// Emit a static `Shell.*` call.
    // ── Json static methods ──────────────────────────────────────────────────

    // ── DateTime static + instance methods ───────────────────────────────────

    fn genDateTimeCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "now")) {
            try g.w.writeAll("_dt_now()");
            return true;
        }
        if (std.mem.eql(u8, method, "fromEpoch")) {
            try g.w.writeAll("_DateTime{ .epoch_ms = ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(" }");
            return true;
        }
        if (std.mem.eql(u8, method, "of")) {
            try g.w.writeAll("_dt_from_gregorian(");
            for (args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            // Fill missing hour/minute/second with 0
            const provided = args.len;
            if (provided < 4) try g.w.writeAll(", 0");
            if (provided < 5) try g.w.writeAll(", 0");
            if (provided < 6) try g.w.writeAll(", 0");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    fn genDateTimeMethod(
        g:      Generator,
        object: *const Ast.Expr,
        method: []const u8,
        args:   []const Ast.Arg,
    ) anyerror!bool {
        // Arithmetic — return new _DateTime
        const arith_map = std.StaticStringMap([]const u8).initComptime(&.{
            .{ "addDays",    "_dt_add_days" },
            .{ "addHours",   "_dt_add_hours" },
            .{ "addMinutes", "_dt_add_minutes" },
            .{ "addSeconds", "_dt_add_seconds" },
            .{ "addMonths",  "_dt_add_months" },
            .{ "addYears",   "_dt_add_years" },
        });
        if (arith_map.get(method)) |fn_name| {
            try g.w.writeAll(fn_name);
            try g.w.writeAll("(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")");
            return true;
        }
        // Comparison
        if (std.mem.eql(u8, method, "before")) {
            try g.genExpr(object);
            try g.w.writeAll(".epoch_ms < ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("_dt_now()");
            try g.w.writeAll(".epoch_ms");
            return true;
        }
        if (std.mem.eql(u8, method, "after")) {
            try g.genExpr(object);
            try g.w.writeAll(".epoch_ms > ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("_dt_now()");
            try g.w.writeAll(".epoch_ms");
            return true;
        }
        if (std.mem.eql(u8, method, "equals")) {
            try g.genExpr(object);
            try g.w.writeAll(".epoch_ms == ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("_dt_now()");
            try g.w.writeAll(".epoch_ms");
            return true;
        }
        // Interval
        if (std.mem.eql(u8, method, "daysBetween")) {
            try g.w.writeAll("_dt_days_between(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("_dt_now()");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "secondsBetween")) {
            try g.w.writeAll("_dt_seconds_between(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("_dt_now()");
            try g.w.writeAll(")");
            return true;
        }
        // Serialization
        if (std.mem.eql(u8, method, "toEpoch")) {
            try g.genExpr(object);
            try g.w.writeAll(".epoch_ms");
            return true;
        }
        if (std.mem.eql(u8, method, "toIso8601")) {
            try g.w.writeAll("_dt_to_iso8601(");
            try g.genExpr(object);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "format")) {
            try g.w.writeAll("_dt_format(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        // Calendar view
        if (std.mem.eql(u8, method, "inCalendar")) {
            try g.w.writeAll("_dt_in_calendar(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("Calendar.Gregorian");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    fn genJsonCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "parse")) {
            try g.w.writeAll("_json_parse(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"{}\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "parseStrict")) {
            // First arg must be a class ident; second arg is the JSON source.
            if (args.len < 2 or args[0].value.* != .ident) {
                std.debug.panic(
                    "Json.parseStrict requires (T, src) where T is a class name",
                    .{},
                );
            }
            const class_name = args[0].value.ident.name;
            const sym = g.resolve.exprs.get(&args[0].value.ident);
            if (sym == null or sym.?.kind != .class) {
                std.debug.panic(
                    "Json.parseStrict({s}, …): '{s}' is not a class declared in this module",
                    .{ class_name, class_name },
                );
            }
            const cls = sym.?.decl.class;
            if (!cls.mods.reflectable) {
                std.debug.panic(
                    "Json.parseStrict requires '@reflectable class {s}' — add the annotation to {s}'s declaration.",
                    .{ class_name, class_name },
                );
            }
            try g.w.print("_json_parse_strict_{s}(", .{class_name});
            try g.genExpr(args[1].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "stringify")) {
            try g.w.writeAll("_json_stringify(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("_json_object()");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "object")) {
            try g.w.writeAll("_json_object()");
            return true;
        }
        if (std.mem.eql(u8, method, "array")) {
            try g.w.writeAll("_json_array()");
            return true;
        }
        return false;
    }

    // ── Tier-3 reflection: Json.parseStrict per-class parser ─────────────────
    //
    // For `@reflectable class T`, emit `fn _json_parse_strict_T(src) ?*T`.
    // Strict semantics: missing key, type mismatch, or extra key → null.
    // Scope-1 supports only int/float/bool/str fields.

    const StrictFieldKind = enum { int_, float_, bool_, str_ };

    fn primitiveFieldKind(tr: Ast.TypeRef) ?StrictFieldKind {
        return switch (tr) {
            .named => |n| if (std.mem.eql(u8, n.name, "int")) .int_
                else if (std.mem.eql(u8, n.name, "float")) .float_
                else if (std.mem.eql(u8, n.name, "bool")) .bool_
                else if (std.mem.eql(u8, n.name, "str") or std.mem.eql(u8, n.name, "String")) .str_
                else null,
            else => null,
        };
    }

    fn genJsonParseStrictFn(g: Generator, n: *Ast.DeclClass) anyerror!void {
        const Field = struct { name: []const u8, kind: StrictFieldKind };
        var fields = std.ArrayListUnmanaged(Field){};
        defer fields.deinit(g.alloc);

        for (n.members) |decl| {
            const v = switch (decl) { .var_ => |vv| vv, else => continue };
            if (v.mods.static_) continue;
            const tr = v.type_ orelse std.debug.panic(
                "@reflectable class {s}: field '{s}' has no declared type — Json.parseStrict requires explicit field types",
                .{ n.name, v.name },
            );
            const k = primitiveFieldKind(tr) orelse {
                const ts = try typeRefStr(tr, g.alloc);
                defer g.alloc.free(ts);
                std.debug.panic(
                    "Json.parseStrict on {s}: field '{s}' has unsupported type '{s}' (only int/float/bool/str supported in 0.9)",
                    .{ n.name, v.name, ts },
                );
            };
            try fields.append(g.alloc, .{ .name = v.name, .kind = k });
        }

        try g.w.print("fn _json_parse_strict_{s}(_src: []const u8) ?*{s} {{\n", .{ n.name, n.name });
        try g.w.writeAll("    const _v = _json_parse(_src) orelse return null;\n");
        try g.w.writeAll("    if (!_json_is_object(_v)) return null;\n");
        if (fields.items.len > 0) {
            try g.w.writeAll("    var _it = _v.object.iterator();\n");
            try g.w.writeAll("    while (_it.next()) |_e| {\n");
            try g.w.writeAll("        const _k = _e.key_ptr.*;\n");
            try g.w.writeAll("        const _known = ");
            for (fields.items, 0..) |f, i| {
                if (i > 0) try g.w.writeAll(" or ");
                try g.w.print("std.mem.eql(u8, _k, \"{s}\")", .{f.name});
            }
            try g.w.writeAll(";\n");
            try g.w.writeAll("        if (!_known) return null;\n");
            try g.w.writeAll("    }\n");
        } else {
            try g.w.writeAll("    if (_v.object.count() != 0) return null;\n");
        }
        for (fields.items) |f| {
            try g.w.print("    {{ const _x = _v.object.get(\"{s}\") orelse return null;\n", .{f.name});
            switch (f.kind) {
                .int_   => try g.w.writeAll("      switch (_x) { .integer => {}, else => return null } }\n"),
                .float_ => try g.w.writeAll("      switch (_x) { .float, .integer => {}, else => return null } }\n"),
                .bool_  => try g.w.writeAll("      switch (_x) { .bool => {}, else => return null } }\n"),
                .str_   => try g.w.writeAll("      switch (_x) { .string => {}, else => return null } }\n"),
            }
        }
        try g.w.print("    const _r = _allocator.create({s}) catch return null;\n", .{n.name});
        try g.w.writeAll("    _r.* = .{};\n");
        try g.w.print("    _r._type_tag = _ttag_{s};\n", .{n.name});
        for (fields.items) |f| {
            switch (f.kind) {
                .int_   => try g.w.print("    _r.{s} = _json_get_int(_v, \"{s}\");\n", .{ f.name, f.name }),
                .float_ => try g.w.print("    _r.{s} = _json_get_float(_v, \"{s}\");\n", .{ f.name, f.name }),
                .bool_  => try g.w.print("    _r.{s} = _json_get_bool(_v, \"{s}\");\n", .{ f.name, f.name }),
                .str_   => try g.w.print("    _r.{s} = _json_get_str(_v, \"{s}\");\n", .{ f.name, f.name }),
            }
        }
        try g.w.writeAll("    return _r;\n");
        try g.w.writeAll("}\n\n");
    }

    // ── Hash static calls ────────────────────────────────────────────────────
    fn genHashCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        const fn_map = std.StaticStringMap([]const u8).initComptime(&.{
            .{ "sha256",  "_hash_sha256"  },
            .{ "sha512",  "_hash_sha512"  },
            .{ "md5",     "_hash_md5"     },
            .{ "blake3",  "_hash_blake3"  },
        });
        if (fn_map.get(method)) |fn_name| {
            try g.w.writeAll(fn_name);
            try g.w.writeAll("(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "hmac256")) {
            try g.w.writeAll("_hash_hmac256(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Random static calls ──────────────────────────────────────────────────
    fn genRandomCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "randInt")) {
            try g.w.writeAll("_random_int(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("100");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "randFloat")) { try g.w.writeAll("_random_float()");  return true; }
        if (std.mem.eql(u8, method, "randBool"))  { try g.w.writeAll("_random_bool()");   return true; }
        if (std.mem.eql(u8, method, "bytes")) {
            try g.w.writeAll("_random_bytes(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("16");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "seed")) {
            try g.w.writeAll("_random_seed(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")");
            return true;
        }
        // choice(list) — emit inline index expression
        if (std.mem.eql(u8, method, "choice")) {
            if (args.len >= 1) {
                try g.genExpr(args[0].value);
                try g.w.writeAll(".items[_rng().uintLessThan(usize, ");
                try g.genExpr(args[0].value);
                try g.w.writeAll(".items.len)]");
            }
            return true;
        }
        // shuffle(list) — emit inline call
        if (std.mem.eql(u8, method, "shuffle")) {
            if (args.len >= 1) {
                try g.w.writeAll("(if (");
                try g.genExpr(args[0].value);
                try g.w.writeAll(".items.len > 0) _rng().shuffle(@TypeOf(");
                try g.genExpr(args[0].value);
                try g.w.writeAll(".items[0]), ");
                try g.genExpr(args[0].value);
                try g.w.writeAll(".items))");
            }
            return true;
        }
        return false;
    }

    // ── Arg static calls ─────────────────────────────────────────────────────
    fn genArgCall(g: Generator, method: []const u8, _: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "parse")) {
            try g.w.writeAll("_arg_parse()");
            return true;
        }
        return false;
    }

    // ── ArgResult instance method calls ─────────────────────────────────────
    fn genArgResultMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        const pass_methods = std.StaticStringMap(void).initComptime(&.{
            .{ "flag", {} }, .{ "contains", {} }, .{ "option", {} },
            .{ "optionInt", {} }, .{ "positional", {} }, .{ "usage", {} },
        });
        if (pass_methods.get(method) != null) {
            // Emit obj.method(args) — these are struct pub fns, so pass-through works directly.
            try g.genExpr(obj);
            try g.w.print(".{s}(", .{method});
            for (args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Terminal static calls ─────────────────────────────────────────────────
    fn genTerminalCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "isTty"))  { try g.w.writeAll("_term_is_tty()");  return true; }
        if (std.mem.eql(u8, method, "width"))  { try g.w.writeAll("_term_width()");   return true; }
        if (std.mem.eql(u8, method, "height")) { try g.w.writeAll("_term_height()");  return true; }
        // write(msg, color) and writeln(msg, color) → _term_print(msg, color, newline)
        const is_println = std.mem.eql(u8, method, "writeln");
        if (is_println or std.mem.eql(u8, method, "write")) {
            try g.w.writeAll("_term_print(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(if (is_println) ", true)" else ", false)");
            return true;
        }
        return false;
    }

    // ── Log static calls ─────────────────────────────────────────────────────
    fn genLogCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        const level_map = std.StaticStringMap([]const u8).initComptime(&.{
            .{ "debug", "_log_debug" },
            .{ "info",  "_log_info"  },
            .{ "warn",  "_log_warn"  },
            .{ "err",   "_log_err"   },
        });
        if (level_map.get(method)) |fn_name| {
            try g.w.writeAll(fn_name);
            try g.w.writeAll("(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "setLevel")) {
            // Accepts a string: "debug"/"info"/"warn"/"err"
            try g.w.writeAll("_log_set_level(");
            if (args.len >= 1) {
                // Inline the level number from the string literal if possible
                const arg = args[0].value;
                if (arg.* == .string_lit) {
                    // Strip surrounding quotes from the raw text.
                    const raw = arg.string_lit.text;
                    const lv = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
                    if (std.mem.eql(u8, lv, "debug"))      try g.w.writeAll("0")
                    else if (std.mem.eql(u8, lv, "info"))  try g.w.writeAll("1")
                    else if (std.mem.eql(u8, lv, "warn"))  try g.w.writeAll("2")
                    else if (std.mem.eql(u8, lv, "err"))   try g.w.writeAll("3")
                    else try g.genExpr(arg);
                } else try g.genExpr(arg);
            } else try g.w.writeAll("1");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "setOutput")) {
            // Accepts "stderr" or "stdout"
            try g.w.writeAll("_log_set_output_stderr(");
            if (args.len >= 1) {
                const arg = args[0].value;
                const raw2 = if (arg.* == .string_lit) arg.string_lit.text else "";
                const lv2  = if (raw2.len >= 2) raw2[1 .. raw2.len - 1] else raw2;
                if (arg.* == .string_lit and std.mem.eql(u8, lv2, "stdout"))
                    try g.w.writeAll("false")
                else
                    try g.w.writeAll("true");
            } else try g.w.writeAll("true");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "timestamp")) {
            try g.w.writeAll("_log_timestamp(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("true");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Uri static calls ─────────────────────────────────────────────────────
    fn genUriCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "parse")) {
            try g.w.writeAll("_uri_parse(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Compress static calls ────────────────────────────────────────────────
    fn genCompressCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "gzip")) {
            try g.w.writeAll("_compress_gzip(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "gunzip")) {
            try g.w.writeAll("_compress_gunzip(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Mime static calls ────────────────────────────────────────────────────
    fn genMimeCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "fromExt")) {
            try g.w.writeAll("_mime_from_ext(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "toExt")) {
            try g.w.writeAll("_mime_to_ext(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Timer static calls ───────────────────────────────────────────────────
    fn genTimerCall(g: Generator, method: []const u8, _: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "start")) {
            try g.w.writeAll("_timer_start()");
            return true;
        }
        return false;
    }

    // ── TimerHandle instance method calls ────────────────────────────────────
    fn genTimerResultMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, _: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "elapsed")) {
            try g.genExpr(obj);
            try g.w.writeAll(".elapsed()");
            return true;
        }
        if (std.mem.eql(u8, method, "elapsedMicros")) {
            try g.genExpr(obj);
            try g.w.writeAll(".elapsedMicros()");
            return true;
        }
        if (std.mem.eql(u8, method, "reset")) {
            try g.genExpr(obj);
            try g.w.writeAll(".reset()");
            return true;
        }
        return false;
    }

    // ── Progress static calls ────────────────────────────────────────────────
    fn genProgressCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "bar")) {
            try g.w.writeAll("_progress_bar(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"progress\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── ProgressBar instance method calls ────────────────────────────────────
    fn genProgressBarMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, _: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "tick")) {
            try g.genExpr(obj); try g.w.writeAll(".tick()"); return true;
        }
        if (std.mem.eql(u8, method, "done")) {
            try g.genExpr(obj); try g.w.writeAll(".done()"); return true;
        }
        return false;
    }

    // ── JsonValue instance methods ───────────────────────────────────────────

    fn genJsonMethod(
        g:      Generator,
        object: *const Ast.Expr,
        method: []const u8,
        args:   []const Ast.Arg,
    ) anyerror!bool {
        // Read-only accessors: emit _json_get_*(v, key)
        const read_map = std.StaticStringMap([]const u8).initComptime(&.{
            .{ "getStr",   "_json_get_str"   },
            .{ "getInt",   "_json_get_int"   },
            .{ "getFloat", "_json_get_float" },
            .{ "getBool",  "_json_get_bool"  },
            .{ "getObj",   "_json_get_obj"   },
            .{ "getList",  "_json_get_list"  },
        });
        if (read_map.get(method)) |fn_name| {
            try g.w.writeAll(fn_name);
            try g.w.writeAll("(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        // Predicate methods: emit _json_is_*(v)
        if (std.mem.eql(u8, method, "isNull")) {
            try g.w.writeAll("_json_is_null("); try g.genExpr(object); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "isObject")) {
            try g.w.writeAll("_json_is_object("); try g.genExpr(object); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "isArray")) {
            try g.w.writeAll("_json_is_array("); try g.genExpr(object); try g.w.writeAll(")"); return true;
        }
        // Stringify: emit _json_stringify(v)
        if (std.mem.eql(u8, method, "stringify")) {
            try g.w.writeAll("_json_stringify("); try g.genExpr(object); try g.w.writeAll(")"); return true;
        }
        // Mutating methods on object: emit _json_put_*(v_ptr, key, val)
        const put_map = std.StaticStringMap([]const u8).initComptime(&.{
            .{ "put",      "_json_put_str"   },
            .{ "putInt",   "_json_put_int"   },
            .{ "putFloat", "_json_put_float" },
            .{ "putBool",  "_json_put_bool"  },
        });
        if (put_map.get(method)) |fn_name| {
            try g.w.writeAll(fn_name);
            try g.w.writeAll("(&");
            try g.genExpr(object);
            for (args) |a| {
                try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            try g.w.writeAll(")");
            return true;
        }
        // Mutating methods on array: emit _json_arr_*(v_ptr, val)
        const arr_map = std.StaticStringMap([]const u8).initComptime(&.{
            .{ "append",      "_json_arr_str"   },
            .{ "appendInt",   "_json_arr_int"   },
            .{ "appendFloat", "_json_arr_float" },
            .{ "appendBool",  "_json_arr_bool"  },
        });
        if (arr_map.get(method)) |fn_name| {
            try g.w.writeAll(fn_name);
            try g.w.writeAll("(&");
            try g.genExpr(object);
            for (args) |a| {
                try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    ///
    ///   Shell.run(cmd)  → []u8  stdout+stderr combined; cross-platform (cmd/sh)
    fn genShellCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "run")) {
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _sh_cmd = ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(";\n");
            try bg.writeIndent();
            try bg.w.writeAll("const _sh_argv = if (comptime builtin.os.tag == .windows)\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("@as([]const []const u8, &[_][]const u8{ \"cmd\", \"/c\", _sh_cmd })\n");
            try bg.writeIndent();
            try bg.w.writeAll("else\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("@as([]const []const u8, &[_][]const u8{ \"sh\", \"-c\", _sh_cmd });\n");
            try bg.writeIndent();
            try bg.w.writeAll("const _sh_res = std.process.Child.run(.{\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll(".allocator = _allocator,\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll(".argv = _sh_argv,\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll(".max_output_bytes = 1024 * 1024,\n");
            try bg.writeIndent();
            try bg.w.writeAll("}) catch @panic(\"Shell.run error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk std.mem.concat(_allocator, u8, &[_][]const u8{ _sh_res.stdout, _sh_res.stderr }) catch @panic(\"OOM\");\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        return false;
    }

    // ── Http static methods ───────────────────────────────────────────────────

    /// Emit a static `Http.*` call.
    ///
    ///   Http.get(url)           → _HttpResponse via _http_get(url)
    ///   Http.post(url, payload) → _HttpResponse via _http_post(url, payload)
    fn genHttpCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "get")) {
            try g.w.writeAll("_http_get(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "post")) {
            try g.w.writeAll("_http_post(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "serve")) {
            try g.w.writeAll("_http_serve(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("8080");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "json")) {
            try g.w.writeAll("_http_json_get(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "postJson")) {
            try g.w.writeAll("_http_json_post(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── HttpResponse factory methods ─────────────────────────────────────────

    fn genHttpResponseFactory(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "ok")) {
            try g.w.writeAll("HttpResponse{ .status = 200, .text = ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(" }");
            return true;
        }
        if (std.mem.eql(u8, method, "notFound")) {
            try g.w.writeAll("HttpResponse{ .status = 404, .text = ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"Not Found\"");
            try g.w.writeAll(" }");
            return true;
        }
        if (std.mem.eql(u8, method, "err")) {
            try g.w.writeAll("HttpResponse{ .status = 500, .text = ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"Internal Server Error\"");
            try g.w.writeAll(" }");
            return true;
        }
        if (std.mem.eql(u8, method, "new")) {
            try g.w.writeAll("HttpResponse{ .status = @intCast(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("200");
            try g.w.writeAll("), .text = ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(" }");
            return true;
        }
        return false;
    }

    // ── HttpResponse instance methods ─────────────────────────────────────────

    fn genHttpResponseMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "withHeader")) {
            try g.w.writeAll("_http_with_header(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Csv static + instance methods ────────────────────────────────────────

    fn genCsvCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "parse")) {
            try g.w.writeAll("_csv_parse(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "parseFile")) {
            try g.w.writeAll("_csv_parse_file(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    fn genCsvMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "rowCount")) {
            try g.w.writeAll("_csv_row_count("); try g.genExpr(obj); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "colCount")) {
            try g.w.writeAll("_csv_col_count("); try g.genExpr(obj); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "header")) {
            try g.w.writeAll("_csv_header("); try g.genExpr(obj); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "row")) {
            try g.w.writeAll("_csv_row(");
            try g.genExpr(obj); try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "rows")) {
            try g.w.writeAll("_csv_rows("); try g.genExpr(obj); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "dataRows")) {
            try g.w.writeAll("_csv_data_rows("); try g.genExpr(obj); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "get")) {
            try g.w.writeAll("_csv_get(");
            try g.genExpr(obj); try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")"); return true;
        }
        return false;
    }

    fn genCsvWriterMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "writeRow")) {
            try g.w.writeAll("_csv_write_row(&");
            try g.genExpr(obj); try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "build")) {
            try g.w.writeAll("_csv_build(&");
            try g.genExpr(obj); try g.w.writeAll(")"); return true;
        }
        return false;
    }

    // ── Tcp static + instance methods ────────────────────────────────────────

    fn genTcpCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "connect")) {
            try g.w.writeAll("_tcp_connect(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    fn genTcpMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "write")) {
            try g.w.writeAll("_tcp_write(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "read")) {
            try g.w.writeAll("_tcp_read(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "readLine")) {
            try g.w.writeAll("_tcp_read_line(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "readBytes")) {
            try g.w.writeAll("_tcp_read_bytes(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("1024");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "close")) {
            try g.w.writeAll("_tcp_close(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Udp static + instance methods ────────────────────────────────────────

    fn genUdpCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "socket")) {
            _ = args;
            try g.w.writeAll("_udp_socket()");
            return true;
        }
        return false;
    }

    // ── Net static methods ────────────────────────────────────────────────────

    fn genNetCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "resolve")) {
            try g.w.writeAll("_net_resolve(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeByte(')');
            return true;
        }
        return false;
    }

    // ── Regex static + instance methods ─────────────────────────────────────

    fn genRegexCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "compile")) {
            try g.w.writeAll("_regex_compile(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    fn genRegexMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "match")) {
            try g.w.writeAll("_regex_match(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "find")) {
            try g.w.writeAll("_regex_find(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "findAll")) {
            try g.w.writeAll("_regex_find_all(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "replace")) {
            try g.w.writeAll("_regex_replace(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "groups")) {
            try g.w.writeAll("_regex_groups(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Gui static + widget methods ──────────────────────────────────────────

    /// Gui.run(title, width, height, callback) → _gui_run(...)
    fn genGuiCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "run")) {
            if (g.uses_gui_ptr) |p| p.* = true;
            try g.w.writeAll("_gui_run(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"App\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("800");
            try g.w.writeAll(", ");
            if (args.len >= 3) try g.genExpr(args[2].value) else try g.w.writeAll("600");
            try g.w.writeAll(", ");
            if (args.len >= 4) try g.genExpr(args[3].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    /// editor.setText / getText / setReadOnly / setErrorMarkers / render
    fn genCodeEditorMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "setText")) {
            try g.w.writeAll("_code_editor_set_text(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "getText")) {
            try g.w.writeAll("_code_editor_get_text(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "setReadOnly")) {
            try g.w.writeAll("_code_editor_set_readonly(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("false");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "setErrorMarkers")) {
            try g.w.writeAll("_code_editor_set_error_markers(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "render")) {
            try g.w.writeAll("_code_editor_render(");
            try g.genExpr(obj);
            // args: g, id, width, height
            for (args) |a| { try g.w.writeAll(", "); try g.genExpr(a.value); }
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    /// g.text(s), g.button(label), etc. — pass through directly to GuiContext methods.
    /// Used for expression context (return values like button, checkbox, slider, input).
    /// For void-returning statement calls with allocating string args, use genGuiWidgetStmt.
    fn genGuiWidgetMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        const known = std.StaticStringMap(void).initComptime(&.{
            .{ "text",      {} }, .{ "separator", {} }, .{ "sameLine",  {} },
            .{ "spacing",   {} }, .{ "indent",    {} }, .{ "unindent",  {} },
            .{ "button",    {} }, .{ "checkbox",  {} }, .{ "slider",         {} },
            .{ "input",     {} }, .{ "inputMultiline", {} },
            .{ "panel",     {} }, .{ "window",    {} },
        });
        if (known.get(method) == null) return false;
        try g.genExpr(obj);
        try g.w.print(".{s}(", .{method});
        for (args, 0..) |a, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.genExpr(a.value);
        }
        try g.w.writeAll(")");
        return true;
    }

    /// Statement-level GUI widget call handler. Wraps allocating string args in temp
    /// vars with defer-free to prevent GPA leaks. Returns true if emitted.
    fn genGuiWidgetStmt(g: Generator, e: *const Ast.Expr) anyerror!bool {
        if (e.* != .call) return false;
        const call = e.call;
        if (call.callee.* != .member) return false;
        const mem = call.callee.member;
        // Determine if receiver is a gui_context typed value.
        const obj_tc = if (g.tc) |tc| tc.expr_types.get(mem.object) orelse .unknown else .unknown;
        const is_gui = obj_tc == .gui_context or
            (g.getExprDeclaredType(mem.object) != null and blk: {
                const tr = g.getExprDeclaredType(mem.object).?;
                break :blk tr == .named and std.mem.eql(u8, tr.named.name, "Gui");
            });
        if (!is_gui) return false;
        const void_methods = std.StaticStringMap(void).initComptime(&.{
            .{ "text", {} }, .{ "separator", {} }, .{ "sameLine", {} },
            .{ "spacing", {} }, .{ "indent", {} }, .{ "unindent", {} },
            .{ "panel", {} }, .{ "window", {} },
        });
        if (void_methods.get(mem.member) == null) return false;
        // Check if any arg is allocating.
        var any_alloc = false;
        for (call.args) |a| {
            if (a.value.* == .string_interp or isAllocatingStringInit(a.value, g.tc)) {
                any_alloc = true; break;
            }
        }
        if (!any_alloc) return false;
        // Emit a block with temp vars.
        try g.writeIndent();
        try g.w.writeAll("{\n");
        const bg = g.indented();
        var tmp_names = std.ArrayList(?[]const u8){};
        try tmp_names.ensureTotalCapacity(g.alloc, call.args.len);
        defer {
            for (tmp_names.items) |tn| if (tn) |n| g.alloc.free(n);
            tmp_names.deinit(g.alloc);
        }
        for (call.args, 0..) |a, i| {
            if (a.value.* == .string_interp or isAllocatingStringInit(a.value, g.tc)) {
                const tname = try std.fmt.allocPrint(g.alloc, "_gw{d}", .{i});
                try tmp_names.append(g.alloc, tname);
                try bg.writeIndent();
                try bg.w.print("const {s} = ", .{tname});
                try bg.genExpr(a.value);
                try bg.w.writeAll(";\n");
            } else {
                try tmp_names.append(g.alloc, null);
            }
        }
        try bg.writeIndent();
        try bg.genExpr(mem.object);
        try bg.w.print(".{s}(", .{mem.member});
        for (call.args, 0..) |_, i| {
            if (i > 0) try bg.w.writeAll(", ");
            if (tmp_names.items[i]) |tn| {
                try bg.w.writeAll(tn);
            } else {
                try bg.genExpr(call.args[i].value);
            }
        }
        try bg.w.writeAll(");\n");
        try g.writeIndent();
        try g.w.writeAll("}\n");
        return true;
    }

    fn genUdpMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "send")) {
            try g.w.writeAll("_udp_send(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 3) try g.genExpr(args[2].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "recv")) {
            try g.w.writeAll("_udp_recv(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("4096");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "close")) {
            try g.w.writeAll("_udp_close(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── String-slice methods ([]const []const u8, e.g. Net.resolve result) ──────

    fn genStrSliceMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "count")) {
            try g.w.writeAll("@as(i64, @intCast(");
            try g.genExpr(obj);
            try g.w.writeAll(".len))");
            return true;
        }
        if (std.mem.eql(u8, method, "at")) {
            try g.genExpr(obj);
            try g.w.writeAll("[@as(usize, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll("))]");
            return true;
        }
        return false;
    }

    /// Emit code for `Reflect.className(obj)`, `Reflect.fieldNames(obj)`,
    /// `Reflect.fieldTypes(obj)`.  Resolves the class name from the TC-inferred
    /// type of the argument and emits a reference to the corresponding
    /// `_reflect_<ClassName>_*` const generated alongside the class struct.
    fn genReflectCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (args.len != 1) return false;
        const arg = args[0].value;
        const arg_type = if (g.tc) |tc| tc.expr_types.get(arg) orelse .unknown else .unknown;
        const class_name: []const u8 = switch (arg_type) {
            .named => |sym| switch (sym.decl) {
                .class   => |c| c.name,
                .struct_ => |s| s.name,
                else     => return false,
            },
            else => return false,
        };
        if (std.mem.eql(u8, method, "className")) {
            try g.w.print("_reflect_{s}_name", .{class_name});
            return true;
        }
        if (std.mem.eql(u8, method, "fieldNames")) {
            try g.w.print("_reflect_{s}_fields[0..]", .{class_name});
            return true;
        }
        if (std.mem.eql(u8, method, "fieldTypes")) {
            try g.w.print("_reflect_{s}_field_types[0..]", .{class_name});
            return true;
        }
        return false;
    }

    // ── List methods ──────────────────────────────────────────────────────────

    fn genListMethod(g: Generator, obj: *const Ast.Expr, item_is_str: bool, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "add")) {
            // list.add(x) → list.append(_allocator, x) catch unreachable  (Zig 0.15)
            // For List(str), dupe the item so the list owns it.
            try g.genExpr(obj);
            try g.w.writeAll(".append(_allocator, ");
            if (args.len > 0) {
                if (item_is_str) {
                    try g.w.writeAll("_intern(");
                    try g.genExpr(args[0].value);
                    try g.w.writeAll(")");
                } else {
                    try g.genExpr(args[0].value);
                }
            }
            try g.w.writeAll(") catch unreachable");
            return true;
        }
        if (std.mem.eql(u8, method, "at")) {
            // list.at(i) → list.items[i]   (use 'at' since 'get' is a keyword)
            // Index is i64 in Zebra; Zig requires usize for slice indexing.
            try g.genExpr(obj);
            try g.w.writeAll(".items[@as(usize, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll("))]");
            return true;
        }
        if (std.mem.eql(u8, method, "remove")) {
            // list.remove(i) → _ = list.orderedRemove(@as(usize, @intCast(i)))
            // Index is i64 in Zebra; orderedRemove takes usize.
            try g.w.writeAll("_ = ");
            try g.genExpr(obj);
            try g.w.writeAll(".orderedRemove(@as(usize, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "clear")) {
            try g.genExpr(obj);
            try g.w.writeAll(".clearRetainingCapacity()");
            return true;
        }
        if (std.mem.eql(u8, method, "contains")) {
            // list.contains(x) → std.mem.indexOfScalar(T, list.items, x) != null
            try g.w.writeAll("(std.mem.indexOfScalar(@TypeOf(");
            try g.genExpr(obj);
            try g.w.writeAll(".items[0]), ");
            try g.genExpr(obj);
            try g.w.writeAll(".items, ");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(") != null)");
            return true;
        }
        if (std.mem.eql(u8, method, "count")) {
            try g.writeListLen(obj);
            return true;
        }
        if (std.mem.eql(u8, method, "sort")) {
            // list.sort() — natural ascending sort (numeric: a < b, strings: lexicographic)
            try g.w.writeAll("_zebra_sort_natural(@TypeOf(");
            try g.genExpr(obj);
            try g.w.writeAll(".items[0]), ");
            try g.genExpr(obj);
            try g.w.writeAll(".items)");
            return true;
        }
        if (std.mem.eql(u8, method, "sortBy")) {
            // list.sortBy(fn(a, b) => bool) — user-supplied comparator
            // The lambda generates as `struct { fn call(...) bool {...} }.call`,
            // a comptime-known function, passed as `comptime cmp` to _zebra_sort_by.
            if (args.len == 0) return false;
            try g.w.writeAll("_zebra_sort_by(@TypeOf(");
            try g.genExpr(obj);
            try g.w.writeAll(".items[0]), ");
            try g.genExpr(args[0].value);
            try g.w.writeAll(", ");
            try g.genExpr(obj);
            try g.w.writeAll(".items)");
            return true;
        }
        if (std.mem.eql(u8, method, "any")) {
            if (args.len == 0) return false;
            try g.w.writeAll("_zebra_list_any(std.meta.Child(@TypeOf(");
            try g.genExpr(obj);
            try g.w.writeAll(".items)), ");
            try g.genExpr(args[0].value);
            try g.w.writeAll(", ");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "all")) {
            if (args.len == 0) return false;
            try g.w.writeAll("_zebra_list_all(std.meta.Child(@TypeOf(");
            try g.genExpr(obj);
            try g.w.writeAll(".items)), ");
            try g.genExpr(args[0].value);
            try g.w.writeAll(", ");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── HashMap methods ───────────────────────────────────────────────────────

    fn genHashMapMethod(g: Generator, obj: *const Ast.Expr, key_is_str: bool, val_is_str: bool, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "set") or std.mem.eql(u8, method, "put")) {
            // HashMap.set(k, v) / HashMap.put(k, v) — both spellings accepted; Zig uses put().
            // Dupe key and/or value when they are strings so the map owns them.
            try g.genExpr(obj);
            try g.w.writeAll(".put(");
            for (args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                const need_dupe = (i == 0 and key_is_str) or (i == 1 and val_is_str);
                if (need_dupe) {
                    try g.w.writeAll("_intern(");
                    try g.genExpr(a.value);
                    try g.w.writeAll(")");
                } else {
                    try g.genExpr(a.value);
                }
            }
            try g.w.writeAll(") catch unreachable");
            return true;
        }
        if (std.mem.eql(u8, method, "fetch")) {
            // map.fetch(k) — note: 'get' is a keyword, use 'fetch'
            // Returns the value or undefined if missing.
            try g.w.writeAll("(");
            try g.genExpr(obj);
            try g.w.writeAll(".get(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(") orelse undefined)");
            return true;
        }
        if (std.mem.eql(u8, method, "contains")) {
            // map.contains(k) — note: 'has' is a keyword, use 'contains'
            try g.genExpr(obj);
            try g.w.writeAll(".contains(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "remove")) {
            try g.w.writeAll("_ = ");
            try g.genExpr(obj);
            try g.w.writeAll(".remove(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "count")) {
            // HashMap.count() returns usize; cast to i64 to match Zebra's int type.
            try g.w.writeAll("@as(i64, @intCast(");
            try g.genExpr(obj);
            try g.w.writeAll(".count()))");
            return true;
        }
        return false;
    }

    // ── String methods ────────────────────────────────────────────────────────

    fn genStringMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "contains")) {
            try g.w.writeAll("(std.mem.indexOf(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(") != null)");
            return true;
        }
        if (std.mem.eql(u8, method, "startsWith")) {
            try g.w.writeAll("std.mem.startsWith(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "endsWith")) {
            try g.w.writeAll("std.mem.endsWith(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "trim")) {
            try g.w.writeAll("std.mem.trim(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", &std.ascii.whitespace)");
            return true;
        }
        if (std.mem.eql(u8, method, "trimLeft")) {
            try g.w.writeAll("std.mem.trimLeft(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", &std.ascii.whitespace)");
            return true;
        }
        if (std.mem.eql(u8, method, "trimRight")) {
            try g.w.writeAll("std.mem.trimRight(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", &std.ascii.whitespace)");
            return true;
        }
        if (std.mem.eql(u8, method, "isEmpty")) {
            try g.w.writeAll("(");
            try g.genExpr(obj);
            try g.w.writeAll(".len == 0)");
            return true;
        }
        if (std.mem.eql(u8, method, "count")) {
            // str.count(substr) → count non-overlapping occurrences; cast to i64.
            try g.w.writeAll("@as(i64, @intCast(std.mem.count(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "join")) {
            // sep.join(list) → std.mem.join(_allocator, sep, list.items)
            try g.w.writeAll("(std.mem.join(_allocator, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("&.{}");
            try g.w.writeAll(".items) catch @panic(\"OOM\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "lines")) {
            // s.lines() → splitScalar iterator on '\n'; used in for-in via genForInLines
            try g.w.writeAll("std.mem.splitScalar(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", '\\n')");
            return true;
        }
        if (std.mem.eql(u8, method, "reverse")) {
            // str.reverse() → allocate copy and reverse it
            try g.w.writeAll("(blk: { const _rbuf = _allocator.alloc(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(".len) catch @panic(\"OOM\"); @memcpy(_rbuf, ");
            try g.genExpr(obj);
            try g.w.writeAll("); std.mem.reverse(u8, _rbuf); break :blk _rbuf; })");
            return true;
        }
        if (std.mem.eql(u8, method, "toHex")) {
            // str.toHex() → lower-case hex encoding; one byte → two hex digits
            try g.w.writeAll("(blk: { const _hx_s = ");
            try g.genExpr(obj);
            try g.w.writeAll("; const _hx_buf = _allocator.alloc(u8, _hx_s.len * 2) catch @panic(\"OOM\"); ");
            try g.w.writeAll("for (_hx_s, 0..) |_hx_b, _hx_i| { _ = std.fmt.bufPrint(_hx_buf[_hx_i * 2 .. _hx_i * 2 + 2], \"{x:0>2}\", .{_hx_b}) catch unreachable; } ");
            try g.w.writeAll("break :blk _hx_buf; })");
            return true;
        }
        if (std.mem.eql(u8, method, "fromHex")) {
            // str.fromHex() → decode hex string to bytes; returns ?str (null on bad input)
            try g.w.writeAll("(blk: { if (");
            try g.genExpr(obj);
            try g.w.writeAll(".len % 2 != 0) break :blk @as(?[]const u8, null); ");
            try g.w.writeAll("const _hbuf = _allocator.alloc(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(".len / 2) catch @panic(\"OOM\"); ");
            try g.w.writeAll("std.fmt.hexToBytes(_hbuf, ");
            try g.genExpr(obj);
            try g.w.writeAll(") catch { _allocator.free(_hbuf); break :blk @as(?[]const u8, null); }; ");
            try g.w.writeAll("break :blk @as(?[]const u8, _hbuf); })");
            return true;
        }
        if (std.mem.eql(u8, method, "isAlpha")) {
            // str.isAlpha() → all bytes are ASCII alphabetic (ASCII-aware)
            try g.w.writeAll("(blk: { if (");
            try g.genExpr(obj);
            try g.w.writeAll(".len == 0) break :blk false; for (");
            try g.genExpr(obj);
            try g.w.writeAll(") |_ac| { if (!std.ascii.isAlphabetic(_ac)) break :blk false; } break :blk true; })");
            return true;
        }
        if (std.mem.eql(u8, method, "isNumeric")) {
            // str.isNumeric() → all bytes are ASCII digits (ASCII-aware)
            try g.w.writeAll("(blk: { if (");
            try g.genExpr(obj);
            try g.w.writeAll(".len == 0) break :blk false; for (");
            try g.genExpr(obj);
            try g.w.writeAll(") |_nc| { if (!std.ascii.isDigit(_nc)) break :blk false; } break :blk true; })");
            return true;
        }
        // ── UTF-8 / Unicode methods ───────────────────────────────────────────
        if (std.mem.eql(u8, method, "isValidUtf8")) {
            try g.w.writeAll("std.unicode.utf8ValidateSlice(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "codePointCount")) {
            // Returns the number of Unicode codepoints (not bytes).
            // Cast to i64 to match Zebra's int type.
            try g.w.writeAll("@as(i64, @intCast(std.unicode.utf8CountCodepoints(");
            try g.genExpr(obj);
            try g.w.writeAll(") catch 0))");
            return true;
        }
        if (std.mem.eql(u8, method, "chars")) {
            // chars() as a standalone expression returns the string unchanged.
            // Actual codepoint iteration is handled in genForIn → genForInChars.
            try g.genExpr(obj);
            return true;
        }
        if (std.mem.eql(u8, method, "concat")) {
            try g.w.writeAll("(std.mem.concat(_allocator, u8, &.{ ");
            try g.genExpr(obj);
            for (args) |a| {
                try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            try g.w.writeAll(" }) catch unreachable)");
            return true;
        }
        if (std.mem.eql(u8, method, "toInt")) {
            try g.w.writeAll("(std.fmt.parseInt(i64, ");
            try g.genExpr(obj);
            try g.w.writeAll(", 10) catch 0)");
            return true;
        }
        if (std.mem.eql(u8, method, "toFloat")) {
            try g.w.writeAll("(std.fmt.parseFloat(f64, ");
            try g.genExpr(obj);
            try g.w.writeAll(") catch 0.0)");
            return true;
        }
        if (std.mem.eql(u8, method, "format")) {
            // str.format(val) — delegates to std.fmt.allocPrint
            try g.w.writeAll("(std.fmt.allocPrint(_allocator, ");
            try g.genExpr(obj);
            for (args) |a| {
                try g.w.writeAll(", .{ ");
                try g.genExpr(a.value);
                try g.w.writeAll(" }");
            }
            try g.w.writeAll(") catch unreachable)");
            return true;
        }
        if (std.mem.eql(u8, method, "upper")) {
            // str.upper() → std.ascii.allocUpperString(_allocator, str) catch unreachable
            try g.w.writeAll("(std.ascii.allocUpperString(_allocator, ");
            try g.genExpr(obj);
            try g.w.writeAll(") catch unreachable)");
            return true;
        }
        if (std.mem.eql(u8, method, "lower")) {
            // str.lower() → std.ascii.allocLowerString(_allocator, str) catch unreachable
            try g.w.writeAll("(std.ascii.allocLowerString(_allocator, ");
            try g.genExpr(obj);
            try g.w.writeAll(") catch unreachable)");
            return true;
        }
        if (std.mem.eql(u8, method, "indexOf")) {
            // str.indexOf(sub) → index as i64, or -1 if not found
            try g.w.writeAll("(if (std.mem.indexOf(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")) |_i| @as(i64, @intCast(_i)) else @as(i64, -1))");
            return true;
        }
        if (std.mem.eql(u8, method, "substring")) {
            // str.substring(start, end) → str[@intCast(start)..@intCast(end)]
            try g.genExpr(obj);
            try g.w.writeAll("[@intCast(");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")..@intCast(");
            if (args.len > 1) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll(")]");
            return true;
        }
        if (std.mem.eql(u8, method, "replace")) {
            // str.replace(old, new) → std.mem.replaceOwned(u8, _allocator, str, old, new)
            try g.w.writeAll("(std.mem.replaceOwned(u8, _allocator, ");
            try g.genExpr(obj);
            for (args) |a| {
                try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            try g.w.writeAll(") catch unreachable)");
            return true;
        }
        if (std.mem.eql(u8, method, "repeat")) {
            // str.repeat(n) → allocate n concatenated copies
            try g.w.writeAll("(blk: { var _rep = std.ArrayList([]const u8){}; ");
            try g.w.writeAll("defer _rep.deinit(_allocator); ");
            try g.w.writeAll("var _ri: i64 = 0; while (_ri < ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(") : (_ri += 1) _rep.append(_allocator, ");
            try g.genExpr(obj);
            try g.w.writeAll(") catch unreachable; ");
            try g.w.writeAll("break :blk std.mem.concat(_allocator, u8, _rep.items) catch unreachable; })");
            return true;
        }
        if (std.mem.eql(u8, method, "split")) {
            // str.split(delim) → returns a splitSequence iterator; use in for loops
            try g.w.writeAll("std.mem.splitSequence(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\" \"");
            try g.w.writeAll(")");
            return true;
        }
        // ── Padding / alignment methods ──────────────────────────────────────
        if (std.mem.eql(u8, method, "padLeft")) {
            // str.padLeft(n [, fill]) → right-align in width n
            try g.w.writeAll("_pad_left(");
            try g.genExpr(obj);
            try g.w.writeAll(", @as(usize, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")), ");
            if (args.len > 1) try g.genExpr(args[1].value) else try g.w.writeAll("' '");
            try g.w.writeAll(", _allocator)");
            return true;
        }
        if (std.mem.eql(u8, method, "padRight")) {
            // str.padRight(n [, fill]) → left-align in width n
            try g.w.writeAll("_pad_right(");
            try g.genExpr(obj);
            try g.w.writeAll(", @as(usize, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")), ");
            if (args.len > 1) try g.genExpr(args[1].value) else try g.w.writeAll("' '");
            try g.w.writeAll(", _allocator)");
            return true;
        }
        if (std.mem.eql(u8, method, "center")) {
            // str.center(n [, fill]) → center in width n
            try g.w.writeAll("_pad_center(");
            try g.genExpr(obj);
            try g.w.writeAll(", @as(usize, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")), ");
            if (args.len > 1) try g.genExpr(args[1].value) else try g.w.writeAll("' '");
            try g.w.writeAll(", _allocator)");
            return true;
        }
        // ── bytes() — iterate raw bytes of a string ───────────────────────────
        // Used in `for b in s.bytes()` → `for (s) |b|` in Zig (b is u8).
        // Note: chars() is reserved for future Unicode codepoint iteration.
        if (std.mem.eql(u8, method, "bytes")) {
            try g.genExpr(obj);
            return true;
        }
        return false;
    }

    /// Emit a struct-instance literal for a lambda that has a `capture` block.
    /// The result is a value of an anonymous struct type; call sites use `.call()`.
    fn genCaptureClosureStruct(g: Generator, e: *Ast.ExprLambda) anyerror!void {
        // Collect capture field names so body idents use `self.name`
        var field_names = std.ArrayList([]const u8){};
        defer field_names.deinit(g.alloc);
        for (e.capture) |cv| try field_names.append(g.alloc, cv.name);

        // Determine if any capture field is mutated in the body.
        // If so, `call` must take `self: *@This()` so assignments are visible to the caller.
        const body_stmts: []const Ast.Stmt = switch (e.body) {
            .stmts => |ss| ss,
            .expr  => &.{},
        };
        var body_mutations = try scanMutations(body_stmts, g.alloc, g.tc);
        defer body_mutations.deinit();
        var any_capture_mutated = false;
        for (e.capture) |cv| {
            if (body_mutations.contains(cv.name)) { any_capture_mutated = true; break; }
        }

        try g.w.writeAll("struct {\n");
        const fg = g.indented();

        // Emit capture fields
        for (e.capture) |cv| {
            try fg.writeIndent();
            try fg.w.writeAll(cv.name);
            try fg.w.writeAll(": ");
            if (cv.type_) |tr| {
                try fg.genType(tr);
            } else if (cv.init) |init| {
                // No explicit type — use @TypeOf(init_expr) so Zig can infer
                // the field type from the initialiser at the struct definition site.
                try fg.w.writeAll("@TypeOf(");
                try fg.genExpr(init);
                try fg.w.writeAll(")");
            } else {
                try fg.w.writeAll("anytype");
            }
            try fg.w.writeAll(",\n");
        }

        // Emit call method — mutable self if any capture field is assigned.
        try fg.writeIndent();
        if (any_capture_mutated) {
            try fg.w.writeAll("fn call(self: *@This()");
        } else {
            try fg.w.writeAll("fn call(self: @This()");
        }
        for (e.params) |p| {
            try fg.w.writeAll(", ");
            try fg.w.writeAll(p.name);
            try fg.w.writeAll(": ");
            if (p.type_) |tr| try fg.genType(tr) else try fg.w.writeAll("anytype");
        }
        try fg.w.writeAll(") ");
        if (e.return_type) |rt| {
            try fg.genType(rt);
        } else {
            switch (e.body) {
                .expr => |ex| {
                    try fg.w.writeAll("@TypeOf(");
                    try fg.genExpr(ex);
                    try fg.w.writeAll(")");
                },
                .stmts => try fg.w.writeAll("void"),
            }
        }
        try fg.w.writeAll(" {\n");

        // Body: idents matching capture names resolve to self.name
        // Escape analysis so deferred frees are skipped for vars whose ownership transfers out.
        var ret_set_capture = try analyzeEscapes(
            if (e.body == .stmts) e.body.stmts else &.{}, g.alloc);
        defer ret_set_capture.deinit();
        const base_bg = fg.indented().withCaptureFields(field_names.items);
        const bg = if (e.body == .stmts) base_bg.withReturnedNames(&ret_set_capture) else base_bg;
        switch (e.body) {
            .expr => |ex| {
                try bg.writeIndent();
                try bg.w.writeAll("return ");
                try bg.genExpr(ex);
                try bg.w.writeAll(";\n");
            },
            .stmts => |ss| {
                try bg.genStmts(ss);
            },
        }
        try fg.writeIndent();
        try fg.w.writeAll("}\n");
        try g.writeIndent();
        try g.w.writeAll("}{ ");
        for (e.capture) |cv| {
            try g.w.writeAll(".");
            try g.w.writeAll(cv.name);
            try g.w.writeAll(" = ");
            if (cv.init) |init| try g.genExpr(init) else try g.w.writeAll("undefined");
            try g.w.writeAll(", ");
        }
        try g.w.writeAll("}");
    }

    fn genAssign(g: Generator, s: *Ast.StmtAssign) anyerror!void {
        try g.writeIndent();
        switch (s.op) {
            .slashslash_eq => {
                // x //= y  →  x = @divTrunc(x, y)
                try g.genExpr(s.target);
                try g.w.writeAll(" = @divTrunc(");
                try g.genExpr(s.target);
                try g.w.writeAll(", ");
                try g.genExpr(s.value);
                try g.w.writeAll(")");
            },
            .starstar_eq => {
                // x **= y  →  x = std.math.pow(f64, x, y)
                try g.genExpr(s.target);
                try g.w.writeAll(" = std.math.pow(f64, ");
                try g.genExpr(s.target);
                try g.w.writeAll(", ");
                try g.genExpr(s.value);
                try g.w.writeAll(")");
            },
            .question_eq => {
                // x ?= y  →  x = x orelse y
                try g.genExpr(s.target);
                try g.w.writeAll(" = ");
                try g.genExpr(s.target);
                try g.w.writeAll(" orelse ");
                try g.genExpr(s.value);
            },
            else => {
                // Self-referential recursive field assignment:
                // If target is a member access whose type is `?*T` and the value
                // is of type `T` (bare struct), wrap the value in an arena alloc
                // so Zig gets the pointer it requires.
                const needs_box = blk: {
                    if (s.op != .assign) break :blk false;
                    if (s.target.* != .member) break :blk false;
                    const tc = g.tc orelse break :blk false;
                    const lhs_t = tc.expr_types.get(s.target) orelse break :blk false;
                    const rhs_t = tc.expr_types.get(s.value) orelse break :blk false;
                    if (lhs_t != .optional) break :blk false;
                    if (lhs_t.optional.* != .named) break :blk false;
                    if (rhs_t != .named) break :blk false;
                    if (lhs_t.optional.named != rhs_t.named) break :blk false;
                    // BUG-047 sibling (self-ref field-assign): class payloads are already `*T`
                    // via auto-box; wrapping `_rp.* = classValue` double-indirects. Suppress.
                    const sym = rhs_t.named;
                    if (sym.decl == .class) break :blk false;
                    break :blk true;
                };
                // `^T` heap-indirection field assignment:
                // If the field's declared type is `^T` or `^T?`, and the RHS is a
                // plain `T` value (not nil), we must heap-allocate so Zig gets a `*T`.
                const ref_box_type_name: ?[]const u8 = blk: {
                    if (s.op != .assign) break :blk null;
                    // Skip if RHS is nil — no allocation needed for null assignment.
                    if (s.value.* == .nil) break :blk null;
                    // Resolve the TypeRef for the target field.  We handle two cases:
                    //
                    //   1. `field = x` or `self.field = x` — look up in owner_class.
                    //   2. `a.b.field = x` (nested member) — look up `field` in the
                    //      declared type of the intermediate object `a.b`.
                    const field_tr_opt: ?Ast.TypeRef = blk2: {
                        switch (s.target.*) {
                            .ident => |id| {
                                break :blk2 g.resolveFieldTypeRef(id.name);
                            },
                            .member => |mem| {
                                if (mem.object.* == .ident) {
                                    // `self.field = x` or `localVar.field = x`:
                                    // First try the owner class (covers `self.field`).
                                    if (g.resolveFieldTypeRef(mem.member)) |tr| break :blk2 tr;
                                    // Fall back: look up via TC type of the object
                                    // (covers `localVar.field` where localVar is
                                    // a different class).
                                    if (g.tc) |tc| {
                                        const obj_t = tc.expr_types.get(mem.object) orelse break :blk2 null;
                                        const sym = switch (obj_t) {
                                            .named => |s2| s2,
                                            else  => break :blk2 null,
                                        };
                                        if (sym.own_scope) |scope| {
                                            if (scope.lookupLocal(mem.member)) |field_sym| {
                                                if (field_sym.decl == .var_) {
                                                    if (field_sym.decl.var_.type_) |*tr|
                                                        break :blk2 tr.*;
                                                }
                                            }
                                        }
                                    }
                                    break :blk2 null;
                                }
                                // Nested `a.b.field = x` — look up `field` in a.b's TC type.
                                if (g.tc) |tc| {
                                    const parent_t = tc.expr_types.get(mem.object) orelse break :blk2 null;
                                    const sym = switch (parent_t) {
                                        .named => |s2| s2,
                                        else  => break :blk2 null,
                                    };
                                    if (sym.own_scope) |scope| {
                                        if (scope.lookupLocal(mem.member)) |field_sym| {
                                            if (field_sym.decl == .var_) {
                                                if (field_sym.decl.var_.type_) |*tr|
                                                    break :blk2 tr.*;
                                            }
                                        }
                                    }
                                }
                                break :blk2 null;
                            },
                            else => break :blk2 null,
                        }
                    };
                    const field_tr = field_tr_opt orelse break :blk null;
                    if (field_tr != .ref_to) break :blk null;
                    // The inner TypeRef must resolve to a named type for codegen.
                    // Handle both `^T` and `^T?` (nilable optional pointer).
                    const inner = field_tr.ref_to;
                    const type_name: ?[]const u8 = switch (inner.*) {
                        .named   => |n| n.name,
                        .nilable => |ni| switch (ni.*) {
                            .named => |n| n.name,
                            else   => null,
                        },
                        else     => null,
                    };
                    const tn = type_name orelse break :blk null;
                    // BUG-047 sibling: class/union payloads are always `*T`; suppress double-box.
                    if (g.isPointerPassedType(tn)) break :blk null;
                    break :blk tn;
                };
                if (needs_box) {
                    // Emit: { const _rp = _allocator.create(T) catch @panic("OOM"); _rp.* = value; target = _rp; }
                    // Block statement — no trailing semicolon (it is added by the else branch below).
                    const rhs_t = g.tc.?.expr_types.get(s.value).?;
                    const class_name = switch (rhs_t.named.decl) {
                        .class   => |c|  c.name,
                        .struct_ => |ss| ss.name,
                        else     => "",
                    };
                    try g.w.writeAll("{ const _rp = _allocator.create(");
                    try g.w.writeAll(class_name);
                    try g.w.writeAll(") catch @panic(\"OOM\"); _rp.* = ");
                    try g.genExpr(s.value);
                    try g.w.writeAll("; ");
                    try g.genExpr(s.target);
                    try g.w.writeAll(" = _rp; }\n");
                    return; // skip trailing ;\n — block statement has no semicolon in Zig
                } else if (ref_box_type_name) |type_name| {
                    // Emit: { const _rp = _allocator.create(T) catch @panic("OOM"); _rp.* = value; target = _rp; }
                    try g.w.writeAll("{ const _rp = _allocator.create(");
                    try g.w.writeAll(type_name);
                    try g.w.writeAll(") catch @panic(\"OOM\"); _rp.* = ");
                    try g.genExpr(s.value);
                    try g.w.writeAll("; ");
                    try g.genExpr(s.target);
                    try g.w.writeAll(" = _rp; }\n");
                    return;
                } else {
                    try g.genExpr(s.target);
                    try g.w.writeAll(" ");
                    try g.w.writeAll(assignOpStr(s.op));
                    try g.w.writeAll(" ");
                    // fn-ref reassignment: `pred = isDigit` → `pred = &isDigit`
                    // Mutable fn-ref vars have type `*const fn(P) R`; bare function
                    // names are function values, so we need `&` to take a pointer.
                    const fn_ref_emitted: bool = fn_emit: {
                        if (s.op != .assign) break :fn_emit false;
                        if (s.value.* != .ident) break :fn_emit false;
                        const tc = g.tc orelse break :fn_emit false;
                        const rhs_t = tc.expr_types.get(s.value) orelse break :fn_emit false;
                        if (rhs_t != .fn_ref) break :fn_emit false;
                        try g.w.writeAll("&");
                        try g.genExpr(s.value);
                        break :fn_emit true;
                    };
                    // In class bodies (generic or concrete), resolve the declared generic
                    // field type from the LHS so any zero-arg constructor `T()` emits
                    // `std.ArrayList(T){}` / `T(Arg).init()` correctly.
                    // Works for List, HashMap, and user-defined generics alike.
                    const generic_emitted: bool = emit: {
                        if (fn_ref_emitted) break :emit true;
                        if (s.op != .assign) break :emit false;
                        if (s.value.* != .call) break :emit false;
                        const rhs_call = s.value.call;
                        if (rhs_call.callee.* != .ident) break :emit false;
                        if (rhs_call.args.len != 0) break :emit false;
                        // Resolve field name from target: bare ident (in method body) or
                        // explicit `self.field` member access (rare in Zebra, but supported).
                        const field_name: []const u8 = switch (s.target.*) {
                            .ident  => |id| id.name,
                            .member => |mem| blk: {
                                switch (mem.object.*) {
                                    .this => {},
                                    .ident => |oid| {
                                        if (!std.mem.eql(u8, oid.name, "self")) break :emit false;
                                    },
                                    else => break :emit false,
                                }
                                break :blk mem.member;
                            },
                            else => break :emit false,
                        };
                        const gtr = g.resolveFieldGenericTypeRef(field_name) orelse break :emit false;
                        // RHS callee must name the same generic type as the field declaration.
                        if (!std.mem.eql(u8, rhs_call.callee.ident.name, gtr.name)) break :emit false;
                        try g.genStdlibInit(gtr);
                        break :emit true;
                    };
                    // Auto-intern when assigning to a struct/class str field so the
                    // stored slice outlives any enclosing arena_scope block.
                    const rhs_is_field_str: bool = blk: {
                        if (s.op != .assign) break :blk false;
                        if (s.target.* != .member) break :blk false;
                        const tc = g.tc orelse break :blk false;
                        const lhs_t = tc.expr_types.get(s.target) orelse break :blk false;
                        break :blk lhs_t == .string;
                    };
                    if (!generic_emitted) {
                        if (rhs_is_field_str) {
                            try g.w.writeAll("_intern(");
                            try g.genExpr(s.value);
                            try g.w.writeAll(")");
                        } else {
                            try g.genExpr(s.value);
                        }
                    }
                }
            },
        }
        try g.w.writeAll(";\n");
    }

    fn genReturn(g: Generator, s: *Ast.StmtReturn) anyerror!void {
        // TCO path: `return self.method(args)` inside a TCO-transformed method.
        // Instead of a real return, assign new arg values to the mutable param
        // copies and `continue` the enclosing `while (true)` loop.
        if (g.tco_method_name.len > 0) {
            if (s.value) |v| {
                if (isTcoExpr(v, g.tco_method_name, g.owner, g.tco_static_)) {
                    const args = v.call.args;
                    const n_update = @min(args.len, g.tco_params.len);
                    // Evaluate new args into temps first (avoids aliasing when a
                    // param appears on both sides, e.g. `return self.f(b, a)`).
                    try g.writeIndent();
                    try g.w.writeAll("{");
                    for (args[0..n_update], 0..) |arg, i| {
                        try g.w.print(" const _tco{d} = ", .{i});
                        try g.genExpr(arg.value);
                        try g.w.writeAll(";");
                    }
                    for (0..n_update) |i| {
                        try g.w.print(" {s} = _tco{d};", .{ g.tco_params[i], i });
                    }
                    try g.w.writeAll(" }\n");
                    try g.writeIndent();
                    try g.w.writeAll("continue;\n");
                    return;
                }
            }
        }
        // Contract `result` capture path: rewrite `return EXPR;` into a block that
        // captures the value into `_result`, arms the ensure flag, and returns the
        // captured local.  Only the outer function's returns are rewritten — lambda
        // bodies clear `ensure_armed_active` via withInLambda.
        if (g.ensure_armed_active and g.ensure_uses_result) {
            if (s.value) |v| {
                try g.writeIndent();
                try g.w.writeAll("{ _result = ");
                try g.genExpr(v);
                try g.w.writeAll("; _ensure_armed = true; return _result; }\n");
                return;
            }
        }
        // Plain ensure-armed path (no result capture): just arm before the existing
        // return logic emits the actual return statement.
        if (g.ensure_armed_active) {
            try g.writeIndent();
            try g.w.writeAll("_ensure_armed = true;\n");
        }
        try g.writeIndent();
        if (s.value) |v| {
            // If the return value is an allocating call whose receiver is also
            // an allocating expression, hoist the receiver into a scoped temp
            // so it can be defer-freed after the outer call completes.
            if (v.* == .call and v.call.callee.* == .member) {
                const mem_call = v.call.callee.member;
                if (isAllocatingStringInit(mem_call.object, g.tc)) {
                    try g.w.writeAll("{\n");
                    const ig = g.indented();
                    try ig.writeIndent();
                    try ig.w.writeAll("const _ret_recv = ");
                    try ig.genExpr(mem_call.object);
                    try ig.w.writeAll(";\n");
                    try ig.writeIndent();
                    try ig.w.writeAll("return ");
                    var sg = ig;
                    sg.expr_subst = .{ .orig = mem_call.object, .name = "_ret_recv" };
                    try sg.genExpr(v);
                    try ig.w.writeAll(";\n");
                    try g.writeIndent();
                    try g.w.writeAll("}\n");
                    return;
                }
            }
            try g.w.writeAll("return ");
            try g.genExpr(v);
            try g.w.writeAll(";\n");
        } else {
            try g.w.writeAll("return;\n");
        }
    }

    fn genIf(g: Generator, s: *Ast.StmtIf) anyerror!void {
        try g.writeIndent();
        // `if x is Union.variant |r|` — emit tag check + payload binding.
        if (s.is_capture) |cap| {
            const is_union_check = s.cond.* == .type_check and s.cond.type_check.variant_name != null;
            if (is_union_check) {
                // `if x is Union.variant as r` — emit tag check + payload binding.
                const tc_node = s.cond.type_check;
                const variant = tc_node.variant_name orelse tc_node.type_name;
                const union_nm = if (tc_node.variant_name != null) tc_node.type_name else "";
                try g.w.writeAll("if (");
                try g.genExpr(tc_node.expr);
                try g.w.print(" == .{s}) {{\n", .{variant});
                const pk = if (union_nm.len > 0)
                    g.unionPayloadKind(union_nm, variant)
                else
                    PayloadKind.other;
                const bg = g.indented();
                try bg.writeIndent();
                if (pk == .ref_payload) {
                    try bg.w.print("const {s}_ptr = ", .{cap});
                    try bg.genExpr(tc_node.expr);
                    try bg.w.print(".{s};\n", .{variant});
                    try bg.writeIndent();
                    try bg.w.print("const {s} = {s}_ptr.*;\n", .{ cap, cap });
                } else {
                    try bg.w.print("const {s} = ", .{cap});
                    try bg.genExpr(tc_node.expr);
                    try bg.w.print(".{s};\n", .{variant});
                }
                try bg.genStmts(s.then_body);
                try g.writeIndent();
                try g.w.writeAll("}");
                for (s.else_ifs) |ei| {
                    if (ei.is_capture) |ei_cap| {
                        const ei_tc = ei.cond.type_check;
                        const ei_variant = ei_tc.variant_name orelse ei_tc.type_name;
                        const ei_union = if (ei_tc.variant_name != null) ei_tc.type_name else "";
                        try g.w.writeAll(" else if (");
                        try g.genExpr(ei_tc.expr);
                        try g.w.print(" == .{s}) {{\n", .{ei_variant});
                        const ei_pk = if (ei_union.len > 0)
                            g.unionPayloadKind(ei_union, ei_variant)
                        else
                            PayloadKind.other;
                        const ei_bg = g.indented();
                        try ei_bg.writeIndent();
                        if (ei_pk == .ref_payload) {
                            try ei_bg.w.print("const {s}_ptr = ", .{ei_cap});
                            try ei_bg.genExpr(ei_tc.expr);
                            try ei_bg.w.print(".{s};\n", .{ei_variant});
                            try ei_bg.writeIndent();
                            try ei_bg.w.print("const {s} = {s}_ptr.*;\n", .{ ei_cap, ei_cap });
                        } else {
                            try ei_bg.w.print("const {s} = ", .{ei_cap});
                            try ei_bg.genExpr(ei_tc.expr);
                            try ei_bg.w.print(".{s};\n", .{ei_variant});
                        }
                        try ei_bg.genStmts(ei.body);
                        try g.writeIndent();
                        try g.w.writeAll("}");
                    } else {
                        try g.w.writeAll(" else if (");
                        try g.genExpr(ei.cond);
                        try g.w.writeAll(") {\n");
                        try g.indented().genStmts(ei.body);
                        try g.writeIndent();
                        try g.w.writeAll("}");
                    }
                }
            } else {
                // Optional-unwrap: `if x as n` or `if x is T as n` — emit Zig optional capture.
                // For the `is T` form the inner expression is the subject; for bare `as` it's cond.
                const inner: *const Ast.Expr = if (s.cond.* == .type_check)
                    s.cond.type_check.expr
                else
                    s.cond;
                try g.w.writeAll("if (");
                try g.genExpr(inner);
                try g.w.print(") |{s}| {{\n", .{cap});
                try g.indented().genStmts(s.then_body);
                try g.writeIndent();
                try g.w.writeAll("}");
                for (s.else_ifs) |ei| {
                    if (ei.is_capture) |ei_cap| {
                        const ei_inner: *const Ast.Expr = if (ei.cond.* == .type_check)
                            ei.cond.type_check.expr
                        else
                            ei.cond;
                        try g.w.writeAll(" else if (");
                        try g.genExpr(ei_inner);
                        try g.w.print(") |{s}| {{\n", .{ei_cap});
                        try g.indented().genStmts(ei.body);
                        try g.writeIndent();
                        try g.w.writeAll("}");
                    } else {
                        try g.w.writeAll(" else if (");
                        try g.genExpr(ei.cond);
                        try g.w.writeAll(") {\n");
                        try g.indented().genStmts(ei.body);
                        try g.writeIndent();
                        try g.w.writeAll("}");
                    }
                }
            }
            if (s.else_body) |eb| {
                try g.w.writeAll(" else {\n");
                try g.indented().genStmts(eb);
                try g.writeIndent();
                try g.w.writeAll("}");
            }
            try g.w.writeAll("\n");
            return;
        }
        try g.w.writeAll("if (");
        try g.genExpr(s.cond);
        try g.w.writeAll(") {\n");
        // Nil narrowing: if cond is `x != nil`, unwrap x with .? inside then_body.
        const narrow_then = nilNarrowVar(s.cond, true);
        const narrow_else = nilNarrowVar(s.cond, false);
        var nn_set = std.StringHashMap(void).init(g.alloc);
        defer nn_set.deinit();
        if (narrow_then) |name| try nn_set.put(name, {});
        const then_g = if (narrow_then != null) g.indented().withNilNarrowed(&nn_set) else g.indented();
        try then_g.genStmts(s.then_body);
        try g.writeIndent();
        try g.w.writeAll("}");
        for (s.else_ifs) |ei| {
            try g.w.writeAll(" else if (");
            try g.genExpr(ei.cond);
            try g.w.writeAll(") {\n");
            try g.indented().genStmts(ei.body);
            try g.writeIndent();
            try g.w.writeAll("}");
        }
        if (s.else_body) |eb| {
            try g.w.writeAll(" else {\n");
            var nn_else_set = std.StringHashMap(void).init(g.alloc);
            defer nn_else_set.deinit();
            if (narrow_else) |name| try nn_else_set.put(name, {});
            const else_g = if (narrow_else != null) g.indented().withNilNarrowed(&nn_else_set) else g.indented();
            try else_g.genStmts(eb);
            try g.writeIndent();
            try g.w.writeAll("}");
        }
        try g.w.writeAll("\n");
    }

    fn genWhile(g: Generator, s: *Ast.StmtWhile) anyerror!void {
        try g.writeIndent();
        if (s.bind) |bind| {
            // `while var c = expr, guard` → while (true) { const c = expr; if (!guard) break; body }
            try g.w.writeAll("while (true) {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.print("const {s} = ", .{bind.name});
            try bg.genExpr(bind.init);
            try bg.w.writeAll(";\n");
            try bg.writeIndent();
            try bg.w.writeAll("if (!(");
            try bg.genExpr(s.cond);
            try bg.w.writeAll(")) break;\n");
            try bg.genStmts(s.body);
            try g.writeIndent();
            try g.w.writeAll("}\n");
            return;
        }
        try g.w.writeAll("while (");
        try g.genExpr(s.cond);
        try g.w.writeAll(") {\n");
        const bg = g.indented();
        try bg.genStmts(s.body);
        if (s.post_body) |pb| {
            // Zig has no built-in post-body; emit as a trailing comment block.
            try bg.line("// post:");
            try bg.genStmts(pb);
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    // ── Char methods (ASCII-aware; full Unicode case/category deferred) ───────

    fn genCharMethod(
        g:      Generator,
        object: *const Ast.Expr,
        method: []const u8,
        args:   []const Ast.Arg,
    ) anyerror!bool {
        _ = args;
        // All char predicates cast to u8 for std.ascii — valid for ASCII range (0..127).
        // Non-ASCII codepoints will return false for isAlpha/isDigit/isWhitespace.
        if (std.mem.eql(u8, method, "isAlpha")) {
            try g.w.writeAll("std.ascii.isAlphabetic(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "isDigit")) {
            try g.w.writeAll("std.ascii.isDigit(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "isWhitespace")) {
            try g.w.writeAll("std.ascii.isWhitespace(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "isUpper")) {
            try g.w.writeAll("std.ascii.isUpper(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "isLower")) {
            try g.w.writeAll("std.ascii.isLower(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "toUpper")) {
            try g.w.writeAll("@as(u21, std.ascii.toUpper(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll("))))");
            return true;
        }
        if (std.mem.eql(u8, method, "toLower")) {
            try g.w.writeAll("@as(u21, std.ascii.toLower(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll("))))");
            return true;
        }
        if (std.mem.eql(u8, method, "toString")) {
            // Encode unicode codepoint (u21) to its UTF-8 byte sequence.
            // Stack-encode into a 4-byte buffer, then dupe to allocator memory.
            try g.w.writeAll("(blk: { var _cpbuf: [4]u8 = undefined; const _cplen = std.unicode.utf8Encode(");
            try g.genExpr(object);
            try g.w.writeAll(", &_cpbuf) catch 1; const _cpout = _allocator.dupe(u8, _cpbuf[0.._cplen]) catch @panic(\"OOM\"); break :blk @as([]const u8, _cpout); })");
            return true;
        }
        return false;
    }

    // ── StringBuilder methods ─────────────────────────────────────────────────

    fn genStringBuilderMethod(
        g:      Generator,
        object: *const Ast.Expr,
        method: []const u8,
        args:   []const Ast.Arg,
    ) anyerror!bool {
        if (std.mem.eql(u8, method, "append")) {
            // sb.append(s) → sb.appendSlice(_allocator, s) catch @panic("OOM")
            try g.genExpr(object);
            try g.w.writeAll(".appendSlice(_allocator, ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch @panic(\"OOM\")");
            return true;
        }
        if (std.mem.eql(u8, method, "appendChar")) {
            // sb.appendChar(c) → sb.append(_allocator, @as(u8, @intCast(c))) catch @panic("OOM")
            try g.genExpr(object);
            try g.w.writeAll(".append(_allocator, @as(u8, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("))) catch @panic(\"OOM\")");
            return true;
        }
        if (std.mem.eql(u8, method, "build")) {
            // sb.build() → owned slice; toOwnedSlice transfers ownership so the
            // deferred deinit becomes a no-op (ArrayList is empty after transfer).
            try g.genExpr(object);
            try g.w.writeAll(".toOwnedSlice(_allocator) catch @panic(\"OOM\")");
            return true;
        }
        if (std.mem.eql(u8, method, "clear")) {
            // sb.clear() → sb.clearRetainingCapacity()
            try g.genExpr(object);
            try g.w.writeAll(".clearRetainingCapacity()");
            return true;
        }
        if (std.mem.eql(u8, method, "len")) {
            // sb.len() → sb.items.len
            try g.genExpr(object);
            try g.w.writeAll(".items.len");
            return true;
        }
        return false;
    }

    fn genForIn(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        // for c in str.chars() — Unicode codepoint iteration via Utf8Iterator
        if (g.isCharsCallOnString(s.iter)) return g.genForInChars(s);

        // for i in start.to(end) — numeric range loop (Zig: while (i < stop) : (i += 1))
        if (isToRangeCall(s.iter)) return g.genForInToRange(s);

        // for x in str.split(delim) — emit while loop over splitSequence iterator
        if (g.isSplitCallOnString(s.iter)) return g.genForInSplit(s);

        // Detect stdlib container types for special iteration patterns.
        if (g.getExprDeclaredType(s.iter)) |tr| {
            if (tr == .generic) {
                if (std.mem.eql(u8, tr.generic.name, "HashMap"))
                    return g.genForInHashMap(s);
                if (std.mem.eql(u8, tr.generic.name, "List"))
                    return g.genForInList(s);
            }
        }
        // Also check list_loop_vars — vars introduced as values in HashMap(K, List(T)) loops.
        if (s.iter.* == .ident) {
            if (g.list_loop_vars) |llv| {
                if (llv.contains(s.iter.ident.name))
                    return g.genForInList(s);
            }
        }
        // for col in hdr where hdr has TC-type csv_row (result of csv.header()/csv.row())
        if (s.iter.* == .ident) {
            const obj_tc = if (g.tc) |tc| tc.expr_types.get(s.iter) orelse .unknown else .unknown;
            if (obj_tc == .csv_row) return g.genForInList(s);
        }
        // for row in csv.rows() / csv.dataRows() / csv.header() / csv.row(n)
        // Capture the returned ArrayList before iterating — avoids use-after-free on temporaries.
        if (s.iter.* == .call) {
            if (s.iter.call.callee.* == .member) {
                const m = s.iter.call.callee.member;
                const obj_tc = if (g.tc) |tc| tc.expr_types.get(m.object) orelse .unknown else .unknown;
                if (obj_tc == .csv_table and (
                    std.mem.eql(u8, m.member, "rows")     or
                    std.mem.eql(u8, m.member, "dataRows") or
                    std.mem.eql(u8, m.member, "header")   or
                    std.mem.eql(u8, m.member, "row")))
                {
                    return g.genForInCsvRows(s);
                }
            }
        }

        // Fallback for struct field accesses (e.g. `m.decls` where `m` is a
        // branch-binding payload from a cross-module union).  The TC cannot
        // infer the type through catch_binding symbols, but in Zebra struct
        // fields that are iterable are always `List(T)` → `std.ArrayListUnmanaged`
        // and therefore need `.items`.  Call-expressions and ident-only cases
        // are already handled above; a bare member access here is always a List.
        if (s.iter.* == .member) return g.genForInList(s);

        // Default: standard Zig for-loop over a slice / range.
        try g.writeIndent();
        try g.w.writeAll("for (");
        try g.genExpr(s.iter);
        try g.w.writeAll(") |");
        for (s.vars, 0..) |v, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.w.writeAll(v);
        }
        try g.w.writeAll("| {\n");
        var bg = g.indented();
        bg.for_else_label = null;  // don't inherit outer for-else label
        if (s.where) |w| {
            try bg.writeIndent();
            try bg.w.writeAll("if (!(");
            try bg.genExpr(w);
            try bg.w.writeAll(")) continue;\n");
        }
        try bg.genStmts(s.body);
        if (s.else_) |else_body| {
            try g.writeIndent();
            try g.w.writeAll("} else {\n");
            try g.indented().genStmts(else_body);
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// True when `e` is a `.to(end)` method call — used for numeric range loops.
    /// Both `n.to(end)` (single arg) shapes are accepted; the receiver becomes `start`.
    fn isToRangeCall(e: *const Ast.Expr) bool {
        if (e.* != .call) return false;
        const c = e.call;
        if (c.args.len != 1) return false;
        if (c.callee.* != .member) return false;
        return std.mem.eql(u8, c.callee.member.member, "to");
    }

    /// `for i in start.to(end)` → numeric range loop. Lowered to:
    ///     { var i: i64 = <start>; const _stop_i: i64 = <end>;
    ///       while (i < _stop_i) : (i += 1) { body } }
    /// Mirrors the `for var in start:end` (StmtForNum) pattern but takes its
    /// arguments from a method-call expression rather than a numeric-range syntax.
    fn genForInToRange(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        const c     = s.iter.call;
        const start = c.callee.member.object;
        const stop  = c.args[0].value;
        const vname = s.vars[0];

        try g.writeIndent();
        try g.w.writeAll("{\n");
        const ig = g.indented();
        try ig.writeIndent();
        try ig.w.print("var {s}: i64 = ", .{vname});
        try ig.genExpr(start);
        try ig.w.writeAll(";\n");
        try ig.writeIndent();
        try ig.w.print("const _stop_{s}: i64 = ", .{vname});
        try ig.genExpr(stop);
        try ig.w.writeAll(";\n");
        var bg = ig.indented();
        bg.for_else_label = null;
        try ig.writeIndent();
        try ig.w.print("while ({s} < _stop_{s}) : ({s} += 1) {{\n", .{ vname, vname, vname });
        if (s.where) |w| {
            try bg.writeIndent();
            try bg.w.writeAll("if (!(");
            try bg.genExpr(w);
            try bg.w.writeAll(")) continue;\n");
        }
        try bg.genStmts(s.body);
        try ig.writeIndent();
        try ig.w.writeAll("}\n");
        if (s.else_) |else_body| {
            try ig.writeIndent();
            try ig.w.writeAll("// for-else: ran to completion\n");
            try ig.genStmts(else_body);
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// `for x in list` — auto-deref to `.items` so bare List vars work without `.items`.
    fn genForInList(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll("for (");
        try g.genExpr(s.iter);
        try g.w.writeAll(".items) |");
        for (s.vars, 0..) |v, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.w.writeAll(v);
        }
        try g.w.writeAll("| {\n");
        var bg = g.indented();
        bg.for_else_label = null;  // don't inherit outer for-else label
        if (s.where) |w| {
            try bg.writeIndent();
            try bg.w.writeAll("if (!(");
            try bg.genExpr(w);
            try bg.w.writeAll(")) continue;\n");
        }
        try bg.genStmts(s.body);
        if (s.else_) |else_body| {
            try g.writeIndent();
            try g.w.writeAll("} else {\n");
            try g.indented().genStmts(else_body);
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// `for k, v in map` or `for k in map` — Zig HashMap iterator pattern.
    fn genForInHashMap(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        const first_var = if (s.vars.len > 0) s.vars[0] else "_k";
        const iter_var   = try std.fmt.allocPrint(g.alloc, "_it_{s}",  .{first_var});
        defer g.alloc.free(iter_var);

        // for-else: wrap while in a labeled block that evaluates to bool
        var fels_lbl: ?[]const u8 = null;
        if (s.else_ != null) {
            const uid = g.nextUid();
            fels_lbl = try std.fmt.allocPrint(g.alloc, "_fels_{x}", .{uid});
            try g.writeIndent();
            try g.w.print("const {s} = {s}: {{\n", .{fels_lbl.?, fels_lbl.?});
        }
        defer { if (fels_lbl) |lbl| g.alloc.free(lbl); }
        // wg = level where `var _it_` and `while` are emitted
        const wg = if (fels_lbl != null) g.indented() else g;

        try wg.writeIndent();
        if (s.vars.len >= 2) {
            // Two-variable form: unpack key and value from iterator entry.
            const entry_var = try std.fmt.allocPrint(g.alloc, "_e_{s}", .{first_var});
            defer g.alloc.free(entry_var);

            // If the HashMap's value type is List(T), mark the value variable
            // so that nested `for elem in v` loops dispatch to genForInList.
            var val_list_vars = std.StringHashMap(void).init(g.alloc);
            defer val_list_vars.deinit();
            var body_gen = wg;
            body_gen.for_else_label = null;
            if (g.getExprDeclaredType(s.iter)) |tr| {
                if (tr == .generic and
                    std.mem.eql(u8, tr.generic.name, "HashMap") and
                    tr.generic.args.len >= 2)
                {
                    const val_tr = tr.generic.args[1];
                    if (val_tr == .generic and
                        std.mem.eql(u8, val_tr.generic.name, "List"))
                    {
                        try val_list_vars.put(s.vars[1], {});
                        body_gen.list_loop_vars = &val_list_vars;
                    }
                }
            }

            try wg.w.print("var {s} = ", .{iter_var});
            try g.genExpr(s.iter);
            try wg.w.writeAll(".iterator();\n");
            try wg.writeIndent();
            try wg.w.print("while ({s}.next()) |{s}| {{\n", .{iter_var, entry_var});
            var bg = body_gen.indented();
            if (fels_lbl) |lbl| bg.for_else_label = lbl;
            try bg.writeIndent();
            try bg.w.print("const {s} = {s}.key_ptr.*;\n",   .{s.vars[0], entry_var});
            if (!nameUsedInStmts(s.vars[0], s.body)) {
                try bg.writeIndent();
                try bg.w.print("_ = {s};\n", .{s.vars[0]});
            }
            try bg.writeIndent();
            try bg.w.print("const {s} = {s}.value_ptr.*;\n", .{s.vars[1], entry_var});
            if (!nameUsedInStmts(s.vars[1], s.body)) {
                try bg.writeIndent();
                try bg.w.print("_ = {s};\n", .{s.vars[1]});
            }
            if (s.where) |w| {
                try bg.writeIndent();
                try bg.w.writeAll("if (!(");
                try bg.genExpr(w);
                try bg.w.writeAll(")) continue;\n");
            }
            try bg.genStmts(s.body);
        } else {
            // Single-variable form: iterate keys only.
            const kptr_var = try std.fmt.allocPrint(g.alloc, "_kp_{s}", .{first_var});
            defer g.alloc.free(kptr_var);

            try wg.w.print("var {s} = ", .{iter_var});
            try g.genExpr(s.iter);
            try wg.w.writeAll(".keyIterator();\n");
            try wg.writeIndent();
            try wg.w.print("while ({s}.next()) |{s}| {{\n", .{iter_var, kptr_var});
            var bg = wg.indented();
            bg.for_else_label = null;
            if (fels_lbl) |lbl| bg.for_else_label = lbl;
            try bg.writeIndent();
            try bg.w.print("const {s} = {s}.*;\n", .{first_var, kptr_var});
            if (!nameUsedInStmts(first_var, s.body)) {
                try bg.writeIndent();
                try bg.w.print("_ = {s};\n", .{first_var});
            }
            if (s.where) |w| {
                try bg.writeIndent();
                try bg.w.writeAll("if (!(");
                try bg.genExpr(w);
                try bg.w.writeAll(")) continue;\n");
            }
            try bg.genStmts(s.body);
        }
        try wg.writeIndent();
        try wg.w.writeAll("}\n");
        if (s.else_) |else_body| {
            try wg.writeIndent();
            try wg.w.print("break :{s} true;\n", .{fels_lbl.?});
            try g.writeIndent();
            try g.w.writeAll("};\n");
            try g.writeIndent();
            try g.w.print("if ({s}) {{\n", .{fels_lbl.?});
            try g.indented().genStmts(else_body);
            try g.writeIndent();
            try g.w.writeAll("}\n");
        }
    }

    /// `for row in csv.rows()` / `for col in csv.header()` etc.
    /// The callee returns an ArrayList; we capture it first to avoid use-after-free on the temporary,
    /// then iterate `.items`.
    fn genForInCsvRows(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        const var_name = if (s.vars.len > 0) s.vars[0] else "_row";
        const iter_var = try std.fmt.allocPrint(g.alloc, "_it_{s}", .{var_name});
        defer g.alloc.free(iter_var);

        // Wrap in a block so the `_it_*` const is scoped — prevents redeclaration
        // errors when the same loop-variable name is used in multiple CSV for-in loops.
        try g.writeIndent();
        try g.w.writeAll("{\n");
        var bg = g.indented();
        bg.for_else_label = null;  // don't inherit outer for-else label
        try bg.writeIndent();
        try bg.w.print("const {s} = ", .{iter_var});
        try bg.genExpr(s.iter);
        try bg.w.writeAll(";\n");
        try bg.writeIndent();
        try bg.w.print("for ({s}.items) |{s}| {{\n", .{iter_var, var_name});
        var bg2 = bg.indented();
        bg2.for_else_label = null;
        if (s.where) |w| {
            try bg2.writeIndent();
            try bg2.w.writeAll("if (!(");
            try bg2.genExpr(w);
            try bg2.w.writeAll(")) continue;\n");
        }
        try bg2.genStmts(s.body);
        try bg.writeIndent();
        try bg.w.writeAll("}\n");
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// `for x in str.split(delim)` / `for x in str.lines()` — while-loop pattern.
    fn genForInSplit(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        const var_name = if (s.vars.len > 0) s.vars[0] else "_part";
        const iter_var = try std.fmt.allocPrint(g.alloc, "_it_{s}", .{var_name});
        defer g.alloc.free(iter_var);

        const recv   = s.iter.call.callee.member.object;
        const method = s.iter.call.callee.member.member;
        const s_args = s.iter.call.args;
        const is_lines = std.mem.eql(u8, method, "lines");

        // for-else: wrap while in a labeled block that evaluates to bool
        var fels_lbl: ?[]const u8 = null;
        if (s.else_ != null) {
            const uid = g.nextUid();
            fels_lbl = try std.fmt.allocPrint(g.alloc, "_fels_{x}", .{uid});
            try g.writeIndent();
            try g.w.print("const {s} = {s}: {{\n", .{fels_lbl.?, fels_lbl.?});
        }
        defer { if (fels_lbl) |lbl| g.alloc.free(lbl); }
        const wg = if (fels_lbl != null) g.indented() else g;

        try wg.writeIndent();
        if (is_lines) {
            // lines() splits on '\n' using the scalar splitter (no allocation)
            try wg.w.print("var {s} = std.mem.splitScalar(u8, ", .{iter_var});
            try g.genExpr(recv);
            try wg.w.writeAll(", '\\n');\n");
        } else {
            try wg.w.print("var {s} = std.mem.splitSequence(u8, ", .{iter_var});
            try g.genExpr(recv);
            try wg.w.writeAll(", ");
            if (s_args.len > 0) try g.genExpr(s_args[0].value) else try wg.w.writeAll("\" \"");
            try wg.w.writeAll(");\n");
        }
        try wg.writeIndent();
        try wg.w.print("while ({s}.next()) |{s}| {{\n", .{iter_var, var_name});
        var bg = wg.indented();
        bg.for_else_label = null;
        if (fels_lbl) |lbl| bg.for_else_label = lbl;
        if (s.where) |w| {
            try bg.writeIndent();
            try bg.w.writeAll("if (!(");
            try bg.genExpr(w);
            try bg.w.writeAll(")) continue;\n");
        }
        try bg.genStmts(s.body);
        try wg.writeIndent();
        try wg.w.writeAll("}\n");
        if (s.else_) |else_body| {
            try wg.writeIndent();
            try wg.w.print("break :{s} true;\n", .{fels_lbl.?});
            try g.writeIndent();
            try g.w.writeAll("};\n");
            try g.writeIndent();
            try g.w.print("if ({s}) {{\n", .{fels_lbl.?});
            try g.indented().genStmts(else_body);
            try g.writeIndent();
            try g.w.writeAll("}\n");
        }
    }

    /// True when `expr` is a call to `str.chars()` on a string — codepoint iteration.
    fn isCharsCallOnString(g: Generator, expr: *const Ast.Expr) bool {
        if (expr.* != .call) return false;
        const callee = expr.call.callee;
        if (callee.* != .member) return false;
        if (!std.mem.eql(u8, callee.member.member, "chars")) return false;
        if (g.getExprDeclaredType(callee.member.object)) |tr| {
            return tr == .named and isStringTypeName(tr.named.name);
        }
        if (g.tc) |tc| {
            const obj_type = tc.expr_types.get(callee.member.object) orelse return false;
            return obj_type == .string;
        }
        return false;
    }

    /// `for c in str.chars()` — iterate Unicode codepoints via Utf8View.
    /// Emits a while loop using `std.unicode.Utf8View.initUnchecked().iterator()`.
    fn genForInChars(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        const var_name = if (s.vars.len > 0) s.vars[0] else "_cp";
        // Monotonic counter — avoids name collisions when the same loop variable
        // name (e.g. `c`) appears in two separate chars() loops.
        const uid = g.nextUid();
        const iter_var = try std.fmt.allocPrint(g.alloc, "_cp_it_{x}", .{uid});
        defer g.alloc.free(iter_var);

        const recv = s.iter.call.callee.member.object;

        // for-else: wrap while in a labeled block that evaluates to bool
        var fels_lbl: ?[]const u8 = null;
        if (s.else_ != null) {
            const fels_uid = g.nextUid();
            fels_lbl = try std.fmt.allocPrint(g.alloc, "_fels_{x}", .{fels_uid});
            try g.writeIndent();
            try g.w.print("const {s} = {s}: {{\n", .{fels_lbl.?, fels_lbl.?});
        }
        defer { if (fels_lbl) |lbl| g.alloc.free(lbl); }
        const wg = if (fels_lbl != null) g.indented() else g;

        try wg.writeIndent();
        try wg.w.print("var {s} = std.unicode.Utf8View.initUnchecked(", .{iter_var});
        try g.genExpr(recv);
        try wg.w.writeAll(").iterator();\n");
        try wg.writeIndent();
        try wg.w.print("while ({s}.nextCodepoint()) |{s}| {{\n", .{iter_var, var_name});
        var bg = wg.indented();
        bg.for_else_label = null;
        if (fels_lbl) |lbl| bg.for_else_label = lbl;
        if (s.where) |w| {
            try bg.writeIndent();
            try bg.w.writeAll("if (!(");
            try bg.genExpr(w);
            try bg.w.writeAll(")) continue;\n");
        }
        try bg.genStmts(s.body);
        try wg.writeIndent();
        try wg.w.writeAll("}\n");
        if (s.else_) |else_body| {
            try wg.writeIndent();
            try wg.w.print("break :{s} true;\n", .{fels_lbl.?});
            try g.writeIndent();
            try g.w.writeAll("};\n");
            try g.writeIndent();
            try g.w.print("if ({s}) {{\n", .{fels_lbl.?});
            try g.indented().genStmts(else_body);
            try g.writeIndent();
            try g.w.writeAll("}\n");
        }
    }

    /// True when `expr` is a call to `str.split(delim)` or `str.lines()` on a string.
    fn isSplitCallOnString(g: Generator, expr: *const Ast.Expr) bool {
        if (expr.* != .call) return false;
        const callee = expr.call.callee;
        if (callee.* != .member) return false;
        const m = callee.member.member;
        if (!std.mem.eql(u8, m, "split") and !std.mem.eql(u8, m, "lines")) return false;
        if (g.getExprDeclaredType(callee.member.object)) |tr| {
            return tr == .named and isStringTypeName(tr.named.name);
        }
        // Also accept when the TC inferred string type for the object.
        if (g.tc) |tc| {
            const obj_type = tc.expr_types.get(callee.member.object) orelse return false;
            return obj_type == .string;
        }
        return false;
    }

    fn genForNum(g: Generator, s: *Ast.StmtForNum) anyerror!void {
        // for-else: wrap while in a labeled block that evaluates to bool
        var fels_lbl: ?[]const u8 = null;
        if (s.else_ != null) {
            const uid = g.nextUid();
            fels_lbl = try std.fmt.allocPrint(g.alloc, "_fels_{x}", .{uid});
            try g.writeIndent();
            try g.w.print("const {s} = {s}: {{\n", .{fels_lbl.?, fels_lbl.?});
        }
        defer { if (fels_lbl) |lbl| g.alloc.free(lbl); }
        const wg = if (fels_lbl != null) g.indented() else g;

        // `for i in start : stop : step` → Zig while loop with explicit counter.
        try wg.writeIndent();
        try wg.w.print("var {s}: i64 = ", .{s.var_});
        try g.genExpr(s.start);
        try wg.w.writeAll(";\n");
        try wg.writeIndent();
        try wg.w.print("while ({s} < ", .{s.var_});
        try g.genExpr(s.stop);
        try wg.w.print(") : ({s} += ", .{s.var_});
        if (s.step) |step| try g.genExpr(step) else try wg.w.writeAll("1");
        try wg.w.writeAll(") {\n");
        var bg = wg.indented();
        bg.for_else_label = null;
        if (fels_lbl) |lbl| bg.for_else_label = lbl;
        try bg.genStmts(s.body);
        try wg.writeIndent();
        try wg.w.writeAll("}\n");
        if (s.else_) |else_body| {
            try wg.writeIndent();
            try wg.w.print("break :{s} true;\n", .{fels_lbl.?});
            try g.writeIndent();
            try g.w.writeAll("};\n");
            try g.writeIndent();
            try g.w.print("if ({s}) {{\n", .{fels_lbl.?});
            try g.indented().genStmts(else_body);
            try g.writeIndent();
            try g.w.writeAll("}\n");
        }
    }

    // Classifies the payload of a union variant for binding purposes.
    //   .ref_payload  → `^T`: Zig switch gives *T; emit `const name = name_ptr.*`.
    //   .list_payload → `List(T)`: inject list_loop_vars so nested for-in uses .items.
    //   .other        → plain value; no special treatment.
    const PayloadKind = enum { ref_payload, list_payload, other };

    fn unionPayloadKind(g: Generator, union_name: []const u8, variant_name: []const u8) PayloadKind {
        if (g.union_decls.get(union_name)) |du| {
            for (du.variants) |vr| {
                if (std.mem.eql(u8, vr.name, variant_name)) {
                    if (vr.payload) |pl| {
                        if (pl == .ref_to) return .ref_payload;
                        if (pl == .generic and std.mem.eql(u8, pl.generic.name, "List"))
                            return .list_payload;
                    }
                    return .other;
                }
            }
        } else if (g.exposed_unions.get(union_name)) |mod_alias| {
            if (g.imported_modules) |imp| {
                if (imp.get(mod_alias)) |iface| {
                    const bv_key = std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ union_name, variant_name }) catch return .other;
                    defer g.alloc.free(bv_key);
                    if (iface.boxed_variants.contains(bv_key)) return .ref_payload;
                }
            }
        }
        return .other;
    }

    fn genBranch(g: Generator, s: *Ast.StmtBranch) anyerror!void {
        // Detect struct field pattern dispatch: any on-clause has a struct_pattern.
        // Lowered to an if-else chain with per-field equality checks.
        const is_struct_pattern = for (s.on) |on| {
            if (on.struct_pattern != null) break true;
        } else false;

        if (is_struct_pattern) {
            try g.writeIndent();
            const tmp = try std.fmt.allocPrint(g.alloc, "_bsp_{x}", .{g.nextUid()});
            defer g.alloc.free(tmp);
            try g.w.writeAll("{\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.print("const {s} = ", .{tmp});
            try bg.genExpr(s.expr);
            try bg.w.writeAll(";\n");
            for (s.on, 0..) |on, ci| {
                try bg.writeIndent();
                if (ci > 0) try bg.w.writeAll("} else ");
                if (on.struct_pattern) |sp| {
                    try bg.w.writeAll("if (");
                    for (sp.fields, 0..) |f, fi| {
                        if (fi > 0) try bg.w.writeAll(" and ");
                        if (f.value.* == .string_lit) {
                            try bg.w.print("std.mem.eql(u8, {s}.{s}, ", .{ tmp, f.name });
                            try bg.genExpr(f.value);
                            try bg.w.writeAll(")");
                        } else {
                            try bg.w.print("{s}.{s} == ", .{ tmp, f.name });
                            try bg.genExpr(f.value);
                        }
                    }
                    if (on.guard) |guard| {
                        if (sp.fields.len > 0) try bg.w.writeAll(" and ");
                        if (on.binding) |bname| {
                            // Guard can reference the binding: declare it first.
                            try bg.w.print("({{ const {s} = {s}; _ = {s}; ", .{ bname, tmp, bname });
                            try bg.genExpr(guard);
                            try bg.w.writeAll("; })");
                        } else {
                            try bg.genExpr(guard);
                        }
                    }
                } else {
                    // Non-struct arm in a struct-pattern branch (shouldn't occur in practice).
                    try bg.w.writeAll("if (true)");
                }
                try bg.w.writeAll(") {\n");
                if (on.binding) |bname| {
                    try bg.indented().writeIndent();
                    try bg.indented().w.print("const {s} = {s};\n", .{ bname, tmp });
                }
                try bg.indented().genStmts(on.body);
            }
            if (s.else_) |eb| {
                try bg.writeIndent();
                try bg.w.writeAll("} else {\n");
                try bg.indented().genStmts(eb);
            }
            if (s.on.len > 0) {
                try bg.writeIndent();
                try bg.w.writeAll("}\n");
            }
            try g.writeIndent();
            try g.w.writeAll("}\n");
            return;
        }

        // Detect union dispatch: any on-clause has a binding name.
        const is_union = for (s.on) |on| { if (on.binding != null) break true; } else false;

        // Detect whether any on-clause has a guard expression.
        const has_guard = for (s.on) |on| { if (on.guard != null) break true; } else false;

        // Detect string dispatch: any on-value is a string literal.
        // Zig cannot switch on []const u8 — lower to if / else-if chains instead.
        const is_string = blk: {
            for (s.on) |on| {
                for (on.values) |v| {
                    if (v.* == .string_lit) break :blk true;
                }
            }
            break :blk false;
        };

        if (is_string) {
            // ── String dispatch: lower to if-else-if chain ────────────────────
            // Hoist subject into a temp so it isn't evaluated N times.
            try g.writeIndent();
            const tmp = try std.fmt.allocPrint(g.alloc, "_bs_{x}", .{g.nextUid()});
            defer g.alloc.free(tmp);
            try g.w.writeAll("{\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.print("const {s} = ", .{tmp});
            try bg.genExpr(s.expr);
            try bg.w.writeAll(";\n");
            for (s.on, 0..) |on, ci| {
                try bg.writeIndent();
                if (ci > 0) try bg.w.writeAll("} else ");
                try bg.w.writeAll("if (");
                for (on.values, 0..) |v, vi| {
                    if (vi > 0) try bg.w.writeAll(" or ");
                    try bg.w.print("std.mem.eql(u8, {s}, ", .{tmp});
                    if (v.* == .string_lit) {
                        try bg.genExpr(v);
                    } else {
                        try bg.genExpr(v);
                    }
                    try bg.w.writeAll(")");
                }
                // AND in the guard for this clause.
                if (on.guard) |guard| {
                    try bg.w.writeAll(" and ");
                    try bg.genExpr(guard);
                }
                try bg.w.writeAll(") {\n");
                try bg.indented().genStmts(on.body);
            }
            if (s.else_) |eb| {
                try bg.writeIndent();
                try bg.w.writeAll("} else {\n");
                try bg.indented().genStmts(eb);
            }
            if (s.on.len > 0) {
                try bg.writeIndent();
                try bg.w.writeAll("}\n");
            }
            try g.writeIndent();
            try g.w.writeAll("}\n");
            return;
        }

        // ── Guarded dispatch (any on-clause has `if condition`) ──────────────
        // Zig switch prongs cannot have guards, so we lower to sequential ifs.
        // Each `if (!_bd and pattern)` check: if the pattern matches but the
        // guard fails, _bd stays false and the next clause can match.
        // Emitted flat (no wrapping block) so `if (!_bd) unreachable` at the end
        // is visible to Zig's return-path analysis.
        if (has_guard) {
            const uid = g.nextUid();
            const bv = try std.fmt.allocPrint(g.alloc, "_bv_{x}", .{uid});
            defer g.alloc.free(bv);
            const bd = try std.fmt.allocPrint(g.alloc, "_bd_{x}", .{uid});
            defer g.alloc.free(bd);
            try g.writeIndent();
            try g.w.print("const {s} = ", .{bv});
            try g.genExpr(s.expr);
            try g.w.writeAll(";\n");
            try g.writeIndent();
            try g.w.print("var {s} = false;\n", .{bd});
            for (s.on) |on| {
                try g.writeIndent();
                try g.w.print("if (!{s}", .{bd});
                if (is_union) {
                    // Union: check the tag, extract payload, then check guard.
                    if (on.values.len == 1) {
                        const v = on.values[0];
                        const tag_name: []const u8 = if (v.* == .member)
                            v.member.member
                        else if (v.* == .call and v.call.callee.* == .member)
                            v.call.callee.member.member
                        else "";
                        if (tag_name.len > 0) {
                            try g.w.print(" and {s} == .{s}", .{ bv, tag_name });
                        }
                    }
                    try g.w.writeAll(") {\n");
                    if (on.binding) |bname| {
                        // Extract the payload before checking the guard.
                        try g.indented().writeIndent();
                        try g.indented().w.print("const {s} = {s}.{s};\n", .{ bname, bv, on.values[0].member.member });
                        // Suppress unused-const Zig warning when the body doesn't
                        // reference the binding.  Only emit when there is no guard:
                        // if a guard is present it already uses bname, and Zig would
                        // report "pointless discard" if we also emitted `_ = bname;`.
                        if (on.guard == null) {
                            try g.indented().writeIndent();
                            try g.indented().w.print("_ = {s};\n", .{bname});
                        }
                        if (on.guard) |guard| {
                            try g.indented().writeIndent();
                            try g.indented().w.writeAll("if (");
                            try g.indented().genExpr(guard);
                            try g.indented().w.writeAll(") {\n");
                            try g.indented().writeIndent();
                            try g.indented().w.print("{s} = true;\n", .{bd});
                            try g.indented().indented().genStmts(on.body);
                            try g.indented().writeIndent();
                            try g.indented().w.writeAll("}\n");
                        } else {
                            try g.indented().writeIndent();
                            try g.indented().w.print("{s} = true;\n", .{bd});
                            try g.indented().indented().genStmts(on.body);
                        }
                    } else {
                        if (on.guard) |guard| {
                            try g.indented().writeIndent();
                            try g.indented().w.writeAll("if (");
                            try g.indented().genExpr(guard);
                            try g.indented().w.writeAll(") {\n");
                            try g.indented().writeIndent();
                            try g.indented().w.print("{s} = true;\n", .{bd});
                            try g.indented().indented().genStmts(on.body);
                            try g.indented().writeIndent();
                            try g.indented().w.writeAll("}\n");
                        } else {
                            try g.indented().writeIndent();
                            try g.indented().w.print("{s} = true;\n", .{bd});
                            try g.indented().indented().genStmts(on.body);
                        }
                    }
                } else {
                    // Non-union (integer / enum): AND the values condition.
                    if (on.values.len > 0) {
                        try g.w.writeAll(" and (");
                        for (on.values, 0..) |v, vi| {
                            if (vi > 0) try g.w.writeAll(" or ");
                            try g.w.print("{s} == ", .{bv});
                            if (v.* == .member) {
                                try g.w.print(".{s}", .{v.member.member});
                            } else {
                                try g.genExpr(v);
                            }
                        }
                        try g.w.writeAll(")");
                    }
                    try g.w.writeAll(") {\n");
                    if (on.guard) |guard| {
                        try g.indented().writeIndent();
                        try g.indented().w.writeAll("if (");
                        try g.indented().genExpr(guard);
                        try g.indented().w.writeAll(") {\n");
                        try g.indented().writeIndent();
                        try g.indented().w.print("{s} = true;\n", .{bd});
                        try g.indented().indented().genStmts(on.body);
                        try g.indented().writeIndent();
                        try g.indented().w.writeAll("}\n");
                    } else {
                        try g.indented().writeIndent();
                        try g.indented().w.print("{s} = true;\n", .{bd});
                        try g.indented().indented().genStmts(on.body);
                    }
                }
                try g.writeIndent();
                try g.w.writeAll("}\n");
            }
            if (s.else_) |eb| {
                try g.writeIndent();
                try g.w.print("if (!{s}) {{\n", .{bd});
                try g.indented().genStmts(eb);
                try g.writeIndent();
                try g.w.writeAll("}\n");
            } else {
                // No else clause: emit `if (!_bd) unreachable` so Zig's control
                // flow analysis sees this path is unreachable (avoids "implicitly
                // returns" on functions where every pattern arm returns a value).
                try g.writeIndent();
                try g.w.print("if (!{s}) unreachable;\n", .{bd});
                // When every on-clause body ends with an explicit return, Zig still
                // thinks the function can "fall off the end" after the `if (!_bd)`
                // check because it sees `_bd == true` as a live path.  In that case
                // add a bare `unreachable;` so the control-flow graph is closed.
                const all_arms_return = blk: {
                    for (s.on) |on| {
                        if (on.body.len == 0) break :blk false;
                        switch (on.body[on.body.len - 1]) {
                            .return_ => {},
                            else    => break :blk false,
                        }
                    }
                    break :blk true;
                };
                if (all_arms_return) {
                    try g.writeIndent();
                    try g.w.writeAll("unreachable;\n");
                }
            }
            return;
        }

        // ── Standard Zig switch dispatch (integer, enum, union) ──────────────
        try g.writeIndent();
        try g.w.writeAll("switch (");
        try g.genExpr(s.expr);
        try g.w.writeAll(") {\n");
        const bg = g.indented();
        for (s.on) |on| {
            try bg.writeIndent();
            for (on.values, 0..) |v, i| {
                if (i > 0) try bg.w.writeAll(", ");
                if (is_union) {
                    // Emit `.variant_name` — extract member part of `Type.variant` or
                    // `Type.variant()` (constructor-call form used in on-clauses) expr.
                    if (v.* == .member) {
                        try bg.w.print(".{s}", .{v.member.member});
                    } else if (v.* == .call and v.call.callee.* == .member) {
                        try bg.w.print(".{s}", .{v.call.callee.member.member});
                    } else {
                        try bg.genExpr(v);
                    }
                } else {
                    // Char/int range: `on c'a'..c'z'` → `'a'...'z'` in Zig switch
                    // Enum member: `on Foo.bar` or `on mod.Foo.bar` → `.bar`
                    if (v.* == .binary and v.binary.op == .dotdot) {
                        try bg.genExpr(v.binary.left);
                        try bg.w.writeAll("...");
                        try bg.genExpr(v.binary.right);
                    } else if (v.* == .member) {
                        try bg.w.print(".{s}", .{v.member.member});
                    } else {
                        try bg.genExpr(v);
                    }
                }
            }
            if (is_union) {
                if (on.binding) |bname| {
                    const v = on.values[0];
                    const variant_name: []const u8 = if (v.* == .member)
                        v.member.member
                    else if (v.* == .call and v.call.callee.* == .member)
                        v.call.callee.member.member
                    else "";
                    const union_name: []const u8 = if (v.* == .member and v.member.object.* == .ident)
                        v.member.object.ident.name
                    else if (v.* == .call and v.call.callee.* == .member and
                             v.call.callee.member.object.* == .ident)
                        v.call.callee.member.object.ident.name
                    else "";
                    const payload_kind = if (variant_name.len > 0 and union_name.len > 0)
                        g.unionPayloadKind(union_name, variant_name)
                    else
                        PayloadKind.other;
                    if (payload_kind == .ref_payload) {
                        // Pointer payload: |bname_ptr| { const bname = bname_ptr.*; ... }
                        try bg.w.print(" => |{s}_ptr| {{\n", .{bname});
                        try bg.indented().writeIndent();
                        try bg.indented().w.print("const {s} = {s}_ptr.*;\n", .{ bname, bname });
                    } else {
                        try bg.w.print(" => |{s}| {{\n", .{bname});
                    }
                    // For List(T) payload bindings, inject list_loop_vars so that any
                    // `for elem in bname` loop inside the body uses genForInList (.items).
                    if (payload_kind == .list_payload) {
                        var llv = std.StringHashMap(void).init(g.alloc);
                        try llv.put(bname, {});
                        var body_gen = bg.indented();
                        body_gen.list_loop_vars = &llv;
                        try body_gen.genStmts(on.body);
                        llv.deinit();
                    } else {
                        try bg.indented().genStmts(on.body);
                    }
                } else {
                    try bg.w.writeAll(" => {\n");
                    try bg.indented().genStmts(on.body);
                }
            } else {
                try bg.w.writeAll(" => {\n");
                try bg.indented().genStmts(on.body);
            }
            try bg.writeIndent();
            try bg.w.writeAll("},\n");
        }
        if (s.else_) |eb| {
            try bg.writeIndent();
            try bg.w.writeAll("else => {\n");
            try bg.indented().genStmts(eb);
            try bg.writeIndent();
            try bg.w.writeAll("},\n");
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    fn genPrint(g: Generator, s: *Ast.StmtPrint) anyerror!void {
        try g.writeIndent();
        if (s.args.len == 0) {
            try g.w.writeAll("std.debug.print(\"\\n\", .{});\n");
            return;
        }

        // If any arg is an allocating string call (including interp), emit each
        // such arg into a named temp so we can defer-free it and avoid GPA leaks.
        var any_alloc = false;
        for (s.args) |a| {
            if (isAllocatingStringInit(a, g.tc) or a.* == .string_interp) {
                any_alloc = true; break;
            }
        }

        if (!any_alloc) {
            // Fast path: no temporaries needed.
            try g.w.writeAll("std.debug.print(\"");
            for (s.args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(" ");
                try g.w.writeAll(printFmt(g.tc, g.catch_var, a));
            }
            try g.w.writeAll("\\n\", .{");
            for (s.args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genExpr(a);
            }
            try g.w.writeAll("});\n");
            return;
        }

        // Slow path: wrap in a block, emit temp + defer for each allocating arg.
        try g.w.writeAll("{\n");
        const bg = g.indented();
        // Collect temp-var names (null = not a temp).
        var tmp_names = std.ArrayList(?[]const u8){};
        try tmp_names.ensureTotalCapacity(g.alloc, s.args.len);
        defer {
            for (tmp_names.items) |tn| if (tn) |n| g.alloc.free(n);
            tmp_names.deinit(g.alloc);
        }
        for (s.args, 0..) |a, i| {
            if (isAllocatingStringInit(a, g.tc) or a.* == .string_interp) {
                const tname = try std.fmt.allocPrint(g.alloc, "_pt{d}", .{i});
                try tmp_names.append(g.alloc, tname);
                try bg.writeIndent();
                try bg.w.print("const {s} = ", .{tname});
                try bg.genExpr(a);
                try bg.w.writeAll(";\n");
            } else {
                try tmp_names.append(g.alloc, null);
            }
        }
        try bg.writeIndent();
        try bg.w.writeAll("std.debug.print(\"");
        for (s.args, 0..) |a, i| {
            if (i > 0) try bg.w.writeAll(" ");
            if (tmp_names.items[i] != null) {
                try bg.w.writeAll("{s}");
            } else {
                try bg.w.writeAll(printFmt(g.tc, g.catch_var, a));
            }
        }
        try bg.w.writeAll("\\n\", .{");
        for (s.args, 0..) |a, i| {
            if (i > 0) try bg.w.writeAll(", ");
            if (tmp_names.items[i]) |tn| {
                try bg.w.writeAll(tn);
            } else {
                try bg.genExpr(a);
            }
        }
        try bg.w.writeAll("});\n");
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// Emit a private `_check_invariant` method that panics when any invariant expression
    /// evaluates to false.  Called inside the struct definition (g is the indented class/struct
    /// generator context).  Inside a generic class the struct is `@This()`, not the class name.
    fn genInvariantCheckFn(g: Generator) anyerror!void {
        try g.writeIndent();
        if (g.is_generic) {
            try g.w.writeAll("fn _check_invariant(self: *@This()) void {\n");
        } else {
            try g.w.print("fn _check_invariant(self: *{s}) void {{\n", .{g.owner});
        }
        const ig = g.indented().asMethod();
        for (g.owner_invariants) |inv_expr| {
            try ig.writeIndent();
            try ig.w.writeAll("if (!(");
            try ig.genExpr(inv_expr);
            try ig.w.print(")) std.debug.panic(\"invariant failed in '{s}'\\n\", .{{}});\n", .{g.owner});
        }
        try g.writeIndent();
        try g.w.writeAll("}\n\n");
    }

    fn genRequireChecks(g: Generator, require: []const *Ast.Expr, context: []const u8) anyerror!void {
        if (g.strip_contracts) return;
        for (require) |req_expr| {
            try g.writeIndent();
            try g.w.writeAll("if (!(");
            try g.genExpr(req_expr);
            try g.w.print(")) std.debug.panic(\"require failed in '{s}'\\n\", .{{}});\n", .{context});
        }
    }

    /// Result of `genEnsureBlock` — describes what the caller's body context needs.
    const EnsureCtx = struct { armed: bool, uses_result: bool };

    /// Emit `const _old_N = expr;` snapshots, `var _result = undefined;` (when result is referenced),
    /// `var _ensure_armed = false;`, and a `defer { if (_ensure_armed and !(check)) panic; }` block.
    /// Returns the context the caller should thread into the body emission so `genReturn` can
    /// arm the flag + capture the return value (see BUG-087).
    /// No-op when ensure is empty or contracts are stripped.
    fn genEnsureBlock(g: Generator, ensure: []const *Ast.Expr, context: []const u8, return_type: ?Ast.TypeRef) anyerror!EnsureCtx {
        if (g.strip_contracts or ensure.len == 0) return .{ .armed = false, .uses_result = false };
        // Detect whether any ensure clause references `result` — if so, the function must
        // have a non-void return type and we'll capture the value into `_result`.
        var uses_result = false;
        for (ensure) |e| { if (containsResultRef(e)) { uses_result = true; break; } }
        if (uses_result and return_type == null) {
            // Static error — result requires a typed return path.
            std.debug.panic("ensure in '{s}' references 'result' but function has no return type", .{context});
        }
        // Collect all old nodes across all ensure exprs (depth-first, left-to-right).
        var old_nodes: std.ArrayListUnmanaged(*Ast.ExprOld) = .{};
        defer old_nodes.deinit(g.alloc);
        for (ensure) |e| try collectOldExprs(e, g.alloc, &old_nodes);
        // Build pointer → index map for substitution during defer-block emit.
        var old_map = std.AutoHashMap(*Ast.ExprOld, usize).init(g.alloc);
        defer old_map.deinit();
        for (old_nodes.items, 0..) |node, i| try old_map.put(node, i);
        // Emit snapshot constants at method entry (before body and before defer registration).
        for (old_nodes.items, 0..) |node, i| {
            try g.writeIndent();
            try g.w.print("const _old_{d} = ", .{i});
            try g.genExpr(node.expr);
            try g.w.writeAll(";\n");
        }
        // Capture variable for `result` references.
        if (uses_result) {
            try g.writeIndent();
            try g.w.writeAll("var _result: ");
            try g.genType(return_type.?);
            try g.w.writeAll(" = undefined;\n");
        }
        // Success-armed flag — defer check fires only when set.
        try g.writeIndent();
        try g.w.writeAll("var _ensure_armed: bool = false;\n");
        // Emit defer block: runs on method exit (LIFO after invariant defer if both present).
        try g.writeIndent();
        try g.w.writeAll("defer {\n");
        const ig = g.indented().withOldMap(&old_map);
        for (ensure) |ens_expr| {
            try ig.writeIndent();
            try ig.w.writeAll("if (_ensure_armed and !(");
            try ig.genExpr(ens_expr);
            try ig.w.print(")) std.debug.panic(\"ensure failed in '{s}'\\n\", .{{}});\n", .{context});
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");
        return .{ .armed = true, .uses_result = uses_result };
    }

    fn genAssert(g: Generator, s: *Ast.StmtAssert) anyerror!void {
        try g.writeIndent();
        if (s.message != null) {
            try g.w.writeAll("if (!(");
            try g.genExpr(s.cond);
            try g.w.writeAll(")) {\n");
            try g.indented().line("std.debug.print(\"assertion failed\\n\", .{});");
            try g.indented().line("unreachable;");
            try g.writeIndent();
            try g.w.writeAll("}\n");
        } else {
            try g.w.writeAll("std.debug.assert(");
            try g.genExpr(s.cond);
            try g.w.writeAll(");\n");
        }
    }

    fn genDefer(g: Generator, s: *Ast.StmtDefer) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll(if (s.is_err) "errdefer " else "defer ");
        switch (s.body) {
            .expr => |e| {
                try g.genExpr(e);
                try g.w.writeAll(";\n");
            },
            else => {
                try g.w.writeAll("{\n");
                try g.indented().genStmt(s.body);
                try g.writeIndent();
                try g.w.writeAll("}\n");
            },
        }
    }

    /// `with target eol Block` — emit a plain block where bare-name assignments
    /// were desugared by AstBuilder to `target.name = value`.
    /// At CodeGen level the body is already correct; just emit a scoped block.
    fn genWith(g: Generator, s: *Ast.StmtWith) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll("{ // with ");
        try g.genExpr(s.target);
        try g.w.writeAll("\n");
        try g.indented().genStmts(s.body);
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// `arena eol Block` — emit a scoped ArenaAllocator that shadows `_allocator`.
    /// All allocations within the block use the sub-arena; freed on block exit.
    ///
    ///   {   // arena
    ///       var _arena_scope = std.heap.ArenaAllocator.init(_allocator);
    ///       defer _arena_scope.deinit();
    ///       const _allocator = _arena_scope.allocator();
    ///       // body
    ///   }
    /// `arena eol Block` — swap `_allocator` to a fresh sub-arena for the block,
    /// then restore the parent allocator on exit.
    ///
    ///   {   // arena
    ///       var _arena_scope = std.heap.ArenaAllocator.init(_allocator);
    ///       const _parent_alloc = _allocator;         // save
    ///       _allocator = _arena_scope.allocator();    // switch to sub-arena
    ///       defer { _allocator = _parent_alloc; _arena_scope.deinit(); }
    ///       // body uses _allocator → sub-arena
    ///   }
    fn genArenaScope(g: Generator, s: *Ast.StmtArenaScope) anyerror!void {
        const depth = g.arena_depth + 1;
        try g.writeIndent();
        try g.w.writeAll("{ // arena\n");
        var ig = g.indented();
        ig.arena_depth = depth;
        try ig.writeIndent(); try ig.w.print("var _arena_scope_{d} = std.heap.ArenaAllocator.init(_allocator);\n", .{depth});
        try ig.writeIndent(); try ig.w.print("const _parent_alloc_{d} = _allocator;\n", .{depth});
        try ig.writeIndent(); try ig.w.print("_allocator = _arena_scope_{d}.allocator();\n", .{depth});
        try ig.writeIndent(); try ig.w.print("defer {{ _allocator = _parent_alloc_{d}; _arena_scope_{d}.deinit(); }}\n", .{ depth, depth });
        try ig.genStmts(s.body);
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// `var name [: T] = base except field=val ...`
    /// Emits: `const name [: T] = blk: { var _tmp = base; _tmp.f = v; break :blk _tmp; };`
    fn genVarExcept(g: Generator, s: *Ast.StmtVarExcept) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll("const ");
        try g.w.writeAll(s.name);
        if (s.type_ref) |tr| {
            try g.w.writeAll(": ");
            try g.genType(tr);
        }
        try g.w.writeAll(" = blk: {\n");
        const ig = g.indented();
        try ig.writeIndent();
        try ig.w.writeAll("var _tmp = ");
        // Inside a method `self` is a pointer (*StructType or *ClassName).
        // `this except ...` must copy the value, not the pointer.
        // Emit `self.*` to dereference and get a value copy.
        const base_is_this = s.base.* == .this;
        try ig.genExpr(s.base);
        if (base_is_this and g.in_method) {
            try ig.w.writeAll(".*");
        }
        try ig.w.writeAll(";\n");
        for (s.fields) |f| {
            try ig.writeIndent();
            try ig.w.writeAll("_tmp.");
            try ig.w.writeAll(f.name);
            try ig.w.writeAll(" = ");
            try ig.genExpr(f.value);
            try ig.w.writeAll(";\n");
        }
        try ig.writeIndent();
        try ig.w.writeAll("break :blk _tmp;\n");
        try g.writeIndent();
        try g.w.writeAll("};\n");
    }

    /// `target = base except field=val ...`
    /// Emits: `target = blk: { var _tmp = base; _tmp.f = v; break :blk _tmp; };`
    fn genAssignExcept(g: Generator, s: *Ast.StmtAssignExcept) anyerror!void {
        try g.writeIndent();
        try g.genExpr(s.target);
        try g.w.writeAll(" = blk: {\n");
        const ig = g.indented();
        try ig.writeIndent();
        try ig.w.writeAll("var _tmp = ");
        // Same deref fix as genVarExcept: `this except` inside a method
        // must dereference the pointer receiver to get a value copy.
        const base_is_this = s.base.* == .this;
        try ig.genExpr(s.base);
        if (base_is_this and g.in_method) {
            try ig.w.writeAll(".*");
        }
        try ig.w.writeAll(";\n");
        for (s.fields) |f| {
            try ig.writeIndent();
            try ig.w.writeAll("_tmp.");
            try ig.w.writeAll(f.name);
            try ig.w.writeAll(" = ");
            try ig.genExpr(f.value);
            try ig.w.writeAll(";\n");
        }
        try ig.writeIndent();
        try ig.w.writeAll("break :blk _tmp;\n");
        try g.writeIndent();
        try g.w.writeAll("};\n");
    }

    // ── raise / try-catch ─────────────────────────────────────────────────────

    fn genRaise(g: Generator, s: *Ast.StmtRaise) anyerror!void {
        // Map to Zebra's thread-local error context + Zig error return.
        try g.writeIndent();
        if (s.message) |msg| {
            if (s.details) |det| {
                // Two-arg form: `raise "msg", details_obj`
                // Determine details type from TypeChecker to pick the right shim.
                const det_type = if (g.tc) |tc| tc.expr_types.get(det) orelse .unknown else .unknown;
                // Unique label from monotonic counter so multiple raises don't collide.
                const uid = g.nextUid();

                const det_is_primitive = switch (det_type) {
                    .int, .uint, .float, .bool, .char,
                    .int_n, .uint_n, .float_n => true,
                    else => false,
                };
                if (det_is_primitive) {
                    const fmt: []const u8 = switch (det_type) {
                        .float, .float_n => "{d}",
                        .char            => "{u}",
                        else             => "{}",
                    };
                    try g.w.print("{{ const _rdet_{x}: []const u8 = std.fmt.allocPrint(_allocator, \"{s}\", .{{", .{ uid, fmt });
                    try g.genExpr(det);
                    try g.w.print("}}) catch @panic(\"OOM\");\n", .{});
                    try g.writeIndent();
                    try g.w.print("  const _rdet_ptr_{x} = _allocator.create([]const u8) catch @panic(\"OOM\");\n", .{uid});
                    try g.writeIndent();
                    try g.w.print("  _rdet_ptr_{x}.* = _rdet_{x};\n", .{uid, uid});
                    try g.writeIndent();
                    try g.w.print("  const _rshim_{x} = struct {{ fn call(p: *anyopaque) []const u8 {{\n", .{uid});
                    try g.writeIndent();
                    try g.w.writeAll("      return @as(*[]const u8, @alignCast(@ptrCast(p))).*;\n");
                    try g.writeIndent();
                    try g.w.print("  }} }};\n", .{});
                    try g.writeIndent();
                    try g.w.writeAll("  _error_ctx = .{ .message = ");
                    try g.genExpr(msg);
                    try g.w.print(", .details = .{{ .ptr = @ptrCast(_rdet_ptr_{x}), .toString_fn = _rshim_{x}.call }} }};\n", .{ uid, uid });
                    try g.writeIndent();
                    try g.w.writeAll("}\n");
                } else if (det_type == .string) {
                    // String details: heap-alloc the slice header so the pointer is stable.
                    try g.w.print("{{ const _rdet_{x}: []const u8 = ", .{uid});
                    try g.genExpr(det);
                    try g.w.print(";\n", .{});
                    try g.writeIndent();
                    try g.w.print("  const _rdet_ptr_{x} = _allocator.create([]const u8) catch @panic(\"OOM\");\n", .{uid});
                    try g.writeIndent();
                    try g.w.print("  _rdet_ptr_{x}.* = _rdet_{x};\n", .{uid, uid});
                    try g.writeIndent();
                    try g.w.print("  const _rshim_{x} = struct {{ fn call(p: *anyopaque) []const u8 {{\n", .{uid});
                    try g.writeIndent();
                    try g.w.writeAll("      return @as(*[]const u8, @alignCast(@ptrCast(p))).*;\n");
                    try g.writeIndent();
                    try g.w.print("  }} }};\n", .{});
                    try g.writeIndent();
                    try g.w.writeAll("  _error_ctx = .{ .message = ");
                    try g.genExpr(msg);
                    try g.w.print(", .details = .{{ .ptr = @ptrCast(_rdet_ptr_{x}), .toString_fn = _rshim_{x}.call }} }};\n", .{ uid, uid });
                    try g.writeIndent();
                    try g.w.writeAll("}\n");
                } else {
                    // Object details: heap-alloc the object, generate type-specific shim.
                    // The type name is inferred from the expression (best-effort: use ident or call callee name).
                    const type_name = detailsTypeName(det);
                    try g.w.print("{{ const _rdet_{x} = _allocator.create({s}) catch @panic(\"OOM\");\n", .{ uid, type_name });
                    try g.writeIndent();
                    try g.w.print("  _rdet_{x}.* = ", .{uid});
                    try g.genExpr(det);
                    try g.w.writeAll(";\n");
                    try g.writeIndent();
                    try g.w.print("  const _rshim_{x} = struct {{ fn call(p: *anyopaque) []const u8 {{\n", .{uid});
                    try g.writeIndent();
                    try g.w.print("      return @as(*{s}, @alignCast(@ptrCast(p))).toString();\n", .{type_name});
                    try g.writeIndent();
                    try g.w.print("  }} }};\n", .{});
                    try g.writeIndent();
                    try g.w.writeAll("  _error_ctx = .{ .message = ");
                    try g.genExpr(msg);
                    try g.w.print(", .details = .{{ .ptr = @ptrCast(_rdet_{x}), .toString_fn = _rshim_{x}.call }} }};\n", .{ uid, uid });
                    try g.writeIndent();
                    try g.w.writeAll("}\n");
                }
            } else {
                // Simple form: message only, no details.
                try g.w.writeAll("_error_ctx = .{ .message = ");
                try g.genExpr(msg);
                try g.w.writeAll(", .details = null };\n");
            }
            try g.writeIndent();
        }
        if (g.try_block_label) |lbl| {
            // Inside a `try` block: record the error into the tracking variable
            // then break out of the labeled block (does not return from the method).
            const ev = g.try_err_var.?;
            try g.w.print("{s} = error.ZebraError;\n", .{ev});
            try g.writeIndent();
            try g.w.print("break :{s};\n", .{lbl});
        } else {
            try g.w.writeAll("return error.ZebraError;\n");
        }
    }

    fn genTryCatch(g: Generator, s: *Ast.StmtTryCatch) anyerror!void {
        // Emit try/catch using an inline labeled block + a ?anyerror tracking variable.
        // This keeps all outer-scope variables accessible (no anonymous function barrier).
        //
        //   var _try_err_XXXX: ?anyerror = null;
        //   _try_blk_XXXX: {
        //       // body — `raise` emits:
        //       //   _error_ctx = ...; _try_err_XXXX = error.ZebraError; break :_try_blk_XXXX;
        //       break :_try_blk_XXXX;  // normal exit
        //   }
        //   if (_try_err_XXXX != null) {
        //       // catch body
        //   }
        //
        // Label/var names are unique-per-try-block via a monotonic counter.
        const ptr_id = g.nextUid();
        const blk_label = try std.fmt.allocPrint(g.alloc, "_try_blk_{x}", .{ptr_id});
        const err_var   = try std.fmt.allocPrint(g.alloc, "_try_err_{x}", .{ptr_id});
        defer g.alloc.free(blk_label);
        defer g.alloc.free(err_var);

        // var/const _try_err_XXXX: ?anyerror = null;
        // Use `var` only when the body may mutate the err variable (via `raise` or
        // `try expr`); otherwise `const` avoids Zig's "never mutated" diagnostic.
        const has_raise = bodyNeedsErrVar(s.body, g.tc) or bodyHasThrowsCall(s.body, g.resolve, g.imported_modules, g.owner_members, g.tc);
        try g.writeIndent();
        try g.w.print("{s} {s}: ?anyerror = null;\n", .{
            if (has_raise) "var" else "const", err_var,
        });

        // _try_blk_XXXX: {
        try g.writeIndent();
        try g.w.print("{s}: {{\n", .{blk_label});

        // Body — `raise` breaks the block and sets err_var.
        const tg = g.indented().withTryLabel(blk_label, err_var);
        try tg.genStmts(s.body);

        // Normal-exit break (no error) — skip if the body's last statement
        // already unconditionally breaks (raise, or throws-call with its own break).
        const body_ends_in_break = blk: {
            if (s.body.len == 0) break :blk false;
            break :blk s.body[s.body.len - 1] == .raise;
        };
        if (!body_ends_in_break) {
            try g.indented().writeIndent();
            try g.w.print("break :{s};\n", .{blk_label});
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");

        // Catch clause(s).
        if (s.clauses.len == 0) return;

        const first = s.clauses[0];
        const catch_name = first.binding orelse "";
        try g.writeIndent();
        try g.w.print("if ({s} != null) {{\n", .{err_var});
        // Generate catch body with the binding name wired to _error_ctx.
        try g.indented().withCatchVar(catch_name).genStmts(first.body);
        try g.writeIndent();
        try g.w.writeAll("}\n");

        for (s.clauses[1..]) |extra| {
            try g.writeIndent();
            try g.w.writeAll("// (additional catch clause — typed dispatch not yet implemented)\n");
            _ = extra;
        }
    }

    fn genGuard(g: Generator, s: *Ast.StmtGuard) anyerror!void {
        // guard cond else { body }  →  if (!(cond)) { body }
        try g.writeIndent();
        try g.w.writeAll("if (!(");
        try g.genExpr(s.cond);
        try g.w.writeAll(")) {\n");
        try g.indented().genStmts(s.else_body);
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    // ── Expressions ───────────────────────────────────────────────────────────

    fn genFloatLit(g: Generator, text: []const u8) !void {
        // Strip _f32/_f64/f32/f64 suffix and emit @as(fNN, value).
        // Zig does not accept C-style suffixed float literals.
        const suffixes = [_]struct { suf: []const u8, ty: []const u8 }{
            .{ .suf = "_f32", .ty = "f32" }, .{ .suf = "_f64", .ty = "f64" },
            .{ .suf = "f32",  .ty = "f32" }, .{ .suf = "f64",  .ty = "f64" },
        };
        for (suffixes) |s| {
            if (std.mem.endsWith(u8, text, s.suf)) {
                const bare = text[0 .. text.len - s.suf.len];
                try g.w.print("@as({s}, {s})", .{ s.ty, bare });
                return;
            }
        }
        try g.w.writeAll(text);
    }

    fn genExpr(g: Generator, expr: *const Ast.Expr) anyerror!void {
        // Expression substitution: used to hoist an allocating receiver out of
        // a return value chain so it can be defer-freed before the return.
        if (g.expr_subst) |sub| {
            if (sub.orig == expr) {
                try g.w.writeAll(sub.name);
                return;
            }
        }
        sw: switch (expr.*) {
            .int_lit       => |e| try g.w.writeAll(e.text),
            .float_lit     => |e| try genFloatLit(g, e.text),
            .bool_lit      => |e| try g.w.writeAll(if (e.value) "true" else "false"),
            .char_lit      => |e| {
                // Two forms:
                //   Legacy:  c'A' or c"A" — strip the 'c' prefix; Zig uses 'A'
                //   New:     'A'           — already valid Zig char literal; emit as-is
                if (e.text.len > 0 and e.text[0] == 'c') {
                    const inner = e.text[1..]; // strip leading 'c'
                    if (inner.len >= 2 and inner[0] == '"') {
                        // c"A" → 'A' (swap delimiters)
                        try g.w.writeByte('\'');
                        try g.w.writeAll(inner[1 .. inner.len - 1]);
                        try g.w.writeByte('\'');
                    } else {
                        try g.w.writeAll(inner); // c'A' → 'A'
                    }
                } else {
                    try g.w.writeAll(e.text); // 'A' → 'A' (no transformation needed)
                }
            },
            .string_lit    => |e| try g.genStringLit(e),
            .string_interp => |e| try g.genStringInterp(e),
            .nil  => try g.w.writeAll("null"),
            .this => try g.w.writeAll(if (g.in_method) "self" else "undefined"),

            .ident  => |*e| try g.genIdent(e),
            .member => |e| {
                // Catch-variable member access: e.message → _error_ctx.message,
                //                               e.details → _error_ctx.details
                if (g.catch_var.len > 0 and e.object.* == .ident and
                    std.mem.eql(u8, e.object.ident.name, g.catch_var))
                {
                    if (std.mem.eql(u8, e.member, "message")) {
                        // Route through _zbr_error_msg() so transitive deps'
                        // error contexts are visible — not just the current
                        // module's own _error_ctx.
                        try g.w.writeAll("_zbr_error_msg()");
                        break :sw;
                    }
                    if (std.mem.eql(u8, e.member, "details")) {
                        try g.w.writeAll("_error_ctx.details");
                        break :sw;
                    }
                }
                // Stdlib property access: list.len → list.items.len, etc.
                if (g.getExprDeclaredType(e.object)) |tr| {
                    if (try g.genStdlibProp(e.object, tr, e.member)) break :sw;
                }
                // TC-type fallback for List/HashMap len/count on unannotated vars.
                if (g.tc) |tc| {
                    const obj_tc = tc.expr_types.get(e.object) orelse .unknown;
                    if (obj_tc == .generic_named) {
                        const gn = obj_tc.generic_named;
                        if (std.mem.eql(u8, gn.sym.name, "List") and
                            (std.mem.eql(u8, e.member, "len") or std.mem.eql(u8, e.member, "count"))) {
                            try g.writeListLen(e.object);
                            break :sw;
                        }
                        if (std.mem.eql(u8, gn.sym.name, "HashMap") and
                            (std.mem.eql(u8, e.member, "len") or std.mem.eql(u8, e.member, "count"))) {
                            try g.genExpr(e.object);
                            try g.w.writeAll(".count()");
                            break :sw;
                        }
                    }
                }
                // TC-type fallback for DateTime field access (unannotated vars).
                if (g.tc) |tc| {
                    const obj_tc = tc.expr_types.get(e.object) orelse .unknown;
                    if (obj_tc == .date_time) {
                        const dt_fields = std.StaticStringMap([]const u8).initComptime(&.{
                            .{ "year", "year" }, .{ "month", "month" }, .{ "day", "day" },
                            .{ "hour", "hour" }, .{ "minute", "minute" }, .{ "second", "second" },
                        });
                        if (dt_fields.get(e.member)) |field| {
                            try g.w.writeAll("_dt_to_gregorian(");
                            try g.genExpr(e.object);
                            try g.w.print(".epoch_ms).{s}", .{field});
                            break :sw;
                        }
                        if (std.mem.eql(u8, e.member, "weekday")) {
                            try g.w.writeAll("_dt_weekday(");
                            try g.genExpr(e.object);
                            try g.w.writeAll(")");
                            break :sw;
                        }
                    }
                }
                // Math constants: Math.PI, Math.E, Math.TAU, Math.INF, Math.NAN
                if (e.object.* == .ident and std.mem.eql(u8, e.object.ident.name, "Math")) {
                    if (std.mem.eql(u8, e.member, "PI"))  { try g.w.writeAll("std.math.pi");      break :sw; }
                    if (std.mem.eql(u8, e.member, "E"))   { try g.w.writeAll("std.math.e");       break :sw; }
                    if (std.mem.eql(u8, e.member, "TAU")) { try g.w.writeAll("std.math.tau");     break :sw; }
                    if (std.mem.eql(u8, e.member, "INF")) { try g.w.writeAll("std.math.inf(f64)"); break :sw; }
                    if (std.mem.eql(u8, e.member, "NAN")) { try g.w.writeAll("std.math.nan(f64)"); break :sw; }
                }
                // Tuple index access: p.0 → p.@"0"
                if (e.member.len > 0 and std.ascii.isDigit(e.member[0])) {
                    try g.genExpr(e.object);
                    try g.w.print(".@\"{s}\"", .{e.member});
                    break :sw;
                }
                // Last-resort List.len: cross-module calls returning List(T) have TC type
                // `.unknown` (generic returns are not preserved in ModuleInterface).
                // When the member is `len` AND the object's type is unknown (not a concrete
                // named type, not a string), assume ArrayList and emit `.items.len`.
                // Use `.len` only (not `count`) to avoid collisions with user struct fields
                // named `count` (e.g. `Counter.count`).
                if (std.mem.eql(u8, e.member, "len")) {
                    const obj_tc = if (g.tc) |tc| tc.expr_types.get(e.object) orelse .unknown else TypeChecker.Type.unknown;
                    if (obj_tc == .unknown) {
                        try g.writeListLen(e.object);
                        break :sw;
                    }
                }
                // Auto-deref for ^T struct fields: `pair.left` → `pair.left.*`
                // when the field's declared TypeRef is ref_to (^T in Zebra).
                // Zig stores the pointer; Zebra semantics expose the dereffed value.
                //
                // BUG-047: class payloads are auto-boxed to `*T` already — `^T` and `^T?`
                // emit as `*T`/`?*T` via the class short-circuit in genType's .ref_to arm.
                // The stored value IS the class value; `.*` would dereference the class pointer
                // itself and produce an invalid Zig expression. Suppress deref for class payloads.
                const field_needs_deref = blk: {
                    const tc = g.tc orelse break :blk false;
                    const obj_type = tc.expr_types.get(e.object) orelse break :blk false;
                    // ① Same-module named type: inspect the scope directly.
                    if (obj_type == .named) {
                        const sym = obj_type.named;
                        if (sym.own_scope) |scope| {
                            const field_sym = scope.lookupLocal(e.member) orelse break :blk false;
                            if (field_sym.decl != .var_) break :blk false;
                            const field_tr = field_sym.decl.var_.type_ orelse break :blk false;
                            if (field_tr != .ref_to) break :blk false;
                            // BUG-047: class/union payloads are pointer-passed; suppress deref.
                            const payload: Ast.TypeRef = if (field_tr.ref_to.* == .nilable)
                                field_tr.ref_to.nilable.*
                            else
                                field_tr.ref_to.*;
                            if (payload == .named) {
                                if (g.isPointerPassedType(payload.named.name)) break :blk false;
                            }
                            break :blk true;
                        }
                        // Exposed cross-module type (`use Mod exposing T`): sym.own_scope is null.
                        // Fall through to look up ref_fields in the imported interface.
                        if (sym.kind == .module and sym.decl == .use) {
                            const use_decl = sym.decl.use;
                            const last_dot = std.mem.lastIndexOf(u8, use_decl.path, ".");
                            const mod_alias = if (last_dot) |d| use_decl.path[d + 1 ..] else use_decl.path;
                            if (!std.mem.eql(u8, sym.name, mod_alias)) {
                                if (g.imported_modules) |imp| {
                                    if (imp.get(mod_alias)) |iface| {
                                        const key = std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ sym.name, e.member }) catch break :blk false;
                                        defer g.alloc.free(key);
                                        break :blk iface.ref_fields.contains(key);
                                    }
                                }
                            }
                        }
                        break :blk false;
                    }
                    // ② Cross-module type: consult ref_fields in the imported interface.
                    if (obj_type == .cross_module) {
                        const cm = obj_type.cross_module;
                        if (g.imported_modules) |imp| {
                            if (imp.get(cm.module)) |iface| {
                                const key = std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ cm.type_name, e.member }) catch break :blk false;
                                defer g.alloc.free(key);
                                break :blk iface.ref_fields.contains(key);
                            }
                        }
                    }
                    break :blk false;
                };
                try g.genExpr(e.object);
                try g.w.writeAll(".");
                try g.w.writeAll(e.member);
                if (field_needs_deref) try g.w.writeAll(".*");
            },
            .call  => |e| try g.genCall(e),

            .index => |e| {
                try g.genExpr(e.object);
                try g.w.writeAll("[");
                // str ([]const u8) requires usize index; i64 variables need a cast.
                const idx_needs_cast = if (g.tc) |tc| blk: {
                    const t = tc.expr_types.get(e.index) orelse .unknown;
                    break :blk t == .int or t == .uint;
                } else false;
                if (idx_needs_cast) try g.w.writeAll("@intCast(");
                try g.genExpr(e.index);
                if (idx_needs_cast) try g.w.writeAll(")");
                try g.w.writeAll("]");
            },
            .slice => |e| {
                try g.genExpr(e.object);
                try g.w.writeAll("[");
                if (e.start) |s| {
                    const needs_cast = if (g.tc) |tc| blk: {
                        const t = tc.expr_types.get(s) orelse .unknown;
                        break :blk t == .int or t == .uint;
                    } else false;
                    if (needs_cast) try g.w.writeAll("@intCast(");
                    try g.genExpr(s);
                    if (needs_cast) try g.w.writeAll(")");
                } else {
                    try g.w.writeAll("0");
                }
                try g.w.writeAll("..");
                if (e.stop) |s| {
                    const needs_cast = if (g.tc) |tc| blk: {
                        const t = tc.expr_types.get(s) orelse .unknown;
                        break :blk t == .int or t == .uint;
                    } else false;
                    if (needs_cast) try g.w.writeAll("@intCast(");
                    try g.genExpr(s);
                    if (needs_cast) try g.w.writeAll(")");
                }
                try g.w.writeAll("]");
            },

            .binary => |e| try g.genBinary(e),
            .unary  => |e| try g.genUnary(e),

            .cast => |e| {
                try g.w.writeAll("@as(");
                try g.genType(e.target);
                try g.w.writeAll(", ");
                try g.genExpr(e.expr);
                try g.w.writeAll(")");
            },
            .to_nilable => |e| {
                // `expr to?` — we don't know the target type here; pass through.
                try g.genExpr(e.expr);
            },
            .to_non_nil => |e| {
                // If the inner ident is already nil-narrowed, genIdent will emit
                // `name.?` itself. Adding another `.?` would produce `name.?.?`.
                // Only append `.?` when the expression is not already unwrapped.
                const already_unwrapped = blk: {
                    if (g.nil_narrowed) |nn| {
                        switch (e.expr.*) {
                            .ident => |ie| break :blk nn.contains(ie.name),
                            else => {},
                        }
                    }
                    break :blk false;
                };
                // Detect `^T?` cross-module fields: `field to!` → `field.?.*`
                // The field stores `?*T` in Zig; `.?` unwraps the optional, `.*` derefs the pointer.
                const needs_ptr_deref = blk: {
                    if (e.expr.* != .member) break :blk false;
                    const mem = e.expr.member;
                    const tc = g.tc orelse break :blk false;
                    const obj_type = tc.expr_types.get(mem.object) orelse break :blk false;
                    // Cross-module type via module.Type syntax.
                    if (obj_type == .cross_module) {
                        const cm = obj_type.cross_module;
                        const imp = g.imported_modules orelse break :blk false;
                        const iface = imp.get(cm.module) orelse break :blk false;
                        const key = std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ cm.type_name, mem.member }) catch break :blk false;
                        defer g.alloc.free(key);
                        break :blk iface.optional_ref_fields.contains(key);
                    }
                    // Exposed cross-module type (`use Mod exposing T`): sym.own_scope is null.
                    if (obj_type == .named) {
                        const sym = obj_type.named;
                        if (sym.own_scope != null) break :blk false;
                        if (sym.kind != .module or sym.decl != .use) break :blk false;
                        const use_decl = sym.decl.use;
                        const last_dot = std.mem.lastIndexOf(u8, use_decl.path, ".");
                        const mod_alias = if (last_dot) |d| use_decl.path[d + 1 ..] else use_decl.path;
                        if (std.mem.eql(u8, sym.name, mod_alias)) break :blk false;
                        const imp = g.imported_modules orelse break :blk false;
                        const iface = imp.get(mod_alias) orelse break :blk false;
                        const key = std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ sym.name, mem.member }) catch break :blk false;
                        defer g.alloc.free(key);
                        break :blk iface.optional_ref_fields.contains(key);
                    }
                    break :blk false;
                };
                try g.genExpr(e.expr);
                if (!already_unwrapped) try g.w.writeAll(".?");
                if (needs_ptr_deref) try g.w.writeAll(".*");
            },
            .is_nil => |e| {
                try g.w.writeAll("(");
                try g.genExpr(e.expr);
                try g.w.writeAll(" == null)");
            },
            .orelse_ => |e| {
                try g.genExpr(e.expr);
                try g.w.writeAll(" orelse ");
                try g.genExpr(e.fallback);
            },
            .catch_ => |e| {
                try g.genExpr(e.expr);
                if (e.err_var) |ev| {
                    try g.w.print(" catch |{s}| ", .{ev});
                } else {
                    try g.w.writeAll(" catch ");
                }
                try g.genExpr(e.fallback);
            },
            .if_expr => |e| {
                try g.w.writeAll("if (");
                try g.genExpr(e.cond);
                try g.w.writeAll(") ");
                try g.genExpr(e.then_expr);
                try g.w.writeAll(" else ");
                try g.genExpr(e.else_expr);
            },
            .lambda   => |e| try g.genLambda(e),
            .list_lit => |e| {
                // `[a, b, c]` lowers to a labeled-block that builds a
                // std.ArrayList(T) and appends each element.  The element
                // type comes from TC's inference of the first element.
                // Empty `[]` requires the LHS annotation to provide T (handled
                // in genLocalVar's list-empty-init special case below); a
                // bare empty list literal in expression position falls back
                // to ArrayList([]const u8) which Zig will reject if used
                // wrong — that's intentional, the caller needs to annotate.
                if (e.elems.len == 0) {
                    try g.w.writeAll("std.ArrayList([]const u8){}");
                } else {
                    const elem_zig: []const u8 = blk: {
                        if (g.tc) |tc| {
                            const t = tc.expr_types.get(e.elems[0]) orelse break :blk "i64";
                            break :blk zigTypeNameOf(t);
                        }
                        break :blk "i64";
                    };
                    const uid = g.nextUid();
                    try g.w.print("(blk_{x}: {{ ", .{uid});
                    try g.w.print("var _ll_{x}: std.ArrayList({s}) = std.ArrayList({s}){{}}; ", .{ uid, elem_zig, elem_zig });
                    for (e.elems) |el| {
                        try g.w.print("_ll_{x}.append(_allocator, ", .{uid});
                        try g.genExpr(el);
                        try g.w.writeAll(") catch @panic(\"OOM\"); ");
                    }
                    try g.w.print("break :blk_{x} _ll_{x}; }})", .{ uid, uid });
                }
            },
            .dict_lit => {
                try g.w.writeAll(
                    "@compileError(\"dict literal: use std.AutoHashMap\")",
                );
            },
            .array_lit => |e| {
                try g.w.writeAll(".{");
                for (e.elems, 0..) |el, i| {
                    if (i > 0) try g.w.writeAll(", ");
                    try g.genExpr(el);
                }
                try g.w.writeAll("}");
            },
            .old     => |e| {
                if (g.old_map) |m| {
                    // Inside ensure defer block: substitute with snapshot variable.
                    const idx = m.get(e) orelse unreachable;
                    try g.w.print("_old_{d}", .{idx});
                } else {
                    // Passthrough outside ensure context (e.g., dead-code path).
                    try g.genExpr(e.expr);
                }
            },
            .result_ => |_| {
                // Always emits `_result` — only valid inside an ensure clause.
                // Resolver/TC reject result outside ensure or in void functions.
                try g.w.writeAll("_result");
            },
            .zig_lit => |e| try g.genZigLit(e),
            .try_ => |e| {
                // `expr?` in Zebra — two meanings depending on the inner type:
                //   - error union → `try expr`   (propagate error to caller)
                //   - optional    → `expr.?`      (force-unwrap; panics if nil)
                // Note: `opt?.field` is parsed as `(try_ opt).field`, so we
                // emit `opt.?.field` — `.?` auto-derefs through `?*T` too.
                // Use optional_unwraps (declared type, pre nil-narrowing) rather than
                // expr_types (which may be narrowed to the non-optional type inside guards).
                const inner_is_optional = if (g.tc) |tc| tc.optional_unwraps.contains(expr) else false;
                if (inner_is_optional) {
                    // If the inner ident is already nil-narrowed, genIdent will emit
                    // `name.?` on its own — don't add a second `.?`.
                    const already_nil_narrowed = blk: {
                        if (g.nil_narrowed) |nn| {
                            if (e.expr.* == .ident) break :blk nn.contains(e.expr.ident.name);
                        }
                        break :blk false;
                    };
                    try g.genExpr(e.expr);
                    if (!already_nil_narrowed) try g.w.writeAll(".?");
                } else if (g.try_block_label) |lbl| {
                    // Inside a try/catch block: redirect errors to the block's
                    // tracking variable and break out, rather than propagating
                    // to the enclosing method.
                    //   expr catch |_c| { _try_err_XXXX = _c; break :blk; }
                    const ev  = g.try_err_var.?;
                    const tmp = try std.fmt.allocPrint(g.alloc, "_tc_{x}", .{g.nextUid()});
                    defer g.alloc.free(tmp);
                    try g.genExpr(e.expr);
                    try g.w.print(" catch |{s}| {{ {s} = {s}; break :{s}; }}", .{ tmp, ev, tmp, lbl });
                } else {
                    try g.w.writeAll("try ");
                    // Suppress auto-try inside genCall — the `try` above already covers it.
                    // g is a value parameter, so shadow it with a mutable copy.
                    var g2 = g;
                    g2.suppress_auto_try = true;
                    try g2.genExpr(e.expr);
                }
            },
            .tuple_lit => |e| {
                // (a, b, c) → .{ @as(T0, a), @as(T1, b), @as(T2, c) }
                // Use @as(T, ...) so Zig can determine the anonymous struct field types.
                try g.w.writeAll(".{ ");
                for (e.elems, 0..) |el, i| {
                    if (i > 0) try g.w.writeAll(", ");
                    if (g.tc) |tc| {
                        const t = tc.expr_types.get(el) orelse .unknown;
                        if (t != .unknown and t != .named) {
                            const zig_t = Builtins.zigTypeName(t.name());
                            if (!std.mem.eql(u8, zig_t, t.name())) {
                                try g.w.print("@as({s}, ", .{zig_t});
                                try g.genExpr(el);
                                try g.w.writeAll(")");
                                continue;
                            }
                        }
                    }
                    try g.genExpr(el);
                }
                try g.w.writeAll(" }");
            },

            // `expr is TypeName`       — class runtime type-tag check.
            // `expr is Union.variant`  — union variant tag check.
            // Parenthesised so unary `not` and other operators bind correctly.
            .type_check => |e| {
                try g.w.writeAll("(");
                try g.genExpr(e.expr);
                if (e.variant_name) |vname| {
                    try g.w.print(" == .{s})", .{vname});
                } else {
                    try g.w.print("._type_tag == _ttag_{s})", .{e.type_name});
                }
            },
        }
    }

    /// Emit an identifier, injecting `self.` when the resolved symbol is a
    /// field and we are inside a method body.
    /// Look up the declared type of an expression.  Only works for direct
    /// identifier references (local vars and parameters that have a type
    /// annotation).  Returns null for everything else.
    fn getExprDeclaredType(g: Generator, expr: *const Ast.Expr) ?Ast.TypeRef {
        if (expr.* == .ident) {
            const sym = g.resolve.exprs.get(&expr.ident) orelse return null;
            return switch (sym.decl) {
                .var_  => |v| v.type_,
                .param => |p| p.type_,
                else   => null,
            };
        }
        // Handle `this.fieldName` — look up the field in the current class's member list.
        if (expr.* == .member) {
            const mem = expr.member;
            if (mem.object.* == .this) {
                for (g.owner_members) |decl| {
                    if (decl == .var_) {
                        const field = decl.var_;
                        if (std.mem.eql(u8, field.name, mem.member)) {
                            return field.type_;
                        }
                    }
                }
                return null;
            }
        }
        // Handle `ClassName.fieldName` — look through the class's member list for the field type.
        if (expr.* == .member) {
            const mem = expr.member;
            if (mem.object.* == .ident) {
                const class_sym = g.resolve.exprs.get(&mem.object.ident) orelse return null;
                const members: []const Ast.Decl = switch (class_sym.decl) {
                    .class   => |c| c.members,
                    .struct_ => |s| s.members,
                    else     => return null,
                };
                for (members) |decl| {
                    if (decl == .var_) {
                        const field = decl.var_;
                        if (std.mem.eql(u8, field.name, mem.member)) {
                            return field.type_;
                        }
                    }
                }
            }
        }
        return null;
    }

    fn genIdent(g: Generator, e: *const Ast.ExprIdent) anyerror!void {
        // Inside a lambda body: captured vars become self.name
        for (g.capture_fields) |cf| {
            if (std.mem.eql(u8, cf, e.name)) {
                try g.w.print("self.{s}", .{e.name});
                return;
            }
        }
        if (g.in_method) {
            if (g.resolve.exprs.get(e)) |sym| {
                if (sym.kind == .var_) {
                    // Shared (static) fields → TypeName.field, not self.field
                    if (sym.decl.var_.mods.static_) {
                        try g.w.print("{s}.{s}", .{g.owner, e.name});
                        return;
                    }
                    // Nil-narrowed field: self.name.?
                    if (g.nil_narrowed) |nn| {
                        if (nn.contains(e.name)) {
                            try g.w.print("self.{s}.?", .{e.name});
                            return;
                        }
                    }
                    try g.w.print("self.{s}", .{e.name});
                    return;
                }
            }
        }
        // Nil-narrowed local: name.?
        if (g.nil_narrowed) |nn| {
            if (nn.contains(e.name)) {
                try g.w.print("{s}.?", .{e.name});
                return;
            }
        }
        try g.w.writeAll(e.name);
    }

    /// Return the `[]const Param` for a callee expression, or null if unavailable.
    /// Used to support named/default arguments at call sites.
    fn lookupParams(g: Generator, e: *Ast.ExprCall) ?[]const Ast.Param {
        if (e.callee.* == .ident) {
            if (g.resolve.exprs.get(&e.callee.ident)) |sym| {
                switch (sym.decl) {
                    .method => |m| return m.params,
                    // Constructor call: ClassName(name: val, ...) — find cue init params.
                    .class  => |c| {
                        for (c.members) |mem| if (mem == .init) return mem.init.params;
                        return null;
                    },
                    .struct_ => |s| {
                        for (s.members) |mem| if (mem == .init) return mem.init.params;
                        return null;
                    },
                    else => return null,
                }
            }
        }
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            const obj_type = if (g.tc) |tc| tc.expr_types.get(mem.object) orelse .unknown else .unknown;
            if (obj_type == .named) {
                const class_sym = obj_type.named;
                if (class_sym.own_scope) |scope| {
                    if (scope.lookupLocal(mem.member)) |method_sym| {
                        if (method_sym.kind == .method) return method_sym.decl.method.params;
                    }
                }
            }
        }
        return null;
    }

    /// Mirror of `lookupParams` that returns the callee's body too, so
    /// `genArgs` can consult `paramNeedsAddrOf` for List/HashMap params
    /// (BUG-091).  Returns null when the callee can't be resolved or has
    /// no body (abstract method, native call, etc.).
    fn lookupCalleeBody(g: Generator, e: *Ast.ExprCall) ?[]const Ast.Stmt {
        if (e.callee.* == .ident) {
            if (g.resolve.exprs.get(&e.callee.ident)) |sym| {
                switch (sym.decl) {
                    .method => |m| return m.body,
                    .class  => |c| {
                        for (c.members) |mem| if (mem == .init) return mem.init.body;
                        return null;
                    },
                    .struct_ => |s| {
                        for (s.members) |mem| if (mem == .init) return mem.init.body;
                        return null;
                    },
                    else => return null,
                }
            }
        }
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            const obj_type = if (g.tc) |tc| tc.expr_types.get(mem.object) orelse .unknown else .unknown;
            if (obj_type == .named) {
                const class_sym = obj_type.named;
                if (class_sym.own_scope) |scope| {
                    if (scope.lookupLocal(mem.member)) |method_sym| {
                        if (method_sym.kind == .method) return method_sym.decl.method.body;
                    }
                }
            }
        }
        return null;
    }

    /// Emit a single argument, boxing value `T` → `*T` when the param is `^T`.
    /// `param_is_ref` = the param's declared type is `.ref_to`; `inner` = the inner TypeRef.
    ///
    /// Class payloads are representation no-ops: a class value is already `*T` via the
    /// auto-box convention, and `^Class` / `^Class?` emit as `*T` / `?*T` (see BUG-041
    /// + concept_zebra-class-auto-box-rule). Boxing the arg into `_allocator.create(...)`
    /// would stack one pointer too many (BUG-045). Detect the class case and fall
    /// through to plain `genArgExpr`.
    fn genBoxedArgExpr(g: Generator, expr: *const Ast.Expr, inner: Ast.TypeRef) anyerror!void {
        const payload: Ast.TypeRef = if (inner == .nilable) inner.nilable.* else inner;
        if (payload == .named) {
            const n = payload.named;
            if (g.class_names.contains(n.name)) {
                try g.genArgExpr(expr);
                return;
            }
            if (std.mem.indexOfScalar(u8, n.name, '.')) |dot| {
                const mod_alias = n.name[0..dot];
                const type_name = n.name[dot + 1 ..];
                const is_class = blk: {
                    const imp = g.imported_modules orelse break :blk false;
                    const iface = imp.get(mod_alias) orelse break :blk false;
                    const kind = iface.types.get(type_name) orelse break :blk false;
                    break :blk kind == .class;
                };
                if (is_class) {
                    try g.genArgExpr(expr);
                    return;
                }
            }
        }
        const uid = g.nextUid();
        const lbl = try std.fmt.allocPrint(g.alloc, "_box_{x}", .{uid});
        defer g.alloc.free(lbl);
        try g.w.print("{s}: {{ const _bp_{x} = _allocator.create(", .{ lbl, uid });
        try g.genType(inner);
        try g.w.print(") catch @panic(\"OOM\"); _bp_{x}.* = ", .{uid});
        try g.genArgExpr(expr);
        try g.w.print("; break :{s} _bp_{x}; }}", .{ lbl, uid });
    }

    /// Emit a comma-separated argument list, honouring named args and defaults.
    /// If params is null or no arg is named, falls back to positional emission.
    /// `body` (when non-null) is the callee's body — used to decide whether a
    /// `List(T)`/`HashMap(K,V)` param is mutated and therefore needs `&` at
    /// the call site (BUG-091).
    fn genArgs(
        g:      Generator,
        params: ?[]const Ast.Param,
        body:   ?[]const Ast.Stmt,
        args:   []const Ast.Arg,
    ) anyerror!void {
        const has_named = for (args) |a| { if (a.name != null) break true; } else false;
        if (!has_named) {
            for (args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                // Box the arg if the corresponding param is ^T.
                if (params) |ps| {
                    if (i < ps.len) {
                        if (ps[i].type_) |pt| if (pt == .ref_to) {
                            try g.genBoxedArgExpr(a.value, pt.ref_to.*);
                            continue;
                        };
                        // BUG-091: take `&` for List/HashMap params mutated by the body.
                        if (paramNeedsAddrOf(ps[i], body, g.alloc, g.tc)) {
                            try g.w.writeAll("&");
                            try g.genArgExpr(a.value);
                            continue;
                        }
                    }
                }
                try g.genArgExpr(a.value);
            }
            return;
        }
        if (params) |ps| {
            // Build a resolved array indexed by param position.
            var resolved = try g.alloc.alloc(?*const Ast.Expr, ps.len);
            defer g.alloc.free(resolved);
            @memset(resolved, null);
            var positional_idx: usize = 0;
            for (args) |a| {
                if (a.name) |name| {
                    for (ps, 0..) |p, pi| {
                        if (std.mem.eql(u8, p.name, name)) { resolved[pi] = a.value; break; }
                    }
                } else {
                    while (positional_idx < ps.len and resolved[positional_idx] != null) : (positional_idx += 1) {}
                    if (positional_idx < ps.len) { resolved[positional_idx] = a.value; positional_idx += 1; }
                }
            }
            for (resolved, 0..) |maybe_expr, i| {
                if (i > 0) try g.w.writeAll(", ");
                const param_is_ref = if (i < ps.len) blk: {
                    const pt = ps[i].type_ orelse break :blk false;
                    break :blk pt == .ref_to;
                } else false;
                const param_needs_addr = if (i < ps.len) paramNeedsAddrOf(ps[i], body, g.alloc, g.tc) else false;
                if (maybe_expr) |expr| {
                    if (param_is_ref) {
                        try g.genBoxedArgExpr(expr, ps[i].type_.?.ref_to.*);
                    } else if (param_needs_addr) {
                        try g.w.writeAll("&");
                        try g.genArgExpr(expr);
                    } else {
                        try g.genArgExpr(expr);
                    }
                } else if (i < ps.len and ps[i].default != null) {
                    if (param_is_ref) {
                        try g.genBoxedArgExpr(ps[i].default.?, ps[i].type_.?.ref_to.*);
                    } else if (param_needs_addr) {
                        try g.w.writeAll("&");
                        try g.genArgExpr(ps[i].default.?);
                    } else {
                        try g.genArgExpr(ps[i].default.?);
                    }
                } else {
                    try g.w.writeAll("undefined"); // missing required arg
                }
            }
        } else {
            // No param info — emit positionally in order written.
            for (args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genArgExpr(a.value);
            }
        }
    }

    /// Emit a single argument expression, prepending `&` when the expression is
    /// a bare fn_ref (function name) being passed to a fn_sig-typed parameter.
    fn genArgExpr(g: Generator, expr: *const Ast.Expr) anyerror!void {
        if (g.tc) |tc| {
            if (tc.fn_ref_args.contains(expr)) {
                try g.w.writeAll("&");
            }
        }
        try g.genExpr(expr);
    }

    fn genCall(g: Generator, e: *Ast.ExprCall) anyerror!void {
        // Generic construction: Stack(int)(42) → Stack(i64).init(42)
        // Detected by type_args.len > 0 (set by AstBuilder.buildGenericConstruct).
        if (e.type_args.len > 0 and e.callee.* == .ident) {
            const class_name = e.callee.ident.name;
            // Stdlib generics: List(T)() → std.ArrayList(T){} (allocator passed to each op)
            if (std.mem.eql(u8, class_name, "List") and e.type_args.len == 1) {
                try g.w.writeAll("std.ArrayList(");
                try g.genType(e.type_args[0]);
                try g.w.writeAll("){}");
                return;
            }
            try g.w.writeAll(class_name);
            try g.w.writeAll("(");
            for (e.type_args, 0..) |ta, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genType(ta);
            }
            try g.w.writeAll(").init(");
            for (e.args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            try g.w.writeAll(")");
            return;
        }

        // Union construction: TypeName.variant(value) → TypeName{ .variant = value }
        // or TypeName.variant() → TypeName{ .variant = {} } for unit variants.
        // e.details.toString() inside a catch block →
        //   if (_error_ctx.details) |_d| _d.toString() else ""
        if (e.callee.* == .member and g.catch_var.len > 0) {
            const mem = e.callee.member;
            if (std.mem.eql(u8, mem.member, "toString") and
                mem.object.* == .member)
            {
                const inner = mem.object.member;
                if (std.mem.eql(u8, inner.member, "details") and
                    inner.object.* == .ident and
                    std.mem.eql(u8, inner.object.ident.name, g.catch_var))
                {
                    try g.w.writeAll("(if (_error_ctx.details) |_det| _det.toString() else \"\")");
                    return;
                }
            }
        }
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            // Cross-module union construction: Module.UnionName.variant(value?)
            // Callee shape: { object: member { object: ident(mod_alias), member: type_name }, member: variant }
            // Emit: mod_alias.TypeName{ .variant = value_or_{} }
            if (mem.object.* == .member) {
                const outer = mem.object.member;
                if (outer.object.* == .ident) {
                    const mod_alias  = outer.object.ident.name;
                    const type_name  = outer.member;
                    const variant    = mem.member;
                    // Confirm the type is a union in the imported module.
                    const is_xmod_union = blk: {
                        const imp = g.imported_modules orelse break :blk false;
                        const iface = imp.get(mod_alias) orelse break :blk false;
                        const kind_ptr = iface.types.getPtr(type_name) orelse break :blk false;
                        break :blk kind_ptr.* == .union_;
                    };
                    if (is_xmod_union) {
                        try g.w.print("{s}.{s}{{ .{s} = ", .{ mod_alias, type_name, variant });
                        if (e.args.len == 1) {
                            // Check whether this cross-module variant's payload is ^T.
                            const box_type: ?[]const u8 = blk: {
                                const imp = g.imported_modules orelse break :blk null;
                                const iface = imp.get(mod_alias) orelse break :blk null;
                                const key = try std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ type_name, variant });
                                defer g.alloc.free(key);
                                break :blk iface.boxed_variants.get(key);
                            };
                            if (box_type) |inner_name| {
                                const uid = g.nextUid();
                                const box_lbl = try std.fmt.allocPrint(g.alloc, "_box_{x}", .{uid});
                                defer g.alloc.free(box_lbl);
                                try g.w.print("{s}: {{ const _bp_{x} = _allocator.create(", .{ box_lbl, uid });
                                try g.w.print("{s}.{s}", .{ mod_alias, inner_name });
                                try g.w.print(") catch @panic(\"OOM\"); _bp_{x}.* = ", .{uid});
                                try g.genExpr(e.args[0].value);
                                try g.w.print("; break :{s} _bp_{x}; }}", .{ box_lbl, uid });
                            } else {
                                try g.genExpr(e.args[0].value);
                            }
                        } else {
                            try g.w.writeAll("{}");
                        }
                        try g.w.writeAll(" }");
                        return;
                    }
                }
            }
            if (mem.object.* == .ident) {
                const type_name = mem.object.ident.name;
                if (g.union_names.contains(type_name) or g.exposed_unions.contains(type_name)) {
                    try g.w.print("{s}{{ .{s} = ", .{type_name, mem.member});
                    if (e.args.len == 1) {
                        // Check whether this variant's payload is ^T (heap-boxed).
                        // For same-module unions: look up union_decls.
                        // For exposed (cross-module) unions: look up boxed_variants via the
                        // stored module alias so the correct qualified inner type is emitted.
                        var box_inner: ?*const Ast.TypeRef = null;
                        var box_xmod_alias: ?[]const u8  = null;
                        var box_xmod_inner: ?[]const u8  = null;
                        if (g.union_decls.get(type_name)) |du| {
                            for (du.variants) |v| {
                                if (std.mem.eql(u8, v.name, mem.member)) {
                                    if (v.payload) |pl| switch (pl) {
                                        .ref_to => |inner| { box_inner = inner; },
                                        else    => {},
                                    };
                                    break;
                                }
                            }
                        } else if (g.exposed_unions.get(type_name)) |mod_alias| {
                            // Cross-module exposed union: consult boxed_variants table.
                            if (g.imported_modules) |imp| {
                                if (imp.get(mod_alias)) |iface| {
                                    const key = try std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ type_name, mem.member });
                                    defer g.alloc.free(key);
                                    if (iface.boxed_variants.get(key)) |inner_name| {
                                        box_xmod_alias = mod_alias;
                                        box_xmod_inner = inner_name;
                                    }
                                }
                            }
                        }
                        if (box_inner) |inner| {
                            const uid = g.nextUid();
                            const box_lbl = try std.fmt.allocPrint(g.alloc, "_box_{x}", .{uid});
                            defer g.alloc.free(box_lbl);
                            try g.w.print("{s}: {{ const _bp_{x} = _allocator.create(", .{ box_lbl, uid });
                            try g.genType(inner.*);
                            try g.w.print(") catch @panic(\"OOM\"); _bp_{x}.* = ", .{uid});
                            try g.genExpr(e.args[0].value);
                            try g.w.print("; break :{s} _bp_{x}; }}", .{ box_lbl, uid });
                        } else if (box_xmod_inner) |inner_name| {
                            const uid = g.nextUid();
                            const box_lbl = try std.fmt.allocPrint(g.alloc, "_box_{x}", .{uid});
                            defer g.alloc.free(box_lbl);
                            try g.w.print("{s}: {{ const _bp_{x} = _allocator.create(", .{ box_lbl, uid });
                            try g.w.print("{s}.{s}", .{ box_xmod_alias.?, inner_name });
                            try g.w.print(") catch @panic(\"OOM\"); _bp_{x}.* = ", .{uid});
                            try g.genExpr(e.args[0].value);
                            try g.w.print("; break :{s} _bp_{x}; }}", .{ box_lbl, uid });
                        } else {
                            try g.genExpr(e.args[0].value);
                        }
                    } else {
                        try g.w.writeAll("{}");
                    }
                    try g.w.writeAll(" }");
                    return;
                }
            }
        }
        // Builtin collection constructors: `List()` → `std.ArrayList(...){}`,
        // `HashMap()` → `std.StringHashMap(...).init(_allocator)`.
        // These appear in assignment RHS and field initializers when no type annotation
        // is available, so we emit the least-typed form that Zig can infer.
        if (e.callee.* == .ident and e.args.len == 0) {
            const name = e.callee.ident.name;
            if (std.mem.eql(u8, name, "List")) {
                // Zero-arg `List()` without LHS type context.
                // Class field assignments now go through genStdlibInit directly (in genAssign),
                // so this path only fires for bare expressions like `return List()` or
                // unannotated local vars. Rely on Zig inference via `.{}` in generic bodies,
                // or emit the untyped ArrayList form for non-generic contexts.
                if (g.is_generic) {
                    try g.w.writeAll(".{}");
                } else {
                    try g.w.writeAll("std.ArrayList([]const u8){}");
                }
                return;
            }
            if (std.mem.eql(u8, name, "HashMap")) {
                try g.w.writeAll("std.StringHashMap(i64).init(_allocator)");
                return;
            }
            if (std.mem.eql(u8, name, "CsvWriter")) {
                try g.w.writeAll("_csv_writer_init()");
                return;
            }
            if (std.mem.eql(u8, name, "CodeEditor")) {
                try g.w.writeAll("_code_editor_new()");
                return;
            }
            // StringBuilder() as an assignment RHS (e.g. class field init in `cue init`).
            // Local `var` declarations are intercepted earlier in genLocalVar.
            if (std.mem.eql(u8, name, "StringBuilder")) {
                try g.w.writeAll("std.ArrayList(u8){}");
                return;
            }
        }
        // Constructor call for exposed class alias: `ExposedClass(args)` after
        // `use Mod exposing ExposedClass` → `ExposedClass.init(args)`.
        // Must be checked before the generic ident-call path below.
        if (e.callee.* == .ident) {
            const cname = e.callee.ident.name;
            if (g.exposed_classes.contains(cname)) {
                try g.w.print("{s}.init(", .{cname});
                // Look up boxing flags from the module interface if available.
                const box_flags: ?[]bool = blk: {
                    if (g.imported_modules) |imp| {
                        var it = imp.iterator();
                        while (it.next()) |entry| {
                            if (entry.value_ptr.struct_init_ref_params.get(cname)) |flags| {
                                break :blk flags;
                            }
                        }
                    }
                    break :blk null;
                };
                for (e.args, 0..) |a, i| {
                    if (i > 0) try g.w.writeAll(", ");
                    if (box_flags) |flags| {
                        if (i < flags.len and flags[i]) {
                            // `nil` literal for a `^T?` param maps to Zig `null`; don't try
                            // to allocate a pointer to null (comptime error with @TypeOf(null)).
                            if (a.value.* == .nil) {
                                try g.w.writeAll("null");
                                continue;
                            }
                            // Need the inner type for boxing: look up ref_fields to get the type name.
                            // For now, emit the labeled-block boxing with anytype inference.
                            const uid = g.nextUid();
                            const lbl = try std.fmt.allocPrint(g.alloc, "_box_{x}", .{uid});
                            defer g.alloc.free(lbl);
                            try g.w.print("{s}: {{ const _bp_{x} = blk2: {{ break :blk2 _allocator.create(@TypeOf(", .{ lbl, uid });
                            try g.genExpr(a.value);
                            try g.w.print(")) catch @panic(\"OOM\"); }}; _bp_{x}.* = ", .{uid});
                            try g.genExpr(a.value);
                            try g.w.print("; break :{s} _bp_{x}; }}", .{ lbl, uid });
                            continue;
                        }
                    }
                    try g.genExpr(a.value);
                }
                try g.w.writeAll(")");
                return;
            }
        }
        // Constructor call: ClassName(args) → ClassName.init(args) if class has `cue init`,
        // else ClassName{} for zero-value construction.
        if (e.callee.* == .ident) {
            const ident = &e.callee.ident;
            if (g.resolve.exprs.get(ident)) |sym| {
                if (sym.kind == .class or sym.kind == .struct_) {
                    const class_name = ident.name;
                    // Scan AST members for a `cue init` declaration (DeclInit).
                    const members: []const Ast.Decl = switch (sym.decl) {
                        .class   => |c| c.members,
                        .struct_ => |s| s.members,
                        else     => &[_]Ast.Decl{},
                    };
                    var has_cue_init = false;
                    for (members) |m| {
                        if (m == .init) { has_cue_init = true; break; }
                    }
                    if (has_cue_init) {
                        try g.w.print("{s}.init(", .{class_name});
                        // Resolve init params for named-arg reordering support.
                        const init_params: ?[]const Ast.Param = blk: {
                            for (members) |m| {
                                if (m == .init) break :blk m.init.params;
                            }
                            break :blk null;
                        };
                        const init_body: ?[]const Ast.Stmt = blk: {
                            for (members) |m| {
                                if (m == .init) break :blk m.init.body;
                            }
                            break :blk null;
                        };
                        try g.genArgs(init_params, init_body, e.args);
                        try g.w.writeAll(")");
                    } else if (sym.kind == .struct_) {
                        // Structs without `cue init`: emit a struct literal.
                        // Named args → .field = value; positional → value (order = declaration order).
                        if (e.args.len == 0) {
                            try g.w.print("{s}{{}}", .{class_name});
                        } else {
                            try g.w.print("{s}{{", .{class_name});
                            for (e.args, 0..) |a, i| {
                                if (i > 0) try g.w.writeAll(",");
                                if (a.name) |n| {
                                    try g.w.print(" .{s} = ", .{n});
                                } else {
                                    try g.w.writeAll(" ");
                                }
                                try g.genExpr(a.value);
                            }
                            try g.w.writeAll(" }");
                        }
                    } else {
                        // No explicit `cue init`: call the synthetic default init().
                        // Every class now has a generated init() that stamps _type_id.
                        try g.w.print("{s}.init()", .{class_name});
                    }
                    return;
                }
            }
        }
        // File I/O static calls: File.read(path), File.write(path, data), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "File")) {
                if (try g.genFileCall(mem.member, e.args)) return;
            }
        }
        // Dir static calls: Dir.create/delete/exists/list/createAll/deleteAll.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Dir")) {
                if (try g.genDirCall(mem.member, e.args)) return;
            }
        }
        // Path static calls: Path.join/basename/dirname/ext/stem/isAbsolute.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Path")) {
                if (try g.genPathCall(mem.member, e.args)) return;
            }
        }
        // Http static calls: Http.get/post/json/postJson/serve.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Http")) {
                if (try g.genHttpCall(mem.member, e.args)) return;
            }
        }
        // Csv static calls: Csv.parse(text), Csv.parseFile(path).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Csv")) {
                if (try g.genCsvCall(mem.member, e.args)) return;
            }
        }
        // DateTime static calls: DateTime.now(), DateTime.fromEpoch(ms), DateTime.of(y,m,d,...).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "DateTime")) {
                if (try g.genDateTimeCall(mem.member, e.args)) return;
            }
        }
        // Reflect static calls: Reflect.className(obj), Reflect.fieldNames(obj), Reflect.fieldTypes(obj).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Reflect")) {
                if (try g.genReflectCall(mem.member, e.args)) return;
            }
        }
        // Hash static calls: Hash.sha256(data), Hash.sha512(data), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Hash")) {
                if (try g.genHashCall(mem.member, e.args)) return;
            }
        }
        // Random static calls: Random.int(min, max), Random.float(), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Random")) {
                if (try g.genRandomCall(mem.member, e.args)) return;
            }
        }
        // Arg static calls: Arg.parse().
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Arg")) {
                if (try g.genArgCall(mem.member, e.args)) return;
            }
        }
        // Terminal static calls: Terminal.print(msg, color), Terminal.width(), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Terminal")) {
                if (try g.genTerminalCall(mem.member, e.args)) return;
            }
        }
        // Log static calls: Log.info(msg), Log.warn(msg), Log.setLevel("warn"), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Log")) {
                if (try g.genLogCall(mem.member, e.args)) return;
            }
        }
        // Uri static calls: Uri.parse(url).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Uri")) {
                if (try g.genUriCall(mem.member, e.args)) return;
            }
        }
        // Compress static calls: Compress.gzip(data), Compress.gunzip(data).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Compress")) {
                if (try g.genCompressCall(mem.member, e.args)) return;
            }
        }
        // Mime static calls: Mime.fromExt(ext), Mime.toExt(mime).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Mime")) {
                if (try g.genMimeCall(mem.member, e.args)) return;
            }
        }
        // Timer static calls: Timer.start().
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Timer")) {
                if (try g.genTimerCall(mem.member, e.args)) return;
            }
        }
        // Json static calls: Json.parse(s), Json.stringify(v), Json.object(), Json.array().
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Json")) {
                if (try g.genJsonCall(mem.member, e.args)) return;
            }
        }
        // Progress static calls: Progress.bar(total, label).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Progress")) {
                if (try g.genProgressCall(mem.member, e.args)) return;
            }
        }
        // HttpResponse factory: HttpResponse.ok(body), HttpResponse.notFound(body), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "HttpResponse")) {
                if (try g.genHttpResponseFactory(mem.member, e.args)) return;
            }
        }
        // Tcp static call: Tcp.connect(host, port).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Tcp")) {
                if (try g.genTcpCall(mem.member, e.args)) return;
            }
        }
        // Udp static call: Udp.socket().
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Udp")) {
                if (try g.genUdpCall(mem.member, e.args)) return;
            }
        }
        // Net static call: Net.resolve(host).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Net")) {
                if (try g.genNetCall(mem.member, e.args)) return;
            }
        }
        // Math static call: Math.sin(x), Math.pow(x,y), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Math")) {
                if (try g.genMathCall(mem.member, e.args)) return;
            }
        }
        // Regex static call: Regex.compile(pattern).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Regex")) {
                if (try g.genRegexCall(mem.member, e.args)) return;
            }
        }
        // Gui static call: Gui.run(title, w, h, callback).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Gui")) {
                if (try g.genGuiCall(mem.member, e.args)) return;
            }
        }
        // CodeEditor static factory: CodeEditor.forZebra() → _code_editor_new()
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "CodeEditor")) {
                try g.w.writeAll("_code_editor_new()");
                return;
            }
        }
        // sys static calls: sys.args(), sys.exit(n), sys.err("msg"), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "sys")) {
                if (try g.genSysCall(mem.member, e.args)) return;
            }
        }
        // Shell static calls: Shell.run(cmd).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Shell")) {
                if (try g.genShellCall(mem.member, e.args)) return;
            }
        }
        // toString() on any value — use TC-inferred type for format specifier.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (std.mem.eql(u8, mem.member, "toString")) {
                const obj_tc = if (g.tc) |tc| tc.expr_types.get(mem.object) orelse .unknown else .unknown;
                // char.toString() — encode the Unicode codepoint as UTF-8 via {u}.
                if (obj_tc == .char) {
                    if (try g.genCharMethod(mem.object, "toString", e.args)) return;
                }
                const fmt: []const u8 = switch (obj_tc) {
                    .float => "{d}",
                    else   => "{}",
                };
                try g.w.print("(std.fmt.allocPrint(_allocator, \"{s}\", .{{", .{fmt});
                try g.genExpr(mem.object);
                try g.w.writeAll("}) catch unreachable)");
                return;
            }
        }
        // Extension method call: obj.method(args) where "TypeName.method" is in ext_methods.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (g.tc) |tc| {
                const obj_type = tc.expr_types.get(mem.object) orelse .unknown;
                const tname_opt: ?[]const u8 = switch (obj_type) {
                    .string         => "String",
                    .int            => "int",
                    .uint           => "uint",
                    .float          => "float",
                    .bool           => "bool",
                    .char           => "char",
                    .string_builder => "StringBuilder",
                    .named          => |sym| switch (sym.decl) {
                        .class     => |c| c.name,
                        .struct_   => |s| s.name,
                        .interface => |i| i.name,
                        else       => null,
                    },
                    else => null,
                };
                if (tname_opt) |tname| {
                    const key = try std.fmt.allocPrint(g.alloc, "{s}.{s}", .{tname, mem.member});
                    defer g.alloc.free(key);
                    if (tc.ext_methods.get(key) != null) {
                        try g.w.print("_ext_{s}_{s}(", .{tname, mem.member});
                        try g.genExpr(mem.object);
                        for (e.args) |a| {
                            try g.w.writeAll(", ");
                            try g.genExpr(a.value);
                        }
                        try g.w.writeAll(")");
                        return;
                    }
                }
            }
        }
        // Stdlib method call: obj.method(args) where obj has a known stdlib type.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (g.getExprDeclaredType(mem.object)) |tr| {
                if (try g.genStdlibMethod(mem.object, tr, mem.member, e.args)) return;
            } else {
                // No declared type annotation — fall back on TC-inferred type.
                // This handles string literals ("hello".method()) and
                // unannotated vars inferred from sys.args() etc.
                // Skip fallback for .named types (user-defined class methods go
                // through genExpr → user struct method call below).
                const tc_type: TypeChecker.Type = blk: {
                    // Inside extension method bodies, `this` has a known self type.
                    if (mem.object.* == .this) {
                        if (g.ext_self_type) |est| break :blk est;
                    }
                    break :blk if (g.tc) |tc| tc.expr_types.get(mem.object) orelse .unknown else .unknown;
                };
                switch (tc_type) {
                    .string     => if (try g.genStringMethod(mem.object, mem.member, e.args)) return,
                    .char       => if (try g.genCharMethod(mem.object, mem.member, e.args)) return,
                    .tcp_conn      => if (try g.genTcpMethod(mem.object, mem.member, e.args)) return,
                    .udp_socket    => if (try g.genUdpMethod(mem.object, mem.member, e.args)) return,
                    .regex         => if (try g.genRegexMethod(mem.object, mem.member, e.args)) return,
                    .gui_context   => if (try g.genGuiWidgetMethod(mem.object, mem.member, e.args)) return,
                    .code_editor   => if (try g.genCodeEditorMethod(mem.object, mem.member, e.args)) return,
                    .str_slice     => if (try g.genStrSliceMethod(mem.object, mem.member, e.args)) return,
                    .json_value    => if (try g.genJsonMethod(mem.object, mem.member, e.args)) return,
                    .date_time     => if (try g.genDateTimeMethod(mem.object, mem.member, e.args)) return,
                    .http_response => if (try g.genHttpResponseMethod(mem.object, mem.member, e.args)) return,
                    .csv_table     => if (try g.genCsvMethod(mem.object, mem.member, e.args)) return,
                    .csv_writer    => if (try g.genCsvWriterMethod(mem.object, mem.member, e.args)) return,
                    .csv_row       => if (try g.genListMethod(mem.object, false, mem.member, e.args)) return,
                    .arg_result    => if (try g.genArgResultMethod(mem.object, mem.member, e.args)) return,
                    .timer_handle  => if (try g.genTimerResultMethod(mem.object, mem.member, e.args)) return,
                    .progress_bar  => if (try g.genProgressBarMethod(mem.object, mem.member, e.args)) return,
                    .unknown       => if (try g.genListMethod(mem.object, false, mem.member, e.args)) return,
                    else           => {},
                }
            }
        }
        // Closure vars (lambdas with capture blocks) are struct instances;
        // call them via .call() instead of direct invocation.
        if (e.callee.* == .ident) {
            if (g.closure_vars) |cv| {
                if (cv.contains(e.callee.ident.name)) {
                    try g.w.writeAll(e.callee.ident.name);
                    try g.w.writeAll(".call(");
                    try g.genArgs(null, null, e.args);
                    try g.w.writeAll(")");
                    return;
                }
            }
        }
        // Bare method call inside an instance method body: `method(args)` → `self.method(args)`.
        // Field idents already get `self.` in genIdent; methods need it here at the call site.
        if (e.callee.* == .ident and g.in_method and g.owner.len > 0) {
            const ident = &e.callee.ident;
            if (g.resolve.exprs.get(ident)) |sym| {
                if (sym.kind == .method) {
                    const is_shared: bool = switch (sym.decl) {
                        .method => |m| m.mods.static_,
                        else    => false,
                    };
                    // Top-level functions have no owner class — call directly.
                    const is_top_level: bool = switch (sym.decl) {
                        .method => |m| m.is_top_level,
                        else    => false,
                    };
                    const bare_params: ?[]const Ast.Param = switch (sym.decl) {
                        .method => |m| m.params,
                        else    => null,
                    };
                    const bare_body: ?[]const Ast.Stmt = switch (sym.decl) {
                        .method => |m| m.body,
                        else    => null,
                    };
                    // Auto-propagate errors: when calling a `throws` method from
                    // inside a `throws` method (and not inside a try/catch block),
                    // emit `try` so Zig doesn't reject the ignored error union.
                    const callee_throws: bool = switch (sym.decl) {
                        .method => |m| m.throws or bodyHasRaise(m.body orelse &.{}, g.tc),
                        else    => false,
                    };
                    if (callee_throws and g.current_method_throws and g.try_block_label == null and !g.suppress_auto_try) {
                        try g.w.writeAll("try ");
                    }
                    if (is_top_level) {
                        try g.w.writeAll(ident.name);
                    } else if (is_shared) {
                        try g.w.print("{s}.{s}", .{ g.owner, ident.name });
                    } else {
                        try g.w.print("self.{s}", .{ident.name});
                    }
                    try g.w.writeAll("(");
                    try g.genArgs(bare_params, bare_body, e.args);
                    try g.w.writeAll(")");
                    return;
                }
            }
        }
        // Cross-module constructor call: `Mod.TypeName(args)` → `Mod.TypeName.init(args)`
        // Detected when the callee is `member_access(module_ident, "TypeName")` and the
        // module's interface exports `TypeName` as a type (not a method).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident) {
                const mod_name = mem.object.ident.name;
                if (g.imported_modules) |imp| {
                    if (imp.get(mod_name)) |iface| {
                        if (iface.types.contains(mem.member)) {
                            // It's a cross-module type constructor.
                            try g.w.print("{s}.{s}.init(", .{ mod_name, mem.member });
                            try g.genArgs(null, null, e.args);
                            try g.w.writeAll(")");
                            return;
                        }
                    }
                }
            }
        }
        // Cross-module `throws` method call: emit `try` when the callee's module
        // interface records the method as throwing and we're in a throws context.
        if (g.current_method_throws and g.try_block_label == null and !g.suppress_auto_try and
            e.callee.* == .member and e.callee.member.object.* == .ident)
        {
            const mod_name = e.callee.member.object.ident.name;
            const method_name = e.callee.member.member;
            if (g.imported_modules) |imp| {
                if (imp.get(mod_name)) |iface| {
                    if (iface.throws_methods.contains(method_name)) {
                        try g.w.writeAll("try ");
                    }
                }
            }
        }
        // Self method call via `.method()` syntax: callee is `this.method_name`.
        // The resolver doesn't store idents for member-access callees, so we walk
        // the owner class/struct members to check if the called method is `throws`.
        // Only emit `try ` prefix when we're in a throws method outside any try block.
        // Inside a try/catch block, `genStmt` handles the catch-and-redirect suffix
        // (see the `exprCallIsThrows` check there, which now covers `this.method()` too).
        if (!g.suppress_auto_try and g.current_method_throws and g.try_block_label == null and
            e.callee.* == .member and e.callee.member.object.* == .this)
        {
            const method_name = e.callee.member.member;
            const callee_throws = for (g.owner_members) |decl| {
                if (decl == .method) {
                    const m = decl.method;
                    if (std.mem.eql(u8, m.name, method_name)) {
                        break m.throws or bodyHasRaise(m.body orelse &.{}, g.tc);
                    }
                }
            } else false;
            if (callee_throws) try g.w.writeAll("try ");
        }
        // BUG-027: expression-position chain fix — `f().method(args)` must materialise
        // the temporary as a mutable `var` so the pointer-receiver method can take `*T`.
        // `(blk_N: { var _mc_N = f(); break :blk_N _mc_N.method(args); })`
        if (e.callee.* == .member and e.callee.member.object.* == .call) {
            const mem = e.callee.member;
            const uid = g.nextUid();
            const chain_throws = exprCallIsThrows(e, g.resolve, g.imported_modules, g.owner_members, g.tc);
            const need_try = chain_throws and g.current_method_throws and g.try_block_label == null and !g.suppress_auto_try;
            try g.w.print("(blk_{x}: {{ var _mc_{x} = ", .{ uid, uid });
            try g.genExpr(mem.object);
            if (need_try) {
                try g.w.print("; break :blk_{x} try _mc_{x}.{s}(", .{ uid, uid, mem.member });
            } else {
                try g.w.print("; break :blk_{x} _mc_{x}.{s}(", .{ uid, uid, mem.member });
            }
            try g.genArgs(g.lookupParams(e), g.lookupCalleeBody(e), e.args);
            try g.w.writeAll("); })");
            return;
        }
        try g.genExpr(e.callee);
        try g.w.writeAll("(");
        try g.genArgs(g.lookupParams(e), g.lookupCalleeBody(e), e.args);
        try g.w.writeAll(")");
    }

    fn genBinary(g: Generator, e: *Ast.ExprBinary) anyerror!void {
        switch (e.op) {
            .div => {
                // Float division uses `/`; integer division uses @divTrunc.
                const is_float = if (g.tc) |tc| blk: {
                    const t = tc.expr_types.get(e.left) orelse .unknown;
                    break :blk t.isFloatFamily();
                } else false;
                if (is_float) {
                    try g.w.writeAll("(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(" / ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                } else {
                    try g.w.writeAll("@divTrunc(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(", ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                }
            },
            .add => {
                // str + str → string concatenation via _str_concat; otherwise numeric add.
                const left_is_str = if (g.tc) |tc|
                    (tc.expr_types.get(e.left) orelse .unknown) == .string
                else false;
                if (left_is_str) {
                    try g.w.writeAll("_str_concat(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(", ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(", _allocator)");
                } else {
                    try g.w.writeAll("(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(" + ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                }
            },
            .int_div => {
                try g.w.writeAll("@divTrunc(");
                try g.genExpr(e.left);
                try g.w.writeAll(", ");
                try g.genExpr(e.right);
                try g.w.writeAll(")");
            },
            .pow => {
                try g.w.writeAll("std.math.pow(f64, ");
                try g.genExpr(e.left);
                try g.w.writeAll(", ");
                try g.genExpr(e.right);
                try g.w.writeAll(")");
            },
            .mod => {
                // Zig's `%` operator on signed integers requires explicit @rem or @mod.
                // Use @mod (mathematical modulo, result has sign of divisor) which matches
                // Zebra's `%` semantics and works for both signed and float types.
                try g.w.writeAll("@mod(");
                try g.genExpr(e.left);
                try g.w.writeAll(", ");
                try g.genExpr(e.right);
                try g.w.writeAll(")");
            },
            .dotdot => {
                try g.genExpr(e.left);
                try g.w.writeAll("..");
                try g.genExpr(e.right);
            },
            .eq, .ne => {
                // For string == / != use std.mem.eql rather than the raw == operator,
                // which Zig does not support on slices.
                // Exception: never use std.mem.eql when one side is nil (null) —
                // that is always a raw null comparison (e.g., optional != nil).
                const either_nil = (e.left.* == .nil or e.right.* == .nil);
                const left_is_str = blk: {
                    if (either_nil) break :blk false;
                    if (g.tc) |tc| {
                        const t = tc.expr_types.get(e.left) orelse .unknown;
                        break :blk t == .string;
                    }
                    break :blk false;
                };
                // If the left side is unknown but the right side is a known string
                // (e.g. a string literal), use std.mem.eql to avoid Zig slice == error.
                const right_is_str = blk: {
                    if (either_nil or left_is_str) break :blk false;
                    if (g.tc) |tc| {
                        const t = tc.expr_types.get(e.right) orelse .unknown;
                        break :blk t == .string;
                    }
                    break :blk false;
                };
                // For user-defined union == / != use std.meta.eql, which Zig requires
                // instead of the raw == operator (tagged unions are not comparable with ==).
                const left_is_union = blk: {
                    if (either_nil or left_is_str or right_is_str) break :blk false;
                    if (g.tc) |tc| {
                        const t = tc.expr_types.get(e.left) orelse .unknown;
                        break :blk t == .named and t.named.kind == .union_;
                    }
                    break :blk false;
                };
                if (left_is_str or right_is_str) {
                    if (e.op == .ne) try g.w.writeAll("!");
                    try g.w.writeAll("std.mem.eql(u8, ");
                    try g.genExpr(e.left);
                    try g.w.writeAll(", ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                } else if (left_is_union) {
                    if (e.op == .ne) try g.w.writeAll("!");
                    try g.w.writeAll("std.meta.eql(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(", ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                } else {
                    try g.w.writeAll("(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(" ");
                    try g.w.writeAll(binaryOpStr(e.op));
                    try g.w.writeAll(" ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                }
            },
            .lt, .le, .gt, .ge => {
                // Use comptime-polymorphic helpers that handle both strings and numerics.
                const helper: []const u8 = switch (e.op) {
                    .lt => "_zebra_lt",
                    .le => "_zebra_le",
                    .gt => "_zebra_gt",
                    .ge => "_zebra_ge",
                    else => unreachable,
                };
                try g.w.writeAll(helper);
                try g.w.writeAll("(");
                try g.genExpr(e.left);
                try g.w.writeAll(", ");
                try g.genExpr(e.right);
                try g.w.writeAll(")");
            },
            .in_ => {
                try g.w.writeAll("_zebra_in(");
                try g.genExpr(e.left);   // item (needle)
                try g.w.writeAll(", ");
                try g.genExpr(e.right);  // container (haystack)
                try g.w.writeAll(")");
            },
            .mul => {
                // str * int → string repetition; otherwise numeric multiply.
                const left_is_str = if (g.tc) |tc|
                    (tc.expr_types.get(e.left) orelse .unknown) == .string
                else false;
                if (left_is_str) {
                    try g.w.writeAll("_str_repeat(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(", ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(", _allocator)");
                } else {
                    try g.w.writeAll("(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(" * ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                }
            },
            else => {
                try g.w.writeAll("(");
                try g.genExpr(e.left);
                try g.w.writeAll(" ");
                try g.w.writeAll(binaryOpStr(e.op));
                try g.w.writeAll(" ");
                try g.genExpr(e.right);
                try g.w.writeAll(")");
            },
        }
    }

    fn genUnary(g: Generator, e: *Ast.ExprUnary) anyerror!void {
        switch (e.op) {
            .neg     => { try g.w.writeAll("(-"); try g.genExpr(e.operand); try g.w.writeAll(")"); },
            .not_    => { try g.w.writeAll("(!"); try g.genExpr(e.operand); try g.w.writeAll(")"); },
            .bit_not => { try g.w.writeAll("(~"); try g.genExpr(e.operand); try g.w.writeAll(")"); },
            .old     => try g.genExpr(e.operand), // contract pre-value → pass through
        }
    }

    fn genStringLit(g: Generator, e: Ast.ExprStringLit) anyerror!void {
        switch (e.kind) {
            .plain => {
                // Triple-quoted doc string """...""" (single-line or multiline).
                if (e.text.len >= 6 and e.text[0] == '"' and e.text[1] == '"' and e.text[2] == '"') {
                    // Strip opening and closing """ delimiters.
                    // For multiline, the content includes embedded newlines.
                    const inner = e.text[3 .. e.text.len - 3];
                    // Strip leading newline (the one right after opening """).
                    const after_lead = if (inner.len > 0 and inner[0] == '\n') inner[1..] else inner;
                    // Strip trailing whitespace-only tail (indentation of closing """).
                    var trim_end = after_lead.len;
                    while (trim_end > 0 and
                           (after_lead[trim_end - 1] == ' ' or after_lead[trim_end - 1] == '\t'))
                        : (trim_end -= 1) {}
                    const content = after_lead[0..trim_end];
                    try g.w.writeByte('"');
                    for (content) |c| switch (c) {
                        '"'  => try g.w.writeAll("\\\""),
                        '\n' => try g.w.writeAll("\\n"),
                        '\r' => try g.w.writeAll("\\r"),
                        '\t' => try g.w.writeAll("\\t"),
                        else => try g.w.writeByte(c),
                    };
                    try g.w.writeByte('"');
                    return;
                }
                // If the Zebra source used single-quotes, re-emit as double-quoted Zig string.
                // Zig only allows single-quotes for character literals (single codepoint).
                if (e.text.len >= 2 and e.text[0] == '\'') {
                    const inner = e.text[1 .. e.text.len - 1]; // strip outer single quotes
                    try g.w.writeByte('"');
                    for (inner) |c| switch (c) {
                        '"'  => try g.w.writeAll("\\\""),
                        '\n' => try g.w.writeAll("\\n"),
                        '\r' => try g.w.writeAll("\\r"),
                        '\t' => try g.w.writeAll("\\t"),
                        else => try g.w.writeByte(c),
                    };
                    try g.w.writeByte('"');
                } else {
                    try g.w.writeAll(e.text);
                }
            },
            .raw   => {
                // r"..." / r'...' — backslashes are literal, not escape sequences.
                // e.text is the full source token including the r prefix and quotes.
                // Emit as a Zig double-quoted string with backslashes doubled.
                const content = e.text[2 .. e.text.len - 1]; // strip r, open-quote, close-quote
                try g.w.writeByte('"');
                for (content) |c| switch (c) {
                    '\\' => try g.w.writeAll("\\\\"),
                    '"'  => try g.w.writeAll("\\\""),
                    '\n' => try g.w.writeAll("\\n"),
                    '\r' => try g.w.writeAll("\\r"),
                    '\t' => try g.w.writeAll("\\t"),
                    else => try g.w.writeByte(c),
                };
                try g.w.writeByte('"');
            },
            .nosub => {
                // ns"..." → strip 'ns' prefix.
                try g.w.writeAll(e.text[2..]);
            },
            .zig => {
                // zig"..." → strip 'zig' prefix and surrounding quotes; emit inner content.
                if (e.text.len >= 5) try g.w.writeAll(e.text[4 .. e.text.len - 1]);
            },
        }
    }

    /// Emit `try std.fmt.allocPrint(_allocator, "fmt", .{args...})`.
    ///
    /// Format string construction rules:
    ///   - literal parts: `{` → `{{`, `}` → `}}`, rest verbatim
    ///   - expr parts: `{s}` / `{}` / `{u}` / `{any}` based on type; or `{fmt}`
    ///     if a `.format` part immediately follows
    fn genStringInterp(g: Generator, e: Ast.ExprStringInterp) anyerror!void {
        // ── Build format string ──────────────────────────────────────────────
        var fmt_buf = std.ArrayList(u8){};
        defer fmt_buf.deinit(g.alloc);

        // Per-arg unsigned cast type (null = no cast needed).
        // Needed when a bit-repr spec (x/X/o/b) is applied to a signed integer:
        // Zig prepends '+' for positive signed ints, which is wrong for hex dumps.
        var cast_types = std.ArrayList(?[]const u8){};
        defer cast_types.deinit(g.alloc);

        // Per-arg flag: true when the expr has a named type with toString() —
        // emit `.toString()` call suffix and use {s} format.
        var needs_tostring = std.ArrayList(bool){};
        defer needs_tostring.deinit(g.alloc);

        var i: usize = 0;
        while (i < e.parts.len) : (i += 1) {
            switch (e.parts[i]) {
                .literal => |lit| {
                    // Escape `{` and `}` so they don't confuse std.fmt.
                    for (lit) |c| {
                        if (c == '{' or c == '}') {
                            try fmt_buf.writer(g.alloc).writeByte(c);
                            try fmt_buf.writer(g.alloc).writeByte(c);
                        } else {
                            try fmt_buf.writer(g.alloc).writeByte(c);
                        }
                    }
                },
                .expr => |ex| {
                    // Check if next part is a format spec.
                    const has_fmt = (i + 1 < e.parts.len) and
                        switch (e.parts[i + 1]) { .format => true, else => false };
                    if (has_fmt) {
                        const raw_spec = switch (e.parts[i + 1]) { .format => |s| s, else => unreachable };
                        const ex_type = if (g.tc) |tc| tc.expr_types.get(ex) orelse .unknown else .unknown;
                        try fmt_buf.writer(g.alloc).writeByte('{');
                        try writeZigFmtSpec(fmt_buf.writer(g.alloc), raw_spec, ex_type);
                        try fmt_buf.writer(g.alloc).writeByte('}');
                        try cast_types.append(g.alloc, castTypeForBitSpec(raw_spec, ex_type));
                        try needs_tostring.append(g.alloc, false);
                        i += 1; // skip the consumed format part
                    } else {
                        // Implicit toString: named type with a toString() method → {s}.
                        const ts = if (g.tc) |tc| blk: {
                            const et = tc.expr_types.get(ex) orelse break :blk false;
                            if (et != .named) break :blk false;
                            const scope = et.named.own_scope orelse break :blk false;
                            break :blk scope.lookupLocal("toString") != null;
                        } else false;
                        if (ts) {
                            try fmt_buf.writer(g.alloc).writeAll("{s}");
                        } else {
                            const spec = printFmt(g.tc, g.catch_var, ex);
                            try fmt_buf.writer(g.alloc).writeAll(spec);
                        }
                        try cast_types.append(g.alloc, null);
                        try needs_tostring.append(g.alloc, ts);
                    }
                },
                .format => unreachable, // consumed above
            }
        }

        // ── Emit call ────────────────────────────────────────────────────────
        try g.w.writeAll("(std.fmt.allocPrint(_allocator, \"");
        // Write the format string with escaped backslashes and double-quotes.
        for (fmt_buf.items) |c| {
            if (c == '"')  { try g.w.writeAll("\\\""); }
            else if (c == '\\') { try g.w.writeAll("\\\\"); }
            else try g.w.writeByte(c);
        }
        try g.w.writeAll("\", .{");

        // Emit the expression arguments (only .expr parts).
        var first = true;
        var arg_idx: usize = 0;
        for (e.parts) |part| {
            switch (part) {
                .expr => |ex| {
                    if (!first) try g.w.writeAll(", ");
                    first = false;
                    const cast = if (arg_idx < cast_types.items.len) cast_types.items[arg_idx] else null;
                    const ts = arg_idx < needs_tostring.items.len and needs_tostring.items[arg_idx];
                    if (cast) |ut| {
                        try g.w.print("@as({s}, @bitCast(", .{ut});
                        try g.genExpr(ex);
                        try g.w.writeAll("))");
                    } else if (ts) {
                        try g.genExpr(ex);
                        try g.w.writeAll(".toString()");
                    } else {
                        try g.genExpr(ex);
                    }
                    arg_idx += 1;
                },
                else => {},
            }
        }
        try g.w.writeAll("}) catch @panic(\"OOM\"))");
    }

    fn genZigLit(g: Generator, e: Ast.ExprZigLit) anyerror!void {
        // e.text is "zig\"...\"" or "zig'...'" (raw source).
        // Layout: z i g <quote-char> <content...> <quote-char>
        //         0 1 2  3            4..len-2      len-1
        if (e.text.len >= 5) try g.w.writeAll(e.text[4 .. e.text.len - 1]);
    }

    fn genLambda(g: Generator, e: *Ast.ExprLambda) anyerror!void {
        // Emit as an anonymous struct with a `call` method — the standard Zig
        // idiom for lambdas.
        //
        // Without capture:
        //   struct { fn call(params) RetT { body } }.call
        //
        // With capture (explicit `capture` block):
        //   (struct { field1: T1, field2: T2, ...,
        //             fn call(self: *@This(), params) RetT { body } }
        //   { .field1 = init1, .field2 = init2, ... }).call

        const has_capture = e.capture.len > 0;

        if (has_capture) try g.w.writeAll("(");
        try g.w.writeAll("struct {");

        // Capture fields
        if (has_capture) {
            try g.w.writeAll("\n");
            const fg = g.indented();
            for (e.capture) |cv| {
                try fg.writeIndent();
                try fg.w.writeAll(cv.name);
                try fg.w.writeAll(": ");
                if (cv.type_) |tr| {
                    try fg.genType(tr);
                } else if (cv.init) |init| {
                    try fg.w.writeAll("@TypeOf(");
                    try fg.genExpr(init);
                    try fg.w.writeAll(")");
                } else {
                    try fg.w.writeAll("anytype");
                }
                try fg.w.writeAll(",\n");
            }
            try g.writeIndent();
        }

        // Determine if any capture field is directly reassigned in the body.
        // If so, `call` takes `self: *@This()` so the mutation is visible to the caller.
        // If not (or no captures), `self: @This()` (by-value) is used; for class-pointer
        // captures this is fine because mutation goes through the pointer, not the field.
        var any_capture_mutated = false;
        if (has_capture) {
            const body_stmts_lam: []const Ast.Stmt = switch (e.body) {
                .stmts => |ss| ss,
                .expr  => &.{},
            };
            var body_mutations_lam = try scanMutations(body_stmts_lam, g.alloc, g.tc);
            defer body_mutations_lam.deinit();
            for (e.capture) |cv| {
                if (body_mutations_lam.contains(cv.name)) { any_capture_mutated = true; break; }
            }
        }

        // call method
        try g.w.writeAll(" fn call(");
        var first = true;
        if (has_capture) {
            if (any_capture_mutated) {
                try g.w.writeAll("self: *@This()");
            } else {
                try g.w.writeAll("self: @This()");
            }
            first = false;
        }
        for (e.params) |p| {
            if (!first) try g.w.writeAll(", ");
            first = false;
            try g.w.writeAll(p.name);
            try g.w.writeAll(": ");
            if (p.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
        }
        try g.w.writeAll(") ");
        // Return type: use declared type if present, else infer:
        //   - Expression body → @TypeOf(expr) (valid in Zig when params are typed)
        //   - Statement body  → walk body for first `return expr`; use TC type or void
        if (e.return_type) |rt| {
            try g.genType(rt);
        } else {
            switch (e.body) {
                .expr => |ex| {
                    try g.w.writeAll("@TypeOf(");
                    try g.genExpr(ex);
                    try g.w.writeAll(")");
                },
                .stmts => |ss| {
                    // Find first `return expr` and query TypeChecker for its type.
                    const inferred = blk: {
                        if (g.tc) |tc| {
                            for (ss) |stmt| {
                                if (stmt == .return_ and stmt.return_.value != null) {
                                    const t = tc.expr_types.get(stmt.return_.value.?) orelse break :blk TypeChecker.Type.void_;
                                    break :blk t;
                                }
                            }
                        }
                        break :blk TypeChecker.Type.void_;
                    };
                    try g.w.writeAll(zigTypeNameOf(inferred));
                },
            }
        }
        try g.w.writeAll(" {");
        // Build capture_fields list so idents inside the body emit `self.name`
        var cap_names = std.ArrayList([]const u8){};
        defer cap_names.deinit(g.alloc);
        for (e.capture) |cv| try cap_names.append(g.alloc, cv.name);
        const lg = g.asMethod().withCaptureFields(cap_names.items);
        switch (e.body) {
            .expr  => |ex| {
                try lg.w.writeAll(" return ");
                try lg.genExpr(ex);
                try lg.w.writeAll(";");
            },
            .stmts => |ss| {
                var mut_set_lambda = try scanMutations(ss, g.alloc, g.tc);
                defer mut_set_lambda.deinit();
                var ret_set_lambda = try analyzeEscapes(ss, g.alloc);
                defer ret_set_lambda.deinit();
                try lg.w.writeAll("\n");
                // withInLambda clears the outer-fn ensure context so `return` inside
                // the lambda body is NOT rewritten to outer-fn `_result` capture.
                try lg.indented().withMutated(&mut_set_lambda).withReturnedNames(&ret_set_lambda).withInLambda().genStmts(ss);
                try lg.writeIndent();
            },
        }
        try g.w.writeAll(" }");
        try g.w.writeAll(" }");

        // Capture initialiser
        if (has_capture) {
            // Emit struct instance; panel/callback sites call .call(arg) on it.
            try g.w.writeAll("{ ");
            for (e.capture) |cv| {
                try g.w.writeAll(".");
                try g.w.writeAll(cv.name);
                try g.w.writeAll(" = ");
                if (cv.init) |init| try g.genExpr(init) else try g.w.writeAll("undefined");
                try g.w.writeAll(", ");
            }
            try g.w.writeAll("}");
            try g.w.writeAll(")");
        } else {
            try g.w.writeAll(".call");
        }
    }

    // ── Type reference ────────────────────────────────────────────────────────

    /// Returns true when `name` refers to a class or union type — i.e. a type
    /// that is always passed/stored as a pointer. `^T` fields of such types must
    /// not be double-boxed on assignment or auto-dereffed on read.
    /// Handles both same-module names and cross-module dotted names (mod.Type).
    fn isPointerPassedType(g: Generator, name: []const u8) bool {
        if (g.class_names.contains(name)) return true;
        if (g.union_names.contains(name)) return true;
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            const mod_alias  = name[0..dot];
            const type_name  = name[dot + 1 ..];
            if (g.imported_modules) |imp| {
                if (imp.get(mod_alias)) |iface| {
                    if (iface.types.get(type_name)) |kind| {
                        if (kind == .class or kind == .union_) return true;
                    }
                }
            }
        }
        return false;
    }

    fn genType(g: Generator, tr: Ast.TypeRef) anyerror!void {
        switch (tr) {
            .named       => |n| {
                // Classes are reference types: emit `*ClassName` instead of `ClassName`.
                // Structs, enums, unions, and primitives are value types (no pointer).
                if (g.class_names.contains(n.name)) {
                    try g.w.writeAll("*");
                    try g.w.writeAll(n.name);
                    return;
                }
                // StringBuilder as a struct field or typed local: emit std.ArrayList(u8).
                // (Local var declarations with `= StringBuilder()` are handled in
                //  genLocalVar; this branch covers struct-field declarations and
                //  any other type-annotation context.)
                if (std.mem.eql(u8, n.name, "StringBuilder")) {
                    try g.w.writeAll("std.ArrayList(u8)");
                    return;
                }
                // CodeEditor is a heap-allocated struct; emit as pointer.
                if (std.mem.eql(u8, n.name, "CodeEditor")) {
                    try g.w.writeAll("*_CodeEditor");
                    return;
                }
                // Cross-module qualified type: "moduleAlias.TypeName".
                // If the referenced type is a class in the imported module, emit
                // `*moduleAlias.TypeName` (pointer) rather than a value type.
                if (std.mem.indexOfScalar(u8, n.name, '.')) |dot| {
                    const mod_alias  = n.name[0..dot];
                    const type_name  = n.name[dot+1..];
                    const is_class = blk: {
                        const imp = g.imported_modules orelse break :blk false;
                        const iface = imp.get(mod_alias) orelse break :blk false;
                        const kind = iface.types.get(type_name) orelse break :blk false;
                        break :blk kind == .class;
                    };
                    if (is_class) try g.w.writeAll("*");
                    try g.w.writeAll(n.name);
                    return;
                }
                // Try static mapping first; fall back to dynamic sized-type emission
                // for arbitrary-width types like int5, uint3, float7.
                const zig = zigTypeName(n.name);
                if (!std.mem.eql(u8, zig, n.name)) {
                    try g.w.writeAll(zig);
                } else if (!try Builtins.writeZigSizedType(g.w, n.name)) {
                    try g.w.writeAll(zig);
                }
            },
            .nilable     => |inner| {
                // Self-referential nilable field (e.g., `var next as Node?` inside `class Node`):
                // Zig requires a pointer to break the infinite-size cycle → emit `?*ClassName`.
                const inner_is_self_ref = inner.* == .named and
                    g.owner.len > 0 and
                    std.mem.eql(u8, inner.named.name, g.owner);
                if (inner_is_self_ref) {
                    try g.w.writeAll("?*");
                    try g.w.writeAll(inner.named.name);
                } else {
                    try g.w.writeAll("?");
                    try g.genType(inner.*);
                }
            },
            .stream      => |inner| {
                // Zig has no built-in stream/generator type.
                try g.w.writeAll("anytype /* stream: ");
                try g.genType(inner.*);
                try g.w.writeAll(" */");
            },
            .error_union => |inner| {
                try g.w.writeAll("anyerror!");
                try g.genType(inner.*);
            },
            .ref_to      => |inner| {
                // ^T — heap-indirection pointer; emits `*T` in Zig to break recursive struct size.
                // Special case: ^T? (ref_to wrapping nilable) → `?*T` rather than `*?T`.
                // This is the natural form for optional recursive references (linked list next, tree children).
                //
                // BUG-041: classes are already auto-boxed to `*T` by the `.named` arm,
                // so recursing via genType on a class inner would stack a second `*`,
                // producing `**T` or `?**T`. For classes `^T` is a no-op on representation —
                // emit `*ClassName` (or `?*ClassName`) directly and skip the auto-box.
                const payload: Ast.TypeRef = if (inner.* == .nilable) inner.nilable.* else inner.*;
                const nilable_prefix: []const u8 = if (inner.* == .nilable) "?*" else "*";
                if (payload == .named) {
                    const n = payload.named;
                    // Bare class name.
                    if (g.class_names.contains(n.name)) {
                        try g.w.writeAll(nilable_prefix);
                        try g.w.writeAll(n.name);
                        return;
                    }
                    // Cross-module dotted class: Mod.ClassName.
                    if (std.mem.indexOfScalar(u8, n.name, '.')) |dot| {
                        const mod_alias = n.name[0..dot];
                        const type_name = n.name[dot+1..];
                        const is_class = blk: {
                            const imp = g.imported_modules orelse break :blk false;
                            const iface = imp.get(mod_alias) orelse break :blk false;
                            const kind = iface.types.get(type_name) orelse break :blk false;
                            break :blk kind == .class;
                        };
                        if (is_class) {
                            try g.w.writeAll(nilable_prefix);
                            try g.w.writeAll(n.name);
                            return;
                        }
                    }
                }
                // Non-class payload: emit `*` (or `?*`) and recurse normally.
                try g.w.writeAll(nilable_prefix);
                try g.genType(payload);
            },
            .generic     => |gtr| {
                // HashMap(K, V): use StringHashMap for string keys, AutoHashMap otherwise.
                if (std.mem.eql(u8, gtr.name, "HashMap")) {
                    const key_is_str = gtr.args.len >= 1 and isStringTypeRef(gtr.args[0]);
                    if (key_is_str) {
                        try g.w.writeAll("std.StringHashMap(");
                        if (gtr.args.len >= 2) try g.genType(gtr.args[1]) else try g.w.writeAll("anytype");
                        try g.w.writeAll(")");
                    } else {
                        try g.w.writeAll("std.AutoHashMap(");
                        for (gtr.args, 0..) |arg, i| {
                            if (i > 0) try g.w.writeAll(", ");
                            try g.genType(arg);
                        }
                        try g.w.writeAll(")");
                    }
                    return;
                }
                try g.w.writeAll(zigGenericName(gtr.name));
                if (gtr.args.len > 0) {
                    try g.w.writeAll("(");
                    for (gtr.args, 0..) |arg, i| {
                        if (i > 0) try g.w.writeAll(", ");
                        try g.genType(arg);
                    }
                    try g.w.writeAll(")");
                }
            },
            .void_       => try g.w.writeAll("void"),
            .same        => try g.w.writeAll(if (g.owner.len > 0) g.owner else "@This()"),
            .tuple       => |ttr| {
                // (T1, T2, …) → struct { T1, T2, … }  (Zig anonymous struct / tuple)
                try g.w.writeAll("struct { ");
                for (ttr.elems, 0..) |el, i| {
                    if (i > 0) try g.w.writeAll(", ");
                    try g.genType(el);
                }
                try g.w.writeAll(" }");
            },
        }
    }
};

// ── Type annotation helper ────────────────────────────────────────────────────

/// Map a TypeChecker.Type to the Zig type annotation string that must appear
/// when a `var` local is initialised with that type.  Returns null when Zig's
/// own inference is correct (named types, stdlib opaques from constructor
/// calls, etc.) so the caller can omit the annotation entirely.
///
/// All non-null results are heap-allocated via `alloc` and must be freed by
/// the caller (typically with `defer alloc.free(ann)`).
fn tcTypeAnnotation(t: TypeChecker.Type, alloc: Allocator) !?[]const u8 {
    return switch (t) {
        // Primitives where Zig's inference would produce comptime_int / comptime_float
        // or a literal array type instead of a slice.
        .int        => try alloc.dupe(u8, "i64"),
        .uint       => try alloc.dupe(u8, "u64"),
        .float      => try alloc.dupe(u8, "f64"),
        .bool       => try alloc.dupe(u8, "bool"),
        .char       => try alloc.dupe(u8, "u21"),
        .string     => try alloc.dupe(u8, "[]const u8"),
        .str_slice  => try alloc.dupe(u8, "[]const []const u8"),
        .void_      => try alloc.dupe(u8, "void"),
        // Sized numerics — bit-width is runtime data so we must allocPrint.
        .int_n   => |w| try std.fmt.allocPrint(alloc, "i{d}", .{w}),
        .uint_n  => |w| try std.fmt.allocPrint(alloc, "u{d}", .{w}),
        .float_n => |w| try std.fmt.allocPrint(alloc, "f{d}", .{w}),
        // Optional wrapper — recurse; propagate null if inner is unresolvable.
        .optional => |inner| blk: {
            const inner_s = try tcTypeAnnotation(inner.*, alloc) orelse break :blk null;
            defer alloc.free(inner_s);
            break :blk try std.fmt.allocPrint(alloc, "?{s}", .{inner_s});
        },
        // Named user types, stdlib opaques, tuples, unknown — Zig infers correctly
        // from constructor calls, so no annotation is needed.
        //
        // GENERIC TYPES (List, HashMap, …): these also fall through here and
        // return null.  That is safe today because every generic-typed local in
        // Zebra requires an explicit `as List(T)` annotation in the source, so
        // `genLocalVar` always takes the `if (n.type_) |tr|` branch and emits
        // `genType(tr)` — it never reaches this function for those vars.
        //
        // If that assumption ever changes (e.g. we add type inference for
        // generics so `var xs = List()` works without an annotation), the
        // generic cases will silently fall through here and produce an
        // unannotated `var xs = ...` — Zig will then reject it with a
        // "variable of type 'std.ArrayList(…)' must be const or comptime"
        // error.  At that point, add explicit `.list`, `.hash_map`, etc. arms
        // to this switch that emit the correct Zig container type.
        else => null,
    };
}

// ── C header generation ───────────────────────────────────────────────────────

/// Emit a C header (`#pragma once` + function declarations) for all
/// `shared def` methods in `module` whose signatures are C-compatible.
/// Call this after `generate()` when in lib mode.
pub fn generateHeader(module: Ast.Module, writer: std.io.AnyWriter) anyerror!void {
    try writer.print(
        \\// Auto-generated by the Zebra compiler.  DO NOT EDIT.
        \\// Source: {s}
        \\#pragma once
        \\#include <stdint.h>
        \\#include <stdbool.h>
        \\#include <stddef.h>
        \\
        \\
    , .{module.file});

    for (module.decls) |decl| {
        const type_name, const members = switch (decl) {
            .class   => |c| .{ c.name, c.members },
            .struct_ => |s| .{ s.name, s.members },
            else     => continue,
        };
        var any_exported = false;
        for (members) |m| {
            const n = switch (m) { .method => |meth| meth, else => continue };
            if (!Generator.isMethodCExportable(n)) continue;
            if (!any_exported) {
                try writer.print("// {s}\n", .{type_name});
                any_exported = true;
            }
            const ret_c = if (n.return_type) |rt| cTypeName(rt) else "void";
            try writer.print("{s} {s}_{s}(", .{ ret_c, type_name, n.name });
            for (n.params, 0..) |p, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{s} {s}", .{ cTypeName(p.type_.?), p.name });
            }
            try writer.writeAll(");\n");
        }
        if (any_exported) try writer.writeAll("\n");
    }
}

fn cTypeName(tr: Ast.TypeRef) []const u8 {
    return switch (tr) {
        .void_  => "void",
        .named  => |n| std.StaticStringMap([]const u8).initComptime(&.{
            .{ "int",     "int64_t"  }, .{ "uint",    "uint64_t" },
            .{ "float",   "double"   }, .{ "bool",    "bool"     },
            .{ "char",    "uint32_t" },
            .{ "int8",    "int8_t"   }, .{ "int16",   "int16_t"  },
            .{ "int32",   "int32_t"  }, .{ "int64",   "int64_t"  },
            .{ "uint8",   "uint8_t"  }, .{ "uint16",  "uint16_t" },
            .{ "uint32",  "uint32_t" }, .{ "uint64",  "uint64_t" },
            .{ "float32", "float"    }, .{ "float64", "double"   },
        }).get(n.name) orelse "/* unsupported */",
        else => "/* unsupported */",
    };
}

// ── Print format specifier ────────────────────────────────────────────────────

/// Choose the Zig format specifier for a single `print` argument based on its
/// inferred type.  Falls back to `{any}` when type information is unavailable.
/// `catch_var` is the current catch-clause binding name (empty if not in a catch);
/// `catch_var.message` is always `[]const u8` so always uses `{s}`.
fn printFmt(tc: ?*const TypeChecker.TypeCheckResult, catch_var: []const u8, expr: *const Ast.Expr) []const u8 {
    // e.message inside a catch block is always []const u8.
    if (catch_var.len > 0 and expr.* == .member) {
        const mem = expr.member;
        if (std.mem.eql(u8, mem.member, "message") and
            mem.object.* == .ident and
            std.mem.eql(u8, mem.object.ident.name, catch_var))
        {
            return "{s}";
        }
    }
    const result = tc orelse return "{any}";
    const t_opt = result.expr_types.get(expr);
    // Fallback for extension method calls: look up return type from ext_methods.
    const t: TypeChecker.Type = t_opt orelse blk: {
        if (expr.* == .call and expr.call.callee.* == .member) {
            const mem = expr.call.callee.member;
            const obj_type = result.expr_types.get(mem.object) orelse .unknown;
            const tname: ?[]const u8 = switch (obj_type) {
                .string         => "String",
                .int            => "int",
                .uint           => "uint",
                .float          => "float",
                .bool           => "bool",
                .char           => "char",
                .string_builder => "StringBuilder",
                .named          => |sym| switch (sym.decl) {
                    .class     => |c| c.name,
                    .struct_   => |s| s.name,
                    .interface => |i| i.name,
                    else       => null,
                },
                else => null,
            };
            if (tname) |tn| {
                var buf: [256]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{s}.{s}", .{tn, mem.member})) |key| {
                    if (result.ext_methods.get(key)) |ext_meth| {
                        if (ext_meth.return_type) |*rt| {
                            // Derive type from return TypeRef
                            const rname = switch (rt.*) {
                                .named => |n| n.name,
                                else   => "",
                            };
                            if (Builtins.isStringTypeName(rname)) break :blk .string;
                            const sk = Builtins.scalarKind(rname);
                            break :blk switch (sk) {
                                .int, .int_n   => .int,
                                .uint, .uint_n => .uint,
                                .float, .float_n => .float,
                                .bool          => .bool,
                                .char          => .char,
                                else           => .unknown,
                            };
                        }
                    }
                } else |_| {}
            }
        }
        break :blk .unknown;
    };
    return switch (t) {
        .string                        => "{s}",
        .int, .uint, .int_n, .uint_n,
        .bool                          => "{}",
        .float, .float_n               => "{d}",
        .char                          => "{u}",
        .void_, .unknown, .named,
        .string_builder,
        .http_request,
        .http_response,
        .tcp_conn,
        .udp_socket,
        .regex,
        .gui_context,
        .shell,
        .file,
        .str_slice,
        .sys_run_result,
        .json_value,
        .json_array,
        .date_time,
        .calendar_view,
        .csv_table,
        .csv_writer,
        .csv_row,
        .arg_result,
        .uri_result,
        .timer_handle,
        .progress_bar,
        .code_editor,
        .optional,
        .tuple,
        .generic_named,
        .cross_module,
        .fn_ref, .fn_sig               => "{any}",
    };
}

// ── Format spec translation ───────────────────────────────────────────────────

/// Translate a Zebra/Python-style format spec (the text after `:` in `[expr:spec]`,
/// already stripped of the leading `:`) into the Zig format specifier that goes
/// inside `{...}`.  Writes directly to `w`.
///
/// Python mini-language:  `[[fill]align][sign][#][0][width][.prec][type]`
/// Zig format string:      `[type][:[[fill]align][width][.prec]]`
///
/// Examples
///   ""       → ""          (empty — use TC-inferred default; caller adds `{}`)
///   "08x"    → "x:0>8"
///   ">10.2f" → "d:>10.2"
///   "<20s"   → "s:<20"
///   ".2f"    → "d:.2"
///   "^15"    → ":^15"      (no type — Zig uses default, just alignment+width)
///   "_>15"   → ":_>15"
fn writeZigFmtSpec(
    w:       anytype,
    spec:    []const u8,
    tc_type: TypeChecker.Type,
) !void {
    if (spec.len == 0) return;

    const isAlignChar = struct {
        fn f(c: u8) bool { return c == '<' or c == '>' or c == '^'; }
    }.f;

    var i: usize = 0;
    var fill:      ?u8          = null;
    var align_ch:  ?u8          = null;
    var zero_pad               = false;
    var width:     []const u8  = "";
    var precision: []const u8  = "";
    var type_ch:   ?u8         = null;

    // ── Fill + align ────────────────────────────────────────────────────────
    // Pattern: [fill]align  where align ∈ { < > ^ }
    if (i + 1 < spec.len and !isAlignChar(spec[i]) and isAlignChar(spec[i + 1])) {
        fill     = spec[i];
        align_ch = spec[i + 1];
        i += 2;
    } else if (i < spec.len and isAlignChar(spec[i])) {
        align_ch = spec[i];
        i += 1;
    }

    // ── Sign (skip — Zig doesn't support the same sign formatting) ──────────
    if (i < spec.len and (spec[i] == '+' or spec[i] == '-' or spec[i] == ' ')) {
        i += 1;
    }

    // ── Alternate form # (skip) ─────────────────────────────────────────────
    if (i < spec.len and spec[i] == '#') i += 1;

    // ── Zero-pad (implicit fill='0', align='>') ──────────────────────────────
    // Only applies if no explicit fill/align seen yet.
    if (i < spec.len and spec[i] == '0' and align_ch == null) {
        zero_pad = true;
        fill     = '0';
        align_ch = '>';
        i += 1;
    }

    // ── Width ────────────────────────────────────────────────────────────────
    const w_start = i;
    while (i < spec.len and spec[i] >= '0' and spec[i] <= '9') : (i += 1) {}
    width = spec[w_start..i];

    // ── Grouping option (skip) ───────────────────────────────────────────────
    if (i < spec.len and (spec[i] == '_' or spec[i] == ',')) i += 1;

    // ── Precision ────────────────────────────────────────────────────────────
    if (i < spec.len and spec[i] == '.') {
        const p_start = i;
        i += 1;
        while (i < spec.len and spec[i] >= '0' and spec[i] <= '9') : (i += 1) {}
        precision = spec[p_start..i];
    }

    // ── Type character ───────────────────────────────────────────────────────
    if (i < spec.len) {
        type_ch = spec[i];
        // (remaining chars ignored)
    }

    // ── Emit Zig specifier ───────────────────────────────────────────────────
    // 1. Type part (before the ':')
    if (type_ch) |tc| {
        switch (tc) {
            's'                => try w.writeByte('s'),
            'c'                => try w.writeByte('c'),
            'u'                => try w.writeByte('u'),
            'd', 'i', 'n'      => try w.writeByte('d'),
            'f', 'g', 'G', '%' => try w.writeByte('d'), // Zig uses 'd' for decimal float
            'e', 'E'           => try w.writeByte('e'),
            'x'                => try w.writeByte('x'),
            'X'                => try w.writeByte('X'),
            'o'                => try w.writeByte('o'),
            'b'                => try w.writeByte('b'),
            else               => try w.writeByte('d'),
        }
    } else {
        // No explicit type: infer from TC type.
        switch (tc_type) {
            .string              => try w.writeByte('s'),
            .float, .float_n     => try w.writeByte('d'),
            .char                => try w.writeByte('u'),
            .int, .uint,
            .int_n, .uint_n      => try w.writeByte('d'),
            else                 => {}, // leave empty — Zig default
        }
    }

    // 2. Format options (after ':')
    const has_opts = fill != null or align_ch != null or
                     width.len > 0 or precision.len > 0 or zero_pad;
    if (has_opts) {
        try w.writeByte(':');
        if (fill)     |f| try w.writeByte(f);
        if (align_ch) |a| try w.writeByte(a);
        try w.writeAll(width);
        try w.writeAll(precision);
    }
}

/// When a bit-repr format spec (x/X/o/b) is applied to a signed integer, Zig's
/// std.fmt prepends a `+` sign for positive values, giving e.g. `+ff` instead
/// of `ff`.  Return the Zig unsigned type name to cast to before formatting, or
/// Map a TypeChecker.Type to its Zig type name string for use in generated code.
/// Used when we need a concrete return type (e.g. block-body lambda return types).
fn zigTypeNameOf(t: TypeChecker.Type) []const u8 {
    return switch (t) {
        .int, .uint     => "i64",
        .float          => "f64",
        .bool           => "bool",
        .char           => "u21",
        .string         => "[]const u8",
        .void_          => "void",
        .int_n   => |b| switch (b) { 8 => "i8", 16 => "i16", 32 => "i32", 64 => "i64", 128 => "i128", else => "i64" },
        .uint_n  => |b| switch (b) { 8 => "u8", 16 => "u16", 32 => "u32", 64 => "u64", 128 => "u128", else => "u64" },
        .float_n => |b| switch (b) { 16 => "f16", 32 => "f32", 64 => "f64", 128 => "f128", else => "f64" },
        else            => "void",
    };
}

/// null if no cast is needed (type is unsigned/float/string, or spec doesn't
/// request a bit representation).
fn castTypeForBitSpec(spec: []const u8, tc_type: TypeChecker.Type) ?[]const u8 {
    if (spec.len == 0) return null;
    // The type character is the last non-digit, non-fill character in the spec;
    // for our purposes it's sufficient to check the final character.
    const last = spec[spec.len - 1];
    if (last != 'x' and last != 'X' and last != 'o' and last != 'b') return null;
    return switch (tc_type) {
        .int        => "u64",
        .int_n => |n| switch (n) {
            8   => "u8",
            16  => "u16",
            32  => "u32",
            64  => "u64",
            128 => "u128",
            else => null,
        },
        else => null,
    };
}

// ── Entry-point detection ─────────────────────────────────────────────────────

/// Search decls (recursing into namespaces) for a class that contains a
/// `shared def main`.  Returns the fully-qualified Zig path (allocated via
/// `alloc`) if found, else null.  Caller must free the returned slice.
/// Find the `shared def main` method in any class/namespace in the module.
/// Returns a pointer to the method declaration (in the arena-owned AST).
fn findMainMethod(decls: []const Ast.Decl) ?*Ast.DeclMethod {
    for (decls) |decl| {
        switch (decl) {
            .class => |c| {
                for (c.members) |m| {
                    if (m == .method and m.method.mods.static_ and
                        std.mem.eql(u8, m.method.name, "main"))
                        return m.method;
                }
            },
            .namespace => |ns| {
                if (findMainMethod(ns.decls)) |m| return m;
            },
            else => {},
        }
    }
    return null;
}

fn findMainClass(decls: []const Ast.Decl, alloc: Allocator, prefix: []const u8) anyerror!?[]const u8 {
    for (decls) |decl| {
        switch (decl) {
            .class => |c| {
                for (c.members) |m| {
                    if (m == .method and
                        m.method.mods.static_ and
                        std.mem.eql(u8, m.method.name, "main"))
                    {
                        if (prefix.len > 0)
                            return try std.fmt.allocPrint(alloc, "{s}.{s}", .{prefix, c.name});
                        return try alloc.dupe(u8, c.name);
                    }
                }
            },
            .namespace => |ns| {
                // Build the qualified prefix for this namespace level.
                const ns_prefix = if (prefix.len > 0)
                    try std.fmt.allocPrint(alloc, "{s}.{s}", .{prefix, ns.name})
                else
                    try alloc.dupe(u8, ns.name);
                defer alloc.free(ns_prefix);
                if (try findMainClass(ns.decls, alloc, ns_prefix)) |name| return name;
            },
            else => {},
        }
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn generateSnippet(src: []const u8, alloc: Allocator) anyerror![]u8 {
    const Tokenizer  = @import("Tokenizer.zig");
    const Parser     = @import("Parser.zig");
    const AstBuilder = @import("AstBuilder.zig");
    const Binder     = @import("Binder.zig");

    const tokens = try Tokenizer.tokenize(src, alloc);
    defer alloc.free(tokens);

    var parse_result = try Parser.parse(tokens, alloc);
    defer parse_result.deinit();

    const ok = switch (parse_result) {
        .ok  => |*s| s,
        .err => |e| {
            std.debug.print("parse error at token {}\n", .{e.error_pos});
            return error.ParseFailed;
        },
    };

    var sym_arena = std.heap.ArenaAllocator.init(alloc);
    defer sym_arena.deinit();

    const module = try AstBuilder.build(ok, sym_arena.allocator());
    var bind = try Binder.bindPass1(module, sym_arena.allocator(), alloc);
    defer bind.deinit();

    var resolve = try Resolver.resolvePass2(module, &bind.table, alloc, alloc, null);
    defer resolve.deinit();

    var out = std.ArrayList(u8){};
    errdefer out.deinit(alloc);

    _ = try generate(module, &resolve, null, alloc, out.writer(alloc).any(), .stub, null, false, null, false);
    return out.toOwnedSlice(alloc);
}

test "codegen: class fields become struct fields" {
    const src =
        \\class Counter
        \\    var count: int
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "pub const Counter = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "count: i64") != null);
}

test "codegen: method gets self param and field uses self prefix" {
    const src =
        \\class Counter
        \\    var count: int
        \\    def increment
        \\        count = count + 1
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "pub fn increment(self: *Counter)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "self.count") != null);
}

test "codegen: method params and return type" {
    const src =
        \\class Greeter
        \\    def greet(name: String): String
        \\        return name
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out,
        "pub fn greet(self: *Greeter, name: []const u8) []const u8") != null);
    try testing.expect(std.mem.indexOf(u8, out, "return name;") != null);
}

test "codegen: interface becomes vtable struct with check" {
    const src =
        \\interface Printable
        \\    def render
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    // Vtable struct (not a comptime-checker function)
    try testing.expect(std.mem.indexOf(u8, out, "pub const Printable = struct {") != null);
    // VTable inner struct with fn pointer
    try testing.expect(std.mem.indexOf(u8, out, "pub const VTable = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "render: *const fn (ptr: *anyopaque) void") != null);
    // Forwarding method
    try testing.expect(std.mem.indexOf(u8, out, "pub fn render(self: @This()) void {") != null);
    // check() comptime verifier
    try testing.expect(std.mem.indexOf(u8, out, "pub fn check(comptime T: type) void {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "@hasDecl(T, \"render\")") != null);
}

test "codegen: enum members" {
    const src =
        \\enum Direction
        \\    North
        \\    South
        \\    East
        \\    West
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "pub const Direction = enum {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "North,") != null);
    try testing.expect(std.mem.indexOf(u8, out, "West,") != null);
}

test "codegen: mixin inlined into class, not emitted standalone" {
    // `adds` is part of the class header line, not a body statement.
    const src =
        \\mixin Loggable
        \\    var log_level: int
        \\
        \\class Service adds Loggable
        \\    var name: String
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    // Mixin should NOT appear as a standalone type.
    try testing.expect(std.mem.indexOf(u8, out, "const Loggable") == null);
    // Mixin field should be inlined inside Service.
    try testing.expect(std.mem.indexOf(u8, out, "log_level: i64") != null);
}

test "codegen: nilable type maps to ?T" {
    const src =
        \\class Node
        \\    var next: Node?
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    // Self-referential `Node?` must be a pointer-nilable `?*Node` to avoid
    // infinite-size struct in Zig.
    try testing.expect(std.mem.indexOf(u8, out, "next: ?*Node") != null);
}
