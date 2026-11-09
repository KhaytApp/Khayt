'use strict';
/**
 * The menu bar, per platform and per build (lib/main/app-menu.js).
 *
 * The E2E reads the live menu, but only ever an unpackaged build on the
 * runner's OS. The two fixes here live in the other branches: Reload is gone
 * from PACKAGED builds, and Ctrl+W is gone on WINDOWS/LINUX.
 */
const test = require('node:test');
const assert = require('node:assert');
const { menuTemplate } = require('../lib/main/app-menu');

function build(over = {}) {
  const sent = [];
  const opened = [];
  const tpl = menuTemplate({
    isMac: false, isPackaged: true, isBedReady: false, flavorName: 'Khayt',
    links: { site: 'https://khaytapp.com', subreddit: 'https://www.reddit.com/r/khayt', repo: 'https://github.com/KhaytApp/Khayt' },
    openHelpLink: (u) => opened.push(u),
    sendMenuCommand: (c) => sent.push(c),
    ...over,
  });
  return { tpl, sent, opened };
}

const all = (tpl) => tpl.flatMap((m) => m.submenu || []);
const menu = (tpl, name) => tpl.find((m) => m.label === name || m.role === name);

test('a packaged build has no Reload, Force Reload or DevTools on any platform', () => {
  for (const isMac of [false, true]) {
    const roles = all(build({ isMac }).tpl).map((i) => i.role);
    for (const r of ['reload', 'forceReload', 'toggleDevTools']) {
      assert.ok(!roles.includes(r), `${r} is in a packaged ${isMac ? 'mac' : 'win/linux'} menu`);
    }
  }
});

test('an unpackaged build keeps them, for whoever is building it', () => {
  const roles = all(build({ isPackaged: false }).tpl).map((i) => i.role);
  for (const r of ['reload', 'forceReload', 'toggleDevTools']) assert.ok(roles.includes(r), r);
});

test('on Windows/Linux nothing closes the only window from the keyboard', () => {
  const items = all(build({ isMac: false }).tpl);
  assert.ok(!items.some((i) => i.role === 'close'), 'a Close item carries Ctrl+W');
  assert.ok(!items.some((i) => /CmdOrCtrl\+W|Ctrl\+W/i.test(i.accelerator || '')));
});

test('macOS keeps File ▸ Close (⌘W does not quit there)', () => {
  assert.ok(menu(build({ isMac: true }).tpl, 'File').submenu.some((i) => i.role === 'close'));
});

test('Settings is reachable with Ctrl+, from File on Windows/Linux and the app menu on macOS', () => {
  const win = build({ isMac: false });
  const s = menu(win.tpl, 'File').submenu.find((i) => i.label === 'Settings…');
  assert.ok(s, 'no File ▸ Settings…');
  assert.strictEqual(s.accelerator, 'CmdOrCtrl+,');
  s.click();
  assert.deepStrictEqual(win.sent, ['open-settings']);

  const mac = build({ isMac: true });
  assert.ok(mac.tpl[0].submenu.some((i) => i.label === 'Settings…' && i.accelerator === 'CmdOrCtrl+,'));
  assert.ok(!menu(mac.tpl, 'File').submenu.some((i) => i.label === 'Settings…'), 'Settings twice on macOS');
});

test('the one accelerator a shortcut uses belongs to one item', () => {
  for (const isMac of [false, true]) {
    const accs = all(build({ isMac }).tpl).map((i) => i.accelerator).filter(Boolean);
    assert.strictEqual(new Set(accs).size, accs.length, accs.join(','));
  }
});

test('Help ▸ Check for Updates… asks the window to run its own update check', () => {
  const b = build();
  const item = menu(b.tpl, 'help').submenu.find((i) => i.label === 'Check for Updates…');
  assert.ok(item);
  item.click();
  assert.deepStrictEqual(b.sent, ['check-updates']);
});

test('Bed Ready keeps its own Help: no r/khayt, its own site', () => {
  const b = build({ isBedReady: true, flavorName: 'Bed Ready', links: { site: 'https://bedready.io', subreddit: 'x', repo: 'https://github.com/KhaytApp/Khayt' } });
  const labels = menu(b.tpl, 'help').submenu.map((i) => i.label).filter(Boolean);
  assert.ok(!labels.some((l) => /khayt/i.test(l)), labels.join('|'));
  menu(b.tpl, 'help').submenu[0].click();
  assert.deepStrictEqual(b.opened, ['https://bedready.io']);
});
