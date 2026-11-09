'use strict';

/**
 * The application menu, as a plain template.
 *
 * Pulled out of main.js so the parts that differ by platform and by build can
 * be tested without launching Electron. The E2E (scripts/e2e-help-menu.mjs)
 * reads the live menu, but it can only ever see an unpackaged build on the
 * runner's OS, which are exactly the two branches that matter least here.
 *
 * Everything that acts goes through the two functions passed in, so this file
 * holds no Electron state and no URLs of its own.
 *
 * @param {object} o
 * @param {boolean} o.isMac
 * @param {boolean} o.isPackaged
 * @param {boolean} o.isBedReady
 * @param {string}  o.flavorName       "Khayt" or "Bed Ready"
 * @param {{site:string, subreddit:string, repo:string}} o.links
 * @param {(url:string) => void} o.openHelpLink
 * @param {(cmd:string) => void} o.sendMenuCommand  renderer commands: 'open-settings', 'check-updates'
 */
function menuTemplate(o) {
  const { isMac, isPackaged, isBedReady, flavorName, links, openHelpLink, sendMenuCommand } = o;

  // Settings had no menu item and no shortcut. Ctrl+, / ⌘, is where VS Code,
  // Slack and Chromium apps keep it. macOS keeps it in the app menu; Windows
  // and Linux have no app menu, so it goes in File
  // (desktop-settings-menus-review.md §4.2).
  const settingsItem = { label: 'Settings…', accelerator: 'CmdOrCtrl+,', click: () => sendMenuCommand('open-settings') };

  return [
    ...(isMac ? [{
      // Electron derives app.name from package.json ("khayt"), so these role items would otherwise read
      // "About khayt" / "Hide khayt" / "Quit khayt" — even in Bed Ready. Override the name-bearing labels
      // with the flavor's product name (Bed Ready / Khayt). Deliberately NOT app.setName(): that would
      // repoint app.getPath('userData') from …/khayt and orphan every user's data.
      label: flavorName,
      submenu: [
        { role: 'about', label: `About ${flavorName}` }, { type: 'separator' },
        settingsItem, { type: 'separator' },
        { role: 'services' }, { type: 'separator' },
        { role: 'hide', label: `Hide ${flavorName}` }, { role: 'hideOthers' }, { role: 'unhide' }, { type: 'separator' },
        { role: 'quit', label: `Quit ${flavorName}` }
      ]
    }] : []),
    {
      label: 'File', submenu: [
        ...(isMac ? [] : [settingsItem, { type: 'separator' }]),
        isMac ? { role: 'close' } : { role: 'quit' },
      ]
    },
    {
      label: 'Edit', submenu: [
        { role: 'undo' }, { role: 'redo' }, { type: 'separator' },
        { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }
      ]
    },
    {
      label: 'View', submenu: [
        // Reload is a developer's key. In the shipped app Ctrl+R (a browser's
        // "refresh" to most people) threw away whatever form or modal was half
        // typed, so it exists only in an unpackaged build.
        ...(!isPackaged ? [{ role: 'reload' }, { role: 'forceReload' }, { role: 'toggleDevTools' }, { type: 'separator' }] : []),
        { role: 'resetZoom' }, { role: 'zoomIn' }, { role: 'zoomOut' }, { type: 'separator' },
        { role: 'togglefullscreen' }
      ]
    },
    {
      label: 'Window', submenu: [
        { role: 'minimize' }, { role: 'zoom' },
        // No Close on Windows/Linux: its Ctrl+W closed the only window, and
        // window-all-closed then quit the app. The title bar and Alt+F4 still
        // close it; a browser's "close tab" key no longer does.
        ...(isMac ? [{ type: 'separator' }, { role: 'front' }] : [])
      ]
    },
    {
      // There was no Help menu at all, so a shop that wanted the docs, the
      // release notes, or somewhere to report a bug had nowhere in the app to
      // find any of them.
      role: 'help',
      submenu: [
        { label: `${flavorName} Website`, click: () => openHelpLink(links.site) },
        // The subreddit belongs to Khayt. Bed Ready is a separate brand to the
        // people running it, and putting "r/khayt" in their Help menu would be
        // the first they had heard of the other product.
        ...(isBedReady ? [] : [
          { label: 'Community — r/khayt', click: () => openHelpLink(links.subreddit) },
        ]),
        { type: 'separator' },
        // Windows/Linux have no app menu to hold it; it sat 3,400 px down
        // Settings ▸ Data & Locale and nowhere else.
        { label: 'Check for Updates…', click: () => sendMenuCommand('check-updates') },
        { label: 'Release Notes', click: () => openHelpLink(`${links.repo}/releases`) },
        { label: 'Report an Issue', click: () => openHelpLink(`${links.repo}/issues/new`) },
      ]
    }
  ];
}

module.exports = { menuTemplate };
