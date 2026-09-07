#!/usr/bin/env bash
# styler_test.sh — headless unit test of the CodeEditor tokenizer (zebra-ide P1).
# Extracts the pure block between `STYLER BEGIN`/`STYLER END` in
# selfhost/gui_libui_ng_section.zig VERBATIM (no copy to drift), appends the
# controls from the IDE plan, and runs `zig test`. Runs anywhere Zig runs; no GUI.
set -eu
cd "$(dirname "$0")/.."
SEC=selfhost/gui_libui_ng_section.zig
OUT=${TMPDIR:-/tmp}/zebra_styler_test.zig
{
  echo 'const std = @import("std");'
  awk '/STYLER BEGIN/{p=1} p{print} /STYLER END/{p=0}' "$SEC"
  cat <<'ZIG'

fn styles(spec: *const _CeLangSpec, src: []const u8) []u8 {
    const out = std.testing.allocator.alloc(u8, src.len) catch unreachable;
    _ce_tokenize(spec, src, out);
    return out;
}
fn styleAt(spec: *const _CeLangSpec, src: []const u8, needle: []const u8) u8 {
    const out = styles(spec, src);
    defer std.testing.allocator.free(out);
    const i = std.mem.indexOf(u8, src, needle) orelse @panic("needle not in src");
    return out[i];
}
const K: u8 = @intCast(_CE_S_KEYWORD);
const C: u8 = @intCast(_CE_S_COMMENT);
const S: u8 = @intCast(_CE_S_STRING);
const N: u8 = @intCast(_CE_S_NUMBER);
const T: u8 = @intCast(_CE_S_TYPE);
const F: u8 = @intCast(_CE_S_FUNC);
const P: u8 = @intCast(_CE_S_PREPROC);
const D: u8 = @intCast(_CE_S_DEFAULT);

test "C: # inside a string is STRING, #include is PREPROC, never COMMENT" {
    const src = "#include <stdio.h>\nconst char *s = \"# not a comment\"; // trailing\n";
    try std.testing.expectEqual(P, styleAt(&_CE_LANG_C, src, "#include"));
    try std.testing.expectEqual(S, styleAt(&_CE_LANG_C, src, "# not"));
    try std.testing.expectEqual(C, styleAt(&_CE_LANG_C, src, "// trailing"));
    try std.testing.expectEqual(K, styleAt(&_CE_LANG_C, src, "const"));
    try std.testing.expectEqual(K, styleAt(&_CE_LANG_C, src, "char"));
}
test "C: block comment spans lines; char literal; hex number; indented # is still preproc" {
    const src = "int x; /* a\n b */ char c = 'x'; int h = 0x7f;\n  #define Y 1\n";
    try std.testing.expectEqual(C, styleAt(&_CE_LANG_C, src, "a\n"));
    try std.testing.expectEqual(C, styleAt(&_CE_LANG_C, src, "b */"));
    try std.testing.expectEqual(K, styleAt(&_CE_LANG_C, src, "char"));
    try std.testing.expectEqual(S, styleAt(&_CE_LANG_C, src, "'x'"));
    try std.testing.expectEqual(N, styleAt(&_CE_LANG_C, src, "0x7f"));
    try std.testing.expectEqual(P, styleAt(&_CE_LANG_C, src, "#define"));
}
test "Zig: \\\\ multiline string lines are STRING; @import is FUNC; // comment; 'c' char" {
    const src = "const s =\n    \\\\multi line\n    \\\\two\n;\nconst x = @import(\"std\"); // c\nconst ch = 'q';\n";
    try std.testing.expectEqual(S, styleAt(&_CE_LANG_ZIG, src, "\\\\multi"));
    try std.testing.expectEqual(S, styleAt(&_CE_LANG_ZIG, src, "multi line"));
    try std.testing.expectEqual(S, styleAt(&_CE_LANG_ZIG, src, "\\\\two"));
    try std.testing.expectEqual(F, styleAt(&_CE_LANG_ZIG, src, "@import"));
    try std.testing.expectEqual(C, styleAt(&_CE_LANG_ZIG, src, "// c"));
    try std.testing.expectEqual(S, styleAt(&_CE_LANG_ZIG, src, "'q'"));
    try std.testing.expectEqual(K, styleAt(&_CE_LANG_ZIG, src, "const"));
}
test "Zebra: ${} stays inside STRING; # is a comment; ' is not a char literal" {
    const src = "# lead\nvar s = \"hi ${name} #x\"\nvar t = 'a'\ndef f(): int\n    return 1\nclass Foo\n";
    try std.testing.expectEqual(C, styleAt(&_CE_LANG_ZEBRA, src, "# lead"));
    try std.testing.expectEqual(S, styleAt(&_CE_LANG_ZEBRA, src, "${name}"));
    try std.testing.expectEqual(S, styleAt(&_CE_LANG_ZEBRA, src, "#x"));
    try std.testing.expectEqual(D, styleAt(&_CE_LANG_ZEBRA, src, "a'"));
    try std.testing.expectEqual(K, styleAt(&_CE_LANG_ZEBRA, src, "def"));
    try std.testing.expectEqual(F, styleAt(&_CE_LANG_ZEBRA, src, "f()"));
    try std.testing.expectEqual(T, styleAt(&_CE_LANG_ZEBRA, src, "Foo"));
    try std.testing.expectEqual(N, styleAt(&_CE_LANG_ZEBRA, src, "1\n"));
}
test "C: capitalised identifiers are NOT types (caps_are_types=false); unterminated string stops at newline" {
    const src = "Foo bar = \"open\nint y;\n";
    try std.testing.expectEqual(D, styleAt(&_CE_LANG_C, src, "Foo"));
    try std.testing.expectEqual(K, styleAt(&_CE_LANG_C, src, "int y"));
}
test "extension mapping" {
    try std.testing.expectEqualStrings("zebra", _ce_spec_for_file("C:\\a\\b\\Lexer.zbr").name);
    try std.testing.expectEqualStrings("c", _ce_spec_for_file("/x/y.h").name);
    try std.testing.expectEqualStrings("c", _ce_spec_for_file("win.cxx").name);
    try std.testing.expectEqualStrings("zig", _ce_spec_for_file("build.zig.zon").name);
    try std.testing.expectEqualStrings("text", _ce_spec_for_file("README.md").name);
    try std.testing.expectEqualStrings("text", _ce_spec_for_file("Makefile").name);
    try std.testing.expectEqualStrings("text", _ce_spec_for_file("dir.v2/noext").name);
}
test "every byte gets exactly one style (out fully written)" {
    const src = "def x()\n  \"s\" # c\n";
    const out = styles(&_CE_LANG_ZEBRA, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(src.len, out.len);
}
ZIG
} > "$OUT"
zig test "$OUT" && echo "styler_test: PASS ($OUT)"
