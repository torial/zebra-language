<!-- doc-status: live -->
# Zebra

A programming language in the Python / Cobra / Eiffel family, with a Zig
backend and a self-hosting effort underway. `.zbr` source compiles (via Zig)
to native executables.

## Status

Pre-1.0, and usable end-to-end for non-trivial programs — the self-hosted
compiler is written in Zebra and is its own main stress test. Also built in
Zebra: a game engine, a language server, and a GUI IDE with an embedded
Scintilla editor. Standard library is growing; a roadmap lives in
[docs/STDLIB_ROADMAP.md](docs/STDLIB_ROADMAP.md), and the priority queue is in
[NEXT_STEPS.md](NEXT_STEPS.md).

## Hello, world

```zebra
def main()
    print("Hello, Zebra!")
```

```bash
zig build run -- hello.zbr
```

A GUI program is not much longer — Zebra uses an Elm-style Model/Update/View
loop, and the same source runs against a native-widget or terminal backend:

```bash
zig-out/bin/zebra.exe --gui-backend=libui_ng run examples/counter.zbr
zig-out/bin/zebra.exe --gui-backend=tui      run examples/counter.zbr
```

## Documentation

- **[QUICKSTART.md](QUICKSTART.md)** — language syntax and idioms (start here).
- **[docs/UI_QUICKSTART.md](docs/UI_QUICKSTART.md)** — GUI programming and the
  libui-ng backend.
- **[docs/SELFHOST_JOURNAL.md](docs/SELFHOST_JOURNAL.md)** — phase-by-phase port notes.
- **[BUGS.md](BUGS.md)** — active bug tracker.
- **[NEXT_STEPS.md](NEXT_STEPS.md)** — authoritative priority queue.
- **[docs/STDLIB_ROADMAP.md](docs/STDLIB_ROADMAP.md)** — standard library plan.
- **[docs/DEBUGGING.md](docs/DEBUGGING.md)** — debugger setup (VS Code, ZebraIDE, lldb-dap).
- **[docs/archive/HERITAGE.md](docs/archive/HERITAGE.md)** — how this repo relates
  to the archived `cobra-language` repo it was split from.

## Installing

Releases ship one folder per platform with the compiler, the Zig it was built with, the
guide and the examples -- see [install/README-INSTALL.md](install/README-INSTALL.md)
(`install.ps1` on Windows, `install.sh` on Linux/macOS). `zebra --version` names both
versions. Building from source is below; how a release is cut is in
[docs/RELEASING.md](docs/RELEASING.md).

## Requirements

- **Zig 0.16.0.** (`build.zig.zon` declares a `minimum_zig_version` of 0.15.0, but
  the tree currently builds against 0.16 and is only tested there.) Zig is also a
  RUNTIME dependency: every program is emitted as Zig and built with `zig build-exe`,
  which is why a release bundles it.
- Nothing else. `build.zig.zon` declares no dependencies (the Earley parser the
  Zig-implemented bootstrap used left with it on 2026-09-16), so the first build needs
  no network.
- **Windows and Linux** are the tested platforms: Windows is where the gates run day
  to day; Linux has built and passed the full smoke since 2026-09-06
  ([docs/LINUX_BUILD.md](docs/LINUX_BUILD.md)). macOS is untested.

## Building

```bash
git clone https://github.com/torial/zebra-language
cd zebra-language
zig build                                    # build the compiler (~30 s from cold)
zig build run -- path/to/file.zbr            # compile and run a Zebra file
zig build test                               # run the test suite
```

That is the whole of it — no submodules, no sibling checkouts, no preparation step.
Verified 2026-08-05 by cloning into an empty directory on a cold package cache and
building; it produces `zig-out/bin/zebra.exe` (and, until the Zig-implemented bootstrap
was retired on 2026-09-16, `zebra-bootstrap.exe` beside it; the build has no dependencies
at all now).

*(Until 2026-08-05 this was not true. The Earley dependency was declared as
`.path = "../earley"` — a sibling directory that is not part of this repository — so
a clean clone failed with `unable to open '../earley': FileNotFound` for everyone
except the author, whose working copy already had the sibling. It is now pinned by
URL and hash — and on 2026-09-16 the dependency went away entirely with the bootstrap
that used it.)*

## Continuous integration

Gates run on GitHub Actions: the QUICK tier on every push and pull request, the FULL
tier nightly and on demand. Both use Windows runners and a checksum-pinned Zig. A `v*`
tag runs the release workflow (Windows, Linux, macOS-experimental archives with the Zig
bundled). See `.github/workflows/`, and `CLAUDE.md` for what each gate does and —
importantly — what it cannot see.

## License

MIT — see [LICENSE](LICENSE). The bundled Zig toolchain is MIT as well. The
original Cobra heritage is noted in `docs/archive/HERITAGE.md`.
