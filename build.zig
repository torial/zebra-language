const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Self-hosted-backend fast path for DEBUG builds (#233): Zig's self-hosted x86_64
    // backend + linker builds zebra.exe ~6x faster than LLVM+LLD (≈1.4s vs 8.5s here)
    // with byte-identical output (validated via the round-trip, which rebuilds the
    // compiler from its own emit and diffs the result). Default ON for Debug; release
    // builds keep LLVM for codegen quality. `-Dfast-backend=false` forces LLVM.
    const fast_backend = (b.option(bool, "fast-backend",
        "Build the debug zebra.exe with Zig's self-hosted backend (~6x faster; Debug only)") orelse true) and optimize == .Debug;
    const setFastBackend = struct {
        fn apply(c: *std.Build.Step.Compile, on: bool) void {
            if (on) { c.use_llvm = false; c.use_lld = false; }
        }
    }.apply;

    // ── The stdlib preamble, embedded at build time ──────────────────────────
    //
    // The compiler inlines selfhost/stdlib_preamble.zig into every emitted program
    // (and reads the installed copy at codegen time for the runtime-module shape).
    // Until 2026-09-16 this block fed the Zig-implemented bootstrap in src/; that
    // compiler is gone (docs/design/bootstrap_sunset.md), and the reading stays so
    // the marker/CRLF invariants below keep being enforced by the build itself.

    const raw_preamble = b.build_root.handle.readFileAlloc(b.graph.io, "selfhost/stdlib_preamble.zig", b.allocator, std.Io.Limit.limited(256 * 1024)) catch @panic("selfhost/stdlib_preamble.zig missing");
    // Strip the file header (HOW-TO comment + allocator setup) — CodeGen emits those dynamically.
    // The static helpers start at the STDLIB_PREAMBLE_HELPERS_START marker.
    // Markers are matched WITHOUT their line ending, and the end index skips to the next
    // '\n' explicitly: a Windows checkout (actions/checkout, core.autocrlf=true) turns this
    // file's "\n" into "\r\n", and a marker string carrying "\n" then never matches. The
    // release workflow's first run (v0.9.0-rc1_zig0.16, 2026-09-12) failed on exactly that
    // panic on windows-latest while ubuntu and macos passed. .gitattributes now pins *.zig
    // to LF as well; this is the second layer, so the build never depends on the first.
    const helpers_start_marker = "// === STDLIB_PREAMBLE_HELPERS_START ===";
    const gui_start_marker     = "// === STDLIB_PREAMBLE_GUI_START ===";
    const gui_end_marker       = "// === STDLIB_PREAMBLE_GUI_END ===";
    const helpers_start = std.mem.indexOf(u8, raw_preamble, helpers_start_marker) orelse @panic("STDLIB_PREAMBLE_HELPERS_START marker missing from selfhost/stdlib_preamble.zig");
    const gui_start_idx = std.mem.indexOf(u8, raw_preamble, gui_start_marker)     orelse @panic("STDLIB_PREAMBLE_GUI_START marker missing from selfhost/stdlib_preamble.zig");
    const gui_end_raw   = std.mem.indexOf(u8, raw_preamble, gui_end_marker)       orelse @panic("STDLIB_PREAMBLE_GUI_END marker missing from selfhost/stdlib_preamble.zig");
    const gui_end_idx   = lineEnd(raw_preamble, gui_end_raw + gui_end_marker.len);
    const preamble_opts = b.addOptions();
    preamble_opts.addOption([]const u8, "stdlib_preamble_pre_gui",  raw_preamble[helpers_start..gui_start_idx]);
    preamble_opts.addOption([]const u8, "stdlib_preamble_post_gui", raw_preamble[gui_end_idx..]);

    // N-API preamble (--target node-addon only).  Kept in a separate file so its
    // node_api.h @cImport never compiles into the compiler itself — embedded as a
    // string and only emitted into generated addons.  Phase 1.
    const raw_napi = b.build_root.handle.readFileAlloc(b.graph.io, "selfhost/napi_preamble.zig", b.allocator, std.Io.Limit.limited(64 * 1024)) catch @panic("selfhost/napi_preamble.zig missing");
    const napi_start_marker = "// === NAPI_PREAMBLE_HELPERS_START ===";
    const napi_end_marker   = "// === NAPI_PREAMBLE_HELPERS_END ===";
    const napi_start_raw = std.mem.indexOf(u8, raw_napi, napi_start_marker) orelse @panic("NAPI_PREAMBLE_HELPERS_START marker missing from selfhost/napi_preamble.zig");
    const napi_start = lineEnd(raw_napi, napi_start_raw + napi_start_marker.len);
    const napi_end   = std.mem.indexOf(u8, raw_napi, napi_end_marker)   orelse @panic("NAPI_PREAMBLE_HELPERS_END marker missing from selfhost/napi_preamble.zig");
    preamble_opts.addOption([]const u8, "napi_preamble", raw_napi[napi_start..napi_end]);

    // ── The zebra binary ────────────────────────────────────────────────────
    //
    // Compiled from selfhost/main.zig -- the checked-in fixed point of the
    // compiler's own emit (tools/bootstrap_check.sh proves it; tools/regen_recover.sh
    // rebuilds it from git if the working compiler is broken). Pipeline: Lex →
    // Parse → Resolve → TC → CodeGen → zig. No external deps; relative @imports.

    const selfhost_mod = b.createModule(.{
        .root_source_file = b.path("selfhost/main.zig"),
        .target   = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name        = "zebra",
        .root_module = selfhost_mod,
    });
    setFastBackend(exe, fast_backend);
    b.installArtifact(exe);

    // Install sqlite3.c alongside zebra.exe so programs using Sqlite can compile.
    // zebra.exe looks for vendor/sqlite/sqlite3.c relative to its own directory.
    const install_sqlite = b.addInstallFile(
        b.path("vendor/sqlite/sqlite3.c"),
        "bin/vendor/sqlite/sqlite3.c",
    );
    b.getInstallStep().dependOn(&install_sqlite.step);

    // Install the stdlib preamble alongside zebra.exe so the selfhost compiler can
    // find it when invoked from any directory (it reads the preamble at codegen
    // time).  Without this, `zebra.exe` only works with cwd = the repo root — the
    // cwd-dependent-panic bug.  main.zbr resolves repo-relative first, then this
    // exe-adjacent copy.
    const install_preamble = b.addInstallFile(
        b.path("selfhost/stdlib_preamble.zig"),
        "bin/stdlib_preamble.zig",
    );
    b.getInstallStep().dependOn(&install_preamble.step);

    // The GUI backend sections: read at runtime for --gui-backend=tui / libui_ng,
    // resolved next to stdlib_preamble.zig.
    const install_gui_tui = b.addInstallFile(
        b.path("selfhost/gui_tui_section.zig"),
        "bin/gui_tui_section.zig",
    );
    b.getInstallStep().dependOn(&install_gui_tui.step);
    const install_gui_lui = b.addInstallFile(
        b.path("selfhost/gui_libui_ng_section.zig"),
        "bin/gui_libui_ng_section.zig",
    );
    b.getInstallStep().dependOn(&install_gui_lui.step);

    const run = b.addRunArtifact(exe);
    run.addArgs(b.args orelse &.{});
    const run_step = b.step("run", "Run the Zebra compiler");
    run_step.dependOn(&run.step);

    // ── Tests ─────────────────────────────────────────────────────────────────
    //
    // The compiler's own unit tests are Zebra fixtures run by the smoke suite
    // (selfhost/ast_test.zbr, typechecker_test.zbr, ...). The Zig-side `unit` and
    // `integration` test binaries and the `test-zig` step tested the bootstrap in
    // src/ and left with it (2026-09-16, bootstrap_sunset.md Step 3).
    const test_step = b.step("test", "Run all tests");

    // Selfhost smoke: run tools/selfhost_smoke.sh after building zebra.exe.
    // Exercises the full lex→parse→resolve→TC→codegen pipeline on 10 fixtures
    // without invoking `zig run` — fast enough for the default test step.
    const smoke_run = b.addSystemCommand(&.{ "bash", "tools/selfhost_smoke.sh" });
    smoke_run.step.dependOn(&exe.step);
    test_step.dependOn(&smoke_run.step);

    // Escape-hatches guard: fails if the `page_allocator` count in
    // selfhost/stdlib_preamble.zig drifts from the recorded baseline.  Cheap;
    // catches accidental new escape hatches before they're committed.
    const escape_check = b.addSystemCommand(&.{ "bash", "tools/escape_hatches_check.sh" });
    test_step.dependOn(&escape_check.step);

    // Compile-check gate: emit every positive-smoke test and type-check the Zig the
    // selfhost compiler actually produces (`zig build-exe -fno-emit-bin -lc`), which the
    // emit-only smoke suite never did. Green at 141/0/1 as of 2026-06-27.
    //
    // BLOCKING on `zig build test` (opted in 2026-06-27): it runs ~144 `build-exe`
    // invocations (minutes, slower on this laptop), but the quality floor it enforces —
    // user programs that emit *type-correct* Zig, not just parseable Zig — is judged worth
    // the inner-loop cost. Also runnable on its own: `zig build compile-check`. To revert
    // to on-demand only, drop the `test_step.dependOn(&compile_check.step)` line below.
    const compile_check = b.addSystemCommand(&.{ "bash", "tools/compile_check.sh" });
    compile_check.step.dependOn(&exe.step);
    const compile_check_step = b.step("compile-check", "Type-check the Zig emitted for every positive-smoke test");
    compile_check_step.dependOn(&compile_check.step);
    test_step.dependOn(&compile_check.step);

    // ── Selfhost build ────────────────────────────────────────────────────────
    //
    // `zig build selfhost` emits all selfhost/*.zbr files to /tmp/bs-zig via
    // the Zig-compiled zebra binary, then compiles the resulting main.zig into
    // zig-out/bin/zebra-selfhost.exe.
    //
    // This is equivalent to `bash tools/bootstrap_check.sh --quick` but
    // callable directly from zig build without requiring bash on PATH.
    //
    // Output: zig-out/bin/zebra-selfhost.exe
    const selfhost_run = b.addSystemCommand(&.{ "bash", "tools/bootstrap_check.sh", "--quick" });
    selfhost_run.step.dependOn(b.getInstallStep());
    const selfhost_step = b.step("selfhost", "Build the selfhost compiler → zig-out/bin/zebra-selfhost.exe");
    selfhost_step.dependOn(&selfhost_run.step);

    // ── Selfhost bootstrap check ──────────────────────────────────────────────
    //
    // `zig build bootstrap` runs tools/bootstrap_check.sh, which verifies that
    // the selfhost compiler reaches a level-2 fixed point: A rebuilds itself
    // into B, and B emits output byte-identical to A. Kept out of the default
    // `test` step because it rebuilds selfhost-A and -B and takes ~1 minute.
    const bootstrap_run = b.addSystemCommand(&.{ "bash", "tools/bootstrap_check.sh" });
    bootstrap_run.step.dependOn(b.getInstallStep());
    const bootstrap_step = b.step("bootstrap", "Verify selfhost round-trip + level-2 fixed point");
    bootstrap_step.dependOn(&bootstrap_run.step);

    // ── Selfhost update ───────────────────────────────────────────────────────
    //
    // `zig build update-selfhost` emits all selfhost/*.zig from selfhost/*.zbr
    // using the zebra.exe built from the COMMITTED selfhost/*.zig (the N-1
    // regen authority since 2026-08-30). Round-trip fidelity is tested separately
    // by `zig build bootstrap` (the full 5-step check); a broken compiler is
    // recovered with tools/regen_recover.sh.
    // After this step, run `zig build` again to rebuild zebra.exe.
    // Does NOT call zig build recursively — that would cause a recursive build
    // error; the two-step idiom is intentional.
    const update_run = b.addSystemCommand(&.{ "bash", "tools/bootstrap_check.sh", "--update" });
    update_run.step.dependOn(b.getInstallStep());
    // BUG-210: this step regenerates selfhost/*.zig from selfhost/*.zbr but declares
    // no .zbr inputs, so Zig's build cache would skip it after a .zbr-only edit
    // (fixed argv + unchanged deps → cache hit), silently leaving the
    // generated .zig stale. Force it to always run — regeneration is the point.
    update_run.has_side_effects = true;
    const update_selfhost_step = b.step("update-selfhost", "Regenerate selfhost/*.zig from .zbr sources (then run 'zig build')");
    update_selfhost_step.dependOn(&update_run.step);
}

/// Index just past the end of the line containing `from` -- past "\n" or "\r\n", or the
/// end of the buffer. Lets the preamble markers be matched independent of line endings.
fn lineEnd(buf: []const u8, from: usize) usize {
    var i = from;
    while (i < buf.len and buf[i] != '\n') : (i += 1) {}
    return if (i < buf.len) i + 1 else i;
}
