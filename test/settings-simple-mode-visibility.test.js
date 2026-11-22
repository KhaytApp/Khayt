'use strict';
/**
 * What Simple mode shows in Settings ▸ Online (desktop-settings-menus-review.md §0).
 *
 * It used to be backwards: Khayt Cloud carried `pro-only`, so a Simple shop
 * could not sign in or sync at all, while the same pane showed it the LAN REST
 * API's port, webhook token, Salla/Zid secrets and the internet tunnel.
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'renderer/index.html'), 'utf8');
const settingsJs = fs.readFileSync(path.join(root, 'renderer/settings.js'), 'utf8');

/** The opening tag of the card that holds `innerId`. */
function cardTagHolding(innerId) {
  const at = html.indexOf(`id="${innerId}"`);
  assert.ok(at > 0, `#${innerId} is gone from index.html`);
  const open = html.lastIndexOf('<div class="card settings-card', at);
  return html.slice(open, html.indexOf('>', open) + 1);
}

test('Khayt Cloud is in Settings for a Simple shop', () => {
  assert.doesNotMatch(cardTagHolding('cloudSettingsSection'), /pro-only/);
});

test('the storefront directory stays Professional', () => {
  const at = html.indexOf('data-i18n="integ.title"');
  const tag = html.slice(html.lastIndexOf('<div class="card settings-card', at), at);
  assert.match(tag, /pro-only/);
});

test('the LAN card hides its developer controls in Simple — but only while unused', () => {
  const fn = settingsJs.slice(settingsJs.indexOf('function renderLanApiSettings'));
  const body = fn.slice(0, fn.indexOf('\nfunction '));
  assert.match(body, /const devOnly = \(inUse\) => \(inUse \? "" : " pro-only"\);/);
  // Each developer control's wrapper, keyed by the field it holds.
  for (const [field, inUse] of [
    ['data-i18n="lan.port"', '(lan.port || 3219) !== 3219'],
    ['data-i18n="lan.intake_pin"', '!!lan.intakePin'],
    ['data-i18n="lan.webhook_token"', '!!lan.webhookToken'],
    ['data-i18n="lan.salla_secret"', '!!(lan.sallaWebhookSecret || lan.zidWebhookSecret)'],
    ['id="lan_tunnel_enabled"', '!!lan.tunnelEnabled'],
  ]) {
    const at = body.indexOf(field);
    assert.ok(at > 0, field);
    const before = body.slice(Math.max(0, at - 260), at);
    assert.ok(before.includes(`lan-dev\${devOnly(${inUse})}`), `${field} is not wrapped in devOnly(${inUse})`);
  }
  // What a Simple shop needs to pair a phone stays in view.
  for (const id of ['lan_enabled', 'lan_pin', 'lan_bind_lan', 'lanPairedPhones', 'btnStartLan']) {
    const at = body.indexOf(`id="${id}"`);
    assert.ok(at > 0, id);
  }
});

test('no settings string tells a Windows or Linux shop about "this Mac"', () => {
  const keys = ['lan.bind_lan_hint', 'lan.loopback_warn', 'set.plib_use_default', 'set.plib_this_mac',
    'plg.dev_mode', 'plg.dev_hint', 'plg.dev_badge', 'plg.dev_warning'];
  const dir = path.join(root, 'renderer/locales');
  for (const f of fs.readdirSync(dir).filter((n) => n.endsWith('.js'))) {
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    for (const k of keys) {
      const line = src.split('\n').find((l) => l.includes(`"${k}":`));
      if (!line) continue;
      assert.doesNotMatch(line, /Mac|الماك/, `${f} ${k}`);
    }
  }
});
