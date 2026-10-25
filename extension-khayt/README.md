# Save to Khayt — the browser extension

A toolbar button that saves the 3D model page you are looking at — Printables,
MakerWorld, Thingiverse, Thangs, Cults3D, MyMiniFactory, or any page with
JSON-LD or Open Graph — into the Khayt Mac app's print library: title, link,
creator, licence, tags, a short description, the cover picture and any direct
model-file links. The record lands under **Saved from web** and on the
**Print next** list.

## What it can and cannot do

- **Permissions:** `activeTab`, `scripting`, `nativeMessaging`. No host
  permissions, no content scripts. The page is read only when you press the
  button, only in that tab (`src/snapshot.js`), and parsed in an inert document
  in the popup.
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
  the page.

## Layout

| File | What it is |
|---|---|
| `manifest.json` | The Chrome/Edge/Brave manifest; `pack.mjs` derives Firefox's and Safari's |
| `popup.html/.css/.js` | Reads the page, shows what will be saved, Save |
| `background.js` | Sends the popup's message to Khayt, so a save survives the popup closing |
| `src/adapters.js` | The site readers — pure functions over a `Document` |
| `src/snapshot.js` | The one function run in the tab |
| `src/native.js`, `src/states.js` | The message, and what the popup says for each answer |
| `_locales/en`, `_locales/ar` | Every string, in English and Arabic (the popup is right-to-left in Arabic) |
| `pack.mjs` | Builds the packages |

Tests: `node --test test/webext-adapters.test.js` (site readers over
hand-written fixtures in `test/fixtures/webext/`; nothing fetches a live site).

## Building the packages

```bash
node extension-khayt/pack.mjs
# → extension-khayt/dist/khayt-chrome.zip   (Chrome, Edge, Brave)
#   extension-khayt/dist/khayt-firefox.zip  (Firefox)
#   extension-khayt/dist/safari/            (what make-app.sh puts in the .appex)
```

Safari needs no separate step: `mac/make-app.sh` stages the extension into
`Khayt.app/Contents/PlugIns/KhaytSafari.appex/Contents/Resources` and signs it
with the app.

## Turning it on

**Safari.** Open Khayt once from /Applications (Safari and `pluginkit` only
see an extension in an app that has been launched from a scanned folder), then
Safari ▸ Settings ▸ Extensions ▸ tick **Save to Khayt**, and allow it on the
sites you want — or leave it at "Ask". Khayt ▸ Settings ▸ Preferences ▸
Browser extension shows whether Safari has it on, with a button to that page.

**Chrome, Edge, Brave, Firefox.** These reach Khayt through a small native
host program and a host manifest installed in each browser's
`NativeMessagingHosts` folder. Khayt installs and removes those from its own
Settings row (never silently) — that part ships separately (see the PR). For
development: `chrome://extensions` ▸ Developer mode ▸ Load unpacked ▸ this
folder.

## Publishing (not done by the build — each step is Turki's)

Nothing here uploads anything. To publish:

1. **Chrome Web Store** (also reaches Brave; Edge has its own store):
   - A Chrome Web Store developer account (one-time US$5) on the Khayt Google
     account.
   - Upload `dist/khayt-chrome.zip` as a new item. The store assigns the
     **extension id**; the native host manifest's `allowed_origins` must name
     `chrome-extension://<that id>/`, so the id is needed before the Chromium
     host ships. To fix the id before publishing, add the store's public
     `key` to `manifest.json`.
   - Privacy tab: single purpose "Save a 3D model page into the user's Khayt
     library"; `activeTab`/`scripting` justification "reads the current page
     only when the user presses the button"; `nativeMessaging` "sends the page
     details to the Khayt app on the same computer". Data use: none collected
     or transmitted to the developer.
2. **Microsoft Edge Add-ons:** a Partner Center account (free); upload the same
   zip. Edge gives its own id — add it to the host manifest too.
3. **Firefox (AMO):** an addons.mozilla.org account; upload
   `dist/khayt-firefox.zip`. The gecko id is `save@khaytapp.com`
   (`pack.mjs` `GECKO_ID`) — confirm before the first upload, it cannot change.
   AMO asks for the source when code is minified; it is not, so none is needed.
4. **Safari:** ships inside Khayt.app (Developer ID, notarised by the normal
   Mac release). Nothing to upload. A Mac App Store listing would need the
   App Store build, which Khayt does not have.

Store listings should say, plainly: page details are sent only to the Khayt
app on your own computer; nothing is sent to Khayt's servers or anyone else.
