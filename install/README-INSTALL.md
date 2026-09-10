# Installing Zebra

A release is one folder: the `zebra` compiler, the Zig toolchain it was built and tested
with (`zig/`), the language guide (`QUICKSTART.md`), and `examples/`. Nothing else is
required -- Zebra compiles your program to Zig and builds it with the bundled `zig`.

## Windows

```powershell
irm https://raw.githubusercontent.com/torial/zebra-language/main/install/install.ps1 | iex
```

Installs to `%USERPROFILE%\.zebra\current` and adds it to your user PATH. Open a new
terminal, then:

```
zebra --version
zebra examples\hello.zbr
```

## Linux and macOS

```sh
curl -fsSL https://raw.githubusercontent.com/torial/zebra-language/main/install/install.sh | sh
```

Installs to `~/.zebra/current` and prints the `export PATH=...` line to add to your shell
profile. macOS builds are experimental until a smoke has run green there.

## Manual

Download the archive for your platform from the Releases page, unpack it anywhere, and
put that folder on your PATH. `zebra` finds the bundled Zig by looking for `zig/` next
to itself; to use a different Zig, set `ZEBRA_ZIG=/path/to/zig`.

## From source

Zig 0.16 on PATH, then `git clone https://github.com/torial/zebra-language && cd
zebra-language && zig build`. The compiler is `zig-out/bin/zebra` (`.exe` on Windows).
`docs/LINUX_BUILD.md` has the container recipe.
