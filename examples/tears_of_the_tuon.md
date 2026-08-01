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

Plain `zebra run …` renders one frame non-interactively — useful for
smoke-checking, not for playing. (**Not** `--gui-backend=stub`: as of
2026-07-30 that flag still delegates the build to `zebra-bootstrap.exe`, whose
older parser rejects this file's return-position `except` — the BUG-204 form
the selfhost accepts. `zebra run` and the test path go through the selfhost.)

## What it is

The game now carries **story + combat**. It opens on the ported intro scene
from the original story project (Namal's order, Chief Gratta at Arna, Gor and
Kav mustering — `MapCreationHelper.cs` Scene ID=1, text faithful), through the
scene's one choice ("Get the Cubs"), across a marked port-added bridge page to
the mountain road, where Yehu (the hero) faces two Ruffians — the roster from
the original story map (`EnemiesList = "Ruffian,Ruffian"`). Each combatant
attacks with one of **two weapons**; the difficulty you pick (Easy/Medium/Hard)
changes initiative, hit odds, enemy AI, and flee odds. Win to earn experience
and continue into a three-page epilogue (the first **Fable-composed** material
in this world — the attachment point for authored episodes); flee to bail.

## The Valley of ArnasThas (added 2026-07-30)

The original game's **30×80 tile map**, extracted mechanically from
`MapCreationHelper.cs` (zero hand-transcription) and walked in phase 11:
choose a difficulty and Yehu sets out from Arna (5,25) for Thas (the `T`,
73,13). Movement is N/S/E/W over the passable set `=.^ATHC`; **travel heals**
by difficulty (easy +2, medium +1, hard +0 per step — the original's
healing-while-traveling); the **eleven canonical combat points** from the C#
bulk-add ambush once each (fresh Ruffians, initiative by difficulty, victory
returns to the road via "Walk on"); reaching Thas enters the
epilogue → mission → feast chain. The BFS road from Arna to Thas is 90 steps
and crosses four of the eleven ambush points.

**Difficulty note, honestly earned:** on Medium the enemies' agility-sum
(30 vs 25) makes the Ruffians strike first at every ambush, and the
playthrough driver lost the first ambush five seeds running before switching
to Easy. That is the faithful math, not a bug — the road to Thas on Medium
is genuinely dangerous.

## Leveling and Save/Load (added 2026-07-30 — feature parity)

The C# ReadMe's remaining feature-list items, ported faithfully:

- **Leveling** (`ApplyExperienceToPlayer` + the Human EntityType JSON):
  thresholds 0, 100, 200, 400 … doubling to 409,600; level up **while**
  `xp > levels[level-1]` (quirk-faithful: the 0 threshold means any victory
  levels a fresh hero to 2); each level grants **+3 agility, +3 max HP,
  +3 strength**, which feed the real combat rolls, flee rolls, initiative,
  and the travel-healing cap. The valley campaign reaches the gates of Thas
  at Level 3 with 200 XP.
- **Save/Load** (`Save/New/Open`, ported small): "Make camp (save)" on the
  map writes a one-field-per-line save (`tears_save.txt`, gitignored);
  "Resume a recorded journey" on the title loads it back onto the map with
  stats, position, and consumed-ambush flags intact (round-trip tested).
  File IO inside `update()` is a deliberate, confined MVU impurity.

Still absent from the original's list: sound (out of scope for the TUI) and
the per-location story scenes beyond the intro (the criteria machinery is
ready for them).

## Story layer (added 2026-07-30)

- **Scene data are pure functions** — `introPage(i)` / `epiloguePage(i)` return
  one string per page, `|`-separated display lines. This is the episode-
  authoring surface: adding an episode means adding page functions and an FSM
  hook, no engine work.
- **Phases 7 (intro) and 8 (epilogue)** extend the FSM; all pre-existing phase
  numbers and the pure combat core are untouched.
- **The choice is structural:** `pageNext` stops at the muster page — only
  `Msg.getCubs` passes it. The FSM requires the scene's choice; the view's
  buttons merely reflect that.
- **Faithfulness note:** intro text is the C# scene's text lightly re-wrapped
  for the TUI; the image callouts (`namalBW.jpg`) become bracketed captions.
  The ArnaThas tile-map walk between intro and combats is **not yet ported**
  (the original plays these scenes at map locations); the bridge page stands
  in for it and is marked as port-added in the source.

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
through a full Easy battle to victory — plus a **story-FSM walk**: intro pages →
choice-page hold (`pageNext` can't skip it) → "Get the Cubs" → bridge → title,
and victory → epilogue → last-page hold. It is co-located in `examples/` (not the
gated `test/` suite) so it can resolve the app by module name; run it manually.
The 2026-07-30 story additions left every combat number identical (140/60 hits,
victory in 4 steps on the fixed seed) — the pure core is untouched.

## Mission: The Cubs of Thas (added 2026-07-30)

The first **composed** mission — the untold interior of Episode I. The novella
(ch. 5–6) sends Commander Yehu's score into Thas by the slave-ruse and then
follows Gratta; the infiltration happens offstage. The mission plays that
interior, contradicting nothing: Aidden's haggling at the gate, the split of
the score, the pen with its fifty guards, the barel's judgment, Gratta at the
gate-beam, Namal's flaming spear at the bridge. Its moral spine is Keanna's
rebuke — the battle is won by *waiting for the sign*, not by the strength of
the score.

- Entry: the epilogue's last page → "Play the finale — The Cubs of Thas"
  (phase 9; `model.story` = scene id).
- **Flags ride `model.states`** (`hasFlag`/`withFlag`) — the DecisionEngine
  criteria idea, ported small: Split, Alarm, Waited/Struck, CubsFree,
  SavedKeanna select among **three endings** (The Faithful Score / Valor and
  Graves / The Unbent Line).
- Deterministic and pure (`missionStep`); the test walks both the canonical
  path and the valor path.
- Zebra note: an empty-list literal in a constructor argument emits a
  never-mutated Zig temp (compile error) — hoist it
  (`var noFlags: List(str) = []`) and pass the variable.

## The Dispute of Sword and Bow (added 2026-07-30)

After the mission's ending, the victory feast hosts a **playable
dispute-poem** (phase 10) — the oldest literary genre on record (the
Mesopotamian precedence-contest: Hoe vs Plough, Sheep vs Grain), carried by
Syriac into the church (Ephrem's Death-and-Satan debates) and by the church
into Europe (The Owl and the Nightingale). Composed by Fable in the tale's own
idiom: the Sword and the Bow trade boasts **citing the game's real mechanics**
(15 dmg / crit 1-in-5 for 25 vs 12 dmg / crit ~1-in-7 for 25), and the player
holds the genre's load-bearing slot — **the verdict**. Crown the Sword or the
Bow (the Sumerian ending: one crowned, one bowed) or take the third voice the
tradition's own history offers: crown neither boaster, and honor the Giver of
the day. The test walks the boasts to the Third Voice verdict.

## Interlude: The Judge of the Ashes (wired 2026-07-30)

The first **non-Yehu playable**: Keanna, returning into judged Thas — canon's
own errand ("I must go to my people now, and minister to those that
survive"; "find the Witness of Thas... for his clan needs him"). Phase 14,
offered from the feast's last page; no combat — *mercy has no hit roll*.
Triage at the well (her jailers, dying, against a pinned weaver and her
kits), the spared maeuw asking for orders, the gold tent's still-chained
slaves and the keys no one dared touch, the Witness writing the names of the
dead — and the **qinah**: the game's second playable ancient form, a lament
the player composes verse by verse with the mothers at the burial trench.
Design law: **a lament has no wrong verses** — the opening and the hard
question are never scored; only the final *turn* (toward trust, or toward
waiting in the ashes) colors the ending, and both closings are honest ("it
is addressed to him — and that is prayer"). The ending is assembled
dynamically from the day's mercies, and its last beat stitches the game's
own seam: El Roi sends her to the ford where Episode II's first scene finds
her "waiting as if appointed."

## Episode II: The Herald's Road (wired 2026-07-30)

Composed canon-interior from the full read of *Shadow of Ikral* (design +
canon argument: `tears_episode2_script.md`): Yehu's **unnamed dangerous
mission** (offstage in the novella, its charter spoken in ch. 2) — the
embassy to the Prince of Pyrr, to tell the Clans what Thas meant before they
decide it themselves. Phase 12; entered when the victory feast burns low.

- Eight scenes: the commission, Keanna at the ford, the burned waystation,
  the zealots' grove (the **Matisyahu gambit** — invoke the king and Ikral's
  own honor — is *gated on having watched from the cold camp*; the first
  information-dependent choice in the game; otherwise steel decides, with an
  `OnEmbassy` battle that rides on to the court), the Prince's one question,
  the courtesy trap (the Naaman-scene inverted), the dawn garden, and three
  endings: **The Open Door** (truth told whole, cup untouched, the garden
  earned — and the reveal of what Matisyahu's temple-fasting bought), **The
  Sealed Account** (polished truth, thinner peace), **The Poured Cup** (some
  doors close politely).
- Moral spine graduates Episode I's *patience* into *candor*.
- The Open Door ending points at Sean's own arc: **Episode III is the road
  to Muze.**
- Tests walk the canonical path and the gated-gambit branch; the playthrough
  driver now runs both episodes end to end.

## Episode III: The Road of Wings (wired 2026-07-30)

Yehu's mission to Muze — **Sean's Episode III arc**, composed
forward-compatible (phase 13): Torial repatriates the Muzite spy captured in
Episode I (composed name: Veskar) as cover for learning who holds his leash.
The road runs through the nanae valley (the bravest of races, hiding from a
bent-winged prisoner), past the Great Prison — where **Yosef and Nathan's
canonical northern journey crosses Yehu's** and the prophet leaves one
warning: *"the king you will stand before is a prisoner in his own hall"* —
to the Court of Veils, where Sena priests present a plumed figure as King
Moriedhadu. Mercy is the key: only if the spy was freed on his wing-oath
("By the First Form…") does he whisper *"that is not the king — I can smell
my own"*, and only warned + befriended does the true hall open: the real
Moriedhadu behind the lattice, pressing a feather and a token through —
**"For the prophet who is coming. Tell him: the thrall is willing."** Yehu
does not rescue him; that is Yosef's, and Sean's. The game makes Yehu the
*courier* of Episode III's opening move.

- Moral spine graduates again: patience → candor → **sight** — the
  shapeshifters' original gift (understanding, "compassion by inhabiting"),
  practiced by the human on the Muzite.
- Endings: **The Feather Carried** / **The Painted Peace** (mercy without
  the hall) / **The Chained Gift** (protocol, and a treaty that says nothing
  true). No combat: this one is won by eyes.
- Tests walk the merciful path and assert the veils hold against the
  unwarned; the driver now plays **all three episodes** end to end.

## The Scribe of Rhea (wired 2026-07-30 — ⚠ verification pending, see below)

Sean asked where a scribe makes sense in an RPG; the canon had already set the
table. Nathan deposited the last **Muzite Scriptures of El Roi** at Rhea
(*Ikral* ch. 5) and taught Yosef to read them — and Episode III ends with Yehu
carrying home a **pictograph token nobody in Torial can read**. Yosef is north;
the reading falls to **Safra** (Aramaic: *scribe*), the young temple copyist
who sat in on Nathan's lessons. Second non-Yehu playable, phase 15, entered
from the **Feather Carried** ending (choice B: bring the token to the
scriptorium).

The mechanics are philology itself — the session's mosaic instruments made
playable:

- **The two scrolls** — the Scriptures are *plural* in canon, and at the cited
  verse they disagree by one memory-glyph. Choice: harmonize silently, or keep
  both readings margined in their own ink (`VariantsKept` — **kethiv/qere as a
  game verb**).
- **The stubborn sign** — one pictograph glosses three ways
  (BOUGHT / MADE / BOUND-TO): the *qanani* dilemma transposed into Muzite.
  Choice: assert a gloss, or write it with the dotted uncertainty mark
  (`GlossHumble`).
- **The young priest's sermon** — two days later the safra hears their own
  gloss preached hot as settled doctrine ("a slave-king!"): the monopoly of a
  translation, caught live. Choice: stand up and unsay your own pen
  (`CorrectedGloss`) or let a useful error run.
- **The second line** — REMEMBER THE COVENANT OF THE FIRST TEMPLE, sealed with
  an *ancestor's* name in old signs: the token is itself a copy, carried a
  thousand years by hidden scribes. (Enriches the Muze backdrop; plots nothing
  of Sean's Episode III.)
- **The letter north** — send Yosef the whole truth, doubts dotted
  (`SentWhole`), or only the clean certain reading.
- Endings assembled from the flags: **The Faithful Hand** vs **The Smooth
  Text** ("Smooth texts travel far. So do their errors."). Moral spine
  completes the tetralogy: patience → candor → sight → **fidelity: carry,
  don't own**.

> **⚠ Verification pending (2026-07-30 afternoon):** the code, tests, and
> driver extensions are applied but **not yet compiled green**. The repo's
> `zig-out/bin` compilers were rebuilt at 13:57 from a working tree with
> unresolved merge conflicts (`selfhost/CodeGen.zbr`, `selfhost/TypeChecker.zig`
> in `UU` state — Opus mid-QA), and that binary rejects *even the last
> committed, previously-green version* of this game (`syntax error near
> 'except'` on every occurrence). Nothing here should be trusted or committed
> until a compiler built from a clean tree runs
> `examples/tears_combat_test.zbr` and `tears_playthrough.zbr` green. The
> machine was under day-job + QA load, so no clean rebuild was attempted.

## Playthrough driver

`examples/tears_playthrough.zbr` — a headless full playthrough that drives the
real `update()` FSM from intro to mission ending, printing every page, choice,
and battle-log line (deterministic per its seed, with a try-again loop on
defeat). First run of record, 2026-07-30: Fable lost the Medium road-battle on
the first attempt and won on the second, finishing the mission on the faithful
path — Split/Waited/CubsFree/SavedKeanna all true, ENDING: The Faithful Score.
Second run of record (the valley campaign): five defeats at the first Medium
ambush, then — humbled to Easy — 90 miles, four ambushes, 200 XP to the gates
of Thas, the faithful mission, and the feast's Third Voice: every flag true.
(The TUI itself is mouse-driven — `_tui_selectable` fires on a left-click at
the widget's row; scripted SGR mouse-injection via winpty is untried, and a
human clicking remains the only proof of rendering.)

## The Village of Arna (wired 2026-08-01 — the reaction engine on the road)

The valley Yehu walks is **ArnasThas**, and the 2015 map names both of its ends:
the *Village of Arna* in the west, the *City of Thas* in the east. The valley is
named for both, so the road always passed a village nobody had written. Phase 16
is that village, and it is where `npc_reactions.zbr` stops being a demo.

**Nothing in Arna is authored per-villager.** Every reception is computed from
two inputs:

1. **Who Yehu has become** — `yehuQualities(model)` derives all ten notebook
   qualities from the flags the playthrough actually set. Waiting for the sign
   raises humility and wisdom; striking first trades humility for courage;
   shading the truth at the Pyrran court costs honour; pouring the cup costs two
   points of faith; blood on the Herald's Road buys prowess and costs kindness.
   This is the 2001 notebook's cross-mission accumulation, arriving at last —
   the village reacts to the *record*, not to a stat sheet.
2. **What has passed between him and this villager** — `arnaStanding` weighs
   service done in the valley above coin opened at the gate, per the notebook's
   own ordering of obligation over payment.

Arna is Tuon country, so it is scored with **region 2**, where a merchant weighs
honour *overwhelmingly*. A man who shaded the truth at a Pyrran court finds that
out here, from a trader who was never at court.

### The four at the door

| Page | Villager | Type | What complicates them |
|---|---|---|---|
| 1 | Kir the herdsman | Farmer | — |
| 2 | Ganna, who trades down the river | Merchant | bound by the river-traders' word until Yehu disclaims the trade |
| 3 | a cub with a sling | Children | — |
| 4 | old Sera at the well | Elderly | optionally weighed against *the men who came before you* |

### The result worth knowing

The engine discriminates through **candor** far more than through willingness.
An intimidating, dishonest Yehu is not refused — he is answered, and lied to.
His help-count stays middling (3 of 4) while his candor collapses from *confides*
to *shades the truth*, and from the child to *tells you what you want to hear*.
That was not written; it fell out of fear being modelled as a separate axis that
buys compliance and costs truth. The result is a village that is helpful and
useless at once, which is a better model of a frightened place than a cold one.

Coin at the gate is deliberately weak: it moves a villager at most one band and
never buys what keeping faith earns. The harness asserts exactly that
(`a purse never outbuys a record`).

### Entering and leaving

Every ending of the arc now comes home through the village, not just one branch:

- the scribe's colophon at Rhea (`scrStep` story 7 → phase 16), and
- the Episode III endings that never reach the scriptorium (`ep3Step` id 7).

Both previously called `init()` and dropped the player at the title screen. Past
the well, Yehu steps out onto the valley map at Arna's own tile `(5, 25)` — the
`A` the map already had.

### Two defects this surfaced

- **Qualities escaped their range.** `yehuQualities` clamped only `prowess` at
  the top, so a merciful run reached `kindness = 6`. The scoring measures
  *deviation from 3* across a 0..5 domain, so an out-of-range quality silently
  over-weights its whole column. All ten are now clamped both ends via
  `clamp05`, and the harness pins it.
- **The engine called every NPC "he".** Its generated reasons are written for a
  generic person whose sex it does not know, so they now read *them*/*they*.
  Arna's own prose knows its four villagers and carries the right pronoun per
  villager (`arnaSubj`/`arnaObj`), which the refusal branch had always done and
  the rest of the lines had not — old Sera was called "he" all the way to the road.

### Seeing it

```
zebra run examples/tears_village_demo.zbr
```

walks three men through the same village: one who kept faith, one who took the
shorter way, and the second man again with coin at the gate. Same four
villagers, same table, three different receptions — and every page prints the
trace (`She reads you: …`) so the reason is reviewable, not just the score.


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

A fourth gap was found by writing the village itself and is **fixed**, not
worked around:

- **BUG-239** — an empty list literal `[]` in *expression* position (a call
  argument, struct field, or return value) failed to compile, because the
  literal lowering hardcoded `var` on a binding that an empty literal never
  mutates. `var x: List(T) = []` was never affected, which is why the corpus
  missed it. Fixed in `selfhost/CodeGen.zbr`; regression at
  `test/bug239_empty_list_literal_test.zbr`.

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
