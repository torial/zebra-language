# Zebra

A programming language in the Python / Cobra / Eiffel family, with a Zig
backend and a self-hosting effort underway. `.zbr` source compiles (via Zig)
to native executables.

## Status

Early. The language is usable end-to-end for non-trivial programs (the
self-hosted compiler itself is the main stress test). Standard library is
growing; a roadmap lives in [STDLIB_ROADMAP.md](STDLIB_ROADMAP.md).

## Hello, world

```zebra
def main
    print "Hello, Zebra!"
```

```bash
zig build run -- hello.zbr
```

## Documentation

- **[QUICKSTART.md](QUICKSTART.md)** — language syntax and idioms (start here).
- **[SELFHOST_JOURNAL.md](SELFHOST_JOURNAL.md)** — phase-by-phase port notes.
- **[BUGS.md](BUGS.md)** — active bug tracker.
- **[STDLIB_ROADMAP.md](STDLIB_ROADMAP.md)** — standard library plan.
- **[IDE/README.md](IDE/README.md)** — self-hosted IDE experiments.
- **[HERITAGE.md](HERITAGE.md)** — how this repo relates to the archived
  `cobra-language` repo it was split from.

## Requirements

- Zig 0.15.0 or newer (see `build.zig.zon`).

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
