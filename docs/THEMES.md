# Khayt theme system

Khayt separates **appearance** (dark / light / system) from **design theme** (visual identity).

## Built-in themes

| ID | Name | Shell | Default appearance |
|----|------|-------|-------------------|
| `workbench` | **Workbench** _(default)_ | Grouped left sidebar | Light |
| `command` | Command | Command bar + rail | Light |
| `vivid` | Vivid | Colorful sidebar | Light |
| `blueprint` | Blueprint | Workbench _(shared)_ | Light |
| `nocturne` | Nocturne | Command _(shared)_ | **Dark** |

The first three are the 2.6 redesign. **Blueprint** and **Nocturne** were added
in 3.4 and are the first themes to *share* a shell rather than ship one:

- **Blueprint** is Khayt's reading of the Bed Ready design language — warm
  paper, ink type, and a blueprint-blue accent used as a drawn line, with a
  deep blueprint-blue dark mode. It rides the Workbench shell because Bed Ready
  is a sidebar app. Bed Ready itself is untouched: it styles from
  `html[data-app="bedready"]` and never reads these files.
- **Nocturne** is the night shift. Every other design is light by default, but a
  farm runs unattended overnight and gets checked in a dim workshop — so this is
  the only theme whose `defaultAppearance` is `dark`, with an amber
  instrument-panel accent (long-wavelength light preserves dark adaptation) and
  saturation spent only on status. It rides the Command shell because the dense
  monitoring layout suits that job.

### Sharing a shell

`shell` selects the layout; `bodyClass` is the theme's own styling hook.
`applyBodyClasses()` sets the shell class from `theme.shell` **and** adds
`theme.bodyClass` separately, so Blueprint gets `khayt-workbench` +
`khayt-blueprint`. A theme's `bodyClass` must therefore be either its own shell
class or a name that is not a shell class at all — naming a *different* shell's
class means no hook is ever applied, silently, while the layout still looks
right. `test/themes-qa.test.js` pins this.

### Legacy themes — removed in 3.3

`ledger`, `console`, `atelier`, `vitrine`, `cockpit` and `atlas` have been
deleted. They were never selectable (all seven legacy designs carry
`legacy: true`, which `listSelectableThemes()` filters out) — only a saved
setting from before the 2.6 consolidation could reach them.
`migrateLegacyDesignTheme()` maps those settings to their intended successor,
and `normalizeDesignId()` falls anything else back to **Workbench**.

`studio` went too, in the same release. It was Bed Ready's foundation rather
than a Khayt design, so it moved with Bed Ready: `renderer/studio/` is now
`renderer/bedready/`, `KhaytStudio` is `KhaytBedReadyUI`, and the two body
classes it needed (`khayt-studio` + `khayt-handoff`, which could never disagree
once it was the last handoff shell) collapsed into one `bedready-ui` class set
from the `html[data-app="bedready"]` marker.

Khayt therefore ships **three** designs and none of Bed Ready's UI layer — the
stylesheets and scripts are gone from `index.html`. Khayt's shared renderers
still call `KhaytBedReadyUI?.x?.()`; that global is simply undefined in Khayt,
so those hooks no-op.

## Architecture

```
renderer/themes/
  registry-core.js    # Theme definitions + custom registration API
  themes.js             # applyDesignSettings(), Settings UI
  custom-loader.js      # Loads themes/custom/*/manifest.json at boot
  _template/            # Copy-paste starter for new themes
  custom/               # Community themes (index.json registry)
  workbench/            # Workbench tokens, shell CSS, dashboard screens
  command/              # Command tokens + shell CSS
  vivid/                # Vivid tokens, shell CSS, screens
  previews/             # Picker preview PNGs, one per selectable theme
```

**Shell types**

- `workbench` — grouped sidebar, light-default (`body.khayt-workbench`) — the default
- `command` — command bar + rail (`body.khayt-command`)
- `vivid` — colorful sidebar (`body.khayt-vivid`)
- `default` — legacy horizontal layout without Studio chrome

**Token contract**

Themes override CSS variables on `html[data-design="<id>"]`:

`--bg`, `--surface`, `--text`, `--accent-h/s/l`, `--primary`, `--radius`, `--font-sans`, `--font-num`, etc.

Status colors should not follow the brand accent.

## Creating a custom theme

1. Copy `renderer/themes/_template/` → `renderer/themes/custom/<id>/`
2. Edit `manifest.json` and `tokens.css` (replace `my-shop` with your id)
3. Add `{ "id": "<id>", "folder": "<id>" }` to `renderer/themes/custom/index.json`
4. Restart Khayt — theme appears under **Settings → Preferences → Design → Community**

Custom theme CSS is loaded at runtime. Built-in theme CSS is linked from `index.html`.

## Fonts

UI fonts are vendored under `renderer/fonts/` for CSP compliance. Re-run:

```bash
node scripts/vendor-theme-fonts.mjs
```

after updating `@fontsource/*` devDependencies.

## Adding a built-in theme (maintainers)

1. Add tokens + optional shell CSS under `renderer/themes/<id>/`
2. Register in `registry-core.js` (`BUILTIN_THEMES` or `RESERVED_THEMES`)
3. Add locale keys `theme.design.<id>` and accent labels
4. Link stylesheets in `index.html` if always loaded
5. Set `shell`, `bodyClass`, `defaultAccent`, `defaultAppearance`

## Handoff screen layer

There is no handoff-shell layer any more. `handoff-screens.css` moved to `renderer/bedready/screens-shared.css`, and `usesHandoffScreens()` / `HANDOFF_SCREEN_SHELLS` are gone from the registry — Bed Ready sets its one body class by product marker, so no theme arbitrates it.

## Roadmap

- Theme import/export (zip manifest + CSS)
- Theme preview thumbnails in Settings
