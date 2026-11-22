# Local development setup

## Requirements

- **Node.js** 22.12 or newer (22 LTS or 24.x)
- **npm** 10+
- macOS 12+, Windows 10+, or Linux x64

## First run

```bash
git clone https://github.com/khaytapp/Khayt.git
cd Khayt
npm install
npm start
```

`npm install` runs `scripts/install-electron-await.js`, which downloads the Electron binary and writes `node_modules/electron/path.txt`. `npm start` runs `scripts/ensure-electron.js` first if that file is still missing.

## Fix: `path.txt` does not exist

Symptoms:

- `cat node_modules/electron/path.txt` → No such file
- `npm start` shows `Downloading Electron binary...` then crashes with `ENOENT` on `path.txt`

Cause: the stock `electron` postinstall can finish before the async download completes, especially on slow networks or when install is interrupted.

### Steps (macOS)

```bash
cd ~/Documents/Khayt   # or your clone path
git fetch origin
git pull origin main   # or: git reset --hard origin/main

rm -rf node_modules/electron
rm -rf ~/Library/Caches/electron
npm install
node scripts/install-electron-await.js
cat node_modules/electron/path.txt
npm start
```

Expected `path.txt` content on macOS:

```
Electron.app/Contents/MacOS/Electron
```

### Mirror (if GitHub CDN is slow or blocked)

```bash
export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
node scripts/install-electron-await.js
```

### Scripts reference

| Command | Purpose |
|---------|---------|
| `npm run install:electron` | Download/extract Electron and write `path.txt` |
| `node scripts/install-electron-await.js` | Same as above (explicit) |
| `npm start` | Ensures Electron exists, then launches the app |

Do **not** rely on `node node_modules/electron/install.js` alone for a first-time install.
