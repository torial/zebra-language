//! cross_sema_check.sh's runtime-declarations leg. Zig analyses lazily, so a runtime helper
//! that no test program calls is never compiled for any target. This references every
//! declaration of the runtime and recurses into the container types DECLARED IN it (never
//! into imports such as std, whose own OS-specific declarations are not ours to check).
//! Generic functions and types are not instantiated -- that half is the program leg's.
const std = @import("std");

fn declName(d: anytype) []const u8 {
    // 0.17's std.meta.declarations yields names; 0.16's yields Declaration structs.
    return if (@TypeOf(d) == [:0]const u8 or @TypeOf(d) == []const u8) d else d.name;
}

pub fn refAllRec(comptime T: type, comptime prefix: []const u8, comptime depth: usize) void {
    @setEvalBranchQuota(1_000_000);
    inline for (comptime std.meta.declarations(T)) |d| {
        const name = comptime declName(d);
        _ = &@field(T, name);
        if (depth > 0 and @TypeOf(@field(T, name)) == type) {
            const U = @field(T, name);
            // `comptime` is load-bearing: as a runtime condition both branches are analysed
            // and the walk escapes into std (measured: 62 std-internal errors on Windows).
            if (comptime std.mem.startsWith(u8, @typeName(U), prefix)) {
                switch (@typeInfo(U)) {
                    .@"struct", .@"union", .@"enum", .@"opaque" => refAllRec(U, prefix, depth - 1),
                    else => {},
                }
            }
        }
    }
}
