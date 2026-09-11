const { app, BrowserWindow, Menu, shell, ipcMain, dialog, safeStorage, clipboard, utilityProcess } = require('electron');
const path = require('path');
const fs = require('fs');
const readline = require('readline');
const { FLAVOR, isBedReady, productName: FLAVOR_NAME } = require('./lib/flavor');

// Bed Ready is a fully independent product that shares Khayt's codebase: give it its OWN Electron
// userData dir (…/BedReady) instead of sharing Khayt's (…/khayt, which app.name still derives to).
// One-time migration copies any existing Bed Ready data across. MUST run before app is ready and before
// anything reads app.getPath('userData'), so it sits here at the very top.
// Defer to an explicit --user-data-dir (dev / e2e / CI isolation) — otherwise we'd override it and every
// test instance would collide on the single real …/BedReady dir (and its single-instance lock).
const hasExplicitUserDataDir = process.argv.some((a) => a === '--user-data-dir' || a.startsWith('--user-data-dir='));
if (isBedReady && !hasExplicitUserDataDir) {
  try {
    app.setPath('userData', require('./lib/bedready-data').migrateAndResolveUserData(app.getPath('appData')));
  } catch (e) {
    console.warn('[bedready] userData independence setup failed, using default:', e && e.message);
  }
}

// Crash/error reporting (Sentry). The DSN is publishable, so it's baked in for
// official builds. Active in PACKAGED installs by default; in dev only when
// SENTRY_DSN is set (so day-to-day development doesn't flood the project).
// PII is off and the E2E store is never sent. Init early to catch startup errors.
// Bed Ready is a separate product and does NOT report to Khayt's Sentry project;
// the SDK is also excluded from its build (see electron-builder.bedready.js).
const SENTRY_DSN = process.env.SENTRY_DSN
  || 'https://7b05dbab160d7a1825f5b2fceab06122@o4511599597977600.ingest.de.sentry.io/4511599624126544';
let sentry = null;
if (!isBedReady && SENTRY_DSN && (app.isPackaged || process.env.SENTRY_DSN)) {
  try {
    sentry = require('@sentry/electron/main');
    sentry.init({
      dsn: SENTRY_DSN,
      release: `khayt@${app.getVersion()}`,
      environment: app.isPackaged ? 'production' : 'development',
      sendDefaultPii: false,
      tracesSampleRate: 0,
      // Crash reporting is OPT-IN. Settings offers it as a checkbox that
      // defaults to off, and the app tells the user "Khayt sends nothing by
      // default" — but Sentry was initialised purely on app.isPackaged and
      // captured regardless of that choice, so stack traces left the device
      // without consent.
      //
      // The gate has to be at send time: init runs at module load, long before
      // the store is read. beforeSend fires when the event does, by which point
      // lanServerStore is populated. Fails CLOSED — if consent is unknown, such
      // as a crash during startup, the event is dropped rather than sent.
      beforeSend: (event) => (telemetryConsent().crash ? event : null),
    });
  } catch (e) { console.error('Sentry init:', e && e.message); sentry = null; }
}

// Optional portable / multi-instance data dir override. Set KHAYT_USER_DATA to
// run an isolated second instance (e.g. to test cloud sync between "devices").
// Must run before any app.getPath('userData') call.
if (process.env.KHAYT_USER_DATA) {
  try { app.setPath('userData', process.env.KHAYT_USER_DATA); } catch (e) { console.error('KHAYT_USER_DATA:', e && e.message); }
}
const crypto = require('crypto');
const QRCode = require('qrcode');
const { safeJsonParse } = require('./lib/safe-json');
const { isBlockedHost, isAllowedPrinterHost, sanitizeMailgunDomain, resolvesToBlockedHost,
        sanitizePrinterHost } = require('./lib/host-guard');
const { sendCustomSmtp } = require('./lib/custom-smtp');
const {
  mergePollSuccess, mergePollFailure, completionsToPersist, restoreCompletions, completionIsNew,
} = require('./lib/printer-poll-cache');
const sdcpClient = require('./lib/sdcp-client');
const { normalizeProgress, fileProgressPct, explainPrinterHttp } = require('./lib/printer-status');
const KhaytDuet = require('./lib/duet');
const KhaytRepetier = require('./lib/repetier');
const printerCommands = require('./lib/printer-commands');
const excludeObject = require('./lib/exclude-object');
const { normalizeStoreSnapshot, STORE_VERSION } = require('./lib/store-validate');
const upgradeBackup = require('./lib/upgrade-backup');
const { createStoreIo, MAX_STORE_BYTES } = require('./lib/store-io');
const { parseGcodeText } = require('./lib/gcode-parse');
const moonrakerHistory = require('./lib/moonraker-history');
// Reading a Klipper printer's answer — shared with the Mac app, which polls the
// same machines. Two readings of the same JSON would be two opinions about
// whether a shop's print is nearly done.
const moonraker = require('./lib/moonraker');
const filamentSensors = require('./lib/filament-sensors');
/**
 * Which filament sensors each Klipper machine publishes, by machine id.
 *
 * Discovered once per machine per run: Klipper's object list changes only
 * across a firmware restart, and asking on every poll would add a request to
 * the slowest link in the app. An empty array means "asked, has none" and is
 * not the same as `undefined`, which means "have not asked yet".
 */
const moonrakerSensors = new Map();
/**
 * The slicer's estimate for the file each Moonraker machine is printing.
 *
 * `machine.id → { filename, meta }`. Moonraker's per-file metadata is static,
 * so this is asked once when the filename changes and held while that file
 * prints — not every poll, which would be a request per tick for a number that
 * cannot move. A failed lookup is remembered as a null `meta` for that
 * filename, so a file the slicer left no estimate in is not re-asked forever.
 */
const moonrakerFileMeta = new Map();
const octoprint = require('./lib/octoprint');
const prusalink = require('./lib/prusalink');
const contextMenu = require('./lib/main/context-menu');
const { createSilhouette } = require('./lib/gcode-geometry');
const { intake: intakeModel } = require('./lib/model-intake');
const { extractActuals } = require('./lib/printer-actuals');
const { contentHash: modelContentHash } = require('./lib/model-identity');
const { extract: extractPrintThumb } = require('./lib/thumbnail-extract');
const bambu = require('./lib/bambu');
const { bambuFtpUpload } = require('./lib/bambu-ftp');
const { sendSms } = require('./lib/sms');
const cloudClient = require('./lib/cloud-client');
const { summarizeBranch, totalBranches } = require('./lib/branch-summary');
const aiTools = require('./lib/ai-tools');
const aiPrivacy = require('./lib/ai-privacy');
const makerrunLibrary = require('./lib/makerrun-library');
const calibProfile = require('./lib/calibration-profile');
const orcaFila = require('./lib/orca-filament-install');
// Login-CSRF guard for the bedready:// sign-in handoff: only honour a deep link the app itself just
// initiated (user clicked "Connect"). Armed by hub:bedready-open-signin, checked in handleBedreadyLink.
let bedreadyLinkArmedAt = 0;
const BEDREADY_LINK_ARM_WINDOW_MS = 10 * 60 * 1000; // 10 min to finish signing in on the website
// Per-handshake nonce: minted when the user opens the sign-in page (passed as ?state=), echoed back in
// the bedready:// link. Binds the returned link to THIS app's own sign-in click — a drive-by link from a
// different tab can't be consumed even inside the arm window. '' before any sign-in attempt.
let bedreadyLinkNonce = '';
const { registerZatcaCrypto } = require('./lib/zatca-crypto');
const { wrapHubIpc } = require('./lib/ipc-guard');
const { sanitizeHtmlForFile, redactStatusHtmlClientRow } = require('./lib/status-html');
const { hashPin: hashPinSalted, verifyPin, isManagedHash, needsUpgrade } = require('./lib/pin-hash');

// FLAVOR / isBedReady / FLAVOR_NAME are resolved at the top of this file (needed
// before the Sentry block). 'bedready' = the standalone maker app (no business
// surfaces); anything else = the full Khayt business app. They drive the entry
// HTML, window branding, and which business-only main-process code gets wired up.
// Entry document, relative to renderer/. Used BOTH for loadFile and the navigation
// lock below — they must agree, or in-app reloads of the Bed Ready page get blocked.
const ENTRY_HTML = isBedReady ? 'bedready.html' : 'index.html';

let mainWindow;
let lanServerStore = {};

/** Only the main app window may invoke privileged hub:* IPC (blocks stray webContents). */
function isTrustedRenderer(event) {
  if (!mainWindow || mainWindow.isDestroyed()) return false;
  return !!(event && event.sender === mainWindow.webContents);
}

wrapHubIpc(ipcMain, isTrustedRenderer);

// Renderer → main error forwarding for Sentry (the renderer is non-bundled with a
// strict CSP, so it can't run the SDK directly). No-op unless Sentry is active.
ipcMain.handle('hub:report-error', (_e, info = {}) => {
  if (!sentry) return false;
  // Same opt-in gate as beforeSend. Checked here too so a renderer error is
  // dropped before an Error object is even constructed from it.
  if (!telemetryConsent().crash) return false;
  try {
    const err = new Error(String((info && info.message) || 'renderer error').slice(0, 500));
    if (info && info.stack) err.stack = String(info.stack).slice(0, 8000);
    sentry.captureException(err, { tags: { source: 'renderer' }, extra: { url: info && info.url, line: info && info.line } });
  } catch { /* ignore */ }
  return true;
});
const {
  encryptStoreField,
  decryptStoreField,
  encryptForDisk,
  hasPlaintextSecrets,
  maskStoreSecretsForRenderer,
  mergeStoreSecretsFromDisk,
  writeStoreToDisk,
  atomicWriteStore,
  recoverStoreRaw,
  syncLanServerStoreFromDisk,
  migrateLanApiSecrets,
  ensureLanIntakeToken,
  ensureLanIntakePin,
  ensureLanCalendarToken,
  isEncryptionAvailable,
  persistLanStoreUpdate,
  updateStoreOnDisk,
  resolveStoreSecret,
  isStoreSecretMasked,
  readStoreDecryptedFromDisk,
  dataFilePath,
} = createStoreIo({
  app,
  fs,
  safeStorage,
  safeJsonParse,
  crypto,
  onStoreUpdated(data) { lanServerStore = data; },
  // Read INSIDE the write chain, so a read-modify-write always sees the result of
  // every write queued ahead of it. See updateStoreOnDisk.
  getStore: () => lanServerStore,
});

// ZATCA e-invoicing is a business-only surface — skip its IPC on the Bed Ready flavor.
if (!isBedReady) {
  registerZatcaCrypto({ app, fs, crypto, ipcMain, encryptStoreField, decryptStoreField });
}

function timingSafeEqualHex(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== 64 || b.length !== 64) return false;
  try {
    return crypto.timingSafeEqual(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8'));
  } catch {
    return false;
  }
}

function appIconPath() {
  // Prefer a flavor-specific icon, else fall back to the shared Khayt preview so
  // the window and dock always have one. This was marked as outstanding Bed
  // Ready branding work long after assets/bedready-preview.png shipped — the
  // fallback has not fired for Bed Ready in a while, and the note only made
  // finished work look unfinished.
  const candidates = [];
  if (isBedReady) candidates.push(path.join(__dirname, 'assets', 'bedready-preview.png'));
  candidates.push(path.join(__dirname, 'assets', 'icon_preview.png'));
  for (const png of candidates) {
    if (fs.existsSync(png)) return png;
  }
  return undefined;
}

function applyDockIcon() {
  if (process.platform !== 'darwin' || !app.dock) return;
  const icon = appIconPath();
  if (icon) app.dock.setIcon(icon);
}

/* ---------- On-disk locations under app userData ---------- */
function ensureDir(name) {
  const dir = path.join(app.getPath('userData'), name);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  return dir;
}
const productsDir    = () => ensureDir('products');
const productDocsDir = () => ensureDir('product-docs');
const orderPhotosDir = () => ensureDir('order-photos');
const orderFilesDir  = () => ensureDir('order-files');
const invoicesDir    = () => ensureDir('invoices');
const backupsDir     = () => ensureDir('backups');
// Receipts photographed on the phone. Under userData like every other attachment
// directory, which also means hub:open-path will open them — its allow-list
// covers userData, and a receipt written anywhere else would be unopenable.
const receiptsDir    = () => ensureDir('receipts');

const { registerPrinterDiscovery } = require('./lib/main/printer-discovery.js');
const { registerWebcamProxy } = require('./lib/main/webcam-proxy.js');
const { registerPaymentLinks } = require('./lib/main/payment-links.js');
const { registerUpdater } = require('./lib/updater');
const { setupAutoUpdater } = registerUpdater({
  app,
  fs,
  ipcMain,
  BrowserWindow,
  encryptForDisk,
  dataFilePath,
  backupsDir,
  // The pre-install flush must go through the SAME writer as every other save.
  // It used to hand-roll one, and the hand-rolled one had no fsync, no .prev
  // generation, a temp name recovery treats as a candidate, and no place in the
  // write chain — at the one moment the app is about to be replaced.
  writeStoreToDisk,
});

/* ---------- Shared helpers ---------- */
function decodeDataUrl(dataUrl) {
  const m = /^data:(image\/(jpeg|jpg|png|webp));base64,(.+)$/.exec(String(dataUrl || ''));
  if (!m) throw new Error('Unsupported image format');
  return { ext: m[2] === 'jpg' ? 'jpg' : m[2], buffer: Buffer.from(m[3], 'base64') };
}
async function imageToDataUrl(fullPath) {
  if (!fs.existsSync(fullPath)) return null;
  const buf = await fs.promises.readFile(fullPath);
  const ext = path.extname(fullPath).slice(1).toLowerCase() || 'jpeg';
  const mime = ext === 'jpg' ? 'jpeg' : ext;
  return `data:image/${mime};base64,${buf.toString('base64')}`;
}

/* ============================================================
   IPC handlers
   ============================================================ */

// --- QR / version (existing) ---
const PENDING_WIPE_FLAG = '.pending-full-wipe';

function completePendingFullWipe() {
  const userData = app.getPath('userData');
  const flag = path.join(userData, PENDING_WIPE_FLAG);
  if (!fs.existsSync(flag)) return false;
  try {
    fs.unlinkSync(flag);
    for (const entry of fs.readdirSync(userData)) {
      fs.rmSync(path.join(userData, entry), { recursive: true, force: true });
    }
    console.log('Khayt: full data wipe completed on restart');
    return true;
  } catch (e) {
    console.error('completePendingFullWipe failed:', e);
    return false;
  }
}

ipcMain.handle('hub:clipboard-write', async (_e, text) => {
  const s = String(text ?? '').slice(0, 500_000);
  clipboard.writeText(s);
  return { ok: true };
});

ipcMain.handle('hub:save-text-file', async (_e, { content, defaultName, filters } = {}) => {
  const win = BrowserWindow.getFocusedWindow();
  const okFilters = Array.isArray(filters) && filters.length
    ? filters.filter((f) => f && f.name && Array.isArray(f.extensions))
    : [{ name: 'Text', extensions: ['txt'] }];
  const { filePath, canceled } = await dialog.showSaveDialog(win || undefined, {
    defaultPath: defaultName || 'khayt-recovery.txt',
    filters: okFilters.length ? okFilters : [{ name: 'Text', extensions: ['txt'] }],
  });
  if (canceled || !filePath) return { ok: false, canceled: true };
  await fs.promises.writeFile(filePath, String(content || ''), 'utf8');
  return { ok: true, filePath };
});

// Write a set of CSV files (one-click "Export all data") into a chosen folder.
ipcMain.handle('hub:export-csv-bundle', async (_e, files) => {
  if (!Array.isArray(files) || files.length === 0) return { ok: false, error: 'nothing-to-export' };
  const win = BrowserWindow.getFocusedWindow();
  const { filePaths, canceled } = await dialog.showOpenDialog(win || undefined, {
    title: 'Choose a folder for the CSV export',
    properties: ['openDirectory', 'createDirectory'],
  });
  if (canceled || !filePaths || !filePaths[0]) return { ok: false, canceled: true };
  const stamp = new Date().toISOString().slice(0, 10);
  const dir = path.join(filePaths[0], `khayt-export-${stamp}`);
  await fs.promises.mkdir(dir, { recursive: true });
  let written = 0;
  for (const f of files) {
    if (!f || typeof f.name !== 'string') continue;
    // Guard against path traversal in the supplied file name.
    const safe = path.basename(f.name);
    await fs.promises.writeFile(path.join(dir, safe), String(f.content || ''), 'utf8');
    written++;
  }
  return { ok: true, dir, count: written };
});

ipcMain.handle('hub:request-full-wipe', async (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const { response } = await dialog.showMessageBox(win || undefined, {
    type: 'warning',
    buttons: ['Cancel', 'Delete everything'],
    defaultId: 0,
    cancelId: 0,
    noLink: true,
    title: 'Full wipe',
    message: 'Delete ALL Khayt data on this computer?',
    detail: 'Store, photos, invoices, backups, and keys will be removed. The app will restart empty. This cannot be undone.',
  });
  if (response !== 1) return { ok: false, canceled: true };
  const flag = path.join(app.getPath('userData'), PENDING_WIPE_FLAG);
  fs.writeFileSync(flag, new Date().toISOString());
  app.relaunch();
  app.exit(0);
  return { ok: true };
});

ipcMain.handle('hub:generate-qr', async (_e, text, options = {}) => {
  const svgStr = await QRCode.toString(String(text || '').slice(0, 4000), {
    type: 'svg',
    errorCorrectionLevel: options.errorCorrectionLevel || 'M',
    margin: options.margin ?? 1,
    width: options.width || 180,
  });
  // When caller wants a data URL (for <img src=...>) return base64-encoded SVG
  if (options.dataUrl) {
    return 'data:image/svg+xml;base64,' + Buffer.from(svgStr).toString('base64');
  }
  return svgStr;
});
ipcMain.handle('hub:app-version', async () => app.getVersion());

// --- Live exchange rates (free, no-key FX API) ---
// Renderer CSP forbids outbound fetch, so the main process pulls rates on demand.
// open.er-api.com returns "1 BASE = rates[X] FOREIGN"; we store base-units-per-1
// -foreign (= 1/rate) to match settings.exchangeRates' convention.
ipcMain.handle('hub:fetch-exchange-rates', async (_e, base) => {
  const code = String(base || 'SAR').toUpperCase().replace(/[^A-Z]/g, '').slice(0, 3);
  if (code.length !== 3) return { ok: false, error: 'Invalid base currency' };
  try {
    const res = await fetch(`https://open.er-api.com/v6/latest/${code}`, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(10000),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok || body.result !== 'success' || !body.rates || typeof body.rates !== 'object') {
      return { ok: false, error: body['error-type'] || `HTTP ${res.status}` };
    }
    const rates = {};
    for (const [cur, r] of Object.entries(body.rates)) {
      const n = +r;
      if (cur !== code && Number.isFinite(n) && n > 0) rates[cur] = 1 / n;
    }
    return { ok: true, base: code, rates, updatedAt: body.time_last_update_utc || null };
  } catch (e) { return { ok: false, error: String(e.message || e) }; }
});

// --- Product images (existing) ---
ipcMain.handle('hub:save-product-image', async (_e, productId, dataUrl, imageId) => {
  const { ext, buffer } = decodeDataUrl(dataUrl);
  const safeId = path.basename(String(productId || '')).replace(/[^a-zA-Z0-9_-]/g, '_');
  /* ONE FILE PER IMAGE, NOT ONE PER PRODUCT.
   *
   * This built the name from the product id alone, which was right while a
   * product had a single picture and silently wrong the moment it could have
   * several: every photo wrote to `PROD-xyz.jpeg`, so the last one overwrote
   * all the others and every image record pointed at the same file. The editor
   * looked correct — three thumbnails, three rows in the store — and on disk
   * there was one picture. Deleting any one of them would have unlinked the
   * file the other two were still using.
   *
   * Existing single-image products keep their original name, so nothing has to
   * be migrated: they are referenced by the path already stored against them.
   */
  const safeImg = path.basename(String(imageId || '')).replace(/[^a-zA-Z0-9_-]/g, '_');
  const filename = safeImg ? `${safeId}-${safeImg}.${ext}` : `${safeId}.${ext}`;
  await fs.promises.writeFile(path.join(productsDir(), filename), buffer);
  return filename;
});
ipcMain.handle('hub:load-product-image', async (_e, filename) =>
  imageToDataUrl(path.join(productsDir(), path.basename(filename || ''))));
ipcMain.handle('hub:delete-product-image', async (_e, filename) => {
  const full = path.join(productsDir(), path.basename(filename || ''));
  if (filename && fs.existsSync(full)) await fs.promises.unlink(full);
  return true;
});
ipcMain.handle('hub:reveal-products-folder', async () => shell.openPath(productsDir()));

// --- Order print photos (new in 1.3) ---
/* ── Fitting an image under an upload limit ─────────────────────────────────
 *
 * Storefronts cap what they accept — Medusa at 1 MB an image — and a rejected
 * upload is found at the END of making a listing, after the description is
 * written and the price is set. Khayt holds the photos, so it can answer before
 * anyone finds out the hard way.
 *
 * lib/image-fit.js decides; this encodes. Electron's own nativeImage does the
 * work, so no image library joins the build for this — which matters, because a
 * native dependency is a thing that breaks on one platform at packaging time and
 * is discovered by a user.
 */
/**
 * Does this image actually use its alpha channel?
 *
 * Scans until it finds a pixel that is not fully opaque, so a transparent image
 * usually answers in the first few rows and an opaque one costs a single pass
 * over the bitmap — a few milliseconds, once, against five PNG encodes of a
 * multi-megapixel image if we guess wrong.
 *
 * Sampling would be cheaper and is not safe here: a logo with one small cut-out
 * corner is exactly the image whose transparency matters most, and exactly the
 * one a sparse sample would miss.
 */
function hasTransparency(img) {
  try {
    /* Checked on a DOWNSCALED copy, never the original.
     *
     * toBitmap() allocates width × height × 4 in the JS heap, so a legitimate
     * 100-megapixel phone photo would be a 400 MB allocation just to answer a
     * yes/no question. Any transparency that matters to a listing survives a
     * reduction to 1000px; a single stray transparent pixel does not, and a
     * single stray transparent pixel is not what "does this image use alpha"
     * means. */
    const s = img.getSize();
    const small = Math.max(s.width, s.height) > 1000
      ? img.resize(s.width >= s.height ? { width: 1000 } : { height: 1000 })
      : img;
    const bmp = small.toBitmap(); // BGRA
    for (let i = 3; i < bmp.length; i += 4) if (bmp[i] !== 255) return true;
    return false;
  } catch (_) {
    // Unreadable bitmap: assume transparency rather than flatten something we
    // could not inspect. The cost is a worse-looking image; the alternative is
    // silently destroying one.
    return true;
  }
}

function fitImageBuffer(buf, opts) {
  const Fit = require('./lib/image-fit.js');
  const { nativeImage } = require('electron');
  const o = opts || {};
  const budget = Math.max(1024, Number(o.budgetBytes) || 1024 * 1024);

  const img = nativeImage.createFromBuffer(buf);
  if (img.isEmpty()) return { ok: false, reason: 'unreadable', bytes: buf.length };
  const size = img.getSize();

  /* ── A PIXEL CAP, NOT ONLY A BYTE CAP ──────────────────────────────────────
   *
   * The caller caps what it will accept at 64 MB of ENCODED image, which sounds
   * like a limit and is not one: compressed formats decide how much memory they
   * become. Measured on this machine, a solid-colour 4000×4000 PNG is 55 KB
   * encoded and 61 MB decoded — 1,135 decoded bytes per encoded byte — so 64 MB
   * of that shape asks for roughly 71 GB.
   *
   * This runs in the MAIN process, so exhausting it takes the whole app down
   * rather than a tab. `getSize()` answers before any pixels are allocated,
   * which is what makes refusing cheap.
   *
   * 60 megapixels is past any real camera a shop would photograph a product with
   * and nowhere near the shapes that make this a weapon.
   */
  const megapixels = (size.width * size.height) / 1e6;
  if (!Number.isFinite(megapixels) || megapixels > 60) {
    return { ok: false, reason: 'too-many-pixels', bytes: buf.length,
      originalWidth: size.width, originalHeight: size.height };
  }
  const originalFormat = buf.length > 8 && buf[0] === 0x89 && buf[1] === 0x50 ? 'png' : 'jpeg';

  const plan = Fit.fitPlan({
    bytes: buf.length, width: size.width, height: size.height,
    format: originalFormat,
    // LOOKED AT, NOT ASSUMED.
    //
    // The first version took "it is a PNG" for "it has transparency", and a
    // photograph saved as PNG — a screenshot, an export, most of what people
    // actually have — then walked the whole PNG ladder because PNG never gets
    // small enough. Measured on a 13 MB 3000×2200 photo: it fitted at 800×587
    // PNG, when JPEG at 2000px fits with room to spare and looks far better.
    // Assuming cost that image most of its resolution to protect an alpha
    // channel it did not have.
    hasAlpha: originalFormat === 'png' && hasTransparency(img),
    budgetBytes: budget, maxEdge: o.maxEdge,
  });

  const base = {
    originalBytes: buf.length, originalWidth: size.width, originalHeight: size.height,
    originalFormat, note: plan.note,
  };
  if (plan.keep) {
    return { ok: true, keep: true, buffer: buf, bytes: buf.length, format: originalFormat,
      width: size.width, height: size.height, ...base };
  }

  for (const step of plan.steps) {
    const longest = Math.max(size.width, size.height) || step.maxEdge;
    const scaled = longest > step.maxEdge
      ? img.resize(size.width >= size.height
        ? { width: step.maxEdge, quality: 'best' }
        : { height: step.maxEdge, quality: 'best' })
      : img;
    const out = step.format === 'png' ? scaled.toPNG() : scaled.toJPEG(step.quality);
    if (out && out.length && out.length <= budget) {
      const s = scaled.getSize();
      return { ok: true, keep: false, buffer: out, bytes: out.length, format: step.format,
        quality: step.quality, width: s.width, height: s.height, ...base };
    }
  }

  /* NOTHING IN THE PLAN FIT, so this refuses rather than returning the smallest
   * attempt. The floor exists because a shop can crop or re-shoot a picture and
   * cannot undo what we quietly did to its only one. */
  return { ok: false, reason: 'too-large', ...base, bytes: buf.length };
}

/**
 * Fit one image for upload. `dataUrl` in, `dataUrl` out, plus what was done.
 *
 * Returns the sentence as well as the numbers: a photo that was silently
 * recompressed is one a shop will one day notice looks worse than the file on
 * its disk, and wonder what else Khayt changed without saying.
 */
ipcMain.handle('hub:fit-image', async (_e, { dataUrl, budgetBytes, maxEdge } = {}) => {
  try {
    const Fit = require('./lib/image-fit.js');
    const m = /^data:image\/[a-z+.-]+;base64,(.+)$/i.exec(String(dataUrl || ''));
    if (!m) return { ok: false, error: 'Not an image.' };
    const buf = Buffer.from(m[1], 'base64');
    // A cap on what we will even attempt: decoding an arbitrarily large image
    // into memory on the main process is a way to take the app down.
    if (buf.length > 64 * 1024 * 1024) return { ok: false, error: 'That image is too large to process.' };
    const r = fitImageBuffer(buf, { budgetBytes, maxEdge });
    if (!r.ok) return { ok: false, error: Fit.describeResult(r), reason: r.reason };
    return {
      ok: true, keep: !!r.keep,
      dataUrl: `data:image/${r.format};base64,${r.buffer.toString('base64')}`,
      bytes: r.bytes, originalBytes: r.originalBytes,
      width: r.width, height: r.height, format: r.format,
      message: Fit.describeResult(r),
    };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:save-order-photo', async (_e, orderId, idx, dataUrl) => {
  const { ext, buffer } = decodeDataUrl(dataUrl);
  const safeId = path.basename(String(orderId || '')).replace(/[^a-zA-Z0-9_-]/g, '_');
  const filename = `${safeId}-${parseInt(idx,10)||0}-${Date.now().toString(36)}.${ext}`;
  await fs.promises.writeFile(path.join(orderPhotosDir(), filename), buffer);
  return filename;
});
ipcMain.handle('hub:load-order-photo', async (_e, filename) =>
  imageToDataUrl(path.join(orderPhotosDir(), path.basename(filename || ''))));
ipcMain.handle('hub:delete-order-photo', async (_e, filename) => {
  const full = path.join(orderPhotosDir(), path.basename(filename || ''));
  if (filename && fs.existsSync(full)) await fs.promises.unlink(full);
  return true;
});

// --- Order file attachments (STL, 3MF, G-code, etc.) ---
ipcMain.handle('hub:pick-and-save-order-file', async (event, orderId) => {
  const wc = event.sender;
  const win = BrowserWindow.fromWebContents(wc);
  const result = await dialog.showOpenDialog(win, {
    title: 'Attach File',
    filters: [
      { name: '3D Print Files', extensions: ['stl', '3mf', 'obj', 'gcode', 'gco', 'nc'] },
      { name: 'All Files', extensions: ['*'] }
    ],
    properties: ['openFile']
  });
  if (result.canceled || !result.filePaths.length) return null;
  const src = result.filePaths[0];
  const originalName = path.basename(src);
  const ext = path.extname(originalName).slice(1).toLowerCase() || 'bin';
  const safeId = path.basename(String(orderId || '')).replace(/[^a-zA-Z0-9_-]/g, '_');
  const filename = `${safeId}-${Date.now().toString(36)}.${ext}`;
  await fs.promises.copyFile(src, path.join(orderFilesDir(), filename));
  const stat = await fs.promises.stat(src);
  return { filename, originalName, size: stat.size };
});

ipcMain.handle('hub:open-order-file', async (_e, filename) => {
  const full = path.join(orderFilesDir(), path.basename(filename || ''));
  if (filename && fs.existsSync(full)) await shell.openPath(full);
  return true;
});

ipcMain.handle('hub:delete-order-file', async (_e, filename) => {
  const full = path.join(orderFilesDir(), path.basename(filename || ''));
  if (filename && fs.existsSync(full)) await fs.promises.unlink(full);
  return true;
});

ipcMain.handle('hub:reveal-order-files-folder', async () => shell.openPath(orderFilesDir()));

// --- Product documents (assembly instructions, safety sheets, drawings) ------
//
// Attached to a PRODUCT rather than to a part or an order, and that is the whole
// design decision. A safety sheet is a property of the thing being made, not of
// one order for it — file it against the part and the shop re-attaches the same
// PDF every time somebody orders that product. Filed here, it follows any order
// that names the product, onto the work order the floor reads and the delivery
// note that goes in the box.
//
// Their own directory rather than orderFilesDir(): these outlive any single
// order, and deleting an order's files must never take a product's documents
// with it.
ipcMain.handle('hub:pick-and-save-product-doc', async (event, productId) => {
  const wc = event.sender;
  const win = BrowserWindow.fromWebContents(wc);
  const result = await dialog.showOpenDialog(win, {
    title: 'Attach Document',
    filters: [
      { name: 'Documents', extensions: ['pdf', 'png', 'jpg', 'jpeg', 'txt', 'md', 'doc', 'docx'] },
      { name: 'All Files', extensions: ['*'] },
    ],
    properties: ['openFile'],
  });
  if (result.canceled || !result.filePaths.length) return null;
  const src = result.filePaths[0];
  const originalName = path.basename(src);
  const ext = path.extname(originalName).slice(1).toLowerCase() || 'bin';
  const safeId = path.basename(String(productId || '')).replace(/[^a-zA-Z0-9_-]/g, '_');
  const filename = `${safeId}-${Date.now().toString(36)}.${ext}`;
  await fs.promises.copyFile(src, path.join(productDocsDir(), filename));
  const stat = await fs.promises.stat(src);
  return { filename, originalName, size: stat.size };
});

ipcMain.handle('hub:open-product-doc', async (_e, filename) => {
  const full = path.join(productDocsDir(), path.basename(filename || ''));
  if (filename && fs.existsSync(full)) await shell.openPath(full);
  return true;
});

ipcMain.handle('hub:delete-product-doc', async (_e, filename) => {
  const full = path.join(productDocsDir(), path.basename(filename || ''));
  if (filename && fs.existsSync(full)) await fs.promises.unlink(full);
  return true;
});



// --- PDF export & sharing (new in 1.3) ---
// Pulls the current renderer page as a PDF using Chromium's print pipeline.
// The @media print rules in styles.css hide everything except the invoice area.
ipcMain.handle('hub:export-pdf', async (event, { savePath, askWhere = false, defaultName = 'invoice.pdf' } = {}) => {
  const wc = event.sender;
  const pdfBuffer = await wc.printToPDF({
    pageSize: 'A4',
    printBackground: true,
    margins: { top: 0, right: 0, bottom: 0, left: 0 } // CSS @page handles margins
  });
  let finalPath = null;
  if (savePath) {
    // Silent (no-dialog) writes are confined to the app's own invoices dir under
    // userData. A renderer-supplied savePath can therefore only ever land inside
    // userData/invoices (with a sanitized basename) — it can never overwrite an
    // arbitrary file under Documents/Downloads/Desktop. To save elsewhere the
    // caller must request the save dialog (askWhere: true) below.
    const invDir = path.resolve(invoicesDir());
    const safeName = path.basename(String(savePath)).replace(/[^a-zA-Z0-9._-]/g, '_') || 'invoice.pdf';
    finalPath = path.join(invDir, safeName);
  }
  if (askWhere) {
    const win = BrowserWindow.fromWebContents(wc);
    const result = await dialog.showSaveDialog(win, {
      defaultPath: defaultName,
      filters: [{ name: 'PDF Document', extensions: ['pdf'] }]
    });
    if (result.canceled || !result.filePath) return null;
    finalPath = result.filePath;
  }
  if (!finalPath) {
    // Default location: userData/invoices/<safeName>
    const safeName = String(defaultName || 'invoice.pdf').replace(/[^a-zA-Z0-9._-]/g, '_');
    finalPath = path.join(invoicesDir(), safeName);
  }
  await fs.promises.writeFile(finalPath, pdfBuffer);
  return finalPath;
});

ipcMain.handle('hub:reveal-in-finder', async (_e, filePath) => {
  if (!filePath) return { ok: false };
  const resolved = path.resolve(String(filePath));
  const allowedReveal = [path.resolve(app.getPath('userData'))];
  if (!allowedReveal.some(d => resolved.startsWith(d + path.sep) || resolved === d)) return { ok: false };
  if (fs.existsSync(resolved)) shell.showItemInFolder(resolved);
  return { ok: true };
});

ipcMain.handle('hub:open-path', async (_e, filePath) => {
  if (!filePath) return { ok: false };
  const resolved = path.resolve(String(filePath));
  const allowedOpen = [
    path.resolve(app.getPath('userData')),
    path.resolve(app.getPath('documents')),
    path.resolve(app.getPath('downloads')),
    path.resolve(app.getPath('desktop')),
  ];
  if (!allowedOpen.some(d => resolved.startsWith(d + path.sep) || resolved === d)) return { ok: false };
  if (fs.existsSync(resolved)) shell.openPath(resolved);
  return { ok: true };
});

// Share to WhatsApp. The Web/Desktop WhatsApp wa.me link can't actually
// attach a file via URL params — it only carries text. So we open WhatsApp
// with a pre-filled message AND reveal the PDF in Finder so the user can
// drag it into the conversation.
ipcMain.handle('hub:share-whatsapp', async (_e, { phone, message, pdfPath }) => {
  // Normalize: strip everything but digits. wa.me expects country code.
  const clean = (String(phone || '').replace(/[^\d]/g, ''));
  const text = encodeURIComponent(String(message || '').slice(0, 4096));
  const url = clean ? `https://wa.me/${clean}?text=${text}` : `https://wa.me/?text=${text}`;
  await shell.openExternal(url);
  // Path-confinement: only reveal files inside userData or known download locations
  if (pdfPath) {
    const resolvedPdf = path.resolve(String(pdfPath));
    const allowedPdfDirs = [
      path.resolve(app.getPath('userData')),
      path.resolve(app.getPath('documents')),
      path.resolve(app.getPath('downloads')),
      path.resolve(app.getPath('desktop')),
      path.resolve(app.getPath('temp')),
    ];
    const confined = allowedPdfDirs.some(d => resolvedPdf.startsWith(d + path.sep) || resolvedPdf === d);
    if (confined && fs.existsSync(resolvedPdf)) shell.showItemInFolder(resolvedPdf);
  }
  return true;
});

// --- iCloud Drive backup (new in 1.4) ---
ipcMain.handle('hub:icloud-available', async () => {
  if (process.platform !== 'darwin') return false;
  const icloudBase = path.join(app.getPath('home'), 'Library', 'Mobile Documents', 'com~apple~CloudDocs');
  return fs.existsSync(icloudBase);
});

ipcMain.handle('hub:write-icloud-backup', async (event, jsonString) => {
  if (!jsonString || typeof jsonString !== 'string' || jsonString.length > MAX_STORE_BYTES) {
    return { ok: false, error: 'Backup data too large or invalid' };
  }
  if (process.platform !== 'darwin') return null;
  const icloudBase = path.join(app.getPath('home'), 'Library', 'Mobile Documents', 'com~apple~CloudDocs');
  if (!fs.existsSync(icloudBase)) return null;
  const backupDir = path.join(icloudBase, isBedReady ? 'Bed Ready' : 'Khayt', 'backups');
  if (!fs.existsSync(backupDir)) fs.mkdirSync(backupDir, { recursive: true });
  const filename = `${new Date().toISOString().split('T')[0]}.json`;
  const fullPath = path.join(backupDir, filename);
  let parsed;
  try { parsed = safeJsonParse(jsonString); } catch (e) { return null; }
  const encrypted = JSON.stringify(encryptForDisk(parsed));
  await fs.promises.writeFile(fullPath, encrypted, 'utf8');
  return fullPath;
});

/**
 * Copy the store aside, verbatim, the first time a newer build opens it.
 *
 * Runs once per schema version: the filename carries both versions, so if one
 * already exists for this hop the shop has already been upgraded and the
 * original pre-upgrade state is the one worth keeping — never overwrite it with
 * a later, possibly already-damaged, copy.
 */
function writePreUpgradeBackup(raw, diskVersion) {
  if (!upgradeBackup.needsPreUpgradeBackup(diskVersion, STORE_VERSION, true)) return null;
  const dir = backupsDir();
  const from = Number.isFinite(diskVersion) ? diskVersion : 0;
  const already = fs.readdirSync(dir).some((f) =>
    upgradeBackup.isProtectedBackup(f) && f.includes(`v${from}-to-v${STORE_VERSION}-`));
  if (already) return null;
  const name = upgradeBackup.preUpgradeBackupName(diskVersion, STORE_VERSION, new Date().toISOString());
  const fullPath = path.join(dir, name);
  fs.writeFileSync(fullPath, JSON.stringify(encryptForDisk(raw)), 'utf8');
  console.warn(`store upgrade v${from} → v${STORE_VERSION}: kept a pre-upgrade backup at ${fullPath}`);
  return fullPath;
}

// --- Daily auto-backup (new in 1.3) ---
ipcMain.handle('hub:write-backup', async (event, jsonString) => {
  if (!jsonString || typeof jsonString !== 'string' || jsonString.length > MAX_STORE_BYTES) {
    return { ok: false, error: 'Backup data too large or invalid' };
  }
  const filename = `${new Date().toISOString().split('T')[0]}.json`;
  const fullPath = path.join(backupsDir(), filename);
  let parsed;
  try { parsed = safeJsonParse(jsonString); } catch (e) { return { ok: false, error: 'Invalid JSON in backup data' }; }
  const encrypted = JSON.stringify(encryptForDisk(parsed));
  await fs.promises.writeFile(fullPath, encrypted, 'utf8');
  // Keep only the most recent 30 backups
  // Rotation keeps the 30 most recent DAILY backups. Pre-upgrade backups are
  // excluded from both the count and the deletion: a shop that opens the app on
  // 30 consecutive days would otherwise have its upgrade insurance deleted by
  // routine housekeeping, so the backup would survive exactly as long as nobody
  // needed it.
  const listed = (await fs.promises.readdir(backupsDir())).filter(f => f.endsWith('.json')).sort();
  const { rotatable } = upgradeBackup.partitionForRotation(listed);
  if (rotatable.length > 30) {
    for (const f of rotatable.slice(0, rotatable.length - 30)) {
      await fs.promises.unlink(path.join(backupsDir(), f)).catch(() => {});
    }
  }
  return fullPath;
});
ipcMain.handle('hub:last-backup-date', async () => {
  const all = (await fs.promises.readdir(backupsDir())).filter(f => f.endsWith('.json')).sort();
  if (all.length === 0) return null;
  return all[all.length - 1].replace('.json', '');
});

// List recent backups (Feature 6)
ipcMain.handle('hub:list-backups', async () => {
  const dir = backupsDir();
  const files = (await fs.promises.readdir(dir)).filter(f => f.endsWith('.json')).sort().reverse().slice(0, 10);
  return Promise.all(files.map(async (f) => {
    const fullPath = path.join(dir, f);
    const stat = await fs.promises.stat(fullPath);
    return { name: f.replace('.json', ''), filename: path.basename(fullPath), mtime: stat.mtimeMs };
  }));
});

// Read a backup file by path (Feature 6)
ipcMain.handle('hub:restore-backup', async (event, backupPath) => {
  const safe = path.join(backupsDir(), path.basename(String(backupPath || '')));
  if (!fs.existsSync(safe)) return null;
  try {
    const content = await fs.promises.readFile(safe, 'utf8');
    const parsed = safeJsonParse(content);
    // Restoring a backup decrypts its secrets → a real keychain read. Explain once first.
    await maybeShowKeychainExplanation(BrowserWindow.fromWebContents(event.sender));
    const decrypted = decryptStoreSecrets(JSON.parse(JSON.stringify(parsed)));
    return JSON.stringify(decrypted);
  } catch (e) {
    console.error('hub:restore-backup error:', e);
    return null;
  }
});
ipcMain.handle('hub:reveal-order-photos-folder', async () => shell.openPath(orderPhotosDir()));
ipcMain.handle('hub:reveal-backups-folder', async () => shell.openPath(backupsDir()));

// --- Named restore points (disaster recovery) ---
// Stored in a separate folder from the dated auto-backups so they are never
// auto-pruned; each carries a user label. Encrypted on disk like backups.
const restorePointsDir = () => ensureDir('restore-points');
const sanitizeRpLabel = (s) => String(s || 'Restore point').replace(/[^\p{L}\p{N} _-]/gu, '').trim().slice(0, 60) || 'Restore point';

ipcMain.handle('hub:create-restore-point', async (_e, { json, label } = {}) => {
  if (!json || typeof json !== 'string' || json.length > MAX_STORE_BYTES) return { ok: false, error: 'Invalid data' };
  let parsed;
  try { parsed = safeJsonParse(json); } catch (e) { return { ok: false, error: 'Invalid JSON' }; }
  const safeLabel = sanitizeRpLabel(label);
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const filename = `${stamp}__${safeLabel.replace(/\s+/g, '_')}.json`;
  await fs.promises.writeFile(path.join(restorePointsDir(), filename), JSON.stringify(encryptForDisk(parsed)), 'utf8');
  // Keep the most recent 50 restore points.
  const all = (await fs.promises.readdir(restorePointsDir())).filter(f => f.endsWith('.json')).sort();
  for (const f of all.slice(0, Math.max(0, all.length - 50))) {
    await fs.promises.unlink(path.join(restorePointsDir(), f)).catch(() => {});
  }
  return { ok: true, filename, label: safeLabel };
});

ipcMain.handle('hub:list-restore-points', async () => {
  const dir = restorePointsDir();
  const files = (await fs.promises.readdir(dir)).filter(f => f.endsWith('.json')).sort().reverse();
  return Promise.all(files.map(async (f) => {
    const stat = await fs.promises.stat(path.join(dir, f));
    const label = (f.replace(/\.json$/, '').split('__')[1] || 'Restore point').replace(/_/g, ' ');
    return { filename: f, label, mtime: stat.mtimeMs };
  }));
});

ipcMain.handle('hub:read-restore-point', async (event, filename) => {
  const safe = path.join(restorePointsDir(), path.basename(String(filename || '')));
  if (!fs.existsSync(safe)) return null;
  try {
    const parsed = safeJsonParse(await fs.promises.readFile(safe, 'utf8'));
    // Reading a restore point decrypts its secrets → a keychain read. Explain once first.
    await maybeShowKeychainExplanation(BrowserWindow.fromWebContents(event.sender));
    return JSON.stringify(decryptStoreSecrets(JSON.parse(JSON.stringify(parsed))));
  } catch (e) { console.error('hub:read-restore-point error:', e); return null; }
});

ipcMain.handle('hub:delete-restore-point', async (_e, filename) => {
  const safe = path.join(restorePointsDir(), path.basename(String(filename || '')));
  // The third of these delete handlers. hub:delete-vault-file and hub:printlib-delete were
  // fixed to report the truth; this one still swallowed the error and always claimed
  // success, so a locked file on Windows silently stayed while the list re-rendered.
  try {
    await fs.promises.unlink(safe);
  } catch (e) {
    if (!e || e.code !== 'ENOENT') {   // already gone is the desired end state
      console.error('hub:delete-restore-point:', e);
      return { ok: false, error: String((e && e.message) || e) };
    }
  }
  return { ok: true };
});

// --- Receipt file picker (Feature 5) ---
ipcMain.handle('hub:pick-file', async (event, opts = {}) => {
  const wc = event.sender;
  const win = BrowserWindow.fromWebContents(wc);
  const filters = opts.filters || [{ name: 'All Files', extensions: ['*'] }];
  const result = await dialog.showOpenDialog(win, { filters, properties: ['openFile'] });
  if (result.canceled || !result.filePaths.length) return null;
  return result.filePaths[0];
});

// --- Slice a model with the user's INSTALLED slicer and return its own time +
//     filament estimate (accurate quoting). We never bundle a slicer engine
//     (keeps the license clean); we shell out to one the user installed and parse
//     its G-code summary via lib/gcode-parse. spawn(shell:false) — no injection. ---
function tokenizeSliceArgs(template) {
  const out = []; let cur = ''; let q = null; let has = false;
  for (const ch of String(template || '')) {
    if (q) { if (ch === q) q = null; else { cur += ch; has = true; } }
    else if (ch === '"' || ch === "'") { q = ch; has = true; }
    else if (/\s/.test(ch)) { if (has) { out.push(cur); cur = ''; has = false; } }
    else { cur += ch; has = true; }
  }
  if (has) out.push(cur);
  return out;
}

// Slice a model with the user's installed slicer. Returns { ok, gcodePath, outDir,
// meta, error } WITHOUT cleaning up outDir — the caller decides (parse only, or
// also upload to a printer, then remove outDir).
// Is this path allowed to be launched as a slicer?
//
// THE ANSWER LIVES IN lib/slicers.js, and this used to answer it a second time.
//
// The slicer path and its argument template both come from settings.slicers[],
// which can arrive in a restored backup or a cloud sync. A poisoned entry must
// not become arbitrary code execution the moment somebody clicks Slice, Test or
// Open in slicer. `spawn` runs shell:false, which stops metacharacter injection
// into a shell and does nothing about the binary itself.
//
// What stood here was a DENYLIST of interpreter names — bash, python, node, and
// thirty more. `lib/slicers.js` replaced it with a positive allowlist and wrote
// down why: a denylist cannot be complete. find, awk, gawk, xargs, gdb, make,
// tclsh, lua, busybox, git and expect each run an arbitrary command from their
// own arguments and not one of them is a shell. GTFOBins is the catalogue and it
// does not fit in a Set.
//
// That module, its reasoning and its tests all shipped. Nothing ever called it:
// all three call sites here kept the denylist, so every one of the binaries
// above was accepted as a slicer for as long as it existed. Measured, not
// assumed — the denylist said yes to all ten.
const { isAllowedSlicerBinary } = require('./lib/slicers');

async function runSlice({ modelPath, slicerPath, args, densityGPerCm3 }) {
  const { spawn } = require('node:child_process');
  const os = require('os');
  if (!slicerPath || !fs.existsSync(slicerPath)) return { ok: false, error: 'Slicer not found — set its path in Settings → Slicer.' };
  if (!isAllowedSlicerBinary(slicerPath)) return { ok: false, error: 'That program is not allowed as a slicer.' };
  if (!modelPath || !fs.existsSync(modelPath)) return { ok: false, error: 'Model file not found.' };
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-slice-'));
  const outPath = path.join(outDir, 'out.gcode');
  const argv = tokenizeSliceArgs(args || '--export-gcode -o {output} {model}')
    .map((a) => a.replace(/\{model\}/g, modelPath).replace(/\{output\}/g, outPath).replace(/\{outdir\}/g, outDir));
  const result = await new Promise((resolve) => {
    let stderr = '';
    let child;
    try { child = spawn(slicerPath, argv, { timeout: 180000, windowsHide: true }); }
    catch (err) { return resolve({ code: -1, stderr: String(err && err.message || err) }); }
    child.stderr?.on('data', (d) => { stderr = (stderr + d.toString()).slice(-4000); });
    child.on('error', (err) => resolve({ code: -1, stderr: String(err && err.message || err) }));
    child.on('close', (code) => resolve({ code, stderr }));
  });
  let gpath = fs.existsSync(outPath) ? outPath : null;
  if (!gpath) {
    const gc = fs.readdirSync(outDir).filter((f) => /\.gcode$/i.test(f)).sort();
    if (gc.length) gpath = path.join(outDir, gc[gc.length - 1]);
  }
  if (!gpath) {
    try { fs.rmSync(outDir, { recursive: true, force: true }); } catch { /* ignore */ }
    return { ok: false, error: 'No G-code produced. ' + String(result.stderr || `exit ${result.code}`).slice(0, 300) };
  }
  const buf = fs.readFileSync(gpath);
  const head = buf.subarray(0, 65536).toString('utf8');
  const tail = buf.subarray(Math.max(0, buf.length - 65536)).toString('utf8');
  // The shop's density lets a profile-less slice still be weighed: PrusaSlicer
  // reports the volume exactly but writes 0.00 g when no filament profile is
  // loaded, which is most of the time from a bare STL.
  return { ok: true, gcodePath: gpath, outDir, meta: parseGcodeText(head + '\n' + tail, { densityGPerCm3 }) };
}
const rmDir = (d) => { try { if (d) fs.rmSync(d, { recursive: true, force: true }); } catch { /* ignore */ } };

ipcMain.handle('hub:slice', async (_e, opts = {}) => {
  try {
    const r = await runSlice(opts);
    if (!r.ok) return r;
    rmDir(r.outDir);
    return { ok: true, ...r.meta };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// Quick "does this slicer binary run?" check for Settings → Slicer.
ipcMain.handle('hub:slice-test', async (_e, { slicerPath } = {}) => {
  try {
    const { spawn } = require('node:child_process');
    if (!slicerPath || !fs.existsSync(slicerPath)) return { ok: false, error: 'Slicer not found at that path.' };
    if (!isAllowedSlicerBinary(slicerPath)) return { ok: false, error: 'That program is not allowed as a slicer.' };
    return await new Promise((resolve) => {
      let out = '';
      let child;
      try { child = spawn(slicerPath, ['--help'], { timeout: 15000, windowsHide: true }); }
      catch (err) { return resolve({ ok: false, error: String(err && err.message || err) }); }
      child.stdout?.on('data', (d) => { out = (out + d.toString()).slice(0, 4000); });
      child.stderr?.on('data', (d) => { out = (out + d.toString()).slice(0, 4000); });
      child.on('error', (err) => resolve({ ok: false, error: String(err && err.message || err) }));
      child.on('close', () => resolve({ ok: true, info: (out.split('\n').find((l) => l.trim()) || '').slice(0, 120) }));
    });
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// Resolve a macOS .app bundle to the inner Mach-O binary that spawn() needs
// (spawning the .app directory itself does not launch it).
function macAppBinary(appPath, preferred) {
  const macos = path.join(appPath, 'Contents', 'MacOS');
  if (preferred && fs.existsSync(path.join(macos, preferred))) return path.join(macos, preferred);
  try {
    const files = fs.readdirSync(macos);
    const exe = files.find((f) => !/helper|crashpad|update|renderer|gpu/i.test(f)) || files[0];
    if (exe) return path.join(macos, exe);
  } catch (_) {}
  return null;
}

// Scan the machine for every installed slicer so Settings can offer them all,
// not just a single hard-coded default. Returns [{ name, path }] (path = the
// executable spawn() can launch directly).
function detectInstalledSlicers() {
  const home = require('node:os').homedir();
  const out = [];
  const seen = new Set();
  const add = (name, p) => {
    if (!p) return;
    const rp = path.resolve(p);
    if (seen.has(rp) || !fs.existsSync(rp)) return;
    seen.add(rp);
    out.push({ name, path: rp });
  };
  const plat = process.platform;

  if (plat === 'darwin') {
    // macOS Contents/MacOS/ executable names verified from each project's build config / bundle.
    // Orca/Bambu C++ forks use a CamelCase app-key on macOS (OrcaSlicer, BambuStudio, QIDIStudio,
    // ElegooSlicer, CrealityPrint); Snapmaker's .app has a space but its binary an underscore.
    const apps = [
      { name: 'PrusaSlicer', app: 'PrusaSlicer.app', bin: 'PrusaSlicer' },
      { name: 'OrcaSlicer', app: 'OrcaSlicer.app', bin: 'OrcaSlicer' },
      { name: 'Snapmaker Orca', app: 'Snapmaker Orca.app', bin: 'Snapmaker_Orca' },
      { name: 'Bambu Studio', app: 'BambuStudio.app', bin: 'BambuStudio' },
      { name: 'Bambu Studio', app: 'Bambu Studio.app', bin: 'BambuStudio' },
      { name: 'UltiMaker Cura', app: 'UltiMaker-Cura.app', bin: 'UltiMaker-Cura' },
      { name: 'Elegoo Slicer', app: 'ElegooSlicer.app', bin: 'ElegooSlicer' },
      { name: 'QIDIStudio', app: 'QIDIStudio.app', bin: 'QIDIStudio' },
      { name: 'Creality Print', app: 'CrealityPrint.app', bin: 'CrealityPrint' },
      { name: 'SuperSlicer', app: 'SuperSlicer.app', bin: 'SuperSlicer' },
      { name: 'Slic3r', app: 'Slic3r.app', bin: 'Slic3r' },
      { name: 'ideaMaker', app: 'ideaMaker.app', bin: 'ideaMaker' },
      { name: 'Simplify3D', app: 'Simplify3D.app', bin: 'Simplify3D' },
      { name: 'Lychee Slicer', app: 'LycheeSlicer.app', bin: 'LycheeSlicer' },
      { name: 'Lychee Slicer', app: 'Lychee Slicer.app', bin: 'LycheeSlicer' },
      { name: 'CHITUBOX', app: 'CHITUBOX.app', bin: 'CHITUBOX' },
      { name: 'FlashPrint', app: 'FlashPrint.app', bin: 'FlashPrint' },
    ];
    let displayName = null;
    try { displayName = require('./lib/slicers').slicerDisplayName; } catch (_) {}
    const dirs = ['/Applications', path.join(home, 'Applications')];
    for (const d of dirs) {
      for (const k of apps) {
        const appPath = path.join(d, k.app);
        if (fs.existsSync(appPath)) add(k.name, macAppBinary(appPath, k.bin));
      }
      let entries = [];
      try { entries = fs.readdirSync(d); } catch (_) {}
      for (const e of entries) {
        // Any .app whose name looks like a slicer — vendor OrcaSlicer forks
        // (Snapmaker Orca, QIDIStudio, Elegoo, Anker, Creality/Bambu) and Cura
        // builds that are not in the list below.
        //
        // The SAME test that decides whether a path may be LAUNCHED, not a
        // second copy of the token list beside it. Two copies is how a scanner
        // comes to offer a shop a slicer the guard then refuses to run;
        // detection and permission have to be one answer.
        if (!/\.app$/i.test(e) || !isAllowedSlicerBinary(e)) continue;
        const stem = e.replace(/\.app$/i, '');
        add((displayName && displayName(e)) || stem, macAppBinary(path.join(d, e)));
      }
    }
  } else if (plat === 'win32') {
    const pf = process.env['ProgramFiles'] || 'C:\\Program Files';
    const pfx86 = process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)';
    const lad = process.env['LOCALAPPDATA'] || path.join(home, 'AppData', 'Local');
    // Windows/Linux binaries for the Orca/Bambu forks use the lowercase-dash SLIC3R_APP_CMD
    // (orca-slicer, bambu-studio, qidi-studio, elegoo-slicer, snapmaker-orca); Creality is CamelCase.
    const cands = [
      { name: 'PrusaSlicer', rels: ['Prusa3D\\PrusaSlicer\\prusa-slicer.exe'] },
      { name: 'OrcaSlicer', rels: ['OrcaSlicer\\orca-slicer.exe', 'OrcaSlicer\\OrcaSlicer.exe'] },
      { name: 'Snapmaker Orca', rels: ['Snapmaker Orca\\snapmaker-orca.exe', 'Snapmaker Orca\\Snapmaker Orca.exe', 'Snapmaker Orca\\snapmaker_orca.exe', 'Snapmaker_Orca\\Snapmaker_Orca.exe'] },
      { name: 'Bambu Studio', rels: ['Bambu Studio\\bambu-studio.exe', 'Bambu Studio\\BambuStudio.exe'] },
      { name: 'Elegoo Slicer', rels: ['ElegooSlicer\\elegoo-slicer.exe', 'ElegooSlicer\\ElegooSlicer.exe'] },
      { name: 'QIDIStudio', rels: ['QIDIStudio\\qidi-studio.exe', 'QIDIStudio\\QIDIStudio.exe'] },
      { name: 'Sovol Slicer', rels: ['SovolSlicer\\sovol-slicer.exe'] },
      { name: 'SuperSlicer', rels: ['SuperSlicer\\superslicer.exe'] },
      { name: 'ideaMaker', rels: ['Raise3D\\ideaMaker\\ideaMaker.exe'] },
      { name: 'Simplify3D', rels: ['Simplify3D\\Simplify3D.exe'] },
      { name: 'Creality Print', rels: ['Creality\\Creality Print\\CrealityPrint.exe', 'CrealityPrint\\CrealityPrint.exe'] },
      { name: 'FlashPrint', rels: ['FlashForge\\FlashPrint 5\\FlashPrint.exe', 'FlashForge\\FlashPrint\\FlashPrint.exe'] },
      { name: 'Lychee Slicer', rels: ['LycheeSlicer\\LycheeSlicer.exe'] },
      { name: 'CHITUBOX', rels: ['ChiTuBox\\CHITUBOX.exe'] },
    ];
    const roots = [pf, pfx86, path.join(lad, 'Programs')];
    for (const c of cands) for (const root of roots) for (const rel of c.rels) add(c.name, path.join(root, rel));
    // Folder layout varies by version for some vendors — scan for Cura / Creality Print dirs.
    for (const root of [pf, pfx86]) {
      let entries = [];
      try { entries = fs.readdirSync(root); } catch (_) {}
      for (const e of entries) {
        if (/cura/i.test(e)) {
          for (const bin of ['UltiMaker-Cura.exe', 'Ultimaker Cura.exe', 'Cura.exe']) add(e, path.join(root, e, bin));
        } else if (/creality/i.test(e)) {
          for (const bin of ['CrealityPrint.exe', 'Creality Print\\CrealityPrint.exe']) add('Creality Print', path.join(root, e, bin));
        }
      }
    }
  } else {
    const bins = [
      { name: 'PrusaSlicer', cmds: ['prusa-slicer', 'PrusaSlicer'] },
      { name: 'OrcaSlicer', cmds: ['orca-slicer', 'OrcaSlicer'] },
      { name: 'Snapmaker Orca', cmds: ['snapmaker-orca', 'Snapmaker_Orca', 'SnapmakerOrca'] },
      { name: 'Bambu Studio', cmds: ['bambu-studio', 'BambuStudio'] },
      { name: 'Elegoo Slicer', cmds: ['elegoo-slicer', 'ElegooSlicer'] },
      { name: 'QIDIStudio', cmds: ['qidi-studio', 'qidi-slicer', 'QIDIStudio'] },
      { name: 'Creality Print', cmds: ['CrealityPrint', 'creality-print'] },
      { name: 'UltiMaker Cura', cmds: ['cura', 'UltiMaker-Cura'] },
      { name: 'SuperSlicer', cmds: ['superslicer', 'SuperSlicer'] },
      { name: 'Slic3r', cmds: ['slic3r'] },
      { name: 'ideaMaker', cmds: ['ideaMaker', 'ideamaker'] },
      { name: 'Lychee Slicer', cmds: ['lycheeslicer', 'LycheeSlicer'] },
    ];
    const dirs = ['/usr/bin', '/usr/local/bin', path.join(home, '.local', 'bin'),
      '/var/lib/flatpak/exports/bin', path.join(home, '.local', 'share', 'flatpak', 'exports', 'bin')];
    for (const b of bins) for (const cmd of b.cmds) for (const d of dirs) add(b.name, path.join(d, cmd));
    let dn = null;
    try { dn = require('./lib/slicers').slicerDisplayName; } catch (_) {}
    for (const d of [path.join(home, 'Applications'), path.join(home, 'Downloads'), path.join(home, '.local', 'bin')]) {
      let entries = [];
      try { entries = fs.readdirSync(d); } catch (_) {}
      for (const e of entries) {
        if (!/\.AppImage$/i.test(e)) continue;
        if (!/slic|cura|prusa|orca|bambu|snapmaker|elegoo|qidi|creality|lychee|ideamaker|anycubic|sovol/i.test(e)) continue;
        add((dn && dn(e)) || e.replace(/\.AppImage$/i, ''), path.join(d, e));
      }
    }
  }
  return out;
}

// Settings → Slicer: find every slicer installed on this computer.
ipcMain.handle('hub:detect-slicers', async () => {
  try { return { ok: true, slicers: detectInstalledSlicers() }; }
  catch (e) { return { ok: false, error: String(e && e.message || e), slicers: [] }; }
});

// Upload a G-code file to a printer (OctoPrint / Moonraker / PrusaLink) and
// optionally start it. Uses the same host allowlist as the status poller (SSRF-safe).
async function uploadGcodeToPrinter(machine, gcodePath, startPrint) {
  const { type, host, port, apiKey, accessCode, serial, printerSlug } = (machine && machine.printerApi) || {};
  const printerHost = sanitizePrinterHost(host);
  if (!isAllowedPrinterHost(printerHost)) return { ok: false, error: 'Invalid printer host' };
  const portNum = parseInt(port || defaultPrinterPort(type), 10);
  if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) return { ok: false, error: 'Invalid port' };
  const bytes = fs.readFileSync(gcodePath);
  // Bambu Lab: upload over FTPS (:990), then start it over MQTT (:8883).
  if (type === 'bambu') {
    const dev = String(serial || printerSlug || '').trim();
    if (!dev) return { ok: false, error: 'Bambu needs the printer serial number.' };
    if (!accessCode) return { ok: false, error: 'Bambu needs the LAN access code.' };
    const ext = /\.3mf$/i.test(gcodePath) ? '3mf' : 'gcode';
    const remoteName = `khayt-${Date.now().toString(36)}.${ext}`;
    try {
      await bambuFtpUpload({ host: printerHost, accessCode, remoteName, data: bytes });
      if (startPrint) await bambu.bambuSendPrint({ host: printerHost, accessCode, serial: dev, fileName: remoteName });
      return { ok: true, started: !!startPrint, filename: remoteName };
    } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
  }
  const base = `http://${printerHost}:${portNum}`;
  const name = `khayt-${Date.now().toString(36)}.gcode`;
  const ok = (res) => (res.status >= 200 && res.status < 300) ? { ok: true, started: !!startPrint, filename: name } : { ok: false, error: `Printer responded ${res.status}` };
  try {
    if (type === 'octoprint' || type === 'moonraker') {
      const fd = new FormData();
      fd.set('file', new Blob([bytes], { type: 'text/plain' }), name);
      let url, headers = {};
      if (type === 'octoprint') { fd.set('select', 'true'); fd.set('print', startPrint ? 'true' : 'false'); url = `${base}/api/files/local`; headers['X-Api-Key'] = apiKey || ''; }
      else { fd.set('root', 'gcodes'); fd.set('print', startPrint ? 'true' : 'false'); url = `${base}/server/files/upload`; if (apiKey) headers['X-Api-Key'] = apiKey; }
      return ok(await fetch(url, { method: 'POST', headers, body: fd, signal: AbortSignal.timeout(60000) }));
    }
    if (type === 'prusalink') {
      // PrusaLink v1: PUT raw G-code to USB storage; Print-After-Upload auto-starts.
      return ok(await fetch(`${base}/api/v1/files/usb/${encodeURIComponent(name)}`, {
        method: 'PUT',
        headers: { 'X-Api-Key': apiKey || '', 'Content-Type': 'application/octet-stream', 'Print-After-Upload': startPrint ? '1' : '0' },
        body: bytes, signal: AbortSignal.timeout(60000),
      }));
    }
    return { ok: false, error: `Send-to-printer isn't supported for ${type || 'this printer'} yet (OctoPrint, Moonraker, PrusaLink, Bambu Lab).` };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
}

// Send an already-sliced G-code file straight to a printer (no slicing).
ipcMain.handle('hub:printer-send-gcode', async (_e, { machine, gcodePath, startPrint } = {}) => {
  try {
    if (!gcodePath || !fs.existsSync(gcodePath)) return { ok: false, error: 'G-code file not found.' };
    return await uploadGcodeToPrinter(machine, gcodePath, startPrint);
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:slice-and-print', async (_e, { modelPath, slicerPath, args, machine, startPrint } = {}) => {
  let outDir;
  try {
    const r = await runSlice({ modelPath, slicerPath, args });
    if (!r.ok) return r;
    outDir = r.outDir;
    const up = await uploadGcodeToPrinter(machine, r.gcodePath, startPrint);
    return up.ok ? { ok: true, meta: r.meta, ...up } : up;
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
  finally { rmDir(outDir); }
});

// Print an order's attached file straight to a machine: resolve the file inside
// the order-files folder (confined), slice it if it's a model or upload directly
// if it's already G-code, then start the print.
ipcMain.handle('hub:print-order-file', async (_e, { orderFile, machine, slicerPath, args, startPrint } = {}) => {
  let outDir;
  try {
    const full = path.join(orderFilesDir(), path.basename(String(orderFile || '')));
    if (!orderFile || !fs.existsSync(full)) return { ok: false, error: 'Attached file not found.' };
    if (/\.(gcode|gco|g|nc)$/i.test(full)) return await uploadGcodeToPrinter(machine, full, startPrint);
    const r = await runSlice({ modelPath: full, slicerPath, args });
    if (!r.ok) return r;
    outDir = r.outDir;
    const up = await uploadGcodeToPrinter(machine, r.gcodePath, startPrint);
    return up.ok ? { ok: true, meta: r.meta, ...up } : up;
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
  finally { rmDir(outDir); }
});

// --- Open file path — restricted to app userData and system temp directories ---
ipcMain.handle('hub:open-file', async (_e, filePath) => {
  const s = path.resolve(String(filePath || ''));
  const allowed = [
    path.resolve(app.getPath('userData')),
    path.resolve(app.getPath('temp')),
  ];
  const confined = allowed.some(dir => s.startsWith(dir + path.sep) || s === dir);
  if (confined && fs.existsSync(s)) await shell.openPath(s);
  return true;
});

// --- Save HTML to temp and open (Feature 7) ---
ipcMain.handle('hub:save-html', async (_e, html, filename, opts = {}) => {
  const tmpDir = app.getPath('temp');
  // Force a .html extension. The file is written then shell.openPath'd, so a
  // renderer-supplied name like "x.hta" / "x.url" / "x.command" would otherwise
  // be launched by a native OS handler (e.g. mshta) → host code execution.
  // Stripping the extension and appending .html makes it open in the browser.
  const baseName = String(filename || 'status').replace(/[^a-zA-Z0-9._-]/g, '_').replace(/\.[^.]*$/, '');
  const safeName = (baseName || 'status') + '.html';
  const fullPath = path.join(tmpDir, safeName);
  const content = opts?.interactive
    ? String(html || '').replace(/\bhref\s*=\s*["']?\s*javascript:/gi, 'href="blocked:')
    : sanitizeHtmlForFile(html);
  await fs.promises.writeFile(fullPath, content, 'utf8');
  await shell.openPath(fullPath);
  return fullPath;
});

ipcMain.handle('hub:encryption-available', async () => ({
  ok: true,
  available: isEncryptionAvailable(),
}));

// --- Main data store (file-based) ---
// ── One-time keychain explanation ──────────────────────────────────────────
// Shows a native dialog before the OS credential-store permission prompt so
// users understand why macOS/Windows is asking for keychain access.
async function maybeShowKeychainExplanation(win) {
  if (!safeStorage.isEncryptionAvailable()) return;
  const flagPath = path.join(app.getPath('userData'), 'khayt-keychain-ok.flag');
  if (fs.existsSync(flagPath)) return;

  const storeName = process.platform === 'darwin' ? 'macOS Keychain'
                  : process.platform === 'win32'  ? 'Windows Credential Manager'
                  : 'your system keyring';

  try {
    await dialog.showMessageBox(win || undefined, {
      type: 'info',
      title: `${FLAVOR_NAME} — Secure Storage`,
      message: 'Your API keys are encrypted',
      detail:
        `${FLAVOR_NAME} encrypts sensitive credentials — ZATCA keys, printer API tokens, ` +
        `payment gateway secrets, and email passwords — using ${storeName}.\n\n` +
        `This is the same secure storage that protects your browser passwords and ` +
        `iCloud data. Nothing is sent to any server.\n\n` +
        `${process.platform === 'darwin'
          ? `macOS will ask for permission once. Click "Always Allow" so ${FLAVOR_NAME} can read these keys each time it opens.`
          : 'Your OS may ask for permission to access the credential store — please allow it.'}`,
      buttons: ['Allow Secure Access'],
      defaultId: 0,
    });
    fs.writeFileSync(flagPath, '1');
  } catch (e) {
    console.warn('[keychain] explanation dialog failed:', e?.message || e);
    // Do not block store load if the dialog cannot be shown.
  }
}

ipcMain.handle('hub:load-store', async (event) => {
  // No keychain explanation here. This handler reads raw JSON, validates it and
  // MASKS secrets for the renderer — it never decrypts, so it never touches the
  // keychain. The explanation used to await a modal on this path, which meant a
  // fresh install hung at boot forever if the dialog was missed or dismissed by
  // the OS. It now gates the operations that actually reach the keychain: save
  // (encrypt) and restore (decrypt), below.
  try {
    // Read the best available copy, transparently recovering from a crash (completed .tmp
    // or previous-generation .prev) and quarantining an unreadable primary so it's never
    // overwritten. This closes the window where a corrupt/partial read led the app to run
    // on empty state and then overwrite the good file on the next save.
    const rec = recoverStoreRaw(MAX_STORE_BYTES);
    if (!rec.data) {
      if (!rec.existed) return null; // genuinely a fresh install
      console.error('hub:load-store: store unreadable; quarantined to', rec.quarantined);
      return { __corrupt: true, error: 'Store unreadable', quarantined: rec.quarantined };
    }
    if (rec.source !== 'primary') console.warn('hub:load-store: recovered store from', rec.source, rec.quarantined ? `(quarantined ${rec.quarantined})` : '');
    // Remember which schema wrote this file, so a save cannot truncate a newer store.
    _diskStoreVersion = (rec.data && typeof rec.data.version === 'number') ? rec.data.version : null;
    // Insurance against THIS build's own migrations being wrong. Taken from
    // rec.data — the raw bytes just read — because the normalize step below is an
    // allowlist, and losing an unrecognised collection is one of the things being
    // insured against. Best-effort: a shop must still be able to open its app if
    // the backups directory is unwritable, so a failure here is logged, not fatal.
    try { writePreUpgradeBackup(rec.data, _diskStoreVersion); }
    catch (e) { console.error('hub:load-store: pre-upgrade backup failed:', e && e.message || e); }
    syncLanServerStoreFromDisk();
    const { normalized, warnings, errors } = normalizeStoreSnapshot(rec.data);
    if (!normalized) {
      console.error('hub:load-store: unrecoverable store shape:', errors.join('; '));
      return { __corrupt: true, error: errors[0] || 'Invalid store' };
    }
    if (errors.length) console.warn('hub:load-store: recovered with issues:', errors.join('; '));
    if (warnings.length) console.warn('hub:load-store:', warnings.join('; '));
    // Mask secrets — renderer must not receive plaintext credentials
    const masked = maskStoreSecretsForRenderer(normalized);
    if (rec.source && rec.source !== 'primary') {
      masked.__recovered = rec.source;
      // Recovering from .prev means the LAST save is gone. Sending the age lets the
      // app say so instead of showing a green tick over real loss.
      masked.__recoveredAt = rec.writtenAt || null;
    }
    return masked;
  } catch (e) {
    console.error('hub:load-store error:', e);
    return { __corrupt: true, error: String(e.message || e) };
  }
});


// Printer discovery and the webcam proxy used to be written out here; they are
// the same code, in lib/main/, registered at the point they used to occupy so
// the file still reads in the order things happen.
// Returns the two functions the rest of this file still calls — see the note in
// that module about why a low dependency count did not make it safe to move.
const { scanForPrinters, sweepForPrinters } = registerPrinterDiscovery({ app, ipcMain, sdcpClient });
registerWebcamProxy({ ipcMain, path, lanServerStore });

/* ── Installed themes ────────────────────────────────────────────────────────
 *
 * They live in userData rather than beside the app, because beside the app means
 * inside `app.asar` — read-only, and replaced whole on every update. That is why
 * the existing `themes/custom/index.json` has never had an entry: nobody could
 * add one and keep it.
 *
 * Every path here comes from lib/theme-store.js, which resolves and confines
 * them, and every stylesheet goes through lib/theme-package.js before a byte is
 * written. Neither check is repeated in this file; both are required by it.
 */
function themesRootDir() {
  const Store = require('./lib/theme-store.js');
  return Store.themesRoot(app.getPath('userData'));
}

ipcMain.handle('hub:themes-list', async () => {
  const Store = require('./lib/theme-store.js');
  const root = themesRootDir();
  const out = [];
  try {
    const entries = await fs.promises.readdir(root, { withFileTypes: true });
    for (const e of entries) {
      if (!e.isDirectory() || !Store.isValidId(e.name)) continue;
      const dir = Store.themeDir(app.getPath('userData'), e.name);
      if (!dir) continue;
      let manifest = null;
      const problems = [];
      try {
        manifest = JSON.parse(await fs.promises.readFile(path.join(dir, Store.MANIFEST_NAME), 'utf8'));
      } catch (err) {
        problems.push({ id: 'unreadable', why: 'manifest.json is missing or will not parse' });
      }
      out.push(Store.describeInstalled(e.name, manifest, problems));
    }
  } catch (err) { /* no themes directory yet is not an error, it is a new install */ }
  return { ok: true, themes: out, root };
});

ipcMain.handle('hub:themes-install', async (_e, { text } = {}) => themeInstallFromText(text));

async function themeInstallFromText(text) {
  const Store = require('./lib/theme-store.js');
  const Pkg = require('./lib/theme-package.js');

  const parsed = Store.parseBundle(text);
  if (!parsed.ok) return { ok: false, error: parsed.error };

  // The CSS is judged before anything is written, not after. An install that has
  // to be undone is an install that already ran.
  const judged = Pkg.inspectPackage({ manifest: parsed.manifest, files: parsed.files });
  if (!judged.ok) return { ok: false, error: Pkg.explain(judged), problems: judged.problems };

  const plan = Store.planInstall(app.getPath('userData'), parsed.manifest, parsed.files);
  if (!plan) return { ok: false, error: 'This theme could not be installed safely.' };

  try {
    await fs.promises.mkdir(plan.dir, { recursive: true });
    for (const w of plan.writes) await fs.promises.writeFile(w.path, w.contents, 'utf8');
  } catch (err) {
    return { ok: false, error: `Could not write the theme: ${(err && err.message) || err}` };
  }
  return { ok: true, id: parsed.manifest.id, name: parsed.manifest.name || parsed.manifest.id, dir: plan.dir };
}

/**
 * Pick a design file and install it, in one call.
 *
 * Deliberately not "pick a file" followed by "read that file". The second half
 * of that pair is a general-purpose read-any-file capability handed to the
 * renderer, which is a much larger thing to own than this feature needs — and
 * once it exists, every future bug in the renderer inherits it. The path never
 * leaves the main process instead.
 */
ipcMain.handle('hub:themes-install-file', async (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const result = await dialog.showOpenDialog(win, {
    filters: [{ name: 'Khayt design', extensions: ['khayttheme', 'json'] }],
    properties: ['openFile'],
  });
  if (result.canceled || !result.filePaths.length) return { ok: false, canceled: true };

  const file = result.filePaths[0];
  let text;
  try {
    const stat = await fs.promises.stat(file);
    // A design is a stylesheet and a few fields. Anything of this size is not
    // one, and reading it into memory to find that out would be the bug.
    if (stat.size > 4 * 1024 * 1024) return { ok: false, error: 'That file is too large to be a design.' };
    text = await fs.promises.readFile(file, 'utf8');
  } catch (err) {
    return { ok: false, error: `Could not read that file: ${(err && err.message) || err}` };
  }
  // Straight into the same handler's logic — the checks live there and are not
  // repeated or relaxed here.
  return themeInstallFromText(text);
});

ipcMain.handle('hub:themes-read', async (_e, { id } = {}) => {
  const Store = require('./lib/theme-store.js');
  const Pkg = require('./lib/theme-package.js');
  const dir = Store.themeDir(app.getPath('userData'), id);
  if (!dir) return { ok: false, error: 'Unknown theme.' };

  let manifest;
  try {
    manifest = JSON.parse(await fs.promises.readFile(path.join(dir, Store.MANIFEST_NAME), 'utf8'));
  } catch (err) {
    return { ok: false, error: 'This theme is missing its manifest.' };
  }

  const files = {};
  for (const field of ['tokens', 'compat', 'shellCss']) {
    const name = manifest[field];
    if (!name || !Store.SAFE_FILENAME.test(String(name))) continue;
    const target = path.join(dir, String(name));
    if (!Store.isInsideRoot(dir, target)) continue;
    try { files[String(name)] = await fs.promises.readFile(target, 'utf8'); } catch (err) { /* reported below as missing */ }
  }

  // Judged AGAIN, on every read.
  //
  // The install-time check proved the file was safe when it arrived. It says
  // nothing about the file now: userData is a directory the owner can open, and
  // anything else running as that user can write to. A theme that passed once
  // and was edited afterwards would otherwise be loaded on that old verdict —
  // which is the same trust-on-first-use mistake as reviewing a dependency at
  // the version you installed and then upgrading it silently.
  //
  // It costs a regex pass over a few KB, once per theme change.
  const judged = Pkg.inspectPackage({ manifest, files });
  if (!judged.ok) {
    return { ok: false, error: Pkg.explain(judged), problems: judged.problems, changedSinceInstall: true };
  }
  return {
    ok: true,
    manifest,
    css: judged.files.map((name) => ({ name, text: files[name] })),
  };
});

ipcMain.handle('hub:themes-remove', async (_e, { id } = {}) => {
  const Store = require('./lib/theme-store.js');
  const dir = Store.themeDir(app.getPath('userData'), id);
  // A null dir means the id would not have been installable, so nothing under
  // that name can be ours to delete. Refusing beats deleting something else.
  if (!dir) return { ok: false, error: 'Unknown theme.' };
  try {
    await fs.promises.rm(dir, { recursive: true, force: true });
  } catch (err) {
    return { ok: false, error: `Could not remove the theme: ${(err && err.message) || err}` };
  }
  return { ok: true, id };
});

ipcMain.handle('hub:relocate-printers', async (_e, { machines, statusCache, requireOffline, timeoutMs } = {}) => {
  const Relocate = require('./lib/printer-relocate.js');
  const scan = await scanForPrinters(timeoutMs);
  if (!scan.ok) return scan;
  // mDNS first, then ask. A printer that announces nothing is still a printer,
  // and it is disproportionately the one whose owner needs this.
  const swept = await sweepForPrinters(machines, timeoutMs);
  const known = new Set(scan.printers.map((p) => String(p.host || '').toLowerCase()));
  scan.printers = scan.printers.concat(swept.filter((p) => !known.has(String(p.host || '').toLowerCase())));
  // TRUST BOUNDARY: `machines` is renderer-supplied, and is used here only to
  // decide which of the scan's own results to describe. Nothing is fetched from
  // it and nothing is written, so a forged entry can at most produce a proposal
  // the owner then declines.
  const list = Array.isArray(machines) ? machines : [];
  const plan = Relocate.planRelocations({
    machines: list,
    discovered: scan.printers,
    statusCache: statusCache || {},
    requireOffline: requireOffline !== false,
  });
  return {
    ok: true,
    printers: scan.printers,
    moves: plan.moves,
    noMoves: plan.noMoves,
    // Identities worth recording while the printers are still answering where
    // they are configured — the only moment a provable one is available.
    learned: Relocate.learnSerials({ machines: list, discovered: scan.printers }),
  };
});


// BNPL checkout links (Tabby, Tamara, Stripe) — lib/main/payment-links.js.
registerPaymentLinks({ ipcMain, resolveStoreSecret });

// ── Telemetry (TELEMETRY-SPEC) ──────────────────────────────────────────────
// OFF by default and gated on explicit per-stream consent. Scrubbing happens HERE — the
// single trusted choke point — and the transport only ever accepts scrubber output, so an
// unscrubbed send is impossible by construction.
//
// There IS an endpoint now (khayt-cloud, POST /v1/telemetry) and lib/telemetry-sender.js
// flushes to it. Two things stay true regardless: nothing leaves without the matching
// per-stream consent, checked again at send time because consent can be withdrawn after an
// event was queued; and the ingest ships DORMANT server-side, so today the flush gets a 404,
// keeps the queue and waits. That is the designed state, not a failure — the field starts
// reporting when the flag flips, with no desktop release needed.
const TELEMETRY_QUEUE_FILE = () => path.join(app.getPath('userData'), 'telemetry-queue.json');

function telemetryConsent() {
  const tm = (lanServerStore && lanServerStore.settings && lanServerStore.settings.telemetry) || {};
  return { crash: !!tm.crashOptIn, usage: !!tm.usageOptIn, installId: tm.installId || '' };
}

function readTelemetryQueue() {
  try { return JSON.parse(fs.readFileSync(TELEMETRY_QUEUE_FILE(), 'utf8')) || []; } catch { return []; }
}

function enqueueTelemetry(kind, rawPayload) {
  try {
    const consent = telemetryConsent();
    if (kind === 'crash' && !consent.crash) return;
    if (kind === 'usage' && !consent.usage) return;
    const Scrub = require('./lib/telemetry-scrub.js');
    // Fail closed: a scrubber throw drops the event rather than risking raw data.
    const payload = kind === 'crash'
      ? Scrub.buildCrashReport({ ...rawPayload, installId: consent.installId })
      : Scrub.buildUsageEvent({ ...rawPayload, installId: consent.installId });
    if (!payload) return;
    let q = readTelemetryQueue();
    q.push({ kind, payload, at: new Date().toISOString() });
    q = Scrub.dedupeCrashes(Scrub.boundQueue(q, 200));
    fs.writeFileSync(TELEMETRY_QUEUE_FILE(), JSON.stringify(q), 'utf8');
  } catch (_) { /* telemetry must never break or crash the app */ }
}

// Opt-out purges everything queued locally, immediately.
ipcMain.handle('hub:telemetry-purge', async () => {
  try { fs.unlinkSync(TELEMETRY_QUEUE_FILE()); } catch (_) {}
  return { ok: true };
});

ipcMain.handle('hub:telemetry-record', async (_e, { kind, payload } = {}) => {
  enqueueTelemetry(kind === 'usage' ? 'usage' : 'crash', payload || {});
  return { ok: true };
});

/* ── Sending it ─────────────────────────────────────────────────────────────
 *
 * All of the policy lives in lib/telemetry-sender.js with its clock, its fetch
 * and its queue injected, so every branch is reachable from a test. What is left
 * here is the wiring: where the queue file is, what the consent is, and when to
 * try. `backoff` and `nextAttempt` are process state on purpose — a shop that
 * cannot reach the endpoint should not spend its next launch discovering that
 * again, but it SHOULD get a fresh attempt on a new launch, which is often
 * exactly what changed.
 */
let telemetryBackoffMs = 0;
let telemetryNextAttempt = 0;

async function flushTelemetry() {
  try {
    const Sender = require('./lib/telemetry-sender.js');
    const r = await Sender.flushOnce({
      readQueue: readTelemetryQueue,
      writeQueue: (q) => fs.writeFileSync(TELEMETRY_QUEUE_FILE(), JSON.stringify(q), 'utf8'),
      consent: telemetryConsent(),
      fetchImpl: (...a) => fetch(...a),
      appVersion: app.getVersion(),
      backoffMs: telemetryBackoffMs,
      nextAttemptAt: telemetryNextAttempt,
    });
    telemetryBackoffMs = r.backoffMs;
    telemetryNextAttempt = r.nextAttemptAt;
  } catch (_) { /* telemetry must never break or crash the app */ }
}

// Once shortly after launch — late enough that it is never racing the window
// onto the screen — and then hourly. The interval is unref'd so it can never be
// the reason the app does not quit.
function startTelemetryFlush() {
  const consent = telemetryConsent();
  if (!consent.crash && !consent.usage) return;
  setTimeout(flushTelemetry, 60 * 1000).unref?.();
  const t = setInterval(flushTelemetry, 60 * 60 * 1000);
  t.unref?.();
}

// Never crash the app in order to report a crash.
process.on('uncaughtException', (err) => {
  console.error('uncaughtException:', err);
  enqueueTelemetry('crash', {
    type: 'uncaughtException', name: err && err.name, message: err && err.message,
    stack: err && err.stack, process: 'main', appVersion: app.getVersion(),
    electronVersion: process.versions.electron,
    osFamily: process.platform === 'darwin' ? 'macOS' : process.platform === 'win32' ? 'Windows' : 'Linux',
    osMajor: String(require('os').release() || '').split('.')[0],
  });
});
process.on('unhandledRejection', (reason) => {
  console.error('unhandledRejection:', reason);
  const err = reason instanceof Error ? reason : new Error(String(reason));
  enqueueTelemetry('crash', {
    type: 'unhandledRejection', name: err.name, message: err.message, stack: err.stack,
    process: 'main', appVersion: app.getVersion(), electronVersion: process.versions.electron,
    osFamily: process.platform === 'darwin' ? 'macOS' : process.platform === 'win32' ? 'Windows' : 'Linux',
    osMajor: String(require('os').release() || '').split('.')[0],
  });
});

// Mint a scoped API token. Crypto + hashing live in the main process; the renderer
// receives the plaintext ONCE (to show the owner) plus the hash-only record to persist.
ipcMain.handle('hub:mint-api-token', async (_e, { label, scopes } = {}) => {
  try {
    const ApiTokens = require('./lib/api-tokens.js');
    const { token, record } = ApiTokens.generateToken({ label, scopes });
    return { ok: true, token, record };
  } catch (e) {
    return { ok: false, error: String(e.message || e) };
  }
});

// Set at load time from the store actually on disk. A store written by a NEWER Khayt
// contains collections this build does not know about, and normalizeStoreSnapshot is an
// allowlist — it drops them. Loading such a store and saving once would therefore delete
// that version's data permanently, with only a console warning. Refuse instead.
let _diskStoreVersion = null;

ipcMain.handle('hub:save-store', async (event, data) => {
  try {
    if (typeof _diskStoreVersion === 'number' && _diskStoreVersion > STORE_VERSION) {
      const msg = `This data file was written by a newer version of Khayt (v${_diskStoreVersion}); this build supports v${STORE_VERSION}. Not saving, so nothing is lost — please update Khayt.`;
      console.error('hub:save-store:', msg);
      return { ok: false, error: msg };
    }
    // Once the quit flush has completed the renderer's state is already on disk.
    // Anything arriving after it is redundant — in practice the `pagehide`
    // backstop in app-boot.js firing as the window tears down — and it is not
    // harmless: atomicWriteStore renames the primary to .prev BEFORE moving the
    // new temp into place, so a write killed by app.quit() between those two
    // renames leaves no khayt-store.json at all. recoverStoreRaw() heals that on
    // next launch from .tmp/.prev, but the window should not exist. Refusing
    // costs nothing (the snapshot is identical) and closes it.
    if (_flushedForQuit) return { ok: true, skipped: 'quit-flush-already-completed' };

    const { normalized, errors } = normalizeStoreSnapshot(data);
    if (!normalized) {
      console.error('hub:save-store: unrecoverable store shape:', errors.join('; '));
      return { ok: false, error: errors[0] || 'Invalid store' };
    }
    if (errors.length) console.warn('hub:save-store: salvaged with issues:', errors.join('; '));
    const merged = mergeStoreSecretsFromDisk(normalized);
    // First real keychain write. Explain once, before encryptForDisk triggers
    // the OS permission prompt — but only when there is actually a plaintext
    // secret to encrypt, so a shop that never configures a credential is never
    // asked. Never awaited on the load path, so it cannot stall boot.
    // ...but NOT while quitting. This handler is also what the quit flush runs
    // through, and a modal here has no one to dismiss it: the renderer waits on
    // a reply that cannot come, before-quit's 10s bound fires, and app.quit()
    // runs with the write never started — the pending edit is lost, which is
    // precisely what the quit handshake exists to prevent. The explanation is
    // informational; losing the save is not. Explain next launch instead.
    if (!_quittingNow && hasPlaintextSecrets(merged)) {
      await maybeShowKeychainExplanation(BrowserWindow.fromWebContents(event.sender));
    }
    const serialized = JSON.stringify(encryptForDisk(merged));
    // Write-side guard: mirror the 50 MB read-side limit from hub:load-store.
    // Prevents runaway data-URL or blob embedding from silently bloating the store.
    if (serialized.length > MAX_STORE_BYTES) {
      console.error('hub:save-store: refusing to write store exceeding 50 MB');
      return { ok: false, error: 'Store too large' };
    }
    // Atomic + durable: fsync'd temp swap, with a one-generation .prev rollback.
    await atomicWriteStore(serialized);
    lanServerStore = merged;  // keep LAN server in sync (plaintext in-memory)
    return { ok: true };
  } catch (e) {
    console.error('hub:save-store error:', e);
    return { ok: false, error: String(e) };
  }
});

ipcMain.handle('hub:store-size', async () => {
  try {
    return fs.statSync(dataFilePath()).size;
  } catch { return 0; }
});

ipcMain.handle('hub:reveal-store-file', async () => {
  const fp = dataFilePath();
  if (fs.existsSync(fp)) shell.showItemInFolder(fp);
  else shell.openPath(path.dirname(fp));
  return true;
});

// --- Feature 2: File vault (per-order 3D files) ---
const fileVaultDir = () => ensureDir('file-vault');
ipcMain.handle('hub:copy-file-to-vault', async (_e, { srcPath, orderId }) => {
  const resolvedSrc = path.resolve(String(srcPath || ''));
  const allowedSrcDirs = [
    app.getPath('userData'),
    app.getPath('documents'),
    app.getPath('downloads'),
    app.getPath('desktop'),
    app.getPath('temp'),
  ];
  if (!allowedSrcDirs.some(d => resolvedSrc.startsWith(path.resolve(d) + path.sep) || resolvedSrc === path.resolve(d))) {
    return { ok: false, error: 'Source path is outside allowed directories' };
  }
  const src = resolvedSrc;
  const safeId = path.basename(String(orderId || '')).replace(/[^a-zA-Z0-9_-]/g, '_');
  const orderVaultDir = path.join(fileVaultDir(), safeId);
  if (!fs.existsSync(orderVaultDir)) fs.mkdirSync(orderVaultDir, { recursive: true });
  const filename = path.basename(src);
  const destPath = path.join(orderVaultDir, filename);
  fs.copyFileSync(src, destPath);
  const stat = await fs.promises.stat(destPath);
  return { destPath, filename, size: stat.size };
});
ipcMain.handle('hub:list-vault-files', async (_e, orderId) => {
  const safeId = path.basename(String(orderId || '')).replace(/[^a-zA-Z0-9_-]/g, '_');
  const orderVaultDir = path.join(fileVaultDir(), safeId);
  if (!fs.existsSync(orderVaultDir)) return [];
  const files = await fs.promises.readdir(orderVaultDir);
  return Promise.all(files.map(async (f) => {
    const fullPath = path.join(orderVaultDir, f);
    const stat = await fs.promises.stat(fullPath);
    return { filename: f, fullPath, size: stat.size };
  }));
});
ipcMain.handle('hub:delete-vault-file', async (_e, fullPath) => {
  const safe = path.resolve(String(fullPath || ''));
  const vaultRoot = path.resolve(fileVaultDir());
  // Path-confinement: only allow deletions inside the vault directory
  if (!safe.startsWith(vaultRoot + path.sep)) return false;
  // Report the truth. Swallowing the error and returning true removed the entry from the
  // UI and told the owner the file was deleted while it remained on disk — a locked file
  // on Windows, or a permissions error, both common. Khayt promises customers in the
  // intake notice that their data can be deleted on request, so a delete that only
  // pretends to succeed undermines that.
  try { await fs.promises.unlink(safe); } catch (e) {
    if (e && e.code === 'ENOENT') return true; // already gone — the desired end state
    console.error('hub:delete-vault-file:', e);
    return false;
  }
  return true;
});

/**
 * How big a print file may be to be READ AT ALL, where there used to be four
 * different answers.
 *
 *   hub:intake-model-bytes   150 MB   dropping a file on the calculator
 *   hub:parse-print-file      50 MB   Browse…, and every library import
 *   hub:printlib-read-bytes   60 MB   an STL's mesh, identity key, thumbnail
 *   hub:extract-thumbnail     50 MB   a 3MF's embedded picture
 *
 * Four numbers written at four different times for the same act of reading the
 * same file, so the same 60 MB STL was read when dropped and refused when
 * picked — while `hub:parse-print-file`, the one refusing it, carries a comment
 * saying Browse… and drag-drop "read the identical file through the identical
 * intake, and a shop should not get a different answer for having used a
 * different button".
 *
 * 150 MB is the number that was already in production on the busiest of the
 * four. Measured rather than assumed: lib/model-intake.js reads a 60 MB binary
 * STL (1.2M triangles) in 394 ms, and base64 for the IPC hop costs 8 ms to
 * encode and 14 ms to decode at that size. The low three were arbitrary, not
 * protective.
 *
 * The limit was never the whole bug. Every refusal here is shaped like an
 * answer — `{ok:false,…}` is truthy, `null` is what a missing file returns,
 * `empty` is what a 3MF with no thumbnail returns — and every caller read them
 * as answers, so a big file joined the library looking imported and holding
 * nothing. Whatever this number is, a refusal has to be able to SAY it is one.
 *
 * This is 1 GB and not 150 MB because reading stopped being expensive: see
 * MESH_ANALYSIS_MAX_BYTES below for the one operation that still is, and why it
 * is a SECOND number rather than this one lowered back down.
 */
const PRINT_FILE_MAX_BYTES = 1024 * 1024 * 1024;
const PRINT_FILE_MAX_LABEL = '1 GB';

/**
 * KEEPING every triangle is a different question from MEASURING the mesh, and
 * only one of them is expensive.
 *
 * Measuring is a running total: volume, area, bounding box and a count, folded
 * in one triangle at a time — see lib/stl-parse.js, where that loop stopped
 * materialising a list nobody had asked for. It costs the file buffer and
 * nothing else, which is why the ceiling above is now a generous bound on a
 * read rather than a limit on what can be understood.
 *
 * The overhang report and the rendered thumbnail are the two things that need
 * the triangles themselves, and a list of them costs roughly six times the
 * file's own size in heap. 150 MB is the number the drop-a-file path has been
 * running with in production all along, so it is the one with evidence behind
 * it.
 *
 * PAST THIS LINE THE FILE IS STILL READ. It gets its print time, weight,
 * material, volume, bounding box and identity key; what it does not get is the
 * picture and the overhang lines. Refusing the whole file because one optional
 * report is expensive is how a 200 MB model ended up unaddable — and this is a
 * separate number from the one above precisely so it cannot do that again.
 */
const MESH_ANALYSIS_MAX_BYTES = 150 * 1024 * 1024;

// --- 3.1: Print-file library (standalone, order-independent) ---
// A per-record subfolder under userData/print-files-vault/<id>/ holds the model
// file plus its generated thumbnail/photo. All handlers are path-confined to that
// root; nothing here touches the network (offline contract).
const PLL = require('./lib/print-library-location');
const PLM = require('./lib/print-library-migrate');
const PLT = require('./lib/print-library-tier');
const SPROV = require('./lib/storage-providers');
const GD = require('./lib/gdrive-client');
const ZIPR = require('./lib/zip-read');
const ZIPI = require('./lib/zip-intake');
const S3C = require('./lib/s3-client');

/** The built-in vault — where the library lived when it could only live here. */
const printLibDefaultRoot = () => ensureDir('print-files-vault');

/** settings.printLibrary, from main's live copy of the store, or off disk on the
 *  first call before the renderer has saved anything. */
function printLibSettings() {
  const cached = lanServerStore && lanServerStore.settings && lanServerStore.settings.printLibrary;
  if (cached) return cached;
  try { return readStoreDecryptedFromDisk()?.settings?.printLibrary || {}; } catch (_) { return {}; }
}

const printLibRoots = () => PLL.resolveRoots(printLibSettings(), printLibDefaultRoot());

/**
 * Can the library be written to right now?
 *
 * Probed rather than assumed: a share that was mounted at launch can be gone by
 * the time someone adds a file. Returns the verdict AND the folder, because a
 * message that does not name the folder sends the shop to the app's settings
 * when the problem is in the Finder.
 */
function printLibStatus() {
  const { primary, isCustom } = printLibRoots();
  // The built-in folder is ours to create; a folder the shop chose is not, and
  // silently creating it would hide a mistyped path or an unmounted share.
  if (!isCustom) { printLibDefaultRoot(); return { ok: true, reason: 'ok', root: primary }; }
  let probe = { exists: false, isDirectory: false, writable: false };
  try {
    const st = fs.statSync(primary);
    probe = { exists: true, isDirectory: st.isDirectory(), writable: false };
    fs.accessSync(primary, fs.constants.W_OK);
    probe.writable = true;
  } catch (_) { /* leave the probe as it stands */ }
  const v = PLL.verdict(probe);
  return { ok: v.ok, reason: v.reason, root: primary, error: PLL.explain(v.reason, primary) };
}

/** Throws a message worth showing when the library cannot be written to. */
function requirePrintLib() {
  const st = printLibStatus();
  if (!st.ok) throw new Error(st.error || 'The print library folder is unavailable.');
  return st.root;
}

// Reads do NOT go through requirePrintLib(). A read that throws when the share is
// away turns "no files here" into an unhandled rejection in every caller that
// merely wanted to know whether a record has a file. Writes refuse loudly;
// reads simply find nothing, and hub:printlib-status is what tells the shop why
// the library looks empty.
const printLibDir = () => printLibRoots().primary;
const printLibItemDir = (id) => path.join(printLibRoots().primary, PLL.itemDirName(id));

/** Is this path part of the library, wherever the library has ever lived? */
const printLibContains = (p) => PLL.insideLibrary(p, printLibRoots().roots);

/** The same record folder under the mirror, or null when no mirror is set. */
function printLibMirrorItemDir(id) {
  const { mirror } = printLibRoots();
  return mirror ? path.join(mirror, PLL.itemDirName(id)) : null;
}

/**
 * The saved object-storage config, with a broken endpoint healed on the way out.
 *
 * A shop that pasted its whole endpoint into the Region box saved an address
 * carrying the provider's suffix twice — one that resolves to nothing — with
 * `enabled: true`. There is no way for them to find out: the library simply
 * never syncs, and no screen says so. `varsFromPastedEndpoint` fixes the shop
 * that does it from now on, because it runs when the settings page SAVES; it
 * does nothing for the book that already holds the bad value, and nobody
 * reopens that tab to press Save on a feature they think is working.
 *
 * So it is healed where it is READ. `SPROV.repair` recomposes the address from
 * the provider and the variable it can recover, returns a working config
 * untouched, and returns anything it cannot make sense of exactly as it is
 * rather than replacing it with a guess.
 *
 * Read-time rather than a migration on load, because the same book is opened by
 * builds that do not have this fix and a migration would have to win a race
 * with them. Healing at the point of use cannot lose one.
 */
function printLibS3Settings() {
  return SPROV.repair((printLibSettings() || {}).s3 || {}) || {};
}

/** The bucket the library is backed up to, or null. */
function printLibS3() {
  const cfg = printLibS3Settings();
  if (!cfg || !cfg.enabled || !S3C.isConfigured(cfg)) return null;
  return { client: S3C.createS3(cfg), prefix: cfg.prefix || '', kind: 's3' };
}

/** The connected Google Drive, or null. */
// The Drive client, kept between calls.
//
// Not an optimisation so much as a correctness-of-cost thing: the client caches
// the access token and the folder id in its own closure, and printLibDrive() is
// called once PER FILE during a sweep. Building a fresh one each time would
// re-authenticate and re-find the folder for every model — three extra round
// trips per file, on the one operation that runs over the whole library.
//
// Keyed on the credentials so that reconnecting a different account, or turning
// Drive off, does not keep serving the old one.
let printLibDriveCache = { key: '', client: null };

function printLibDrive() {
  const cfg = (printLibSettings() || {}).gdrive;
  if (!cfg || !cfg.enabled || !GD.isConfigured(cfg)) return null;
  const key = `${cfg.clientId}\u0000${cfg.refreshToken}\u0000${cfg.folderName || ''}`;
  if (printLibDriveCache.key !== key) {
    printLibDriveCache = { key, client: GD.createDrive(cfg) };
  }
  return { client: printLibDriveCache.client, prefix: cfg.prefix || '', kind: 'gdrive' };
}

/**
 * Wherever this library's remote copy lives.
 *
 * S3 and Drive expose the same four methods over the same opaque keys, so
 * everything downstream — the mirror, the tiering sweep, rehydration — is
 * written once and does not know which it is holding. That is the entire reason
 * lib/gdrive-client.js bothers to imitate the S3 client's head() shape.
 *
 * Both configured is a real configuration and not an error: S3 for the off-site
 * backup, Drive for the storage the shop already pays for. The bucket wins,
 * because it is the one that was there first and the one a shop is more likely
 * to have sized for the whole library.
 */
function printLibRemote() {
  return printLibS3() || printLibDrive();
}

/**
 * Copy a file that was just written to wherever the shop keeps its backups.
 *
 * A folder and a bucket are the same job here — write-through, after the primary
 * has succeeded — so they share one function and one report. Both are
 * best-effort and NEITHER is ever read from: a backup you read from is a second
 * primary, and the two drift.
 *
 * Best-effort, but not silent. A backup that can fail a save is a second thing
 * to go wrong; a backup that fails without saying so is worse, because the shop
 * believes it has one. The primary write stands and the handler reports what
 * landed.
 *
 * @returns {null|{folder: boolean|null, s3: boolean|null}} null when no backup
 *   is configured at all.
 */
async function printLibMirrorFile(id, filename, srcPath) {
  const dir = printLibMirrorItemDir(id);
  const s3 = printLibRemote();
  if (!dir && !s3) return null;
  const out = { folder: null, s3: null };
  if (dir) {
    try {
      await fs.promises.mkdir(dir, { recursive: true });
      await fs.promises.copyFile(srcPath, path.join(dir, filename));
      out.folder = true;
    } catch (e) {
      console.error('printlib mirror (folder):', e.message);
      out.folder = false;
    }
  }
  if (s3) {
    try {
      // Read once, here, rather than streaming: these are model files, the
      // upload is already bounded by INTAKE_MAX_BYTES upstream, and a Buffer is
      // what keeps the bytes intact — a string round trip corrupts binary.
      const buf = await fs.promises.readFile(srcPath);
      await s3.client.put(S3C.objectKey(s3.prefix, id, filename), buf);
      out.s3 = true;
    } catch (e) {
      console.error('printlib mirror (s3):', e.message);
      out.s3 = false;
    }
  }
  return out;
}

// ── Tiering: keeping the library bigger than the disk ───────────────────────
// The mirror above frees nothing — it is a second copy, by design. Tiering is
// the other use for the same bucket: a cold model lives there ONLY, the local
// copy is deleted, and it comes back the first time anyone opens it.
//
// The rule that keeps this from losing models: nothing is deleted locally until
// the bucket has been asked, in its own round trip, and has answered with an
// etag matching the local content. Not "the upload returned 200" — that is the
// same call that would have failed. See lib/print-library-tier.js.

const printLibTierPolicy = () => PLT.normalisePolicy((printLibSettings() || {}).tier);

/**
 * Both digests in ONE pass over the file.
 *
 * They answer different questions — the MD5 is compared with the bucket's etag
 * to decide whether deleting is safe, the SHA-256 goes in the sidecar to check
 * the file that eventually comes back — but reading a 400 MB model twice to get
 * them separately doubles the slowest part of a sweep for no reason.
 */
function printLibDigests(p) {
  return new Promise((resolve, reject) => {
    const sha = crypto.createHash('sha256');
    const md5 = crypto.createHash('md5');
    const s = fs.createReadStream(p);
    s.on('error', reject);
    s.on('data', (d) => { sha.update(d); md5.update(d); });
    s.on('end', () => resolve({ sha256: sha.digest('hex'), md5: md5.digest('hex') }));
  });
}

/** The sidecars in one item folder, keyed by the filename each stands in for. */
async function printLibSidecarMap(dir) {
  const out = new Map();
  let names;
  try { names = await fs.promises.readdir(dir); } catch (_) { return out; }
  for (const n of names) {
    if (!PLT.isSidecar(n)) continue;
    try {
      const side = PLT.parseSidecar(await fs.promises.readFile(path.join(dir, n), 'utf8'));
      // An unreadable sidecar is deliberately NOT added. The base file then shows
      // as simply absent, which is the honest report: we have no verifiable
      // record of where it went, and claiming it is safely in the bucket would
      // be the one lie that costs a model.
      if (side) out.set(PLT.baseName(n), { ...side, fullPath: path.join(dir, PLT.baseName(n)) });
    } catch (_) { /* skip it; the file reads as missing rather than as safe */ }
  }
  return out;
}

/**
 * Put a file in the bucket and prove it arrived.
 *
 * Returns the digests as well, because the caller needs the SHA-256 for the
 * sidecar and computing it twice means reading the model twice.
 */
async function printLibEnsureInBucket(s3, id, filename, srcPath) {
  const key = S3C.objectKey(s3.prefix, id, filename);
  const { sha256, md5 } = await printLibDigests(srcPath);
  const local = (await fs.promises.stat(srcPath)).size;

  let head = null;
  try { head = await s3.client.head(key); } catch (e) { return { ok: false, error: `Could not reach the bucket: ${e.message}` }; }

  // Already there and provably identical — the mirror had done its job, and this
  // sweep costs nothing but a HEAD.
  if (head && head.size === local && PLT.etagVerdict(head.etag, md5) === 'match') {
    return { ok: true, key, sha256, uploaded: false };
  }

  try { await s3.client.put(key, await fs.promises.readFile(srcPath)); }
  catch (e) { return { ok: false, error: `Upload failed: ${e.message}` }; }

  // Ask again, as a separate request. A PUT that returns 200 through a proxy
  // that stored nothing is exactly the case this is here to catch.
  let after = null;
  try { after = await s3.client.head(key); } catch (e) { return { ok: false, error: `Could not confirm the upload: ${e.message}` }; }
  if (!after) return { ok: false, error: 'The bucket accepted the upload but does not have the file.' };
  if (after.size !== local) return { ok: false, error: `The bucket holds ${after.size} bytes, not ${local}.` };

  const verdict = PLT.etagVerdict(after.etag, md5);
  if (verdict === 'mismatch') return { ok: false, error: 'The bucket holds different bytes under this name.' };
  if (verdict === 'unusable') {
    // The bucket answered in a form that proves nothing — a multipart etag from
    // some other tool. Rather than delete on a size match alone, pay for the
    // download and check properly.
    try {
      const back = await s3.client.get(key);
      if (!back) return { ok: false, error: 'The bucket lost the file between two requests.' };
      if (crypto.createHash('sha256').update(back).digest('hex') !== sha256) {
        return { ok: false, error: 'The stored file does not match the local one.' };
      }
    } catch (e) { return { ok: false, error: `Could not verify the stored file: ${e.message}` }; }
  }
  return { ok: true, key, sha256, uploaded: true };
}

// One rehydrate per file. Opening a model from two places at once — the grid and
// the slicer button — would otherwise start two downloads writing the same path,
// and the loser truncates the winner's file.
const printLibRehydrating = new Map();

/**
 * Make sure a library path is actually on disk, fetching it back if it was tiered.
 *
 * Every read path goes through this. A file that is present, or that was never
 * tiered, costs one existsSync and nothing else — so this is safe to call on the
 * hot path.
 *
 * @returns {{ok: boolean, error?: string, restored?: boolean}}
 */
async function printLibRehydrate(fullPath) {
  const p = path.resolve(String(fullPath || ''));
  if (fs.existsSync(p)) return { ok: true, restored: false };

  const sidePath = p + PLT.SIDECAR_EXT;
  if (!fs.existsSync(sidePath)) return { ok: true, restored: false };  // simply not a library file we tiered

  if (printLibRehydrating.has(p)) return printLibRehydrating.get(p);
  const job = (async () => {
    let side;
    try { side = PLT.parseSidecar(await fs.promises.readFile(sidePath, 'utf8')); }
    catch (_) { side = null; }
    if (!side) return { ok: false, error: 'The record of this file in the cloud is unreadable.' };

    const s3 = printLibRemote();
    if (!s3) return { ok: false, error: 'This file is in cloud storage, but no bucket is configured. Add the credentials in Settings.' };

    let buf;
    try { buf = await s3.client.get(side.key); }
    catch (e) { return { ok: false, error: `Could not download the file: ${e.message}` }; }
    if (!buf) return { ok: false, error: 'The file is no longer in the bucket.' };

    const v = PLT.verifyRehydrate(side, buf.length, crypto.createHash('sha256').update(buf).digest('hex'));
    if (!v.ok) return { ok: false, error: v.error };

    // Write beside, then rename. A half-written model at the real path would be
    // indistinguishable from a whole one on the next open, and it would parse as
    // a corrupt mesh rather than as a failure.
    const tmp = `${p}.part-${process.pid}`;
    try {
      await fs.promises.mkdir(path.dirname(p), { recursive: true });
      await fs.promises.writeFile(tmp, buf);
      await fs.promises.rename(tmp, p);
    } catch (e) {
      try { await fs.promises.unlink(tmp); } catch (_) { /* nothing to clean up */ }
      return { ok: false, error: `Could not save the downloaded file: ${e.message}` };
    }
    // Only now is the sidecar redundant. Removing it earlier would, on a crash
    // mid-write, leave a file that is neither local nor known to be in the cloud.
    try { await fs.promises.unlink(sidePath); } catch (_) { /* it will be ignored anyway */ }
    return { ok: true, restored: true };
  })();

  printLibRehydrating.set(p, job);
  try { return await job; } finally { printLibRehydrating.delete(p); }
}

/**
 * Where the library is, and whether it can be reached right now.
 *
 * The renderer asks this to show the shop why the library looks empty, which is
 * the counterpart to writes failing loudly: refusing a save without ever saying
 * the NAS is unmounted just moves the confusion somewhere else.
 */
ipcMain.handle('hub:printlib-status', async () => {
  const { primary, mirror, isCustom, roots } = printLibRoots();
  const st = printLibStatus();
  let mirrorOk = null;
  if (mirror) {
    try { mirrorOk = fs.statSync(mirror).isDirectory(); } catch (_) { mirrorOk = false; }
  }
  const s3cfg = printLibS3Settings();
  const s3 = !!(s3cfg.enabled && S3C.isConfigured(s3cfg));
  return { ok: st.ok, reason: st.reason, error: st.error || '', root: primary, isCustom, mirror, mirrorOk, roots, s3, s3Bucket: s3 ? s3cfg.bucket : '' };
});

/** Choose a folder for the library, or for its mirror. */
/**
 * Prove the bucket works, with a real round trip.
 *
 * Credentials that look right and a bucket that refuses writes are
 * indistinguishable until the first model fails to upload — by which time the
 * shop believes it has a backup. Writes, reads back, compares, deletes.
 */
// ── Google Drive: connecting an account ─────────────────────────────────────
// The loopback flow, which is what Google requires of a desktop app: the consent
// screen opens in the shop's REAL browser, not an embedded window. Embedded
// webviews are blocked by Google outright, and rightly — the app hosting the
// window can read what is typed into it, so the shop has no way to tell a real
// consent screen from a convincing drawing of one.
//
// The redirect comes back to a server on 127.0.0.1 that exists for the seconds
// the flow takes, on a port the OS picks. Nothing is exposed off this machine.

/** Ten minutes. Long enough to find a password, short enough not to sit open. */
const GDRIVE_AUTH_TIMEOUT_MS = 600000;

/**
 * Run one consent flow and return the tokens.
 *
 * @returns {Promise<{ok: boolean, refreshToken?: string, error?: string}>}
 */
function gdriveAuthorize(cfg) {
  return new Promise((resolve) => {
    const http = require('node:http');
    const { verifier, challenge } = GD.pkcePair();
    // Binds the redirect to THIS attempt. Without it the loopback server would
    // accept any code delivered to it, including one a local process obtained
    // for a different account.
    const state = crypto.randomBytes(16).toString('hex');
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { server.close(); } catch (_) { /* already closing */ }
      resolve(result);
    };

    const page = (title, body) => `<!doctype html><meta charset="utf-8">`
      + `<title>${title}</title><body style="font-family:system-ui;padding:3rem;max-width:32rem;margin:auto">`
      + `<h2>${title}</h2><p>${body}</p></body>`;

    const server = http.createServer(async (req, res) => {
      let url;
      try { url = new URL(req.url, 'http://127.0.0.1'); } catch (_) { res.writeHead(400).end(); return; }
      if (url.pathname !== '/callback') { res.writeHead(404).end(); return; }

      const err = url.searchParams.get('error');
      const code = url.searchParams.get('code');
      const gotState = url.searchParams.get('state');

      const reply = (title, body) => {
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        res.end(page(title, body));
      };

      if (err) { reply('Not connected', `Google reported: ${String(err).replace(/[<>&]/g, '')}`); finish({ ok: false, error: String(err) }); return; }
      // Compared before the code is spent, and in constant time — a timing
      // oracle on the state is a way to have a code redeemed by something else.
      const a = Buffer.from(String(gotState || ''));
      const b = Buffer.from(state);
      if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
        reply('Not connected', 'That sign-in did not come from Khayt. Nothing was changed.');
        finish({ ok: false, error: 'The sign-in response did not match this request.' });
        return;
      }
      if (!code) { reply('Not connected', 'Google did not return an authorisation code.'); finish({ ok: false, error: 'No authorisation code.' }); return; }

      try {
        const tok = await GD.exchangeCode(globalThis.fetch, {
          clientId: cfg.clientId, clientSecret: cfg.clientSecret, code, verifier, redirectUri,
        });
        if (!tok.refresh_token) {
          // Almost always a re-consent where Google reuses the earlier grant.
          // Naming the fix is the difference between a shop solving this in a
          // minute and filing a bug.
          reply('Almost there', 'Google did not issue a refresh token. Remove Khayt at myaccount.google.com → Security → Third-party access, then connect again.');
          finish({ ok: false, error: 'Google did not issue a refresh token. Remove Khayt from your Google account\'s third-party access and try again.' });
          return;
        }
        reply('Connected', 'Khayt can now use your Google Drive. You can close this tab.');
        finish({ ok: true, refreshToken: String(tok.refresh_token) });
      } catch (e) {
        reply('Not connected', String(e.message || e).replace(/[<>&]/g, ''));
        finish({ ok: false, error: String(e.message || e) });
      }
    });

    const timer = setTimeout(() => finish({ ok: false, error: 'Timed out waiting for the browser sign-in.' }), GDRIVE_AUTH_TIMEOUT_MS);
    let redirectUri = '';
    server.on('error', (e) => finish({ ok: false, error: `Could not start the sign-in listener: ${e.message}` }));
    // Port 0 = let the OS choose a free one. 127.0.0.1 rather than localhost,
    // which can resolve to ::1 and produce a redirect_uri Google will not match.
    server.listen(0, '127.0.0.1', () => {
      redirectUri = `http://127.0.0.1:${server.address().port}/callback`;
      shell.openExternal(GD.authUrl({ clientId: cfg.clientId, redirectUri, challenge, state }))
        .catch((e) => finish({ ok: false, error: `Could not open the browser: ${e.message}` }));
    });
  });
}

// One flow at a time. Two open consent screens race to write the same token, and
// the shop cannot tell which account they ended up connected to.
let gdriveConnecting = false;

ipcMain.handle('hub:gdrive-connect', async () => {
  if (gdriveConnecting) return { ok: false, error: 'A Google sign-in is already open.' };
  gdriveConnecting = true;
  try {
    const cfg = (printLibSettings() || {}).gdrive || {};
    if (!String(cfg.clientId || '').trim()) {
      return { ok: false, error: 'Add the OAuth client ID from your Google Cloud project first.' };
    }
    const r = await gdriveAuthorize(cfg);
    if (!r.ok) return r;
    // Handed back for the renderer to save through the ordinary settings path,
    // so it goes through store-io's encryption like every other credential
    // rather than getting its own way of reaching the disk.
    return { ok: true, refreshToken: r.refreshToken };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e) };
  } finally { gdriveConnecting = false; }
});

/**
 * Who is connected, and is the account actually usable.
 *
 * Round-trips to Drive rather than reporting on the presence of a token: a
 * revoked grant looks exactly like a working one from the settings file, and the
 * shop would find out when a sweep deleted nothing.
 */
ipcMain.handle('hub:gdrive-status', async () => {
  const cfg = (printLibSettings() || {}).gdrive || {};
  if (!GD.isConfigured(cfg)) return { ok: true, connected: false };
  try {
    const about = await GD.createDrive(cfg).about();
    return { ok: true, connected: true, ...about };
  } catch (e) {
    return { ok: true, connected: false, error: String((e && e.message) || e) };
  }
});

/**
 * The provider presets, for the Settings dropdown.
 *
 * Over IPC rather than a renderer script because the table is main-side data the
 * endpoint builder also uses, and two copies of it would drift — the renderer
 * offering a provider main cannot resolve is exactly the bug the presets exist
 * to prevent.
 */
ipcMain.handle('hub:storage-providers', async () => {
  const endpoint = printLibS3Settings().endpoint || '';
  const current = SPROV.detect(endpoint);
  return {
    providers: SPROV.list(),
    pricedOn: SPROV.PRICED_ON,
    current,
    // The account id / region already in use, pulled back out of the saved
    // endpoint. Without this the fields render empty and saving any other
    // setting on the page would overwrite a working endpoint with a broken one.
    vars: current ? SPROV.extractVars(current, endpoint) : {},
    endpoint,
  };
});

/**
 * Turn a provider choice plus its variables into an endpoint.
 *
 * Over IPC rather than duplicated in the renderer: two copies of the table is
 * how the dropdown ends up offering a provider main cannot resolve, which is the
 * exact class of bug the presets were added to remove.
 */
ipcMain.handle('hub:storage-resolve-endpoint', async (_e, { provider, vars } = {}) => (
  SPROV.resolveEndpoint(provider, vars || {})
));

ipcMain.handle('hub:printlib-s3-test', async () => {
  const cfg = printLibS3Settings();
  if (!cfg || !S3C.isConfigured(cfg)) return { ok: false, error: 'Fill in the endpoint, bucket, key and secret first.' };
  const key = S3C.objectKey(cfg.prefix || '', '_khayt-check', `probe-${Date.now().toString(36)}.bin`);
  const payload = crypto.randomBytes(64);
  const s3 = S3C.createS3(cfg);
  try {
    await s3.put(key, payload);
    const back = await s3.get(key);
    await s3.del(key);
    if (!back || !Buffer.from(back).equals(payload)) {
      return { ok: false, error: 'The bucket accepted the file but returned something different.' };
    }
    return { ok: true, bucket: cfg.bucket, endpoint: cfg.endpoint };
  } catch (e) {
    try { await s3.del(key); } catch (_) { /* nothing to clean up */ }
    return { ok: false, error: String((e && e.message) || e) };
  }
});

/**
 * Every model in the library, with the id of the record it belongs to.
 *
 * Tiering needs the id because that is what the object key is built from, so
 * this cannot reuse printLibWalk's relative paths — a file two folders deep
 * under a record still belongs to that record.
 */
async function printLibAllFiles() {
  const root = printLibRoots().primary;
  const out = [];
  let dirs;
  try { dirs = await fs.promises.readdir(root, { withFileTypes: true }); } catch (_) { return out; }
  for (const d of dirs) {
    if (!d.isDirectory()) continue;
    const dir = path.join(root, d.name);
    let names;
    try { names = await fs.promises.readdir(dir); } catch (_) { continue; }
    for (const n of names) {
      if (n === '.DS_Store') continue;
      const full = path.join(dir, n);
      try {
        const st = await fs.promises.stat(full);
        if (!st.isFile()) continue;
        out.push({ id: d.name, filename: n, fullPath: full, size: st.size, mtimeMs: st.mtimeMs });
      } catch (_) { /* raced with a delete */ }
    }
  }
  return out;
}

/**
 * What a sweep would free, without touching anything.
 *
 * A preview, not a plan to execute later — the run re-scans, for the same reason
 * the migration does: acting on a list gathered minutes ago evicts files the
 * shop has since opened.
 */
ipcMain.handle('hub:printlib-tier-scan', async () => {
  try {
    const policy = printLibTierPolicy();
    const s3 = printLibRemote();
    const files = await printLibAllFiles();
    const p = PLT.plan(files, policy, Date.now());
    const tiered = files.filter((f) => PLT.isSidecar(f.filename)).length;
    return {
      ok: true,
      configured: !!s3,
      enabled: policy.enabled,
      keepDays: policy.keepDays,
      count: p.candidates.length,
      bytes: p.bytes,
      human: PLT.formatBytes(p.bytes),
      skipped: p.skipped,
      alreadyTiered: tiered,
    };
  } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
});

// One at a time, for the same reason the migration is: two sweeps over the same
// files would each be deleting what the other is still verifying.
let printLibSweeping = false;

/**
 * Upload, verify, then delete — in that order, per file, with the verification
 * as its own round trip.
 *
 * Per file rather than in phases: a sweep that uploaded everything and then
 * deleted everything would, if interrupted between the phases, leave the shop
 * paying for a full second copy with nothing freed. Doing one file end to end
 * means an interrupted sweep is just a shorter sweep.
 */
ipcMain.handle('hub:printlib-tier-run', async (event) => {
  if (printLibSweeping) return { ok: false, error: 'A cleanup is already running.' };
  printLibSweeping = true;
  try {
    const policy = printLibTierPolicy();
    if (!policy.enabled) return { ok: false, error: 'Cloud tiering is switched off.' };
    const s3 = printLibRemote();
    if (!s3) return { ok: false, error: 'No object storage is configured. Add the bucket details first.' };
    requirePrintLib();

    const p = PLT.plan(await printLibAllFiles(), policy, Date.now());
    const send = (m) => { try { event.sender.send('hub:printlib-tier-progress', m); } catch (_) { /* window gone */ } };

    let freed = 0;
    let done = 0;
    const failed = [];
    for (const f of p.candidates) {
      send({ phase: 'file', filename: f.filename, done, total: p.candidates.length });
      const r = await printLibEnsureInBucket(s3, f.id, f.filename, f.fullPath);
      if (!r.ok) { failed.push({ filename: f.filename, error: r.error }); continue; }

      // The sidecar is written BEFORE the model is removed. Crash between the
      // two and the shop has a redundant sidecar next to a file that is still
      // there — which mergeListing already treats as present. The other order
      // loses the model on the same crash.
      const side = PLT.makeSidecar({
        size: f.size, sha256: r.sha256, key: r.key,
        provider: printLibS3Settings().endpoint || '', at: new Date().toISOString(),
      });
      try {
        await fs.promises.writeFile(f.fullPath + PLT.SIDECAR_EXT, JSON.stringify(side));
        await fs.promises.unlink(f.fullPath);
      } catch (e) { failed.push({ filename: f.filename, error: String(e.message || e) }); continue; }

      freed += f.size;
      done += 1;
    }
    send({ phase: 'done', done, total: p.candidates.length });
    return {
      ok: true, moved: done, freed, human: PLT.formatBytes(freed),
      failed, attempted: p.candidates.length,
    };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e) };
  } finally { printLibSweeping = false; }
});

/**
 * Pull everything back down — the way out of tiering.
 *
 * A shop that changes its mind, or is leaving Khayt, must be able to get its
 * models back onto a disk it controls without knowing what an object key is. A
 * feature that deletes local files and has no reverse is a trap.
 */
ipcMain.handle('hub:printlib-tier-restore-all', async (event) => {
  if (printLibSweeping) return { ok: false, error: 'A cleanup is already running.' };
  printLibSweeping = true;
  try {
    requirePrintLib();
    const files = await printLibAllFiles();
    const sidecars = files.filter((f) => PLT.isSidecar(f.filename));
    const send = (m) => { try { event.sender.send('hub:printlib-tier-progress', m); } catch (_) { /* window gone */ } };
    let done = 0;
    const failed = [];
    for (const s of sidecars) {
      const target = s.fullPath.slice(0, -PLT.SIDECAR_EXT.length);
      send({ phase: 'file', filename: path.basename(target), done, total: sidecars.length });
      const r = await printLibRehydrate(target);
      if (r.ok) done += 1; else failed.push({ filename: path.basename(target), error: r.error });
    }
    send({ phase: 'done', done, total: sidecars.length });
    return { ok: true, restored: done, failed, attempted: sidecars.length };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e) };
  } finally { printLibSweeping = false; }
});

/**
 * Every file under a root, as paths relative to it.
 *
 * Relative, because that is what makes the destination obvious: the same
 * relative path under the new root. Item folders hold thumbnails and photos
 * beside the models, and nothing here needs to know which is which.
 */
async function printLibWalk(root, rel = '', out = []) {
  let entries;
  try {
    entries = await fs.promises.readdir(path.join(root, rel), { withFileTypes: true });
  } catch (_) { return out; }              // an unmounted share scans as empty
  for (const e of entries) {
    if (e.name === '.DS_Store') continue;
    const childRel = rel ? path.join(rel, e.name) : e.name;
    if (e.isDirectory()) { await printLibWalk(root, childRel, out); continue; }
    if (!e.isFile()) continue;             // symlinks are not ours to relocate
    try {
      const st = await fs.promises.stat(path.join(root, childRel));
      out.push({ root, rel: childRel, size: st.size });
    } catch (_) { /* vanished mid-scan */ }
  }
  return out;
}

/** Streamed, because a library holds files far larger than we want in memory. */
function printLibHashFile(p) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    const s = fs.createReadStream(p);
    s.on('error', reject);
    s.on('data', (d) => h.update(d));
    s.on('end', () => resolve(h.digest('hex')));
  });
}

/** Free bytes on the volume holding a path, or null when we cannot tell. */
async function printLibFreeSpace(dir) {
  try {
    const st = await fs.promises.statfs(dir);       // Node 18.15+
    return Number(st.bavail) * Number(st.bsize);
  } catch (_) { return null; }
}

/** The real filesystem, in the shape PLM.moveOne takes it. */
const printLibMoveIO = {
  hash: printLibHashFile,
  exists: async (p) => fs.existsSync(p),
  readdir: async (d) => { try { return await fs.promises.readdir(d); } catch (_) { return []; } },
  mkdir: (d) => fs.promises.mkdir(d, { recursive: true }),
  copy: (a, b) => fs.promises.copyFile(a, b),
  unlink: (p) => fs.promises.unlink(p),
};

/** Everything sitting somewhere the library no longer reads from. */
async function printLibStrandedFiles() {
  const { primary, mirror, roots } = printLibRoots();
  const from = PLM.sources(roots, primary, mirror);
  const items = [];
  for (const root of from) items.push(...await printLibWalk(root));
  return items;
}

/**
 * What is stranded, and whether it will fit.
 *
 * A preview, not a plan to execute later: the run re-scans. Acting on a list
 * gathered minutes ago would move files the shop has since deleted and miss the
 * ones they added.
 */
ipcMain.handle('hub:printlib-migrate-scan', async () => {
  try {
    const { primary } = printLibRoots();
    const items = await printLibStrandedFiles();
    const sum = PLM.summarize(items);
    const free = await printLibFreeSpace(path.dirname(primary));
    return { ok: true, ...sum, to: primary, space: PLM.enoughSpace(sum.bytes, free) };
  } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
});

// One at a time. Two runs over the same files would each see the other's
// half-finished copies, and "the destination already exists" is a branch that
// ends in a deleted source.
let printLibMigrating = false;

/**
 * Move the stranded files in.
 *
 * Copy, read back, compare hashes, and only then remove the source. Not rename:
 * across volumes it fails outright (EXDEV), and where it does work it leaves no
 * window in which to check that the bytes arrived. A copy that returns without
 * throwing is not proof — a short write to a share that dropped mid-transfer
 * does exactly that.
 *
 * Nothing is overwritten, and no source is removed unless its bytes are proven
 * to exist at the destination. Anything that fails is left exactly as it was
 * and reported by name.
 */
ipcMain.handle('hub:printlib-migrate-run', async (event) => {
  if (printLibMigrating) return { ok: false, error: 'A move is already running.' };
  printLibMigrating = true;
  const report = { ok: true, moved: 0, duplicates: 0, collisions: 0, failed: 0, bytes: 0, errors: [] };
  try {
    requirePrintLib();                                   // refuse before touching anything
    const { primary } = printLibRoots();
    const items = await printLibStrandedFiles();
    const space = PLM.enoughSpace(PLM.summarize(items).bytes, await printLibFreeSpace(path.dirname(primary)));
    if (!space.ok) {
      return { ok: false, error: `Not enough room in ${primary} — ${Math.ceil(space.shortBy / 1e6)} MB short.` };
    }
    const send = (p) => { try { event.sender.send('hub:printlib-migrate-progress', p); } catch (_) { /* window gone */ } };

    for (let i = 0; i < items.length; i += 1) {
      const it = items[i];
      const src = path.join(it.root, it.rel);
      send({ done: i, total: items.length, file: path.basename(it.rel) });
      try {
        const r = await PLM.moveOne(printLibMoveIO, src, path.join(primary, path.dirname(it.rel)), path.basename(it.rel));
        if (r.action === PLM.SAME) { report.duplicates += 1; continue; }
        if (r.action === PLM.COLLISION) report.collisions += 1;
        report.moved += 1;
        report.bytes += it.size;
      } catch (e) {
        report.failed += 1;
        report.errors.push(`${it.rel}: ${String((e && e.message) || e)}`);
      }
    }
    send({ done: items.length, total: items.length, file: '' });

    // Tidy the folders we emptied. Only ever empty ones, and never a root.
    for (const root of PLM.sources(printLibRoots().roots, primary, printLibRoots().mirror)) {
      const dirs = new Set(items.filter((i) => i.root === root).map((i) => path.dirname(i.rel)).filter((d) => d && d !== '.'));
      for (const d of dirs) {
        try { await fs.promises.rmdir(path.join(root, d)); } catch (_) { /* not empty, and that is fine */ }
      }
    }
    return report;
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e) };
  } finally {
    printLibMigrating = false;
  }
});

/**
 * Fold the root we are leaving into the ones this install remembers.
 *
 * The renderer owns the store, so it does the saving — but the decision lives in
 * a tested module rather than in four lines of renderer that nothing checks.
 * Called before the new root is saved, so printLibSettings() still reports the
 * old one. Pass '' to go back to the built-in folder.
 */
ipcMain.handle('hub:printlib-remember-root', async (_e, nextRoot) => (
  { history: PLM.rememberRoot(printLibSettings(), String(nextRoot || ''), printLibDefaultRoot()).history }
));

ipcMain.handle('hub:printlib-pick-folder', async (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const r = await dialog.showOpenDialog(win, {
    title: 'Choose a folder for the print library',
    properties: ['openDirectory', 'createDirectory'],
  });
  if (r.canceled || !r.filePaths.length) return null;
  const dir = r.filePaths[0];
  try {
    fs.accessSync(dir, fs.constants.W_OK);
  } catch (_) {
    return { ok: false, error: `No permission to write to ${dir}.` };
  }
  return { ok: true, path: dir };
});

/**
 * A name for a file inside a print record's vault folder.
 *
 * This was `model-<base36 timestamp>.<ext>`, which is unique only if two copies
 * never land in the same MILLISECOND. That held while every import made its own
 * record and therefore its own folder — but a print made of several files puts
 * them all in ONE folder, which is exactly the case that collides, and a
 * collision here is `copyFile` silently overwriting a part with another part.
 *
 * Derived from the file's own name instead, so it is unique BY CONSTRUCTION
 * rather than by timing, and so the vault is readable when somebody opens it:
 * `head.stl` beside `left-arm.stl` rather than two base36 stamps.
 *
 * Existing records keep whatever name they were stored under — this changes the
 * scheme for new files only, and nothing reads the shape of the old one.
 */
function vaultFilename(dir, originalName, ext) {
  const stem = String(originalName || '')
    .replace(/\.[^.]*$/, '')
    .replace(/[^\w\u0600-\u06FF .-]+/g, '')   // keep Arabic; drop separators and control chars
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 60)
    .replace(/^[.\s]+|[.\s]+$/g, '');
  const base = stem || 'model';
  let name = `${base}.${ext}`;
  for (let n = 2; fs.existsSync(path.join(dir, name)); n++) name = `${base}-${n}.${ext}`;
  return name;
}

ipcMain.handle('hub:printlib-pick-and-copy', async (event, id) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const result = await dialog.showOpenDialog(win, {
    title: 'Add print file',
    filters: [
      { name: '3D Print Files', extensions: ['stl', '3mf', 'obj', 'gcode', 'gco', 'zip'] },
      { name: 'All Files', extensions: ['*'] },
    ],
    properties: ['openFile'],
  });
  if (result.canceled || !result.filePaths.length) return null;
  const src = result.filePaths[0];
  const originalName = path.basename(src);
  const ext = path.extname(originalName).slice(1).toLowerCase() || 'bin';
  let contentHash = null;
  try { contentHash = modelContentHash(await fs.promises.readFile(src)); } catch (_) { contentHash = null; }
  requirePrintLib();                       // refuses, by name, before anything is copied
  const dir = printLibItemDir(id);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  const filename = vaultFilename(dir, originalName, ext);
  const destPath = path.join(dir, filename);
  await fs.promises.copyFile(src, destPath);
  const stat = await fs.promises.stat(destPath);
  const mirrored = await printLibMirrorFile(id, filename, destPath);
  return { filename, originalName, size: stat.size, ext, fullPath: destPath, contentHash, mirrored };
});

// Pick MANY print files at once — returns the chosen source paths (no copy). The renderer then copies
// each into its own record's vault via printlib-copy-path, reusing the drag-and-drop ingest path.
ipcMain.handle('hub:printlib-pick-multi', async (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const result = await dialog.showOpenDialog(win, {
    title: 'Add print files',
    filters: [
      { name: '3D Print Files', extensions: ['stl', '3mf', 'obj', 'gcode', 'gco', 'zip'] },
      { name: 'All Files', extensions: ['*'] },
    ],
    properties: ['openFile', 'multiSelections'],
  });
  if (result.canceled || !result.filePaths.length) return { ok: false };
  return { ok: true, paths: result.filePaths };
});

// Copy a KNOWN file path (e.g. from a drag-and-drop) into a record's vault — the no-dialog twin of
// pick-and-copy. Extension-gated to real print files so a stray drop can't smuggle in something else.
ipcMain.handle('hub:printlib-copy-path', async (_e, { id, srcPath } = {}) => {
  try {
    const src = path.resolve(String(srcPath || ''));
    if (!src || !fs.existsSync(src) || !fs.statSync(src).isFile()) return { ok: false, error: 'File not found.' };
    const originalName = path.basename(src);
    const ext = path.extname(originalName).slice(1).toLowerCase();
    if (!/^(stl|3mf|obj|gcode|gco)$/.test(ext)) return { ok: false, error: 'Not a print file (need STL, 3MF, OBJ or G-code).' };
    // Hash the SOURCE, before the copy. A file the shop already has should be
    // recognised without first writing a second copy of it into the library.
    let contentHash = null;
    try { contentHash = modelContentHash(await fs.promises.readFile(src)); } catch (_) { contentHash = null; }

    requirePrintLib();
    const dir = printLibItemDir(id);
    fs.mkdirSync(dir, { recursive: true });
    const filename = vaultFilename(dir, originalName, ext);
    const destPath = path.join(dir, filename);
    await fs.promises.copyFile(src, destPath);
    const stat = await fs.promises.stat(destPath);
    const mirrored = await printLibMirrorFile(id, filename, destPath);
    return { ok: true, filename, originalName, size: stat.size, ext, fullPath: destPath, contentHash, mirrored };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

/**
 * Unpack the print files from a .zip into a temp folder.
 *
 * Model packs arrive as archives — a Drive download, a Patreon bundle — and
 * every file had to be unzipped by hand and dragged in one at a time.
 *
 * This does NOT create records. It extracts, and the renderer then feeds each
 * file through hub:printlib-copy-path — the ordinary single-file intake, which
 * already hashes, names, mirrors and makes a record. So a six-part pack becomes
 * six records exactly as if they had been unzipped and dropped, which is the
 * hand work this removes, and there is still only one path that ingests a file.
 *
 * The first version of this wrote every member into ONE record's folder while
 * the renderer minted a record per file — leaving records 2..n pointing at files
 * inside record 1's directory, where deleting record 1 would take them.
 *
 * Two things it must not get wrong:
 *
 *   The name on disk comes from the PLAN, never from the zip member. That is the
 *   zip-slip defence — lib/zip-intake.js returns a basename with nothing left to
 *   traverse with, so path.join below cannot escape the temp folder.
 *
 *   Everything not extracted is reported. A budget or filter that drops files
 *   silently is the bug lib/mf-convert.js shipped once.
 */
ipcMain.handle('hub:printlib-unpack-zip', async (_e, { srcPath } = {}) => {
  try {
    const src = path.resolve(String(srcPath || ''));
    if (!src || !fs.existsSync(src) || !fs.statSync(src).isFile()) return { ok: false, error: 'File not found.' };
    if (!/\.zip$/i.test(src)) return { ok: false, error: 'Not a zip archive.' };

    requirePrintLib();                                  // refuse before reading a large file
    const buf = await fs.promises.readFile(src);
    const entries = ZIPR.listEntries(buf);              // never throws; [] on junk
    const plan = ZIPI.plan(entries);
    if (ZIPI.summarize(plan).empty) {
      return { ok: false, empty: true, skipped: plan.skipped,
        error: 'No STL, 3MF, OBJ or G-code files in that archive.' };
    }

    const os = require('os');   // not module-scoped in this file; see the requires at the top
    const dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'khayt-zip-'));
    const files = [];
    const failed = [];
    for (const t of plan.take) {
      let bytes = null;
      try { bytes = ZIPR.readEntry(buf, t.entry); } catch (_) { bytes = null; }
      // null for an unsupported method (zip64, encrypted) or a member over its
      // own cap. Named, not swallowed.
      if (!bytes) { failed.push(t.from); continue; }
      try {
        // t.name, NOT t.from — the plan's basename is the zip-slip defence.
        const dest = path.join(dir, t.name);
        await fs.promises.writeFile(dest, bytes);
        files.push({ path: dest, name: t.name, from: t.from });
      } catch (_) { failed.push(t.from); }
    }
    return { ok: files.length > 0, dir, files, failed,
      skipped: plan.skipped, truncated: plan.truncated };
  } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
});

/** Remove a folder made by hub:printlib-unpack-zip, once its files are in. */
ipcMain.handle('hub:printlib-unpack-cleanup', async (_e, dir) => {
  try {
    const os = require('os');
    const safe = path.resolve(String(dir || ''));
    // Confined to our own temp prefix: this deletes recursively, so it must be
    // impossible to point at anything else.
    if (!safe.startsWith(path.join(os.tmpdir(), 'khayt-zip-'))) return false;
    await fs.promises.rm(safe, { recursive: true, force: true });
    return true;
  } catch (_) { return false; }
});

ipcMain.handle('hub:printlib-list', async (_e, id) => {
  const dir = printLibItemDir(id);
  if (!fs.existsSync(dir)) return [];
  const files = await fs.promises.readdir(dir);
  const entries = [];
  for (const f of files) {
    if (PLT.isSidecar(f)) continue;                  // folded in below, under the name it stands for
    const fullPath = path.join(dir, f);
    try {
      const stat = await fs.promises.stat(fullPath);
      entries.push({ filename: f, fullPath, size: stat.size });
    } catch (_) { /* raced with a delete */ }
  }
  // A tiered model is listed exactly where it was, at its real size, flagged so
  // the row can say so. Dropping it would make "in the cloud" and "gone" look
  // identical to the person staring at the screen — and this listing has to keep
  // working with the bucket unreachable, which is why it reads sidecars off the
  // disk rather than asking the bucket what it holds.
  return PLT.mergeListing(entries, await printLibSidecarMap(dir));
});

ipcMain.handle('hub:printlib-delete', async (_e, fullPath) => {
  const safe = path.resolve(String(fullPath || ''));
  if (!printLibContains(safe)) return false; // confine to the library, wherever it lives
  // Report the truth, like hub:delete-vault-file. Swallowing the error and returning true
  // removed the entry from the library while the file stayed on disk.
  // A tiered file's local copy is a sidecar, not the model. Removing the model
  // has to remove that too, or the library keeps listing a file the shop
  // deleted and offers to download it.
  //
  // The OBJECT is deliberately left in the bucket. Mirroring and tiering write
  // the same key, so deleting it here would destroy the off-site backup of a
  // shop that runs both — and an orphaned object costs pennies where a deleted
  // backup costs the model. Settings' sweep reports what is orphaned.
  let removedSidecar = false;
  try {
    await fs.promises.unlink(safe + PLT.SIDECAR_EXT);
    removedSidecar = true;
  } catch (_) { /* the ordinary case: there was no sidecar */ }

  try {
    const stat = await fs.promises.stat(safe);
    if (stat.isDirectory()) await fs.promises.rm(safe, { recursive: true, force: true });
    else await fs.promises.unlink(safe);
  } catch (e) {
    if (e && e.code === 'ENOENT') return true; // already gone — the desired end state
    console.error('hub:printlib-delete:', e);
    return removedSidecar;                     // the tiered case: the sidecar WAS the file here
  }
  return true;
});

// Save a generated thumbnail / user photo (data URL from the renderer) into the item folder.
ipcMain.handle('hub:printlib-save-image', async (_e, { id, name, dataUrl } = {}) => {
  try {
    const m = /^data:image\/(png|jpe?g|webp);base64,([A-Za-z0-9+/=]+)$/.exec(String(dataUrl || ''));
    if (!m) return { ok: false, error: 'Unsupported image data' };
    requirePrintLib();
    const dir = printLibItemDir(id);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    const safeName = path.basename(String(name || 'img')).replace(/[^a-zA-Z0-9_.-]/g, '_');
    const dest = path.join(dir, safeName);
    await fs.promises.writeFile(dest, Buffer.from(m[2], 'base64'));
    return { ok: true, filename: safeName, fullPath: dest };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

/**
 * Write a record's thumbnail into its own vault folder AND PROVE IT LANDED.
 *
 * The picture is 94% of a print-file record — 914 bytes without it, 14,900 with
 * — and the store is one encrypted JSON document with a hard 50 MB ceiling. At
 * 5,000 files the thumbnails alone are 71 MB, past which every save is refused
 * and a shop loses its day at the next launch. On disk, 10,000 files is 8.9 MB.
 *
 * The write and the read-back are ONE call, in main, on purpose. The caller has
 * to drop its in-store copy to get the saving, and it must only do that on
 * proof — so the proof cannot be a second round trip the caller might skip,
 * mis-order, or lose to a reload in between. `verified` is true only when the
 * bytes were read back off the disk afterwards and match what went in.
 *
 * A failure returns {ok:false} and the caller keeps its copy. Nothing here ever
 * deletes anything.
 */
ipcMain.handle('hub:printlib-save-thumb', async (_e, { id, dataUrl } = {}) => {
  try {
    const m = /^data:image\/(png|jpe?g|webp);base64,([A-Za-z0-9+/=]+)$/.exec(String(dataUrl || ''));
    if (!m) return { ok: false, error: 'Unsupported image data' };
    const bytes = Buffer.from(m[2], 'base64');
    if (!bytes.length) return { ok: false, error: 'Empty image' };
    requirePrintLib();
    const dir = printLibItemDir(id);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    const filename = m[1] === 'png' ? 'thumb.png' : (m[1] === 'webp' ? 'thumb.webp' : 'thumb.jpg');
    const dest = path.join(dir, filename);
    await fs.promises.writeFile(dest, bytes);
    /* Read it back. A write that returned without throwing is not evidence the
     * file is there and whole: a full disk, a share that dropped mid-write and
     * a folder that was removed underneath all come back quiet. */
    let verified = false;
    try {
      const back = await fs.promises.readFile(dest);
      verified = back.length === bytes.length && back.equals(bytes);
    } catch (_) { verified = false; }
    return { ok: true, filename, verified };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

/**
 * Thumbnails for many records at once, by record id and filename.
 *
 * By ID rather than by path, because the library can be MOVED — see
 * lib/print-library-location.js — and a full path stored in a record would rot
 * the moment somebody pointed the vault at a different disk. Main resolves the
 * folder each time, so a moved library keeps its pictures.
 *
 * In one call rather than one per card: a thousand-card grid is a thousand IPC
 * round trips otherwise, which is the cost this whole change exists to avoid.
 */
ipcMain.handle('hub:printlib-load-thumbs', async (_e, wanted) => {
  const out = {};
  if (!Array.isArray(wanted)) return out;
  for (const item of wanted.slice(0, 400)) {
    const id = item && item.id;
    const file = item && item.file;
    if (!id || !file) continue;
    try {
      const safeName = path.basename(String(file));
      const full = path.join(printLibItemDir(id), safeName);
      if (!printLibContains(path.resolve(full))) continue;
      const buf = await fs.promises.readFile(full);
      const ext = path.extname(safeName).slice(1).toLowerCase();
      const mime = ext === 'png' ? 'image/png' : (ext === 'webp' ? 'image/webp' : 'image/jpeg');
      out[id] = `data:${mime};base64,${buf.toString('base64')}`;
    } catch (_) { /* a missing picture is a card with no picture, not an error */ }
  }
  return out;
});

// Load a saved image back as a data URL for display.
ipcMain.handle('hub:printlib-load-image', async (_e, fullPath) => {
  const safe = path.resolve(String(fullPath || ''));
  if (!printLibContains(safe)) return null;
  try {
    const buf = await fs.promises.readFile(safe);
    const ext = path.extname(safe).slice(1).toLowerCase();
    const mime = ext === 'png' ? 'image/png' : (ext === 'webp' ? 'image/webp' : 'image/jpeg');
    return `data:${mime};base64,${buf.toString('base64')}`;
  } catch (_) { return null; }
});

// Open a library model in the user's installed slicer GUI (detached — outlives us).
/**
 * Open a print in the slicer — ALL of it.
 *
 * Spiderman is a head, two arms and a torso, and opening him means opening the
 * four of them together. This took exactly one path, so a four-part print
 * opened its head and nothing else, and the only way to load the rest was four
 * more trips through the library.
 *
 * `filePaths` (a list) is the shape now; `filePath` still works and is what
 * every single-file caller sends. The list is spawned as ONE command with four
 * arguments rather than four commands: every slicer that takes a file on the
 * command line takes several, and four `spawn`s would be four slicer windows
 * each holding one limb.
 *
 * Every path is checked and rehydrated before ANY of them launches. A part that
 * is missing or stuck in the bucket stops the whole open and says which one —
 * a slicer that came up holding three quarters of a print, with the fourth
 * silently dropped, is how you print a Spiderman with one arm.
 */
ipcMain.handle('hub:printlib-open-in-slicer', async (_e, { filePath, filePaths, slicerPath } = {}) => {
  const wanted = (Array.isArray(filePaths) && filePaths.length ? filePaths : [filePath])
    .map((f) => String(f || '')).filter(Boolean);
  if (!wanted.length) return { ok: false, error: 'File not found.' };
  const safes = [];
  for (const w of wanted) {
    const safe = path.resolve(w);
    if (!printLibContains(safe)) return { ok: false, error: 'File is outside the library.' };
    // The slicer opens a path, so the bytes have to be there before it launches —
    // handing it a tiered file would open an empty window with no explanation.
    // The error is surfaced rather than folded into "File not found": "your bucket
    // credentials expired" and "you deleted this" need different responses.
    const back = await printLibRehydrate(safe);
    if (!back.ok) return { ok: false, error: back.error };
    if (!fs.existsSync(safe)) return { ok: false, error: `File not found: ${path.basename(safe)}` };
    safes.push(safe);
  }
  if (slicerPath && fs.existsSync(slicerPath) && isAllowedSlicerBinary(slicerPath)) {
    try {
      const { spawn } = require('node:child_process');
      const child = spawn(slicerPath, safes, { detached: true, stdio: 'ignore', windowsHide: false });
      child.on('error', () => {});
      child.unref();
      return { ok: true, opened: 'slicer', count: safes.length };
    } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
  }
  // No slicer configured — fall back to the OS default handler for the file type.
  try {
    for (const safe of safes) await shell.openPath(safe);
    return { ok: true, opened: 'os', count: safes.length };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// Read a library model file's raw bytes (base64) so the renderer can parse/render an
// STL preview. Confined to the library vault; capped so a giant file can't blow up IPC.
/**
 * Returns {ok:true, b64} or {ok:false, reason}, and used to return a bare string
 * or `null`.
 *
 * `null` meant four different things — not in the library, gone from the tier it
 * was moved to, unreadable, or simply bigger than the old 60 MB ceiling — and
 * the one caller wrote `if (b64)`, so all four skipped the mesh, the geometry
 * key and the thumbnail with nothing said. A big STL joined the library as an
 * icon with no numbers and no reason given, which is indistinguishable from an
 * import that quietly did not work.
 *
 * Only one caller (renderer/printfiles.js enrichPrintFile), so the shape is
 * changed rather than a second signal bolted on.
 */
ipcMain.handle('hub:printlib-read-bytes', async (_e, fullPath) => {
  const safe = path.resolve(String(fullPath || ''));
  if (!printLibContains(safe)) return { ok: false, reason: 'unavailable' };
  // Tiered? Fetch it back first. This returns immediately for the overwhelming
  // majority of calls, where the file is simply present.
  const back = await printLibRehydrate(safe);
  if (!back.ok) return { ok: false, reason: 'unavailable' };
  try {
    const stat = await fs.promises.stat(safe);
    // The mesh budget, not the read budget: these bytes cross IPC as base64 and
    // become a triangle list in the renderer, purely to draw a picture.
    if (stat.size > MESH_ANALYSIS_MAX_BYTES) return { ok: false, reason: 'too-large' };
    const buf = await fs.promises.readFile(safe);
    return { ok: true, b64: buf.toString('base64') };
  } catch (_) { return { ok: false, reason: 'unavailable' }; }
});

// The expensive 3MF/STL work now lives in lib/mf-jobs.js and normally runs in a
// utilityProcess (lib/mf-worker.js) so it can't stop the thread drawing the app.
// mfRun() below is the client every 3MF handler goes through.
const mfJobs = require('./lib/mf-jobs');

// ── the converter's worker process ──────────────────────────────────────────
// One long-lived utilityProcess, forked on first use and reused. Jobs are correlated by
// id, so several can be in flight; the child answers them in order and none of them are
// on this thread.
//
// If the fork fails, jobs run HERE instead — the app converts exactly as it did before,
// freeze and all, rather than losing the feature to a process that wouldn't start. Same
// code either way (lib/mf-jobs.js), so the fallback can't drift from the real path.
//
// The bookkeeping moved to lib/mf-client.js so it could be tested: living here, it
// shipped without a guard for a child that HANGS rather than exits, which left the
// renderer waiting on a promise that would never settle. See test/mf-client.test.js.
const mfClient = require('./lib/mf-client').createMfClient({
  fork: () => utilityProcess.fork(path.join(__dirname, 'lib', 'mf-worker.js'), [], {
    serviceName: 'khayt-3mf',
    stdio: 'ignore',
  }),
  inline: (op, args) => mfJobs.run(op, args),
  onWarn: (m) => { try { console.warn('[3mf]', m); } catch (_) {} },
});

/** Run a lib/mf-jobs op off this thread, or on it if there's no child to run it on. */
function mfRun(op, args) {
  return mfClient.run(op, args);
}

app.on('will-quit', () => { try { mfClient.dispose(); } catch (_) {} });
app.on('will-quit', () => { try { releaseStoreOwnership(); } catch (_) {} });

/**
 * Jobs that produce a file write it to a temp path; this puts it where it belongs once the
 * destination is known (which, for a save dialog, is only after the work is done). Rename
 * when it can, copy when the temp and the destination are on different volumes.
 */
async function mfFinalize(tmpPath, finalPath) {
  try {
    await fs.promises.rename(tmpPath, finalPath);
  } catch (_) {
    await fs.promises.copyFile(tmpPath, finalPath);
    try { await fs.promises.unlink(tmpPath); } catch (_) {}
  }
}
function mfTempPath(ext) {
  return path.join(app.getPath('temp'), `khayt-3mf-${Date.now().toString(36)}-${Math.floor(Math.random() * 1e6).toString(36)}.${ext}`);
}
async function mfDiscard(tmpPath) {
  if (tmpPath) { try { await fs.promises.unlink(tmpPath); } catch (_) {} }
}

// Mesh for a print file in the vault (STL or 3MF). Confined to the vault, like read-bytes.
ipcMain.handle('hub:printlib-mesh', async (_e, fullPath) => {
  const safe = path.resolve(String(fullPath || ''));
  if (!printLibContains(safe)) return { ok: false };
  // The converter runs in a worker that only knows about paths, so a tiered file
  // has to be back on disk before the job is handed over.
  const back = await printLibRehydrate(safe);
  if (!back.ok) return { ok: false, error: back.error };
  try {
    const stat = await fs.promises.stat(safe);
    if (stat.size > 200_000_000) return { ok: false, error: 'too-large' };
    return await mfRun('mesh', { src: safe, maxBytes: 200_000_000 });
  } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
});

// ── 3MF converter (multi-printer) ───────────────────────────────────────────
// Reading is confined to the app's own folders + any source the user explicitly
// picked through our own open dialog (approved for this session).
//
// Writing is a SEPARATE question, and conflating the two was a hole. Writing needs
// consent for that destination: either the path came back from our own save dialog
// in this same call, or it sits under a folder the user chose in the output-folder
// picker. "The file happens to live somewhere we are allowed to read" is not consent
// to write there — see mfWriteAllowed below.
// A ceiling on the file we're willing to pull into memory at all. 200 MB turned out to be
// under what people actually download: a 229 MB multi-plate poster was refused at every
// converter entry point with "File is too large", which reads as a broken app rather than
// a deliberate limit. 600 MB clears that class of file. What the limit is really guarding —
// unbounded INFLATION — is bounded separately and much more tightly by mf-convert's member
// budget, and normalizing no longer inflates geometry at all.
const MF_MAX_BYTES = 600_000_000;
const approvedConvertSources = new Set();
const approvedConvertDirs = new Set(); // user-picked output folders (batch) — writes allowed under these
function mfAllowedDirs() {
  return [
    app.getPath('userData'), app.getPath('documents'), app.getPath('downloads'),
    app.getPath('desktop'), app.getPath('temp'),
  ].map((d) => path.resolve(d));
}
const convertPaths = require('./lib/convert-paths');

function mfReadAllowed(p) {
  return convertPaths.readAllowed(p, {
    approvedSources: approvedConvertSources,
    approvedDirs: approvedConvertDirs,
    appDirs: mfAllowedDirs(),
  });
}

/**
 * May the renderer have us WRITE here, without asking the user first?
 *
 * Only under a folder the user picked in the output-folder dialog — see
 * lib/convert-paths.js for why that is a different question from reading.
 *
 * Symlinks are resolved on the PARENT directory before the check, and a parent we
 * cannot resolve is refused rather than allowed: the destination file itself usually
 * does not exist yet (that is the point), so it is the directory that has to be real.
 * Without this, a link planted inside an approved output folder would carry the write
 * back out of it.
 */
function mfWriteAllowed(p) {
  const safe = path.resolve(String(p || ''));
  let realParent;
  try {
    realParent = fs.realpathSync(path.dirname(safe));
  } catch (_) {
    return false; // fail closed — an unresolvable destination is not an approved one
  }
  const target = path.join(realParent, path.basename(safe));
  const dirs = [];
  for (const d of approvedConvertDirs) {
    try { dirs.push(fs.realpathSync(d)); } catch (_) { /* dropped folder — no longer approved */ }
  }
  return convertPaths.writeAllowed(target, { approvedDirs: dirs });
}

/**
 * Ask the user where to put a finished file. The answer is theirs, so it needs no
 * further gate; returns null when they cancel.
 */
async function mfAskWhereToSave(sender, { defaultPath, filters }) {
  const win = BrowserWindow.fromWebContents(sender);
  const result = await dialog.showSaveDialog(win, { defaultPath, filters });
  if (result.canceled || !result.filePath) return null;
  return path.resolve(result.filePath);
}

ipcMain.handle('hub:mf-pick', async (_e) => {
  const win = BrowserWindow.fromWebContents(_e.sender);
  const result = await dialog.showOpenDialog(win, {
    filters: [{ name: '3MF model', extensions: ['3mf'] }], properties: ['openFile'],
  });
  if (result.canceled || !result.filePaths[0]) return { ok: false, canceled: true };
  const p = path.resolve(result.filePaths[0]);
  approvedConvertSources.add(p);
  return { ok: true, path: p, name: path.basename(p) };
});

// Multi-select 3MF picker for batch conversion.
ipcMain.handle('hub:mf-pick-multi', async (_e) => {
  const win = BrowserWindow.fromWebContents(_e.sender);
  const result = await dialog.showOpenDialog(win, {
    filters: [{ name: '3MF model', extensions: ['3mf'] }], properties: ['openFile', 'multiSelections'],
  });
  if (result.canceled || !result.filePaths.length) return { ok: false, canceled: true };
  const files = result.filePaths.map((fp) => path.resolve(fp));
  files.forEach((fp) => approvedConvertSources.add(fp));
  return { ok: true, files: files.map((fp) => ({ path: fp, name: path.basename(fp) })) };
});

// Output-folder picker for batch conversion (grants write access under the chosen dir).
ipcMain.handle('hub:mf-pick-outdir', async (_e) => {
  const win = BrowserWindow.fromWebContents(_e.sender);
  const result = await dialog.showOpenDialog(win, { properties: ['openDirectory', 'createDirectory'] });
  if (result.canceled || !result.filePaths[0]) return { ok: false, canceled: true };
  const dir = path.resolve(result.filePaths[0]);
  approvedConvertDirs.add(dir);
  return { ok: true, dir };
});

ipcMain.handle('hub:mf-analyze', async (_e, { path: srcPath } = {}) => {
  try {
    if (!srcPath || !mfReadAllowed(srcPath)) return { ok: false, error: 'File is outside an allowed folder.' };
    return await mfRun('analyze', { src: srcPath, maxBytes: MF_MAX_BYTES });
  } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
});

// Decimated mesh for a converter SOURCE file (STL or 3MF) — for the "what am I
// converting?" 3D preview. Same allow-list as analyze/convert (picked sources only).
ipcMain.handle('hub:convert-mesh', async (_e, { path: srcPath } = {}) => {
  try {
    if (!srcPath || !mfReadAllowed(srcPath)) return { ok: false, error: 'outside-allowed' };
    return await mfRun('mesh', { src: srcPath, maxBytes: MF_MAX_BYTES });
  } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
});

ipcMain.handle('hub:mf-convert', async (_e, { path: srcPath, targetId, mode, slotMap, outPath, intoVaultId, targetProfile, fullSpectrum, fsPhysical, fsPhysicalHex, filaments, process, bandSwap } = {}) => {
  try {
    if (!srcPath || !mfReadAllowed(srcPath)) return { ok: false, error: 'Source file is outside an allowed folder.' };
    // The converted file lands in temp first. The save dialog can only be answered after
    // the work is done, and a 228 MB result has no business travelling back down a pipe
    // just to be written out again from here.
    const tmp = mfTempPath('3mf');
    const r = await mfRun('convert', {
      src: srcPath, maxBytes: MF_MAX_BYTES, tmpOut: tmp,
      opts: { targetId, mode, slotMap, targetProfile, fullSpectrum, fsPhysical, fsPhysicalHex, filaments, process, bandSwap },
    });
    if (!r.ok) { await mfDiscard(tmp); return r; }

    // In-app destination: move the converted 3MF straight into a print-file
    // record's vault (userData/print-files-vault/<id>/), no save dialog.
    if (intoVaultId) {
      const dir = printLibItemDir(intoVaultId);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
      const tag = String(targetId || 'out').replace(/[^a-zA-Z0-9]/g, '').slice(0, 14) || 'out';
      const filename = `converted-${Date.now().toString(36)}-${tag}.3mf`;
      const dest = path.join(dir, filename);
      await mfFinalize(r.tmpPath, dest);
      const stat = await fs.promises.stat(dest);
      return { ok: true, vault: true, filename, ext: '3mf', size: stat.size, outPath: dest, report: r.report };
    }

    // A renderer-chosen destination is only honoured under a folder the user picked in
    // the output-folder dialog (batch conversion). Anything else asks.
    let finalPath = outPath ? path.resolve(String(outPath)) : null;
    if (finalPath && !mfWriteAllowed(finalPath)) {
      await mfDiscard(r.tmpPath);
      return { ok: false, error: 'Output path is outside the folder you chose for converted files.' };
    }
    if (!finalPath) {
      const base = path.basename(String(srcPath)).replace(/\.3mf$/i, '') + `-${targetId || 'converted'}.3mf`;
      finalPath = await mfAskWhereToSave(_e.sender, {
        defaultPath: base, filters: [{ name: '3MF model', extensions: ['3mf'] }],
      });
      if (!finalPath) { await mfDiscard(r.tmpPath); return { ok: false, canceled: true }; }
    }
    await mfFinalize(r.tmpPath, finalPath);
    return { ok: true, outPath: finalPath, report: r.report };
  } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
});

// Filament presets from the maker's installed Snapmaker Orca / OrcaSlicer, for the converter's
// per-slot "what's loaded" picker. Empty list → the converter falls back to "Generic <type>".
ipcMain.handle('hub:orca-filaments', async () => {
  try {
    const db = require('./lib/orca-db');
    return { ok: true, available: db.available(), filaments: db.listU1Filaments(),
      processes: db.listU1Processes(), defaultProcess: db.defaultU1Process() };
  } catch (e) { return { ok: false, available: false, filaments: [], processes: [], error: String((e && e.message) || e) }; }
});

// The maker's installed-slicer printer catalogue (Snapmaker Orca + OrcaSlicer), for the converter's
// "target any printer" list. Names only — cheap; details resolved on selection via hub:orca-machine-info.
ipcMain.handle('hub:orca-printers', async () => {
  try { const db = require('./lib/orca-db'); return { ok: true, available: db.available(), printers: db.listMachines() }; }
  catch (e) { return { ok: false, available: false, printers: [], error: String((e && e.message) || e) }; }
});

// Resolved details (bed, nozzle, colour slots, process presets) for one catalogue printer.
ipcMain.handle('hub:orca-machine-info', async (_e, { name } = {}) => {
  try {
    const db = require('./lib/orca-db');
    const n = String(name || '');
    return { ok: true, info: db.machineInfo(n), processes: db.listProcessesFor(n), defaultProcess: db.defaultProcessFor(n) };
  } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
});

// Full Spectrum plan preview: which filaments load physically + how the extra colours are mixed.
ipcMain.handle('hub:fs-plan', async (_e, { path: srcPath, targetId, targetProfile, fsPhysical, fsPhysicalHex } = {}) => {
  try {
    if (!srcPath || !mfReadAllowed(srcPath)) return { available: false, error: 'Source file is outside an allowed folder.' };
    return await mfRun('fsPlan', { src: srcPath, maxBytes: MF_MAX_BYTES, opts: { targetId, targetProfile, fsPhysical, fsPhysicalHex } });
  } catch (e) { return { available: false, error: String((e && e.message) || e) }; }
});

// Colour-band analysis: is this painted model cleanly VERTICALLY banded, so a swap-capable printer can
// print every colour EXACTLY via M600 filament-swap pauses (instead of Full-Spectrum mixing)? Read-only.
ipcMain.handle('hub:mf-bands', async (_e, { path: srcPath, heads, pauseGcode } = {}) => {
  try {
    if (!srcPath || !mfReadAllowed(srcPath)) return { available: false, error: 'Source file is outside an allowed folder.' };
    // heads omitted → U1 4-head default (existing converter flow). heads:1 → single-extruder M600 plan.
    return await mfRun('bands', {
      src: srcPath, maxBytes: MF_MAX_BYTES,
      opts: { heads: heads || undefined, pauseGcode: pauseGcode || undefined },
    });
  } catch (e) { return { available: false, error: String((e && e.message) || e) }; }
});

// STL → 3MF: pick an STL and wrap its mesh into a clean generic 3MF any slicer opens.
ipcMain.handle('hub:stl-pick', async (_e) => {
  const win = BrowserWindow.fromWebContents(_e.sender);
  const result = await dialog.showOpenDialog(win, {
    filters: [{ name: 'STL model', extensions: ['stl'] }], properties: ['openFile'],
  });
  if (result.canceled || !result.filePaths[0]) return { ok: false, canceled: true };
  const p = path.resolve(result.filePaths[0]);
  approvedConvertSources.add(p);
  return { ok: true, path: p, name: path.basename(p) };
});

ipcMain.handle('hub:stl-to-3mf', async (_e, { path: srcPath, intoVaultId } = {}) => {
  try {
    if (!srcPath || !mfReadAllowed(srcPath)) return { ok: false, error: 'Source file is outside an allowed folder.' };
    const tmp = mfTempPath('3mf');
    const r = await mfRun('stlTo3mf', { src: srcPath, maxBytes: MF_MAX_BYTES, tmpOut: tmp });
    if (!r.ok) { await mfDiscard(tmp); return r; }
    const report = r.report;
    if (intoVaultId) {
      const dir = printLibItemDir(intoVaultId);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
      const filename = `stl2mf-${Date.now().toString(36)}.3mf`;
      const dest = path.join(dir, filename);
      await mfFinalize(r.tmpPath, dest);
      const stat = await fs.promises.stat(dest);
      return { ok: true, vault: true, filename, ext: '3mf', size: stat.size, outPath: dest, report };
    }
    const base = path.basename(String(srcPath)).replace(/\.stl$/i, '') + '.3mf';
    const finalPath = await mfAskWhereToSave(_e.sender, { defaultPath: base, filters: [{ name: '3MF model', extensions: ['3mf'] }] });
    if (!finalPath) { await mfDiscard(r.tmpPath); return { ok: false, canceled: true }; }
    await mfFinalize(r.tmpPath, finalPath);
    return { ok: true, outPath: finalPath, report };
  } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
});

// 3MF → STL: extract the raw mesh from a 3MF and save it as a binary STL.
ipcMain.handle('hub:mf-to-stl', async (_e, { path: srcPath } = {}) => {
  try {
    if (!srcPath || !mfReadAllowed(srcPath)) return { ok: false, error: 'Source file is outside an allowed folder.' };
    const tmp = mfTempPath('stl');
    const r = await mfRun('mfToStl', { src: srcPath, maxBytes: MF_MAX_BYTES, tmpOut: tmp });
    if (!r.ok) { await mfDiscard(tmp); return r; }
    const base = path.basename(String(srcPath)).replace(/\.3mf$/i, '') + '.stl';
    const finalPath = await mfAskWhereToSave(_e.sender, { defaultPath: base, filters: [{ name: 'STL model', extensions: ['stl'] }] });
    if (!finalPath) { await mfDiscard(r.tmpPath); return { ok: false, canceled: true }; }
    await mfFinalize(r.tmpPath, finalPath);
    return { ok: true, outPath: finalPath, triangleCount: r.triangleCount };
  } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
});

// HueForge → U1: build a zero-slicer Snapmaker-Orca 3MF from a solved heightfield + a
// per-band head plan (colour swaps encoded as layer_config_ranges). The relief is rebuilt
// in-process from the compact heightfield (lighter over IPC than the full triangle soup).
ipcMain.handle('hub:hf-export-3mf', async (_e, { heights, width, height, layerH, widthMm, bands, filaments, name, thumbPng, thumbSmallPng } = {}) => {
  try {
    if (!Array.isArray(heights) || !width || !height || !Array.isArray(bands) || !bands.length) return { ok: false, error: 'Nothing to export yet.' };
    const HF = require('./lib/hueforge');
    const HF3 = require('./lib/hueforge-3mf');
    const solve = { heights: Uint16Array.from(heights), width, height };
    const mesh = HF.heightfieldToMesh(solve, { layerH, widthMm });
    if (!mesh.triangleCount) return { ok: false, error: 'Empty model.' };
    const b64ToBuf = (b64) => { try { return b64 ? Buffer.from(String(b64), 'base64') : null; } catch (_) { return null; } };
    const buf = HF3.buildU1_3mf({
      triangles: mesh.triangles, bands, filaments, layerH, name, sizeMm: mesh.sizeMm, bed: { x: 270, y: 270 },
      thumbnailPng: b64ToBuf(thumbPng), thumbnailSmallPng: b64ToBuf(thumbSmallPng),
    });
    if (!buf) return { ok: false, error: 'Failed to build the 3MF.' };
    const base = String(name || 'hueforge').replace(/[^\w.-]+/g, '_') + '-U1.3mf';
    const finalPath = await mfAskWhereToSave(_e.sender, { defaultPath: base, filters: [{ name: '3MF model', extensions: ['3mf'] }] });
    if (!finalPath) return { ok: false, canceled: true };
    await fs.promises.writeFile(finalPath, buf);
    return { ok: true, outPath: finalPath, triangleCount: mesh.triangleCount, sizeMm: mesh.sizeMm };
  } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
});

// HueForge FLAT → U1: the toolchanger mode. Where the relief encodes colour as height and
// ships one mesh plus a Z-band table, this ships one mesh PART per colour, each tagged with
// its head, and no layer ranges at all.
//
// Only the label field crosses IPC, not the geometry. The renderer already computed it for
// the preview, and rebuilding the parts here from labels + palette is far cheaper than
// sending a triangle soup — the same reason the relief path sends a heightfield.
ipcMain.handle('hub:hf-export-flat-3mf', async (_e, { labels, palette, width, height, widthMm, heightMm, capMm, layerH, filaments, baseHead, name, thumbPng, thumbSmallPng } = {}) => {
  try {
    if (!Array.isArray(labels) || !labels.length || !Array.isArray(palette) || !palette.length || !width || !height) {
      return { ok: false, error: 'Nothing to export yet.' };
    }
    const FLAT = require('./lib/hueforge-flat');
    const HF3 = require('./lib/hueforge-3mf');
    const built = FLAT.buildFlatParts({ labels, palette, width, height }, { widthMm, heightMm, capMm });
    if (!built || !built.parts.length) return { ok: false, error: 'Empty model.' };
    const b64ToBuf = (b64) => { try { return b64 ? Buffer.from(String(b64), 'base64') : null; } catch (_) { return null; } };
    const buf = HF3.buildFlatU1_3mf({
      parts: built.parts,
      // The renderer's slot colours win when it sent them: they are what the maker pinned in
      // the stack. buildFlatParts' own palette is the quantiser's, which may differ.
      filaments: (Array.isArray(filaments) && filaments.length) ? filaments : built.filaments,
      sizeMm: built.sizeMm,
      baseHead: Number.isInteger(baseHead) ? baseHead : built.baseHead,
      layerH, name, bed: { x: 270, y: 270 },
      thumbnailPng: b64ToBuf(thumbPng), thumbnailSmallPng: b64ToBuf(thumbSmallPng),
    });
    if (!buf) return { ok: false, error: 'Failed to build the 3MF.' };
    const base = String(name || 'hueforge-flat').replace(/[^\w.-]+/g, '_') + '-flat-U1.3mf';
    const finalPath = await mfAskWhereToSave(_e.sender, { defaultPath: base, filters: [{ name: '3MF model', extensions: ['3mf'] }] });
    if (!finalPath) return { ok: false, canceled: true };
    await fs.promises.writeFile(finalPath, buf);
    return { ok: true, outPath: finalPath, partCount: built.parts.length, sizeMm: built.sizeMm };
  } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
});

// Extract an embedded preview + (3MF) colour/swap info from a print file. Local only.
ipcMain.handle('hub:extract-thumbnail', async (_e, filePath) => {
  const empty = { pngBase64: null, colors: [], swapCount: 0, source: null };
  const safe = path.resolve(String(filePath || ''));
  const allowed = [app.getPath('userData'), app.getPath('documents'), app.getPath('downloads'), app.getPath('desktop'), app.getPath('temp')];
  if (!allowed.some(d => safe.startsWith(path.resolve(d) + path.sep) || safe === path.resolve(d))) return empty;
  try {
    const ext = path.extname(safe).slice(1).toLowerCase();
    if (ext === 'gcode' || ext === 'gco') {
      const stat = fs.statSync(safe);
      const HEAD = 32 * 1024, TAIL = 64 * 1024;
      let text;
      if (stat.size <= HEAD + TAIL) text = fs.readFileSync(safe, 'latin1');
      else {
        const fd = fs.openSync(safe, 'r');
        try {
          const h = Buffer.alloc(HEAD), tb = Buffer.alloc(TAIL);
          fs.readSync(fd, h, 0, HEAD, 0);
          fs.readSync(fd, tb, 0, TAIL, stat.size - TAIL);
          text = h.toString('latin1') + '\n' + tb.toString('latin1');
        } finally { fs.closeSync(fd); }
      }
      return extractPrintThumb({ ext, text });
    }
    if (ext === '3mf') {
      const stat = fs.statSync(safe);
      // The fourth number that governed reading one print file. `empty` is a
      // legitimate answer here — plenty of 3MFs carry no thumbnail — so past
      // this line a big one was indistinguishable from a plain one, and the
      // caller had nothing to report. The mesh budget, because a picture is
      // exactly what this is: the file is read for its numbers either way.
      if (stat.size > MESH_ANALYSIS_MAX_BYTES) return Object.assign({}, empty, { tooLarge: true });
      return extractPrintThumb({ ext, buf: fs.readFileSync(safe) });
    }
  } catch (_) { /* silent */ }
  return empty;
});

// --- Feature 8: Auto-export status page ---
const statusPagesDir = () => ensureDir('status-pages');

async function migrateLegacyStatusPages() {
  const dir = statusPagesDir();
  let files;
  try {
    files = await fs.promises.readdir(dir);
  } catch {
    return;
  }
  for (const name of files) {
    if (!name.startsWith('order-status-') || !name.endsWith('.html')) continue;
    const fullPath = path.join(dir, name);
    try {
      const raw = await fs.promises.readFile(fullPath, 'utf8');
      const next = sanitizeHtmlForFile(redactStatusHtmlClientRow(raw));
      if (next !== raw) await fs.promises.writeFile(fullPath, next, 'utf8');
    } catch (e) {
      console.warn('migrateLegacyStatusPages:', name, e?.message || e);
    }
  }
}

ipcMain.handle('hub:verify-operator-pin', async (_event, { operatorId, pin } = {}) => {
  if (!lanServerStore?.operators?.length) syncLanServerStoreFromDisk();
  const op = (lanServerStore?.operators || []).find(o => o.id === operatorId);
  if (!op) return { ok: false, error: 'operator_not_found' };
  if (!op.pinHash) return { ok: true, noPin: true };
  // Verify against either the salted PBKDF2 format or a legacy SHA-256 hash.
  // Unrecognized formats (the very old base64 scheme) report legacy_pin so the
  // renderer re-prompts to set a fresh PIN.
  if (!isManagedHash(op.pinHash)) return { ok: false, error: 'legacy_pin' };
  const ok = verifyPin(String(pin || ''), op.pinHash);
  // A correct PIN against a LEGACY hash is the moment to replace it — the only
  // moment, because it is the only time the plaintext is in hand. See the note
  // on `hub:verify-pin`. The caller writes it; this cannot, because the store's
  // write chain is not here.
  return { ok, upgraded: ok && needsUpgrade(op.pinHash) ? hashPinSalted(String(pin || '')) : null };
});

// Hash a PIN/secret in the salted PBKDF2 format (renderer delegates here so all
// hashing uses Node crypto + a fresh salt).
ipcMain.handle('hub:hash-pin', async (_e, pin) => hashPinSalted(String(pin ?? '')));

// Verify a plaintext against a stored hash (salted PBKDF2 or legacy SHA-256),
// using the salt embedded in the stored hash. Used for admin-PIN + recovery-code.
//
// ── AND UPGRADE THE HASH WHILE THE PLAINTEXT IS IN HAND ──────────────────
//
// `lib/pin-hash.js` has always exported `needsUpgrade`, documented as "should
// this stored hash be upgraded to the salted format on next successful auth?".
// Nothing called it. So a shop that set its PIN before PBKDF2 shipped kept an
// unsalted SHA-256 hash for ever — verified happily on every unlock, upgraded
// never — and a four-to-eight digit PIN under unsalted SHA-256 is a lookup, not
// a search. That hash travels in backups and through cloud sync.
//
// A successful verify is the only moment the plaintext exists, so it is the
// only moment an upgrade is possible. The new hash is RETURNED rather than
// written: this handler does not know which record the caller read it from —
// an operator's `pinHash`, `settings.recoveryCodeHash` — and guessing would be
// worse than handing it back to the one place that does know.
ipcMain.handle('hub:verify-pin', async (_e, plain, stored) => {
  const ok = verifyPin(String(plain ?? ''), stored);
  return { ok, upgraded: ok && needsUpgrade(stored) ? hashPinSalted(String(plain ?? '')) : null };
});

ipcMain.handle('hub:write-status-page', async (_event, { html, orderId }) => {
  const safeId = path.basename(String(orderId || '')).replace(/[^a-zA-Z0-9_-]/g, '_');
  const dir = statusPagesDir();
  const fullPath = path.join(dir, `order-status-${safeId}.html`);
  await fs.promises.writeFile(fullPath, sanitizeHtmlForFile(html), 'utf8');
  return fullPath;
});

// Shared with LAN API live telemetry endpoint (hub:start-printer-polling fills this)
let printerStatusCache = {};

/**
 * Keep a finished job's measured figures across a restart.
 *
 * captureCompletion freezes filament and duration on the edge out of printing,
 * because the printer's counters reset when the next job starts. It froze them
 * into memory, so the window a measurement actually survived was not the 24
 * hours prefillActuals offers it for — it was "until Khayt is next quit".
 *
 * Written under its OWN store key rather than onto the machine record. Machine
 * records are rebuilt from the edit form when a shop saves one, so a field
 * living there is dropped by any unrelated visit to that dialog — which is the
 * failure print-kits already had to carry a comment about for `settings`.
 *
 * Never fails a poll: a completion that cannot be written is one measurement
 * lost, and throwing here would cost the polling loop instead.
 */
const COMPLETIONS_KEY = 'printerCompletions';

async function persistCompletions() {
  try {
    // Read-modify-write INSIDE the write chain.
    //
    // This runs on a background timer and writes the WHOLE store back. Building
    // that write from a long-lived in-memory copy is how a save made in the
    // renderer thirty seconds ago gets overwritten by a snapshot taken before
    // it — the same shape as the restore bug in #708, arriving from a different
    // direction. Re-reading first narrowed that window; it did not close it,
    // because the in-memory copy is only refreshed after a write LANDS, so any
    // write already in flight was still invisible. updateStoreOnDisk takes the
    // read inside the chain, which closes it.
    const saved = completionsToPersist(printerStatusCache);
    await updateStoreOnDisk((cur) => ({ ...cur, [COMPLETIONS_KEY]: saved }));
  } catch (e) {
    console.error('persistCompletions:', e && e.message ? e.message : e);
  }
}

/** Put yesterday's finished jobs back, and NOTHING that was live at the time. */
function rehydrateCompletions() {
  try {
    // Polling can start before anything has populated the in-memory store, and
    // an empty one here would restore nothing at all — silently, which is the
    // shape of bug this whole change exists to remove. Same guard the operator
    // PIN handler already uses for the same reason.
    if (!lanServerStore || !Object.keys(lanServerStore).length) syncLanServerStoreFromDisk();
    const saved = (lanServerStore || {})[COMPLETIONS_KEY];
    const restored = restoreCompletions(saved);
    for (const [machineId, entry] of Object.entries(restored)) {
      // A poll that has already run since boot knows more than the disk does.
      if (printerStatusCache[machineId]) continue;
      printerStatusCache[machineId] = entry;
    }
  } catch (e) {
    console.error('rehydrateCompletions:', e && e.message ? e.message : e);
  }
}

const { registerLanServer } = require('./lib/lan-server');
registerLanServer({
  fs,
  ipcMain,
  BrowserWindow,
  safeJsonParse,
  syncLanServerStoreFromDisk,
  resolveStoreSecret,
  isStoreSecretMasked,
  migrateLanApiSecrets,
  ensureLanIntakeToken,
  ensureLanIntakePin,
  ensureLanCalendarToken,
  writeStoreToDisk,
  persistLanStoreUpdate,
  updateStoreOnDisk,
  getLanServerStore: () => lanServerStore,
  setLanServerStore(data) { lanServerStore = data; },
  getMainWindow: () => mainWindow,
  statusPagesDir,
  appRoot: __dirname,
  getPrinterStatusCache: () => printerStatusCache,
  // Injected rather than derived inside lan-server, which has no access to
  // Electron's app paths — and so tests can point it at a temp directory.
  receiptsDir,
});

/**
 * A mailto: may name a subject and a body. It may not name another recipient.
 *
 * The renderer builds these, and one of them interpolated a CLIENT'S EMAIL
 * without encoding it — an address the LAN intake form takes from anyone who can
 * reach it. `customer@example.com?bcc=attacker@evil.example` added a header to
 * the shop's own reply and copied it to a stranger, in a compose window that
 * looked normal. That is fixed where the URL is built; this refuses it here too,
 * because the main process should not open a recipient the shop cannot see.
 *
 * `cc` is refused as well: nothing in Khayt sends one, so its only appearance
 * would be an injected one.
 */
function mailtoHasNoHiddenRecipients(s) {
  const q = s.indexOf('?');
  if (q === -1) return true;                     // address only
  // A second '?' cannot appear in a correctly-encoded mailto, and an address
  // containing one is how the header gets in.
  if (s.indexOf('?', q + 1) !== -1) return false;
  let params;
  try { params = new URLSearchParams(s.slice(q + 1)); } catch { return false; }
  for (const key of params.keys()) {
    if (!/^(subject|body)$/i.test(key)) return false;
  }
  return true;
}

function isAllowedExternalUrl(s) {
  if (s.startsWith('mailto:')) return mailtoHasNoHiddenRecipients(s);
  if (s.startsWith('https://')) {
    try { return !isBlockedHost(new URL(s).hostname); } catch { return false; }
  }
  if (s.startsWith('http://')) {
    try {
      const h = new URL(s).hostname;
      if (/^localhost$/i.test(h)) return true;
      const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
      if (v4) {
        const a = +v4[1], b = +v4[2];
        if (a === 127) return true;
        if (a === 10) return true;
        if (a === 192 && b === 168) return true;
        if (a === 172 && b >= 16 && b <= 31) return true;
      }
    } catch { return false; }
  }
  return false;
}

// Resolved file:// URL of the app's own entry page. Navigation is locked to
// exactly this document — not just any file:// URL — so a compromised renderer
// cannot navigate to other local files and read them under the privileged origin.
const APP_INDEX_PATHNAME = (() => {
  try { return decodeURIComponent(require('url').pathToFileURL(path.join(__dirname, 'renderer', ENTRY_HTML)).pathname); }
  catch { return null; }
})();

function isAppIndexNavigation(navigationUrl) {
  if (!APP_INDEX_PATHNAME) return false;
  try {
    const u = new URL(navigationUrl);
    if (u.protocol !== 'file:') return false;
    // Compare only the resolved pathname (ignore query/hash so in-app reloads work).
    return decodeURIComponent(u.pathname) === APP_INDEX_PATHNAME;
  } catch { return false; }
}

// --- Safe external URL opener (mailto, https, private LAN http) ---
ipcMain.handle('hub:open-external', async (_e, url) => {
  const s = String(url || '');
  if (!isAllowedExternalUrl(s)) return { ok: false, error: 'Blocked URL' };
  await shell.openExternal(s);
  return { ok: true };
});

// Parse a model the user DROPPED on the calculator. Takes bytes, not a path:
// hub:parse-print-file restricts which directories it will read so a renderer
// cannot name an arbitrary file, and a dropped path arrives from that same
// untrusted renderer. Bytes the OS already gave the page grant nothing new.
/* The drop-a-file path is the mesh budget, not the read budget, and for two
 * reasons at once: the page has already materialised the whole file as an
 * ArrayBuffer before it gets here, and this is the quote screen, which is the
 * one caller that actually wants the overhang report. Adding a large model to
 * the LIBRARY goes through hub:parse-print-file, which reads it off disk and
 * asks for neither. */
const INTAKE_MAX_BYTES = MESH_ANALYSIS_MAX_BYTES;
ipcMain.handle('hub:intake-model-bytes', async (_e, payload) => {
  const filename = String((payload && payload.filename) || '');
  const raw = payload && payload.bytes;
  if (!raw) return { ok: false, error: 'No file data' };
  const buf = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
  if (!buf.length) return { ok: false, error: 'Empty file' };
  if (buf.length > INTAKE_MAX_BYTES) return { ok: false, error: 'File too large (max 150 MB)', warnings: ['too-large'] };
  try {
    // The mesh analysis is asked for here rather than always, because it needs
    // the triangle list. The nozzle and support angle come from the renderer,
    // which knows which machine the shop is quoting for — a report answering the
    // wrong machine's question is worse than no report.
    const r = intakeModel({ filename, bytes: buf }, {
      risk: true,
      nozzleDiameter: Number(payload && payload.nozzleDiameter) || undefined,
      supportThresholdDeg: Number(payload && payload.supportThresholdDeg) || undefined,
      layerHeight: Number(payload && payload.layerHeight) || undefined,
      bed: (payload && payload.bed) || undefined,
    });
    return {
      ok: true,
      filename: path.basename(filename),
      exact: r.exact,
      source: r.source,
      printTimeMins: r.printTimeMins,
      filamentGrams: r.filamentGrams,
      filamentType: r.filamentType,
      filamentCost: r.filamentCost,
      slicer: r.slicer,
      geometry: r.geometry
        ? { volumeMm3: r.geometry.volumeMm3, bbox: r.geometry.bbox, triangleCount: r.geometry.triangleCount }
        : null,
      risk: r.risk,
      warnings: r.warnings,
    };
  } catch (e) {
    return { ok: false, error: 'Could not read that file' };
  }
});

/**
 * The printed envelope of a g-code file — see lib/gcode-geometry.js for what it
 * is and why the usual identity keys cannot survive a re-slice.
 *
 * Best-effort: a file that cannot be read, or is larger than any real print,
 * yields null and the record simply keeps no geometry key, exactly as before.
 */
const SILHOUETTE_MAX_BYTES = 256 * 1024 * 1024;
async function gcodeSilhouette(fullPath, size) {
  if (Number.isFinite(size) && size > SILHOUETTE_MAX_BYTES) return null;
  try {
    const sil = createSilhouette();
    const rl = readline.createInterface({
      input: fs.createReadStream(fullPath, { encoding: 'utf8' }),
      crlfDelay: Infinity,
    });
    for await (const line of rl) sil.push(line);
    return sil.result();
  } catch (_) {
    return null;
  }
}

// --- Feature 1 (new batch): G-code / 3MF metadata extraction ---
ipcMain.handle('hub:parse-print-file', async (_e, arg) => {
  // Called with a bare path for most of this handler's life, and now optionally
  // with { filePath, ...riskOpts } so the mesh analysis can answer for the
  // machine being quoted. Both shapes are accepted rather than migrating every
  // caller: the path is the only part this function needs to do its old job.
  const payload = (arg && typeof arg === 'object') ? arg : null;
  const filePath = payload ? payload.filePath : arg;
  /* THE RISK REPORT IS THE EXPENSIVE PART, and it was being computed for a
   * caller that throws it away.
   *
   * It is the only thing here that needs the TRIANGLE LIST — everything else is
   * a running total — and a materialised list of a big mesh is the single
   * heaviest thing this app does. The library import calls this with a bare
   * path, reads printTimeMins / filamentGrams / filamentType / slicer /
   * silhouette / geometry, and never looks at `risk`; only the quote screen
   * asks, and it asks with an object because it has to name the machine.
   *
   * So the object IS the request. A bare path now means "measure it", which is
   * what that caller always wanted, and a 250 MB model costs the buffer instead
   * of the buffer plus 1.5 GB of nested arrays. */
  const wantRisk = !!payload && payload.risk !== false;
  const resolvedParse = path.resolve(String(filePath || ''));
  const allowedParseDirs = [
    app.getPath('userData'),
    app.getPath('documents'),
    app.getPath('downloads'),
    app.getPath('desktop'),
    app.getPath('temp'),
  ];
  if (!allowedParseDirs.some(d => resolvedParse.startsWith(path.resolve(d) + path.sep) || resolvedParse === path.resolve(d))) {
    return { ok: false, error: 'Path outside allowed directories' };
  }
  const result = { printTimeMins: null, filamentGrams: null, filename: path.basename(filePath) };
  try {
    const ext = path.extname(filePath).toLowerCase();
    if (ext === '.gcode' || ext === '.gco') {
      // Read HEAD + TAIL: PrusaSlicer/SuperSlicer/OrcaSlicer write their summary
      // in the footer config block, so a head-only read misses most slicers.
      const stat = fs.statSync(resolvedParse);
      const HEAD = 32 * 1024;
      const TAIL = 64 * 1024;
      let text;
      if (stat.size <= HEAD + TAIL) {
        text = fs.readFileSync(resolvedParse, 'utf8');
      } else {
        const fd = fs.openSync(resolvedParse, 'r');
        try {
          const headBuf = Buffer.alloc(HEAD);
          const tailBuf = Buffer.alloc(TAIL);
          fs.readSync(fd, headBuf, 0, HEAD, 0);
          fs.readSync(fd, tailBuf, 0, TAIL, stat.size - TAIL);
          text = headBuf.toString('utf8') + '\n' + tailBuf.toString('utf8');
        } finally {
          fs.closeSync(fd);
        }
      }
      // The envelope needs the whole toolpath, which the head/tail read above
      // deliberately does not have — that read is for the slicer's summary, and
      // it stops well short of the moves. Streamed rather than slurped so a
      // 60 MB file costs one line at a time, and capped so a pathological one
      // costs a bounded amount of work instead of the app's responsiveness.
      result.silhouette = await gcodeSilhouette(resolvedParse, stat.size);
      const parsed = parseGcodeText(text);
      result.printTimeMins = parsed.printTimeMins;
      result.filamentGrams = parsed.filamentGrams;
      result.filamentType = parsed.filamentType;
      result.filamentCost = parsed.filamentCost;
      result.slicer = parsed.slicer;
      // Same provenance contract as the 3MF/STL/OBJ branch, so the renderer has
      // one shape to reason about rather than two.
      result.exact = !!(parsed.printTimeMins > 0 && parsed.filamentGrams > 0);
      result.source = result.exact ? 'slicer' : null;
    } else if (ext === '.3mf' || ext === '.stl' || ext === '.obj') {
      // A 3MF is a ZIP — its slicer summary lives in a DEFLATE'd member and is
      // not present in the raw bytes, so it has to be unzipped. STL and OBJ
      // carry no slicer data at all and yield a geometric ESTIMATE, which the
      // caller must label as one; `exact` says which kind of answer this is.
      const mfStat = fs.statSync(resolvedParse);
      // `warnings` so the answer is presentable: lib/intake-view.js says WHICH
      // kind of nothing it got, and "too large" is the one kind of nothing with
      // an action attached. Without it both callers reported a generic failure
      // — or, in the library, nothing at all.
      if (mfStat.size > PRINT_FILE_MAX_BYTES) {
        return {
          ok: false,
          error: `File too large (max ${PRINT_FILE_MAX_LABEL})`,
          warnings: ['too-large'],
          filename: path.basename(filePath),
        };
      }
      // Same mesh analysis the drop-a-file path asks for. Browse… and drag-drop
      // read the identical file through the identical intake, and a shop should
      // not get a different answer for having used a different button.
      // Requested and affordable are different things. Past the mesh budget the
      // file is still measured — it simply comes back without the overhang
      // report, rather than not coming back.
      const doRisk = wantRisk && mfStat.size <= MESH_ANALYSIS_MAX_BYTES;
      const r = intakeModel({ filename: path.basename(filePath), bytes: fs.readFileSync(resolvedParse) }, {
        risk: doRisk,
        /* NINE SECONDS IN HERE IS NINE SECONDS OF FROZEN APP, in every window.
         *
         * Folding a real poster's thirteen million facets is small in memory now
         * but not small in time, and this handler runs in the main process. A
         * 3MF that has to be measured is therefore handed to the converter's
         * utilityProcess below — which is what that process exists for — and the
         * geometry merged back.
         *
         * Gated on the EFFECTIVE risk decision, not the request: when the
         * overhang report is actually being computed the triangles are built
         * here anyway, so deferring would walk the same file twice. STL and OBJ
         * never defer — their read is one pass over a buffer. */
        deferMesh: ext === '.3mf' && !doRisk,
        nozzleDiameter: Number(payload && payload.nozzleDiameter) || undefined,
        supportThresholdDeg: Number(payload && payload.supportThresholdDeg) || undefined,
        layerHeight: Number(payload && payload.layerHeight) || undefined,
        bed: (payload && payload.bed) || undefined,
      });
      result.printTimeMins = r.printTimeMins;
      result.filamentGrams = r.filamentGrams;
      result.filamentType = r.filamentType;
      result.filamentCost = r.filamentCost;
      result.slicer = r.slicer;
      result.exact = r.exact;
      result.source = r.source;
      result.geometry = r.geometry
        ? { volumeMm3: r.geometry.volumeMm3, bbox: r.geometry.bbox, triangleCount: r.geometry.triangleCount }
        : null;
      result.risk = r.risk;
      result.warnings = r.warnings;

      /* The deferred half. `mesh-deferred` means the file carried no slicer
       * summary, so its numbers can only come from the mesh — the case where a
       * shop gets nothing at all if this does not happen. A worker that cannot
       * answer leaves the record exactly as a 3MF with no geometry already is,
       * rather than failing the whole read. */
      if (Array.isArray(r.warnings) && r.warnings.includes('mesh-deferred')) {
        result.warnings = r.warnings.filter((w) => w !== 'mesh-deferred');
        let m = null;
        try { m = await mfRun('measure', { src: resolvedParse, maxBytes: PRINT_FILE_MAX_BYTES }); } catch (_) { m = null; }
        if (m && m.ok && m.geometry) {
          result.geometry = {
            volumeMm3: m.geometry.volumeMm3,
            bbox: m.geometry.bbox,
            triangleCount: m.geometry.triangleCount,
          };
          result.source = 'geometry';
        } else {
          result.source = null;
          result.warnings = result.warnings.concat(['no-geometry']);
        }
      }
    }
  } catch(e) { /* silent fail */ }
  return result;
});

// --- Feature 2 (new batch): Printer API polling infrastructure ---
let printerPollInterval = null;
let lastRelocateScanAt = 0;

/**
 * Work out WHY a machine stopped answering, rather than only that it did.
 *
 * "offline" is what Khayt says for a printer switched off at the wall and for a
 * printer whose DHCP lease moved it to another address — and those have nothing
 * in common except the symptom. The second one is a two-second fix that nobody
 * makes, because nothing tells them there is one to make: the original bug was
 * found on a bench where the U1 had been polled at a dead address long enough
 * for the shop's entire completion history to be empty.
 *
 * Leaving this behind a button in the machine dialog would not have helped that
 * shop. Nobody scans a printer they have no reason to think has moved, so the
 * one owner who needs the answer is the one who will never ask for it. It has to
 * volunteer itself.
 *
 * The cost is contained by lib/printer-relocate.js `shouldScan`: only when
 * something is offline and not already explained, and at most once every ten
 * minutes however many machines are down. The poll loop itself runs every thirty
 * seconds, so the debounce is doing real work.
 *
 * Annotates the poll cache and writes nothing to the store. Every surface that
 * already renders `entry.error` can render the better sentence instead, and the
 * fix stays the owner's to accept.
 */
async function diagnoseMovedPrinters(machineList) {
  const Relocate = require('./lib/printer-relocate.js');
  const now = Date.now();
  if (!Relocate.shouldScan({
    machines: machineList, statusCache: printerStatusCache, lastScanAt: lastRelocateScanAt, now,
  })) return;
  // Stamped BEFORE the scan, not after: a scan takes seconds and the poll loop
  // does not wait for this, so stamping afterwards would let a second poll start
  // a second scan while the first was still listening.
  lastRelocateScanAt = now;
  let scan;
  try { scan = await scanForPrinters(4000); } catch { return; }
  if (!scan || !scan.ok) return;
  let discovered = scan.printers || [];
  // Nothing announced itself. That is the U1 case rather than an edge case, so
  // go and ask the subnet before giving up and leaving the owner on "offline".
  if (!discovered.length) {
    try { discovered = await sweepForPrinters(machineList, 8000); } catch (e) { discovered = []; }
  }
  const plan = Relocate.planRelocations({
    machines: machineList, discovered, statusCache: printerStatusCache,
  });
  for (const move of plan.moves) {
    const entry = printerStatusCache[move.machineId];
    if (!entry || !entry.error) continue;   // came back while we were scanning
    entry.relocated = {
      from: move.from, to: move.to, port: move.port,
      serial: move.serial, confidence: move.confidence,
    };
  }
  if (plan.moves.length) {
    BrowserWindow.getAllWindows().forEach(w => w.webContents.send('printer-status-update', printerStatusCache));
  }
}

ipcMain.handle('hub:start-printer-polling', async (_e, machines) => {
  if (printerPollInterval) clearInterval(printerPollInterval);
  // TRUST BOUNDARY: the `machines` array is renderer-supplied and is NOT
  // re-validated against the persisted store here (doing so would require
  // threading the store + machine identity through this handler). The SSRF
  // surface is instead contained downstream in fetchPrinterStatus(), where
  // isAllowedPrinterHost() now restricts every target to RFC1918 / link-local
  // LAN ranges — so even a forged machine entry can only reach a LAN device,
  // never an arbitrary public host or cloud metadata endpoint.
  const machineList = Array.isArray(machines) ? machines : [];
  // Anything captured before the app was last closed, back in the cache before
  // the first poll overwrites the entry it belongs to.
  rehydrateCompletions();
  /* ONE POLL AT A TIME.
   *
   * setInterval does not wait for an async callback, and a poll is SEQUENTIAL:
   * one fetchPrinterStatus per machine, each with a 5-second timeout. Seven
   * machines that do not answer — a shop whose printers are off overnight — take
   * 35 seconds, so the next tick fires 5 seconds before the previous poll has
   * finished, and from then on they stack.
   *
   * Two polls in flight both read `before` from printerStatusCache and both
   * write it back. The one that read the STALE value does not see the edge out
   * of printing, and whichever writes last wins:
   *
   *     completion seen by the poll that read the fresh state : true
   *     completion seen by the poll that read a STALE state   : false
   *
   * That edge is the only moment a job's measured filament and duration are
   * true — captureCompletion exists because the printer's counters reset when
   * the next job starts. Losing the race loses the measurement, silently.
   *
   * Skipping a tick rather than queueing it: the next one is thirty seconds
   * away and the data it wants is "what is the printer doing now", so a queued
   * poll would only ask a stale question late. */
  let pollInFlight = false;
  const poll = async () => {
    if (pollInFlight) return;
    pollInFlight = true;
    try {
      await pollOnce();
    } finally {
      pollInFlight = false;
    }
  };
  const pollOnce = async () => {
    let captured = false;
    for (const machine of machineList) {
      if (!machine.printerApi?.type || machine.printerApi.type === 'none') continue;
      try {
        const status = await fetchPrinterStatus(machine);
        const before = printerStatusCache[machine.id];
        printerStatusCache[machine.id] = mergePollSuccess(before, status, Date.now());
        // A job just ended. This is the only moment its figures are true, and
        // now the only moment they are written down.
        if (completionIsNew(before, printerStatusCache[machine.id])) captured = true;
      } catch(e) {
        printerStatusCache[machine.id] = mergePollFailure(
          printerStatusCache[machine.id], e.message, Date.now(),
        );
      }
    }
    const wins = BrowserWindow.getAllWindows();
    wins.forEach(w => w.webContents.send('printer-status-update', printerStatusCache));
    // Only when something finished — a write per poll would be a store write
    // every thirty seconds for the life of the app, to save a figure that had
    // not changed.
    if (captured) persistCompletions().catch(() => { /* never break polling */ });
    // Deliberately not awaited: a LAN scan takes seconds and polling must not
    // stall behind it. It pushes its own update when it finds something.
    diagnoseMovedPrinters(machineList).catch(() => { /* never break polling */ });
  };
  await poll();
  printerPollInterval = setInterval(poll, 30000);
  return printerStatusCache;
});

ipcMain.handle('hub:stop-printer-polling', () => {
  if (printerPollInterval) { clearInterval(printerPollInterval); printerPollInterval = null; }
});

ipcMain.handle('hub:get-printer-status', () => printerStatusCache);

/**
 * Pause / resume / cancel the job on a printer.
 *
 * Same host allowlist and no-redirect rule as the status poller: this reaches a
 * LAN device on the user's behalf, so it must not be steerable off the validated
 * address.
 */
/**
 * Read a Klipper/Moonraker machine's OWN job history.
 *
 * Khayt's print log is what a shop sold; this is what the printer actually ran —
 * test prints, reprints, calibration and everything nobody paid for. The
 * nozzle-wear counter needs the second, and had only ever seen the first.
 *
 * STRICTLY READ-ONLY, and deliberately so: this is safe to run mid-print, which
 * is exactly when a shop is most likely to want it. Same host guard as every
 * other printer call — isAllowedPrinterHost keeps it on the LAN.
 */
async function fetchPrinterHistory(machine, limit) {
  const { type, host, port, apiKey } = (machine && machine.printerApi) || {};
  if (type !== 'moonraker') {
    return { ok: false, error: 'Only Klipper/Moonraker printers keep a job history Khayt can read' };
  }
  const printerHost = sanitizePrinterHost(host);
  if (!isAllowedPrinterHost(printerHost)) return { ok: false, error: 'Invalid printer host' };
  const portNum = parseInt(port || defaultPrinterPort(type), 10);
  if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
    return { ok: false, error: 'Invalid port number' };
  }
  const n = Number.isInteger(limit) && limit > 0 && limit <= 1000 ? limit : 500;
  const headers = {};
  if (apiKey) headers['X-Api-Key'] = apiKey;
  try {
    const res = await fetch(`http://${printerHost}:${portNum}/server/history/list?limit=${n}`, {
      headers, redirect: 'manual', signal: AbortSignal.timeout(30000),
    });
    if (!res.ok) return { ok: false, error: `Printer answered HTTP ${res.status}` };
    const body = await res.json();
    const raw = (body && body.result) || {};
    // Mapped in the main process so the renderer never sees the slicer's
    // thumbnails: a hundred base64 previews would land in the store file, which
    // is pushed to the cloud encrypted on every sync.
    return { ok: true, jobs: moonrakerHistory.mapJobs(raw), count: raw.count ?? null };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e) };
  }
}

async function sendPrinterCommand(machine, command) {
  const { type, host, port, apiKey, printerSlug } = (machine && machine.printerApi) || {};
  const printerHost = sanitizePrinterHost(host);
  if (!isAllowedPrinterHost(printerHost)) return { ok: false, error: 'Invalid printer host' };
  const portNum = parseInt(port || defaultPrinterPort(type), 10);
  if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
    return { ok: false, error: 'Invalid port number' };
  }
  const base = `http://${printerHost}:${portNum}`;
  const headers = {};
  if (apiKey) {
    if (type === 'octoprint' || type === 'prusalink' || type === 'moonraker') headers['X-Api-Key'] = apiKey;
    if (type === 'repetier') headers['x-api-key'] = apiKey;
  }

  // PrusaLink keys its endpoints by the running job's id, and returns 404 if the
  // id is stale — so read it now rather than trusting anything cached.
  let jobId = null;
  if (printerCommands.requiresJobId(type)) {
    try {
      const res = await fetch(`${base}/api/v1/job`, { headers, redirect: 'manual', signal: AbortSignal.timeout(5000) });
      if (!res.ok) return { ok: false, error: 'No job is running on this printer' };
      jobId = (await res.json())?.id ?? null;
    } catch (e) {
      return { ok: false, error: String((e && e.message) || e) };
    }
  }

  // One request from a descriptor. `extra` carries a Duet session key when one
  // has been negotiated; everything else passes nothing.
  const send = async (req, extra) => {
    const init = { method: req.method, headers: { ...headers, ...(extra || {}) }, redirect: 'manual', signal: AbortSignal.timeout(10000) };
    if (req.body !== undefined && req.body !== null) {
      init.headers['Content-Type'] = req.contentType || 'application/json';
      // A Duet takes its G-code as text/plain in the body; every other protocol
      // here sends JSON. Encoding a string as JSON would wrap it in quotes and
      // send `"M25"` to a firmware expecting `M25`.
      init.body = typeof req.body === 'string' ? req.body : JSON.stringify(req.body);
    }
    const res = await fetch(`${base}${req.path}`, init);
    if (res.status >= 300 && res.status < 400) { const e = new Error('Unexpected redirect from printer'); e.fatal = true; throw e; }
    if (!res.ok) { const e = new Error(`Printer responded ${res.status}`); e.status = res.status; throw e; }
    return res;
  };

  // Run one descriptor, or a sequence of them in order. A sequence stops at the
  // first failure — for Duet's cancel that leaves the machine paused, which is
  // a safe place for a print to sit and is worth reporting rather than hiding.
  const run = async (req, extra) => {
    if (Array.isArray(req.sequence)) {
      for (const step of req.sequence) await send(step, extra);
      return;
    }
    await send(req, extra);
  };

  try {
    // A DUET IS TWO MACHINES WEARING ONE NAME, and job control only ever spoke
    // to one of them. The poller learned both surfaces and the session
    // handshake when SBC support landed; this path did not, so a Duet 3 + SBC
    // 404'd on every command and a password-protected Duet refused every one
    // with a 401 nobody could act on. It now does exactly what the poller does,
    // from the same endpoint table, including remembering which surface
    // answered so the wasted probe happens once rather than on every command.
    if (type === 'duet') {
      const password = apiKey || '';
      let lastErr = null;
      for (const flavour of duetFlavourFor(base)) {
        const req = printerCommands.buildCommand(type, command, jobId, { duetFlavour: flavour });
        if (req.unsupported) return { ok: false, error: req.unsupported };
        try {
          try {
            await run(req);
          } catch (e) {
            // Only a refusal earns the handshake. A password-less standalone
            // Duet — the common case — pays nothing for this branch.
            if (e.fatal || !isHttpStatus(e, KhaytDuet.ENDPOINTS[flavour].unauthorized)) throw e;
            const raw = await (await fetch(`${base}${KhaytDuet.ENDPOINTS[flavour].connect(password)}`, {
              headers, redirect: 'manual', signal: AbortSignal.timeout(10000),
            })).json();
            const r = flavour === 'standalone' ? KhaytDuet.rrConnectResult(raw) : KhaytDuet.dsfConnectResult(raw);
            if (!r.ok) return { ok: false, error: r.error };
            await run(req, r.sessionKey ? { 'X-Session-Key': r.sessionKey } : {});
          }
          rememberDuetFlavour(base, flavour);
          return { ok: true, command };
        } catch (e) {
          if (e.fatal) return { ok: false, error: e.message };
          lastErr = e;
        }
      }
      return { ok: false, error: String((lastErr && lastErr.message) || 'The Duet refused the command') };
    }

    const req = printerCommands.buildCommand(type, command, jobId, { printerSlug });
    if (req.unsupported) return { ok: false, error: req.unsupported };
    await run(req);
    return { ok: true, command };
  } catch (e) {
    // OctoPrint answers 409 when there is no active job — say so rather than
    // reporting a bare status code the user cannot act on.
    if (isHttpStatus(e, 409)) return { ok: false, error: 'No job is running on this printer' };
    return { ok: false, error: String((e && e.message) || e) };
  }
}

/**
 * What is on a Klipper printer's plate, and dropping one of it.
 *
 * ── WHY THIS IS NOT A FOURTH `printer-command` ────────────────────────────
 *
 * `pause`, `resume` and `cancel` are whole-job verbs that every protocol has a
 * shape for. This is Klipper's alone, it takes an ARGUMENT, and that argument
 * is a name out of a sliced file which ends up inside a G-code script. It gets
 * its own path so the name is checked against what the printer just reported
 * — see `lib/exclude-object.js` for why that check is the whole safety story.
 *
 * The plate is read here, in the main process, immediately before the command
 * is built. Not passed in from the renderer: a list the renderer is holding is
 * a list from some seconds ago, and the object it names may have finished.
 */
async function plateObjects(machine) {
  const { type, host, port, apiKey } = (machine && machine.printerApi) || {};
  if (type !== 'moonraker') {
    return { ok: false, error: 'Only Klipper/Moonraker printers can drop one object' };
  }
  const printerHost = sanitizePrinterHost(host);
  if (!isAllowedPrinterHost(printerHost)) return { ok: false, error: 'Invalid printer host' };
  const portNum = parseInt(port || defaultPrinterPort(type), 10);
  if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
    return { ok: false, error: 'Invalid port number' };
  }
  const headers = {};
  if (apiKey) headers['X-Api-Key'] = apiKey;
  const base = `http://${printerHost}:${portNum}`;
  try {
    const res = await fetch(`${base}/printer/objects/query?${excludeObject.QUERY}`, {
      headers, redirect: 'manual', signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) return { ok: false, error: `Printer answered HTTP ${res.status}` };
    return { ok: true, base, headers, data: await res.json() };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e) };
  }
}

ipcMain.handle('hub:printer-plate', async (_e, { machine } = {}) => {
  const read = await plateObjects(machine);
  if (!read.ok) return read;
  const plate = excludeObject.plate(read.data);
  return { ok: true, ...plate, remaining: excludeObject.remaining(read.data) };
});

ipcMain.handle('hub:printer-exclude-object', async (_e, { machine, name } = {}) => {
  const read = await plateObjects(machine);
  if (!read.ok) return read;
  const req = excludeObject.excludeRequest(name, read.data);
  if (req.refused) return { ok: false, error: req.refused };
  try {
    const res = await fetch(read.base + req.path, {
      method: req.method, headers: read.headers,
      redirect: 'manual', signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) return { ok: false, error: `Printer answered HTTP ${res.status}` };
    return { ok: true, dropped: name };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e) };
  }
});

ipcMain.handle('hub:printer-command', async (_e, { machine, command } = {}) =>
  sendPrinterCommand(machine, command));
// Read-only: safe to call while the printer is mid-job, which is when a shop is
// most likely to reach for it.
/**
 * The app's language, so the spellchecker can follow it.
 *
 * Chromium picks a dictionary from the SYSTEM locale and never learns what
 * language the app is being used in — so an Arabic shop had every word
 * underlined by an English dictionary. Chromium has no Arabic dictionary at all
 * (nor Japanese or Chinese), and for those this switches spellcheck OFF rather
 * than marking correct text wrong.
 */
// Labels for the right-click menu, sent by the renderer with the language: the
// main process has no access to the locale files, and a menu that says "Cut" to
// an Arabic shop is a smaller version of the same problem this fixes.
let menuStrings = {};

ipcMain.handle('hub:set-app-language', (_e, lang, strings) => {
  if (strings && typeof strings === 'object') menuStrings = strings;
  const win = BrowserWindow.getAllWindows()[0];
  const ses = win && win.webContents && win.webContents.session;
  return contextMenu.applyLanguage(ses, lang);
});

ipcMain.handle('hub:printer-history', async (_e, { machine, limit } = {}) =>
  fetchPrinterHistory(machine, limit));


/**
 * The filament stock a machine runs, for turning extruded millimetres into
 * grams. Falls back to lib/printer-actuals' documented defaults when the machine
 * has not been told.
 */
function stockOptsFor(machine) {
  const api = (machine && machine.printerApi) || {};
  return {
    diameterMm: api.filamentDiameterMm,
    densityGPerCm3: api.filamentDensityGPerCm3,
  };
}

async function fetchPrinterStatus(machine) {
  const { type, host, port, apiKey, accessCode, printerSlug, serial } = machine.printerApi || {};
  // Strip any characters that aren't valid in a hostname/IP (prevents URL injection via @, /, etc.)
  const printerHost = sanitizePrinterHost(host);
  if (!isAllowedPrinterHost(printerHost)) {
    return { ok: false, error: 'Invalid printer host' };
  }
  const portNum = parseInt(port || defaultPrinterPort(type), 10);
  if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
    return { ok: false, error: 'Invalid port number' };
  }
  // Bambu Lab: MQTT-over-TLS, not HTTP. Needs the device serial for its topics.
  if (type === 'bambu') {
    const dev = String(serial || printerSlug || '').trim();
    if (!dev) return { ok: false, error: 'Bambu needs the printer serial number (Settings → Device on the printer).' };
    if (!accessCode) return { ok: false, error: 'Bambu needs the LAN access code.' };
    return bambu.fetchBambuStatus({ host: printerHost, port: portNum, accessCode, serial: dev });
  }
  // SDCP (Elegoo resin): a WebSocket, not HTTP either. The mainboard id is its
  // address on the protocol — every frame is topic-addressed by it — and
  // discovery is where a shop gets one, since it is not printed on the machine.
  //
  // The global WebSocket is used rather than a dependency: Electron 42 ships
  // Node 22, where it is standard. See lib/sdcp-client.js for why the socket is
  // a parameter rather than opened in there.
  if (type === 'sdcp') {
    const board = String(serial || printerSlug || '').trim();
    if (!board) return { ok: false, error: 'SDCP needs the printer’s mainboard ID — run a network scan to find it.' };
    return sdcpClient.fetchStatus({
      connect: (url) => new WebSocket(url),
      ip: printerHost,
      mainboardId: board,
    });
  }
  const baseUrl = `http://${printerHost}:${portNum}`;
  const headers = {};
  // Moonraker was missing here. It accepts X-Api-Key from untrusted clients, and
  // without it Khayt only works when the printer happens to list this machine in
  // `trusted_clients` — any shop running `force_logins: True`, or an app on a
  // subnet the printer doesn't trust, got a blanket 401 with nothing to explain it.
  //
  // Guarded on a non-empty key: an unset one previously sent the literal string
  // "undefined" as the header value, and Moonraker in trusted-client mode needs
  // no key at all, so sending a junk one is worse than sending none.
  if (apiKey) {
    if (type === 'octoprint' || type === 'prusalink' || type === 'moonraker') headers['X-Api-Key'] = apiKey;
    if (type === 'repetier') headers['x-api-key'] = apiKey;
  }

  const get = async (p, extraHeaders) => {
    // redirect:'manual' so a compromised/misconfigured printer host can't 302 the poller off the
    // validated LAN address to loopback/metadata (the response here IS returned to the renderer).
    const res = await fetch(`${baseUrl}${p}`, {
      headers: extraHeaders ? { ...headers, ...extraHeaders } : headers,
      redirect: 'manual', signal: AbortSignal.timeout(5000),
    });
    if (res.status >= 300 && res.status < 400) throw new Error('Unexpected redirect from printer');
    // The status is carried on the error rather than only in its text, because
    // the Duet adapter has to tell "you need a session" (401 standalone, 403 SBC)
    // apart from "this surface does not exist here" (404) to pick a transport.
    if (!res.ok) {
      // The body is read before the message is built because the vendors put the
      // useful half there: Moonraker names which Klippy failure it is, OctoPrint
      // says "Printer is not operational" in words. Failing to read it must not
      // turn a 409 into a network error, hence the catch.
      const body = await res.text().catch(() => '');
      const e = new Error(explainPrinterHttp(type, res.status, body) || `HTTP ${res.status}`);
      e.status = res.status;
      throw e;
    }
    return res.json();
  };

  if (type === 'octoprint') {
    // `/api/printer` is guarded by `abort(409, "Printer is not operational")` —
    // in the 1.11 line and in the 2.0 line alike (server/api/printer.py). That
    // is not a fault: it is OctoPrint running with the printer switched off or
    // not connected, which is most of any working day. Because both requests
    // were awaited together, that 409 failed the WHOLE poll, so the card showed
    // an error where it should have shown "Offline" — and threw away the
    // `/api/job` response, which answers fine in exactly that state (its GET
    // carries no operational guard) and whose `state` reads "Offline" straight
    // from the connection's own string.
    //
    // So the job is asked for unconditionally and the printer tolerantly. Any
    // other status still fails the poll, because any other status is a fault.
    const [printer, job] = await Promise.all([
      get('/api/printer').catch((e) => { if (e && e.status === 409) return null; throw e; }),
      get('/api/job'),
    ]);
    return {
      ...octoprint.readStatus(printer, job),
      // What the job has ACTUALLY used so far. Already in this payload; Khayt
      // fetched it and threw it away until now.
      actuals: extractActuals('octoprint', job, stockOptsFor(machine)),
    };
  }
  if (type === 'moonraker') {
    // The filament sensors are DISCOVERED, once per machine per run, because a
    // hardcoded object name finds nothing on the printer this was written
    // against — see `lib/filament-sensors.js`. Klipper's object list changes
    // only across a firmware restart, and a failed discovery simply means no
    // runout reporting rather than a failed poll.
    let sensorNames = moonrakerSensors.get(machine.id);
    if (sensorNames === undefined) {
      try {
        sensorNames = filamentSensors.sensorNames(await get('/printer/objects/list'));
      } catch (e) { sensorNames = []; }
      moonrakerSensors.set(machine.id, sensorNames);
    }
    const data = await get(`/printer/objects/query?${moonraker.queryWith(sensorNames)}`);
    // On a toolchanger the live head is not toolhead zero, and only the machines
    // that need it pay for the second request. A failure there keeps toolhead
    // zero's reading rather than showing nothing.
    const hotName = moonraker.activeExtruder(data);
    let hot = null;
    if (hotName) {
      try { hot = await get(`/printer/objects/query?${encodeURIComponent(hotName)}`); }
      catch (e) { hot = null; }
    }
    // The slicer's own estimate for this file, so the ETA is not extrapolated
    // from the first two percent of a print — see `etaWithEstimate`.
    const printing = (data && data.result && data.result.status
                      && data.result.status.print_stats && data.result.status.print_stats.filename) || '';
    let held = moonrakerFileMeta.get(machine.id);
    if (!held || held.filename !== printing) {
      const path = moonraker.metadataPath(printing);
      let meta = null;
      if (path) { try { meta = await get(path); } catch (e) { meta = null; } }
      held = { filename: printing, meta };
      moonrakerFileMeta.set(machine.id, held);
    }
    return {
      ...moonraker.readStatus(data, hot, hotName, sensorNames, held.meta),
      // filament_used is a running total across toolchanges, not per-head:
      // print_stats.py rebases its last extruder position on the
      // `extruder:activate_extruder` event, so the jump between heads is not
      // counted as extrusion and a four-colour job sums correctly.
      actuals: extractActuals('moonraker', data, stockOptsFor(machine)),
    };
  }
  if (type === 'prusalink') {
    // `/api/v1/status` carries no file information, so the filename here was
    // always the empty string. Not "usually" — the job object Prusa's Buddy
    // firmware renders is exactly {id, progress, time_remaining,
    // filament_change_in, time_printing} (lib/WUI/nhttp/status_renderer.cpp) and
    // the OpenAPI spec's StatusJob agrees. `job.file` does not exist on this
    // endpoint at any firmware version; it lives on `/api/v1/job`.
    //
    // That second request is allowed to fail: it answers 204 No Content when
    // nothing is printing, and a missing name must not cost us the temperatures
    // and progress the first request did return.
    const [data, jobData] = await Promise.all([
      get('/api/v1/status'),
      get('/api/v1/job').catch(() => null),
    ]);
    return {
      ...prusalink.readStatus(data, jobData),
      actuals: extractActuals('prusalink', data, stockOptsFor(machine)),
    };
  }
  // (Bambu is handled above via MQTT before the HTTP branches.)
  if (type === 'duet') {
    // A Duet answers over one of two entirely different HTTP surfaces —
    // RepRapFirmware standalone (`rr_*`) or a Duet 3 with an SBC attached
    // (`machine/*`) — and this only ever spoke the first. Every request to a
    // Duet 3 + SBC 404'd, so an officially supported configuration read as an
    // unreachable machine rather than a degraded one. See lib/duet.js.
    //
    // Both are session-based. Standalone auto-creates a session for a machine
    // with no password, which is why this worked for everyone who never ran
    // M551 and for nobody who did; SBC always needs `machine/connect` first and
    // its session lasts "at least 8 seconds", so re-authenticating between polls
    // is ordinary operation rather than an error.
    const password = apiKey || '';
    const flavours = duetFlavourFor(baseUrl);

    const tryFlavour = async (flavour) => {
      const ep = KhaytDuet.ENDPOINTS[flavour];
      const withSession = async () => {
        const raw = await get(ep.connect(password));
        const r = flavour === 'standalone' ? KhaytDuet.rrConnectResult(raw) : KhaytDuet.dsfConnectResult(raw);
        if (!r.ok) throw new Error(r.error);
        return r.sessionKey ? { 'X-Session-Key': r.sessionKey } : {};
      };

      // Try unauthenticated first and only pay for a handshake when refused.
      // A password-less standalone Duet — the overwhelmingly common case — then
      // costs exactly what it did before this change.
      let extra = {};
      const fetchModel = async () => {
        const live = await get(ep.live, extra);
        if (!ep.file) return { live, file: null };
        const file = await get(ep.file, extra).catch(() => null);
        return { live, file };
      };

      let got;
      try {
        got = await fetchModel();
      } catch (e) {
        if (!isHttpStatus(e, ep.unauthorized)) throw e;
        extra = await withSession();
        got = await fetchModel();
      }
      return KhaytDuet.statusFromObjectModel(got.live, KhaytDuet.objectModel(got.file), {
        fileProgressPct, extractActuals, stockOpts: stockOptsFor(machine),
      });
    };

    let lastErr = null;
    for (const flavour of flavours) {
      try {
        const status = await tryFlavour(flavour);
        rememberDuetFlavour(baseUrl, flavour);   // skip the wrong surface next time
        return status;
      } catch (e) { lastErr = e; }
    }

    // Both surfaces refused. The pre-RRF-3 status endpoint is the last thing to
    // try — it predates the object model entirely and only exists standalone.
    try {
      // The shape is `lib/duet.js`'s now, not this function's — the Mac app
      // needs the same one, and an inline object needed in two places is two
      // objects that drift. See `legacyStatus` there.
      const data = await get(KhaytDuet.ENDPOINTS.standalone.legacy);
      return KhaytDuet.legacyStatus(data, normalizeProgress);
    } catch (e) { throw lastErr || e; }
  }
  if (type === 'repetier') {
    const slug = printerSlug || 'default';
    // TWO CALLS, BECAUSE THE JOB IS NOT ON THE CALL THIS ASKED.
    //
    // `stateList` is the state of the MACHINE — temperatures, active extruder,
    // layer, position. `listPrinter` is the state of the JOB — `done`, `job`,
    // `paused`, `online`. This adapter read `done` and `job` off `stateList`,
    // where Repetier's own API reference lists neither, so progress was always
    // 0 and the filename always empty, and the machine therefore always looked
    // Idle. See lib/repetier.js for the sources and for why that survived the
    // 2026-08-25 audit, which fixed a different cause of the same symptom.
    //
    // The listing is allowed to fail on its own: losing the job must not cost
    // the temperatures the first call did return — the same rule the PrusaLink
    // branch above follows for its second request.
    const [stateData, listData] = await Promise.all([
      get(`/printer/api/${encodeURIComponent(slug)}?a=stateList`),
      get(`/printer/api/${encodeURIComponent(slug)}?a=listPrinter`).catch(() => null),
    ]);
    return KhaytRepetier.repetierStatus({ stateData, listData, slug, normalizeProgress });
  }
  throw new Error(`Unknown printer type: ${type}`);
}

/**
 * Which Duet surface a given address answered on last time.
 *
 * A Duet is either standalone RepRapFirmware or a Duet 3 with an SBC, and the
 * two share no endpoints. Detection means trying one and falling back, which
 * costs a wasted request — once, not on every poll for the life of the machine.
 * Remembered by address rather than by machine id so the same board reached
 * twice under different names is still only probed once.
 *
 * Deliberately not persisted: a board that gets an SBC bolted to it, or has one
 * removed, should be re-detected on the next launch rather than argued with.
 */
const duetFlavours = new Map();

function duetFlavourFor(baseUrl) {
  const known = duetFlavours.get(baseUrl);
  // Standalone first when nothing is known: it is the far more common build, so
  // the wasted probe lands on the rarer configuration.
  if (known === 'sbc') return ['sbc', 'standalone'];
  return ['standalone', 'sbc'];
}

function rememberDuetFlavour(baseUrl, flavour) { duetFlavours.set(baseUrl, flavour); }

/** Did this error come from a specific HTTP status? */
function isHttpStatus(err, status) { return !!err && err.status === status; }

function defaultPrinterPort(type) {
  const ports = { octoprint: 80, moonraker: 7125, bambu: 8883, prusalink: 80, duet: 80, repetier: 3344, sdcp: 3030 };
  return ports[type] || 80;
}

// --- Feature 5 (new batch): Outbound email notifications ---
ipcMain.handle('hub:send-email', async (event, { to, subject, body, smtpConfig }) => {
  const cfg = smtpConfig ? { ...smtpConfig } : {};
  cfg.apiKey = resolveStoreSecret(cfg.apiKey, d => d?.settings?.emailConfig?.apiKey);
  if (cfg?.provider === 'sendgrid' && cfg?.apiKey) {
    try {
      const res = await fetch('https://api.sendgrid.com/v3/mail/send', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${cfg.apiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          personalizations: [{ to: [{ email: to }] }],
          from: { email: cfg.fromEmail || 'noreply@khaytapp.com', name: cfg.fromName || 'Khayt' },
          subject,
          content: [{ type: 'text/html', value: body }]
        })
      });
      return { ok: res.ok, status: res.status };
    } catch(e) {
      return { ok: false, error: String(e) };
    }
  }
  if (cfg?.provider === 'mailgun' && cfg?.apiKey && cfg?.domain) {
    try {
      const mgDomain = sanitizeMailgunDomain(cfg.domain);
      if (!mgDomain) return { ok: false, error: 'Invalid Mailgun domain' };
      const formData = new URLSearchParams({
        from: `${cfg.fromName||'Khayt'} <mailgun@${mgDomain}>`,
        to, subject, html: body
      });
      const res = await fetch(`https://api.mailgun.net/v3/${mgDomain}/messages`, {
        method: 'POST',
        headers: { 'Authorization': `Basic ${Buffer.from(`api:${cfg.apiKey}`).toString('base64')}` },
        body: formData
      });
      return { ok: res.ok, status: res.status };
    } catch(e) {
      return { ok: false, error: String(e) };
    }
  }
  if (cfg?.provider === 'custom' && cfg?.smtpHost) {
    cfg.smtpPassword = resolveStoreSecret(cfg.smtpPassword, d => d?.settings?.emailConfig?.smtpPassword);
    return sendCustomSmtp({
      host: cfg.smtpHost,
      port: cfg.smtpPort || 587,
      user: cfg.smtpUser || '',
      pass: cfg.smtpPassword || '',
      secure: !!cfg.smtpSecure,
      from: cfg.fromEmail || cfg.smtpUser || 'noreply@khaytapp.com',
      fromName: cfg.fromName || 'Khayt',
      to,
      subject,
      html: body,
    });
  }
  // Fallback: mailto link
  return { ok: false, fallback: true, mailtoUrl: `mailto:${to}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}` };
});

// Outbound SMS / WhatsApp via a configured provider (Twilio / WhatsApp Cloud /
// Unifonic / webhook). Provider secrets resolve from the encrypted store so they
// never round-trip the renderer in plaintext after first save.
ipcMain.handle('hub:send-sms', async (_e, { to, message, channel, smsConfig } = {}) => {
  const cfg = smsConfig ? { ...smsConfig } : {};
  const provider = cfg.provider;
  cfg.authToken = resolveStoreSecret(cfg.authToken, d => d?.settings?.smsConfig?.authToken);
  cfg.token     = resolveStoreSecret(cfg.token,     d => d?.settings?.smsConfig?.token);
  cfg.appSid    = resolveStoreSecret(cfg.appSid,    d => d?.settings?.smsConfig?.appSid);
  cfg.secret    = resolveStoreSecret(cfg.secret,    d => d?.settings?.smsConfig?.secret);
  return sendSms(provider, cfg, { to, message, channel });
});

// One-way accounting sync: POST a canonical invoice/expense payload to the
// owner's webhook (bridge to QuickBooks/Zoho/Xero via Zapier/Make/own endpoint).
// Idempotent by payload.idempotencyKey; secret resolves from the encrypted store.
ipcMain.handle('hub:accounting-push', async (_e, { url, secret, payload } = {}) => {
  if (!/^https?:\/\//i.test(String(url || ''))) return { ok: false, error: 'Accounting webhook needs an http(s) URL' };
  // Same SSRF hardening as hub:webhook-post — the URL comes from the store
  // (settings.accountingSync.webhookUrl), which can arrive via restore/sync, so
  // block private/loopback/metadata targets, DNS-rebinding and redirects.
  let parsed;
  try {
    parsed = new URL(url);
    if (isBlockedHost(parsed.hostname)) return { ok: false, error: 'Blocked URL — cannot send to private/loopback addresses' };
  } catch { return { ok: false, error: 'Invalid accounting webhook URL' }; }
  if (await resolvesToBlockedHost(parsed.hostname)) {
    return { ok: false, error: 'Blocked URL — hostname resolves to a private/loopback address' };
  }
  secret = resolveStoreSecret(secret, d => d?.settings?.accountingSync?.secret);
  try {
    const headers = { 'content-type': 'application/json' };
    if (secret) headers['X-Khayt-Secret'] = String(secret);
    if (payload && payload.idempotencyKey) headers['Idempotency-Key'] = String(payload.idempotencyKey);
    const res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(payload || {}), redirect: 'manual', signal: AbortSignal.timeout(15000) });
    if (res.status >= 300 && res.status < 400) return { ok: false, error: 'Blocked redirect from accounting webhook' };
    if (!res.ok) {
      let detail = `HTTP ${res.status}`;
      try { const txt = await res.text(); if (txt) detail += ` — ${txt.slice(0, 200)}`; } catch { /* ignore */ }
      return { ok: false, status: res.status, error: detail };
    }
    return { ok: true, status: res.status };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// Generic outbound event webhook poster: signs the body with HMAC-SHA256
// (X-Khayt-Signature: sha256=<hex>) so the receiver can verify authenticity, and
// sends an Idempotency-Key (the event id) so retries dedupe. Same SSRF hardening
// as hub:fire-webhook — https-only, blocked-host string + DNS-rebinding checks,
// no redirects.
ipcMain.handle('hub:webhook-post', async (_e, { url, secret, payload } = {}) => {
  if (!url || !String(url).startsWith('https://')) return { ok: false, error: 'Webhook needs an https:// URL' };
  let parsed;
  try {
    parsed = new URL(url);
    if (isBlockedHost(parsed.hostname)) return { ok: false, error: 'Blocked URL — cannot send webhooks to private/loopback addresses' };
  } catch { return { ok: false, error: 'Invalid webhook URL' }; }
  if (await resolvesToBlockedHost(parsed.hostname)) {
    return { ok: false, error: 'Blocked URL — hostname resolves to a private/loopback address' };
  }
  secret = resolveStoreSecret(secret, d => d?.settings?.eventWebhooks?.secret);
  try {
    const body = JSON.stringify(payload || {});
    const headers = { 'content-type': 'application/json' };
    if (payload && payload.id) headers['Idempotency-Key'] = String(payload.id);
    if (secret) {
      const sig = require('crypto').createHmac('sha256', String(secret)).update(body).digest('hex');
      headers['X-Khayt-Signature'] = 'sha256=' + sig;
    }
    const res = await fetch(url, { method: 'POST', headers, body, redirect: 'manual', signal: AbortSignal.timeout(15000) });
    if (res.status >= 300 && res.status < 400) return { ok: false, error: 'Webhook redirects are not allowed' };
    return res.ok ? { ok: true, status: res.status } : { ok: false, status: res.status, error: `HTTP ${res.status}` };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// ── Feature R12-1: Outbound Webhooks ────────────────────────────────────────
// AI quote extraction (BYO Anthropic key) — opt-in; fails safe (renderer falls
// back to the manual quote form on any error). Key resolved from the encrypted
// store so it never round-trips the renderer in plaintext after first save.
ipcMain.handle('hub:ai-extract', async (_e, { apiKey, model, system, request, image, schema, task } = {}) => {
  apiKey = resolveStoreSecret(apiKey, d => d?.settings?.ai?.apiKey);
  if (!apiKey) return { ok: false, error: 'No AI key configured' };
  if (!request || !String(request).trim()) return { ok: false, error: 'Empty request' };

  // The tool name/description must describe the CALLING feature — the model
  // leans on them heavily, and one shared 'quote_extract' definition was
  // mis-framing price, reply and assistant calls. See lib/ai-tools.js.
  const { tool, maxTokens, task: resolvedTask } = aiTools.resolveTool(task, schema);

  // Consent is enforced HERE, not only in the renderer. This is the single
  // point where shop data leaves the device, so a call site that forgets to
  // check (or a future one that never knew to) still cannot transmit a feature
  // the owner has not agreed to. See lib/ai-privacy.js.
  const storeAi = readStoreDecryptedFromDisk()?.settings?.ai;
  if (!aiPrivacy.isFeatureEnabled(storeAi, resolvedTask)) {
    return { ok: false, error: 'AI_FEATURE_NOT_CONSENTED', feature: resolvedTask };
  }
  const content = [{ type: 'text', text: String(request) }];
  if (image) content.push({ type: 'image', source: { type: 'base64', media_type: 'image/png', data: String(image) } });
  const body = JSON.stringify({
    model: model || 'claude-opus-5',
    max_tokens: maxTokens,
    system: String(system || ''),
    tools: [tool],
    tool_choice: { type: 'tool', name: tool.name },
    messages: [{ role: 'user', content }],
  });

  // Retry transient faults (429/529/5xx) with backoff. Raw fetch gives us none
  // of this for free, so a single rate-limit reply used to kill the feature.
  const MAX_ATTEMPTS = 3;
  let lastError = 'AI request failed';
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    let res;
    try {
      res = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' },
        body,
        // 60s, not 30s: the default model thinks before it answers, and thinking
        // happens before the first byte of the reply. A 30s ceiling was set when
        // the default model did not think, and would now abort a good answer
        // mid-flight — which the shop would see as a network error.
        signal: AbortSignal.timeout(60000),
      });
    } catch (e) {
      // Network fault or timeout — transient by nature, so it retries too.
      lastError = String(e && e.message || e);
      if (attempt + 1 >= MAX_ATTEMPTS) return { ok: false, error: lastError };
      await new Promise(r => setTimeout(r, aiTools.retryDelayMs(attempt)));
      continue;
    }

    if (!res.ok) {
      const errBody = await res.json().catch(() => null);
      lastError = aiTools.describeHttpError(res.status, errBody);
      if (!aiTools.shouldRetry(res.status) || attempt + 1 >= MAX_ATTEMPTS) return { ok: false, error: lastError };
      await new Promise(r => setTimeout(r, aiTools.retryDelayMs(attempt, res.headers.get('retry-after'))));
      continue;
    }

    const data = await res.json();
    const toolUse = (data.content || []).find(c => c && c.type === 'tool_use');
    // Hand back the usage block. It arrives on every response and used to be
    // discarded, so a shop on its own key had no way to know what the AI
    // features were costing them — see lib/ai-usage.js.
    if (toolUse && toolUse.input) {
      return { ok: true, draft: toolUse.input, usage: data.usage || null, model: data.model || null };
    }
    // A 200 with no tool call: stop_reason says whether the model refused, ran
    // out of room, or paused — three different fixes, previously one message.
    return { ok: false, error: aiTools.describeStop(data.stop_reason) || 'No structured output returned' };
  }
  return { ok: false, error: lastError };
});

// ── Khayt Cloud sync (opt-in, E2E) ────────────────────────────────────────────
// The unlocked backend (with the in-memory DEK) lives only for the session; the
// passphrase is never stored, so the renderer re-unlocks each launch.
let cloudBackend = null;

// Same probe, but says WHY it failed — timeout, unreachable, wrong server, bad
// address — so the user is told which of those to go and fix.
ipcMain.handle('hub:cloud-health-detail', (_e, url) => cloudClient.healthDetail(url));

ipcMain.handle('hub:cloud-create-keyset', (_e, passphrase) => {
  try { return { ok: true, ...cloudClient.createKeyset(String(passphrase || '')) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-signup', async (_e, { url, email, password, registerSecret } = {}) => {
  try { return { ok: true, ...(await cloudClient.signup(url, { email, password, registerSecret })) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-login', async (_e, { url, email, password } = {}) => {
  try {
    const r = await cloudClient.login(url, { email, password });
    if (!r) return { ok: false, error: 'Wrong email or password' };
    return { ok: true, ...r };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-accept-invite', async (_e, { url, email, password, code } = {}) => {
  try { return { ok: true, ...(await cloudClient.acceptInvite(url, { email, password, code })) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-member-invite', async (_e, { url, shopId, token, email, role } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.inviteMember(url, shopId, token, email, role)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-members-list', async (_e, { url, shopId, token } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, members: await cloudClient.listMembers(url, shopId, token) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-get-slug', async (_e, { url, shopId, token } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.getShopSlug(url, shopId, token)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-set-slug', async (_e, { url, shopId, token, slug } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.setShopSlug(url, shopId, token, slug)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-member-remove', async (_e, { url, shopId, token, email } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.removeMember(url, shopId, token, email)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

/* ── Publishing when this shop could have a new order ready ─────────────────
 *
 * A storefront asks at basket time and has no credential, so the figure has to
 * be somewhere it can read without one — see khayt-cloud
 * GET /v1/shops/{id}/lead-time. This is what puts it there.
 *
 * The queue itself never leaves: lib/lead-time-publish.js folds it into a single
 * `availableFrom` and sums the shop's buffers into one `handlingDays` first.
 *
 * REPUBLISHED ON A TIMER EVEN WHEN NOTHING CHANGED, and that is the point rather
 * than an oversight. The snapshot carries `staleAfterHours`, and a reader that
 * finds it older than that stops quoting — correctly, because a queue shrinks as
 * a shop prints and grows as orders arrive. So silence has to be refreshed or a
 * storefront quietly stops answering; `differs()` decides whether the figure is
 * NEWS, not whether to send it.
 */
let lastLeadTimeSnapshot = null;

async function publishLeadTime() {
  try {
    const Publish = require('./lib/lead-time-publish.js');
    const settings = (lanServerStore && lanServerStore.settings) || {};
    const cloud = settings.cloud || {};
    const now = new Date();
    const snap = Publish.buildSnapshot({
      settings,
      printLog: (lanServerStore && lanServerStore.printLog) || [],
      /* Machines live at the STORE ROOT, not under settings — the same place
         lib/lan-server.js reads them from. An earlier `settings.machines ||`
         here was a fallback that could never fire: it read as a handled case,
         always fell through, and would have hidden a real change of location
         behind a branch that looked like it covered one. */
      machines: (lanServerStore && lanServerStore.machines) || [],
      // The SHOP's local day. lib/lead-time.js does its arithmetic in UTC and
      // never asks a clock, so this is the one place the timezone is decided.
      today: `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`,
      nowIso: now.toISOString(),
      /* What the printers themselves are doing.
       *
       * Without this the promise was built from the order book alone, so a
       * machine running a job sent straight to it from a slicer counted as free
       * and the shop quoted a customer a date that assumed an idle printer. */
      statusCache: printerStatusCache,
    });

    // Turned off, or never turned on. Withdraw once rather than every tick, so a
    // shop that opts out stops answering instead of leaving a frozen date on a
    // public URL — and so opting out does not become an hourly DELETE for ever.
    if (!snap) {
      if (lastLeadTimeSnapshot && cloud.url && cloud.shopId) {
        const token = resolveStoreSecret(cloud.token, d => d?.settings?.cloud?.token);
        if (token) await cloudClient.putLeadTime(cloud.url, cloud.shopId, token, null);
      }
      lastLeadTimeSnapshot = null;
      return;
    }
    if (!cloud.url || !cloud.shopId) return;
    const token = resolveStoreSecret(cloud.token, d => d?.settings?.cloud?.token);
    if (!token) return;
    await cloudClient.putLeadTime(cloud.url, cloud.shopId, token, snap);
    lastLeadTimeSnapshot = snap;
  } catch (_) { /* a promise nobody can read is better than an app that fell over */ }
}

// Once shortly after launch, then every six hours — comfortably inside the
// default 24-hour staleness window, so a storefront keeps quoting even if a
// publish or two fails. Unref'd so it can never hold the app open.
function startLeadTimePublisher() {
  setTimeout(publishLeadTime, 90 * 1000).unref?.();
  const t = setInterval(publishLeadTime, 6 * 60 * 60 * 1000);
  t.unref?.();
}

ipcMain.handle('hub:cloud-catalog-publish', async (_e, { url, shopId, token, catalog } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.putCatalog(url, shopId, token, catalog)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// ── MakerRun library sync (site ↔ app) — pull the user's saved designs from makerrun.com. Separate from
// Khayt Cloud above: read-only, no encryption, no shop token; just the user's MakerRun access token.
ipcMain.handle('hub:bedready-linked', () => {
  try { return { ok: true, linked: makerrunAccount.isLinked(app.getPath('userData')) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:bedready-library', async () => {
  try {
    const userData = app.getPath('userData');
    const token = await makerrunAccount.getAccessToken(userData); // refreshes if needed
    const SyncState = require('./lib/makerrun-sync-state.js');
    const state = SyncState.read(userData);
    // `?since=` is used as a probe, never as a delta feed — it cannot report an
    // unsave, so only "nothing changed" is acted on and anything else re-reads
    // the whole list. See syncLibrary.
    const r = await makerrunLibrary.syncLibrary(token, { state });
    // THE CACHE IS ONLY REPLACED FROM A COMPLETE READ.
    //
    // An incomplete sync — paging that did not reach the end — is still worth
    // showing, because a partial library beats none. It is NOT worth storing as
    // the library: the next sync would compare against it and read the pages we
    // never fetched as designs the shop had removed. Absence only means removal
    // when the read was whole.
    if (r.complete !== false) {
      SyncState.write(userData, { ...state, syncedAt: r.syncedAt, items: r.items });
    }
    return { ok: true, items: r.items, unchanged: r.unchanged, partial: r.complete === false };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:bedready-unlink', () => {
  try { makerrunAccount.clear(app.getPath('userData')); return { ok: true }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:bedready-download-all', async (_e, { items } = {}) => {
  try {
    const { app, shell } = require('electron');
    // Keeps an existing Downloads/BedReady-Library rather than splitting a renamed library across two
    // folders. `folder` goes back so the UI names the folder it actually wrote to, not a guess.
    const dest = makerrunLibrary.downloadsDir(app.getPath('downloads'));
    const userData = app.getPath('userData');
    const SyncState = require('./lib/makerrun-sync-state.js');
    let state = SyncState.read(userData);
    // Remembered as each file lands rather than in one write at the end: a sync
    // interrupted halfway must not re-download what it already fetched, and an
    // all-or-nothing write is exactly the case where it would.
    const r = await makerrunLibrary.downloadAll(items, dest, {
      state,
      onKept: (item, filePath) => { state = SyncState.remember(state, item, filePath); },
    });
    SyncState.write(userData, state);
    // `kept` files are already there, so opening the folder is still the right
    // thing when nothing was newly saved but something was kept.
    if (r.saved.length || r.kept.length) shell.openPath(dest).catch(() => {});
    return { ok: true, dest, folder: require('path').basename(dest), ...r };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// Download one library design straight into a Print-File Library record's vault folder, so a synced
// design lands IN the app (with a thumbnail) instead of orphaned in ~/Downloads. Renderer mints the
// vaultId, calls this, then creates the print-file record via importConvertedAsNew().
ipcMain.handle('hub:bedready-download-into-vault', async (_e, { item, vaultId } = {}) => {
  try {
    if (!vaultId) return { ok: false, error: 'Missing library id.' };
    const dir = printLibItemDir(vaultId);
    fs.mkdirSync(dir, { recursive: true });
    const out = await makerrunLibrary.downloadItem(item, dir);
    if (!out) return { ok: false, skipped: true };
    const stat = fs.statSync(out);
    return { ok: true, filename: path.basename(out), ext: path.extname(out).slice(1).toLowerCase() || '3mf', size: stat.size };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// Fetch a design cover as a data: URI (the renderer CSP forbids remote img-src). SSRF-guarded in the lib.
ipcMain.handle('hub:bedready-cover', async (_e, { url } = {}) => {
  try { return { ok: true, dataUrl: await makerrunLibrary.fetchCoverDataUrl(url) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:bedready-open-signin', () => {
  try {
    bedreadyLinkArmedAt = Date.now(); // arm: the next bedready:// link is user-initiated and expected
    bedreadyLinkNonce = crypto.randomBytes(16).toString('hex'); // bind the handshake to this click
    const url = makerrunLibrary.signInUrl() + '?state=' + encodeURIComponent(bedreadyLinkNonce);
    require('electron').shell.openExternal(url);
    return { ok: true };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// ── Orca filament installer (Bed Ready) — install OrcaSlicer profiles into any Orca-family slicer ──
ipcMain.handle('hub:orca-fila-slicers', () => {
  try { return { ok: true, slicers: orcaFila.targets() }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:orca-fila-manifest', async () => {
  try { return { ok: true, manifest: await orcaFila.fetchManifest() }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:orca-fila-install', async (_e, { item, slicerId, printerLabel } = {}) => {
  try {
    const r = await orcaFila.installProfile(item, { slicerId, printerLabel });
    return { ok: true, path: r.path, slicer: r.slicer, printer: r.printer };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:orca-fila-reveal', async (_e, { slicerId } = {}) => {
  try {
    const { shell } = require('electron');
    const dir = orcaFila.filamentDirFor(slicerId);
    if (!dir) return { ok: false, error: 'No slicer detected yet.' };
    require('fs').mkdirSync(dir, { recursive: true });
    // openPath resolves with an error STRING (not a rejection) when it can't open — surface it so the
    // renderer can tell the user instead of the click silently doing nothing.
    const err = await shell.openPath(dir);
    if (err) return { ok: false, error: err };
    return { ok: true, dir };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:orca-fila-installed', (_e, { slicerId } = {}) => {
  try { return { ok: true, names: orcaFila.installedFilamentNames(slicerId) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// Calibration → tuned OrcaSlicer filament profile (Bed Ready). Targets = detected slicers with their
// printers + the user's own filament presets (bases to tune from); save writes the tuned preset in.
ipcMain.handle('hub:calib-targets', () => {
  try { return { ok: true, targets: calibProfile.calibrationTargets() }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});
ipcMain.handle('hub:calib-save-profile', (_e, opts = {}) => {
  try { return calibProfile.saveCalibratedProfile(opts); }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-review-summary', async (_e, { url, shopId } = {}) => {
  try { return { ok: true, summary: await cloudClient.getReviewSummary(url, shopId) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-list-reviews', async (_e, { url, shopId, token, limit } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, reviews: await cloudClient.listReviews(url, shopId, token, limit) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-delete-review', async (_e, { url, shopId, token, reviewId } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    await cloudClient.deleteReview(url, shopId, token, reviewId);
    return { ok: true };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-request-reset', async (_e, { url, email } = {}) => {
  try { return { ok: true, ...(await cloudClient.requestReset(url, { email })) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-reset-password', async (_e, { url, email, code, newPassword } = {}) => {
  try { return { ok: true, ...(await cloudClient.resetPassword(url, { email, code, newPassword })) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-request-verify', async (_e, { url, email } = {}) => {
  try { return { ok: true, ...(await cloudClient.requestVerify(url, { email })) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-verify-email', async (_e, { url, email, code } = {}) => {
  try { return { ok: true, ...(await cloudClient.verifyEmail(url, { email, code })) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// Customer portal: publish/unpublish an owner-curated (plaintext) item; list actions.
ipcMain.handle('hub:cloud-publish', async (_e, { url, shopId, token, pubToken, kind, payload, customerEmail } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.publishPortal(url, shopId, token, pubToken, kind, payload, customerEmail)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-unpublish', async (_e, { url, shopId, token, pubToken } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.unpublishPortal(url, shopId, token, pubToken)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-published-list', async (_e, { url, shopId, token } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, items: await cloudClient.listPublished(url, shopId, token) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-intake-list', async (_e, { url, shopId, token } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, items: await cloudClient.listIntake(url, shopId, token) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-intake-delete', async (_e, { url, shopId, token, id } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.deleteIntake(url, shopId, token, id)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-storefront-stats', async (_e, { url, shopId, token } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, stats: await cloudClient.storefrontStats(url, shopId, token) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-portal-messages', async (_e, { url, shopId, token, authToken } = {}) => {
  try {
    authToken = resolveStoreSecret(authToken, d => d?.settings?.cloud?.token);
    return { ok: true, messages: await cloudClient.portalMessages(url, shopId, token, authToken) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-portal-reply', async (_e, { url, shopId, token, authToken, text } = {}) => {
  try {
    authToken = resolveStoreSecret(authToken, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.portalReply(url, shopId, token, authToken, text)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-billing-me', async (_e, { url, shopId, token } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.billingMe(url, shopId, token)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// Store the (already-encrypted) keyset server-side so other devices can fetch it.
ipcMain.handle('hub:cloud-put-keyset', async (_e, { url, shopId, token, keyset } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.putKeyset(url, shopId, token, keyset)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-unlock', (_e, { url, shopId, token, keyset, passphrase } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    const dek = cloudClient.unlockWithPassphrase(String(passphrase || ''), keyset);
    cloudBackend = cloudClient.backendFor(url, shopId, token, dek, {
      // Warm launch: let this session start from the server view the last one
      // left behind, so the first pull asks for a slice instead of the base and
      // the whole chain. docs/KHAYT-CLOUD-DELTA-SYNC.md §7.
      cacheDir: ensureDir('cloud-cache'),
      // The store as it is ON DISK, which is what the cached view was last
      // reconciled against. Unsaved renderer edits only make local NEWER than
      // disk, and the check refuses on local being OLDER — so reading the file
      // here errs toward a cold pull, never toward adopting a view it should not.
      getLocalSnapshot: () => {
        try { return recoverStoreRaw(MAX_STORE_BYTES).data || null; } catch (e) { return null; }
      },
    });
    return { ok: true };
  } catch (e) { cloudBackend = null; return { ok: false, error: 'Wrong passphrase or invalid keyset' }; }
});

/* ── Organisations (multi-shop) ───────────────────────────────────────────────
 *
 * One org key opens every branch, so the owner unlocks once. See
 * docs/KHAYT-3.0-ORG-DATA-KEY.md.
 *
 * The Org Data Key is held for the session, exactly like a shop DEK: never
 * written to disk, gone when the app closes. Branch backends are built LAZILY —
 * on the first call that names a branch, not all at once on unlock. A branch
 * that is unreachable, or whose keyset is missing, then fails only the work that
 * touched it, instead of failing the unlock and taking every other branch with
 * it. It also matches how the sync loop already works: one shop at a time.
 */
let orgKey = null;                  // Buffer | null — the session's ODK
let orgId = null;                   // which org it belongs to

/** Drop every org-derived secret. Called on lock and on leaving an org. */
function clearOrgSession() {
  orgKey = null;
  orgId = null;
}

ipcMain.handle('hub:org-create-keyset', (_e, passphrase) => {
  try {
    const { orgKeyset, orgKey: key, recoveryKey } = cloudClient.createOrgKeyset(String(passphrase || ''));
    // Hold the key for this session so the caller can enrol branches straight
    // away without a second scrypt pass; the recovery key is shown once and
    // never stored.
    orgKey = key;
    orgId = orgKeyset.orgId;
    return { ok: true, orgKeyset, recoveryKey };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:org-unlock', (_e, { orgKeyset, passphrase, recoveryKey } = {}) => {
  try {
    orgKey = recoveryKey
      ? cloudClient.unlockOrgWithRecovery(String(recoveryKey), orgKeyset)
      : cloudClient.unlockOrgWithPassphrase(String(passphrase || ''), orgKeyset);
    orgId = orgKeyset && orgKeyset.orgId;
    return { ok: true, orgId };
  } catch (e) {
    clearOrgSession();
    return { ok: false, error: recoveryKey ? 'Wrong recovery key for this organisation' : 'Wrong organisation passphrase' };
  }
});

ipcMain.handle('hub:org-status', () => ({ unlocked: !!orgKey, orgId }));
ipcMain.handle('hub:org-lock', () => { clearOrgSession(); return { ok: true }; });

/** Add this shop's DEK to the org, so the org key opens it too. */
ipcMain.handle('hub:org-enrol-shop', (_e, { keyset, passphrase } = {}) => {
  try {
    if (!orgKey) return { ok: false, error: 'locked' };
    const dek = cloudClient.unlockWithPassphrase(String(passphrase || ''), keyset);
    return { ok: true, keyset: cloudClient.joinOrg(keyset, dek, orgKey, orgId) };
  } catch (e) { return { ok: false, error: 'Wrong passphrase or invalid keyset' }; }
});

/** Remove the org's way into this shop. Its own passphrase still opens it. */
ipcMain.handle('hub:org-remove-shop', (_e, { keyset } = {}) => {
  try { return { ok: true, keyset: cloudClient.leaveOrg(keyset) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:org-change-passphrase', (_e, { orgKeyset, currentPassphrase, newPassphrase } = {}) => {
  try {
    const rotated = cloudClient.changeOrgPassphrase(orgKeyset, String(currentPassphrase || ''), String(newPassphrase || ''));
    // The ODK itself does not change, so every branch's wrappedByOrg stays valid
    // and nothing is re-encrypted — the session key is still the right one.
    return { ok: true, orgKeyset: rotated };
  } catch (e) { return { ok: false, error: 'Wrong organisation passphrase' }; }
});

/**
 * The organisation overview: what is happening at every branch.
 *
 * One call, because the interesting failures are per branch and the caller wants
 * them side by side. Each branch is fetched and opened on its own — a branch that
 * has never pushed, or whose keyset is missing, or which this org key cannot open,
 * reports against ITSELF and the rest still come back. That is what the lazy
 * design was for; doing it all-or-nothing would let one bad branch blank the
 * screen.
 *
 * Only the SUMMARY crosses back. A branch store can be megabytes and the overview
 * needs a handful of counts; see lib/branch-summary.js for what is deliberately
 * not counted (money, and anything needing a calendar day).
 */
// `today` is the READER's calendar day, passed in rather than computed here:
// branches may sit in other timezones, and the day that decides what is late is
// the day of the person looking at the screen. Omitted → no late counts at all.
ipcMain.handle('hub:org-overview', async (_e, { url, shopId, token, today } = {}) => {
  if (!orgKey) return { ok: false, error: 'locked' };
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    const members = await cloudClient.getOrgKeysets(url, shopId, token);
    const branches = [];
    for (const m of members) {
      const row = { shopId: m.shopId, isSelf: m.shopId === shopId };
      try {
        if (!m.keyset) throw new Error('this branch has not finished setting up sync');
        const dek = cloudClient.unlockWithOrg(orgKey, orgId, m.keyset);
        const blob = await cloudClient.getBranchStore(url, shopId, token, m.shopId);
        if (!blob) { row.empty = true; branches.push(row); continue; }
        row.rev = blob.rev;
        // decryptBranchStore, not decryptStore: a branch may hold a delta chain
        // on top of its base, and summarising the base alone would report figures
        // missing its newest orders with nothing saying so.
        row.summary = summarizeBranch(cloudClient.decryptBranchStore(blob, dek), { today });
      } catch (e) {
        row.error = String(e && e.message || e);
      }
      branches.push(row);
    }
    return { ok: true, branches, total: totalBranches(branches.map((b) => b.summary)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

/* Org membership on the server — the wrapped org keyset and which branches are in. */
ipcMain.handle('hub:org-get', async (_e, { url, shopId, token } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, org: await cloudClient.getOrg(url, shopId, token) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:org-put', async (_e, { url, shopId, token, orgId: id, keyset } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.putOrg(url, shopId, token, id, keyset)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:org-leave', async (_e, { url, shopId, token } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    const r = await cloudClient.leaveOrgRemote(url, shopId, token);
    clearOrgSession();
    return { ok: true, ...r };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:org-invite', async (_e, { url, shopId, token } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.createOrgInvite(url, shopId, token)) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:org-join', async (_e, { url, shopId, token, code } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, ...(await cloudClient.joinOrgRemote(url, shopId, token, String(code || '').trim())) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:org-members', async (_e, { url, shopId, token } = {}) => {
  try {
    token = resolveStoreSecret(token, d => d?.settings?.cloud?.token);
    return { ok: true, members: await cloudClient.listOrgMembers(url, shopId, token) };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-lock', () => { cloudBackend = null; clearOrgSession(); return { ok: true }; });
ipcMain.handle('hub:cloud-push', async (_e, snapshot) => {
  if (!cloudBackend) return { ok: false, error: 'locked' };
  try { return { ok: true, ...(await cloudBackend.push(snapshot)) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-pull', async () => {
  if (!cloudBackend) return { ok: false, error: 'locked' };
  try { return { ok: true, ...(await cloudBackend.pull()) }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

/**
 * A restore or import has replaced local state — make the next sync cold.
 *
 * The restore path is renderer-side: this process only reads and decrypts the
 * file, and `applyStoreFromSnapshot` does the replacing. So the backend cannot
 * notice on its own that local just moved BACKWARDS, and its retained view then
 * claims the server holds records local no longer has at those revs — the one
 * direction that pushes older data over newer, on every device.
 * docs/KHAYT-CLOUD-DELTA-SYNC.md §7.
 *
 * Locked is not an error: with no backend there is no in-memory claim to drop,
 * and the cache on disk is checked against the restored store by
 * `viewSafeForLocal` at the next unlock, which is what that guard is for.
 */
ipcMain.handle('hub:cloud-forget-view', () => {
  if (!cloudBackend) return { ok: true, forgotten: false };
  try { cloudBackend.forgetServerView(); return { ok: true, forgotten: true }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

// Cloud snapshot history (cross-device restore). list returns metadata only;
// get decrypts the chosen version with the session DEK held in cloudBackend.
ipcMain.handle('hub:cloud-snapshots-list', async () => {
  if (!cloudBackend) return { ok: false, error: 'locked' };
  try { return { ok: true, snapshots: await cloudBackend.listSnapshots() }; }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:cloud-snapshot-get', async (_e, { id } = {}) => {
  if (!cloudBackend) return { ok: false, error: 'locked' };
  try {
    const snap = await cloudBackend.getSnapshot(id);
    if (!snap) return { ok: false, error: 'Snapshot not found' };
    return { ok: true, ...snap };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
});

ipcMain.handle('hub:fire-webhook', async (event, { url, event: webhookEvent, payload, secret }) => {
  // Restrict to https:// only — prevents SSRF to localhost and internal network
  if (!url || !url.startsWith('https://')) return { ok: false, error: 'Invalid URL — only https:// allowed' };
  let parsedWebhook;
  try {
    parsedWebhook = new URL(url);
    if (isBlockedHost(parsedWebhook.hostname)) return { ok: false, error: 'Blocked URL — cannot send webhooks to private/loopback addresses' };
  } catch { return { ok: false, error: 'Invalid webhook URL' }; }
  // DNS-rebinding defence: the string check above only inspects the hostname,
  // so a public-looking name (e.g. evil.example.com) could still resolve to an
  // internal IP. Resolve it and reject if ANY answer is in a blocked range.
  // NOTE: best-effort / TOCTOU — fetch() resolves again at connect time and
  // Node does not expose the resolved peer address for a post-connect re-check.
  if (await resolvesToBlockedHost(parsedWebhook.hostname)) {
    return { ok: false, error: 'Blocked URL — hostname resolves to a private/loopback address' };
  }
  try {
    const body = JSON.stringify({ event: webhookEvent, payload, timestamp: Date.now() });
    const headers = { 'Content-Type': 'application/json', 'X-Khayt-Event': webhookEvent };
    if (secret) headers['X-Khayt-Signature'] = require('crypto')
      .createHmac('sha256', secret).update(body).digest('hex');
    const res = await fetch(url, { method: 'POST', headers, body, redirect: 'manual', signal: AbortSignal.timeout(10000) });
    if (res.status >= 300 && res.status < 400) {
      return { ok: false, error: 'Webhook redirects are not allowed' };
    }
    return { ok: res.ok, status: res.status };
  } catch(e) { return { ok: false, error: String(e) }; }
});


/** The chat-id rule, shared with both windows and the Mac app. */
function telegramChatId(value) {
  try {
    return require('./lib/telegram-message.js').chatId(value);
  } catch (e) {
    return null;
  }
}

ipcMain.handle('hub:send-telegram', async (_e, { botToken, chatId, message } = {}) => {
  botToken = resolveStoreSecret(botToken, d => d?.settings?.telegram?.botToken);
  if (!botToken || !chatId || !message) return { ok: false, error: 'Missing params' };
  if (!/^[0-9]+:[A-Za-z0-9_-]+$/.test(botToken)) return { ok: false, error: 'Invalid bot token format' };
  /* The chat id, by the shared rule — a numeric id or a public @username.
   *
   * This used to be `String(chatId).replace(/[^0-9@-]/g, '')`, which keeps the
   * @ and THROWS THE NAME AWAY: a shop that typed "@khaytshop" was sending to
   * "@", getting a 400 back, and being told nothing. Now a value Telegram
   * could not deliver to is refused here, with a reason the shop can act on. */
  const chatIdStr = telegramChatId(chatId);
  if (!chatIdStr) return { ok: false, error: 'Invalid chat id — use a numeric id or @username' };
  if (isBlockedHost('api.telegram.org')) return { ok: false, error: 'Host is blocked' };
  const url = `https://api.telegram.org/bot${encodeURIComponent(botToken)}/sendMessage`;
  const body = JSON.stringify({ chat_id: chatIdStr, text: message.slice(0, 4096) });
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
      signal: AbortSignal.timeout(10000)
    });
    const data = await res.json().catch(() => ({}));
    return { ok: res.ok, status: res.status, data };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
});

/* ============================================================
   Window
   ============================================================ */
function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1400,
    height: 900,
    minWidth: 1024,
    minHeight: 700,
    title: FLAVOR_NAME,
    icon: appIconPath(),
    backgroundColor: '#0f172a',
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 16, y: 16 },
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,       // explicit — guards against accidental removal via build config
      navigateOnDragDrop: false,
    }
  });

  /* Right-click. Electron ships no default context menu, so Chromium underlined
   * misspellings and there was no way to reach a correction — and no Cut, Copy
   * or Paste anywhere either, which on Windows and Linux is how people copy
   * text at all. */
  contextMenu.attach(mainWindow, { Menu }, (key, fallback) => menuStrings[key] || fallback);

  mainWindow.loadFile(path.join(__dirname, 'renderer', ENTRY_HTML));

  // Prevent same-frame navigation away from the local app file.
  // Without this, renderer JS could do location.href = 'https://evil.com' and retain
  // full access to the contextBridge-exposed hubAPI under a foreign origin.
  mainWindow.webContents.on('will-navigate', (event, navigationUrl) => {
    if (!isAppIndexNavigation(navigationUrl)) {
      event.preventDefault();
    }
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('https://')) {
      try {
        const parsed = new URL(url);
        if (!isBlockedHost(parsed.hostname)) shell.openExternal(url);
      } catch { /* invalid URL — deny */ }
    } else if (url.startsWith('mailto:')) {
      shell.openExternal(url);
    }
    return { action: 'deny' };
  });
}

// Block navigation and new-window creation for any web contents spawned after startup.
app.on('web-contents-created', (_event, wc) => {
  wc.on('will-navigate', (event, navigationUrl) => {
    if (!isAppIndexNavigation(navigationUrl)) {
      event.preventDefault();
    }
  });
  wc.setWindowOpenHandler(() => ({ action: 'deny' }));
});

// Help-menu destinations. Kept as named constants so the menu below reads as a
// list of places rather than a wall of URLs, and so a typo is in one place.
const KHAYT_SITE = 'https://khaytapp.com';
const BEDREADY_SITE = 'https://bedready.io';
const KHAYT_SUBREDDIT = 'https://www.reddit.com/r/khayt';
const KHAYT_REPO = 'https://github.com/KhaytApp/Khayt';

/**
 * Open a Help-menu destination in the user's browser.
 *
 * Every caller passes a literal from the constants above, so this cannot
 * currently be handed anything hostile. The https check is here for the edit
 * that comes later: shell.openExternal will happily hand `file://` to the OS,
 * and a Help menu is an easy place for someone to wire up a local path without
 * thinking about it.
 */
function openHelpLink(url) {
  const target = String(url || '');
  if (!/^https:\/\//i.test(target)) {
    console.error('refusing to open a non-https help link:', target);
    return;
  }
  shell.openExternal(target).catch((e) => console.error('help link failed:', e));
}

function buildMenu() {
  const isMac = process.platform === 'darwin';
  const template = [
    ...(isMac ? [{
      // Electron derives app.name from package.json ("khayt"), so these role items would otherwise read
      // "About khayt" / "Hide khayt" / "Quit khayt" — even in Bed Ready. Override the name-bearing labels
      // with the flavor's product name (Bed Ready / Khayt). Deliberately NOT app.setName(): that would
      // repoint app.getPath('userData') from …/khayt and orphan every user's data.
      label: FLAVOR_NAME,
      submenu: [
        { role: 'about', label: `About ${FLAVOR_NAME}` }, { type: 'separator' },
        { role: 'services' }, { type: 'separator' },
        { role: 'hide', label: `Hide ${FLAVOR_NAME}` }, { role: 'hideOthers' }, { role: 'unhide' }, { type: 'separator' },
        { role: 'quit', label: `Quit ${FLAVOR_NAME}` }
      ]
    }] : []),
    { label: 'File', submenu: [ isMac ? { role: 'close' } : { role: 'quit' } ] },
    {
      label: 'Edit', submenu: [
        { role: 'undo' }, { role: 'redo' }, { type: 'separator' },
        { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }
      ]
    },
    {
      label: 'View', submenu: [
        { role: 'reload' }, { role: 'forceReload' },
        ...(!app.isPackaged ? [{ role: 'toggleDevTools' }] : []),
        { type: 'separator' },
        { role: 'resetZoom' }, { role: 'zoomIn' }, { role: 'zoomOut' }, { type: 'separator' },
        { role: 'togglefullscreen' }
      ]
    },
    {
      label: 'Window', submenu: [
        { role: 'minimize' }, { role: 'zoom' },
        ...(isMac ? [ { type: 'separator' }, { role: 'front' } ] : [ { role: 'close' } ])
      ]
    },
    {
      // There was no Help menu at all, so a shop that wanted the docs, the
      // release notes, or somewhere to report a bug had nowhere in the app to
      // find any of them.
      role: 'help',
      submenu: [
        { label: `${FLAVOR_NAME} Website`, click: () => openHelpLink(isBedReady ? BEDREADY_SITE : KHAYT_SITE) },
        // The subreddit belongs to Khayt. Bed Ready is a separate brand to the
        // people running it, and putting "r/khayt" in their Help menu would be
        // the first they had heard of the other product.
        ...(isBedReady ? [] : [
          { label: 'Community — r/khayt', click: () => openHelpLink(KHAYT_SUBREDDIT) },
        ]),
        { type: 'separator' },
        { label: 'Release Notes', click: () => openHelpLink(`${KHAYT_REPO}/releases`) },
        { label: 'Report an Issue', click: () => openHelpLink(`${KHAYT_REPO}/issues/new`) },
      ]
    }
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ── MakerRun deep-link sign-in (bedready://auth#access_token=…&refresh_token=…) ────────────────────────
// Single-instance so a protocol activation (Windows/Linux relaunch) forwards its argv to the running app
// instead of opening a second window; macOS delivers the URL via 'open-url'. Also gives Khayt one instance
// (one data store), which is the desired behaviour for a business app.
const makerrunAccount = require('./lib/makerrun-account');
if (!app.requestSingleInstanceLock()) {
  app.quit();
  return;
}
// Only the Bed Ready flavor owns the bedready:// scheme — Khayt has no MakerRun-account UI and must
// not claim the scheme (it would cold-launch Khayt and write a token file it can't use).
if (isBedReady) { try { app.setAsDefaultProtocolClient('bedready'); } catch { /* unpackaged/dev — fine */ } }

function handleBedreadyLink(url) {
  if (!isBedReady) return; // defence in depth — never link a MakerRun account on the Khayt flavor
  if (!url || String(url).indexOf('bedready://') !== 0) return;
  // Login-CSRF defence: accept only a link the app itself initiated within the arm window. A drive-by
  // bedready://auth#refresh_token=… fired by a random web page finds the app un-armed → ignored, so it
  // can't silently re-link the app to an attacker's account (session fixation).
  if (!bedreadyLinkArmedAt || Date.now() - bedreadyLinkArmedAt > BEDREADY_LINK_ARM_WINDOW_MS) return;
  bedreadyLinkArmedAt = 0; // single-use
  const tokens = makerrunAccount.parseDeepLink(url);
  if (!tokens) return;
  // Nonce check (defence-in-depth over the arm window): the link MUST carry a `state` equal to the nonce
  // we minted when we opened this sign-in (the website always echoes it). This closes the login-CSRF
  // residual where a state-less link was accepted on the arm window alone. Timing-safe compare avoids
  // leaking the nonce via response timing.
  const expected = bedreadyLinkNonce;
  bedreadyLinkNonce = ''; // single-use regardless of outcome
  if (!tokens.state || !expected) return;
  const a = Buffer.from(tokens.state);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return;
  if (makerrunAccount.link(app.getPath('userData'), tokens)) {
    const win = mainWindow || BrowserWindow.getAllWindows()[0];
    if (win) { try { if (win.isMinimized()) win.restore(); win.focus(); win.webContents.send('bedready-linked'); } catch { /* window gone */ } }
  }
}
const isBedreadyLink = (a) => typeof a === 'string' && a.indexOf('bedready://') === 0;
let pendingBedreadyLink = process.argv.find(isBedreadyLink) || null; // cold-start (Windows/Linux) via argv

app.on('second-instance', (_e, argv) => {
  const win = mainWindow || BrowserWindow.getAllWindows()[0];
  if (win) { try { if (win.isMinimized()) win.restore(); win.focus(); } catch { /* window gone */ } }
  const link = (argv || []).find(isBedreadyLink);
  if (link) handleBedreadyLink(link);
});
app.on('open-url', (event, url) => { // macOS
  event.preventDefault();
  if (mainWindow) handleBedreadyLink(url); else pendingBedreadyLink = url;
});


// --- Store ownership -------------------------------------------------------
//
// Khayt has always had exactly one writer and never said so. `requestSingleInstanceLock`
// keeps the renderer, the LAN handlers, the printer poll and the updater inside one
// process, and store-io's write chain serialises them; the invariant held because
// nothing else on the machine could open the file. The native Mac app can. This
// publishes who owns the book so the newcomer can stay out of the way.
//
// EVERY PATH HERE IS BEST-EFFORT ON PURPOSE. A lock that can stop a shop opening its
// own app is worse than the collision it guards against, so nothing below is allowed
// to throw into startup. Electron is the writer, and it takes ownership even when it
// finds a live foreign holder — today the only other holder is a reader, and refusing
// to launch on the strength of a file would be a far bigger failure than the one being
// prevented. The verdict is recorded so a later release can act on it.
const StoreLock = require('./lib/store-lock');
let _storeLockBeat = null;
let _storeLockMine = null;

const storeLockPath = () => path.join(app.getPath('userData'), StoreLock.LOCK_FILENAME);

function readStoreLockRecord() {
  try { return JSON.parse(fs.readFileSync(storeLockPath(), 'utf8')); } catch (_) { return null; }
}

/** Is that pid a running process? EPERM means it exists and is not ours. */
function pidIsAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (e) { return !!(e && e.code === 'EPERM'); }
}

function acquireStoreOwnership() {
  try {
    const os = require('os');
    const host = String(os.hostname() || '');
    const existing = readStoreLockRecord();
    const sameHost = existing && String(existing.host || '') === host;
    const alive = sameHost && Number(existing.pid) ? pidIsAlive(Number(existing.pid)) : null;
    const verdict = StoreLock.decide(existing, { pid: process.pid, host, now: Date.now(), alive });
    if (verdict.action === 'held') {
      console.warn('store lock:', StoreLock.describe({ ...verdict, selfHost: host })
        || 'another application claims this store; taking ownership anyway');
    }
    _storeLockMine = StoreLock.claim({ app: 'Khayt', pid: process.pid, host, now: Date.now() });
    fs.writeFileSync(storeLockPath(), JSON.stringify(_storeLockMine));
    // A heartbeat is what lets a lock left by a crash on ANOTHER machine be
    // broken later; on this one, liveness answers it and the beat is belt and braces.
    _storeLockBeat = setInterval(() => {
      try {
        _storeLockMine = StoreLock.beat(_storeLockMine, Date.now());
        fs.writeFileSync(storeLockPath(), JSON.stringify(_storeLockMine));
      } catch (_) { /* a lock we cannot refresh is not worth crashing over */ }
    }, StoreLock.HEARTBEAT_MS);
    if (_storeLockBeat.unref) _storeLockBeat.unref();
  } catch (e) {
    console.warn('store lock: could not take ownership —', (e && e.message) || e);
  }
}

/** Give it up on the way out. A crash skips this, and the next start sees a dead pid. */
function releaseStoreOwnership() {
  try { if (_storeLockBeat) clearInterval(_storeLockBeat); } catch (_) {}
  _storeLockBeat = null;
  try {
    const current = readStoreLockRecord();
    if (current && _storeLockMine && Number(current.pid) === Number(_storeLockMine.pid)
        && String(current.host || '') === String(_storeLockMine.host || '')) {
      fs.unlinkSync(storeLockPath());
    }
  } catch (_) { /* nothing left to release */ }
}

app.whenReady().then(() => {
  acquireStoreOwnership();
  completePendingFullWipe();
  applyDockIcon();
  buildMenu();
  createWindow();
  if (pendingBedreadyLink) { handleBedreadyLink(pendingBedreadyLink); pendingBedreadyLink = null; }
  migrateLegacyStatusPages().catch((e) => console.warn('status page migration:', e?.message || e));
  setupAutoUpdater(mainWindow);
  // Sends nothing without consent, and nothing at all while the server-side
  // ingest is dormant — it 404s, keeps the queue and waits. See the block above
  // TELEMETRY_QUEUE_FILE.
  startTelemetryFlush();
  startLeadTimePublisher();

  const { session } = require('electron');

  // ── Content Security Policy ───────────────────────────────────────────────
  // Applied to every response served to the renderer. Tightens XSS impact:
  //   • script-src 'self'  — only scripts bundled with the app; no inline eval
  //   • connect-src 'self' + external APIs the app legitimately calls
  //   • object-src 'none'  — no Flash / plugin execution
  //   • base-uri 'none'    — prevents <base href="…"> attacks
  session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': [
          [
            "default-src 'self'",
            "script-src 'self'",  // Renderer uses data-act delegation; exported LAN/survey HTML may use inline scripts outside this CSP
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",  // keep in sync with renderer/index.html meta CSP
            "img-src 'self' data: blob: https://*.supabase.co",  // *.supabase.co: MakerRun library cover thumbnails (Supabase storage) in the Bed Ready flavor
            "font-src 'self' data: https://fonts.gstatic.com",
            "connect-src 'self' https://api.telegram.org https://api.sendgrid.com https://api.mailgun.net https://api.tabby.ai https://api.tamara.co https://api.stripe.com https://gw-fatoorah.zatca.gov.sa https://gw-apic-gov.gazt.gov.sa",
            "media-src 'self' blob:",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
          ].join('; ')
        ]
      }
    });
  });

  // Grant camera access so the filament label scanner can use getUserMedia({video}).
  // Microphone is intentionally NOT granted — the app never captures audio, so this
  // keeps the permission surface to exactly what the scanner needs.
  //
  // 'clipboard-sanitized-write' is what Chromium asks for on every
  // navigator.clipboard.writeText(). Without it that call rejects with
  // NotAllowedError, which silently killed all ~25 "Copy link" buttons in the
  // renderer — the storefront import/feed links, portal and quote URLs, the
  // colour hex picker, print plans. Reading the clipboard is still denied: the
  // app never pastes on the user's behalf, and clipboard-read is the half that
  // could exfiltrate whatever else the user has copied.
  session.defaultSession.setPermissionRequestHandler((_webContents, permission, callback) => {
    const allowed = ['media', 'camera', 'clipboard-sanitized-write'];
    callback(allowed.includes(permission));
  });

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

// ── Flush the renderer's debounced save before quitting ─────────────────────
// saveAll() debounces ~300ms. With no quit handshake, any edit made within that window
// of Cmd+Q or a window close was simply lost, and an in-flight write was killed
// mid-flight. flushSave() already existed in the renderer; nothing ever called it on
// quit. Bounded so a wedged renderer can never make the app unquittable.
let _flushedForQuit = false;
// Set as soon as a quit begins, and read by hub:save-store so the quit flush is
// never blocked behind a modal nobody can dismiss. Module-level, so it is
// initialised long before any IPC callback can run.
let _quittingNow = false;
app.on('before-quit', (e) => {
  _quittingNow = true;
  if (_flushedForQuit) return;
  const win = BrowserWindow.getAllWindows()[0];
  if (!win || win.webContents.isDestroyed()) { _flushedForQuit = true; return; }
  e.preventDefault();
  let done = false;
  const finish = () => {
    if (done) return;
    done = true;
    _flushedForQuit = true;
    ipcMain.removeListener('hub:flush-save-done', finish);
    app.quit();
  };
  ipcMain.once('hub:flush-save-done', finish);
  try { win.webContents.send('hub:flush-save-request'); } catch (_) { return finish(); }
  // Quit anyway if the renderer doesn't answer — never trap the user in the app. 3s proved
  // too tight under load (a CI run quit before the write completed); 10s still bounds a
  // wedged renderer while leaving room for a large store to be serialised and fsynced.
  setTimeout(finish, 10_000);
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
