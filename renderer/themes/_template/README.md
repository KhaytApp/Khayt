# Khayt custom theme template

Copy this folder to `renderer/themes/custom/<your-id>/`, edit the files, then register the theme in `renderer/themes/custom/index.json`.

## Quick start

1. **Copy the template**
   ```bash
   cp -R renderer/themes/_template renderer/themes/custom/my-shop
   ```

2. **Edit `manifest.json`**
   - Set a unique `id` (lowercase slug, 2–32 chars).
   - Set `name`, `description`, `shell`, and `accents`.
   - `shell`: `workbench` (grouped sidebar), `command` (rail + inspector), `vivid` (colorful sidebar), or `default` (legacy layout).

3. **Edit `tokens.css`**
   - Replace every `custom:my-shop` with `custom:<your-id>`.
   - Define surfaces, text, accent HSL variables, radii, and fonts.
   - Status colors (`--success`, `--warning`, etc.) should stay independent of the accent.

4. **Register in `index.json`**
   ```json
   {
     "themes": [
       { "id": "my-shop", "folder": "my-shop" }
     ]
   }
   ```

5. **Restart the app** — your theme appears under Settings → Preferences → Design → Community.

## Manifest reference

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Unique slug; becomes `custom:<id>` in settings |
| `name` | yes | Display name |
| `tokens` | yes | CSS filename (usually `tokens.css`) |
| `shell` | no | `workbench`, `command`, `vivid`, or `default` (default: `default`) |
| `defaultAppearance` | no | `dark`, `light`, or `system` |
| `defaultAccent` | no | Key from `accents` object |
| `accents` | no | Map of accent id → `{ h, s, l, label }` |
| `compat` | no | Optional component overrides CSS |

## Rules

- Scope all CSS to `html[data-design="custom:<id>"]`.
- Do not ship remote fonts or scripts — use `renderer/fonts/` or system stacks.
- Keep `data-i18n` keys; add locale strings if you expose new labels.
- Test RTL (`ar`) and both light/dark appearances.

## Built-in themes

| ID | Shell | Notes |
|----|-------|-------|
| `workbench` | `workbench` | Grouped sidebar — the default |
| `command` | `command` | Rail + inspector + status bar |
| `vivid` | `vivid` | Colorful sidebar, per-module hue |
| `blueprint` | `workbench` | Warm paper + blueprint blue |
| `nocturne` | `command` | Dark-first, amber instrument accents |

A theme may reuse a built-in shell (Blueprint and Nocturne both do). Pick the
shell whose layout you want, then differentiate with tokens — you only need
your own shell if the LAYOUT differs, not the look.

See [docs/THEMES.md](../../../docs/THEMES.md) for architecture and contribution notes.
