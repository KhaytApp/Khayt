# Khayt Companion — iOS UI mockup

> **Superseded.** The current iOS design is `design/ios-v2/` (Claude Design, v2). Do not build from this folder.

Place your design export here (HTML, CSS, images from Figma / v0 / etc.).

**From your Mac (Documents clone):**

```bash
cd ~/Documents/Khayt
# You already have: design/iOS UI/
git add "design/iOS UI"
git commit -m "Add iOS Companion UI mockup"
git push origin cursor/ios-companion-app-2e93
```

After push, the cloud agent reads this folder and aligns `ios/KhaytCompanion/` SwiftUI to match.

Verify locally:

```bash
python3 scripts/sync-companion-design-from-html.py
ls -la "design/iOS UI"
git status -- "design/iOS UI"
```

## Push did not show up on GitHub?

If the agent still only sees `README.md` here, run on your Mac:

```bash
cd ~/Documents/Khayt   # or ~/Khayt — use the clone that has your mockup files
git branch --show-current   # must be cursor/ios-companion-app-2e93
ls -la "design/iOS UI"      # expect index.html, .css, images — not only README.md
git add -A "design/iOS UI"
git status                  # staged files should list your HTML/CSS/assets
git commit -m "Add iOS Companion UI mockup"
git push -u origin cursor/ios-companion-app-2e93
```

Common causes: wrong branch, files never staged (`git add`), or push went to a different remote/repo. After a good push, `git ls-tree -r HEAD -- "design/iOS UI"` should list more than `README.md`.

### `git add` does nothing but `ls` shows files?

Files are probably **already committed** locally. Check:

```bash
git ls-files "design/iOS UI"
git log -1 --stat
```

If you see `Khayt Companion.html` and `khayt-*.jsx` above, you only need to **publish** (see below).

### Push rejected: “fetch first” / remote has new commits

The cloud agent may have pushed doc fixes. Integrate then push:

```bash
git fetch origin cursor/ios-companion-app-2e93
git pull --rebase origin cursor/ios-companion-app-2e93
git push -u origin cursor/ios-companion-app-2e93
```

If rebase stops with conflicts, run `git status`, fix files, then `git rebase --continue`.

### Extra untracked `design/Khayt Companion.html`

That is a **duplicate** outside `design/iOS UI/`. Either remove it or move it into `design/iOS UI/` — the mockup set should live only under `design/iOS UI/`.
