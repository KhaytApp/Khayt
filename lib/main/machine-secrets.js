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
 */
const FIELDS = [['printerApi', 'apiKey'], ['printerApi', 'accessCode'], ['smartPlug', 'token'], ['smartPlug', 'password']];

function fillMachineSecrets(machine, diskMachines, isMasked) {
  if (!machine || typeof machine !== 'object') return machine;
  if (!FIELDS.some(([g, f]) => isMasked(machine[g] && machine[g][f]))) return machine;
  const disk = (Array.isArray(diskMachines) ? diskMachines : []).find((m) => m && m.id && m.id === machine.id);
  if (!disk) return machine;
  let next = machine;
  for (const [g, f] of FIELDS) {
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

module.exports = { fillMachineSecrets, createMachineSecrets, FIELDS };
