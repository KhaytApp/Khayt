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

/**
 * Samples per folder, folders per request. Enough to read, little to send.
 *
 * `looseNames` / `looseNamesPerScan`: the loose files at the TOP of a linked
 * folder (no sub-folder of their own) are sent as names only, at most 300 to
 * a request and 3,000 in one scan; `looseNameLength` clips each name.
 */
const LIMITS = {
  samples: 5, subfolders: 30, folders: 150, nameLength: 60,
  looseNames: 300, looseNamesPerScan: 3000, looseNameLength: 120,
  // "Check pictures": at most 2 images a request (the candidate photo and the
  // print's own preview), at most 40 checks a scan (its own budget, apart from
  // the 40 picture downloads a pass), each image at most 512 px on its long
  // side, from a source file of at most 8 MB.
  pictureImages: 2, pictureChecksPerScan: 40, picturePixels: 512, pictureSourceBytes: 8 * 1024 * 1024,
};

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
  // Something to read: `..`, `-` or `***` names no print, and a group path
  // segment of dots is one nobody should be handed.
  return /[\p{L}\p{N}]/u.test(s) ? s : '';
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

// ── Loose files: the models at the top of a linked folder ───────────────────
//
// WHY: the shop's Drive had ~2,150 models dropped straight into its top folder
// by a copy job (Oct 2026). The Mac groups them by name first, offline
// (`LooseSort.swift`); what it cannot read is a kit whose parts have generic
// names — `TMNT Van 3MF For Bambu Printers.3mf` followed by `Plate 10 - Dark
// Gray.stl … Plate 1 - Yellow.stl`. The copy job dropped a kit's files one
// after another, so the names are sent IN THAT ORDER, numbered, and the
// assistant answers with prints: a name and the numbers of their files.
//
// WHAT IS SENT: the file NAMES, in the order they were copied in. Never a
// path above the linked folder, never a file, never a picture, never a date.

const LOOSE_SCHEMA = {
  type: 'object',
  required: ['prints'],
  properties: {
    prints: {
      type: 'array',
      description: 'One entry per print made of TWO or more of the files. Leave out files that stand alone.',
      items: {
        type: 'object',
        required: ['name', 'members'],
        properties: {
          name: {
            type: 'string',
            description: 'A short clean display name for the print (no file formats, printer names, colours or part words).',
          },
          members: {
            type: 'array',
            description: 'The numbers of the print\'s files, exactly as given.',
            items: { type: 'integer' },
          },
        },
      },
    },
  },
};

function buildLooseSystem() {
  return [
    'You group the model files of a 3D-print shop. You see file NAMES only, numbered in the order they were copied into one folder.',
    'A copy job dropped each kit\'s files one after another, so neighbours usually belong together.',
    'Group the files into prints — one independent thing a customer would order, with all its parts, colours, sizes and file formats (STL and 3MF of the same model, a ".u1" printer variant, a "(1)" copy).',
    'A file named only for a part or a colour ("Plate 3 - Yellow", "KA KEY A", "Charcoal Black 2", "Peg") belongs to the named kit file next to it ("TMNT Van 3MF For Bambu Printers", "3MF - Titan Fighter").',
    'Prefixes like "obj_12_" or "Fig_" and hash names say nothing. Different sizes or versions of one kit with their own names ("v4-AA", "v4-AAA") are separate prints.',
    'Picture files (.jpg, .png) may be listed with the print they show; a picture alone is not a print.',
    'Only list prints with two or more files; leave single files out. Never put a file in two prints.',
    'Answer with the tool, using the numbers exactly as given.',
  ].join('\n');
}

/**
 * The loose sort's tool. Part of the `library` feature (the same switch and
 * the same disclosure row), so not a task of its own in ai-tools.js — but its
 * own tool name and framing, because its answer is shaped differently.
 */
function looseTool() {
  return {
    maxTokens: 16000,
    tool: {
      name: 'group_loose_model_files',
      description: 'Group the loose model files at the top of a 3D-print shop\'s library folder into prints, naming each print and listing the numbers of its files.',
      input_schema: LOOSE_SCHEMA,
    },
  };
}

/** A loose file's name as it may be sent: its own name only, one line. */
function looseName(raw) {
  const s = String(raw == null ? '' : raw);
  return clip(s.split(/[\\/]/).pop(), LIMITS.looseNameLength);
}

/**
 * The prompt for one batch of loose file names, in copy order.
 * @param {string[]} names at most LIMITS.looseNames are sent
 */
function buildLooseRequest(names) {
  const lines = ['Files (number | name), in the order they were copied into the folder:'];
  (names || []).slice(0, LIMITS.looseNames).forEach((n, i) => {
    lines.push(`${i} | ${looseName(n)}`);
  });
  return lines.join('\n');
}

/**
 * The model's prints, kept only where they can be believed: a name with
 * something to read and no path in it, and two or more members that are each
 * a number that was sent and in no other print. A row that fails any of that
 * is dropped whole — a print with one wrong member is not trusted for the rest.
 *
 * @param {object} draft the tool input the provider returned
 * @param {number} count how many names were sent
 * @returns {{prints: Array<{name: string, members: number[]}>, dropped: number}}
 */
function readLooseAnswer(draft, count) {
  const n = Math.max(0, Math.min(+count || 0, LIMITS.looseNames));
  const rows = (draft && Array.isArray(draft.prints)) ? draft.prints : [];
  const used = new Set();
  const prints = [];
  let dropped = 0;
  for (const row of rows) {
    const raw = row && typeof row.name === 'string' ? row.name : '';
    const members = row && Array.isArray(row.members) ? row.members : null;
    const name = /[\\/]|\.\./.test(raw) ? '' : cleanName(raw);
    const ok = name && members && members.length >= 2
      && members.every((m) => Number.isInteger(m) && m >= 0 && m < n && !used.has(m))
      && new Set(members).size === members.length;
    if (!ok) { dropped += 1; continue; }
    members.forEach((m) => used.add(m));
    prints.push({ name, members: members.slice() });
  }
  return { prints, dropped };
}

// ── Check pictures: is this photo of this print? ────────────────────────────
//
// WHY: the shop asked for the RIGHT picture on each print (Oct 2026). A name
// says a photo is "probably" a print's; this asks the assistant to LOOK. Its
// own switch ("Check pictures"), off until the shop turns it on.
//
// WHAT IS SENT, per check: the print's name; the candidate photo, drawn into a
// new JPEG of at most 512 px (no metadata survives that); and, when there is
// one, the print's own preview — the picture embedded in a 3MF on this Mac, or
// the one this app drew of a model on this Mac. Never a model file. A model
// kept only in the cloud is never downloaded to make a preview.
//
// WHAT COMES BACK: yes, no or unsure. Anything else is "unsure".

const VERDICTS = ['yes', 'no', 'unsure'];

const PICTURE_SCHEMA = {
  type: 'object',
  required: ['verdict'],
  properties: {
    verdict: {
      type: 'string',
      enum: VERDICTS,
      description: 'yes: the photo shows this very print. no: it shows something else. unsure: cannot tell.',
    },
  },
};

function buildPictureSystem() {
  return [
    'You check pictures for a 3D-print shop\'s model library.',
    'You are given a print\'s name, a candidate photo and, sometimes, the print\'s own preview image rendered from its model file.',
    'Say "yes" only if the photo shows this same print (the same object, not merely the same subject: a bust is not a figure, two different Luffy prints are different).',
    'Say "no" if it shows something else, and "unsure" if you cannot tell.',
    'Answer with the tool.',
  ].join('\n');
}

/**
 * The prompt for one check. The images travel beside it, at most
 * LIMITS.pictureImages of them: the photo first, then the preview if any.
 */
function buildPictureRequest(printName, hasReference) {
  const name = clip(printName, LIMITS.nameLength) || 'unnamed';
  return hasReference
    ? `Print: ${name}\nImage 1 is the candidate photo. Image 2 is the print's own preview. Do they show the same print?`
    : `Print: ${name}\nThe image is a candidate photo. Does it look like a 3D print called "${name}"?`;
}

/** The images of one check, capped: never more than LIMITS.pictureImages. */
function pictureImages(photo, reference) {
  return [photo, reference].filter((x) => typeof x === 'string' && x.length > 0)
    .slice(0, LIMITS.pictureImages)
    .map((data) => ({ data, mediaType: 'image/jpeg' }));
}

/** The verdict, or "unsure" for anything that is not one. */
function readPictureAnswer(draft) {
  const v = draft && typeof draft.verdict === 'string' ? draft.verdict.trim().toLowerCase() : '';
  return VERDICTS.includes(v) ? v : 'unsure';
}

/**
 * What a verdict does — the one rule the Mac follows.
 *   yes + preview  → attach (unless the shop set or removed a photo there)
 *   yes, no preview → offer, ticked
 *   no             → drop, and remember it was turned down
 *   unsure / error → offer, unticked
 */
function pictureOutcome(verdict, hasReference) {
  if (verdict === 'yes') return hasReference ? 'attach' : 'ticked';
  if (verdict === 'no') return 'rejected';
  return 'unticked';
}

const api = {
  ROLES, LIMITS, LIBRARY_SCHEMA, buildLibrarySystem, buildLibraryRequest, cleanName, readLibraryAnswer,
  LOOSE_SCHEMA, buildLooseSystem, buildLooseRequest, readLooseAnswer, looseName, looseTool,
  VERDICTS, PICTURE_SCHEMA, buildPictureSystem, buildPictureRequest, pictureImages, readPictureAnswer,
  pictureOutcome,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytAiLibrary = api;

})();
