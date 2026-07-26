# Tears of the Tuon — Zebra/GameEngine port

A faithful port of a C# console RPG (interview brief: *"make a console based RPG
that allows the characters to attack with 2 different items"*) to Zebra + the
GameEngine MVU GUI. Source of truth for the mechanics:
`C:\Projects\TearsOfTheTuon` (`Engines/CombatEngine.cs` + the weapon/entity JSON).

## Play it

```bash
# In a real terminal (the TUI needs a console):
zig build                                            # build the compiler
zig-out/bin/zebra.exe --gui-backend=tui examples/tears_of_the_tuon.zbr
# q / Q / Esc to quit.
```

`--gui-backend=stub examples/tears_of_the_tuon.zbr` (or plain `zebra run …`)
renders one frame non-interactively — useful for smoke-checking, not for playing.

## What it is

Yehu (the hero) faces two Ruffians on the mountain road — the roster from the
original story map (`EnemiesList = "Ruffian,Ruffian"`). Each combatant attacks
with one of **two weapons**; the difficulty you pick (Easy/Medium/Hard) changes
initiative, hit odds, enemy AI, and flee odds. Win to earn experience; flee to
bail. It is turn-based: pick a weapon, pick a target, then step the enemies.

## Faithful mechanics (ported from `CombatEngine.cs`)

- **Hit roll:** `nextFloat()*attackerAgility` vs `nextFloat()*victimAgility`;
  miss if the attack roll is lower. Difficulty always favours the player
  (Easy `+2`, Hard `-2` to the player's side of the roll).
- **Crit:** `nextFloat()*100 <= weapon.critChance` → crit damage.
- **Damage:** `weaponDamage + ((rollDelta + strength) / 4) - (armor / 4)`.
  The C# original wrote `damage += (int)(attackRoll-defenseRoll) + Strength>>2`;
  `>>` binds *looser* than `+` in C#, so that is `((rollDelta+strength) >> 2)`,
  i.e. `/4` for the non-negative operands here. Ported with explicit parentheses.
- **Initiative:** Easy = player first, Hard = enemy first, Medium = higher total
  agility first.
- **Enemy weapon AI:** Easy picks the weakest weapon, Hard the strongest
  (`damage + critChance*critDamage`), Medium a seed-derived pick.
- **Flee:** `nextFloat()*ΣplayerAgility` vs `nextFloat()*ΣenemyAgility`
  (`+3`/`-3` by difficulty).
- **Weapons:** sword (stabs, 15, crit 20%→25), bow (shoots, 12, 15%→25),
  dagger (stabs, 10, 10%→20). **Entities:** Yehu (agi 25, str 15, armor 10,
  35 HP, sword+bow), Ruffian (agi 15, str 10, armor 10, 20 HP, bow+dagger,
  25 killExp).

### Deliberate divergence from the original

The C# code did `new Random((int)DateTime.Now.Ticks)` inside **every** roll,
which correlates rolls made within one tick. This port carries a single seeded
stream in the model and advances it each turn — a strictly better, still
deterministic source. Don't "fix" it back to per-roll reseeding.

## Architecture

Single file, two layers:

1. **Pure combat core** (top of the file): `Weapon`, `resolveAttack`,
   `weaponScore`, `chooseEnemyWeapon`, `tryFlee`, `playerFirst` — all
   *seed-in / result-out*, no GUI dependency. These are what the test pins.
2. **MVU app**: `GameModel` / `Msg` / `init` / `update` / `view`. `update` is a
   pure `(model, msg) → model`; RNG is threaded through `model.rngSeed`, each
   randomness-using step storing the advanced seed back.

**Why one file, not a module + app?** The `--gui-backend=tui` scaffold does not
resolve `use`'d Zebra modules (it references `dep.zig` but never copies it into
the build — see below). So a GUI app must be self-contained. The test still gets
real coverage without duplication by `use`-ing the app and importing only its
pure functions (a non-GUI program *can* resolve the dependency).

## Test

```bash
zig-out/bin/zebra.exe run examples/tears_combat_test.zbr
# → tears_combat_test: OK  (… hits / … misses; easy N vs hard M; won in K steps …)
```

`examples/tears_combat_test.zbr` `use`s the app and asserts the exact ported
numbers with fixed seeds: weapon/entity data, `weaponScore`, the enemy weapon AI,
determinism of `resolveAttack`, the damage floor, "Easy lands ≥ Hard hits" (the
difficulty bonus), initiative, and an **end-to-end FSM run** that drives `update`
through a full Easy battle to victory. It is co-located in `examples/` (not the
gated `test/` suite) so it can resolve the app by module name; run it manually.

## Compiler gaps found — now dissolved

Dogfooding this port surfaced three **bootstrap-lags-selfhost** gaps
(`BUGS.md` BUG-204/205/206). They bit only the *bootstrap-delegated* GUI path:
`--gui-backend=tui` used to hand the whole build to `zebra-bootstrap.exe`, whose
older parser/codegen rejected forms the primary selfhost compiler accepts —
- **BUG-204** — return-position `except` (`return x except …`);
- **BUG-205** — a var *initialized with* `except` then reassigned;
- **BUG-206** — `.toInt()` on a float whose operands were reassigned.

These are **gone for this example**: `--gui-backend=tui` now emits + scaffolds
through the **selfhost itself** (no bootstrap delegation), so the natural forms
compile directly. The workarounds have been removed — the code above is written
plainly. (See NEXT_STEPS "GUI builds via selfhost emission" for the mechanism.)

Two language notes worth keeping:

- **List field of an `except`-copied model is `*const`** — `m.log.add(…)` won't
  compile. The `withLog` helper copies the list, appends, and re-binds it
  (`m except log = lg`) — the functional-update idiom.
- **Integer division is `/`** (truncating on ints). `//` is tokenized but not
  wired as an operator in either parser, and there is no `>>`; `/4` is the
  faithful stand-in for the original's `>>2`.

## Maintainer notes

- All numeric tuning lives in the pure functions and the `init` roster — change
  a weapon stat in one place and the test will tell you what moved.
- If BUG-204/205/206 are fixed, the inline workarounds can be simplified back to
  the natural forms (return-position `except`, `except`-init vars, unannotated
  `.toInt()`), but there's no functional need to.
- The game is deterministic per starting seed (`init` draws one from the global
  PRNG). For a reproducible playthrough, hardcode `rngSeed` in `init`.
