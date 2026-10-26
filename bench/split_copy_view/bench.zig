// Copy vs view for `split` results (memory_model.md §6.1), under an allocator that FREES --
// the question only exists under a freeing model; under today's arena nothing is freed either
// way. Each variant simulates what a counted runtime would free, and when.
//
// Workloads (data shaped like C:\tmp\zzrc\data.txt: 5 `word12345` fields joined by `*`):
//   W1 keep-last : a = line.upper().split("*")[0], previous `a` dropped   (Sean's loop)
//   W2 keep-all  : results.append(line.upper().split("*")[0])            (the retention trap)
//   W3 frame     : "rect|120|340|64|32|Play".split("|"), parse, drop     (a GUI-ish temp)
// Policies:
//   view      : pieces are slices of the parent; the parent lives while any piece does
//   copy_all  : split copies every piece; the parent is freed right after split
//   copy_kept : pieces are views while temporary; the ONE that is kept is copied (copy at escape)
//   arena     : today -- view, program arena, nothing freed (W1 only, for scale)
const std = @import("std");

const VARIANT = "@V@";
const WIDE = @W@; // false: 2M lines of 5 fields (~50 B); true: 500k lines of 20 fields (~200 B)
const NFIELDS: usize = if (WIDE) 20 else 5;

const HANDLE = *anyopaque;
const PMC = extern struct {
    cb: u32,
    PageFaultCount: u32,
    PeakWorkingSetSize: usize,
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
};
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn K32GetProcessMemoryInfo(h: HANDLE, p: *PMC, cb: u32) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceCounter(c: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(f: *i64) callconv(.winapi) i32;

fn nowNs() u64 {
    var c: i64 = 0;
    var f: i64 = 0;
    _ = QueryPerformanceCounter(&c);
    _ = QueryPerformanceFrequency(&f);
    return @intCast(@divTrunc(@as(i128, c) * 1_000_000_000, f));
}

// Counting wrapper: requested bytes live / peak, allocation count.
const Counting = struct {
    backing: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,
    allocs: usize = 0,
    frees: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn bump(self: *Counting, n: usize) void {
        self.live += n;
        if (self.live > self.peak) self.peak = self.live;
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, a, ra) orelse return null;
        self.allocs += 1;
        self.bump(len);
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(m, a, n, ra)) return false;
        self.live -= m.len;
        self.bump(n);
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawRemap(m, a, n, ra) orelse return null;
        self.live -= m.len;
        self.bump(n);
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(m, a, ra);
        self.frees += 1;
        self.live -= m.len;
    }
};

const words = [_][]const u8{ "alpha", "beta", "gamma", "delta", "eps", "zeta", "eta", "theta" };

fn genData(a: std.mem.Allocator, nlines: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    var tmp: [32]u8 = undefined;
    for (0..nlines) |_| {
        for (0..NFIELDS) |k| {
            if (k > 0) try buf.append(a, '*');
            try buf.appendSlice(a, words[r.uintLessThan(usize, words.len)]);
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{r.uintLessThan(u32, 100000)});
            try buf.appendSlice(a, s);
        }
        try buf.append(a, '\n');
    }
    return buf.items;
}

fn splitList(a: std.mem.Allocator, s: []const u8, sep: []const u8, copy: bool) !std.ArrayList([]const u8) {
    var l: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, s, sep);
    while (it.next()) |p| try l.append(a, if (copy) try a.dupe(u8, p) else p);
    return l;
}

pub fn main() !void {
    const nlines: usize = if (WIDE) 500_000 else 2_000_000;
    const data = try genData(std.heap.page_allocator, nlines);

    const policy = comptime blk: {
        const i = std.mem.indexOfScalar(u8, VARIANT, ':').?;
        break :blk VARIANT[i + 1 ..];
    };
    const work = comptime VARIANT[0..std.mem.indexOfScalar(u8, VARIANT, ':').?];
    const is_arena = comptime std.mem.eql(u8, policy, "arena");
    const copy_all = comptime std.mem.eql(u8, policy, "copy_all");
    const copy_kept = comptime std.mem.eql(u8, policy, "copy_kept");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var cnt = Counting{ .backing = if (is_arena) arena.allocator() else std.heap.smp_allocator };
    const a = cnt.allocator();

    var checksum: u64 = 0;
    const t0 = nowNs();

    if (comptime std.mem.eql(u8, work, "W3")) {
        const cmds = [_][]const u8{ "rect|120|340|64|32|Play", "text|12|18|0|0|Score: 1200", "img|400|20|48|48|coin", "rect|0|0|800|24|bar" };
        for (0..2000) |frame| {
            for (0..1000) |i| {
                const s = cmds[(i + frame) % cmds.len];
                var l = try splitList(a, s, "|", copy_all);
                for (l.items[1..5]) |f| checksum +%= std.fmt.parseInt(u32, f, 10) catch 0;
                checksum +%= l.items[5].len;
                if (!is_arena) {
                    if (copy_all) for (l.items) |p| a.free(p);
                    l.deinit(a);
                }
            }
        }
    } else {
        const keep_all = comptime std.mem.eql(u8, work, "W2");
        var results: std.ArrayList([]const u8) = .empty;
        var parents: std.ArrayList([]u8) = .empty; // view+W2: the parents the kept views pin
        var prev_a: []const u8 = "";
        var prev_parent: ?[]u8 = null;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |src| {
            if (src.len == 0) continue;
            const line = try a.dupe(u8, src); // what readLine hands over
            const up = try std.ascii.allocUpperString(a, line);
            if (!is_arena) a.free(line);
            var l = try splitList(a, up, "*", copy_all);
            var kept: []const u8 = l.items[0];
            if (copy_kept) kept = try a.dupe(u8, kept);
            // release the temporaries
            if (!is_arena) {
                if (copy_all) for (l.items[1..]) |p| a.free(p);
                l.deinit(a);
            }
            const up_pinned = !copy_all and !copy_kept; // a kept view pins its parent
            if (!is_arena and !up_pinned) a.free(up);
            checksum +%= kept.len + kept[0];
            if (keep_all) {
                try results.append(a, kept);
                if (up_pinned and !is_arena) try parents.append(a, up);
            } else {
                if (!is_arena) {
                    if (up_pinned) {
                        if (prev_parent) |pp| a.free(pp);
                        prev_parent = up;
                    } else if (prev_a.len > 0) a.free(@constCast(prev_a));
                }
                prev_a = kept;
            }
        }
        checksum +%= results.items.len;
    }
    const t1 = nowNs();

    var pmc: PMC = std.mem.zeroes(PMC);
    pmc.cb = @sizeOf(PMC);
    _ = K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, @sizeOf(PMC));
    std.debug.print("{s:<14} {s:<5} {d:>7} ms  allocs {d:>9}  peak-live {d:>6} MB  end-live {d:>6} MB  peakWS {d:>6} MB  chk {d}\n", .{
        VARIANT, if (WIDE) "wide" else "short", (t1 - t0) / 1_000_000, cnt.allocs,
        cnt.peak / 1048576,               cnt.live / 1048576,    pmc.PeakWorkingSetSize / 1048576,
        checksum,
    });
}
