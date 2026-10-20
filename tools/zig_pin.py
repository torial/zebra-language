"""The repo's PINNED Zig for Python tools -- the Python half of tools/zig_toolchain.sh.

    import zig_pin            # from tools/ (fuzz/ tools put tools/ on sys.path first)
    ZIG = zig_pin.apply()     # the pinned zig's path; PATH, ZEBRA_ZIG and ZIG_PIN exported

`apply()` puts the pinned zig first on PATH and exports ZEBRA_ZIG, so every zig the tool runs
AND every zig the compiler runs (main.zbr's zigExe() honours ZEBRA_ZIG) is the same one --
standalone as well as under gates.sh, which sources the shell half.

Same resolution as the shell half, first match: $ZEBRA_ZIG_DIR, ~/.zvm/<pin>/, then `zig` on
PATH (CI puts the downloaded toolchain there); the pin is .zig-version unless
ZEBRA_ZIG_VERSION overrides it. The candidate's `zig version` must EQUAL the pin or this
REFUSES (exit 2). That equality is also why two copies of the resolution are tolerable: they
can differ only in WHICH zig of the pinned version they pick, never in the version.

RECEIPT (2026-10-19, hazard_lint H14): a standalone shell tool passed a BUG-596 fixture on the
shared 0.16 that the 0.17 tier failed. The Python tools had the same gap and worse: leakgen,
fuzz/harness.py and mutation_check named the machine's shared default zig (the zvm `bin`
directory, 0.16 here) outright.
"""
import os
import pathlib
import shutil
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent


def pin_version():
    v = os.environ.get("ZEBRA_ZIG_VERSION", "").strip()
    if v:
        return v
    f = REPO / ".zig-version"
    if not f.is_file():
        print(f"zig_pin: no .zig-version at {REPO} and ZEBRA_ZIG_VERSION unset", file=sys.stderr)
        raise SystemExit(2)
    return f.read_text(encoding="utf-8").strip()


def _version(exe):
    try:
        p = subprocess.run([exe, "version"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return ""
    return p.stdout.strip()


def pinned_zig():
    """The pinned zig's path, or SystemExit(2) naming what was found instead."""
    pin = pin_version()
    dirs = []
    if os.environ.get("ZEBRA_ZIG_DIR"):
        dirs.append(pathlib.Path(os.environ["ZEBRA_ZIG_DIR"]))
    dirs += [pathlib.Path.home() / ".zvm" / pin, pathlib.Path("C:/Users/Sean/.zvm") / pin]
    exe = None
    for d in dirs:
        for name in ("zig.exe", "zig"):
            if (d / name).is_file():
                exe = str(d / name)
                break
        if exe:
            break
    if exe is None:
        exe = shutil.which("zig")
    got = _version(exe) if exe else ""
    if got != pin:
        print(f"zig_pin: the pinned Zig is {pin} but the best candidate is '{exe or 'none'}' "
              f"(version '{got or 'none'}').\n  Install it (zvm install {pin}), or set "
              f"ZEBRA_ZIG_DIR to a directory holding Zig {pin}.", file=sys.stderr)
        raise SystemExit(2)
    return exe


def apply():
    """Resolve the pin and export it into this process's environment (children inherit)."""
    exe = pinned_zig()
    os.environ["PATH"] = os.path.dirname(exe) + os.pathsep + os.environ.get("PATH", "")
    os.environ["ZEBRA_ZIG"] = exe
    os.environ["ZIG_PIN"] = pin_version()
    return exe


if __name__ == "__main__":
    print(apply())
