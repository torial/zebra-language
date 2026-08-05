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
[STDLIB_ROADMAP.md](STDLIB_ROADMAP.md), and the priority queue is in
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
- **[SELFHOST_JOURNAL.md](SELFHOST_JOURNAL.md)** — phase-by-phase port notes.
- **[BUGS.md](BUGS.md)** — active bug tracker.
- **[NEXT_STEPS.md](NEXT_STEPS.md)** — authoritative priority queue.
- **[STDLIB_ROADMAP.md](STDLIB_ROADMAP.md)** — standard library plan.
- **[docs/DEBUGGING.md](docs/DEBUGGING.md)** — debugger setup (VS Code, ZebraIDE, lldb-dap).
- **[IDE/README.md](IDE/README.md)** — self-hosted IDE experiments.
- **[docs/archive/HERITAGE.md](docs/archive/HERITAGE.md)** — how this repo relates
  to the archived `cobra-language` repo it was split from.

## Requirements

- **Zig 0.16.0.** (`build.zig.zon` declares a `minimum_zig_version` of 0.15.0, but
  the tree currently builds against 0.16 and is only tested there.)
- A network connection on first build, to fetch the one external dependency
  ([`torial/earley`](https://github.com/torial/earley), pinned by URL and hash).
  Subsequent builds use Zig's package cache.
- **Windows is the only tested platform.** Other platforms are not claimed to work
  and are not exercised by CI.

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
building; it produces `zig-out/bin/zebra.exe` and `zig-out/bin/zebra-bootstrap.exe`.

*(Until 2026-08-05 this was not true. The Earley dependency was declared as
`.path = "../earley"` — a sibling directory that is not part of this repository — so
a clean clone failed with `unable to open '../earley': FileNotFound` for everyone
except the author, whose working copy already had the sibling. It is now pinned by
URL and hash. If you are developing against a local Earley checkout, see the comment
in `build.zig.zon` for the one-line override.)*

## Continuous integration

Gates run on GitHub Actions: the QUICK tier on every push and pull request, the FULL
tier nightly and on demand. Both use Windows runners and a checksum-pinned Zig. See
`.github/workflows/`, and `CLAUDE.md` for what each gate does and — importantly — what
it cannot see.

## License

TBD. See the original Cobra license for heritage context noted in
`HERITAGE.md`; a Zebra-specific license will be added before the first
tagged release.
