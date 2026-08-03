import pathlib
import re
import subprocess

REPO = pathlib.Path(r"C:\Projects\zebra-language")
BASH = r"C:\Program Files\Git\bin\bash.exe"

DOC_GEN = re.compile(r"<!--\s*doc-gen:\s*(.+?)\s*=\s*(.+?)\s*-->")


def oracle(cmd):
    return subprocess.run([BASH, "-c", cmd], cwd=str(REPO),
                          capture_output=True).stdout.decode().strip()


# Re-derive EVERY doc-gen count in one pass rather than hand-patching the three that are
# currently stale. Hand-patching is how the fourth gets missed.
n = 0
for f in list(REPO.glob("*.md")) + list(REPO.glob("docs/*.md")) + \
         list(REPO.glob("tools/*.sh")) + list(REPO.glob("tools/*.py")):
    if f.name == "doc_lint.py":
        continue
    s = f.read_text(encoding="utf-8", errors="replace")
    out = s
    for m in DOC_GEN.finditer(s):
        claimed, cmd = m.group(1).strip(), m.group(2).strip()
        got = oracle(cmd)
        if got and got != claimed:
            # Replace the claimed number in the visible prose AND in the marker.
            old_marker = m.group(0)
            new_marker = old_marker.replace(f"doc-gen: {claimed} =", f"doc-gen: {got} =", 1)
            # The prose number sits before the marker on the same line.
            line_start = out.rindex("\n", 0, out.index(old_marker)) + 1
            line = out[line_start:out.index(old_marker) + len(old_marker)]
            new_line = re.sub(rf"(?<![\d]){re.escape(claimed)}(?![\d])", got, line, count=1)
            new_line = new_line.replace(old_marker, new_marker)
            out = out[:line_start] + new_line + out[out.index(old_marker) + len(old_marker):]
            n += 1
            print(f"  {f.name}: {claimed} -> {got}")
    if out != s:
        f.write_text(out, encoding="utf-8", newline="\n")

print(f"refreshed {n} doc-gen count(s)")
