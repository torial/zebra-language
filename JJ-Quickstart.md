# JJ Quickstart — Zebra project (jj 0.40+)

Working notes for jj (Jujutsu) on the Zebra repo, written for both Sean and Claude. The
goal is for the *tool* to handle process-safety, freeing both of us to think about real
work. If `jj <command>` ever surprises you, run `jj <command> --help` — Claude was trained
on an older jj and should defer to actual help output when uncertain.

## Why we adopted jj

Two `git stash` lost-work incidents on this repo (see `wiki/concept_vcs-alternatives`).
jj makes that class of failure structurally impossible: every working state is
automatically a revision — there's no stash, nothing to drop. `jj undo` reverses any
operation. The mental model shift takes ~2 hours; the safety wins are permanent.

---

## Mental model in five lines

1. Every working-copy state is a revision (a "change") with a stable change-id.
2. `@` is the working copy's change. `@-` is its parent. `@--` is the grandparent.
3. There is no staging area. Edits go straight into `@`. To "commit," describe `@` and start a new `@`.
4. `jj op log` records every operation that touched the repo. `jj undo` reverses one. `jj op restore <opid>` jumps to any earlier state.
5. Bookmarks (formerly "branches") are pointers. They don't track the working copy automatically — you `jj bookmark move` them, or use `jj git push -c @-` which auto-creates one.

That's it. Most git muscle memory translates with one rename and the dropped staging area.

---

## One-time setup (already done if `jj st` works in this repo)

```bash
# Verify install
jj --version           # expect 0.40 or later

# In the repo root (C:/Projects/zebra-language)
jj git init            # colocated mode is the default in 0.40+

# Configure identity (one-time, global)
jj config set --user user.name  "Sean McKay"
jj config set --user user.email "your-email@example.com"

# Optional: a more useful default log template
jj config set --user ui.default-command 'log'
```

After `jj git init`, the repo has both `.git` and `.jj` directories. Git tools still work;
jj layers on top.

---

## The daily-workflow shortlist (the 80% case)

| What you want | jj command |
|---|---|
| See the local repo state | `jj st` |
| See history (last ~10 changes) | `jj log` |
| Start fresh work on top of `@` | `jj new` |
| Set the message on the current change | `jj describe -m "feat: …"` |
| "Commit" — describe + start new change | `jj commit -m "feat: …"` |
| Look at changes in the current revision | `jj diff` or `jj show` |
| Pull from GitHub | `jj git fetch` |
| Push the current change to GitHub | `jj git push -c @-` (creates a bookmark for `@-`) |
| Push an existing bookmark | `jj git push -b <bookmark>` |
| Switch focus to an earlier change | `jj edit <change-id>` |
| Undo whatever you just did | `jj undo` |

Notes:

- `jj commit` is the closest analogue to `git commit -am "..."` — it describes the current
  change AND starts a new empty `@` on top of it. Use this when you want a clean
  "commit and continue."
- `jj describe` only updates the message. The change is already real; describing it
  doesn't "advance" anything.
- `jj new` without a target creates a new empty change as a child of `@`. `jj new <id>`
  creates a child of `<id>` (use this to start a side branch).

---

## Stash replacement — there is no stash

You don't need it. The pattern that breaks people coming from git:

> "I'm in the middle of feature X, but I want to try Y on a clean tree."

In git: `git stash` (← this is the dangerous one) `git checkout main` `… work on Y …`
`git checkout feature-X` `git stash pop` (← also dangerous).

In jj:

```bash
# You're on @. Just start Y as a sibling.
jj new main             # creates a new empty change as a child of main
… work on Y …
jj st                   # shows what you've done in Y
# Done with Y; go back to X:
jj edit <X-change-id>   # or jj log to find the id
```

The X work was never lost — it was in its own change the whole time. `jj log` shows
every change, including all your half-done experiments. Nothing has to be "popped."

---

## "I just did something dumb" — the recovery section

| Situation | Fix |
|---|---|
| Last operation was a mistake | `jj undo` |
| Several operations ago was a mistake | `jj op log` to find the bad op, then `jj op restore <prev-opid>` |
| Want to redo a `jj undo` | `jj redo` |
| Abandoned a change you wanted | `jj op log` shows the abandon op; `jj op restore <opid-before-abandon>` |
| Pushed something bad | `jj abandon <id>`, then `jj git push --bookmark <name> --allow-empty`. **Do not** force-push to `main`. Verify before any push. |
| Working copy is messed up | `jj restore` (restores `@` to match its parent's content) |

The op log is your safety net. **Nothing in jj is truly destructive locally** — even
`abandon` is reversible from the op log. The only true point-of-no-return is `jj git
push` to a remote; everything else is recoverable.

---

## Translation table — git → jj

| git | jj | Notes |
|---|---|---|
| `git status` | `jj st` | |
| `git log --oneline -10` | `jj log` | jj's default is reverse-chrono, narrower |
| `git diff` | `jj diff` | shows changes in `@` (working copy) |
| `git diff HEAD~` | `jj diff -r @-` | |
| `git add -A && git commit -m "msg"` | `jj commit -m "msg"` | no staging step needed |
| `git commit --amend` | `jj describe` (just edit the message) or just keep editing — `@` IS the "amendable" commit |
| `git stash` | `jj new` (start a new change; old work is preserved) |
| `git stash pop` | `jj edit <old-change-id>` |
| `git checkout <branch>` | `jj edit <bookmark>` or `jj new <bookmark>` |
| `git switch -c new-branch` | `jj new`; later `jj bookmark create new-branch -r @-` |
| `git push origin HEAD` | `jj git push -c @-` (auto-creates bookmark) or `jj git push -b <name>` |
| `git pull` | `jj git fetch` then `jj rebase -d main` if needed |
| `git rebase -i` | `jj squash`, `jj split`, `jj rebase`, `jj parallelize` (each does part of -i's job) |
| `git reflog` | `jj op log` (much more useful — every op, not just commits) |
| `git reset --hard HEAD` | `jj restore` |
| `git revert <commit>` | `jj revert <change>` |

---

## Bookmarks (branches) — what changed

In jj, **bookmarks are passive pointers**. They don't track `@` automatically — that's
the source of git's "wrong-branch commit" foot-gun, and jj eliminates it by making
the relationship explicit:

```bash
jj bookmark list            # show local bookmarks (alias: jj b l)
jj bookmark create <name>   # create at @-  (use -r <id> for a different revision)
jj bookmark move <name> --to @-   # advance an existing bookmark
jj bookmark delete <name>   # mark for deletion on next push
```

For our workflow, the simplest path is:

1. Just keep working — `jj new`, `jj describe`, etc.
2. When ready to push: `jj git push -c @-` (auto-creates a bookmark named after the change-id)
3. Or, if you want a meaningful name: `jj bookmark create feat/typecheck-merge -r @-` then `jj git push -b feat/typecheck-merge`

The `main` bookmark from the git side becomes a normal jj bookmark. `jj git fetch` updates it.

---

## Agent-specific notes (Claude reading this)

### Always-OK commands
`jj st`, `jj log`, `jj diff`, `jj show`, `jj op log`, `jj bookmark list` — read-only, never destructive.

### Verify-before-running commands
`jj git push` (any variant) — same caution as `git push`. Confirm bookmark + revision before running.

`jj abandon <id>` — local-only and reversible via op log, but still ask before discarding work that has any chance of being intentional.

`jj rebase` — fine on local-only history; ask before rebasing anything that's been pushed.

### Never run without explicit instruction
`jj git push --force-with-lease` / any forced push.
Anything that touches `main` directly (push, bookmark move, etc.) — match the git rule.

### Replacing the dangerous git habits
- **Never reach for `git stash` reflexively.** `jj new` is the answer. The previous state is preserved as `@-` automatically.
- **Never `git reset --hard`.** `jj restore` is the equivalent for the working copy; for "go back N operations" use `jj op restore`.
- **Never assume "uncommitted changes" needs handling.** In jj there's no such thing — the working copy is already a change.

### When uncertain
1. Run `jj st` and `jj log` to ground yourself in current state.
2. Run `jj <subcommand> --help` if the syntax has changed (jj moves fast; my training data is older than 0.40).
3. Check `jj op log` if something went wrong; the last entry tells you what to undo.

### Failure mode to watch
**Git operations done outside jj** (e.g., `gh pr create` may operate on `.git/` directly).
After running git tools, do `jj git import` to re-sync jj's view. In colocated mode this
is usually automatic, but it's worth a `jj st` after any git-side change to verify.

---

## Cheat sheet — most-used commands one more time

```bash
jj st                            # what's the state?
jj log                           # what happened recently?
jj op log                        # what did I just do?
jj new                           # start fresh on top of current
jj describe -m "msg"             # set message on current change
jj commit -m "msg"               # describe + start new empty change
jj diff                          # what changed in @
jj undo                          # whoops
jj git fetch                     # pull from GitHub
jj git push -c @-                # push current with auto-bookmark
```

---

## Where this file lives

Initially in `C:/Projects/zebra-language/JJ-Quickstart.md` — local to the Zebra repo
while we evaluate. If jj sticks for a couple weeks of real use, promote to a global
reference (probably under `C:/Users/Sean/wiki/pages/concepts/concept_jj-quickstart.md`
plus a pointer in global `CLAUDE.md`).

## Further reading

- Official tutorial: `jj help -k tutorial` (or https://docs.jj-vcs.dev/latest/tutorial/)
- Operation log: https://docs.jj-vcs.dev/latest/operation-log/
- Bookmarks: `jj help -k bookmarks`
- The wiki page that prompted this: `C:/Users/Sean/wiki/pages/concepts/concept_vcs-alternatives.md`
