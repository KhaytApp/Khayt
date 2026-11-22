const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { JSDOM } = require('jsdom');

const SRC = fs.readFileSync(path.join(__dirname, '..', 'renderer/update-ui.js'), 'utf8');

/**
 * Boot update-ui.js against a jsdom document with the three globals it borrows
 * from the rest of the renderer (escapeHtml, appendStackedModal, t), and hand
 * back the update callbacks the module registers so a test can drive them the
 * way the main process would.
 */
function boot({ strings = {} } = {}) {
  const dom = new JSDOM('<!doctype html><html><body></body></html>');
  const { window } = dom;
  const cb = {};

  window.hubAPI = {
    formatReleaseNotes: async () => '',
    startUpdateDownload: () => { cb.downloadStarted = true; },
    onUpdateAvailable:        (fn) => { cb.available = fn; },
    onUpdateDownloadProgress: (fn) => { cb.progress = fn; },
    onUpdateDownloaded:       (fn) => { cb.downloaded = fn; },
    onUpdateError:            (fn) => { cb.error = fn; },
  };
  window.escapeHtml = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  window.appendStackedModal = (html) => {
    const el = window.document.createElement('div');
    el.innerHTML = html;
    window.document.body.appendChild(el);
    return el;
  };
  window.t = (key) => strings[key] || key;   // unknown key → tr() uses its fallback

  vm.runInContext(SRC, vm.createContext(window), { filename: 'update-ui.js' });
  return { window, cb };
}

async function openDownloadingModal(window, cb) {
  window.KhaytUpdateUI.wireUpdateUI({ getCurrentVersion: () => '3.3.0' });
  await window.KhaytUpdateUI.showUpdateChangesModal(
    { version: '3.4.0-beta.2', releaseNotes: '' }, { currentVersion: '3.3.0' });
  // Click "Download update" the way a user would.
  window.document.querySelector('[data-upd="download"]').click();
  return cb;
}

test('a running download shows bytes, speed and ETA — not just a percentage', async () => {
  // Reported from the field as "started the download but nothing is
  // downloading": the download was fine, but on a 158 MB file the percentage
  // creeps a point every few seconds and the UI discarded transferred/total/
  // bytesPerSecond, so there was nothing on screen that looked like movement.
  const { window, cb } = boot();
  await openDownloadingModal(window, cb);

  cb.progress({ percent: 12.7, transferred: 20 * 1048576, total: 158 * 1048576, bytesPerSecond: 2 * 1048576 });

  const meta = window.document.querySelector('.update-progress-meta').textContent;
  assert.match(meta, /20\.0 MB \/ 158\.0 MB/, 'byte counter missing');
  assert.match(meta, /2\.0 MB\/s/, 'speed missing');
  assert.match(meta, /about 1 min/, 'ETA missing');
  assert.equal(window.document.querySelector('.update-progress-label').textContent, '13%');
});

test('progress updates in place instead of rebuilding the live region', async () => {
  // setModalBody on every tick replaced the whole aria-live block, which makes
  // a screen reader re-announce it several times a second.
  const { window, cb } = boot();
  await openDownloadingModal(window, cb);

  const first = window.document.querySelector('.update-progress-fill');
  cb.progress({ percent: 40, transferred: 10, total: 100, bytesPerSecond: 5 });
  const second = window.document.querySelector('.update-progress-fill');

  assert.equal(first, second, 'progress bar node was replaced, not updated');
  assert.equal(second.style.width, '40%');
  const bar = window.document.querySelector('.update-progress-bar');
  assert.equal(bar.getAttribute('aria-valuenow'), '40');
});

test('a download that never reports progress eventually says so', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const { window, cb } = boot();
  await openDownloadingModal(window, cb);

  assert.equal(window.document.querySelector('.update-progress-stalled'), null,
    'stall notice shown immediately');
  t.mock.timers.tick(46_000);
  const note = window.document.querySelector('.update-progress-stalled');
  assert.ok(note, 'no stall notice after 45s of silence');
  assert.match(note.textContent, /not progressed/i);
});

test('a recovering download clears the stall notice', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const { window, cb } = boot();
  await openDownloadingModal(window, cb);

  t.mock.timers.tick(46_000);
  assert.ok(window.document.querySelector('.update-progress-stalled'), 'precondition: notice shown');

  cb.progress({ percent: 5, transferred: 1, total: 100, bytesPerSecond: 1 });
  assert.equal(window.document.querySelector('.update-progress-stalled'), null,
    'stall notice survived a fresh progress event');
});

test('byte and ETA formatting stays readable across the range', async () => {
  const { window, cb } = boot();
  await openDownloadingModal(window, cb);
  const meta = () => window.document.querySelector('.update-progress-meta').textContent;

  cb.progress({ percent: 1, transferred: 512 * 1048576, total: 2048 * 1048576, bytesPerSecond: 1048576 });
  assert.match(meta(), /512\.0 MB \/ 2\.00 GB/, 'GB threshold not applied');

  // 1 MB left at 1 MB/s — under a minute, so the ETA reads in seconds.
  cb.progress({ percent: 99, transferred: 157 * 1048576, total: 158 * 1048576, bytesPerSecond: 1048576 });
  assert.match(meta(), /about 1 sec/, 'sub-minute ETA should be in seconds');

  // No totals yet (electron-updater emits a first event with zeros) — show the
  // bar without inventing "0.0 MB / 0.0 MB · NaN".
  cb.progress({ percent: 0, transferred: 0, total: 0, bytesPerSecond: 0 });
  assert.equal(meta().trim(), '');
});
