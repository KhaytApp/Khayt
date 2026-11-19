'use strict';
/**
 * A machine as the WINDOW holds it, with its credentials put back from disk.
 *
 * The window never sees a secret: `maskStoreSecretsForRenderer` replaces every
 * one on the list (lib/store-secret-paths.js) — a printer's API key and Bambu
 * access code, a smart plug's token and password — with `__KHAYT_MASKED__`.
 * And every printer call in main.js (the poll, pause/resume/cancel, sending a
 * print, the history import, the plate list) takes the machine the window
 * hands it. So each one sent the MASK: OctoPrint, PrusaLink and Moonraker were
 * asked with `X-Api-Key: __KHAYT_MASKED__`, and a Bambu was given it as its
 * LAN access code. Only a save put the real values back
 * (`mergeStoreSecretsFromDisk`); nothing that talks to a printer did.
 *
 * So every one of those calls now starts here. A masked field is filled from
 * the SAME machine, by id, in the book on disk; a field the window really holds
 * (one just typed and not yet saved) is left alone; a machine the book does not
 * have keeps its mask, which then fails as a wrong key rather than borrowing
 * another machine's.
 *
 * AND ONLY TO WHERE IT WAS SAVED TO GO. The id alone is not enough: the window
 * also chooses the address, so a script there could send a real machine's id
 * with another LAN box as its host (the read-only probe, plate and history
 * calls are open to it) and the access code went to that box. A printer's
 * secrets are filled only when the window's printerApi names the same type,
 * host and port as the book's (and the same serial for a Bambu); a plug's only
 * when every field its request is built from matches (see PLUG_KEY). Anything
 * else keeps its mask.
 *
 * A printer has no scheme field: every printer call is `http://host:port`, MQTT
 * or FTPS on that host, and the host is stripped of `:` and `/` before use, so
 * a scheme written into the host is simply a different host here.
 */
const Plug = require('../smart-plug.js');

const FIELDS = [['printerApi', 'apiKey'], ['printerApi', 'accessCode'], ['smartPlug', 'token'], ['smartPlug', 'password']];

const text = (v) => (v == null ? '' : String(v).trim());
const hostKey = (v) => text(v).toLowerCase().replace(/\/+$/, '');
const portKey = (v) => { const n = Number(text(v)); return Number.isFinite(n) && n > 0 ? n : 0; };

/** Is the window's connection the one the secret was saved for? */
const SAME = {
  printerApi(win, disk) {
    if (!win || !disk) return false;
    const type = text(disk.type).toLowerCase();
    const host = hostKey(disk.host);
    if (!type || !host) return false;
    if (text(win.type).toLowerCase() !== type || hostKey(win.host) !== host) return false;
    if (portKey(win.port) !== portKey(disk.port)) return false;
    if (type === 'bambu' && text(win.serial).toUpperCase() !== text(disk.serial).toUpperCase()) return false;
    return true;
  },
  smartPlug(win, disk) {
    const a = plugKey(win);
    return a !== null && a === plugKey(disk);
  },
};

/**
 * Everything lib/smart-plug.js `request` builds a plug's request from, except
 * the secrets themselves — read through its own `config`, so the two cannot
 * disagree about what a field means:
 *
 *   every kind     type, and the base URL (scheme, host, port, path) the
 *                  request is appended to; scheme and host compared without
 *                  case, the rest exactly
 *   homeassistant  entity — the token reads or switches whatever it names
 *   tasmota        user — sent beside the password
 *   shelly, shelly-rpc  nothing more (relay 0 is fixed)
 *
 * null when the plug is unusable (unknown kind, no host, an address that is
 * not a URL), which never matches anything.
 */
const PLUG_EXTRA = { homeassistant: ['entity'], tasmota: ['user'], shelly: [], 'shelly-rpc': [] };
function plugKey(plug) {
  if (!plug || typeof plug !== 'object') return null;
  const c = Plug.config({ smartPlug: plug });
  if (!c || !PLUG_EXTRA[c.type]) return null;
  let u;
  try { u = new URL(c.base); } catch (_) { return null; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (u.username || u.password) return null;
  const base = u.protocol + '//' + u.host + u.pathname.replace(/\/+$/, '') + u.search + u.hash;
  return JSON.stringify([c.type, base, ...PLUG_EXTRA[c.type].map((f) => c[f])]);
}

function fillMachineSecrets(machine, diskMachines, isMasked) {
  if (!machine || typeof machine !== 'object') return machine;
  if (!FIELDS.some(([g, f]) => isMasked(machine[g] && machine[g][f]))) return machine;
  const disk = (Array.isArray(diskMachines) ? diskMachines : []).find((m) => m && m.id && m.id === machine.id);
  if (!disk) return machine;
  let next = machine;
  for (const [g, f] of FIELDS) {
    if (!SAME[g](machine[g], disk[g])) continue;   // another address: keep the mask
    const stored = disk[g] && disk[g][f];
    if (isMasked(next[g] && next[g][f]) && stored && !isMasked(stored)) {
      next = { ...next, [g]: { ...(next[g] || {}), [f]: stored } };
    }
  }
  return next;
}

/**
 * The reader main.js uses: the book's machines, decrypted, read at most once
 * every `ttlMs` — the poll asks for every machine every thirty seconds, and a
 * decrypt of the whole book per machine per poll is not free. A save (which is
 * when a credential changes) clears it.
 */
function createMachineSecrets({ readDisk, isMasked, ttlMs = 15000, now = () => Date.now() }) {
  let cache = null;
  let at = 0;
  const machines = () => {
    if (!cache || now() - at > ttlMs) {
      let book = null;
      try { book = readDisk(); } catch (_) { book = null; }
      cache = (book && Array.isArray(book.machines)) ? book.machines : [];
      at = now();
    }
    return cache;
  };
  return {
    fill: (machine) => (FIELDS.some(([g, f]) => isMasked(machine && machine[g] && machine[g][f]))
      ? fillMachineSecrets(machine, machines(), isMasked)
      : machine),  // nothing masked: the book is not read at all
    forget() { cache = null; },
  };
}

module.exports = { fillMachineSecrets, createMachineSecrets, FIELDS, SAME, plugKey };
