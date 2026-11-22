'use strict';
/**
 * Printer alerts and print notices to Telegram and ntfy on Windows/Linux — the
 * Mac's PrintNotices / NtfySettings, through the shared lib/alert-routes.js.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');

test('the Telegram settings card renders into a container the page has', () => {
  // It looked for #telegramSettingsSection, which the page has not had since
  // v2.0.12: the card was empty and Telegram could not be set up on desktop.
  const html = read('renderer/index.html');
  const src = read('renderer/settings.js');
  const fn = src.slice(src.indexOf('function renderTelegramSettings('), src.indexOf('function renderNtfySettings('));
  const id = /getElementById\('([^']+)'\)/.exec(fn)[1];
  assert.ok(html.includes(`id="${id}"`), `renderTelegramSettings fills #${id}, which index.html does not have`);
  const nfn = src.slice(src.indexOf('function renderNtfySettings('));
  const nid = /getElementById\('([^']+)'\)/.exec(nfn)[1];
  assert.ok(html.includes(`id="${nid}"`), `renderNtfySettings fills #${nid}, which index.html does not have`);
});

test('both entry points load the routing rule', () => {
  for (const f of ['renderer/index.html', 'renderer/bedready.html']) {
    assert.match(read(f), /<script src="\.\.\/lib\/alert-routes\.js"><\/script>/, f);
  }
});

test('the ntfy token is read from the saved book in main, never taken from the window', () => {
  const main = read('main.js');
  const at = main.indexOf("ipcMain.handle('hub:send-ntfy'");
  assert.ok(at > 0);
  const body = main.slice(at, at + 1800);
  assert.match(body, /async \(_e, \{ type, title, body \} = \{\}\)/, 'the window sends only what happened');
  assert.match(body, /readStoreDecryptedFromDisk\(\)/);
  assert.match(body, /ntfyRequest\(\{ type, title, body \}, s\)/);
  assert.match(body, /redirect: 'manual'/);
});

/** Run the renderer's transition watcher with stubbed transports. */
function harness(settings) {
  const sent = { telegram: [], ntfy: [] };
  const ctx = {
    settings, machines: [{ id: 'M1', name: 'X1C' }], console,
    KhaytAlertRoutes: require('../lib/alert-routes.js'),
    t: (k, f) => (k.startsWith('alerts.notice_') ? `${f.machine} ${k.slice(14)}` : k),
    window: { hubAPI: {
      sendTelegram: (o) => { sent.telegram.push(o.message); return Promise.resolve({ ok: true }); },
      sendNtfy: (o) => { sent.ntfy.push(o); return Promise.resolve({ ok: true }); },
    } },
  };
  vm.createContext(ctx);
  const src = read('renderer/integrations.js');
  const a = src.indexOf('let _printPhase = {};');
  const b = src.indexOf('function _firePrintNotification(');
  vm.runInContext(src.slice(a, b) + '; this.notifyPrintTransitions = notifyPrintTransitions;', ctx);
  return { ctx, sent };
}

test('a finished print is told to the channels that opted in, without the file name unless asked', () => {
  const settings = {
    notifyPrintDone: false,
    telegram: { botToken: '1:a', chatId: '5', notifyPrintFinished: true },
    ntfy: { enabled: true, topic: 'khayt-test', events: { finished: true }, printNoticeNames: true },
  };
  const { ctx, sent } = harness(settings);
  ctx.notifyPrintTransitions({ M1: { state: 'printing', filename: 'client-bracket.3mf' } });
  ctx.notifyPrintTransitions({ M1: { state: 'finished', filename: 'client-bracket.3mf' } });
  assert.deepEqual(sent.telegram, ['✅ X1C finished'], 'Telegram did not ask for names');
  assert.deepEqual(sent.ntfy.map((n) => [n.type, n.title, n.body]), [['finished', 'X1C finished', 'client-bracket.3mf']]);
});

test('print notices are opt-in: a channel set up for faults is not told about every print', () => {
  const { ctx, sent } = harness({ telegram: { botToken: '1:a', chatId: '5' }, ntfy: { enabled: true, topic: 'k' } });
  ctx.notifyPrintTransitions({ M1: { state: 'printing' } });
  ctx.notifyPrintTransitions({ M1: { state: 'finished' } });
  assert.deepEqual(sent, { telegram: [], ntfy: [] });
});

test('a pause is told once, and a resume re-arms it', () => {
  const { ctx, sent } = harness({ ntfy: { enabled: true, topic: 'k', events: { paused: true, finished: true } } });
  ctx.notifyPrintTransitions({ M1: { state: 'printing' } });
  ctx.notifyPrintTransitions({ M1: { state: 'paused' } });
  ctx.notifyPrintTransitions({ M1: { state: 'paused' } });
  assert.deepEqual(sent.ntfy.map((n) => n.type), ['paused']);
  ctx.notifyPrintTransitions({ M1: { state: 'printing' } });
  ctx.notifyPrintTransitions({ M1: { state: 'paused' } });
  ctx.notifyPrintTransitions({ M1: { state: 'complete' } });
  assert.deepEqual(sent.ntfy.map((n) => n.type), ['paused', 'paused', 'finished']);
});
