# Save to Khayt — the browser extension

A toolbar button that saves the 3D model page you are looking at — Printables,
MakerWorld, Thingiverse, Thangs, Cults3D, MyMiniFactory, or any page with
JSON-LD or Open Graph — into the Khayt Mac app's print library: title, link,
creator, licence, tags, a short description, the cover picture and any direct
model-file links. The record lands under **Saved from web** and on the
**Print next** list.

Then, when you download the model from that page within ten minutes, Khayt
asks whether to add the file to the record it just made. It never adds one
without asking, and the download stays where it is.

## What it can and cannot do

- **Permissions, every browser:** `activeTab`, `scripting`, `nativeMessaging`.
  No host permissions, no content scripts. The page is read only when you press
  the button, only in that tab (`src/snapshot.js`), and parsed in an inert
  document in the popup.
- **Chrome, Edge, Brave, Vivaldi and Firefox also ask for `downloads` and
  `storage`** (Safari's manifest leaves both out — `pack.mjs`
  `SAFARI_LEAVES_OUT`). `downloads` lets the background see a download finish:
  its file path, address, referrer, start time and state. It never opens or
  reads the file. A download is matched against the saves of the last ten
  minutes (`background.js` `matchDownload`: same tab, referrer on the saved
  page or site, or one of the page's file links); one that does not match is
  dropped on the spot and nothing is sent about it. One that matches sends
  Khayt a single `attach` message: the saved page's address, the file's path
  and its name. `storage` is `storage.session` only — the last ten minutes'
  saves (page address, its file links, the tab id, the time), gone when the
  browser quits.
- **Transport:** native messaging only, to code inside Khayt.app. No network
  request, no localhost server, no `khayt://` link
  (`test/webext-adapters.test.js` checks the source for all three). A web page
  cannot send a native message.
- **Where the data goes:** the Khayt app on this Mac. The extension sends page
  details nowhere else. The app then fetches the cover picture from the site
  (https only, at most 8 MB, kept only if it decodes as a picture).
- **Khayt checks everything again** (`mac/KhaytCore/Sources/KhaytWebSave`):
  https only, length caps, no control characters, at most 20 tags and 20 links,
  64 KB per message. The site is worked out from the address, never taken from
  the page. A download is offered only when it is a model file (3mf, stl, obj,
  step, gcode, … or a zip/7z/rar holding one), a plain non-empty file inside
  your home folder (not through a symbolic link), from a page saved in the last
  few minutes.

## Layout

| File | What it is |
|---|---|
| `manifest.json` | The Chrome/Edge/Brave/Vivaldi manifest; `pack.mjs` derives Firefox's and Safari's |
| `popup.html/.css/.js` | Reads the page, shows what will be saved, Save |
| `background.js` | Sends the popup's message to Khayt, so a save survives the popup closing; matches a finished download to a save |
| `src/adapters.js` | The site readers — pure functions over a `Document` |
| `src/snapshot.js` | The one function run in the tab |
| `src/native.js`, `src/states.js` | The message, and what the popup says for each answer |
| `_locales/en`, `_locales/ar` | Every string, in English and Arabic (the popup is right-to-left in Arabic) |
| `pack.mjs` | Builds the packages |

Tests: `node --test test/webext-adapters.test.js test/webext-attach.test.js`
(site readers over hand-written fixtures in `test/fixtures/webext/`, and the
background run in a sandbox with a stand-in browser API; nothing fetches a live
site). The Mac side: `swift test --filter "WebSave"` in `mac/KhaytCore`.

## Building the packages

```bash
node extension-khayt/pack.mjs
# → extension-khayt/dist/khayt-chrome.zip   (Chrome, Edge, Brave, Vivaldi)
#   extension-khayt/dist/khayt-firefox.zip  (Firefox)
#   extension-khayt/dist/safari/            (what make-app.sh puts in the .appex)
```

Safari needs no separate step: `mac/make-app.sh` stages the extension into
`Khayt.app/Contents/PlugIns/KhaytSafari.appex/Contents/Resources` and signs it
with the app.

## How each browser reaches Khayt

**Safari.** The extension's native half is `KhaytSafari.appex` inside
Khayt.app. Open Khayt once from /Applications (Safari and `pluginkit` only see
an extension in an app that has been launched from a scanned folder), then
Safari ▸ Settings ▸ Extensions ▸ tick **Save to Khayt**, and allow it on the
sites you want — or leave it at "Ask". Khayt ▸ Settings ▸ Preferences ▸
Browser extension shows whether Safari has it on, with a button to that page.
Safari has no downloads API, so for ten minutes after a Safari save the Khayt
app itself looks in `~/Downloads` for a new model file (macOS asks once for
Downloads access, at the first Safari save).

**Chrome, Chromium, Edge, Brave, Vivaldi, Firefox.** These start a native
program, `Khayt.app/Contents/MacOS/khayt-browser-host`, named by a small *host
manifest* in the browser's own folder:

| Browser | Host manifest |
|---|---|
| Chrome | `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/app.khayt.mac.json` |
| Chromium | `~/Library/Application Support/Chromium/NativeMessagingHosts/app.khayt.mac.json` |
| Edge | `~/Library/Application Support/Microsoft Edge/NativeMessagingHosts/app.khayt.mac.json` |
| Brave | `~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/app.khayt.mac.json` |
| Vivaldi | `~/Library/Application Support/Vivaldi/NativeMessagingHosts/app.khayt.mac.json` |
| Firefox | `~/Library/Application Support/Mozilla/NativeMessagingHosts/app.khayt.mac.json` |

Khayt ▸ Settings ▸ Preferences ▸ Browser extension has a row per installed
browser with **Install** / **Update** / **Remove**. Khayt writes a manifest
only when you press Install, never on its own, and Remove deletes only a file
Khayt wrote (one whose program is a `khayt-browser-host` inside a `Khayt.app`);
anything else of that name is reported and left alone. The Chromium manifest's
`allowed_origins` lists the store ids in
`mac/KhaytCore/Sources/KhaytWebSave/BrowserExtensionIds.swift`; Firefox's
`allowed_extensions` is `save@khaytapp.com`.

The host does exactly what the Safari handler does, through the same function
(`WebInbox.reply`): it reads one framed message from standard input (a 4-byte
little-endian length, then JSON; at most 1 MB, and `WebSave` then allows 64
KB), checks it, writes it into the app group's `WebInbox` folder, waits up to
four seconds for the app's answer and writes that back. It reads nothing else,
fetches nothing, opens no book and never launches the app.

### Developing with an unpacked copy

1. `chrome://extensions` ▸ Developer mode ▸ **Load unpacked** ▸ this folder.
2. Copy the id Chrome shows on the card (32 letters a–p). An unpacked
   extension's id is derived from the folder's path, so it changes if the
   folder moves; to pin it, add a `"key"` (a public key, base64) to your local
   `manifest.json` — the id is then the first 32 hex digits of
   SHA-256(DER public key), each digit 0–f spelled a–p. Never upload a
   manifest with `key` to a store.
3. Tell Khayt about it, then press Install for that browser in Settings:

   ```bash
   defaults write app.khayt.mac mac.sfw_devExtensionIds -array <id>
   ```

   A development Khayt run with `swift run` has no `khayt-browser-host` beside
   it (Settings says so); use a `mac/make-app.sh` build.

Firefox: `about:debugging` ▸ This Firefox ▸ **Load Temporary Add-on** ▸
`dist/firefox/manifest.json` (after `node extension-khayt/pack.mjs`). Its id
is already `save@khaytapp.com`, so Install works as is.

## Publishing (not done by the build — each step is Turki's)

Nothing here uploads anything. Build first: `node extension-khayt/pack.mjs`.

### 1. Chrome Web Store (also how Brave and Vivaldi install it)

1. Sign in to the Chrome Web Store Developer Dashboard
   (<https://chrome.google.com/webstore/devconsole>) with the Khayt Google
   account (one-time US$5 registration if not done).
2. **New item** ▸ upload `extension-khayt/dist/khayt-chrome.zip`.
3. **Store listing:** name and description come from `_locales/en` (Arabic
   from `_locales/ar` — add it as a second language in the listing); category
   *Productivity*; icon `icons/icon128.png`; at least one 1280×800 screenshot
   (the popup over a Printables page). Homepage <https://khaytapp.com>.
4. **Privacy practices:**
   - Single purpose: "Save a 3D model page, and the model downloaded from it,
     into the user's Khayt library on the same computer."
   - `activeTab` / `scripting`: "Reads the current page only when the user
     presses the button."
   - `nativeMessaging`: "Sends the page details to the Khayt app on the same
     computer; that is the extension's only output."
   - `downloads`: "For ten minutes after a save, checks whether a finished
     download came from the saved page, so Khayt can offer to add the model.
     The file is not read; other downloads are ignored."
   - `storage`: "Remembers the last ten minutes' saves in session storage
     until the browser quits."
   - Data usage: tick nothing collected; certify no sale/transfer. Privacy
     policy URL: <https://khaytapp.com/privacy>.
5. Submit for review.
6. **Paste the id.** Once the item exists (before review finishes is fine), copy
   its **Item ID** from the dashboard and put it in
   `mac/KhaytCore/Sources/KhaytWebSave/BrowserExtensionIds.swift`:
   `public static let chromeWebStore: [String] = ["<item id>"]`. Ship a Mac
   build; shops then press Install (or Update) for Chrome, Brave, Vivaldi in
   Settings.

### 2. Microsoft Edge Add-ons

1. Partner Center (<https://partner.microsoft.com/dashboard/microsoftedge>),
   free developer registration on the Khayt Microsoft account.
2. **Create new extension** ▸ upload the same `dist/khayt-chrome.zip`.
3. Properties and listing as for Chrome (same justifications, same privacy
   URL); availability: all markets.
4. Submit.
5. **Paste the id.** Partner Center ▸ the extension ▸ *Extension overview* ▸
   **Extension ID** goes in `BrowserExtensionIds.swift`:
   `public static let edgeAddOns: [String] = ["<extension id>"]`. (It differs
   from the Chrome Web Store id; Edge users who installed from the Chrome Web
   Store use that one, so both stay listed.)

### 3. Firefox (addons.mozilla.org)

1. <https://addons.mozilla.org/developers/> with the Khayt Firefox account.
2. **Submit a New Add-on** ▸ *On this site* ▸ upload
   `extension-khayt/dist/khayt-firefox.zip`.
3. The add-on id is `save@khaytapp.com` (`pack.mjs` `GECKO_ID`, and
   `BrowserHosts.firefoxExtensionId` on the Mac — the two must match, and
   `test/webext-attach.test.js` holds them equal). It cannot change after the
   first upload. The manifest already declares
   `data_collection_permissions: none`.
4. Source code: AMO asks only for minified or generated code; nothing here is,
   so answer *No*.
5. Listing: same description, privacy policy <https://khaytapp.com/privacy>.
   Submit for review. No id to paste — it is fixed in advance.

### 4. Safari

Ships inside Khayt.app (Developer ID, notarised by the normal Mac release).
Nothing to upload. A Mac App Store listing would need the App Store build,
which Khayt does not have.

Store listings should say, plainly: page details are sent only to the Khayt
app on your own computer; nothing is sent to Khayt's servers or anyone else.
