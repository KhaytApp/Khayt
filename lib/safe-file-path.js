'use strict';
/**
 * Is this a real file, of a kind we expect, inside one of these folders?
 *
 * Main process only. The folder checks in front of hub:open-path and
 * hub:copy-file-to-vault compared the path as the window SPELLED it. A symlink
 * spells one place and is another: `~/Downloads/model.stl` can point at
 * `~/.ssh/id_ed25519`, and `~/Downloads/report.pdf` at an app bundle. So the
 * path is resolved to where it really is (fs.realpathSync) and THAT is checked —
 * against the folders' own real paths too, because on macOS the temp folder is
 * /var/… and really /private/var/….
 *
 * The extension is the real file's, for the same reason, and must be one the
 * caller lists: opening or copying a file the app never writes or reads is not
 * something the window has any business asking for.
 *
 * Returns { ok: true, real } or { ok: false, error }.
 */
function realFileWithin(filePath, { dirs = null, exts, fs, path }) {
  const raw = String(filePath || '');
  if (!raw) return { ok: false, error: 'No file' };
  let real;
  try { real = fs.realpathSync(path.resolve(raw)); } catch (_) { return { ok: false, error: 'File not found' }; }
  let stat;
  try { stat = fs.statSync(real); } catch (_) { return { ok: false, error: 'File not found' }; }
  if (!stat.isFile()) return { ok: false, error: 'Not a file' };
  const ext = path.extname(real).slice(1).toLowerCase();
  if (!exts.includes(ext)) return { ok: false, error: `Files of type .${ext || '?'} are not allowed here` };
  if (dirs) {
    const inside = dirs.some((d) => {
      let root;
      try { root = fs.realpathSync(path.resolve(String(d))); } catch (_) { return false; }
      return real.startsWith(root + path.sep);
    });
    if (!inside) return { ok: false, error: 'Source path is outside allowed directories' };
  }
  return { ok: true, real };
}

/** What the app writes and then opens for the shop: reports, invoices, exports. */
const OPENABLE_EXTS = Object.freeze(['pdf', 'html', 'htm', 'csv', 'txt', 'png', 'jpg', 'jpeg', 'webp']);

/** What a job's file vault holds: print files, their archives, and QC photos. */
const VAULT_EXTS = Object.freeze(['stl', '3mf', 'obj', 'step', 'stp', 'gcode', 'gco', 'zip',
  'jpg', 'jpeg', 'png', 'webp', 'heic', 'pdf']);

/**
 * What a shop attaches and later opens from inside the app: an order's files, a
 * product's documents, a job's vault, an expense's receipt. Documents, pictures
 * and print files — every one opens in a viewer, a slicer or an office app.
 *
 * Never anything the OS would RUN when "opened": .exe/.msi/.bat/.cmd/.ps1/.vbs/
 * .js/.hta/.scr/.lnk/.url/.jar/.sh/.command/.app/.desktop/.AppImage and kin.
 * The attach pickers offer "All Files", so such a file can sit in these folders —
 * and the name on disk comes from a book that syncs between devices. An allow
 * list is the only shape that stays safe as operating systems add launchers.
 * (`zip` is here because the vault takes archives of print files; opening one
 * shows its contents, it does not run them.)
 */
const ATTACHMENT_EXTS = Object.freeze([
  // documents
  'pdf', 'txt', 'md', 'csv', 'rtf', 'doc', 'docx', 'xls', 'xlsx', 'odt', 'ods',
  // pictures
  'png', 'jpg', 'jpeg', 'webp', 'gif', 'heic', 'bmp', 'tif', 'tiff',
  // print files and models
  'stl', '3mf', 'obj', 'step', 'stp', 'gcode', 'gco', 'nc', 'zip',
]);

/** What an expense's receipt may be: the receipt pickers' own filter. */
const RECEIPT_EXTS = Object.freeze(['pdf', 'png', 'jpg', 'jpeg']);

module.exports = { realFileWithin, OPENABLE_EXTS, VAULT_EXTS, ATTACHMENT_EXTS, RECEIPT_EXTS };
