//! Token kinds and source-annotated token structs for the Zebra tokenizer.
//!
//! ## Two-layer design
//!
//! The Earley parser library requires a comptime enum as its Token type.
//! `TokenKind` is that enum.  `Token` is a richer struct that pairs a kind
//! with source-location metadata (file, line, column, and a slice of the
//! original source text).
//!
//! The tokenizer produces `[]Token`.  Before handing the input to the
//! Earley parser, extract the kind array:
//!
//! ```zig
//! const kinds = try Token.kindsOf(tokens, alloc);
//! defer alloc.free(kinds);
//! var result = try parser.parseResult(kinds);
//! ```

// ── TokenKind ─────────────────────────────────────────────────────────────────

/// Every distinct token kind the Zebra tokenizer can produce.
///
/// Order within each group is alphabetical; the grouping mirrors the
/// Zebra tokenizer source.  Keywords appear as their own kinds so that the
/// Earley grammar can reference them directly — no post-processing needed.
pub const TokenKind = enum {

    // ── Structure tokens ───────────────────────────────────────────────────

    /// Increase in indentation (one level).
    indent,
    /// Decrease in indentation (one level per emitted DEDENT).
    dedent,
    /// Newline / end of logical line.
    eol,
    /// End of file.
    eof,

    // ── Identifiers ────────────────────────────────────────────────────────

    /// A plain identifier: `[A-Za-z_][A-Za-z0-9_]*`
    id,
    /// An attribute-style identifier: `@[A-Za-z_][A-Za-z0-9_]*`
    at_id,

    // ── Numeric literals ───────────────────────────────────────────────────

    /// Decimal integer: `42`, `1_000_000`, etc.
    integer_lit,
    /// Explicitly-sized integer: `42_u8`, `255_i16`, etc.
    integer_lit_explicit,
    /// Hex literal: `0xFF`
    hex_lit,
    /// Hex unsigned: `0xFF_u32`
    hex_lit_unsign,
    /// Hex sized: `0xFF_8`
    hex_lit_explicit,
    /// Float literal: `3.14`, `1.0_f32`, `1_f64` (all variants unified)
    float_lit,
    /// Decimal (high-precision): `3.14_d`
    decimal_lit,
    /// Number (default number type): `3.14_n`
    number_lit,
    /// Sized int type name: `int32`, `int64`, `int128`
    int_size,
    /// Sized uint type name: `uint8`, `uint64`
    uint_size,
    /// Sized float type name: `float32`, `float64`
    float_size,

    // ── Character literals ─────────────────────────────────────────────────

    /// Single-quoted char: `c'x'`
    char_lit_single,
    /// Double-quoted char: `c"x"`
    char_lit_double,

    // ── String literals ────────────────────────────────────────────────────

    /// Plain single-quoted string: `'hello'`
    string_single,
    /// Plain double-quoted string: `"hello"`
    string_double,
    /// Non-substituted single-quoted: `ns'hello'`
    string_nosub_single,
    /// Non-substituted double-quoted: `ns"hello"`
    string_nosub_double,
    /// Raw (no-escape) single-quoted: `r'hello'`
    string_raw_single,
    /// Raw double-quoted: `r"hello"`
    string_raw_double,
    /// Start of interpolated single-quoted string: `'hello ${
    string_start_single,
    /// Literal part inside interpolated string
    string_part_single,
    /// End of interpolated single-quoted string
    string_stop_single,
    /// Start of interpolated double-quoted string
    string_start_double,
    string_part_double,
    string_stop_double,
    /// Format spec inside interpolation: `:06.2f`
    string_part_format,
    /// `}` that closes a `${...}` interpolation expression
    rcurly_special,
    /// Backend (Zig) literal single-quoted: `zig'...'`
    zig_single,
    /// Backend (Zig) literal double-quoted: `zig"..."`
    zig_double,
    /// Doc-string start: triple-quote on its own line
    doc_string_start,
    /// Doc-string single line: `"""..."""`
    doc_string_line,

    // ── Operators and punctuation ──────────────────────────────────────────

    dot,           // .
    dotdot,        // ..
    colon,         // :
    semi,          // ;
    comma,         // ,
    lparen,        // (
    rparen,        // )
    lbracket,      // [
    rbracket,      // ]
    lcurly,        // {
    rcurly,        // }
    at_lbracket,   // @[  (array literal open)

    plus,          // +
    plusplus,      // ++
    minus,         // -
    minusminus,    // --
    arrow,         // ->
    left_arrow,    // <- (channel send/recv)
    left_arrow_deep, // <<- (arena deep copy-out; §28d 2026-07-02 — was <-)
    star,          // *
    starstar,      // **
    slash,         // /
    slashslash,    // //
    percent,       // %
    percentpercent,// %%
    ampersand,     // &
    vertical_bar,  // |
    caret,         // ^
    tilde,         // ~
    question,      // ?
    question_dot,  // ?.  (optional-chain access)
    bang,          // !
    double_lt,     // <<
    double_gt,     // >>

    assign,        // =
    eq,            // ==
    ne,            // <>
    lt,            // <
    gt,            // >
    le,            // <=
    ge,            // >=

    plus_equals,          // +=
    minus_equals,         // -=
    star_equals,          // *=
    slash_equals,         // /=
    slashslash_equals,    // //=
    percent_equals,       // %=
    starstar_equals,      // **=
    ampersand_equals,     // &=
    vertical_bar_equals,  // |=
    caret_equals,         // ^=
    double_lt_equals,     // <<=
    double_gt_equals,     // >>=
    question_equals,      // ?=
    bang_equals,          // !=

    /// `identifier(` — identifier immediately followed by `(`, no space.
    /// Signals a call vs. a reference.
    open_call,

    // ── Keywords ───────────────────────────────────────────────────────────
    //
    // Grouped by category, matching KeywordSpecs.rawSpecs.

    // Module / namespace
    kw_use,
    kw_exposing,
    kw_namespace,

    // Type declarations
    kw_class,
    kw_interface,
    kw_mixin,
    kw_struct,
    kw_enum,
    kw_extend,

    // Member declarations
    kw_def,
    kw_sig,
    kw_type,
    kw_var,
    kw_const,
    kw_cue,
    kw_test,

    // Declaration keywords
    kw_implements,
    kw_adds,
    kw_is,
    kw_as,
    kw_has,
    kw_static,
    kw_invariant,
    kw_where,

    // Modifiers
    kw_abstract,
    kw_export,
    kw_extern,
    kw_public,
    kw_private,
    kw_readonly,

    // Built-in types
    kw_bool,
    kw_char,
    kw_int,
    kw_uint,
    kw_float,
    kw_same,

    // Contracts
    kw_require,
    kw_ensure,
    kw_old,
    kw_result,
    kw_implies,

    // Statements
    kw_assert,
    kw_assert_eq,
    kw_assert_ne,
    kw_assert_true,
    kw_assert_false,
    kw_branch,
    kw_on,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_break,
    kw_continue,
    kw_pass,
    kw_print,
    kw_stop,
    kw_return,
    kw_defer,     // defer stmt — run on scope exit
    kw_errdefer,  // errdefer stmt — run only on error exit

    // Expressions
    kw_this,
    kw_to,
    kw_and,
    kw_or,
    kw_not,
    kw_in,
    kw_using,     // using EXPR — resource scope block (begin/end lifecycle)
    kw_orelse,    // expr orelse fallback — optional/error unwrap with fallback
    kw_catch,     // expr catch fallback — error union fallback (with optional binding)
    kw_true,
    kw_false,
    kw_nil,

    // Argument modifiers
    kw_vari,

    // Aspect-oriented programming
    // NEXT_STEPS U4: `kw_aspect` removed 2026-08-09. AOP was never implemented —
    // AstBuilder panicked "aspect declarations are not yet implemented" — so the
    // keyword's only live effect was to block `aspect` as an identifier, which it
    // is in the wild (a DB column name, a parameter name). If AOP is ever built,
    // `@aspect` matches @reflectable/@once and needs no reserved word.
    // U4a 2026-08-09: kw_weaves removed with kw_aspect. `@weaves` if AOP is ever
    // built. `implies` is the ONLY reserved-but-unimplemented word kept (Sean's
    // call) -- it is intended as a contract operator, `a implies b`.

    // U4a tail 2026-08-13: kw_error and kw_try are GONE. Both were reserved and
    // consumed by no rule in either compiler -- `error`'s only grammar uses were the
    // `on error(e)` advice clauses inside an aspect body, orphaned when kw_aspect was
    // removed; `try` lost its construct when Section 28b replaced `try expr` with
    // `expr?`. What survives is the method-level `catch |e|` clause, which synthesises
    // Ast.StmtTryCatch without any `try` token.
    // They waited on the EMIT, not on the parse: freeing a word the codegen cannot
    // spell trades a clear Zebra diagnostic for a Zig error against generated code.
    // That cleared with BUG-280's field paths plus the isZigKeyword oracle
    // (tools/lint_zig_keywords.py), which is what made this safe to do.

    // Closures / contextual self / struct update
    kw_capture,   // capture block — explicit closure state declaration
    kw_with,      // with obj — contextual self block
    kw_except,    // original except field = val — struct update expression

    // Discriminated union types
    kw_union,     // union type declaration

    // Scoped arena allocation
    kw_arena,     // arena block — creates a sub-arena that frees all allocations on exit
    kw_allocate,  // allocate <expr> block — redirect _allocator for the duration of the block

    // Guard statements
    kw_guard,     // guard cond else stmt/block — early-exit pattern

    // Error propagation
    kw_raise,     // raise an error (with optional details)
    kw_throws,    // method annotation — method may propagate errors

};

// ── Keyword table ─────────────────────────────────────────────────────────────

/// Maps keyword strings to their `TokenKind`.  Used by the tokenizer to
/// distinguish identifiers from keywords in O(1) via hash lookup.
pub const keyword_map = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "use",         .kw_use },
    .{ "exposing",    .kw_exposing },
    .{ "namespace",   .kw_namespace },
    .{ "class",       .kw_class },
    .{ "interface",   .kw_interface },
    .{ "mixin",       .kw_mixin },
    .{ "struct",      .kw_struct },
    .{ "enum",        .kw_enum },
    .{ "extend",      .kw_extend },
    .{ "def",         .kw_def },
    .{ "sig",         .kw_sig },
    .{ "type",        .kw_type },
    .{ "var",         .kw_var },
    .{ "const",       .kw_const },
    .{ "cue",         .kw_cue },
    .{ "test",        .kw_test },
    .{ "implements",  .kw_implements },
    .{ "adds",        .kw_adds },
    .{ "is",          .kw_is },
    .{ "as",          .kw_as },
    .{ "has",         .kw_has },
    .{ "static",      .kw_static },
    .{ "invariant",   .kw_invariant },
    .{ "export",      .kw_export },
    .{ "extern",      .kw_extern },
    // no "internal": BUG-316. It named a real middle visibility level (hidden
    // cross-module, visible within the module -- pub(crate) / package-private), but
    // the two compilers disagreed about it, it was NEVER used in any commit in the
    // whole history, and 32k lines of multi-module Zebra in selfhost/ never needed it.
    // Removed 2026-08-29 rather than fixed. If module-scoped visibility comes back,
    // design it once and implement it in the SELFHOST -- shipping it in one compiler
    // and not the other is what made it a divergence instead of a feature.
    .{ "public",      .kw_public },
    .{ "private",     .kw_private },
    // no "protected": BUG-315. It was a synonym for `private` and its documented
    // meaning ("the class and subclasses") needs inheritance this language does not
    // have. Do not re-add without a hierarchy to justify it.
    .{ "bool",        .kw_bool },
    .{ "char",        .kw_char },
    .{ "int",         .kw_int },
    .{ "uint",        .kw_uint },
    .{ "float",       .kw_float },
    .{ "same",        .kw_same },
    .{ "require",     .kw_require },
    .{ "ensure",      .kw_ensure },
    // "old" and "result" are context-sensitive: emitted as kw_old/kw_result only
    // inside ensure blocks by Tokenizer. They are NOT in the keyword map.
    .{ "implies",     .kw_implies },
    .{ "assert",       .kw_assert },
    .{ "branch",       .kw_branch },
    .{ "on",          .kw_on },
    .{ "if",          .kw_if },
    .{ "else",        .kw_else },
    .{ "while",       .kw_while },
    .{ "for",         .kw_for },
    .{ "break",       .kw_break },
    .{ "continue",    .kw_continue },
    .{ "pass",        .kw_pass },
    .{ "print",       .kw_print },
    // `stop` is intentionally NOT reserved: kw_stop is unused by the parser and
    // `stop` is an extremely common method name (Sound/Animation/Tween :Stop()).
    // Reserving it broke `.stop()` calls — tokenize it as a plain identifier.
    .{ "return",      .kw_return },
    // `defer` / `errdefer` FREED 2026-09-15 (Sean). Fully implemented here, never parsed
    // by the shipping selfhost -- a reserved word that did nothing for users. The
    // kw_ variants, StmtDefer rules and genDefer stay as dead code until this compiler
    // retires; only the WORDS leave the table, so both lex as identifiers.
    .{ "this",        .kw_this },
    .{ "to",          .kw_to },
    .{ "and",         .kw_and },
    .{ "or",          .kw_or },
    .{ "not",         .kw_not },
    .{ "in",          .kw_in },
    .{ "using",       .kw_using },
    .{ "orelse",      .kw_orelse },
    .{ "catch",       .kw_catch },
    .{ "true",        .kw_true },
    .{ "false",       .kw_false },
    .{ "nil",         .kw_nil },
    .{ "capture",     .kw_capture },
    .{ "with",        .kw_with },
    .{ "except",      .kw_except },
    .{ "union",       .kw_union  },
    .{ "raise",       .kw_raise  },
    .{ "throws",      .kw_throws },
    .{ "where",       .kw_where  },
    .{ "allocate",    .kw_allocate  },
});

// ── Token (source-annotated) ──────────────────────────────────────────────────

/// A token with source-location metadata.
///
/// The `text` slice points into the original source string; it is valid for
/// the lifetime of the source buffer.  The `Token` struct itself is 24 bytes
/// on 64-bit targets.
pub const Token = struct {
    kind:  TokenKind,
    /// The exact text of the token in the source file.
    text:  []const u8,
    /// 1-based line number.
    line:  u32,
    /// 1-based column number of the first character.
    col:   u16,

    /// Convenience: is this token a keyword?
    pub fn isKeyword(self: Token) bool {
        return @intFromEnum(self.kind) >= @intFromEnum(TokenKind.kw_use);
    }

    /// Convenience: is this token an identifier or keyword?
    pub fn isName(self: Token) bool {
        return self.kind == .id or self.isKeyword();
    }
};

// ── Kind extraction ───────────────────────────────────────────────────────────

/// Extract just the `TokenKind` values from a token slice into a new allocation.
///
/// The result is sized for the Earley parser: `parser.parseResult(kinds)`.
/// Caller owns the returned slice.
pub fn kindsOf(tokens: []const Token, alloc: @import("std").mem.Allocator) ![]const TokenKind {
    const out = try alloc.alloc(TokenKind, tokens.len);
    for (tokens, 0..) |tok, i| out[i] = tok.kind;
    return out;
}

// ── Imports ───────────────────────────────────────────────────────────────────

const std = @import("std");
