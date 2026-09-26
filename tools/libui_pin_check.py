#!/usr/bin/env python3
"""libui_pin_check -- is the zig-libui-ng commit the compiler pins USABLE by a stranger?

`--gui-backend=libui_ng` scaffolds a project whose build.zig.zon fetches zig-libui-ng
at ONE commit, written into selfhost/main.zbr (and its generated main.zig). Every
libui_ng program anyone builds from a clean machine gets exactly that commit. This
gate asks the three questions that decide whether that works:

  1. do main.zbr and the generated main.zig pin the SAME commit?  (main.zig is what
     the shipped binary is built from; rc2 shipped with the two disagreeing)
  2. is the pinned commit PUBLISHED -- reachable from main on the public repo?
     (a pin to an unpushed commit fails the stranger's fetch)
  3. does every `_ui.X` / `_ui.X.Y` / `_sci.X...` the libui section references exist
     in the bindings AT THAT COMMIT?  (the section is emitted whole; one missing decl on
     its shared render path fails EVERY program, even a two-button counter)

WHY IT EXISTS (2026-09-25). On main, every libui_ng program failed to build for anyone
without ZEBRA_LIBUI_PATH -- 14 compile errors, counter.zbr included -- because the pin had
been silently reverted to the July commit 93c7f54b TWICE (c203114 on 09-14, b0e52c3 on
09-24), each time inside a large unrelated commit, and the section had meanwhile started
using tree/toolbar/clipboard/tooltip calls that exist only in newer (then UNPUSHED)
zig-libui-ng commits. Nothing could see it: `libui-section` and zebra-ide's check.sh both
compile against the LOCAL CHECKOUT, never against the pin. This checks the pin.

THE ORACLE IS THE PUBLIC REPOSITORY, not a local clone: a blobless bare clone cached in
.zig-cache/libui-pin-check/ and fetched every run, so "published" means published and a
stale local remote-tracking ref cannot pass for it. LIBUI_REPO=<path to a git clone>
overrides it for an offline machine; the report then says which oracle it used and that
"published" means that clone's `origin/main`, which may lag.

Exit: 0 = pin usable; 1 = pin NOT usable (the failure names what and why); 2 = REFUSED
(could not measure -- offline with no override, extraction collapsed, or a control
stopped discriminating). A refusal is never a pass.
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = "https://github.com/torial/zig-libui-ng"
SECTION = os.path.join(REPO, "selfhost", "gui_libui_ng_section.zig")
PIN_RE = re.compile(r"zig-libui-ng\?ref=main#([0-9a-f]{40})")
REF_RE = re.compile(r"\b(_ui|_sci)\.([A-Z][A-Za-z0-9_]*)(?:\.([A-Za-z_][A-Za-z0-9_]*))?")
GUARD_RE = re.compile(r'@hasDecl\((_ui|_sci)\.([A-Za-z0-9_]+),\s*"([A-Za-z0-9_]+)"\)')
MIN_REFS = 100          # the section references ~136 today; far fewer = extraction broke

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")


def refuse(msg):
    print(f"libui-pin: REFUSED -- {msg}")
    sys.exit(2)


def git(*args, cwd=None, check=False):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()[:300]}")
    return r


def read(path):
    with open(path, encoding="utf-8", errors="replace", newline="") as f:
        return f.read()


def pins():
    """The pinned sha in each of main.zbr / main.zig; refuse if either cannot be read."""
    out = {}
    for name in ("main.zbr", "main.zig"):
        p = os.path.join(REPO, "selfhost", name)
        found = sorted(set(PIN_RE.findall(read(p))))
        if not found:
            refuse(f"no zig-libui-ng pin found in selfhost/{name} -- the pattern stopped matching")
        if len(found) > 1:
            print(f"libui-pin: FAIL -- selfhost/{name} pins MORE THAN ONE commit: {found}")
            sys.exit(1)
        out[name] = found[0]
    return out


def oracle():
    """(git_dir, main_ref, description). Fetches the public repo into a cached blobless
    bare clone unless LIBUI_REPO names an existing clone."""
    override = os.environ.get("LIBUI_REPO")
    if override:
        if git("rev-parse", "--git-dir", cwd=override).returncode != 0:
            refuse(f"LIBUI_REPO={override} is not a git repository")
        return override, "refs/remotes/origin/main", (
            f"LOCAL clone {override} (published = its origin/main, which may lag GitHub)")
    cache = os.path.join(REPO, ".zig-cache", "libui-pin-check", "repo.git")
    if not os.path.isdir(cache):
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        r = git("clone", "--bare", "--filter=blob:none", "--quiet", URL, cache)
        if r.returncode != 0:
            refuse(f"cannot clone {URL} (offline?). Set LIBUI_REPO=<a zig-libui-ng clone> "
                   f"to check against it instead.\n  git: {r.stderr.strip()[:200]}")
    r = git("fetch", "--quiet", "--filter=blob:none", "origin",
            "+refs/heads/*:refs/heads/*", cwd=cache)
    if r.returncode != 0:
        refuse(f"cannot fetch {URL} (offline?). Set LIBUI_REPO=<a zig-libui-ng clone>.\n"
               f"  git: {r.stderr.strip()[:200]}")
    return cache, "refs/heads/main", f"PUBLIC {URL} (fetched now)"


def bindings_text(gitdir, sha):
    """Every .zig file under src/ at `sha`, concatenated. Blobs are fetched lazily."""
    r = git("ls-tree", "-r", "--name-only", sha, "--", "src", cwd=gitdir)
    files = [f for f in r.stdout.split() if f.endswith(".zig")]
    if not files:
        refuse(f"no src/*.zig at {sha[:8]} -- not a zig-libui-ng tree?")
    return "\n".join(git("show", f"{sha}:{f}", cwd=gitdir, check=True).stdout for f in files)


def declared(name, text):
    """A name counts as declared if something binds it: fn / const / var (incl. extern
    and pub forms) or a container field `name:`. Loose on purpose -- the failure this
    gate hunts is a name that appears NOWHERE at the pin, not a subtle kind mismatch."""
    return re.search(rf"(?:\bfn|\bconst|\bvar)\s+{re.escape(name)}\b|^\s*{re.escape(name)}\s*:",
                     text, re.M) is not None


def section_refs(section):
    guarded = {(m[0], m[1], m[2]) for m in GUARD_RE.findall(section)}
    refs = set()
    for mod, a, b in REF_RE.findall(section):
        if b and (mod, a, b) in guarded:
            continue        # behind @hasDecl: legitimately optional at an older pin
        refs.add((mod, a, b))
    return refs, guarded


def container_bodies(name, text):
    """Every `{ ... }` body of a `const <name> = <opaque|struct|...> {`, by brace counting.
    ALL of them, not the first: names repeat across files (extras.zig nests small
    `Checkbox`/`Image` structs beside the real input.Checkbox / table.Image that ui.zig
    re-exports), and taking the first match reported `_ui.Checkbox.New` missing at a pin
    where it plainly exists -- a false red is how a gate earns being ignored. Empty when
    <name> is only an alias (`const Draw = @import("draw.zig")`)."""
    out = []
    for m in re.finditer(rf"\bconst\s+{re.escape(name)}\s*=\s*(?:extern\s+|packed\s+)?"
                         rf"(?:opaque|struct|union|enum)\b[^{{;]*\{{", text):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            c = text[i]
            depth += (c == "{") - (c == "}")
            i += 1
        out.append(text[m.end():i - 1])
    return out


def missing(refs, text):
    """A member B of container A is looked up INSIDE A's body when A is an inline
    container. Looking it up anywhere was the first version, and it missed
    `_ui.Tab.Selected` because `Combobox.Selected` exists: a name present on the wrong
    type is exactly as absent as one present nowhere."""
    out = []
    for mod, a, b in sorted(refs):
        if not declared(a, text):
            out.append(f"{mod}.{a}")
        elif b:
            bodies = container_bodies(a, text)
            if not (any(declared(b, x) for x in bodies) if bodies else declared(b, text)):
                out.append(f"{mod}.{a}.{b}")
    return sorted(set(out))


def main():
    p = pins()
    zbr, zig = p["main.zbr"], p["main.zig"]
    print(f"libui-pin: main.zbr pins {zbr[:10]}, generated main.zig pins {zig[:10]}")
    if zbr != zig:
        print("libui-pin: FAIL -- source and generated compiler pin DIFFERENT commits. The binary "
              "is built from main.zig, so the shipped pin is main.zig's. Regenerate "
              "(bash tools/rebuild.sh) after editing the pin in main.zbr.")
        sys.exit(1)
    sha = zbr

    section = read(SECTION)
    refs, guarded = section_refs(section)
    if len(refs) < MIN_REFS:
        refuse(f"extracted only {len(refs)} binding references from the section (floor "
               f"{MIN_REFS}) -- the reference pattern stopped matching")

    gitdir, main_ref, desc = oracle()
    print(f"libui-pin: oracle = {desc}")

    if git("cat-file", "-e", f"{sha}^{{commit}}", cwd=gitdir).returncode != 0:
        print(f"libui-pin: FAIL -- pinned commit {sha[:10]} does not exist in the oracle. If it "
              "exists in your local zig-libui-ng, it is UNPUSHED: push zig-libui-ng, then "
              "re-run. Strangers' builds cannot fetch it.")
        sys.exit(1)

    text = bindings_text(gitdir, sha)

    # CONTROLS, derived at run time rather than pinned to today's gap: a name that
    # certainly exists must be found, and a name that certainly does not must be reported.
    # If either stops holding, `declared` has stopped discriminating and every verdict
    # below is meaningless.
    if missing({("_ui", "Window", "New")}, text):
        refuse("control failed: _ui.Window.New not found at the pin -- the declaration "
               "matcher cannot see declarations")
    if not missing({("_ui", "ZzNoSuchDecl", None)}, text):
        refuse("control failed: a nonexistent name was reported as declared -- the matcher "
               "accepts everything")

    gone = missing(refs, text)
    published = git("merge-base", "--is-ancestor", sha, main_ref, cwd=gitdir).returncode == 0

    ok = True
    if not published:
        ok = False
        print(f"libui-pin: FAIL -- {sha[:10]} exists but is NOT reachable from {main_ref} in "
              "the oracle, so a stranger's fetch of `?ref=main#<sha>` may not find it. Push it to main.")
    if gone:
        ok = False
        print(f"libui-pin: FAIL -- {len(gone)} of {len(refs)} binding references in "
              f"gui_libui_ng_section.zig do not exist at the pinned commit {sha[:10]}; every "
              "libui_ng program will fail to compile for anyone without ZEBRA_LIBUI_PATH:")
        for g in gone:
            print(f"    missing: {g}")
        print("  Fix: push zig-libui-ng, then `bash tools/bump_libui_pin.sh <sha>` to a commit "
              "that has them. If you REVERTED the pin because an offline machine could only "
              "build the cached one, do not commit that -- it breaks every stranger.")
    if not ok:
        sys.exit(1)
    print(f"libui-pin: PASS -- pin {sha[:10]} published; all {len(refs)} section references "
          f"exist there ({len(guarded)} @hasDecl-guarded names exempt)")


if __name__ == "__main__":
    main()
