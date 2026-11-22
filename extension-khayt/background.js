// The extension's background: the popup's messages to Khayt go through here,
// and — where the browser has a downloads API — the model downloaded from a
// page just saved is offered to that page's record in Khayt.
//
// A popup closes the moment the shop clicks elsewhere, and a native message in
// flight from it dies with it. Sent from here, the save completes whether the
// popup is still open or not.
//
// A CLASSIC SCRIPT, not a module, so the one file loads the same way as
// Chrome's service worker, Firefox's event page and Safari's non-persistent
// background page. `src/native.js` is the popup's copy of the same two rules.
// The functions are top-level declarations so `test/webext-attach.test.js`
// can load this file in a sandbox and call them.
'use strict';

const api = globalThis.browser || globalThis.chrome;
const HOST = 'app.khayt.mac';

/** How long after a save a download still belongs to it (WebSave.attachWindow). */
const ATTACH_WINDOW_MS = 10 * 60 * 1000;
/** A download begun this long before the save still counts: the shop may press Download first. */
const STARTED_BEFORE_MS = 2 * 60 * 1000;
/** WebSave.modelKinds — `test/webext-attach.test.js` holds the two lists equal. */
const MODEL_KINDS = ['3mf', 'stl', 'obj', 'step', 'stp', 'zip', '7z', 'rar',
  'gcode', 'bgcode', 'f3d', 'blend', 'ply', 'amf'];

async function sendToKhayt(message) {
  try {
    const reply = await api.runtime.sendNativeMessage(HOST, message);
    if (reply && typeof reply === 'object' && typeof reply.state === 'string') return reply;
    return { ok: false, state: 'no-host' };
  } catch (e) {
    return { ok: false, state: 'no-host', error: String((e && e.message) || e).slice(0, 200) };
  }
}

// ── WHICH DOWNLOAD BELONGS TO WHICH SAVE ──────────────────────────────────
//
// What is remembered, and only in the browser's session storage (gone when
// the browser quits): for each save in the last ten minutes, the page's
// address, the model-file links the page listed, the tab it was saved from,
// and when. Nothing about any other page or download is kept.

/** `origin + path`, without a trailing slash, query or fragment — or ''. */
function pageKey(raw) {
  try {
    const u = new URL(raw);
    if (u.protocol !== 'https:') return '';
    return (u.origin + u.pathname).replace(/\/+$/, '').toLowerCase();
  } catch { return ''; }
}

function hostOf(raw) {
  try { return new URL(raw).hostname.replace(/^www\./, '').toLowerCase(); } catch { return ''; }
}

function extOf(path) {
  const leaf = String(path || '').split(/[\\/]/).pop() || '';
  const dot = leaf.lastIndexOf('.');
  return dot > 0 ? leaf.slice(dot + 1).toLowerCase() : '';
}

function isModelFile(path) { return MODEL_KINDS.includes(extOf(path)); }

/**
 * The save a finished download belongs to, or null.
 *
 * `item` is a `downloads.DownloadItem`; `saves` the remembered saves;
 * `tabId` the tab that was in front when the download began (or null);
 * `now` epoch ms. A download belongs to a save when it is a finished model
 * file at an absolute path, it began no earlier than two minutes before the
 * save and the save is under ten minutes old, and one of: it came from the
 * tab the page was saved in, its referrer is that page (or another page on
 * the same site), or its address is one of the file links the page listed.
 * The newest matching save wins.
 */
function matchDownload(item, saves, tabId, now) {
  if (!item || item.state !== 'complete' || item.exists === false) return null;
  const path = String(item.filename || '');
  if (!path.startsWith('/') || !isModelFile(path)) return null;
  const started = Date.parse(item.startTime || '') || now;
  const candidates = (saves || [])
    .filter((s) => s && typeof s.at === 'number' && now - s.at <= ATTACH_WINDOW_MS && started >= s.at - STARTED_BEFORE_MS)
    .sort((a, b) => b.at - a.at);
  const referrer = pageKey(item.referrer || '');
  const refHost = hostOf(item.referrer || '');
  const urls = [item.url, item.finalUrl].filter(Boolean).map(String);
  // The exact page or one of its own file links first, over every save; only
  // then the looser tab and same-site rules — a download from another page of
  // the same site was offered to the last page saved there.
  for (const s of candidates) {
    if (referrer && referrer === pageKey(s.url)) return s;
    if (urls.some((u) => (s.files || []).includes(u))) return s;
  }
  for (const s of candidates) {
    if (tabId != null && s.tabId === tabId) return s;
    if (refHost && refHost === hostOf(s.url)) return s;
  }
  return null;
}

/** The message an attach is (`WebSave.Attach`). */
function attachMessage(save, item) {
  const leaf = String(item.filename).split('/').pop();
  return { v: 1, kind: 'attach', attach: { page: save.url, path: String(item.filename), name: leaf } };
}

const session = api.storage && api.storage.session;

async function loadSaves() {
  if (!session) return [];
  try {
    const got = await session.get('saves');
    return Array.isArray(got && got.saves) ? got.saves : [];
  } catch { return []; }
}

async function storeSaves(saves) {
  if (!session) return;
  const now = Date.now();
  try { await session.set({ saves: saves.filter((s) => now - s.at <= ATTACH_WINDOW_MS).slice(-10) }); } catch { /* not kept */ }
}

// One read-then-write at a time: two saves within one storage round trip each
// read the same list and the second write dropped the first save.
let remembering = Promise.resolve();

function remember(page, tabId) {
  const next = remembering.then(() => rememberNow(page, tabId), () => rememberNow(page, tabId));
  remembering = next.catch(() => {});
  return next;
}

async function rememberNow(page, tabId) {
  if (!api.downloads || !page || !pageKey(page.url)) return;
  const saves = await loadSaves();
  saves.push({
    url: String(page.url),
    files: (Array.isArray(page.files) ? page.files : []).map((f) => String((f && f.url) || '')).filter(Boolean).slice(0, 20),
    tabId: typeof tabId === 'number' ? tabId : null,
    at: Date.now(),
  });
  await storeSaves(saves);
}

// ── THE DOWNLOADS, ONLY WHERE THERE IS AN API (Chrome, Edge, Brave, Firefox) ─
//
// Safari has none; there the app watches ~/Downloads instead, for ten minutes
// after a save (`SafariDownloadsWatch`). Every download is looked at only to
// ask "is this a model from a page just saved"; one that is not is forgotten
// at once, and nothing is sent about it.
if (api.downloads && api.downloads.onChanged) {
  // The tab in front when each download began — Chrome's DownloadItem has no
  // tab of its own. Held only while the download runs.
  const tabs = new Map();
  if (api.downloads.onCreated) {
    api.downloads.onCreated.addListener(async (item) => {
      if (!(await loadSaves()).length) return;
      try {
        const [tab] = await api.tabs.query({ active: true, lastFocusedWindow: true });
        if (tab && typeof tab.id === 'number') tabs.set(item.id, tab.id);
      } catch { /* no tab: matched by its referrer instead */ }
    });
  }
  api.downloads.onChanged.addListener(async (delta) => {
    if (!delta || !delta.state) return;
    const tabId = tabs.has(delta.id) ? tabs.get(delta.id) : null;
    if (delta.state.current !== 'in_progress') tabs.delete(delta.id);
    if (delta.state.current !== 'complete') return;
    const saves = await loadSaves();
    if (!saves.length) return;
    let item;
    try { [item] = await api.downloads.search({ id: delta.id }); } catch { return; }
    const save = matchDownload(item, saves, tabId, Date.now());
    if (save) await sendToKhayt(attachMessage(save, item));
  });
}

api.runtime.onMessage.addListener((msg, sender, reply) => {
  // Only the extension's own pages: there are no content scripts, so a
  // message from a tab is not one of ours.
  if (!msg || typeof msg !== 'object' || (sender && sender.tab)) return false;
  if (msg.type === 'khayt' && msg.message && typeof msg.message === 'object') {
    sendToKhayt(msg.message).then(async (answer) => {
      if (msg.message.kind === 'save' && answer && answer.ok) await remember(msg.message.page, msg.tabId);
      reply(answer);
    });
    return true;
  }
  return false;
});
