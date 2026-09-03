# Timers3

A Windower 4 Lua addon that tracks job ability recasts, spell recasts, and buff durations for spells and abilities you cast.

Forked from [Gol-exe/Timers2](https://github.com/Gol-exe/Timers2) (itself a Lua rewrite of the closed-source `Timers` Windower plugin). This fork:

- Moves the default panel position down (`y = 450` instead of `100`)
- Renders bars taller (14px) with the label/time text vertically centered *inside* the bar instead of floating above it
- Brightens the text (full alpha + heavier outline stroke) so it stays legible sitting on top of colored bar fills
- Adds a mouse drag-and-drop **setup mode** for repositioning, instead of typing coordinates blind

Only timers the addon witnesses are tracked — buffs active before the addon loads are intentionally ignored.

## Installation

Place the `Timers3` folder in your `Windower/addons/` directory and load it with:

```
//lua load Timers3
```

## Settings & multiple characters

Settings save to `data/settings.xml` inside the addon folder, via Windower's own `config` library. By default, every tuning command (`pos`, `classic font`, `classic scale`, etc.) saves to your **currently logged-in character's own section** — other characters won't see those changes and fall back to the defaults.

To make your tuned settings the shared default for every character:

```
//tm3 saveall
```

This writes the current settings to the file's shared `<global>` section (and collapses any existing per-character override sections back into it — so run it once you're happy with the look, not mid-tuning if you've already customized a different character separately).

## Setup mode (drag-and-drop positioning)

```
//tm3 setup          -- or //tm3 reposition
```

Shows two draggable handles:
- **Blue handle** — drag to move the recast/buffs panel (`pos`)
- **Orange handle** — drag to move the custom-timer panel (`custompos`)

The real timer bars follow the handles live as you drag. All other commands (`classic font`, `classic textcolor`, `classic barheight`, etc.) still work while setup mode is active — adjust everything in one pass, then:

```
//tm3 lock
```

to hide the handles and save the final position.

## Display

Two themes are available, switchable at any time with `//tm3 theme <name>`.

### classic (default)

Each row shows a category icon (or coloured dot), spell name, and time remaining centered inside a progress bar.

- **Orange dot** — Job ability recasts
- **Blue dot** — Spell recasts
- **Green dot** — Buff durations
- **Yellow dot** — Custom timers

Icon PNGs live in `icons/abilities/` and `icons/spells/` (named by recast/spell ID, e.g. `00036.png`), pulled from the [upstream Timers2 repo](https://github.com/Gol-exe/Timers2/tree/main/icons). If an icon is missing for a given ability/spell/buff, the addon falls back to a colored dot automatically — nothing breaks.

### slim

A minimal plain-text display — no graphics, just `SpellName: M:SS` per line.

## Party Buff Condensing

When the same buff is cast on multiple party members individually (e.g. a Red Mage casting Shell V on six people in succession), the addon collapses those rows into a single entry rather than displaying six near-identical 6-hour timers.

The condensed row shows the spell name with a count suffix — `Shell V [6]` — and tracks the **earliest** expiry among all affected members, so you know exactly when the first one needs to be recast.

The threshold is controlled by the `condense_party_threshold` setting in the saved settings file (default: `2`; set to `0` to disable). Not yet exposed as a command — edit the saved settings XML directly.

## Grouping and Sorting

### Group type

Controls how timers are bucketed into sections. Recast timers always appear in the left column; buff timers appear in the right column.

| Mode | Behaviour |
|---|---|
| `start` | Right column: BUFFS-SELF / BUFFS-AOE / BUFFS-PARTY / [player] *(default)* |
| `character` | Right column: SELF (self-buffs only) / AOE / PARTY / [player] |
| `none` | Right column: single flat list; party buff rows show `[CharacterName]` or `[N]` count |

### Sort order

Controls the order of rows within each section:

| Mode | Behaviour |
|---|---|
| `duration` | By time remaining *(default)* |
| `name` | Alphabetical |
| `player` | By target name, then duration |
| `creation` | By cast order — oldest first when direction is `asc` |

Sort direction can be set independently per column:

| Command | Default | Effect |
|---|---|---|
| `recastdir asc\|desc` | `asc` | Soonest ready first |
| `buffdir asc\|desc` | `desc` | Longest remaining first |
| `customdir asc\|desc` | `desc` | Longest remaining first |

## Commands

All commands use `//timers3` or `//tm3`.

### Positioning

| Command | Description |
|---|---|
| `setup` / `reposition` | Enter drag-and-drop setup mode |
| `lock` | Exit setup mode and save position |
| `pos <x> <y>` | Set main panel position directly (no dragging) |
| `custompos <x> <y>` | Set custom timer panel position directly |

### Display

| Command | Description |
|---|---|
| `theme <classic\|slim>` | Switch display theme |
| `group <start\|character\|none>` | Set grouping mode |
| `sort <duration\|name\|player\|creation>` | Set sort order |
| `direction <up\|down>` | `down` shows time remaining *(default)*; `up` shows time elapsed |
| `recastdir / buffdir / customdir <asc\|desc>` | Per-column sort direction |
| `recastlimit / bufflimit / customlimit <N>` | Cap rows per section (0 = no limit) |
| `interval <seconds>` | Refresh rate — governs how smoothly the bar fill and countdown update (default: 0.5; try 0.1 or 0 for the smoothest look, at the cost of slightly more CPU) |
| `tenths` | Toggle sub-second display when < 10s remaining |
| `1hourname` | Toggle hiding the time counter for SP abilities |

### Visibility

| Command | Description |
|---|---|
| `abilities` | Toggle ability recast display |
| `spells` | Toggle spell recast display |
| `buffs` | Toggle buff duration display |

### Theme Settings (classic)

Applied with `//tm3 classic <setting> <values>`.

| Setting | Values | Description |
|---|---|---|
| `highcolor R G B` | 0–255 each | Bar fill when remaining > med threshold *(default green)* |
| `medpercent 0-1` | fraction | Threshold below which mid color activates *(default 0.5)* |
| `medcolor R G B` | 0–255 each | Bar fill in mid range *(default yellow)* |
| `lowpercent 0-1` | fraction | Threshold below which low color activates *(default 0.25)* |
| `lowcolor R G B` | 0–255 each | Bar fill in low range *(default red)* |
| `flash <sec> [R G B]` | seconds + color | Flash buff bars when remaining ≤ this *(default off; buffs only)* |
| `bgcolor A R G B` | 0–255 each | Bar background color |
| `textcolor A R G B` | 0–255 each | Row label and time text color |
| `font NAME SIZE` | string + points | Font family and size (reloads pool) |
| `spacing N` | pixels | Extra vertical gap between rows |
| `barheight N` | pixels | Bar height *(default 14)* |
| `textoffset N` | pixels | Vertical text offset from the bar's top edge — tune this if text isn't sitting inside the bar *(default -3, can be negative)* |
| `scale N` | multiplier | Scales bar width/height, icon size, font size, and spacing together, on top of whatever base values you've already tuned *(default 1; any decimal, e.g. 1.1, 1.5, 2 — not limited to fixed steps)* |
| `outline N` | pixels | Text stroke/outline width, 0 = none *(default 2; reloads pool)* |
| `slim` | toggle | Hide all text — show bars and icons only |
| `extend` | toggle | Position time outside the bar (to the right) |

### Theme Settings (slim)

Applied with `//tm3 slim <setting> <values>`.

| Setting | Values | Description |
|---|---|---|
| `flash <sec> [R G B]` | seconds | Flash buff rows with `! ` when remaining ≤ this |
| `textcolor A R G B` | 0–255 each | Display text color |
| `font NAME SIZE` | string + points | Font family and size |

### Filters

Named filters let you save a specific combination of category, sort, and whitelist settings and switch between them on demand. Only one filter is active at a time.

| Command | Description |
|---|---|
| `filter list` | List all filters (built-in and user-created) |
| `filter select <name\|none>` | Activate a filter, or clear the active one |
| `filter create <name>` | Create a new user filter |
| `filter delete <name>` | Delete a user filter |
| `filter sort <name> <mode>` | Set the sort order for a filter |
| `filter category <name> <add\|remove> <ability\|spell\|buff\|custom>` | Restrict a filter to specific categories |
| `filter whitelist <name> <add\|remove> <entry>` | Restrict a filter to named entries |

### Whitelists and Blacklists

| Command | Description |
|---|---|
| `whitelist abilities add\|remove <name>` | Show only whitelisted abilities (empty = show all) |
| `whitelist spells add\|remove <name>` | Show only whitelisted spells (empty = show all) |
| `blacklist add\|remove <buff name>` | Hide a specific buff from all buff sections |

### Custom Timers

Custom timers render at a separate position (`custompos`), independently draggable via the orange setup-mode handle.

| Command | Description |
|---|---|
| `create <name> <duration>` | Create a custom timer (duration in seconds) |
| `delete <name>` | Remove a custom timer |

## Examples

```
//tm3 setup
   (drag handles into place)
//tm3 lock

//tm3 classic barheight 16
//tm3 classic textcolor 255 255 255 255
//tm3 theme slim
//tm3 group character
//tm3 sort name

//tm3 create Bolster 180
//tm3 delete Bolster

//tm3 whitelist abilities add Meditate
//tm3 blacklist add Protect
```
