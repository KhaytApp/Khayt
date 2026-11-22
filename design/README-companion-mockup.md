# Khayt Companion UI mockup

Add your mockup under **`design/iOS UI/`**, then **push**:

```bash
cd ~/Documents/Khayt
git add "design/iOS UI"
git commit -m "Add iOS Companion UI mockup"
git push origin cursor/ios-companion-app-2e93
```

(Also works from `~/Khayt` if that is your clone — use the repo that contains `design/iOS UI`.)

Verify tokens locally:

```bash
python3 scripts/sync-companion-design-from-html.py
```

## Implemented in iOS

SwiftUI on branch `cursor/ios-companion-app-2e93` follows **`design/iOS UI/khayt-design.jsx`** (`DARK_TOKENS`):

- Surfaces `#0C0C0F` / `#1C1C26`, brand `#8183FF`, kanban stage colors
- Home stat blocks, pipeline strip, mini order cards, blurred tab bar
- Files: `ios/KhaytCompanion/Theme/KhaytDesign.swift`, `KhaytTabBar.swift`, `KanbanStripView.swift`

Run `python3 scripts/sync-companion-design-from-html.py` after updating mockup files.
