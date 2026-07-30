# `str` ownership per operation (§28e)

**GENERATED** by `tools/str_ownership_extract.py` from real compiler emit — do not hand-edit. Regenerate after any change to string codegen; a flipped ownership shows up as a changed snippet.

**BORROW** = the result aliases the receiver's bytes; it dies when the receiver does, and it is not safe to keep past an `allocate` scope that owns the receiver.

**OWN** = freshly allocated in the program arena (`_allocator`); independent of the receiver's lifetime.

**VALUE** = a byte or codepoint, not a slice. Aliases nothing, so neither borrow nor own applies.

| operation | result | elements | emitted Zig | note |
|---|---|---|---|---|
| `s[1..4]` | **BORROW** | — | `s[@as(usize, @intCast(1))..@as(usize, @intCast(4))]` | slicing syntax, not a method |
| `s.substring(0, 3)` | **BORROW** | — | `s[@intCast(0)..@intCast(3)]` |  |
| `s.toString()` | **BORROW** | — | `s` | str receiver (identity-ish) |
| `s.trim()` | **BORROW** | — | `std.mem.trim(u8, s, " \t\n\r")` |  |
| `s.trimLeft()` | **BORROW** | — | `std.mem.trimStart(u8, s, &std.ascii.whitespace)` |  |
| `s.trimRight()` | **BORROW** | — | `std.mem.trimEnd(u8, s, &std.ascii.whitespace)` |  |
| `s.center(20, " ")` | **OWN** | — | `_pad_center(s, @as(usize, @intCast(20)), " ", _zbr_rt._allocator)` |  |
| `s.concat("!")` | **OWN** | — | `(std.mem.concat(_zbr_rt._allocator, u8, &.{ s, "!" }) catch @panic(...` |  |
| `b.decodeBase64()` | **OWN** | — | `_base64_decode_str(b)` | receiver must be base64 |
| `s.encodeBase64()` | **OWN** | — | `_base64_encode(s)` |  |
| `f.format(1)` | **OWN** | — | `(std.fmt.allocPrint(_zbr_rt._allocator, f, .{ 1 }) catch @panic("OO...` | variadic; see BUG-224 for 2+ args |
| `h.fromHex()` | **OWN** | — | `(blk_fhx: { if (h.len % 2 != 0) break :blk_fhx @as(?[]const u8, nul...` | receiver must be hex digits |
| `parts.join(", ")` | **OWN** | — | `(std.mem.join(_zbr_rt._allocator, ", ", parts.items) catch @panic("...` | called on List(str) |
| `s.lines()` | **OWN** | **BORROW** | `blk_sl_1: { var _ll_1: std.ArrayList([]const u8) = std.ArrayList([]...` |  |
| `s.lower()` | **OWN** | — | `(std.ascii.allocLowerString(_zbr_rt._allocator, s) catch @panic("OO...` |  |
| `s.padLeft(20, " ")` | **OWN** | — | `_pad_left(s, @as(usize, @intCast(20)), " ", _zbr_rt._allocator)` |  |
| `s.padRight(20, " ")` | **OWN** | — | `_pad_right(s, @as(usize, @intCast(20)), " ", _zbr_rt._allocator)` |  |
| `s.repeat(2)` | **OWN** | — | `(blk_rep: { var _rep = std.ArrayList([]const u8).empty; defer _rep....` |  |
| `s.replace("l", "L")` | **OWN** | — | `(std.mem.replaceOwned(u8, _zbr_rt._allocator, s, "l", "L") catch @p...` |  |
| `s.replaceAll("l", "L")` | **OWN** | — | `(std.mem.replaceOwned(u8, _zbr_rt._allocator, s, "l", "L") catch @p...` |  |
| `s.reverse()` | **OWN** | — | `(blk_rev: { const _rbuf = _zbr_rt._allocator.alloc(u8, s.len) catch...` |  |
| `s.split(",")` | **OWN** | **BORROW** | `blk_sl_2: { var _ll_2: std.ArrayList([]const u8) = std.ArrayList([]...` |  |
| `s.toHex()` | **OWN** | — | `(blk_hex: { const _hx_s = s; const _hx_buf = _zbr_rt._allocator.all...` |  |
| `s.tokenize(",")` | **OWN** | **BORROW** | `(blk_tok: { var _tok_it = std.mem.tokenizeSequence(u8, s, ","); var...` |  |
| `s.upper()` | **OWN** | — | `(std.ascii.allocUpperString(_zbr_rt._allocator, s) catch @panic("OO...` |  |
| `s.bytes()` | **UNKNOWN** | — | `s.bytes()` | for-only; binding emits invalid Zig |
| `s.chars()` | **UNKNOWN** | — | `s.chars()` | for-only; binding emits invalid Zig |
| `s.charAt(0)` | **VALUE** | — | `s[@intCast(0)]` | BUG-223: typed str, emits u8 |

## for-only iterators

These cannot be bound to a variable, so no emitted binding exists to classify. The rows below are **hand-stated from the iterator codegen, not derived** — treat them with less authority than the table above.

| iteration form | ownership of what it yields | why |
|---|---|---|
| `for c in s.chars()` | **VALUE** | decoded u21 codepoint — aliases nothing |
| `for byte in s.bytes()` | **VALUE** | single u8 — aliases nothing |
