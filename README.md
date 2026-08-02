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

- Zig 0.16.0. (`build.zig.zon` declares a `minimum_zig_version` of 0.15.0, but
  the tree currently builds against 0.16.)

## Building

```bash
zig build                                    # build the compiler
zig build run -- path/to/file.zbr            # compile and run a Zebra file
zig build test                               # run the test suite
```

## License

TBD. See the original Cobra license for heritage context noted in
`HERITAGE.md`; a Zebra-specific license will be added before the first
tagged release.
