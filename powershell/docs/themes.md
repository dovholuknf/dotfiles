# wt themes

Per-tab Windows Terminal theming via OSC escape sequences. Source of truth is
`powershell/wt-themes.ps1` (engine + core themes) and `powershell/wt-themes-rainbow.ps1` (extra
dark-background themes). Both are dot-sourced from each user's profile, rainbow AFTER core so its
themes register on top of the same `$script:WtThemes` table.

A theme sets the tab background, foreground, cursor, selection colors, and the 16 ANSI palette
slots by writing OSC 4 / 10 / 11 / 12 / 117 / 119 sequences straight to the console. Nothing is
persisted in the Windows Terminal settings file. The change lives only in the running tab.

## Applying a theme

| Command | What it does |
| --- | --- |
| `Set-Theme <name>` | Apply by name. Prefix / substring tolerant (`Set-Theme tang` finds `tangent`). |
| `Set-Theme <N>` | Apply the Nth theme in the sorted list. |
| `Set-Theme` | No args: open the interactive picker (see live preview below). |
| `Set-Theme -UseRepoTheme [-Quiet]` | Apply the theme mapped to the current repo (see below). |
| `Set-Theme -Tour [-Filter <s>]` | Walk every theme (or those matching `-Filter`), Enter to advance. |
| `Reset-Theme` | Restore the tab's default colors and clear `$global:WtThemeName`. |
| `Show-ThemePalette` / `Show-Theme` | Preview the active theme's slots. |
| `Set-Bg <#hex>` | Quick background-only override. |

### Interactive picker: live preview

`Set-Theme` with no args opens `_TuiSelect`. As the cursor lands on each row the theme is applied
live so you see it in the real tab. Enter accepts the highlighted theme. Esc restores whatever was
active before you started previewing. This rides on the `_TuiSelect -OnHighlight` callback (see the
"List pickers" section in the root `CLAUDE.md`).

### Tour

`Set-Theme -Tour` clears the screen between each theme so colors are not muddied by prior output,
and it waits for Enter on the LAST theme too. That last wait matters: the on-cd auto-apply (below)
would otherwise immediately re-theme the tab and you would never see the final theme. `-Filter`
passes through, so `Set-Theme -Tour -Filter blue` walks just the blue family.

## Per-repo themes

`$script:RepoThemes` in `wt-themes.ps1` maps a repo name (the last path segment of the origin URL,
no `.git`) to a theme name. It is a living list; read the file for the current set. Examples:

```
ziti              -> teal-dusk
ziti-sdk-c        -> neon-grape
ziti-tunnel-sdk-c -> gruvbox-dark
desktop-edge-win  -> dracula
ziti-doc          -> imperial-purple
dotfiles          -> tangent
```

### How `-UseRepoTheme` resolves the repo

1. `git remote get-url origin` and take the last path segment.
2. If that fails (no remote), parse the worktree path layout
   `<WORKTREE_ROOT>\<host>\<org>\<repo>\<branch>` and take `<repo>`.

If the repo is in the map, that theme is applied. If not, behavior depends on `-Quiet`.

### Quiet vs manual

- `Set-Theme -UseRepoTheme -Quiet` (used by the on-cd hook): mapped repo gets its theme, unmapped
  repo triggers `Reset-Theme`. Never prompts.
- `Set-Theme -UseRepoTheme` (manual, no `-Quiet`): always opens the picker so you can SET or CHANGE
  the mapping. After you pick, it asks `(y)es / (a)gain / (N)o`. `y` writes the mapping back into
  `wt-themes.ps1` via `_SaveRepoThemeMapping` (it replaces an existing line for the repo, or inserts
  a new one). `a` reopens the picker to try another. `N` applies the pick without saving.

### Auto-apply on cd

Each user's `Prompt` function tracks the cwd and calls `Set-Theme -UseRepoTheme -Quiet` when it
changes. So `cd` into a mapped repo (clone or worktree) themes the tab automatically, and leaving a
mapped repo resets it. `Reset-Theme` clears `$global:WtThemeName` so the next mapped repo re-applies
cleanly.

### Prompt decorations driven by the theme

The clint prompt adds, in addition to the usual host + path:

- A `[theme-name]` prefix (or `[default]` when no theme is active) before the hostname.
- A 30-char-wide repo banner pinned to the top-right of the prompt line. It is true-color: the
  theme's background hex is the text color, the theme's `ansi[6]` slot is the stripe background.
- A one-time `hint: Set-Theme -UseRepoTheme` line shown when you enter a repo that has no mapping
  yet but could have one. It re-shows only when the detected repo changes, not on every prompt.

## The rainbow themes

`wt-themes-rainbow.ps1` adds two dozen dark-background themes grouped loosely by hue: red, orange,
amber, green, blue, and violet / purple. They register into the same `$script:WtThemes` table, so
`Set-Theme`, the picker, and `-Tour` all see them.

`-Filter` is a plain substring match against the theme name. If you want a family to be reachable
as a group (`Set-Theme -Tour -Filter blue`), put the family word in the theme name. The blue and
purple families are named that way on purpose (`arctic-blue`, `pure-blue`, `dusk-blue`,
`mauve-purple`, `imperial-purple`) after the filter-by-family workflow proved useful. Other families
use evocative names and are reached by name, not filter.

## Theme shape

Each theme is a hashtable: `label`, `bg`, `fg`, `cursor`, `sel_bg`, `sel_fg`, a 16-entry `ansi`
array, and an optional `psr` block for PSReadLine token colors. `ansi[8]` (bright-black) and
`ansi[15]` (bright-white) may be left `$null`; `_NormalizeTheme` derives readable values from the
bg/fg luminance. `_ValidateTheme` rejects malformed hex. To eyeball a theme, paste the sample
one-liner documented at the top of `wt-themes.ps1`.

## gwt integration

`gwt new` defaults to grouping a spawned tab into a window named after the repo and lets the spawn
auto-pick the theme. The spawn helper `_InvokeGwtSpawn` applies a work-type theme when the window is
a known one (active-work / pull-requests / tangent / discourse / worktrees), and otherwise falls back
to `Set-Theme -UseRepoTheme -Quiet` so a per-project window gets the repo's mapped color. See
`powershell/onpath/README.md`.
