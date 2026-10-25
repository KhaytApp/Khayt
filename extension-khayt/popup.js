// The popup: read the page the shop is on, show what will be saved, save it.
//
// Nothing happens until the toolbar button is pressed. Then, for that tab
// only (`activeTab`), `pageSnapshot` reads the page's markup; it is parsed here
// in an inert document and read by the site's reader (`src/adapters.js`). The
// shop sees exactly what will be saved before anything leaves the browser, and
// Save sends it to Khayt over native messaging and to nowhere else.
import { extract } from './src/adapters.js';
import { pageSnapshot, MAX_HTML } from './src/snapshot.js';
import { extensionApi, askKhayt, saveMessage } from './src/native.js';
import { describe } from './src/states.js';

const api = extensionApi();
const $ = (id) => document.getElementById(id);
const say = (key, subs) => (api.i18n && api.i18n.getMessage(key, subs)) || key;

const SITE_NAMES = {
  printables: 'Printables', makerworld: 'MakerWorld', thingiverse: 'Thingiverse',
  thangs: 'Thangs', cults3d: 'Cults3D', myminifactory: 'MyMiniFactory',
};

function show(id) {
  for (const s of document.querySelectorAll('.state')) s.hidden = s.id !== id;
}

function localise() {
  const dir = say('@@bidi_dir');
  document.documentElement.dir = dir === 'rtl' ? 'rtl' : 'ltr';
  document.documentElement.lang = say('@@ui_locale').split('_')[0] || 'en';
  for (const el of document.querySelectorAll('[data-i18n]')) el.textContent = say(el.dataset.i18n);
  document.title = say('popupHeading');
}

function render(page) {
  $('title').textContent = page.title;
  let host = '';
  try { host = new URL(page.url).hostname.replace(/^www\./, ''); } catch { /* shown blank */ }
  $('site').textContent = SITE_NAMES[page.site] || host;
  $('creator').textContent = page.creator ? say('popupBy', [page.creator]) : '';
  $('creatorSep').hidden = !page.creator;
  // Khayt's id, shown the way a licence is written: `cc-by-nc` → CC BY-NC.
  $('licence').textContent = /^cc(0|-)/.test(page.licence)
    ? page.licence.replace(/^cc-?/, 'CC ').replace('CC 0', 'CC0').toUpperCase() : page.licence;
  $('licence').hidden = !page.licence;
  const n = page.files.length;
  $('files').textContent = n === 1 ? say('popupOneFile') : say('popupFiles', [String(n)]);
  $('files').hidden = n === 0;
  if (page.cover) $('cover').src = page.cover; else $('cover').removeAttribute('src');
  const tags = $('tags');
  tags.replaceChildren(...page.tags.slice(0, 8).map((t) => {
    const li = document.createElement('li');
    li.textContent = t;
    li.dir = 'auto';
    return li;
  }));
  $('description').textContent = page.description;
  $('description').hidden = !page.description;
  show('preview');
}

function result(reply) {
  const { key, tone } = describe(reply);
  const text = $('resultText');
  text.textContent = say(key);
  text.className = 'result ' + tone;
  show('result');
}

async function readActiveTab() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  if (!tab || !/^https:/i.test(tab.url || '')) return null;
  const [done] = await api.scripting.executeScript({
    target: { tabId: tab.id }, func: pageSnapshot, args: [MAX_HTML],
  });
  const snap = done && done.result;
  if (!snap || typeof snap.html !== 'string') return null;
  const doc = new DOMParser().parseFromString(snap.html, 'text/html');
  return { tab, page: extract(doc, snap.url) };
}

async function main() {
  localise();
  let read = null;
  try { read = await readActiveTab(); } catch { read = null; }
  const page = read && read.page;
  if (!page) { show('unsupported'); return; }
  render(page);
  const save = $('save');
  save.disabled = false;
  save.addEventListener('click', async () => {
    save.disabled = true;
    save.textContent = say('popupSaving');
    const reply = await askKhayt(api, saveMessage(page), read.tab && read.tab.id);
    result(reply);
    save.textContent = say('popupDone');
    save.disabled = false;
    save.onclick = () => window.close();
  }, { once: true });
}

main();
