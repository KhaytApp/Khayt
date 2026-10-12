'use strict';
(function () {
/**
 * AI library sorting — the shop's assistant reads a linked folder's TREE OF
 * NAMES and says what each folder is: a collection, a print, a part of a
 * print, a format folder, or pictures.
 *
 * WHY: a shop linked a Google Drive of ~10,000 models (Oct 2026) and the
 * library filed them under Patreon tiers and month folders. The native Mac app
 * sorts every folder with a heuristic first (`PrintSort.swift`), offline and
 * always; this is the optional second opinion for the folders a list of words
 * cannot read — `Cube_Pro_Organizer_Hobby_-_KS/02_Hobby Pledge/01_Cubes` is one
 * product, `2026 World Cup/{Key Chain, Can Opener}` is two.
 *
 * WHAT IS SENT: folder paths, how many models each holds, its sub-folder
 * names and a few file NAMES. Never a file, never a picture, never anything of
 * a customer's — `ai-privacy.js` says so to the shop in those words.
 *
 * WHAT COMES BACK IS NOT TRUSTED: `readAnswer` keeps only paths that were
 * sent and roles that exist, and a print's name is cleaned to something a
 * group can be called. Anything missing falls back to the heuristic.
 *
 * Pure (no DOM, no network, no clock) so all of it is unit-testable.
 */

const ROLES = ['collection', 'print', 'part', 'format', 'assets'];

/** Samples per folder, folders per request. Enough to read, little to send. */
const LIMITS = { samples: 5, subfolders: 30, folders: 150, nameLength: 60 };

const LIBRARY_SCHEMA = {
  type: 'object',
  required: ['folders'],
  properties: {
    folders: {
      type: 'array',
      description: 'One entry per folder you were given, by its exact path.',
      items: {
        type: 'object',
        required: ['path', 'role'],
        properties: {
          path: { type: 'string', description: 'The folder path exactly as given.' },
          role: { type: 'string', enum: ROLES },
          name: {
            type: 'string',
            description: 'For a print only: a short clean display name (no file formats, tier or pack words, shop handles or site numbers).',
          },
        },
      },
    },
  },
};

function buildLibrarySystem() {
  return [
    'You sort a 3D-print shop\'s model folders. You see folder PATHS and file NAMES only.',
    'Give every folder exactly one role:',
    '- collection: holds several independent prints (a Patreon tier, a month\'s release, a pack, a bundle, a theme set, a designer\'s folder of many models).',
    '- print: one independent thing a customer would order (a figure, a helmet, a poster, an organizer), with all its files.',
    '- part: inside a print — a part, a size or a variant set of that same print (Body, Wing, 4 feet Size, Large Cuts, Concert Poster).',
    '- format: inside a print — the same parts in another file format or state (STLs, Colored 3MFs, Uncolored 3MFs, Print Files, Supported).',
    '- assets: pictures, renders, documents — no models.',
    'Rules: a folder inside a print is never a collection or a print. A folder that only repeats its parent\'s name ("Mumm Ra - Patreon" inside "Mumm-Ra") is format. Two folders in different collections with the same print name are the same print.',
    'For each print, give a short clean name a shop would recognise.',
    'Answer with the tool, one entry per folder, using each path exactly as given.',
  ].join('\n');
}

/** Text a name may safely carry into a prompt line. */
function clip(s, n) {
  const t = String(s == null ? '' : s).replace(/[\r\n\t]+/g, ' ').trim();
  return t.length > n ? t.slice(0, n) : t;
}

/**
 * The prompt for one batch of folders.
 * @param {Array<{path: string, models: number, folders?: string[], samples?: string[]}>} entries
 */
function buildLibraryRequest(entries) {
  const lines = ['Folders (path | models directly inside | sub-folders | sample files):'];
  for (const e of (entries || []).slice(0, LIMITS.folders)) {
    if (!e || typeof e.path !== 'string' || !e.path) continue;
    const subs = (e.folders || []).slice(0, LIMITS.subfolders).map((s) => clip(s, 80));
    const samples = (e.samples || []).slice(0, LIMITS.samples).map((s) => clip(s, 80));
    lines.push([clip(e.path, 400), String(Math.max(0, +e.models || 0)),
      subs.join('; ') || '-', samples.join('; ') || '-'].join(' | '));
  }
  return lines.join('\n');
}

/** A print's name as a group can hold it: one line, no path separator, ≤ 60. */
function cleanName(raw) {
  let s = String(raw == null ? '' : raw).replace(/[\u0000-\u001f\u007f]/g, ' ');
  s = s.replace(/\//g, ' - ').replace(/\s+/g, ' ').trim();
  if (s.length > LIMITS.nameLength) {
    const words = s.split(' ');
    let out = '';
    for (const w of words) {
      const next = out ? out + ' ' + w : w;
      if (next.length > LIMITS.nameLength) break;
      out = next;
    }
    s = out || s.slice(0, LIMITS.nameLength);
  }
  return s;
}

/**
 * The model's answer, kept only where it can be believed.
 *
 * @param {object} draft the tool input the provider returned
 * @param {string[]} sentPaths every path that was in the request
 * @returns {{roles: Object<string,string>, names: Object<string,string>, dropped: number}}
 */
function readLibraryAnswer(draft, sentPaths) {
  const sent = new Set(sentPaths || []);
  const roles = {};
  const names = {};
  let dropped = 0;
  const rows = (draft && Array.isArray(draft.folders)) ? draft.folders : [];
  for (const row of rows) {
    const path = row && typeof row.path === 'string' ? row.path : null;
    const role = row && typeof row.role === 'string' ? row.role.trim().toLowerCase() : null;
    if (!path || !sent.has(path) || !ROLES.includes(role) || Object.prototype.hasOwnProperty.call(roles, path)) {
      dropped += 1;
      continue;
    }
    roles[path] = role;
    if (role === 'print' && typeof row.name === 'string') {
      const name = cleanName(row.name);
      if (name) names[path] = name;
    }
  }
  return { roles, names, dropped };
}

const api = {
  ROLES, LIMITS, LIBRARY_SCHEMA, buildLibrarySystem, buildLibraryRequest, cleanName, readLibraryAnswer,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytAiLibrary = api;

})();
