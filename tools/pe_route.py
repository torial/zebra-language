"""pe_route.py FILE -- print the BUILD ROUTE fingerprint of a Windows PE image, one line.

Used by cli_check.sh's "one link decision" leg (BUG-720 / BUG-747). That leg asked the run path
and `--emit-exe` to build BYTE-IDENTICAL executables, and the premise is false on Windows: zig's
self-hosted (fast) backend is not byte-reproducible. Two `--emit-exe` builds of one program at
one path differed 2 times in 26, cold or warm -- `SizeOfImage` and `.text`'s VirtualSize, and once
the whole layout from the entry point on (2026-11-16). What stayed fixed across every differing
pair is what tells the ROUTE apart: the file size (the self-hosted linker preallocates), the
linker version in the optional header (0.0 there; LLD writes its own), and the section names.
An LLVM/LLD build of the same program differs in all three.

Prints `pe size=<n> linker=<maj>.<min> sections=<a,b,...>`, or `not-pe` for anything else (the
caller then compares bytes, as before). Exits 2 on a truncated or malformed PE header: a
fingerprint that could not be read must never compare equal to one that was.
"""
import struct
import sys


def fingerprint(path):
    data = open(path, "rb").read()
    if data[:2] != b"MZ":
        return "not-pe"
    lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[lfanew:lfanew + 4] != b"PE\0\0":
        raise ValueError("no PE signature at e_lfanew")
    nsec = struct.unpack_from("<H", data, lfanew + 6)[0]
    opt_size = struct.unpack_from("<H", data, lfanew + 20)[0]
    opt = lfanew + 24
    table = opt + opt_size
    if nsec == 0 or table + 40 * nsec > len(data):
        raise ValueError("section table out of range")
    names = [data[table + 40 * k: table + 40 * k + 8].rstrip(b"\0").decode("ascii", "replace")
             for k in range(nsec)]
    return "pe size=%d linker=%d.%d sections=%s" % (len(data), data[opt + 2], data[opt + 3], ",".join(names))


def main():
    if len(sys.argv) != 2:
        print("usage: pe_route.py FILE", file=sys.stderr)
        return 2
    try:
        print(fingerprint(sys.argv[1]))
    except (OSError, ValueError, struct.error) as e:
        print("pe_route: cannot read %s: %s" % (sys.argv[1], e), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
