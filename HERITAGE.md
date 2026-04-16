# Heritage

This repository was split out from `torial/cobra-language` on **2026-04-16**.

## Background

The work that became Zebra started in late 2025 / early 2026 as a Zig-backend
port inside the Cobra language repository, on a branch called `zig_backend`
under a subdirectory `zig-compiler/`. Over the course of ~70 commits the
subproject grew into its own distinct language:

- A new compiler written in Zig (not Cobra).
- A new language (Zebra, `.zbr`) whose syntax takes cues from Cobra but whose
  semantics, runtime, and error model are Zig-flavored (error unions,
  allocator-passing, Zig-style tagged unions).
- A self-hosting effort in which the Zebra compiler is being re-implemented
  in Zebra itself.

By April 2026 the Zebra work had no remaining code path through the original
Cobra compiler or runtime, and the shared repository was no longer pulling
its weight. This split preserves Zebra's authentic commit history while
letting it stand on its own.

## What's in this repo

Only the `zig-compiler/` subtree — promoted to the root — and its history.
Commit hashes here differ from the old repo (paths were rewritten by
`git filter-repo`), but commit messages, authors, dates, and parent
relationships among the preserved commits are intact.

Stray build artifacts (`.exe`, `.pdb`, `.lib`, `.obj`, `.dll`) that had been
accidentally committed in the pre-split history were stripped in the same
filter-repo pass.

## What's not in this repo

- The original Cobra-for-.NET compiler (`Source/`, `Source/Cobra.Core/`,
  `Source/Snapshot/`, `Source/BackEndClr/`, `Source/BackEndZig/` — the
  Cobra-hosted stub of the Zig backend).
- The Cobra standard library, tutorials (`HowTo/`), and test corpus (`Tests/`).
- Any commit on the original `master` branch (those predate the Zebra work
  by many years and are orthogonal to this project).

## Where the old history lives

The pre-split repository remains at **`torial/cobra-language`** on GitHub,
with a tag **`archive/pre-zebra-split`** marking the exact commit on
`zig_backend` at the moment of the split. Anyone needing the combined
history — e.g. the original `.NET` Cobra compiler alongside the Zig-backend
experiments — can `git checkout archive/pre-zebra-split` there.

## Relation to the original Cobra language

Cobra (Chuck Esterbrook, ~2005–2013; `torial` and others subsequently) is a
.NET/Mono language combining ideas from Python, C#, Objective-C, and Eiffel,
with a focus on quality (contracts, nil tracking, tests-as-first-class).
Zebra inherits some of that surface syntax — significant indentation, `def`
for functions, `var` for locals, `prop` for properties, contracts — and its
spirit of quality-focused design. It does **not** inherit Cobra's type
system, runtime, standard library, or backend.
