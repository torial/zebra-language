const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Self-hosted-backend fast path for DEBUG builds (#233): Zig's self-hosted x86_64
    // backend + linker builds the primary zebra.exe (selfhost) ~6x faster than LLVM+LLD
    // (≈1.4s vs 8.5s here) with byte-identical output (validated via the bootstrap
    // round-trip, which rebuilds the selfhost compiler and diffs its full self-emit).
    // Default ON for Debug; release builds keep LLVM for codegen quality.  Applied only
    // to zebra.exe — the bootstrap (src/) is miscompiled by the self-hosted backend (see
    // below), so it stays on LLVM.  `-Dfast-backend=false` forces LLVM (cross-check).
    const fast_backend = (b.option(bool, "fast-backend",
        "Build the debug zebra.exe with Zig's self-hosted backend (~6x faster; Debug only)") orelse true) and optimize == .Debug;
    const setFastBackend = struct {
        fn apply(c: *std.Build.Step.Compile, on: bool) void {
            if (on) { c.use_llvm = false; c.use_lld = false; }
        }
    }.apply;

    const earley_dep = b.dependency("earley", .{ .target = target, .optimize = optimize });
    const earley_mod = earley_dep.module("earley");

    // ── Bootstrap compiler: Zig-implemented backend ──────────────────────────
    //
    // After Phase 22 cutover, this is NOT the primary `zebra` binary.
    // Primary use: bootstrap_check.sh Step 1 (emit selfhost/*.zig from *.zbr).
    // Installed as zebra-bootstrap.exe; used via --zig-backend escape hatch.

    const compiler_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target   = target,
        .optimize = optimize,
    });
    compiler_mod.addImport("earley", earley_mod);
    const raw_preamble = b.build_root.handle.readFileAlloc(b.graph.io, "selfhost/stdlib_preamble.zig", b.allocator, std.Io.Limit.limited(256 * 1024)) catch @panic("selfhost/stdlib_preamble.zig missing");
    // Strip the file header (HOW-TO comment + allocator setup) — CodeGen emits those dynamically.
    // The static helpers start at the STDLIB_PREAMBLE_HELPERS_START marker.
    const helpers_start_marker = "// === STDLIB_PREAMBLE_HELPERS_START ===\n";
    const gui_start_marker     = "// === STDLIB_PREAMBLE_GUI_START ===\n";
    const gui_end_marker       = "// === STDLIB_PREAMBLE_GUI_END ===\n";
    const helpers_start = std.mem.indexOf(u8, raw_preamble, helpers_start_marker) orelse @panic("STDLIB_PREAMBLE_HELPERS_START marker missing from selfhost/stdlib_preamble.zig");
    const gui_start_idx = std.mem.indexOf(u8, raw_preamble, gui_start_marker)     orelse @panic("STDLIB_PREAMBLE_GUI_START marker missing from selfhost/stdlib_preamble.zig");
    const gui_end_raw   = std.mem.indexOf(u8, raw_preamble, gui_end_marker)       orelse @panic("STDLIB_PREAMBLE_GUI_END marker missing from selfhost/stdlib_preamble.zig");
    const gui_end_idx   = gui_end_raw + gui_end_marker.len;
    const preamble_opts = b.addOptions();
    preamble_opts.addOption([]const u8, "stdlib_preamble_pre_gui",  raw_preamble[helpers_start..gui_start_idx]);
    preamble_opts.addOption([]const u8, "stdlib_preamble_post_gui", raw_preamble[gui_end_idx..]);
    compiler_mod.addOptions("build_options", preamble_opts);

    const bootstrap_exe = b.addExecutable(.{
        .name        = "zebra-bootstrap",
        .root_module = compiler_mod,
    });
    // The bootstrap stays on LLVM even in Debug. It is the regeneration authority — it
    // produces the committed selfhost/*.zig fixed point (via `update-selfhost`) — so it
    // uses the battle-tested LLVM backend, not the newer self-hosted one.  (#234 found the
    // self-hosted backend compiles the bootstrap *correctly* — full --bootstrap parity is
    // identical to LLVM — so this is conservatism about committed artifacts, NOT a
    // miscompile.  Note: self-hosted-built binaries on Windows have a stdout-to-pipe bug —
    // they write correctly to a file/redirect but nothing to a pipe; harmless here since
    // every gate uses redirect/--output-dir, but pipe `zebra ... | x` needs -Dfast-backend=false.)
    b.installArtifact(bootstrap_exe);

    // ── Primary zebra binary: selfhost pipeline (Phase 22 cutover) ──────────
    //
    // Compiled from selfhost/main.zig (checked-in fixed point from the
    // bootstrap round-trip). Default mode: Lex → Parse → Resolve → TC →
    // CodeGen → zig run. No external module deps — uses relative @imports.

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

    const run = b.addRunArtifact(exe);
    run.addArgs(b.args orelse &.{});
    const run_step = b.step("run", "Run the Zebra compiler");
    run_step.dependOn(&run.step);

    // ── Explicit module graph for tools and integration tests ─────────────────
    //
    // When src files are split across multiple modules (grammar tool, integ
    // tests) each file must belong to exactly one module.  We therefore create
    // one module per source file and wire every cross-file `@import` as a
    // named module dependency using the same string the source uses (e.g.
    // `"Token.zig"`), so the existing source files need no changes.

    const token_mod = b.createModule(.{
        .root_source_file = b.path("src/Token.zig"),
        .target   = target,
        .optimize = optimize,
    });

    const tokenizer_mod = b.createModule(.{
        .root_source_file = b.path("src/Tokenizer.zig"),
        .target   = target,
        .optimize = optimize,
    });
    tokenizer_mod.addImport("Token.zig", token_mod);

    const zebra_grammar_mod = b.createModule(.{
        .root_source_file = b.path("src/ZebraGrammar.zig"),
        .target   = target,
        .optimize = optimize,
    });
    zebra_grammar_mod.addImport("earley",    earley_mod);
    zebra_grammar_mod.addImport("Token.zig", token_mod);

    const ast_mod = b.createModule(.{
        .root_source_file = b.path("src/Ast.zig"),
        .target   = target,
        .optimize = optimize,
    });

    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/Parser.zig"),
        .target   = target,
        .optimize = optimize,
    });
    parser_mod.addImport("earley",           earley_mod);
    parser_mod.addImport("Token.zig",        token_mod);
    parser_mod.addImport("Tokenizer.zig",    tokenizer_mod);
    parser_mod.addImport("ZebraGrammar.zig", zebra_grammar_mod);

    const ast_builder_mod = b.createModule(.{
        .root_source_file = b.path("src/AstBuilder.zig"),
        .target   = target,
        .optimize = optimize,
    });
    ast_builder_mod.addImport("earley",           earley_mod);
    ast_builder_mod.addImport("Ast.zig",          ast_mod);
    ast_builder_mod.addImport("Parser.zig",       parser_mod);
    ast_builder_mod.addImport("Token.zig",        token_mod);
    ast_builder_mod.addImport("ZebraGrammar.zig", zebra_grammar_mod);

    const ast_printer_mod = b.createModule(.{
        .root_source_file = b.path("src/AstPrinter.zig"),
        .target   = target,
        .optimize = optimize,
    });
    ast_printer_mod.addImport("Ast.zig", ast_mod);

    // ── Grammar listing ───────────────────────────────────────────────────────

    const grammar_tool_mod = b.createModule(.{
        .root_source_file = b.path("tools/print_grammar.zig"),
        .target   = target,
        .optimize = optimize,
    });
    grammar_tool_mod.addImport("earley",       earley_mod);
    grammar_tool_mod.addImport("ZebraGrammar", zebra_grammar_mod);

    const grammar_exe  = b.addExecutable(.{ .name = "print-grammar", .root_module = grammar_tool_mod });
    const grammar_run  = b.addRunArtifact(grammar_exe);
    const grammar_step = b.step("grammar", "Print the Zebra grammar as a BNF listing");
    grammar_step.dependOn(&grammar_run.step);

    // ── Tests ─────────────────────────────────────────────────────────────────

    // Unit tests: single module rooted at src/main.zig — relative imports work
    // naturally; only the external 'earley' dep needs registering.
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target   = target,
        .optimize = optimize,
    });
    unit_mod.addImport("earley", earley_mod);
    unit_mod.addOptions("build_options", preamble_opts);
    const unit_tests = b.addTest(.{ .name = "unit", .root_module = unit_mod });

    // Integration tests: test/main.zig imports the explicit module graph.
    const integ_mod = b.createModule(.{
        .root_source_file = b.path("test/main.zig"),
        .target   = target,
        .optimize = optimize,
    });
    integ_mod.addImport("Tokenizer",   tokenizer_mod);
    integ_mod.addImport("Parser",      parser_mod);
    integ_mod.addImport("AstBuilder",  ast_builder_mod);
    integ_mod.addImport("AstPrinter",  ast_printer_mod);
    const integ_tests = b.addTest(.{ .name = "integration", .root_module = integ_mod });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(integ_tests).step);

    // Selfhost smoke: run tools/selfhost_smoke.sh after building zebra.exe.
    // Exercises the full lex→parse→resolve→TC→codegen pipeline on 10 fixtures
    // without invoking `zig run` — fast enough for the default test step.
    const smoke_run = b.addSystemCommand(&.{ "bash", "tools/selfhost_smoke.sh" });
    smoke_run.step.dependOn(&exe.step);
    test_step.dependOn(&smoke_run.step);

    // Escape-hatches guard: fails if `page_allocator` count in src/ or in
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
    // using zebra-bootstrap.exe (the authoritative Zig-compiled compiler).
    // Using bootstrap — not the selfhost binary — avoids the chicken-and-egg
    // where a codegen bug in selfhost/CodeGen.zbr causes the selfhost binary to
    // regenerate that same bug. Round-trip fidelity is tested separately by
    // `zig build bootstrap` (the full 5-step check).
    // After this step, run `zig build` again to rebuild zebra.exe.
    // Does NOT call zig build recursively — that would cause a recursive build
    // error; the two-step idiom is intentional.
    const update_run = b.addSystemCommand(&.{ "bash", "tools/bootstrap_check.sh", "--update" });
    update_run.step.dependOn(&bootstrap_exe.step); // only needs the Zig-compiled bootstrap, not zebra.exe
    const update_selfhost_step = b.step("update-selfhost", "Regenerate selfhost/*.zig from .zbr sources (then run 'zig build')");
    update_selfhost_step.dependOn(&update_run.step);
}
