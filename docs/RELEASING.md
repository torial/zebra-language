<!-- doc-status: live -->
# Cutting a release

Written 2026-09-10 for the first public release, `0.9.0_zig0.16` (public 0.9 = internal
1.0; the suffix names the Zig the binary was built and tested with -- see `docs/README.md`).

## The pieces

| what | where |
|---|---|
| the version, ONE place | `_zbr_version` in `selfhost/stdlib_preamble.zig`; `zebra --version` prints it |
| the tag convention | `v<version>_zig0.16`, e.g. `v0.9.0_zig0.16`; the workflow refuses a mismatch or a `-dev` version. A test build is a semver PRE-RELEASE, `v0.9.0-rc1_zig0.16` (`_zbr_version = "0.9.0-rc1"`), which sorts BEFORE `0.9.0` -- not `0.89`, which sorts AFTER it (89 > 9) |
| the workflow | `.github/workflows/release.yml` -- on a `v*` tag: Windows, Linux, macOS (experimental) builds, each with the pinned Zig bundled, smoke-tested, zipped, attached to the GitHub release with `SHA256SUMS.txt` |
| how the binary finds Zig | `zigExe()` in `selfhost/main.zbr`: `$ZEBRA_ZIG`, then `<exe dir>/zig/zig`, then PATH |
| installers | `install/install.sh`, `install/install.ps1`, `install/README-INSTALL.md` (shipped in the archive as `INSTALL.md`) |

## Checklist

1. `--daily` green on the commit you will tag (Windows: `bash tools/gates.sh --daily`;
   the container cannot run the git-dependent static gates -- they need the real tree).
2. Bump `_zbr_version` from `x.y.z-dev` to `x.y.z`; regenerate (`bash tools/rebuild.sh`,
   the preamble is embedded); commit "release: x.y.z".
3. `CHANGELOG.md`: a section for the version.
4. Tag: `git tag v0.9.0_zig0.16 && git push origin main --tags`. The workflow runs; the
   first job fails fast if the tag and `_zbr_version` disagree.
5. When the release page has the three archives: on a clean machine (or a fresh user),
   run the installer for your platform and `zebra examples/hello.zbr`. That is the
   release test; nothing in CI stands in for it.
6. Bump `_zbr_version` to the next `-dev` and commit.

## Known gaps on 2026-09-10

- ~~No LICENSE file in the repo.~~ **MIT, added 2026-09-10 (Sean's call)**; `LICENSE` is
  copied into every release zip.
- The Zig checksums for all three platforms are pinned in `release.yml` (the 0.16.0
  values from `ziglang.org/download/index.json`, read 2026-09-10; Windows
  `68659eb5…`, Linux `70e49664…`, macOS-aarch64 `b23d70de…`). A new platform may
  start as `sha: index` (verified against the index at run time) until its value has
  been seen once; then pin it. Bumping the Zig version means re-pinning all three.
- macOS has never built Zebra; its job is `continue-on-error` until a smoke is green there.
- `winget` / `scoop` / Homebrew manifests are an hour each once the first release exists;
  not started.
- The `zebra-bootstrap` binary is shipped because `zig-out/bin` is copied whole. Nothing
  in the shipped compiler calls it since 2026-09-15 (`--zig-backend` is gone); it leaves
  the archive when `src/` does (docs/design/bootstrap_sunset.md Step 3).
