'use strict';
/**
 * The nightly off-site backup, as this computer runs it — the Mac's
 * OffsiteBackups.swift. lib/offsite-backup.js is the rule (name, sealing,
 * proof, what to keep); this is the schedule, the settings and the IPC.
 *
 * ── THE SETTINGS ARE THIS COMPUTER'S, NOT THE BOOK'S ────────────────────
 *
 * Kept in a small file in userData, not in `settings`, for the Mac's reasons:
 * it is a JOB this computer does (a book that syncs would arm it on every
 * device, and they would all upload the same book every night); a folder
 * destination is a path on this disk; and nothing here turns on by itself —
 * the August 2026 development leftover in `settings.printLibrary.s3` never
 * arms anything. The shop picks a destination; only then is the library's
 * bucket or Drive used.
 *
 * The CREDENTIALS are the library's (Settings › Print library), so a shop that
 * set up online storage is not asked twice. The key is the shop's Khayt Cloud
 * data key, held only while Khayt Cloud is unlocked: no key, no backup.
 */
const fs = require('fs');
const path = require('path');
const OB = require('../offsite-backup.js');

const CHECK_EVERY_MS = 60 * 60 * 1000;
const FIRST_CHECK_MS = 5 * 60 * 1000;

function registerOffsiteBackup({ app, ipcMain, dialog, BrowserWindow, getDek, readBookBytes, decryptForWindow, libraryBucket, libraryDrive, log = console }) {
  const file = () => path.join(app.getPath('userData'), 'offsite-backup.json');
  const read = () => {
    try { return JSON.parse(fs.readFileSync(file(), 'utf8')) || {}; } catch (_) { return {}; }
  };
  const write = (v) => {
    const tmp = file() + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(v, null, 2));
    fs.renameSync(tmp, file());
  };
  const settingsOf = (v) => {
    const s = (v && v.settings) || {};
    return {
      enabled: s.enabled === true,
      destination: ['bucket', 'drive', 'folder'].includes(s.destination) ? s.destination : 'folder',
      folderPath: typeof s.folderPath === 'string' ? s.folderPath : '',
    };
  };

  /** Where the backup goes, or `{ error }` saying what is missing. */
  function destination(settings) {
    if (settings.destination === 'bucket') {
      const b = libraryBucket();
      if (!b) return { error: 'bucket_missing' };
      return { dest: OB.bucketDestination(b.client, b.prefix), where: b.label };
    }
    if (settings.destination === 'drive') {
      const d = libraryDrive();
      if (!d) return { error: 'drive_missing' };
      return { dest: OB.driveDestination(d.client, d.prefix), where: 'Google Drive' };
    }
    const p = String(settings.folderPath || '').trim();
    if (!p || !path.isAbsolute(p)) return { error: 'folder_missing' };
    return { dest: OB.folderDestination(p), where: p };
  }

  let running = null;
  async function runNow() {
    if (running) return running;
    running = (async () => {
      const state = read();
      const settings = settingsOf(state);
      const now = Date.now();
      try {
        const d = destination(settings);
        // The reasons the shop can act on travel as codes (offsite.<code> in
        // the window's language); anything else is the destination's own words.
        if (d.error) throw new OB.OffsiteError(d.error, d.error);
        const dek = getDek();
        if (!dek) throw new OB.OffsiteError('needs_unlock', 'needs_unlock');
        const book = readBookBytes();
        if (!book || !book.length) throw new Error('There is no book on this computer to back up yet.');
        const local = new Date(now);
        const day = `${local.getFullYear()}-${String(local.getMonth() + 1).padStart(2, '0')}-${String(local.getDate()).padStart(2, '0')}`;
        const outcome = await OB.run({ book, dek, day, createdAt: local.toISOString(), destination: d.dest });
        write({ ...state, status: OB.succeeded(outcome, now) });
        return { ok: true, ...outcome, where: d.where };
      } catch (e) {
        const code = (e && e.code) || '';
        const why = String((e && e.message) || e);
        write({ ...state, status: { ...OB.failed(state.status, why, now), lastCode: code } });
        log.warn && log.warn('offsite backup failed:', code || 'error');
        return { ok: false, code, error: why };
      }
    })();
    try { return await running; } finally { running = null; }
  }

  // Once an hour: a backup when one is due and the shop turned it on. The
  // first look waits a few minutes so it never competes with launch.
  async function tick() {
    const state = read();
    const s = settingsOf(state);
    if (!s.enabled || !OB.isDue(state.status, Date.now())) return;
    if (!getDek()) return;  // locked: try again next hour rather than log a failure every hour
    await runNow();
  }
  const first = setTimeout(() => { tick().catch(() => {}); }, FIRST_CHECK_MS);
  const every = setInterval(() => { tick().catch(() => {}); }, CHECK_EVERY_MS);
  if (first.unref) first.unref();
  if (every.unref) every.unref();

  ipcMain.handle('hub:offsite-get', () => {
    const state = read();
    const settings = settingsOf(state);
    const d = destination(settings);
    return {
      settings, status: state.status || {},
      ready: !d.error, where: d.where || '', problem: d.error || '',
      unlocked: !!getDek(),
      overdue: OB.isOverdue(state.status, Date.now()),
    };
  });
  ipcMain.handle('hub:offsite-set', (_e, next = {}) => {
    const state = read();
    write({ ...state, settings: settingsOf({ settings: { ...settingsOf(state), ...next } }) });
    return { ok: true };
  });
  ipcMain.handle('hub:offsite-run', () => runNow());
  /** Choose the folder, and keep it only if this computer can write there. */
  ipcMain.handle('hub:offsite-pick-folder', async (event) => {
    const r = await dialog.showOpenDialog(BrowserWindow.fromWebContents(event.sender), {
      properties: ['openDirectory', 'createDirectory'],
    });
    if (r.canceled || !r.filePaths.length) return null;
    const dir = r.filePaths[0];
    try { fs.accessSync(dir, fs.constants.W_OK); } catch (_) { return { ok: false, error: `No permission to write to ${dir}.` }; }
    const state = read();
    write({ ...state, settings: { ...settingsOf(state), destination: 'folder', folderPath: dir } });
    return { ok: true, path: dir };
  });
  ipcMain.handle('hub:offsite-list', async () => {
    try {
      const d = destination(settingsOf(read()));
      if (d.error) return { ok: false, code: d.error, error: d.error };
      return { ok: true, entries: await OB.available(d.dest) };
    } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
  });
  /** The chosen backup, opened and handed to the window's usual restore. */
  ipcMain.handle('hub:offsite-restore', async (event, name) => {
    try {
      const d = destination(settingsOf(read()));
      if (d.error) return { ok: false, code: d.error, error: d.error };
      const bytes = await OB.fetchBook(String(name || ''), d.dest, getDek());
      return { ok: true, json: await decryptForWindow(bytes, event) };
    } catch (e) { return { ok: false, code: (e && e.code) || '', error: String((e && e.message) || e) }; }
  });

  return { runNow, tick, stop() { clearTimeout(first); clearInterval(every); } };
}

module.exports = { registerOffsiteBackup };
