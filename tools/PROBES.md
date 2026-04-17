# Probe & Snapshot Conventions

Short reference for the two verification tools that live in `tools/`.

## 1. `corpus_snapshot.sh` — file-level emit snapshots

Walks `test/*.zbr` (top-level only), runs `--emit-zig` per file via the chosen
backend(s), and writes a diff-able TSV:

```
file<TAB>backend<TAB>exit<TAB>content_sha<TAB>stderr_sha
```

- `exit` = `--emit-zig` exit code. `0` = pass.
- `content_sha` = first 12 hex of sha256 of emitted Zig stdout. `-` on fail.
- `stderr_sha` = first 12 hex of sha256 of stderr. Clusters failures by class.

### Usage

```bash
# before a wave edit:
tools/corpus_snapshot.sh /tmp/pre.tsv              # zig backend
tools/corpus_snapshot.sh --selfhost /tmp/pre-sh.tsv
tools/corpus_snapshot.sh --both     /tmp/pre-both.tsv

# after the wave edit:
tools/corpus_snapshot.sh /tmp/post.tsv

# any shift = a file whose behaviour moved:
diff /tmp/pre.tsv /tmp/post.tsv
```

A changed `content_sha` with `exit=0` on both sides is the sneaky case: emit
changed silently. A flipped `exit` is a regression or a new pass. Cluster
failures by `stderr_sha`.

### Non-goals

- Does **not** compile emitted Zig. Use `tools/bootstrap_check.sh` for the
  full round-trip gate.
- Does **not** diff content line-by-line. If a `content_sha` shifts, re-emit
  the specific file by hand and diff the Zig.
- Recurses only one level deep — subdirectories under `test/` are excluded
  so sweep runtime stays bounded.

## 2. Golden-emit probes

Small `.zbr` files, usually living in `C:\tmp\verify_<bug-id>.zbr` or
`C:\tmp\<topic>\`, whose purpose is to pinpoint a single emit behaviour.

### Naming

- `verify_bug<NNN>.zbr` — tied to a specific BUGS.md entry. Always name-link
  to the bug in the file's header comment.
- `verify_<topic>.zbr` — rule-level probe (e.g. `verify_ref_struct.zbr`,
  `verify_selfref.zbr`). Test a rule rather than a single bug.

### Header comment convention

```zebra
# BUG-041 verify: ^ClassType? must emit ?*T (not ?**T).
# Expected stdout after compile+run: "count=3"
# Companion rule in wiki: concept_zebra-class-auto-box-rule
```

One line per: what it probes, expected observable output, related rule/bug.
Future-you skims the header and knows what the probe is for.

### Execution

```bash
# emit only:
zig-out/bin/zebra.exe --emit-zig C:/tmp/verify_bug041.zbr > /tmp/v.zig

# full compile + run (zig backend):
zig-out/bin/zebra.exe C:/tmp/verify_bug041.zbr

# selfhost counterpart (from repo root — selfhost needs relative preamble path):
zig-out/bin/zebra-selfhost.exe --emit-zig C:/tmp/verify_bug041.zbr 2>/tmp/v.zig >/dev/null
```

Selfhost writes emit output to **stderr** (Zig's `std.debug.print` default).
Redirect `2>` to capture; `>/dev/null` swallows the unrelated stdout noise.

### Promoting a probe to the in-tree golden set

When a probe proves to be load-bearing (it catches a rule violation under
several reasonable-looking edits), promote it:

1. Copy the `.zbr` into `test/` with a descriptive name (not `verify_bugNNN`
   — at that point it's a rule test, not a bug probe).
2. Emit it through the zig backend and commit the `.zig` alongside the
   `.zbr` (same pattern the existing `test/*_test.zig` golden files follow).
3. It then rides on every `corpus_snapshot.sh` run and surfaces in diffs
   automatically.

`test/recursive_type_test.zbr` / `.zig` is an example of a promoted probe
(originally filed as part of LANG-003; now the load-bearing golden for
BUG-041's rule).

## When to reach for which tool

| Situation                                      | Tool                         |
|-----------------------------------------------|------------------------------|
| About to start a wave edit (compiler change) | `corpus_snapshot.sh` before + after |
| Fixing a specific bug, need a minimal case   | hand-written probe in `C:\tmp\` |
| Rule-level assertion, want it to ride with CI | promote probe into `test/`  |
| Round-trip / bootstrap convergence            | `tools/bootstrap_check.sh`  |
| Emit-only quick check                         | `corpus_snapshot.sh --both` |
