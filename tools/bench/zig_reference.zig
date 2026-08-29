// Hand-written Zig reference for tools/bench/index_bench.zbr.
//
// SAME algorithm, SAME data layout, SAME timing method (best-of-25 in-process rounds), SAME
// work per round (12000 matvec calls, n=128). The point is to measure the LANGUAGE gap, so
// anything differing other than the language is a defect in the comparison.
//
// Two variants, answering different questions:
//   FLATMODE=false  ArrayList-of-ArrayList, exactly what Zebra emits -> isolates codegen
//   FLATMODE=true   a flat slice, what a Zig programmer would write  -> the real user gap
const std = @import("std");

fn matvecList(M: []const std.ArrayList(f64), v: []const f64, out: []f64) void {
    var i: usize = 0;
    while (i < M.len) : (i += 1) {
        const row = M[i].items;
        var s: f64 = 0.0;
        var j: usize = 0;
        while (j < v.len) : (j += 1) {
            s += row[j] * v[j];
        }
        out[i] = s;
    }
}

fn matvecFlat(M: []const f64, n: usize, v: []const f64, out: []f64) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const row = M[i * n ..][0..n];
        var s: f64 = 0.0;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            s += row[j] * v[j];
        }
        out[i] = s;
    }
}

pub fn main(zinit: std.process.Init) !void {
    const io = zinit.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const n: usize = 128;

    const M = try a.alloc(std.ArrayList(f64), n);
    for (0..n) |i| {
        M[i] = .empty;
        for (0..n) |j| try M[i].append(a, 0.001 * @as(f64, @floatFromInt(i + j)));
    }
    const F = try a.alloc(f64, n * n);
    for (0..n) |i| for (0..n) |j| {
        F[i * n + j] = 0.001 * @as(f64, @floatFromInt(i + j));
    };

    const v = try a.alloc(f64, n);
    const out = try a.alloc(f64, n);
    for (0..n) |i| {
        v[i] = 0.5;
        out[i] = 0.0;
    }

    const which = FLATMODE;

    var best: i64 = std.math.maxInt(i64);
    var worst: i64 = 0;
    for (0..25) |_| {
        const t0 = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms);
        var c: usize = 0;
        while (c < 12000) : (c += 1) {
            if (which) matvecFlat(F, n, v, out) else matvecList(M, v, out);
        }
        const t1 = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms);
        const d: i64 = @intCast(t1 - t0);
        if (d < best) best = d;
        if (d > worst) worst = d;
    }

    var chk: f64 = 0.0;
    for (out) |x| chk += x;
    std.debug.print("best {d} worst {d} checksum {d}\n", .{ best, worst, chk });
}
