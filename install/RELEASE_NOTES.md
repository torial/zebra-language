## Install

**Windows (PowerShell)**
```powershell
irm https://raw.githubusercontent.com/torial/zebra-language/main/install/install.ps1 | iex
```

**Linux / macOS**
```sh
curl -fsSL https://raw.githubusercontent.com/torial/zebra-language/main/install/install.sh | sh
```

Then open a new terminal and run `zebra --version`. Already installed? `zebra up` updates in
place. Manual install and building from source:
[install/README-INSTALL.md](https://github.com/torial/zebra-language/blob/main/install/README-INSTALL.md).

Each archive holds the compiler, the Zig it was built with (you do not need Zig
separately), the language guide (`QUICKSTART.md`) and `examples/`. `SHA256SUMS.txt` lists the
archive checksums; the installers verify them.

**What changed:** [CHANGELOG.md](https://github.com/torial/zebra-language/blob/main/CHANGELOG.md).
**Learn the language:** [The Zebra Programming Language](https://torial.github.io/zebra-language-book/).

---
