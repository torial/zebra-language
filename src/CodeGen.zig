//! CodeGen: emit Zig source from a Zebra AST. (rev2)
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

/// BUG-137: reserved Zig-name prefix for module-level `var`/`const`.  Module
/// vars emit as file-scope `pub var`/`pub const`, and Zig forbids any
/// function-local/param from shadowing a file-scope name — so a module var
/// named like a common local (`total`, `count`, `g`, …) or a runtime-preamble
/// local/param would fail to compile.  Emitting them as `_zbr_mv_<name>` (and
/// prefixing references identically in genIdent) moves them out of the namespace
/// any user/preamble identifier occupies.  The Zebra source name is unchanged.
const module_var_prefix = "_zbr_mv_";

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
pub const GuiBackend = enum { stub, glfw, sdl2, dx12, tui, libui_ng };

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
    /// True when the generated code calls any Sqlite.* API.
    /// Callers must add sqlite3.c to the zig compile command when true.
    uses_sqlite: bool,
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
    writer:           *std.Io.Writer,
    gui_backend:      GuiBackend,
    native_uses:      ?*const std.StringHashMap(NativeUse),
    emit_exports:     bool,
    imported_modules: ?*const std.StringHashMap(TypeChecker.ModuleInterface),
    strip_contracts:      bool,
    test_mode:            bool,
    build_mode:           bool,
    list_targets_mode:    bool,
    tag_filter:           ?[]const u8,
    library_mode:         bool,
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
    var uses_sqlite = false;
    var box_counter: u32 = 0;
    var dynlib_vars = std.StringHashMap(void).init(alloc);
    defer dynlib_vars.deinit();
    var type_alias_decls = try collectTypeAliases(module, alloc);
    defer type_alias_decls.deinit();
    var pending_thunks = std.ArrayList(ClosureThunk).empty;
    defer pending_thunks.deinit(alloc);
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
        .uses_sqlite_ptr  = &uses_sqlite,
        .source_file      = module.file,
        .imported_modules = imported_modules,
        .box_counter_ptr  = &box_counter,
        .strip_contracts  = strip_contracts,
        .test_mode           = test_mode,
        .build_mode          = build_mode,
        .list_targets_mode   = list_targets_mode,
        .tag_filter          = tag_filter,
        .library_mode        = library_mode,
        .module              = module,
        .dynlib_vars         = &dynlib_vars,
        .type_alias_decls    = &type_alias_decls,
        .pending_thunks      = &pending_thunks,
    };
    try g.genModule(module);
    return GenerateResult{ .uses_gui = uses_gui, .has_exports = has_exports, .uses_sqlite = uses_sqlite };
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
fn collectTypeAliases(module: Ast.Module, alloc: Allocator) !std.StringHashMap(*const Ast.DeclTypeAlias) {
    var map = std.StringHashMap(*const Ast.DeclTypeAlias).init(alloc);
    errdefer map.deinit();
    for (module.decls) |decl| {
        if (decl == .type_alias) try map.put(decl.type_alias.name, decl.type_alias);
    }
    return map;
}

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
            var buf: std.ArrayListUnmanaged(u8) = .empty;
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
        .void_         => try alloc.dupe(u8, "void"),
        .same          => try alloc.dupe(u8, "same"),
        .tuple         => try alloc.dupe(u8, "tuple"),
        .alias_applied => |aa| try alloc.dupe(u8, aa.name),
    };
}

fn typeRefSimpleName(tr: Ast.TypeRef) ?[]const u8 {
    return switch (tr) {
        .named   => |n| n.name,
        .generic => |g| g.name,
        else     => null,
    };
}

/// Returns the interface declaration for `name` if one exists in the current module.
fn findInterfaceDecl(module: Ast.Module, name: []const u8) ?*const Ast.DeclInterface {
    for (module.decls) |*decl| {
        if (decl.* == .interface and std.mem.eql(u8, decl.interface.name, name)) return decl.interface;
    }
    return null;
}

/// Returns the generic class declaration for `name` (type_params > 0) if one exists.
fn findGenericClassDecl(module: Ast.Module, name: []const u8) ?*const Ast.DeclClass {
    for (module.decls) |*decl| {
        if (decl.* == .class and std.mem.eql(u8, decl.class.name, name) and decl.class.type_params.len > 0) return decl.class;
    }
    return null;
}

/// Collect the transitive super-interfaces of `iface` (the `implements` closure),
/// into the caller-provided fixed `buf` (avoids allocation; interface hierarchies
/// are shallow — depth past `buf.len` is silently dropped). De-duplicated. Returns
/// the filled prefix slice.
///
/// Used to wire interface→interface upcasts: a sub-interface's vtable carries an
/// `__as_<Super>: *const <Super>.VTable` pointer per super-interface, so an erased
/// sub-interface value can be re-projected to any super-interface in O(1).
fn collectSuperIfaces(
    module: Ast.Module,
    iface: *const Ast.DeclInterface,
    buf: []*const Ast.DeclInterface,
) []*const Ast.DeclInterface {
    var n: usize = 0;
    collectSuperIfacesInto(module, iface, buf, &n);
    return buf[0..n];
}

fn collectSuperIfacesInto(
    module: Ast.Module,
    iface: *const Ast.DeclInterface,
    buf: []*const Ast.DeclInterface,
    n: *usize,
) void {
    for (iface.implements) |tr| {
        const sname = typeRefSimpleName(tr) orelse continue;
        const sdecl = findInterfaceDecl(module, sname) orelse continue;
        var dup = false;
        for (buf[0..n.*]) |existing| if (existing == sdecl) { dup = true; break; };
        if (dup) continue;
        if (n.* >= buf.len) return;
        buf[n.*] = sdecl;
        n.* += 1;
        collectSuperIfacesInto(module, sdecl, buf, n);
    }
}

/// Emit shim functions + vtable const for `class_name implements iface_name`.
/// Shims cast `*anyopaque` → `*ClassName` so Zig's strict fn-pointer types are satisfied.
fn genIfaceVtable(g: Generator, class_name: []const u8, iface: *const Ast.DeclInterface) anyerror!void {
    const iname = iface.name;
    for (iface.members) |m| {
        const meth = switch (m) { .method => |x| x, else => continue };
        try g.w.print("fn _shim_{s}_{s}_{s}(ptr: *anyopaque", .{ class_name, iname, meth.name });
        for (meth.params) |p| {
            try g.w.print(", {s}: ", .{p.name});
            if (p.type_) |pt| try g.genType(pt) else try g.w.writeAll("anytype");
        }
        try g.w.writeAll(") ");
        if (meth.throws) try g.w.writeAll("anyerror!");
        if (meth.return_type) |rt| try g.genType(rt) else try g.w.writeAll("void");
        try g.w.print(" {{ {s}{s}.{s}(@alignCast(@ptrCast(ptr))", .{
            if (meth.throws) "return try " else "return ",
            class_name, meth.name,
        });
        for (meth.params) |p| try g.w.print(", {s}", .{p.name});
        try g.w.writeAll("); }\n");
    }
    try g.w.print("const _vtable_{s}_{s} = {s}.VTable{{", .{ class_name, iname, iname });
    for (iface.members) |m| {
        const meth = switch (m) { .method => |x| x, else => continue };
        try g.w.print(" .{s} = &_shim_{s}_{s}_{s},", .{ meth.name, class_name, iname, meth.name });
    }
    // Wire the `__as_<Super>` pointers so an erased value of this interface can be
    // re-projected to any super-interface. `_vtable_<Class>_<Super>` is emitted by
    // the transitive `implements` closure, so it is always available here.
    var super_buf: [16]*const Ast.DeclInterface = undefined;
    for (collectSuperIfaces(g.module, iface, &super_buf)) |s| {
        try g.w.print(" .__as_{s} = &_vtable_{s}_{s},", .{ s.name, class_name, s.name });
    }
    try g.w.writeAll(" };\n");
}

/// Emit interface shims + vtable INSIDE a generic class's `struct` body, so each
/// instantiation (`Box(i64)`) gets its own monomorphized `_vtable_<Iface>`. The
/// shims reference `@This()` (the instantiated struct) rather than a class name,
/// since a generic class has no single concrete name. Coercion sites reference
/// these as `Box(i64)._vtable_<Iface>`. `g` is the struct-body generator (indented).
fn genIfaceVtableInStruct(g: Generator, iface: *const Ast.DeclInterface) anyerror!void {
    const iname = iface.name;
    for (iface.members) |m| {
        const meth = switch (m) { .method => |x| x, else => continue };
        try g.writeIndent();
        try g.w.print("fn _shim_{s}_{s}(ptr: *anyopaque", .{ iname, meth.name });
        for (meth.params) |p| {
            try g.w.print(", {s}: ", .{p.name});
            if (p.type_) |pt| try g.genType(pt) else try g.w.writeAll("anytype");
        }
        try g.w.writeAll(") ");
        if (meth.throws) try g.w.writeAll("anyerror!");
        if (meth.return_type) |rt| try g.genType(rt) else try g.w.writeAll("void");
        try g.w.print(" {{ {s}@as(*@This(), @alignCast(@ptrCast(ptr))).{s}(", .{
            if (meth.throws) "return try " else "return ",
            meth.name,
        });
        var first = true;
        for (meth.params) |p| {
            if (!first) try g.w.writeAll(", ");
            first = false;
            try g.w.print("{s}", .{p.name});
        }
        try g.w.writeAll("); }\n");
    }
    try g.writeIndent();
    try g.w.print("const _vtable_{s} = {s}.VTable{{", .{ iname, iname });
    for (iface.members) |m| {
        const meth = switch (m) { .method => |x| x, else => continue };
        try g.w.print(" .{s} = &_shim_{s}_{s},", .{ meth.name, iname, meth.name });
    }
    var super_buf: [16]*const Ast.DeclInterface = undefined;
    for (collectSuperIfaces(g.module, iface, &super_buf)) |s| {
        try g.w.print(" .__as_{s} = &_vtable_{s},", .{ s.name, s.name });
    }
    try g.w.writeAll(" };\n");
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

/// Returns the Zig type string for a value parameter in a parametric alias constraint block.
/// Only handles the primitive types that are legal as alias value-param types.
fn zigTypeForParam(tr: Ast.TypeRef) []const u8 {
    if (tr != .named) return "i64";
    const n = tr.named.name;
    if (std.mem.eql(u8, n, "int") or std.mem.startsWith(u8, n, "int"))   return "i64";
    if (std.mem.eql(u8, n, "float") or std.mem.startsWith(u8, n, "float")) return "f64";
    if (std.mem.eql(u8, n, "bool"))   return "bool";
    if (std.mem.eql(u8, n, "str") or std.mem.eql(u8, n, "String"))  return "[]const u8";
    return "i64"; // safe default — error surfaces at Zig compile time
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
        .assert       => |s| { try refsInExpr(s.cond, r, o); if (s.message) |m| try refsInExpr(m, r, o); },
        .assert_eq, .assert_ne => |s| { try refsInExpr(s.lhs, r, o); try refsInExpr(s.rhs, r, o); },
        .assert_true, .assert_false => |s| try refsInExpr(s.expr, r, o),
        .yield     => |s| try refsInExpr(s.value, r, o),
        .expr      => |e| try refsInExpr(e, r, o),
        .defer_    => |s| try refsInStmt(s.body, r, o),
        .contract  => |s| { for (s.exprs) |e| try refsInExpr(e, r, o); },
        .with        => |s| { try refsInExpr(s.target, r, o); try refsInStmts(s.body, r, o); },
        .in_scope    => |s| { try refsInExpr(s.expr, r, o);   try refsInStmts(s.body, r, o); },
        .arena_scope => |s| try refsInStmts(s.body, r, o),
        .allocate_   => |s| { try refsInExpr(s.source, r, o); try refsInStmts(s.body, r, o); },
        .copy_out    => |s| { try refsInExpr(s.target, r, o); try refsInExpr(s.value, r, o); },
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
            .raise, .assert_eq, .assert_ne, .assert_true, .assert_false => return true,
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
            .allocate_   => |s| if (bodyHasRaise(s.body, tc_opt)) return true,
            .copy_out    => {},
            .defer_  => |s| return bodyHasRaise(&.{s.body}, tc_opt),
            .guard   => |s| { if (exprHasTry(s.cond, tc_opt)) return true; if (bodyHasRaise(s.else_body, tc_opt)) return true; },
            .try_catch => {}, // try/catch absorbs raises — don't propagate
            .destruct => {},
            else => {},
        }
    }
    return false;
}

// ── Receiver-mutability analysis (method_chain / auto-`*const`) ──────────────
// Decides whether a method's `self` can be `*const Owner` (read-only → callable on
// by-value / const / rvalue receivers like a chained temp) or must be `*Owner`.
// CONSERVATIVE: any assignment / copy-out / destruct / `return this` / ANY call keeps
// the method `*` (a callee may take *self, which we cannot resolve without a fixpoint).
// Only call-free, assignment-free methods relax to `*const`. The only failure mode is
// being too strict; the round-trip gate validates every method of the compiler itself.
fn methodMutatesSelf(stmts: []const Ast.Stmt) bool {
    for (stmts) |s| if (stmtMutatesSelf(s)) return true;
    return false;
}

fn stmtMutatesSelf(s: Ast.Stmt) bool {
    switch (s) {
        .assign, .copy_out, .destruct => return true,
        .assign_except => |x| {
            if (exprMentionsThis(x.target)) return true;
            for (x.fields) |f| if (exprHasSelfCall(f.value)) return true;
            return exprHasSelfCall(x.base);
        },
        .var_except => |x| {
            for (x.fields) |f| if (exprHasSelfCall(f.value)) return true;
            return exprHasSelfCall(x.base);
        },
        .var_    => |x| return if (x.init) |e| exprHasSelfCall(e) else false,
        .return_ => |x| return if (x.value) |v| (v.* == .this or exprHasSelfCall(v)) else false,
        .expr    => |e| return exprHasSelfCall(e),
        .print   => |x| { for (x.args) |a| if (exprHasSelfCall(a)) return true; return false; },
        .if_     => |x| {
            if (exprHasSelfCall(x.cond)) return true;
            if (methodMutatesSelf(x.then_body)) return true;
            for (x.else_ifs) |ei| { if (exprHasSelfCall(ei.cond)) return true; if (methodMutatesSelf(ei.body)) return true; }
            if (x.else_body) |eb| if (methodMutatesSelf(eb)) return true;
            return false;
        },
        .while_  => |x| {
            if (x.bind) |b| if (exprHasSelfCall(b.init)) return true;
            if (exprHasSelfCall(x.cond)) return true;
            if (methodMutatesSelf(x.body)) return true;
            if (x.post_body) |pb| if (methodMutatesSelf(pb)) return true;
            return false;
        },
        .for_in  => |x| {
            if (exprHasSelfCall(x.iter)) return true;
            if (x.where) |w| if (exprHasSelfCall(w)) return true;
            if (methodMutatesSelf(x.body)) return true;
            if (x.else_) |eb| if (methodMutatesSelf(eb)) return true;
            return false;
        },
        .for_num => |x| {
            if (exprHasSelfCall(x.start) or exprHasSelfCall(x.stop)) return true;
            if (x.step) |stp| if (exprHasSelfCall(stp)) return true;
            if (methodMutatesSelf(x.body)) return true;
            if (x.else_) |eb| if (methodMutatesSelf(eb)) return true;
            return false;
        },
        .branch  => |x| {
            if (exprHasSelfCall(x.expr)) return true;
            for (x.on) |on| {
                for (on.values) |v| if (exprHasSelfCall(v)) return true;
                if (on.guard) |gd| if (exprHasSelfCall(gd)) return true;
                if (methodMutatesSelf(on.body)) return true;
            }
            if (x.else_) |eb| if (methodMutatesSelf(eb)) return true;
            return false;
        },
        .with        => |x| { if (exprHasSelfCall(x.target)) return true; return methodMutatesSelf(x.body); },
        .arena_scope => |x| return methodMutatesSelf(x.body),
        .allocate_   => |x| { if (exprHasSelfCall(x.source)) return true; return methodMutatesSelf(x.body); },
        .guard   => |x| { if (exprHasSelfCall(x.cond)) return true; return methodMutatesSelf(x.else_body); },
        .defer_  => |x| return methodMutatesSelf(&.{x.body}),
        else => return true,
    }
}

/// True if `e` contains ANY call (a callee may take *self).
fn exprHasSelfCall(e: *const Ast.Expr) bool {
    switch (e.*) {
        .call => return true,
        .opt_chain => |x| { if (x.args != null) return true; return exprHasSelfCall(x.base); },
        .member => |x| return exprHasSelfCall(x.object),
        .binary => |x| return exprHasSelfCall(x.left) or exprHasSelfCall(x.right),
        .unary  => |x| return exprHasSelfCall(x.operand),
        .index  => |x| return exprHasSelfCall(x.object) or exprHasSelfCall(x.index),
        .slice  => |x| return exprHasSelfCall(x.object) or (if (x.start) |s| exprHasSelfCall(s) else false) or (if (x.stop) |s| exprHasSelfCall(s) else false),
        .if_expr => |x| return exprHasSelfCall(x.cond) or exprHasSelfCall(x.then_expr) or exprHasSelfCall(x.else_expr),
        .orelse_ => |x| return exprHasSelfCall(x.expr) or exprHasSelfCall(x.fallback),
        .catch_  => |x| return exprHasSelfCall(x.expr) or exprHasSelfCall(x.fallback),
        .to_nilable => |x| return exprHasSelfCall(x.expr),
        .to_non_nil => |x| return exprHasSelfCall(x.expr),
        .is_nil  => |x| return exprHasSelfCall(x.expr),
        .cast    => |x| return exprHasSelfCall(x.expr),
        .old     => |x| return exprHasSelfCall(x.expr),
        .try_    => |x| return exprHasSelfCall(x.expr),
        .type_check => |x| return exprHasSelfCall(x.expr),
        .chained_cmp => |x| { for (x.operands) |op| if (exprHasSelfCall(op)) return true; return false; },
        .list_lit  => |x| { for (x.elems) |el| if (exprHasSelfCall(el)) return true; return false; },
        .array_lit => |x| { for (x.elems) |el| if (exprHasSelfCall(el)) return true; return false; },
        .tuple_lit => |x| { for (x.elems) |el| if (exprHasSelfCall(el)) return true; return false; },
        .dict_lit  => |x| { for (x.entries) |en| if (exprHasSelfCall(en.key) or exprHasSelfCall(en.value)) return true; return false; },
        .string_interp => |x| { for (x.parts) |p| switch (p) { .expr => |ex| if (exprHasSelfCall(ex)) return true, else => {} }; return false; },
        .lambda => |x| switch (x.body) { .expr => |ex| return exprHasSelfCall(ex), .stmts => |ss| return methodMutatesSelf(ss) },
        else => return false,
    }
}

/// True if `e` (recursively) mentions the receiver `this`.
fn exprMentionsThis(e: *const Ast.Expr) bool {
    switch (e.*) {
        .this => return true,
        .call => |x| { if (exprMentionsThis(x.callee)) return true; for (x.args) |a| if (exprMentionsThis(a.value)) return true; return false; },
        .opt_chain => |x| { if (exprMentionsThis(x.base)) return true; if (x.args) |args| for (args) |a| if (exprMentionsThis(a.value)) return true; return false; },
        .member => |x| return exprMentionsThis(x.object),
        .binary => |x| return exprMentionsThis(x.left) or exprMentionsThis(x.right),
        .unary  => |x| return exprMentionsThis(x.operand),
        .index  => |x| return exprMentionsThis(x.object) or exprMentionsThis(x.index),
        .slice  => |x| return exprMentionsThis(x.object) or (if (x.start) |s| exprMentionsThis(s) else false) or (if (x.stop) |s| exprMentionsThis(s) else false),
        .if_expr => |x| return exprMentionsThis(x.cond) or exprMentionsThis(x.then_expr) or exprMentionsThis(x.else_expr),
        .orelse_ => |x| return exprMentionsThis(x.expr) or exprMentionsThis(x.fallback),
        .catch_  => |x| return exprMentionsThis(x.expr) or exprMentionsThis(x.fallback),
        .to_nilable => |x| return exprMentionsThis(x.expr),
        .to_non_nil => |x| return exprMentionsThis(x.expr),
        .is_nil  => |x| return exprMentionsThis(x.expr),
        .cast    => |x| return exprMentionsThis(x.expr),
        .old     => |x| return exprMentionsThis(x.expr),
        .try_    => |x| return exprMentionsThis(x.expr),
        .type_check => |x| return exprMentionsThis(x.expr),
        .chained_cmp => |x| { for (x.operands) |op| if (exprMentionsThis(op)) return true; return false; },
        .list_lit  => |x| { for (x.elems) |el| if (exprMentionsThis(el)) return true; return false; },
        .array_lit => |x| { for (x.elems) |el| if (exprMentionsThis(el)) return true; return false; },
        .tuple_lit => |x| { for (x.elems) |el| if (exprMentionsThis(el)) return true; return false; },
        .dict_lit  => |x| { for (x.entries) |en| if (exprMentionsThis(en.key) or exprMentionsThis(en.value)) return true; return false; },
        .string_interp => |x| { for (x.parts) |p| switch (p) { .expr => |ex| if (exprMentionsThis(ex)) return true, else => {} }; return false; },
        else => return false,
    }
}

/// Returns true if the try block needs a mutable `_try_err` variable — i.e., when
/// the body contains either a `raise` statement or a `try expr` expression (both of
/// which route errors through the tracking variable).
/// Does not recurse into nested try/catch — inner blocks have their own variables.
fn bodyNeedsErrVar(stmts: []const Ast.Stmt, tc_opt: ?*const TypeChecker.TypeCheckResult) bool {
    for (stmts) |stmt| {
        switch (stmt) {
            .raise, .assert_eq, .assert_ne, .assert_true, .assert_false => return true,
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
            .allocate_   => |s| if (bodyNeedsErrVar(s.body, tc_opt)) return true,
            .copy_out    => {},
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
        .try_ => blk: {
            // TC records optional-unwrap `.try_` nodes in `optional_unwraps` by
            // checking the inner ident's DECLARED type (pre nil-narrowing).
            // Only count this as a real error propagation if it's NOT an opt-unwrap.
            if (tc_opt) |tc| {
                if (tc.optional_unwraps.contains(expr)) break :blk false;
            }
            break :blk true;
        },
        .binary => |e| exprHasTry(e.left, tc_opt) or exprHasTry(e.right, tc_opt),
        .chained_cmp => |cc| blk: {
            for (cc.operands) |op| if (exprHasTry(op, tc_opt)) break :blk true;
            break :blk false;
        },
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
        .chained_cmp => |cc| { for (cc.operands) |op| try refsInExpr(op, r, o); },
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
        .opt_chain => |e| { try refsInExpr(e.base, r, o); if (e.args) |args| for (args) |a| try refsInExpr(a.value, r, o); },
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
        .chained_cmp   => |cc| blk: {
            for (cc.operands) |op| if (containsResultRef(op)) break :blk true;
            break :blk false;
        },
        .opt_chain => |e| blk: {
            if (containsResultRef(e.base)) break :blk true;
            if (e.args) |args| for (args) |a| if (containsResultRef(a.value)) break :blk true;
            break :blk false;
        },
        .lambda        => false,
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
        .chained_cmp => |cc| { for (cc.operands) |op| try collectOldExprs(op, alloc, out); },
        .opt_chain => |e| { try collectOldExprs(e.base, alloc, out); if (e.args) |args| for (args) |a| try collectOldExprs(a.value, alloc, out); },
        .lambda      => {},
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
        .chained_cmp   => |cc| { for (cc.operands) |op| try collectAllIdents(op, set); },
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
            .allocate_   => |s| try seedEscapedFromReturns(s.body, set),
            .copy_out    => {},
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
            .allocate_   => |s| { if (try propagateEscapesOnce(s.body, set)) grew = true; },
            .copy_out    => {},
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
            .allocate_   => |s| try scanMutationsInto(s.body, set, tc_opt),
            .copy_out    => |s| {
                // The target is being mutated (assigned to).
                if (s.target.* == .ident) try set.put(s.target.ident.name, {});
                try scanMutationsInExpr(s.value, set, tc_opt);
            },
            .try_catch => |s| {
                try scanMutationsInto(s.body, set, tc_opt);
                for (s.clauses) |cl| try scanMutationsInto(cl.body, set, tc_opt);
            },
            .guard    => |s| try scanMutationsInto(s.else_body, set, tc_opt),
            .destruct => |s| try scanMutationsInExpr(s.init, set, tc_opt),
            .assert       => |s| try scanMutationsInExpr(s.cond, set, tc_opt),
            .assert_eq, .assert_ne => |s| { try scanMutationsInExpr(s.lhs, set, tc_opt); try scanMutationsInExpr(s.rhs, set, tc_opt); },
            .assert_true, .assert_false => |s| try scanMutationsInExpr(s.expr, set, tc_opt),
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
                                    // Exception: @derive methods take *const Self and do not mutate.
                                    if (sym.kind == .struct_) {
                                        const sd = sym.decl.struct_;
                                        const is_derive_readonly =
                                            (sd.mods.derive_debug and std.mem.eql(u8, method, "toString")) or
                                            (sd.mods.derive_eq    and std.mem.eql(u8, method, "eql")) or
                                            (sd.mods.derive_hash  and std.mem.eql(u8, method, "hash"));
                                        if (!is_derive_readonly) break :blk true;
                                        break :blk false;
                                    }
                                    if (sym.kind == .interface) break :blk true;
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
        .tuple_lit   => |e| { for (e.elems) |el| try scanMutationsInExpr(el, set, tc_opt); },
        .type_check  => |e| try scanMutationsInExpr(e.expr, set, tc_opt),
        .chained_cmp => |cc| { for (cc.operands) |op| try scanMutationsInExpr(op, set, tc_opt); },
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
            .allocate_   => |s| try addAddrOfMutationsInStmts(s.body, set, alloc, tc_opt, resolve),
            .copy_out    => |s| { try addAddrOfMutationsInExpr(s.target, set, alloc, tc_opt, resolve); try addAddrOfMutationsInExpr(s.value, set, alloc, tc_opt, resolve); },
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
            .assert_eq, .assert_ne => |s| {
                try addAddrOfMutationsInExpr(s.lhs, set, alloc, tc_opt, resolve);
                try addAddrOfMutationsInExpr(s.rhs, set, alloc, tc_opt, resolve);
            },
            .assert_true, .assert_false => |s| try addAddrOfMutationsInExpr(s.expr, set, alloc, tc_opt, resolve),
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
        .tuple_lit   => |e| { for (e.elems) |el| try addAddrOfMutationsInExpr(el, set, alloc, tc_opt, resolve); },
        .type_check  => |e| try addAddrOfMutationsInExpr(e.expr, set, alloc, tc_opt, resolve),
        .chained_cmp => |cc| { for (cc.operands) |op| try addAddrOfMutationsInExpr(op, set, alloc, tc_opt, resolve); },
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

/// CONSERVATIVE "might `name` be read anywhere in `stmts`?".  Unlike
/// nameUsedInStmt (which under-approximates — it returns false for statement
/// forms it doesn't model, e.g. `branch`/`with`/`try`), this returns TRUE for
/// any form it can't fully analyze.  Callers may therefore safely emit an
/// "unused local" discard (`_ = X;`) only when this is FALSE — guaranteeing we
/// never discard a name that is actually used (which Zig rejects as a
/// "pointless discard").
/// CONSERVATIVE expression-level companion to mightUseName: TRUE for any expr
/// form it doesn't model (type_check / if_expr / orelse / catch / try / …), so
/// a use hidden inside one is never missed.
fn mightUseNameInExpr(name: []const u8, expr: *const Ast.Expr) bool {
    return switch (expr.*) {
        .ident     => |e| std.mem.eql(u8, e.name, name),
        .member    => |e| mightUseNameInExpr(name, e.object),
        .index     => |e| mightUseNameInExpr(name, e.object) or mightUseNameInExpr(name, e.index),
        .unary     => |e| mightUseNameInExpr(name, e.operand),
        .binary    => |e| mightUseNameInExpr(name, e.left) or mightUseNameInExpr(name, e.right),
        .call      => |e| blk: {
            if (mightUseNameInExpr(name, e.callee)) break :blk true;
            for (e.args) |a| if (mightUseNameInExpr(name, a.value)) break :blk true;
            break :blk false;
        },
        .tuple_lit => |e| blk: { for (e.elems) |el| if (mightUseNameInExpr(name, el)) break :blk true; break :blk false; },
        .chained_cmp => |cc| blk: { for (cc.operands) |op| if (mightUseNameInExpr(name, op)) break :blk true; break :blk false; },
        .nil, .int_lit, .float_lit, .string_lit, .bool_lit, .char_lit => false,
        // type_check / if_expr / orelse / catch_ / try_ / opt_chain / lambda /
        // string_interp / … — not modelled; conservatively assume a use.
        else       => true,
    };
}

fn mightUseName(name: []const u8, stmts: []const Ast.Stmt) bool {
    for (stmts) |s| if (mightUseNameStmt(name, s)) return true;
    return false;
}
fn mightUseNameStmt(name: []const u8, stmt: Ast.Stmt) bool {
    return switch (stmt) {
        .var_     => |n| if (n.init) |e| mightUseNameInExpr(name, e) else false,
        .assign   => |s| mightUseNameInExpr(name, s.target) or mightUseNameInExpr(name, s.value),
        .return_  => |s| if (s.value) |v| mightUseNameInExpr(name, v) else false,
        .print    => |s| blk: { for (s.args) |a| if (mightUseNameInExpr(name, a)) break :blk true; break :blk false; },
        .expr     => |e| mightUseNameInExpr(name, e),
        .destruct => |s| mightUseNameInExpr(name, s.init),
        .if_      => |s| blk: {
            if (mightUseNameInExpr(name, s.cond)) break :blk true;
            if (mightUseName(name, s.then_body)) break :blk true;
            for (s.else_ifs) |ei| if (mightUseNameInExpr(name, ei.cond) or mightUseName(name, ei.body)) break :blk true;
            if (s.else_body) |eb| if (mightUseName(name, eb)) break :blk true;
            break :blk false;
        },
        .while_   => |s| blk: {
            if (s.bind) |bind| if (mightUseNameInExpr(name, bind.init)) break :blk true;
            break :blk mightUseNameInExpr(name, s.cond) or mightUseName(name, s.body);
        },
        .for_in   => |s| mightUseNameInExpr(name, s.iter) or mightUseName(name, s.body),
        .for_num  => |s| mightUseNameInExpr(name, s.start) or mightUseNameInExpr(name, s.stop) or mightUseName(name, s.body),
        .guard    => |s| mightUseNameInExpr(name, s.cond) or mightUseName(name, s.else_body),
        .break_, .continue_, .pass => false,
        // branch / with / try_catch / raise / yield / defer / *_except / arena /
        // allocate / copy_out / contract / assert* — not modelled here;
        // conservatively assume a use (so we never wrongly discard).  Kept to the
        // same core set as the selfhost mirror for bootstrap parity.
        else => true,
    };
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
        .allocate_   => |s| nameUsedInExpr(name, s.source) or nameUsedInStmts(name, s.body),
        .copy_out    => |s| nameUsedInExpr(name, s.target) or nameUsedInExpr(name, s.value),
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
        .chained_cmp => |cc| blk: {
            for (cc.operands) |op| if (nameUsedInExpr(name, op)) break :blk true;
            break :blk false;
        },
        .string_interp => |e| blk: {
            for (e.parts) |p| if (p == .expr and nameUsedInExpr(name, p.expr)) break :blk true;
            break :blk false;
        },
        // BUG-FIX: previously fell through to the `else => false` arm, so
        // names used in a lambda's capture-init or body were treated as
        // unused at the outer scope — causing spurious `_ = name;` cleanup
        // emit that conflicted with later use at the capture construction
        // site.
        .lambda    => |e| blk: {
            // 1) Capture init expressions always reference outer scope.
            for (e.capture) |cv| {
                if (cv.init) |ie| if (nameUsedInExpr(name, ie)) break :blk true;
            }
            // 2) Body — recurse unless a param or capture-field shadows `name`.
            for (e.params) |p| if (std.mem.eql(u8, p.name, name)) break :blk false;
            for (e.capture) |cv| if (std.mem.eql(u8, cv.name, name)) break :blk false;
            switch (e.body) {
                .expr  => |ex| break :blk nameUsedInExpr(name, ex),
                .stmts => |ss| break :blk nameUsedInStmts(name, ss),
            }
        },
        else       => false,
    };
}

/// Gap 1 (sig-takes-closure): one entry per call site where a capture-block
/// lambda is passed to a sig-typed param.  The codegen emits at module end:
///   var _zbr_state_N: ?*anyopaque = null;
///   var _zbr_dispatch_N: ?*const fn(*anyopaque, <args>) <ret> = null;
///   fn _zbr_thunk_N(<args>) <ret> {
///       if (_zbr_state_N) |s| _zbr_dispatch_N.?(s, <args>);
///   }
/// The call site (replaces `target.connect(closure_expr)`) emits:
///   {
///     const _c = _allocator.create(@TypeOf(<closure>)) catch @panic("OOM");
///     _c.* = <closure>;
///     _zbr_state_N = @ptrCast(_c);
///     _zbr_dispatch_N = (struct {
///         fn dispatch(ctx: *anyopaque, <args>) <ret> {
///             const cc: *@TypeOf(<closure>) = @ptrCast(@alignCast(ctx));
///             cc.call(<args>);
///         }
///     }).dispatch;
///     target.connect(_zbr_thunk_N);
///   }
const ClosureThunk = struct {
    id: u32,
    /// The lambda whose captures are bound here.  Used at module-end to emit
    /// the public thunk signature (param + return types) and at the call
    /// site to construct the closure value.
    lambda: *const Ast.ExprLambda,
};

// ── Generator ─────────────────────────────────────────────────────────────────

const Generator = struct {
    resolve:   *const Resolver.ResolveResult,
    /// Pass-3 type map.  Null when called from tests that don't run TypeChecker.
    tc:        ?*const TypeChecker.TypeCheckResult,
    /// Output writer.  Pointer is copied when Generator is copied; all copies
    /// target the same underlying output stream.
    w:         *std.Io.Writer,
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
    /// Set to true the first time any Sqlite.* API call is encountered.
    uses_sqlite_ptr: ?*bool = null,
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
    /// BUG-097: param names in the current function that are emitted as
    /// `*ArrayList` (because BUG-091 `paramNeedsAddrOf` returned true for them).
    /// `genArgs` uses this for three-case logic: ptr→ptr (pass as-is),
    /// ptr→value (emit `arg.*`), value→ptr (emit `&arg`).
    /// Null at module scope and when no params need addr-of.
    caller_ptr_params: ?*const std.StringHashMap(void) = null,
    /// True when generating the body of a generic class (emitted as a comptime
    /// function `pub fn Name(comptime T: type) type { return struct { … }; }`).
    /// Enables `@This()` instead of `owner` for self-type references in init/methods.
    is_generic: bool = false,
    /// When `is_generic`, points to the class declaration so that `genAssign` can
    /// resolve field types for explicit `std.ArrayList(T).empty` emission.
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
    /// When true, generate a test-runner `pub fn main()` that discovers and calls
    /// all top-level `def test_*()` functions, catches failures, and reports results.
    test_mode: bool = false,
    /// When true, append `_build_auto_run();` at the end of the top-level `main`
    /// function so `zebra build` auto-executes the registered build context even if
    /// the user never calls `b.run()` explicitly (declarative build.zbr style).
    build_mode: bool = false,
    /// When true, inject `_list_targets_mode = true;` at the start of `main()` so
    /// `_build_run()` outputs a JSON target graph instead of invoking the compiler.
    list_targets_mode: bool = false,
    /// When true, omit `defer _arena.deinit();` from the generated `main()`.
    /// Used when the .zig output is linked into a host program (e.g. the
    /// GameEngine's script-binding layer) where `main()` returns to the host
    /// instead of exiting the process — the script's arena needs to outlive
    /// the call so that other modules that captured it (via _initAllocator)
    /// keep working.  Standalone Zebra programs leave this false so the
    /// arena gets cleaned at program exit.
    library_mode: bool = false,
    /// When non-null, only run tests whose effective tags include this value.
    tag_filter: ?[]const u8 = null,
    /// Return type of the current method; null outside a method or for void methods.
    /// Used by genReturn so `return HashMap()` gets a type-hinted emission.
    method_ret_type: ?Ast.TypeRef = null,
    /// The module being compiled.  Used by interface vtable construction to locate
    /// interface declarations by name without a separate pre-pass map.
    module: Ast.Module = undefined,
    /// Variable names that are DynLib handles (result of DynLib.open).
    /// Used to dispatch .close() and .lookup() to DynLib-specific codegen.
    dynlib_vars: *std.StringHashMap(void),
    /// Named type aliases declared in the current module.
    /// Used by genType to emit the base Zig type and by genLocalVar to
    /// emit constraint checks at variable-declaration sites.
    type_alias_decls: *const std.StringHashMap(*const Ast.DeclTypeAlias),
    /// Gap 1 (sig-takes-closure): when a capture-block lambda is passed as a
    /// call argument where the param type is a `sig`, the codegen hoists a
    /// module-level state slot + dispatcher + public thunk fn so the
    /// closure can satisfy the fn-pointer-typed sig.  Entries are added at
    /// call-site emit and flushed at module-end.  See ClosureThunk.
    pending_thunks: *std.ArrayList(ClosureThunk),

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

    fn withMethodRetType(g: Generator, rt: ?Ast.TypeRef) Generator {
        var c = g; c.method_ret_type = rt; return c;
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

    /// Write a source path with forward slashes. Emitted `// Source:` / `// zbr:`
    /// markers must be byte-identical regardless of the host path separator —
    /// on Windows the shell may pass backslash (or mixed) paths to the compiler,
    /// sometimes non-deterministically (MSYS arg mangling), which would otherwise
    /// make the generated .zig differ run-to-run. Normalizing here keeps emission
    /// deterministic and portable across OSes and invocation contexts.
    fn writePathFwd(w: *std.Io.Writer, path: []const u8) !void {
        for (path) |c| try w.writeByte(if (c == '\\') '/' else c);
    }

    fn genModule(g: Generator, module: Ast.Module) anyerror!void {
        try g.w.writeAll("// Generated by the Zebra compiler.\n// Source: ");
        try writePathFwd(g.w, module.file);
        try g.w.writeAll("\n\nconst std     = @import(\"std\");\nconst builtin = @import(\"builtin\");\nvar _io: std.Io = undefined;\nvar _args: std.process.Args = undefined;\n\n");
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
        // `_initIo` propagates the Zig 0.16 _io handle from the entry point to every
        // dep module so file-I/O calls in dep code (e.g. codegen.zig readFileAlloc)
        // have a valid io handle.  Called once from the root entry thunk.
        try g.w.writeAll("pub fn _initIo(io: std.Io) void {\n    _io = io;\n");
        for (module.decls) |decl| {
            const u = switch (decl) { .use => |u| u, else => continue };
            if (g.native_uses) |nu| if (nu.get(u.path) != null) continue;
            const imp_path = try std.mem.replaceOwned(u8, g.alloc, u.path, ".", "/");
            defer g.alloc.free(imp_path);
            try g.w.print("    @import(\"{s}.zig\")._initIo(io);\n", .{imp_path});
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
            \\const _GuiVec2 = struct { f64, f64 };
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
            \\    beginPanelFn:       *const fn (label: []const u8) bool,
            \\    endPanelFn:         *const fn () void,
            \\    beginWindowFn:      *const fn (label: []const u8) bool,
            \\    endWindowFn:        *const fn () void,
            \\    selectableFn:       *const fn (label: []const u8) bool,
            \\    textColoredFn:      *const fn (r: f32, gv: f32, b_: f32, a: f32, s: []const u8) void,
            \\    beginTableFn:       *const fn (id: []const u8, cols: i64) bool,
            \\    tableSetupColumnFn: *const fn (label: []const u8) void,
            \\    tableHeadersRowFn:  *const fn () void,
            \\    tableNextRowFn:     *const fn () void,
            \\    tableNextColumnFn:  *const fn () bool,
            \\    endTableFn:         *const fn () void,
            \\    beginChildFn:       *const fn (id: []const u8, w: f64, h: f64) bool,
            \\    endChildFn:         *const fn () void,
            \\    treeNodeFn:         *const fn (label: []const u8) bool,
            \\    treePopFn:          *const fn () void,
            \\    setColorFn:         *const fn (role: []const u8, r: f32, g: f32, b: f32, a: f32) void,
            \\    setColorsDarkFn:    *const fn () void,
            \\    setStyleFloatFn:    *const fn (name: []const u8, value: f32) void,
            \\    setVec2Fn:          *const fn (name: []const u8, x: f32, y: f32) void,
            \\    scaleAllSizesFn:      *const fn (scale: f32) void,
            \\    getDpiFn:             *const fn () f32,
            \\    ll_addLineFn:         *const fn (x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void,
            \\    ll_addRectFn:         *const fn (x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void,
            \\    ll_addRectFilledFn:   *const fn (x1: f64, y1: f64, x2: f64, y2: f64, col: i64) void,
            \\    ll_addCircleFn:       *const fn (cx: f64, cy: f64, r: f64, col: i64, thickness: f64) void,
            \\    ll_addCircleFilledFn: *const fn (cx: f64, cy: f64, r: f64, col: i64) void,
            \\    ll_addTextFn:         *const fn (x: f64, y: f64, col: i64, text: []const u8) void,
            \\    ll_getWindowPosFn:    *const fn () _GuiVec2,
            \\    ll_getWindowSizeFn:   *const fn () _GuiVec2,
            \\    ll_getCursorPosFn:    *const fn () _GuiVec2,
            \\    ll_getMousePosFn:     *const fn () _GuiVec2,
            \\    ll_beginGroupFn:      *const fn () void,
            \\    ll_endGroupFn:        *const fn () void,
            \\    beginHBoxFn: *const fn (id: []const u8, stretch: bool) void,
            \\    endHBoxFn:   *const fn () void,
            \\    beginVBoxFn: *const fn (id: []const u8, stretch: bool) void,
            \\    endVBoxFn:   *const fn () void,
            \\    progressBarFn: *const fn (label: []const u8, value: f64) void,
            \\    comboboxFn:    *const fn (label: []const u8, items: []const []const u8, selected: i64) i64,
            \\    spinboxFn:     *const fn (label: []const u8, value: i64, min: i64, max: i64) i64,
            \\    openFileFn:    *const fn () ?[]const u8,
            \\    saveFileFn:    *const fn () ?[]const u8,
            \\    openFolderFn:  *const fn () ?[]const u8,
            \\    msgBoxFn:      *const fn (title: []const u8, description: []const u8) void,
            \\    msgBoxErrorFn: *const fn (title: []const u8, description: []const u8) void,
            \\};
            \\const _LowLevel = struct {
            \\    _b: *const _GuiBackend,
            \\    pub fn addLine(ll: _LowLevel, x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void {
            \\        ll._b.ll_addLineFn(x1, y1, x2, y2, col, thickness);
            \\    }
            \\    pub fn addRect(ll: _LowLevel, x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void {
            \\        ll._b.ll_addRectFn(x1, y1, x2, y2, col, thickness);
            \\    }
            \\    pub fn addRectFilled(ll: _LowLevel, x1: f64, y1: f64, x2: f64, y2: f64, col: i64) void {
            \\        ll._b.ll_addRectFilledFn(x1, y1, x2, y2, col);
            \\    }
            \\    pub fn addCircle(ll: _LowLevel, cx: f64, cy: f64, r: f64, col: i64, thickness: f64) void {
            \\        ll._b.ll_addCircleFn(cx, cy, r, col, thickness);
            \\    }
            \\    pub fn addCircleFilled(ll: _LowLevel, cx: f64, cy: f64, r: f64, col: i64) void {
            \\        ll._b.ll_addCircleFilledFn(cx, cy, r, col);
            \\    }
            \\    pub fn addText(ll: _LowLevel, x: f64, y: f64, col: i64, text: []const u8) void {
            \\        ll._b.ll_addTextFn(x, y, col, text);
            \\    }
            \\    pub fn getWindowPos(ll: _LowLevel) _GuiVec2 { return ll._b.ll_getWindowPosFn(); }
            \\    pub fn getWindowSize(ll: _LowLevel) _GuiVec2 { return ll._b.ll_getWindowSizeFn(); }
            \\    pub fn getCursorPos(ll: _LowLevel) _GuiVec2 { return ll._b.ll_getCursorPosFn(); }
            \\    pub fn getMousePos(ll: _LowLevel) _GuiVec2 { return ll._b.ll_getMousePosFn(); }
            \\    pub fn beginGroup(ll: _LowLevel) void { ll._b.ll_beginGroupFn(); }
            \\    pub fn endGroup(ll: _LowLevel) void { ll._b.ll_endGroupFn(); }
            \\    pub fn sameLine(ll: _LowLevel) void { ll._b.sameLineFn(); }
            \\};
            \\const GuiContext = struct {
            \\    _b: *const _GuiBackend,
            \\    lowLevel: _LowLevel,
            \\    _send_fn: ?*const fn(*anyopaque, *const anyopaque) void = null,
            \\    _send_ptr: ?*anyopaque = null,
            \\    pub fn send(self: GuiContext, msg: anytype) void {
            \\        if (self._send_fn) |f| f(self._send_ptr.?, @ptrCast(&msg));
            \\    }
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
            \\    pub fn selectable(self: GuiContext, label: []const u8) bool { return self._b.selectableFn(label); }
            \\    pub fn textColored(self: GuiContext, r: f64, gv: f64, b_: f64, a: f64, s: []const u8) void {
            \\        self._b.textColoredFn(@floatCast(r), @floatCast(gv), @floatCast(b_), @floatCast(a), s);
            \\    }
            \\    pub fn beginTable(self: GuiContext, id: []const u8, cols: i64) bool { return self._b.beginTableFn(id, cols); }
            \\    pub fn tableSetupColumn(self: GuiContext, label: []const u8) void { self._b.tableSetupColumnFn(label); }
            \\    pub fn tableHeadersRow(self: GuiContext) void { self._b.tableHeadersRowFn(); }
            \\    pub fn tableNextRow(self: GuiContext) void { self._b.tableNextRowFn(); }
            \\    pub fn tableNextColumn(self: GuiContext) bool { return self._b.tableNextColumnFn(); }
            \\    pub fn endTable(self: GuiContext) void { self._b.endTableFn(); }
            \\    pub fn childWindow(self: GuiContext, id: []const u8, w: f64, h: f64, callback: anytype) void {
            \\        const _vis = self._b.beginChildFn(id, w, h);
            \\        if (_vis) {
            \\            if (comptime @typeInfo(@TypeOf(callback)) == .@"fn") callback(self) else callback.call(self);
            \\        }
            \\        self._b.endChildFn();
            \\    }
            \\    pub fn treeNode(self: GuiContext, label: []const u8) bool { return self._b.treeNodeFn(label); }
            \\    pub fn treePop(self: GuiContext) void { self._b.treePopFn(); }
            \\    pub fn setColor(self: GuiContext, role: []const u8, r: f64, g: f64, b: f64, a: f64) void {
            \\        self._b.setColorFn(role, @floatCast(r), @floatCast(g), @floatCast(b), @floatCast(a));
            \\    }
            \\    pub fn setColorsDark(self: GuiContext) void { self._b.setColorsDarkFn(); }
            \\    pub fn setStyleFloat(self: GuiContext, name: []const u8, value: f64) void {
            \\        self._b.setStyleFloatFn(name, @floatCast(value));
            \\    }
            \\    pub fn setVec2(self: GuiContext, name: []const u8, x: f64, y: f64) void {
            \\        self._b.setVec2Fn(name, @floatCast(x), @floatCast(y));
            \\    }
            \\    pub fn scaleAllSizes(self: GuiContext, scale: f64) void {
            \\        self._b.scaleAllSizesFn(@floatCast(scale));
            \\    }
            \\    pub fn getDpi(self: GuiContext) f64 { return @floatCast(self._b.getDpiFn()); }
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
            \\    pub fn beginHBox(self: GuiContext, id: []const u8, stretch: bool) void { self._b.beginHBoxFn(id, stretch); }
            \\    pub fn endHBox(self: GuiContext) void { self._b.endHBoxFn(); }
            \\    pub fn beginVBox(self: GuiContext, id: []const u8, stretch: bool) void { self._b.beginVBoxFn(id, stretch); }
            \\    pub fn endVBox(self: GuiContext) void { self._b.endVBoxFn(); }
            \\    pub fn vbox(self: GuiContext, id: []const u8, stretch: bool) _GuiVBox { return .{ ._b = self._b, ._id = id, ._stretch = stretch }; }
            \\    pub fn hbox(self: GuiContext, id: []const u8, stretch: bool) _GuiHBox { return .{ ._b = self._b, ._id = id, ._stretch = stretch }; }
            \\    pub fn progressBar(self: GuiContext, label: []const u8, value: f64) void { self._b.progressBarFn(label, value); }
            \\    pub fn combobox(self: GuiContext, label: []const u8, items: std.ArrayList([]const u8), selected: i64) i64 { return self._b.comboboxFn(label, items.items, selected); }
            \\    pub fn spinbox(self: GuiContext, label: []const u8, value: i64, min: i64, max: i64) i64 { return self._b.spinboxFn(label, value, min, max); }
            \\    pub fn openFile(self: GuiContext) ?[]const u8 { return self._b.openFileFn(); }
            \\    pub fn saveFile(self: GuiContext) ?[]const u8 { return self._b.saveFileFn(); }
            \\    pub fn openFolder(self: GuiContext) ?[]const u8 { return self._b.openFolderFn(); }
            \\    pub fn msgBox(self: GuiContext, title: []const u8, description: []const u8) void { self._b.msgBoxFn(title, description); }
            \\    pub fn msgBoxError(self: GuiContext, title: []const u8, description: []const u8) void { self._b.msgBoxErrorFn(title, description); }
            \\};
            \\const _GuiVBox = struct {
            \\    _b: *const _GuiBackend,
            \\    _id: []const u8,
            \\    _stretch: bool,
            \\    pub fn begin(self: _GuiVBox) void { self._b.beginVBoxFn(self._id, self._stretch); }
            \\    pub fn end(self: _GuiVBox) void { self._b.endVBoxFn(); }
            \\};
            \\const _GuiHBox = struct {
            \\    _b: *const _GuiBackend,
            \\    _id: []const u8,
            \\    _stretch: bool,
            \\    pub fn begin(self: _GuiHBox) void { self._b.beginHBoxFn(self._id, self._stretch); }
            \\    pub fn end(self: _GuiHBox) void { self._b.endHBoxFn(); }
            \\};
            \\const Gui = GuiContext;
            \\fn _gui_run(title: []const u8, width: i64, height: i64, frame: anytype) void {
            \\    _gui_active_backend.initFn(title, width, height) catch @panic("gui init failed");
            \\    defer _gui_active_backend.deinitFn();
            \\    const _g = GuiContext{ ._b = &_gui_active_backend, .lowLevel = .{ ._b = &_gui_active_backend } };
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
            \\fn _gui_mvu_run(title: []const u8, width: i64, height: i64, _mvu_init: anytype, _mvu_update: anytype, _mvu_view: anytype) void {
            \\    _gui_active_backend.initFn(title, width, height) catch @panic("gui init failed");
            \\    defer _gui_active_backend.deinitFn();
            \\    const MsgType = comptime blk: {
            \\        if (@typeInfo(@TypeOf(_mvu_update)) == .@"fn")
            \\            break :blk @typeInfo(@TypeOf(_mvu_update)).@"fn".params[1].type.?
            \\        else
            \\            break :blk @typeInfo(@TypeOf(@TypeOf(_mvu_update).call)).@"fn".params[2].type.?;
            \\    };
            \\    const _MvuQueue = struct { buf: [32]MsgType = undefined, len: usize = 0 };
            \\    var _pq = _MvuQueue{};
            \\    const _sfn = struct {
            \\        fn send(ctx: *anyopaque, mp: *const anyopaque) void {
            \\            const q: *_MvuQueue = @ptrCast(@alignCast(ctx));
            \\            if (q.len < 32) { q.buf[q.len] = (@as(*const MsgType, @ptrCast(@alignCast(mp)))).* ; q.len += 1; }
            \\        }
            \\    }.send;
            \\    var _model = if (comptime @typeInfo(@TypeOf(_mvu_init)) == .@"fn") _mvu_init() else blk: { var _m = _mvu_init; break :blk _m.call(); };
            \\    const _g = GuiContext{ ._b = &_gui_active_backend, .lowLevel = .{ ._b = &_gui_active_backend }, ._send_fn = _sfn, ._send_ptr = &_pq };
            \\    while (_gui_active_backend.newFrameFn()) {
            \\        if (comptime @typeInfo(@TypeOf(_mvu_view)) == .@"fn") _mvu_view(_g, _model) else { var _mv = _mvu_view; _mv.call(_g, _model); }
            \\        for (_pq.buf[0.._pq.len]) |msg| {
            \\            if (comptime @typeInfo(@TypeOf(_mvu_update)) == .@"fn")
            \\                _model = _mvu_update(_model, msg)
            \\            else { var _mu = _mvu_update; _model = _mu.call(_model, msg); }
            \\        }
            \\        _pq.len = 0;
            \\        _gui_active_backend.endFrameFn();
            \\    }
            \\}
            \\
        );
        // ── Backend-specific implementation (includes _CodeEditor) ───────────
        switch (g.gui_backend) {
            .stub => try g.w.writeAll(
                \\// ─── CodeEditor widget — text buffer stub (no native editor) ─────────────────
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
                \\    const _r = _g.inputMultiline(id, _ed.text, w, h);
                \\    if (!_ed.read_only) { _ed.text = _r; }
                \\}
                \\fn _code_editor_set_error_markers(_ed: *_CodeEditor, _m: anytype) void { _ = _ed; _ = _m; }
                \\fn _code_editor_get_cursor_line(_ed: *_CodeEditor) i64 { _ = _ed; return 1; }
                \\fn _code_editor_get_cursor_col(_ed: *_CodeEditor) i64 { _ = _ed; return 1; }
                \\fn _code_editor_set_cursor_position(_ed: *_CodeEditor, line: i64, col: i64) void { _ = _ed; _ = line; _ = col; }
                \\// ─── Stub backend (single frame, prints to stderr) ───────────────────────────
                \\fn _stub_progressbar(_l: []const u8, _v: f64) void { std.debug.print("[gui] progressBar: {s} {d:.1}%\n", .{_l, _v * 100.0}); }
                \\fn _stub_combobox(_l: []const u8, _items: []const []const u8, _sel: i64) i64 { std.debug.print("[gui] combobox: {s} sel={d}/{d}\n", .{_l, _sel, _items.len}); return _sel; }
                \\fn _stub_spinbox(_l: []const u8, _v: i64, _min: i64, _max: i64) i64 { std.debug.print("[gui] spinbox: {s} val={d} [{d},{d}]\n", .{_l, _v, _min, _max}); return _v; }
                \\fn _stub_open_file() ?[]const u8 { std.debug.print("[gui] openFile (no window)\n", .{}); return null; }
                \\fn _stub_save_file() ?[]const u8 { std.debug.print("[gui] saveFile (no window)\n", .{}); return null; }
                \\fn _stub_open_folder() ?[]const u8 { std.debug.print("[gui] openFolder (no window)\n", .{}); return null; }
                \\fn _stub_msg_box(_t: []const u8, _m: []const u8) void { std.debug.print("[gui] msgBox: {s}: {s}\n", .{_t, _m}); }
                \\fn _stub_msg_box_error(_t: []const u8, _m: []const u8) void { std.debug.print("[gui] msgBoxError: {s}: {s}\n", .{_t, _m}); }
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
                \\fn _stub_selectable(label: []const u8) bool { std.debug.print("[gui] selectable: {s}\n", .{label}); return false; }
                \\fn _stub_text_colored(r: f32, gv: f32, b_: f32, a: f32, s: []const u8) void { _ = r; _ = gv; _ = b_; _ = a; std.debug.print("[gui] textColored: {s}\n", .{s}); }
                \\fn _stub_begin_table(id: []const u8, cols: i64) bool { std.debug.print("[gui] beginTable: {s} cols={d}\n", .{ id, cols }); return true; }
                \\fn _stub_table_setup_column(label: []const u8) void { std.debug.print("[gui] tableSetupColumn: {s}\n", .{label}); }
                \\fn _stub_table_headers_row() void {}
                \\fn _stub_table_next_row() void {}
                \\fn _stub_table_next_column() bool { return true; }
                \\fn _stub_end_table() void {}
                \\fn _stub_begin_child(id: []const u8, w: f64, h: f64) bool { _ = id; _ = w; _ = h; return true; }
                \\fn _stub_end_child() void {}
                \\fn _stub_tree_node(label: []const u8) bool { std.debug.print("[gui] treeNode: {s}\n", .{label}); return true; }
                \\fn _stub_tree_pop() void {}
                \\fn _stub_set_color(role: []const u8, r: f32, g: f32, b: f32, a: f32) void { _ = role; _ = r; _ = g; _ = b; _ = a; }
                \\fn _stub_set_colors_dark() void {}
                \\fn _stub_set_style_float(name: []const u8, value: f32) void { _ = name; _ = value; }
                \\fn _stub_set_vec2(name: []const u8, x: f32, y: f32) void { _ = name; _ = x; _ = y; }
                \\fn _stub_scale_all_sizes(scale: f32) void { _ = scale; }
                \\fn _stub_get_dpi() f32 { return 1.0; }
                \\fn _stub_ll_add_line(x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void { _ = x1; _ = y1; _ = x2; _ = y2; _ = col; _ = thickness; }
                \\fn _stub_ll_add_rect(x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void { _ = x1; _ = y1; _ = x2; _ = y2; _ = col; _ = thickness; }
                \\fn _stub_ll_add_rect_filled(x1: f64, y1: f64, x2: f64, y2: f64, col: i64) void { _ = x1; _ = y1; _ = x2; _ = y2; _ = col; }
                \\fn _stub_ll_add_circle(cx: f64, cy: f64, r: f64, col: i64, thickness: f64) void { _ = cx; _ = cy; _ = r; _ = col; _ = thickness; }
                \\fn _stub_ll_add_circle_filled(cx: f64, cy: f64, r: f64, col: i64) void { _ = cx; _ = cy; _ = r; _ = col; }
                \\fn _stub_ll_add_text(x: f64, y: f64, col: i64, text: []const u8) void { _ = x; _ = y; _ = col; _ = text; }
                \\fn _stub_ll_get_window_pos() _GuiVec2 { return .{ 0, 0 }; }
                \\fn _stub_ll_get_window_size() _GuiVec2 { return .{ 800, 600 }; }
                \\fn _stub_ll_get_cursor_pos() _GuiVec2 { return .{ 0, 0 }; }
                \\fn _stub_ll_get_mouse_pos() _GuiVec2 { return .{ 0, 0 }; }
                \\fn _stub_ll_begin_group() void {}
                \\fn _stub_ll_end_group() void {}
                \\fn _stub_begin_hbox(id: []const u8, stretch: bool) void { _ = id; _ = stretch; }
                \\fn _stub_end_hbox() void {}
                \\fn _stub_begin_vbox(id: []const u8, stretch: bool) void { _ = id; _ = stretch; }
                \\fn _stub_end_vbox() void {}
                \\const _gui_stub_backend = _GuiBackend{
                \\    .initFn             = _stub_init,
                \\    .deinitFn           = _stub_deinit,
                \\    .newFrameFn         = _stub_new_frame,
                \\    .endFrameFn         = _stub_end_frame,
                \\    .textFn             = _stub_text,
                \\    .separatorFn        = _stub_separator,
                \\    .sameLineFn         = _stub_same_line,
                \\    .spacingFn          = _stub_spacing,
                \\    .indentFn           = _stub_indent,
                \\    .unindentFn         = _stub_unindent,
                \\    .buttonFn           = _stub_button,
                \\    .checkboxFn         = _stub_checkbox,
                \\    .sliderFn           = _stub_slider,
                \\    .inputFn            = _stub_input,
                \\    .inputMultilineFn   = _stub_input_multiline,
                \\    .beginPanelFn       = _stub_begin_panel,
                \\    .endPanelFn         = _stub_end_panel,
                \\    .beginWindowFn      = _stub_begin_window,
                \\    .endWindowFn        = _stub_end_window,
                \\    .selectableFn       = _stub_selectable,
                \\    .textColoredFn      = _stub_text_colored,
                \\    .beginTableFn       = _stub_begin_table,
                \\    .tableSetupColumnFn = _stub_table_setup_column,
                \\    .tableHeadersRowFn  = _stub_table_headers_row,
                \\    .tableNextRowFn     = _stub_table_next_row,
                \\    .tableNextColumnFn  = _stub_table_next_column,
                \\    .endTableFn         = _stub_end_table,
                \\    .beginChildFn       = _stub_begin_child,
                \\    .endChildFn         = _stub_end_child,
                \\    .treeNodeFn         = _stub_tree_node,
                \\    .treePopFn          = _stub_tree_pop,
                \\    .setColorFn         = _stub_set_color,
                \\    .setColorsDarkFn    = _stub_set_colors_dark,
                \\    .setStyleFloatFn    = _stub_set_style_float,
                \\    .setVec2Fn          = _stub_set_vec2,
                \\    .scaleAllSizesFn    = _stub_scale_all_sizes,
                \\    .getDpiFn           = _stub_get_dpi,
                \\    .ll_addLineFn         = _stub_ll_add_line,
                \\    .ll_addRectFn         = _stub_ll_add_rect,
                \\    .ll_addRectFilledFn   = _stub_ll_add_rect_filled,
                \\    .ll_addCircleFn       = _stub_ll_add_circle,
                \\    .ll_addCircleFilledFn = _stub_ll_add_circle_filled,
                \\    .ll_addTextFn         = _stub_ll_add_text,
                \\    .ll_getWindowPosFn    = _stub_ll_get_window_pos,
                \\    .ll_getWindowSizeFn   = _stub_ll_get_window_size,
                \\    .ll_getCursorPosFn    = _stub_ll_get_cursor_pos,
                \\    .ll_getMousePosFn     = _stub_ll_get_mouse_pos,
                \\    .ll_beginGroupFn      = _stub_ll_begin_group,
                \\    .ll_endGroupFn        = _stub_ll_end_group,
                \\    .beginHBoxFn = _stub_begin_hbox,
                \\    .endHBoxFn   = _stub_end_hbox,
                \\    .beginVBoxFn = _stub_begin_vbox,
                \\    .endVBoxFn   = _stub_end_vbox,
                \\    .progressBarFn = _stub_progressbar,
                \\    .comboboxFn    = _stub_combobox,
                \\    .spinboxFn     = _stub_spinbox,
                \\    .openFileFn    = _stub_open_file,
                \\    .saveFileFn    = _stub_save_file,
                \\    .openFolderFn  = _stub_open_folder,
                \\    .msgBoxFn      = _stub_msg_box,
                \\    .msgBoxErrorFn = _stub_msg_box_error,
                \\};
                \\const _gui_active_backend: _GuiBackend = _gui_stub_backend;
                \\
            ),
            // ── zgui GLFW+OpenGL3 backend ──────────────────────────────────────
            // Requires a `zig build` project (not bare `zig run`).
            // main.zig wires up a generated project dir when uses_gui is true.
            .glfw => try g.w.writeAll(
                \\// ─── CodeEditor widget — ImGuiColorTextEdit via C shim ───────────────────────
                \\const te_c = @cImport(@cInclude("TextEditorC.h"));
                \\const _CodeEditor = struct { handle: te_c.TE_Handle, read_only: bool };
                \\fn _code_editor_new() *_CodeEditor {
                \\    const _ed = _allocator.create(_CodeEditor) catch unreachable;
                \\    _ed.* = .{ .handle = te_c.te_create(), .read_only = false };
                \\    return _ed;
                \\}
                \\fn _code_editor_set_text(_ed: *_CodeEditor, text: []const u8) void {
                \\    const _z = _allocator.dupeZ(u8, text) catch return;
                \\    defer _allocator.free(_z);
                \\    te_c.te_set_text(_ed.handle, _z);
                \\}
                \\fn _code_editor_get_text(_ed: *_CodeEditor) []const u8 {
                \\    const _c = te_c.te_get_text(_ed.handle) orelse return "";
                \\    return _allocator.dupe(u8, std.mem.span(_c)) catch "";
                \\}
                \\fn _code_editor_set_readonly(_ed: *_CodeEditor, v: bool) void {
                \\    _ed.read_only = v;
                \\    te_c.te_set_readonly(_ed.handle, if (v) @as(c_int, 1) else @as(c_int, 0));
                \\}
                \\fn _code_editor_render(_ed: *_CodeEditor, _g: GuiContext, id: []const u8, w: f64, h: f64) void {
                \\    _ = _g;
                \\    const _z = _allocator.dupeZ(u8, id) catch return;
                \\    defer _allocator.free(_z);
                \\    if (_mono_font) |mf| zgui.pushFont(mf, 0.0);
                \\    te_c.te_render(_ed.handle, _z, @floatCast(w), @floatCast(h));
                \\    if (_mono_font != null) zgui.popFont();
                \\}
                \\fn _code_editor_set_error_markers(_ed: *_CodeEditor, _m: anytype) void {
                \\    te_c.te_clear_errors(_ed.handle);
                \\    for (_m.items) |_d| {
                \\        const _mz = _allocator.dupeZ(u8, _d.message) catch continue;
                \\        defer _allocator.free(_mz);
                \\        te_c.te_add_error(_ed.handle, @intCast(_d.line), _mz);
                \\    }
                \\}
                \\fn _code_editor_get_cursor_line(_ed: *_CodeEditor) i64 { return @intCast(te_c.te_get_cursor_line(_ed.handle)); }
                \\fn _code_editor_get_cursor_col(_ed: *_CodeEditor) i64 { return @intCast(te_c.te_get_cursor_col(_ed.handle)); }
                \\fn _code_editor_set_cursor_position(_ed: *_CodeEditor, line: i64, col: i64) void {
                \\    te_c.te_set_cursor_position(_ed.handle, @intCast(line), @intCast(col));
                \\}
                \\// ─── zgui GLFW+OpenGL3 backend ──────────────────────────────────────────────
                \\const zgui    = @import("zgui");
                \\const zglfw   = @import("zglfw");
                \\const zopengl = @import("zopengl");
                \\var _gl_window: *zglfw.Window = undefined;
                \\var _mono_font: ?zgui.Font = null;
                \\// iOS 5-inspired dark theme — "Space Navy"
                \\// Deep navy base, accent blue (#1E78CB) for interactive elements,
                \\// 7px frame rounding, visible 1px borders, generous padding.
                \\fn _applyIOSTheme() void {
                \\    // The zgui GLFW backend renders in physical pixels (DisplayFramebufferScale=1).
                \\    // Read the OS content scale so fonts and style dimensions match display density.
                \\    const _cs = _gl_window.getContentScale();
                \\    const _dpi: f32 = @max(1.0, _cs[0]);
                \\    // UI font: Inter Regular — optional, loaded at runtime from vendor/fonts/.
                \\    var _ui_font_buf: [std.fs.max_path_bytes]u8 = undefined;
                \\    if (std.Io.Dir.cwd().realpath(_io, "vendor/fonts/Inter-Regular.ttf", &_ui_font_buf)) |abs_path| {
                \\        _ = zgui.io.addFontFromFile(abs_path, 15.0 * _dpi);
                \\    } else |_| {}
                \\    // Mono font: Cascadia Mono for code editors.
                \\    const MONO_FONT = "C:\\Windows\\Fonts\\CascadiaMono.ttf";
                \\    if (blk: { const _mf = std.Io.Dir.cwd().openFile(_io, MONO_FONT, .{}) catch break :blk false; _mf.close(_io); break :blk true; }) {
                \\        _mono_font = zgui.io.addFontFromFile(MONO_FONT, 13.0 * _dpi);
                \\    } else |_| {}
                \\    const s = zgui.getStyle();
                \\    zgui.styleColorsDark(s);
                \\    s.frame_rounding       = 7.0;
                \\    s.child_rounding       = 8.0;
                \\    s.popup_rounding       = 10.0;
                \\    s.scrollbar_rounding   = 6.0;
                \\    s.grab_rounding        = 5.0;
                \\    s.tab_rounding         = 6.0;
                \\    s.window_rounding      = 0.0;
                \\    s.frame_padding        = .{ 10.0, 6.0 };
                \\    s.item_spacing         = .{ 8.0,  6.0 };
                \\    s.window_padding       = .{ 12.0, 12.0 };
                \\    s.scrollbar_size       = 10.0;
                \\    s.grab_min_size        = 10.0;
                \\    s.window_border_size   = 0.0;
                \\    s.frame_border_size    = 1.0;
                \\    s.child_border_size    = 1.0;
                \\    s.popup_border_size    = 1.0;
                \\    s.setColor(.text,                    .{ 0.910, 0.929, 0.961, 1.00 });
                \\    s.setColor(.text_disabled,           .{ 0.353, 0.396, 0.502, 1.00 });
                \\    s.setColor(.window_bg,               .{ 0.102, 0.125, 0.208, 1.00 });
                \\    s.setColor(.child_bg,                .{ 0.125, 0.157, 0.251, 1.00 });
                \\    s.setColor(.popup_bg,                .{ 0.118, 0.149, 0.239, 0.97 });
                \\    s.setColor(.border,                  .{ 0.165, 0.208, 0.376, 1.00 });
                \\    s.setColor(.border_shadow,           .{ 0.000, 0.000, 0.000, 0.00 });
                \\    s.setColor(.frame_bg,                .{ 0.118, 0.157, 0.271, 1.00 });
                \\    s.setColor(.frame_bg_hovered,        .{ 0.161, 0.216, 0.380, 1.00 });
                \\    s.setColor(.frame_bg_active,         .{ 0.196, 0.267, 0.451, 1.00 });
                \\    s.setColor(.title_bg,                .{ 0.078, 0.094, 0.161, 1.00 });
                \\    s.setColor(.title_bg_active,         .{ 0.118, 0.431, 0.784, 1.00 });
                \\    s.setColor(.title_bg_collapsed,      .{ 0.078, 0.094, 0.161, 0.75 });
                \\    s.setColor(.menu_bar_bg,             .{ 0.090, 0.110, 0.184, 1.00 });
                \\    s.setColor(.scrollbar_bg,            .{ 0.102, 0.125, 0.208, 0.50 });
                \\    s.setColor(.scrollbar_grab,          .{ 0.227, 0.314, 0.565, 1.00 });
                \\    s.setColor(.scrollbar_grab_hovered,  .{ 0.278, 0.388, 0.659, 1.00 });
                \\    s.setColor(.scrollbar_grab_active,   .{ 0.118, 0.471, 0.796, 1.00 });
                \\    s.setColor(.check_mark,              .{ 0.118, 0.471, 0.796, 1.00 });
                \\    s.setColor(.slider_grab,             .{ 0.118, 0.431, 0.784, 1.00 });
                \\    s.setColor(.slider_grab_active,      .{ 0.118, 0.471, 0.796, 1.00 });
                \\    s.setColor(.button,                  .{ 0.118, 0.431, 0.784, 0.90 });
                \\    s.setColor(.button_hovered,          .{ 0.141, 0.471, 0.800, 1.00 });
                \\    s.setColor(.button_active,           .{ 0.082, 0.345, 0.639, 1.00 });
                \\    s.setColor(.header,                  .{ 0.118, 0.431, 0.784, 0.38 });
                \\    s.setColor(.header_hovered,          .{ 0.118, 0.431, 0.784, 0.58 });
                \\    s.setColor(.header_active,           .{ 0.118, 0.431, 0.784, 0.80 });
                \\    s.setColor(.separator,               .{ 0.145, 0.188, 0.314, 1.00 });
                \\    s.setColor(.separator_hovered,       .{ 0.118, 0.471, 0.796, 0.78 });
                \\    s.setColor(.separator_active,        .{ 0.118, 0.471, 0.796, 1.00 });
                \\    s.setColor(.resize_grip,             .{ 0.118, 0.431, 0.784, 0.25 });
                \\    s.setColor(.resize_grip_hovered,     .{ 0.118, 0.471, 0.796, 0.55 });
                \\    s.setColor(.resize_grip_active,      .{ 0.118, 0.471, 0.796, 0.90 });
                \\    s.setColor(.tab,                     .{ 0.118, 0.157, 0.251, 1.00 });
                \\    s.setColor(.tab_hovered,             .{ 0.118, 0.431, 0.784, 0.80 });
                \\    s.setColor(.tab_selected,            .{ 0.118, 0.431, 0.784, 1.00 });
                \\    s.setColor(.tab_dimmed,              .{ 0.098, 0.122, 0.200, 1.00 });
                \\    s.setColor(.tab_dimmed_selected,     .{ 0.137, 0.188, 0.337, 1.00 });
                \\    s.setColor(.table_header_bg,         .{ 0.118, 0.157, 0.271, 1.00 });
                \\    s.setColor(.table_border_strong,     .{ 0.188, 0.251, 0.427, 1.00 });
                \\    s.setColor(.table_border_light,      .{ 0.145, 0.196, 0.337, 1.00 });
                \\    s.setColor(.table_row_bg,            .{ 0.000, 0.000, 0.000, 0.00 });
                \\    s.setColor(.table_row_bg_alt,        .{ 0.157, 0.196, 0.318, 0.35 });
                \\    s.setColor(.text_selected_bg,        .{ 0.118, 0.431, 0.784, 0.45 });
                \\    s.setColor(.nav_cursor,              .{ 0.118, 0.471, 0.796, 1.00 });
                \\    s.setColor(.nav_windowing_highlight, .{ 1.000, 1.000, 1.000, 0.70 });
                \\    s.setColor(.nav_windowing_dim_bg,    .{ 0.078, 0.098, 0.165, 0.70 });
                \\    s.setColor(.modal_window_dim_bg,     .{ 0.063, 0.078, 0.133, 0.65 });
                \\    s.scaleAllSizes(_dpi);
                \\}
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
                \\    _applyIOSTheme();
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
                \\    zopengl.bindings.clearColor(0.102, 0.125, 0.208, 1.0);
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
                \\fn _imgui_selectable(label: []const u8) bool {
                \\    const _z = _allocator.dupeZ(u8, label) catch return false;
                \\    defer _allocator.free(_z);
                \\    return zgui.selectable(_z, .{});
                \\}
                \\fn _imgui_text_colored(r: f32, gv: f32, b_: f32, a: f32, s: []const u8) void {
                \\    zgui.pushStyleColor4f(.{ .idx = .text, .c = .{ r, gv, b_, a } });
                \\    zgui.textUnformatted(s);
                \\    zgui.popStyleColor(.{});
                \\}
                \\fn _imgui_begin_table(id: []const u8, cols: i64) bool {
                \\    const _z = _allocator.dupeZ(u8, id) catch return false;
                \\    defer _allocator.free(_z);
                \\    return zgui.beginTable(_z, .{ .column = @intCast(cols) });
                \\}
                \\fn _imgui_table_setup_column(label: []const u8) void {
                \\    const _z = _allocator.dupeZ(u8, label) catch return;
                \\    defer _allocator.free(_z);
                \\    zgui.tableSetupColumn(_z, .{});
                \\}
                \\fn _imgui_table_headers_row() void { zgui.tableHeadersRow(); }
                \\fn _imgui_table_next_row() void { zgui.tableNextRow(.{}); }
                \\fn _imgui_table_next_column() bool { return zgui.tableNextColumn(); }
                \\fn _imgui_end_table() void { zgui.endTable(); }
                \\fn _imgui_begin_child(id: []const u8, w: f64, h: f64) bool {
                \\    const _z = _allocator.dupeZ(u8, id) catch return false;
                \\    defer _allocator.free(_z);
                \\    return zgui.beginChild(_z, .{ .w = @floatCast(w), .h = @floatCast(h) });
                \\}
                \\fn _imgui_end_child() void { zgui.endChild(); }
                \\fn _imgui_tree_node(label: []const u8) bool {
                \\    const _z = _allocator.dupeZ(u8, label) catch return false;
                \\    defer _allocator.free(_z);
                \\    return zgui.treeNode(_z);
                \\}
                \\fn _imgui_tree_pop() void { zgui.treePop(); }
                \\fn _imgui_set_color(role: []const u8, r: f32, g: f32, b: f32, a: f32) void {
                \\    if (std.meta.stringToEnum(zgui.StyleCol, role)) |col| {
                \\        zgui.getStyle().setColor(col, .{ r, g, b, a });
                \\    }
                \\}
                \\fn _imgui_set_colors_dark() void { zgui.styleColorsDark(zgui.getStyle()); }
                \\fn _imgui_set_style_float(name: []const u8, value: f32) void {
                \\    const _s = zgui.getStyle();
                \\    if (std.mem.eql(u8, name, "frame_rounding"))         { _s.frame_rounding = value; }
                \\    else if (std.mem.eql(u8, name, "child_rounding"))     { _s.child_rounding = value; }
                \\    else if (std.mem.eql(u8, name, "popup_rounding"))     { _s.popup_rounding = value; }
                \\    else if (std.mem.eql(u8, name, "scrollbar_rounding")) { _s.scrollbar_rounding = value; }
                \\    else if (std.mem.eql(u8, name, "grab_rounding"))      { _s.grab_rounding = value; }
                \\    else if (std.mem.eql(u8, name, "tab_rounding"))       { _s.tab_rounding = value; }
                \\    else if (std.mem.eql(u8, name, "window_rounding"))    { _s.window_rounding = value; }
                \\    else if (std.mem.eql(u8, name, "scrollbar_size"))     { _s.scrollbar_size = value; }
                \\    else if (std.mem.eql(u8, name, "grab_min_size"))      { _s.grab_min_size = value; }
                \\    else if (std.mem.eql(u8, name, "window_border_size")) { _s.window_border_size = value; }
                \\    else if (std.mem.eql(u8, name, "frame_border_size"))  { _s.frame_border_size = value; }
                \\    else if (std.mem.eql(u8, name, "child_border_size"))  { _s.child_border_size = value; }
                \\    else if (std.mem.eql(u8, name, "popup_border_size"))  { _s.popup_border_size = value; }
                \\}
                \\fn _imgui_set_vec2(name: []const u8, x: f32, y: f32) void {
                \\    const _s = zgui.getStyle();
                \\    if (std.mem.eql(u8, name, "frame_padding"))         { _s.frame_padding = .{ x, y }; }
                \\    else if (std.mem.eql(u8, name, "item_spacing"))     { _s.item_spacing = .{ x, y }; }
                \\    else if (std.mem.eql(u8, name, "window_padding"))   { _s.window_padding = .{ x, y }; }
                \\}
                \\fn _imgui_scale_all_sizes(scale: f32) void { zgui.getStyle().scaleAllSizes(scale); }
                \\fn _imgui_get_dpi() f32 {
                \\    const _mon = zglfw.getPrimaryMonitor() orelse return 1.0;
                \\    const _cs = _mon.getContentScale();
                \\    return @max(1.0, _cs[0]);
                \\}
                \\fn _imgui_ll_add_line(x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void {
                \\    const _dl = zgui.getWindowDrawList();
                \\    _dl.addLine(.{ .p1 = .{ @floatCast(x1), @floatCast(y1) }, .p2 = .{ @floatCast(x2), @floatCast(y2) }, .col = @intCast(col), .thickness = @floatCast(thickness) });
                \\}
                \\fn _imgui_ll_add_rect(x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void {
                \\    const _dl = zgui.getWindowDrawList();
                \\    _dl.addRect(.{ .pmin = .{ @floatCast(x1), @floatCast(y1) }, .pmax = .{ @floatCast(x2), @floatCast(y2) }, .col = @intCast(col), .thickness = @floatCast(thickness) });
                \\}
                \\fn _imgui_ll_add_rect_filled(x1: f64, y1: f64, x2: f64, y2: f64, col: i64) void {
                \\    const _dl = zgui.getWindowDrawList();
                \\    _dl.addRectFilled(.{ .pmin = .{ @floatCast(x1), @floatCast(y1) }, .pmax = .{ @floatCast(x2), @floatCast(y2) }, .col = @intCast(col) });
                \\}
                \\fn _imgui_ll_add_circle(cx: f64, cy: f64, r: f64, col: i64, thickness: f64) void {
                \\    const _dl = zgui.getWindowDrawList();
                \\    _dl.addCircle(.{ .p = .{ @floatCast(cx), @floatCast(cy) }, .r = @floatCast(r), .col = @intCast(col), .thickness = @floatCast(thickness) });
                \\}
                \\fn _imgui_ll_add_circle_filled(cx: f64, cy: f64, r: f64, col: i64) void {
                \\    const _dl = zgui.getWindowDrawList();
                \\    _dl.addCircleFilled(.{ .p = .{ @floatCast(cx), @floatCast(cy) }, .r = @floatCast(r), .col = @intCast(col) });
                \\}
                \\fn _imgui_ll_add_text(x: f64, y: f64, col: i64, text: []const u8) void {
                \\    const _dl = zgui.getWindowDrawList();
                \\    _dl.addTextUnformatted(.{ @floatCast(x), @floatCast(y) }, @intCast(col), text);
                \\}
                \\fn _imgui_ll_get_window_pos() _GuiVec2 { const _p = zgui.getWindowPos(); return .{ @floatCast(_p[0]), @floatCast(_p[1]) }; }
                \\fn _imgui_ll_get_window_size() _GuiVec2 { const _p = zgui.getWindowSize(); return .{ @floatCast(_p[0]), @floatCast(_p[1]) }; }
                \\fn _imgui_ll_get_cursor_pos() _GuiVec2 { const _p = zgui.getCursorPos(); return .{ @floatCast(_p[0]), @floatCast(_p[1]) }; }
                \\fn _imgui_ll_get_mouse_pos() _GuiVec2 { const _p = zgui.getMousePos(); return .{ @floatCast(_p[0]), @floatCast(_p[1]) }; }
                \\fn _imgui_ll_begin_group() void { zgui.beginGroup(); }
                \\fn _imgui_ll_end_group() void { zgui.endGroup(); }
                \\fn _imgui_begin_hbox(id: []const u8, stretch: bool) void { _ = id; _ = stretch; }
                \\fn _imgui_end_hbox() void {}
                \\fn _imgui_begin_vbox(id: []const u8, stretch: bool) void { _ = id; _ = stretch; }
                \\fn _imgui_end_vbox() void {}
                \\fn _imgui_progressbar(_l: []const u8, _v: f64) void { _ = _l; _ = _v; }
                \\fn _imgui_combobox(_l: []const u8, _items: []const []const u8, _sel: i64) i64 { _ = _l; _ = _items; return _sel; }
                \\fn _imgui_spinbox(_l: []const u8, _v: i64, _min: i64, _max: i64) i64 { _ = _l; _ = _min; _ = _max; return _v; }
                \\fn _imgui_open_file() ?[]const u8 { return null; }
                \\fn _imgui_save_file() ?[]const u8 { return null; }
                \\fn _imgui_open_folder() ?[]const u8 { return null; }
                \\fn _imgui_msg_box(_t: []const u8, _m: []const u8) void { _ = _t; _ = _m; }
                \\fn _imgui_msg_box_error(_t: []const u8, _m: []const u8) void { _ = _t; _ = _m; }
                \\const _gui_imgui_backend = _GuiBackend{
                \\    .initFn             = _imgui_init,
                \\    .deinitFn           = _imgui_deinit,
                \\    .newFrameFn         = _imgui_new_frame,
                \\    .endFrameFn         = _imgui_end_frame,
                \\    .textFn             = _imgui_text,
                \\    .separatorFn        = _imgui_separator,
                \\    .sameLineFn         = _imgui_same_line,
                \\    .spacingFn          = _imgui_spacing,
                \\    .indentFn           = _imgui_indent,
                \\    .unindentFn         = _imgui_unindent,
                \\    .buttonFn           = _imgui_button,
                \\    .checkboxFn         = _imgui_checkbox,
                \\    .sliderFn           = _imgui_slider,
                \\    .inputFn            = _imgui_input,
                \\    .inputMultilineFn   = _imgui_input_multiline,
                \\    .beginPanelFn       = _imgui_begin_panel,
                \\    .endPanelFn         = _imgui_end_panel,
                \\    .beginWindowFn      = _imgui_begin_window,
                \\    .endWindowFn        = _imgui_end_window,
                \\    .selectableFn       = _imgui_selectable,
                \\    .textColoredFn      = _imgui_text_colored,
                \\    .beginTableFn       = _imgui_begin_table,
                \\    .tableSetupColumnFn = _imgui_table_setup_column,
                \\    .tableHeadersRowFn  = _imgui_table_headers_row,
                \\    .tableNextRowFn     = _imgui_table_next_row,
                \\    .tableNextColumnFn  = _imgui_table_next_column,
                \\    .endTableFn         = _imgui_end_table,
                \\    .beginChildFn       = _imgui_begin_child,
                \\    .endChildFn         = _imgui_end_child,
                \\    .treeNodeFn         = _imgui_tree_node,
                \\    .treePopFn          = _imgui_tree_pop,
                \\    .setColorFn         = _imgui_set_color,
                \\    .setColorsDarkFn    = _imgui_set_colors_dark,
                \\    .setStyleFloatFn    = _imgui_set_style_float,
                \\    .setVec2Fn          = _imgui_set_vec2,
                \\    .scaleAllSizesFn      = _imgui_scale_all_sizes,
                \\    .getDpiFn             = _imgui_get_dpi,
                \\    .ll_addLineFn         = _imgui_ll_add_line,
                \\    .ll_addRectFn         = _imgui_ll_add_rect,
                \\    .ll_addRectFilledFn   = _imgui_ll_add_rect_filled,
                \\    .ll_addCircleFn       = _imgui_ll_add_circle,
                \\    .ll_addCircleFilledFn = _imgui_ll_add_circle_filled,
                \\    .ll_addTextFn         = _imgui_ll_add_text,
                \\    .ll_getWindowPosFn    = _imgui_ll_get_window_pos,
                \\    .ll_getWindowSizeFn   = _imgui_ll_get_window_size,
                \\    .ll_getCursorPosFn    = _imgui_ll_get_cursor_pos,
                \\    .ll_getMousePosFn     = _imgui_ll_get_mouse_pos,
                \\    .ll_beginGroupFn      = _imgui_ll_begin_group,
                \\    .ll_endGroupFn        = _imgui_ll_end_group,
                \\    .beginHBoxFn = _imgui_begin_hbox,
                \\    .endHBoxFn   = _imgui_end_hbox,
                \\    .beginVBoxFn = _imgui_begin_vbox,
                \\    .endVBoxFn   = _imgui_end_vbox,
                \\    .progressBarFn = _imgui_progressbar,
                \\    .comboboxFn    = _imgui_combobox,
                \\    .spinboxFn     = _imgui_spinbox,
                \\    .openFileFn    = _imgui_open_file,
                \\    .saveFileFn    = _imgui_save_file,
                \\    .openFolderFn  = _imgui_open_folder,
                \\    .msgBoxFn      = _imgui_msg_box,
                \\    .msgBoxErrorFn = _imgui_msg_box_error,
                \\};
                \\const _gui_active_backend: _GuiBackend = _gui_imgui_backend;
                \\
            ),
            // sdl2 / dx12 not yet implemented — fall through to stub.
            .sdl2, .dx12 => try g.w.writeAll(
                \\// TODO: sdl2/dx12 GUI backend not yet implemented; using stub.
                \\// ─── CodeEditor widget — text buffer stub (no native editor) ─────────────────
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
                \\    const _r = _g.inputMultiline(id, _ed.text, w, h);
                \\    if (!_ed.read_only) { _ed.text = _r; }
                \\}
                \\fn _code_editor_set_error_markers(_ed: *_CodeEditor, _m: anytype) void { _ = _ed; _ = _m; }
                \\fn _code_editor_get_cursor_line(_ed: *_CodeEditor) i64 { _ = _ed; return 1; }
                \\fn _code_editor_get_cursor_col(_ed: *_CodeEditor) i64 { _ = _ed; return 1; }
                \\fn _code_editor_set_cursor_position(_ed: *_CodeEditor, line: i64, col: i64) void { _ = _ed; _ = line; _ = col; }
                \\fn _stub_progressbar(_l: []const u8, _v: f64) void { std.debug.print("[gui] progressBar: {s} {d:.1}%\n", .{_l, _v * 100.0}); }
                \\fn _stub_combobox(_l: []const u8, _items: []const []const u8, _sel: i64) i64 { std.debug.print("[gui] combobox: {s} sel={d}/{d}\n", .{_l, _sel, _items.len}); return _sel; }
                \\fn _stub_spinbox(_l: []const u8, _v: i64, _min: i64, _max: i64) i64 { std.debug.print("[gui] spinbox: {s} val={d} [{d},{d}]\n", .{_l, _v, _min, _max}); return _v; }
                \\fn _stub_open_file() ?[]const u8 { std.debug.print("[gui] openFile (no window)\n", .{}); return null; }
                \\fn _stub_save_file() ?[]const u8 { std.debug.print("[gui] saveFile (no window)\n", .{}); return null; }
                \\fn _stub_open_folder() ?[]const u8 { std.debug.print("[gui] openFolder (no window)\n", .{}); return null; }
                \\fn _stub_msg_box(_t: []const u8, _m: []const u8) void { std.debug.print("[gui] msgBox: {s}: {s}\n", .{_t, _m}); }
                \\fn _stub_msg_box_error(_t: []const u8, _m: []const u8) void { std.debug.print("[gui] msgBoxError: {s}: {s}\n", .{_t, _m}); }
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
                \\fn _stub_selectable(label: []const u8) bool { std.debug.print("[gui] selectable: {s}\n", .{label}); return false; }
                \\fn _stub_text_colored(r: f32, gv: f32, b_: f32, a: f32, s: []const u8) void { _ = r; _ = gv; _ = b_; _ = a; std.debug.print("[gui] textColored: {s}\n", .{s}); }
                \\fn _stub_begin_table(id: []const u8, cols: i64) bool { std.debug.print("[gui] beginTable: {s} cols={d}\n", .{ id, cols }); return true; }
                \\fn _stub_table_setup_column(label: []const u8) void { std.debug.print("[gui] tableSetupColumn: {s}\n", .{label}); }
                \\fn _stub_table_headers_row() void {}
                \\fn _stub_table_next_row() void {}
                \\fn _stub_table_next_column() bool { return true; }
                \\fn _stub_end_table() void {}
                \\fn _stub_begin_child(id: []const u8, w: f64, h: f64) bool { _ = id; _ = w; _ = h; return true; }
                \\fn _stub_end_child() void {}
                \\fn _stub_tree_node(label: []const u8) bool { std.debug.print("[gui] treeNode: {s}\n", .{label}); return true; }
                \\fn _stub_tree_pop() void {}
                \\fn _stub_set_color(role: []const u8, r: f32, g: f32, b: f32, a: f32) void { _ = role; _ = r; _ = g; _ = b; _ = a; }
                \\fn _stub_set_colors_dark() void {}
                \\fn _stub_set_style_float(name: []const u8, value: f32) void { _ = name; _ = value; }
                \\fn _stub_set_vec2(name: []const u8, x: f32, y: f32) void { _ = name; _ = x; _ = y; }
                \\fn _stub_scale_all_sizes(scale: f32) void { _ = scale; }
                \\fn _stub_get_dpi() f32 { return 1.0; }
                \\fn _stub_ll_add_line(x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void { _ = x1; _ = y1; _ = x2; _ = y2; _ = col; _ = thickness; }
                \\fn _stub_ll_add_rect(x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void { _ = x1; _ = y1; _ = x2; _ = y2; _ = col; _ = thickness; }
                \\fn _stub_ll_add_rect_filled(x1: f64, y1: f64, x2: f64, y2: f64, col: i64) void { _ = x1; _ = y1; _ = x2; _ = y2; _ = col; }
                \\fn _stub_ll_add_circle(cx: f64, cy: f64, r: f64, col: i64, thickness: f64) void { _ = cx; _ = cy; _ = r; _ = col; _ = thickness; }
                \\fn _stub_ll_add_circle_filled(cx: f64, cy: f64, r: f64, col: i64) void { _ = cx; _ = cy; _ = r; _ = col; }
                \\fn _stub_ll_add_text(x: f64, y: f64, col: i64, text: []const u8) void { _ = x; _ = y; _ = col; _ = text; }
                \\fn _stub_ll_get_window_pos() _GuiVec2 { return .{ 0, 0 }; }
                \\fn _stub_ll_get_window_size() _GuiVec2 { return .{ 800, 600 }; }
                \\fn _stub_ll_get_cursor_pos() _GuiVec2 { return .{ 0, 0 }; }
                \\fn _stub_ll_get_mouse_pos() _GuiVec2 { return .{ 0, 0 }; }
                \\fn _stub_ll_begin_group() void {}
                \\fn _stub_ll_end_group() void {}
                \\fn _stub_begin_hbox(id: []const u8, stretch: bool) void { _ = id; _ = stretch; }
                \\fn _stub_end_hbox() void {}
                \\fn _stub_begin_vbox(id: []const u8, stretch: bool) void { _ = id; _ = stretch; }
                \\fn _stub_end_vbox() void {}
                \\const _gui_stub_backend = _GuiBackend{
                \\    .initFn             = _stub_init,
                \\    .deinitFn           = _stub_deinit,
                \\    .newFrameFn         = _stub_new_frame,
                \\    .endFrameFn         = _stub_end_frame,
                \\    .textFn             = _stub_text,
                \\    .separatorFn        = _stub_separator,
                \\    .sameLineFn         = _stub_same_line,
                \\    .spacingFn          = _stub_spacing,
                \\    .indentFn           = _stub_indent,
                \\    .unindentFn         = _stub_unindent,
                \\    .buttonFn           = _stub_button,
                \\    .checkboxFn         = _stub_checkbox,
                \\    .sliderFn           = _stub_slider,
                \\    .inputFn            = _stub_input,
                \\    .inputMultilineFn   = _stub_input_multiline,
                \\    .beginPanelFn       = _stub_begin_panel,
                \\    .endPanelFn         = _stub_end_panel,
                \\    .beginWindowFn      = _stub_begin_window,
                \\    .endWindowFn        = _stub_end_window,
                \\    .selectableFn       = _stub_selectable,
                \\    .textColoredFn      = _stub_text_colored,
                \\    .beginTableFn       = _stub_begin_table,
                \\    .tableSetupColumnFn = _stub_table_setup_column,
                \\    .tableHeadersRowFn  = _stub_table_headers_row,
                \\    .tableNextRowFn     = _stub_table_next_row,
                \\    .tableNextColumnFn  = _stub_table_next_column,
                \\    .endTableFn         = _stub_end_table,
                \\    .beginChildFn       = _stub_begin_child,
                \\    .endChildFn         = _stub_end_child,
                \\    .treeNodeFn         = _stub_tree_node,
                \\    .treePopFn          = _stub_tree_pop,
                \\    .setColorFn         = _stub_set_color,
                \\    .setColorsDarkFn    = _stub_set_colors_dark,
                \\    .setStyleFloatFn    = _stub_set_style_float,
                \\    .setVec2Fn          = _stub_set_vec2,
                \\    .scaleAllSizesFn    = _stub_scale_all_sizes,
                \\    .getDpiFn           = _stub_get_dpi,
                \\    .ll_addLineFn         = _stub_ll_add_line,
                \\    .ll_addRectFn         = _stub_ll_add_rect,
                \\    .ll_addRectFilledFn   = _stub_ll_add_rect_filled,
                \\    .ll_addCircleFn       = _stub_ll_add_circle,
                \\    .ll_addCircleFilledFn = _stub_ll_add_circle_filled,
                \\    .ll_addTextFn         = _stub_ll_add_text,
                \\    .ll_getWindowPosFn    = _stub_ll_get_window_pos,
                \\    .ll_getWindowSizeFn   = _stub_ll_get_window_size,
                \\    .ll_getCursorPosFn    = _stub_ll_get_cursor_pos,
                \\    .ll_getMousePosFn     = _stub_ll_get_mouse_pos,
                \\    .ll_beginGroupFn      = _stub_ll_begin_group,
                \\    .ll_endGroupFn        = _stub_ll_end_group,
                \\    .beginHBoxFn = _stub_begin_hbox,
                \\    .endHBoxFn   = _stub_end_hbox,
                \\    .beginVBoxFn = _stub_begin_vbox,
                \\    .endVBoxFn   = _stub_end_vbox,
                \\    .progressBarFn = _stub_progressbar,
                \\    .comboboxFn    = _stub_combobox,
                \\    .spinboxFn     = _stub_spinbox,
                \\    .openFileFn    = _stub_open_file,
                \\    .saveFileFn    = _stub_save_file,
                \\    .openFolderFn  = _stub_open_folder,
                \\    .msgBoxFn      = _stub_msg_box,
                \\    .msgBoxErrorFn = _stub_msg_box_error,
                \\};
                \\const _gui_active_backend: _GuiBackend = _gui_stub_backend;
                \\
            ),
            // ── ZigZag TUI backend ────────────────────────────────────────────
            // Requires a `zig build` project with the `zigzag` dependency.
            // main.zig wires up a generated project dir when uses_gui is true.
            .tui => try g.w.writeAll(
                \\// ─── CodeEditor widget — text buffer stub (no native editor) ─────────────────
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
                \\    const _r = _g.inputMultiline(id, _ed.text, w, h);
                \\    if (!_ed.read_only) { _ed.text = _r; }
                \\}
                \\fn _code_editor_set_error_markers(_ed: *_CodeEditor, _m: anytype) void { _ = _ed; _ = _m; }
                \\fn _code_editor_get_cursor_line(_ed: *_CodeEditor) i64 { _ = _ed; return 1; }
                \\fn _code_editor_get_cursor_col(_ed: *_CodeEditor) i64 { _ = _ed; return 1; }
                \\fn _code_editor_set_cursor_position(_ed: *_CodeEditor, line: i64, col: i64) void { _ = _ed; _ = line; _ = col; }
                \\// ─── ZigZag TUI backend ──────────────────────────────────────────────────────
                \\const zz = @import("zigzag");
                \\var _tui_env: *std.process.Environ.Map = undefined;
                \\var _tui_terminal: ?zz.Terminal = null;
                \\var _tui_current_row: u16 = 0;
                \\var _tui_click_y: i32 = -1;
                \\var _tui_quit: bool = false;
                \\var _tui_indent_level: u16 = 0;
                \\fn _tui_init(title: []const u8, width: i64, height: i64) anyerror!void {
                \\    _ = width; _ = height;
                \\    var _t = try zz.Terminal.init(_io, _tui_env, .{
                \\        .alt_screen = true,
                \\        .mouse = true,
                \\        .hide_cursor = true,
                \\        .bracketed_paste = false,
                \\    });
                \\    try _t.setTitle(title);
                \\    _tui_terminal = _t;
                \\}
                \\fn _tui_deinit() void {
                \\    if (_tui_terminal) |*_t| _t.deinit();
                \\    _tui_terminal = null;
                \\}
                \\fn _tui_new_frame() bool {
                \\    if (_tui_quit) return false;
                \\    const _t = &(_tui_terminal orelse return false);
                \\    _tui_click_y = -1;
                \\    _tui_indent_level = 0;
                \\    var _buf: [256]u8 = undefined;
                \\    const _n = _t.readInput(&_buf, 16) catch 0;
                \\    if (_n > 0) {
                \\        const _evs = zz.input.keyboard.parseAll(_allocator, _buf[0.._n]) catch &.{};
                \\        for (_evs) |_ev| {
                \\            switch (_ev) {
                \\                .key => |_k| switch (_k.key) {
                \\                    .char => |_c| { if (_c == 'q' or _c == 'Q') _tui_quit = true; },
                \\                    .escape => { _tui_quit = true; },
                \\                    else => {},
                \\                },
                \\                .mouse => |_m| {
                \\                    if (_m.event_type == .press and _m.button == .left)
                \\                        _tui_click_y = @as(i32, _m.y);
                \\                },
                \\                .none => {},
                \\            }
                \\        }
                \\    }
                \\    _t.clear() catch return false;
                \\    _tui_current_row = 0;
                \\    return !_tui_quit;
                \\}
                \\fn _tui_end_frame() void {
                \\    if (_tui_terminal) |*_t| _t.flush() catch {};
                \\}
                \\fn _tui_text(s: []const u8) void {
                \\    if (_tui_terminal) |*_t| {
                \\        _t.writeAt(_tui_current_row, _tui_indent_level * 2, s) catch {};
                \\        _tui_current_row += 1;
                \\    }
                \\}
                \\fn _tui_separator() void {
                \\    if (_tui_terminal) |*_t| {
                \\        _t.writeAt(_tui_current_row, 0, "──────────────────────────────") catch {};
                \\        _tui_current_row += 1;
                \\    }
                \\}
                \\fn _tui_same_line() void {}
                \\fn _tui_spacing() void { _tui_current_row += 1; }
                \\fn _tui_indent() void { _tui_indent_level += 1; }
                \\fn _tui_unindent() void { if (_tui_indent_level > 0) _tui_indent_level -= 1; }
                \\fn _tui_button(label: []const u8) bool {
                \\    const _row = _tui_current_row;
                \\    _tui_current_row += 1;
                \\    if (_tui_terminal) |*_t| {
                \\        const _col = _tui_indent_level * 2;
                \\        const _clicked = (_tui_click_y == @as(i32, _row));
                \\        var _buf: [256]u8 = undefined;
                \\        const _s = std.fmt.bufPrint(&_buf, "[ {s} ]", .{label}) catch label;
                \\        if (_clicked) {
                \\            var _sb: [320]u8 = undefined;
                \\            const _rs = std.fmt.bufPrint(&_sb, "\x1b[7m{s}\x1b[27m", .{_s}) catch _s;
                \\            _t.writeAt(_row, _col, _rs) catch {};
                \\        } else {
                \\            _t.writeAt(_row, _col, _s) catch {};
                \\        }
                \\        return _clicked;
                \\    }
                \\    return false;
                \\}
                \\fn _tui_checkbox(label: []const u8, value: bool) bool {
                \\    const _row = _tui_current_row;
                \\    _tui_current_row += 1;
                \\    if (_tui_terminal) |*_t| {
                \\        const _col = _tui_indent_level * 2;
                \\        var _buf: [256]u8 = undefined;
                \\        const _s = std.fmt.bufPrint(&_buf, "[{s}] {s}", .{ if (value) "x" else " ", label }) catch label;
                \\        _t.writeAt(_row, _col, _s) catch {};
                \\        if (_tui_click_y == @as(i32, _row)) return !value;
                \\    }
                \\    return value;
                \\}
                \\fn _tui_slider(label: []const u8, value: f64, min: f64, max: f64) f64 {
                \\    _ = min; _ = max;
                \\    if (_tui_terminal) |*_t| {
                \\        const _col = _tui_indent_level * 2;
                \\        var _buf: [256]u8 = undefined;
                \\        const _s = std.fmt.bufPrint(&_buf, "{s}: {d:.2}", .{ label, value }) catch label;
                \\        _t.writeAt(_tui_current_row, _col, _s) catch {};
                \\        _tui_current_row += 1;
                \\    }
                \\    return value;
                \\}
                \\fn _tui_input(label: []const u8, value: []const u8) []const u8 {
                \\    if (_tui_terminal) |*_t| {
                \\        const _col = _tui_indent_level * 2;
                \\        var _buf: [256]u8 = undefined;
                \\        const _s = std.fmt.bufPrint(&_buf, "{s}: {s}", .{ label, value }) catch label;
                \\        _t.writeAt(_tui_current_row, _col, _s) catch {};
                \\        _tui_current_row += 1;
                \\    }
                \\    return value;
                \\}
                \\fn _tui_input_multiline(label: []const u8, value: []const u8, w: f64, h: f64) []const u8 {
                \\    _ = w; _ = h;
                \\    return _tui_input(label, value);
                \\}
                \\fn _tui_begin_panel(label: []const u8) bool {
                \\    if (_tui_terminal) |*_t| {
                \\        const _col = _tui_indent_level * 2;
                \\        var _buf: [256]u8 = undefined;
                \\        const _s = std.fmt.bufPrint(&_buf, "\x1b[1m\u{25b6} {s}\x1b[22m", .{label}) catch label;
                \\        _t.writeAt(_tui_current_row, _col, _s) catch {};
                \\        _tui_current_row += 1;
                \\        _tui_indent_level += 1;
                \\    }
                \\    return true;
                \\}
                \\fn _tui_end_panel() void { if (_tui_indent_level > 0) _tui_indent_level -= 1; }
                \\fn _tui_begin_window(label: []const u8) bool { return _tui_begin_panel(label); }
                \\fn _tui_end_window() void { _tui_end_panel(); }
                \\fn _tui_selectable(label: []const u8) bool {
                \\    const _row = _tui_current_row;
                \\    _tui_text(label);
                \\    return _tui_click_y == @as(i32, _row);
                \\}
                \\fn _tui_text_colored(r: f32, gv: f32, b_: f32, a: f32, s: []const u8) void {
                \\    _ = r; _ = gv; _ = b_; _ = a;
                \\    _tui_text(s);
                \\}
                \\fn _tui_begin_table(id: []const u8, cols: i64) bool { _ = id; _ = cols; return true; }
                \\fn _tui_table_setup_column(label: []const u8) void { _ = label; }
                \\fn _tui_table_headers_row() void {}
                \\fn _tui_table_next_row() void { _tui_current_row += 1; }
                \\fn _tui_table_next_column() bool { return true; }
                \\fn _tui_end_table() void {}
                \\fn _tui_begin_child(id: []const u8, w: f64, h: f64) bool { _ = id; _ = w; _ = h; return true; }
                \\fn _tui_end_child() void {}
                \\fn _tui_tree_node(label: []const u8) bool { return _tui_begin_panel(label); }
                \\fn _tui_tree_pop() void { _tui_end_panel(); }
                \\fn _tui_set_color(role: []const u8, r: f32, g: f32, b: f32, a: f32) void { _ = role; _ = r; _ = g; _ = b; _ = a; }
                \\fn _tui_set_colors_dark() void {}
                \\fn _tui_set_style_float(name: []const u8, value: f32) void { _ = name; _ = value; }
                \\fn _tui_set_vec2(name: []const u8, x: f32, y: f32) void { _ = name; _ = x; _ = y; }
                \\fn _tui_scale_all_sizes(scale: f32) void { _ = scale; }
                \\fn _tui_get_dpi() f32 { return 1.0; }
                \\fn _tui_ll_add_line(x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void { _ = x1; _ = y1; _ = x2; _ = y2; _ = col; _ = thickness; }
                \\fn _tui_ll_add_rect(x1: f64, y1: f64, x2: f64, y2: f64, col: i64, thickness: f64) void { _ = x1; _ = y1; _ = x2; _ = y2; _ = col; _ = thickness; }
                \\fn _tui_ll_add_rect_filled(x1: f64, y1: f64, x2: f64, y2: f64, col: i64) void { _ = x1; _ = y1; _ = x2; _ = y2; _ = col; }
                \\fn _tui_ll_add_circle(cx: f64, cy: f64, r: f64, col: i64, thickness: f64) void { _ = cx; _ = cy; _ = r; _ = col; _ = thickness; }
                \\fn _tui_ll_add_circle_filled(cx: f64, cy: f64, r: f64, col: i64) void { _ = cx; _ = cy; _ = r; _ = col; }
                \\fn _tui_ll_add_text(x: f64, y: f64, col: i64, text: []const u8) void { _ = x; _ = y; _ = col; _ = text; }
                \\fn _tui_ll_get_window_pos() _GuiVec2 { return .{ 0, 0 }; }
                \\fn _tui_ll_get_window_size() _GuiVec2 { return .{ 80, 24 }; }
                \\fn _tui_ll_get_cursor_pos() _GuiVec2 { return .{ 0, @floatFromInt(_tui_current_row) }; }
                \\fn _tui_ll_get_mouse_pos() _GuiVec2 {
                \\    return .{ 0, if (_tui_click_y >= 0) @floatFromInt(_tui_click_y) else -1 };
                \\}
                \\fn _tui_ll_begin_group() void {}
                \\fn _tui_ll_end_group() void {}
                \\fn _tui_begin_hbox(id: []const u8, stretch: bool) void { _ = id; _ = stretch; }
                \\fn _tui_end_hbox() void {}
                \\fn _tui_begin_vbox(id: []const u8, stretch: bool) void { _ = id; _ = stretch; }
                \\fn _tui_end_vbox() void {}
                \\fn _tui_progressbar(_l: []const u8, _v: f64) void { _ = _l; _ = _v; }
                \\fn _tui_combobox(_l: []const u8, _items: []const []const u8, _sel: i64) i64 { _ = _l; _ = _items; return _sel; }
                \\fn _tui_spinbox(_l: []const u8, _v: i64, _min: i64, _max: i64) i64 { _ = _l; _ = _min; _ = _max; return _v; }
                \\fn _tui_open_file() ?[]const u8 { return null; }
                \\fn _tui_save_file() ?[]const u8 { return null; }
                \\fn _tui_open_folder() ?[]const u8 { return null; }
                \\fn _tui_msg_box(_t: []const u8, _m: []const u8) void { _ = _t; _ = _m; }
                \\fn _tui_msg_box_error(_t: []const u8, _m: []const u8) void { _ = _t; _ = _m; }
                \\const _gui_tui_backend = _GuiBackend{
                \\    .initFn             = _tui_init,
                \\    .deinitFn           = _tui_deinit,
                \\    .newFrameFn         = _tui_new_frame,
                \\    .endFrameFn         = _tui_end_frame,
                \\    .textFn             = _tui_text,
                \\    .separatorFn        = _tui_separator,
                \\    .sameLineFn         = _tui_same_line,
                \\    .spacingFn          = _tui_spacing,
                \\    .indentFn           = _tui_indent,
                \\    .unindentFn         = _tui_unindent,
                \\    .buttonFn           = _tui_button,
                \\    .checkboxFn         = _tui_checkbox,
                \\    .sliderFn           = _tui_slider,
                \\    .inputFn            = _tui_input,
                \\    .inputMultilineFn   = _tui_input_multiline,
                \\    .beginPanelFn       = _tui_begin_panel,
                \\    .endPanelFn         = _tui_end_panel,
                \\    .beginWindowFn      = _tui_begin_window,
                \\    .endWindowFn        = _tui_end_window,
                \\    .selectableFn       = _tui_selectable,
                \\    .textColoredFn      = _tui_text_colored,
                \\    .beginTableFn       = _tui_begin_table,
                \\    .tableSetupColumnFn = _tui_table_setup_column,
                \\    .tableHeadersRowFn  = _tui_table_headers_row,
                \\    .tableNextRowFn     = _tui_table_next_row,
                \\    .tableNextColumnFn  = _tui_table_next_column,
                \\    .endTableFn         = _tui_end_table,
                \\    .beginChildFn       = _tui_begin_child,
                \\    .endChildFn         = _tui_end_child,
                \\    .treeNodeFn         = _tui_tree_node,
                \\    .treePopFn          = _tui_tree_pop,
                \\    .setColorFn         = _tui_set_color,
                \\    .setColorsDarkFn    = _tui_set_colors_dark,
                \\    .setStyleFloatFn    = _tui_set_style_float,
                \\    .setVec2Fn          = _tui_set_vec2,
                \\    .scaleAllSizesFn    = _tui_scale_all_sizes,
                \\    .getDpiFn           = _tui_get_dpi,
                \\    .ll_addLineFn         = _tui_ll_add_line,
                \\    .ll_addRectFn         = _tui_ll_add_rect,
                \\    .ll_addRectFilledFn   = _tui_ll_add_rect_filled,
                \\    .ll_addCircleFn       = _tui_ll_add_circle,
                \\    .ll_addCircleFilledFn = _tui_ll_add_circle_filled,
                \\    .ll_addTextFn         = _tui_ll_add_text,
                \\    .ll_getWindowPosFn    = _tui_ll_get_window_pos,
                \\    .ll_getWindowSizeFn   = _tui_ll_get_window_size,
                \\    .ll_getCursorPosFn    = _tui_ll_get_cursor_pos,
                \\    .ll_getMousePosFn     = _tui_ll_get_mouse_pos,
                \\    .ll_beginGroupFn      = _tui_ll_begin_group,
                \\    .ll_endGroupFn        = _tui_ll_end_group,
                \\    .beginHBoxFn   = _tui_begin_hbox,
                \\    .endHBoxFn     = _tui_end_hbox,
                \\    .beginVBoxFn   = _tui_begin_vbox,
                \\    .endVBoxFn     = _tui_end_vbox,
                \\    .progressBarFn = _tui_progressbar,
                \\    .comboboxFn    = _tui_combobox,
                \\    .spinboxFn     = _tui_spinbox,
                \\    .openFileFn    = _tui_open_file,
                \\    .saveFileFn    = _tui_save_file,
                \\    .openFolderFn  = _tui_open_folder,
                \\    .msgBoxFn      = _tui_msg_box,
                \\    .msgBoxErrorFn = _tui_msg_box_error,
                \\};
                \\const _gui_active_backend: _GuiBackend = _gui_tui_backend;
                \\
            ),
        // ── libui-ng native OS GUI backend ───────────────────────────────────────
        // Retained-mode adapter: immediate-mode Zebra API → libui-ng widget tree.
        // Frame 0 = creation pass (widgets are created + added to vbox).
        // Frames 1+ = event-driven: newFrameFn blocks on uiMainStep(.blocking),
        // callbacks write into _LuiMut, view() reads _LuiMut state.
        // Interactive widgets (button/checkbox/slider/entry/mle): label-keyed StringHashMap.
        // Display widgets (text/separator): frame-counter ArrayList.
        .libui_ng => try g.w.writeAll(
            \\// ─── CodeEditor widget — Scintilla via libui-scintilla ───────────────────────
            \\const sci = @import("sci");
            \\const _CodeEditor = struct {
            \\    scint: ?*sci.Scintilla = null,
            \\    read_only: bool = false,
            \\    text: []u8 = &.{},
            \\};
            \\fn _code_editor_new() *_CodeEditor {
            \\    const _ed = _allocator.create(_CodeEditor) catch unreachable;
            \\    _ed.* = .{};
            \\    return _ed;
            \\}
            \\fn _code_editor_set_text(_ed: *_CodeEditor, text: []const u8) void {
            \\    _allocator.free(_ed.text);
            \\    _ed.text = _allocator.dupe(u8, text) catch &.{};
            \\    if (_ed.scint) |_s| _s.setText(_ed.text);
            \\}
            \\fn _code_editor_get_text(_ed: *_CodeEditor) []const u8 {
            \\    if (_ed.scint) |_s| {
            \\        const _len = _s.getLength();
            \\        if (_len > _ed.text.len) {
            \\            _allocator.free(_ed.text);
            \\            _ed.text = _allocator.alloc(u8, _len + 1) catch return _ed.text;
            \\        }
            \\        if (_len > 0) _s.getRange(0, _len, _ed.text.ptr);
            \\        _ed.text = _ed.text[0.._len];
            \\    }
            \\    return _ed.text;
            \\}
            \\fn _code_editor_set_readonly(_ed: *_CodeEditor, v: bool) void {
            \\    _ed.read_only = v;
            \\    if (_ed.scint) |_s| _ = _s.sendMessage(2171, @intFromBool(v), 0);
            \\}
            \\fn _code_editor_render(_ed: *_CodeEditor, _g: GuiContext, id: []const u8, _w: f64, _h: f64) void {
            \\    _ = id; _ = _w; _ = _h; _ = _g;
            \\    if (_ed.scint == null) {
            \\        _ed.scint = sci.Scintilla.new() catch return;
            \\        if (_ed.text.len > 0) _ed.scint.?.setText(_ed.text);
            \\        if (_ed.read_only) _ = _ed.scint.?.sendMessage(2171, 1, 0);
            \\        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _ed.scint.?.as_control(), .stretch);
            \\    }
            \\}
            \\fn _code_editor_set_error_markers(_ed: *_CodeEditor, _m: anytype) void { _ = _ed; _ = _m; }
            \\fn _code_editor_get_cursor_line(_ed: *_CodeEditor) i64 {
            \\    const _s = _ed.scint orelse return 1;
            \\    const _pos = _s.sendMessage(2008, 0, 0);
            \\    return @intCast(_s.sendMessage(2166, _pos, 0) + 1);
            \\}
            \\fn _code_editor_get_cursor_col(_ed: *_CodeEditor) i64 {
            \\    const _s = _ed.scint orelse return 1;
            \\    const _pos = _s.sendMessage(2008, 0, 0);
            \\    return @intCast(_s.sendMessage(2129, _pos, 0) + 1);
            \\}
            \\fn _code_editor_set_cursor_position(_ed: *_CodeEditor, line: i64, col: i64) void {
            \\    _ = col;
            \\    const _s = _ed.scint orelse return;
            \\    _ = _s.sendMessage(2024, @intCast(@max(0, line - 1)), 0);
            \\}
            \\// ─── libui-ng retained-mode adapter ──────────────────────────────────────────
            \\const ui = @import("ui");
            \\const _LuiMut = struct {
            \\    ctrl: ?*ui.Control = null,
            \\    lbl: ?*ui.Label = null,
            \\    clicked: bool = false,
            \\    checked: bool = false,
            \\    text_buf: [1024]u8 = undefined,
            \\    text_len: usize = 0,
            \\    sval: c_int = 0,
            \\    smin: f64 = 0,
            \\    smax: f64 = 1,
            \\    pb: ?*ui.ProgressBar = null,
            \\};
            \\const _LuiPanel = struct { inner: *ui.Box };
            \\var _lui_icache: std.StringHashMap(*_LuiMut) = undefined;
            \\var _lui_dcache: std.ArrayList(*_LuiMut) = undefined;
            \\var _lui_didx: usize = 0;
            \\var _lui_frame: u32 = 0;
            \\var _lui_quit: bool = false;
            \\var _lui_win_w: i64 = 800;
            \\var _lui_win_h: i64 = 600;
            \\var _lui_window: ?*ui.Window = null;
            \\var _lui_root_box: ?*ui.Box = null;
            \\var _lui_box_stack: [32]?*ui.Box = [_]?*ui.Box{null} ** 32;
            \\var _lui_box_depth: usize = 0;
            \\var _lui_box_icache: std.StringHashMap(*ui.Box) = undefined;
            \\var _lui_grp_cache: std.StringHashMap(_LuiPanel) = undefined;
            \\fn _lui_cur_box() ?*ui.Box {
            \\    if (_lui_box_depth == 0) return null;
            \\    return _lui_box_stack[_lui_box_depth - 1];
            \\}
            \\fn _lui_push_box(_b: *ui.Box) void {
            \\    if (_lui_box_depth < 32) { _lui_box_stack[_lui_box_depth] = _b; _lui_box_depth += 1; }
            \\}
            \\fn _lui_pop_box() void { if (_lui_box_depth > 1) _lui_box_depth -= 1; }
            \\fn _lui_on_close(_w: *ui.Window, _q: ?*bool) anyerror!ui.Window.ClosingAction {
            \\    _ = _w;
            \\    if (_q) |p| p.* = true;
            \\    ui.Quit();
            \\    return .should_close;
            \\}
            \\fn _lui_btn_cb(_btn: *ui.Button, _m: ?*_LuiMut) anyerror!void {
            \\    _ = _btn;
            \\    if (_m) |p| p.clicked = true;
            \\}
            \\fn _lui_chk_cb(_chk: *ui.Checkbox, _m: ?*_LuiMut) void {
            \\    if (_m) |p| p.checked = _chk.Checked();
            \\}
            \\fn _lui_entry_cb(_ent: *ui.Entry, _m: ?*_LuiMut) anyerror!void {
            \\    if (_m) |p| {
            \\        const _s = std.mem.span(_ent.Text());
            \\        const _n = @min(_s.len, 1023);
            \\        @memcpy(p.text_buf[0.._n], _s[0.._n]);
            \\        p.text_len = _n;
            \\    }
            \\}
            \\fn _lui_mle_cb(_mle: *ui.MultilineEntry, _m: ?*_LuiMut) anyerror!void {
            \\    if (_m) |p| {
            \\        const _s = std.mem.span(_mle.Text());
            \\        const _n = @min(_s.len, 1023);
            \\        @memcpy(p.text_buf[0.._n], _s[0.._n]);
            \\        p.text_len = _n;
            \\    }
            \\}
            \\fn _lui_slider_cb(_sld: *ui.Slider, _m: ?*_LuiMut) anyerror!void {
            \\    if (_m) |p| p.sval = _sld.Value();
            \\}
            \\fn _lui_cmb_cb(_c: *ui.Combobox, _m: ?*_LuiMut) anyerror!void {
            \\    if (_m) |p| p.sval = _c.Selected();
            \\}
            \\fn _lui_spn_cb(_s: *ui.Spinbox, _m: ?*_LuiMut) anyerror!void {
            \\    if (_m) |p| p.sval = _s.Value();
            \\}
            \\fn _lui_init(_title: []const u8, _width: i64, _height: i64) anyerror!void {
            \\    _lui_win_w = _width; _lui_win_h = _height;
            \\    var _d = ui.InitData{ .options = .{ .Size = @sizeOf(ui.InitOptions) } };
            \\    try ui.Init(&_d);
            \\    _lui_icache = std.StringHashMap(*_LuiMut).init(_allocator);
            \\    _lui_dcache = .empty;
            \\    _lui_box_icache = std.StringHashMap(*ui.Box).init(_allocator);
            \\    _lui_grp_cache = std.StringHashMap(_LuiPanel).init(_allocator);
            \\    _lui_box_depth = 0;
            \\    var _tbuf: [256]u8 = undefined;
            \\    const _tz: [:0]u8 = try std.fmt.bufPrintZ(&_tbuf, "{s}", .{_title});
            \\    _lui_window = try ui.Window.New(_tz, @intCast(_width), @intCast(_height), .hide_menubar);
            \\    ui.Window.OnClosing(_lui_window.?, bool, anyerror, _lui_on_close, &_lui_quit);
            \\    _lui_root_box = try ui.Box.New(.Vertical);
            \\    _lui_root_box.?.SetPadded(true);
            \\    _lui_push_box(_lui_root_box.?);
            \\    ui.Timer(anyopaque, anyerror, 100, _lui_poll_tick, null);
            \\    _lui_frame = 0; _lui_quit = false;
            \\}
            \\fn _lui_poll_tick(_: ?*anyopaque) anyerror!ui.TimerAction { return .rearm; }
            \\fn _lui_deinit() void {
            \\    _lui_icache.deinit();
            \\    _lui_dcache.deinit(_allocator);
            \\    _lui_box_icache.deinit();
            \\    _lui_grp_cache.deinit();
            \\    ui.Uninit();
            \\}
            \\fn _lui_newframe() bool {
            \\    _lui_didx = 0;
            \\    if (_lui_frame == 0) return true;
            \\    if (_lui_quit) return false;
            \\    return ui.MainStep(.blocking) == .running and !_lui_quit;
            \\}
            \\fn _lui_endframe() void {
            \\    _lui_box_depth = 1; // reset to root box only
            \\    if (_lui_frame == 0) {
            \\        _lui_frame = 1;
            \\        if (_lui_window) |_w| {
            \\            if (_lui_root_box) |_vb| _w.SetChild(_vb.as_control());
            \\            _w.SetMargined(true);
            \\            _w.as_control().Show();
            \\        }
            \\    }
            \\}
            \\const _LuiIR = struct { m: *_LuiMut, fresh: bool };
            \\fn _lui_iget(_label: []const u8) _LuiIR {
            \\    if (_lui_icache.get(_label)) |_m| return .{ .m = _m, .fresh = false };
            \\    const _m = _allocator.create(_LuiMut) catch unreachable;
            \\    _m.* = .{};
            \\    _lui_icache.put(_label, _m) catch unreachable;
            \\    return .{ .m = _m, .fresh = true };
            \\}
            \\fn _lui_dget() _LuiIR {
            \\    if (_lui_didx < _lui_dcache.items.len) {
            \\        const _m = _lui_dcache.items[_lui_didx];
            \\        _lui_didx += 1;
            \\        return .{ .m = _m, .fresh = false };
            \\    }
            \\    const _m = _allocator.create(_LuiMut) catch unreachable;
            \\    _m.* = .{};
            \\    _lui_dcache.append(_allocator, _m) catch unreachable;
            \\    _lui_didx += 1;
            \\    return .{ .m = _m, .fresh = true };
            \\}
            \\fn _lui_text(_s: []const u8) void {
            \\    const _r = _lui_dget();
            \\    const _n = @min(_s.len, 510);
            \\    var _tb: [512]u8 = undefined;
            \\    @memcpy(_tb[0.._n], _s[0.._n]);
            \\    _tb[_n] = 0;
            \\    const _tz: [:0]u8 = _tb[0.._n :0];
            \\    if (_r.fresh) {
            \\        const _lbl = ui.Label.New(_tz) catch return;
            \\        _r.m.lbl = _lbl;
            \\        _r.m.ctrl = _lbl.as_control();
            \\        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _lbl.as_control(), .dont_stretch);
            \\    } else {
            \\        if (_r.m.lbl) |_lb| _lb.SetText(_tz);
            \\    }
            \\}
            \\fn _lui_sep() void {
            \\    const _r = _lui_dget();
            \\    if (_r.fresh) {
            \\        const _sep = ui.Separator.New(.Horizontal) catch return;
            \\        _r.m.ctrl = _sep.as_control();
            \\        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _sep.as_control(), .dont_stretch);
            \\    }
            \\}
            \\fn _lui_noop_void() void {}
            \\fn _lui_noop_bool(_l: []const u8) bool { _ = _l; return true; }
            \\fn _lui_selectable(_l: []const u8) bool { _ = _l; return false; }
            \\fn _lui_text_colored(_rv: f32, _gv: f32, _bv: f32, _av: f32, _s: []const u8) void {
            \\    _ = _rv; _ = _gv; _ = _bv; _ = _av; _lui_text(_s);
            \\}
            \\fn _lui_begin_table(_id: []const u8, _cols: i64) bool { _ = _id; _ = _cols; return true; }
            \\fn _lui_table_setup_col(_l: []const u8) void { _ = _l; }
            \\fn _lui_table_next_col() bool { return true; }
            \\fn _lui_begin_child(_id: []const u8, _cw: f64, _ch: f64) bool {
            \\    _ = _id; _ = _cw; _ = _ch; return true;
            \\}
            \\fn _lui_set_color(_role: []const u8, _rv: f32, _gv: f32, _bv: f32, _av: f32) void {
            \\    _ = _role; _ = _rv; _ = _gv; _ = _bv; _ = _av;
            \\}
            \\fn _lui_set_style_float(_name: []const u8, _v: f32) void { _ = _name; _ = _v; }
            \\fn _lui_set_vec2(_name: []const u8, _xv: f32, _yv: f32) void { _ = _name; _ = _xv; _ = _yv; }
            \\fn _lui_scale_all(_sc: f32) void { _ = _sc; }
            \\fn _lui_get_dpi() f32 { return 1.0; }
            \\fn _lui_ll_noop_line(_x1: f64, _y1: f64, _x2: f64, _y2: f64, _c: i64, _t: f64) void {
            \\    _ = _x1; _ = _y1; _ = _x2; _ = _y2; _ = _c; _ = _t;
            \\}
            \\fn _lui_ll_noop_rect(_x1: f64, _y1: f64, _x2: f64, _y2: f64, _c: i64, _t: f64) void {
            \\    _ = _x1; _ = _y1; _ = _x2; _ = _y2; _ = _c; _ = _t;
            \\}
            \\fn _lui_ll_noop_rectfill(_x1: f64, _y1: f64, _x2: f64, _y2: f64, _c: i64) void {
            \\    _ = _x1; _ = _y1; _ = _x2; _ = _y2; _ = _c;
            \\}
            \\fn _lui_ll_noop_circle(_cx: f64, _cy: f64, _r: f64, _c: i64, _t: f64) void {
            \\    _ = _cx; _ = _cy; _ = _r; _ = _c; _ = _t;
            \\}
            \\fn _lui_ll_noop_circlefill(_cx: f64, _cy: f64, _r: f64, _c: i64) void {
            \\    _ = _cx; _ = _cy; _ = _r; _ = _c;
            \\}
            \\fn _lui_ll_noop_text(_x: f64, _y: f64, _c: i64, _s: []const u8) void {
            \\    _ = _x; _ = _y; _ = _c; _ = _s;
            \\}
            \\fn _lui_ll_get_win_pos() _GuiVec2 { return .{ 0, 0 }; }
            \\fn _lui_ll_get_win_size() _GuiVec2 {
            \\    return .{ @floatFromInt(_lui_win_w), @floatFromInt(_lui_win_h) };
            \\}
            \\fn _lui_ll_get_cursor_pos() _GuiVec2 { return .{ 0, 0 }; }
            \\fn _lui_ll_get_mouse_pos() _GuiVec2 { return .{ -1, -1 }; }
            \\fn _lui_button(_label: []const u8) bool {
            \\    const _r = _lui_iget(_label);
            \\    if (_r.fresh) {
            \\        const _n = @min(_label.len, 255);
            \\        var _lb: [256]u8 = undefined;
            \\        @memcpy(_lb[0.._n], _label[0.._n]);
            \\        _lb[_n] = 0;
            \\        const _lz: [:0]u8 = _lb[0.._n :0];
            \\        const _btn = ui.Button.New(_lz) catch return false;
            \\        ui.Button.OnClicked(_btn, _LuiMut, anyerror, _lui_btn_cb, _r.m);
            \\        _r.m.ctrl = _btn.as_control();
            \\        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _btn.as_control(), .dont_stretch);
            \\    }
            \\    const _clicked = _r.m.clicked;
            \\    _r.m.clicked = false;
            \\    return _clicked;
            \\}
            \\fn _lui_checkbox(_label: []const u8, _value: bool) bool {
            \\    const _r = _lui_iget(_label);
            \\    if (_r.fresh) {
            \\        const _n = @min(_label.len, 255);
            \\        var _lb: [256]u8 = undefined;
            \\        @memcpy(_lb[0.._n], _label[0.._n]);
            \\        _lb[_n] = 0;
            \\        const _lz: [:0]u8 = _lb[0.._n :0];
            \\        const _chk = ui.Checkbox.New(_lz) catch return _value;
            \\        _chk.SetChecked(_value);
            \\        _r.m.checked = _value;
            \\        ui.Checkbox.OnToggled(_chk, _LuiMut, _lui_chk_cb, _r.m);
            \\        _r.m.ctrl = _chk.as_control();
            \\        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _chk.as_control(), .dont_stretch);
            \\    }
            \\    return _r.m.checked;
            \\}
            \\fn _lui_slider(_label: []const u8, _value: f64, _min: f64, _max: f64) f64 {
            \\    const _r = _lui_iget(_label);
            \\    if (_r.fresh) {
            \\        const _n = @min(_label.len, 255);
            \\        var _lb: [256]u8 = undefined;
            \\        @memcpy(_lb[0.._n], _label[0.._n]);
            \\        _lb[_n] = 0;
            \\        const _lz: [:0]u8 = _lb[0.._n :0];
            \\        const _sllbl = ui.Label.New(_lz) catch return _value;
            \\        const _sld = ui.Slider.New(0, 1000) catch return _value;
            \\        const _raw: c_int = @intFromFloat((_value - _min) / (_max - _min) * 1000.0);
            \\        const _init: c_int = if (_raw < 0) 0 else if (_raw > 1000) 1000 else _raw;
            \\        _sld.SetValue(_init);
            \\        _r.m.sval = _init; _r.m.smin = _min; _r.m.smax = _max;
            \\        ui.Slider.OnChanged(_sld, _LuiMut, anyerror, _lui_slider_cb, _r.m);
            \\        _r.m.ctrl = _sld.as_control();
            \\        _r.m.lbl = _sllbl;
            \\        if (_lui_cur_box()) |_vb| {
            \\            ui.Box.Append(_vb, _sllbl.as_control(), .dont_stretch);
            \\            ui.Box.Append(_vb, _sld.as_control(), .dont_stretch);
            \\        }
            \\    }
            \\    const _t = @as(f64, @floatFromInt(_r.m.sval)) / 1000.0;
            \\    return _r.m.smin + _t * (_r.m.smax - _r.m.smin);
            \\}
            \\fn _lui_input(_label: []const u8, _value: []const u8) []const u8 {
            \\    const _r = _lui_iget(_label);
            \\    if (_r.fresh) {
            \\        const _n = @min(_label.len, 255);
            \\        var _lb: [256]u8 = undefined;
            \\        @memcpy(_lb[0.._n], _label[0.._n]);
            \\        _lb[_n] = 0;
            \\        const _lz: [:0]u8 = _lb[0.._n :0];
            \\        const _enlbl = ui.Label.New(_lz) catch return _value;
            \\        const _ent = ui.Entry.New(.Entry) catch return _value;
            \\        const _vn = @min(_value.len, 1022);
            \\        var _vtb: [1024]u8 = undefined;
            \\        @memcpy(_vtb[0.._vn], _value[0.._vn]);
            \\        _vtb[_vn] = 0;
            \\        _ent.SetText(_vtb[0.._vn :0]);
            \\        @memcpy(_r.m.text_buf[0.._vn], _value[0.._vn]);
            \\        _r.m.text_len = _vn;
            \\        ui.Entry.OnChanged(_ent, _LuiMut, anyerror, _lui_entry_cb, _r.m);
            \\        _r.m.ctrl = _ent.as_control();
            \\        _r.m.lbl = _enlbl;
            \\        if (_lui_cur_box()) |_vb| {
            \\            ui.Box.Append(_vb, _enlbl.as_control(), .dont_stretch);
            \\            ui.Box.Append(_vb, _ent.as_control(), .dont_stretch);
            \\        }
            \\    }
            \\    return _r.m.text_buf[0.._r.m.text_len];
            \\}
            \\fn _lui_input_ml(_label: []const u8, _value: []const u8, _mw: f64, _mh: f64) []const u8 {
            \\    _ = _mw; _ = _mh;
            \\    const _r = _lui_iget(_label);
            \\    if (_r.fresh) {
            \\        const _n = @min(_label.len, 255);
            \\        var _lb: [256]u8 = undefined;
            \\        @memcpy(_lb[0.._n], _label[0.._n]);
            \\        _lb[_n] = 0;
            \\        const _lz: [:0]u8 = _lb[0.._n :0];
            \\        const _mllbl = ui.Label.New(_lz) catch return _value;
            \\        const _mle = ui.MultilineEntry.New(.Wrapping) catch return _value;
            \\        const _vn = @min(_value.len, 1022);
            \\        var _vtb: [1024]u8 = undefined;
            \\        @memcpy(_vtb[0.._vn], _value[0.._vn]);
            \\        _vtb[_vn] = 0;
            \\        _mle.SetText(_vtb[0.._vn :0]);
            \\        @memcpy(_r.m.text_buf[0.._vn], _value[0.._vn]);
            \\        _r.m.text_len = _vn;
            \\        ui.MultilineEntry.OnChanged(_mle, _LuiMut, anyerror, _lui_mle_cb, _r.m);
            \\        _r.m.ctrl = _mle.as_control();
            \\        _r.m.lbl = _mllbl;
            \\        if (_lui_cur_box()) |_vb| {
            \\            ui.Box.Append(_vb, _mllbl.as_control(), .dont_stretch);
            \\            ui.Box.Append(_vb, _mle.as_control(), .stretch);
            \\        }
            \\    }
            \\    return _r.m.text_buf[0.._r.m.text_len];
            \\}
            \\fn _lui_begin_hbox(_id: []const u8, _stretch: bool) void {
            \\    const _e = _lui_box_icache.getOrPut(_id) catch return;
            \\    if (!_e.found_existing) {
            \\        const _hb = ui.Box.New(.Horizontal) catch return;
            \\        _hb.SetPadded(true);
            \\        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _hb.as_control(), if (_stretch) ui.Stretchy.stretch else ui.Stretchy.dont_stretch);
            \\        _e.value_ptr.* = _hb;
            \\    }
            \\    _lui_push_box(_e.value_ptr.*);
            \\}
            \\fn _lui_end_hbox() void { if (_lui_box_depth > 1) _lui_box_depth -= 1; }
            \\fn _lui_begin_vbox(_id: []const u8, _stretch: bool) void {
            \\    const _e = _lui_box_icache.getOrPut(_id) catch return;
            \\    if (!_e.found_existing) {
            \\        const _vb2 = ui.Box.New(.Vertical) catch return;
            \\        _vb2.SetPadded(false);
            \\        if (_lui_cur_box()) |_pvb| ui.Box.Append(_pvb, _vb2.as_control(), if (_stretch) ui.Stretchy.stretch else ui.Stretchy.dont_stretch);
            \\        _e.value_ptr.* = _vb2;
            \\    }
            \\    _lui_push_box(_e.value_ptr.*);
            \\}
            \\fn _lui_end_vbox() void { if (_lui_box_depth > 1) _lui_box_depth -= 1; }
            \\fn _lui_begin_panel(_label: []const u8) bool {
            \\    if (_lui_grp_cache.get(_label)) |_p| {
            \\        _lui_push_box(_p.inner);
            \\        return true;
            \\    }
            \\    const _n = @min(_label.len, 255);
            \\    var _lb: [256]u8 = undefined;
            \\    @memcpy(_lb[0.._n], _label[0.._n]);
            \\    _lb[_n] = 0;
            \\    const _lz: [:0]u8 = _lb[0.._n :0];
            \\    const _grp = ui.Group.New(_lz) catch return true;
            \\    const _inner = ui.Box.New(.Vertical) catch return true;
            \\    _inner.SetPadded(true);
            \\    _grp.SetChild(_inner.as_control());
            \\    _grp.SetMargined(true);
            \\    if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _grp.as_control(), .dont_stretch);
            \\    _lui_grp_cache.put(_label, .{ .inner = _inner }) catch {};
            \\    _lui_push_box(_inner);
            \\    return true;
            \\}
            \\fn _lui_end_panel() void { if (_lui_box_depth > 1) _lui_box_depth -= 1; }
            \\fn _lui_progressbar(_label: []const u8, _value: f64) void {
            \\    _ = _label;
            \\    const _r = _lui_dget();
            \\    const _pct: c_int = @intFromFloat(_value * 100.0);
            \\    const _clamped: c_int = if (_pct < 0) 0 else if (_pct > 100) 100 else _pct;
            \\    if (_r.fresh) {
            \\        const _pb = ui.ProgressBar.New() catch return;
            \\        _pb.SetValue(_clamped);
            \\        _r.m.pb = _pb;
            \\        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _pb.as_control(), .dont_stretch);
            \\    } else {
            \\        if (_r.m.pb) |_pb| _pb.SetValue(_clamped);
            \\    }
            \\}
            \\fn _lui_combobox(_label: []const u8, _items: []const []const u8, _sel: i64) i64 {
            \\    const _r = _lui_iget(_label);
            \\    if (_r.fresh) {
            \\        const _cmb = ui.Combobox.New() catch return _sel;
            \\        for (_items) |_it| {
            \\            const _n = @min(_it.len, 255);
            \\            var _lb: [256]u8 = undefined;
            \\            @memcpy(_lb[0.._n], _it[0.._n]);
            \\            _lb[_n] = 0;
            \\            const _lz: [:0]u8 = _lb[0.._n :0];
            \\            ui.Combobox.Append(_cmb, _lz);
            \\        }
            \\        const _init: c_int = @intCast(_sel);
            \\        _cmb.SetSelected(_init);
            \\        _r.m.sval = _init;
            \\        ui.Combobox.OnSelected(_cmb, _LuiMut, anyerror, _lui_cmb_cb, _r.m);
            \\        _r.m.ctrl = _cmb.as_control();
            \\        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _cmb.as_control(), .dont_stretch);
            \\    }
            \\    return @as(i64, @intCast(_r.m.sval));
            \\}
            \\fn _lui_spinbox(_label: []const u8, _value: i64, _min: i64, _max: i64) i64 {
            \\    const _r = _lui_iget(_label);
            \\    if (_r.fresh) {
            \\        const _spn = ui.Spinbox.New(.{ .Integer = .{ .min = @intCast(_min), .max = @intCast(_max) } }) catch return _value;
            \\        _spn.SetValue(@intCast(_value));
            \\        _r.m.sval = @intCast(_value);
            \\        ui.Spinbox.OnChanged(_spn, _LuiMut, anyerror, _lui_spn_cb, _r.m);
            \\        _r.m.ctrl = _spn.as_control();
            \\        if (_lui_cur_box()) |_vb| ui.Box.Append(_vb, _spn.as_control(), .dont_stretch);
            \\    }
            \\    return @as(i64, @intCast(_r.m.sval));
            \\}
            \\fn _lui_open_file() ?[]const u8 {
            \\    const _cpath = ui.Window.OpenFile(_lui_window.?) orelse return null;
            \\    defer ui.FreeText(_cpath);
            \\    const _s = std.mem.span(_cpath);
            \\    return _allocator.dupe(u8, _s) catch null;
            \\}
            \\fn _lui_save_file() ?[]const u8 {
            \\    const _cpath = ui.Window.SaveFile(_lui_window.?) orelse return null;
            \\    defer ui.FreeText(_cpath);
            \\    const _s = std.mem.span(_cpath);
            \\    return _allocator.dupe(u8, _s) catch null;
            \\}
            \\fn _lui_open_folder() ?[]const u8 {
            \\    const _cpath = ui.Window.OpenFolder(_lui_window.?) orelse return null;
            \\    defer ui.FreeText(_cpath);
            \\    const _s = std.mem.span(_cpath);
            \\    return _allocator.dupe(u8, _s) catch null;
            \\}
            \\fn _lui_msg_box(_title: []const u8, _desc: []const u8) void {
            \\    const _tz = _allocator.dupeZ(u8, _title) catch return;
            \\    const _mz = _allocator.dupeZ(u8, _desc) catch return;
            \\    ui.Window.MsgBox(_lui_window.?, _tz, _mz);
            \\}
            \\fn _lui_msg_box_error(_title: []const u8, _desc: []const u8) void {
            \\    const _tz = _allocator.dupeZ(u8, _title) catch return;
            \\    const _mz = _allocator.dupeZ(u8, _desc) catch return;
            \\    ui.Window.MsgBoxError(_lui_window.?, _tz, _mz);
            \\}
            \\const _gui_lui_backend = _GuiBackend{
            \\    .initFn             = _lui_init,
            \\    .deinitFn           = _lui_deinit,
            \\    .newFrameFn         = _lui_newframe,
            \\    .endFrameFn         = _lui_endframe,
            \\    .textFn             = _lui_text,
            \\    .separatorFn        = _lui_sep,
            \\    .sameLineFn         = _lui_noop_void,
            \\    .spacingFn          = _lui_noop_void,
            \\    .indentFn           = _lui_noop_void,
            \\    .unindentFn         = _lui_noop_void,
            \\    .buttonFn           = _lui_button,
            \\    .checkboxFn         = _lui_checkbox,
            \\    .sliderFn           = _lui_slider,
            \\    .inputFn            = _lui_input,
            \\    .inputMultilineFn   = _lui_input_ml,
            \\    .beginPanelFn       = _lui_begin_panel,
            \\    .endPanelFn         = _lui_end_panel,
            \\    .beginWindowFn      = _lui_noop_bool,
            \\    .endWindowFn        = _lui_noop_void,
            \\    .selectableFn       = _lui_selectable,
            \\    .textColoredFn      = _lui_text_colored,
            \\    .beginTableFn       = _lui_begin_table,
            \\    .tableSetupColumnFn = _lui_table_setup_col,
            \\    .tableHeadersRowFn  = _lui_noop_void,
            \\    .tableNextRowFn     = _lui_noop_void,
            \\    .tableNextColumnFn  = _lui_table_next_col,
            \\    .endTableFn         = _lui_noop_void,
            \\    .beginChildFn       = _lui_begin_child,
            \\    .endChildFn         = _lui_noop_void,
            \\    .treeNodeFn         = _lui_noop_bool,
            \\    .treePopFn          = _lui_noop_void,
            \\    .setColorFn         = _lui_set_color,
            \\    .setColorsDarkFn    = _lui_noop_void,
            \\    .setStyleFloatFn    = _lui_set_style_float,
            \\    .setVec2Fn          = _lui_set_vec2,
            \\    .scaleAllSizesFn    = _lui_scale_all,
            \\    .getDpiFn           = _lui_get_dpi,
            \\    .ll_addLineFn         = _lui_ll_noop_line,
            \\    .ll_addRectFn         = _lui_ll_noop_rect,
            \\    .ll_addRectFilledFn   = _lui_ll_noop_rectfill,
            \\    .ll_addCircleFn       = _lui_ll_noop_circle,
            \\    .ll_addCircleFilledFn = _lui_ll_noop_circlefill,
            \\    .ll_addTextFn         = _lui_ll_noop_text,
            \\    .ll_getWindowPosFn    = _lui_ll_get_win_pos,
            \\    .ll_getWindowSizeFn   = _lui_ll_get_win_size,
            \\    .ll_getCursorPosFn    = _lui_ll_get_cursor_pos,
            \\    .ll_getMousePosFn     = _lui_ll_get_mouse_pos,
            \\    .ll_beginGroupFn      = _lui_noop_void,
            \\    .ll_endGroupFn        = _lui_noop_void,
            \\    .beginHBoxFn = _lui_begin_hbox,
            \\    .endHBoxFn   = _lui_end_hbox,
            \\    .beginVBoxFn   = _lui_begin_vbox,
            \\    .endVBoxFn     = _lui_end_vbox,
            \\    .progressBarFn = _lui_progressbar,
            \\    .comboboxFn    = _lui_combobox,
            \\    .spinboxFn     = _lui_spinbox,
            \\    .openFileFn    = _lui_open_file,
            \\    .saveFileFn    = _lui_save_file,
            \\    .openFolderFn  = _lui_open_folder,
            \\    .msgBoxFn      = _lui_msg_box,
            \\    .msgBoxErrorFn = _lui_msg_box_error,
            \\};
            \\const _gui_active_backend: _GuiBackend = _gui_lui_backend;
            \\
        ),
        }

        try g.w.writeAll(build_options.stdlib_preamble_post_gui);
        for (module.decls) |decl| try g.genTopDecl(decl);

        // ── Gap 1: emit module-level thunk infrastructure for any closure
        // arguments collected during genCall (see emitCallWithClosureThunks).
        try g.flushPendingThunks();

        // Test runner: discover all top-level `def test_*()` and emit a main that
        // calls each, catches failures, and prints a summary.
        if (g.test_mode) {
            try g.genTestMain(module);
            return;
        }

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
            // Build allocator-init and io-init calls for all Zebra-dep `use` modules
            // so that library code shares the root arena allocator and _io handle.
            var alloc_init_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer alloc_init_buf.deinit(g.alloc);
            for (module.decls) |decl| {
                const u = switch (decl) { .use => |u| u, else => continue };
                // Skip native (Zig/C) imports — they don't have `_initAllocator`/`_initIo`.
                if (g.native_uses) |nu| if (nu.get(u.path) != null) continue;
                // Compute import path (dots → slashes).
                const imp_path = try std.mem.replaceOwned(u8, g.alloc, u.path, ".", "/");
                defer g.alloc.free(imp_path);
                const alloc_init_line = try std.fmt.allocPrint(g.alloc,
                    "    @import(\"{s}.zig\")._initAllocator(_allocator);\n    @import(\"{s}.zig\")._initIo(_io);\n", .{imp_path, imp_path});
                defer g.alloc.free(alloc_init_line);
                try alloc_init_buf.appendSlice(g.alloc, alloc_init_line);
            }
            const alloc_init = alloc_init_buf.items;

            const auto_run_line       = if (g.build_mode) "    _build_auto_run();\n" else "";
            const list_targets_prefix = if (g.list_targets_mode) "    _list_targets_mode = true;\n" else "";
            // library_mode skips `defer _arena.deinit()` so the arena outlives
            // main() — useful when the emitted .zig is linked into a host
            // program (script-binding layer).  See GameEngine docs/CONCERNS.md #1.
            const arena_deinit_line = if (g.library_mode) "" else "    defer _arena.deinit();\n";
            if (main_throws) {
                try g.w.print(
                    "pub fn main(_zinit: std.process.Init) void {{\n" ++
                    "    _io = _zinit.io;\n" ++
                    "    _args = _zinit.minimal.args;\n" ++
                    "    _allocator = _arena.allocator();\n" ++
                    "{s}" ++
                    "{s}" ++
                    "{s}" ++
                    "    {s}.main() catch |_err| {{\n" ++
                    "        if (_err == error.ZebraError) {{\n" ++
                    "            std.debug.print(\"Error: {{s}}\\n\", .{{_zbr_error_msg()}});\n" ++
                    "        }} else {{\n" ++
                    "            std.debug.print(\"Error: {{}}\\n\", .{{_err}});\n" ++
                    "        }}\n" ++
                    "        std.process.exit(1);\n" ++
                    "    }};\n" ++
                    "{s}" ++
                    "}}\n",
                    .{ arena_deinit_line, alloc_init, list_targets_prefix, class_name, auto_run_line },
                );
            } else {
                try g.w.print(
                    "pub fn main(_zinit: std.process.Init) void {{\n" ++
                    "    _io = _zinit.io;\n" ++
                    "    _args = _zinit.minimal.args;\n" ++
                    "    _allocator = _arena.allocator();\n" ++
                    "{s}" ++
                    "{s}" ++
                    "{s}" ++
                    "    {s}.main();\n" ++
                    "{s}" ++
                    "}}\n",
                    .{ arena_deinit_line, alloc_init, list_targets_prefix, class_name, auto_run_line },
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
            .method    => |n| {
                // In test mode, skip top-level `def main()` — the test runner
                // provides its own `pub fn main()`.
                if (g.test_mode and !n.mods.static_ and std.mem.eql(u8, n.name, "main")) return;
                try g.genMethod(n);
            },
            .var_      => |n| try g.genTopVar(n),
            .init      => {},   // top-level constructor makes no sense
            .union_      => |n| try g.genUnion(n),
            .sig_        => |n| try g.genSig(n),
            .type_alias  => {},  // transparent alias — base type emitted inline at use sites
        }
    }

    // ── sig ───────────────────────────────────────────────────────────────────

    fn genSig(g: Generator, n: *Ast.DeclSig) anyerror!void {
        // Emit: `pub const Name = *const fn(T1, T2) R;`
        // pub is required so cross-module `use mod exposing SigType` can resolve the type.
        try g.writeIndent();
        try g.w.print("pub const {s} = *const fn(", .{n.name});
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
        // Split dotted names ("Outer.Inner") into nested struct layers.
        var parts_buf: [16][]const u8 = undefined;
        var n_parts: usize = 0;
        var it = std.mem.splitScalar(u8, n.name, '.');
        while (it.next()) |p| { if (n_parts < parts_buf.len) { parts_buf[n_parts] = p; n_parts += 1; } }
        const parts = parts_buf[0..n_parts];

        // Open one struct layer per path component.
        var depth: u32 = 0;
        for (parts) |part| {
            var og = g; og.indent += depth;
            try og.writeIndent();
            try og.w.print("pub const {s} = struct {{\n", .{part});
            depth += 1;
        }
        // Emit body at the innermost indent level.
        var ig = g; ig.indent += depth;
        for (n.decls) |decl| try ig.genTopDecl(decl);
        // Close in reverse order (innermost first).
        while (depth > 0) {
            depth -= 1;
            var cg = g; cg.indent += depth;
            try cg.writeIndent();
            try cg.w.writeAll("};\n");
        }
        try g.w.writeAll("\n");
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

        // ⑥ Per-instantiation interface vtables (inside the struct, referencing
        //    @This()), plus the transitive super-interface closure — so a generic
        //    instance can be coerced to an interface: `var b: I = Box(i64)(...)`.
        {
            var emitted: [32]*const Ast.DeclInterface = undefined;
            var emitted_n: usize = 0;
            for (n.implements) |tr| {
                const iname = typeRefSimpleName(tr) orelse continue;
                const iface = findInterfaceDecl(g.module, iname) orelse continue;
                var to_emit: [17]*const Ast.DeclInterface = undefined;
                to_emit[0] = iface;
                var sb: [16]*const Ast.DeclInterface = undefined;
                const supers = collectSuperIfaces(g.module, iface, &sb);
                for (supers, 0..) |s, i| to_emit[i + 1] = s;
                for (to_emit[0 .. supers.len + 1]) |ifc| {
                    var dup = false;
                    for (emitted[0..emitted_n]) |e| if (e == ifc) { dup = true; break; };
                    if (dup) continue;
                    if (emitted_n < emitted.len) { emitted[emitted_n] = ifc; emitted_n += 1; }
                    try genIfaceVtableInStruct(ig, ifc);
                }
            }
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
            var field_names = std.ArrayListUnmanaged([]const u8).empty;
            defer field_names.deinit(g.alloc);
            var field_types = std.ArrayListUnmanaged([]const u8).empty;

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

        // Emit shim + vtable const for each implemented interface, plus the
        // transitive super-interfaces it inherits. The supers are required so the
        // `__as_<Super>` pointers wired into the sub-interface vtable resolve, and
        // so the class is directly usable as any super-interface.
        var emitted_ifaces: [32]*const Ast.DeclInterface = undefined;
        var emitted_n: usize = 0;
        for (n.implements) |tr| {
            const iname = typeRefSimpleName(tr) orelse continue;
            const iface = findInterfaceDecl(g.module, iname) orelse continue;
            var to_emit_buf: [17]*const Ast.DeclInterface = undefined;
            to_emit_buf[0] = iface;
            var sb: [16]*const Ast.DeclInterface = undefined;
            const supers = collectSuperIfaces(g.module, iface, &sb);
            for (supers, 0..) |s, i| to_emit_buf[i + 1] = s;
            for (to_emit_buf[0 .. supers.len + 1]) |ifc| {
                var dup = false;
                for (emitted_ifaces[0..emitted_n]) |e| if (e == ifc) { dup = true; break; };
                if (dup) continue;
                if (emitted_n < emitted_ifaces.len) { emitted_ifaces[emitted_n] = ifc; emitted_n += 1; }
                try genIfaceVtable(g, n.name, ifc);
            }
        }

        try g.genExportWrappers(n.name, n.members);

        // @export("sym") class Foo is IFoo → emit module-static singleton factory.
        if (n.export_sym) |sym| {
            if (n.implements.len > 0) {
                if (typeRefSimpleName(n.implements[0])) |iname| {
                    try g.genExportFactory(n.name, sym, iname);
                }
            }
        }
    }

    fn genExportFactory(g: Generator, class_name: []const u8, sym: []const u8, iface_name: []const u8) anyerror!void {
        try g.w.print("var _zbr_export_{s}_iface: ?{s} = null;\n", .{ sym, iface_name });
        try g.w.print("pub export fn {s}() *{s} {{\n", .{ sym, iface_name });
        try g.w.print("    if (_zbr_export_{s}_iface == null) {{\n", .{sym});
        try g.w.print("        _zbr_export_{s}_iface = .{{ .ptr = {s}.init(), .vtable = &_vtable_{s}_{s} }};\n", .{ sym, class_name, class_name, iface_name });
        try g.w.print("    }}\n", .{});
        try g.w.print("    return &_zbr_export_{s}_iface.?;\n", .{sym});
        try g.w.writeAll("}\n\n");
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
            // Must emit `std.ArrayList(T).empty` / `std.StringHashMap(T).init(_allocator)`, not `List()`.
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
            if (n.type_) |tr| {
                try g.w.writeAll(": ");
                try g.genType(tr);
            } else if (std.mem.eql(u8, kw, "var")) {
                // Untyped static `var`: emit the TC-inferred type so Zig doesn't
                // reject `pub var x = 10` ("comptime_int must be const or
                // comptime"). Same machinery as genLocalVar. (`const` statics
                // stay untyped — Zig keeps them comptime.)
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
            if (n.init) |e| { try g.w.writeAll(" = "); try g.genExpr(e); }
            else try g.w.writeAll(" = undefined");
            try g.w.writeAll(";\n");
        } else {
            try g.w.writeAll(n.name);
            try g.w.writeAll(": ");
            // StringBuilder as struct field: emit the concrete type and default to empty.
            if (n.type_) |tr| {
                if (tr == .named and std.mem.eql(u8, tr.named.name, "StringBuilder")) {
                    try g.w.writeAll("std.ArrayList(u8) = .empty");
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
        // Super-interface re-projection pointers: one `__as_<Super>` per (transitive)
        // implemented interface, enabling O(1) interface→interface upcasts.
        var super_buf: [16]*const Ast.DeclInterface = undefined;
        const supers = collectSuperIfaces(g.module, n, &super_buf);
        for (supers) |s| {
            try vtig.writeIndent();
            try vtig.w.print("__as_{s}: *const {s}.VTable,\n", .{ s.name, s.name });
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

        // ── inherited forwarding methods (super-interface members) ─────────
        // A sub-interface IS-A super-interface, so its methods are callable
        // directly; they dispatch through the `__as_<Super>` vtable pointer.
        for (supers) |s| {
            for (s.members) |m| {
                const meth = switch (m) { .method => |x| x, else => continue };
                // Skip if this interface (or a nearer super) already declares the name.
                var shadowed = false;
                for (n.members) |om| {
                    const oname: []const u8 = switch (om) { .method => |x| x.name, else => continue };
                    if (std.mem.eql(u8, oname, meth.name)) { shadowed = true; break; }
                }
                if (shadowed) continue;
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
                if (meth.throws) try mig.w.writeAll("return try self.vtable.__as_")
                else             try mig.w.writeAll("return self.vtable.__as_");
                try mig.w.print("{s}.{s}(self.ptr", .{ s.name, meth.name });
                for (meth.params) |p| try mig.w.print(", {s}", .{p.name});
                try mig.w.writeAll(");\n");
                try ig.writeIndent();
                try ig.w.writeAll("}\n");
            }
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
        // Synthetic `pub fn init(fields...) StructName` for structs without explicit `cue init`.
        // Normalises all structs so callers can use StructName.init(...) uniformly.
        var has_cue_init_s = false;
        for (n.members) |m| if (m == .init) { has_cue_init_s = true; break; };
        if (!has_cue_init_s) {
            try ig.writeIndent();
            try ig.w.writeAll("pub fn init(");
            var fi: usize = 0;
            for (n.members) |m| {
                if (m != .var_) continue;
                if (m.var_.mods.static_) continue;
                if (fi > 0) try ig.w.writeAll(", ");
                try ig.w.print("{s}: ", .{m.var_.name});
                if (m.var_.type_) |tr| try ig.genType(tr) else try ig.w.writeAll("anytype");
                fi += 1;
            }
            try ig.w.print(") {s} {{\n", .{n.name});
            const sig = ig.indented();
            try sig.writeIndent();
            if (fi == 0) {
                try sig.w.writeAll("return .{};\n");
            } else {
                try sig.w.writeAll("return .{");
                var fj: usize = 0;
                for (n.members) |m| {
                    if (m != .var_) continue;
                    if (m.var_.mods.static_) continue;
                    if (fj > 0) try sig.w.writeAll(",");
                    try sig.w.print(" .{s} = {s}", .{ m.var_.name, m.var_.name });
                    fj += 1;
                }
                try sig.w.writeAll(" };\n");
            }
            try ig.writeIndent();
            try ig.w.writeAll("}\n\n");
        }
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
        if (n.mods.derive_debug) try ig.genDeriveToString(n);
        if (n.mods.derive_eq)    try ig.genDeriveEql(n);
        if (n.mods.derive_hash)  try ig.genDeriveHash(n);
        try g.writeIndent();
        try g.w.writeAll("};\n\n");
        try g.genExportWrappers(n.name, n.members);
    }

    fn genDeriveToString(g: Generator, n: *Ast.DeclStruct) anyerror!void {
        try g.writeIndent();
        try g.w.print("pub fn toString(self: *const {s}) []const u8 {{\n", .{n.name});
        const ig = g.indented();
        // Build format string and args list
        var fmt_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer fmt_buf.deinit(g.alloc);
        try fmt_buf.appendSlice(g.alloc, n.name);
        try fmt_buf.append(g.alloc, '(');
        var field_count: usize = 0;
        for (n.members) |m| {
            if (m != .var_) continue;
            if (m.var_.mods.static_) continue;
            if (field_count > 0) try fmt_buf.appendSlice(g.alloc, ", ");
            try fmt_buf.appendSlice(g.alloc, m.var_.name);
            try fmt_buf.append(g.alloc, '=');
            const is_str = if (m.var_.type_) |tr| isStringTypeRef(tr) else false;
            const is_float = if (m.var_.type_) |tr| (tr == .named and (std.mem.eql(u8, tr.named.name, "float") or std.mem.eql(u8, tr.named.name, "num"))) else false;
            if (is_str) {
                try fmt_buf.appendSlice(g.alloc, "{s}");
            } else if (is_float) {
                try fmt_buf.appendSlice(g.alloc, "{d}");
            } else {
                try fmt_buf.appendSlice(g.alloc, "{}");
            }
            field_count += 1;
        }
        try fmt_buf.append(g.alloc, ')');
        try ig.writeIndent();
        try ig.w.print("return std.fmt.allocPrint(_allocator, \"{s}\", .{{", .{fmt_buf.items});
        var fi: usize = 0;
        for (n.members) |m| {
            if (m != .var_) continue;
            if (m.var_.mods.static_) continue;
            if (fi > 0) try ig.w.writeAll(", ");
            try ig.w.print("self.{s}", .{m.var_.name});
            fi += 1;
        }
        try ig.w.writeAll("}) catch unreachable;\n");
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    fn genDeriveEql(g: Generator, n: *Ast.DeclStruct) anyerror!void {
        try g.writeIndent();
        try g.w.print("pub fn eql(self: *const {s}, other: *const {s}) bool {{\n", .{ n.name, n.name });
        const ig = g.indented();
        var field_count: usize = 0;
        for (n.members) |m| {
            if (m != .var_) continue;
            if (m.var_.mods.static_) continue;
            field_count += 1;
        }
        if (field_count == 0) {
            try ig.writeIndent();
            try ig.w.writeAll("return true;\n");
        } else {
            try ig.writeIndent();
            try ig.w.writeAll("return ");
            var fi: usize = 0;
            for (n.members) |m| {
                if (m != .var_) continue;
                if (m.var_.mods.static_) continue;
                if (fi > 0) try ig.w.writeAll(" and ");
                const is_str = if (m.var_.type_) |tr| isStringTypeRef(tr) else false;
                if (is_str) {
                    try ig.w.print("std.mem.eql(u8, self.{s}, other.{s})", .{ m.var_.name, m.var_.name });
                } else {
                    try ig.w.print("(self.{s} == other.{s})", .{ m.var_.name, m.var_.name });
                }
                fi += 1;
            }
            try ig.w.writeAll(";\n");
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    fn genDeriveHash(g: Generator, n: *Ast.DeclStruct) anyerror!void {
        try g.writeIndent();
        try g.w.print("pub fn hash(self: *const {s}) u64 {{\n", .{n.name});
        const ig = g.indented();
        try ig.writeIndent();
        try ig.w.writeAll("var hasher = std.hash.Wyhash.init(0);\n");
        for (n.members) |m| {
            if (m != .var_) continue;
            if (m.var_.mods.static_) continue;
            try ig.writeIndent();
            try ig.w.print("std.hash.autoHashStrat(&hasher, self.{s}, .Deep);\n", .{m.var_.name});
        }
        try ig.writeIndent();
        try ig.w.writeAll("return hasher.final();\n");
        try g.writeIndent();
        try g.w.writeAll("}\n");
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
        // BUG-137: module-level vars are file-scope `pub var`/`pub const`. Zig
        // forbids any function-local/param from shadowing a file-scope name, so a
        // module var named like a common local (`total`, `count`, `g`, …) — or
        // like a runtime-preamble local/param — would fail to compile. Emit the
        // Zig name with a reserved prefix that user/preamble identifiers never
        // use; references are prefixed identically in genIdent. The Zebra source
        // name (n.name) is unchanged.
        try g.w.print("pub {s} {s}{s}", .{ kw, module_var_prefix, n.name });
        if (n.type_) |tr| {
            try g.w.writeAll(": ");
            try g.genType(tr);
        } else if (std.mem.eql(u8, kw, "var")) {
            // Untyped module-level `var`: emit the TC-inferred type so Zig
            // doesn't reject `pub var x = 10` ("comptime_int must be const or
            // comptime").  Same machinery as genFieldDecl. (`const` stays
            // untyped — Zig keeps it comptime.)
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

        // Instance methods inside a type get `self: *Owner`.
        // `shared` methods (type-level, not instance) omit self.
        const has_self = g.owner.len > 0 and !n.mods.static_;

        // @once: cache-on-first-call pattern.
        // Emits: (1) a nullable cache field, (2) a public wrapper that checks/fills the cache,
        // (3) the private impl function that runs the original body (name = _zbr_once_X_impl).
        var once_name_buf: [256]u8 = undefined;
        const emit_name: []const u8 = if (n.mods.once) blk: {
            if (!has_self or n.params.len != 0 or n.return_type == null)
                std.debug.panic("@once requires a no-param instance method with a non-void return type", .{});
            const impl_name = std.fmt.bufPrint(&once_name_buf, "_zbr_once_{s}_impl", .{n.name}) catch n.name;
            // ── Cache field ──────────────────────────────────────────────────
            try g.writeIndent();
            try g.w.print("_once_{s}_val: ?", .{n.name});
            try g.genType(n.return_type.?);
            try g.w.writeAll(" = null,\n");
            // ── Public wrapper ───────────────────────────────────────────────
            try g.writeIndent();
            const self_type = if (g.is_generic) "@This()" else g.owner;
            try g.w.print("pub fn {s}(self: *{s}) ", .{ n.name, self_type });
            try g.genType(n.return_type.?);
            try g.w.writeAll(" {\n");
            const wg = mg.indented();
            try wg.writeIndent();
            try wg.w.print("if (self._once_{s}_val) |_zbr_v| return _zbr_v;\n", .{n.name});
            try wg.writeIndent();
            try wg.w.print("const _zbr_r = self.{s}();\n", .{impl_name});
            try wg.writeIndent();
            try wg.w.print("self._once_{s}_val = _zbr_r;\n", .{n.name});
            try wg.writeIndent();
            try wg.w.writeAll("return _zbr_r;\n");
            try g.writeIndent();
            try g.w.writeAll("}\n\n");
            break :blk impl_name;
        } else n.name;

        try g.writeIndent();
        // @once impl is private (the wrapper above is the public API).
        if (!n.mods.once) {
            if (n.mods.export_) try g.w.writeAll("pub export ")
            else                try g.w.writeAll("pub ");
        }
        try g.w.print("fn {s}(", .{emit_name});

        // Pre-check: does this method have any tail-recursive calls?
        // If so, we use the loop-transformation (TCO) path.
        const is_tco = if (n.body) |body| n.params.len > 0 and
            scanTco(body, n.name, g.owner, n.mods.static_) else false;

        if (has_self) {
            // `@pure` opts the method into `self: *const Owner` so callers can
            // invoke it on by-value/const receivers (e.g. Vector3.len() on a
            // `Vector3` by-value param).  Default: `*Owner` (current behavior).
            // `@pure` forces `*const`; otherwise auto-detect non-mutating methods so
            // they take `*const Owner` (callable on by-value/const/rvalue receivers —
            // method-chain temps, by-value params). A non-private method of a class with
            // invariants gets an injected `defer self._check_invariant()` (takes *self),
            // so it must stay `*` even when the source body is non-mutating.
            const will_inject_invariant = !n.mods.private and g.owner_invariants.len > 0 and !g.strip_contracts;
            const non_mutating = !will_inject_invariant and (if (n.body) |b| !methodMutatesSelf(b) else false);
            const self_qual: []const u8 = if (n.mods.pure or non_mutating) "*const " else "*";
            // Generic class methods use *@This() (the struct is anonymous inside the comptime fn).
            if (g.is_generic) {
                try g.w.print("self: {s}@This()", .{self_qual});
            } else {
                try g.w.print("self: {s}{s}", .{ self_qual, g.owner });
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
        // Root entry point: append `init: std.process.Init` so Zig 0.16 can supply
        // the _io handle and process args before any user code runs.
        if (g.owner.len == 0 and std.mem.eql(u8, n.name, "main") and !g.test_mode) {
            if (n.params.len > 0 or has_self) try g.w.writeAll(", ");
            try g.w.writeAll("_zinit: std.process.Init");
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
            // BUG-097: track which params are emitted as *ArrayList so genArgs
            // can use three-case logic instead of binary &/no-& (see argIdentInCpp).
            var cpp = std.StringHashMap(void).init(g.alloc);
            defer cpp.deinit();
            if (!is_tco) {
                for (n.params) |p| {
                    if (paramNeedsAddrOf(p, n.body, g.alloc, g.tc))
                        try cpp.put(p.name, {});
                }
            }
            mg.caller_ptr_params = if (cpp.count() > 0) &cpp else null;

            try g.w.writeAll(" {\n");

            // Root entry point: inject _io/_args/_allocator init before user code.
            if (g.owner.len == 0 and std.mem.eql(u8, n.name, "main") and !g.test_mode) {
                const _eg = mg.indented();
                try _eg.writeIndent(); try _eg.w.writeAll("_io = _zinit.io;\n");
                try _eg.writeIndent(); try _eg.w.writeAll("_args = _zinit.minimal.args;\n");
                try _eg.writeIndent(); try _eg.w.writeAll("_allocator = _arena.allocator();\n");
                if (!g.library_mode) {
                    try _eg.writeIndent(); try _eg.w.writeAll("defer _arena.deinit();\n");
                }
                if (g.gui_backend == .tui) {
                    try _eg.writeIndent(); try _eg.w.writeAll("_tui_env = _zinit.environ_map;\n");
                }
                for (g.module.decls) |_ed| {
                    const _eu = switch (_ed) { .use => |u| u, else => continue };
                    if (g.native_uses) |nu| if (nu.get(_eu.path) != null) continue;
                    const _ep = try std.mem.replaceOwned(u8, g.alloc, _eu.path, ".", "/");
                    defer g.alloc.free(_ep);
                    try _eg.writeIndent();
                    try _eg.w.print("@import(\"{s}.zig\")._initAllocator(_allocator);\n", .{_ep});
                    try _eg.writeIndent();
                    try _eg.w.print("@import(\"{s}.zig\")._initIo(_io);\n", .{_ep});
                }
            }

            // `zebra build --list-targets`: set flag before any user code so _build_run()
            // outputs JSON instead of invoking the compiler.
            if (g.list_targets_mode and g.owner.len == 0 and std.mem.eql(u8, n.name, "main")) {
                try mg.indented().writeIndent();
                try mg.indented().w.writeAll("_list_targets_mode = true;\n");
            }

            // @profile: record entry time and defer _profile_end() on any exit path.
            if (n.mods.profile) {
                const ig = mg.indented();
                try ig.writeIndent();
                if (g.owner.len > 0) {
                    try ig.w.print("_profile_start(\"{s}.{s}\");\n", .{ g.owner, n.name });
                } else {
                    try ig.w.print("_profile_start(\"{s}\");\n", .{n.name});
                }
                try ig.writeIndent();
                try ig.w.writeAll("defer _profile_end();\n");
            }

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
                var tco_pnames: std.ArrayListUnmanaged([]const u8) = .empty;
                defer tco_pnames.deinit(g.alloc);
                for (n.params) |p| try tco_pnames.append(g.alloc, p.name);

                const bg = ig.indented()
                    .withClosureVars(&cv_map).withReturnedNames(&ret_set)
                    .withTco(n.name, tco_pnames.items, n.mods.static_)
                    .withMethodRetType(n.return_type);
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
                const bg = mg.indented().withClosureVars(&cv_map).withReturnedNames(&ret_set)
                    .withMethodRetType(n.return_type);
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

            // `zebra build` declarative mode: auto-run the registered build context
            // at the end of main() if the user never called b.run() explicitly.
            if (g.build_mode and g.owner.len == 0 and std.mem.eql(u8, n.name, "main")) {
                try mg.indented().writeIndent();
                try mg.indented().w.writeAll("_build_auto_run();\n");
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
            // @once cache fields are synthetic (not in AST), so they need explicit null init.
            for (g.owner_members) |decl| {
                const m = switch (decl) { .method => |mv| mv, else => continue };
                if (!m.mods.once) continue;
                try bg.writeIndent();
                try bg.w.print("self._once_{s}_val = null;\n", .{m.name});
            }
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
        for (stmts) |stmt| {
            try bg.genStmt(stmt);
            // Auto-discard a local that is never read anywhere in the block and
            // never mutated.  Zig hard-errors on unused locals; translated code
            // routinely emits dead `var X = …` stubs.  A `_ = X;` no-op satisfies
            // Zig.  Conservative (mutated OR used ⇒ no discard); a stray discard
            // would only be a harmless redundant read, never a miscompile.
            if (stmt == .var_) {
                const name = stmt.var_.name;
                // Skip explicitly-typed locals: a refinement type (`int where …`)
                // emits an inline contract check that *uses* the local — invisible
                // to mightUseName — so discarding it would be a pointless discard.
                // The dominant dead-stub case (`var X = nil`) is untyped anyway.
                if (!std.mem.eql(u8, name, "_") and
                    stmt.var_.type_ == null and
                    !block_mut.contains(name) and
                    !mightUseName(name, stmts))
                {
                    try bg.writeIndent();
                    try bg.w.print("_ = {s};\n", .{name});
                }
            }
        }
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
            .assert_eq, .assert_ne => |s| s.span,
            .assert_true, .assert_false => |s| s.span,
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
            .in_scope      => |s| s.span,
            .arena_scope   => |s| s.span,
            .allocate_     => |s| s.span,
            .copy_out      => |s| s.span,
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
            .chained_cmp   => |x| x.span,
            .opt_chain     => |x| x.span,
        };
    }

    fn genStmt(g: Generator, stmt: Ast.Stmt) anyerror!void {
        // Emit source-map marker so Zig compiler errors can be remapped
        // to the originating Zebra file and line by main.zig.
        if (g.source_file.len > 0) {
            if (stmtSpan(stmt)) |sp| {
                try g.w.writeAll("// zbr:");
                try writePathFwd(g.w, g.source_file);
                try g.w.print(":{d}\n", .{sp.line});
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
            .assert       => |s| try g.genAssert(s),
            .assert_eq    => |s| try g.genAssertCmp(s, true),
            .assert_ne    => |s| try g.genAssertCmp(s, false),
            .assert_true  => |s| try g.genAssertUnary(s, true),
            .assert_false => |s| try g.genAssertUnary(s, false),
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
                // Zig 0.15 rejects discarding a non-void expression as a statement;
                // emit `_ = expr;` when the TC has a definitive non-void type.
                if (g.tc) |tc| {
                    const t = tc.expr_types.get(e) orelse .unknown;
                    if (t != .void_ and t != .unknown) try g.w.writeAll("_ = ");
                }
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
                    const content = std.mem.trimEnd(u8, raw[4 .. raw.len - 1], " \t\r\n");
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
            .in_scope    => |s| try g.genInScope(s),
            .arena_scope => |s| try g.genArenaScope(s),
            .allocate_   => |s| try g.genAllocate(s),
            .copy_out    => |s| try g.genCopyOut(s),
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

        // Interface coercion for a generic-class ctor: `var b: I = Box(int)(args)`.
        // The concrete type is a generic instantiation, so the vtable lives inside the
        // monomorphized struct body — reference it as `&Box(i64)._vtable_I`. The ctor
        // is a single `.call` with `type_args` (callee = ident, the generic class).
        if (n.init) |init_e| {
            if (init_e.* == .call and init_e.call.callee.* == .ident and init_e.call.type_args.len > 0) {
                const gclass = init_e.call.callee.ident.name;
                if (findGenericClassDecl(g.module, gclass) != null) {
                    if (n.type_) |tr| {
                        if (tr == .named and findInterfaceDecl(g.module, tr.named.name) != null) {
                            try g.writeIndent();
                            try g.w.print("{s} {s}: {s} = .{{ .ptr = ", .{ kw, n.name, tr.named.name });
                            try g.genExpr(init_e);
                            // Reconstruct `Box(i64)` for the in-struct vtable reference.
                            try g.w.print(", .vtable = &{s}(", .{gclass});
                            for (init_e.call.type_args, 0..) |ta, i| {
                                if (i > 0) try g.w.writeAll(", ");
                                try g.genType(ta);
                            }
                            try g.w.print(")._vtable_{s} }};\n", .{tr.named.name});
                            return;
                        }
                    }
                }
            }
        }

        // Interface coercion: `var x: IFace = ClassCtor()` or `var x: ^IFace = ClassCtor()`.
        // Emits shim-based vtable construction so Zig's strict fn-pointer types are satisfied.
        if (n.init) |init_e| {
            if (init_e.* == .call and init_e.call.callee.* == .ident and init_e.call.type_args.len == 0) {
                const class_name = init_e.call.callee.ident.name;
                if (n.type_) |tr| {
                    // `var x: IFace = ClassCtor()`
                    if (tr == .named) {
                        if (findInterfaceDecl(g.module, tr.named.name) != null) {
                            try g.writeIndent();
                            try g.w.print("{s} {s}: {s} = .{{ .ptr = {s}.init(), .vtable = &_vtable_{s}_{s} }};\n", .{
                                kw, n.name, tr.named.name, class_name, class_name, tr.named.name,
                            });
                            return;
                        }
                    }
                    // `var x: ^IFace = ClassCtor()`
                    if (tr == .ref_to and tr.ref_to.* == .named) {
                        const iname = tr.ref_to.named.name;
                        if (findInterfaceDecl(g.module, iname) != null) {
                            const uid = g.nextUid();
                            try g.writeIndent();
                            try g.w.print("const _iface_{x} = _allocator.create({s}) catch @panic(\"OOM\");\n", .{ uid, iname });
                            try g.writeIndent();
                            try g.w.print("_iface_{x}.* = .{{ .ptr = {s}.init(), .vtable = &_vtable_{s}_{s} }};\n", .{ uid, class_name, class_name, iname });
                            try g.writeIndent();
                            try g.w.print("{s} {s}: *{s} = _iface_{x};\n", .{ kw, n.name, iname, uid });
                            return;
                        }
                    }
                }
            }
        }

        // Interface → interface upcast: `var b: IBase = f` where `f: IFoo` and
        // `IFoo implements IBase`. The two fat-pointer structs are distinct Zig
        // types, so we rebuild the target from the source's erased `ptr` and the
        // `__as_IBase` vtable pointer wired into the source's vtable. Bind the
        // source to a temp first so a side-effecting init isn't evaluated twice.
        if (n.init) |init_e| {
            if (n.type_) |tr| if (tr == .named) {
                const dst_name = tr.named.name;
                if (findInterfaceDecl(g.module, dst_name) != null) {
                    if (g.tc) |tc| if (tc.expr_types.get(init_e)) |rhs_ty| if (rhs_ty == .named) {
                        const src_name = rhs_ty.named.name;
                        if (!std.mem.eql(u8, src_name, dst_name)) {
                            if (findInterfaceDecl(g.module, src_name)) |src_iface| {
                                var sb: [16]*const Ast.DeclInterface = undefined;
                                var is_super = false;
                                for (collectSuperIfaces(g.module, src_iface, &sb)) |s| {
                                    if (std.mem.eql(u8, s.name, dst_name)) { is_super = true; break; }
                                }
                                if (is_super) {
                                    const uid = g.nextUid();
                                    try g.writeIndent();
                                    try g.w.print("const _ifsrc_{x} = ", .{uid});
                                    try g.genExpr(init_e);
                                    try g.w.writeAll(";\n");
                                    try g.writeIndent();
                                    try g.w.print("{s} {s}: {s} = .{{ .ptr = _ifsrc_{x}.ptr, .vtable = _ifsrc_{x}.vtable.__as_{s} }};\n", .{ kw, n.name, dst_name, uid, uid, dst_name });
                                    return;
                                }
                            }
                        }
                    };
                }
            };
        }

        // Track DynLib handle variables for instance method dispatch.
        if (n.init) |e| {
            if (e.* == .call and e.call.callee.* == .member) {
                const mem = e.call.callee.member;
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "DynLib") and std.mem.eql(u8, mem.member, "open")) {
                    try g.dynlib_vars.put(n.name, {});
                }
            }
        }
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
                try g.w.print("var {s} = std.ArrayList(u8).empty;\n", .{n.name});
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
        // Type alias constraint check: if the declared type is a named alias with a
        // constraint, validate it at the declaration site (skipped under --turbo).
        if (!g.strip_contracts) {
            if (n.type_) |tr| {
                const alias_name_opt: ?[]const u8 = switch (tr) {
                    .named         => |nt| nt.name,
                    .alias_applied => |aa| aa.name,
                    else           => null,
                };
                if (alias_name_opt) |alias_name| {
                    if (g.type_alias_decls.get(alias_name)) |alias| {
                        if (alias.constraint) |c| {
                            const ig = g.indented();
                            try g.writeIndent();
                            try g.w.writeAll("{\n");
                            // Bind value params for parametric aliases: const lo: i64 = 0;
                            if (alias.params) |params| {
                                const value_args = tr.alias_applied.args;
                                for (params, 0..) |param, i| {
                                    try ig.writeIndent();
                                    const zig_type = zigTypeForParam(param.type_.?);
                                    try ig.w.print("const {s}: {s} = ", .{ param.name, zig_type });
                                    try ig.genExpr(&value_args[i]);
                                    try ig.w.writeAll(";\n");
                                }
                            }
                            try ig.writeIndent();
                            try ig.w.print("const value = {s};\n", .{n.name});
                            try ig.writeIndent();
                            try ig.w.writeAll("if (!(");
                            try ig.genExpr(c);
                            try ig.w.print(")) std.debug.panic(\"type constraint '{s}' failed\\n\", .{{}});\n", .{alias.name});
                            try g.writeIndent();
                            try g.w.writeAll("}\n");
                        }
                    }
                }
            }
        }
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
    ///   List(int)       → std.ArrayList(i64).empty   (Zig 0.15: unmanaged, alloc per-op)
    ///   HashMap(str, T) → std.StringHashMap(T).init(_allocator)
    ///   HashMap(K, V)   → std.AutoHashMap(K, V).init(_allocator)
    fn genStdlibInit(g: Generator, gtr: Ast.GenericTypeRef) anyerror!void {
        if (std.mem.eql(u8, gtr.name, "List")) {
            // Zig 0.16: ArrayList.empty replaces {} (no default field values)
            try g.genType(.{ .generic = gtr });
            try g.w.writeAll(".empty");
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
                    const item_tr: ?Ast.TypeRef = if (gtr.args.len >= 1) gtr.args[0] else null;
                    return g.genListMethod(object, item_is_str, item_tr, method, args);
                }
                if (std.mem.eql(u8, gtr.name, "HashMap")) {
                    const key_is_str = gtr.args.len >= 1 and isStringTypeRef(gtr.args[0]);
                    const val_is_str = gtr.args.len >= 2 and isStringTypeRef(gtr.args[1]);
                    return g.genHashMapMethod(object, key_is_str, val_is_str, method, args);
                }
                if (std.mem.eql(u8, gtr.name, "Chan")) {
                    return g.genChanMethod(object, method, args);
                }
                // Atomic(T) and ThreadPool: instance methods pass through to
                // the Zig-generated _Atomic(T)/_ThreadPool struct methods directly.
                if (std.mem.eql(u8, gtr.name, "Atomic") or
                    std.mem.eql(u8, gtr.name, "ThreadPool")) {
                    return false;
                }
            },
            .named => |n| {
                if (isStringTypeName(n.name)) return g.genStringMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "StringBuilder")) return g.genStringBuilderMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "char")) return g.genCharMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "TcpConn"))    return g.genTcpMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "UdpSocket"))  return g.genUdpMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "SqliteDb"))   return g.genSqliteMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "SqliteRow"))  return g.genSqliteRowMethod(object, method, args);
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
                    .{ "any", {} }, .{ "all", {} }, .{ "find", {} },
                    .{ "join", {} },
                });
                if (list_methods.get(method) != null) {
                    return g.genListMethod(object, false, null, method, args);
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
                    try g.w.writeAll("@as(i64, @intCast(");
                    try g.genExpr(object);
                    try g.w.writeAll(".len))");
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
            // File.read(path) → std.Io.Dir.cwd().readFileAlloc(_io, path, alloc, .unlimited)
            try g.w.writeAll("(std.Io.Dir.cwd().readFileAlloc(_io, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", _allocator, .unlimited) catch @panic(\"File.read error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "write")) {
            // File.write(path, content) → createFile + writeStreamingAll + close
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _fw_path = ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(";\n");
            try bg.writeIndent();
            try bg.w.writeAll("const _fw_f = std.Io.Dir.cwd().createFile(_io, _zbr_norm_path(_fw_path), .{}) catch @panic(\"File.write error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _fw_f.close(_io);\n");
            try bg.writeIndent();
            try bg.w.writeAll("_fw_f.writeStreamingAll(_io, ");
            if (args.len >= 2) try bg.genExpr(args[1].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(") catch @panic(\"File.write error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk {};\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "exists")) {
            // File.exists(path) → labelled block: access → true, else false
            try g.w.writeAll("(blk: { std.Io.Dir.cwd().access(_io, ");
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
            try bg.w.writeAll("const _fl_content = std.Io.Dir.cwd().readFileAlloc(_io, ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(", _allocator, .unlimited) catch @panic(\"File.readLines error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _fl_list = std.ArrayList([]const u8).empty;\n");
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
            try bg.w.writeAll("const _fa_file = std.Io.Dir.cwd().openFile(_io, _zbr_norm_path(_fa_path), .{ .mode = .read_write })\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("catch std.Io.Dir.cwd().createFile(_io, _zbr_norm_path(_fa_path), .{}) catch @panic(\"File.append error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _fa_file.close(_io);\n");
            try bg.writeIndent();
            try bg.w.writeAll("_ = _fa_file.seekFromEnd(_io, 0) catch @panic(\"File.append seek error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("_fa_file.writeStreamingAll(_io, ");
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
            try g.w.writeAll("(std.Io.Dir.cwd().deleteFile(_io, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch |_fd_err| { if (_fd_err != error.FileNotFound) @panic(\"File.delete error\"); })");
            return true;
        }
        if (std.mem.eql(u8, method, "rename")) {
            // File.rename(oldPath, newPath) → rename/move within cwd.
            try g.w.writeAll("(std.Io.Dir.cwd().rename(_io, ");
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
            try bg.w.writeAll("const _fc_data = std.Io.Dir.cwd().readFileAlloc(_io, ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(", _allocator, .unlimited) catch @panic(\"File.copy read error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("const _fc_dst = ");
            if (args.len >= 2) try bg.genExpr(args[1].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(";\n");
            try bg.writeIndent();
            try bg.w.writeAll("const _fc_f = std.Io.Dir.cwd().createFile(_io, _fc_dst, .{}) catch @panic(\"File.copy write error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _fc_f.close(_io);\n");
            try bg.writeIndent();
            try bg.w.writeAll("_fc_f.writeStreamingAll(_io, _fc_data) catch @panic(\"File.copy write error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk {};\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "modtime")) {
            // File.modtime(path: str) → int?  — mtime in ms since epoch, or nil if missing (A2)
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _mt_stat = std.Io.Dir.cwd().statFile(_io, ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(", .{}) catch break :blk @as(?i64, null);\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk @as(?i64, _mt_stat.mtime.toMilliseconds());\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "size")) {
            // File.size(path) → i64 bytes, or -1 if missing
            try g.w.writeAll("(blk: { const _fs_stat = std.Io.Dir.cwd().statFile(_io, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", .{}) catch break :blk @as(i64, -1); break :blk @as(i64, @intCast(_fs_stat.size)); })");
            return true;
        }
        if (std.mem.eql(u8, method, "isFile")) {
            // File.isFile(path) → bool
            try g.w.writeAll("(blk: { const _fi_stat = std.Io.Dir.cwd().statFile(_io, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", .{}) catch break :blk false; break :blk _fi_stat.kind == .file; })");
            return true;
        }
        if (std.mem.eql(u8, method, "isDir")) {
            // File.isDir(path) → bool; statFile fails on directories on Windows so use openDir
            try g.w.writeAll("(blk: { var _fd_dir = std.Io.Dir.cwd().openDir(_io, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", .{}) catch break :blk false; _fd_dir.close(_io); break :blk true; })");
            return true;
        }
        if (std.mem.eql(u8, method, "writeLines")) {
            // File.writeLines(path, lines: List(str)) → void
            try g.w.writeAll("_file_write_lines(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "listDir")) {
            // File.listDir(path) → ArrayList([]const u8) of entry names in directory.
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("var _ld_dir = std.Io.Dir.cwd().openDir(_io, ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\".\"\n");
            try bg.w.writeAll(", .{ .iterate = true }) catch @panic(\"File.listDir error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _ld_dir.close(_io);\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _ld_list = std.ArrayList([]const u8).empty;\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _ld_iter = _ld_dir.iterate();\n");
            try bg.writeIndent();
            try bg.w.writeAll("while (_ld_iter.next(_io) catch null) |_ld_entry| {\n");
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
    //   Dir.list(path)          → List(str)  (entry names, flat)
    //   Dir.walk(path)          → List(str)  (all file paths recursively, root-prefixed, '/' separators)
    fn genDirCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "create")) {
            try g.w.writeAll("(std.Io.Dir.cwd().createDirPath(_io, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch @panic(\"Dir.create error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "createAll")) {
            try g.w.writeAll("(std.Io.Dir.cwd().createDirPath(_io, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch @panic(\"Dir.createAll error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "delete")) {
            try g.w.writeAll("(std.Io.Dir.cwd().deleteDir(_io, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch |_dd_err| { if (_dd_err != error.FileNotFound) @panic(\"Dir.delete error\"); })");
            return true;
        }
        if (std.mem.eql(u8, method, "deleteAll")) {
            try g.w.writeAll("(std.Io.Dir.cwd().deleteTree(_io, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch @panic(\"Dir.deleteAll error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "exists")) {
            // Open the directory to check; access() only works for files.
            try g.w.writeAll("(blk: { var _de_d = std.Io.Dir.cwd().openDir(_io, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", .{}) catch break :blk false; _de_d.close(_io); break :blk true; })");
            return true;
        }
        if (std.mem.eql(u8, method, "list")) {
            // Dir.list(path) → ArrayList([]const u8) of entry names
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("var _dl_dir = std.Io.Dir.cwd().openDir(_io, ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\".\"\n");
            try bg.w.writeAll(", .{ .iterate = true }) catch @panic(\"Dir.list error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _dl_dir.close(_io);\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _dl_list = std.ArrayList([]const u8).empty;\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _dl_iter = _dl_dir.iterate();\n");
            try bg.writeIndent();
            try bg.w.writeAll("while (_dl_iter.next(_io) catch null) |_dl_entry| {\n");
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
        if (std.mem.eql(u8, method, "walk")) {
            // Dir.walk(path) → ArrayList([]const u8) of all file paths recursively,
            // rooted at path, '/' separators, path prefix included.
            try g.w.writeAll("(blk_dw: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _dw_root = ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\".\"");
            try bg.w.writeAll(";\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _dw_dir = std.Io.Dir.cwd().openDir(_io, _dw_root, .{ .iterate = true }) catch @panic(\"Dir.walk error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _dw_dir.close(_io);\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _dw_walker = _dw_dir.walk(_allocator) catch @panic(\"Dir.walk alloc error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _dw_walker.deinit();\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _dw_list = std.ArrayList([]const u8).empty;\n");
            try bg.writeIndent();
            try bg.w.writeAll("while (_dw_walker.next() catch null) |_dw_entry| {\n");
            const ig = bg.indented();
            try ig.writeIndent();
            try ig.w.writeAll("if (_dw_entry.kind != .file) continue;\n");
            try ig.writeIndent();
            try ig.w.writeAll("const _dw_raw = std.fmt.allocPrint(_allocator, \"{s}/{s}\", .{ _dw_root, _dw_entry.path }) catch @panic(\"OOM\");\n");
            try ig.writeIndent();
            try ig.w.writeAll("for (_dw_raw) |*_dw_c| if (_dw_c.* == '\\\\') { _dw_c.* = '/'; };\n");
            try ig.writeIndent();
            try ig.w.writeAll("_dw_list.append(_allocator, _dw_raw) catch @panic(\"OOM\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("}\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk_dw _dw_list;\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        return false;
    }

    // ── Path static methods ───────────────────────────────────────────────────
    //
    //   Path.join(a, b)       → str   (join two path segments)
    //   Path.basename(path)   → str   (last component, no trailing separator)
    //   Path.dirname(path)    → str   (parent directory)
    //   Path.ext(path)        → str   (file extension including dot, or "" if none)
    //   Path.extension(path)  → str   (alias for ext)
    //   Path.stem(path)       → str   (basename without extension)
    //   Path.isAbsolute(path) → bool
    //   Path.absolute(path)   → str   (resolved absolute path)
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
        if (std.mem.eql(u8, method, "ext") or std.mem.eql(u8, method, "extension")) {
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
        if (std.mem.eql(u8, method, "absolute")) {
            // Path.absolute(p) → resolved absolute path; returns p unchanged on error
            try g.w.writeAll("(blk: { const _pp = ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll("; break :blk std.Io.Dir.cwd().realpathAlloc(_io, _pp, _allocator) catch _pp; })");
            return true;
        }
        return false;
    }

    // ── SIMD helper methods ───────────────────────────────────────────────────

    /// Emit a SIMD static constructor: `f32x8.splat(v)` or `f32x8.load(slice)`.
    fn genSimdStaticCall(g: Generator, si: Builtins.SimdInfo, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "splat")) {
            // f32x8.splat(v) → @as(@Vector(8, f32), @splat(@as(f32, v)))
            try g.w.print("@as(@Vector({d}, {s}), @splat(@as({s}, ", .{ si.lanes, si.elem_zig, si.elem_zig });
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "load")) {
            // f32x8.load(slice) → @as(@Vector(8, f32), slice[0..8].*)
            try g.w.print("@as(@Vector({d}, {s}), ", .{ si.lanes, si.elem_zig });
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("&.{}");
            try g.w.print("[0..{d}].*)", .{si.lanes});
            return true;
        }
        return false;
    }

    /// Emit a SIMD instance method: `acc.sum()`, `a.dot(b)`, `a.max_element()`.
    fn genSimdInstanceCall(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "sum")) {
            // acc.sum() → @reduce(.Add, acc)
            try g.w.writeAll("@reduce(.Add, ");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "dot")) {
            // a.dot(b) → @reduce(.Add, a * b)
            try g.w.writeAll("@reduce(.Add, ");
            try g.genExpr(obj);
            try g.w.writeAll(" * ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "max_element")) {
            // a.max_element() → @reduce(.Max, a)
            try g.w.writeAll("@reduce(.Max, ");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "min_element")) {
            // a.min_element() → @reduce(.Min, a)
            try g.w.writeAll("@reduce(.Min, ");
            try g.genExpr(obj);
            try g.w.writeAll(")");
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
        // Hyperbolic trig
        if (std.mem.eql(u8, method, "sinh"))  { try one(g, "sinh",  args); return true; }
        if (std.mem.eql(u8, method, "cosh"))  { try one(g, "cosh",  args); return true; }
        if (std.mem.eql(u8, method, "tanh"))  { try one(g, "tanh",  args); return true; }
        if (std.mem.eql(u8, method, "asinh")) { try one(g, "asinh", args); return true; }
        if (std.mem.eql(u8, method, "acosh")) { try one(g, "acosh", args); return true; }
        if (std.mem.eql(u8, method, "atanh")) { try one(g, "atanh", args); return true; }
        // Cube root, numerically stable variants
        if (std.mem.eql(u8, method, "cbrt"))  { try one(g, "cbrt",  args); return true; }
        if (std.mem.eql(u8, method, "log1p")) { try one(g, "log1p", args); return true; }
        if (std.mem.eql(u8, method, "expm1")) { try one(g, "expm1", args); return true; }
        // Euclidean distance: hypot(a, b)
        if (std.mem.eql(u8, method, "hypot")) {
            try g.w.writeAll("std.math.hypot(@as(f64, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("), @as(f64, ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll("))");
            return true;
        }
        // Linear interpolation: lerp(a, b, t)
        if (std.mem.eql(u8, method, "lerp")) {
            try g.w.writeAll("std.math.lerp(@as(f64, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("), @as(f64, ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll("), @as(f64, ");
            if (args.len >= 3) try g.genExpr(args[2].value) else try g.w.writeAll("0");
            try g.w.writeAll("))");
            return true;
        }
        // Number theory: gcd(a,b), lcm(a,b) — Euclidean algorithm, returns i64
        if (std.mem.eql(u8, method, "gcd")) {
            try g.w.writeAll("(blk: { var _ga = @as(i64, @intCast(@abs(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("))); var _gb = @as(i64, @intCast(@abs(");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll("))); while (_gb != 0) { const _gt = _gb; _gb = @mod(_ga, _gb); _ga = _gt; } break :blk _ga; })");
            return true;
        }
        if (std.mem.eql(u8, method, "lcm")) {
            try g.w.writeAll("(blk: { const _la = @as(i64, @intCast(@abs(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("))); const _lb = @as(i64, @intCast(@abs(");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll("))); var _lg = _la; var _lh = _lb; while (_lh != 0) { const _lt = _lh; _lh = @mod(_lg, _lh); _lg = _lt; } break :blk if (_lg == 0) @as(i64, 0) else @divExact(_la, _lg) * _lb; })");
            return true;
        }
        // Angle conversion
        if (std.mem.eql(u8, method, "toRadians")) {
            try g.w.writeAll("std.math.degreesToRadians(@as(f64, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("))");
            return true;
        }
        if (std.mem.eql(u8, method, "toDegrees")) {
            try g.w.writeAll("std.math.radiansToDegrees(@as(f64, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("))");
            return true;
        }
        // Integer predicates
        if (std.mem.eql(u8, method, "isPowerOfTwo")) {
            try g.w.writeAll("(blk: { const _po2 = ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("; break :blk _po2 > 0 and (_po2 & (_po2 - 1)) == 0; })");
            return true;
        }
        // wrap(x, r) → Python-style always-non-negative modulo
        if (std.mem.eql(u8, method, "wrap")) {
            try g.w.writeAll("@mod(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("1");
            try g.w.writeByte(')');
            return true;
        }
        // Bit operations
        if (std.mem.eql(u8, method, "popcount")) {
            try g.w.writeAll("@as(i64, @intCast(@popCount(@as(u64, @intCast(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")))))");
            return true;
        }
        if (std.mem.eql(u8, method, "clz")) {
            try g.w.writeAll("@as(i64, @intCast(@clz(@as(u64, @intCast(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")))))");
            return true;
        }
        if (std.mem.eql(u8, method, "ctz")) {
            try g.w.writeAll("@as(i64, @intCast(@ctz(@as(u64, @intCast(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")))))");
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
            try bg.w.writeAll("var _sa_list = std.ArrayList([]const u8).empty;\n");
            try bg.writeIndent();
            try bg.w.writeAll("for (_sa_raw) |_sa_arg| _sa_list.append(_allocator, _sa_arg) catch unreachable;\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk _sa_list;\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "exit")) {
            try g.w.writeAll("std.process.exit(@intCast(@as(i64, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(") & 0xFF))");
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
            try g.w.writeAll("_sys_getenv(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "readLine")) {
            // sys.readLine() → ?[]const u8 (null on EOF/error)
            try g.w.writeAll("_sys_readline()");
            return true;
        }
        if (std.mem.eql(u8, method, "run")) {
            // sys.run(argv as List(str)) → _SysRunResult
            try g.w.writeAll("_sys_run(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "exec_inherit")) {
            // sys.exec_inherit(argv: List(str)) → int
            // Runs the process with inherited stdin/stdout/stderr; returns exit code.
            try g.w.writeAll("_sys_exec_inherit(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "spawn")) {
            // sys.spawn(argv: List(str)) → *_SysProcess (non-blocking)
            try g.w.writeAll("_sys_spawn(");
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
        if (std.mem.eql(u8, method, "go")) {
            // sys.go(lambda) — fire-and-forget thread spawn.
            // lambda emits as either fn() void (no capture) or struct instance (captured).
            // _sys_go() in stdlib_preamble.zig handles both via comptime dispatch.
            try g.w.writeAll("_sys_go(");
            if (args.len >= 1) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "cwd")) {
            // sys.cwd() → current working directory as str
            try g.w.writeAll("(std.Io.Dir.cwd().realpathAlloc(_io, \".\", _allocator) catch \"\")");
            return true;
        }
        if (std.mem.eql(u8, method, "setenv")) {
            // sys.setenv(key, val) → set an environment variable
            try g.w.writeAll("_sys_setenv(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "selfExe")) {
            try g.w.writeAll("_sys_self_exe()");
            return true;
        }
        return false;
    }

    // ── DynLib instance methods ───────────────────────────────────────────────

    fn genDynLibMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "close")) {
            try g.w.writeAll("_dynlib_close(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "lookup")) {
            // args[0] = interface type ident, args[1] = symbol name string
            if (args.len < 2) return false;
            const iface_name = switch (args[0].value.*) {
                .ident => |id| id.name,
                else => return false,
            };
            const uid = g.nextUid();
            try g.w.print("blk_{x}: {{ const _fn = ", .{uid});
            try g.genExpr(obj);
            try g.w.print(".lib.lookup(*const fn () *{s}, ", .{iface_name});
            try g.genExpr(args[1].value);
            try g.w.print(") orelse break :blk_{x} null; break :blk_{x} _fn(); }}", .{ uid, uid });
            return true;
        }
        return false;
    }

    // ── SysProcess instance methods ───────────────────────────────────────────

    fn genSysProcessMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, _args: []const Ast.Arg) anyerror!bool {
        _ = _args;
        if (std.mem.eql(u8, method, "kill")) {
            try g.w.writeAll("_sys_process_kill(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "isRunning")) {
            try g.w.writeAll("_sys_process_is_running(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
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
        // Unix timestamp in seconds (epoch_ms / 1000)
        if (std.mem.eql(u8, method, "timestamp")) {
            try g.w.writeAll("@divFloor(");
            try g.genExpr(object);
            try g.w.writeAll(".epoch_ms, 1000)");
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
        if (std.mem.eql(u8, method, "inZone")) {
            try g.w.writeAll("_dt_in_zone(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"UTC\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    fn genJsonCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "parse")) {
            // Json.parse(T, src) — overload: first arg is a class ident → route to strict parser.
            if (args.len >= 2 and args[0].value.* == .ident) {
                const sym = g.resolve.exprs.get(&args[0].value.ident);
                if (sym != null and sym.?.kind == .class) {
                    const class_name = args[0].value.ident.name;
                    if (!sym.?.decl.class.mods.reflectable) {
                        std.debug.panic(
                            "Json.parse({s}, …) requires '@reflectable class {s}'",
                            .{ class_name, class_name },
                        );
                    }
                    try g.w.print("_json_parse_strict_{s}(", .{class_name});
                    try g.genExpr(args[1].value);
                    try g.w.writeAll(")");
                    return true;
                }
            }
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
        var fields = std.ArrayListUnmanaged(Field).empty;
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
            .{ "sha256",    "_hash_sha256"    },
            .{ "sha512",    "_hash_sha512"    },
            .{ "md5",       "_hash_md5"       },
            .{ "blake3",    "_hash_blake3"    },
            .{ "crc32",     "_hash_crc32"     },
            .{ "fnv64",     "_hash_fnv64"     },
            .{ "xxHash64",  "_hash_xxhash64"  },
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
        if (std.mem.eql(u8, method, "hmac512")) {
            try g.w.writeAll("_hash_hmac512(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Crypto static calls ──────────────────────────────────────────────────
    fn genCryptoCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "encrypt")) {
            try g.w.writeAll("_crypto_encrypt(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "decrypt")) {
            try g.w.writeAll("_crypto_decrypt(");
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
        // gaussian(mean, stddev) — Box-Muller normal distribution
        if (std.mem.eql(u8, method, "gaussian")) {
            try g.w.writeAll("_random_gaussian(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0.0");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("1.0");
            try g.w.writeAll(")");
            return true;
        }
        // weighted(items, weights) — weighted random choice
        if (std.mem.eql(u8, method, "weighted")) {
            try g.w.writeAll("_random_weighted(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
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
        if (std.mem.eql(u8, method, "setFile")) {
            try g.w.writeAll("_log_set_file(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "json")) {
            // Log.json(level, msg) or Log.json(level, msg, data)
            try g.w.writeAll("_log_json(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"info\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 3) try g.genExpr(args[2].value) else try g.w.writeAll("\"\"");
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

    // ── Profile static calls ────────────────────────────────────────────────
    fn genProfileCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "start")) {
            try g.w.writeAll("_profile_start(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "end"))           { try g.w.writeAll("_profile_end()");           return true; }
        if (std.mem.eql(u8, method, "report"))        { try g.w.writeAll("_profile_report()");       return true; }
        if (std.mem.eql(u8, method, "dump_folded"))   { try g.w.writeAll("_profile_dump_folded()");  return true; }
        if (std.mem.eql(u8, method, "reset"))         { try g.w.writeAll("_profile_reset()");        return true; }
        return false;
    }

    // ── Base64 static calls ───────────────────────────────────────────────────
    fn genBase64Call(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "encode")) {
            try g.w.writeAll("_base64_encode(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "decode")) {
            try g.w.writeAll("_base64_decode(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "encodeUrl")) {
            try g.w.writeAll("_base64_encode_url(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "decodeUrl")) {
            try g.w.writeAll("_base64_decode_url(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
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

    // ── Ws static methods ─────────────────────────────────────────────────────

    /// Emit a static `Ws.*` call.
    ///   Ws.connect(url) → _ws_connect(url) → ?*_WsConn
    ///   Ws.serve(port, handler) → _ws_serve(port, handler)
    fn genWsCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "connect")) {
            try g.w.writeAll("_ws_connect(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "serve")) {
            try g.w.writeAll("_ws_serve(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── WsConn instance methods ───────────────────────────────────────────────

    fn genWsConnMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "send")) {
            try g.w.writeAll("_ws_send(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "recv")) {
            try g.w.writeAll("_ws_recv(");
            try g.genExpr(obj);
            try g.w.writeAll(", _allocator)");
            return true;
        }
        if (std.mem.eql(u8, method, "close")) {
            try g.w.writeAll("_ws_close(");
            try g.genExpr(obj);
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
        if (std.mem.eql(u8, method, "serve")) {
            try g.w.writeAll("_tcp_serve(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("8080");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("undefined");
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
            try g.w.writeAll("_udp_socket()");
            return true;
        }
        if (std.mem.eql(u8, method, "bind")) {
            try g.w.writeAll("_udp_bind(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeByte(')');
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

    /// Gui.run / Gui.setColor / Gui.setColorsDark / Gui.setStyleFloat / Gui.setVec2 / Gui.scaleAllSizes / Gui.getDpi
    fn genGuiCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "run")) {
            if (g.uses_gui_ptr) |p| p.* = true;
            if (args.len >= 6) {
                // MVU form: Gui.run(title, w, h, init, update, view)
                try g.w.writeAll("_gui_mvu_run(");
                try g.genExpr(args[0].value);
                try g.w.writeAll(", ");
                try g.genExpr(args[1].value);
                try g.w.writeAll(", ");
                try g.genExpr(args[2].value);
                try g.w.writeAll(", ");
                try g.genExpr(args[3].value);
                try g.w.writeAll(", ");
                try g.genExpr(args[4].value);
                try g.w.writeAll(", ");
                try g.genExpr(args[5].value);
                try g.w.writeAll(")");
            } else {
                try g.w.writeAll("_gui_run(");
                if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"App\"");
                try g.w.writeAll(", ");
                if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("800");
                try g.w.writeAll(", ");
                if (args.len >= 3) try g.genExpr(args[2].value) else try g.w.writeAll("600");
                try g.w.writeAll(", ");
                if (args.len >= 4) try g.genExpr(args[3].value) else try g.w.writeAll("undefined");
                try g.w.writeAll(")");
            }
            return true;
        }
        if (std.mem.eql(u8, method, "setColor")) {
            if (g.uses_gui_ptr) |p| p.* = true;
            try g.w.writeAll("_gui_active_backend.setColorFn(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", @as(f32, @floatCast(");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll(")), @as(f32, @floatCast(");
            if (args.len >= 3) try g.genExpr(args[2].value) else try g.w.writeAll("0");
            try g.w.writeAll(")), @as(f32, @floatCast(");
            if (args.len >= 4) try g.genExpr(args[3].value) else try g.w.writeAll("0");
            try g.w.writeAll(")), @as(f32, @floatCast(");
            if (args.len >= 5) try g.genExpr(args[4].value) else try g.w.writeAll("1");
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "setColorsDark")) {
            if (g.uses_gui_ptr) |p| p.* = true;
            try g.w.writeAll("_gui_active_backend.setColorsDarkFn()");
            return true;
        }
        if (std.mem.eql(u8, method, "setStyleFloat")) {
            if (g.uses_gui_ptr) |p| p.* = true;
            try g.w.writeAll("_gui_active_backend.setStyleFloatFn(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", @as(f32, @floatCast(");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "setVec2")) {
            if (g.uses_gui_ptr) |p| p.* = true;
            try g.w.writeAll("_gui_active_backend.setVec2Fn(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", @as(f32, @floatCast(");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll(")), @as(f32, @floatCast(");
            if (args.len >= 3) try g.genExpr(args[2].value) else try g.w.writeAll("0");
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "scaleAllSizes")) {
            if (g.uses_gui_ptr) |p| p.* = true;
            try g.w.writeAll("_gui_active_backend.scaleAllSizesFn(@as(f32, @floatCast(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("1");
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "getDpi")) {
            if (g.uses_gui_ptr) |p| p.* = true;
            try g.w.writeAll("@as(f64, @floatCast(_gui_active_backend.getDpiFn()))");
            return true;
        }
        return false;
    }

    /// editor.setText / getText / getCursorLine / getCursorCol / setCursorPosition / setReadOnly / setErrorMarkers / render
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
        if (std.mem.eql(u8, method, "getCursorLine")) {
            try g.w.writeAll("_code_editor_get_cursor_line(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "getCursorCol")) {
            try g.w.writeAll("_code_editor_get_cursor_col(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "setCursorPosition")) {
            try g.w.writeAll("_code_editor_set_cursor_position(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("1");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("1");
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
            .{ "text",      {} }, .{ "separator",      {} }, .{ "sameLine",  {} },
            .{ "spacing",   {} }, .{ "indent",         {} }, .{ "unindent",  {} },
            .{ "button",    {} }, .{ "checkbox",       {} }, .{ "slider",    {} },
            .{ "input",     {} }, .{ "inputMultiline", {} },
            .{ "panel",     {} }, .{ "window",         {} },
            .{ "selectable",       {} }, .{ "textColored",     {} },
            .{ "beginTable",       {} }, .{ "tableSetupColumn",{} },
            .{ "tableHeadersRow",  {} }, .{ "tableNextRow",    {} },
            .{ "tableNextColumn",  {} }, .{ "endTable",        {} },
            .{ "childWindow",      {} },
            .{ "treeNode",         {} }, .{ "treePop",         {} },
            .{ "progressBar",      {} }, .{ "combobox",        {} }, .{ "spinbox", {} },
            .{ "openFile",         {} }, .{ "saveFile",         {} }, .{ "openFolder", {} },
            .{ "msgBox",           {} }, .{ "msgBoxError",      {} },
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
            .{ "text",    {} }, .{ "separator",     {} }, .{ "sameLine",    {} },
            .{ "spacing", {} }, .{ "indent",        {} }, .{ "unindent",    {} },
            .{ "panel",   {} }, .{ "window",        {} }, .{ "textColored", {} },
            .{ "tableSetupColumn", {} }, .{ "tableHeadersRow", {} },
            .{ "tableNextRow",     {} }, .{ "tableNextColumn", {} },
            .{ "endTable",         {} }, .{ "childWindow",     {} }, .{ "treePop", {} },
            .{ "progressBar",      {} }, .{ "msgBox",          {} }, .{ "msgBoxError", {} },
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
        var tmp_names = std.ArrayList(?[]const u8).empty;
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

    fn genLowLevelMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        const known = std.StaticStringMap(void).initComptime(&.{
            .{ "addLine",          {} }, .{ "addRect",          {} }, .{ "addRectFilled", {} },
            .{ "addCircle",        {} }, .{ "addCircleFilled",  {} }, .{ "addText",       {} },
            .{ "getWindowPos",     {} }, .{ "getWindowSize",    {} },
            .{ "getCursorPos",     {} }, .{ "getMousePos",      {} },
            .{ "beginGroup",       {} }, .{ "endGroup",         {} }, .{ "sameLine",       {} },
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

    // ── Build context methods ─────────────────────────────────────────────────

    fn genBuildMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "new")) {
            // Build.new() — ignores the receiver (Build type name), emits constructor.
            try g.w.writeAll("_build_new(_allocator)");
            return true;
        }
        if (std.mem.eql(u8, method, "exe") or
            std.mem.eql(u8, method, "lib") or
            std.mem.eql(u8, method, "test_"))
        {
            // b.exe(name, entry) → _build_add(b, _Build_Kind.exe, name, entry)
            try g.w.writeAll("_build_add(");
            try g.genExpr(obj);
            try g.w.print(", _Build_Kind.{s}, ", .{method});
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "run")) {
            try g.w.writeAll("_build_run(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "target")) {
            // b.target(name) — look up a registered BuildTarget by name.
            try g.w.writeAll("_build_target_by_name(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "dependency")) {
            // Post-1.0 stub — no-op at runtime.
            try g.w.writeAll("_build_dep_stub(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    fn genBuildTargetMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "linkLib")) {
            try g.w.writeAll("_build_target_link_lib(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "platform")) {
            try g.w.writeAll("_build_target_platform(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "option")) {
            try g.w.writeAll("_build_target_option(");
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

    fn genUdpMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "send")) {
            try g.genExpr(obj);
            try g.w.writeAll(".send_(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 3) try g.genExpr(args[2].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "recv")) {
            try g.genExpr(obj);
            try g.w.writeAll(".recv_(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("4096");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "close")) {
            try g.genExpr(obj);
            try g.w.writeAll(".close_()");
            return true;
        }
        return false;
    }

    // ── SQLite ────────────────────────────────────────────────────────────────────

    /// Emit a `&[_]_SqliteParam{...}` slice from a Zebra list literal.
    /// Falls back to `&.{}` (empty) when the expression is not a list literal.
    fn genSqliteParams(g: Generator, params_expr: *const Ast.Expr) anyerror!void {
        if (params_expr.* == .list_lit) {
            try g.w.writeAll("&[_]_SqliteParam{");
            for (params_expr.list_lit.elems, 0..) |elem, i| {
                if (i > 0) try g.w.writeAll(", ");
                const elem_tc = if (g.tc) |tc| tc.expr_types.get(elem) orelse .unknown else .unknown;
                switch (elem_tc) {
                    .int, .char, .uint, .int_n, .uint_n => {
                        try g.w.writeAll(".{ .int = @as(i64, @intCast(");
                        try g.genExpr(elem);
                        try g.w.writeAll(")) }");
                    },
                    .float => {
                        try g.w.writeAll(".{ .float = @as(f64, ");
                        try g.genExpr(elem);
                        try g.w.writeAll(") }");
                    },
                    else => {
                        try g.w.writeAll(".{ .text = ");
                        try g.genExpr(elem);
                        try g.w.writeAll(" }");
                    },
                }
            }
            try g.w.writeAll("}");
        } else {
            try g.w.writeAll("&.{}");
        }
    }

    /// `Sqlite.open(path)` static call.
    fn genSqliteCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "open")) {
            if (g.uses_sqlite_ptr) |p| p.* = true;
            try g.w.writeAll("_sqlite_open(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeByte(')');
            return true;
        }
        return false;
    }

    /// Methods on a `SqliteDb` receiver.
    fn genSqliteMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (g.uses_sqlite_ptr) |p| p.* = true;
        if (std.mem.eql(u8, method, "exec")) {
            if (args.len >= 2) {
                // db.exec(sql, params)
                try g.genExpr(obj);
                try g.w.writeAll(".exec_p_(");
                try g.genExpr(args[0].value);
                try g.w.writeAll(", ");
                try g.genSqliteParams(args[1].value);
                try g.w.writeByte(')');
            } else {
                try g.genExpr(obj);
                try g.w.writeAll(".exec_(");
                if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
                try g.w.writeByte(')');
            }
            return true;
        }
        if (std.mem.eql(u8, method, "query")) {
            if (args.len >= 2) {
                try g.genExpr(obj);
                try g.w.writeAll(".query_p_(");
                try g.genExpr(args[0].value);
                try g.w.writeAll(", ");
                try g.genSqliteParams(args[1].value);
                try g.w.writeByte(')');
            } else {
                try g.genExpr(obj);
                try g.w.writeAll(".query_(");
                if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
                try g.w.writeByte(')');
            }
            return true;
        }
        if (std.mem.eql(u8, method, "begin"))    { try g.genExpr(obj); try g.w.writeAll(".begin_()");    return true; }
        if (std.mem.eql(u8, method, "commit"))   { try g.genExpr(obj); try g.w.writeAll(".commit_()");   return true; }
        if (std.mem.eql(u8, method, "rollback")) { try g.genExpr(obj); try g.w.writeAll(".rollback_()"); return true; }
        if (std.mem.eql(u8, method, "close"))    { try g.genExpr(obj); try g.w.writeAll(".close_()");    return true; }
        return false;
    }

    /// Methods on a `SqliteRow` receiver (row.int/str/float/bool).
    fn genSqliteRowMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "asInt") or std.mem.eql(u8, method, "asBool")) {
            try g.genExpr(obj);
            try g.w.writeAll(".int_(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeByte(')');
            return true;
        }
        if (std.mem.eql(u8, method, "asStr")) {
            try g.genExpr(obj);
            try g.w.writeAll(".str_(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeByte(')');
            return true;
        }
        if (std.mem.eql(u8, method, "asFloat")) {
            try g.genExpr(obj);
            try g.w.writeAll(".float_(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeByte(')');
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
        // Reflect.hostKind(x): language-neutral substrate category of x's
        // compile-time type ("nil"/"bool"/"int"/"float"/"string"/"function"/"ref").
        // Resolved by Zig at comptime via @typeInfo(@TypeOf(x)); @TypeOf does NOT
        // evaluate its operand, so passing a call expression is side-effect-safe.
        // Per-language type-name mapping (Luau's "number"/"table"/…, JS's …) lives
        // in the *consumer* (e.g. GameEngine's luaTypeName), keeping the compiler
        // free of any source-language knowledge.  See docs/dynamic_interop.md.
        if (std.mem.eql(u8, method, "hostKind")) {
            try g.w.writeAll("switch (@typeInfo(@TypeOf(");
            try g.genExpr(arg);
            // A Zig string is a slice of u8 OR a pointer to an array of u8
            // (uncoerced string literals are `*const [N:0]u8`) — mirrors the
            // preamble's string detection.
            try g.w.writeAll("))) { .bool => \"bool\", .int, .comptime_int => \"int\", .float, .comptime_float => \"float\", .pointer => |_p| _sw: { const _ci = @typeInfo(_p.child); break :_sw if (_p.child == u8 or (_ci == .array and _ci.array.child == u8)) \"string\" else \"ref\"; }, .@\"fn\" => \"function\", .optional, .null => \"nil\", else => \"ref\" }");
            return true;
        }
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

    // ── Chan methods ──────────────────────────────────────────────────────────

    fn genChanMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "send")) {
            try g.genExpr(obj);
            try g.w.writeAll(".send(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "recv")) {
            try g.genExpr(obj);
            try g.w.writeAll(".recv()");
            return true;
        }
        if (std.mem.eql(u8, method, "close")) {
            try g.genExpr(obj);
            try g.w.writeAll(".close()");
            return true;
        }
        return false;
    }

    // ── List methods ──────────────────────────────────────────────────────────

    fn genListMethod(g: Generator, obj: *const Ast.Expr, item_is_str: bool, item_tr: ?Ast.TypeRef, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "add")) {
            // list.add(x) → list.append(_allocator, x) catch unreachable  (Zig 0.15)
            // For List(str), intern the item.  For List(^T) with a struct element, auto-box.
            try g.genExpr(obj);
            try g.w.writeAll(".append(_allocator, ");
            if (args.len > 0) {
                const item_is_ptr = blk: {
                    const itr = item_tr orelse break :blk false;
                    break :blk itr == .ref_to;
                };
                if (item_is_ptr) {
                    try g.genBoxedArgExpr(args[0].value, item_tr.?.ref_to.*);
                } else if (item_is_str) {
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
        if (std.mem.eql(u8, method, "find")) {
            if (args.len == 0) return false;
            try g.w.writeAll("_zebra_list_find(std.meta.Child(@TypeOf(");
            try g.genExpr(obj);
            try g.w.writeAll(".items)), ");
            try g.genExpr(args[0].value);
            try g.w.writeAll(", ");
            try g.genExpr(obj);
            try g.w.writeAll(")");
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
        if (std.mem.eql(u8, method, "join")) {
            // list.join(sep) → std.mem.join(_allocator, sep, list.items)
            // Requires List(str); sep is a string literal or variable.
            try g.w.writeAll("(std.mem.join(_allocator, ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            try g.genExpr(obj);
            try g.w.writeAll(".items) catch @panic(\"OOM\"))");
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
            try g.w.writeAll("std.mem.trimStart(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", &std.ascii.whitespace)");
            return true;
        }
        if (std.mem.eql(u8, method, "trimRight")) {
            try g.w.writeAll("std.mem.trimEnd(u8, ");
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
            try g.w.writeAll("(blk: { var _rep = std.ArrayList([]const u8).empty; ");
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
        // ── lastIndexOf ───────────────────────────────────────────────────────
        if (std.mem.eql(u8, method, "lastIndexOf")) {
            try g.w.writeAll("(if (std.mem.lastIndexOf(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")) |_li| @as(i64, @intCast(_li)) else @as(i64, -1))");
            return true;
        }
        // ── eqlIgnoreCase ─────────────────────────────────────────────────────
        if (std.mem.eql(u8, method, "eqlIgnoreCase")) {
            try g.w.writeAll("std.ascii.eqlIgnoreCase(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        // ── isAlphanumeric ────────────────────────────────────────────────────
        if (std.mem.eql(u8, method, "isAlphanumeric")) {
            try g.w.writeAll("(blk: { if (");
            try g.genExpr(obj);
            try g.w.writeAll(".len == 0) break :blk false; for (");
            try g.genExpr(obj);
            try g.w.writeAll(") |_an| { if (!std.ascii.isAlphanumeric(_an)) break :blk false; } break :blk true; })");
            return true;
        }
        // ── isPrintable ───────────────────────────────────────────────────────
        if (std.mem.eql(u8, method, "isPrintable")) {
            try g.w.writeAll("(blk: { if (");
            try g.genExpr(obj);
            try g.w.writeAll(".len == 0) break :blk false; for (");
            try g.genExpr(obj);
            try g.w.writeAll(") |_pr| { if (!std.ascii.isPrint(_pr)) break :blk false; } break :blk true; })");
            return true;
        }
        // ── case-insensitive search ───────────────────────────────────────────
        if (std.mem.eql(u8, method, "startsWithIgnoreCase")) {
            try g.w.writeAll("std.ascii.startsWithIgnoreCase(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "endsWithIgnoreCase")) {
            try g.w.writeAll("std.ascii.endsWithIgnoreCase(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "containsIgnoreCase")) {
            try g.w.writeAll("(std.ascii.indexOfIgnoreCase(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") != null)");
            return true;
        }
        if (std.mem.eql(u8, method, "indexOfIgnoreCase")) {
            try g.w.writeAll("(if (std.ascii.indexOfIgnoreCase(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")) |_ii| @as(i64, @intCast(_ii)) else @as(i64, -1))");
            return true;
        }
        // ── indexOfFrom(sub, start) ───────────────────────────────────────────
        if (std.mem.eql(u8, method, "indexOfFrom")) {
            try g.w.writeAll("(if (std.mem.indexOfPos(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", @intCast(");
            if (args.len > 1) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll("), ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")) |_if| @as(i64, @intCast(_if)) else @as(i64, -1))");
            return true;
        }
        // ── toIntBase(base) ───────────────────────────────────────────────────
        if (std.mem.eql(u8, method, "toIntBase")) {
            try g.w.writeAll("(std.fmt.parseInt(i64, ");
            try g.genExpr(obj);
            try g.w.writeAll(", @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("10");
            try g.w.writeAll(")) catch 0)");
            return true;
        }
        // ── tokenize(delim) — split skipping empty tokens, returns ArrayList ────
        if (std.mem.eql(u8, method, "tokenize")) {
            try g.w.writeAll("(blk_tok: { var _tok_it = std.mem.tokenizeSequence(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\" \"");
            try g.w.writeAll("); var _tok_list = std.ArrayList([]const u8).empty; while (_tok_it.next()) |_tok_t| { _tok_list.append(_allocator, _tok_t) catch unreachable; } break :blk_tok _tok_list; })");
            return true;
        }
        // ── Base64 instance methods (ergonomic form) ──────────────────────────
        if (std.mem.eql(u8, method, "encodeBase64")) {
            try g.w.writeAll("_base64_encode(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "decodeBase64")) {
            try g.w.writeAll("_base64_decode_str(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    /// Emit a struct-instance literal for a lambda that has a `capture` block.
    /// The result is a value of an anonymous struct type; call sites use `.call()`.
    fn genCaptureClosureStruct(g: Generator, e: *Ast.ExprLambda) anyerror!void {
        // Collect capture field names so body idents use `self.name`
        var field_names = std.ArrayList([]const u8).empty;
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
                    // `std.ArrayList(T).empty` / `T(Arg).init()` correctly.
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
                try g.genTypedOrExpr(v, g.method_ret_type);
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
            // Interface pointer coercion: `return ClassCtor()` when ret type is `^IFace`.
            if (v.* == .call and v.call.callee.* == .ident and v.call.type_args.len == 0) {
                if (g.method_ret_type) |ret| {
                    if (ret == .ref_to and ret.ref_to.* == .named) {
                        const iname = ret.ref_to.named.name;
                        if (findInterfaceDecl(g.module, iname) != null) {
                            const class_name = v.call.callee.ident.name;
                            const uid = g.nextUid();
                            try g.w.print("const _iface_{x} = _allocator.create({s}) catch @panic(\"OOM\");\n", .{ uid, iname });
                            try g.writeIndent();
                            try g.w.print("_iface_{x}.* = .{{ .ptr = {s}.init(), .vtable = &_vtable_{s}_{s} }};\n", .{ uid, class_name, class_name, iname });
                            try g.writeIndent();
                            try g.w.print("return _iface_{x};\n", .{uid});
                            return;
                        }
                    }
                }
            }
            try g.w.writeAll("return ");
            try g.genTypedOrExpr(v, g.method_ret_type);
            try g.w.writeAll(";\n");
        } else {
            try g.w.writeAll("return;\n");
        }
    }

    /// Emit one clause of an if/else-if chain that may carry a capture binding.
    /// Each clause independently decides whether it is a union-variant check
    /// (`x is U.v as r`), an optional unwrap (`x as n` / `x is T as n`), or a
    /// plain condition — clauses in the same chain need not share a form
    /// (BUG-132: a `... as ...` head with a union-check else-if, or vice versa,
    /// previously panicked by assuming `ei.cond.type_check`).
    /// `lead` is the leading keyword fragment ("if (" or " else if (").
    fn genIfCaptureClause(
        g:       Generator,
        lead:    []const u8,
        cond:    *const Ast.Expr,
        cap_opt: ?[]const u8,
        body:    []const Ast.Stmt,
    ) anyerror!void {
        const is_union_check = cond.* == .type_check and cond.type_check.variant_name != null;
        if (cap_opt) |cap| {
            if (is_union_check) {
                const tc_node = cond.type_check;
                const variant = tc_node.variant_name orelse tc_node.type_name;
                const union_nm = tc_node.type_name;
                try g.w.writeAll(lead);
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
                try bg.genStmts(body);
                try g.writeIndent();
                try g.w.writeAll("}");
            } else {
                // Optional-unwrap: `if x as n` or `if x is T as n`.
                const inner: *const Ast.Expr = if (cond.* == .type_check)
                    cond.type_check.expr
                else
                    cond;
                try g.w.writeAll(lead);
                try g.genExpr(inner);
                try g.w.print(") |{s}| {{\n", .{cap});
                try g.indented().genStmts(body);
                try g.writeIndent();
                try g.w.writeAll("}");
            }
        } else {
            try g.w.writeAll(lead);
            try g.genExpr(cond);
            try g.w.writeAll(") {\n");
            try g.indented().genStmts(body);
            try g.writeIndent();
            try g.w.writeAll("}");
        }
    }

    fn genIf(g: Generator, s: *Ast.StmtIf) anyerror!void {
        try g.writeIndent();
        // `if x is Union.variant |r|` — emit tag check + payload binding.
        if (s.is_capture != null) {
            // Each clause decides its own form (union check / optional unwrap /
            // plain) so a chain may mix forms without panicking (BUG-132).
            try g.genIfCaptureClause("if (", s.cond, s.is_capture, s.then_body);
            for (s.else_ifs) |ei|
                try g.genIfCaptureClause(" else if (", ei.cond, ei.is_capture, ei.body);
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
            // A plain-headed if-chain may still have capture-bearing else-ifs
            // (`if c {} else if x as n {}`); route through the capture-aware
            // clause emitter so the binding is honored (BUG-132).
            try g.genIfCaptureClause(" else if (", ei.cond, ei.is_capture, ei.body);
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
            // sb.len() → @as(i64, @intCast(sb.items.len))
            try g.w.writeAll("@as(i64, @intCast(");
            try g.genExpr(object);
            try g.w.writeAll(".items.len))");
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

        // for a, b in list_of_pairs — tuple List destructuring takes priority over HashMap dispatch.
        // Only fires when the iter's declared type is List((T1, T2, ...)).
        if (s.vars.len >= 2) {
            if (g.getExprDeclaredType(s.iter)) |tr| {
                if (tr == .generic and
                    std.mem.eql(u8, tr.generic.name, "List") and
                    tr.generic.args.len > 0 and
                    tr.generic.args[0] == .tuple)
                {
                    return g.genForInTuple(s);
                }
            }
        }

        // for k, v in map — 2-var form is HashMap-only in Zebra; dispatch early
        // so type-inference gaps don't fall through to the native Zig for-loop path.
        if (s.vars.len == 2) return g.genForInHashMap(s);

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
        // for row in rows — indirect sqlite query: rows was assigned from db.query(...)
        // Detect by tracing the ident's init expression through the resolver.
        if (s.iter.* == .ident) {
            if (g.resolve.exprs.get(&s.iter.ident)) |sym| {
                if (sym.decl == .var_) {
                    const dv = sym.decl.var_;
                    if (dv.init) |init_expr| {
                        if (init_expr.* == .call and init_expr.call.callee.* == .member) {
                            const m = init_expr.call.callee.member;
                            if (std.mem.eql(u8, m.member, "query")) {
                                const obj_tc = if (g.tc) |tc| tc.expr_types.get(m.object) orelse .unknown else .unknown;
                                if (obj_tc == .sqlite_db) return g.genForInCsvRows(s);
                            }
                        }
                    }
                }
            }
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
                // for row in db.query(sql) — sqlite query result
                if (obj_tc == .sqlite_db and std.mem.eql(u8, m.member, "query")) {
                    return g.genForInCsvRows(s); // reuse: both return ArrayList with .items
                }
            }
        }

        // for x in re.findAll(s) / re.groups(s) / Net.resolve(host) — these return
        // List(str) (A1, 1.0 freeze); iterate with .items like any List. Element
        // string-ness comes from the TC for-loop element inference.
        if (s.iter.* == .call and s.iter.call.callee.* == .member) {
            const m = s.iter.call.callee.member;
            if (std.mem.eql(u8, m.member, "findAll") or std.mem.eql(u8, m.member, "groups")) {
                const obj_tc = if (g.tc) |tc| tc.expr_types.get(m.object) orelse .unknown else .unknown;
                if (obj_tc == .regex) return g.genForInList(s);
            }
            if (std.mem.eql(u8, m.member, "resolve") and m.object.* == .ident and
                std.mem.eql(u8, m.object.ident.name, "Net")) return g.genForInList(s);
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

    /// `for a, b in list_of_pairs` — destructure each tuple element into named variables.
    /// Emits: for (iter.items) |_zbr_tup| { const a = _zbr_tup.@"0"; const b = _zbr_tup.@"1"; ... }
    fn genForInTuple(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        const elem_var = "_zbr_tup";
        try g.writeIndent();
        try g.w.writeAll("for (");
        try g.genExpr(s.iter);
        try g.w.print(".items) |{s}| {{\n", .{elem_var});
        var bg = g.indented();
        bg.for_else_label = null;
        for (s.vars, 0..) |v, i| {
            try bg.writeIndent();
            try bg.w.print("const {s} = {s}.@\"{d}\";\n", .{ v, elem_var, i });
            if (!nameUsedInStmts(v, s.body)) {
                try bg.writeIndent();
                try bg.w.print("_ = {s};\n", .{v});
            }
        }
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

        // Wrap in a block to scope `_it_*` and `_e_*`/`_kp_*` — prevents redeclaration
        // when the same loop-variable name appears in multiple HashMap loops in the same scope.
        try g.writeIndent();
        try g.w.writeAll("{\n");
        const og = g.indented();

        // for-else: wrap while in a labeled block that evaluates to bool
        var fels_lbl: ?[]const u8 = null;
        if (s.else_ != null) {
            const uid = g.nextUid();
            fels_lbl = try std.fmt.allocPrint(g.alloc, "_fels_{x}", .{uid});
            try og.writeIndent();
            try og.w.print("const {s} = {s}: {{\n", .{fels_lbl.?, fels_lbl.?});
        }
        defer { if (fels_lbl) |lbl| g.alloc.free(lbl); }
        // wg = level where `var _it_` and `while` are emitted
        const wg = if (fels_lbl != null) og.indented() else og;

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
            try og.writeIndent();
            try og.w.writeAll("};\n");
            try og.writeIndent();
            try og.w.print("if ({s}) {{\n", .{fels_lbl.?});
            try og.indented().genStmts(else_body);
            try og.writeIndent();
            try og.w.writeAll("}\n");
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");
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

        // Wrap in a block to scope `_it_*` — prevents redeclaration when the same
        // loop-variable name appears in multiple split/lines loops in the same Zig scope.
        try g.writeIndent();
        try g.w.writeAll("{\n");
        const og = g.indented();

        // for-else: wrap while in a labeled block that evaluates to bool
        var fels_lbl: ?[]const u8 = null;
        if (s.else_ != null) {
            const uid = g.nextUid();
            fels_lbl = try std.fmt.allocPrint(g.alloc, "_fels_{x}", .{uid});
            try og.writeIndent();
            try og.w.print("const {s} = {s}: {{\n", .{fels_lbl.?, fels_lbl.?});
        }
        defer { if (fels_lbl) |lbl| g.alloc.free(lbl); }
        const wg = if (fels_lbl != null) og.indented() else og;

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
            try og.writeIndent();
            try og.w.writeAll("};\n");
            try og.writeIndent();
            try og.w.print("if ({s}) {{\n", .{fels_lbl.?});
            try og.indented().genStmts(else_body);
            try og.writeIndent();
            try og.w.writeAll("}\n");
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");
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
                        // When binding is "_" (discard), skip the dereference — Zig accepts
                        // |_| { directly even for pointer payloads.
                        if (std.mem.eql(u8, bname, "_")) {
                            try bg.w.writeAll(" => {\n");
                        } else {
                            try bg.w.print(" => |{s}_ptr| {{\n", .{bname});
                            try bg.indented().writeIndent();
                            try bg.indented().w.print("const {s} = {s}_ptr.*;\n", .{ bname, bname });
                        }
                    } else {
                        if (std.mem.eql(u8, bname, "_")) {
                            try bg.w.writeAll(" => {\n");
                        } else {
                            try bg.w.print(" => |{s}| {{\n", .{bname});
                        }
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
        var tmp_names = std.ArrayList(?[]const u8).empty;
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
        var old_nodes: std.ArrayListUnmanaged(*Ast.ExprOld) = .empty;
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

    fn genTestMain(g: Generator, module: Ast.Module) anyerror!void {
        // Derive file stem for auto-tagging: "path/to/foo_test.zbr" → "foo_test".
        const file_stem = blk: {
            const base = std.fs.path.basename(module.file);
            if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
                break :blk base[0..dot];
            }
            break :blk base;
        };

        // Collect test entries as (Zig call expression, display label) pairs.
        // Auto-tags: file stem (all tests) + class/struct name (class-contained tests).
        var test_calls  = std.ArrayListUnmanaged([]const u8).empty;
        var test_labels = std.ArrayListUnmanaged([]const u8).empty;
        defer test_calls.deinit(g.alloc);
        defer test_labels.deinit(g.alloc);

        // Top-level def test_*() functions.
        for (module.decls) |decl| {
            const m = switch (decl) { .method => |m| m, else => continue };
            if (m.mods.static_) continue;
            if (!std.mem.startsWith(u8, m.name, "test_")) continue;
            if (m.params.len != 0) continue;
            if (g.tag_filter) |filter| {
                var matched = std.mem.eql(u8, file_stem, filter);
                if (!matched) for (m.tags) |tag| {
                    if (std.mem.eql(u8, tag, filter)) { matched = true; break; }
                };
                if (!matched) continue;
            }
            try test_calls.append(g.alloc, m.name);
            try test_labels.append(g.alloc, m.name);
        }

        // Class/struct-contained static def test_*() methods.
        for (module.decls) |decl| {
            const container_name: []const u8 = switch (decl) {
                .class   => |c| c.name,
                .struct_ => |s| s.name,
                else     => continue,
            };
            const members: []const Ast.Decl = switch (decl) {
                .class   => |c| c.members,
                .struct_ => |s| s.members,
                else     => unreachable,
            };
            for (members) |mdecl| {
                const m = switch (mdecl) { .method => |m| m, else => continue };
                if (!m.mods.static_) continue;
                if (!std.mem.startsWith(u8, m.name, "test_")) continue;
                if (m.params.len != 0) continue;
                if (g.tag_filter) |filter| {
                    var matched = std.mem.eql(u8, file_stem, filter) or
                                  std.mem.eql(u8, container_name, filter);
                    if (!matched) for (m.tags) |tag| {
                        if (std.mem.eql(u8, tag, filter)) { matched = true; break; }
                    };
                    if (!matched) continue;
                }
                const call_expr = try std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ container_name, m.name });
                try test_calls.append(g.alloc, call_expr);
                try test_labels.append(g.alloc, call_expr);
            }
        }

        try g.w.writeAll(
            "pub fn main(_zinit: std.process.Init) void {\n" ++
            "    _io = _zinit.io;\n" ++
            "    _args = _zinit.minimal.args;\n" ++
            "    _allocator = _arena.allocator();\n" ++
            "    defer _arena.deinit();\n" ++
            "    var _test_pass: usize = 0;\n" ++
            "    var _test_fail: usize = 0;\n",
        );
        for (test_calls.items, test_labels.items) |call, label| {
            try g.w.print(
                "    if ({s}()) |_| {{\n" ++
                "        _test_pass += 1;\n" ++
                "        std.debug.print(\"PASS: {s}\\n\", .{{}});\n" ++
                "    }} else |_terr| {{\n" ++
                "        _test_fail += 1;\n" ++
                "        if (_terr == error.ZebraError) {{\n" ++
                "            std.debug.print(\"FAIL: {s}: {{s}}\\n\", .{{_zbr_error_msg()}});\n" ++
                "        }} else {{\n" ++
                "            std.debug.print(\"FAIL: {s}: {{}}\\n\", .{{_terr}});\n" ++
                "        }}\n" ++
                "    }}\n",
                .{ call, label, label, label },
            );
        }
        try g.w.writeAll(
            "    std.debug.print(\"\\n{d} passed, {d} failed\\n\", .{_test_pass, _test_fail});\n" ++
            "    if (_test_fail > 0) std.process.exit(1);\n" ++
            "}\n",
        );
    }

    fn genAssertCmp(g: Generator, s: *Ast.StmtAssertCmp, eq: bool) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll("try _zebra_assert_cmp(");
        try g.genExpr(s.lhs);
        try g.w.writeAll(", ");
        try g.genExpr(s.rhs);
        try g.w.print(", {s});\n", .{if (eq) "true" else "false"});
    }

    fn genAssertUnary(g: Generator, s: *Ast.StmtAssertUnary, expect_true: bool) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll("try _zebra_assert_bool(");
        try g.genExpr(s.expr);
        try g.w.print(", {s});\n", .{if (expect_true) "true" else "false"});
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

    /// `in expr eol Block` — desugar to { const _in_N = expr; _in_N.begin(); defer _in_N.end(); body }
    fn genInScope(g: Generator, s: *Ast.StmtIn) anyerror!void {
        const uid = g.nextUid();
        try g.writeIndent();
        try g.w.writeAll("{\n");
        const ig = g.indented();
        try ig.writeIndent();
        try ig.w.print("const _in_{d} = ", .{uid});
        try ig.genExpr(s.expr);
        try ig.w.writeAll(";\n");
        try ig.writeIndent();
        try ig.w.print("_in_{d}.begin();\n", .{uid});
        try ig.writeIndent();
        try ig.w.print("defer _in_{d}.end();\n", .{uid});
        try ig.genStmts(s.body);
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

    const AllocSourceKind = enum { arena, debug, fixed_buffer, stack_fallback, user };

    fn allocSourceKind(e: *const Ast.Expr) AllocSourceKind {
        if (e.* != .call) return .user;
        const c = e.call;
        if (c.callee.* != .ident) return .user;
        const n = c.callee.ident.name;
        if (std.mem.eql(u8, n, "Arena"))         return .arena;
        if (std.mem.eql(u8, n, "Debug"))         return .debug;
        if (std.mem.eql(u8, n, "FixedBuffer"))   return .fixed_buffer;
        if (std.mem.eql(u8, n, "StackFallback")) return .stack_fallback;
        return .user;
    }

    /// Emit the Zig initializer for a named AllocatorSource wrapper.
    /// Scoped wrappers (Arena/Debug/FixedBuffer/StackFallback) emit their init expression.
    /// Borrow-mode singletons (Page/Smp/C) emit their std.heap.* value.
    /// Falls back to plain `genExpr` for user-defined sources.
    fn genAllocatorSourceInit(g: Generator, e: *const Ast.Expr) anyerror!void {
        if (e.* == .call) {
            const c = e.call;
            if (c.callee.* == .ident) {
                const name = c.callee.ident.name;
                if (std.mem.eql(u8, name, "Arena")) {
                    try g.w.writeAll("std.heap.ArenaAllocator.init(_allocator)");
                    return;
                }
                if (std.mem.eql(u8, name, "Debug")) {
                    try g.w.writeAll("std.heap.DebugAllocator(.{}){}");
                    return;
                }
                // FixedBuffer is handled inline in genAllocate (needs a backing
                // buffer var emitted before the source init, which requires depth).
                if (std.mem.eql(u8, name, "StackFallback")) {
                    try g.w.writeAll("std.heap.stackFallback(");
                    if (c.args.len > 0) try g.genExpr(c.args[0].value) else try g.w.writeAll("256");
                    try g.w.writeAll(", _allocator)");
                    return;
                }
                if (std.mem.eql(u8, name, "Page")) {
                    try g.w.writeAll("std.heap.page_allocator");
                    return;
                }
                if (std.mem.eql(u8, name, "Smp")) {
                    try g.w.writeAll("std.heap.smp_allocator");
                    return;
                }
                if (std.mem.eql(u8, name, "C")) {
                    try g.w.writeAll("std.heap.c_allocator");
                    return;
                }
            }
        }
        try g.genExpr(e);
    }

    /// `allocate <source> eol Block`
    ///
    /// Borrow mode (is_scoped = false):
    ///   { // allocate
    ///     const _parent_alloc_N = _allocator;
    ///     _allocator = <source>;          // singleton or user Allocator value
    ///     defer _allocator = _parent_alloc_N;
    ///     <body>
    ///   }
    ///
    /// Scoped mode (is_scoped = true):
    ///   { // allocate
    ///     var _alloc_src_N = <init>;      // AllocatorSource wrapper
    ///     const _parent_alloc_N = _allocator;
    ///     _allocator = _alloc_src_N.<getter>();
    ///     defer { _allocator = _parent_alloc_N; [_alloc_src_N.deinit();] }
    ///     <body>
    ///   }
    ///   getter = .get() for StackFallback; .allocator() for all others
    ///   deinit = assert(.ok) for Debug; plain .deinit() for Arena/user;
    ///            omitted for FixedBuffer/StackFallback (stack frame handles cleanup)
    fn genAllocate(g: Generator, s: *Ast.StmtAllocate) anyerror!void {
        const depth = g.arena_depth + 1;
        try g.writeIndent();
        try g.w.writeAll("{ // allocate\n");
        var ig = g.indented();
        ig.arena_depth = if (s.is_scoped) depth else g.arena_depth;

        if (s.is_scoped) {
            const kind = allocSourceKind(s.source);
            if (kind == .fixed_buffer) {
                // `FixedBuffer(N)` — N is a comptime size; emit the backing buffer first
                // so genAllocatorSourceInit can reference &_fba_backing_{depth}.
                const fb_args = s.source.call.args;
                try ig.writeIndent(); try ig.w.print("var _fba_backing_{d}: [", .{depth});
                if (fb_args.len > 0) try ig.genExpr(fb_args[0].value) else try ig.w.writeAll("4096");
                try ig.w.writeAll("]u8 = undefined;\n");
                try ig.writeIndent(); try ig.w.print("var _alloc_src_{d} = std.heap.FixedBufferAllocator.init(&_fba_backing_{d});\n", .{ depth, depth });
            } else {
                try ig.writeIndent(); try ig.w.print("var _alloc_src_{d} = ", .{depth});
                try ig.genAllocatorSourceInit(s.source);
                try ig.w.writeAll(";\n");
            }
            try ig.writeIndent(); try ig.w.print("const _parent_alloc_{d} = _allocator;\n", .{depth});
            const getter: []const u8 = if (kind == .stack_fallback) ".get()" else ".allocator()";
            try ig.writeIndent(); try ig.w.print("_allocator = _alloc_src_{d}{s};\n", .{ depth, getter });
            switch (kind) {
                .fixed_buffer, .stack_fallback => {
                    // Stack-allocated source: no deinit needed; restore _allocator only.
                    try ig.writeIndent(); try ig.w.print("defer _allocator = _parent_alloc_{d};\n", .{depth});
                },
                .debug => {
                    // deinit() returns Check; assert .ok so leaks are caught in debug builds.
                    try ig.writeIndent(); try ig.w.print("defer {{ _allocator = _parent_alloc_{d}; std.debug.assert(_alloc_src_{d}.deinit() == .ok); }}\n", .{ depth, depth });
                },
                .arena, .user => {
                    try ig.writeIndent(); try ig.w.print("defer {{ _allocator = _parent_alloc_{d}; _alloc_src_{d}.deinit(); }}\n", .{ depth, depth });
                },
            }
        } else {
            // Borrow: source is a plain Allocator (user expr or intercepted singleton)
            try ig.writeIndent(); try ig.w.print("const _parent_alloc_{d} = _allocator;\n", .{depth});
            try ig.writeIndent(); try ig.w.writeAll("_allocator = ");
            try ig.genAllocatorSourceInit(s.source);
            try ig.w.writeAll(";\n");
            try ig.writeIndent(); try ig.w.print("defer _allocator = _parent_alloc_{d};\n", .{depth});
        }

        try ig.genStmts(s.body);
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    fn isCopyByValueType(t: TypeChecker.Type) bool {
        return switch (t) {
            .int, .uint, .float, .bool, .char, .void_, .int_n, .uint_n, .float_n, .simd => true,
            else => false,
        };
    }

    /// `lhs <- rhs` — copy-out across an `allocate` block boundary.
    ///
    /// Inside a scoped `allocate` block (arena_depth > 0):
    ///   - str → dupe into parent allocator (handles *const[N:0]u8 literal coercion)
    ///   - List/class/other heap types → _zbr_deep_copy into parent allocator
    ///   - primitives (int/float/bool/char) → plain assignment (value types, no heap)
    /// Outside a scoped block, `<-` degenerates to a plain assignment.
    fn genCopyOut(g: Generator, s: *Ast.StmtCopyOut) anyerror!void {
        // Type-driven channel disambiguation: check declared types of LHS and RHS.
        if (g.getExprDeclaredType(s.target)) |tr| {
            if (tr == .generic and std.mem.eql(u8, tr.generic.name, "Chan")) {
                try g.writeIndent();
                try g.genExpr(s.target);
                try g.w.writeAll(".send(");
                try g.genExpr(s.value);
                try g.w.writeAll(");\n");
                return;
            }
        }
        if (g.getExprDeclaredType(s.value)) |tr| {
            if (tr == .generic and std.mem.eql(u8, tr.generic.name, "Chan")) {
                try g.writeIndent();
                try g.genExpr(s.target);
                try g.w.writeAll(" = ");
                try g.genExpr(s.value);
                try g.w.writeAll(".recv();\n");
                return;
            }
        }
        const rhs_type = if (g.tc) |tc| (tc.expr_types.get(s.value) orelse .unknown) else .unknown;
        const is_str = rhs_type == .string;
        const depth  = g.arena_depth;

        if (depth > 0 and !isCopyByValueType(rhs_type)) {
            const uid = g.nextUid();
            try g.writeIndent();
            if (is_str) {
                // Explicit []const u8 annotation coerces string literals (*const[N:0]u8 → []const u8).
                try g.w.print("const _co_{x}: []const u8 = ", .{uid});
                try g.genExpr(s.value);
                try g.w.writeAll(";\n");
                try g.writeIndent();
                try g.genExpr(s.target);
                try g.w.print(" = _parent_alloc_{d}.dupe(u8, _co_{x}) catch _co_{x};\n", .{ depth, uid, uid });
            } else {
                try g.w.print("const _co_{x} = ", .{uid});
                try g.genExpr(s.value);
                try g.w.writeAll(";\n");
                try g.writeIndent();
                try g.genExpr(s.target);
                try g.w.print(" = _zbr_deep_copy(@TypeOf(_co_{x}), _parent_alloc_{d}, _co_{x}, 0) catch @panic(\"OOM copy-out\");\n", .{ uid, depth, uid });
            }
        } else {
            // Outside arena or primitive: plain assignment — no heap involved.
            try g.writeIndent();
            try g.genExpr(s.target);
            try g.w.writeAll(" = ");
            try g.genExpr(s.value);
            try g.w.writeAll(";\n");
        }
    }

    /// If `expr` is a zero-arg call whose callee name matches the generic type
    /// in `type_hint`, emit a typed stdlib init (e.g. `std.StringHashMap([]const u8).init(_allocator)`).
    /// Otherwise emit via `genExpr`. Used at struct literal fields, cue-init args,
    /// and except-field values to avoid the dumb i64/anytype fallback.
    fn genTypedOrExpr(g: Generator, expr: *const Ast.Expr, type_hint: ?Ast.TypeRef) anyerror!void {
        if (type_hint) |tr| {
            if (tr == .generic) {
                const gtr = tr.generic;
                if (expr.* == .call) {
                    const call = expr.call;
                    if (call.args.len == 0 and call.callee.* == .ident and
                        std.mem.eql(u8, call.callee.ident.name, gtr.name))
                    {
                        try g.genStdlibInit(gtr);
                        return;
                    }
                }
            }
        }
        try g.genExpr(expr);
    }

    /// Emit the value expression for a single `except` field.
    fn genExceptFieldValue(g: Generator, f: Ast.ExceptField) anyerror!void {
        const gtr = g.resolveFieldGenericTypeRef(f.name);
        const hint: ?Ast.TypeRef = if (gtr) |r| .{ .generic = r } else null;
        try g.genTypedOrExpr(f.value, hint);
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
            try ig.genExceptFieldValue(f);
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
            try ig.genExceptFieldValue(f);
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
        // already unconditionally transfers control:
        //   - raise    → break + err recorded (already handled by genRaise)
        //   - return_  → function return (no break needed; success path exits directly)
        const last_stmt_tag: ?std.meta.Tag(Ast.Stmt) = if (s.body.len > 0) s.body[s.body.len - 1] else null;
        const body_ends_in_jump = last_stmt_tag == .raise or last_stmt_tag == .return_;
        const body_ends_in_return = last_stmt_tag == .return_;
        if (!body_ends_in_jump) {
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
        // When the success path always returns (body_ends_in_return), after the
        // block we are guaranteed to be on the error path.  The catch if-block
        // above handles it, so the fall-through is unreachable — tell Zig so it
        // doesn't emit "function with non-void return type implicitly returns".
        if (body_ends_in_return) {
            try g.writeIndent();
            try g.w.writeAll("unreachable;\n");
        }

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
                // TC-type fallback for List/HashMap/str len/count on unannotated vars.
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
                    // str.len on unannotated vars (e.g. for-in loop vars from List(str))
                    if (obj_tc == .string and std.mem.eql(u8, e.member, "len")) {
                        try g.w.writeAll("@as(i64, @intCast(");
                        try g.genExpr(e.object);
                        try g.w.writeAll(".len))");
                        break :sw;
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
                // Math constants: Math.PI, Math.E, Math.TAU, Math.INF, Math.NAN, Math.PHI, etc.
                if (e.object.* == .ident and std.mem.eql(u8, e.object.ident.name, "Math")) {
                    if (std.mem.eql(u8, e.member, "PI"))    { try g.w.writeAll("std.math.pi");      break :sw; }
                    if (std.mem.eql(u8, e.member, "E"))     { try g.w.writeAll("std.math.e");       break :sw; }
                    if (std.mem.eql(u8, e.member, "TAU"))   { try g.w.writeAll("std.math.tau");     break :sw; }
                    if (std.mem.eql(u8, e.member, "INF"))   { try g.w.writeAll("std.math.inf(f64)"); break :sw; }
                    if (std.mem.eql(u8, e.member, "NAN"))   { try g.w.writeAll("std.math.nan(f64)"); break :sw; }
                    if (std.mem.eql(u8, e.member, "PHI"))   { try g.w.writeAll("std.math.phi");     break :sw; }
                    if (std.mem.eql(u8, e.member, "SQRT2")) { try g.w.writeAll("std.math.sqrt2");   break :sw; }
                    if (std.mem.eql(u8, e.member, "LN2"))   { try g.w.writeAll("std.math.ln2");     break :sw; }
                    if (std.mem.eql(u8, e.member, "LN10"))  { try g.w.writeAll("std.math.ln10");    break :sw; }
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
                    try g.w.writeAll("std.ArrayList([]const u8).empty");
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
                    try g.w.print("var _ll_{x}: std.ArrayList({s}) = std.ArrayList({s}).empty; ", .{ uid, elem_zig, elem_zig });
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
            .result_ => {
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

            // `a < b < c` — chained comparison.
            // Emits a labeled block that captures each middle operand in a temp
            // const so each expression is evaluated exactly once (Python semantics).
            // Pattern: (_cchain_N: { const _cm0_N = b; break :_cchain_N (_zebra_lt(a, _cm0_N) and _zebra_lt(_cm0_N, c)); })
            .chained_cmp => |cc| {
                const uid = g.nextUid();
                const n = cc.ops.len; // number of operator/pair slots
                // Open labeled block
                try g.w.print("(_cchain_{d}: {{", .{uid});
                // Declare temps for each middle operand (indices 1..n-1 of operands)
                for (0..n - 1) |i| {
                    try g.w.print("const _cm{d}_{d} = ", .{i, uid});
                    try g.genExpr(cc.operands[i + 1]);
                    try g.w.writeAll("; ");
                }
                try g.w.print("break :_cchain_{d} (", .{uid});
                for (0..n) |i| {
                    if (i > 0) try g.w.writeAll(" and ");
                    const op = cc.ops[i];
                    switch (op) {
                        .lt, .le, .gt, .ge => {
                            const helper: []const u8 = switch (op) {
                                .lt => "_zebra_lt", .le => "_zebra_le",
                                .gt => "_zebra_gt", .ge => "_zebra_ge",
                                else => unreachable,
                            };
                            try g.w.writeAll(helper);
                            try g.w.writeAll("(");
                            if (i == 0) try g.genExpr(cc.operands[0])
                            else        try g.w.print("_cm{d}_{d}", .{i - 1, uid});
                            try g.w.writeAll(", ");
                            if (i == n - 1) try g.genExpr(cc.operands[n])
                            else            try g.w.print("_cm{d}_{d}", .{i, uid});
                            try g.w.writeAll(")");
                        },
                        .eq, .ne => {
                            // Use _zebra_eq/_zebra_ne helpers so string equality works correctly.
                            const helper: []const u8 = if (op == .eq) "_zebra_eq" else "_zebra_ne";
                            try g.w.writeAll(helper);
                            try g.w.writeAll("(");
                            if (i == 0) try g.genExpr(cc.operands[0])
                            else        try g.w.print("_cm{d}_{d}", .{i - 1, uid});
                            try g.w.writeAll(", ");
                            if (i == n - 1) try g.genExpr(cc.operands[n])
                            else            try g.w.print("_cm{d}_{d}", .{i, uid});
                            try g.w.writeAll(")");
                        },
                        else => unreachable,
                    }
                }
                try g.w.writeAll("); })");
            },

            // `expr?.member` / `expr?.method(args)` — nil-propagating optional access.
            // Member: (if (base) |_oc_N| _oc_N.member else null)
            // Method: (if (base) |_oc_val_N| _oc_blk_N: { var _oc_N = _oc_val_N; break :_oc_blk_N _oc_N.method(args); } else null)
            // The method path uses a mutable local copy so `self: *T` receives a non-const pointer.
            .opt_chain => |e| {
                const uid = g.nextUid();
                try g.w.writeAll("(if (");
                try g.genExpr(e.base);
                if (e.args) |args| {
                    try g.w.print(") |_oc_val_{d}| _oc_blk_{d}: {{ var _oc_{d} = _oc_val_{d}; break :_oc_blk_{d} _oc_{d}.{s}(", .{uid, uid, uid, uid, uid, uid, e.member});
                    for (args, 0..) |a, i| {
                        if (i > 0) try g.w.writeAll(", ");
                        if (a.name) |nm| try g.w.print(".{s} = ", .{nm});
                        try g.genExpr(a.value);
                    }
                    try g.w.print("); }} else null)", .{});
                } else {
                    try g.w.print(") |_oc_{d}| _oc_{d}.{s} else null)", .{uid, uid, e.member});
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
        // BUG-137: a reference that resolves to a module-level var → the prefixed
        // file-scope name emitted by genTopVar.  Checked before in_method/self
        // logic and regardless of scope (top-level `def` bodies and class methods
        // alike).  Sound per-reference: a shadowing local/param resolves to its
        // own symbol here, not the top-level var, so it keeps its bare name.
        if (g.resolve.exprs.get(e)) |sym| {
            if (sym.kind == .var_ and sym.decl.var_.is_top_level) {
                try g.w.print("{s}{s}", .{ module_var_prefix, e.name });
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
        try g.genType(payload);
        try g.w.print(") catch @panic(\"OOM\"); _bp_{x}.* = ", .{uid});
        try g.genArgExpr(expr);
        try g.w.print("; break :{s} _bp_{x}; }}", .{ lbl, uid });
    }

    /// BUG-097: true iff `expr` is a bare identifier that appears in `cpp`
    /// (the set of caller params emitted as `*ArrayList`).
    fn argIdentInCpp(expr: *const Ast.Expr, cpp: ?*const std.StringHashMap(void)) bool {
        const c = cpp orelse return false;
        switch (expr.*) {
            .ident => |id| return c.contains(id.name),
            else   => return false,
        }
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
        const needs_defaults = if (params) |ps| args.len < ps.len else false;
        if (!has_named and !needs_defaults) {
            for (args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                // Box the arg if the corresponding param is ^T.
                if (params) |ps| {
                    if (i < ps.len) {
                        if (ps[i].type_) |pt| if (pt == .ref_to) {
                            try g.genBoxedArgExpr(a.value, pt.ref_to.*);
                            continue;
                        };
                        // BUG-091/097: addr-of, pass-through, or deref for container params.
                        if (paramNeedsAddrOf(ps[i], body, g.alloc, g.tc)) {
                            if (argIdentInCpp(a.value, g.caller_ptr_params)) {
                                // Case 1: arg is already *ArrayList, callee wants *ArrayList.
                                try g.genArgExpr(a.value);
                            } else {
                                try g.w.writeAll("&");
                                try g.genArgExpr(a.value);
                            }
                            continue;
                        }
                        // Case 2: arg is *ArrayList but callee wants plain ArrayList → deref.
                        const ps_i_is_container = if (ps[i].type_) |pt| isContainerType(pt) else false;
                        if (ps_i_is_container and argIdentInCpp(a.value, g.caller_ptr_params)) {
                            try g.genArgExpr(a.value);
                            try g.w.writeAll(".*");
                            continue;
                        }
                    }
                }
                // Use param type hint for zero-arg generic ctors.
                const pt_positional: ?Ast.TypeRef = if (params) |ps| (if (i < ps.len) ps[i].type_ else null) else null;
                try g.genTypedOrExpr(a.value, pt_positional);
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
                const param_is_container = if (i < ps.len) if (ps[i].type_) |pt| isContainerType(pt) else false else false;
                if (maybe_expr) |expr| {
                    if (param_is_ref) {
                        try g.genBoxedArgExpr(expr, ps[i].type_.?.ref_to.*);
                    } else if (param_needs_addr) {
                        if (argIdentInCpp(expr, g.caller_ptr_params)) {
                            // Case 1: arg is already *ArrayList, callee wants *ArrayList.
                            try g.genArgExpr(expr);
                        } else {
                            try g.w.writeAll("&");
                            try g.genArgExpr(expr);
                        }
                    } else if (param_is_container and argIdentInCpp(expr, g.caller_ptr_params)) {
                        // Case 2: arg is *ArrayList but callee wants plain ArrayList → deref.
                        try g.genArgExpr(expr);
                        try g.w.writeAll(".*");
                    } else {
                        // Plain pass-through: use param type hint for zero-arg generic ctors.
                        const param_type: ?Ast.TypeRef = if (i < ps.len) ps[i].type_ else null;
                        try g.genTypedOrExpr(expr, param_type);
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

    /// Gap 1: if `expr` is (or refers to) a capture-block lambda, return its
    /// ExprLambda node so the call site can build a thunk.  Returns null for
    /// non-closure expressions.  Handles:
    ///   - inline lambda:  `connect(def(dt) capture {...} body)`
    ///   - ident:          `var lam = def(...) capture {...} ...; connect(lam)`
    fn closureLambdaFor(g: Generator, expr: *const Ast.Expr) ?*const Ast.ExprLambda {
        if (expr.* == .lambda) {
            if (expr.lambda.capture.len > 0) return expr.lambda;
            return null;
        }
        if (expr.* == .ident) {
            const sym = g.resolve.exprs.get(&expr.ident) orelse return null;
            // Local var declarations: check if init was a capture-block lambda
            if (sym.kind == .local or sym.kind == .var_) {
                switch (sym.decl) {
                    .var_ => |dv| {
                        if (dv.init) |init_expr| {
                            if (init_expr.* == .lambda and init_expr.lambda.capture.len > 0)
                                return init_expr.lambda;
                        }
                    },
                    else => {},
                }
            }
        }
        return null;
    }

    /// Gap 1: emit module-level state slot + dispatcher slot + public thunk
    /// fn for every ClosureThunk collected during call-site emit.  See the
    /// ClosureThunk doc-comment for the runtime shape.
    /// Pool size: how many distinct connections one closure-via-sig call site
    /// supports.  Each needs its own (state slot, thunk fn) pair because a bare
    /// Zig fn-pointer carries no context — so K distinct code addresses are
    /// required (BUG-126).  When a single call site is reached more than K
    /// times in one run (e.g. K+1 scene instances of the same script connecting
    /// to the same signal), the call site panics with a clear message rather
    /// than silently overwriting an earlier connection's state (the old
    /// single-slot behaviour, which dropped all but the last connection).
    const closure_thunk_pool_size = 64;

    fn flushPendingThunks(g: Generator) anyerror!void {
        const K = closure_thunk_pool_size;
        for (g.pending_thunks.items) |t| {
            // Per-call-site pool: K state slots, one shared dispatcher (the
            // closure type is fixed per call site), a monotonic slot counter,
            // and K distinct thunk functions each bound to its own slot.
            try g.w.print("\nvar _zbr_state_{d}: [{d}]?*anyopaque = .{{null}} ** {d};\n", .{ t.id, K, K });
            try g.w.print("var _zbr_dispatch_{d}: ?*const fn(*anyopaque", .{t.id});
            for (t.lambda.params) |p| {
                try g.w.writeAll(", ");
                try g.w.writeAll(p.name);
                try g.w.writeAll(": ");
                if (p.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
            }
            try g.w.writeAll(") ");
            if (t.lambda.return_type) |rt| {
                try g.genType(rt);
            } else {
                try g.w.writeAll("void");
            }
            try g.w.writeAll(" = null;\n");
            try g.w.print("var _zbr_next_{d}: usize = 0;\n", .{t.id});
            // K thunk functions, each closing over a fixed slot index.
            var slot: usize = 0;
            while (slot < K) : (slot += 1) {
                try g.w.print("fn _zbr_thunk_{d}_{d}(", .{ t.id, slot });
                for (t.lambda.params, 0..) |p, pi| {
                    if (pi > 0) try g.w.writeAll(", ");
                    try g.w.writeAll(p.name);
                    try g.w.writeAll(": ");
                    if (p.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
                }
                try g.w.writeAll(") ");
                if (t.lambda.return_type) |rt| {
                    try g.genType(rt);
                } else {
                    try g.w.writeAll("void");
                }
                try g.w.print(" {{\n    if (_zbr_state_{d}[{d}]) |s| _zbr_dispatch_{d}.?(s", .{ t.id, slot, t.id });
                for (t.lambda.params) |p| {
                    try g.w.writeAll(", ");
                    try g.w.writeAll(p.name);
                }
                try g.w.writeAll(");\n}\n");
            }
            // Lookup table of the K thunk fn pointers, indexed by slot.
            try g.w.print("const _zbr_thunks_{d} = [_]*const @TypeOf(_zbr_thunk_{d}_0){{", .{ t.id, t.id });
            slot = 0;
            while (slot < K) : (slot += 1) {
                if (slot > 0) try g.w.writeAll(", ");
                try g.w.print("&_zbr_thunk_{d}_{d}", .{ t.id, slot });
            }
            try g.w.writeAll("};\n");
        }
    }

    /// Emit a call with one or more closure-typed args wrapped in a labeled
    /// block that registers a module-level thunk per closure arg.  See
    /// Gap 1 gate: a capture-block closure passed as a call arg needs the
    /// bare-fn-pointer thunk treatment when its destination is a `sig` (bare
    /// fn-pointer) parameter — those can't carry the closure's captured state,
    /// so we hoist a module-level trampoline.
    ///
    /// In Zebra *user* code a closure value can only be typed through a `sig`
    /// parameter (there is no user-writable `anytype`), so every closure arg to
    /// a user function — same-module *or* cross-module (e.g. `Signal.connect`,
    /// the case Gap 1 exists for) — wants the thunk.  The sole exceptions are
    /// the stdlib builtins that take the closure *struct* directly via `anytype`
    /// dispatch (`sys.go`, `ThreadPool.submit`); those must NOT be thunked, and
    /// are handled by their own stdlib emitters.  A negative gate (thunk unless
    /// a known struct-consumer) is therefore correct and, unlike a param-type
    /// probe, never risks un-thunking an unresolvable cross-module `sig` param.
    fn callNeedsClosureThunks(g: Generator, e: *Ast.ExprCall) bool {
        if (g.isStdlibClosureStructConsumer(e.callee)) return false;
        for (e.args) |a| {
            if (g.closureLambdaFor(a.value) != null) return true;
        }
        return false;
    }

    /// stdlib functions that accept a closure *struct* via `anytype` dispatch
    /// and therefore must never be handed a bare-fn-pointer thunk: `sys.go(...)`
    /// and `<pool: ThreadPool>.submit(...)`.  Detected structurally so the
    /// detection survives even when the receiver's type can't be resolved.
    fn isStdlibClosureStructConsumer(g: Generator, callee: *const Ast.Expr) bool {
        if (callee.* != .member) return false;
        const m = callee.member;
        // sys.go(closure)
        if (std.mem.eql(u8, m.member, "go") and m.object.* == .ident and
            std.mem.eql(u8, m.object.ident.name, "sys")) return true;
        // <ThreadPool>.submit(closure)
        if (std.mem.eql(u8, m.member, "submit")) {
            if (g.getExprDeclaredType(m.object)) |tr| {
                const nm: ?[]const u8 = switch (tr) {
                    .generic => |gt| gt.name,
                    .named   => |nn| nn.name,
                    else     => null,
                };
                if (nm) |n| if (std.mem.eql(u8, n, "ThreadPool")) return true;
            }
        }
        return false;
    }

    /// genCall's Gap 1 dispatch + flushPendingThunks.
    fn emitCallWithClosureThunks(g: Generator, e: *Ast.ExprCall) anyerror!void {
        // Pre-assign thunk IDs and stash specs so the call body can refer to
        // them, and so flushPendingThunks can emit the dispatchers at module
        // end.  Use the existing box_counter for uniqueness across the module.
        const arg_thunk_ids = try g.alloc.alloc(?u32, e.args.len);
        defer g.alloc.free(arg_thunk_ids);
        for (e.args, 0..) |a, i| {
            if (g.closureLambdaFor(a.value)) |lam| {
                const id = g.nextUid();
                try g.pending_thunks.append(g.alloc, .{ .id = id, .lambda = lam });
                arg_thunk_ids[i] = id;
            } else {
                arg_thunk_ids[i] = null;
            }
        }
        // Wrap in `({ ... })` so the block is in expression context — needed
        // because the surrounding Stmt.expr emit follows the call with `;`,
        // and a bare `{ ... };` is a parse error in Zig 0.16 (block as
        // statement doesn't take a trailing `;`).  The parenthesized form
        // makes the block an expression that yields void; `void;` is a
        // valid statement.
        try g.w.writeAll("({\n");
        const bg = g.indented();
        for (e.args, 0..) |a, i| {
            const tid = arg_thunk_ids[i] orelse continue;
            // Use the resolved lambda for sig types; the arg expression (which
            // may be an ident bound to the lambda) is what we instantiate.
            const lam = g.closureLambdaFor(a.value).?;
            // Heap-allocate the closure value and stash a type-erased pointer
            // plus a typed dispatcher into the module-level slots.
            // Emit the closure value ONCE into a local, then derive its type
            // from that local so the create's `@TypeOf` and the assignment use
            // the *same* type.  Re-emitting the `(struct{...}{...})` literal in
            // both places yields two distinct anonymous types and a "expected
            // main__struct_N, found main__struct_M" mismatch for inline
            // capture-lambdas (BUG-131).  (The dispatcher below re-derives the
            // type independently — it's a nested fn that can't see this local —
            // but it only reinterprets the type-erased pointer, and the structs
            // are layout-identical, so that round-trip is sound.)
            try bg.writeIndent();
            try bg.w.print("const _zbr_val_{d} = ", .{tid});
            try bg.genExpr(a.value);
            try bg.w.writeAll(";\n");
            try bg.writeIndent();
            try bg.w.print("const _zbr_cls_{d} = _allocator.create(@TypeOf(_zbr_val_{d})) catch @panic(\"OOM\");\n", .{ tid, tid });
            try bg.writeIndent();
            try bg.w.print("_zbr_cls_{d}.* = _zbr_val_{d};\n", .{ tid, tid });
            // Grab the next pool slot for this connection (BUG-126: per-call
            // state, not a single shared slot).  Overflow → loud panic.
            try bg.writeIndent();
            try bg.w.print("if (_zbr_next_{d} >= {d}) @panic(\"closure-via-sig pool exhausted (>{d} live connections at one call site)\");\n", .{ tid, closure_thunk_pool_size, closure_thunk_pool_size });
            try bg.writeIndent();
            try bg.w.print("const _zbr_slot_{d} = _zbr_next_{d}; _zbr_next_{d} += 1;\n", .{ tid, tid, tid });
            try bg.writeIndent();
            try bg.w.print("_zbr_state_{d}[_zbr_slot_{d}] = @ptrCast(_zbr_cls_{d});\n", .{ tid, tid, tid });
            try bg.writeIndent();
            try bg.w.print("_zbr_dispatch_{d} = (struct {{\n", .{tid});
            const dg = bg.indented();
            try dg.writeIndent();
            try dg.w.writeAll("fn dispatch(ctx: *anyopaque");
            for (lam.params) |p| {
                try dg.w.writeAll(", ");
                try dg.w.writeAll(p.name);
                try dg.w.writeAll(": ");
                if (p.type_) |tr| try dg.genType(tr) else try dg.w.writeAll("anytype");
            }
            try dg.w.writeAll(") ");
            if (lam.return_type) |rt| {
                try dg.genType(rt);
            } else {
                try dg.w.writeAll("void");
            }
            try dg.w.writeAll(" {\n");
            const ig = dg.indented();
            try ig.writeIndent();
            try ig.w.print("const cc: *@TypeOf(", .{});
            try ig.genExpr(a.value);
            try ig.w.writeAll(") = @ptrCast(@alignCast(ctx));\n");
            try ig.writeIndent();
            try ig.w.writeAll("cc.call(");
            for (lam.params, 0..) |p, pi| {
                if (pi > 0) try ig.w.writeAll(", ");
                try ig.w.writeAll(p.name);
            }
            try ig.w.writeAll(");\n");
            try dg.writeIndent();
            try dg.w.writeAll("}\n");
            try bg.writeIndent();
            try bg.w.writeAll("}).dispatch;\n");
        }
        // Emit the actual call with thunk fn pointers in place of closure args.
        try bg.writeIndent();
        try bg.genExpr(e.callee);
        try bg.w.writeAll("(");
        for (e.args, 0..) |a, i| {
            if (i > 0) try bg.w.writeAll(", ");
            if (arg_thunk_ids[i]) |tid| {
                try bg.w.print("_zbr_thunks_{d}[_zbr_slot_{d}]", .{ tid, tid });
            } else {
                try bg.genArgExpr(a.value);
            }
        }
        try bg.w.writeAll(");\n");
        try g.writeIndent();
        try g.w.writeAll("})");
    }

    fn genCall(g: Generator, e: *Ast.ExprCall) anyerror!void {
        // ── Gap 1: closure-via-sig thunking ───────────────────────────────────
        // When any call arg is a closure (either inline capture-block lambda
        // OR an ident bound to such a lambda), hoist a module-level thunk +
        // state slot, then emit the call inside a labeled block that
        // (a) constructs the closure on the heap, (b) stashes pointer +
        // dispatch fn into the slots, (c) calls the target with the public
        // thunk fn pointer in place of the closure.
        // See QUICKSTART §19.1 + docs/CONCERNS.md #3 Gap 1.
        if (g.callNeedsClosureThunks(e)) {
            try g.emitCallWithClosureThunks(e);
            return;
        }
        // ThreadPool(n) plain constructor (no type args) → _thread_pool_create(n)
        if (e.type_args.len == 0 and e.callee.* == .ident and
            std.mem.eql(u8, e.callee.ident.name, "ThreadPool"))
        {
            try g.w.writeAll("_thread_pool_create(");
            if (e.args.len > 0) try g.genExpr(e.args[0].value) else try g.w.writeAll("4");
            try g.w.writeAll(")");
            return;
        }
        // Generic construction: Stack(int)(42) → Stack(i64).init(42)
        // Detected by type_args.len > 0 (set by AstBuilder.buildGenericConstruct).
        if (e.type_args.len > 0 and e.callee.* == .ident) {
            const class_name = e.callee.ident.name;
            // Stdlib generics: Chan(T)(cap) → _chan_create(T, cap)
            if (std.mem.eql(u8, class_name, "Chan") and e.type_args.len == 1) {
                try g.w.writeAll("_chan_create(");
                try g.genType(e.type_args[0]);
                try g.w.writeAll(", ");
                if (e.args.len > 0) try g.genExpr(e.args[0].value) else try g.w.writeAll("0");
                try g.w.writeAll(")");
                return;
            }
            // Atomic(T)(v) → _atomic_create(T, v)
            if (std.mem.eql(u8, class_name, "Atomic") and e.type_args.len == 1) {
                try g.w.writeAll("_atomic_create(");
                try g.genType(e.type_args[0]);
                try g.w.writeAll(", ");
                if (e.args.len > 0) try g.genExpr(e.args[0].value) else try g.w.writeAll("0");
                try g.w.writeAll(")");
                return;
            }
            // ThreadPool(n)(n_threads) → _thread_pool_create(n_threads)
            if (std.mem.eql(u8, class_name, "ThreadPool")) {
                try g.w.writeAll("_thread_pool_create(");
                if (e.args.len > 0) try g.genExpr(e.args[0].value)
                else if (e.type_args.len > 0) try g.genType(e.type_args[0])
                else try g.w.writeAll("4");
                try g.w.writeAll(")");
                return;
            }
            // List(T)() → std.ArrayList(T).empty (allocator passed to each op)
            if (std.mem.eql(u8, class_name, "List") and e.type_args.len == 1) {
                try g.w.writeAll("std.ArrayList(");
                try g.genType(e.type_args[0]);
                try g.w.writeAll(").empty");
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
                            const create_type = if (inner.* == .nilable) inner.nilable.* else inner.*;
                            try g.w.print("{s}: {{ const _bp_{x} = _allocator.create(", .{ box_lbl, uid });
                            try g.genType(create_type);
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
        // Builtin collection constructors: `List()` → `std.ArrayList(...).empty`,
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
                    try g.w.writeAll("std.ArrayList([]const u8).empty");
                }
                return;
            }
            if (std.mem.eql(u8, name, "HashMap")) {
                // No LHS type context — emit anytype so the Zig error points at the
                // missing annotation rather than producing a misleading type mismatch.
                try g.w.writeAll("std.StringHashMap(anytype).init(_allocator)");
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
                try g.w.writeAll("std.ArrayList(u8).empty");
                return;
            }
        }
        // SIMD vector constructor: f32x8(1.0, 2.0, ...) → @as(@Vector(8, f32), .{1.0, 2.0, ...})
        if (e.callee.* == .ident) {
            if (Builtins.parseSimdType(e.callee.ident.name)) |si| {
                try g.w.print("@as(@Vector({d}, {s}), .{{", .{ si.lanes, si.elem_zig });
                for (e.args, 0..) |arg, i| {
                    if (i > 0) try g.w.writeAll(", ");
                    try g.genExpr(arg.value);
                }
                try g.w.writeAll("})");
                return;
            }
        }
        // SIMD static constructors: f32x8.splat(v), f32x8.load(slice)
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident) {
                if (Builtins.parseSimdType(mem.object.ident.name)) |si| {
                    if (try g.genSimdStaticCall(si, mem.member, e.args)) return;
                }
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
                                    // Look up field type from members for typed generic init.
                                    const field_type: ?Ast.TypeRef = blk: {
                                        for (members) |m| {
                                            if (m != .var_) continue;
                                            if (!std.mem.eql(u8, m.var_.name, n)) continue;
                                            break :blk m.var_.type_;
                                        }
                                        break :blk null;
                                    };
                                    try g.genTypedOrExpr(a.value, field_type);
                                } else {
                                    try g.w.writeAll(" ");
                                    try g.genExpr(a.value);
                                }
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
        // Ws static calls: Ws.connect/serve.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Ws")) {
                if (try g.genWsCall(mem.member, e.args)) return;
            }
        }
        // Http static calls: Http.get/post/json/postJson/serve.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Http")) {
                if (try g.genHttpCall(mem.member, e.args)) return;
            }
        }
        // DynLib static calls: DynLib.open(path).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "DynLib")) {
                if (std.mem.eql(u8, mem.member, "open") and e.args.len > 0) {
                    try g.w.writeAll("try _dynlib_open(");
                    try g.genExpr(e.args[0].value);
                    try g.w.writeAll(")");
                    return;
                }
            }
        }
        // DynLib instance methods: lib.close(), lib.lookup(IFace, "sym").
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident) {
                if (g.dynlib_vars.contains(mem.object.ident.name)) {
                    if (try g.genDynLibMethod(mem.object, mem.member, e.args)) return;
                }
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
        // Crypto static calls: Crypto.encrypt(key, plaintext), Crypto.decrypt(key, hex).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Crypto")) {
                if (try g.genCryptoCall(mem.member, e.args)) return;
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
        // Profile static calls: Profile.start/stop/report/dump_folded/reset.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Profile")) {
                if (try g.genProfileCall(mem.member, e.args)) return;
            }
        }
        // Base64 static calls: Base64.encode/decode/encodeUrl/decodeUrl.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Base64")) {
                if (try g.genBase64Call(mem.member, e.args)) return;
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
        // Sqlite static call: Sqlite.open(path).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Sqlite")) {
                if (try g.genSqliteCall(mem.member, e.args)) return;
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
        // Build calls: Build.new() + b.exe/lib/run/dependency.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Build")) {
                if (try g.genBuildMethod(mem.object, mem.member, e.args)) return;
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
                // Classes/structs with a user-defined toString() method — emit as a direct call.
                const has_user_tostring = switch (obj_tc) {
                    .named => |sym| if (sym.own_scope) |sc| sc.lookupLocal("toString") != null else false,
                    .generic_named => |gn| if (gn.sym.own_scope) |sc| sc.lookupLocal("toString") != null else false,
                    else => false,
                };
                if (has_user_tostring) {
                    // Fall through to normal method call codegen below.
                } else if (obj_tc == .named and obj_tc.named.kind == .struct_ and obj_tc.named.decl.struct_.mods.derive_debug) {
                    // @derive(Debug) structs also fall through.
                } else {
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
                    .sqlite_db     => if (try g.genSqliteMethod(mem.object, mem.member, e.args)) return,
                    .sqlite_row    => if (try g.genSqliteRowMethod(mem.object, mem.member, e.args)) return,
                    .regex         => if (try g.genRegexMethod(mem.object, mem.member, e.args)) return,
                    .gui_context   => if (try g.genGuiWidgetMethod(mem.object, mem.member, e.args)) return,
                    .low_level     => if (try g.genLowLevelMethod(mem.object, mem.member, e.args)) return,
                    .build_ctx     => if (try g.genBuildMethod(mem.object, mem.member, e.args)) return,
                    .build_target  => if (try g.genBuildTargetMethod(mem.object, mem.member, e.args)) return,
                    .code_editor   => if (try g.genCodeEditorMethod(mem.object, mem.member, e.args)) return,
                    .str_slice     => if (try g.genStrSliceMethod(mem.object, mem.member, e.args)) return,
                    .json_value    => if (try g.genJsonMethod(mem.object, mem.member, e.args)) return,
                    .date_time     => if (try g.genDateTimeMethod(mem.object, mem.member, e.args)) return,
                    .http_response => if (try g.genHttpResponseMethod(mem.object, mem.member, e.args)) return,
                    .csv_table     => if (try g.genCsvMethod(mem.object, mem.member, e.args)) return,
                    .csv_writer    => if (try g.genCsvWriterMethod(mem.object, mem.member, e.args)) return,
                    .csv_row       => if (try g.genListMethod(mem.object, false, null, mem.member, e.args)) return,
                    .arg_result    => if (try g.genArgResultMethod(mem.object, mem.member, e.args)) return,
                    .timer_handle  => if (try g.genTimerResultMethod(mem.object, mem.member, e.args)) return,
                    .progress_bar  => if (try g.genProgressBarMethod(mem.object, mem.member, e.args)) return,
                    .simd          => if (try g.genSimdInstanceCall(mem.object, mem.member, e.args)) return,
                    .string_builder => if (try g.genStringBuilderMethod(mem.object, mem.member, e.args)) return,
                    .sys_process    => if (try g.genSysProcessMethod(mem.object, mem.member, e.args)) return,
                    .ws_conn        => if (try g.genWsConnMethod(mem.object, mem.member, e.args)) return,
                    .unknown       => if (try g.genListMethod(mem.object, false, null, mem.member, e.args)) return,
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
                // For @derive(Eq) structs, route == / != through the generated eql() method.
                const left_is_eq_struct = blk: {
                    if (either_nil or left_is_str or right_is_str or left_is_union) break :blk false;
                    if (g.tc) |tc| {
                        const t = tc.expr_types.get(e.left) orelse .unknown;
                        if (t == .named and t.named.kind == .struct_) {
                            const decl = t.named.decl.struct_;
                            break :blk decl.mods.derive_eq;
                        }
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
                } else if (left_is_eq_struct) {
                    if (e.op == .ne) try g.w.writeAll("!");
                    try g.genExpr(e.left);
                    try g.w.writeAll(".eql(&");
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
        var fmt_buf = std.ArrayList(u8).empty;
        defer fmt_buf.deinit(g.alloc);

        // Per-arg unsigned cast type (null = no cast needed).
        // Needed when a bit-repr spec (x/X/o/b) is applied to a signed integer:
        // Zig prepends '+' for positive signed ints, which is wrong for hex dumps.
        var cast_types = std.ArrayList(?[]const u8).empty;
        defer cast_types.deinit(g.alloc);

        // Per-arg flag: true when the expr has a named type with toString() —
        // emit `.toString()` call suffix and use {s} format.
        var needs_tostring = std.ArrayList(bool).empty;
        defer needs_tostring.deinit(g.alloc);

        var i: usize = 0;
        while (i < e.parts.len) : (i += 1) {
            switch (e.parts[i]) {
                .literal => |lit| {
                    // Escape `{` and `}` so they don't confuse std.fmt.
                    for (lit) |c| {
                        if (c == '{' or c == '}') {
                            try fmt_buf.append(g.alloc, c);
                            try fmt_buf.append(g.alloc, c);
                        } else {
                            try fmt_buf.append(g.alloc, c);
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
                        try fmt_buf.append(g.alloc, '{');
                        var faw = std.Io.Writer.Allocating.fromArrayList(g.alloc, &fmt_buf);
                        try writeZigFmtSpec(&faw.writer, raw_spec, ex_type);
                        fmt_buf = faw.toArrayList();
                        try fmt_buf.append(g.alloc, '}');
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
                            try fmt_buf.appendSlice(g.alloc, "{s}");
                        } else {
                            const spec = printFmt(g.tc, g.catch_var, ex);
                            try fmt_buf.appendSlice(g.alloc, spec);
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
        var cap_names = std.ArrayList([]const u8).empty;
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
            .alias_applied => |aa| {
                // ThreadPool(n) is a value-parameterized stdlib type — always *_ThreadPool.
                if (std.mem.eql(u8, aa.name, "ThreadPool")) {
                    try g.w.writeAll("*_ThreadPool");
                    return;
                }
                // Value-parameterized alias: emit the base type, same as named alias.
                if (g.type_alias_decls.get(aa.name)) |alias| {
                    try g.genType(alias.base);
                    return;
                }
                try g.w.writeAll(aa.name);
            },
            .named       => |n| {
                // Type alias: emit the base type instead of the alias name.
                if (g.type_alias_decls.get(n.name)) |alias| {
                    try g.genType(alias.base);
                    return;
                }
                // SIMD vector type annotation: f32x8, i16x16, u8x32, etc.
                if (Builtins.parseSimdType(n.name)) |si| {
                    try g.w.print("@Vector({d}, {s})", .{ si.lanes, si.elem_zig });
                    return;
                }
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
                // SysProcess is a heap-allocated struct; emit as pointer.
                if (std.mem.eql(u8, n.name, "SysProcess")) {
                    try g.w.writeAll("*_SysProcess");
                    return;
                }
                // WsConn is a heap-allocated struct; emit as pointer.
                if (std.mem.eql(u8, n.name, "WsConn")) {
                    try g.w.writeAll("*_WsConn");
                    return;
                }
                // DynLib is a heap-allocated struct; emit as pointer.
                if (std.mem.eql(u8, n.name, "DynLib")) {
                    try g.w.writeAll("*_DynLib");
                    return;
                }
                // ThreadPool (plain, no type arg) — heap-allocated worker pool.
                if (std.mem.eql(u8, n.name, "ThreadPool")) {
                    try g.w.writeAll("*_ThreadPool");
                    return;
                }
                // Build system builtins: heap-allocated, emitted as pointers.
                if (std.mem.eql(u8, n.name, "Build")) {
                    try g.w.writeAll("*_Build");
                    return;
                }
                if (std.mem.eql(u8, n.name, "BuildTarget")) {
                    try g.w.writeAll("*_BuildTarget");
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
                // Chan(T) — heap-allocated *_Chan(T) pointer.
                if (std.mem.eql(u8, gtr.name, "Chan")) {
                    try g.w.writeAll("*_Chan(");
                    if (gtr.args.len >= 1) try g.genType(gtr.args[0]) else try g.w.writeAll("anytype");
                    try g.w.writeAll(")");
                    return;
                }
                // Atomic(T) — heap-allocated *_Atomic(T) pointer.
                if (std.mem.eql(u8, gtr.name, "Atomic")) {
                    try g.w.writeAll("*_Atomic(");
                    if (gtr.args.len >= 1) try g.genType(gtr.args[0]) else try g.w.writeAll("anytype");
                    try g.w.writeAll(")");
                    return;
                }
                // ThreadPool(n) — heap-allocated *_ThreadPool pointer (thread count is a runtime value, not a type param).
                if (std.mem.eql(u8, gtr.name, "ThreadPool")) {
                    try g.w.writeAll("*_ThreadPool");
                    return;
                }
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
pub fn generateHeader(module: Ast.Module, writer: *std.Io.Writer) anyerror!void {
    try writer.writeAll("// Auto-generated by the Zebra compiler.  DO NOT EDIT.\n// Source: ");
    try Generator.writePathFwd(writer, module.file);
    try writer.writeAll(
        \\
        \\#pragma once
        \\#include <stdint.h>
        \\#include <stdbool.h>
        \\#include <stddef.h>
        \\
        \\
    );

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
        .void_, .unknown, .context_dependent, .unresolved, .named,
        .string_builder,
        .http_request,
        .http_response,
        .tcp_conn,
        .udp_socket,
        .regex,
        .gui_context,
        .low_level,
        .shell,
        .file,
        .str_slice,
        .sys_run_result,
        .sys_process,
        .json_value,
        .json_array,
        .date_time,
        .calendar_view,
        .csv_table,
        .csv_writer,
        .csv_row,
        .sqlite_db,
        .sqlite_row,
        .arg_result,
        .uri_result,
        .timer_handle,
        .progress_bar,
        .code_editor,
        .allocator_ctx,
        .build_ctx,
        .build_target,
        .ws_conn,
        .simd,
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
        .allocator_ctx  => "std.mem.Allocator",
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

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var aw = std.Io.Writer.Allocating.fromArrayList(alloc, &out);
    _ = try generate(module, &resolve, null, alloc, &aw.writer, .stub, null, false, null, false, false, false, false, null);
    out = aw.toArrayList();
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
